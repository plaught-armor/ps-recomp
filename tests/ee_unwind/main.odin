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
// than main's call, no call's: a jump there; with main's call the last that
// the search reaches (cpu.UNWIND_MAX) and one past it; from a SetSyscall
// handler, whose call by the kernel is host code the jump must not cross,
// and from it to NOWHERE, a return as before with that host code under it.
//
// With the argument learn (the coroutine model only; FLAT notes no runs),
// the cases run under LEARN: C's run, which jumps to NOWHERE and to CO
// (another fiber's code), ends at the jump, written .Open, so no record
// for C holds words outside C.
//
// With the argument getpc, a bgezal, jal and jalr each to its own return
// address (pc + 8, a get-pc idiom) only set $ra and go on there: no call,
// so no more than G's own call is ever open.
//
// With the argument frames, two calls return to the same address with
// other sps (Q calling itself): the innermost `jr $ra`s to that address
// with the outer one's sp. A return needs the return address and the sp
// both: it unwinds to the outer call, so the run that goes on there (and
// hangs) has one call open less than a return from the innermost leaves.
//
// With the argument away, it calls a function that jumps back to the call
// instead of returning, over and over: each call is left open until the
// search no longer reaches the outermost (cpu.UNWIND_MAX), and from there
// each `jr $ra` returns as before, so no more than UNWIND_MAX + 1 are ever
// open. With the argument cap, a function calls itself without end: the
// chain's cap (cpu.INTERP_DEPTH_MAX, kernel.FLAT_DEPTH_MAX under FLAT) is a
// fatal, not a host stack overflow.
//
// With the argument native (the coroutine model only), R is learned code
// run native (ps2 load_learned), so native frames are between C's run and
// main's: the unwinds return past them (cpu.unwinding), the jumps leave
// them open, and the search, which counts records, finds main's call past
// UNWIND_MAX native R calls. Then a handler called by the kernel
// (kernel.call_handler) that `jr $ra`s to an address no call returns to
// returns as before: host code's call is under it. With the argument
// stale, L calls native N, which calls F, which jumps back to L: each jump
// leaves N's frame open under the run, until the one that would leave more
// than cpu.NATIVE_STALE_MAX returns as before. Last (x64 SysV), R is
// registered as a thunk that puts known values in every callee-saved
// register and calls R's native code, and a handler's call of R(2) is
// unwound past both native R frames: each must give the thunk its values
// back, as the epilogue that the unwind leaves through restores them.
//
// With the argument learned (the coroutine model only), C is learned code
// run native: its own `jr $ra` (a host return in native code) must unwind
// and jump as the interpreted C's does (ps2 learned_jr), so every case
// ends as in the default run.
//
// With the argument catch (the coroutine model only), the call a throw
// returns to is one learned code made, which leaves no record but the
// callee's own run (cpu.Learned_Run). K calls M, M calls N, N calls T, and
// T `jr $ra`s to K's call of M with K's sp there (plus DELTA): M's and N's
// counts are skipped, K goes on. Each case has its own copy of the four,
// some of them learned code run native, and must end as the copy with none
// learned does, with as many unwinds and jumps: an interpreted T and a
// learned one to a learned K and M; the same through a native N; to an
// interpreted K past learned M, N and T, and past a learned N and T alone;
// and with another sp than K's (DELTA 16), which no call has: a jump, then
// K's own return unwinds to the call of K. Last, a learned X that jumps
// out of its words to Y with another sp: Y's return is one to X's own
// call, which X's jump out must end.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"
import "ps:recomp/native"
import "ps:recomp/r5900"

