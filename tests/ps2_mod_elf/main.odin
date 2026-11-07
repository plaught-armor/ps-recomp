// An EE mod built from C (mods/build.sh) on a hand-assembled game, loaded
// as a port loads one: ps2.mods_read of tests/ps2_mod_elf/mods, then
// ps2.mods_load. Plain (with the game's 8-argument function registered as
// recompiled code; `interp`: none), `native` (as plain, and the mod's own
// functions compiled for this host by r5900.mods_blob and loaded by
// ps2.load_mods, as play's --mods child and boot do), and
// -define:PS_FLAT=true.
//
//   - native: a blob of the mod's functions with one word changed (a stale
//     blob, as after an edit) and the arm64 blob on an x64 host are
//     refused, and the mod then runs from the host's blob: every call into
//     the mod region reaches native code, none the interpreter. The arm64
//     blob is built and its header and spans read, never run.
//
//   - api/mod_api.h and api/mod.ld are recomp --mod-api's for the game's
//     ELF (`odin run tests/ps2_mod_elf -collection:ps=. -- update` writes
//     them, and with clang mods/abi/mod.elf and clang.txt); with clang,
//     ld.lld, llvm-nm, llvm-objdump and sh, mods/abi/mod.c builds, to the
//     committed mod.elf byte for byte when clang's major version is
//     clang.txt's (another clang's code may differ).
//   - mods/abi hooks G_WIDE with a before, an after and a replacement,
//     which sees, passes on (mod_call_original) and returns 64-bit values.
//   - Its replacement of G_ADD8 calls the original with 8 arguments
//     changed (a0-a7) and the unhooked G_SUM9 with 9 (the ninth on the
//     stack, as n32 passes it).
//   - Its before hook and its replacement of G_KEEP change all 128 bits of
//     s0, which the game holds a 128-bit value in, and the replacement
//     changes $f21 and $f31, which the game holds floats in: the game sees
//     them as they were after the call.
//   - Its before hook converts a float with mod_f2i (cvt.w.s), truncating.
package main

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"
import "ps:recomp/mips"
import rnative "ps:recomp/native"
import "ps:recomp/r5900"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL ps2_mod_elf: %s (line %d)", what, loc.line)
		failed += 1
	}
}

DIR :: "tests/ps2_mod_elf"
ENTRY :: u32(0x00100000)
G_WIDE :: ENTRY + 0x400 // v0 = a0 + 1, 64-bit
G_ADD8 :: ENTRY + 0x500 // v0 = a0 + ... + a7
G_SUM9 :: ENTRY + 0x600 // G_ADD8's sum + the word at 0(sp)
G_KEEP :: ENTRY + 0x700 // returns
DATA :: u32(0x00180000) // the game's results, then (LOG) the mod's
LOG :: DATA + 0x40
DONE :: DATA + 0x30
STACK :: u32(0x001a0000)
WIDE :: u64(0x0000_0005_0000_0007)
S0_LO :: u64(0x1111_2222)
S0_HI :: u64(0x3333_4444)
F21 :: u32(0x3fc0_0000) // 1.5
F31 :: u32(0xc020_0000) // -2.5

ZERO :: 0
V0 :: 2
A0 :: 4
T9 :: 25
T8 :: 24
T7 :: 15
T4 :: 12
S0 :: 16
SP :: 29

i_type :: proc(op, rs, rt: u32, imm: i32) -> u32 {return op << 26 | rs << 21 | rt << 16 | (u32(imm) & 0xffff)}
r_type :: proc(rs, rt, rd, sa, fn: u32) -> u32 {return rs << 21 | rt << 16 | rd << 11 | sa << 6 | fn}
addiu :: proc(rt, rs: u32, imm: i32) -> u32 {return i_type(9, rs, rt, imm)}
addu :: proc(rd, rs, rt: u32) -> u32 {return r_type(rs, rt, rd, 0, 0x21)}
lui :: proc(rt, imm: u32) -> u32 {return i_type(15, 0, rt, i32(imm))}
jal :: proc(t: u32) -> u32 {return 3 << 26 | (t >> 2) & 0x3ff_ffff}
JR_RA :: 0x03e0_0008
NOP :: 0

