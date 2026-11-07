// A `jr $ra` that is a longjmp: guest code that sets $ra to an outer
// call's return address and sp to that call's sp, as a throw restoring a
// catch frame does, returns there, the calls in between dropped. Both
// models must run it alike: the coroutine model (a default build), whose
// interpreted runs are host frames (ps2 interp_call), and FLAT
// (-define:PS_FLAT=true), whose runs keep the calls as data (interp_flat).
//
// R recurses a0 deep and then calls C; each R counts its return in s2. C
// either returns, or jumps with $ra and sp loaded from DATA. Each case
// stores s2 as main sees it after its call to R: 0 when the jump unwound to
// main, the depth when every R returned. The cases: a plain return; a jump
// to main's call 2 calls below C's caller; to an address no call returns to,
// a jump there (NOWHERE, which goes back to main by a plain jump, the calls
// it left open); to a coroutine's entry no call returns to (CO), whose
// later `jr $ra` to main's call with its sp unwinds there; with another sp
// than main's call; with main's call the last that the search reaches
// (cpu.UNWIND_MAX) and one past it; from a SetSyscall handler, whose call
// by the kernel is host code the jump must not cross; and a bgezal, jal and
// jalr each to its own return address (pc + 8, a get-pc idiom), which only
// set $ra and go on there, no call.
//
// With the argument away, it calls a function that jumps back to the call
// instead of returning, over and over: each call is left open until the
// search no longer reaches the outermost (cpu.UNWIND_MAX), and from there
// each `jr $ra` returns as before, so no more than UNWIND_MAX + 1 are ever
// open. With the argument cap, a function calls itself without end: the
// chain's cap (cpu.INTERP_DEPTH_MAX, kernel.FLAT_DEPTH_MAX under FLAT) is a
// fatal, not a host stack overflow.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"

ENTRY :: u32(0x00100000) // thread 1: the cases
FN_R :: u32(0x00100400)
FN_C :: u32(0x00100600)
FN_W :: u32(0x00100700) // makes the syscall
HANDLER :: u32(0x00100780) // the installed syscall's: calls R
NOWHERE :: u32(0x00100800) // a jump target no call returns to
CO :: u32(0x00100880) // a coroutine's entry no call returns to
FN_G :: u32(0x00100900) // the links to pc + 8
DATA :: u32(0x00180000)
MODE :: DATA + 0x0 // 0: C returns; else it jumps
TGT :: DATA + 0x4 // the $ra C jumps with
SP0 :: DATA + 0x8 // main's sp at its call
DELTA :: DATA + 0xc // added to it for the jump's sp
RES :: DATA + 0x10 // each case's s2
RET :: DATA + 0xc0 // main's return address from its call
DONE :: DATA + 0x100
FRAMES :: DATA + 0x1000 // R's saved $ra, growing down (s1)
SYSCALL_N :: 0xa0

ZERO :: 0
V1 :: 3
A0 :: 4
A1 :: 5
T0 :: 8
T1 :: 9
T2 :: 10
T3 :: 11
T7 :: 15
S0 :: 16
S1 :: 17
S2 :: 18
SP :: 29
RA :: 31

Target :: enum {
	Main, // main's return address
	Nowhere, // NOWHERE: s2 = 50, then a plain jump back to main
	Co, // CO: s2 += 1000, then `jr $ra` to main's call with its sp
}

Case :: struct {
	mode, delta: u32,
	to:          Target,
	depth:       u32,
	syscall:     bool, // main calls W, whose syscall's handler calls R
	getpc:       bool, // no call: the links to pc + 8, each s2 += 11
	want:        u32,
}