ENTRY :: u32(0x00100000) // thread 1: the cases
FN_R :: u32(0x00100400)
FN_C :: u32(0x00100600)
FN_W :: u32(0x00100700) // makes the syscall
HANDLER :: u32(0x00100780) // the installed syscall's: calls R
NOWHERE :: u32(0x00100800) // a jump target no call returns to
CO :: u32(0x00100880) // a coroutine's entry no call returns to
FN_G :: u32(0x00100900) // the links to pc + 8
FN_Q :: u32(0x00100a00) // frames: calls itself
DATA :: u32(0x00180000)
MODE :: DATA + 0x0 // 0: C returns; else it jumps
TGT :: DATA + 0x4 // the $ra C jumps with
SP0 :: DATA + 0x8 // main's sp at its call
DELTA :: DATA + 0xc // added to it for the jump's sp
RES :: DATA + 0x10 // each case's s2
RET :: DATA + 0xc0 // main's return address from its call
DONE :: DATA + 0x100
FRAMES :: DATA + 0x1000 // R's saved $ra, growing down (s1)
STACK :: DATA + 0x2000 // frames: main's sp
FN_HJ :: u32(0x00100b00) // native: the handler that jumps
NOWHERE2 :: u32(0x00100b40) // its target: MARK = 1, then a return
FN_HC :: u32(0x00100c00) // native: the handler whose R(2) is unwound
MARK :: DATA + 0x104
HC_RES :: DATA + 0x108 // its s2 after its call
SYSCALL_N :: 0xa0
// getpc: main's call of G the only one open (were the links calls, 4).
GETPC_OPEN :: 1
// frames: at the hang, main's call of the outer Q and its call of the
// middle one, the innermost's call unwound (a return from the innermost
// would leave the middle one's run, 3).
FRAMES_OPEN :: 2

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
	want:        u32,
}

CASES :: [?]Case {
	{mode = 0, depth = 2, want = 2}, // returns: unchanged
	{mode = 1, depth = 2, want = 0}, // unwound to main, 2 calls below C's caller
	{mode = 1, depth = 2, to = .Nowhere, want = 50}, // no call returns there: a jump
	{mode = 1, depth = 2, to = .Co, want = 1000}, // a jump, then unwound to main
	{mode = 1, depth = 2, delta = 16, want = 0}, // another sp: a jump to main's
	{mode = 1, depth = cpu.UNWIND_MAX - 1, want = 0}, // main's call the UNWIND_MAX-th
	{mode = 1, depth = cpu.UNWIND_MAX, want = cpu.UNWIND_MAX}, // one past
	{mode = 1, depth = 2, syscall = true, want = 102}, // past host code: W counts 100
	{mode = 1, depth = 2, syscall = true, to = .Nowhere, want = 102}, // host code under: no jump
}

// native: CASES with R native. Its calls make no records, so the search
// reaches main's call past UNWIND_MAX of them too.
NATIVE_WANT :: [len(CASES)]u32{2, 0, 50, 1000, 0, 0, 0, 102, 102}

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

// getpc: main calls G and stores s2. G: the links to pc + 8, each s2 += 1
// in its slot, += 10 after it, += $ra less pc + 8 (0 when it was set): 33.
// Were a link a call, each would be a run of its own, open under G's.
program_getpc :: proc() {
	a := Asm{ENTRY}
	li(&a, S1, FRAMES)
	put(&a, addiu(S2, ZERO, 0), jal(FN_G), NOP)
	li(&a, T7, DATA)
	put(&a, sw(S2, RES - DATA, T7))
	put(&a, addiu(T0, ZERO, 1), sw(T0, DONE - DATA, T7))
	put(&a, i_type(4, ZERO, ZERO, -1), NOP) // hang
	a = {FN_G}
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
}

vblank_getpc :: proc() {
	if mem.rd32(DONE) == 0 {
		if kernel.k.frame > 60 {
			fmt.eprintln("fail: not done after 60 frames")
			os.exit(1)
		}
		return
	}
	got, open := mem.rd32(RES), open_max()
	if got != 33 || open != GETPC_OPEN {
		fmt.eprintfln("fail: s2 %d, want 33; %d calls open at most, want %d", got, open, GETPC_OPEN)
		os.exit(1)
	}
	fmt.printfln("ee_unwind getpc: ok (s2 33, %d calls open at most)", open)
	os.exit(0)
}

// The calls open now, either model.
open_now :: proc() -> u32 {
	when core.FLAT {return kernel.flat_ctx().depth} else {return cpu.interp_top == nil ? 0 : cpu.interp_top.depth}
}

