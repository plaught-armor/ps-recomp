// Host window: presents the GS read circuit each vblank and paces the game
// to 60 Hz. platform_init sets kernel.vblank_hook, so a game's main calls it
// once after ps2.init and before running the ELF.
package ps2_host

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl2"
import "ps:core"
import cpu "../cpu"
import gs "../gs"
import iop "../iop"
import kernel "../kernel"
import mem "../mem"
import vu "../vu"

@(private)
win: ^sdl.Window
@(private)
ren: ^sdl.Renderer
@(private)
tex: ^sdl.Texture
@(private)
hw: bool // the Vulkan GS draws and presents
@(private)
last: time.Tick
@(private)
pace := 60 // frames a second; 0 for unpaced
// Presented frames: vblanks whose GS read circuit showed a picture, so a
// game's boot vblanks with the display off do not count. PRESS, SHOT,
// SNAPTEST, RBTEST and DUMP all count these, unlike psx/host, whose PRESS
// counts every vblank (cpu.presents).
@(private)
frame: int
@(private)
shots: [dynamic]int // SHOT=<frame>,...: write shot_<frame>.ppm at each, ascending
@(private)
next_shot: int // index into shots
// Every vblank, unlike frame (presented frames): netplay's frame count.
@(private)
vblank: int
@(private)
SHOT_WARMUP :: 10 // frames drawn before a headless shot, to fill both buffers
// PRESS=Start@600,Cross@900: scripted taps, held for PRESS_FRAMES, so a
// headless run can get past the title screen. A ":n" suffix (Start@900:2)
// presses on player n instead of player 1, a "+n" suffix (Left@900+120)
// holds for n frames (core.input_script_load). Frames are presented frames
// (frame). A bad entry stops platform_init.
@(private)
PRESS_FRAMES :: 6

// Open the window (titled title) or set up a headless run, and take over the
// vblank. Returns false, after saying why, when the host cannot run.
platform_init :: proc(title: cstring) -> bool {
	// Map Switch-style pads by position (south face button = cross), not label.
	sdl.SetHint(sdl.HINT_GAMECONTROLLER_USE_BUTTON_LABELS, "0")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS4_RUMBLE, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS5_RUMBLE, "1")
	// HEADLESS=1: no window, no 60 Hz pacing, no controllers.
	core.headless_init()
	stats = core.env("STATS") == "1"
	// PACE=<hz> paces a headless run too (netplay tests; a different
	// rate on each peer stands in for clock drift).
	if core.headless {pace = strconv.parse_int(core.env("PACE")) or_else 0}
	if !core.dump_init() {return false}
	if v, ok := core.env_lookup("SNAPTEST"); ok {
		a, _, b := strings.partition(v, ",")
		snaptest = {strconv.parse_int(a) or_else 0, strconv.parse_int(b) or_else 0}
	}
	if v, ok := core.env_lookup("RBTEST"); ok {
		for f, i in strings.split(v, ",", context.temp_allocator) {
			if i < len(rbtest) {rbtest[i] = strconv.parse_int(f) or_else 0}
		}
	}
	// The frame count drives PRESS and SHOT, so it rewinds with the game.
	core.snap_add(&frame)
	core.snap_add(&next_shot)
	core.snap_add(&vblank)
	// Headless runs take input from PRESS only, so they replay exactly.
	subsystems := sdl.InitFlags{.VIDEO, .AUDIO, .GAMECONTROLLER}
	if core.headless {subsystems -= {.GAMECONTROLLER}}
	if sdl.Init(subsystems) != 0 {
		fmt.eprintln("sdl:", sdl.GetError())
		return false
	}
	// SW=1: the software GS and SDL's renderer; otherwise the Vulkan GS
	// at SCALE times the native resolution (default 1 headless, 3 in a
	// window).
	hw = core.env("SW") != "1"
	scale := core.headless ? 1 : 3
	if v, ok := strconv.parse_int(core.env("SCALE")); ok && v >= 1 && v <= 8 {scale = v}
	flags := sdl.WindowFlags{.RESIZABLE}
	if hw && !core.headless {flags += {.VULKAN}}
	win = sdl.CreateWindow(title, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED,
		gs.DISP_W * 2, 480 * 2, flags)
	if hw {
		gs.hw_init(core.headless ? nil : win, u32(scale))
	} else {
		ren = sdl.CreateRenderer(win, -1, {.ACCELERATED})
		tex = sdl.CreateTexture(ren, .ABGR8888, .STREAMING, gs.DISP_W, gs.DISP_H)
	}
	gs.snap_regions(core.snap_add_bytes)
	if hw {append(&core.snap_hooks, core.Snap_Hook{gs.hw_snap_save, gs.hw_snap_load})}
	// Also loads community mappings for pads SDL does not know
	// (gamecontrollerdb.txt).
	core.input_init(false)
	core.input_bind_standard()
	core.input_bind_keys_standard()
	if v, ok := strconv.parse_int(core.env("PLAYERS")); ok {
		forced_players = clamp(v, 1, iop.MAX_PLAYERS)
		for i in 0 ..< forced_players {iop.pads[i].connected = true}
	}
	if !net_init() {return false}
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer
	kernel.vblank_hook = vblank_frame
	audio_init(core.headless)
	last = time.tick_now()
	if v, ok := core.env_lookup("SHOT"); ok {
		for item in strings.split(v, ",", context.temp_allocator) {
			if f, ok2 := strconv.parse_int(item); ok2 && f > 0 {append(&shots, f)}
		}
		slice.sort(shots[:])
	}
	shot_skip_update()
	if !core.input_script_load(PRESS_FRAMES) {return false}
	return true
}

