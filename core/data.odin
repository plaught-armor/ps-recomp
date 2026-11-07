// The user data directory: what the player keeps for each disc, under
// discs/<disc id> (core/disc id):
//
//   <data>/discs/<id>/
//     disc.tsv             what the player knows of the disc
//     native.<arch>.bin    native code compiled for it (recomp/native)
//     native.<arch>.key    the blob format and build that wrote it
//     learned.<arch>.bin   native code for the runs learn/ holds (play LEARN)
//     learned.<arch>.key   the blob format, build and learn/psx.bin it is for
//     learned-iop.<arch>.bin  the same for a PS2 game's IOP (learn/ps2.bin)
//     learned-iop.<arch>.key
//     learned-ee.<arch>.bin   the same for a PS2 game's EE (learn/ps2.bin)
//     learned-ee.<arch>.key
//     cards/  saves/  settings.tsv  compat.log  learn/
//     thumb.ppm            the picture a run last showed (thumb.odin)
//     play.log             what the last run the launcher started printed
//     press.txt            a PRESS script for compatibility runs
//     switches.<arch>.txt  native entries a thread switch was fatal under
//                          (wasm32, known_switches)
//
// <data> is the DATA setting, else SDL's per-user directory for ps-recomp
// (~/.local/share/ps-recomp, ~/Library/Application Support/ps-recomp,
// %APPDATA%\ps-recomp).
package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl2"

// The ps-recomp commit this build is from (-define:COMMIT=<hash>); "dev"
// without one. A dev build never trusts a cached blob: its code may differ
// from any build that wrote one.
COMMIT :: #config(COMMIT, "dev")

Disc_File :: enum {
	Info,
	Native,
	Native_Key,
	Learned,
	Learned_Key,
	Learned_Iop,
	Learned_Iop_Key,
	Learned_Ee,
	Learned_Ee_Key,
	Mods_Native,
	Mods_Native_Key,
	Cards,
	Compat_Cards,
	Saves,
	Settings,
	Compat_Log,
	Compat_Progress,
	Learn,
	Mods,
	Press,
	Thumb,
	Play_Log,
	Vu0_Capture,
	Vu1_Capture,
	Switches,
}

DISC_FILES :: [Disc_File]string {
	.Info            = "disc.tsv",
	.Native          = "native." + NATIVE_ARCH_NAME + ".bin",
	.Native_Key      = "native." + NATIVE_ARCH_NAME + ".key",
	.Learned         = "learned." + NATIVE_ARCH_NAME + ".bin",
	.Learned_Key     = "learned." + NATIVE_ARCH_NAME + ".key",
	.Learned_Iop     = "learned-iop." + NATIVE_ARCH_NAME + ".bin",
	.Learned_Iop_Key = "learned-iop." + NATIVE_ARCH_NAME + ".key",
	.Learned_Ee      = "learned-ee." + NATIVE_ARCH_NAME + ".bin",
	.Learned_Ee_Key  = "learned-ee." + NATIVE_ARCH_NAME + ".key",
	.Mods_Native     = "mods." + NATIVE_ARCH_NAME + ".bin",
	.Mods_Native_Key = "mods." + NATIVE_ARCH_NAME + ".key",
	.Cards           = "cards",
	.Compat_Cards    = "compat-cards",
	.Saves           = "saves",
	.Settings        = "settings.tsv",
	.Compat_Log      = "compat.log",
	.Compat_Progress = "compat.progress",
	.Learn           = "learn",
	.Mods            = "mods",
	.Press           = "press.txt",
	.Thumb           = "thumb.ppm",
	.Play_Log        = "play.log",
	.Vu0_Capture     = "vu0-capture.bin",
	.Vu1_Capture     = "vu1-capture.bin",
	.Switches        = "switches." + NATIVE_ARCH_NAME + ".txt",
}

// The data directory, created if missing. False, after a message, when it
// cannot be.
data_dir :: proc(allocator := context.allocator) -> (dir: string, ok: bool) {
	if d := env("DATA"); d != "" {
		make_dir(d) or_return
		return strings.clone(d, allocator), true
	}
	p := sdl.GetPrefPath("", "ps-recomp")
	if p == nil {
		fmt.eprintln("sdl: no user data directory:", sdl.GetError())
		return "", false
	}
	defer sdl.free(rawptr(p))
	return strings.clone(strings.trim_right(string(p), "/\\"), allocator), true
}

// The disc's directory, created if missing. False, after a message, for an
// id core/disc did not make or a directory that cannot be created.
disc_dir :: proc(id: string, allocator := context.allocator) -> (dir: string, ok: bool) {
	if id == "" || id[0] == '.' {
		fmt.eprintln("not a disc id:", id)
		return "", false
	}
	for c in transmute([]u8)id {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '0' ..= '9', '-', '.':
		case:
			fmt.eprintln("not a disc id:", id)
			return "", false
		}
	}
	data := data_dir(context.temp_allocator) or_return
	dir, _ = filepath.join({data, "discs", id}, allocator)
	if !make_dir(dir) {
		delete(dir, allocator)
		return "", false
	}
	return dir, true
}

// The path of one of a disc directory's files; directories are not created.
disc_path :: proc(dir: string, f: Disc_File, allocator := context.allocator) -> string {
	files := DISC_FILES
	path, _ := filepath.join({dir, files[f]}, allocator)
	return path
}

