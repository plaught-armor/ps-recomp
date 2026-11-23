// A game's own cooperative task switch (psx/cpu task_switch): its routine S
// saves $ra, $sp and $s0-$s7 of the running task in that task's slot, loads
// the next task's from its slot, and ends with `jr $ra`, so it "returns" into
// another task. Racing Lagoon's 0x8006cf24 does this. Native code must go on
// in the task S switched to, as the interpreter does; before task_switch, a
// native call of S came back to its own caller with the other task's $ra and
// $sp, and ran on there.
//
// A is the main task: it counts CNT(0) up three times and calls S after each.
// B and C count CNT(1) and CNT(2) in s0 and call S forever; S switches round
// robin over NTASK tasks. Right, for 2 and 3 tasks: every count 3, CUR 0, and
// A returns to its caller with sp and $ra as it was called. Each case runs
// interpreted, then with only S native (interpreted callers: interp_call's
// and, under FLAT, flat_enter's host return), then all native (the four
// functions compiled apart, as jal targets are, and marked as a blob build
// marks them). Under FLAT, A runs on a flat run of its own, each task on
// records of its own, and a switch made in native code holds the run there
// while the other tasks run (task_go); for wasm32, all native is all
// learned (a second learned blob of every function but S). A's loop
// ends on bgtz, so a broken switch fails, not hangs. A third case has tasks
// E and F each wait one switch in one routine W, so a switch from E to F
// returns at W's own link on F's $sp; under FLAT with S native, E's and F's
// calls of W are open on records each task's own, and A's last `jr $ra`
// must find its return in A's. It runs again with A going round 100
// times, and must discard no task: a switch missed with only S native would
// leave a task suspended each round and fill the table.
// G calls P, a SetSp (as Driver 2's f_00090300): P moves $sp and returns to
// its link, loading $ra through a0. That is no task switch; G counts
// CNT(3) once and puts $sp back.
// H is A switching through W(1), not S itself. A mode with all native but W
// has native code (H, E, F) make a guest call of W the interpreter runs,
// nested in it, and S switch there: under FLAT that switch holds the run in
// the native code below, as one native code makes itself does (Racing
// Lagoon's blob calls its 0x8006c910 natively, left to the interpreter).
// The R3000 code waits out each load's delay slot.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import cpu "ps:psx/cpu"
import psx_native "ps:psx/native"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"

A :: u32(0x80020000)
B :: u32(0x80020100)
C :: u32(0x80020200)
S :: u32(0x80020300)
D :: u32(0x80020400)
W :: u32(0x80020500)
E :: u32(0x80020600)
F :: u32(0x80020700)
G :: u32(0x80020800)
P :: u32(0x80020900)
H :: u32(0x80020a00)
DATA :: u32(0x80010000)
CUR :: DATA // the running task's index
NTASK :: DATA + 4
STACK_A :: DATA + 0x2000
STACK_B :: DATA + 0x3000
STACK_C :: DATA + 0x4000
STACK_P :: DATA + 0x4800 // the stack P moves to
RET :: u32(0x80000080) // the caller's return address of the call of A

cnt :: proc(i: u32) -> u32 {return DATA + 0x10 + 4 * i}
slot :: proc(i: u32) -> u32 {return DATA + 0x100 + 0x40 * i} // +0 ra, +4 sp, +8 s0..s7

ZERO, A0, T0, T1, T2, T7, S0, S1, SP, RA :: u32(0), u32(4), u32(8), u32(9), u32(10), u32(15), u32(16), u32(17), u32(29), u32(31)
ROUNDS :: u32(3) // A's rounds, but in the long case
NOP :: u32(0)
JR_RA :: u32(0x03e00008)

lui :: proc(rt, imm: u32) -> u32 {return 0x0f << 26 | rt << 16 | imm & 0xffff}
lw :: proc(rt, off, base: u32) -> u32 {return 0x23 << 26 | base << 21 | rt << 16 | off & 0xffff}
sw :: proc(rt, off, base: u32) -> u32 {return 0x2b << 26 | base << 21 | rt << 16 | off & 0xffff}
addiu :: proc(rt, rs, imm: u32) -> u32 {return 0x09 << 26 | rs << 21 | rt << 16 | imm & 0xffff}
sll :: proc(rd, rt, sa: u32) -> u32 {return rt << 16 | rd << 11 | sa << 6}
addu :: proc(rd, rs, rt: u32) -> u32 {return rs << 21 | rt << 16 | rd << 11 | 0x21}
jal :: proc(t: u32) -> u32 {return 0x03 << 26 | t >> 2 & 0x03ffffff}
j :: proc(t: u32) -> u32 {return 0x02 << 26 | t >> 2 & 0x03ffffff}
bne :: proc(pc, rs, rt, t: u32) -> u32 {return 0x05 << 26 | rs << 21 | rt << 16 | (t - pc - 4) >> 2 & 0xffff}
bgtz :: proc(pc, rs, t: u32) -> u32 {return 0x07 << 26 | rs << 21 | (t - pc - 4) >> 2 & 0xffff}

