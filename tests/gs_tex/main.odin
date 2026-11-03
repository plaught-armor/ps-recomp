// The software GS's decoded texture cache: a texture sampled again after
// each kind of write to it reads the new texels. Host-to-local uploads,
// draws into the texture's pages, local copies, CLUT loads and snapshot
// loads each change what a draw samples; a draw sampling the buffer it
// writes sees its own earlier primitives, in the same context too; and two textures of 4096 tiles
// each, sampled tile by tile past the pool's size, read right on every
// sample and again after their tiles are reused.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "ps:core"
import "ps:ps2/gs"

@(private = "file")
failed := 0

@(private = "file")
fail :: proc(msg: string, args: ..any) {
	fmt.eprintfln(msg, ..args)
	failed += 1
}

// Pages. T: a 64x64 PSMCT32 texture; S: copy source; F: frame; T4: a 64x64
// PSMT4 texture; P: its CLUT; A and B: 1024x1024 PSMT4 textures, 64 pages
// each.
@(private = "file")
T, S, F, T4, P, A, B :: 0x20, 0x21, 0x60, 0x22, 0x23, 0x80, 0xc0

@(private = "file")
PSMCT32, PSMT4 :: 0x00, 0x14

// Host-to-local transfer of w x h pixels to (x, y) of the buffer at page p.
@(private = "file")
upload :: proc(p, bw, psm, x, y, w, h: u64, data: []u8) {
	gs.gs_write(0x50, (p * 32) << 32 | bw << 48 | psm << 56) // BITBLTBUF: DBP, DBW, DPSM
	gs.gs_write(0x51, x << 32 | y << 48) // TRXPOS: DSAX, DSAY
	gs.gs_write(0x52, w | h << 32) // TRXREG
	gs.gs_write(0x53, 0) // TRXDIR: host to local
	gs.transfer(data)
}

// One PSMCT32 colour for all w x h pixels.
@(private = "file")
fill :: proc(p, x, y, w, h: u64, col: u32) {
	px := make([]u32, w * h, context.temp_allocator)
	for &v in px {v = col}
	upload(p, 1, PSMCT32, x, y, w, h, slice.to_bytes(px))
}

// A sprite (x0, y0)..(x1, y1) into the 64-wide PSMCT32 buffer at page fbp,
// UV (u0, v0)..(u1, v1) in texels, from TEX0 tex0 when it is not 0 (DECAL).
@(private = "file")
sprite :: proc(fbp, tex0: u64, x0, y0, x1, y1: u64, u0, v0, u1, v1: u64, col: u64 = 0x80000000) {
	gs.gs_write(0x4c, fbp | 1 << 16) // FRAME_1: FBW 1, PSMCT32
	gs.gs_write(0x4e, 0x100 | 1 << 32) // ZBUF_1: ZMSK
	gs.gs_write(0x40, 63 << 16 | 63 << 48) // SCISSOR_1: 0..63
	gs.gs_write(0x18, 0) // XYZOFFSET_1
	gs.gs_write(0x1a, 1) // PRMODECONT
	prim: u64 = 6 | 1 << 8 // SPRITE, FST
	if tex0 != 0 {
		gs.gs_write(0x06, tex0)
		prim |= 1 << 4
	}
	gs.gs_write(0x00, prim)
	gs.gs_write(0x01, col)
	gs.gs_write(0x03, u0 << 4 | (v0 << 4) << 16)
	gs.gs_write(0x05, x0 << 4 | (y0 << 4) << 16)
	gs.gs_write(0x03, u1 << 4 | (v1 << 4) << 16)
	gs.gs_write(0x05, x1 << 4 | (y1 << 4) << 16)
}

// TEX0 for a 2^tw square texture at page p, bw wide, DECAL; a PSMT4 one
// loads its PSMCT32 CLUT from page P.
@(private = "file")
tex0 :: proc(p, bw, psm, tw: u64) -> u64 {
	t := (p * 32) | bw << 14 | psm << 20 | tw << 26 | tw << 30 | 1 << 35
	if psm == PSMT4 {t |= (P * 32) << 37 | 1 << 61} // CBP, CLD 1
	return t
}

@(private = "file")
at :: proc(p, x, y: u32) -> u32 {return gs.read_raw(PSMCT32, p * 32, 1, x, y) & 0xffffff}

// The 16 CLUT entries at page P, PSMCT32 CSM1 (8x2).
@(private = "file")
set_clut :: proc(base: u32) {
	px: [16]u32
	for &v, i in px {v = base + u32(i) * 0x010101}
	upload(P, 1, PSMCT32, 0, 0, 8, 2, slice.to_bytes(px[:]))
}

@(private = "file")
idx_a :: proc(x, y: u32) -> u32 {return (x ~ (y * 3) ~ (x >> 4)) & 15}
@(private = "file")
idx_b :: proc(x, y: u32) -> u32 {return (x * 5 + y + (y >> 4)) & 15}

