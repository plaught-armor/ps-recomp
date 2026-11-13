// The software GS's decoded texture cache: a texture sampled again after
// each kind of write to it reads the new texels. Host-to-local uploads,
// draws into the texture's pages, local copies, CLUT loads and snapshot
// loads each change what a draw samples; a draw sampling the buffer it
// writes sees its own earlier primitives, in the same context too; and two textures of 4096 tiles
// each, sampled tile by tile past the pool's size, read right on every
// sample and again after their tiles are reused. The sampler, by level
// (sample_level) and through TEX1's filters and level choice (sample, with
// sample_level inlined), matches its pre-SHOT-PERF-E copy below on random
// textures, coordinates and LODs, every wrap mode at levels 1 and up too. A
// sprite with STQ coordinates samples the texels of its UV twin.
package main

import "core:fmt"
import "core:math"
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

// Context and PRIM for a sprite into the 64-wide PSMCT32 buffer at page
// fbp, from TEX0 tex0 when it is not 0 (DECAL); UV coordinates when fst.
@(private = "file")
sprite_prim :: proc(fbp, tex0: u64, fst: bool) {
	gs.gs_write(0x4c, fbp | 1 << 16) // FRAME_1: FBW 1, PSMCT32
	gs.gs_write(0x4e, 0x100 | 1 << 32) // ZBUF_1: ZMSK
	gs.gs_write(0x40, 63 << 16 | 63 << 48) // SCISSOR_1: 0..63
	gs.gs_write(0x18, 0) // XYZOFFSET_1
	gs.gs_write(0x1a, 1) // PRMODECONT
	prim: u64 = 6 // SPRITE
	if fst {prim |= 1 << 8}
	if tex0 != 0 {
		gs.gs_write(0x06, tex0)
		prim |= 1 << 4
	}
	gs.gs_write(0x00, prim)
}

// A sprite (x0, y0)..(x1, y1) into the 64-wide PSMCT32 buffer at page fbp,
// UV (u0, v0)..(u1, v1) in texels, from TEX0 tex0 when it is not 0 (DECAL).
@(private = "file")
sprite :: proc(fbp, tex0: u64, x0, y0, x1, y1: u64, u0, v0, u1, v1: u64, col: u64 = 0x80000000) {
	sprite_prim(fbp, tex0, true)
	gs.gs_write(0x01, col)
	gs.gs_write(0x03, u0 << 4 | (v0 << 4) << 16)
	gs.gs_write(0x05, x0 << 4 | (y0 << 4) << 16)
	gs.gs_write(0x03, u1 << 4 | (v1 << 4) << 16)
	gs.gs_write(0x05, x1 << 4 | (y1 << 4) << 16)
}

// The same sprite with STQ coordinates: (s0, t0)..(s1, t1), and Q q at both
// vertices.
@(private = "file")
sprite_stq :: proc(fbp, tex0: u64, x0, y0, x1, y1: u64, s0, t0, s1, t1, q: f32) {
	sprite_prim(fbp, tex0, false)
	gs.gs_write(0x01, 0x80000000 | u64(transmute(u32)q) << 32) // RGBAQ
	gs.gs_write(0x02, u64(transmute(u32)s0) | u64(transmute(u32)t0) << 32) // ST
	gs.gs_write(0x05, x0 << 4 | (y0 << 4) << 16)
	gs.gs_write(0x02, u64(transmute(u32)s1) | u64(transmute(u32)t1) << 32)
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
	// STQ: S/Q and T/Q scaled by the 64-texel size give the same texels as
	// UV 0..16 (Q 2, all powers of two, so exact); every pixel checked.
	sprite_stq(F, tt, 0, 0, 16, 16, 0, 0, 0.5, 0.5, 2)
	stq: for y in u32(0) ..< 16 {
		for x in u32(0) ..< 16 {
			if at(F, x, y) != x | y << 8 | 0x40 << 16 {
				fail("STQ sample (%d, %d): %x", x, y, at(F, x, y))
				break stq
			}
		}
	}

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

	check_sampler()

	if failed > 0 {os.exit(1)}
	fmt.println("ok gs_tex")
}

// xorshift64*, fixed seed: the same samples every run.
@(private = "file")
rng: u64 = 0x9e3779b97f4a7c15

@(private = "file")
rnd :: proc() -> u64 {
	rng ~= rng >> 12
	rng ~= rng << 25
	rng ~= rng >> 27
	return rng * 0x2545f4914f6cdd1d
}

@(private = "file")
rndn :: proc(n: u64) -> u64 {return rnd() % n}

