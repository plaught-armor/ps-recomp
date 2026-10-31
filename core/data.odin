// The user data directory: what the player keeps for each disc, under
// discs/<disc id> (core/disc id):
//
//   <data>/discs/<id>/
//     disc.tsv             what the player knows of the disc
//     native.<arch>.bin    native code compiled for it (recomp/native)
//     native.<arch>.key    the blob format and build that wrote it
//     cards/  saves/  settings.tsv  compat.log  learn/
//     press.txt            a PRESS script for compatibility runs
//
// <data> is the DATA setting, else SDL's per-user directory for ps-recomp
// (~/.local/share/ps-recomp, ~/Library/Application Support/ps-recomp,
// %APPDATA%\ps-recomp).
package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
	Cards,
	Saves,
	Settings,
	Compat_Log,
	Learn,
	Press,
}

DISC_FILES :: [Disc_File]string {
	.Info       = "disc.tsv",
	.Native     = "native." + NATIVE_ARCH_NAME + ".bin",
	.Native_Key = "native." + NATIVE_ARCH_NAME + ".key",
	.Cards      = "cards",
	.Saves      = "saves",
	.Settings   = "settings.tsv",
	.Compat_Log = "compat.log",
	.Learn      = "learn",
	.Press      = "press.txt",
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

// Whether the disc directory holds a blob this build can run: its key names
// this blob format and commit, and its header this format and host arch.
// Never for a dev build.
blob_cached :: proc(dir: string, commit := COMMIT) -> bool {
	if commit == "dev" {
		return false
	}
	key, err := os.read_entire_file(disc_path(dir, .Native_Key, context.temp_allocator), context.temp_allocator)
	if err != nil || string(key) != blob_key(commit) {
		return false
	}
	f: ^os.File
	if f, err = os.open(disc_path(dir, .Native, context.temp_allocator)); err != nil {
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

// Store a blob in the disc directory with its key. The old key goes first
// and the new one last, each file written whole, so a crash or a failed
// write leaves no key naming a blob it does not match. False, after a
// message, on a failure.
blob_store :: proc(dir: string, blob: []u8, commit := COMMIT) -> bool {
	key_path := disc_path(dir, .Native_Key, context.temp_allocator)
	path := disc_path(dir, .Native, context.temp_allocator)
	if err := os.remove(key_path); err != nil && os.exists(key_path) {
		fmt.eprintln("cannot remove", key_path, err)
		return false
	}
	if err := write_file_atomic(path, blob); err != nil {
		fmt.eprintln("cannot write", path, err)
		return false
	}
	if err := write_file_atomic(key_path, transmute([]u8)blob_key(commit)); err != nil {
		fmt.eprintln("cannot write", key_path, err)
		return false
	}
	return true
}

@(private = "file")
blob_key :: proc(commit: string) -> string {
	return fmt.tprintf("%d %s\n", NATIVE_VERSION, commit)
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
