// play --compat: compatibility runs. Each disc runs in a child of this
// executable as play would run it, headless, unpaced and as a COMPAT run
// (core/compat) to FRAMES vblanks, and gets one row in <data>/compat.tsv:
// the latest run of each disc id, kept in place, new ids appended.
//
// The child's output goes to the disc's compat.log. Its compat line names
// the result; a child that ends without one crashed. The child writes its
// vblank count to the disc's compat.progress (COMPAT_PROGRESS, core/compat);
// one whose count has not moved for COMPAT_WAIT seconds (default 120), or
// for COMPAT_BOOT_FACTOR times that before its first vblank, is stopped and
// hung, however long it has run. A disc that fails in its child is a row,
// never a failure of the run. The conversion runs here first (convert_store,
// in its own child), and then the compile of the disc's learned code
// (learned_blob, in its own child too), so neither window counts them and a
// child hung or killed leaves no compile running. Either one still running
// after COMPAT_BOOT_FACTOR times COMPAT_WAIT is stopped; a disc whose
// conversion fails or is stopped runs interpreted, and one whose compile
// fails or is stopped runs without learned code, its child not compiling
// again.
//
// Each child starts on blank memory cards: its parent empties the disc's
// compat-cards folder first, and the child uses it in place of cards, so a
// save from an earlier run cannot change the game's route. COMPAT_CARDS=keep
// runs on the disc's cards instead, as play does, for a run that proves a
// save loads. One run of a disc at a time is assumed: a parent runs its
// discs in turn, but two parents in one data folder would share the folder.
//
// The disc's press.txt, when there is one and PRESS is unset, is the
// child's PRESS script.
//
// A child ends when its parent does, however the parent ended (a signal
// such as SIGTERM, SIGINT or SIGKILL included): it watches the parent's pid
// (COMPAT_PARENT, parent_watch) on a thread of its own.
package play

import "base:runtime"
import "core:bufio"
import "core:bytes"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import "ps:core"
import "ps:core/disc"

// The vblank a run ends at without a frames argument or FRAMES.
@(private = "file")
COMPAT_FRAMES :: 3600

// Seconds a child's vblank count may stay the same before it counts as
// hung, without COMPAT_WAIT. The child writes the count once a second of
// game time (COMPAT_PROGRESS_EVERY vblanks), so this is about 6 times the
// gap of an interpreted disc at 3 to 5 frames a second on a loaded machine.
// No cap on the whole run: a count that keeps moving reaches FRAMES.
@(private = "file")
COMPAT_WAIT :: 120

// The window before vblank 1, as a multiple of COMPAT_WAIT: the child first
// loads a native blob and its learned code and boots the console, none of
// which writes a count. 5 times the default is the
// 600 s the whole run had before the count.
@(private = "file")
COMPAT_BOOT_FACTOR :: 5

// How often the parent reads a running child's count.
@(private = "file")
COMPAT_POLL :: 250 * time.Millisecond

// The longest line of a child's output read, in bytes.
@(private = "file")
LOG_LINE_MAX :: 16 << 20

// The most of a fatal message a row keeps, in bytes.
@(private = "file")
FATAL_MAX :: 200

