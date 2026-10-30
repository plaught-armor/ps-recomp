// play test: play runs small synthetic PS1 discs (a PS-X EXE that loops on
// one branch) headless to FRAMES, under a DATA setting in the OS temp
// directory. The test runs itself as play, the converter child included.
// - native, psx_exe: a disc with SYSTEM.CNF, and one with only PSX.EXE,
//   convert; the blob and its key land in the disc's directory, the
//   temporary file a crash left there is overwritten and gone, the memory
//   cards directory is made, and the game runs to FRAMES with status 0. A
//   second run uses the stored blob with no conversion;
// - bad_blob: a stored blob with a whole header but cut short will not
//   load; play says so, removes its key and exits with status 1;
// - interpreted: a converter that cannot write its output (a directory in
//   the way) fails; play says it has no native code, stores nothing, and
//   runs the game to FRAMES interpreted.
// It is all removed at the end whether the test passes or fails. Build it
// with -define:COMMIT=test: a dev build never uses a stored blob.
package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "ps:core"
import "ps:core/disc"
import "ps:play"
import "ps:tests/discimg"

@(private = "file")
FRAMES :: 5

@(private = "file")
failed: int

@(private = "file")
check :: proc(name: string, ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL play %s: %s (line %d)", name, what, loc.line)
		failed += 1
	}
}

@(private = "file")
tmp: string

main :: proc() {
	if len(os.args) > 1 {
		os.exit(play.run(os.args))
	}
	if core.COMMIT != "test" {
		fmt.eprintln("FAIL play: build with -define:COMMIT=test")
		os.exit(1)
	}
	err: os.Error
	tmp, err = os.make_directory_temp("", "ps_play_test_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL play: no temp directory:", err)
		os.exit(1)
	}
	data, _ := filepath.join({tmp, "data"}, context.allocator)
	os.set_env(core.env_name("DATA"), data)
	os.set_env(core.env_name("HEADLESS"), "1")
	os.set_env(core.env_name("FRAMES"), fmt.tprint(FRAMES))
	os.set_env(core.env_name("SW"), "1") // no Vulkan device needed
	os.set_env(core.env_name("GPU"), "sw")
	test_native("native", cnf_disc())
	test_bad_blob(test_native("psx_exe", exe_disc()))
	test_interpreted()
	if os.remove_all(tmp) != nil {
		check("", false, fmt.tprintf("cannot remove %s", tmp))
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok play")
}

// A PS-X EXE: header, then at 0x80010000 `b .` and its delay slot.
@(private = "file")
exe :: proc() -> []u8 {
	e := make([]u8, 0x1000, context.temp_allocator)
	copy(e, "PS-X EXE")
	endian.put_u32(e[0x10:], .Little, 0x80010000) // pc
	endian.put_u32(e[0x18:], .Little, 0x80010000) // text address
	endian.put_u32(e[0x1c:], .Little, 0x800) // text size
	endian.put_u32(e[0x30:], .Little, 0x801ffff0) // sp
	endian.put_u32(e[0x800:], .Little, 0x1000ffff)
	return e
}

// A disc with SYSTEM.CNF naming DATA/PSX.EXE; extra goes in SYSTEM.CNF.
@(private = "file")
cnf_disc :: proc(extra := "") -> []u8 {
	cnf := strings.concatenate({"BOOT = cdrom:\\DATA\\PSX.EXE;1\n", extra}, context.temp_allocator)
	return discimg.make_iso(cnf, sub_name = "PSX.EXE;1", sub = string(exe()))
}

// A disc with PSX.EXE in the root, where make_iso puts SYSTEM.CNF, and no
// SYSTEM.CNF; the file runs on over the sectors after.
@(private = "file")
exe_disc :: proc() -> []u8 {
	e := exe()
	img := discimg.make_iso(string(e), cnf_name = "PSX.EXE;1")
	copy(img[22 * disc.DATA:], e)
	return img
}

@(private = "file")
test_native :: proc(name: string, img: []u8) -> (path, dir: string) {
	path = write(name, img)
	dir = disc_dir(name, path)
	if dir == "" {
		return
	}
	blob := core.disc_path(dir, .Native, context.temp_allocator)
	stale := strings.concatenate({blob, ".convert"}, context.temp_allocator)
	if os.write_entire_file(stale, "not a blob") != nil {
		check(name, false, "cannot write the stale temporary file")
	}
	errs := run(name, path) or_else ""
	check(name, strings.contains(errs, "converting"), "no progress from the converter")
	check(name, !strings.contains(errs, "no native code"), "no native code")
	b, _ := os.read_entire_file(blob, context.temp_allocator)
	check(name, core.blob_valid(b), "no blob")
	check(name, os.exists(core.disc_path(dir, .Native_Key, context.temp_allocator)), "no key")
	check(name, !os.exists(stale), "temporary file left")
	check(name, os.is_dir(core.disc_path(dir, .Cards, context.temp_allocator)), "no cards directory")
	errs = run(name, path) or_else ""
	check(name, !strings.contains(errs, "converting") && !strings.contains(errs, "no native code"), "stored blob not used")
	return
}

