// ps2's EE mod hooks (mod.odin) on a guest program run by the kernel, as
// the main thread, in both models (plain and -define:PS_FLAT=true). Two
// mods, a and b, whose code is guest code in the mod region, interpreted:
//
//   G_A  a before hook (a), an after hook (b): the before sees the mod
//        stack and its clobbering of a0 and s0 is undone; the after sees
//        the entry a0 (G_A changes it) and the result v0
//   G_R  a replaces it with code that calls its original (mod_call_original)
//        on a0 + 1 and adds 1000
//   G_L  a before hook (b) that counts; G_L loops by jumping to its own
//        entry, which is no call: the hook runs once
//   G_T  not hooked: a tail jump (j) to G_A runs G_A's chain
//   G_J  not hooked: a tail jump through a register (jr) to G_A
//   G_C  a before hook (b) that counts; registered recompiled code in the
//        plain build (its thunk calls the registered procedure)
//
// Then from host code (the vblank hook): a call to G_A runs its chain; with
// another program named in RAM (kernel k.exec.prog), or G_A's fourth word
// changed, it runs without. Then the program is started again, each run
// logging anew: by ExecPS2 with a word of its text changed (no program the
// mods name: no chain), by ExecPS2 with it back (the chains again), by
// LoadExecPS2 of another ELF file with the same code (another program: no
// chain), and by LoadExecPS2 of the boot ELF file (the chains again).
// Before the program runs: keys for another slot or program, a misaligned
// address and code that is not the key's are refused, nothing installed;
// mods_check refuses mods whose hooked set the recompiled code was not
// built for. Fatal (a child process each): mod_call_original with no
// replacement running, from a before hook, and from inside an original.
//
// Built for wasi_wasm32 (run.mjs runs it under Node) the program's unhooked
// functions run as a wasm32 blob (wasm.odin): G_T's and G_J's jumps leave
// native code and must reach G_A's chain. There are no child processes
// and no disc directory there, so the fatal cases are not run and the
// program is not started again (the host calls are).
package main

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:strings"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL ps2_mod: %s (line %d)", what, loc.line)
		failed += 1
	}
}

ENTRY :: u32(0x00100000)
G_A :: ENTRY + 0x400
G_R :: ENTRY + 0x500
G_L :: ENTRY + 0x600
G_T :: ENTRY + 0x700
G_J :: ENTRY + 0x800
G_C :: ENTRY + 0x900
G_X :: ENTRY + 0xa00 // children: a before hook calls mod_call_original
G_Y :: ENTRY + 0xb00 // children: replaced; its original calls it
DATA :: u32(0x00180000) // the log: a count, then the entries
DONE :: DATA + 0x100
CHILD :: DATA + 0x104 // a child's: the function the program calls first
NEXT :: DATA + 0x108 // once done, the syscall to start the program again with
NEXT_A0 :: DATA + 0x10c // and its a0
NAME :: DATA + 0x200 // LoadExecPS2's file name
TEXT_WORD :: ENTRY + 0xf00 // in the recompiled range, in no function
STACK :: u32(0x001a0000)

M_BEFORE_A :: mem.MOD_BASE
M_AFTER_B :: mem.MOD_BASE + 0x100
M_REPLACE_R :: mem.MOD_BASE + 0x200
M_COUNT :: mem.MOD_BASE + 0x300
M_ORIGINAL :: mem.MOD_BASE + 0x400 // a before hook that calls the original
M_REPLACE_Y :: mem.MOD_BASE + 0x500
MOD_CODE :: 0x600

ZERO :: 0
V0 :: 2
V1 :: 3
A0 :: 4
A1 :: 5
A2 :: 6
A3 :: 7
T4 :: 12
T5 :: 13
T6 :: 14
T7 :: 15
S0 :: 16
T9 :: 25
SP :: 29
RA :: 31

