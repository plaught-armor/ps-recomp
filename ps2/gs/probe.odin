package ps2_gs

import "core:math"

// Test hooks: the texture sampler outside a draw, for tests/gs_tex, the
// pixel proc choice, for tests/gs_pixel, a triangle's pixel calls, for
// tests/gs_span, and the CLUT buffer, for tests/gs_clut and tests/gs_tex.

// Decodes the context PRIM's CTXT selects, texture mapping on, as a draw
// would, and resolves its levels again on their first sample. The next
// draw decodes its own context.
probe_ctx :: proc(prim: u64) {
	ctx_cur = decode_ctx(prim | 1 << 4)
	ctx_key = {~u64(0), ~u64(0)}
	tc_ctx()
}

// sample_level on the probed context's texture.
probe_sample :: proc(n: u32, u, v: f32, bilinear: bool) -> [4]i32 {
	return transmute([4]i32)sample_level(&ctx_cur.tex, n, u, v, bilinear)
}

// sample on the probed context's texture: TEX1's filters and level choice
// with sample_level inlined, the path draws take.
probe_sample_lod :: proc(u, v: f32, lod: i32) -> [4]i32 {
	return transmute([4]i32)sample(&ctx_cur.tex, u, v, lod)
}

// Level n's texel (x, y) of the probed context's texture, through the cache.
probe_texel :: proc(n, x, y: u32) -> u32 {
	return texel(&ctx_cur.tex, n, x, y)
}

// Whether contexts decoded from now on take the generic pixel proc rather
// than a fast one (tests/gs_pixel). The next draw decodes its context again.
probe_generic :: proc(on: bool) {
	px_force = on ? pixel : nil
	ctx_key = {~u64(0), ~u64(0)}
}

// Whether contexts decoded from now on fold a flat texture's LOD to 0, as
// they do unless switched off (tests/gs_pixel). The next draw decodes its
// context again.
probe_fold :: proc(on: bool) {
	tex_fold_off = !on
	ctx_key = {~u64(0), ~u64(0)}
}

// Whether the last context decoded has a flat texture.
probe_flat :: proc() -> bool {
	return ctx_cur.tme && ctx_cur.tex.flat
}

// Whether level n of the current context's texture is read from local
// memory, not the texture cache: the context writes a page of it.
probe_bypass :: proc(n: u32) -> bool {
	return tc_lvl[n] == TC_BYPASS
}

// Pixel calls since probe_tally(true), by their LOD: <= 0, > 0.
probe_lods: [2]int

@(private = "file")
px_tally :: proc(_: ^Ctx, _, _: i32, _: f64, _: [4]f32, _, _: f32, lod: i32, _: f32) {
	probe_lods[int(lod > 0)] += 1
}

// Whether contexts decoded from now on count their pixel calls in
// probe_lods in place of drawing them; on clears the counts. The next draw
// decodes its context again.
probe_tally :: proc(on: bool) {
	px_force = on ? px_tally : nil
	if on {probe_lods = {}}
	ctx_key = {~u64(0), ~u64(0)}
}

// The PX_FAST index of the last context drawn's pixel proc, or -1 for the
// generic one.
probe_fast :: proc() -> int {
	for p, i in px_procs {
		if p == ctx_cur.px {return i}
	}
	return -1
}

// One call of a context's pixel proc: its arguments, floats as bits.
Px_Call :: struct {
	x, y: i32,
	z:    u64,
	col:  [4]u32,
	u, v: u32,
	lod:  i32,
	fog:  u32,
}

// The pixel calls of the last probe_tri, in order.
probe_calls: [dynamic]Px_Call

