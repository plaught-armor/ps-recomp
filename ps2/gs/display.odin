// Read-circuit output: turns the displayed frame buffer into an RGBA8888
// image for the host window.
package ps2_gs

import "core:fmt"

DISP_W :: 640
DISP_H :: 512

screen: [DISP_W * DISP_H]u32
// Headless with no picture wanted this vblank: scanout returns the size
// without filling `screen`. VRAM and GS state are untouched either way.
skip_readout: bool
// Set by the host each vblank: headless, with no picture due soon (a shot
// or the COMPAT lit count). Draws are then skipped only into a buffer the
// display has shown, while the game flips, and while no draw or transfer has
// read a shown buffer back; see track_display.
skip_wanted: bool
// Set by the host when snapshots or rollback are in use (SNAPTEST, RBTEST,
// netplay): no draw is skipped, since the shown set and the feedback latch
// are not in the snapshot and a replay must draw what the first run drew.
replays: bool
@(private)
disp_logged: u64

// Buffers the display has shown since the last reset. A draw whose FRAME
// FBP is one of them (exact base) is the picture itself, redrawn every
// frame while the game flips; a draw to any other FBP builds something the
// picture is made from (a texture, an offscreen buffer) and always runs.
@(private)
Shown :: struct {
	fbp, fbw, psm, h, dby: u32, // fbp in blocks; h and dby in rows
}
@(private)
SHOWN_MAX :: 4
@(private)
shown: [SHOWN_MAX]Shown
@(private)
n_shown: int
// DISPFB FBP per circuit at the last vblank, to see flips.
@(private)
last_fbp := [2]u32{max(u32), max(u32)}
// Vblanks since a circuit's DISPFB FBP last changed. Within FLIP_WINDOW the
// game is flipping (20 fps and up); past it the screen is held, and a held
// screen may be drawn only once, so nothing is skipped.
@(private)
since_flip: u32 = FLIP_WINDOW + 1
@(private)
FLIP_WINDOW :: 2
// A draw textured from, or a transfer read, a shown buffer: its content is
// read, so skipping draws into it is no longer safe until the display resets.
@(private)
feedback: bool
// Whether draw skips draws into shown buffers now (decode_ctx sets
// Ctx.on_display; draw checks both).
@(private)
skip_on: bool
// Whether the skip has been reported turning off and on, by skip_on: only
// the first of each is logged.
@(private)
skip_logged: [2]bool

// Clear the shown buffers and the feedback latch: CSR RESET only. A fifth
// base or a width, format or height change resets the shown set in
// track_display but keeps the latch, on purpose: a buffer once read back
// may be read again, so keeping the skip off is the safe side. A snapshot
// load keeps both (snapshots turn the skip off; see replays).
display_reset :: proc() {
	n_shown, feedback, skip_on = 0, false, false
	last_fbp = {max(u32), max(u32)}
	since_flip = FLIP_WINDOW + 1
	ctx_gen += 1
}

// The display tracking above, which is host state: a compat probe
// (ps2/host/probe.odin) keeps it across its branches, so the run goes on as
// if they never ran.
Display_Track :: struct {
	shown:       [SHOWN_MAX]Shown,
	n_shown:     int,
	last_fbp:    [2]u32,
	since_flip:  u32,
	feedback:    bool,
	skip_on:     bool,
	skip_logged: [2]bool,
	disp_logged: u64,
}

display_track_get :: proc() -> Display_Track {
	return {shown, n_shown, last_fbp, since_flip, feedback, skip_on, skip_logged, disp_logged}
}

// Set the tracking back; the cached drawing context may have seen another.
display_track_set :: proc(t: Display_Track) {
	shown, n_shown, last_fbp, since_flip = t.shown, t.n_shown, t.last_fbp, t.since_flip
	feedback, skip_on, skip_logged, disp_logged = t.feedback, t.skip_on, t.skip_logged, t.disp_logged
	ctx_gen += 1
}