// One random texture: what the sampler reads from TEX0, TEX1 and CLAMP.
@(private = "file")
Cfg :: struct {
	w, h:                   u32,
	wms, wmt:               u32,
	minu, maxu, minv, maxv: u32,
	mxl, mmin:              u32,
	mmag:                   bool, // bilinear
}

@(private = "file")
ref_wrap :: proc(i: i32, mode, size, lo, hi: u32) -> u32 {
	switch mode {
	case 0: return u32(i) & (size - 1)
	case 1: return u32(clamp(i, 0, i32(size) - 1))
	case 2: return u32(clamp(i, i32(lo), i32(hi)))
	}
	return (u32(i) & lo) | hi
}

@(private = "file")
ref_unpack :: proc(c: u32) -> [4]i32 {
	return {i32(c & 0xff), i32((c >> 8) & 0xff), i32((c >> 16) & 0xff), i32(c >> 24)}
}

// The sampler before SHOT-PERF E: per-tap texel, math.floor, divide by 2^n.
@(private = "file")
ref_sample_level :: proc(t: ^Cfg, n: u32, tu, tv: f32, bilinear: bool) -> [4]i32 {
	u, v := tu / f32(u32(1) << n), tv / f32(u32(1) << n)
	w, h := max(t.w >> n, 1), max(t.h >> n, 1)
	minu, maxu, minv, maxv := t.minu, t.maxu, t.minv, t.maxv
	if t.wms == 2 {minu, maxu = minu >> n, maxu >> n}
	if t.wmt == 2 {minv, maxv = minv >> n, maxv >> n}
	if !bilinear {
		x := ref_wrap(i32(math.floor(u)), t.wms, w, minu, maxu)
		y := ref_wrap(i32(math.floor(v)), t.wmt, h, minv, maxv)
		return ref_unpack(gs.probe_texel(n, x, y))
	}
	UV_EPS :: 1.0 / 512
	u, v = u - 0.5 + UV_EPS, v - 0.5 + UV_EPS
	fu, fv := math.floor(u), math.floor(v)
	iu, iv := i32(fu), i32(fv)
	au, av := i32((u - fu) * 256), i32((v - fv) * 256)
	x0 := ref_wrap(iu, t.wms, w, minu, maxu)
	x1 := ref_wrap(iu + 1, t.wms, w, minu, maxu)
	y0 := ref_wrap(iv, t.wmt, h, minv, maxv)
	y1 := ref_wrap(iv + 1, t.wmt, h, minv, maxv)
	c00, c10 := ref_unpack(gs.probe_texel(n, x0, y0)), ref_unpack(gs.probe_texel(n, x1, y0))
	c01, c11 := ref_unpack(gs.probe_texel(n, x0, y1)), ref_unpack(gs.probe_texel(n, x1, y1))
	top := c00 + ((c10 - c00) * au) / 256
	bot := c01 + ((c11 - c01) * au) / 256
	return top + ((bot - top) * av) / 256
}

// Whether a bilinear sample's four taps, wrapped, lie in one 16 x 16 tile
// of level n.
@(private = "file")
ref_one_tile :: proc(t: ^Cfg, n: u32, tu, tv: f32) -> bool {
	UV_EPS :: 1.0 / 512
	u, v := tu / f32(u32(1) << n) - 0.5 + UV_EPS, tv / f32(u32(1) << n) - 0.5 + UV_EPS
	w, h := max(t.w >> n, 1), max(t.h >> n, 1)
	minu, maxu, minv, maxv := t.minu, t.maxu, t.minv, t.maxv
	if t.wms == 2 {minu, maxu = minu >> n, maxu >> n}
	if t.wmt == 2 {minv, maxv = minv >> n, maxv >> n}
	iu, iv := i32(math.floor(u)), i32(math.floor(v))
	x0, x1 := ref_wrap(iu, t.wms, w, minu, maxu), ref_wrap(iu + 1, t.wms, w, minu, maxu)
	y0, y1 := ref_wrap(iv, t.wmt, h, minv, maxv), ref_wrap(iv + 1, t.wmt, h, minv, maxv)
	return x0 >> 4 == x1 >> 4 && y0 >> 4 == y1 >> 4
}