// compat.tsv's columns. result: ok (FRAMES reached), stalled (FRAMES reached
// with no progress: the display never on, nothing drawn on the last frame, or
// main RAM unchanged from FRAMES/2), fallback (FRAMES reached with progress,
// but an IOP module's load failed and the HLE stood in for it), exit (the
// game ended), fatal, watch (a PRESS condition timed out,
// core.input_script_frame; the child exits 1), crash (no compat line),
// hang (stopped with no new vblank in a window, COMPAT_WAIT), spawn (no child); status: the child's
// exit status (the signal of a crash on POSIX), 1 for stalled as for
// fatal though the child exits 0, "" for hang and spawn; native: whether the
// run had the disc's native code; interp_share: interp_insns *
// cycles_per_insn / cycles, at most 1; entries: the hottest interpreter
// entries, pc:count, comma separated; unimplemented: name=count, semicolon
// separated; fatal: the fatal message or a watch's timeout message, else
// why a run stalled, else a crash's
// last output line ("" for a hang); when: UTC; shown: the vblanks with the
// display on, whether anything was drawn or not; idle_share: idle_cycles /
// cycles, the share of the run with every guest thread waiting (0 for a
// console whose kernel skips no idle time); information only, as a game
// waiting on vsync on a light screen idles nearly all the time too; lit: the
// non-black pixels on the last frame of a run to FRAMES, "" when not counted;
// stretches: the sampled stretches of at least core.COMPAT_STRETCH vblanks,
// kind:from-to comma separated (kinds black, frozen, ram_still, and still
// or deaf for a picture that barely changed: deaf when a press of the
// loaded PRESS script, the disc's press.txt when PRESS is unset, started
// in it, still when none did; only a picture static as a whole, not a
// stuck prompt over a moving 3D scene; see core.Compat_Stretch_Kind), then +<n> for
// those past core.COMPAT_STRETCHES; information only; learned: whether the
// run had the disc's learned code (a PS2 disc's: its IOP's or EE's), compiled from
// the records earlier runs left; cards: fresh (the child ran on blank cards,
// the default), kept (COMPAT_CARDS=keep, on the disc's cards, which held
// files) or kept-empty (keep, the disc's cards empty or missing).
Column :: enum {
	Id,
	Serial,
	System,
	Vmode,
	Result,
	Status,
	Frames,
	Frames_Wanted,
	Native,
	Interp_Share,
	Interp_Insns,
	Cycles,
	Entries,
	Entries_Other,
	Unimplemented,
	Fatal,
	Wall_S,
	User_S,
	Build,
	When,
	Shown,
	Idle_Share,
	Lit,
	Stretches,
	Learned,
	Cards,
}

COLUMNS :: [Column]string {
	.Id            = "id",
	.Serial        = "serial",
	.System        = "system",
	.Vmode         = "vmode",
	.Result        = "result",
	.Status        = "status",
	.Frames        = "frames",
	.Frames_Wanted = "frames_wanted",
	.Native        = "native",
	.Interp_Share  = "interp_share",
	.Interp_Insns  = "interp_insns",
	.Cycles        = "cycles",
	.Entries       = "entries",
	.Entries_Other = "entries_other",
	.Unimplemented = "unimplemented",
	.Fatal         = "fatal",
	.Wall_S        = "wall_s",
	.User_S        = "user_s",
	.Build         = "build",
	.When          = "when",
	.Shown         = "shown",
	.Idle_Share    = "idle_share",
	.Lit           = "lit",
	.Stretches     = "stretches",
	.Learned       = "learned",
	.Cards         = "cards",
}

Row :: [Column]string

// Run the disc image, or each disc image in the directory, to frames
// vblanks ("" for FRAMES, else COMPAT_FRAMES). The exit status: 0 when
// every disc found has a row, 1 when none was found or compat.tsv cannot
// be written, 2 on a bad setting.
compat_mode :: proc(path, frames_arg: string) -> int {
	frames, wait, keep, ok := compat_settings(frames_arg)
	if !ok {
		return 2
	}
	images := compat_images(path)
	data, has_data := core.data_dir()
	if !has_data {
		return 1
	}
	tsv, _ := filepath.join({data, "compat.tsv"})
	rows := 0
	for image in images {
		// Everything one disc needs goes when it is done.
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		context.allocator = context.temp_allocator
		row, ran := compat_disc(image, frames, wait, keep)
		if !ran {
			continue
		}
		if !tsv_put(tsv, row) {
			return 1
		}
		rows += 1
		fmt.printfln("%s\t%s\t%s\t%s", row[.Id], row[.Result], row[.Frames], row[.Interp_Share])
	}
	if rows == 0 {
		fmt.eprintln("play: no disc to run in", path)
		return 1
	}
	return 0
}

// The vblank count, COMPAT_WAIT and whether COMPAT_CARDS keeps the disc's
// cards; false, after a message, for a bad one.
@(private = "file")
compat_settings :: proc(frames_arg: string) -> (frames, wait: u64, keep, ok: bool) {
	frames, wait = COMPAT_FRAMES, COMPAT_WAIT
	v, name := frames_arg, "frames"
	if v == "" {
		v, name = core.env("FRAMES"), core.env_name("FRAMES")
	}
	if v != "" {
		if frames, ok = strconv.parse_u64(v, 10); !ok || frames == 0 {
			fmt.eprintln("play:", name, "is not a vblank count:", v)
			return 0, 0, false, false
		}
	}
	if v = core.env("COMPAT_WAIT"); v != "" {
		if wait, ok = strconv.parse_u64(v, 10); !ok || wait == 0 {
			fmt.eprintln("play:", core.env_name("COMPAT_WAIT"), "is not a count of seconds:", v)
			return 0, 0, false, false
		}
	}
	if _, ok = core.compat_probe_setting(); !ok {
		return 0, 0, false, false
	}
	switch v = core.env("COMPAT_CARDS"); v {
	case "", "fresh":
	case "keep":
		keep = true
	case:
		fmt.eprintln("play:", core.env_name("COMPAT_CARDS"), "is not fresh or keep:", v)
		return 0, 0, false, false
	}
	return frames, wait, keep, true
}

