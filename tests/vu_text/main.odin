// .vutext's programs as the conversion finds them (recomp/vu vutext_scan,
// native_programs), and what a VU half that cannot be read does to a
// conversion (recomp/r5900 generate), on hand-made sections and ELFs.
//
//   - A program, a bundle that loads elsewhere than address 0 in two MPGs,
//     then a program in two MPGs: both programs are found with their own
//     words, and the bundle is left out, once.
//   - A section holding only such a bundle: no programs, and no failure.
//   - No .vutext: no programs. An MPG that runs past the section: a failure.
//   - A whole conversion with a capture file that cannot be read, of either
//     unit, or with a .vutext that fails, still writes the blob with its EE
//     functions: without that unit's programs, with the other's. Each
//     conversion runs in a child (this binary, `convert <options>`), as a
//     failing one exits.
//   - The VU programs alone (vu_only) with such a capture: the child fails.
//
//   odin run tests/vu_text -collection:ps=.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "ps:core"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r5900"
import rvu "ps:recomp/vu"

NOP_L :: 0x8000033c
NOP_U :: 0x000002ff
E_BIT :: 1 << 30
TEXT :: 0x0010_0000
VUTEXT :: 0x0010_0100

fails: int

check :: proc(ok: bool, what: string) {
	if ok {return}
	fmt.eprintln("FAIL vu_text:", what)
	fails += 1
}

// An MPG loading pairs NOP pairs at micro address addr; last: the pair
// before the last one ends the program.
mpg :: proc(w: ^[dynamic]u32, addr: u32, pairs: int, last := false) {
	append(w, 0x4a00_0000 | u32(pairs) << 16 | addr / 8)
	for k in 0 ..< pairs {
		append(w, NOP_L, NOP_U | (E_BIT if last && k == pairs - 2 else 0))
	}
}

// Two programs with a bundle between them that loads at 0x80.
mixed :: proc() -> []u32 {
	w: [dynamic]u32
	mpg(&w, 0, 2, true)
	mpg(&w, 0x80, 2)
	mpg(&w, 0x90, 1)
	mpg(&w, 0, 2)
	mpg(&w, 0x10, 2, true)
	return w[:]
}

image :: proc(words: []u32) -> mips.Image {
	secs := make([]mips.Section, 1)
	secs[0] = {name = ".vutext", addr = VUTEXT, size = u32(len(words) * 4), data = slice.to_bytes(words), flags = mips.SHF_ALLOC}
	return {base = VUTEXT, data = secs[0].data, name = "test", sections = secs}
}

scanner :: proc() {
	arch := native.Arch(core.NATIVE_ARCH)
	{
		w := mixed()
		img := image(w)
		programs, dropped, ok := rvu.vutext_scan(img)
		check(ok && programs == 2 && dropped == 1, fmt.tprintf("a bundle between two programs: %d programs, %d left out, ok %v; want 2, 1, true", programs, dropped, ok))
		a := native.make_asm(arch, r5900.native_ram())
		spans: [dynamic]native.Blob_Span
		done := rvu.native_programs(&a, img, "", .VU1, &spans)
		check(done && len(spans) == 2, fmt.tprintf("a bundle between two programs: %d compiled, ok %v; want 2", len(spans), done))
		if len(spans) == 2 {
			first, second := spans[0].ranges, spans[1].ranges
			check(len(first) == 1 && first[0].pc == 0 && slice.equal(first[0].words, w[1:5]), "the program before the bundle has its own 2 pairs")
			want: [dynamic]u32
			append(&want, ..w[14:18])
			append(&want, ..w[19:23])
			check(len(second) == 1 && second[0].pc == 0 && slice.equal(second[0].words, want[:]), "the program after the bundle has its own 4 pairs")
		}
	}
	{
		w: [dynamic]u32
		mpg(&w, 0x80, 2)
		mpg(&w, 0x90, 1)
		img := image(w[:])
		programs, dropped, ok := rvu.vutext_scan(img)
		check(ok && programs == 0 && dropped == 1, fmt.tprintf("only a bundle: %d programs, %d left out, ok %v; want 0, 1, true", programs, dropped, ok))
		a := native.make_asm(arch, r5900.native_ram())
		spans: [dynamic]native.Blob_Span
		check(rvu.native_programs(&a, img, "", .VU1, &spans) && len(spans) == 0, "only a bundle: the unit compiles, with no program")
	}
	{
		programs, dropped, ok := rvu.vutext_scan(mips.Image{})
		check(ok && programs == 0 && dropped == 0, "no .vutext: no programs")
	}
	{
		w := past()
		_, _, ok := rvu.vutext_scan(image(w))
		check(!ok, "an MPG that runs past .vutext fails the scan")
	}
}

