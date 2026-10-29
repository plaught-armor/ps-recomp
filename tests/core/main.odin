// Coroutine, snapshot and rollback test for core, run on every target in CI.
//
// main ping-pongs with a coroutine (registers and floats must survive the
// switch), then runs a "game" coroutine under snap_run: it saves at frame
// 10, loads that at 30, then commits each frame and rewinds 3 at frame 40.
// A replayed frame must hash the same as the first time through.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "ps:core"

frame: int
ram: []u8
heap_val: ^[64]u64
snap: core.Snapshot
sums: map[int]u64
loaded: bool
rewound: int // frame rewound from
other: ^core.Coroutine

// Floats live across switches: xmm6-xmm15 and MXCSR must survive.
pingpong :: proc(_: rawptr) {
	x := 1.5
	for i := 0; ; i += 1 {
		x = math.sqrt(x * x + f64(i))
		core.co_switch(&core.co_main_thread)
	}
}

game :: proc(_: rawptr) {
	local := 0
	acc := 0.25
	for {
		frame += 1
		local += 1
		acc += 0.5
		assert(local == frame, "stack not restored")
		assert(acc == 0.25 + 0.5 * f64(frame), "float not restored")
		ram[(frame % 32) * 4096] += 1
		heap_val[frame % 64] = u64(frame)
		s := sum()
		if rewound != 0 && frame == 38 {fmt.println("ok resumed at", frame)}
		if v, ok := sums[frame]; ok {assert(v == s, "replayed frame differs")} else {sums[frame] = s}
		switch {
		case frame == 10: core.snap_op, core.snap_target = .Save, &snap
		case frame == 30 && !loaded: core.snap_op = .Load; loaded = true
		case frame == 40 && rewound == 0: core.snap_op, core.rb_back = .Rewind, 3; rewound = frame
		case frame == 60:
			fmt.println("ok snapshot", len(snap.data), "bytes")
			assert(rewound == 40, "no rewind")
			st := core.rb_stats()
			fmt.println("ok rollback from", rewound, "commits", st.commits, "pages", st.pages)
			os.exit(0)
		case frame > 30: core.snap_op = .Commit
		case: core.snap_op = .None
		}
		core.snap_yield()
	}
}

sum :: proc() -> (s: u64) {
	for b in ram {s += u64(b)}
	for v in heap_val {s += v}
	return s + u64(frame)
}

main :: proc() {
	// Plain switches first.
	other = core.co_create(pingpong, nil)
	y := 2.0
	for _ in 0 ..< 1000 {
		y = y * 1.0001 + 0.5
		core.co_switch(other)
	}
	fmt.println("ok pingpong", y > 2)
	// The second write replaces an existing file, which rename must allow.
	atomic_path :: "atomic_test.bin"
	for data in ([2]string{"first", "second!"}) {
		err := core.write_file_atomic(atomic_path, transmute([]u8)data)
		back, _ := os.read_entire_file(atomic_path, context.temp_allocator)
		if err != nil || string(back) != data || os.exists(atomic_path + core.ATOMIC_TMP) {
			fmt.eprintln("FAIL write_file_atomic", data, err)
			_ = os.remove(atomic_path)
			_ = os.remove(atomic_path + core.ATOMIC_TMP)
			os.exit(1)
		}
	}
	_ = os.remove(atomic_path)
	fmt.println("ok write_file_atomic")
	test_load_elf()
	core.snap_init(1 << 20)
	core.snap_add(&frame)
	ram = core.snap_area(32 * 4096)
	context.allocator = core.emu_allocator()
	core.co_allocator = context.allocator
	heap_val = new([64]u64)
	sums = make(map[int]u64, core.host_allocator)
	core.snap_run(core.co_create(game, nil))
}
