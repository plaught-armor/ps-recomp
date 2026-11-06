// The PS1 mod API (recomp/r3000/mod_api.odin, mods/build.sh), on a
// hand-made program written to the OS temp directory: a 64-word PS-X EXE
// at 80010000 and two overlays at one slot, with tests/mod_api/funcs.tsv.
// The EE's (recomp/r5900/mod_api.odin) is tests/mod_api/ee.odin's.
//
//   - mod_api.h and mod.ld are the committed ones byte for byte
//     (`odin run tests/mod_api -collection:ps=. -- update` writes them),
//     and the same for the rows in another order.
//   - Rows out of their image (or with fewer than four words left) are
//     skipped, and so are names that are not one function's own C name.
//   - A row of an unknown space, or an unaligned entry, is an error, and so
//     is an overlay too short for its id word.
//   - The region constants are the console's, and an image ending at
//     MOD_IMAGE_END loads while one 16 bytes past it does not.
//   - With clang, ld.lld, llvm-nm and sh: build.sh builds hook.c, and
//     mod_elf_read gives its three hooks with the fixture's keys; the mod
//     calls the game through jalr, with no jal or j out of its image, and
//     control.c and control_tail.c, a game call and tail call without
//     long_call, have one. orig.c's replacement calls mod_call_original,
//     at MOD_ORIGINAL, through jalr, and orig_tail.c's tail-calls it
//     through a jr not on $ra. --origin moves the image, and two
//     mods that overlap are refused by name. The build fails for a mod that
//     defines a game function's name (clash.c) or mod_call_original
//     (clash_orig.c), a section mod.ld does not place
//     (stray.c), an image past the region (big.c), and an origin that is
//     not hex, below or past the region, or not 16-byte aligned. Without
//     the tools that part prints a skip.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "ps:core"
import cpu "ps:psx/cpu"
import "ps:recomp/mips"
import "ps:recomp/r3000"

failed: int

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL mod_api: %s (line %d)", what, loc.line)
		failed += 1
	}
}

EXE :: 0x8001_0000
SLOT :: 0x8010_0000
ID_A :: 0xa0a0_a0a0
ID_B :: 0xb0b0_b0b0
DIR :: "tests/mod_api"

exe_word :: proc(k: int) -> u32 {return 0x2402_0000 + u32(k)}
ovl_word :: proc(id: u32, k: int) -> u32 {return k == 0 ? id : (id & 0xff00) + u32(k)}