// frames: main calls Q(4). Q: sp -= 16 and its $ra saved there; a0 -= 1;
// with a0 left, Q again, and after it (XQ) DONE += 1 and a hang. The
// innermost Q instead sets sp to its caller's caller's (32 above its own:
// the sp at the call of its caller, which returns to XQ too) and `jr $ra`,
// to XQ: with the sp of that call, not its own (16 above), so that call's
// caller's run goes on at XQ. A registered host probe would not do: FLAT
// interprets every call.
program_frames :: proc() {
	a := Asm{ENTRY}
	li(&a, SP, STACK)
	li(&a, A0, 4)
	put(&a, jal(FN_Q), NOP)
	put(&a, i_type(4, ZERO, ZERO, -1), NOP) // hang: not reached
	a = {FN_Q}
	put(&a, addiu(SP, SP, -16), sw(RA, 0, SP), addiu(A0, A0, -1))
	leaf := a.pc + 12 * 4
	beq(&a, A0, ZERO, leaf)
	put(&a, NOP, jal(FN_Q), NOP)
	li(&a, T7, DATA) // XQ
	put(&a, lw(T0, DONE - DATA, T7), addiu(T0, T0, 1), sw(T0, DONE - DATA, T7))
	put(&a, i_type(4, ZERO, ZERO, -1), NOP) // hang
	assert(a.pc <= leaf)
	for a.pc < leaf {put(&a, NOP)}
	put(&a, addiu(SP, SP, 32), JR_RA, NOP)
}