Asm :: struct {
	pc: u32,
}

put :: proc(a: ^Asm, words: ..u32) {
	for w in words {
		mem.wr32(a.pc, w)
		a.pc += 4
	}
}

li :: proc(a: ^Asm, r, v: u32) {
	put(a, lui(r, v >> 16), i_type(13, r, r, i32(v & 0xffff))) // ori
}

// a0-a7 ($4-$11) = 1-8.
args8 :: proc(a: ^Asm) {
	for r in u32(4) ..= 11 {put(a, addiu(r, ZERO, i32(r) - 3))}
}

program :: proc() {
	a := Asm{ENTRY}
	li(&a, SP, STACK)
	li(&a, S0, u32(S0_LO))
	li(&a, T8, u32(S0_HI))
	put(&a, r_type(T8, S0, S0, 0x0e, 0x09) | 0x7000_0000) // pcpyld s0, t8, s0
	put(&a, addiu(A0, ZERO, i32(WIDE >> 32)), r_type(0, A0, A0, 0, 0x3c), i_type(13, A0, A0, i32(WIDE & 0xffff))) // dsll32, ori
	put(&a, jal(G_WIDE), NOP, lui(T7, DATA >> 16), i_type(0x3f, T7, V0, 0)) // sd v0, 0(t7)
	args8(&a)
	put(&a, jal(G_ADD8), NOP, lui(T7, DATA >> 16), i_type(0x2b, T7, V0, 8)) // sw v0, 8(t7)
	args8(&a)
	put(&a, addiu(SP, SP, -16), addiu(T9, ZERO, 1000), i_type(0x2b, SP, T9, 0)) // sw t9, 0(sp)
	put(&a, jal(G_SUM9), NOP, addiu(SP, SP, 16), lui(T7, DATA >> 16), i_type(0x2b, T7, V0, 12))
	li(&a, T8, F21)
	put(&a, 0x4480_0000 | T8 << 16 | 21 << 11) // mtc1 t8, $f21
	li(&a, T8, F31)
	put(&a, 0x4480_0000 | T8 << 16 | 31 << 11) // mtc1 t8, $f31
	put(&a, jal(G_KEEP), NOP, lui(T7, DATA >> 16), i_type(0x1f, T7, S0, 16)) // sq s0, 16(t7)
	put(&a, i_type(0x39, T7, 21, 32), i_type(0x39, T7, 31, 36)) // swc1 $f21, 32(t7); swc1 $f31, 36(t7)
	put(&a, addiu(T4, ZERO, 1), i_type(0x2b, T7, T4, i32(DONE - DATA)))
	put(&a, i_type(4, ZERO, ZERO, -1), NOP) // hang

	a = {G_WIDE}
	put(&a, JR_RA, i_type(0x19, A0, V0, 1), NOP, NOP) // daddiu v0, a0, 1
	for at in ([2]u32{G_ADD8, G_SUM9}) {
		a = {at}
		put(&a, addu(V0, 4, 5))
		for r in u32(6) ..= 11 {put(&a, addu(V0, V0, r))}
		if at == G_SUM9 {put(&a, i_type(0x23, SP, T8, 0), NOP, addu(V0, V0, T8))} // lw t8, 0(sp)
		put(&a, JR_RA, NOP)
	}
	a = {G_KEEP}
	put(&a, JR_RA, NOP, NOP, NOP)
}

