package play

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "ps:core"
import "ps:ps2"
import "ps:psx"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"
import "ps:recomp/r5900"
import "ps:recomp/vu"

// The converter child (`play --convert <disc image> <out> <vu0> <vu1>
// [<hooks>]`): the executable SYSTEM.CNF names, compiled to a native blob
// for this host at out. vu0 and vu1 are a PS2 disc's VU capture files
// (native_captures), "" for none; with either, the blob holds the VU
// microprograms too, the captured ones and those of .vutext. hooks is the
// file of the EE functions its mods hook (the recomp option mod_hooks),
// "" or absent for none. A failure exits with status 1 after a message
// (mips.fail), which is why it runs in a child.
//
// vu_only (`play --convert-vu`, the same arguments but hooks, then the
// run's pid) compiles a PS2 disc's VU microprograms alone, VU1 code
// computing status whatever its programs read, for a run to load beside
// the code it runs (midload.odin).
convert :: proc(image, out, vu0, vu1: string, hooks := "", vu_only := false) -> int {
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
	if hooks != "" {o.values["mod_hooks"] = hooks}
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

// The mods in dir, read for a PS2 game's EE when ee, else for a PS1 game.
mods_read :: proc(ee: bool, dir: string) -> (core.Mod_Set, string) {
	if ee {return ps2.mods_read_set(dir, "")}
	return psx.mods_read(dir, "")
}

// The mods child (`play --mods <psx | ee> <mods directory> <out>`): the
// functions of the mods in dir (their mod.elf's .symtab, core.mod_elf_read)
// for a PS1 game, or a PS2 game's EE when ee, compiled to a blob of mod
// functions for this host at out (psx/native/mods.odin,
// ps2/mods_native.odin). A failure exits with status 1 after a message.
compile_mods :: proc(ee: bool, dir, out: string) -> int {
	blob, ok := mods_compile(ee, dir)
	if !ok {return 1}
	defer delete(blob)
	if werr := os.write_entire_file(out, blob); werr != nil {
		fmt.eprintln("mods: cannot write", out, werr)
		return 1
	}
	return 0
}

// The blob of the functions of the mods in dir for this host, in
// context.allocator (compile_mods); false after a message.
@(private = "file")
mods_compile :: proc(ee: bool, dir: string) -> ([]u8, bool) {
	set, err := mods_read(ee, dir)
	if err != "" {
		fmt.eprintln(err)
		return nil, false
	}
	defer core.mod_set_delete(set)
	arch, ok := native.arch_of("mods", mips.HOST_ARCH)
	if !ok {
		return nil, false
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
	blob: []u8
	skipped := 0 // functions the EE's compiler left to the interpreter
	if ee {
		// The same runs: a mod function is one, entered at its first word;
		// a call between two is direct.
		blob, skipped = r5900.mods_blob(transmute([]r5900.Learned)funcs[:], arch)
	} else {
		blob = r3000.learned_blob(funcs[:], arch)
	}
	if ee {
		fmt.eprintfln("mods: %d functions from %d mods (%d not lowered, interpreted)", len(funcs) - skipped, len(set.mods), skipped)
	} else {
		fmt.eprintfln("mods: %d functions from %d mods", len(funcs), len(set.mods))
	}
	return blob, true
}

// Convert the disc image in a child of this executable (in this process in
// a wasm32 build: convert_here) and store the blob
// in the disc directory dir, its key naming the VU captures and the hooked
// set it was compiled with (native_captures). The child's output goes to
// stderr as it comes,
// on a terminal as one line rewritten in place. False, after a message
// naming the child's last line, when there is no blob. A child still
// running after deadline (0: none) is stopped (child_blob).
// A conversion the recompiler refuses (a hooked address inside a function,
// not at its entry) stores no blob: each start converts again, says why and
// interprets, until the mods change.
convert_store :: proc(image, dir: string, ps2_disc: bool, deadline: time.Duration) -> bool {
	// One read of the mods: the key's hooked set and the file's are the same.
	set, caps, text := native_captures(dir, ps2_disc)
	tmp := strings.concatenate({core.disc_path(dir, .Native, context.temp_allocator), ".convert"}, context.temp_allocator)
	// The hooked set's file, for the child's recomp option mod_hooks: written
	// whole beside it, then renamed, so the child never reads part of one.
	hooks := strings.concatenate({tmp, ".hooks"}, context.temp_allocator)
	n := 5
	if text != "" {
		part := strings.concatenate({hooks, ".part"}, context.temp_allocator)
		err := os.write_entire_file(part, transmute([]u8)text)
		if err == nil {err = os.rename(part, hooks)}
		if err != nil {
			os.remove(part)
			fmt.eprintln("play: cannot write", hooks, err)
			return false
		}
		n = 6
	}
	defer if n == 6 {os.remove(hooks)}
	when core.NATIVE_ARCH == core.NATIVE_ARCH_WASM32 {
		blob := convert_here(image, tmp, caps, hooks if n == 6 else "") or_return
	} else {
		args := [6]string{"--convert", image, tmp, caps[0], caps[1], hooks}
		blob := child_blob(args[:n], tmp, "native code", "conversion", deadline) or_return
	}
	defer delete(blob)
	return core.blob_store(dir, blob, core.COMMIT, .Native, set)
}

// convert_store's conversion in a wasm32 build, which cannot start a
// child: in this process, to tmp, read back. A failure exits with status
// 1 (convert), so this process does nothing else (`play --convert-store`):
// it leaves tmp, which the next conversion removes first, and no key.
// The conversion frees the temp allocator as it goes (once per function),
// so it runs under one of its own: the caller's temp data, the key's set
// and the paths among it, outlive it.
@(private = "file")
convert_here :: proc(image, tmp: string, caps: [2]string, hooks: string) -> ([]u8, bool) {
	os.remove(tmp)
	defer os.remove(tmp)
	status: int
	{
		scratch: mem.Dynamic_Arena
		mem.dynamic_arena_init(&scratch)
		defer mem.dynamic_arena_destroy(&scratch)
		context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
		status = convert(image, tmp, caps[0], caps[1], hooks)
	}
	if status != 0 {
		fmt.eprintln("play: no native code (the conversion failed)")
		return nil, false
	}
	blob, err := os.read_entire_file(tmp, context.allocator)
	if err != nil || !core.blob_valid(blob) {
		delete(blob)
		fmt.eprintln("play: no native code (the conversion wrote no valid blob)")
		return nil, false
	}
	return blob, true
}

// `play --convert-store <disc image>`: the native blob of the disc image
// stored in its directory, converted unless one this build can run is
// there already. A wasm32 build's play runs only a stored blob (and only a
// PS2 disc's), so the play page runs this first, in its own instance: the
// conversion's memory is not the game's. 0 when a blob is stored, 1 when
// none is (a dev build stores none it would use).
convert_store_mode :: proc(image: string) -> int {
	id, cnf, _, ok := identify(image)
	if !ok {return 1}
	dir, has_dir := core.disc_dir(id)
	if !has_dir {return 1}
	when core.NATIVE_ARCH == core.NATIVE_ARCH_WASM32 {
		if !cnf.ps2 {
			fmt.eprintln("play: a wasm32 build runs native code for a PS2 disc only")
			return 1
		}
	}
	if core.COMMIT == "dev" {
		fmt.eprintln("play: a dev build stores no native code it would run")
		return 1
	}
	if native_cached(dir, cnf.ps2) {
		fmt.eprintln("play: the native code is stored already")
		return 0
	}
	return 0 if convert_store(image, dir, cnf.ps2, 0) else 1
}

// Whether the disc directory dir holds a native blob this build can run,
// compiled with the VU captures and the hooked set dir holds now
// (native_captures).
native_cached :: proc(dir: string, ps2_disc: bool) -> bool {
	set, _, _ := native_captures(dir, ps2_disc)
	return core.blob_cached(dir, core.COMMIT, .Native, set)
}

// The VU capture files of the disc directory dir (VU_CAPTURE) that add
// programs, each unit's path or "", and the set the native blob's key names
// them by: "vu0 <fingerprint> vu1 <fingerprint>", "-" for a unit without
// one, and "" when neither has one, so a blob compiled without captures
// keeps its key. A capture that grows by new entries changes its
// fingerprint, and the blob is compiled again; one that only repeats
// records does not (vu.capture_fingerprint). A PS2 disc whose mods hook EE
// functions adds " mod_hooks <hash>" (native_hooks), so a blob built for no
// mods keeps its key; hooks is that set's file (native_hooks). Temp
// allocated.
native_captures :: proc(dir: string, ps2_disc: bool) -> (set: string, caps: [2]string, hooks: string) {
	set, caps = vu_captures(dir)
	h: u64
	if hooks, h = native_hooks(dir, ps2_disc); h != 0 {
		set = fmt.tprintf("%s%smod_hooks %016x", set, set == "" ? "" : " ", h)
	}
	return
}

// The EE functions the mods of PS2 disc directory dir hook, one hex address
// per line (the recomp option mod_hooks), and the hash of that set
// (ps2.mods_read); "" and 0 for none, or a PS1 disc. Mods that cannot be
// read hook none here: the boot says why. Temp allocated.
native_hooks :: proc(dir: string, ps2_disc: bool) -> (text: string, hash: u64) {
	if !ps2_disc {return}
	set, h, err := ps2.mods_read(core.disc_path(dir, .Mods, context.temp_allocator), "")
	if err != "" {return}
	defer core.mod_set_delete(set)
	if h == 0 {return}
	b := strings.builder_make(context.temp_allocator)
	for k in set.hooks {fmt.sbprintfln(&b, "%08x", k.key.addr)}
	return strings.to_string(b), h
}

// native_captures' VU half.
@(private = "file")
vu_captures :: proc(dir: string) -> (set: string, caps: [2]string) {
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
// of this executable (as convert_store; in this process in a wasm32 build,
// which cannot start one, and whose compile of a few functions needs no
// memory of its own) and store the blob in the disc directory dir, its key
// naming the mod set by set. False, after a message, when there is no blob.
mods_store :: proc(ee: bool, mods, dir, set: string, deadline: time.Duration) -> bool {
	when core.NATIVE_ARCH == core.NATIVE_ARCH_WASM32 {
		blob := mods_compile(ee, mods) or_return
	} else {
		tmp := strings.concatenate({core.disc_path(dir, .Mods_Native, context.temp_allocator), ".compile"}, context.temp_allocator)
		blob := child_blob({"--mods", "ee" if ee else "psx", mods, tmp}, tmp, "native code for the mods", "mods compile", deadline) or_return
	}
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
