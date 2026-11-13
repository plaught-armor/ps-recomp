// Specialised pixel procs: `pixel` with the context's texture function,
// depth test, blend and formats fixed at compile time, for the contexts
// that draw most pixels. decode_ctx picks one per Ctx (px_pick); every
// other context takes the generic `pixel`.
//
// A fast proc covers a context with the depth test on, no PABE, no FBA,
// COLCLAMP on, an alpha test that does not fail to AFAIL ZB_ONLY, and frame
// and Z formats with rows (row_init). It takes the rows already at y: the
// rasteriser seeks them once per row (ctx_seek), where `pixel` seeks them
// itself.
package ps2_gs

@(private)
Pixel_Proc :: #type proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32)

// One fast context. tfx is -1 for no texture mapping; bl is ALPHA's
// A, B, C and D (its low byte), 0xff for no blending; fbmsk is FBMSK != 0;
// atst is TEST's ATST, tested against the context's AREF, and afail its
// AFAIL (0 KEEP, 1 FB_ONLY, 3 RGB_ONLY); no alpha test, or ATST ALWAYS, is
// atst 1 with afail 0. fge is PRIM's FGE; date is 0 for no destination
// alpha test, 1 for DATM 0, 2 for DATM 1.
Px_Fast :: struct {
	tfx:   i32,
	tcc:   bool,
	ztst:  u32,
	zmsk:  bool,
	zpsm:  u32,
	bl:    u32,
	fpsm:  u32,
	fbmsk: bool,
	atst:  u32,
	afail: u32,
	fge:   bool,
	date:  u32,
}

// The contexts, by the pixels each drew in a profiled title (SHOT-PERF F):
// 99.5% of its pixels between them. Then the generic contexts drawing
// most pixels in three more titles (gh, sp, then bk), by a pixel tally.
// Then the generic contexts drawing most pixels of two more titles' scenes
// (SWGS-PX-1): seven of one, eight of the other, and the first's
// destination alpha test.
PX_FAST :: [?]Px_Fast {
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x68, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 1, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ32, bl = 0x44, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ16S, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0x29, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 6, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ16S, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 6, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ16S, bl = 0x48, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 6, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 5, afail = 3, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 5, afail = 1, fge = false, date = 0},
	{tfx = 1, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ32, bl = 0xff, fpsm = PSMCT24, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x64, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 1, fge = false, date = 2},
	{tfx = 1, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 1, fge = false, date = 0},
	{tfx = -1, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x64, fpsm = PSMCT32, fbmsk = false, atst = 0, afail = 1, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 5, afail = 0, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 2, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x48, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = true, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = true, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = false, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x44, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0xff, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = true, date = 0},
	{tfx = 0, tcc = true, ztst = 1, zmsk = false, zpsm = PSMZ24, bl = 0x58, fpsm = PSMCT32, fbmsk = false, atst = 1, afail = 0, fge = false, date = 0},
}

// PX_FAST's procs, in its order.
@(private, rodata)
px_procs := [len(PX_FAST)]Pixel_Proc {
	px_0, px_1, px_2, px_3, px_4, px_5, px_6, px_7, px_8, px_9, px_10, px_11, px_12, px_13, px_14, px_15, px_16,
	px_17, px_18, px_19, px_20, px_21, px_22, px_23, px_24, px_25, px_26, px_27, px_28, px_29, px_30, px_31,
}

@(private)
px_0 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 0)}
@(private)
px_1 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 1)}
@(private)
px_2 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 2)}
@(private)
px_3 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 3)}
@(private)
px_4 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 4)}
@(private)
px_5 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 5)}
@(private)
px_6 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 6)}
@(private)
px_7 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 7)}

@(private)
px_8 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 8)}
@(private)
px_9 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 9)}
@(private)
px_10 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 10)}
@(private)
px_11 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 11)}
@(private)
px_12 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 12)}
@(private)
px_13 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 13)}
@(private)
px_14 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 14)}
@(private)
px_15 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 15)}
@(private)
px_16 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 16)}
@(private)
px_17 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 17)}
@(private)
px_18 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 18)}
@(private)
px_19 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 19)}
@(private)
px_20 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 20)}
@(private)
px_21 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 21)}
@(private)
px_22 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 22)}
@(private)
px_23 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 23)}
@(private)
px_24 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 24)}
@(private)
px_25 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 25)}
@(private)
px_26 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 26)}
@(private)
px_27 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 27)}
@(private)
px_28 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 28)}
@(private)
px_29 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 29)}
@(private)
px_30 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 30)}
@(private)
px_31 :: proc(c: ^Ctx, x, y: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32) {px_inst(c, x, zf, col, u, v, lod, fogf, 31)}