vblank_frames :: proc() {
	if mem.rd32(DONE) == 0 {
		if kernel.k.frame > 60 {
			fmt.eprintln("fail: not done after 60 frames")
			os.exit(1)
		}
		return
	}
	done, open := mem.rd32(DONE), open_now()
	if done != 1 || open != FRAMES_OPEN {
		fmt.eprintfln("fail: XQ ran %d times, want 1; %d calls open at its hang, want %d", done, open, FRAMES_OPEN)
		os.exit(1)
	}
	fmt.printfln("ee_unwind frames: ok (%d calls open at the hang)", open)
	os.exit(0)
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

// learn: C's records, each within C, one of them .Open.
learn_dir, learn_path: string
vblank_learn :: proc() {
	if mem.rd32(DONE) == 0 {
		vblank()
		return
	}
	core.learn_report()
	data, err := os.read_entire_file(learn_path, context.allocator)
	os.remove_all(learn_dir)
	if err != nil {
		fmt.eprintln("fail: no LEARN file:", err)
		os.exit(1)
	}
	recs, bad := core.learn_read(data)
	n, open := 0, 0
	for r in recs {
		if r.entry != FN_C {continue}
		n += 1
		if .Open in r.flags {open += 1}
		if r.lo < FN_C || r.lo + 4 * u32(len(r.words)) > FN_W {
			fmt.eprintfln("fail: a record for C holds %08x..%08x, outside C", r.lo, r.lo + 4 * u32(len(r.words)))
			os.exit(1)
		}
	}
	if bad != 0 || n == 0 || open == 0 {
		fmt.eprintfln("fail: %d bad records, %d for C, %d of them .Open", bad, n, open)
		os.exit(1)
	}
	vblank()
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
	cases, native_want := CASES, NATIVE_WANT
	ok := true
	for c, k in cases {
		got, want := mem.rd32(RES + 4 * u32(k)), native_on ? native_want[k] : c.want
		fmt.printfln("case %d: s2 %d", k, got)
		if got != want {
			fmt.eprintfln("fail: case %d: s2 %d, want %d", k, got, want)
			ok = false
		}
	}
	if !ok {os.exit(1)}
	if native_on {
		if cpu.learned_calls < cpu.UNWIND_MAX {
			fmt.eprintfln("fail: %d native calls of R", cpu.learned_calls)
			os.exit(1)
		}
		kernel.call_handler(FN_HJ, 0, 0, 0, 0)
		if mem.rd32(MARK) != 0 {
			fmt.eprintln("fail: a handler's jump past the kernel's call ran")
			os.exit(1)
		}
		saved_ok()
		if cpu.interp_unwinds_native == 0 || cpu.interp_jumps_native == 0 || cpu.interp_barriers == 0 || cpu.interp_stale != 0 {
			fmt.eprintfln("fail: %d unwinds and %d jumps across native code, %d barriers, %d stale refusals", cpu.interp_unwinds_native, cpu.interp_jumps_native, cpu.interp_barriers, cpu.interp_stale)
			os.exit(1)
		}
		fmt.printfln("ee_unwind native: ok (%d native calls)", cpu.learned_calls)
		os.exit(0)
	}
	if learned_c_on {
		if cpu.learned_calls == 0 || cpu.interp_unwinds == 0 || cpu.interp_jumps == 0 {
			fmt.eprintfln("fail: %d native calls of C, %d unwinds, %d jumps", cpu.learned_calls, cpu.interp_unwinds, cpu.interp_jumps)
			os.exit(1)
		}
		fmt.printfln("ee_unwind learned: ok (%d native calls)", cpu.learned_calls)
		os.exit(0)
	}
	fmt.println("ee_unwind: ok")
	os.exit(0)
}

// Whether R runs native (the argument native), or C (learned).
native_on, learned_c_on: bool

// Compile the words lo..hi, entered at lo, to native code and load them
// (ps2 learned.odin): run in place of the interpreter while RAM holds them.
load_native :: proc(lo, hi: u32) {
	words := make([]u32, (hi - lo) / 4)
	for &w, k in words {w = mem.rd32(lo + 4 * u32(k))}
	blob, skipped := r5900.learned_blob({{lo, lo, words}}, native.Arch(core.NATIVE_ARCH))
	dir, err := os.make_directory_temp("", "ps_ee_unwind_*", context.allocator)
	if skipped != 0 || err != nil {
		fmt.eprintln("fail: no native code:", skipped, err)
		os.exit(1)
	}
	path, _ := filepath.join({dir, "native.bin"}, context.allocator)
	loaded := os.write_entire_file(path, blob) == nil && ps2.load_learned(path)
	os.remove_all(dir)
	if !loaded {
		fmt.eprintln("fail: native code not loaded")
		os.exit(1)
	}
}

// native: HJ `jr $ra`s to NOWHERE2, which no call returns to; were it a
// jump there, NOWHERE2 sets MARK, and its own `jr $ra` returns.
program_handler :: proc() {
	a := Asm{FN_HJ}
	li(&a, RA, NOWHERE2)
	put(&a, JR_RA, NOP)
	a = {NOWHERE2}
	li(&a, T7, DATA)
	put(&a, addiu(T0, ZERO, 1), sw(T0, MARK - DATA, T7), addu(RA, ZERO, ZERO), JR_RA, NOP)

	// HC: R(2), whose C jumps back to HC's call with its sp (CASES' second
	// case), then s2 to HC_RES and a return.
	a = {FN_HC}
	li(&a, S1, FRAMES)
	push_ra(&a)
	li(&a, T7, DATA)
	put(&a, addiu(T0, ZERO, 1), sw(T0, MODE - DATA, T7), sw(ZERO, DELTA - DATA, T7), sw(SP, SP0 - DATA, T7))
	tgt := a.pc
	li(&a, T0, 0) // patched below
	put(&a, sw(T0, TGT - DATA, T7), addiu(S2, ZERO, 0), addiu(A0, ZERO, 2), jal(FN_R), NOP)
	patch := Asm{tgt}
	li(&patch, T0, a.pc)
	li(&a, T7, DATA)
	put(&a, sw(S2, HC_RES - DATA, T7))
	pop_ra(&a)
	put(&a, JR_RA, NOP)
	assert(a.pc <= ENTRY + 0x1000)
}

// The values the thunk puts in rbx, rbp and r12-r15 (bit 31 clear: each is
// checked by an xor with a sign-extended imm32).
SAVED_MAGIC :: [6]u32{0x11111111, 0x22222222, 0x33333333, 0x44444444, 0x55555555, 0x66666666}

// Each register's xor with its magic after a call, or'd (saved_thunk).
saved_bad: u64

// x64 SysV, as a Func_Proc (rdi, the context, passed on): push rbx, rbp,
// r12-r15, set each to its SAVED_MAGIC, call fn, then or each register xor
// its magic into saved_bad (0 when all came back), the registers restored.
saved_thunk :: proc(fn: cpu.Func_Proc) -> []u8 {
	m := SAVED_MAGIC
	b: [dynamic]u8
	imm :: proc(b: ^[dynamic]u8, v: u64, n: int) {for k in 0 ..< n {append(b, u8(v >> (8 * uint(k))))}}
	append(&b, 0x53, 0x55, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56, 0x41, 0x57) // push rbx rbp r12-r15
	append(&b, 0x48, 0x83, 0xec, 0x08) // sub rsp, 8: aligned for the call
	append(&b, 0xbb);imm(&b, u64(m[0]), 4) // mov ebx, m0
	append(&b, 0xbd);imm(&b, u64(m[1]), 4) // mov ebp, m1
	for k in 0 ..< 4 {
		append(&b, 0x41, 0xbc + u8(k));imm(&b, u64(m[2 + k]), 4) // mov r12d+k, m
	}
	append(&b, 0x48, 0xb8);imm(&b, u64(uintptr(rawptr(fn))), 8) // mov rax, fn
	append(&b, 0xff, 0xd0) // call rax
	append(&b, 0x48, 0x89, 0xd8, 0x48, 0x35);imm(&b, u64(m[0]), 4) // mov rax, rbx; xor rax, m0
	append(&b, 0x48, 0x89, 0xe9, 0x48, 0x81, 0xf1);imm(&b, u64(m[1]), 4) // mov rcx, rbp; xor rcx, m1
	append(&b, 0x48, 0x09, 0xc8) // or rax, rcx
	for k in 0 ..< 4 {
		append(&b, 0x4c, 0x89, 0xe1 + 8 * u8(k), 0x48, 0x81, 0xf1);imm(&b, u64(m[2 + k]), 4) // mov rcx, r12+k; xor rcx, m
		append(&b, 0x48, 0x09, 0xc8) // or rax, rcx
	}
	append(&b, 0x48, 0xb9);imm(&b, u64(uintptr(&saved_bad)), 8) // mov rcx, &saved_bad
	append(&b, 0x48, 0x09, 0x01) // or [rcx], rax
	append(&b, 0x48, 0x83, 0xc4, 0x08) // add rsp, 8
	append(&b, 0x41, 0x5f, 0x41, 0x5e, 0x41, 0x5d, 0x41, 0x5c, 0x5d, 0x5b, 0xc3) // pop r15-r12 rbp rbx; ret
	return b[:]
}

// native, last: R registered as the thunk around its native code, so each
// native R frame returns to the thunk, then the kernel calls HC: its R(2)
// is unwound past both native R frames (s2 0, one more unwind across
// native code), and each frame's leave gave the thunk's values back.
saved_ok :: proc() {
	when ODIN_ARCH == .amd64 && ODIN_OS != .Windows {
		fn := ps2.learned_find(FN_R)
		if fn == nil {
			fmt.eprintln("fail: R's native code not found")
			os.exit(1)
		}
		code := saved_thunk(fn)
		thunk := cast(cpu.Func_Proc)core.map_code(code)
		unwinds := cpu.interp_unwinds_native
		mem.wr32(HC_RES, 0xffffffff)
		cpu.register(FN_R, thunk)
		kernel.call_handler(FN_HC, 0, 0, 0, 0)
		cpu.register(FN_R, nil)
		core.unmap_code(rawptr(thunk), len(code))
		if saved_bad != 0 || mem.rd32(HC_RES) != 0 || cpu.interp_unwinds_native != unwinds + 1 {
			fmt.eprintfln("fail: callee-saved xor %x, HC's s2 %d, %d unwinds across native code (want 0, 0, %d)", saved_bad, mem.rd32(HC_RES), cpu.interp_unwinds_native, unwinds + 1)
			os.exit(1)
		}
		fmt.println("ee_unwind native: callee-saved registers kept")
	}
}

// stale: L sets sp and calls N, then DONE = 1 and a hang. N (native): sp -= 16 and its
// $ra saved there, F, then its $ra back and a return. F: `jr $ra` to L.
FN_N :: ENTRY + 0x100
FN_F2 :: ENTRY + 0x200
program_stale :: proc() {
	a := Asm{ENTRY}
	li(&a, SP, STACK)
	put(&a, jal(FN_N), NOP)
	li(&a, T7, DATA)
	put(&a, addiu(T0, ZERO, 1), sw(T0, DONE - DATA, T7))
	put(&a, i_type(4, ZERO, ZERO, -1), NOP) // hang
	a = {FN_N}
	put(&a, addiu(SP, SP, -16), sw(RA, 0, SP), jal(FN_F2), NOP, lw(RA, 0, SP), addiu(SP, SP, 16), JR_RA, NOP)
	assert(a.pc <= FN_F2)
	a = {FN_F2}
	li(&a, RA, ENTRY)
	put(&a, JR_RA, NOP)
}

// stale: the run that would leave NATIVE_STALE_MAX + 1 gaps open returned
// to its N, whose return took L to the hang, with one call of N fewer open.
vblank_stale :: proc() {
	if mem.rd32(DONE) == 0 {
		if kernel.k.frame > 60 {
			fmt.eprintln("fail: not done after 60 frames")
			os.exit(1)
		}
		return
	}
	open, most, calls := open_now(), cpu.interp_max_depth, cpu.learned_calls
	if open != cpu.NATIVE_STALE_MAX || most != cpu.NATIVE_STALE_MAX + 1 || calls != cpu.NATIVE_STALE_MAX + 1 {
		fmt.eprintfln("fail: %d calls open at the hang, %d at most, %d native calls of N; want %d, %d, %d", open, most, calls, cpu.NATIVE_STALE_MAX, cpu.NATIVE_STALE_MAX + 1, cpu.NATIVE_STALE_MAX + 1)
		os.exit(1)
	}
	if cpu.interp_stale != 1 {
		fmt.eprintfln("fail: %d jumps refused at NATIVE_STALE_MAX, want 1", cpu.interp_stale)
		os.exit(1)
	}
	fmt.printfln("ee_unwind stale: ok (%d calls open at the hang)", open)
	os.exit(0)
}

// catch: the functions of a case, its learned ones native.
Catch_Fn :: enum {
	K,
	M,
	N,
	T,
	X,
}

Catch_Case :: struct {
	name:    string,
	learned: bit_set[Catch_Fn],
	delta:   u32,
	tail:    bool, // main calls X, not K
	ref:     int, // the case with none learned it must end as
	counted: bool, // with as many unwinds and jumps too
}

CATCH_CASES :: [?]Catch_Case {
	{name = "none learned", ref = 0, counted = true},
	{name = "none learned, another sp", delta = 16, ref = 1, counted = true},
	{name = "none learned, a jump out", tail = true, ref = 2, counted = true},
	{name = "interpreted T to learned K and M", learned = {.K, .M}, ref = 0, counted = true},
	{name = "learned T to learned K and M", learned = {.K, .M, .N, .T}, ref = 0, counted = true},
	{name = "interpreted T past native N to learned K and M", learned = {.K, .M, .N}, ref = 0, counted = true},
	{name = "learned T past learned M and N to interpreted K", learned = {.M, .N, .T}, ref = 0, counted = true},
	{name = "learned T past learned N to interpreted K and M", learned = {.N, .T}, ref = 0, counted = true},
	{name = "learned T, another sp", learned = {.K, .M, .N, .T}, delta = 16, ref = 1, counted = true},
	{name = "interpreted T, another sp, learned K and M", learned = {.K, .M}, delta = 16, ref = 1, counted = true},
	// The interpreted X goes on in its own run; the learned one's jump
	// out is a run of its own, whose return unwinds to X's call.
	{name = "learned X jumps out", learned = {.X}, tail = true, ref = 2},
}

CATCH_BASE :: u32(0x00110000) // case k's code at CATCH_BASE + k * 0x1000
CATCH_FN :: 0x100 // each function's room; X's Y is past X's
STEP :: DATA + 0x200 // the cases done
GO :: DATA + 0x204 // the cases the host has seen done
CATCH_RES :: DATA + 0x300

catch_fn :: proc(k: int, f: Catch_Fn) -> u32 {
	return CATCH_BASE + u32(k) * 0x1000 + (u32(f) + 1) * CATCH_FN
}

program_catch :: proc() {
	cases := CATCH_CASES
	a := Asm{ENTRY}
	for c, k in cases {
		li(&a, SP, STACK)
		li(&a, T7, DATA)
		li(&a, T0, c.delta)
		put(&a, sw(T0, DELTA - DATA, T7), addiu(S2, ZERO, 0))
		put(&a, jal(catch_fn(k, c.tail ? .X : .K)), NOP)
		li(&a, T7, DATA)
		put(&a, sw(S2, CATCH_RES - DATA + 4 * u32(k), T7))
		put(&a, addiu(T0, ZERO, i32(k + 1)), sw(T0, STEP - DATA, T7))
		// Until the host has counted this case's unwinds and jumps.
		put(&a, lw(T1, GO - DATA, T7), i_type(5, T1, T0, -2), NOP)

		// K: its sp to SP0, M, then (K_RET) the sp back, its count and a return.
		f := Asm{catch_fn(k, .K)}
		put(&f, addiu(SP, SP, -16), sw(RA, 0, SP), sw(S0, 4, SP), addu(S0, SP, ZERO))
		li(&f, T7, DATA)
		put(&f, sw(SP, SP0 - DATA, T7), jal(catch_fn(k, .M)), NOP)
		k_ret := f.pc
		put(&f, addu(SP, S0, ZERO), addiu(S2, S2, 1), lw(RA, 0, SP), lw(S0, 4, SP), addiu(SP, SP, 16), JR_RA, NOP)
		catch_load(c, .K, f)
		// M and N: the next one, then a count the throw skips.
		for m in ([?]Catch_Fn{.M, .N}) {
			f = {catch_fn(k, m)}
			put(&f, addiu(SP, SP, -16), sw(RA, 0, SP), jal(catch_fn(k, m == .M ? .N : .T)), NOP)
			put(&f, addiu(S2, S2, m == .M ? 100 : 1000), lw(RA, 0, SP), addiu(SP, SP, 16), JR_RA, NOP)
			catch_load(c, m, f)
		}
		// T: `jr $ra` to K_RET with K's sp at its call of M, plus DELTA.
		f = {catch_fn(k, .T)}
		li(&f, T7, DATA)
		put(&f, lw(T0, SP0 - DATA, T7), lw(T1, DELTA - DATA, T7), addu(SP, T0, T1))
		li(&f, RA, k_ret)
		put(&f, JR_RA, NOP)
		catch_load(c, .T, f)
		// X: a frame, then a jump out of its words to Y, which drops the
		// frame, counts and returns to X's caller.
		f = {catch_fn(k, .X)}
		y := f.pc + CATCH_FN
		put(&f, addiu(SP, SP, -16), j_type(2, y), NOP)
		catch_load(c, .X, f)
		f = {y}
		put(&f, addiu(SP, SP, 16), addiu(S2, S2, 7), JR_RA, NOP)
	}
	put(&a, i_type(4, ZERO, ZERO, -1), NOP) // hang
	assert(a.pc <= FN_R)
}

// The function f of case c ends at a.pc: learned, when the case has it so.
catch_load :: proc(c: Catch_Case, f: Catch_Fn, a: Asm) {
	lo := a.pc &~ (CATCH_FN - 1)
	assert(a.pc - lo <= CATCH_FN)
	if f in c.learned {load_native(lo, a.pc)}
}

catch_seen: u32
catch_last: [2]u64 // unwinds and jumps when the case before was done
catch_got: [len(CATCH_CASES)][2]u64

vblank_catch :: proc() {
	cases := CATCH_CASES
	if kernel.k.frame > 120 {
		fmt.eprintfln("fail: catch: %d of %d cases done after 120 frames", catch_seen, len(cases))
		os.exit(1)
	}
	step := mem.rd32(STEP)
	if step == catch_seen {return}
	now := [2]u64{cpu.interp_unwinds, cpu.interp_jumps}
	catch_got[catch_seen] = now - catch_last
	catch_last = now
	catch_seen = step
	mem.wr32(GO, step)
	if int(step) != len(cases) {return}
	ok := true
	for c, k in cases {
		r, got := mem.rd32(CATCH_RES + 4 * u32(k)), catch_got[k]
		want, want_got := mem.rd32(CATCH_RES + 4 * u32(c.ref)), catch_got[c.ref]
		if r != want || (c.counted && got != want_got) {
			ok = false
			fmt.eprintfln("fail: catch: %s: s2 %d with %d unwinds and %d jumps; none learned: s2 %d, %d, %d", c.name, r, got[0], got[1], want, want_got[0], want_got[1])
		}
	}
	// What the cases with none learned must be: K's count alone, with one
	// unwind; the same after one jump; Y's count, a plain return.
	refs := [3][3]u64{{1, 1, 0}, {1, 1, 1}, {7, 0, 0}}
	for w, k in refs {
		if u64(mem.rd32(CATCH_RES + 4 * u32(k))) != w[0] || catch_got[k] != {w[1], w[2]} {
			ok = false
			fmt.eprintfln("fail: catch: %s: s2 %d with %d unwinds and %d jumps, want %d, %d, %d", cases[k].name, mem.rd32(CATCH_RES + 4 * u32(k)), catch_got[k][0], catch_got[k][1], w[0], w[1], w[2])
		}
	}
	if cpu.learned_calls == 0 || cpu.unwinding {
		ok = false
		fmt.eprintfln("fail: catch: %d native calls, cpu.unwinding %v at the end", cpu.learned_calls, cpu.unwinding)
	}
	if !ok {os.exit(1)}
	fmt.printfln("ee_unwind catch: ok (%d cases, %d native calls)", len(cases), cpu.learned_calls)
	os.exit(0)
}

main :: proc() {
	ps2.init()
	cpu.text_range(ENTRY, ENTRY + 0x1000)
	mode := len(os.args) > 1 ? os.args[1] : ""
	if mode == "catch" {
		when core.FLAT {
			fmt.eprintln("fail: catch: the coroutine model only")
			os.exit(1)
		}
		cpu.text_range(ENTRY, CATCH_BASE + len(CATCH_CASES) * 0x1000)
		kernel.vblank_hook = vblank_catch
		program_catch()
	} else if mode == "cap" {
		core.fatal_cleanup = cap_fatal
		kernel.vblank_hook = vblank_cap
		program_cap()
	} else if mode == "learn" {
		when core.FLAT {
			fmt.eprintln("fail: learn: the coroutine model only")
			os.exit(1)
		}
		dir, err := os.make_directory_temp("", "ps_ee_unwind_*", context.allocator)
		if err != nil {
			fmt.eprintln("fail: no temp directory:", err)
			os.exit(1)
		}
		learn_dir = dir
		learn_path, _ = filepath.join({dir, "learn.bin"}, context.allocator)
		if !core.learn_open_path(learn_path, {.Ee}) {
			os.remove_all(learn_dir)
			os.exit(1)
		}
		core.learn_cpu(.Ee, &cpu.state.cycles, cpu.CYCLES_PER_INSN, proc(a: u32) -> u32 {return mem.rd32(a)}, mem.RAM_SIZE, false)
		kernel.vblank_hook = vblank_learn
		program()
	} else if mode == "getpc" {
		kernel.vblank_hook = vblank_getpc
		program_getpc()
	} else if mode == "frames" {
		kernel.vblank_hook = vblank_frames
		program_frames()
	} else if mode == "learned" {
		when core.FLAT {
			fmt.eprintln("fail: learned: the coroutine model only")
			os.exit(1)
		}
		learned_c_on = true
		kernel.vblank_hook = vblank
		program()
		load_native(FN_C, FN_W)
	} else if mode == "native" || mode == "stale" {
		when core.FLAT {
			fmt.eprintln("fail: native code: the coroutine model only")
			os.exit(1)
		}
		if mode == "native" {
			native_on = true
			kernel.vblank_hook = vblank
			program()
			program_handler()
			load_native(FN_R, FN_C)
		} else {
			kernel.vblank_hook = vblank_stale
			program_stale()
			load_native(FN_N, FN_F2)
		}
	} else if mode == "away" {
		kernel.vblank_hook = vblank_away
		program_away()
	} else {
		kernel.vblank_hook = vblank
		program()
	}
	ps2.run(ENTRY)
}
