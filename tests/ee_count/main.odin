// A write to COP0 Count sets what Count reads from then on, in whichever
// thread or interrupt handler reads it: the count is the machine's, not a
// thread's. The program is guest code, interpreted, run by the kernel in
// both models (a default build, -define:PS_FLAT=true):
//
//   main writes, then reads by mfc0 and by GetCop0; B, created before the
//   write, reads it and writes near the wrap; main reads that on the switch
//   back. An alarm handler writes, and a handler nested in it (from its
//   trap) writes again and reads by iGetCop0; the first reads that, then B,
//   which it wakes. B writes and exits, and main reads that.
//
// Each read must be the value last written plus the few cycles since.
package main

import "core:fmt"
import "core:os"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"

ENTRY :: u32(0x00100000) // thread 1, the main thread
THREAD_B :: u32(0x00100800)
HANDLER :: u32(0x00100c00) // the alarm's
INNER :: u32(0x00100e00) // the one nested in it
DATA :: u32(0x00180000) // a word a Read
B_ID :: 0x100 // these three are offsets from DATA
WOKEN :: 0x104
DONE :: 0x108
PARAM :: DATA + 0x200 // B's CreateThread parameters
B_STACK :: u32(0x00190000)
FRAMES_MAX :: 60
WRAP_NOPS :: 40
DELAY_LOOPS :: 2000

MAIN_V :: u32(0x20000000)
WRAP_V :: u32(0xfffffff0)
ARMED_V :: u32(0x30000000)
OUTER_V :: u32(0x40000000)
INNER_V :: u32(0x90000000)
EXIT_V :: u32(0xc0000000)

Read :: enum u32 {
	Unwritten,
	Main,
	Get,
	Switched_To,
	Near_Wrap,
	Wrapped,
	Switched_Back,
	In_Handler,
	IGet_Nested,
	After_Nested,
	After_Handler,
	After_Exit,
}

Want :: struct {
	from:         u32, // the value last written
	least, under: u32, // cycles since the write: at least, and under
}

WANT :: [Read]Want {
	.Unwritten     = {0, 0, 1 << 20},
	.Main          = {MAIN_V, 1, 16},
	.Get           = {MAIN_V, 1, 64},
	.Switched_To   = {MAIN_V, 1, 1 << 16},
	.Near_Wrap     = {WRAP_V, 1, 16},
	.Wrapped       = {WRAP_V, WRAP_NOPS, WRAP_NOPS + 64}, // past 2^32
	.Switched_Back = {WRAP_V, WRAP_NOPS, WRAP_NOPS + 512},
	.In_Handler    = {OUTER_V, 1, 16},
	.IGet_Nested   = {INNER_V, 1, 64},
	.After_Nested  = {INNER_V, 1, 1 << 16},
	.After_Handler = {INNER_V, 1, 1 << 16},
	.After_Exit    = {EXIT_V, 1, 1 << 16},
}

ZERO :: 0
V0 :: 2
V1 :: 3
A0 :: 4
A1 :: 5
T0 :: 8
T1 :: 9
T7 :: 15
COUNT :: 9
JR_RA :: 0x03e00008
SYSCALL :: 0x0000000c
TRAP :: 0x00000034 // teq zero, zero
NOP :: 0

i_type :: proc(op, rs, rt: u32, imm: i32) -> u32 {return op << 26 | rs << 21 | rt << 16 | (u32(imm) & 0xffff)}
addiu :: proc(rt, rs: u32, imm: i32) -> u32 {return i_type(9, rs, rt, imm)}
lui :: proc(rt, imm: u32) -> u32 {return i_type(15, 0, rt, i32(imm))}
ori :: proc(rt, rs, imm: u32) -> u32 {return i_type(13, rs, rt, i32(imm))}

Asm :: struct {
	pc: u32,
}

put :: proc(a: ^Asm, words: ..u32) {
	for w in words {
		mem.wr32(a.pc, w)
		a.pc += 4
	}
}

// DATA + off = r, and r = DATA + off (t7 clobbered).
save :: proc(a: ^Asm, off, r: u32) {
	put(a, lui(T7, DATA >> 16), i_type(0x2b, T7, r, i32(off)))
}

load :: proc(a: ^Asm, r, off: u32) {
	put(a, lui(T7, DATA >> 16), i_type(0x23, T7, r, i32(off)))
}

// mtc0 v, Count (t0 clobbered).
write :: proc(a: ^Asm, v: u32) {
	put(a, lui(T0, v >> 16), ori(T0, T0, v & 0xffff), 0x40800000 | T0 << 16 | COUNT << 11)
}

// mfc0 t1, Count, saved as r.
read :: proc(a: ^Asm, r: Read) {
	put(a, 0x40000000 | T1 << 16 | COUNT << 11)
	save(a, 4 * u32(r), T1)
}