i_type :: proc(op, rs, rt: u32, imm: i32) -> u32 {return op << 26 | rs << 21 | rt << 16 | (u32(imm) & 0xffff)}
r_type :: proc(rs, rt, rd, sa, fn: u32) -> u32 {return rs << 21 | rt << 16 | rd << 11 | sa << 6 | fn}
j_type :: proc(op, target: u32) -> u32 {return op << 26 | (target >> 2) & 0x3ffffff}
addiu :: proc(rt, rs: u32, imm: i32) -> u32 {return i_type(9, rs, rt, imm)}
lui :: proc(rt, imm: u32) -> u32 {return i_type(15, 0, rt, i32(imm))}
lw :: proc(rt, off, base: u32) -> u32 {return i_type(0x23, base, rt, i32(off))}
sw :: proc(rt, off, base: u32) -> u32 {return i_type(0x2b, base, rt, i32(off))}
jal :: proc(t: u32) -> u32 {return j_type(3, t)}
JR_RA :: 0x03e00008
SYSCALL :: 0x0000000c
NOP :: 0

// Guest code at pc: into RAM, or into buf (the mod image, from MOD_BASE).
Asm :: struct {
	pc:  u32,
	buf: []u8,
}

put :: proc(a: ^Asm, words: ..u32) {
	for w in words {
		if a.buf != nil {
			(^u32le)(&a.buf[a.pc - mem.MOD_BASE])^ = u32le(w)
		} else {
			mem.wr32(a.pc, w)
		}
		a.pc += 4
	}
}

li :: proc(a: ^Asm, r, v: u32) {
	put(a, lui(r, v >> 16), i_type(13, r, r, i32(v & 0xffff))) // ori
}

// Append register r to the log (t5-t7 clobbered).
log :: proc(a: ^Asm, r: u32) {
	put(a,
		lui(T7, DATA >> 16),
		lw(T6, 0, T7),
		addiu(T5, T6, 1),
		sw(T5, 0, T7),
		r_type(0, T6, T6, 2, 0), // sll t6, t6, 2
		r_type(T6, T7, T6, 0, 0x21), // addu t6, t6, t7
		sw(r, 4, T6),
	)
}

log_code :: proc(a: ^Asm, code: i32) {
	put(a, addiu(T4, ZERO, code))
	log(a, T4)
}

// Call t with a0 = arg, then log v0.
call_log :: proc(a: ^Asm, t: u32, arg: i32) {
	put(a, addiu(A0, ZERO, arg), jal(t), NOP)
	log(a, V0)
}

program :: proc() {
	a := Asm{pc = ENTRY}
	li(&a, SP, STACK)
	li(&a, S0, 0x1234)
	// A child calls the function at CHILD first.
	put(&a, lui(T7, DATA >> 16), lw(T9, CHILD - DATA, T7))
	put(&a, i_type(4, T9, ZERO, 3), NOP) // beq t9, zero, past the call
	put(&a, r_type(T9, 0, RA, 0, 9), NOP) // jalr t9
	call_log(&a, G_A, 5)
	call_log(&a, G_R, 1)
	call_log(&a, G_L, 3)
	call_log(&a, G_T, 5)
	call_log(&a, G_J, 5)
	call_log(&a, G_C, 5)
	log(&a, S0)
	put(&a, addiu(T4, ZERO, 1), lui(T7, DATA >> 16), sw(T4, DONE - DATA, T7))
	// Wait for the host's NEXT, then make that syscall.
	put(&a, lw(T9, NEXT - DATA, T7), i_type(4, T9, ZERO, -2), NOP) // beq t9, zero, back
	put(&a, sw(ZERO, NEXT - DATA, T7), lw(A0, NEXT_A0 - DATA, T7), r_type(T9, ZERO, V1, 0, 0x21)) // addu v1, t9, zero
	put(&a, addiu(A1, ZERO, 0), addiu(A2, ZERO, 0), addiu(A3, ZERO, 0), SYSCALL)
	put(&a, i_type(4, ZERO, ZERO, -1), NOP) // hang

	a = {pc = G_A}
	put(&a, addiu(V0, A0, 1), JR_RA, addiu(A0, ZERO, 55), NOP) // a0 changed

	a = {pc = G_R}
	put(&a, JR_RA, addiu(V0, A0, 10), NOP, NOP)
	a = {pc = G_L}
	put(&a, i_type(4, A0, ZERO, 3), NOP) // beq a0, zero, out
	put(&a, addiu(A0, A0, -1), j_type(2, G_L), NOP)
	put(&a, JR_RA, NOP) // out
	a = {pc = G_T}
	put(&a, addiu(A0, A0, 2), j_type(2, G_A), NOP, NOP)
	a = {pc = G_J}
	li(&a, T9, G_A)
	put(&a, r_type(T9, 0, 0, 0, 8), NOP) // jr t9
	a = {pc = G_C}
	put(&a, JR_RA, addiu(V0, A0, 100), NOP, NOP)
	a = {pc = G_X}
	put(&a, JR_RA, NOP, NOP, NOP)
	a = {pc = G_Y}
	put(&a, addiu(SP, SP, -16), sw(RA, 0, SP), jal(mem.MOD_ORIGINAL), NOP, lw(RA, 0, SP), JR_RA, addiu(SP, SP, 16))
}