// A program, then an MPG naming more pairs than the section has.
past :: proc() -> []u32 {
	w: [dynamic]u32
	mpg(&w, 0, 2, true)
	append(&w, 0x4a00_0000 | 8 << 16, NOP_L, NOP_U)
	return w[:]
}

// A 32-bit little-endian MIPS executable: .text (jr ra) at TEXT, .vutext
// holding vutext at VUTEXT, and .shstrtab; no program headers (recomp
// reads sections).
elf :: proc(vutext: []u32) -> []u8 {
	CODE := [4]u32{0x03e0_0008, 0, 0, 0}
	TEXT_OFF :: 0x40
	names := "\x00.text\x00.vutext\x00.shstrtab\x00"
	vu_off := TEXT_OFF + len(CODE) * 4
	str_off := vu_off + len(vutext) * 4
	sh_off := (str_off + len(names) + 3) &~ 3
	b := make([]u8, sh_off + 4 * 40)
	put32 :: proc(b: []u8, o: int, v: u32) {(^u32le)(&b[o])^ = u32le(v)}
	put16 :: proc(b: []u8, o: int, v: u16) {(^u16le)(&b[o])^ = u16le(v)}
	copy(b, "\x7fELF\x01\x01\x01")
	put16(b, 16, 2) // ET_EXEC
	put16(b, 18, 8) // EM_MIPS
	put32(b, 20, 1)
	put32(b, 24, TEXT)
	put32(b, 32, u32(sh_off))
	put16(b, 40, 52)
	put16(b, 46, 40)
	put16(b, 48, 4)
	put16(b, 50, 3)
	for w, k in CODE {put32(b, TEXT_OFF + 4 * k, w)}
	for w, k in vutext {put32(b, vu_off + 4 * k, w)}
	copy(b[str_off:], names)
	text := sh_off + 40
	put32(b, text, 1)
	put32(b, text + 4, 1) // PROGBITS
	put32(b, text + 8, 6) // ALLOC | EXECINSTR
	put32(b, text + 12, TEXT)
	put32(b, text + 16, TEXT_OFF)
	put32(b, text + 20, u32(len(CODE) * 4))
	put32(b, text + 32, 4)
	vut := sh_off + 80
	put32(b, vut, 7)
	put32(b, vut + 4, 1)
	put32(b, vut + 8, 2) // ALLOC
	put32(b, vut + 12, VUTEXT)
	put32(b, vut + 16, u32(vu_off))
	put32(b, vut + 20, u32(len(vutext) * 4))
	put32(b, vut + 32, 4)
	strs := sh_off + 120
	put32(b, strs, 15)
	put32(b, strs + 4, 3) // STRTAB
	put32(b, strs + 16, u32(str_off))
	put32(b, strs + 20, u32(len(names)))
	put32(b, strs + 32, 1)
	return b
}

join :: proc(parts: []string) -> string {
	p, _ := os.join_path(parts, context.temp_allocator)
	return p
}

write :: proc(path: string, data: []u8) {
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintln("FAIL vu_text: cannot write", path, err)
		os.exit(1)
	}
}

