// Primitive assembly, rasterisation and the per-pixel pipeline: texture
// mapping, fog, alpha test, destination alpha test, depth test, blending
// and masked frame/depth writes.
//
// write, vertex, decode_ctx, fetch and pixel run without bounds checks.
// Every index there is a constant, masked to its array (context &1, prim
// kind &7, CLUT &511), bounded by a loop over the array, a mip level
// clamped to 6 (mxl), or the vertex queue count, which vertex checks
// itself because snapshots restore it.
package ps2_gs

import "core:math"
import "core:simd"

Vertex :: struct {
	x, y:    f32, // pixels, window-relative
	z:       f64,
	c:       [4]f32, // r, g, b, a
	s, t, q: f32,
	u, v:    f32, // texels (FST = 1)
	fog:     f32,
}

// Frames rerun after a netplay rollback are drawn but not shown.
skip_present: bool

@(private)
cur: Vertex // attributes from RGBAQ/ST/UV/FOG awaiting a vertex kick
@(private)
queue: [3]Vertex
@(private)
nq: int

@(private)
Tex :: struct {
	tbp, tbw, psm:      u32,
	w, h:               u32,
	tcc:                bool,
	tfx:                u32,
	cpsm, csa:          u32,
	bilinear:           bool,
	wms, wmt:           u32,
	minu, maxu:         u32,
	minv, maxv:         u32,
	ta0, ta1:           u32,
	aem:                bool,
	// Mipmapping, from TEX1 and MIPTBP1/2: level n's base and width.
	lcm:                bool, // LOD is K alone
	mxl, mmin, l:       u32,
	k:                  i32, // 1/16ths
	mtbp, mtbw:         [7]u32,
	// Level n's wrap, set for levels 0..mxl (tex_wrap).
	wrap:               [7]Tex_Wrap,
}

// One level's wrap of the bilinear taps' coordinates (x0, x1, y0, y1),
// every mode as (min(max(i, lo), hi) & mask) | fix (wrap_axis).
@(private)
Tex_Wrap :: struct {
	lo, hi, mask, fix: #simd[4]i32,
}

// Drawing state for one primitive, decoded from PRIM and its context.
@(private)
Ctx :: struct {
	iip, tme, fge, abe, fst: bool,
	fbp, fbw, fpsm, fbmsk:   u32,
	zbp, zpsm:               u32,
	zmsk:                    bool,
	sx0, sx1, sy0, sy1:      i32,
	ate:                     bool,
	atst, aref, afail:       u32,
	date, datm:              bool,
	zte:                     bool,
	ztst:                    u32,
	a, b, c, d, fix:         u32,
	pabe, fba, colclamp:     bool,
	on_display:              bool, // FRAME FBP is a shown buffer
	// Whether pixel needs the stored frame pixel (DATE, FBMSK, a blend
	// reading Cd or Ad, or an alpha fail keeping Ad) and the stored Z
	// (GEQUAL or GREATER). Skipped reads are dead.
	dst_read, z_read:        bool,
	frow, zrow:              Row,
	px:                      Pixel_Proc, // pixel or a fast proc (px_pick)
	fogcol:                  [3]i32,
	tex:                     Tex,
}

// Every GS register write lands here after gs_write stores it.
write :: proc(reg: u8, v: u64) #no_bounds_check {
	switch reg {
	case GS_PRIM: nq = 0
	case GS_RGBAQ:
		cur.c = {f32(v & 0xff), f32((v >> 8) & 0xff), f32((v >> 16) & 0xff), f32((v >> 24) & 0xff)}
		cur.q = transmute(f32)u32(v >> 32)
	case GS_ST:
		cur.s = transmute(f32)u32(v)
		cur.t = transmute(f32)u32(v >> 32)
	case GS_UV:
		cur.u = f32(v & 0x3fff) / 16
		cur.v = f32((v >> 16) & 0x3fff) / 16
	case GS_FOG: cur.fog = f32(v >> 56)
	case GS_XYZF2, GS_XYZF3:
		cur.fog = f32(v >> 56)
		vertex(v, f64((v >> 32) & 0xffffff), reg == GS_XYZF2)
	case GS_XYZ2, GS_XYZ3:
		vertex(v, f64(v >> 32), reg == GS_XYZ2)
	case 0x06, 0x07: clut_load(v) // TEX0_1/2
	case 0x16, 0x17: // TEX2_1/2: PSM and CLUT fields of TEX0
		MASK :: u64(0x3f) << 20 | 0xffff_ffe0_0000_0000
		t := &state.regs[reg - 0x10]
		t^ = (t^ &~ MASK) | (v & MASK)
		clut_load(t^)
	case GS_TRXDIR: xfer_start(u32(v))
	}
}

