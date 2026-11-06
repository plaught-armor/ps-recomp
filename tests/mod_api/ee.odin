// The EE mod API (recomp/r5900/mod_api.odin), on a hand-made ELF written to
// the OS temp directory: a 20-word .text at 00100000 whose entry calls two
// functions.
//
//   - mod_api.h and mod.ld are the committed tests/mod_api/ee ones byte for
//     byte (`odin run tests/mod_api -collection:ps=. -- update` writes them):
//     three functions, all plain calls (no long_call), keyed slot 0 and the
//     id the kernel gives the boot program from the same ELF.
//   - A words option patching a function changes nothing: keys name the
//     words the port's RAM has.
//   - The region constants are the console's (ps2/mem), and an image ending
//     at MOD_IMAGE_END loads while one 16 bytes past it does not.
//   - With clang, ld.lld, llvm-nm, llvm-objdump and sh: build.sh builds
//     ee/hook.c as an n32 EE mod (its MOD_ARCH), and mod_elf_read gives its
//     three hooks with the fixture's keys; its calls out of the image are
//     plain jal, to the game function and to MOD_ORIGINAL, with no jalr.
//     ee/mul64.c (a 64-bit multiply) and ee/f2i.c ((int)f: trunc.w.s)
//     fail the build, naming the function and the instruction, and
//     ee/double.c, naming the file and the compiler routine; none leaves a
//     mod.elf.
//   - With llvm-mc too: build.sh's fpu list is the decoder's FPU
//     instructions as llvm names them, every COP1, LWC1 and SWC1 encoding
//     the decoder (ps2/r5900) takes, and no name an encoding it rejects
//     has.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "ps:core"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"
import isa "ps:ps2/r5900"
import "ps:recomp/mips"
import "ps:recomp/r5900"

EE_TEXT :: 0x0010_0000
EE_DIR :: "tests/mod_api/ee"

@(private = "file")
EE_CODE := [20]u32 {
	0x0c04_0008, 0, 0x0c04_0010, 0, 0x03e0_0008, 0, 0, 0, // entry: jal 00100020, jal 00100040, jr ra
	0x03e0_0008, 0x2402_0001, 0, 0, 0, 0, 0, 0, // 00100020: jr ra, li v0 1
	0x03e0_0008, 0x2402_0002, 0, 0, // 00100040: jr ra, li v0 2
}

// A 32-bit little-endian MIPS executable: .text holding EE_CODE at
// EE_TEXT, and .shstrtab; no program headers (recomp reads sections).
@(private = "file")
ee_elf :: proc() -> []u8 {
	TEXT_OFF :: 0x40
	names := "\x00.text\x00.shstrtab\x00"
	str_off := TEXT_OFF + len(EE_CODE) * 4
	sh_off := (str_off + len(names) + 3) &~ 3
	b := make([]u8, sh_off + 3 * 40)
	put32 :: proc(b: []u8, o: int, v: u32) {(^u32le)(&b[o])^ = u32le(v)}
	put16 :: proc(b: []u8, o: int, v: u16) {(^u16le)(&b[o])^ = u16le(v)}
	copy(b, "\x7fELF\x01\x01\x01")
	put16(b, 16, 2) // ET_EXEC
	put16(b, 18, 8) // EM_MIPS
	put32(b, 20, 1)
	put32(b, 24, EE_TEXT)
	put32(b, 32, u32(sh_off))
	put16(b, 40, 52)
	put16(b, 46, 40)
	put16(b, 48, 3)
	put16(b, 50, 2)
	for w, k in EE_CODE {put32(b, TEXT_OFF + 4 * k, w)}
	copy(b[str_off:], names)
	text := sh_off + 40
	put32(b, text, 1)
	put32(b, text + 4, 1) // PROGBITS
	put32(b, text + 8, 6) // ALLOC | EXECINSTR
	put32(b, text + 12, EE_TEXT)
	put32(b, text + 16, TEXT_OFF)
	put32(b, text + 20, u32(len(EE_CODE) * 4))
	put32(b, text + 32, 4)
	strs := sh_off + 80
	put32(b, strs, 7)
	put32(b, strs + 4, 3) // STRTAB
	put32(b, strs + 16, u32(str_off))
	put32(b, strs + 20, u32(len(names)))
	put32(b, strs + 32, 1)
	return b
}

