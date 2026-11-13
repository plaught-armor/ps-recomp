// Decoded texture cache for the software GS: 16x16 tiles of texels as
// `fetch` returns them (RGBA8888, after the CLUT and expand16), each tile
// decoded on first use by a loop for its format (tc_fill). A cached texel is
// the fetch it stands for as long as nothing fetch read has changed since.
//
// An entry is one mip level of one texture, keyed by what fetch reads: the
// PSM, the level's base, width and size, the CLUT entries an indexed format
// looks up, and TEXA where the format or a 16-bit CLUT uses it. Every write
// to local memory records the pages it reaches (page_gen): host-to-local
// transfers (transfer_cpu), local-to-local copies (xfer_start) and draws,
// each primitive by its bounding box in the frame and Z buffers. An entry is
// validated when a context first samples its level, and again after any
// transfer; a write since the last validation to a page the level spans
// drops its tiles. CLUT loads are caught by the key: the entries are
// compared on validation, skipped while clut_gen is unchanged. A snapshot
// load drops everything (tc_flush).
//
// Fetched uncached: a level sharing a page with the frame or Z buffer its
// context writes, which may read the context's own draws, and texels
// outside the level's w x h (region clamp and repeat).
package ps2_gs

import "core:math/bits"

// Tiles in the pool, 1 KiB each. The busiest measured game keeps about
// 2500 live; past this the oldest-allocated tile is reused (tc_alloc).
@(private)
TC_TILES :: 4096
@(private)
TC_ENTRIES :: 64
// A level is at most 1024x1024 texels: 64x64 tiles.
@(private)
TC_MAP :: 64 * 64
// tc_lvl values below 0.
@(private)
TC_UNRESOLVED :: -1
@(private)
TC_BYPASS :: -2

// What fetch reads besides local memory, and where. Fields a format does not
// use stay 0, so equal levels share an entry whatever the rest of TEX0 says.
@(private)
Tc_Key :: struct {
	psm, tbp, tbw: u32,
	cw, ch:        u32, // level size in texels
	c32:           bool, // indexed with a PSMCT32 CLUT
	csa, nclut:    u32,
	ta0, ta1:      u32,
	aem:           bool,
}

@(private)
Tc_Entry :: struct {
	used:     bool,
	key:      Tc_Key,
	tw:       u32, // tiles per row
	gen:      u64, // tc_gen at the last validation
	last:     u64, // tc_use at the last resolve, for replacement
	clut_gen: u64, // clut_gen the CLUT entries last matched at
	live:     u32, // tiles in the pool
	pages:    Page_Set,
	clut:     [256]u32, // key.nclut entries from csa * 16
	// Pool slot + 1 of each tile, row-major, 0 when not decoded; all 0
	// while the entry is unused.
	tile:     [TC_MAP]u16,
}

@(private)
Tc_Owner :: struct {
	e, b: u16, // entry and tile index; e TC_ENTRIES when the slot is free
}

@(private)
tc_e: [TC_ENTRIES]Tc_Entry
@(private)
tc_pool: [TC_TILES][256]u32
@(private)
tc_owner: [TC_TILES]Tc_Owner
// Slots never used yet are tc_top.., dropped ones are on tc_free; with
// neither left every slot is owned and tc_hand picks the one to reuse.
@(private)
tc_top, tc_hand, tc_nfree: u32
@(private)
tc_free: [TC_TILES]u16

// Page write stamps: a page written after an entry's validation at gen g
// has page_gen > g. Draws and transfers collect their pages in tc_pending;
// the next resolve stamps them, so a primitive costs its bounding box only.
@(private)
page_gen: [PAGES]u64
@(private)
tc_gen: u64 = 1
@(private)
tc_pending: Page_Set
@(private)
tc_use: u64
// Bumped by a software CLUT load that changes a word of the buffer.
@(private)
clut_gen: u64 = 1