@(private)
prim_attrs :: proc() -> u64 {
	prim := state.regs[GS_PRIM]
	if state.regs[0x1a] & 1 == 0 {prim = (prim & 7) | (state.regs[0x1b] &~ 7)} // PRMODECONT
	return prim
}

@(private)
vertex :: proc(xyz: u64, z: f64, kick: bool) #no_bounds_check {
	prim := prim_attrs()
	ctx := u32(prim >> 9) & 1
	off := state.regs[0x18 + ctx]
	v := cur
	v.x = (f32(xyz & 0xffff) - f32(off & 0xffff)) / 16
	v.y = (f32((xyz >> 16) & 0xffff) - f32((off >> 32) & 0xffff)) / 16
	v.z = z
	if nq >= len(queue) {panic("gs: vertex queue overrun")}
	queue[nq] = v
	nq += 1
	kind := prim & 7
	@(static, rodata) need := [8]int{1, 2, 2, 3, 3, 3, 2, 1}
	if nq < need[kind] {return}
	if kick && kind != 7 {draw(kind, prim)}
	switch kind {
	case 2: // line strip
		queue[0] = queue[1]
		nq = 1
	case 4: // triangle strip
		queue[0], queue[1] = queue[1], queue[2]
		nq = 2
	case 5: // triangle fan
		queue[1] = queue[2]
		nq = 2
	case:
		nq = 0
	}
}

@(private)
decode_ctx :: proc(prim: u64) -> (c: Ctx) #no_bounds_check {
	r := &state.regs
	n := u32(prim >> 9) & 1
	c.iip = prim & (1 << 3) != 0
	c.tme = prim & (1 << 4) != 0
	c.fge = prim & (1 << 5) != 0
	c.abe = prim & (1 << 6) != 0
	c.fst = prim & (1 << 8) != 0

	frame := r[0x4c + n]
	c.fbp = u32(frame & 0x1ff) * 32
	c.fbw = u32(frame >> 16) & 0x3f
	c.fpsm = u32(frame >> 24) & 0x3f
	c.fbmsk = u32(frame >> 32)
	for e in shown[:n_shown] {c.on_display = c.on_display || e.fbp == c.fbp}
	zbuf := r[0x4e + n]
	c.zbp = u32(zbuf & 0x1ff) * 32
	c.zpsm = (u32(zbuf >> 24) & 0xf) | 0x30
	c.zmsk = zbuf & (1 << 32) != 0
	sc := r[0x40 + n]
	c.sx0, c.sx1 = i32(sc & 0x7ff), i32((sc >> 16) & 0x7ff)
	c.sy0, c.sy1 = i32((sc >> 32) & 0x7ff), i32((sc >> 48) & 0x7ff)
	test := r[0x47 + n]
	c.ate = test & 1 != 0
	c.atst = u32(test >> 1) & 7
	c.aref = u32(test >> 4) & 0xff
	c.afail = u32(test >> 12) & 3
	c.date = test & (1 << 14) != 0
	c.datm = test & (1 << 15) != 0
	c.zte = test & (1 << 16) != 0
	c.ztst = u32(test >> 17) & 3
	al := r[0x42 + n]
	c.a, c.b, c.c, c.d = u32(al) & 3, u32(al >> 2) & 3, u32(al >> 4) & 3, u32(al >> 6) & 3
	c.fix = u32(al >> 32) & 0xff
	c.pabe = r[0x49] & 1 != 0
	c.fba = r[0x4a + n] & 1 != 0
	c.colclamp = r[0x46] & 1 != 0
	fc := r[0x3d]
	c.fogcol = {i32(fc & 0xff), i32((fc >> 8) & 0xff), i32((fc >> 16) & 0xff)}
	blend_dst := c.a == 1 || c.b == 1 || c.c == 1 || c.d == 1
	c.dst_read = c.date || c.fbmsk != 0 || (c.abe && blend_dst) || (c.ate && c.afail == 3)
	c.z_read = c.zte && c.ztst >= 2
	c.frow, c.zrow = row_init(c.fpsm), row_init(c.zpsm)

	if c.tme {
		t0 := r[0x06 + n]
		t1 := r[0x14 + n]
		cl := r[0x08 + n]
		ta := r[0x3b]
		mip := [2]u64{r[0x34 + n], r[0x36 + n]}
		c.tex = {
			tbp      = u32(t0) & 0x3fff,
			tbw      = u32(t0 >> 14) & 0x3f,
			psm      = u32(t0 >> 20) & 0x3f,
			w        = 1 << min(u32(t0 >> 26) & 0xf, 10),
			h        = 1 << min(u32(t0 >> 30) & 0xf, 10),
			tcc      = t0 & (1 << 34) != 0,
			tfx      = u32(t0 >> 35) & 3,
			cpsm     = u32(t0 >> 51) & 0xf,
			csa      = u32(t0 >> 56) & 0x1f,
			bilinear = t1 & (1 << 5) != 0,
			wms      = u32(cl) & 3,
			wmt      = u32(cl >> 2) & 3,
			minu     = u32(cl >> 4) & 0x3ff,
			maxu     = u32(cl >> 14) & 0x3ff,
			minv     = u32(cl >> 24) & 0x3ff,
			maxv     = u32(cl >> 34) & 0x3ff,
			ta0      = u32(ta) & 0xff,
			ta1      = u32(ta >> 32) & 0xff,
			aem      = ta & (1 << 15) != 0,
			lcm      = t1 & 1 != 0,
			mxl      = min(u32(t1 >> 2) & 7, 6),
			mmin     = u32(t1 >> 6) & 7,
			l        = u32(t1 >> 19) & 3,
			k        = i32(u32(t1 >> 32) << 20) >> 20,
		}
		c.tex.mtbp[0], c.tex.mtbw[0] = c.tex.tbp, c.tex.tbw
		for i in u32(1) ..= 6 {
			m := mip[(i - 1) / 3] >> (((i - 1) % 3) * 20)
			c.tex.mtbp[i], c.tex.mtbw[i] = u32(m) & 0x3fff, u32(m >> 14) & 0x3f
		}
		for i in u32(0) ..= c.tex.mxl {
			shown_read(c.tex.mtbp[i], c.tex.mtbw[i], c.tex.psm, 0, c.tex.h >> i)
		}
		tex_wrap(&c.tex)
	}
	c.px = px_pick(&c)
	return
}

