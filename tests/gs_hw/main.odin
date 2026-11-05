// The GPU GS against the software GS, bit for bit on all of local memory,
// for draws that sample the buffers they write: per case a picture
// uploaded, then sprites over it, each pixel sampling a texel the same
// sprite writes later in the software GS's order. Each case runs twice in
// a row in software and twice on the GPU, every GPU case against its
// software twin, so a race between a primitive's samples and its own
// writes shows as a mismatch. Each resolution scale runs in a child of its
// own (the GPU GS starts once a process). Needs a Vulkan device: without
// one it says so on stderr and exits 0, which is a skip, not a pass.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "ps:ps2/gs"

@(private = "file")
failed := 0

@(private = "file")
fail :: proc(msg: string, args: ..any) {
	fmt.eprintfln(msg, ..args)
	failed += 1
}

@(private = "file")
W, H :: 256, 224 // each sprite, from (0, 0)

@(private = "file")
PASSES :: 32

@(private = "file")
ROUNDS :: 2

// The software GS draws a sprite's rows top down, so a pixel sampling a
// texel the sprite writes on a later row reads it as it stood before the
// sprite, which is what the GPU's copy of it gives. Every case samples so:
// a texel written on an earlier row would read new in software and old on
// the GPU, a difference that is no race and that this compare must not see.
// The UVs are half a texel in, so each pixel samples a texel's centre: on a
// texel's edge the GPU's interpolation lands either side of it.
@(private = "file")
Case :: struct {
	name: string,
	draw: proc(),
}

@(private = "file")
CASES := [?]Case {
	{"ct32", ct32},
	{"t8 clut", t8_clut},
	{"region repeat", region_repeat},
	{"z as texture", z_texture},
	{"top pages", top_pages},
	{"past width", past_width},
}

// Local memory after each case of each software round.
@(private = "file")
want: [ROUNDS][len(CASES)][]u32

// A picture of w x h CT32 pixels at block bp, every pixel a different
// colour, alpha kept.
@(private = "file")
picture :: proc(bp, bw, w, h: u64) {
	px := make([]u32, w * h, context.temp_allocator)
	seed: u32 = 0x9e3779b9 ~ u32(bp)
	for &v in px {
		seed ~= seed << 13
		seed ~= seed >> 17
		seed ~= seed << 5
		v = seed
	}
	gs.gs_write(0x50, bp << 32 | bw << 48) // BITBLTBUF: PSMCT32
	gs.gs_write(0x51, 0) // TRXPOS
	gs.gs_write(0x52, w | h << 32) // TRXREG
	gs.gs_write(0x53, 0) // TRXDIR: host to local
	gs.transfer(slice.to_bytes(px))
}

// Context 1's registers for a case: DECAL, point sampled, UV.
@(private = "file")
setup :: proc(frame, zbuf, test, clamp, tex0: u64) {
	gs.gs_write(0x4c, frame) // FRAME_1
	gs.gs_write(0x4e, zbuf) // ZBUF_1
	gs.gs_write(0x47, test) // TEST_1
	gs.gs_write(0x40, (W - 1) << 16 | (H - 1) << 48) // SCISSOR_1
	gs.gs_write(0x18, 0) // XYOFFSET_1
	gs.gs_write(0x1a, 1) // PRMODECONT
	gs.gs_write(0x14, 0) // TEX1_1: nearest
	gs.gs_write(0x08, clamp) // CLAMP_1
	gs.gs_write(0x06, tex0) // TEX0_1
}

// PASSES sprites, (0, 0) to (W, H), texel (x, y) of the frame from texel
// (u0 + x, v0 + dv * y) (1/16 texel units, per pixel row for dv), at z
// 1, 2, ...
@(private = "file")
sprites :: proc(u0, v0, dv: u64) {
	for p in 1 ..= u64(PASSES) {
		gs.gs_write(0x00, 6 | 1 << 4 | 1 << 8) // PRIM: SPRITE, TME, FST
		gs.gs_write(0x01, 0x80808080)
		gs.gs_write(0x03, u0 | v0 << 16) // UV
		gs.gs_write(0x05, p << 32) // XYZ2 (0, 0)
		gs.gs_write(0x03, u0 + W << 4 | (v0 + dv * H) << 16)
		gs.gs_write(0x05, W << 4 | (H << 4) << 16 | p << 32) // XYZ2 (W, H)
	}
}

// TEX0's fields for a PSMCT32 texture: TBW, log2 width and height, TCC, DECAL.
@(private = "file")
tex0 :: proc(tbp, tbw, tw, th: u64) -> u64 {
	return tbp | tbw << 14 | tw << 26 | th << 30 | 1 << 34 | 1 << 35
}

@(private = "file")
ZMSK :: 1 << 32

// The frame as a 1024 x 512 texture, each pixel from the one below. At
// scales 1 and 2 the GPU decodes it; at scale 3 it is too big to decode
// (512K words a layer) and is read from a copy of its pages.
@(private = "file")
ct32 :: proc() {
	picture(0, 4, W, 256)
	setup(4 << 16, 0x100 | ZMSK, 0, 0, tex0(0, 4, 10, 9))
	sprites(8, 1 << 4 + 8, 16)
}