@(private = "file")
px_record :: proc(_: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {
	append(&probe_calls, Px_Call{x, y, transmute(u64)zf, transmute([4]u32)col, transmute(u32)u, transmute(u32)v, lod, transmute(u32)fogf})
}

// What the reference walk met in one triangle.
Tri_Class :: enum {
	Drawn, // a pixel drawn
	Back, // wound the other way: two vertices swapped
	Tie_Owned, // a pixel on an edge that owns it
	Tie_Left, // a pixel on an edge that does not
	Level, // an edge with dy == 0
	Before, // a row with a pixel failed before its run, or with no run
	After, // a row with a pixel failed after its run
	Empty_Row, // a row of the box with no pixel
	Clipped, // the scissor cut the box
}
Tri_Classes :: bit_set[Tri_Class]

// Rasterises the three vertices queued (sent without a kick, XYZ3 or
// XYZF3) under PRIM's context, recording the pixel calls in probe_calls
// in place of drawing: by draw_tri, or with ref by the walk it replaced.
// The classes are the reference walk's. The next draw decodes its own
// context.
probe_tri :: proc(prim: u64, ref: bool) -> (cls: Tri_Classes) {
	ctx_cur = decode_ctx(prim)
	ctx_key = {~u64(0), ~u64(0)}
	ctx_cur.px = px_record
	clear(&probe_calls)
	if ref {return draw_tri_ref(&ctx_cur, &queue[0], &queue[1], &queue[2])}
	draw_tri(&ctx_cur, &queue[0], &queue[1], &queue[2])
	return
}

// draw_tri as it was before it computed each row's run: every pixel of the
// box tested, from minx. It notes the classes it meets, and asserts what
// draw_tri rests on, that each stepped weight is the edge function itself.
@(private = "file")
draw_tri_ref :: proc(c: ^Ctx, v0, v1, v2: ^Vertex) -> (cls: Tri_Classes) {
	a, b, d := v0, v1, v2
	area := f64(b.x - a.x) * f64(d.y - a.y) - f64(b.y - a.y) * f64(d.x - a.x)
	if area == 0 {return}
	if area < 0 {
		b, d = d, b
		area = -area
		cls += {.Back}
	}
	minx := max(i32(math.ceil(min(a.x, b.x, d.x))), c.sx0)
	maxx := min(i32(math.floor(max(a.x, b.x, d.x))), c.sx1)
	miny := max(i32(math.ceil(min(a.y, b.y, d.y))), c.sy0)
	maxy := min(i32(math.floor(max(a.y, b.y, d.y))), c.sy1)
	if minx > maxx || miny > maxy {return}
	if i32(math.ceil(min(a.x, b.x, d.x))) < c.sx0 || i32(math.floor(max(a.x, b.x, d.x))) > c.sx1 ||
	   i32(math.ceil(min(a.y, b.y, d.y))) < c.sy0 || i32(math.floor(max(a.y, b.y, d.y))) > c.sy1 {
		cls += {.Clipped}
	}

	// Edge e(p) = (q.x - p0.x)(p.y - p0.y) - (q.y - p0.y)(p.x - p0.x), positive
	// inside. Pixels on an edge belong to it only for top or left edges.
	Edge :: struct {dx, dy, w: f64, bias: bool}
	mk :: proc(p, q: ^Vertex, x, y: f64) -> Edge {
		dx, dy := f64(q.x - p.x), f64(q.y - p.y)
		w := dx * (y - f64(p.y)) - dy * (x - f64(p.x))
		top_left := dy < 0 || (dy == 0 && dx > 0)
		return {dx, dy, w, top_left}
	}
	fx, fy := f64(minx), f64(miny)
	e0 := mk(b, d, fx, fy) // weight of a
	e1 := mk(d, a, fx, fy) // weight of b
	e2 := mk(a, b, fx, fy) // weight of d
	if e0.dy == 0 || e1.dy == 0 || e2.dy == 0 {cls += {.Level}}
	inv := 1 / area
	flat := a.c
	if !c.iip {flat = v2.c}
	sa := #simd[4]f32{a.s, a.t, a.u, a.v}
	sb := #simd[4]f32{b.s, b.t, b.u, b.v}
	sd := #simd[4]f32{d.s, d.t, d.u, d.v}
	for y in miny ..= maxy {
		w0, w1, w2 := e0.w, e1.w, e2.w
		ctx_seek(c, y)
		// Each w steps by an exact subtraction of the same dy, so it moves
		// one way only, and each edge's test passes on one run of x: the
		// three pass together on one run, which ends at the first pixel
		// that fails after one that passed.
		inside := false
		for x in minx ..= maxx {
			defer {w0 -= e0.dy; w1 -= e1.dy; w2 -= e2.dy}
			assert(w0 == mk(b, d, f64(x), f64(y)).w && w1 == mk(d, a, f64(x), f64(y)).w && w2 == mk(a, b, f64(x), f64(y)).w, "gs: an edge's step rounded")
			if w0 < 0 || w1 < 0 || w2 < 0 || (w0 == 0 && !e0.bias) || (w1 == 0 && !e1.bias) || (w2 == 0 && !e2.bias) {
				if w0 >= 0 && w1 >= 0 && w2 >= 0 {cls += {.Tie_Left}}
				if inside {
					cls += {.After}
					break
				}
				cls += {.Before}
				continue
			}
			inside = true
			if w0 == 0 || w1 == 0 || w2 == 0 {cls += {.Tie_Owned}}
			l0, l1, l2 := w0 * inv, w1 * inv, w2 * inv
			f0, f1, f2 := f32(l0), f32(l1), f32(l2)
			z := a.z * l0 + b.z * l1 + d.z * l2
			col := flat
			if c.iip {col = a.c * f0 + b.c * f1 + d.c * f2}
			u, v: f32
			lod: i32
			if c.tme {
				u, v, lod = tex_coord(c,
					sa * f0 + sb * f1 + sd * f2,
					a.q * f0 + b.q * f1 + d.q * f2)
			}
			fog := a.fog * f0 + b.fog * f1 + d.fog * f2
			c.px(c, x, y, z, col, u, v, lod, fog)
		}
		if inside {cls += {.Drawn}} else {cls += {.Empty_Row}}
		e0.w += e0.dx
		e1.w += e1.dx
		e2.w += e2.dx
	}
	return
}

// The CLUT buffer and the block pointers CLD 4 and 5 compare with.
probe_clut :: proc() -> (buf: ^[512]u32, c0, c1: ^u32) {
	return &clut, &cbp0, &cbp1
}

// The CLUT generation: it moves when a load changes the buffer.
probe_clut_gen :: proc() -> u64 {
	return clut_gen
}

// The cache entry of level n of the probed context's texture, once a
// sample has resolved it.
probe_entry :: proc(n: u32) -> i32 {
	return tc_lvl[n]
}

// Whether cache entry e's CLUT entries are known to be the buffer's, so
// that validating it compares none.
probe_clut_known :: proc(e: i32) -> bool {
	return tc_e[e].clut_gen == clut_gen
}

// Level n's texel (x, y) of the probed context's texture, from local memory
// and the CLUT buffer.
probe_fetch :: proc(n, x, y: u32) -> u32 {
	return fetch(&ctx_cur.tex, n, x, y)
}

// clut_load as it was before CSM1 read through clut_off32 and clut_off16:
// each entry's pixel through read_raw. The software path only.
clut_load_ref :: proc(tex0: u64) {
	cbp := u32(tex0 >> 37) & 0x3fff
	switch (tex0 >> 61) & 7 {
	case 0: return
	case 2: cbp0 = cbp
	case 3: cbp1 = cbp
	case 4:
		if cbp == cbp0 {return}
		cbp0 = cbp
	case 5:
		if cbp == cbp1 {return}
		cbp1 = cbp
	case 6, 7: return
	}
	psm := u32(tex0 >> 20) & 0x3f
	cpsm := u32(tex0 >> 51) & 0xf
	csm2 := tex0 & (1 << 55) != 0
	csa := u32(tex0 >> 56) & 0x1f
	n: u32 = (psm == PSMT8 || psm == PSMT8H) ? 256 : 16
	base := csa * 16
	tc := state.regs[0x1c] // TEXCLUT: CBW, COU, COV
	cbw, cou, cov := u32(tc) & 0x3f, u32(tc >> 6) & 0x3f, u32(tc >> 12) & 0x3ff
	if csm2 {
		for i in 0 ..< n {
			clut[(base + i) & 511] = read_raw(cpsm, cbp, cbw, cou * 16 + i, cov)
		}
		return
	}
	for i in 0 ..< n {
		x, y: u32
		if n == 256 {
			p := (i & 0xe7) | ((i & 0x08) << 1) | ((i & 0x10) >> 1)
			x, y = p & 15, p >> 4
		} else {
			x, y = i & 7, i >> 3
		}
		clut[(base + i) & 511] = read_raw(cpsm, cbp, 1, x, y)
	}
}

// Drops every cache entry and fills every tile of the pool with v, so that
// a tile decoded from now on holds v wherever its decode did not write
// (tests/gs_decode).
probe_tiles_fill :: proc(v: u32) {
	tc_flush()
	for &tile in tc_pool {tile = v}
}

// The cached tile holding level n's texel (x, y) of the probed context's
// texture, decoded if it was not, or nil where the level is not cached.
probe_tile :: proc(n, x, y: u32) -> ^[256]u32 {
	return tile_at(&ctx_cur.tex, n, x, y, x, y)
}