// The path, or the .cue, .iso and .bin files in the directory at path in
// name order, leaving out the .bin files its cue sheets name.
@(private)
compat_images :: proc(path: string) -> []string {
	if !os.is_dir(path) {
		return slice.clone([]string{path})
	}
	infos, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("play: cannot read", path, err)
		return nil
	}
	tracks := make(map[string]bool, context.temp_allocator)
	images := make([dynamic]string)
	for fi in infos {
		ext := strings.to_lower(filepath.ext(fi.name), context.temp_allocator)
		if fi.type != .Regular || ext != ".cue" && ext != ".iso" && ext != ".bin" {
			continue
		}
		append(&images, fi.fullpath)
		if ext != ".cue" {
			continue
		}
		if d, ok := disc.open(fi.fullpath, context.temp_allocator); ok {
			for f in d.files {
				tracks[filepath.base(os.name(f))] = true
			}
			disc.close(&d)
		}
	}
	n := 0
	for im in images {
		if !(strings.equal_fold(filepath.ext(im), ".bin") && tracks[filepath.base(im)]) {
			images[n] = im
			n += 1
		}
	}
	resize(&images, n)
	slice.sort(images[:])
	return images[:]
}

// Run one disc image in a child and make its row; false, after a message,
// for a file that is not a disc with an executable.
@(private = "file")
compat_disc :: proc(image: string, frames, wait: u64, keep: bool) -> (row: Row, ran: bool) {
	id, cnf, _, ok := identify(image)
	if !ok {
		return
	}
	dir, has_dir := core.disc_dir(id)
	if !has_dir {
		return
	}
	ran = true
	row[.Id] = id
	row[.Serial] = cnf.serial
	row[.System] = "ps2" if cnf.ps2 else "ps1"
	row[.Vmode] = cnf.vmode
	row[.Frames_Wanted] = fmt.tprint(frames)
	row[.When], _ = time.time_to_rfc3339(time.now(), 0, false, context.temp_allocator)
	// Each compile gets the child's window before its first vblank: a
	// hung one is stopped, and the child runs without what it makes.
	stall := time.Duration(wait) * time.Second
	native := !core.FLAT && core.env("NATIVE") != "0" && (native_cached(dir) || convert_store(image, dir, COMPAT_BOOT_FACTOR * stall))
	// The child finds the blob stored and compiles nothing (compat_child).
	learn_cpu := core.Learn_Cpu.Iop if cnf.ps2 else .Psx
	learned, learned_ee: string
	if native && core.env("LEARN") != "0" {
		learned = learned_blob(dir, learn_cpu, true, COMPAT_BOOT_FACTOR * stall)
		if cnf.ps2 {learned_ee = learned_blob(dir, .Ee, true, COMPAT_BOOT_FACTOR * stall)}
	}
	if !core.FLAT && core.env("NATIVE") != "0" && !cnf.ps2 && core.env("MOD_NATIVE") != "0" {
		_ = mods_blob(dir, true, COMPAT_BOOT_FACTOR * stall)
	}

	self, serr := os.get_executable_path(context.temp_allocator)
	if serr != nil {
		row[.Result], row[.Fatal] = "spawn", fmt.tprint("cannot find this executable:", serr)
		return
	}
	log_path := core.disc_path(dir, .Compat_Log)
	// Inheritable: on Windows the child's standard handles are otherwise
	// invalid and its output is lost.
	log, lerr := os.open(log_path, {.Write, .Create, .Trunc, .Inheritable}, os.Permissions_Default_File)
	if lerr != nil {
		row[.Result], row[.Fatal] = "spawn", fmt.tprint("cannot create", log_path, lerr)
		return
	}
	// The child's cards (play's main): blank ones, or the disc's own.
	if keep {
		have, _ := os.read_directory_by_path(core.disc_path(dir, .Cards), 1, context.temp_allocator)
		row[.Cards] = "kept" if len(have) > 0 else "kept-empty"
	} else {
		cards := core.disc_path(dir, .Compat_Cards)
		if err := os.remove_all(cards); err != nil && err != .Not_Exist {
			os.close(log)
			row[.Result], row[.Fatal] = "spawn", fmt.tprint("cannot empty", cards, err)
			return
		}
		row[.Cards] = "fresh"
	}
	progress_path := core.disc_path(dir, .Compat_Progress)
	// Empty: a count from an earlier run is not progress of this one.
	progress, gerr := os.open(progress_path, {.Read, .Write, .Create, .Trunc}, os.Permissions_Default_File)
	if gerr != nil {
		os.close(log)
		row[.Result], row[.Fatal] = "spawn", fmt.tprint("cannot create", progress_path, gerr)
		return
	}
	defer os.close(progress)
	start := time.tick_now()
	p, perr := os.process_start({command = {self, image}, env = child_env(dir, frames, native, progress_path), stdout = log, stderr = log})
	os.close(log)
	if perr != nil {
		row[.Result], row[.Fatal] = "spawn", fmt.tprint("cannot start the child:", perr)
		return
	}
	state, werr, hang := compat_wait(p, progress, COMPAT_BOOT_FACTOR * stall, stall)
	row[.Wall_S] = fmt.tprintf("%.1f", time.duration_seconds(time.tick_since(start)))
	if werr == nil {
		row[.User_S] = fmt.tprintf("%.1f", time.duration_seconds(state.user_time))
		if !hang {
			row[.Status] = fmt.tprint(state.exit_code)
		}
	}
	// A stored blob the child could not load is removed, and the run
	// was interpreted.
	row[.Native] = "yes" if native && native_cached(dir) else "no"
	// The same for the learned blob, whose key the child removes.
	had := learned != "" && os.exists(core.disc_path(dir, learned_files(learn_cpu).key))
	had ||= learned_ee != "" && os.exists(core.disc_path(dir, learned_files(.Ee).key))
	row[.Learned] = "yes" if had else "no"

	line, last := log_lines(log_path)
	l: core.Compat_Line
	if line != "" && json.unmarshal_string(line, &l) == nil {
		line_row(&row, l)
	} else if hang {
		// Its last line is wherever the kill caught it, not a cause.
		row[.Result] = "hang"
	} else {
		row[.Result], row[.Fatal] = "crash", last
	}
	return
}