// A blob header of this format and host arch whose code (64 bytes) is
// missing, stored for this build.
@(private = "file")
test_bad_blob :: proc(path, dir: string) {
	if dir == "" {
		return
	}
	b: [core.NATIVE_HEADER]u8
	endian.put_u32(b[0:], .Little, core.NATIVE_MAGIC)
	endian.put_u32(b[4:], .Little, core.NATIVE_VERSION)
	endian.put_u32(b[8:], .Little, core.NATIVE_ARCH)
	// The header ends with the code's size and where its import slots start.
	endian.put_u32(b[core.NATIVE_HEADER - 8:], .Little, 64)
	endian.put_u32(b[core.NATIVE_HEADER - 4:], .Little, 64)
	if !core.blob_valid(b[:]) || !core.blob_store(dir, b[:]) || !core.blob_cached(dir) {
		check("bad_blob", false, "cannot store the blob")
		return
	}
	errs := run("bad_blob", path, 1) or_else ""
	check("bad_blob", strings.contains(errs, "play: the stored native code would not load; it is converted again next run"), "no load failure")
	check("bad_blob", !strings.contains(errs, "converting"), "converted")
	check("bad_blob", !os.exists(core.disc_path(dir, .Native_Key, context.temp_allocator)), "key left")
}

@(private = "file")
test_interpreted :: proc() {
	path := write("interpreted", cnf_disc("TCB = 4\n"))
	dir := disc_dir("interpreted", path)
	if dir == "" {
		return
	}
	// The converter writes its output to the temporary file's path.
	stale := strings.concatenate({core.disc_path(dir, .Native, context.temp_allocator), ".convert"}, context.temp_allocator)
	in_way, _ := filepath.join({stale, "in the way"}, context.temp_allocator)
	if os.make_directory(stale) != nil || os.write_entire_file(in_way, "") != nil {
		check("interpreted", false, "cannot block the converter")
		return
	}
	errs := run("interpreted", path) or_else ""
	check("interpreted", strings.contains(errs, "play: no native code (the conversion failed"), "no conversion failure")
	check("interpreted", strings.contains(errs, "psx: no native code, interpreting everything"), "not interpreted")
	check("interpreted", !os.exists(core.disc_path(dir, .Native, context.temp_allocator)), "a blob")
	check("interpreted", !os.exists(core.disc_path(dir, .Native_Key, context.temp_allocator)), "a key")
}

@(private = "file")
write :: proc(name: string, data: []u8) -> string {
	path, _ := filepath.join({tmp, strings.concatenate({name, ".iso"}, context.temp_allocator)}, context.temp_allocator)
	if os.write_entire_file(path, data) != nil {
		check(name, false, fmt.tprintf("cannot write %s", path))
	}
	return path
}

// The disc's directory under DATA, created; "" on a failure.
@(private = "file")
disc_dir :: proc(name, path: string) -> string {
	d, ok := disc.open(path, context.temp_allocator)
	if !ok {
		check(name, false, "the image does not open")
		return ""
	}
	defer disc.close(&d)
	id, has_id := disc.id(&d, context.temp_allocator)
	dir, has_dir := core.disc_dir(id, context.temp_allocator)
	check(name, has_id && has_dir, "no disc directory")
	return dir if has_id && has_dir else ""
}

// Run play on the image and check it ends with status, at FRAMES for 0; its
// stderr.
@(private = "file")
run :: proc(name, path: string, status := 0) -> (errs: string, ok: bool) {
	self, err := os.get_executable_path(context.temp_allocator)
	state: os.Process_State
	out, e: []u8
	if err == nil {
		state, out, e, err = os.process_exec({command = {self, path}}, context.temp_allocator)
	}
	if err != nil {
		check(name, false, fmt.tprintf("cannot run play: %v", err))
		return
	}
	errs = string(e)
	frames := strings.contains(errs, fmt.tprintf("frames: %d reached", FRAMES))
	if !state.exited || state.exit_code != status || frames != (status == 0) {
		check(name, false, fmt.tprintf("status %d, stdout:\n%s\nstderr:\n%s", state.exit_code, out, errs))
		return errs, false
	}
	return errs, true
}
