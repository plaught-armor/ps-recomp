// Draw levels for a GPU backend's queue (not a PS1 feature). The GPU draws a
// run of primitives in one call without ordering a pixel's read of the
// target after another primitive's write in the same call, so each queued
// primitive is given a level: the backend draws a level in one call, in
// queue order, and makes each level wait for those before. Overlap is judged
// in 8x8 VRAM cells.
package psx_render

import "base:intrinsics"

// Draw levels a queue may take; the backend submits when the top is reached.
@(private)
LEVELS :: 255

// The highest draw levels of one VRAM cell's queued primitives: drawing
// there, reading it back, touching the ghost layer, and touching it by
// fading (whose order counts; a solid pixel only hides ghosts behind it,
// which any order does alike). 0 is none.
//
// A primitive draws at the level after the last one it must follow (it
// reads what that one drew, draws over what it read, or both touch the
// ghost layer where order counts) and at least at the level of the last
// that drew where it draws. Each level is then one draw call with no wait
// inside, in queue order, and levels wait for those before.
@(private)
Level :: struct {
	written, read, ghost, fade: u8,
}

@(private)
levels: struct {
	// Each cell's levels and the rows of cells holding any (bit y / 8).
	cells:  [VRAM_H / 8][VRAM_W / 8]Level,
	rows:   u64,
	// The highest level taken, the lowest the next may take (raised past
	// all taken where depth_on changes, so a level has one) and each
	// level's depth_on.
	top:    u8,
	floor:  u8,
	depth:  [LEVELS + 1]bool,
	// Levels holding primitives that write depth: each lays its depths
	// down first (the backend clears them as it draws).
	z:      [LEVELS + 1]bool,
	// A group's cells as Level has them, held until it ends to be taken
	// at its highest level, so its primitives never wait for each other;
	// the rows they touch (bit y / 8).
	held_written, held_read, held_ghost, held_fade: Cells,
	held_rows:  u64,
	held_level: u8,
	group:  bool,
	// Cells holding ghosts since the last flush.
	ghost_live: Cells,
	// The backend orders a pixel's primitives itself (vk_target.odin's
	// pixel interlock): a primitive takes the lowest level it may, levels
	// split only where depth_on changes, and no cell is marked.
	single: bool,
}

// How a primitive over the VRAM area x, y, w x h with flags f, fading
// possibly (fade), meets the target: its pixels go to the ghost layer
// (ghosts), it reads them back (reader), it touches the ghost layer (acc).
@(private)
level_kinds :: proc(f: Gpu_Flags, fade: bool, x, y, w, h: i32) -> (ghosts, reader, acc: bool) {
	// A ghost's pixels go to the ghost layer: the picture's own are read
	// only to blend.
	ghosts = fade && .Flat not_in f && .See_Direct not_in f
	reader = .Semi in f || .Check_Mask in f || fade && !ghosts
	// Takers: a solid pixel nearer than a ghost, or any pixel without depth
	// drawn over one before the flush, spends it.
	acc = fade && (.Flat in f || .See_Direct not_in f) || .See_Active in f && (.Depth in f || .See_Direct not_in f) && cells_hit(&levels.ghost_live, x, y, w, h)
	return
}

// Whether the queue must be submitted before another primitive takes a
// level: below LEVELS, no level + 1 overflows.
@(private)
levels_full :: #force_inline proc() -> bool {
	return levels.top == LEVELS
}

// Give a primitive over the VRAM area x, y, w x h (wrapping), as level_kinds
// has it, its level, with others queued before it (queued) or not.
@(private)
level_place :: proc(x, y, w, h: i32, ghosts, reader, acc, fade, depth_on, z_write, queued: bool) -> u8 {
	l := &levels
	if queued && l.depth[l.top] != depth_on {
		l.floor = l.top + 1
	}
	if l.single {
		lv := l.floor
		l.top = lv
		l.depth[lv] = depth_on
		if z_write {l.z[lv] = true}
		if ghosts {
			cells_add(&l.ghost_live, x, y, w, h)
		}
		return lv
	}
	lv := level_need(x, y, w, h, reader, acc, fade, l.floor)
	l.top = max(l.top, lv)
	l.depth[lv] = depth_on
	if z_write {l.z[lv] = true}
	if l.group {
		l.held_rows |= cell_rows(y, h)
		l.held_level = max(l.held_level, lv)
		cells_add(&l.held_written, x, y, w, h)
		if reader {cells_add(&l.held_read, x, y, w, h)}
		if acc {cells_add(&l.held_ghost, x, y, w, h)}
		if acc && fade {cells_add(&l.held_fade, x, y, w, h)}
	} else {
		level_mark(x, y, w, h, reader, acc, fade, lv)
	}
	if ghosts {
		cells_add(&l.ghost_live, x, y, w, h)
	}
	return lv
}

