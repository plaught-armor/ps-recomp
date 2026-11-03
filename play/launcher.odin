// The launcher's state and picture, apart from the window (launcher_window.odin)
// so tests drive it with no display. Every input source maps to an Action;
// launcher_step applies one and says what the window must do next.
//
// Two screens: the library list, with the selected disc's thumbnail and
// compatibility result beside it, and the selected disc's settings. A setting
// changed is saved to the disc's settings.tsv at once, and only as a value
// the runtime reads (SETTING_CHOICES); the run started reads it there itself
// (settings_apply), so the launcher never puts a setting in its environment.
// A setting the environment sets is shown locked.
package play

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "ps:core"

Screen :: enum {
	List,
	Settings,
}

Action :: enum {
	None,
	Up,
	Down,
	Left,
	Right,
	Page_Up,
	Page_Down,
	Ok, // list: run the disc; settings: the next choice
	Launch, // run the disc from either screen
	Back,
	Menu, // list: the disc's settings
	Remove, // take a missing disc out of the library
	Quit,
}

// What the window does after a step.
Command :: enum {
	None,
	Launch, // run the selected disc
	Quit,
}

// A setting the settings screen offers: its name there, the values it may
// write ("" leaves it unset, for the runtime's default) and what each is
// called.
Setting_Choice :: struct {
	setting: core.Setting,
	label:   string,
	values:  []string,
	names:   []string,
}

@(rodata)
PS1_CHOICES := [?]Setting_Choice {
	{.Gpu, "Renderer", {"", "vk", "sw"}, {"default", "Vulkan", "software"}},
	{.Native, "Code", {"", "0"}, {"default (native)", "interpreted"}},
}

@(rodata)
PS2_CHOICES := [?]Setting_Choice {
	{.Sw, "Renderer", {"", "1"}, {"default (Vulkan)", "software"}},
	{.Scale, "Scale (Vulkan)", {"", "1", "2", "3", "4", "5", "6", "7", "8"}, {"default", "1x", "2x", "3x", "4x", "5x", "6x", "7x", "8x"}},
	{.Irx, "IOP modules", {"", "0"}, {"default (run)", "HLE"}},
	{.Native, "Code", {"", "0"}, {"default (native)", "interpreted"}},
}

// Where things go on a w x h picture: every size a multiple of the integer
// scale chosen from the picture size.
Layout :: struct {
	w, h:        int,
	scale:       int,
	line:        int, // a text line's height
	margin:      int,
	list_y:      int, // the first list row's top
	list_w:      int, // the list's width, from margin
	rows:        int, // list rows that fit
	panel_x:     int, // the details panel's left edge
	footer_y:    int,
}

Launcher :: struct {
	discs:      [dynamic]Library_Disc,
	sel, top:   int,
	screen:     Screen,
	row:        int, // the settings screen's selected row
	settings:   core.Settings, // the selected disc's settings.tsv
	global:     core.Settings, // <data>/settings.tsv
	thumb:      []u8, // the selected disc's thumbnail, nil without one
	toast:      string, // shown until the next action, in toast_buf
	toast_buf:  [256]u8,
	layout:     Layout,
	// The library's strings; the selected disc's settings and thumbnail.
	lib_arena:  virtual.Arena,
	sel_arena:  virtual.Arena,
}

// Load the library into l. False, after a message, without a data directory
// or when library.tsv cannot be written.
launcher_init :: proc(l: ^Launcher) -> bool {
	return launcher_reload(l, "")
}

launcher_destroy :: proc(l: ^Launcher) {
	virtual.arena_destroy(&l.lib_arena)
	virtual.arena_destroy(&l.sel_arena)
	l^ = {}
}

// Load the library again and select the disc at path, else the row selected
// before, now kept within the list. False as launcher_init.
launcher_reload :: proc(l: ^Launcher, path: string) -> bool {
	keep := strings.clone(path, context.temp_allocator)
	free_all(virtual.arena_allocator(&l.lib_arena))
	l.discs = {}
	discs, ok := library_load(virtual.arena_allocator(&l.lib_arena))
	if !ok {
		return false
	}
	l.discs = discs
	for d, i in l.discs {
		if keep != "" && d.info[.Path] == keep {
			l.sel = i
		}
	}
	l.sel = clamp(l.sel, 0, max(len(l.discs) - 1, 0))
	if len(l.discs) == 0 || l.discs[l.sel].missing {
		l.screen = .List
	}
	launcher_select(l)
	return true
}