// The sampler's TEX1 filters and level choice over ref_sample_level, and
// the highest level it read.
@(private = "file")
ref_sample :: proc(t: ^Cfg, u, v: f32, lod: i32) -> ([4]i32, u32) {
	if lod <= 0 {return ref_sample_level(t, 0, u, v, t.mmag), 0}
	bil := t.mmin == 1 || t.mmin >= 4
	switch t.mmin {
	case 2, 4:
		n := min(u32((lod + 1 << 22) >> 23), t.mxl)
		return ref_sample_level(t, n, u, v, bil), n
	case 3, 5:
		n := min(u32(lod >> 23), t.mxl)
		c := ref_sample_level(t, n, u, v, bil)
		if n == t.mxl {return c, n}
		f := (lod >> 15) & 0xff
		return c + ((ref_sample_level(t, n + 1, u, v, bil) - c) * f) / 256, n + 1
	}
	return ref_sample_level(t, 0, u, v, bil), 0
}

// A coordinate for a level-0 extent of size texels: mostly inside or
// near it, with texel centres, exact integers, values a hair off either,
// large magnitudes, NaN and inf.
@(private = "file")
rnd_coord :: proc(size: u32) -> f32 {
	s := f32(size)
	switch rndn(16) {
	case 0: return f32(i64(rndn(u64(size) * 4)) - i64(size)) // integer
	case 1: return f32(i64(rndn(u64(size) * 4)) - i64(size)) + 0.5
	case 2: // an integer or centre, the next float either way
		x := f32(i64(rndn(u64(size) * 4)) - i64(size)) + (rndn(2) == 0 ? 0 : 0.5)
		return rndn(2) == 0 ? math.nextafter(x, math.inf_f32(1)) : math.nextafter(x, math.inf_f32(-1))
	case 3: return f32(i64(rndn(u64(size) * 4)) - i64(size)) + f32(rndn(256)) / 256 // 1/256 steps
	case 4: return (f32(rndn(1 << 24)) / (1 << 24) - 0.5) * 2e10
	case 5:
		switch rndn(4) {
		case 0: return math.nan_f32()
		case 1: return math.inf_f32(1)
		case 2: return math.inf_f32(-1)
		}
		return transmute(f32)u32(0x80000000) // -0
	}
	return (f32(rndn(1 << 24)) / (1 << 24)) * s * 3 - s
}