// Wait for the child p to end, reading its vblank count from progress each
// COMPAT_POLL. hang: the count stayed at 0 (no vblank yet) for boot, or at
// any later value for stall, so p was killed (and waited for). Any new
// value is progress, a compat probe's heartbeat included
// (core.compat_probe_beat).
@(private = "file")
compat_wait :: proc(p: os.Process, progress: ^os.File, boot, stall: time.Duration) -> (state: os.Process_State, err: os.Error, hang: bool) {
	last: u64
	since := time.tick_now()
	for {
		state, err = os.process_wait(p, COMPAT_POLL)
		if err != os.General_Error.Timeout {
			return
		}
		// A short read (an empty file, no vblank yet) is 0. A torn read
		// of a write in flight is a new value too, so at worst it counts
		// as progress once: harmless.
		b: [8]u8
		n, _ := os.read_at(progress, b[:], 0)
		v := endian.unchecked_get_u64le(b[:]) if n == len(b) else 0
		if v != last {
			last, since = v, time.tick_now()
		} else if time.tick_since(since) >= (boot if last == 0 else stall) {
			_ = os.process_kill(p)
			state, err = os.process_wait(p)
			return state, err, true
		}
	}
}

// Watch, on a thread of its own, for the end of the compat parent whose pid
// is COMPAT_PARENT (child_env), and once it has ended stop this process at
// once (parent_exit), with status 1: no one is left to read its row. Only
// a compat child calls it (run). The thread reads the pid alone, no state
// the run shares; it checks every PARENT_POLL where it polls
// (parent_gone_wait).
parent_watch :: proc() {
	pid, ok := strconv.parse_int(core.env("COMPAT_PARENT"), 10)
	if !ok || pid <= 0 {
		return
	}
	watch :: proc(pid: int) {
		parent_gone_wait(pid)
		fmt.eprintfln("compat: parent %d gone, stopping", pid)
		parent_exit(1)
	}
	if !core.THREADS {
		// No thread to watch it with (core.THREADS): this run outlives
		// the parent.
		return
	}
	if thread.create_and_start_with_poly_data(pid, watch, self_cleanup = true) == nil {
		fmt.eprintln("compat: cannot watch the parent; this run outlives it")
	}
}

