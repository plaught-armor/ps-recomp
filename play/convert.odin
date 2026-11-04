package play

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"
import "ps:recomp/r5900"

// The converter child (`play --convert <disc image> <out>`): the executable
// SYSTEM.CNF names, compiled to a native blob for this host at out. A
// failure exits with status 1 after a message (mips.fail), which is why it
// runs in a child.
convert :: proc(image, out: string) -> int {
	o := mips.disc_options(image, "")
	o.values["native_out"] = out
	fmt.eprintln("converting", image)
	switch b := mips.option(o, "backend"); b {
	case "r3000": r3000.generate(o)
	case "r5900": r5900.generate(o)
	case: mips.fail("%s: unknown backend %s", image, b)
	}
	return 0
}

// The learned child (`play --learned <psx | iop> <records> <out>`): the
// runs of the PS1 or IOP processor in the LEARN file at records that native
// code can stand for (core.learn_compilable), compiled to a blob of learned
// functions for this host at out (psx/native/learned.odin). Both run the
// R3000 of psx_cpu, so one compiler serves them.
compile_learned :: proc(cpu: core.Learn_Cpu, records, out: string) -> int {
	data, err := os.read_entire_file(records, context.allocator)
	if err != nil {
		fmt.eprintln("learned: cannot read", records, err)
		return 1
	}
	recs, _ := core.learn_read(data)
	runs, large, smc := core.learn_compilable(recs[:], cpu)
	funcs := make([]r3000.Learned, len(runs))
	for r, k in runs {
		funcs[k] = {r.entry, r.lo, r.words}
	}
	arch, _ := native.parse_arch(mips.HOST_ARCH)
	if werr := os.write_entire_file(out, r3000.learned_blob(funcs, arch)); werr != nil {
		fmt.eprintln("learned: cannot write", out, werr)
		return 1
	}
	fmt.eprintfln("learned: %d functions from %d records (not compiled: %d stored into their code, %d large)", len(runs), len(recs), smc, large)
	return 0
}

// Convert the disc image in a child of this executable and store the blob
// in the disc directory dir. The child's output goes to stderr as it comes,
// on a terminal as one line rewritten in place. False, after a message
// naming the child's last line, when there is no blob.
convert_store :: proc(image, dir: string) -> bool {
	tmp := strings.concatenate({core.disc_path(dir, .Native, context.temp_allocator), ".convert"}, context.temp_allocator)
	blob := child_blob({"--convert", image, tmp}, tmp, "native code", "conversion") or_return
	defer delete(blob)
	return core.blob_store(dir, blob)
}

// Compile the LEARN file at records in a child of this executable (as
// convert_store) and store the blob of learned functions in the disc
// directory dir, its key naming the records by set. False, after a
// message, when there is no blob.
learned_store :: proc(cpu: core.Learn_Cpu, records, dir, set: string) -> bool {
	l := learned_files(cpu)
	tmp := strings.concatenate({core.disc_path(dir, l.blob, context.temp_allocator), ".compile"}, context.temp_allocator)
	blob := child_blob({"--learned", l.name, records, tmp}, tmp, "learned code", "compile") or_return
	defer delete(blob)
	return core.blob_store(dir, blob, core.COMMIT, l.kind, set)
}

// Run this executable with args, which write a blob to tmp, relaying its
// output. The blob, in context.allocator; false, after a message naming
// what has none and the child's last line, when it wrote no valid one.
@(private = "file")
child_blob :: proc(args: []string, tmp, what, step: string) -> ([]u8, bool) {
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
	last := relay(r)
	state, werr := os.process_wait(p)
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
