// A syscall the program installed with SetSyscall runs its own handler, as
// a call from the syscall that returns to the instruction after it. The
// handler here is switched away from twice: an alarm wakes a thread of
// higher priority while it spins, and then it sleeps until a second alarm
// wakes it. All of it is guest code, interpreted. Both models must run it
// alike: the coroutine model (a default build), where the handler's host
// call parks with the thread, and FLAT (-define:PS_FLAT=true), where the
// handler runs on the thread's own flat run. The log of what ran, in order,
// and the cycle count at the end are printed so the two builds' output can
// be compared.
package main

import "core:fmt"
import "core:os"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"

ENTRY :: u32(0x00100000) // thread 1: the program
HANDLER :: u32(0x00100400) // the installed syscall's handler
THREAD_B :: u32(0x00100800) // the thread of higher priority
ALARM_B :: u32(0x00100c00) // an alarm handler that wakes it
ALARM_MAIN :: u32(0x00100e00) // one that wakes thread 1
DATA :: u32(0x00180000) // the log: a count, then the entries
B_ID :: DATA + 0x100
B_RAN :: DATA + 0x104 // set by B when the first alarm has woken it
DONE :: DATA + 0x108
PARAM :: DATA + 0x200 // B's CreateThread parameters
B_STACK :: u32(0x00190000)
SYSCALL_N :: 0xa0 // the installed syscall's number
WANT :: [?]u32{10, 1, 2, 11, 3, 4, 5}

ZERO :: 0
V0 :: 2
V1 :: 3
A0 :: 4
A1 :: 5
A2 :: 6
T0 :: 8
T5 :: 13
T6 :: 14
T7 :: 15
RA :: 31

i_type :: proc(op, rs, rt: u32, imm: i32) -> u32 {return op << 26 | rs << 21 | rt << 16 | (u32(imm) & 0xffff)}
r_type :: proc(rs, rt, rd, sa, fn: u32) -> u32 {return rs << 21 | rt << 16 | rd << 11 | sa << 6 | fn}
addiu :: proc(rt, rs: u32, imm: i32) -> u32 {return i_type(9, rs, rt, imm)}
lui :: proc(rt, imm: u32) -> u32 {return i_type(15, 0, rt, i32(imm))}
lw :: proc(rt, off, base: u32) -> u32 {return i_type(0x23, base, rt, i32(off))}
sw :: proc(rt, off, base: u32) -> u32 {return i_type(0x2b, base, rt, i32(off))}
SYSCALL :: 0x0000000c
JR_RA :: 0x03e00008
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
	if i32(v) == i32(i16(u16(v))) {
		put(a, addiu(r, ZERO, i32(v)))
	} else {
		put(a, lui(r, v >> 16), i_type(13, r, r, i32(v & 0xffff))) // ori
	}
}

sys :: proc(a: ^Asm, n: i32, args: ..u32) {
	for v, i in args {li(a, A0 + u32(i), v)}
	put(a, addiu(V1, ZERO, n), SYSCALL)
}

// Append code to the log (t5-t7 clobbered).
log :: proc(a: ^Asm, code: i32) {
	put(a,
		lui(T7, DATA >> 16),
		lw(T6, 0, T7),
		addiu(T5, T6, 1),
		sw(T5, 0, T7),
		r_type(0, T6, T6, 2, 0), // sll t6, t6, 2
		r_type(T6, T7, T6, 0, 0x21), // addu t6, t6, t7
		addiu(T5, ZERO, code),
		sw(T5, 4, T6),
	)
}

// Set the word at DATA + off to 1.
flag :: proc(a: ^Asm, off: u32) {
	put(a, lui(T7, DATA >> 16), addiu(T5, ZERO, 1), sw(T5, off, T7))
}

// beq zero, zero, to itself; nop.
hang :: proc(a: ^Asm) {
	put(a, i_type(4, ZERO, ZERO, -1), NOP)
}

program :: proc() {
	a := Asm{ENTRY}
	sys(&a, 0x29, 1, 64) // ChangeThreadPriority(1, 64)
	sys(&a, 0x74, SYSCALL_N, HANDLER) // SetSyscall
	sys(&a, 0x20, PARAM) // CreateThread
	put(&a, lui(T7, DATA >> 16), sw(V0, B_ID - DATA, T7))
	// StartThread(id, 0): B runs at once, logs and sleeps.
	put(&a, addiu(A0, V0, 0), addiu(A1, ZERO, 0), addiu(V1, ZERO, 0x22), SYSCALL)
	log(&a, 1)
	put(&a, addiu(V1, ZERO, SYSCALL_N), SYSCALL)
	log(&a, 5)
	flag(&a, DONE - DATA)
	hang(&a)

	a = {HANDLER}
	log(&a, 2)
	sys(&a, 0x18, 20, ALARM_B, 0) // SetAlarm(20 lines)
	put(&a, lui(T7, DATA >> 16))
	spin := a.pc
	put(&a, lw(T0, B_RAN - DATA, T7))
	put(&a, i_type(4, T0, ZERO, i32(spin - (a.pc + 4)) / 4), NOP) // beq t0, zero, spin
	log(&a, 3)
	sys(&a, 0x18, 20, ALARM_MAIN, 0)
	sys(&a, 0x32) // SleepThread
	log(&a, 4)
	put(&a, JR_RA, NOP)

	a = {THREAD_B}
	log(&a, 10)
	sys(&a, 0x32)
	log(&a, 11)
	flag(&a, B_RAN - DATA)
	sys(&a, 0x32)
	hang(&a)

	a = {ALARM_B}
	put(&a, lui(T7, DATA >> 16), lw(A0, B_ID - DATA, T7))
	put(&a, addiu(V1, ZERO, -0x34), SYSCALL) // iWakeupThread
	put(&a, JR_RA, NOP)

	a = {ALARM_MAIN}
	put(&a, addiu(A0, ZERO, 1), addiu(V1, ZERO, -0x34), SYSCALL, JR_RA, NOP)

	mem.wr32(PARAM + 4, THREAD_B)
	mem.wr32(PARAM + 8, B_STACK)
	mem.wr32(PARAM + 12, 0x1000)
	mem.wr32(PARAM + 20, 10)
}

vblank :: proc() {
	if mem.rd32(DONE) == 0 {
		if kernel.k.frame > 60 {
			fmt.eprintln("fail: not done after 60 frames")
			os.exit(1)
		}
		return
	}
	want := WANT
	n := mem.rd32(DATA)
	fmt.printf("log")
	ok := n == len(WANT)
	for i in 0 ..< n {
		v := mem.rd32(DATA + 4 + 4 * i)
		fmt.printf(" %d", v)
		if i < len(WANT) && v != want[i] {ok = false}
	}
	fmt.printfln("\ncycles %d frame %d", cpu.state.cycles, kernel.k.frame)
	cpu.flat_print()
	if !ok {
		fmt.eprintln("fail: log not", WANT)
		os.exit(1)
	}
	fmt.println("ee_syscall_handler: ok")
	os.exit(0)
}

main :: proc() {
	ps2.init()
	cpu.text_range(ENTRY, ENTRY + 0x1000)
	kernel.vblank_hook = vblank
	program()
	ps2.run(ENTRY)
}