// How often parent_gone_wait checks the parent where it polls.
@(private)
PARENT_POLL :: 250 * time.Millisecond

// Whether this run is a compat child: COMPAT_PROGRESS is set only by the
// compat parent (child_env).
@(private)
compat_child :: proc() -> bool {
	return core.env("COMPAT_PROGRESS") != ""
}

// The child's environment: this one with HEADLESS, COMPAT and FRAMES set,
// COMPAT_PROGRESS the file for its vblank count, COMPAT_PARENT this
// process's pid (parent_watch), NATIVE=0 without native
// code (so the child does not convert again), and PRESS from the disc's
// press.txt when PRESS is unset.
@(private = "file")
child_env :: proc(dir: string, frames: u64, native: bool, progress: string) -> []string {
	set := make([dynamic]string)
	append(&set, fmt.tprintf("%s=1", core.env_name("HEADLESS")))
	append(&set, fmt.tprintf("%s=1", core.env_name("COMPAT")))
	append(&set, fmt.tprintf("%s=%d", core.env_name("FRAMES"), frames))
	append(&set, fmt.tprintf("%s=%s", core.env_name("COMPAT_PROGRESS"), progress))
	append(&set, fmt.tprintf("%s=%d", core.env_name("COMPAT_PARENT"), os.get_pid()))
	if !native {
		append(&set, fmt.tprintf("%s=0", core.env_name("NATIVE")))
	}
	if _, has_press := core.env_lookup("PRESS"); !has_press {
		if press, err := os.read_entire_file(core.disc_path(dir, .Press), context.temp_allocator); err == nil {
			append(&set, fmt.tprintf("%s=%s", core.env_name("PRESS"), strings.trim_space(string(press))))
		}
	}
	env, _ := os.environ(context.temp_allocator)
	out := make([dynamic]string)
	outer: for e in env {
		key, _, _ := strings.partition(e, "=")
		for s in set {
			k, _, _ := strings.partition(s, "=")
			// Windows names are any case.
			if strings.equal_fold(key, k) {
				continue outer
			}
		}
		append(&out, e)
	}
	append(&out, ..set[:])
	return out[:]
}

// The last compat line's JSON in the child's output, "" for none, and its
// last non-empty line, temp allocated. Read a line at a time: a game that
// floods its output leaves gigabytes. A line past LOG_LINE_MAX ends the
// read there.
@(private = "file")
log_lines :: proc(path: string) -> (line, last: string) {
	f, err := os.open(path)
	if err != nil {
		return
	}
	defer os.close(f)
	s: bufio.Scanner
	bufio.scanner_init(&s, os.to_stream(f), context.temp_allocator)
	s.max_token_size = LOG_LINE_MAX
	l := make([dynamic]u8, context.temp_allocator)
	t := make([dynamic]u8, context.temp_allocator)
	for bufio.scan(&s) {
		b := bufio.scanner_bytes(&s)
		if len(b) == 0 {
			continue
		}
		resize(&t, len(b))
		copy(t[:], b)
		if bytes.has_prefix(b, transmute([]u8)string("compat: ")) {
			resize(&l, len(b) - len("compat: "))
			copy(l[:], b[len("compat: "):])
		}
	}
	return string(l[:]), string(t[:])
}