main :: proc() {
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer

	// Texel (x, y) of T is x | y << 8 | 0x40 << 16.
	tx: [64 * 64]u32
	for &v, i in tx {v = u32(i % 64) | u32(i / 64) << 8 | 0x40 << 16}
	upload(T, 1, PSMCT32, 0, 0, 64, 64, slice.to_bytes(tx[:]))
	tt := tex0(T, 1, PSMCT32, 6)
	sprite(F, tt, 0, 0, 16, 16, 0, 0, 16, 16)
	if at(F, 5, 9) != 0x400905 {fail("first sample: %x", at(F, 5, 9))}

	fill(T, 0, 0, 8, 16, 0x111111)
	sprite(F, tt, 0, 0, 16, 16, 0, 0, 16, 16)
	if at(F, 5, 9) != 0x111111 {fail("sample after an upload: %x", at(F, 5, 9))}
	if at(F, 9, 9) != 0x400909 {fail("texel the upload missed: %x", at(F, 9, 9))}

	sprite(T, 0, 0, 0, 8, 16, 0, 0, 0, 0, 0x80222222) // draw into the texture
	sprite(F, tt, 0, 0, 16, 16, 0, 0, 16, 16)
	if at(F, 5, 9) != 0x222222 {fail("sample after a draw into the texture: %x", at(F, 5, 9))}

	fill(S, 0, 0, 8, 8, 0x333333)
	gs.gs_write(0x50, S * 32 | 1 << 16 | (T * 32) << 32 | 1 << 48) // BITBLTBUF: S to T
	gs.gs_write(0x51, 0)
	gs.gs_write(0x52, 8 | 8 << 32)
	gs.gs_write(0x53, 2) // local copy
	sprite(F, tt, 0, 0, 16, 16, 0, 0, 16, 16)
	if at(F, 5, 7) != 0x333333 {fail("sample after a local copy: %x", at(F, 5, 7))}

	// A texture inside the frame: the second sprite reads the first.
	sprite(F, 0, 32, 0, 40, 8, 0, 0, 0, 0, 0x80444444)
	sprite(F, tex0(F, 1, PSMCT32, 6), 40, 0, 48, 8, 32, 0, 40, 8)
	if at(F, 44, 4) != 0x444444 {fail("feedback sample: %x", at(F, 44, 4))}
	// In one context (vertex writes only): the second sprite reads rows the
	// first wrote, inside the tile the first one sampled.
	sprite(F, tex0(F, 1, PSMCT32, 6), 32, 8, 40, 16, 32, 0, 40, 8)
	gs.gs_write(0x03, 32 << 4 | (8 << 4) << 16)
	gs.gs_write(0x05, 40 << 4 | (8 << 4) << 16)
	gs.gs_write(0x03, 40 << 4 | (16 << 4) << 16)
	gs.gs_write(0x05, 48 << 4 | (16 << 4) << 16)
	if at(F, 44, 12) != 0x444444 {fail("feedback sample in one context: %x", at(F, 44, 12))}

	// Snapshot load: local memory changes under the cache.
	gs.gs_snap()
	gs.write_raw(PSMCT32, T * 32, 1, 5, 7, 0x555555)
	for h in core.snap_hooks {h.load(0)}
	sprite(F, tt, 0, 0, 16, 16, 0, 0, 16, 16)
	if at(F, 5, 7) != 0x555555 {fail("sample after a snapshot load: %x", at(F, 5, 7))}

	// PSMT4 64x64 of index idx_a, the CLUT reloaded with new colours.
	t4: [64 * 32]u8
	for &b, i in t4 {
		x, y := u32(i % 32) * 2, u32(i / 32)
		b = u8(idx_a(x, y) | idx_a(x + 1, y) << 4)
	}
	upload(T4, 1, PSMT4, 0, 0, 64, 64, t4[:])
	for base in ([2]u32{0x100000, 0x200000}) {
		set_clut(base)
		sprite(F, tex0(T4, 1, PSMT4, 6), 0, 0, 16, 16, 20, 30, 36, 46)
		want := base + idx_a(23, 31) * 0x010101
		if at(F, 3, 1) != want {fail("CLUT %x: %x, want %x", base, at(F, 3, 1), want)}
	}

	// A and B, every tile sampled once each: 8192 tiles through a 4096-tile
	// pool. Then tiles A decoded first, long reused.
	set_clut(0x300000)
	for x in u32(0) ..< 1024 {
		for y in u32(0) ..< 1024 {
			gs.write_raw(PSMT4, A * 32, 16, x, y, idx_a(x, y))
			gs.write_raw(PSMT4, B * 32, 16, x, y, idx_b(x, y))
		}
	}
	tex := [2]u64{tex0(A, 16, PSMT4, 10), tex0(B, 16, PSMT4, 10)}
	idx := [2]proc(x, y: u32) -> u32{idx_a, idx_b}
	check :: proc(t: u64, f: proc(x, y: u32) -> u32, x, y: u32) {
		sprite(F, t, 0, 0, 1, 1, u64(x), u64(y), u64(x) + 1, u64(y) + 1)
		want := 0x300000 + f(x, y) * 0x010101
		if at(F, 0, 0) != want {fail("tile texel (%d, %d): %x, want %x", x, y, at(F, 0, 0), want)}
	}
	for k in 0 ..< 2 {
		for ty in u32(0) ..< 64 {
			for tx in u32(0) ..< 64 {check(tex[k], idx[k], tx * 16 + (ty & 15), ty * 16 + (tx & 15))}
		}
	}
	for ty in u32(0) ..< 4 {
		for tx in u32(0) ..< 64 {check(tex[0], idx[0], tx * 16 + 15, ty * 16 + 7)}
	}

	if failed > 0 {os.exit(1)}
	fmt.println("ok gs_tex")
}