Code :: struct {
	at: u32,
	w:  [dynamic]u32,
}

pc :: proc(c: Code) -> u32 {return c.at + 4 * u32(len(c.w))}
emit :: proc(c: ^Code, words: ..u32) {append(&c.w, ..words)}

// t1 = SLOT(t0)
emit_slot :: proc(c: ^Code) {emit(c, sll(T1, T0, 6), addu(T1, T1, T7), addiu(T1, T1, 0x100))}

s_code :: proc() -> Code {
	c := Code{at = S}
	emit(&c, lui(T7, DATA >> 16), lw(T0, 0, T7), NOP)
	emit_slot(&c)
	emit(&c, sw(RA, 0, T1), sw(SP, 4, T1))
	for k in u32(0) ..< 8 {emit(&c, sw(S0 + k, 8 + 4 * k, T1))}
	emit(&c, addiu(T0, T0, 1), lw(T2, NTASK - DATA, T7), NOP)
	at := pc(c)
	emit(&c, bne(at, T0, T2, at + 12), NOP, addu(T0, ZERO, ZERO))
	emit(&c, sw(T0, 0, T7))
	emit_slot(&c)
	// The lw $ra through t1, not $sp, is what makes S return elsewhere.
	emit(&c, lw(RA, 0, T1), lw(SP, 4, T1))
	for k in u32(0) ..< 8 {emit(&c, lw(S0 + k, 8 + 4 * k, T1))}
	emit(&c, NOP, JR_RA, NOP)
	return c
}

// A(a0): a0 rounds, each switching once: at A through S itself, at H
// through W(1).
a_code :: proc(at := A) -> Code {
	c := Code{at = at}
	emit(&c, addiu(SP, SP, 0xfff0), sw(RA, 0, SP), addu(S0, A0, ZERO), lui(S1, DATA >> 16))
	loop := pc(c)
	emit(&c, lw(T0, cnt(0) - DATA, S1), NOP, addiu(T0, T0, 1), sw(T0, cnt(0) - DATA, S1))
	if at == H {emit(&c, addiu(A0, ZERO, 1))}
	emit(&c, jal(at == H ? W : S), NOP, addiu(S0, S0, 0xffff))
	emit(&c, bgtz(pc(c), S0, loop), NOP)
	emit(&c, lw(RA, 0, SP), NOP, JR_RA, addiu(SP, SP, 16))
	return c
}

// A side task at D counting CNT(1) once and switching once, then returning:
// it is made with its entry as $ra, so its `jr $ra` starts it over, as
// Racing Lagoon's task at 0x8007e5f8 is.
d_code :: proc() -> Code {
	c := Code{at = D}
	emit(&c, addiu(SP, SP, 0xfff8), sw(RA, 0, SP), lui(S1, DATA >> 16))
	emit(&c, lw(T0, cnt(1) - DATA, S1), NOP, addiu(T0, T0, 1), sw(T0, cnt(1) - DATA, S1))
	emit(&c, jal(S), NOP, lw(RA, 0, SP), NOP, JR_RA, addiu(SP, SP, 8))
	return c
}

// W(a0): wait a0 switches, then return; Racing Lagoon's 0x8006c910 waits
// frames so. Tasks waiting in it go on at one link (after its jal S): only
// their $sp tells a switch from one to another from W's own return.
w_code :: proc() -> Code {
	c := Code{at = W}
	emit(&c, addiu(SP, SP, 0xfff0), sw(RA, 0, SP), sw(S0, 4, SP), addu(S0, A0, ZERO))
	loop := pc(c)
	emit(&c, jal(S), NOP, addiu(S0, S0, 0xffff))
	emit(&c, bgtz(pc(c), S0, loop), NOP)
	emit(&c, lw(RA, 0, SP), lw(S0, 4, SP), NOP, JR_RA, addiu(SP, SP, 16))
	return c
}

// A side task at at counting CNT(i) up after each W(k), forever.
wait_task_code :: proc(at, i, k: u32) -> Code {
	c := Code{at = at}
	emit(&c, addiu(SP, SP, 0xfff8), lui(S1, DATA >> 16))
	loop := pc(c)
	emit(&c, addiu(A0, ZERO, k), jal(W), NOP)
	emit(&c, lw(T0, cnt(i) - DATA, S1), NOP, addiu(T0, T0, 1), sw(T0, cnt(i) - DATA, S1), j(loop), NOP)
	return c
}

