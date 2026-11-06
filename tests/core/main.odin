// Coroutine, snapshot and rollback test for core, run on every target in CI.
//
// main ping-pongs with a coroutine (registers and floats must survive the
// switch), then runs a "game" coroutine under snap_run: it saves at frame
// 10, loads that at 30, then commits each frame and rewinds 3 at frame 40.
// A replayed frame must hash the same as the first time through. A press
// script with conditions on `ram` runs each frame (press_frame) across the
// load and the rewind: a replayed frame's script state must equal the
// first time through too.
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

// The press script's state after a frame, and player 1's input from it.
Press_State :: struct {
	watch:   core.Script_Watch,
	at:      [4]u64,
	buttons: core.Buttons,
	left:    [2]f32,
	started: u64,
	fail:    string,
}
presses: map[int]Press_State

// A wait from 12 (met at 16, moving the rest 4 later), then a repeat from
// 18 every 3 pressing LUp until frame 39 (moving the rest 21 later), Start
// at 40, and a wait from 50 that times out at 55: the load at 30 replays the
// first wait and the repeat's presses, the rewind at 40 the repeat's end.
PRESS :: "Cross@12?u8[80000010]==1~10,LUp@14*3?u8[80000011]==0~30,Start@15,Circle@25?u16[80000012]==1~5"

// Run the press script's frame, with its RAM bytes set by the frame.
press_frame :: proc() {
	ram[0x10] = frame >= 16 ? 1 : 0
	ram[0x11] = frame >= 39 ? 0 : 2
	core.input_script_frame(u64(frame), ram)
	p := core.input_poll(u64(frame))[0]
	st := Press_State {
		watch   = core.input.watch,
		buttons = p.buttons,
		left    = p.left,
		started = core.input.script_started,
		fail    = core.input_watch_failed(),
	}
	for s, i in core.input.script {st.at[i] = s.at}
	if v, ok := presses[frame]; ok {
		if v != st {
			fmt.eprintln("FAIL press script replayed frame", frame, "as", st, "first", v)
			os.exit(1)
		}
	} else {presses[frame] = st}
}

// The press script's run checked at a few frames, once at frame 60.
press_check :: proc() {
	ok := presses[15].buttons == {} && presses[16].buttons == {.Cross} && presses[17].buttons == {.Cross} && presses[18].buttons == {}
	ok &&= presses[18].left == {0, -1} && presses[20].left == {} && presses[37].left == {0, -1} && presses[39].left == {}
	ok &&= presses[38].watch.repeats == 7 && presses[40].buttons == {.Start} && presses[40].watch.gate == 3
	ok &&= presses[54].fail == "" && presses[55].fail != ""
	if !ok {
		fmt.eprintln("FAIL press script run:", presses[15], presses[16], presses[38], presses[40], presses[55])
		os.exit(1)
	}
	fmt.println("ok press script across load and rewind")
}

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
		press_frame()
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
			press_check()
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
	if len(os.args) == 2 && os.args[1] == "heap-full" {heap_full_child()}
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
	test_audio_step()
	test_font()
	test_thumb()
	test_record_mods()
	test_hello()
	test_peer_hash()
	test_heap_full()
	core.snap_init(1 << 20)
	core.snap_add(&frame)
	ram = core.snap_area(32 * 4096)
	os.set_env(core.env_name("PRESS"), PRESS)
	if !core.input_script_load(2, u32(len(ram))) || len(core.input.script) != 4 {
		fmt.eprintln("FAIL press script load")
		os.exit(1)
	}
	presses = make(map[int]Press_State, core.host_allocator)
	context.allocator = core.emu_allocator()
	core.co_allocator = context.allocator
	heap_val = new([64]u64)
	sums = make(map[int]u64, core.host_allocator)
	core.snap_run(core.co_create(game, nil))
}