@(private)
px_inst :: #force_inline proc(c: ^Ctx, x: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32, $N: int) {
	F :: PX_FAST
	pixel_fast(c, x, zf, col, u, v, lod, fogf,
		F[N].tfx, F[N].tcc, F[N].ztst, F[N].zmsk, F[N].zpsm, F[N].bl, F[N].fpsm, F[N].fbmsk, F[N].atst, F[N].afail, F[N].fge, F[N].date)
}

// The pixel proc of every context decoded from now on, when not nil: the
// generic `pixel`, or one that tallies (probe_generic, probe_tally).
@(private)
px_force: Pixel_Proc

// The pixel proc for a decoded context: a fast one when the context is one
// of PX_FAST's, else `pixel`.
@(private)
px_pick :: proc(c: ^Ctx) -> Pixel_Proc {
	if px_force != nil {return px_force}
	if !c.zte || c.pabe || c.fba || !c.colclamp {return pixel}
	if !c.frow.ok || !c.zrow.ok {return pixel}
	atst, afail: u32 = 1, 0
	if c.ate && c.atst != 1 {
		if c.afail == 2 {return pixel} // ZB_ONLY
		atst, afail = c.atst, c.afail
	}
	k := Px_Fast {
		tfx   = c.tme ? i32(c.tex.tfx) : -1,
		tcc   = c.tme && c.tex.tcc,
		ztst  = c.ztst,
		zmsk  = c.zmsk,
		zpsm  = c.zpsm,
		bl    = c.abe ? c.a | c.b << 2 | c.c << 4 | c.d << 6 : 0xff,
		fpsm  = c.fpsm,
		fbmsk = c.fbmsk != 0,
		atst  = atst,
		afail = afail,
		fge   = c.fge,
		date  = c.date ? (c.datm ? 2 : 1) : 0,
	}
	for f, i in PX_FAST {
		if f == k {return px_procs[i]}
	}
	return pixel
}

// Seeks the context's frame and Z rows to y, for the pixels of one row.
@(private)
ctx_seek :: #force_inline proc(c: ^Ctx, y: i32) {
	if c.frow.ok {row_seek(&c.frow, c.fbp, c.fbw, u32(y))}
	if c.zrow.ok {row_seek(&c.zrow, c.zbp, c.fbw, u32(y))}
}

// TEST's alpha test ATST of alpha a against AREF.
@(private)
px_atst :: #force_inline proc "contextless" ($ATST: u32, a, aref: u32) -> bool {
	when ATST == 0 {
		return false
	} else when ATST == 1 {
		return true
	} else when ATST == 2 {
		return a < aref
	} else when ATST == 3 {
		return a <= aref
	} else when ATST == 4 {
		return a == aref
	} else when ATST == 5 {
		return a >= aref
	} else when ATST == 6 {
		return a > aref
	} else {
		return a != aref
	}
}