// An ELF file loading code at ENTRY, entered there: a program header for
// the kernel, a .text section for recomp.
make_elf :: proc(code: []u8) -> []u8 {
	TEXT :: 0x60
	names := "\x00.text\x00.shstrtab\x00"
	str_off := TEXT + len(code)
	sh_off := (str_off + len(names) + 3) &~ 3
	b := make([]u8, sh_off + 3 * 40)
	put := proc(b: []u8, at: int, v: u32, n: int) {for i in 0 ..< n {b[at + i] = u8(v >> uint(8 * i))}}
	put(b, 0, 0x464c457f, 4)
	b[4], b[5], b[6] = 1, 1, 1 // 32-bit, little-endian, version 1
	put(b, 16, 2, 2) // executable
	put(b, 18, 8, 2) // MIPS
	put(b, 20, 1, 4)
	put(b, 24, ENTRY, 4)
	put(b, 28, 52, 4) // phoff
	put(b, 32, u32(sh_off), 4)
	put(b, 40, 52, 2) // ehsize
	put(b, 42, 32, 2) // phentsize
	put(b, 44, 1, 2) // phnum
	put(b, 46, 40, 2) // shentsize
	put(b, 48, 3, 2) // shnum
	put(b, 50, 2, 2) // shstrndx
	put(b, 52, 1, 4) // PT_LOAD
	put(b, 56, TEXT, 4)
	put(b, 60, ENTRY, 4)
	put(b, 64, ENTRY, 4)
	put(b, 68, u32(len(code)), 4)
	put(b, 72, u32(len(code)), 4)
	put(b, 76, 7, 4) // rwx
	copy(b[TEXT:], code)
	copy(b[str_off:], names)
	text := sh_off + 40
	put(b, text, 1, 4)
	put(b, text + 4, 1, 4) // PROGBITS
	put(b, text + 8, 6, 4) // ALLOC | EXECINSTR
	put(b, text + 12, ENTRY, 4)
	put(b, text + 16, TEXT, 4)
	put(b, text + 20, u32(len(code)), 4)
	put(b, text + 32, 4, 4)
	strs := sh_off + 80
	put(b, strs, 7, 4)
	put(b, strs + 4, 3, 4) // STRTAB
	put(b, strs + 16, u32(str_off), 4)
	put(b, strs + 20, u32(len(names)), 4)
	put(b, strs + 32, 1, 4)
	return b
}

join :: proc(parts: []string) -> string {return strings.join(parts, "/", context.temp_allocator)}

write :: proc(dir, name: string, b: []u8) {
	_ = os.make_directory_all(dir)
	if err := os.write_entire_file(join({dir, name}), b); err != nil {
		fmt.eprintln("FAIL ps2_mod_elf: write", dir, name, err)
		os.exit(1)
	}
}

have_tools :: proc(tools: []string) -> bool {
	for tool in tools {
		state, _, _, err := os.process_exec({command = {tool, "--version"}}, context.temp_allocator)
		if err != nil || !state.exited || state.exit_code != 0 {
			fmt.printfln("ps2_mod_elf: skip build: no %s", tool)
			return false
		}
	}
	return true
}

// The game's API against the committed one, and with the tools, mod.c's
// build against the committed mod.elf; update writes both.
api_and_build :: proc(elf: []u8, update: bool) {
	tmp, terr := os.make_directory_temp("", "ps_ps2_mod_elf_*", context.allocator)
	if terr != nil {
		fmt.eprintln("FAIL ps2_mod_elf: temp dir:", terr)
		os.exit(1)
	}
	defer os.remove_all(tmp)
	write(tmp, "game.elf", elf)
	write(tmp, "options.tsv", transmute([]u8)fmt.tprintf("key\tvalue\nbackend\tr5900\nexe\t%s\nquiet\ttrue\n", join({tmp, "game.elf"})))
	spaces, rows := r5900.mod_api_load(mips.load_options(join({tmp, "options.tsv"})))
	header, script, skips, err := r5900.mod_api(spaces, rows)
	check(err == "" && skips == {} && len(rows) == 5, fmt.tprint("api:", err, skips, len(rows)))
	if update {
		write(DIR + "/api", "mod_api.h", transmute([]u8)header)
		write(DIR + "/api", "mod.ld", transmute([]u8)script)
	}
	golden_h, _ := os.read_entire_file(DIR + "/api/mod_api.h", context.temp_allocator)
	golden_ld, _ := os.read_entire_file(DIR + "/api/mod.ld", context.temp_allocator)
	check(header == string(golden_h) && script == string(golden_ld), "api/mod_api.h and api/mod.ld are the game's")

	if !have_tools({"clang", "ld.lld", "llvm-nm", "llvm-objdump", "sh"}) {return}
	src, _ := os.read_entire_file(DIR + "/mods/abi/mod.c", context.temp_allocator)
	write(join({tmp, "abi"}), "mod.c", src)
	state, _, errs, perr := os.process_exec({command = {"sh", "mods/build.sh", DIR + "/api", join({tmp, "abi"})}}, context.temp_allocator)
	if perr != nil || !state.exited || state.exit_code != 0 {
		check(false, fmt.tprintf("build: %v exit %d: %s", perr, state.exit_code, string(errs)))
		return
	}
	built, _ := os.read_entire_file(join({tmp, "abi", "mod.elf"}), context.temp_allocator)
	major := clang_major()
	if update {
		write(DIR + "/mods/abi", "mod.elf", built)
		write(DIR, "clang.txt", transmute([]u8)fmt.tprintf("%s\n", major))
	}
	pinned, _ := os.read_entire_file(DIR + "/clang.txt", context.temp_allocator)
	if strings.trim_space(string(pinned)) != major {
		fmt.printfln("ps2_mod_elf: skip mod.elf compare: clang %s, mod.elf is clang %s's", major, strings.trim_space(string(pinned)))
		return
	}
	committed, _ := os.read_entire_file(DIR + "/mods/abi/mod.elf", context.temp_allocator)
	check(bytes.equal(built, committed), "mods/abi/mod.elf is mod.c's build")
}

