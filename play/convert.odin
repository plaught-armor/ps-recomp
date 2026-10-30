package play

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"
import "ps:recomp/mips"
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

// Convert the disc image in a child of this executable and store the blob
// in the disc directory dir. The child's output goes to stderr as it comes,
// on a terminal as one line rewritten in place. False, after a message
// naming the child's last line, when there is no blob.
convert_store :: proc(image, dir: string) -> bool {
	self, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		fmt.eprintln("play: cannot find this executable:", err)
		return false
	}
	// A temporary file a crash left behind is overwritten, never used.
	tmp := strings.concatenate({core.disc_path(dir, .Native, context.temp_allocator), ".convert"}, context.temp_allocator)
	defer os.remove(tmp)
	r, w: ^os.File
	if r, w, err = os.pipe(); err != nil {
		fmt.eprintln("play: cannot make a pipe:", err)
		return false
	}
	defer os.close(r)
	p: os.Process
	{
		defer os.close(w)
		p, err = os.process_start({command = {self, "--convert", image, tmp}, stdout = w, stderr = w})
	}
	if err != nil {
		fmt.eprintln("play: cannot start the converter:", err)
		return false
	}
	last := relay(r)
	state, werr := os.process_wait(p)
	if werr != nil || !state.exited || state.exit_code != 0 {
		fmt.eprintfln("play: no native code (the conversion failed: %s)", last)
		return false
	}
	blob, rerr := os.read_entire_file(tmp, context.allocator)
	defer delete(blob)
	if rerr != nil || !core.blob_valid(blob) {
		fmt.eprintln("play: no native code (the conversion wrote no valid blob)")
		return false
	}
	return core.blob_store(dir, blob)
}

// Copy the child's output from r to stderr until it closes; on a terminal
// each line overwrites the one before. The last non-empty line, temp
// allocated.
@(private = "file")
relay :: proc(r: ^os.File) -> string {
	tty := os.is_tty(os.stderr)
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