// Exit, after printing the fallback counters when built with them, and
// the VU1 program counters when VU1_STATS is set.
@(private)
quit :: proc(code: int) -> ! {
	when cpu.FALLBACK_COUNT {cpu.fallback_print()}
	vu.vu1_stats_print()
	os.exit(code)
}

@(private)
vblank_frame :: proc() {
	// Nothing outlives a frame in the temp arena; without this it grows
	// with every DMA transfer gathered into it.
	free_all(context.temp_allocator)
	vblank += 1
	ev: sdl.Event
	for sdl.PollEvent(&ev) {
		if ev.type == .QUIT {quit(0)}
		// Hotplug; also fires at startup for pads already plugged in.
		core.input_event(ev)
	}
	input_poll()
	// A rerun after a rollback: emulated as usual, but neither shown nor
	// heard, and unpaced.
	rerun := core.net_resimulating()
	if core.net_hash_due() {
		core.net_hash(xxhash.XXH3_64_with_seed(iop.iop_ram, xxhash.XXH3_64_default(mem.ram)))
	}
	audio_frame(!rerun)
	gs.skip_present = rerun
	w, h := gs.scanout()
	if w > 0 && h > 0 {
		if !core.headless && !hw && !rerun {
			sdl.UpdateTexture(tex, nil, &gs.screen, gs.DISP_W * 4)
			src := sdl.Rect{0, 0, i32(w), i32(h)}
			sdl.RenderClear(ren)
			sdl.RenderCopy(ren, tex, &src, nil)
			sdl.RenderPresent(ren)
		}
		frame += 1
		for next_shot < len(shots) && frame >= shots[next_shot] {
			if frame == shots[next_shot] {
				name := fmt.tprintf("shot_%d.ppm", frame)
				if hw {
					px, sw, sh := gs.hw_screen()
					write_ppm(name, px, sw, sw, sh)
				} else {
					write_ppm(name, gs.screen[:], gs.DISP_W, w, h)
				}
				fmt.eprintfln("shot: frame %d", frame)
			}
			next_shot += 1
			// A headless run with shots is done once the last one is taken.
			if core.headless && next_shot == len(shots) && (snaptest[1] == 0 || snaptest_loaded) {
				// A netplay peer may still need this host's input to get here.
				if !net_on {quit(0)}
				if quit_at == 0 {quit_at = vblank + NET_LINGER}
			}
		}
		shot_skip_update()
		snaptest_frame()
		if rbtest[1] > 0 {rbtest_frame()}
		if stats && frame % STATS_FRAMES == 0 {print_stats()}
		// DUMP=<dir>: the guest clock and EE and IOP memory per presented
		// frame (with DUMP_HASH=1, their hashes in <dir>/hashes.tsv, so two
		// runs can be diffed for the first frame they diverge).
		if core.dump_due(u64(frame)) {
			cyc := cpu.state.cycles
			core.dump_put("cyc", "bin", u64(frame), ([^]u8)(&cyc)[:size_of(cyc)])
			core.dump_put("ram", "bin", u64(frame), mem.ram)
			core.dump_put("iop", "bin", u64(frame), iop.iop_ram)
		}
	}
	if net_on && vblank % 600 == 0 {print_net()}
	if quit_at > 0 && vblank >= quit_at {
		print_net()
		quit(0)
	}
	if pace == 0 || rerun {return}
	// Netplay time sync stretches the frame while this host is ahead.
	length := time.Second / time.Duration(pace)
	length += time.Duration(f64(length) * f64(core.net_stretch()))
	// An absolute deadline: sleep overshoot must not add up, or the game runs
	// under 60 Hz and the sound queue drains. Far behind, start again from now.
	now := time.tick_now()
	last = time.tick_add(last, length)
	if time.tick_diff(last, now) > length {last = now}
	if d := time.tick_diff(now, last); d > 0 {time.sleep(d)}
}