// The current context's entry per mip level, or TC_UNRESOLVED/TC_BYPASS,
// and the pages it writes (tc_wpages, computed when first needed).
@(private)
tc_lvl: [7]i32
@(private)
tc_wpages: Page_Set
@(private)
tc_wready: bool

// Level n's decoded 16x16 tile holding texel (x, y), or nil where the
// texel comes from fetch: an unresolved or bypassed level, or (xe, ye)
// outside the entry (a caller using the tile for several texels passes
// their largest coordinates). Unchecked: n <= 6 (mxl is clamped), a
// resolved tc_lvl is an entry index, x < cw and y < ch keep the tile index
// under tw * 64 <= TC_MAP, and a nonzero tile is a slot + 1.
@(private)
tile_at :: #force_inline proc(t: ^Tex, n, x, y, xe, ye: u32) -> ^[256]u32 #no_bounds_check {
	l := tc_lvl[n]
	if l < 0 {
		if l == TC_UNRESOLVED {
			l = tc_resolve(t, n)
			tc_lvl[n] = l
		}
		if l < 0 {return nil}
	}
	e := &tc_e[l]
	if xe >= e.key.cw || ye >= e.key.ch {return nil}
	s := u32(e.tile[(y >> 4) * e.tw + (x >> 4)])
	if s == 0 {s = tc_decode(e, u32(l), t, n, x >> 4, y >> 4)}
	return &tc_pool[s - 1]
}

// Level n's texel (x, y), as fetch returns it.
@(private)
texel :: #force_inline proc(t: ^Tex, n, x, y: u32) -> u32 #no_bounds_check {
	p := tile_at(t, n, x, y, x, y)
	if p == nil {return fetch_direct(t, n, x, y)}
	return p[(y & 15) << 4 | (x & 15)]
}

// A new context: every level resolves again on its first sample.
@(private)
tc_ctx :: proc() {
	for &l in tc_lvl {l = TC_UNRESOLVED}
	tc_wready = false
}

// A host-to-local chunk or local-to-local copy writing w x h pixels from
// (x0, y0): its pages are written, and the current context's entries
// validate again before their next sample.
@(private)
tc_write_rect :: proc(bp, bw, psm, x0, y0, w, h: u32) {
	page_rect(psm, bp, bw, x0, y0, x0 + w, y0 + h, &tc_pending)
	for &l in tc_lvl {if l >= 0 {l = TC_UNRESOLVED}}
}

// A primitive about to be drawn: the pages its bounding box, clipped to the
// scissor, reaches in the frame buffer and, when written, the Z buffer.
@(private)
tc_draw :: proc(c: ^Ctx, kind: u64) #no_bounds_check {
	@(static, rodata) verts := [8]int{1, 2, 2, 3, 3, 3, 2, 1}
	x0, y0, x1, y1 := queue[0].x, queue[0].y, queue[0].x, queue[0].y
	for i in 1 ..< verts[kind & 7] {
		x0, x1 = min(x0, queue[i].x), max(x1, queue[i].x)
		y0, y1 = min(y0, queue[i].y), max(y1, queue[i].y)
	}
	// Rasterisers write floor..ceil of the box at most.
	ix0, iy0 := max(i32(x0), c.sx0, 0), max(i32(y0), c.sy0, 0)
	ix1, iy1 := min(i32(x1) + 1, c.sx1), min(i32(y1) + 1, c.sy1)
	if ix1 < ix0 || iy1 < iy0 {return}
	page_rect(c.fpsm, c.fbp, c.fbw, u32(ix0), u32(iy0), u32(ix1) + 1, u32(iy1) + 1, &tc_pending)
	if c.zte && !c.zmsk {
		page_rect(c.zpsm, c.zbp, c.fbw, u32(ix0), u32(iy0), u32(ix1) + 1, u32(iy1) + 1, &tc_pending)
	}
}

// Drop every entry: local memory and the CLUT may be anything now.
tc_flush :: proc() {
	for &e in tc_e {
		if e.used {tc_drop(&e)}
		e.used = false
	}
	tc_pending = {}
	tc_ctx()
}