// PRIM's bits decode_ctx reads: IIP, TME, FGE, ABE, FST, CTXT.
@(private)
CTX_PRIM :: 0x378

// The last context decoded, and the ctx_gen and PRIM bits it was decoded
// at. Primitives only read it.
@(private)
ctx_cur: Ctx
@(private)
ctx_key: [2]u64

@(private)
draw :: proc(kind, prim: u64) {
	key := [2]u64{ctx_gen, prim & CTX_PRIM}
	if key != ctx_key {
		ctx_cur, ctx_key = decode_ctx(prim), key
		tc_ctx()
	}
	c := &ctx_cur
	if skip_on && c.on_display {return} // headless: a shown buffer, redrawn before it is read
	if c.zte && c.ztst == 0 {return} // NEVER
	if hw_on {
		hw_draw(c, kind)
		return
	}
	tc_draw(c, kind)
	switch kind {
	case 0: draw_point(c, &queue[0])
	case 1, 2: draw_line(c, &queue[0], &queue[1])
	case 3, 4, 5: draw_tri(c, &queue[0], &queue[1], &queue[2])
	case 6: draw_sprite(c, &queue[0], &queue[1])
	}
}

// ------------------------------------------------------------ rasteriser

@(private)
draw_point :: proc(c: ^Ctx, v: ^Vertex) {
	x, y := i32(math.floor(v.x)), i32(math.floor(v.y))
	if x < c.sx0 || x > c.sx1 || y < c.sy0 || y > c.sy1 {return}
	u, tv, lod := tex_coord(c, {v.s, v.t, v.u, v.v}, v.q)
	ctx_seek(c, y)
	c.px(c, x, y, v.z, v.c, u, tv, lod, v.fog)
}

