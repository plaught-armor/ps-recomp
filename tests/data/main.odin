// User data directory test, under a DATA setting in the OS temp directory:
// the directory and a disc's are created when missing, an id core/disc
// cannot make is refused, and a stored blob is cached only for the commit
// that stored it, a blob header of this format and host arch, and never for
// a dev build; no temporary file is left behind. On Linux, with DATA empty,
// the directory is SDL's under XDG_DATA_HOME. It is all removed at the end
// whether the test passes or fails.
package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "ps:core"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL data: %s (line %d)", what, loc.line)
		failed += 1
	}
}

ID :: "SLUS-12345.0123456789abcdef"

// A blob header (magic, version, arch) and a few bytes of body.
@(private = "file")
blob :: proc(version, arch: u32) -> []u8 {
	b := make([]u8, core.NATIVE_HEADER, context.temp_allocator)
	endian.put_u32(b[0:], .Little, core.NATIVE_MAGIC)
	endian.put_u32(b[4:], .Little, version)
	endian.put_u32(b[8:], .Little, arch)
	return b
}

@(private = "file")
test_dirs :: proc(data: string) -> (dir: string) {
	got, ok := core.data_dir(context.temp_allocator)
	check(ok && got == data && os.is_dir(data), "data dir")
	dir, ok = core.disc_dir(ID, context.temp_allocator)
	want, _ := filepath.join({data, "discs", ID}, context.temp_allocator)
	check(ok && dir == want && os.is_dir(dir), "disc dir")
	_, ok = core.disc_dir(ID, context.temp_allocator)
	check(ok, "disc dir again")
	for bad in ([]string{"", ".", "..", "../x", ".x", "a/b", "a\\b", "a b"}) {
		_, ok = core.disc_dir(bad, context.temp_allocator)
		check(!ok, fmt.tprintf("disc id %q", bad))
	}
	native := core.disc_path(dir, .Native, context.temp_allocator)
	check(filepath.base(native) == "native." + core.NATIVE_ARCH_NAME + ".bin", "native path")
	return dir
}

@(private = "file")
V :: core.NATIVE_VERSION

@(private = "file")
test_blob :: proc(dir: string) {
	check(core.COMMIT == "dev", "a test build is dev")
	check(!core.blob_cached(dir, "abc"), "no blob cached")
	check(core.blob_store(dir, blob(V, core.NATIVE_ARCH), "abc"), "store")
	check(core.blob_cached(dir, "abc"), "blob cached")
	check(!core.blob_cached(dir, "abd"), "blob of another commit")
	check(!core.blob_cached(dir, "dev"), "blob for a dev build")
	key, err := os.read_entire_file(core.disc_path(dir, .Native_Key, context.temp_allocator), context.temp_allocator)
	check(err == nil && string(key) == fmt.tprintf("%d abc\n", V), "key")
	check(core.blob_store(dir, blob(V, core.NATIVE_ARCH), "dev"), "store from a dev build")
	check(!core.blob_cached(dir, "dev"), "dev blob for a dev build")
	other_arch := core.NATIVE_ARCH == 1 ? u32(3) : u32(1)
	bad := [][]u8{blob(V, other_arch), blob(V + 1, core.NATIVE_ARCH), blob(V, core.NATIVE_ARCH)[:8]}
	for b, i in bad {
		check(core.blob_store(dir, b, "abc"), "store")
		check(!core.blob_cached(dir, "abc"), fmt.tprintf("bad blob %d", i))
	}
	// A blob whose key is gone is not cached.
	check(core.blob_store(dir, blob(V, core.NATIVE_ARCH), "abc"), "store")
	check(os.remove(core.disc_path(dir, .Native_Key, context.temp_allocator)) == nil, "remove key")
	check(!core.blob_cached(dir, "abc"), "blob with no key")
	files, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	check(len(files) == 1, "files left")
	for f in files {
		check(!strings.has_suffix(f.name, core.ATOMIC_TMP), fmt.tprintf("left %s", f.name))
	}
}

main :: proc() {
	tmp, err := os.make_directory_temp("", "ps_data_test_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL data: no temp directory:", err)
		os.exit(1)
	}
	data, _ := filepath.join({tmp, "data"}, context.allocator)
	if os.set_env(core.env_name("DATA"), data) != nil {
		fmt.eprintln("FAIL data: cannot set", core.env_name("DATA"))
		os.exit(1)
	}
	test_blob(test_dirs(data))
	// With DATA empty, SDL's directory: on Linux under XDG_DATA_HOME.
	when ODIN_OS == .Linux {
		xdg, _ := filepath.join({tmp, "xdg"}, context.allocator)
		want, _ := filepath.join({xdg, "ps-recomp"}, context.allocator)
		_ = os.set_env(core.env_name("DATA"), "")
		_ = os.set_env("XDG_DATA_HOME", xdg)
		got, ok := core.data_dir(context.temp_allocator)
		check(ok && got == want && os.is_dir(want), "SDL data dir")
	}
	if os.remove_all(tmp) != nil {
		check(false, fmt.tprintf("cannot remove %s", tmp))
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok data")
}