// clang's major version, from `clang --version` ("... clang version 23.1.4 ...").
clang_major :: proc() -> string {
	_, out, _, _ := os.process_exec({command = {"clang", "--version"}}, context.temp_allocator)
	s := string(out)
	k := strings.index(s, "clang version ")
	if k < 0 {return "?"}
	s = s[k + len("clang version "):]
	if d := strings.index_byte(s, '.'); d > 0 {return s[:d]}
	return "?"
}

add8_calls: int

// G_ADD8 as recompiled code.
fn_add8 :: proc() {
	add8_calls += 1
	r := &cpu.state.r
	sum: u32
	for k in 4 ..= 11 {sum += r[k].w[0]}
	r[V0].d[0] = u64(i64(i32(sum)))
}

native: bool
// The mod's own functions run as native code (`native`).
mods_native: bool

vblank :: proc() {
	if mem.rd32(DONE) == 0 {
		if kernel.k.frame > 60 {
			fmt.eprintln("FAIL ps2_mod_elf: the game did not finish")
			os.exit(1)
		}
		return
	}
	wide := u64(mem.rd32(DATA)) | u64(mem.rd32(DATA + 4)) << 32
	check(wide == WIDE + 1 << 32 + 2, fmt.tprintf("G_WIDE gave %016x", wide))
	for k in u32(0) ..< 2 {
		seen := u64(mem.rd32(LOG + 8 * k)) | u64(mem.rd32(LOG + 8 * k + 4)) << 32
		check(seen == WIDE, fmt.tprintf("G_WIDE's %s hook saw %016x", k == 0 ? "before" : "after", seen))
	}
	check(mem.rd32(DATA + 8) == 38 + 136, fmt.tprintf("G_ADD8 gave %d", mem.rd32(DATA + 8)))
	check(mem.rd32(DATA + 12) == 1036, fmt.tprintf("G_SUM9 gave %d", mem.rd32(DATA + 12)))
	check(!native || add8_calls == 1, fmt.tprintf("recompiled G_ADD8 ran %d times", add8_calls))
	s0: [4]u32
	for &w, k in s0 {w = mem.rd32(DATA + 16 + 4 * u32(k))}
	check(s0 == {u32(S0_LO), 0, u32(S0_HI), 0}, fmt.tprintf("s0 after G_KEEP %08x", s0))
	check(mem.rd32(DATA + 32) == F21 && mem.rd32(DATA + 36) == F31, fmt.tprintf("$f21 $f31 after G_KEEP %08x %08x", mem.rd32(DATA + 32), mem.rd32(DATA + 36)))
	check(mem.rd32(LOG + 16) == 1, fmt.tprintf("G_KEEP's before hook ran %d times", mem.rd32(LOG + 16)))
	check(mem.rd32(LOG + 24) == transmute(u32)i32(-2), fmt.tprintf("mod_f2i(-2.75) gave %d", i32(mem.rd32(LOG + 24))))
	if mods_native {
		check(mem.mod_native_calls > 0, "no call reached the mod's native code")
		check(mem.mod_interp_calls == 0, fmt.tprintf("%d calls into the mod region were interpreted", mem.mod_interp_calls))
	} else if !core.FLAT {
		check(mem.mod_native_calls == 0, "native mod calls with no mods blob")
		check(mem.mod_interp_calls > 0, "no interpreted call into the mod region")
	}
	when !core.FLAT {hooks_keep_cop0()}
	if failed > 0 {os.exit(1)}
	fmt.println("ps2_mod_elf: ok")
	os.exit(0)
}