ee :: proc(tmp: string, update: bool) {
	dir := join({tmp, "ee"})
	elf := ee_elf()
	write(dir, "game.elf", elf)
	write(dir, "words.tsv", transmute([]u8)fmt.tprintf("at\tword\n%08x\t24020005\n", EE_TEXT + 0x24))
	opts := fmt.tprintf("key\tvalue\nbackend\tr5900\nexe\t%s\nquiet\ttrue\n", join({dir, "game.elf"}))
	write(dir, "options.tsv", transmute([]u8)opts)
	write(dir, "patched.tsv", transmute([]u8)fmt.tprintf("%swords\t%s\n", opts, join({dir, "words.tsv"})))

	spaces, rows := r5900.mod_api_load(mips.load_options(join({dir, "options.tsv"})))
	entries := make([]u32, len(rows), context.temp_allocator)
	for r, k in rows {entries[k] = r.entry}
	check(len(spaces) == 1 && spaces[0].name == "ram" && spaces[0].slot == 0, fmt.tprint("ee spaces", spaces))
	check(fmt.tprint(entries) == fmt.tprint([]u32{EE_TEXT, EE_TEXT + 0x20, EE_TEXT + 0x40}), fmt.tprintf("ee functions %x", entries))
	kernel.exec_boot_program(elf)
	check(spaces[0].id == kernel.k.exec.boot_prog, fmt.tprintf("ee id %08x, the kernel's %08x", spaces[0].id, kernel.k.exec.boot_prog))
	header, script, skips, err := r5900.mod_api(spaces, rows)
	check(err == "" && skips == {}, fmt.tprint("ee", err, skips))
	if update {
		write(EE_DIR, "mod_api.h", transmute([]u8)header)
		write(EE_DIR, "mod.ld", transmute([]u8)script)
		fmt.println("mod_api: ee goldens written")
	}
	golden_h, _ := os.read_entire_file(EE_DIR + "/mod_api.h", context.allocator)
	golden_ld, _ := os.read_entire_file(EE_DIR + "/mod.ld", context.allocator)
	check(header == string(golden_h), "ee mod_api.h is the golden one")
	check(script == string(golden_ld), "ee mod.ld is the golden one")

	ps, prows := r5900.mod_api_load(mips.load_options(join({dir, "patched.tsv"})))
	h2, ld2, _, _ := r5900.mod_api(ps, prows)
	check(h2 == header && ld2 == script, "ee: a words patch changes no key")

	ee_build(tmp, "ee_api", header, script, spaces[0].id)
	ee_fpu_list(tmp)

	check(r5900.MOD_API == core.MOD_API && r5900.MOD_BASE == mem.MOD_BASE && r5900.MOD_REGION == mem.MOD_REGION && r5900.MOD_STACK == mem.MOD_STACK, "ee region constants")
	check(r5900.MOD_ORIGINAL == mem.MOD_ORIGINAL, "ee MOD_ORIGINAL")
	check(mem.mod_ram_load({{lo = mem.MOD_BASE, hi = r5900.MOD_IMAGE_END}}, {"end"}) == "", "ee: an image to MOD_IMAGE_END loads")
	mem.mod_ram_free()
	check(mem.mod_ram_load({{lo = mem.MOD_BASE, hi = r5900.MOD_IMAGE_END + 16}}, {"past"}) != "", "ee: an image past MOD_IMAGE_END does not")
	mem.mod_ram_free()
}

// Build the EE fixture mods against the API in <tmp>/<api>.
@(private = "file")
ee_build :: proc(tmp, api, header, script: string, prog: u32) {
	if !have_tools({"clang", "ld.lld", "llvm-nm", "llvm-objdump", "sh"}) {return}
	write(join({tmp, api}), "mod_api.h", transmute([]u8)header)
	write(join({tmp, api}), "mod.ld", transmute([]u8)script)
	code, errs, dir := build_run(tmp, "hook", "", EE_DIR, api)
	check(code == 0, fmt.tprintf("ee build hook: exit %d: %s", code, errs))
	if code != 0 {return}
	elf, _ := os.read_entire_file(join({dir, "mod.elf"}), context.allocator)
	img, ierr := core.mod_elf_read(elf, mem.MOD_BASE, mem.MOD_BASE + mem.MOD_REGION, 0, context.allocator)
	check(ierr == "", fmt.tprint("ee read hook:", ierr))
	check(img.lo == mem.MOD_BASE, fmt.tprintf("ee hook linked at %08x", img.lo))
	want := [core.Mod_Hook_Kind]core.Mod_Key {
		.Before  = {0, prog, EE_TEXT, {EE_CODE[0], EE_CODE[1], EE_CODE[2], EE_CODE[3]}},
		.After   = {0, prog, EE_TEXT + 0x20, {EE_CODE[8], EE_CODE[9], EE_CODE[10], EE_CODE[11]}},
		.Replace = {0, prog, EE_TEXT + 0x40, {EE_CODE[16], EE_CODE[17], EE_CODE[18], EE_CODE[19]}},
	}
	check(len(img.hooks) == 3, fmt.tprint("ee hooks:", len(img.hooks)))
	for h in img.hooks {check(h.key == want[h.kind], fmt.tprint("ee", h.kind, "key", h.key))}
	// Calls out of the image: jal targets, and jalr.
	out: [dynamic]u32
	jalr: int
	for sg in img.segments {
		if !sg.exec {continue}
		for k := 0; k + 4 <= len(sg.bytes); k += 4 {
			w := u32((^u32le)(&sg.bytes[k])^)
			pc := sg.addr + u32(k)
			if w >> 26 == 3 {
				to := ((pc + 4) & 0xf000_0000) | (w & 0x3ff_ffff) << 2
				if (to < img.lo || to >= img.hi) && !slice.contains(out[:], to) {append(&out, to)}
			}
			if w >> 26 == 0 && w & 0x3f == 9 {jalr += 1}
		}
	}
	slice.sort(out[:])
	check(fmt.tprint(out[:]) == fmt.tprint([]u32{EE_TEXT + 0x20, mem.MOD_ORIGINAL}) && jalr == 0, fmt.tprintf("ee hook: jal out %x, %d jalr", out[:], jalr))

	Bad :: struct {
		name, says: string,
	}
	for b in ([]Bad {
			{"mul64", "before has dmult, which the R5900 does not have"},
			{"f2i", "before has trunc.w.s, which the R5900 does not have"},
			{"double", "double.c calls __"},
		}) {
		c, e, d := build_run(tmp, b.name, "", EE_DIR, api)
		_, left := os.stat(join({d, "mod.elf"}), context.temp_allocator)
		check(c == 1 && strings.contains(e, b.says) && left != nil, fmt.tprintf("ee build %s: exit %d: %s", b.name, c, e))
	}
}