CASES :: [?]Case {
	{mode = 0, depth = 2, want = 2}, // returns: unchanged
	{mode = 1, depth = 2, want = 0}, // unwound to main, 2 calls below C's caller
	{mode = 1, depth = 2, to = .Nowhere, want = 50}, // no call returns there: a jump
	{mode = 1, depth = 2, to = .Co, want = 1000}, // a jump, then unwound to main
	{mode = 1, depth = 2, delta = 16, want = 2}, // another sp
	{mode = 1, depth = cpu.UNWIND_MAX - 1, want = 0}, // main's call the UNWIND_MAX-th
	{mode = 1, depth = cpu.UNWIND_MAX, want = cpu.UNWIND_MAX}, // one past
	{mode = 1, depth = 2, syscall = true, want = 102}, // past host code: W counts 100
	{getpc = true, want = 33}, // bgezal, jal, jalr to pc + 8
}

i_type :: proc(op, rs, rt: u32, imm: i32) -> u32 {return op << 26 | rs << 21 | rt << 16 | (u32(imm) & 0xffff)}
r_type :: proc(rs, rt, rd, fn: u32) -> u32 {return rs << 21 | rt << 16 | rd << 11 | fn}
j_type :: proc(op, target: u32) -> u32 {return op << 26 | (target >> 2) & 0x3ffffff}
addiu :: proc(rt, rs: u32, imm: i32) -> u32 {return i_type(9, rs, rt, imm)}
addu :: proc(rd, rs, rt: u32) -> u32 {return r_type(rs, rt, rd, 0x21)}
lui :: proc(rt, imm: u32) -> u32 {return i_type(15, 0, rt, i32(imm))}
ori :: proc(rt, rs, imm: u32) -> u32 {return i_type(13, rs, rt, i32(imm))}
lw :: proc(rt, off, base: u32) -> u32 {return i_type(0x23, base, rt, i32(off))}
sw :: proc(rt, off, base: u32) -> u32 {return i_type(0x2b, base, rt, i32(off))}
subu :: proc(rd, rs, rt: u32) -> u32 {return r_type(rs, rt, rd, 0x23)}
jal :: proc(t: u32) -> u32 {return j_type(3, t)}
jr :: proc(rs: u32) -> u32 {return r_type(rs, 0, 0, 8)}
jalr :: proc(rs: u32) -> u32 {return r_type(rs, 0, RA, 9)}
bgezal_zero_8 :: 0x04110001 // bgezal zero to pc + 8
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

// Always two words, so an address can be patched in later.
li :: proc(a: ^Asm, r, v: u32) {
	put(a, lui(r, v >> 16), ori(r, r, v & 0xffff))
}

// beq rs, rt to `to`, from the branch at a.pc.
beq :: proc(a: ^Asm, rs, rt, to: u32) {
	put(a, i_type(4, rs, rt, i32(to - (a.pc + 4)) / 4))
}

// Push $ra on s1's stack; pop it.
push_ra :: proc(a: ^Asm) {put(a, addiu(S1, S1, -4), sw(RA, 0, S1))}
pop_ra :: proc(a: ^Asm) {put(a, lw(RA, 0, S1), addiu(S1, S1, 4))}

