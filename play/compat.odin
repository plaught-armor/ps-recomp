// play --compat: compatibility runs. Each disc runs in a child of this
// executable as play would run it, headless, unpaced and as a COMPAT run
// (core/compat) to FRAMES vblanks, and gets one row in <data>/compat.tsv:
// the latest run of each disc id, kept in place, new ids appended.
//
// The child's output goes to the disc's compat.log. Its compat line names
// the result; a child that ends without one crashed, and one still running
// after COMPAT_WAIT seconds (default 600) is stopped and hung. A disc that
// fails in its child is a row, never a failure of the run. The conversion
// runs here first (convert_store, in its own child), so COMPAT_WAIT times
// the game alone; a disc whose conversion fails runs interpreted.
//
// The disc's press.txt, when there is one and PRESS is unset, is the
// child's PRESS script.
package play

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "ps:core"
import "ps:core/disc"

// The vblank a run ends at without a frames argument or FRAMES.
@(private = "file")
COMPAT_FRAMES :: 3600

// Seconds a child runs before it counts as hung, without COMPAT_WAIT.
@(private = "file")
COMPAT_WAIT :: 600

// The most of a fatal message a row keeps, in bytes.
@(private = "file")
FATAL_MAX :: 200

// compat.tsv's columns. result: ok (FRAMES reached), exit (the game
// ended), fatal, crash (no compat line), hang (stopped at COMPAT_WAIT),
// spawn (no child); status: the child's exit status (the signal of a
// crash on POSIX), "" for hang and spawn; native: whether the run had the
// disc's native code; interp_share: interp_insns * cycles_per_insn /
// cycles, at most 1; entries: the hottest interpreter entries, pc:count,
// comma separated; unimplemented: name=count, semicolon separated; fatal:
// the fatal message, else a crash's or hang's last output line; when: UTC.
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
}

Row :: [Column]string

// Run the disc image, or each disc image in the directory, to frames
// vblanks ("" for FRAMES, else COMPAT_FRAMES). The exit status: 0 when
// every disc found has a row, 1 when none was found or compat.tsv cannot
// be written, 2 on a bad setting.
compat_mode :: proc(path, frames_arg: string) -> int {
	frames, wait, ok := compat_settings(frames_arg)
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
		row, ran := compat_disc(image, frames, wait)
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

// The vblank count and COMPAT_WAIT; false, after a message, for a bad one.
@(private = "file")
compat_settings :: proc(frames_arg: string) -> (frames, wait: u64, ok: bool) {
	frames, wait = COMPAT_FRAMES, COMPAT_WAIT
	v, name := frames_arg, "frames"
	if v == "" {
		v, name = core.env("FRAMES"), core.env_name("FRAMES")
	}
	if v != "" {
		if frames, ok = strconv.parse_u64(v, 10); !ok || frames == 0 {
			fmt.eprintln("play:", name, "is not a vblank count:", v)
			return 0, 0, false
		}
	}
	if v = core.env("COMPAT_WAIT"); v != "" {
		if wait, ok = strconv.parse_u64(v, 10); !ok || wait == 0 {
			fmt.eprintln("play:", core.env_name("COMPAT_WAIT"), "is not a count of seconds:", v)
			return 0, 0, false
		}
	}
	return frames, wait, true
}

// The path, or the .cue, .iso and .bin files in the directory at path in
// name order, leaving out the .bin files its cue sheets name.
@(private = "file")
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
compat_disc :: proc(image: string, frames, wait: u64) -> (row: Row, ran: bool) {
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
	native := core.env("NATIVE") != "0" && (core.blob_cached(dir) || convert_store(image, dir))

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
	start := time.tick_now()
	p, perr := os.process_start({command = {self, image}, env = child_env(dir, frames, native), stdout = log, stderr = log})
	os.close(log)
	if perr != nil {
		row[.Result], row[.Fatal] = "spawn", fmt.tprint("cannot start the child:", perr)
		return
	}
	state, werr := os.process_wait(p, time.Duration(wait) * time.Second)
	hang := werr == os.General_Error.Timeout
	if hang {
		_ = os.process_kill(p)
		state, werr = os.process_wait(p)
	}
	row[.Wall_S] = fmt.tprintf("%.1f", time.duration_seconds(time.tick_since(start)))
	if werr == nil {
		row[.User_S] = fmt.tprintf("%.1f", time.duration_seconds(state.user_time))
		if !hang {
			row[.Status] = fmt.tprint(state.exit_code)
		}
	}
	// A stored blob the child could not load is removed, and the run
	// was interpreted.
	row[.Native] = "yes" if native && core.blob_cached(dir) else "no"

	text, _ := os.read_entire_file(log_path, context.temp_allocator)
	line, last := log_lines(string(text))
	l: core.Compat_Line
	if line != "" && json.unmarshal_string(line, &l) == nil {
		line_row(&row, l)
	} else {
		row[.Result] = "hang" if hang else "crash"
		row[.Fatal] = last
	}
	return
}

// The child's environment: this one with HEADLESS, COMPAT and FRAMES set,
// NATIVE=0 without native code (so the child does not convert again), and
// PRESS from the disc's press.txt when PRESS is unset.
@(private = "file")
child_env :: proc(dir: string, frames: u64, native: bool) -> []string {
	set := make([dynamic]string)
	append(&set, fmt.tprintf("%s=1", core.env_name("HEADLESS")))
	append(&set, fmt.tprintf("%s=1", core.env_name("COMPAT")))
	append(&set, fmt.tprintf("%s=%d", core.env_name("FRAMES"), frames))
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
// last non-empty line.
@(private = "file")
log_lines :: proc(text: string) -> (line, last: string) {
	rest := text
	for l in strings.split_lines_iterator(&rest) {
		s := strings.trim_right(l, "\r")
		if s == "" {
			continue
		}
		last = s
		if strings.has_prefix(s, "compat: ") {
			line = s[len("compat: "):]
		}
	}
	return
}

// Fill the row from the child's compat line.
@(private = "file")
line_row :: proc(row: ^Row, l: core.Compat_Line) {
	switch l.result {
	case "frames": row[.Result] = "ok"
	case: row[.Result] = l.result
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
	row[.Fatal] = l.fatal
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
		if first != header {
			fmt.eprintln("play:", path, "has other columns; it starts again")
			rest = ""
		}
		for line in strings.split_lines_iterator(&rest) {
			fields := strings.split(line, "\t")
			if len(fields) != len(Column) {
				continue
			}
			if fields[0] != row[.Id] {
				strings.write_string(&b, line)
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
