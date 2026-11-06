package play

import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "ps:core"
import "ps:psx"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"
import "ps:recomp/r5900"
import "ps:recomp/vu"

// The converter child (`play --convert <disc image> <out> <vu0> <vu1>`):
// the executable SYSTEM.CNF names, compiled to a native blob for this host
// at out. vu0 and vu1 are a PS2 disc's VU capture files (native_captures),
// "" for none; with either, the blob holds the VU microprograms too, the
// captured ones and those of .vutext. A failure exits with status 1 after
// a message (mips.fail), which is why it runs in a child.
//
// vu_only (`play --convert-vu`, the same arguments, then the run's pid)
// compiles a PS2 disc's VU microprograms alone, VU1 code computing status
// whatever its programs read, for a run to load beside the code it runs
// (midload.odin).
convert :: proc(image, out, vu0, vu1: string, vu_only := false) -> int {
	if _, ok := native.arch_of("convert", mips.HOST_ARCH); !ok {
		return 1
	}
	o := mips.disc_options(image, "")
	o.values["native_out"] = out
	if vu0 != "" || vu1 != "" {
		o.values["native_vu"] = "true"
		if vu0 != "" {o.values["vu0_capture"] = vu0}
		if vu1 != "" {o.values["vu1_capture"] = vu1}
	}
	if vu_only {
		o.values["vu_only"] = "true"
		o.values["vu_status"] = "all"
	}
	b := mips.option(o, "backend")
	if vu_only {
		if b != "r5900" {mips.fail("%s: a %s disc has no VU microprograms", image, b)}
		fmt.eprintln("converting the VU microprograms of", image)
	} else {
		fmt.eprintln("converting", image)
	}
	switch b {
	case "r3000": r3000.generate(o)
	case "r5900": r5900.generate(o)
	case: mips.fail("%s: unknown backend %s", image, b)
	}
	return 0
}

// The learned child (`play --learned <psx | iop | ee> <records> <out>`):
// the runs of the PS1, IOP or EE processor in the LEARN file at records
// that native code can stand for (core.learn_compilable), compiled to a
// blob of learned functions for this host at out (psx/native/learned.odin;
// the EE's, ps2/learned.odin). The PS1 and the IOP both run the R3000 of
// psx_cpu, so one compiler serves them; the EE's is recomp/r5900.
compile_learned :: proc(cpu: core.Learn_Cpu, records, out: string) -> int {
	data, err := os.read_entire_file(records, context.allocator)
	if err != nil {
		fmt.eprintln("learned: cannot read", records, err)
		return 1
	}
	recs, _ := core.learn_read(data)
	runs, large, smc := core.learn_compilable(recs[:], cpu)
	arch, ok := native.arch_of("learned", mips.HOST_ARCH)
	if !ok {
		return 1
	}
	blob: []u8
	skipped := 0 // runs the EE's compiler left to the interpreter
	if cpu == .Ee {
		funcs := make([]r5900.Learned, len(runs))
		for r, k in runs {funcs[k] = {r.entry, r.lo, r.words}}
		blob, skipped = r5900.learned_blob(funcs, arch)
	} else {
		funcs := make([]r3000.Learned, len(runs))
		for r, k in runs {funcs[k] = {r.entry, r.lo, r.words}}
		blob = r3000.learned_blob(funcs, arch)
	}
	if werr := os.write_entire_file(out, blob); werr != nil {
		fmt.eprintln("learned: cannot write", out, werr)
		return 1
	}
	fmt.eprintfln("learned: %d functions from %d records (not compiled: %d stored into their code, %d large, %d not lowered)", len(runs) - skipped, len(recs), smc, large, skipped)
	return 0
}

// The mods child (`play --mods <mods directory> <out>`): the functions of
// the mods in dir (their mod.elf's .symtab, core.mod_elf_read), compiled to
// a blob of mod functions for this host at out (psx/native/mods.odin). A
// failure exits with status 1 after a message.
compile_mods :: proc(dir, out: string) -> int {
	set, err := psx.mods_read(dir, "")
	if err != "" {
		fmt.eprintln(err)
		return 1
	}
	defer core.mod_set_delete(set)
	arch, ok := native.arch_of("mods", mips.HOST_ARCH)
	if !ok {
		return 1
	}
	funcs := make([dynamic]r3000.Learned)
	for img in set.images {
		for f in img.funcs {
			words := make([]u32, len(f.bytes) / 4)
			for &w, i in words {
				b := f.bytes[i * 4:]
				w = u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
			}
			append(&funcs, r3000.Learned{f.addr, f.addr, words})
		}
	}
	blob := r3000.learned_blob(funcs[:], arch)
	if werr := os.write_entire_file(out, blob); werr != nil {
		fmt.eprintln("mods: cannot write", out, werr)
		return 1
	}
	fmt.eprintfln("mods: %d functions from %d mods", len(funcs), len(set.mods))
	return 0
}