// A disc directory's blobs: the executable's native code, and the learned
// functions (play's LEARN) of a PS1 game or of a PS2 game's IOP or EE,
// whose key also names the records they are from, and the functions of
// the game's mods, whose key names the mod set (mod_set_hash).
Blob_Kind :: enum {
	Native,
	Learned,
	Learned_Iop,
	Learned_Ee,
	Mods,
}

@(private = "file")
BLOB_FILES :: [Blob_Kind][2]Disc_File {
	.Native      = {.Native, .Native_Key},
	.Learned     = {.Learned, .Learned_Key},
	.Learned_Iop = {.Learned_Iop, .Learned_Iop_Key},
	.Learned_Ee  = {.Learned_Ee, .Learned_Ee_Key},
	.Mods        = {.Mods_Native, .Mods_Native_Key},
}

// Whether the disc directory holds a blob this build can run: its key names
// this blob format and commit (and set: for a learned blob the records,
// for the mods blob the mod set),
// and its header this format and host arch. Never for a dev build.
blob_cached :: proc(dir: string, commit := COMMIT, kind := Blob_Kind.Native, set := "") -> bool {
	if commit == "dev" {
		return false
	}
	files := BLOB_FILES
	key, err := os.read_entire_file(disc_path(dir, files[kind][1], context.temp_allocator), context.temp_allocator)
	if err != nil || string(key) != blob_key(commit, set) {
		return false
	}
	f: ^os.File
	if f, err = os.open(disc_path(dir, files[kind][0], context.temp_allocator)); err != nil {
		return false
	}
	defer os.close(f)
	head: [NATIVE_HEADER]u8
	n, _ := os.read_full(f, head[:])
	return blob_valid(head[:n])
}

// Whether blob (or its first NATIVE_HEADER bytes) starts with a whole header
// of this format and host arch; native_load checks the rest.
blob_valid :: proc(blob: []u8) -> bool {
	if len(blob) < NATIVE_HEADER {
		return false
	}
	word :: proc(b: []u8) -> u32 {
		return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
	}
	return word(blob[0:]) == NATIVE_MAGIC && word(blob[4:]) == NATIVE_VERSION && word(blob[8:]) == NATIVE_ARCH
}

// Store a blob in the disc directory with its key (blob_cached). The old
// key goes first and the new one last, each file written whole, so a crash
// or a failed write leaves no key naming a blob it does not match. False,
// after a message, on a failure.
blob_store :: proc(dir: string, blob: []u8, commit := COMMIT, kind := Blob_Kind.Native, set := "") -> bool {
	files := BLOB_FILES
	key_path := disc_path(dir, files[kind][1], context.temp_allocator)
	path := disc_path(dir, files[kind][0], context.temp_allocator)
	if err := os.remove(key_path); err != nil && os.exists(key_path) {
		fmt.eprintln("cannot remove", key_path, err)
		return false
	}
	if err := write_file_atomic(path, blob); err != nil {
		fmt.eprintln("cannot write", path, err)
		return false
	}
	if err := write_file_atomic(key_path, transmute([]u8)blob_key(commit, set)); err != nil {
		fmt.eprintln("cannot write", key_path, err)
		return false
	}
	return true
}

@(private = "file")
blob_key :: proc(commit, set: string) -> string {
	if set == "" {
		return fmt.tprintf("%d %s\n", NATIVE_VERSION, commit)
	}
	return fmt.tprintf("%d %s %s\n", NATIVE_VERSION, commit, set)
}

@(private = "file")
make_dir :: proc(path: string) -> bool {
	err := os.make_directory_all(path)
	if err == nil || err == .Exist && os.is_dir(path) {
		return true
	}
	fmt.eprintln("cannot create", path, err)
	return false
}

// The native entries a thread switch was fatal under (a wasm32 PS1 run,
// psx/cpu flat_block), which play leaves to the interpreter on the runs
// after: one hex address a line in the disc directory's Switches file.
// Temp allocated; none when the file is missing. A line that is no address
// is skipped.
known_switches :: proc(dir: string) -> []u32 {
	data, err := os.read_entire_file(disc_path(dir, .Switches, context.temp_allocator), context.temp_allocator)
	if err != nil {return nil}
	out := make([dynamic]u32, context.temp_allocator)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		v, ok := strconv.parse_u64_of_base(strings.trim_space(line), 16)
		if ok && v <= u64(max(u32)) {append(&out, u32(v))}
	}
	return out[:]
}

// Add entries (0s skipped) to the Switches file (known_switches), each
// once. False, after a message, when it cannot be written.
known_switches_add :: proc(dir: string, entries: []u32) -> bool {
	old := known_switches(dir)
	sb := strings.builder_make(context.temp_allocator)
	for e in old {fmt.sbprintfln(&sb, "%08x", e)}
	n := 0
	outer: for e, k in entries {
		if e == 0 {continue}
		for o in old {
			if o == e {continue outer}
		}
		for p in entries[:k] {
			if p == e {continue outer}
		}
		fmt.sbprintfln(&sb, "%08x", e)
		n += 1
	}
	if n == 0 {return true}
	path := disc_path(dir, .Switches, context.temp_allocator)
	if err := write_file_atomic(path, transmute([]u8)strings.to_string(sb)); err != nil {
		fmt.eprintln("cannot write", path, err)
		return false
	}
	return true
}
