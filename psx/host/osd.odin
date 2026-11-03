// Host on-screen display: short-lived notices (toasts) and a label drawn
// over the game picture in the 640x480 logical canvas, and the paging of a
// panel that a feature draws in the game's own picture.
//
// The game never sees any of it. Text is rendered with an 8x8 bitmap font
// into a streaming texture that is rebuilt only when the text changes or a
// toast expires. Toasts expire on real time (SDL ticks): they are host UI,
// not game logic, so the emulated frame rate does not matter to them.
//
// The panel exists only while a feature gives it pages (osd_panel_pages).
// The feature shows and hides it (osd_toggle_panel), draws the page shown
// (osd_panel_shown, osd_panel_page) and steps the pages (osd_panel_step). While
// it is up the game sees no pad buttons (pad_game). A label is one line at a
// chosen spot, such as a button hint inside a game screen. The inset is a small
// picture a feature paints itself (osd_inset_pixels, then osd_inset_changed)
// and shows at a canvas spot. The overlay is a whole-canvas picture painted the
// same way, drawn over all of it (the map editor's cursor and text).
package psx_host

import "core:fmt"
import sdl "vendor:sdl2"

import "ps:core"

// Longest line, in characters; longer text is cut at this width.
OSD_COLS :: 72
@(private)
OSD_TOASTS :: 4
// Real time a toast stays on screen.
@(private)
OSD_TOAST_MS :: 6000

@(private)
GLYPH :: core.FONT_GLYPH
@(private)
LINE_H :: 10
@(private)
OSD_MARGIN :: 8
@(private)
OSD_PAD :: 4

@(private)
OSD_TEXT :: 0xffffffff // ARGB
@(private)
OSD_BACK :: 0xc0000000

@(private)
Osd_Line :: struct {
	text: [OSD_COLS]u8,
	len:  int,
}

@(private)
Osd_Toast :: struct {
	line:    Osd_Line,
	expires: u32, // SDL ticks
}

@(private)
osd: struct {
	tex:         ^sdl.Texture,
	failed:      bool,
	pixels:      [WINDOW_W * WINDOW_H]u32,
	toasts:      [OSD_TOASTS]Osd_Toast,
	toast_count: int,
	label:       Osd_Line,
	label_at:    [2]int, // canvas position of the label text
	dirty:       bool,
}

// The inset's side, in canvas pixels.
OSD_INSET :: 112

// The inset picture, ARGB; the feature that owns it paints it and calls
// osd_inset_changed. Shown at osd_inset_at (canvas top-left) while
// osd_inset_shown, at osd_inset_opacity (0..1).
osd_inset_pixels: [OSD_INSET * OSD_INSET]u32
osd_inset_at: [2]int
osd_inset_shown := false
osd_inset_opacity: f32 = 1

@(private)
inset: struct {
	tex:    ^sdl.Texture,
	failed: bool,
	dirty:  bool,
}

// The overlay picture, ARGB over the whole canvas; the feature that owns it
// paints it and calls osd_overlay_changed. Shown while osd_overlay_shown.
osd_overlay_pixels: [WINDOW_W * WINDOW_H]u32
osd_overlay_shown := false

@(private)
overlay: struct {
	tex:    ^sdl.Texture,
	failed: bool,
	dirty:  bool,
}

// Pages of the panel; a feature that draws one sets this. 0 = no panel.
osd_panel_pages := 0
osd_panel_shown := false
osd_panel_page := 0 // the page shown while osd_panel_shown

// Show one line with its text's top-left corner at canvas (x, y); empty text
// hides it. Cheap when nothing changed.
osd_set_label :: proc(text: string, x, y: int) {
	changed := osd_line_set(&osd.label, text)
	changed |= osd.label_at != {x, y}
	osd.label_at = {x, y}
	osd.dirty |= changed
}

// Show a notice for OSD_TOAST_MS; the oldest goes when all slots are used.
osd_toast :: proc(text: string) {
	if osd.toast_count == OSD_TOASTS {
		copy(osd.toasts[:], osd.toasts[1:])
		osd.toast_count -= 1
	}
	t := &osd.toasts[osd.toast_count]
	osd_line_set(&t.line, text)
	t.expires = sdl.GetTicks() + OSD_TOAST_MS
	osd.toast_count += 1
	osd.dirty = true
	if .Game in core.trace.active {
		core.tracef(.Game, "osd toast: %s", text)
	}
}

// Show or hide the panel; it opens on the page last shown.
osd_toggle_panel :: proc() {
	if osd_panel_shown {
		osd_hide_panel()
	} else {
		osd_panel_shown = osd_panel_pages > 0
	}
}

// Upload the overlay picture on the next draw.
osd_overlay_changed :: proc() {
	overlay.dirty = true
}

// Upload the inset picture on the next draw.
osd_inset_changed :: proc() {
	inset.dirty = true
}

// Draw glyph `ch` into an ARGB picture `stride` pixels wide, top-left at
// (x, y), clipped to the picture (core/font).
osd_put_glyph :: proc(pixels: []u32, stride: int, ch: u8, x, y: int, color: u32) {
	core.font_glyph(pixels, stride, ch, x, y, color)
}

// Hide the panel. The buttons held now stay hidden from the game until
// released (pad_game), so a press that hides the panel does not reach it.
osd_hide_panel :: proc() {
	if osd_panel_shown {
		input.blocked |= pad_buttons()
	}
	osd_panel_shown = false
}

// Turn the shown panel by `by` pages, wrapping around.
osd_panel_step :: proc(by: int) {
	if osd_panel_shown && osd_panel_pages > 0 {
		osd_panel_page = (osd_panel_page + by) %% osd_panel_pages
	}
}