// Page size and pages per buffer row of a format at width bw.
@(private)
page_geom :: proc(psm, bw: u32) -> (pw, ph, bwp: u32) {
	switch psm {
	case PSMT8H, PSMT4HL, PSMT4HH: return 64, 32, bw
	}
	switch psm_bits(psm) {
	case 16: return 64, 64, bw
	case 8: return 128, 64, bw >> 1
	case 4: return 128, 128, bw >> 1
	}
	return 64, 32, bw
}

// Add to `out` the pages holding pixels [x0, x1) x [y0, y1) of the buffer at
// block bp: the exact page of each, a pixel past the buffer's width
// included, and the next physical page too when bp is not page-aligned. An
// axis past 2048 wraps, so takes all of it.
@(private)
page_rect :: proc(psm, bp, bw, x0, y0, x1, y1: u32, out: ^Page_Set) #no_bounds_check {
	x0, y0, x1, y1 := x0, y0, x1, y1
	if x1 > 2048 {x0, x1 = 0, 2048}
	if y1 > 2048 {y0, y1 = 0, 2048}
	if x1 <= x0 || y1 <= y0 {return}
	pw, ph, bwp := page_geom(psm, bw)
	for py in y0 / ph ..= (y1 - 1) / ph {
		for px in x0 / pw ..= (x1 - 1) / pw {
			blk := bp + (py * bwp + px) * 32
			a, b := (blk >> 5) % PAGES, ((blk + 31) >> 5) % PAGES
			out[a / 64] |= 1 << (a % 64)
			out[b / 64] |= 1 << (b % 64)
		}
	}
}

@(private)
pages_meet :: proc(a, b: ^Page_Set) -> bool {
	for w, i in a {if w & b[i] != 0 {return true}}
	return false
}

// Stamp the pending writes.
@(private)
tc_stamp :: proc() #no_bounds_check {
	for &w, i in tc_pending {
		for w != 0 {
			page_gen[u32(i) * 64 + u32(bits.count_trailing_zeros(w))] = tc_gen
			w &= w - 1
		}
	}
}

// The entry for level n of the current context's texture, validated, or
// TC_BYPASS when the context writes a page the level spans.
@(private, cold)
tc_resolve :: proc(t: ^Tex, n: u32) -> i32 #no_bounds_check {
	k := Tc_Key {
		psm = t.psm,
		tbp = t.mtbp[n],
		tbw = t.mtbw[n],
		cw  = max(t.w >> n, 1),
		ch  = max(t.h >> n, 1),
	}
	texa := false
	switch t.psm {
	case PSMCT24, PSMCT16, PSMCT16S: texa = true
	case PSMCT32:
	case:
		k.c32 = t.cpsm == PSMCT32
		k.csa = t.csa
		k.nclut = (t.psm == PSMT8 || t.psm == PSMT8H) ? 256 : 16
		texa = !k.c32
	}
	if texa {k.ta0, k.ta1, k.aem = t.ta0, t.ta1, t.aem}

	if !tc_wready {
		c := &ctx_cur
		tc_wpages = {}
		sx0, sy0 := u32(max(c.sx0, 0)), u32(max(c.sy0, 0))
		sx1, sy1 := u32(max(c.sx1, 0)) + 1, u32(max(c.sy1, 0)) + 1
		page_rect(c.fpsm, c.fbp, c.fbw, sx0, sy0, sx1, sy1, &tc_wpages)
		if c.zte && !c.zmsk {page_rect(c.zpsm, c.zbp, c.fbw, sx0, sy0, sx1, sy1, &tc_wpages)}
		tc_wready = true
	}

	tc_stamp()
	tc_pending = {}
	tc_use += 1
	found := -1
	for &e, i in tc_e {
		if e.used && e.key == k && tc_clut_match(&e) {
			found = i
			break
		}
	}
	if found >= 0 {
		e := &tc_e[found]
		if pages_meet(&e.pages, &tc_wpages) {return TC_BYPASS}
		for w, i in e.pages {
			m := w
			for m != 0 {
				if page_gen[u32(i) * 64 + u32(bits.count_trailing_zeros(m))] > e.gen {
					tc_drop(e)
					break
				}
				m &= m - 1
			}
		}
		e.gen, e.last = tc_gen, tc_use
		tc_gen += 1
		return i32(found)
	}

	pages: Page_Set
	page_rect(k.psm, k.tbp, k.tbw, 0, 0, k.cw, k.ch, &pages)
	if pages_meet(&pages, &tc_wpages) {return TC_BYPASS}
	slot := tc_victim()
	e := &tc_e[slot]
	if e.used {tc_drop(e)}
	e.used, e.key, e.pages = true, k, pages
	e.tw = (k.cw + 15) >> 4
	e.gen, e.last, e.clut_gen = tc_gen, tc_use, clut_gen
	for i in 0 ..< k.nclut {e.clut[i] = clut[(k.csa * 16 + i) & 511]}
	tc_gen += 1
	return i32(slot)
}