// The hooks, for hooks_keep_cop0.
hooks: []core.Mod_Hook

// Each before and after hook's own code, run on its own, leaves cop0 as it
// was: mod_call puts every register back but cop0, which only game code
// a hook calls may change.
hooks_keep_cop0 :: proc() {
	ran := 0
	for h in hooks {
		if h.kind == .Replace {continue}
		cop0, sp, next := cpu.state.cop0, cpu.state.r[29], cpu.next_event
		cpu.state.r[29].q = u128(mem.mod_sp)
		cpu.next_event = max(u64)
		cpu.mod_depth += 1
		cpu.call(h.fn)
		cpu.mod_depth -= 1
		check(cpu.state.cop0 == cop0, fmt.tprintf("the hook at %08x changed cop0", h.fn))
		cpu.state.r[29], cpu.next_event = sp, next
		ran += 1
	}
	check(ran == 3, fmt.tprintf("%d before and after hooks run on their own", ran))
}

main :: proc() {
	update := len(os.args) == 2 && os.args[1] == "update"
	ps2.init()
	cpu.text_range(ENTRY, ENTRY + 0x1000)
	native = !core.FLAT && !(len(os.args) == 2 && os.args[1] == "interp")
	mods_native = !core.FLAT && len(os.args) == 2 && os.args[1] == "native"
	if native {cpu.register(G_ADD8, fn_add8)}
	kernel.vblank_hook = vblank
	program()
	elf := make_elf(mem.ram[ENTRY:][:0x1000])
	api_and_build(elf, update)
	kernel.exec_boot_program(elf)
	set, _, err := ps2.mods_read(DIR + "/mods", "")
	check(err == "" && len(set.mods) == 1 && len(set.hooks) == 6, fmt.tprint("mods_read:", err, len(set.mods), len(set.hooks)))
	// set.hooks is in the temp allocator, which mods_blob frees.
	hooks = slice.clone(set.hooks)
	funcs := mod_funcs(set)
	if err = ps2.mods_load(set); err != "" {
		fmt.eprintln("FAIL ps2_mod_elf:", err)
		os.exit(1)
	}
	when !core.FLAT {if mods_native {load_native(funcs)}}
	ps2.run(ENTRY)
}

// The mods' functions as play's --mods child reads them: one run each,
// entered at its first word.
mod_funcs :: proc(set: core.Mod_Set) -> []r5900.Learned {
	funcs := make([dynamic]r5900.Learned)
	for img in set.images {
		for f in img.funcs {
			words := make([]u32, len(f.bytes) / 4)
			for &w, i in words {
				b := f.bytes[i * 4:]
				w = u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
			}
			append(&funcs, r5900.Learned{f.addr, f.addr, words})
		}
	}
	return funcs[:]
}