mod_code :: proc() -> []u8 {
	buf := make([]u8, MOD_CODE)
	a := Asm{pc = M_BEFORE_A, buf = buf}
	log_code(&a, 1)
	put(&a, r_type(0, SP, T4, 24, 2)) // srl t4, sp, 24
	log(&a, T4)
	put(&a, addiu(A0, ZERO, 77), addiu(S0, ZERO, 99), JR_RA, NOP)

	a.pc = M_AFTER_B
	log_code(&a, 2)
	log(&a, A0)
	log(&a, V0)
	put(&a, JR_RA, NOP)

	a.pc = M_REPLACE_R
	put(&a, addiu(SP, SP, -16), sw(RA, 0, SP), addiu(A0, A0, 1), jal(mem.MOD_ORIGINAL), NOP)
	put(&a, lw(RA, 0, SP), addiu(SP, SP, 16), JR_RA, addiu(V0, V0, 1000))

	a.pc = M_COUNT
	log_code(&a, 3)
	put(&a, JR_RA, NOP)

	a.pc = M_ORIGINAL
	put(&a, jal(mem.MOD_ORIGINAL), NOP, JR_RA, NOP)

	a.pc = M_REPLACE_Y
	put(&a, addiu(SP, SP, -16), sw(RA, 0, SP), jal(mem.MOD_ORIGINAL), NOP, lw(RA, 0, SP), JR_RA, addiu(SP, SP, 16))
	return buf
}

// The boot program's ELF file: the code program wrote, from ENTRY.
boot_elf: []u8

// An ELF file loading code at ENTRY, entered there; pad bytes after it.
make_elf :: proc(code: []u8, pad: int) -> []u8 {
	b := make([]u8, 84 + len(code) + pad)
	put := proc(b: []u8, at: int, v: u32, n: int) {for i in 0 ..< n {b[at + i] = u8(v >> uint(8 * i))}}
	put(b, 0, 0x464c457f, 4)
	b[4], b[5], b[6] = 1, 1, 1 // 32-bit, little-endian, version 1
	put(b, 16, 2, 2) // executable
	put(b, 18, 8, 2) // MIPS
	put(b, 20, 1, 4)
	put(b, 24, ENTRY, 4)
	put(b, 28, 52, 4) // phoff
	put(b, 40, 52, 2) // ehsize
	put(b, 42, 32, 2) // phentsize
	put(b, 44, 1, 2) // phnum
	put(b, 52, 1, 4) // PT_LOAD
	put(b, 56, 84, 4) // offset
	put(b, 60, ENTRY, 4) // vaddr
	put(b, 64, ENTRY, 4) // paddr
	put(b, 68, u32(len(code)), 4) // filesz
	put(b, 72, u32(len(code)), 4) // memsz
	put(b, 76, 7, 4) // rwx
	copy(b[84:], code)
	return b
}