// Set the picture size the launcher draws.
launcher_resize :: proc(l: ^Launcher, w, h: int) {
	s := max(1, min(w / 480, h / 360))
	lo := l.layout
	lo.w, lo.h, lo.scale = w, h, s
	lo.line = (core.FONT_GLYPH + 2) * s
	lo.margin = 8 * s
	lo.list_y = lo.margin + 2 * lo.line
	lo.panel_x = w - lo.margin - core.THUMB_W * s
	lo.list_w = max(lo.panel_x - 2 * lo.margin, 0)
	lo.footer_y = h - lo.margin - lo.line
	lo.rows = max((lo.footer_y - lo.line - lo.list_y) / lo.line, 1)
	l.layout = lo
	keep_visible(l)
}

// The choices the selected disc's settings screen offers.
launcher_choices :: proc(l: ^Launcher) -> []Setting_Choice {
	if len(l.discs) == 0 {
		return nil
	}
	return PS2_CHOICES[:] if l.discs[l.sel].info[.System] == "ps2" else PS1_CHOICES[:]
}

// Apply action a.
launcher_step :: proc(l: ^Launcher, a: Action) -> Command {
	if a == .None {
		return .None
	}
	l.toast = ""
	if a == .Quit {
		return .Quit
	}
	if len(l.discs) == 0 {
		return .None
	}
	d := &l.discs[l.sel]
	if a == .Launch || (a == .Ok && l.screen == .List) {
		if d.missing {
			launcher_toast(l, "This disc image is missing; Delete or Y removes it.")
			return .None
		}
		return .Launch
	}
	switch l.screen {
	case .List:
		move := 0
		#partial switch a {
		case .Up:
			move = -1
		case .Down:
			move = 1
		case .Page_Up:
			move = -l.layout.rows
		case .Page_Down:
			move = l.layout.rows
		case .Menu:
			if d.missing {
				launcher_toast(l, "This disc image is missing; Delete or Y removes it.")
			} else {
				l.screen, l.row = .Settings, 0
			}
		case .Remove:
			if !d.missing {
				launcher_toast(l, "Only a missing disc can be removed.")
			} else if !library_remove(d.info[.Path]) || !launcher_reload(l, "") {
				launcher_toast(l, "Cannot write the library (see the terminal).")
			}
		}
		if move != 0 {
			launcher_select_row(l, l.sel + move)
		}
	case .Settings:
		n := len(launcher_choices(l))
		#partial switch a {
		case .Up:
			l.row = (l.row + n - 1) % n
		case .Down:
			l.row = (l.row + 1) % n
		case .Left:
			change_setting(l, -1)
		case .Right, .Ok:
			change_setting(l, 1)
		case .Back, .Menu:
			l.screen = .List
		}
	}
	return .None
}

// Show message t until the next action, cut to fit toast_buf.
launcher_toast :: proc(l: ^Launcher, t: string) {
	n := copy(l.toast_buf[:], t)
	l.toast = string(l.toast_buf[:n])
}

// Select list row i, kept within the list.
launcher_select_row :: proc(l: ^Launcher, row: int) {
	i := clamp(row, 0, max(len(l.discs) - 1, 0))
	if i != l.sel {
		l.sel = i
		launcher_select(l)
	}
}

// The list row (on the list screen) or settings row at picture point
// (x, y), or -1.
launcher_row_at :: proc(l: ^Launcher, x, y: int) -> int {
	lo := l.layout
	if x < lo.margin || x >= lo.margin + lo.list_w || y < lo.list_y {
		return -1
	}
	r := (y - lo.list_y) / lo.line
	if l.screen == .Settings {
		return r if r < len(launcher_choices(l)) else -1
	}
	if r >= lo.rows || l.top + r >= len(l.discs) {
		return -1
	}
	return l.top + r
}

