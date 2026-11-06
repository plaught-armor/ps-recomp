// Host window: presents the GS read circuit each vblank and paces the game
// to NTSC's 59.94 Hz. platform_init sets kernel.vblank_hook, so a game's
// main calls it once after ps2.init and before running the ELF.
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
pace := 60 // frames a second, at NTSC's 1000 / 1001 (59.94 Hz); 0 for unpaced
// Presented frames: vblanks whose GS read circuit showed a picture, so a
// game's boot vblanks with the display off do not count. PRESS, SNAPTEST,
// RBTEST and DUMP all count these, unlike psx/host, whose PRESS counts every
// vblank (cpu.presents).
@(private)
frame: int
// SHOT=<vblank>,...: write shot_<vblank>.ppm at each, ascending. Shots count
// vblanks, as FRAMES and the compat lit count do, so a shot at FRAMES is
// the picture lit counts.
@(private)
shots: [dynamic]int
@(private)
next_shot: int // index into shots
@(private)
SHOT_WARMUP :: 10 // vblanks the GS draws everything before a picture is read
// Every vblank, unlike frame (presented frames): netplay's frame count,
// SHOT and FRAMES.
@(private)
vblank: int
// The GS read circuit's picture size at the last vblank (0 x 0 with the
// display off), for thumb_save.
@(private)
shown: [2]int
// PRESS=Start@600,Cross@900: scripted taps, held for PRESS_FRAMES, so a
// headless run can get past the title screen. A ":n" suffix (Start@900:2)
// presses on player n instead of player 1, a "+n" suffix (Left@900+120)
// holds for n frames, and stick directions (LRight@900+60) or several names
// joined by "&" (LUp&LRight@900) push the sticks
// (core.input_script_load). Frames are presented frames
// (frame); a script's RAM conditions are checked as each is counted. A bad
// entry stops platform_init, a condition that times out the run (status 1).
@(private)
PRESS_FRAMES :: 6

// Open the window (titled title) or set up a headless run, and take over the
// vblank. Returns false, after saying why, when the host cannot run.
platform_init :: proc(title: cstring) -> bool {
	// Map Switch-style pads by position (south face button = cross), not label.
	sdl.SetHint(sdl.HINT_GAMECONTROLLER_USE_BUTTON_LABELS, "0")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS4_RUMBLE, "1")
	sdl.SetHint(sdl.HINT_JOYSTICK_HIDAPI_PS5_RUMBLE, "1")
	// HEADLESS=1: no window, no 60 Hz pacing, no controllers. FRAMES=<n>:
	// exit at vblank n. COMPAT=1: a compatibility run (core/compat).
	if !core.headless_init() {return false}
	core.compat_init("ps2", &cpu.state.cycles, cpu.CYCLES_PER_INSN, &kernel.idle_cycles)
	// PS_COMPAT_PROBE=<vblanks>: probes of input under COMPAT (probe.odin).
	if every, ok := core.compat_probe_setting(); ok {
		core.compat.probe_every = every
	} else {
		return false
	}
	// LEARN=<file>: record the code the interpreters run (core/learn.odin);
	// the IOP names its counter in iop_cpu_init.
	core.learn_open()
	core.learn_cpu(.Ee, &cpu.state.cycles, cpu.CYCLES_PER_INSN, proc(a: u32) -> u32 {return mem.rd32(a)}, mem.RAM_SIZE, false)
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
	// Headless runs take input from PRESS only, so they replay exactly, and
	// open no audio device (a runner may have none).
	subsystems := sdl.InitFlags{.VIDEO, .AUDIO, .GAMECONTROLLER}
	if core.headless {subsystems -= {.GAMECONTROLLER, .AUDIO}}
	if sdl.Init(subsystems) != 0 {
		fmt.eprintln("sdl:", sdl.GetError())
		return false
	}
	// SW=1, and every wasm build (which has no GPU GS): the software GS and
	// SDL's renderer; otherwise the Vulkan GS at SCALE times the native
	// resolution (default 1 headless, 3 in a window).
	hw = gs.HW && core.env("SW") != "1"
	scale := core.headless ? 1 : 3
	if v, ok := strconv.parse_int(core.env("SCALE")); ok && v >= 1 && v <= 8 {scale = v}
	flags := sdl.WindowFlags{.RESIZABLE}
	if hw && !core.headless {flags += {.VULKAN}}
	if core.headless {flags += {.HIDDEN}}
	win = sdl.CreateWindow(title, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED,
		gs.DISP_W * 2, 480 * 2, flags)
	if win == nil {
		fmt.eprintln("SDL_CreateWindow:", sdl.GetError())
		return false
	}
	if hw {
		if !gs.hw_init(core.headless ? nil : win, u32(scale)) {return false}
	} else {
		// No flags when windowed: SDL takes an accelerated renderer first and
		// falls back to software where none is (as psx/host's window does).
		ren = sdl.CreateRenderer(win, -1, core.headless ? {.SOFTWARE} : {})
		if ren == nil {
			fmt.eprintln("SDL_CreateRenderer:", sdl.GetError())
			return false
		}
		tex = sdl.CreateTexture(ren, .ABGR8888, .STREAMING, gs.DISP_W, gs.DISP_H)
		if tex == nil {
			fmt.eprintln("SDL_CreateTexture:", sdl.GetError())
			return false
		}
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
	// Snapshot and rollback runs draw every frame (gs.replays).
	gs.replays = snaptest != {} || rbtest[1] > 0 || net_on
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer
	// The boot chains Boot.vblank after this (ps2/boot.odin): set here
	// only, never after.
	kernel.vblank_hook = vblank_frame
	probe_init()
	audio_init(core.headless)
	last = time.tick_now()
	if v, ok := core.env_lookup("SHOT"); ok {
		for item in strings.split(v, ",", context.temp_allocator) {
			if f, ok2 := strconv.parse_int(item); ok2 && f > 0 {append(&shots, f)}
		}
		slice.sort(shots[:])
	}
	if !core.input_script_load(PRESS_FRAMES, mem.RAM_SIZE) {return false}
	return true
}