@(private)
draw_line :: proc(c: ^Ctx, a, b: ^Vertex) {
	dx, dy := b.x - a.x, b.y - a.y
	n := int(max(abs(dx), abs(dy)))
	for i in 0 ..< n {
		f := f32(i) / f32(n)
		v := lerp_vertex(a, b, f)
		if !c.iip {v.c = b.c}
		x, y := i32(math.floor(v.x)), i32(math.floor(v.y))
		if x < c.sx0 || x > c.sx1 || y < c.sy0 || y > c.sy1 {continue}
		u, tv, lod := tex_coord(c, {v.s, v.t, v.u, v.v}, v.q)
		ctx_seek(c, y)
		c.px(c, x, y, v.z, v.c, u, tv, lod, v.fog)
	}
}

@(private)
lerp_vertex :: proc(a, b: ^Vertex, f: f32) -> (v: Vertex) {
	v.x = a.x + (b.x - a.x) * f
	v.y = a.y + (b.y - a.y) * f
	v.z = a.z + (b.z - a.z) * f64(f)
	v.c = a.c + (b.c - a.c) * f
	v.s = a.s + (b.s - a.s) * f
	v.t = a.t + (b.t - a.t) * f
	v.q = a.q + (b.q - a.q) * f
	v.u = a.u + (b.u - a.u) * f
	v.v = a.v + (b.v - a.v) * f
	v.fog = a.fog + (b.fog - a.fog) * f
	return
}

// Texel-space coordinates from stuv = {S, T, U, V} and Q, and the level of
// detail. All four lanes take part in the divide and the scale (U and V
// as /1*1, exact), so no lane holds leftover data. Do not narrow this to
// two-lane scalar math: LLVM then packs s/q and t/q into a vector divide
// whose undefined upper lanes hold the sampler's leftover integers, which
// read as denormal floats, and the denormal assist on undefined lanes costs
// a microcode assist per pixel (over 20% of the software GS's wall time).
@(private)
tex_coord :: #force_inline proc(c: ^Ctx, stuv: #simd[4]f32, q: f32) -> (f32, f32, i32) {
	if !c.tme {return 0, 0, 0}
	d, sc := f32(1), #simd[4]f32{1, 1, 1, 1}
	lod: i32
	if c.fst {
		lod = tex_lod(&c.tex, 1)
	} else {
		lod = tex_lod(&c.tex, q)
		if q != 0 {d = q}
		sc = {f32(c.tex.w), f32(c.tex.h), 1, 1}
	}
	r := stuv / #simd[4]f32{d, d, 1, 1} * sc
	if c.fst {return simd.extract(r, 2), simd.extract(r, 3), lod}
	return simd.extract(r, 0), simd.extract(r, 1), lod
}

// LOD = log2(1/|Q|) * 2^L + K in 1/2^23ths, the log taken as the float's
// exponent plus its mantissa read linearly: integer arithmetic, so the
// GPU's shaders/prim.frag `tex_lod` gets the same levels. UV primitives
// take Q as 1.
@(private)
tex_lod :: #force_inline proc(t: ^Tex, q: f32) -> i32 {
	x: i32
	if !t.lcm {
		x = clamp(127 << 23 - i32(transmute(u32)abs(q)), -16 << 23, 16 << 23) << t.l
	}
	return x + t.k << 19
}

@(private)
draw_sprite :: proc(c: ^Ctx, a, b: ^Vertex) {
	x0, x1 := min(a.x, b.x), max(a.x, b.x)
	y0, y1 := min(a.y, b.y), max(a.y, b.y)
	if x1 <= x0 || y1 <= y0 {return}
	// Attributes run from a to b; flip if b is the left/top corner.
	ua, ub := a.u, b.u
	va, vb := a.v, b.v
	sa, sb := a.s, b.s
	ta, tb := a.t, b.t
	if a.x > b.x {ua, ub, sa, sb = ub, ua, sb, sa}
	if a.y > b.y {va, vb, ta, tb = vb, va, tb, ta}
	px0 := max(i32(math.ceil(x0)), c.sx0)
	px1 := min(i32(math.ceil(x1)) - 1, c.sx1)
	py0 := max(i32(math.ceil(y0)), c.sy0)
	py1 := min(i32(math.ceil(y1)) - 1, c.sy1)
	for y in py0 ..= py1 {
		fy := (f32(y) - y0) / (y1 - y0)
		vv := va + (vb - va) * fy
		tt := ta + (tb - ta) * fy
		ctx_seek(c, y)
		for x in px0 ..= px1 {
			fx := (f32(x) - x0) / (x1 - x0)
			u, v, lod := tex_coord(c, {sa + (sb - sa) * fx, tt, ua + (ub - ua) * fx, vv}, b.q)
			c.px(c, x, y, b.z, b.c, u, v, lod, b.fog)
		}
	}
}