// Once per vblank, before the read circuit: note each enabled circuit's
// DISPFB in the shown set, see whether the game flips, and decide skip_on.
// The set resets when a buffer's width, format or height changes, or a
// fifth base appears (the game moved its buffers).
@(private)
track_display :: proc(pmode: u64) {
	flipped := false
	for circ in u32(0) ..< 2 {
		if pmode & (1 << circ) == 0 {continue}
		dispfb := gs_priv(0x70 + circ * 0x20)
		display := gs_priv(0x80 + circ * 0x20)
		b := Shown {
			fbp = u32(dispfb & 0x1ff) * 32,
			fbw = u32(dispfb >> 9) & 0x3f,
			psm = u32(dispfb >> 15) & 0x1f,
			h   = (u32(display >> 44) & 0x7ff + 1) / (u32(display >> 27) & 3 + 1),
			dby = u32(dispfb >> 43) & 0x7ff,
		}
		if b.fbp != last_fbp[circ] {
			flipped = flipped || last_fbp[circ] != max(u32)
			last_fbp[circ] = b.fbp
		}
		found, changed := false, false
		for e in shown[:n_shown] {
			if e.fbw != b.fbw || e.psm != b.psm || e.h != b.h {changed = true}
			if e == b {found = true}
		}
		if found && !changed {continue}
		if changed || n_shown == SHOWN_MAX {n_shown = 0}
		shown[n_shown] = b
		n_shown += 1
		ctx_gen += 1
	}
	since_flip = flipped ? 0 : min(since_flip + 1, FLIP_WINDOW + 1)
	on := skip_wanted && !replays && since_flip <= FLIP_WINDOW && !feedback
	if on != skip_on && skip_wanted && !skip_logged[int(on)] {
		skip_logged[int(on)] = true
		fmt.eprintfln("gs: headless skip of shown-buffer draws %s (%d shown); later toggles not logged", on ? "on" : "off", n_shown)
	}
	skip_on = on
}

// The blocks [lo, hi) holding rows y ..< y+h of a buffer at block bp, bw
// 64-pixel units wide, in format psm: whole rows of pages, so a superset.
@(private)
rows_span :: proc(bp, bw, psm, y, h: u32) -> (lo, hi: u32) {
	pw, ph: u32 = 64, 32 // a page's size in pixels: 32-bit, and the H formats
	if psm != PSMT8H && psm != PSMT4HL && psm != PSMT4HH {
		switch psm_bits(psm) {
		case 16: ph = 64
		case 8: pw, ph = 128, 64
		case 4: pw, ph = 128, 128
		}
	}
	y0, y1 := y, y + max(h, 1)
	if y1 > 2048 {y0, y1 = 0, 2048} // wraps: take every row
	per_row := max(bw * 64 / pw, 1) * 32 // blocks
	return bp + y0 / ph * per_row, bp + (y1 + ph - 1) / ph * per_row
}

// A draw or transfer reads rows y ..< y+h of the buffer at block bp: if any
// of it lies in a shown buffer, stop skipping until the display resets.
@(private)
shown_read :: proc(bp, bw, psm, y, h: u32) {
	if feedback {return}
	lo, hi := rows_span(bp, bw, psm, y, h)
	shown_read_blocks(lo, hi)
}

// A read of blocks [lo, hi): if any lies in a shown buffer, latch.
@(private)
shown_read_blocks :: proc(lo, hi: u32) {
	if feedback {return}
	for e in shown[:n_shown] {
		elo, ehi := rows_span(e.fbp, e.fbw, e.psm, e.dby, e.h)
		if lo < ehi && elo < hi {
			feedback, skip_on = true, false
			if skip_wanted {
				fmt.eprintfln("gs: shown buffer at block %x read back from block %x; headless draw skip off until the display resets", e.fbp, lo)
			}
			return
		}
	}
}

