// core.read_dir lists a directory on the host and on wasi_wasm32 alike:
// every entry once, with its type, and none of "." and "..", for a
// directory whose dirents fill fd_readdir's first buffer several times
// over. It writes into a new temporary directory on the host and removes
// it after, into the preopen's in-memory one under Node (run.mjs):
//
//   odin run tests/read_dir -collection:ps=.
//   odin build tests/read_dir -collection:ps=. -target:wasi_wasm32 -out:read_dir.wasm
//   node tests/read_dir/run.mjs read_dir.wasm
package test_read_dir

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "ps:core"

FILES :: 40

main :: proc() {
	when ODIN_OS == .WASI {
		dir := "listed"
		check(os.make_directory(dir) == nil, "cannot make the directory")
	} else {
		dir, terr := os.make_directory_temp("", "read_dir-*", context.temp_allocator)
		check(terr == nil, fmt.tprintf("cannot make a temporary directory: %v", terr))
		defer os.remove_all(dir)
	}
	want := make([dynamic]string, context.temp_allocator)
	for k in 0 ..< FILES {
		// Long names: 40 of them are over 2 KiB of dirents.
		name := fmt.tprintf("file-%02d-with-a-long-enough-name-to-fill", k)
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		check(os.write_entire_file(path, transmute([]u8)name) == nil, "cannot write a file")
		append(&want, name)
	}
	sub, _ := filepath.join({dir, "sub"}, context.temp_allocator)
	check(os.make_directory(sub) == nil, "cannot make the subdirectory")
	append(&want, "sub")

	infos, err := core.read_dir(dir, context.allocator)
	check(err == nil, fmt.tprintf("read_dir: %v", err))
	defer os.file_info_slice_delete(infos, context.allocator)
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	slice.sort(want[:])
	check(len(infos) == len(want), fmt.tprintf("%d entries, want %d", len(infos), len(want)))
	for fi, k in infos {
		check(fi.name == want[k], fmt.tprintf("entry %d is %q, want %q", k, fi.name, want[k]))
		kind: os.File_Type = .Directory if fi.name == "sub" else .Regular
		check(fi.type == kind, fmt.tprintf("%s is a %v, want %v", fi.name, fi.type, kind))
		// The host makes it absolute; wasi keeps it as given.
		check(filepath.base(fi.fullpath) == fi.name && os.is_file(fi.fullpath) == (kind == .Regular), fmt.tprintf("%s: fullpath %q", fi.name, fi.fullpath))
	}
	_, merr := core.read_dir(sub, context.temp_allocator)
	check(merr == nil, "an empty directory does not list")
	missing, _ := filepath.join({dir, "missing"}, context.temp_allocator)
	_, nerr := core.read_dir(missing, context.temp_allocator)
	check(nerr != nil, "a missing directory lists")
	fmt.println("read_dir: ok")
}

check :: proc(ok: bool, what: string) {
	if !ok {
		fmt.eprintln("read_dir:", what)
		os.exit(1)
	}
}