program :: proc() {
	cases := CASES
	a := Asm{ENTRY}
	put(&a, addu(S0, SP, ZERO))
	li(&a, S1, FRAMES)
	li(&a, A0, SYSCALL_N)
	li(&a, A1, HANDLER)
	put(&a, addiu(V1, ZERO, 0x74), SYSCALL) // SetSyscall
	for c, k in cases {
		if c.getpc {
			put(&a, addiu(S2, ZERO, 0), jal(FN_G), NOP)
			li(&a, T7, DATA)
			put(&a, sw(S2, RES - DATA + 4 * u32(k), T7))
			put(&a, addu(SP, S0, ZERO))
			continue
		}
		li(&a, T7, DATA)
		li(&a, T0, c.mode)
		put(&a, sw(T0, MODE - DATA, T7))
		li(&a, T0, c.delta)
		put(&a, sw(T0, DELTA - DATA, T7))
		put(&a, sw(SP, SP0 - DATA, T7))
		tgt := a.pc
		li(&a, T0, 0) // patched below
		put(&a, sw(T0, TGT - DATA, T7))
		li(&a, T0, 0) // patched below
		put(&a, sw(T0, RET - DATA, T7))
		put(&a, addiu(S2, ZERO, 0))
		li(&a, A0, c.depth)
		put(&a, jal(c.syscall ? FN_W : FN_R), NOP)
		ret := a.pc
		patch := Asm{tgt}
		li(&patch, T0, c.to == .Nowhere ? NOWHERE : c.to == .Co ? CO : ret)
		patch.pc += 4
		li(&patch, T0, ret)
		li(&a, T7, DATA)
		put(&a, sw(S2, RES - DATA + 4 * u32(k), T7))
		put(&a, addu(SP, S0, ZERO))
	}
	li(&a, T7, DATA)
	put(&a, addiu(T0, ZERO, 1), sw(T0, DONE - DATA, T7))
	put(&a, i_type(4, ZERO, ZERO, -1), NOP) // hang
	assert(a.pc <= FN_R)

	// R(a0): a0 - 1 more calls to R, the last calling C; s2 += 1 after.
	a = {FN_R}
	push_ra(&a)
	put(&a, addiu(A0, A0, -1))
	leaf := a.pc + 6 * 4
	beq(&a, A0, ZERO, leaf)
	put(&a, NOP, jal(FN_R), NOP)
	after := leaf + 2 * 4
	beq(&a, ZERO, ZERO, after)
	put(&a, NOP)
	assert(a.pc == leaf)
	put(&a, jal(FN_C), NOP)
	assert(a.pc == after)
	put(&a, addiu(S2, S2, 1))
	pop_ra(&a)
	put(&a, JR_RA, NOP)

	// C: return, or jump with $ra = TGT and sp = SP0 + DELTA.
	a = {FN_C}
	li(&a, T7, DATA)
	put(&a, lw(T0, MODE - DATA, T7))
	plain := a.pc + 6 * 4
	beq(&a, T0, ZERO, plain)
	put(&a, NOP)
	put(&a, lw(RA, TGT - DATA, T7), lw(T1, SP0 - DATA, T7), lw(T2, DELTA - DATA, T7), addu(SP, T1, T2))
	assert(a.pc == plain)
	put(&a, JR_RA, NOP)

	// W: the syscall, then s2 += 100.
	a = {FN_W}
	push_ra(&a)
	put(&a, addiu(V1, ZERO, SYSCALL_N), SYSCALL)
	put(&a, addiu(S2, S2, 100))
	pop_ra(&a)
	put(&a, JR_RA, NOP)

	// The handler: R(2).
	a = {HANDLER}
	push_ra(&a)
	put(&a, addiu(A0, ZERO, 2), jal(FN_R), NOP)
	pop_ra(&a)
	put(&a, JR_RA, NOP)

	// G: the links to pc + 8, each s2 += 1 in its slot, += 10 after it,
	// += $ra less pc + 8 (0 when it was set). It returns with sp 16 below
	// its call's: were a link a call, its record's would be the innermost
	// return address, not G's, and with G's sp another, the return would
	// go back to after that link (the search's another-sp case), which
	// would count again.
	a = {FN_G}
	put(&a, addiu(SP, SP, -16))
	push_ra(&a)
	for n in 0 ..< 3 {
		if n == 2 {li(&a, T0, a.pc + 8 + 8)} // jalr's: past the li
		link := a.pc
		put(&a, n == 0 ? bgezal_zero_8 : n == 1 ? jal(a.pc + 8) : jalr(T0), addiu(S2, S2, 1))
		assert(a.pc == link + 8)
		put(&a, addiu(S2, S2, 10))
		li(&a, T1, link + 8)
		put(&a, subu(T2, RA, T1), addu(S2, S2, T2))
	}
	pop_ra(&a)
	put(&a, JR_RA, NOP)

	// NOWHERE: s2 = 50, then back to main by a plain jump.
	a = {NOWHERE}
	li(&a, T7, DATA)
	put(&a, addiu(S2, ZERO, 50), lw(T3, RET - DATA, T7), jr(T3), NOP)

	// CO: s2 += 1000, then `jr $ra` to main's call with its sp.
	a = {CO}
	li(&a, T7, DATA)
	put(&a, addiu(S2, S2, 1000), lw(RA, RET - DATA, T7), lw(SP, SP0 - DATA, T7), JR_RA, NOP)
}

