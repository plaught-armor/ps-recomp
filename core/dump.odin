// Headless and regression runs.
//
// HEADLESS=1: no window on screen and every controller ignored, so the only
// input is a replay or a script and two runs see the same frames. The game
// also opens no audio device (audio_init with `device` false) and runs
// unpaced.
//
// DUMP=<dir>: the game writes pictures and memory into dir as
// <kind>_<frame>.<ext>, from frame DUMP_FROM (default 1) every DUMP_EVERY
// frames (default 1). With DUMP_HASH=1 each dump is instead a line
// "<kind>\t<frame>\t<XXH3 of data>" in <dir>/hashes.tsv, which two runs can
// be diffed by for the first frame they diverge. With DUMP_FD=<n> each dump
// is instead written whole to the open file descriptor n (a pipe from a
// harness comparing two runs as they go) as "<kind>\t<frame>\t<bytes>\n"
// and the data; DUMP still decides which frames are dumped.
package core

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:strconv"
import sdl "vendor:sdl2"

headless: bool

@(private = "file")
dump: struct {
	dir:    string,
	from:   u64,
	every:  u64,
	hashes: ^os.File,
	stream: ^os.File,
}

// Read HEADLESS and set SDL up for it. Call before SDL_Init.
headless_init :: proc() {
	headless = env("HEADLESS") == "1"
	if headless {
		sdl.SetHint("SDL_VIDEODRIVER", "offscreen")
		sdl.SetHint(sdl.HINT_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT, "0x0000/0x0000")
	}
}

// Read the DUMP settings; false (after a message) for a bad one or a
// hashes.tsv that cannot be created.
dump_init :: proc() -> bool {
	dump.dir = env("DUMP", context.allocator)
	dump.from = dump_period("DUMP_FROM") or_return
	dump.every = dump_period("DUMP_EVERY") or_return
	if fd := env("DUMP_FD"); dump.dir != "" && fd != "" {
		n, ok := strconv.parse_uint(fd)
		if !ok {
			fmt.eprintln(env_name("DUMP_FD"), "is not a file descriptor:", fd)
			return false
		}
		dump.stream = os.new_file(uintptr(n), "dump stream")
		if dump.stream == nil {
			fmt.eprintln(env_name("DUMP_FD"), "is not open:", fd)
			return false
		}
	} else if dump.dir != "" && env("DUMP_HASH") == "1" {
		path := fmt.tprintf("%s/hashes.tsv", dump.dir)
		f, err := os.create(path)
		if err != nil {
			fmt.eprintln(ENV_PREFIX + "DUMP_HASH: cannot create", path, err)
			return false
		}
		dump.hashes = f
	}
	return true
}

// The DUMP directory, "" when unset, for a game's dumps not tied to a frame.
dump_dir :: proc() -> string {
	return dump.dir
}

// Whether frame `frame` is dumped: from DUMP_FROM on, every DUMP_EVERY
// frames, or every `every` frames for a kind with its own period.
dump_due :: proc(frame: u64, every: u64 = 0) -> bool {
	n := every == 0 ? dump.every : every
	return dump.dir != "" && frame >= dump.from && frame % n == 0
}

// Write one dump of frame `frame`, or its hash line.
dump_put :: proc(kind, ext: string, frame: u64, data: []u8) {
	if dump.stream != nil {
		head := fmt.tprintf("%s\t%d\t%d\n", kind, frame, len(data))
		_, err := os.write_string(dump.stream, head)
		if err == nil {
			_, err = os.write(dump.stream, data)
		}
		if err != nil {
			fmt.eprintln(ENV_PREFIX + "DUMP_FD: write failed:", err)
		}
		return
	}
	if dump.hashes != nil {
		line := fmt.tprintf("%s\t%d\t%016x\n", kind, frame, xxhash.XXH3_64_default(data))
		if _, err := os.write_string(dump.hashes, line); err != nil {
			fmt.eprintln(ENV_PREFIX + "DUMP_HASH: write failed:", err)
		}
		return
	}
	name := fmt.tprintf("%s/%s_%05d.%s", dump.dir, kind, frame, ext)
	if err := os.write_entire_file(name, data); err != nil {
		fmt.eprintln(ENV_PREFIX + "DUMP: write failed:", name, err)
	}
}

// Write a w x h picture of RGB888 pixels, rows top first, as a PPM dump.
dump_ppm :: proc(kind: string, frame: u64, w, h: int, rgb: []u8) {
	assert(len(rgb) == w * h * 3)
	buf := make([dynamic]u8, context.temp_allocator)
	append(&buf, ..transmute([]u8)fmt.tprintf("P6\n%d %d\n255\n", w, h))
	append(&buf, ..rgb)
	dump_put(kind, "ppm", frame, buf[:])
}

@(private = "file")
dump_period :: proc(name: string) -> (u64, bool) {
	v := env(name)
	if v == "" {
		return 1, true
	}
	n, ok := strconv.parse_u64(v)
	if !ok || n == 0 {
		fmt.eprintln(env_name(name), "is not a positive number:", v)
		return 0, false
	}
	return n, true
}