key :: proc(addr: u32) -> core.Mod_Key {
	k := core.Mod_Key{id = u32(xxhash.XXH3_64_default(boot_elf)), addr = addr}
	for &w, i in k.sig {w = mem.rd32(addr + 4 * u32(i))}
	return k
}

// The two mods with their hooks; bad changes the first hook's key.
make_set :: proc(bad: proc(k: ^core.Mod_Key) = nil) -> core.Mod_Set {
	mods := make([]core.Mod_Manifest, 2)
	mods[0] = {id = strings.clone("a"), version = {1, 0, 0}, api = core.MOD_API}
	mods[1] = {id = strings.clone("b"), version = {1, 0, 0}, api = core.MOD_API}
	code := mod_code()
	// One image per mod: a's holds all the code, b's is empty.
	images := make([]core.Mod_Image, 2)
	segs := make([]core.Mod_Segment, 1)
	segs[0] = {addr = mem.MOD_BASE, size = MOD_CODE, bytes = code, exec = true}
	funcs := make([]core.Mod_Func, 1)
	funcs[0] = {addr = mem.MOD_BASE, bytes = code}
	images[0] = {lo = mem.MOD_BASE, hi = mem.MOD_BASE + MOD_CODE, segments = segs, funcs = funcs}
	images[1] = {lo = mem.MOD_BASE + MOD_CODE, hi = mem.MOD_BASE + MOD_CODE}
	hooks := make([dynamic]core.Mod_Hook)
	append(&hooks,
		core.Mod_Hook{key = key(G_A), kind = .Before, mod = 0, fn = M_BEFORE_A},
		core.Mod_Hook{key = key(G_A), kind = .After, mod = 1, fn = M_AFTER_B},
		core.Mod_Hook{key = key(G_R), kind = .Replace, mod = 0, fn = M_REPLACE_R},
		core.Mod_Hook{key = key(G_L), kind = .Before, mod = 1, fn = M_COUNT},
		core.Mod_Hook{key = key(G_C), kind = .Before, mod = 1, fn = M_COUNT},
		core.Mod_Hook{key = key(G_X), kind = .Before, mod = 0, fn = M_ORIGINAL},
		core.Mod_Hook{key = key(G_Y), kind = .Replace, mod = 1, fn = M_REPLACE_Y},
	)
	if bad != nil {bad(&hooks[0].key)}
	order := make([]int, 2)
	order[0], order[1] = 0, 1
	return {mods = mods, order = order, images = images, hooks = hooks[:]}
}

c_calls: int

fn_c :: proc() {
	c_calls += 1
	cpu.state.r[V0].d[0] = cpu.state.r[A0].d[0] + 100
}

test_refusals :: proc() {
	Bad :: struct {
		bad:  proc(k: ^core.Mod_Key),
		said: string,
	}
	bads := []Bad {
		{proc(k: ^core.Mod_Key) {k.slot = 1}, "EE hooks name the boot program, slot 0"},
		{proc(k: ^core.Mod_Key) {k.id += 1}, "(EE hooks name only it)"},
		{proc(k: ^core.Mod_Key) {k.addr += 2}, "which is not a function in RAM"},
		{proc(k: ^core.Mod_Key) {k.sig[3] += 1}, "is not the code it was built for"},
	}
	for b in bads {
		err := ps2.mods_load(make_set(b.bad))
		check(strings.contains(err, b.said), fmt.tprintf("refused %q, want %q", err, b.said))
		check(!cpu.mod_on && mem.mod_ram == nil, fmt.tprintf("installed after %q", err))
	}
	core.run_mods = 1
	_, h, _ := ps2.mods_read("", "")
	check(h == 0 && ps2.mods_check(0) == "", "no mods: no check")
	check(core.run_mods == 0, "no mods: no run set")
	// The run's set is noted before the input record opens (ps2.boot).
	boot := #load("../../ps2/boot.odin", string)
	at, opened := strings.index(boot, "mods_read(b.mods"), strings.index(boot, "host.platform_init(")
	check(at >= 0 && opened > at, "ps2.boot reads the mods before host.platform_init")
	check(strings.contains(ps2.mods_check(1), "the recomp option mod_hooks"), "hash mismatch refused")
}