// Called by quit before the counters are printed; nil none.
quit_hook: proc()

// Exit, after printing the fallback counters when built with them, the
// VU1 program counters when VU1_STATS is set, and the unmapped access
// counts when some went unlogged.
@(private)
quit :: proc(code: int) -> ! {
	if quit_hook != nil {quit_hook()}
	if code == 0 {thumb_save()}
	when cpu.FALLBACK_COUNT {cpu.fallback_print()}
	vu.vu_stats_print()
	cpu.unmapped_print()
	cpu.learned_print()
	cpu.flat_print()
	core.learn_report()
	core.compat_report()
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
	// A compat probe's branch: emulated, and nothing else (probe.odin).
	if probe_running() {
		probe_input()
		audio_frame(vblank, false)
		gs.skip_present, gs.skip_readout = true, true
		gs.skip_wanted = core.headless && !draw_due()
		probe_frame(gs.scanout())
		return
	}
	input_poll()
	// A rerun after a rollback: emulated as usual, but neither shown nor
	// heard, and unpaced.
	rerun := core.net_resimulating()
	if core.net_hash_due() {
		core.net_hash(xxhash.XXH3_64_with_seed(iop.iop_hle, xxhash.XXH3_64_with_seed(iop.iop_ram, xxhash.XXH3_64_default(mem.ram))))
	}
	audio_frame(vblank, !rerun)
	gs.skip_present = rerun
	gs.skip_readout = core.headless && !readout_due()
	gs.skip_wanted = core.headless && !draw_due()
	w, h := gs.scanout()
	shown = {w, h}
	core.compat_vblank(u64(vblank), w > 0 && h > 0, mem.ram)
	if w > 0 && h > 0 {
		if !core.headless && !hw && !rerun {
			sdl.UpdateTexture(tex, nil, &gs.screen, gs.DISP_W * 4)
			src := sdl.Rect{0, 0, i32(w), i32(h)}
			sdl.RenderClear(ren)
			sdl.RenderCopy(ren, tex, &src, nil)
			sdl.RenderPresent(ren)
		}
		frame += 1
		core.input_script_frame(u64(frame), mem.ram)
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
			core.dump_put("iophle", "bin", u64(frame), iop.iop_hle)
		}
	}
	for next_shot < len(shots) && vblank >= shots[next_shot] {
		if vblank == shots[next_shot] {
			name := fmt.tprintf("shot_%d.ppm", vblank)
			switch {
			case w <= 0 || h <= 0: fmt.eprintfln("shot: vblank %d, display off, none written", vblank)
			case:
				px, stride, pw, ph := screen_picture(w, h)
				write_ppm(name, px, stride, pw, ph)
				fmt.eprintfln("shot: vblank %d", vblank)
			}
		}
		next_shot += 1
		// A headless run without FRAMES is done once its last shot is
		// taken; with FRAMES it runs on to FRAMES.
		if core.headless && core.frames == 0 && next_shot == len(shots) && (snaptest[1] == 0 || snaptest_loaded) {
			// A netplay peer may still need this host's input to get here.
			if !net_on {quit(0)}
			if quit_at == 0 {quit_at = vblank + NET_LINGER}
		}
	}
	if net_on && vblank % 600 == 0 {print_net()}
	if quit_at > 0 && vblank >= quit_at {
		print_net()
		quit(0)
	}
	if core.compat.on && u64(vblank) == core.frames {core.compat.lit = i64(lit_pixels(w, h))}
	if core.compat_sample_due(u64(vblank)) {
		px: []u32
		stride, pw, ph: int
		if w > 0 && h > 0 {px, stride, pw, ph = screen_picture(w, h)}
		core.compat_sample(u64(vblank), px, stride, pw, ph)
		probe_maybe()
	}
	if core.frames_done(u64(vblank)) {quit(0)}
	if core.input_watch_failed() != "" {quit(1)}
	if pace == 0 || rerun {return}
	// Netplay time sync stretches the frame while this host is ahead.
	// NTSC's vblank: pace * 1000 / 1001 Hz, as the guest's clock runs.
	length := time.Second * 1001 / time.Duration(pace * 1000)
	length += time.Duration(f64(length) * f64(core.net_stretch()))
	// An absolute deadline: sleep overshoot must not add up, or the game runs
	// under 60 Hz and the sound queue drains. Far behind, start again from now.
	// A quarter vblank late or more (the host took over 1.25 vblanks), the
	// queue drains at the host's speed, not the clocks': hold the sound's
	// drift learning, as at the resync.
	now := time.tick_now()
	last = time.tick_add(last, length)
	if late := time.tick_diff(last, now); late > length / 4 {
		core.audio_settle()
		if late > length {last = now}
	}
	if d := time.tick_diff(now, last); d > 0 {time.sleep(d)}
}