main :: proc() {
	update := len(os.args) > 1 && os.args[1] == "update"
	tmp, terr := os.make_directory_temp("", "ps_mod_api_test_*", context.allocator)
	if terr != nil {
		fmt.eprintln("FAIL mod_api: no temp directory:", terr)
		os.exit(1)
	}
	defer os.remove_all(tmp)

	// The program: the executable and overlays/{ov_a,ov_b}.bin.
	exe := make([]u8, 0x800 + 64 * 4)
	copy(exe, "PS-X EXE")
	(^u32le)(&exe[0x10])^, (^u32le)(&exe[0x18])^, (^u32le)(&exe[0x1c])^ = EXE, EXE, 64 * 4
	for k in 0 ..< 64 {(^u32le)(&exe[0x800 + k * 4])^ = u32le(exe_word(k))}
	write(tmp, "test.exe", exe)
	ovls := join({tmp, "overlays"})
	for id in ([]u32{ID_A, ID_B}) {
		b := make([]u8, 16 * 4, context.temp_allocator)
		for k in 0 ..< 16 {(^u32le)(&b[k * 4])^ = u32le(ovl_word(id, k))}
		write(ovls, id == ID_A ? "ov_a.bin" : "ov_b.bin", b)
	}
	write(ovls, "manifest.tsv", transmute([]u8)fmt.tprintf("file\tslot\nov_a.bin\t%08x\nov_b.bin\t%08x\n", SLOT, SLOT))
	exe_path := join({tmp, "test.exe"})
	opts := fmt.tprintf("key\tvalue\nbackend\tr3000\nexe\t%s\noverlays\t%s\nfuncs\t%s/funcs.tsv\n", exe_path, ovls, DIR)
	write(tmp, "options.tsv", transmute([]u8)opts)

	spaces, rows, lerr := r3000.mod_api_load(mips.load_options(join({tmp, "options.tsv"})))
	check(lerr == "", lerr)
	header, script, skips, err := r3000.mod_api(spaces, rows)
	check(err == "", err)
	check(skips == {outside = 2, names = 5}, fmt.tprint("skips", skips))
	if update {
		write(DIR, "mod_api.h", transmute([]u8)header)
		write(DIR, "mod.ld", transmute([]u8)script)
		fmt.println("mod_api: goldens written")
	}
	golden_h, _ := os.read_entire_file(DIR + "/mod_api.h", context.allocator)
	golden_ld, _ := os.read_entire_file(DIR + "/mod.ld", context.allocator)
	check(header == string(golden_h), "mod_api.h is the golden one")
	check(script == string(golden_ld), "mod.ld is the golden one")

	// Another order: the same bytes.
	shuffled := slice.clone(rows, context.temp_allocator)
	slice.reverse(shuffled)
	slice.rotate_left(shuffled, 5)
	h2, ld2, skips2, err2 := r3000.mod_api(spaces, shuffled)
	check(err2 == "" && skips2 == skips && h2 == header && ld2 == script, "rows in another order give the same output")

	// Errors.
	bad := slice.concatenate([][]r3000.Mod_Api_Row{rows, {{"ov_c", SLOT, ""}}}, context.temp_allocator)
	_, _, _, err = r3000.mod_api(spaces, bad)
	check(err == "ov_c 80100000: unknown space ov_c", err)
	bad[len(bad) - 1] = {"ram", EXE + 2, ""}
	_, _, _, err = r3000.mod_api(spaces, bad)
	check(err == "ram 80010002: entry not word aligned", err)

	// An overlay with no id word.
	short := join({tmp, "short"})
	write(short, "ov_e.bin", {0x11, 0x22})
	write(short, "manifest.tsv", transmute([]u8)fmt.tprintf("file\tslot\nov_e.bin\t%08x\n", SLOT))
	sopts := fmt.tprintf("key\tvalue\nbackend\tr3000\nexe\t%s\noverlays\t%s\nfuncs\t%s/funcs.tsv\n", exe_path, short, DIR)
	write(short, "options.tsv", transmute([]u8)sopts)
	_, _, lerr = r3000.mod_api_load(mips.load_options(join({short, "options.tsv"})))
	check(lerr == "overlay ov_e: 2 bytes, no id word", lerr)

	// The constants are the console's.
	check(r3000.MOD_API == core.MOD_API, "MOD_API")
	check(r3000.MOD_BASE == cpu.MOD_BASE && r3000.MOD_REGION == cpu.MOD_REGION && r3000.MOD_STACK == cpu.MOD_STACK, "region constants")
	check(r3000.MOD_ORIGINAL == cpu.MOD_ORIGINAL, "MOD_ORIGINAL")
	check(cpu.mod_ram_load({{lo = cpu.MOD_BASE, hi = r3000.MOD_IMAGE_END}}, {"end"}) == "", "an image to MOD_IMAGE_END loads")
	cpu.mod_ram_free()
	check(cpu.mod_ram_load({{lo = cpu.MOD_BASE, hi = r3000.MOD_IMAGE_END + 16}}, {"past"}) != "", "an image past MOD_IMAGE_END does not")
	cpu.mod_ram_free()

	build(tmp, header, script)
	ee(tmp, update)

	if failed > 0 {
		fmt.eprintfln("mod_api: %d failed", failed)
		os.exit(1)
	}
	fmt.println("mod_api: ok")
}