// Load the selected disc's settings and thumbnail.
@(private = "file")
launcher_select :: proc(l: ^Launcher) {
	alloc := virtual.arena_allocator(&l.sel_arena)
	free_all(alloc)
	l.settings, l.global, l.thumb = {}, {}, nil
	keep_visible(l)
	if len(l.discs) == 0 {
		return
	}
	if path, ok := core.settings_global_path(context.temp_allocator); ok {
		l.global = core.settings_load(path, alloc)
	}
	dir, ok := core.disc_dir(l.discs[l.sel].id, context.temp_allocator)
	if !ok {
		return
	}
	l.settings = core.settings_load(core.disc_path(dir, .Settings, context.temp_allocator), alloc)
	l.thumb = core.thumb_load(core.disc_path(dir, .Thumb, context.temp_allocator), alloc)
}

@(private = "file")
keep_visible :: proc(l: ^Launcher) {
	rows := max(l.layout.rows, 1)
	l.top = clamp(l.top, max(l.sel - rows + 1, 0), l.sel)
	l.top = clamp(l.top, 0, max(len(l.discs) - rows, 0))
}

// Step the selected setting's choice by dir and save the disc's settings.
@(private = "file")
change_setting :: proc(l: ^Launcher, dir: int) {
	c := launcher_choices(l)[l.row]
	names := core.SETTING_NAMES
	if _, set := core.env_lookup(names[c.setting]); set {
		launcher_toast(l, fmt.tprintf("Set by %s in the environment.", core.env_name(names[c.setting])))
		return
	}
	// A value the file holds that is not a choice steps from "".
	i := 0
	for v, k in c.values {
		if c.setting in l.settings.set && v == l.settings.value[c.setting] {
			i = k
		}
	}
	i = (i + dir + len(c.values)) % len(c.values)
	s := l.settings
	if c.values[i] == "" {
		s.set -= {c.setting}
		s.value[c.setting] = ""
	} else {
		s.set += {c.setting}
		s.value[c.setting] = c.values[i]
	}
	dirpath, ok := core.disc_dir(l.discs[l.sel].id, context.temp_allocator)
	if !ok || !core.settings_save(core.disc_path(dirpath, .Settings, context.temp_allocator), s) {
		launcher_toast(l, "Cannot save the setting (see the terminal).")
		return
	}
	l.settings = s
}

// What the settings screen shows for choice c, and whether the environment
// sets it.
launcher_setting_text :: proc(l: ^Launcher, c: Setting_Choice) -> (text: string, locked: bool) {
	names := core.SETTING_NAMES
	value, from := core.settings_resolve(l.settings, l.global)
	v := value[c.setting]
	shown := v
	for cv, k in c.values {
		if cv == v {
			shown = c.names[k]
		}
	}
	switch from[c.setting] {
	case .Env:
		return fmt.tprintf("%s (set by %s)", shown, core.env_name(names[c.setting])), true
	case .Global:
		return fmt.tprintf("%s (all discs)", shown), false
	case .Disc, .Default:
	}
	return shown, false
}

// Colors, 0xRRGGBB.
@(private = "file")
Color :: enum u32 {
	Back      = 0x14181e,
	Text      = 0xd8d8d8,
	Dim       = 0x80868e,
	Select    = 0x2c4c70,
	Missing   = 0xd07070,
	Toast     = 0x703030,
	Thumb_Off = 0x262c34,
}