// G: count CNT(3) once on the stack P moved to, then put $sp and $ra back.
g_code :: proc() -> Code {
	c := Code{at = G}
	emit(&c, addu(S0, SP, ZERO), addu(S1, RA, ZERO), lui(A0, STACK_P >> 16), addiu(A0, A0, STACK_P & 0xffff))
	emit(&c, jal(P), NOP, lui(T7, DATA >> 16), lw(T0, cnt(3) - DATA, T7), NOP, addiu(T0, T0, 1), sw(T0, cnt(3) - DATA, T7))
	emit(&c, addu(RA, S1, ZERO), JR_RA, addu(SP, S0, ZERO))
	return c
}

// P(a0): $sp = a0, back at its link. The $ra it returns on is loaded
// through a0 (a SetSp keeping it in the new stack), so its call gets the
// call_back check, as S's do.
p_code :: proc() -> Code {
	c := Code{at = P}
	emit(&c, sw(RA, 0, A0), lw(RA, 0, A0), NOP, JR_RA, addu(SP, A0, ZERO))
	return c
}

// A side task at at counting CNT(i) in s0, forever.
task_code :: proc(at, i: u32) -> Code {
	c := Code{at = at}
	emit(&c, addiu(SP, SP, 0xfff8), addu(S0, ZERO, ZERO), lui(S1, DATA >> 16))
	loop := pc(c)
	emit(&c, addiu(S0, S0, 1), sw(S0, cnt(i) - DATA, S1), jal(S), NOP, j(loop), NOP)
	return c
}

put :: proc(c: Code) {
	for w, k in c.w {(^u32le)(&cpu.ram[(c.at & 0x1fffff) + u32(k) * 4])^ = u32le(w)}
}

rd :: proc(at: u32) -> u32 {return u32((^u32le)(&cpu.ram[at & 0x1fffff])^)}
wr :: proc(at, v: u32) {(^u32le)(&cpu.ram[at & 0x1fffff])^ = u32le(v)}

fail :: proc(what: string) -> ! {
	fmt.eprintln("FAIL psx_task_switch:", what)
	os.exit(1)
}

// The eleven functions, each discovered apart, then marked as a blob build
// marks them (r3000.returns_elsewhere: A's, B's, C's, D's and W's jal S get
// the call_back check, since S loads $ra through t1, and G's jal P, since
// P loads it through a0; H's jal W does not), then lowered.
compile :: proc(na: ^native.Asm, codes: []Code) -> (out: [11]native.Blob_Func) {
	fs: [11]^mips.Func
	for c, k in codes {
		fs[k] = mips.func_make(c.at, pc(c), c.at)
		mips.discover(r3000.RULES, {base = c.at, data = ([^]u8)(raw_data(c.w))[:4 * len(c.w)], entry = c.at}, fs[k], nil)
	}
	if r3000.returns_elsewhere({fs[:]}) != 6 {fail("the jal S of A, B, C, D and W and G's jal P are not marked as returning elsewhere")}
	for f, k in fs {
		out[k] = {f.entry, r3000.native_func(na, f, nil, 1)}
		mips.func_free(f)
	}
	free_all(context.temp_allocator)
	return
}

// Call the guest function at entry as the test's caller does: $sp STACK_A,
// $ra RET.
call_guest :: proc(entry: u32) {
	cpu.state.r[29], cpu.state.r[31] = STACK_A, RET
	when core.FLAT {
		@(static) x: cpu.Flat_Ctx
		cpu.flat_start(&x, entry)
		if !cpu.flat_run(&x) {fail(fmt.tprintf("the flat run at %08x stopped", entry))}
	} else {
		cpu.call(entry)
	}
}

// One case of n tasks, task 1 starting at first (B, D, or E, with task 2
// at F), the main task (A or H) going round rounds times; true when it came
// out right and discarded no task.
run :: proc(mode: string, n: u32, first := B, rounds := ROUNDS, main_task := A) -> bool {
	for a := DATA; a < DATA + 0x5000; a += 4 {wr(a, 0)}
	wr(NTASK, n)
	wr(slot(1), first)
	wr(slot(1) + 4, STACK_B)
	wr(slot(2), first == E ? F : C)
	wr(slot(2) + 4, STACK_C)
	reaped := cpu.tasks_reaped
	cpu.state.r[4] = rounds
	call_guest(main_task)
	got := [7]u32{rd(cnt(0)), rd(cnt(1)), rd(cnt(2)), rd(CUR), cpu.state.r[29], cpu.state.r[31], u32(cpu.tasks_reaped - reaped)}
	want := [7]u32{rounds, rounds, n == 3 ? rounds : 0, 0, STACK_A, RET, 0}
	// E and F start in A's first switch and count once in each later one.
	if first == E {want[1], want[2] = rounds - 1, rounds - 1}
	ok := got == want
	fmt.printfln("%s %d tasks%s%s, %d rounds: cnt cur sp ra reaped %x, want %x %s", mode, n, first == D ? " (task 1 starts over)" : first == E ? " (both wait in one routine)" : "", main_task == H ? " (main switching in W)" : "", rounds, got, want, ok ? "ok" : "FAIL")
	return ok
}