// Build the fixture mods with mods/build.sh and read them back.
@(private = "file")
build :: proc(tmp, header, script: string) {
	for tool in ([]string{"clang", "ld.lld", "llvm-nm", "sh"}) {
		state, _, _, err := os.process_exec({command = {tool, "--version"}}, context.temp_allocator)
		if err != nil || !state.exited || state.exit_code != 0 {
			fmt.printfln("mod_api: skip build: no %s", tool)
			return
		}
	}
	api := join({tmp, "api"})
	write(api, "mod_api.h", transmute([]u8)header)
	write(api, "mod.ld", transmute([]u8)script)

	img, elf := build_one(tmp, "hook", "")
	check(img.lo == cpu.MOD_BASE, fmt.tprintf("hook linked at %08x", img.lo))
	sig :: proc(w: proc(k: int) -> u32) -> [4]u32 {return {w(0), w(1), w(2), w(3)}}
	ov_b :: proc(k: int) -> u32 {return ovl_word(ID_B, k + 1)}
	ov_a :: proc(k: int) -> u32 {return ovl_word(ID_A, k + 1)}
	want := [core.Mod_Hook_Kind]core.Mod_Key {
		.Before  = {0, 0, EXE, sig(exe_word)},
		.After   = {SLOT, ID_A, SLOT + 4, sig(ov_a)},
		.Replace = {SLOT, ID_B, SLOT + 4, sig(ov_b)},
	}
	check(len(img.hooks) == 3, fmt.tprint("hooks:", len(img.hooks)))
	seen: [core.Mod_Hook_Kind]bool
	for h in img.hooks {
		seen[h.kind] = true
		check(h.key == want[h.kind], fmt.tprint(h.kind, "key", h.key))
		_, is_fn := slice.binary_search_by(img.funcs, h.fn, proc(f: core.Mod_Func, a: u32) -> slice.Ordering {return slice.cmp(f.addr, a)})
		check(is_fn, fmt.tprintf("%v hook fn %08x is a mod function", h.kind, h.fn))
	}
	check(seen == {.Before = true, .After = true, .Replace = true}, "one hook of each kind")
	out, jal_in, jalr, _ := calls(img)
	check(out == 0, fmt.tprint("hook: jal or j out of the image:", out))
	check(jal_in > 0, "hook: its own call is a jal")
	check(jalr > 0, "hook: the game call is a jalr")
	_ = elf

	for name in ([]string{"control", "control_tail"}) {
		c, _ := build_one(tmp, name, "")
		out, _, _, _ = calls(c)
		check(out > 0, fmt.tprintf("%s: a game call without long_call is a jal or j out of the image", name))
	}

	orig, _ := build_one(tmp, "orig", "")
	out, _, jalr, _ = calls(orig)
	check(out == 0 && jalr > 0 && loads(orig, cpu.MOD_ORIGINAL), fmt.tprintf("orig: %d calls out, %d jalr, loads %08x: %v", out, jalr, u32(cpu.MOD_ORIGINAL), loads(orig, cpu.MOD_ORIGINAL)))
	tail, _ := build_one(tmp, "orig_tail", "")
	jr: int
	out, _, _, jr = calls(tail)
	check(out == 0 && jr > 0 && loads(tail, cpu.MOD_ORIGINAL), fmt.tprintf("orig_tail: %d calls out, %d jr not on $ra, loads %08x: %v", out, jr, u32(cpu.MOD_ORIGINAL), loads(tail, cpu.MOD_ORIGINAL)))

	moved, _ := build_one(tmp, "hook", "0x1f500000")
	check(moved.lo == 0x1f50_0000, fmt.tprintf("--origin: linked at %08x", moved.lo))

	// Two mods whose images overlap: the region refuses them by name.
	over, _ := build_one(tmp, "hook", "0x1f400010")
	err := cpu.mod_ram_load({img, over}, {"first", "second"})
	check(strings.has_prefix(err, "mod first and mod second: images "), err)
	cpu.mod_ram_free()

	// Builds that must fail, and what build.sh or ld.lld says.
	Bad :: struct {
		name, origin, says: string,
		code:               int,
	}
	bads := []Bad {
		{"clash", "", "the mod defines start, a name mod_api.h gives a game function", 1},
		{"clash_orig", "", "the mod defines mod_call_original, a name mod_api.h gives", 1},
		{"stray", "", ".stray", 1},
		{"big", "", "mod: the image runs past the mod region", 1},
		{"hook", "zz", "is not a hex address", 2},
		{"hook", "0x1f3ffff0", "mod: the origin is outside the mod region", 1},
		{"hook", "0x1f800000", "mod: the origin is outside the mod region", 1},
		{"hook", "0x1f400004", "mod: the origin is not 16-byte aligned", 1},
	}
	for b in bads {
		code, errs, _ := build_run(tmp, b.name, b.origin)
		check(code == b.code && strings.contains(errs, b.says), fmt.tprintf("build %s %s: exit %d: %s", b.name, b.origin, code, errs))
	}
}