// Fill the row from the child's compat line.
line_row :: proc(row: ^Row, l: core.Compat_Line) {
	switch l.result {
	case "frames": row[.Result] = "ok"
	case: row[.Result] = l.result
	}
	row[.Fatal] = l.fatal
	idle := l.cycles > 0 ? min(1, f64(l.idle_cycles) / f64(l.cycles)) : 0
	if l.cycles > 0 {
		row[.Idle_Share] = fmt.tprintf("%.6f", idle)
	}
	if l.result == "frames" {
		stalled := true
		switch {
		case l.shown == 0: row[.Fatal] = "stalled: no picture shown"
		case l.lit == 0: row[.Fatal] = "stalled: nothing drawn"
		case l.ram_still_since != 0: row[.Fatal] = fmt.tprintf("stalled: main RAM unchanged f%d-f%d", l.ram_still_since, l.frames)
		case: stalled = false
		}
		if stalled {
			row[.Result], row[.Status] = "stalled", "1"
		} else if l.fallback {
			row[.Result] = "fallback"
		}
	}
	if l.system != "" {
		row[.System] = l.system
	}
	row[.Frames] = fmt.tprint(l.frames)
	row[.Interp_Insns] = fmt.tprint(l.interp_insns)
	row[.Cycles] = fmt.tprint(l.cycles)
	if l.cycles > 0 {
		row[.Interp_Share] = fmt.tprintf("%.6f", min(1, f64(l.interp_insns) * f64(l.cycles_per_insn) / f64(l.cycles)))
	}
	b := strings.builder_make()
	for e, i in l.interp_entries {
		fmt.sbprintf(&b, "%s%s:%d", "," if i > 0 else "", e.pc, e.n)
	}
	row[.Entries] = strings.to_string(b)
	row[.Entries_Other] = fmt.tprint(l.interp_entries_other)
	b = strings.builder_make()
	for u, i in l.unimplemented {
		fmt.sbprintf(&b, "%s%s=%d", ";" if i > 0 else "", u.name, u.n)
	}
	row[.Unimplemented] = strings.to_string(b)
	row[.Shown] = fmt.tprint(l.shown)
	if l.lit >= 0 {
		row[.Lit] = fmt.tprint(l.lit)
	}
	b = strings.builder_make()
	for st, i in l.stretches {
		fmt.sbprintf(&b, "%s%s:%d-%d", "," if i > 0 else "", st.kind, st.from, st.to)
	}
	if l.stretches_other > 0 {
		fmt.sbprintf(&b, "%s+%d", "," if len(l.stretches) > 0 else "", l.stretches_other)
	}
	row[.Stretches] = strings.to_string(b)
	row[.Build] = l.build
}

// Put the row in the compat.tsv at path in place of its disc id's, or at
// the end, replacing the file whole. False, after a message, when it
// cannot be written. A file with other columns starts again.
@(private = "file")
tsv_put :: proc(path: string, row: Row) -> bool {
	cols := COLUMNS
	header := strings.join(slice.enumerated_array(&cols), "\t")
	b := strings.builder_make()
	strings.write_string(&b, header)
	strings.write_byte(&b, '\n')
	put := false
	if text, err := os.read_entire_file(path, context.allocator); err == nil {
		rest := string(text)
		first, _ := strings.split_lines_iterator(&rest)
		// A file from before columns were added at the end keeps its rows,
		// the new columns empty.
		missing := 0
		if first != header {
			if first != "" && strings.has_prefix(header, first) && header[len(first)] == '\t' {
				missing = strings.count(header[len(first):], "\t")
			} else {
				fmt.eprintln("play:", path, "has other columns; it starts again")
				rest = ""
			}
		}
		for line in strings.split_lines_iterator(&rest) {
			fields := strings.split(line, "\t")
			if len(fields) != len(Column) - missing {
				continue
			}
			if fields[0] != row[.Id] {
				strings.write_string(&b, line)
				for _ in 0 ..< missing {
					strings.write_byte(&b, '\t')
				}
				strings.write_byte(&b, '\n')
			} else if !put {
				row_write(&b, row)
				put = true
			}
		}
	}
	if !put {
		row_write(&b, row)
	}
	if err := core.write_file_atomic(path, b.buf[:]); err != nil {
		fmt.eprintln("play: cannot write", path, err)
		return false
	}
	return true
}

// One row, tabs and line breaks in its fields made spaces and the fatal
// message cut to FATAL_MAX bytes.
@(private = "file")
row_write :: proc(b: ^strings.Builder, row: Row) {
	for f, c in row {
		s := f
		if c == .Fatal && len(s) > FATAL_MAX {
			n := FATAL_MAX
			for n > 0 && !utf8.rune_start(s[n]) {
				n -= 1
			}
			s = s[:n]
		}
		if c != .Id {
			strings.write_byte(b, '\t')
		}
		for r in s {
			strings.write_rune(b, ' ' if r == '\t' || r == '\n' || r == '\r' else r)
		}
	}
	strings.write_byte(b, '\n')
}