WANT_LOG :: [?]u32 {
	1, 0x0e, 2, 5, 6, 6, // G_A(5)
	1012, // G_R(1)
	3, 1012, // G_L(3): one count; v0 is still G_R's
	1, 0x0e, 2, 7, 8, 8, // G_T(5): G_A(7)
	1, 0x0e, 2, 5, 6, 6, // G_J(5)
	3, 105, // G_C(5)
	0x1234, // s0
}

log_words :: proc() -> []u32 {
	n := mem.rd32(DATA)
	w := make([]u32, n, context.temp_allocator)
	for &v, i in w {v = mem.rd32(DATA + 4 + 4 * u32(i))}
	return w
}

host_call :: proc(t: u32, arg: u64) -> u64 {
	cpu.state.r[A0].d[0] = arg
	cpu.call(t)
	return cpu.state.r[V0].d[0]
}

// The log of a run with no chain.
NO_CHAIN_LOG :: [?]u32{6, 11, 11, 8, 6, 105, 0x1234}

// The run vblank waits for: 0 the boot, then each start again (the file.s
// comment), and the frame it started at.
pass: int
pass_frame: u64

// The disc directory of the LoadExecPS2 runs: the boot ELF file and another.
disc: string

// The id of the other ELF file (OTHER.ELF).
other_prog: u32

// Start the program again by syscall sys with a0, a fresh log, when this
// vblank returns.
start_again :: proc(sys, a0: u32) {
	mem.wr32(DATA, 0)
	mem.wr32(DONE, 0)
	mem.wr32(NEXT_A0, a0)
	mem.wr32(NEXT, sys)
	pass += 1
	pass_frame = kernel.k.frame
}

load_exec :: proc(name: string) {
	for c, i in transmute([]u8)name {mem.wr8(NAME + u32(i), c)}
	mem.wr8(NAME + u32(len(name)), 0)
	start_again(6, NAME)
}

vblank :: proc() {
	if mem.rd32(DONE) == 0 {
		if kernel.k.frame > pass_frame + 60 {
			fmt.eprintln("FAIL ps2_mod: run", pass, "not done after 60 frames", log_words())
			os.exit(1)
		}
		return
	}
	chains := pass % 2 == 0
	with, without := WANT_LOG, NO_CHAIN_LOG
	want := chains ? with[:] : without[:]
	got := log_words()
	same := len(got) == len(want)
	for v, i in got {if i < len(want) && v != want[i] {same = false}}
	check(same, fmt.tprintf("run %d: log %v, want %v", pass, got, want))
	when !core.FLAT {
		calls := [5]int{1, 1, 2, 3, 4} // run 1 interprets G_C
		check(c_calls == calls[pass], fmt.tprintf("run %d: G_C's procedure ran %d times", pass, c_calls))
	}
	progs := [5]u32{kernel.k.exec.boot_prog, 0, kernel.k.exec.boot_prog, other_prog, kernel.k.exec.boot_prog}
	check(kernel.k.exec.prog == progs[pass], fmt.tprintf("run %d: program %08x, want %08x", pass, kernel.k.exec.prog, progs[pass]))
	switch pass {
	case 1:
		mem.wr32(TEXT_WORD, 0)
		start_again(7, ENTRY)
		return
	case 2:
		load_exec("OTHER.ELF")
		return
	case 3:
		load_exec("BOOT.ELF")
		return
	case 4:
		finish()
	}

	// From host code.
	n := len(log_words())
	check(host_call(G_A, 9) == 10 && len(log_words()) == n + 5 && log_words()[n + 3] == 9, "host call runs the chain")
	n = len(log_words())
	kernel.k.exec.prog += 1
	check(host_call(G_A, 9) == 10 && len(log_words()) == n, "another program: no chain")
	kernel.k.exec.prog -= 1
	w := mem.rd32(G_A + 12)
	mem.wr32(G_A + 12, addiu(ZERO, ZERO, 0))
	check(host_call(G_A, 9) == 10 && len(log_words()) == n, "other code: no chain")
	mem.wr32(G_A + 12, w)
	check(host_call(G_A, 9) == 10 && len(log_words()) == n + 5, "the code back: the chain")

	// wasm32 has no disc directory: the program is not started again.
	when ODIN_ARCH == .wasm32 {
		finish()
	} else {
		mem.wr32(TEXT_WORD, 1)
		start_again(7, ENTRY)
	}
}