// Run build.sh on DIR/<name>.c at origin ("" the default): its exit code
// (-1 when it did not run) and stderr. The mod is <dir>/mod.elf.
@(private = "file")
build_run :: proc(tmp, name, origin: string) -> (code: int, errs: string, dir: string) {
	dir = join({tmp, fmt.tprintf("%s_%s", name, origin)})
	src, _ := os.read_entire_file(fmt.tprintf("%s/%s.c", DIR, name), context.temp_allocator)
	write(dir, fmt.tprintf("%s.c", name), src)
	cmd := []string{"sh", "mods/build.sh", join({tmp, "api"}), dir, "--origin", origin}
	state, _, e, err := os.process_exec({command = cmd[:origin == "" ? 4 : 6]}, context.temp_allocator)
	if err != nil || !state.exited {return -1, fmt.tprint(err), dir}
	return state.exit_code, string(e), dir
}

// Build DIR/<name>.c as a mod, at origin ("" the default).
@(private = "file")
build_one :: proc(tmp, name, origin: string) -> (core.Mod_Image, []u8) {
	code, errs, dir := build_run(tmp, name, origin)
	if code != 0 {
		check(false, fmt.tprintf("build %s: exit %d: %s", name, code, errs))
		return {}, nil
	}
	elf, _ := os.read_entire_file(join({dir, "mod.elf"}), context.allocator)
	img, ierr := core.mod_elf_read(elf, cpu.MOD_BASE, cpu.MOD_BASE + cpu.MOD_REGION, 0, context.allocator)
	check(ierr == "", fmt.tprintf("read %s: %s", name, ierr))
	return img, elf
}

// The calls in the image's code: jal or j out of it, jal into it, jalr, and
// jr through a register other than $ra (a tail call).
@(private = "file")
calls :: proc(img: core.Mod_Image) -> (out, jal_in, jalr, jr: int) {
	for s in img.segments {
		if !s.exec {continue}
		for k := 0; k + 4 <= len(s.bytes); k += 4 {
			w := u32((^u32le)(&s.bytes[k])^)
			pc := s.addr + u32(k)
			switch {
			case w >> 26 == 2 || w >> 26 == 3:
				to := ((pc + 4) & 0xf000_0000) | (w & 0x3ff_ffff) << 2
				if to & 0x1fff_ffff < img.lo || to & 0x1fff_ffff >= img.hi {out += 1} else if w >> 26 == 3 {jal_in += 1}
			case w >> 26 == 0 && w & 0x3f == 9:
				jalr += 1
			case w >> 26 == 0 && w & 0x3f == 8 && (w >> 21) & 31 != 31:
				jr += 1
			}
		}
	}
	return
}

// Whether the image's code puts addr in a register: a lui of its high half,
// then an addiu or ori of the low half into that register.
@(private = "file")
loads :: proc(img: core.Mod_Image, addr: u32) -> bool {
	for s in img.segments {
		if !s.exec {continue}
		hi: [32]u32 // per register: its last lui's value
		set: [32]bool
		for k := 0; k + 4 <= len(s.bytes); k += 4 {
			w := u32((^u32le)(&s.bytes[k])^)
			op, rs, rt, imm := w >> 26, (w >> 21) & 31, (w >> 16) & 31, w & 0xffff
			switch op {
			case 0x0f:
				hi[rt], set[rt] = imm << 16, true
			case 0x09, 0x0d:
				got := op == 0x09 ? hi[rs] + u32(i32(i16(imm))) : hi[rs] | imm
				if set[rs] && got == addr {return true}
			}
		}
	}
	return false
}

join :: proc(parts: []string) -> string {
	p, _ := filepath.join(parts, context.temp_allocator)
	return p
}

write :: proc(dir, name: string, data: []u8) {
	_ = os.make_directory_all(dir)
	path := join({dir, name})
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintln("FAIL mod_api: cannot write", path, err)
		os.exit(1)
	}
}