// G's call of the SetSp P; true when it counted once, came back as called,
// and switched no task.
set_sp :: proc(mode: string) -> bool {
	wr(cnt(3), 0)
	switches := cpu.task_switches
	call_guest(G)
	got := [4]u32{rd(cnt(3)), cpu.state.r[29], cpu.state.r[31], u32(cpu.task_switches - switches)}
	want := [4]u32{1, STACK_A, RET, 0}
	ok := got == want
	fmt.printfln("%s SetSp: cnt sp ra switches %x, want %x %s", mode, got, want, ok ? "ok" : "FAIL")
	return ok
}

main :: proc() {
	cpu.register_funcs(nil)
	when core.FLAT {cpu.interp_run = cpu.flat_nested} else {cpu.interp_run = cpu.interp_loop}
	cpu.next_event = max(u64)
	codes := [11]Code{a_code(), task_code(B, 1), task_code(C, 2), s_code(), d_code(), w_code(), wait_task_code(E, 1, 1), wait_task_code(F, 2, 1), g_code(), p_code(), a_code(H)}
	assert(pc(codes[0]) <= B && pc(codes[1]) <= C && pc(codes[2]) <= S && pc(codes[3]) <= D && pc(codes[4]) <= W && pc(codes[5]) <= E && pc(codes[6]) <= F && pc(codes[7]) <= G && pc(codes[8]) <= P && pc(codes[9]) <= H)
	for c in codes {put(c)}
	bad := 0
	// Each mode: 2 and 3 tasks, with A and with H, then 2 with task 1 at D,
	// then 3 at E and F, short and long, then the SetSp.
	cases :: proc(mode: string) -> (bad: int) {
		for n in u32(2) ..= 3 {
			if !run(mode, n) {bad += 1}
			if !run(mode, n, main_task = H) {bad += 1}
		}
		if !run(mode, 2, D) {bad += 1}
		if !run(mode, 3, E) {bad += 1}
		// More rounds than the table has tasks (cpu MAX_TASKS 48).
		if !run(mode, 3, E, 100) {bad += 1}
		if !set_sp(mode) {bad += 1}
		return
	}
	bad += cases("interp")
	when ODIN_ARCH == .wasm32 {
		// wasm32 has no PS1 blob of fixed functions: S is learned code, as
		// the play page runs native PS1 code (load_learned_blob).
		s := codes[3]
		blob := r3000.learned_blob({{S, S, s.w[:]}}, .Wasm32)
		if !psx_native.load_learned_blob(blob, "learned") {fail("load the learned blob")}
		bad += cases("S learned")
		// Then all but W learned too: S's callers switch in native code, and
		// in W's guest calls from native code (H, E, F).
		all: [dynamic]r3000.Learned
		for c, k in codes {
			if k != 3 && k != 5 {append(&all, r3000.Learned{c.at, c.at, c.w[:]})}
		}
		if !psx_native.load_learned_blob(r3000.learned_blob(all[:], .Wasm32), "learned") {fail("load the second learned blob")}
		bad += cases("all but W learned")
		w := codes[5]
		if !psx_native.load_learned_blob(r3000.learned_blob({{W, W, w.w[:]}}, .Wasm32), "learned") {fail("load the third learned blob")}
		bad += cases("learned")
		if bad > 0 {fail(fmt.tprintf("%d runs wrong: a native call of a task switch ran on in the task it left", bad))}
		fmt.println("ok")
		return
	}
	na := native.make_asm(native.Arch(core.NATIVE_ARCH), r3000.native_ram(), r3000.NATIVE_CACHED[:])
	funcs := compile(&na, codes[:])
	code, err := core.native_load(native.make_blob(&na, funcs[:], {}), psx_native.imports())
	if err != "" {fail(fmt.tprint("native_load:", err))}
	fns: [11]cpu.Func_Entry
	for e, k in funcs {fns[k] = {e.addr, cast(cpu.Func_Proc)rawptr(code.base + uintptr(code.funcs[k].off))}}
	// S and P native: interp_call's host returns.
	cpu.register_funcs({fns[3], fns[9]})
	bad += cases("S native")
	// All but W native: native code's guest calls of W switch in S.
	but_w: [dynamic]cpu.Func_Entry
	for e, k in fns {if k != 5 {append(&but_w, e)}}
	cpu.register_funcs(but_w[:])
	bad += cases("all but W native")
	cpu.register_funcs(fns[:])
	bad += cases("native")
	if bad > 0 {fail(fmt.tprintf("%d runs wrong: a native call of a task switch ran on in the task it left", bad))}
	fmt.println("ok")
}