@(private)
draw_tri :: proc(c: ^Ctx, v0, v1, v2: ^Vertex) {
	a, b, d := v0, v1, v2
	area := f64(b.x - a.x) * f64(d.y - a.y) - f64(b.y - a.y) * f64(d.x - a.x)
	if area == 0 {return}
	if area < 0 {
		b, d = d, b
		area = -area
	}
	minx := max(i32(math.ceil(min(a.x, b.x, d.x))), c.sx0)
	maxx := min(i32(math.floor(max(a.x, b.x, d.x))), c.sx1)
	miny := max(i32(math.ceil(min(a.y, b.y, d.y))), c.sy0)
	maxy := min(i32(math.floor(max(a.y, b.y, d.y))), c.sy1)
	if minx > maxx || miny > maxy {return}

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
	inv := 1 / area
	flat := a.c
	if !c.iip {flat = v2.c}
	sa := #simd[4]f32{a.s, a.t, a.u, a.v}
	sb := #simd[4]f32{b.s, b.t, b.u, b.v}
	sd := #simd[4]f32{d.s, d.t, d.u, d.v}
	for y in miny ..= maxy {
		w0, w1, w2 := e0.w, e1.w, e2.w
		ctx_seek(c, y)
		// Each w steps by one rounded subtraction of the same dy, so it moves
		// one way only, and each edge's test passes on one run of x: the
		// three pass together on one run, which ends at the first pixel
		// that fails after one that passed.
		inside := false
		for x in minx ..= maxx {
			defer {w0 -= e0.dy; w1 -= e1.dy; w2 -= e2.dy}
			if w0 < 0 || w1 < 0 || w2 < 0 || (w0 == 0 && !e0.bias) || (w1 == 0 && !e1.bias) || (w2 == 0 && !e2.bias) {
				if inside {break}
				continue
			}
			inside = true
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
		e0.w += e0.dx
		e1.w += e1.dx
		e2.w += e2.dx
	}
}

// --------------------------------------------------------------- texture

// One axis's wrap at level n as (lo, hi, mask, fix), for a level-0 size
// and CLAMP's MIN and MAX: REPEAT masks with the level's size, CLAMP and
// REGION_CLAMP clamp (the region scaled to the level), and REGION_REPEAT
// masks with MIN and sets MAX unscaled at every level. The clamp is
// max then min, as `clamp`, so a region with MIN > MAX gives MAX.
@(private)
wrap_axis :: proc(mode, size, lo, hi, n: u32) -> [4]i32 {
	switch mode {
	case 0: return {min(i32), max(i32), i32(max(size >> n, 1) - 1), 0}
	case 1: return {0, i32(max(size >> n, 1)) - 1, -1, 0}
	case 2: return {i32(lo >> n), i32(hi >> n), -1, 0}
	}
	return {min(i32), max(i32), i32(lo), i32(hi)}
}

// Fills t.wrap for levels 0..mxl from WMS, WMT, the size and CLAMP.
@(private)
tex_wrap :: proc(t: ^Tex) {
	for n in u32(0) ..= t.mxl {
		a := wrap_axis(t.wms, t.w, t.minu, t.maxu, n)
		b := wrap_axis(t.wmt, t.h, t.minv, t.maxv, n)
		t.wrap[n] = {
			lo   = {a[0], a[0], b[0], b[0]},
			hi   = {a[1], a[1], b[1], b[1]},
			mask = {a[2], a[2], b[2], b[2]},
			fix  = {a[3], a[3], b[3], b[3]},
		}
	}
}

// Texel coordinates (x0, x1, y0, y1) wrapped by one level's Tex_Wrap.
@(private)
wrap :: #force_inline proc "contextless" (i: #simd[4]i32, w: ^Tex_Wrap) -> #simd[4]i32 {
	return (simd.min(simd.max(i, w.lo), w.hi) & w.mask) | w.fix
}

// Texel as RGBA8888 (R in the low byte).
@(private)
fetch :: proc(t: ^Tex, n, x, y: u32) -> u32 #no_bounds_check {
	raw := read_raw(t.psm, t.mtbp[n], t.mtbw[n], x, y)
	switch t.psm {
	case PSMCT32: return raw
	case PSMCT24:
		a := t.aem && raw == 0 ? 0 : t.ta0
		return raw | a << 24
	case PSMCT16, PSMCT16S: return expand16(t, raw)
	}
	e := clut[(t.csa * 16 + raw) & 511]
	if t.cpsm == PSMCT32 {return e}
	return expand16(t, e & 0xffff)
}

