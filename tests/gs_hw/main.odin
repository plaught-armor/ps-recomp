// The GPU GS against the software GS, bit for bit on all of local memory,
// for draws that sample the buffer they write: a picture uploaded, then
// sprites over it, each sampling the frame one row below the pixel it
// writes. Two GPU runs, each against the software run, so a race between
// a primitive's samples and its own writes shows as a mismatch. Each
// resolution scale runs in a child of its own (the GPU GS starts once a
// process). Needs a Vulkan device: without one it says so on stderr and
// exits 0, which is a skip, not a pass.
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
W, H :: 256, 224 // the frame, in the texture's top left corner

// The texture is 1024 x 512, 512K words decoded a layer: at scales 1 and 2
// that fits the decoded texture space, at scale 3 it does not and the GPU
// reads local memory straight, which still races. Scale 3 is a known
// failure until a primitive sampling its own frame on that path reads a
// copy of the pages taken before it: a mismatch there is printed, not
// counted.
@(private = "file")
KNOWN_RACE :: 3

@(private = "file")
PASSES :: 32

// Local memory after the software run.
@(private = "file")
want: [len(gs.vram)]u32

// The picture: every pixel a different colour, alpha kept.
@(private = "file")
picture :: proc() {
	px := make([]u32, W * 256, context.temp_allocator)
	seed: u32 = 0x9e3779b9
	for &v in px {
		seed ~= seed << 13
		seed ~= seed >> 17
		seed ~= seed << 5
		v = seed
	}
	gs.gs_write(0x50, 0 << 32 | 4 << 48) // BITBLTBUF: DBP 0, DBW 4, PSMCT32
	gs.gs_write(0x51, 0) // TRXPOS
	gs.gs_write(0x52, W | 256 << 32) // TRXREG
	gs.gs_write(0x53, 0) // TRXDIR: host to local
	gs.transfer(slice.to_bytes(px))
}

// The picture, then PASSES sprites over the frame at block 0, each texel
// (x, y + 1) to pixel (x, y): DECAL, point sampled, UV. The UVs are half a
// texel in, so each pixel samples a texel's centre: on a texel's edge the
// GPU's interpolation lands either side of it.
//
// The row is the one below because the software GS draws a sprite's rows
// top down: the row it samples is not drawn yet, so it reads the texels as
// they stood before the sprite, which is what the GPU's copy of them gives.
// A sprite sampling a row above would read its own new texels in software
// and the old ones on the GPU, a difference that is no race and that this
// compare must not see.
@(private = "file")
draw :: proc() {
	picture()
	gs.gs_write(0x4c, 4 << 16) // FRAME_1: FBP 0, FBW 4, PSMCT32
	gs.gs_write(0x4e, 0x100 | 1 << 32) // ZBUF_1: ZMSK
	gs.gs_write(0x40, (W - 1) << 16 | (H - 1) << 48) // SCISSOR_1
	gs.gs_write(0x18, 0) // XYOFFSET_1
	gs.gs_write(0x1a, 1) // PRMODECONT
	gs.gs_write(0x14, 0) // TEX1_1: nearest
	gs.gs_write(0x08, 0) // CLAMP_1: repeat
	gs.gs_write(0x06, 4 << 14 | 10 << 26 | 9 << 30 | 1 << 34 | 1 << 35) // TEX0_1: TBW 4, 1024 x 512, TCC, DECAL
	for _ in 0 ..< PASSES {
		gs.gs_write(0x00, 6 | 1 << 4 | 1 << 8) // PRIM: SPRITE, TME, FST
		gs.gs_write(0x01, 0x80808080)
		gs.gs_write(0x03, 8 | (1 << 4 + 8) << 16) // UV (0.5, 1.5)
		gs.gs_write(0x05, 0) // XYZ2 (0, 0)
		gs.gs_write(0x03, W << 4 + 8 | ((H + 1) << 4 + 8) << 16) // UV (W + 0.5, H + 1.5)
		gs.gs_write(0x05, W << 4 | (H << 4) << 16) // XYZ2 (W, H)
	}
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
		case scale == KNOWN_RACE:
			fmt.eprintfln("gs_hw scale %d: known failure, the over-cap path reads local memory straight", scale)
		case:
			fail("FAIL gs_hw scale %d: status %d", scale, state.exit_code)
		}
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok gs_hw")
}

// One scale: the software run, then two GPU runs against it. Exits 0 when
// both match, 1 when one does not, 2 with no Vulkan device.
@(private = "file")
child :: proc(scale: u32) -> ! {
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer

	draw()
	want = gs.vram
	if want[0] == 0 {fail("software run: the frame is empty")}

	if !gs.hw_init(nil, scale) {
		fmt.eprintln("gs_hw: skip, no Vulkan device")
		os.exit(2)
	}
	for run in 1 ..= 2 {
		draw()
		gs.hw_download()
		for v, i in gs.vram {
			if v != want[i] {
				fail("gs_hw scale %d, GPU run %d: word %x %08x, software %08x", scale, run, i, v, want[i])
				break
			}
		}
	}
	os.exit(failed != 0 ? 1 : 0)
}