// `pixel` for one PX_FAST context, its steps in the same order: the frame
// pixel is read before the Z buffer is written, as the two can overlap.
@(private)
pixel_fast :: #force_inline proc(c: ^Ctx, x: i32, zf: f64, col: [4]f32, u, v: f32, lod: i32, fogf: f32,
	$TFX: i32, $TCC: bool, $ZTST: u32, $ZMSK: bool, $ZPSM: u32, $BL: u32, $FPSM: u32, $FBMSK: bool,
	$ATST: u32, $AFAIL: u32, $FGE: bool, $DATE: u32) #no_bounds_check {
	#assert(FPSM == PSMCT32 || FPSM == PSMCT24)
	#assert(ZTST >= 1)
	#assert(ATST <= 7 && (AFAIL == 0 || AFAIL == 1 || AFAIL == 3))
	#assert(ATST != 1 || AFAIL == 0)
	#assert(DATE <= 2)
	px := u32(x)
	src := col_int(col)
	when TFX == 0 { // MODULATE
		t := transmute([4]i32)sample(&c.tex, u, v, lod)
		for k in 0 ..< 3 {src[k] = min((t[k] * src[k]) >> 7, 255)}
		when TCC {src.a = min((t.a * src.a) >> 7, 255)}
	} else when TFX == 1 { // DECAL
		t := transmute([4]i32)sample(&c.tex, u, v, lod)
		src.rgb = t.rgb
		when TCC {src.a = t.a}
	} else {
		#assert(TFX == -1)
	}
	when FGE {
		f := i32(fogf)
		for k in 0 ..< 3 {src[k] = (f * src[k] + (255 - f) * c.fogcol[k]) >> 8}
	}

	A :: BL & 3
	B :: (BL >> 2) & 3
	C :: (BL >> 4) & 3
	D :: (BL >> 6) & 3
	BLEND :: BL != 0xff
	// A pixel failing the alpha test: KEEP writes neither frame nor Z,
	// FB_ONLY and RGB_ONLY no Z, and RGB_ONLY keeps the frame's alpha.
	// `pass` exists only where one of these reads it.
	ZWRITE :: !ZMSK && !(ATST == 0 && AFAIL != 0) // ATST NEVER always fails
	FAIL_Z :: ATST != 1 && AFAIL != 0 && ZWRITE
	FAIL_A :: ATST != 1 && AFAIL == 3
	when ATST != 1 && (AFAIL == 0 || FAIL_Z || FAIL_A) {
		pass := px_atst(ATST, u32(src.a), c.aref)
		when AFAIL == 0 {if !pass {return}}
	}

	UNPACK :: FAIL_A || (BLEND && (A == 1 || B == 1 || C == 1 || D == 1))
	DST :: FBMSK || DATE != 0 || UNPACK
	fa := row_addr_w(&c.frow, px, true)
	when DST {dst_raw := row_read_w(&c.frow, fa, true)} // `when` opens no scope
	when DATE != 0 {if (dst_raw & 0x80000000 != 0) != (DATE == 2) {return}}

	when ZTST >= 2 || ZWRITE {
		ZWIDE :: ZPSM == PSMZ32 || ZPSM == PSMZ24
		ZMAX :: 0xffffffff when ZPSM == PSMZ32 else 0xffffff when ZPSM == PSMZ24 else 0xffff
		z := min(u32(min(zf, 4294967295.0)), u32(ZMAX))
		za := row_addr_w(&c.zrow, px, ZWIDE)
		when ZTST == 2 {
			if z < row_read_w(&c.zrow, za, ZWIDE) {return}
		} else when ZTST == 3 {
			if z <= row_read_w(&c.zrow, za, ZWIDE) {return}
		}
		when FAIL_Z {
			if pass {row_write_w(&c.zrow, za, z, ZWIDE)}
		} else when ZWRITE {
			row_write_w(&c.zrow, za, z, ZWIDE)
		}
	}

	when UNPACK {
		dst := unpack(dst_raw)
		when FPSM == PSMCT24 {dst.a = 0x80}
	} else when BLEND {
		dst: [4]i32 // not read
	}
	when BLEND {
		sel :: #force_inline proc($N: u32, s, d: [4]i32) -> [3]i32 {
			when N == 0 {return s.rgb} else when N == 1 {return d.rgb} else {return {}}
		}
		ca, cb, cd := sel(A, src, dst), sel(B, src, dst), sel(D, src, dst)
		alpha: i32
		when C == 0 {
			alpha = src.a
		} else when C == 1 {
			alpha = dst.a
		} else {
			alpha = i32(c.fix)
		}
		for k in 0 ..< 3 {src[k] = (((ca[k] - cb[k]) * alpha) >> 7) + cd[k]}
	}
	for k in 0 ..< 3 {src[k] = clamp(src[k], 0, 255)}
	when FAIL_A {if !pass {src.a = dst.a}}

	out := u32(src.r) | u32(src.g) << 8 | u32(src.b) << 16 | u32(src.a & 0xff) << 24
	when FBMSK {out = (out &~ c.fbmsk) | (dst_raw & c.fbmsk)}
	row_write_w(&c.frow, fa, out, true)
}