// The frame's pages as a PSMT8 texture through a CT32 CLUT. 512 texels
// wide, its pages lie in rows of four like the frame's, and the 8-pixel
// block row of texel row v is frame row 8 * (v / 16) up: sampling row
// 2y + 16 reads below pixel row y, rows the sprite writes later.
@(private = "file")
t8_clut :: proc() {
	CBP :: 9600 // page 300
	picture(0, 4, W, 256)
	picture(CBP, 1, 16, 16)
	PSMT8 :: 0x13
	setup(4 << 16, 0x100 | ZMSK, 0, 0, 8 << 14 | PSMT8 << 20 | 9 << 26 | 9 << 30 | 1 << 34 | 1 << 35 | CBP << 37 | 1 << 61)
	sprites(8, 16 << 4 + 8, 32)
}

// The frame as a 64 x 64 texture in region repeat, MINU = MINV = 255 the
// mask: texels past its 64 rows and columns, each pixel from the one below.
@(private = "file")
region_repeat :: proc() {
	picture(0, 4, W, 256)
	setup(4 << 16, 0x100 | ZMSK, 0, 3 | 3 << 2 | 0xff << 4 | 0xff << 24, tex0(0, 4, 6, 6))
	sprites(8, 1 << 4 + 8, 16)
}

// The depth buffer (PSMZ32, page 64, written by every sprite at z = its
// pass) as a CT32 texture, drawn to a frame on other pages. A Z32 page
// lays its blocks out other than a CT32 page (halves of its rows and
// columns swapped), so a texel's depth pixel can lie anywhere in its page:
// each pixel samples texel row y + 32, in the page row below. Region clamp, which
// here clamps as CLAMP does, keeps the texture undecoded.
@(private = "file")
z_texture :: proc() {
	ZBP :: 64
	picture(ZBP * 32, 4, W, 256)
	ZTE_ALWAYS :: 1 << 16 | 1 << 17
	setup(128 | 4 << 16, ZBP, ZTE_ALWAYS, 2 | 2 << 2 | 255 << 14 | 255 << 34, tex0(ZBP * 32, 4, 8, 8))
	sprites(8, 32 << 4 + 8, 16)
}

// The frame and texture on pages 504 up, which wrap past the last page to
// page 0, each pixel from the one below; region clamp, undecoded.
@(private = "file")
top_pages :: proc() {
	FBP :: 504
	picture(FBP * 32, 4, W, 256)
	setup(FBP | 4 << 16, 0x100 | ZMSK, 0, 2 | 2 << 2 | 255 << 14 | 255 << 34, tex0(FBP * 32, 4, 8, 8))
	sprites(8, 1 << 4 + 8, 16)
}

// The frame as a texture sampled past its buffer's width, TBW 4 (256
// texels): texel (x + 512, v) lies in page (v / 32 + 2) * 4 + x / 64, frame
// pixel (x, v + 64). Each pixel samples v = y + 1, frame row y + 65, up to
// row 288 (page 36): the pages past row 255 (page 32) are in the copy only
// through the span's term for texels past the width. Region clamp, 512..767,
// undecoded.
@(private = "file")
past_width :: proc() {
	picture(0, 4, W, 320)
	setup(4 << 16, 0x100 | ZMSK, 0, 2 | 2 << 2 | 512 << 4 | 767 << 14 | 255 << 34, tex0(0, 4, 10, 8))
	sprites(512 << 4 + 8, 1 << 4 + 8, 16)
}

main :: proc() {
	if len(os.args) == 2 {
		scale, _ := strconv.parse_uint(os.args[1])
		child(u32(scale))
	}
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		fmt.eprintfln("FAIL gs_hw: cannot find the test: %v", err)
		os.exit(1)
	}
	for scale in 1 ..= 3 {
		state, out, errs, perr := os.process_exec({command = {self, fmt.tprint(scale)}}, context.temp_allocator)
		os.write(os.stdout, out)
		os.write(os.stderr, errs)
		switch {
		case perr != nil:
			fail("FAIL gs_hw scale %d: cannot run the child: %v", scale, perr)
		case state.exited && state.exit_code == 2:
			os.exit(0) // no Vulkan device, said on stderr
		case state.exited && state.exit_code == 0:
		case:
			fail("FAIL gs_hw scale %d: status %d", scale, state.exit_code)
		}
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok gs_hw")
}

// One scale: the software rounds, then the GPU rounds against them. Exits
// 0 when every case matches, 1 when one does not, 2 with no Vulkan device.
@(private = "file")
child :: proc(scale: u32) -> ! {
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer

	for r in 0 ..< ROUNDS {
		for c, i in CASES {
			c.draw()
			want[r][i] = slice.clone(gs.vram[:])
		}
	}

	if !gs.hw_init(nil, scale) {
		fmt.eprintln("gs_hw: skip, no Vulkan device")
		os.exit(2)
	}
	for r in 0 ..< ROUNDS {
		for c, i in CASES {
			c.draw()
			gs.hw_download()
			for v, a in gs.vram {
				if v != want[r][i][a] {
					fail("FAIL gs_hw scale %d, round %d, %s: word %x %08x, software %08x", scale, r + 1, c.name, a, v, want[r][i][a])
					break
				}
			}
		}
	}
	os.exit(failed != 0 ? 1 : 0)
}
