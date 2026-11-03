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
@(private)
disp_logged: u64

// Buffers the display has shown since the last reset. A draw whose FRAME
// FBP is one of them (exact base) is the picture itself, redrawn every
// frame while the game flips; a draw to any other FBP builds something the
// picture is made from (a texture, an offscreen buffer) and always runs.
@(private)
Shown :: struct {
	fbp, fbw, psm, h: u32, // fbp in blocks
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

// Clear the shown buffers and the feedback latch: CSR RESET and snapshot
// loads.
display_reset :: proc() {
	n_shown, feedback, skip_on = 0, false, false
	last_fbp = {max(u32), max(u32)}
	since_flip = FLIP_WINDOW + 1
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
	on := skip_wanted && since_flip <= FLIP_WINDOW && !feedback
	if on != skip_on && skip_wanted {
		fmt.eprintfln("gs: headless skip of shown-buffer draws %s (%d shown)", on ? "on" : "off", n_shown)
	}
	skip_on = on
}

// Whether block address bp lies in a shown buffer.
@(private)
in_shown :: proc(bp: u32) -> bool {
	for e in shown[:n_shown] {
		rows: u32 = psm_bits(e.psm) == 16 ? 64 : 32 // a page's height
		if bp >= e.fbp && bp < e.fbp + e.fbw * ((e.h + rows - 1) / rows) * 32 {return true}
	}
	return false
}

// A draw or transfer reads block address bp: if that is a shown buffer,
// stop skipping until the display resets.
@(private)
shown_read :: proc(bp: u32) {
	if feedback || !in_shown(bp) {return}
	feedback, skip_on = true, false
	if skip_wanted {
		fmt.eprintfln("gs: shown buffer at block %x read back; headless draw skip off until the display resets", bp)
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
	for y in 0 ..< h {
		row := screen[y * DISP_W:]
		for x in 0 ..< w {
			c := read_raw(psm, fbp, fbw, dbx + u32(x), dby + u32(y))
			if psm == PSMCT16 || psm == PSMCT16S {
				c = (c & 0x1f) << 3 | (c & 0x3e0) << 6 | (c & 0x7c00) << 9
			}
			row[x] = c | 0xff000000
		}
	}
	return
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