// away: L calls F, which jumps back to L by `jr $ra`; no call returns to
// L (each returns to L + 8), so each is left open.
FN_F :: ENTRY + 0x40
program_away :: proc() {
	a := Asm{ENTRY}
	put(&a, jal(FN_F), NOP)
	a = {FN_F}
	li(&a, RA, ENTRY)
	put(&a, JR_RA, NOP)
}

// The most calls open at once, either model.
open_max :: proc() -> u32 {
	when core.FLAT {return cpu.flat_max_depth} else {return cpu.interp_max_depth}
}

vblank_away :: proc() {
	if kernel.k.frame < 2 {return}
	if got := open_max(); got != cpu.UNWIND_MAX + 1 {
		fmt.eprintfln("fail: %d calls open at most, want %d", got, cpu.UNWIND_MAX + 1)
		os.exit(1)
	}
	fmt.printfln("ee_unwind away: ok (%d calls open at most)", cpu.UNWIND_MAX + 1)
	os.exit(0)
}

// cap: L calls L.
program_cap :: proc() {
	a := Asm{ENTRY}
	put(&a, jal(ENTRY), NOP)
}

// At the cap's fatal: the chain is full, or the test fails.
cap_fatal :: proc() {
	when core.FLAT {
		depth, cap := kernel.flat_ctx().depth, u32(kernel.FLAT_DEPTH_MAX)
	} else {
		depth, cap := cpu.interp_top == nil ? 0 : cpu.interp_top.depth, u32(cpu.INTERP_DEPTH_MAX)
	}
	if depth != cap {
		fmt.eprintfln("fail: a fatal with %d calls open, want %d", depth, cap)
		os.exit(1)
	}
	fmt.printfln("ee_unwind cap: ok (%d calls open)", depth)
	os.exit(0)
}

vblank_cap :: proc() {
	if kernel.k.frame > 60 {
		fmt.eprintln("fail: no fatal after 60 frames")
		os.exit(1)
	}
}

vblank :: proc() {
	done := mem.rd32(DONE)
	if done == 0 {
		if kernel.k.frame > 60 {
			fmt.eprintln("fail: not done after 60 frames")
			os.exit(1)
		}
		return
	}
	if done != 1 {
		fmt.eprintln("fail: the jump's target ran")
		os.exit(1)
	}
	cases := CASES
	ok := true
	for c, k in cases {
		got := mem.rd32(RES + 4 * u32(k))
		fmt.printfln("case %d: s2 %d", k, got)
		if got != c.want {
			fmt.eprintfln("fail: case %d: s2 %d, want %d", k, got, c.want)
			ok = false
		}
	}
	if !ok {os.exit(1)}
	fmt.println("ee_unwind: ok")
	os.exit(0)
}

main :: proc() {
	ps2.init()
	cpu.text_range(ENTRY, ENTRY + 0x1000)
	mode := len(os.args) > 1 ? os.args[1] : ""
	if mode == "cap" {
		core.fatal_cleanup = cap_fatal
		kernel.vblank_hook = vblank_cap
		program_cap()
	} else if mode == "away" {
		kernel.vblank_hook = vblank_away
		program_away()
	} else {
		kernel.vblank_hook = vblank
		program()
	}
	ps2.run(ENTRY)
}