// The entry's CLUT entries are the CLUT's now.
@(private)
tc_clut_match :: proc(e: ^Tc_Entry) -> bool #no_bounds_check {
	if e.key.nclut == 0 || e.clut_gen == clut_gen {return true}
	for i in 0 ..< e.key.nclut {
		if e.clut[i] != clut[(e.key.csa * 16 + i) & 511] {return false}
	}
	e.clut_gen = clut_gen
	return true
}

// An unused entry, else the least recently resolved one no level of the
// current context holds.
@(private)
tc_victim :: proc() -> int {
	best := -1
	outer: for &e, i in tc_e {
		if !e.used {return i}
		for l in tc_lvl {if l == i32(i) {continue outer}}
		if best < 0 || e.last < tc_e[best].last {best = i}
	}
	assert(best >= 0) // TC_ENTRIES > len(tc_lvl)
	return best
}

// Return the entry's tiles to the pool.
@(private)
tc_drop :: proc(e: ^Tc_Entry) #no_bounds_check {
	if e.live == 0 {return}
	th := (e.key.ch + 15) >> 4
	for &s in e.tile[:e.tw * th] {
		if s == 0 {continue}
		tc_owner[s - 1].e = TC_ENTRIES
		tc_free[tc_nfree] = s - 1
		tc_nfree += 1
		s = 0
	}
	e.live = 0
}

// A pool slot: never used, dropped, or else the next one round the pool,
// taken from the tile that holds it.
@(private)
tc_alloc :: proc() -> u32 #no_bounds_check {
	if tc_nfree > 0 {
		tc_nfree -= 1
		return u32(tc_free[tc_nfree])
	}
	if tc_top < TC_TILES {
		tc_top += 1
		return tc_top - 1
	}
	s := tc_hand
	tc_hand = (tc_hand + 1) % TC_TILES
	o := tc_owner[s]
	assert(o.e < TC_ENTRIES) // with no free slot every slot is owned
	tc_e[o.e].tile[o.b] = 0
	tc_e[o.e].live -= 1
	return s
}

// Decode tile (tx, ty) of entry ei (level n of t) and return its slot + 1.
@(private, cold)
tc_decode :: proc(e: ^Tc_Entry, ei: u32, t: ^Tex, n, tx, ty: u32) -> u32 #no_bounds_check {
	s := tc_alloc()
	b := ty * e.tw + tx
	x0, y0 := tx * 16, ty * 16
	tc_fill(&tc_pool[s], t, n, x0, y0, min(16, e.key.cw - x0), min(16, e.key.ch - y0))
	e.tile[b] = u16(s + 1)
	e.live += 1
	tc_owner[s] = {u16(ei), u16(b)}
	return s + 1
}

