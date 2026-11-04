package ps2_gs

// Test hooks: the texture sampler outside a draw, for tests/gs_tex, and
// the pixel proc choice, for tests/gs_pixel.

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
	return sample_level(&ctx_cur.tex, n, u, v, bilinear)
}

// Level n's texel (x, y) of the probed context's texture, through the cache.
probe_texel :: proc(n, x, y: u32) -> u32 {
	return texel(&ctx_cur.tex, n, x, y)
}

// Whether contexts decoded from now on take the generic pixel proc rather
// than a fast one (tests/gs_pixel). The next draw decodes its context again.
probe_generic :: proc(on: bool) {
	px_generic = on
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