// The refused blobs, then the host's.
load_native :: proc(funcs: []r5900.Learned) {
	check(len(funcs) > 0, "the mod has no functions")
	tmp, terr := os.make_directory_temp("", "ps_ps2_mod_native_*", context.allocator)
	if terr != nil {
		fmt.eprintln("FAIL ps2_mod_elf: temp dir:", terr)
		os.exit(1)
	}
	defer os.remove_all(tmp)
	arch, ok := rnative.arch_of("mods", mips.HOST_ARCH)
	check(ok, "no native arch for this host")

	arm64, arm_skipped := r5900.mods_blob(funcs, .Arm64)
	arm64_spans(arm64, funcs, arm_skipped)
	if arch != .Arm64 {
		write(tmp, "arm64.bin", arm64)
		why := ps2.load_mods(join({tmp, "arm64.bin"}))
		check(strings.contains(why, "built for arch"), fmt.tprintf("the arm64 blob on this host: %q", why))
	}

	// A stale blob: one word of the last function changed, as after an edit.
	last := &funcs[len(funcs) - 1]
	was := last.words[0]
	last.words[0] ~= 0x0000_0001
	stale, _ := r5900.mods_blob(funcs, arch)
	last.words[0] = was
	write(tmp, "stale.bin", stale)
	why := ps2.load_mods(join({tmp, "stale.bin"}))
	check(strings.contains(why, "is not the mods' code"), fmt.tprintf("the stale blob: %q", why))
	check(mem.mod_func_at(last.entry) == nil, "the stale blob left code behind")

	blob, skipped := r5900.mods_blob(funcs, arch)
	check(skipped == 0, fmt.tprintf("%d of the mod's %d functions not lowered", skipped, len(funcs)))
	// The jal to mod_call_original in replace_add8 calls it direct, on
	// both backends, not through cpu.call.
	for b in ([2][]u8{blob, arm64}) {
		check(bytes.contains(b, transmute([]u8)string("ps2.mod_call_original")), "the mods blob does not import ps2.mod_call_original")
	}
	write(tmp, "mods.bin", blob)
	why = ps2.load_mods(join({tmp, "mods.bin"}))
	check(why == "", fmt.tprintf("the host's blob: %q", why))
	for f in funcs {check(mem.mod_func_at(f.entry) != nil, fmt.tprintf("no native code for %08x", f.entry))}
}

// The arm64 blob's header and spans: an Ee span per function, one range
// each, the function's words. Read as bytes: an x64 host cannot map it.
arm64_spans :: proc(blob: []u8, funcs: []r5900.Learned, skipped: int) {
	at := 0
	word :: proc(blob: []u8, at: ^int) -> u32 {
		if at^ + 4 > len(blob) {return 0}
		b := blob[at^:]
		at^ += 4
		return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
	}
	h: [core.NATIVE_HEADER / 4]u32
	for &v in h {v = word(blob, &at)}
	n := u32(len(funcs) - skipped)
	check(h[0] == core.NATIVE_MAGIC && h[1] == core.NATIVE_VERSION && h[2] == u32(rnative.Arch.Arm64), fmt.tprintf("arm64 header %x", h[:3]))
	check(skipped == 0, fmt.tprintf("arm64: %d functions not lowered", skipped))
	check(h[4] == 0 && h[5] == 0 && h[6] == 0 && h[7] == n && h[8] == n && h[10] > 0, fmt.tprintf("arm64 counts %v", h))
	for _ in 0 ..< h[3] {
		if at + 2 > len(blob) {break}
		at += 2 + (int(blob[at]) | int(blob[at + 1]) << 8)
	}
	at += 8 * int(h[4]) + 32 * int(h[5]) + 12 * int(h[6]) // funcs, overlays, interp
	spans := make([][5]u32, h[7], context.temp_allocator)
	for &sp in spans {for &v in sp {v = word(blob, &at)}}
	ranges := make([][3]u32, h[8], context.temp_allocator)
	for &r in ranges {for &v in r {v = word(blob, &at)}}
	pool := make([]u32, h[9], context.temp_allocator)
	for &w in pool {w = word(blob, &at)}
	check(at + int(h[10]) == len(blob), "arm64 blob size")
	for sp, k in spans {
		if k >= len(funcs) {break}
		f := funcs[k]
		check(sp[0] == u32(core.Native_Kind.Ee) && sp[1] == f.entry && sp[2] < h[11] && sp[4] == 1, fmt.tprintf("arm64 span %d %v", k, sp))
		if sp[3] >= u32(len(ranges)) {continue}
		r := ranges[sp[3]]
		ok := r[0] == f.lo && int(r[1]) == len(f.words) && u64(r[2]) + u64(r[1]) <= u64(len(pool))
		if ok {for w, i in f.words {ok &&= pool[r[2] + u32(i)] == w}}
		check(ok, fmt.tprintf("arm64 span %d range %v", k, r))
	}
}