// Convert exe in a child with the options extra (key, value pairs): its
// exit code, and the blob's EE function and span counts, -1 with no blob.
convert :: proc(dir, name, exe: string, extra: []string) -> (code, funcs, spans: int) {
	out := join({dir, strings.concatenate({name, ".bin"}, context.temp_allocator)})
	sb: strings.Builder
	arch := "x64_sysv"
	when ODIN_ARCH == .arm64 {arch = "arm64"} else when ODIN_OS == .Windows {arch = "x64_win"}
	fmt.sbprintf(&sb, "key\tvalue\nbackend\tr5900\nexe\t%s\nquiet\ttrue\nnative_arch\t%s\nnative_out\t%s\n", exe, arch, out)
	for k := 0; k + 1 < len(extra); k += 2 {fmt.sbprintf(&sb, "%s\t%s\n", extra[k], extra[k + 1])}
	opts := join({dir, strings.concatenate({name, ".tsv"}, context.temp_allocator)})
	write(opts, sb.buf[:])
	self, perr := os.get_executable_path(context.temp_allocator)
	if perr != nil {
		fmt.eprintln("FAIL vu_text: no path to this binary:", perr)
		os.exit(1)
	}
	state, _, _, err := os.process_exec({command = {self, "convert", opts}}, context.temp_allocator)
	if err != nil || !state.exited {
		fmt.eprintln("FAIL vu_text: cannot run the conversion child:", err)
		os.exit(1)
	}
	blob, rerr := os.read_entire_file(out, context.temp_allocator)
	if rerr != nil {return state.exit_code, -1, -1}
	h, _, _, serr := core.native_slots(blob)
	if serr != "" {return state.exit_code, -1, -1}
	return state.exit_code, int(h[4]), int(h[7])
}

fail_soft :: proc() {
	dir, err := os.make_directory_temp("", "ps_vu_text_*", context.temp_allocator)
	if err != nil {
		fmt.eprintln("FAIL vu_text: no temp directory:", err)
		os.exit(1)
	}
	defer os.remove_all(dir)
	good, bad_text, bad := join({dir, "good.elf"}), join({dir, "past.elf"}), join({dir, "bad.bin"})
	write(good, elf(mixed()))
	write(bad_text, elf(past()))
	write(bad, {'X'})

	code, funcs, spans := convert(dir, "plain", good, {"native_vu", "true"})
	check(code == 0 && funcs > 0 && spans == 2, fmt.tprintf("a conversion with no capture: exit %d, %d functions, %d programs; want 0, some, 2", code, funcs, spans))
	ee := funcs
	code, funcs, spans = convert(dir, "vu1", good, {"native_vu", "true", "vu1_capture", bad})
	check(code == 0 && funcs == ee && spans == 0, fmt.tprintf("fail soft, bad VU1 capture: exit %d, %d functions, %d programs; want 0, %d, 0", code, funcs, spans, ee))
	code, funcs, spans = convert(dir, "vu0", good, {"native_vu", "true", "vu0_capture", bad})
	check(code == 0 && funcs == ee && spans == 2, fmt.tprintf("fail soft, bad VU0 capture: exit %d, %d functions, %d programs; want 0, %d, 2", code, funcs, spans, ee))
	code, funcs, spans = convert(dir, "text", bad_text, {"native_vu", "true"})
	check(code == 0 && funcs == ee && spans == 0, fmt.tprintf("fail soft, bad .vutext: exit %d, %d functions, %d programs; want 0, %d, 0", code, funcs, spans, ee))
	code, funcs, _ = convert(dir, "only", good, {"vu_only", "true", "vu1_capture", bad})
	check(code != 0 && funcs == -1, fmt.tprintf("the VU programs alone with a bad VU1 capture: exit %d, blob %v; want a failure and no blob", code, funcs != -1))
	code, funcs, spans = convert(dir, "only_good", good, {"vu_only", "true"})
	check(code == 0 && funcs == 0 && spans == 2, fmt.tprintf("the VU programs alone: exit %d, %d functions, %d programs; want 0, 0, 2", code, funcs, spans))
}

main :: proc() {
	if len(os.args) == 3 && os.args[1] == "convert" {
		r5900.generate(mips.load_options(os.args[2]))
		return
	}
	scanner()
	fail_soft()
	if fails > 0 {os.exit(1)}
	fmt.println("ok vu_text: the scan leaves a bundle out and goes on; a VU half that fails leaves the EE blob")
}
