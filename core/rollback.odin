// Rollback: a record of each of the last RB_FRAMES frames, cheap enough to
// take every frame, and a rewind to any of them (the base for rollback
// netplay). Same rules as save states (snap.odin): records live in this
// process, are taken and restored on the host main thread, and the snapshot
// hooks keep GPU-side copies (one per ring slot).
//
// Large memory (snap_area memory and the emulated heap) has its written
// pages tracked by the OS (rollback_<os>.odin: rb_start, and rb_scan, which
// lists the pages written since the last scan). A shadow copy holds that
// memory as of the last commit:
// - a commit appends the shadow's contents of each written page to the
//   frame's undo log, then copies the page into the shadow;
// - a rewind puts the pages written since the last commit back from the
//   shadow, then applies undo logs newest first to both.
// The small regions and live stacks are copied whole into every record.
// The scan's cost grows with the tracked size: keep areas and heap small.
package core

import "core:time"

RB_FRAMES :: 8

// Set with snap_op = .Rewind; 1 is the frame of the last commit.
rb_back: int

// Ids for the snapshot hooks, apart from save-state ids: a hook sees an id
// at or above it for a rollback slot, below it for a save state.
RB_HOOK_ID :: 1 << 20

@(private)
PAGE :: 4096

@(private)
Rb_Area :: struct {
	mem, shadow: []u8,
}

@(private)
Rb_Page :: struct {
	area, off: u32,
}

@(private)
Rb_Record :: struct {
	small: [dynamic]u8, // regions, then live stacks
	pages: [dynamic]Rb_Page, // written during this frame, with ...
	undo:  [dynamic]u8, // ... their contents as of the previous commit
}

@(private)
Rb_Commit :: struct {
	rec:  ^Rb_Record,
	area: u32,
	log:  bool,
}

@(private)
rb: struct {
	on:      bool,
	areas:   [dynamic]Rb_Area,
	records: [RB_FRAMES]Rb_Record,
	head:    int, // newest record
	count:   int, // records held
	stats:   Rb_Stats,
}

// Host time spent in commits, for measuring.
Rb_Stats :: struct {
	commits, pages: int,
	small:          int, // bytes copied whole per commit
	total, worst:   time.Duration,
}

rb_stats :: proc() -> Rb_Stats {
	return rb.stats
}

// Frames that can be rewound to now (rb_back < rb_frames()).
rb_frames :: proc() -> int {
	return rb.count
}

// Record the state at this vblank as the newest frame.
@(private)
rb_commit :: proc() {
	if !rb.on && !rb_start() {panic(RB_NEED)}
	t := time.tick_now()
	rb.head = (rb.head + 1) % RB_FRAMES
	rec := &rb.records[rb.head]
	clear(&rec.pages)
	clear(&rec.undo)
	// The oldest record's undo log is never applied, so the first commit
	// (taking every page written since rb_start) keeps none.
	for a, i in rb.areas {
		c := Rb_Commit{rec, u32(i), rb.count > 0}
		rb_scan(a, proc(a: Rb_Area, off: int, data: rawptr) {
			c := (^Rb_Commit)(data)
			if c.log {
				append(&c.rec.pages, Rb_Page{c.area, u32(off)})
				append(&c.rec.undo, ..a.shadow[off:][:PAGE])
			}
			copy(a.shadow[off:][:PAGE], a.mem[off:][:PAGE])
		}, &c)
	}
	clear(&rec.small)
	put_regions(&rec.small)
	co_stacks_put(&rec.small)
	rb.count = min(rb.count + 1, RB_FRAMES)
	for h in snap_hooks {h.save(RB_HOOK_ID + rb.head)}
	d := time.tick_since(t)
	rb.stats.commits += 1
	rb.stats.pages += len(rec.pages)
	rb.stats.small = len(rec.small)
	rb.stats.total += d
	rb.stats.worst = max(rb.stats.worst, d)
}

// Go back to the state `back` commits ago (1 = the last one).
@(private)
rb_rewind :: proc(back: int) {
	assert(back >= 1 && back <= rb.count, "rollback: frame not held")
	for a in rb.areas {
		rb_scan(a, proc(a: Rb_Area, off: int, _: rawptr) {
			copy(a.mem[off:][:PAGE], a.shadow[off:][:PAGE])
		}, nil)
	}
	for _ in 1 ..< back {
		rec := &rb.records[rb.head]
		for p, i in rec.pages {
			a := rb.areas[p.area]
			old := rec.undo[i * PAGE:][:PAGE]
			copy(a.mem[p.off:][:PAGE], old)
			copy(a.shadow[p.off:][:PAGE], old)
		}
		rb.head = (rb.head + RB_FRAMES - 1) % RB_FRAMES
		rb.count -= 1
	}
	// The pages just restored match the shadow again: protect them.
	for a in rb.areas {rb_scan(a, proc(a: Rb_Area, off: int, _: rawptr) {}, nil)}
	rec := &rb.records[rb.head]
	pos := 0
	take_regions(rec.small[:], &pos)
	co_stacks_take(rec.small[:], &pos)
	assert(pos == len(rec.small), "rollback: size mismatch")
	for h in snap_hooks {h.load(RB_HOOK_ID + rb.head)}
}