// Copy the active read circuit into `screen`; returns the visible size.
scanout :: proc() -> (w, h: int) {
	pmode := gs_priv(0x00)
	track_display(pmode)
	circ: u32 = pmode & 1 != 0 ? 0 : 1
	if pmode & 3 == 0 {
		if hw_on {hw_frame(0, 0, 0, 0, 0, 0, 0)}
		return 0, 0
	}
	dispfb := gs_priv(0x70 + circ * 0x20)
	display := gs_priv(0x80 + circ * 0x20)
	fbp := u32(dispfb & 0x1ff) * 32
	fbw := u32(dispfb >> 9) & 0x3f
	psm := u32(dispfb >> 15) & 0x1f
	dbx := u32(dispfb >> 32) & 0x7ff
	dby := u32(dispfb >> 43) & 0x7ff
	magh := u32(display >> 23) & 0xf
	magv := u32(display >> 27) & 3
	dw := u32(display >> 32) & 0xfff
	dh := u32(display >> 44) & 0x7ff
	w = int((dw + 1) / (magh + 1))
	h = int((dh + 1) / (magv + 1))
	// Interlaced frame mode (SMODE2 INT and FFMD): DH counts both fields,
	// but each field reads the same buffer lines, so it is half as tall.
	if gs_priv(0x20) & 3 == 3 {h /= 2}
	key := (dispfb &~ 0x1ff) ~ display << 1 ~ pmode << 7 // ignore page flips
	if key != disp_logged {
		disp_logged = key
		fmt.eprintfln("gs: display c%d fbp %x fbw %d psm %x at %d,%d size %dx%d (mag %d,%d)",
			circ + 1, fbp, fbw, psm, dbx, dby, w, h, magh, magv)
	}
	w, h = min(w, DISP_W), min(h, DISP_H)
	if hw_on {
		hw_frame(psm, fbp, fbw, dbx, dby, w, h)
		return
	}
	if skip_readout {return} // headless, no picture due: the size is enough
	r := row_init(psm)
	switch {
	case r.ok && r.wide: scanout_rows(&r, fbp, fbw, dbx, dby, w, h, true)
	case psm == PSMCT16 || psm == PSMCT16S: scanout_rows(&r, fbp, fbw, dbx, dby, w, h, false)
	case:
		for y in 0 ..< h {
			row := screen[y * DISP_W:]
			for x in 0 ..< w {
				c := read_raw(psm, fbp, fbw, dbx + u32(x), dby + u32(y))
				row[x] = scanout_rgba(c, psm == PSMCT16 || psm == PSMCT16S)
			}
		}
	}
	return
}

// A displayed pixel as RGBA8888: 16-bit colours widened (5 bits to the top
// of each byte), alpha forced opaque.
@(private)
scanout_rgba :: #force_inline proc(c: u32, narrow: bool) -> u32 {
	c := c
	if narrow {c = (c & 0x1f) << 3 | (c & 0x3e0) << 6 | (c & 0x7c00) << 9}
	return c | 0xff000000
}

// scanout for a 32- or 24-bit buffer, or a 16-bit colour one: each row's
// address math once (row_seek), then two table reads per pixel, as draw
// does. Reads the same words read_raw would.
@(private)
scanout_rows :: proc(r: ^Row, fbp, fbw, dbx, dby: u32, w, h: int, $WIDE: bool) #no_bounds_check {
	for y in 0 ..< h {
		row := screen[y * DISP_W:]
		row_seek(r, fbp, fbw, dby + u32(y))
		for x in 0 ..< w {
			a := row_addr_w(r, dbx + u32(x), WIDE)
			row[x] = scanout_rgba(row_read_w(r, a, WIDE), !WIDE)
		}
	}
}

// Debug: write the texture TEX0_1 currently names, as raw indices (8/4-bit)
// or colours, to a PPM.
dump_tex :: proc(path: string) -> []u8 {
	t0 := state.regs[0x06]
	tbp, tbw, psm := u32(t0) & 0x3fff, u32(t0 >> 14) & 0x3f, u32(t0 >> 20) & 0x3f
	w, h := u32(1) << (u32(t0 >> 26) & 0xf), u32(1) << (u32(t0 >> 30) & 0xf)
	fmt.eprintfln("gs: dump tex tbp %x tbw %d psm %x %dx%d", tbp, tbw, psm, w, h)
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, fmt.tprintf("P6\n%d %d\n255\n", w, h))
	for y in 0 ..< h {
		for x in 0 ..< w {
			c := read_raw(psm, tbp, tbw, x, y)
			if psm_bits(psm) <= 8 {c = c * 0x010101}
			append(&buf, u8(c), u8(c >> 8), u8(c >> 16))
		}
	}
	return buf[:]
}
