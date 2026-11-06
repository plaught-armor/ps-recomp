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
package main

import "core:fmt"
import "core:os"
import "ps:core"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"
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

	check(r5900.MOD_API == core.MOD_API && r5900.MOD_BASE == mem.MOD_BASE && r5900.MOD_REGION == mem.MOD_REGION && r5900.MOD_STACK == mem.MOD_STACK, "ee region constants")
	check(r5900.MOD_ORIGINAL == mem.MOD_ORIGINAL, "ee MOD_ORIGINAL")
	check(mem.mod_ram_load({{lo = mem.MOD_BASE, hi = r5900.MOD_IMAGE_END}}, {"end"}) == "", "ee: an image to MOD_IMAGE_END loads")
	mem.mod_ram_free()
	check(mem.mod_ram_load({{lo = mem.MOD_BASE, hi = r5900.MOD_IMAGE_END + 16}}, {"past"}) != "", "ee: an image past MOD_IMAGE_END does not")
	mem.mod_ram_free()
}