// The w x h texels from (x0, y0) of level n of t into a tile, each as
// `fetch` returns it; the rest of the tile is not written. x0 and y0 are
// multiples of 16, so the tile lies in one page of every format, and in
// that page covers one block of a 4- or 8-bit format, two of a 16-bit one,
// one above the other, and four of a 32-bit one: what an address shares
// across the tile or a row of it is computed once, and a texel costs a
// column table read and a load. tests/gs_decode holds each loop to fetch.
@(private = "file")
tc_fill :: #force_no_inline proc(out: ^[256]u32, t: ^Tex, n, x0, y0, w, h: u32) #no_bounds_check {
	c16 := t.cpsm != PSMCT32
	ta := Tc_Texa{t.ta0 << 24, t.ta1 << 24, t.aem}
	pal := t.csa * 16
	switch t.psm {
	case PSMCT32: tc_fill_w(out, t, n, x0, y0, w, h, ta, pal, Tc_Wide.CT32, false)
	case PSMCT24: tc_fill_w(out, t, n, x0, y0, w, h, ta, pal, Tc_Wide.CT24, false)
	case PSMCT16: tc_fill_h(out, t, n, x0, y0, w, h, ta, &block16)
	case PSMCT16S: tc_fill_h(out, t, n, x0, y0, w, h, ta, &block16s)
	case PSMT8:
		if c16 {tc_fill_8(out, t, n, x0, y0, w, h, ta, pal, true)} else {tc_fill_8(out, t, n, x0, y0, w, h, ta, pal, false)}
	case PSMT4:
		if c16 {tc_fill_4(out, t, n, x0, y0, w, h, ta, pal, true)} else {tc_fill_4(out, t, n, x0, y0, w, h, ta, pal, false)}
	case PSMT8H:
		if c16 {tc_fill_w(out, t, n, x0, y0, w, h, ta, pal, Tc_Wide.T8H, true)} else {tc_fill_w(out, t, n, x0, y0, w, h, ta, pal, Tc_Wide.T8H, false)}
	case PSMT4HL:
		if c16 {tc_fill_w(out, t, n, x0, y0, w, h, ta, pal, Tc_Wide.T4HL, true)} else {tc_fill_w(out, t, n, x0, y0, w, h, ta, pal, Tc_Wide.T4HL, false)}
	case PSMT4HH:
		if c16 {tc_fill_w(out, t, n, x0, y0, w, h, ta, pal, Tc_Wide.T4HH, true)} else {tc_fill_w(out, t, n, x0, y0, w, h, ta, pal, Tc_Wide.T4HH, false)}
	case:
		// No texture format: whatever fetch makes of it.
		for y in 0 ..< h {
			for x in 0 ..< w {out[y << 4 | x] = fetch(t, n, x0 + x, y0 + y)}
		}
	}
}

// TEXA as expand16 reads it, the alphas in place.
@(private = "file")
Tc_Texa :: struct {
	a0, a1: u32,
	aem:    bool,
}

// expand16 of c.
@(private = "file")
tc_x16 :: #force_inline proc(c: u32, ta: Tc_Texa) -> u32 {
	rgb := (c & 0x1f) << 3 | (c & 0x3e0) << 6 | (c & 0x7c00) << 9
	a := c & 0x8000 != 0 ? ta.a1 : !ta.aem || c & 0x7fff != 0 ? ta.a0 : 0
	return rgb | a
}

// CLUT entry i from `base`, fetch's colour for an indexed texel: as it is
// for a 32-bit CLUT, expanded for a 16-bit one.
@(private = "file")
tc_pal :: #force_inline proc(base, i: u32, ta: Tc_Texa, $C16: bool) -> u32 #no_bounds_check {
	c := clut[(base + i) & 511]
	when C16 {return tc_x16(c & 0xffff, ta)} else {return c}
}

// The formats stored a texel to a 32-bit word.
@(private = "file")
Tc_Wide :: enum {
	CT32,
	CT24,
	T8H,
	T4HL,
	T4HH,
}