// Random textures in random local memory at pages 0x100.. (every format,
// CLUTs from it too), each sampled at random levels, coordinates, wrap
// modes and filters against ref_sample_level, and at random LODs and TEX1
// filters against ref_sample. Each wrap mode must be sampled at a level
// above 0 on both paths. One texture in four is sampled by a context whose
// frame lies on level 0's first pages, so that level is read from local
// memory, not the cache (gs.probe_bypass); its samples must equal those
// taken through the cache. Floors: LODs above 0 under each MMIN, and
// bilinear samples with their four taps in one decoded tile, across tiles,
// and in a bypassed level.
@(private = "file")
check_sampler :: proc() {
	R :: 0x100 // first random page; 256 pages, 1024 x 512 PSMCT32 at width 16
	for y in u32(0) ..< 512 {
		for x in u32(0) ..< 1024 {gs.write_raw(PSMCT32, R * 32, 16, x, y, u32(rnd()))}
	}
	psms := [?]u64{0x00, 0x01, 0x02, 0x0a, 0x13, 0x14, 0x1b, 0x24, 0x2c}
	CONFIGS :: 2048
	SAMPLES :: 512 // 1M in all
	bad := 0
	// Samples per path (level, LOD) and wrap mode reading a level above 0.
	up: [2][4]int
	Tap :: enum {Nearest, One_Tile, Straddle, Bypass}
	taps: [Tap]int
	minified: [8]int // LOD > 0, by MMIN
	want_level, want_lod: [SAMPLES][4]i32
	tops: [SAMPLES]u32
	for _ in 0 ..< CONFIGS {
		psm := psms[rndn(len(psms))]
		tw, th := rndn(11), rndn(11)
		bw := 1 + rndn(16)
		tbp := R * 32 + rndn(255 * 32)
		mip := [2]u64{rnd(), rnd()}
		for &m in mip {
			// Each base inside the random pages: TBPn 14 bits, TBWn 6.
			for i in u64(0) ..< 3 {
				m &~= 0x3fff << (i * 20)
				m |= (R * 32 + rndn(255 * 32)) << (i * 20)
				m |= (1 + rndn(16)) << (i * 20 + 14)
			}
		}
		cbp := R * 32 + rndn(255 * 32)
		cpsm := rndn(2) == 0 ? u64(0) : 2
		csa := rndn(32)
		t0 := tbp | bw << 14 | psm << 20 | tw << 26 | th << 30 | rndn(2) << 34 | cbp << 37 | cpsm << 51 | csa << 56 | 1 << 61
		mxl := rndn(7)
		mmag, mmin := rndn(2), rndn(8)
		t1 := mxl << 2 | mmag << 5 | mmin << 6
		cl := rnd() & 0xfffffffffff // WMS, WMT 2 bits each; MINU..MAXV 10 each
		ta := rndn(256) | rndn(2) << 15 | rndn(256) << 32
		gs.gs_write(0x3b, ta) // TEXA
		gs.gs_write(0x14, t1) // TEX1_1
		gs.gs_write(0x08, cl) // CLAMP_1
		gs.gs_write(0x34, mip[0]) // MIPTBP1_1
		gs.gs_write(0x36, mip[1]) // MIPTBP2_1
		gs.gs_write(0x06, t0) // TEX0_1, loading its CLUT
		gs.probe_ctx(6)
		c := Cfg {
			w    = 1 << min(u32(tw), 10),
			h    = 1 << min(u32(th), 10),
			wms  = u32(cl) & 3,
			wmt  = u32(cl >> 2) & 3,
			minu = u32(cl >> 4) & 0x3ff,
			maxu = u32(cl >> 14) & 0x3ff,
			minv = u32(cl >> 24) & 0x3ff,
			maxv = u32(cl >> 34) & 0x3ff,
			mxl  = min(u32(mxl), 6),
			mmin = u32(mmin),
			mmag = mmag != 0,
		}
		// The reference's samples first, through the cache; then the
		// sampler's, of the same random stream, after the frame moves onto
		// the texture when the context is to bypass it.
		stream := rng
		for i in 0 ..< SAMPLES {
			n := u32(rndn(u64(c.mxl) + 1))
			u, v := rnd_coord(c.w), rnd_coord(c.h)
			bil := rndn(4) != 0
			want_level[i] = ref_sample_level(&c, n, u, v, bil)
			lod := i32(rndn(9 << 23)) - (1 << 23)
			want_lod[i], tops[i] = ref_sample(&c, u, v, lod)
		}
		feedback := rndn(4) == 0
		if feedback {
			gs.gs_write(0x4c, tbp / 32 | 1 << 16) // FRAME_1 on level 0
			gs.probe_ctx(6)
		}
		after := rng
		rng = stream
		for i in 0 ..< SAMPLES {
			n := u32(rndn(u64(c.mxl) + 1))
			u, v := rnd_coord(c.w), rnd_coord(c.h)
			bil := rndn(4) != 0
			got := gs.probe_sample(n, u, v, bil)
			want := want_level[i]
			switch {
			case !bil: taps[.Nearest] += 1
			case gs.probe_bypass(n): taps[.Bypass] += 1
			case ref_one_tile(&c, n, u, v): taps[.One_Tile] += 1
			case: taps[.Straddle] += 1
			}
			if got != want {
				if bad < 8 {
					fail("sampler psm %x %dx%d wrap %d/%d level %d (%v, %v) bilinear %v: %v, want %v",
						psm, c.w, c.h, c.wms, c.wmt, n, u, v, bil, got, want)
				}
				bad += 1
			}
			if n > 0 {up[0][c.wms] += 1; up[0][c.wmt] += 1}
			// LODs from below 0 to past level 6, fraction bits and all.
			lod := i32(rndn(9 << 23)) - (1 << 23)
			got = gs.probe_sample_lod(u, v, lod)
			want = want_lod[i]
			top := tops[i]
			if lod > 0 {minified[c.mmin] += 1}
			if got != want {
				if bad < 8 {
					fail("sample psm %x %dx%d wrap %d/%d mmag %v mmin %d mxl %d lod %x (%v, %v): %v, want %v",
						psm, c.w, c.h, c.wms, c.wmt, c.mmag, c.mmin, c.mxl, lod, u, v, got, want)
				}
				bad += 1
			}
			if top > 0 {up[1][c.wms] += 1; up[1][c.wmt] += 1}
		}
		rng = after
		if feedback {gs.gs_write(0x4c, F | 1 << 16)}
	}
	fmt.printfln("sampler taps %v, LOD > 0 by MMIN %v", taps, minified)
	for k, t in taps {
		if k < 20000 {fail("sampler: %v taps %d times", t, k)}
	}
	for k, m in minified {
		if k < 50000 {fail("sampler: MMIN %d with LOD > 0 %d times", m, k)}
	}
	if bad > 0 {fail("sampler: %d of %d samples differ", bad, 2 * CONFIGS * SAMPLES)}
	for p, i in up {
		for k, m in p {
			if k < 10000 {fail("sampler path %d: wrap mode %d at levels 1 and up %d times", i, m, k)}
		}
	}
}