// STATS=1: every STATS_FRAMES presented frames, host frame rate and the
// share of guest time the kernel skipped with every thread waiting, and the
// share the spin skip (ps2/spin.odin) jumped.
@(private)
stats: bool
@(private)
STATS_FRAMES :: 300

@(private)
print_stats :: proc() {
	@(static) t0: time.Tick
	@(static) cyc0, idle0, spin0, tsc0: u64
	@(static) prof0: [cpu.Prof]u64
	now := time.tick_now()
	tsc := cpu.prof_start()
	if t0 != {} {
		secs := time.duration_seconds(time.tick_diff(t0, now))
		cyc, idl := cpu.state.cycles - cyc0, kernel.idle_cycles - idle0
		spin := cpu.spin_cycles - spin0
		fmt.eprintf("stats: frame %d  %.1f fps  idle %.0f%%  spin %.0f%%", frame,
			f64(STATS_FRAMES) / secs, 100 * f64(idl) / f64(max(cyc, 1)), 100 * f64(spin) / f64(max(cyc, 1)))
		for p in cpu.Prof {
			fmt.eprintf("  %v %.0f%%", p, 100 * f64(cpu.prof[p] - prof0[p]) / f64(max(tsc - tsc0, 1)))
		}
		a := core.audio_take_stats()
		fmt.eprintfln("  audio dry %d dropped %d low %.0f ms", a.dry, a.dropped, a.low_ms)
	}
	t0, cyc0, idle0, spin0, tsc0, prof0 = now, cpu.state.cycles, kernel.idle_cycles, cpu.spin_cycles, tsc, cpu.prof
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

// Whether this vblank's picture is read: a shot is due, or under COMPAT the
// FRAMES vblank, which lit_pixels counts, or a sample (core.compat_sample).
// A headless run reads no other picture.
@(private)
readout_due :: proc() -> bool {
	if next_shot < len(shots) && shots[next_shot] == vblank {return true}
	return (core.compat.on && core.frames > 0 && u64(vblank) == core.frames) || core.compat_sample_due(u64(vblank))
}

// Whether a picture is read within SHOT_WARMUP vblanks (a shot, or under
// COMPAT the FRAMES vblank or a sample): the GS then draws everything, so a
// game that fills its buffers over several frames has them full when read.
@(private)
draw_due :: proc() -> bool {
	if next_shot < len(shots) && shots[next_shot] - vblank <= SHOT_WARMUP {return true}
	return (core.compat.on && core.frames > 0 && u64(vblank) + SHOT_WARMUP >= core.frames) ||
		core.compat_sample_near(u64(vblank), SHOT_WARMUP)
}

// The picture on screen, w x h when drawn in software: its pixels (XBGR),
// row stride, width and height.
@(private)
screen_picture :: proc(w, h: int) -> (px: []u32, stride, pw, ph: int) {
	if hw {
		px, pw, ph = gs.hw_screen()
		return px, pw, pw, ph
	}
	return gs.screen[:], gs.DISP_W, w, h
}

// The picture on screen as the disc's thumbnail (core.thumb_save), when the
// display was on at the last vblank and its picture was read: headless,
// only shots and the COMPAT FRAMES vblank read it.
@(private)
thumb_save :: proc() {
	if shown.x <= 0 || shown.y <= 0 || (core.headless && !readout_due()) {return}
	px, stride, w, h := screen_picture(shown.x, shown.y)
	core.thumb_save(px, stride, w, h, .Xbgr)
}

// The non-black pixels of the picture on screen, w x h when drawn in
// software.
@(private)
lit_pixels :: proc(w, h: int) -> int {
	px, stride, pw, ph := screen_picture(w, h)
	n := 0
	for y in 0 ..< ph {
		for c in px[y * stride:][:pw] {
			if c & 0xffffff != 0 {n += 1}
		}
	}
	return n
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