// Store text in a line; reports whether it differs from before.
@(private)
osd_line_set :: proc(l: ^Osd_Line, text: string) -> bool {
	n := min(len(text), OSD_COLS)
	if n == l.len && string(l.text[:n]) == text[:n] {
		return false
	}
	copy(l.text[:], text[:n])
	l.len = n
	return true
}

// Drop expired toasts.
@(private)
osd_expire :: proc() {
	now := sdl.GetTicks()
	kept := 0
	for i in 0 ..< osd.toast_count {
		if i32(osd.toasts[i].expires - now) > 0 {
			osd.toasts[kept] = osd.toasts[i]
			kept += 1
		}
	}
	osd.dirty |= kept != osd.toast_count
	osd.toast_count = kept
}

// Draw the label and toasts over the canvas; called by draw().
@(private)
osd_draw :: proc() {
	inset_draw()
	overlay_draw()
	osd_expire()
	shown := osd.toast_count > 0 || osd.label.len > 0
	if !shown || osd.failed {
		return
	}
	if osd.tex == nil && !osd_create() {
		return
	}
	if osd.dirty {
		osd_render()
		sdl.UpdateTexture(osd.tex, nil, &osd.pixels[0], WINDOW_W * 4)
		osd.dirty = false
	}
	sdl.RenderCopy(host.renderer, osd.tex, nil, nil)
}

@(private)
inset_draw :: proc() {
	if !osd_inset_shown || inset.failed {
		return
	}
	if inset.tex == nil {
		inset.tex = sdl.CreateTexture(host.renderer, .ARGB8888, .STREAMING, OSD_INSET, OSD_INSET)
		if inset.tex == nil || sdl.SetTextureBlendMode(inset.tex, .BLEND) != 0 {
			fmt.eprintln("osd: cannot create inset texture, inset disabled:", sdl.GetError())
			inset.failed = true
			return
		}
		inset.dirty = true
	}
	if inset.dirty {
		sdl.UpdateTexture(inset.tex, nil, &osd_inset_pixels[0], OSD_INSET * 4)
		inset.dirty = false
	}
	dst := sdl.Rect{i32(osd_inset_at.x), i32(osd_inset_at.y), OSD_INSET, OSD_INSET}
	sdl.SetTextureAlphaMod(inset.tex, u8(255 * clamp(osd_inset_opacity, 0, 1)))
	sdl.RenderCopy(host.renderer, inset.tex, nil, &dst)
}

@(private)
overlay_draw :: proc() {
	if !osd_overlay_shown || overlay.failed {
		return
	}
	if overlay.tex == nil {
		overlay.tex = sdl.CreateTexture(host.renderer, .ARGB8888, .STREAMING, WINDOW_W, WINDOW_H)
		if overlay.tex == nil || sdl.SetTextureBlendMode(overlay.tex, .BLEND) != 0 {
			fmt.eprintln("osd: cannot create overlay texture, overlay disabled:", sdl.GetError())
			overlay.failed = true
			return
		}
		overlay.dirty = true
	}
	if overlay.dirty {
		sdl.UpdateTexture(overlay.tex, nil, &osd_overlay_pixels[0], WINDOW_W * 4)
		overlay.dirty = false
	}
	sdl.RenderCopy(host.renderer, overlay.tex, nil, nil)
}

@(private)
osd_create :: proc() -> bool {
	osd.tex = sdl.CreateTexture(host.renderer, .ARGB8888, .STREAMING, WINDOW_W, WINDOW_H)
	if osd.tex == nil || sdl.SetTextureBlendMode(osd.tex, .BLEND) != 0 {
		fmt.eprintln("osd: cannot create texture, on-screen text disabled:", sdl.GetError())
		osd.failed = true
		return false
	}
	osd.dirty = true
	return true
}

@(private)
osd_render :: proc() {
	osd.pixels = {}
	if osd.label.len > 0 {
		osd_block({osd.label}, osd.label_at.x, osd.label_at.y)
	}
	for i in 0 ..< osd.toast_count {
		y := WINDOW_H - OSD_MARGIN - (osd.toast_count - i) * (LINE_H + 2 * OSD_PAD + 2) + OSD_PAD
		osd_block({osd.toasts[i].line}, OSD_MARGIN, y)
	}
}

// Text lines on a dark box whose top-left text corner is (x, y).
@(private)
osd_block :: proc(lines: []Osd_Line, x, y: int) {
	w := 0
	for l in lines {
		w = max(w, l.len * GLYPH)
	}
	osd_fill(x - OSD_PAD, y - OSD_PAD, w + 2 * OSD_PAD, len(lines) * LINE_H + 2 * OSD_PAD - (LINE_H - GLYPH), OSD_BACK)
	for l, i in lines {
		for k in 0 ..< l.len {
			osd_glyph(l.text[k], x + k * GLYPH, y + i * LINE_H)
		}
	}
}

@(private)
osd_fill :: proc(x, y, w, h: int, color: u32) {
	x0, y0 := max(x, 0), max(y, 0)
	x1, y1 := min(x + w, WINDOW_W), min(y + h, WINDOW_H)
	for row in y0 ..< y1 {
		for col in x0 ..< x1 {
			osd.pixels[row * WINDOW_W + col] = color
		}
	}
}

@(private)
osd_glyph :: proc(ch: u8, x, y: int) {
	osd_put_glyph(osd.pixels[:], WINDOW_W, ch, x, y, OSD_TEXT)
}