// build.sh's fpu list against the decoder: llvm-mc's name for each COP1
// (rs MF to BC, and fmt S, D, W, L with every function), LWC1, LDC1, SWC1
// and SDC1 encoding, the list being the names of the ones the decoder
// takes; a name of one it rejects must not be in it.
@(private = "file")
ee_fpu_list :: proc(tmp: string) {
	if !have_tools({"llvm-mc"}) {return}
	words: [dynamic]u32
	for rs in u32(0) ..< 8 {append(&words, 0x4400_0000 | rs << 21 | 2 << 16 | 3 << 11)}
	for rt in u32(0) ..< 4 {append(&words, 0x4500_0004 | rt << 16)}
	for f in ([]u32{16, 17, 20, 21}) {
		for fn in u32(0) ..< 64 {append(&words, 0x4400_0000 | f << 21 | fn)}
	}
	for op in ([]u32{49, 53, 57, 61}) {append(&words, op << 26 | 4 << 21 | 2 << 16 | 8)}
	// Each word after a marker (addiu $zero, $zero, 77), so the names
	// llvm-mc prints line up with the words it knows.
	MARK :: 0x2400_004d
	input: strings.Builder
	for w in words {
		for x in ([]u32{MARK, w}) {fmt.sbprintf(&input, "0x%02x 0x%02x 0x%02x 0x%02x\n", x & 0xff, x >> 8 & 0xff, x >> 16 & 0xff, x >> 24)}
	}
	write(join({tmp, "ee"}), "fpu.txt", transmute([]u8)strings.to_string(input))
	cmd := []string{"llvm-mc", "--disassemble", "-triple=mips64el", "-mcpu=mips3", join({tmp, "ee", "fpu.txt"})}
	state, out, _, err := os.process_exec({command = cmd}, context.temp_allocator)
	check(err == nil && state.exited, fmt.tprint("ee: llvm-mc", err))
	if err != nil {return}
	has, lacks: map[string]bool
	k := -1
	for line in strings.split_lines(string(out), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 {continue}
		if f[0] == "addiu" && strings.has_suffix(line, "77") {
			k += 1
			continue
		}
		if k < 0 || k >= len(words) {continue}
		if isa.decode(0, words[k]).op != .INVALID {has[f[0]] = true} else {lacks[f[0]] = true}
	}
	sh, _ := os.read_entire_file("mods/build.sh", context.temp_allocator)
	list: []string
	for line in strings.split_lines(string(sh), context.temp_allocator) {
		if strings.has_prefix(line, "fpu='") {list = strings.fields(strings.trim(line[4:], "'"), context.temp_allocator)}
	}
	names := make([dynamic]string, context.temp_allocator)
	for n in has {append(&names, n)}
	slice.sort(names[:])
	check(fmt.tprint(list) == fmt.tprint(names[:]), fmt.tprintf("ee: build.sh fpu is %v, the decoder's %v", list, names[:]))
	for n in has {check(!lacks[n], fmt.tprint("ee:", n, "names an encoding the decoder takes and one it rejects"))}
	check(len(lacks) > 0 && lacks["trunc.w.s"] && lacks["c.ule.s"] && lacks["ldc1"], fmt.tprint("ee: rejected names", lacks))
}