// Empty the levels once the queue is drawn.
@(private)
levels_reset :: proc() #no_bounds_check {
	l := &levels
	rows := l.rows
	for rows != 0 {
		i := intrinsics.count_trailing_zeros(rows)
		rows &= rows - 1
		l.cells[i] = {}
	}
	l.rows, l.top, l.floor = 0, 0, 1
	level_held_drop(false)
}

// Start or end a group: primitives covering distinct pixels, which a
// segment never needs cutting between.
@(private)
level_group :: proc(on: bool) {
	if !on && levels.group {
		level_held_drop(true)
	}
	levels.group = on
}

// Empty the group's held cells, giving them its level first when `take`.
@(private = "file")
level_held_drop :: #force_inline proc(take: bool) #no_bounds_check {
	l := &levels
	rows := l.held_rows
	if take {
		l.rows |= rows
	}
	for rows != 0 {
		i := intrinsics.count_trailing_zeros(rows)
		rows &= rows - 1
		if take {
			lv := l.held_level
			row := &l.cells[i]
			level_take(row, l.held_written[i], lv, offset_of(Level, written))
			level_take(row, l.held_read[i], lv, offset_of(Level, read))
			level_take(row, l.held_ghost[i], lv, offset_of(Level, ghost))
			level_take(row, l.held_fade[i], lv, offset_of(Level, fade))
		}
		l.held_written[i], l.held_read[i], l.held_ghost[i], l.held_fade[i] = 0, 0, 0, 0
	}
	l.held_rows, l.held_level = 0, 0
}

// Raise the level at byte `field` of the row's cells set in `span` to lv.
@(private = "file")
level_take :: #force_inline proc(row: ^[VRAM_W / 8]Level, span: u128, lv: u8, field: uintptr) #no_bounds_check {
	span := span
	for span != 0 {
		j := intrinsics.count_trailing_zeros(span)
		span &= span - 1
		b := (^u8)(uintptr(&row[j]) + field)
		b^ = max(b^, lv)
	}
}

// The level a primitive over the VRAM area x, y, w x h (wrapping) takes:
// reading it back (reader), touching the ghost layer (acc), by fading
// (fade); at least floor.
@(private = "file")
level_need :: proc(x, y, w, h: i32, reader, acc, fade: bool, floor: u8) -> u8 #no_bounds_check {
	lv := floor
	rows := h > VRAM_H - 8 ? VRAM_H / 8 : ((y + h - 1) >> 3) - (y >> 3) + 1
	cols := w > VRAM_W - 8 ? VRAM_W / 8 : ((x + w - 1) >> 3) - (x >> 3) + 1
	for i in 0 ..< rows {
		row := &levels.cells[((y >> 3) + i) & (VRAM_H / 8 - 1)]
		for j in 0 ..< cols {
			c := row[((x >> 3) + j) & (VRAM_W / 8 - 1)]
			lv = max(lv, c.written, c.read + 1)
			if reader {lv = max(lv, c.written + 1)}
			if acc {lv = max(lv, fade ? c.ghost + 1 : c.fade + 1)}
		}
	}
	return lv
}

// Raise the levels of the VRAM area x, y, w x h (wrapping) to lv, as
// level_need takes them.
@(private = "file")
level_mark :: proc(x, y, w, h: i32, reader, acc, fade: bool, lv: u8) #no_bounds_check {
	levels.rows |= cell_rows(y, h)
	rows := h > VRAM_H - 8 ? VRAM_H / 8 : ((y + h - 1) >> 3) - (y >> 3) + 1
	cols := w > VRAM_W - 8 ? VRAM_W / 8 : ((x + w - 1) >> 3) - (x >> 3) + 1
	for i in 0 ..< rows {
		row := &levels.cells[((y >> 3) + i) & (VRAM_H / 8 - 1)]
		for j in 0 ..< cols {
			c := &row[((x >> 3) + j) & (VRAM_W / 8 - 1)]
			c.written = max(c.written, lv)
			if reader {c.read = max(c.read, lv)}
			if acc {c.ghost = max(c.ghost, lv)}
			if acc && fade {c.fade = max(c.fade, lv)}
		}
	}
}