// Convert the disc image in a child of this executable and store the blob
// in the disc directory dir, its key naming the VU captures it was compiled
// with (native_captures). The child's output goes to stderr as it comes,
// on a terminal as one line rewritten in place. False, after a message
// naming the child's last line, when there is no blob. A child still
// running after deadline (0: none) is stopped (child_blob).
convert_store :: proc(image, dir: string, deadline: time.Duration) -> bool {
	set, caps := native_captures(dir)
	tmp := strings.concatenate({core.disc_path(dir, .Native, context.temp_allocator), ".convert"}, context.temp_allocator)
	blob := child_blob({"--convert", image, tmp, caps[0], caps[1]}, tmp, "native code", "conversion", deadline) or_return
	defer delete(blob)
	return core.blob_store(dir, blob, core.COMMIT, .Native, set)
}

// Whether the disc directory dir holds a native blob this build can run,
// compiled with the VU captures dir holds now (native_captures).
native_cached :: proc(dir: string) -> bool {
	set, _ := native_captures(dir)
	return core.blob_cached(dir, core.COMMIT, .Native, set)
}

// The VU capture files of the disc directory dir (VU_CAPTURE) that add
// programs, each unit's path or "", and the set the native blob's key names
// them by: "vu0 <fingerprint> vu1 <fingerprint>", "-" for a unit without
// one, and "" when neither has one, so a blob compiled without captures
// keeps its key. A capture that grows by new entries changes its
// fingerprint, and the blob is compiled again; one that only repeats
// records does not (vu.capture_fingerprint). Temp allocated.
native_captures :: proc(dir: string) -> (set: string, caps: [2]string) {
	fps: [2]string = {"-", "-"}
	for f, unit in ([2]core.Disc_File{.Vu0_Capture, .Vu1_Capture}) {
		path := core.disc_path(dir, f, context.temp_allocator)
		if fp, ok := vu.capture_fingerprint(path, vu.Unit(unit)); ok {
			caps[unit] = path
			fps[unit] = fmt.tprintf("%016x", fp)
		}
	}
	if caps[0] == "" && caps[1] == "" {return "", caps}
	return fmt.tprintf("vu0 %s vu1 %s", fps[0], fps[1]), caps
}

// Compile the LEARN file at records in a child of this executable (as
// convert_store) and store the blob of learned functions in the disc
// directory dir, its key naming the records by set. False, after a
// message, when there is no blob.
learned_store :: proc(cpu: core.Learn_Cpu, records, dir, set: string, deadline: time.Duration) -> bool {
	l := learned_files(cpu)
	tmp := strings.concatenate({core.disc_path(dir, l.blob, context.temp_allocator), ".compile"}, context.temp_allocator)
	blob := child_blob({"--learned", l.name, records, tmp}, tmp, "learned code", "compile", deadline) or_return
	defer delete(blob)
	return core.blob_store(dir, blob, core.COMMIT, l.kind, set)
}

// Compile the functions of the mods in the mods directory mods in a child
// of this executable (as convert_store) and store the blob in the disc
// directory dir, its key naming the mod set by set. False, after a
// message, when there is no blob.
mods_store :: proc(mods, dir, set: string, deadline: time.Duration) -> bool {
	tmp := strings.concatenate({core.disc_path(dir, .Mods_Native, context.temp_allocator), ".compile"}, context.temp_allocator)
	blob := child_blob({"--mods", mods, tmp}, tmp, "native code for the mods", "mods compile", deadline) or_return
	defer delete(blob)
	return core.blob_store(dir, blob, core.COMMIT, .Mods, set)
}