// GetCop0(Count) or iGetCop0(Count), saved as r.
read_cop0 :: proc(a: ^Asm, n: i32, r: Read) {
	put(a, addiu(A0, ZERO, COUNT), addiu(V1, ZERO, n), SYSCALL)
	save(a, 4 * u32(r), V0)
}

main_thread :: proc() {
	a := Asm{ENTRY}
	read(&a, .Unwritten)
	// Run past every slack below: the cycles alone then pass no read after a write.
	put(&a, addiu(T0, ZERO, DELAY_LOOPS))
	put(&a, addiu(T0, T0, -1), i_type(5, T0, ZERO, -2), NOP) // bne t0, zero, back
	put(&a, addiu(A0, ZERO, 1), addiu(A1, ZERO, 64), addiu(V1, ZERO, 0x29), SYSCALL) // ChangeThreadPriority
	put(&a, lui(A0, PARAM >> 16), ori(A0, A0, PARAM & 0xffff), addiu(V1, ZERO, 0x20), SYSCALL) // CreateThread
	save(&a, B_ID, V0)
	write(&a, MAIN_V)
	read(&a, .Main)
	read_cop0(&a, 0x63, .Get)
	load(&a, A0, B_ID)
	put(&a, addiu(A1, ZERO, 0), addiu(V1, ZERO, 0x22), SYSCALL) // StartThread
	read(&a, .Switched_Back)
	write(&a, ARMED_V)
	put(&a, addiu(A0, ZERO, 20), lui(A1, HANDLER >> 16), ori(A1, A1, HANDLER & 0xffff))
	put(&a, addiu(6, ZERO, 0), addiu(V1, ZERO, 0x18), SYSCALL) // SetAlarm(20 lines)
	spin := a.pc
	load(&a, T0, WOKEN)
	put(&a, i_type(4, T0, ZERO, i32(spin - (a.pc + 4)) / 4), NOP) // beq t0, zero, spin
	read(&a, .After_Exit)
	put(&a, addiu(T0, ZERO, 1))
	save(&a, DONE, T0)
	put(&a, i_type(4, ZERO, ZERO, -1), NOP) // hang
}

thread_b :: proc() {
	a := Asm{THREAD_B}
	read(&a, .Switched_To)
	write(&a, WRAP_V)
	read(&a, .Near_Wrap)
	for _ in 0 ..< WRAP_NOPS {put(&a, NOP)}
	read(&a, .Wrapped)
	put(&a, addiu(V1, ZERO, 0x32), SYSCALL) // SleepThread
	read(&a, .After_Handler)
	put(&a, addiu(T0, ZERO, 1))
	save(&a, WOKEN, T0)
	write(&a, EXIT_V)
	put(&a, addiu(V1, ZERO, 0x24), SYSCALL) // ExitDeleteThread
}

handlers :: proc() {
	a := Asm{HANDLER}
	write(&a, OUTER_V)
	read(&a, .In_Handler)
	put(&a, TRAP)
	read(&a, .After_Nested)
	load(&a, A0, B_ID)
	put(&a, addiu(V1, ZERO, -0x34), SYSCALL, JR_RA, NOP) // iWakeupThread

	a = {INNER}
	write(&a, INNER_V)
	read_cop0(&a, -0x67, .IGet_Nested)
	put(&a, JR_RA, NOP)
}

vblank :: proc() {
	if mem.rd32(DATA + DONE) == 0 {
		if kernel.k.frame > FRAMES_MAX {
			fmt.eprintln("FAIL ee_count: not done after", FRAMES_MAX, "frames")
			os.exit(1)
		}
		return
	}
	failed := 0
	for w, r in WANT {
		got := mem.rd32(DATA + 4 * u32(r))
		if d := got - w.from; d < w.least || d >= w.under {
			failed += 1
			fmt.eprintfln("FAIL ee_count %v: read %08x, want %08x plus %d to %d", r, got, w.from, w.least, w.under - 1)
		}
	}
	if failed > 0 {os.exit(1)}
	fmt.printfln("ok ee_count: %d reads", len(Read))
	os.exit(0)
}

main :: proc() {
	ps2.init()
	cpu.text_range(ENTRY, ENTRY + 0x1000)
	cpu.trap_hook = proc(pc: u32) {kernel.call_handler(INNER, 0, 0, 0, 0)}
	kernel.vblank_hook = vblank
	main_thread()
	thread_b()
	handlers()
	mem.wr32(PARAM + 4, THREAD_B)
	mem.wr32(PARAM + 8, B_STACK)
	mem.wr32(PARAM + 12, 0x1000)
	mem.wr32(PARAM + 20, 10)
	ps2.run(ENTRY)
}