// fetch, inlined for the formats a bypassed level samples most (a level
// the context also draws to, as render-to-texture feedback does): CT32 and
// T8. Every other format calls fetch.
@(private)
fetch_direct :: #force_inline proc(t: ^Tex, n, x, y: u32) -> u32 #no_bounds_check {
	switch t.psm {
	case PSMCT32: return vram[addr32(PSMCT32, t.mtbp[n], t.mtbw[n], x, y)]
	case PSMT8:
		e := clut[(t.csa * 16 + u32(vram8()[addr8(t.mtbp[n], t.mtbw[n], x, y)])) & 511]
		if t.cpsm == PSMCT32 {return e}
		return expand16(t, e & 0xffff)
	}
	return fetch(t, n, x, y)
}

@(private)
expand16 :: #force_inline proc(t: ^Tex, c: u32) -> u32 {
	rgb := (c & 0x1f) << 3 | (c & 0x3e0) << 6 | (c & 0x7c00) << 9
	a: u32
	if c & 0x8000 != 0 {
		a = t.ta1
	} else if !t.aem || c & 0x7fff != 0 {
		a = t.ta0
	}
	return rgb | a << 24
}

// The texel colour at level-0 texel coordinates (u, v) and level of
// detail `lod`: LOD <= 0 magnifies level 0 with MMAG, otherwise MMIN picks
// the filter and how levels 0..MXL are used. RGBA in lanes 0..3. Level 0
// is inlined into the pixel loop, which then saves no registers per pixel;
// the mipmap filters stay a call.
@(private)
sample :: #force_inline proc(t: ^Tex, u, v: f32, lod: i32) -> #simd[4]i32 {
	if lod <= 0 {return sample_level(t, 0, u, v, t.bilinear)}
	return sample_min(t, u, v, lod)
}

// `sample` for LOD > 0: MMIN's filter.
@(private)
sample_min :: proc(t: ^Tex, u, v: f32, lod: i32) -> #simd[4]i32 {
	bil := t.mmin == 1 || t.mmin >= 4
	switch t.mmin {
	case 2, 4: // MIPMAP_NEAREST: the nearest level
		n := min(u32((lod + 1 << 22) >> 23), t.mxl)
		return sample_level(t, n, u, v, bil)
	case 3, 5: // MIPMAP_LINEAR: between the two nearest levels
		n := min(u32(lod >> 23), t.mxl)
		c := sample_level(t, n, u, v, bil)
		if n == t.mxl {return c}
		f := (lod >> 15) & 0xff
		return c + div256((sample_level(t, n + 1, u, v, bil) - c) * #simd[4]i32{f, f, f, f})
	}
	return sample_level(t, 0, u, v, bil)
}

// 2^-n for level n: multiplying by it gives the same correctly rounded
// value as dividing by 2^n.
@(private, rodata)
level_scale := [7]f32{1, 0.5, 0.25, 0.125, 0.0625, 0.03125, 0.015625}