// The end of the test: the fatal cases (a child process each; wasm32 starts
// no processes), the disc directory removed, the verdict.
finish :: proc() -> ! {
	when ODIN_ARCH != .wasm32 {
		children()
		os.remove_all(disc)
	}
	if failed > 0 {os.exit(1)}
	fmt.println("ps2_mod: ok")
	os.exit(0)
}

Child :: struct {
	name: string,
	call: u32,
}

CHILDREN :: [?]Child{{"none", mem.MOD_ORIGINAL}, {"before", G_X}, {"inside", G_Y}}

children :: proc() {
	self, _ := os.get_executable_path(context.temp_allocator)
	for c in CHILDREN {
		state, _, errs, perr := os.process_exec({command = {self, c.name}}, context.temp_allocator)
		check(perr == nil && state.exit_code == 1, fmt.tprintf("child %s: %v exit %d", c.name, perr, state.exit_code))
		check(strings.contains(string(errs), "outside a replacement"), fmt.tprintf("child %s said %q", c.name, string(errs)))
	}
}

// The disc directory of the LoadExecPS2 runs, a temporary one: the boot ELF
// file and another with the same code.
disc_files :: proc() {
	err: os.Error
	if disc, err = os.make_directory_temp("", "ps_ps2_mod_test_*", context.allocator); err != nil {
		fmt.eprintln("FAIL ps2_mod: temp dir:", err)
		os.exit(1)
	}
	other := make_elf(mem.ram[ENTRY:][:0x1000], 4)
	other_prog = u32(xxhash.XXH3_64_default(other))
	files := [2]string{"BOOT.ELF", "OTHER.ELF"}
	for f, i in ([2][]u8{boot_elf, other}) {
		if err = os.write_entire_file(fmt.tprintf("%s/%s", disc, files[i]), f); err != nil {
			fmt.eprintln("FAIL ps2_mod: write", files[i], err)
			os.exit(1)
		}
	}
	iop.disc_dir = disc
}

main :: proc() {
	ps2.init()
	// wasm32 runs some of the program native, which sets the range.
	when ODIN_ARCH != .wasm32 {cpu.text_range(ENTRY, ENTRY + 0x1000)}
	when !core.FLAT {cpu.register(G_C, fn_c)}
	kernel.vblank_hook = vblank
	program()
	boot_elf = make_elf(mem.ram[ENTRY:][:0x1000], 0)
	kernel.exec_boot_program(boot_elf)
	when ODIN_ARCH == .wasm32 {native_program()}
	child := len(os.args) == 2
	if child {
		for c in CHILDREN {if c.name == os.args[1] {mem.wr32(CHILD, c.call)}}
	} else {
		test_refusals()
		when ODIN_ARCH != .wasm32 {disc_files()}
	}
	if err := ps2.mods_load(make_set()); err != "" {
		fmt.eprintln("FAIL ps2_mod:", err)
		os.exit(1)
	}
	check(ps2.mods_load(make_set()) != "", "loaded twice")
	if child {kernel.vblank_hook = proc() {if kernel.k.frame > 60 {os.exit(3)}}}
	ps2.run(ENTRY)
}