// STATS=1: every STATS_FRAMES presented frames, host frame rate and the
// share of guest time the kernel skipped with every thread waiting.
@(private)
stats: bool
@(private)
STATS_FRAMES :: 300

@(private)
print_stats :: proc() {
	@(static) t0: time.Tick
	@(static) cyc0, idle0, tsc0: u64
	@(static) prof0: [cpu.Prof]u64
	now := time.tick_now()
	tsc := cpu.prof_start()
	if t0 != {} {
		secs := time.duration_seconds(time.tick_diff(t0, now))
		cyc, idl := cpu.state.cycles - cyc0, kernel.idle_cycles - idle0
		fmt.eprintf("stats: frame %d  %.1f fps  idle %.0f%%", frame,
			f64(STATS_FRAMES) / secs, 100 * f64(idl) / f64(max(cyc, 1)))
		for p in cpu.Prof {
			fmt.eprintf("  %v %.0f%%", p, 100 * f64(cpu.prof[p] - prof0[p]) / f64(max(tsc - tsc0, 1)))
		}
		a := core.audio_take_stats()
		fmt.eprintfln("  audio dry %d dropped %d low %.0f ms", a.dry, a.dropped, a.low_ms)
	}
	t0, cyc0, idle0, tsc0, prof0 = now, cpu.state.cycles, kernel.idle_cycles, tsc, cpu.prof
}

// SNAPTEST=<save>,<load>: save state at presented frame <save>, load it
// once at frame <load>. The replayed frames must match the first pass: with
// DUMP_HASH, every frame hashes the same both times.
@(private)
snaptest: [2]int
@(private)
snaptest_loaded: bool
@(private)
snaptest_snap: core.Snapshot
@(private)
snaptest_t: time.Tick

@(private)
snaptest_frame :: proc() {
	if snaptest_t != {} {
		fmt.eprintfln("snap: %v took %.2f ms, %d MiB", snaptest_loaded ? "load" : "save",
			time.duration_milliseconds(time.tick_since(snaptest_t)), len(snaptest_snap.data) >> 20)
		snaptest_t = {}
	}
	op: core.Snap_Op
	if frame == snaptest[0] && !snaptest_loaded {op = .Save}
	if frame == snaptest[1] && !snaptest_loaded {op = .Load; snaptest_loaded = true}
	if op != .None {
		core.snap_op, core.snap_target = op, &snaptest_snap
		snaptest_t = time.tick_now()
	}
}

// RBTEST=<start>,<every>,<back>: from presented frame <start>, commit a
// rollback record every frame, and every <every> frames rewind <back>
// frames (once per frame reached). The resimulated frames must match a
// plain run: with DUMP_HASH, the set of hash lines is the same.
@(private)
rbtest: [3]int
@(private)
rbtest_done: int // host side: the last frame rewound from

@(private)
rbtest_frame :: proc() {
	if frame < rbtest[0] {return}
	core.snap_op = .Commit
	if frame > rbtest_done && (frame - rbtest[0]) % rbtest[1] == 0 && core.rb_frames() > rbtest[2] {
		rbtest_done = frame
		core.snap_op, core.rb_back = .Rewind, rbtest[2]
	}
	if frame % 600 == 0 {
		st := core.rb_stats()
		fmt.eprintfln("rb: %d commits, avg %.3f ms (%.1f pages, %d KiB whole), worst %.3f ms", st.commits,
			time.duration_milliseconds(st.total) / f64(max(st.commits, 1)), f64(st.pages) / f64(max(st.commits, 1)),
			st.small >> 10, time.duration_milliseconds(st.worst))
	}
}

// Headless runs skip rasterizing until shortly before the next shot.
@(private)
shot_skip_update :: proc() {
	gs.skip_draw = core.headless && (next_shot >= len(shots) || frame < shots[next_shot] - SHOT_WARMUP)
}

@(private)
write_ppm :: proc(path: string, px: []u32, stride, w, h: int) {
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, fmt.tprintf("P6\n%d %d\n255\n", w, h))
	for y in 0 ..< h {
		for x in 0 ..< w {
			c := px[y * stride + x]
			append(&buf, u8(c), u8(c >> 8), u8(c >> 16))
		}
	}
	_ = os.write_entire_file(path, buf[:])
	fmt.eprintln("video: wrote", path)
}