// A sample of level n, nearest or bilinear, through the texture cache. The
// two taps of each axis run as one vector (u, u, v, v) from the floor on.
// Inlined into `sample`, so the colour stays in a vector register.
@(private)
sample_level :: #force_inline proc(t: ^Tex, n: u32, tu, tv: f32, bilinear: bool) -> #simd[4]i32 #no_bounds_check {
	u, v := tu * level_scale[n], tv * level_scale[n]
	if !bilinear {
		xy := wrap(cast(#simd[4]i32)simd.floor(#simd[4]f32{u, u, v, v}), &t.wrap[n])
		return expand(texel(t, n, u32(simd.extract(xy, 0)), u32(simd.extract(xy, 2))))
	}
	// Round the 1/256 weights rather than truncate: the GPU's float
	// barycentrics land a hair under exact texel positions, and rounding on
	// both sides keeps the two renderers equal (shaders/prim.frag).
	UV_EPS :: 1.0 / 512
	u, v = u - 0.5 + UV_EPS, v - 0.5 + UV_EPS
	uv := #simd[4]f32{u, u, v, v}
	fl := simd.floor(uv)
	// Weights (au, au, av, av); taps (x0, x1, y0, y1).
	a := cast(#simd[4]i32)((uv - fl) * 256)
	xy := wrap(cast(#simd[4]i32)fl + {0, 1, 0, 1}, &t.wrap[n])
	x0, x1 := u32(simd.extract(xy, 0)), u32(simd.extract(xy, 1))
	y0, y1 := u32(simd.extract(xy, 2)), u32(simd.extract(xy, 3))
	// The four taps in one decoded tile (most of them): one tile lookup.
	// Tested on the wrapped coordinates, as wrap can split or join them.
	c00, c10, c01, c11: u32
	if p := x0 >> 4 == x1 >> 4 && y0 >> 4 == y1 >> 4 ? tile_at(t, n, x0, y0, max(x0, x1), max(y0, y1)) : nil; p != nil {
		r0, r1 := (y0 & 15) << 4, (y1 & 15) << 4
		c00, c10 = p[r0 | (x0 & 15)], p[r0 | (x1 & 15)]
		c01, c11 = p[r1 | (x0 & 15)], p[r1 | (x1 & 15)]
	} else {
		c00, c10 = texel(t, n, x0, y0), texel(t, n, x1, y0)
		c01, c11 = texel(t, n, x0, y1), texel(t, n, x1, y1)
	}
	au, av := simd.swizzle(a, 0, 0, 0, 0), simd.swizzle(a, 2, 2, 2, 2)
	top := expand(c00) + div256((expand(c10) - expand(c00)) * au)
	bot := expand(c01) + div256((expand(c11) - expand(c01)) * au)
	return top + div256((bot - top) * av)
}

// x / 256 lane by lane, rounded toward 0 as i32 division is: a negative x
// adds 255 before the arithmetic shift.
@(private)
div256 :: #force_inline proc "contextless" (x: #simd[4]i32) -> #simd[4]i32 {
	return simd.shr(x + (simd.shr(x, 31) & 255), 8)
}

// An RGBA8888 texel as its four channels, R in lane 0.
@(private)
expand :: #force_inline proc "contextless" (c: u32) -> #simd[4]i32 {
	return cast(#simd[4]i32)transmute(#simd[4]u8)c
}

@(private)
unpack :: #force_inline proc(c: u32) -> [4]i32 {
	return {i32(c & 0xff), i32((c >> 8) & 0xff), i32((c >> 16) & 0xff), i32(c >> 24)}
}

// ---------------------------------------------------------------- pixels

// An interpolated color to integers, all four lanes in one truncation
// (cvttps2dq, wasm's i32x4.trunc_sat_f32x4_s).
// The GS interpolates colors in fixed point, so equal vertex colors stay
// exact. Float barycentrics can land just below (128 -> 127.99999); the
// small bias keeps truncation from dropping a whole step, which breaks
// alpha tests against the vertex value.
@(private)
col_int :: #force_inline proc "contextless" (col: [4]f32) -> [4]i32 {
	COL_EPS :: 1.0 / 256
	v := transmute(#simd[4]f32)col + #simd[4]f32{COL_EPS, COL_EPS, COL_EPS, COL_EPS}
	return transmute([4]i32)cast(#simd[4]i32)v
}

@(private)
pixel :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) #no_bounds_check {
	px, py := u32(x), u32(y)
	src := col_int(col)

	if c.tme {
		t := transmute([4]i32)sample(&c.tex, u, v, lod)
		switch c.tex.tfx {
		case 0: // MODULATE
			for k in 0 ..< 3 {src[k] = min((t[k] * src[k]) >> 7, 255)}
			if c.tex.tcc {src.a = min((t.a * src.a) >> 7, 255)}
		case 1: // DECAL
			src.rgb = t.rgb
			if c.tex.tcc {src.a = t.a}
		case 2, 3: // HIGHLIGHT, HIGHLIGHT2
			for k in 0 ..< 3 {src[k] = min(((t[k] * src[k]) >> 7) + src.a, 255)}
			if c.tex.tcc {src.a = c.tex.tfx == 2 ? min(t.a + src.a, 255) : t.a}
		}
	}
	if c.fge {
		f := i32(fogf)
		for k in 0 ..< 3 {src[k] = (f * src[k] + (255 - f) * c.fogcol[k]) >> 8}
	}

	write_fb, write_z := true, !c.zmsk
	write_alpha := true
	if c.ate {
		a := u32(src.a)
		pass: bool
		switch c.atst {
		case 0: pass = false
		case 1: pass = true
		case 2: pass = a < c.aref
		case 3: pass = a <= c.aref
		case 4: pass = a == c.aref
		case 5: pass = a >= c.aref
		case 6: pass = a > c.aref
		case 7: pass = a != c.aref
		}
		if !pass {
			switch c.afail {
			case 0: return
			case 1: write_z = false
			case 2: write_fb = false
			case 3:
				write_z = false
				write_alpha = false
			}
		}
	}

	fb32 := c.fpsm == PSMCT32 || c.fpsm == PSMCT24 || c.fpsm == PSMZ32 || c.fpsm == PSMZ24
	// The frame pixel's index, taken once for the read and the write.
	fr := &c.frow
	fa: u32
	if fr.ok {
		row_seek(fr, c.fbp, c.fbw, py)
		fa = row_addr(fr, px)
	}
	dst_raw: u32
	if c.dst_read {
		dst_raw = fr.ok ? row_read(fr, fa) : read_raw(c.fpsm, c.fbp, c.fbw, px, py)
	}
	if c.date {
		bit := fb32 ? dst_raw & 0x80000000 != 0 : dst_raw & 0x8000 != 0
		if bit != c.datm {return}
	}

	z := u32(min(zf, 4294967295.0))
	if c.zte {
		zmax: u32 = 0xffffffff
		switch c.zpsm {
		case PSMZ24: zmax = 0xffffff
		case PSMZ16, PSMZ16S: zmax = 0xffff
		}
		z = min(z, zmax)
		zr := &c.zrow
		za: u32
		if zr.ok {
			row_seek(zr, c.zbp, c.fbw, py)
			za = row_addr(zr, px)
		}
		if c.z_read {
			dz := zr.ok ? row_read(zr, za) : read_raw(c.zpsm, c.zbp, c.fbw, px, py)
			switch c.ztst {
			case 2: if z < dz {return}
			case 3: if z <= dz {return}
			}
		}
		if write_z {
			if zr.ok {row_write(zr, za, z)} else {write_raw(c.zpsm, c.zbp, c.fbw, px, py, z)}
		}
	}
	if !write_fb {return}

	dst: [4]i32
	if fb32 {
		dst = unpack(dst_raw)
		if c.fpsm == PSMCT24 || c.fpsm == PSMZ24 {dst.a = 0x80}
	} else {
		dst = {i32(dst_raw & 0x1f) << 3, i32((dst_raw >> 5) & 0x1f) << 3, i32((dst_raw >> 10) & 0x1f) << 3, dst_raw & 0x8000 != 0 ? 0x80 : 0}
	}

	if c.abe && !(c.pabe && src.a < 0x80) {
		sel :: #force_inline proc(n: u32, s, d: [4]i32) -> [3]i32 {
			switch n {
			case 0: return s.rgb
			case 1: return d.rgb
			}
			return {}
		}
		ca := sel(c.a, src, dst)
		cb := sel(c.b, src, dst)
		cd := sel(c.d, src, dst)
		alpha: i32
		switch c.c {
		case 0: alpha = src.a
		case 1: alpha = dst.a
		case: alpha = i32(c.fix)
		}
		#no_bounds_check for k in 0 ..< 3 {src[k] = (((ca[k] - cb[k]) * alpha) >> 7) + cd[k]}
	}
	#no_bounds_check for k in 0 ..< 3 {
		src[k] = c.colclamp ? clamp(src[k], 0, 255) : src[k] & 0xff
	}
	if c.fba {src.a |= 0x80}
	if !write_alpha {src.a = dst.a}

	out: u32
	if fb32 {
		out = u32(src.r) | u32(src.g) << 8 | u32(src.b) << 16 | u32(src.a & 0xff) << 24
	} else {
		out = u32(src.r >> 3) | u32(src.g >> 3) << 5 | u32(src.b >> 3) << 10 | (src.a & 0x80 != 0 ? 0x8000 : 0)
		dst_raw &= 0xffff
	}
	msk := c.fbmsk
	if !fb32 {
		msk = (msk >> 3) & 0x1f | (msk >> 6) & 0x3e0 | (msk >> 9) & 0x7c00 | (msk >> 16) & 0x8000
	}
	v := (out &~ msk) | (dst_raw & msk)
	if fr.ok {row_write(fr, fa, v)} else {write_raw(c.fpsm, c.fbp, c.fbw, px, py, v)}
}