// Draw the launcher into px, an XRGB picture l.layout.w by l.layout.h.
launcher_draw :: proc(l: ^Launcher, px: []u32) {
	lo := l.layout
	if len(px) < lo.w * lo.h {
		return
	}
	fill(px, lo.w, 0, 0, lo.w, lo.h, .Back)
	m, s, line := lo.margin, lo.scale, lo.line
	chars := lo.list_w / (core.FONT_GLYPH * s)
	if len(l.discs) == 0 {
		text(px, lo, m, lo.list_y, "The library is empty.", .Text, chars)
	} else {
		d := l.discs[l.sel]
		switch l.screen {
		case .List:
			text(px, lo, m, m, fmt.tprintf("Library: %d disc%s", len(l.discs), "" if len(l.discs) == 1 else "s"), .Dim, chars)
			for i in l.top ..< min(l.top + lo.rows, len(l.discs)) {
				ry := lo.list_y + (i - l.top) * line
				if i == l.sel {
					fill(px, lo.w, m, ry - s, lo.list_w, line, .Select)
				}
				e := l.discs[i]
				name := e.info[.Title] if e.info[.Title] != "" else e.info[.Serial] if e.info[.Serial] != "" else e.id
				text(px, lo, m + s, ry, name, .Missing if e.missing else .Text, chars - 1)
			}
			text(px, lo, m, lo.footer_y, "Enter/A play  Tab/X settings  Del/Y remove a missing disc", .Dim, lo.w / (core.FONT_GLYPH * s) - 2)
		case .Settings:
			text(px, lo, m, m, fmt.tprintf("Settings: %s", d.info[.Title] if d.info[.Title] != "" else d.id), .Dim, chars)
			label_w := 16
			for c, i in launcher_choices(l) {
				ry := lo.list_y + i * line
				if i == l.row {
					fill(px, lo.w, m, ry - s, lo.list_w, line, .Select)
				}
				t, locked := launcher_setting_text(l, c)
				text(px, lo, m + s, ry, c.label, .Text, min(label_w, chars - 1))
				text(px, lo, m + s + label_w * core.FONT_GLYPH * s, ry, t, .Dim if locked else .Text, chars - 1 - label_w)
			}
			text(px, lo, m, lo.footer_y, "Left/Right change  Enter/Start play  Esc/B back", .Dim, lo.w / (core.FONT_GLYPH * s) - 2)
		}
		draw_details(l, px, d)
	}
	if l.toast != "" {
		ty := lo.footer_y - line - s
		fill(px, lo.w, 0, ty - s, lo.w, line + s, .Toast)
		text(px, lo, m, ty, l.toast, .Text, lo.w / (core.FONT_GLYPH * s) - 2)
	}
}

// The details panel: the thumbnail, then what the library knows of disc d.
@(private = "file")
draw_details :: proc(l: ^Launcher, px: []u32, d: Library_Disc) {
	lo := l.layout
	s, x0, top := lo.scale, lo.panel_x, lo.list_y
	if x0 < lo.margin {
		return
	}
	tw, th := core.THUMB_W * s, core.THUMB_H * s
	if l.thumb == nil {
		fill(px, lo.w, x0, top, tw, th, .Thumb_Off)
	} else {
		for py in 0 ..< min(th, lo.h - top) {
			row := (py / s) * core.THUMB_W
			for qx in 0 ..< tw {
				o := (row + qx / s) * 3
				px[(top + py) * lo.w + x0 + qx] = u32(l.thumb[o]) << 16 | u32(l.thumb[o + 1]) << 8 | u32(l.thumb[o + 2])
			}
		}
	}
	chars := tw / (core.FONT_GLYPH * s)
	lines := [?]string {
		d.info[.Title],
		fmt.tprintf("%s  %s", d.info[.System], d.info[.Serial] if d.info[.Serial] != "" else d.id),
		compat_text(d.compat),
		"missing" if d.missing else "",
	}
	ly := top + th + lo.line
	for t in lines {
		if t != "" {
			text(px, lo, x0, ly, t, .Missing if t == "missing" else .Text, chars)
			ly += lo.line
		}
	}
}

// One line for a compat.tsv row: its result and how far the run got.
@(private = "file")
compat_text :: proc(r: Row) -> string {
	if r[.Result] == "" {
		return "compat: not run"
	}
	if r[.Frames] == "" {
		return fmt.tprintf("compat: %s", r[.Result])
	}
	return fmt.tprintf("compat: %s at frame %s", r[.Result], r[.Frames])
}

// Draw str at (x, y), at most max_chars characters, each byte outside
// printable ASCII taking its place and drawing nothing.
@(private = "file")
text :: proc(px: []u32, lo: Layout, x, ty: int, str: string, c: Color, max_chars: int) {
	step := core.FONT_GLYPH * lo.scale
	for i in 0 ..< min(len(str), max(max_chars, 0)) {
		core.font_glyph(px, lo.w, str[i], x + i * step, ty, u32(c), lo.scale)
	}
}

// Fill the rectangle (x, y, w, h) of a picture stride pixels wide, clipped.
@(private = "file")
fill :: proc(px: []u32, stride, x, y, w, h: int, c: Color) {
	rows := len(px) / stride
	for ry in max(y, 0) ..< min(y + h, rows) {
		for rx in max(x, 0) ..< min(x + w, stride) {
			px[ry * stride + rx] = u32(c)
		}
	}
}