// Blocks are 8 x 8: a row of the tile lies in two, side by side.
@(private = "file")
tc_fill_w :: #force_inline proc(out: ^[256]u32, t: ^Tex, n, x0, y0, w, h: u32, ta: Tc_Texa, pal: u32, $K: Tc_Wide, $C16: bool) #no_bounds_check {
	page := t.mtbp[n] + ((y0 >> 5) * t.mtbw[n] + (x0 >> 6)) * 32
	bx := (x0 >> 3) & 7
	for y in 0 ..< h {
		blk := &block32[((y0 + y) >> 3) & 3]
		col := &col32[y & 7]
		base := [2]u32{(page + blk[bx]) << 6, (page + blk[bx + 1]) << 6}
		o := ([^]u32)(out)[y << 4:]
		for x in 0 ..< w {
			v := vram[(base[x >> 3] + col[x & 7]) & (VRAM_WORDS - 1)]
			when K == .CT32 {
				o[x] = v
			} else when K == .CT24 {
				o[x] = v & 0xffffff | (ta.aem && v & 0xffffff == 0 ? 0 : ta.a0)
			} else when K == .T8H {
				o[x] = tc_pal(pal, v >> 24, ta, C16)
			} else when K == .T4HL {
				o[x] = tc_pal(pal, (v >> 24) & 15, ta, C16)
			} else {
				o[x] = tc_pal(pal, v >> 28, ta, C16)
			}
		}
	}
}

// PSMCT16 and PSMCT16S, by their block table. Blocks are 16 x 8: a row of
// the tile lies in one.
@(private = "file")
tc_fill_h :: proc(out: ^[256]u32, t: ^Tex, n, x0, y0, w, h: u32, ta: Tc_Texa, blocks: ^[8][4]u32) #no_bounds_check {
	page := t.mtbp[n] + ((y0 >> 6) * t.mtbw[n] + (x0 >> 6)) * 32
	bx := (x0 >> 4) & 3
	for y in 0 ..< h {
		base := (page + blocks[((y0 + y) >> 3) & 7][bx]) << 7
		col := &col16[y & 7]
		o := ([^]u32)(out)[y << 4:]
		for x in 0 ..< w {
			o[x] = tc_x16(u32(vram16()[(base + col[x]) & (2 * VRAM_WORDS - 1)]), ta)
		}
	}
}

// PSMT8. Blocks are 16 x 16: the tile is one.
@(private = "file")
tc_fill_8 :: #force_inline proc(out: ^[256]u32, t: ^Tex, n, x0, y0, w, h: u32, ta: Tc_Texa, pal: u32, $C16: bool) #no_bounds_check {
	base := (t.mtbp[n] + ((y0 >> 6) * (t.mtbw[n] >> 1) + (x0 >> 7)) * 32 + block32[(y0 >> 4) & 3][(x0 >> 4) & 7]) << 8
	for y in 0 ..< h {
		col := &col8[y]
		o := ([^]u32)(out)[y << 4:]
		for x in 0 ..< w {
			o[x] = tc_pal(pal, u32(vram8()[(base + col[x]) & (4 * VRAM_WORDS - 1)]), ta, C16)
		}
	}
}

// PSMT4. Blocks are 32 x 16: the tile is a half of one.
@(private = "file")
tc_fill_4 :: #force_inline proc(out: ^[256]u32, t: ^Tex, n, x0, y0, w, h: u32, ta: Tc_Texa, pal: u32, $C16: bool) #no_bounds_check {
	base := (t.mtbp[n] + ((y0 >> 7) * (t.mtbw[n] >> 1) + (x0 >> 7)) * 32 + block16[(y0 >> 4) & 7][(x0 >> 5) & 3]) << 9
	for y in 0 ..< h {
		col := ([^]u32)(&col4[y])[x0 & 16:]
		o := ([^]u32)(out)[y << 4:]
		for x in 0 ..< w {
			a := (base + col[x]) & (8 * VRAM_WORDS - 1)
			o[x] = tc_pal(pal, u32(vram8()[a >> 1] >> ((a & 1) * 4)) & 15, ta, C16)
		}
	}
}