// Run this executable with args, which write a blob to tmp, relaying its
// output. The blob, in context.allocator; false, after a message naming
// what has none and the child's last line, when it wrote no valid one. A
// child still running after deadline (0: none) is killed, which ends its
// output too: a hung one never closes the pipe the relay reads.
@(private = "file")
child_blob :: proc(args: []string, tmp, what, step: string, deadline: time.Duration) -> ([]u8, bool) {
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		fmt.eprintln("play: cannot find this executable:", err)
		return nil, false
	}
	// A temporary file a crash left behind is overwritten, never used.
	defer os.remove(tmp)
	r, w: ^os.File
	if r, w, err = os.pipe(); err != nil {
		fmt.eprintln("play: cannot make a pipe:", err)
		return nil, false
	}
	defer os.close(r)
	command := make([]string, len(args) + 1, context.temp_allocator)
	command[0] = self
	copy(command[1:], args)
	p: os.Process
	{
		defer os.close(w)
		p, err = os.process_start({command = command, stdout = w, stderr = w})
	}
	if err != nil {
		fmt.eprintfln("play: cannot start the %s: %v", step, err)
		return nil, false
	}
	// Without threads (core.THREADS) nothing watches the child while its
	// output is relayed, and relay blocks for as long as a hung child keeps
	// its pipe open, so there is no deadline at all: the child is waited for
	// once its output ends, for as long as it takes.
	cw := Child_Wait{p = p, deadline = deadline if deadline > 0 && core.THREADS else os.TIMEOUT_INFINITE}
	t: ^thread.Thread
	if core.THREADS {
		t = thread.create_and_start_with_poly_data(&cw, child_watch)
		if t == nil {
			// Unwatched, it could hang the run: stopped, it fails below.
			fmt.eprintfln("play: cannot watch the %s", step)
			_ = os.process_kill(p)
		}
	}
	last := relay(r)
	if t != nil {
		thread.join(t)
		thread.destroy(t)
	} else {
		child_watch(&cw)
	}
	if cw.expired {
		fmt.eprintfln("play: no %s (the %s took over %.0f s, stopped)", what, step, time.duration_seconds(deadline))
		return nil, false
	}
	state, werr := cw.state, cw.err
	if werr != nil || !state.exited || state.exit_code != 0 {
		fmt.eprintfln("play: no %s (the %s failed: %s)", what, step, last)
		return nil, false
	}
	blob, rerr := os.read_entire_file(tmp, context.allocator)
	if rerr != nil || !core.blob_valid(blob) {
		delete(blob)
		fmt.eprintfln("play: no %s (the %s wrote no valid blob)", what, step)
		return nil, false
	}
	return blob, true
}

// A child_blob child's wait. Only child_watch waits on p: a wait that
// returns its end reaps it, and another wait on it fails.
@(private = "file")
Child_Wait :: struct {
	p:        os.Process,
	deadline: time.Duration,
	state:    os.Process_State,
	err:      os.Error,
	expired:  bool,
}

// Wait for w.p to end, killing it once w.deadline has passed (expired).
@(private = "file")
child_watch :: proc(w: ^Child_Wait) {
	w.state, w.err = os.process_wait(w.p, w.deadline)
	if w.err == os.General_Error.Timeout {
		w.expired = true
		_ = os.process_kill(w.p)
		w.state, w.err = os.process_wait(w.p)
	}
}

// Copy the child's output from r to stderr until it closes; on a terminal
// (or with TTY=1, which the launcher sets when its stderr is one and it
// copies a run's stderr there) each line overwrites the one before. The
// last non-empty line, temp allocated.
@(private = "file")
relay :: proc(r: ^os.File) -> string {
	tty := os.is_tty(os.stderr) || core.env("TTY") == "1"
	line, last: [dynamic]u8
	line.allocator = context.temp_allocator
	last.allocator = context.temp_allocator
	buf: [4096]u8
	for {
		n, err := os.read(r, buf[:])
		for c in buf[:max(n, 0)] {
			if c != '\n' {
				append(&line, c)
				continue
			}
			end_line(&line, &last, tty)
		}
		if err != nil || n <= 0 {
			break
		}
	}
	end_line(&line, &last, tty)
	if tty && len(last) > 0 {
		fmt.eprintln()
	}
	return string(last[:])
}

@(private = "file")
end_line :: proc(line, last: ^[dynamic]u8, tty: bool) {
	s := strings.trim_right(string(line[:]), "\r")
	if s == "" {
		return
	}
	if tty {
		fmt.eprintf("\r\x1b[K%s", s)
	} else {
		fmt.eprintln(s)
	}
	resize(last, len(s))
	copy(last[:], s)
	clear(line)
}
