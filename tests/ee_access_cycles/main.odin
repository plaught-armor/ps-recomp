// The cycles a COP0 Count read sees (ps2/interp.odin's MFC0, recomp/r5900
// lower.odin's each): the cycles of every instruction before it and its own,
// interpreted and learned alike, wherever it sits: right after a label the
// block before falls into (a loop's head), after instructions whose cycles
// wait for a flush (batches), after a call to code no native code holds
// returns, in a branch's delay slot, in a branch-likely's (run only when
// taken) and in a delay slot that is itself a branch's target.
//
// A loop runs three times and stores each read into BUF: interpreted, then
// as a learned function (native code from the same words). Both stores and
// the cycles after the call match. A second function, run the same two ways,
// writes Count after instructions that batch, and reads it 3 cycles on.
//
// Run it on the host (not FLAT: no learned code runs there) and built for
// wasi_wasm32 (run.mjs), whose learned function is wasm32 code, the one
// native EE code that keeps exact's blocks (lower's exact with each).
// Before wasm32 batched (BLOB-SIZE BS1), its code charged each
// instruction just before it ran.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import mem "ps:ps2/mem"
import "ps:recomp/native"
import "ps:recomp/r5900"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL ee_access_cycles: %s (line %d)", what, loc.line)
		failed += 1
	}
}

@(private = "file")
T :: u32(0x00100000)

// W: writes Count and reads it.
@(private = "file")
W :: u32(0x00100200)

@(private = "file")
WROTE :: u32(0xfffffffe) // what W writes: the read is past the wrap

@(rodata, private = "file")
W_CODE := [?]u32 {
	0x24080001, // addiu t0, zero, 1
	0x24090002, // addiu t1, zero, 2     batched with it
	0x40844800, // mtc0 a0, Count
	0x01095021, // addu t2, t0, t1
	0x01495821, // addu t3, t2, t1
	0x40024800, // mfc0 v0, Count        3 cycles on
	0x03e00008, // jr ra
	0x00000000, // nop
}

// F: interpreted, no native code holds it.
@(private = "file")
F :: u32(0x00100100)

@(private = "file")
BUF :: u32(0x00180000)

@(private = "file")
RA :: u32(0x001fff00)

@(private = "file")
SP :: u32(0x001ff000)

// The reads: 3 per pass (the loop's head, after batches, after the call),
// the last pass's bne-slot read stored at the next head (0 before it), and
// at the end the branch-likely's slot read and the last bne slot's.
@(private = "file")
N_WORDS :: 3 * 4 + 2

@(rodata, private = "file")
CODE := [?]u32 {
	0x03e08025, // 00 or s0, ra, zero         $ra, kept over the call
	0x24090003, // 04 addiu t1, zero, 3
	0x240b0000, // 08 addiu t3, zero, 0
	0x40084800, // 0c L: mfc0 t0, Count       right after the label
	0xaca80000, // 10 sw t0, 0(a1)
	0xacab0004, // 14 sw t3, 4(a1)          the last bne slot's read
	0x24a50008, // 18 addiu a1, a1, 8
	0x01295021, // 1c addu t2, t1, t1
	0x40084800, // 20 mfc0 t0, Count       after batches
	0xaca80000, // 24 sw t0, 0(a1)
	0x0c040040, // 28 jal F
	0x24a50004, // 2c addiu a1, a1, 4      in the call's delay slot
	0x40084800, // 30 mfc0 t0, Count       after the call returns
	0xaca80000, // 34 sw t0, 0(a1)
	0x24a50004, // 38 addiu a1, a1, 4
	0x2529ffff, // 3c addiu t1, t1, -1
	0x51200002, // 40 beql t1, zero, 4c
	0x40084800, // 44 mfc0 t0, Count       a branch-likely's slot, taken only on the last pass
	0x1520fff0, // 48 bne t1, zero, L
	0x400b4800, // 4c mfc0 t3, Count       the bne's slot, and the beql's target
	0xaca80000, // 50 sw t0, 0(a1)
	0xacab0004, // 54 sw t3, 4(a1)
	0x0200f825, // 58 or ra, s0, zero
	0x03e00008, // 5c jr ra
	0x00000000, // 60 nop
}

@(rodata, private = "file")
F_CODE := [?]u32 {
	0x24020001, // addiu v0, zero, 1
	0x03e00008, // jr ra
	0x00000000, // nop
}

// Call T with a1 = BUF from the host: what it stored, the cycles the call
// took, and whether learned code ran.
@(private = "file")
run :: proc() -> (got: [N_WORDS]u32, took: u64, ran: bool) {
	for k in u32(0) ..< N_WORDS {mem.wr32(BUF + 4 * k, 0xffffffff)}
	cpu.state.r = {}
	cpu.state.r[29].d[0], cpu.state.r[31].d[0] = u64(SP), u64(RA)
	cpu.state.r[5].d[0] = u64(BUF)
	cpu.state.cop0[9] = 0 // never written: T's reads are the cycles themselves
	calls := cpu.learned_calls
	at := cpu.state.cycles
	cpu.call(T)
	took = cpu.state.cycles - at
	// Word 1 is t3 before any bne-slot read: 0, not a cycle count.
	for k in u32(0) ..< N_WORDS {got[k] = mem.rd32(BUF + 4 * k) - (k == 1 ? 0 : u32(at))}
	return got, took, cpu.learned_calls != calls
}

// Call W with a0 = WROTE from the host: what it read, and whether learned
// code ran.
@(private = "file")
run_write :: proc() -> (got: u32, ran: bool) {
	cpu.state.r = {}
	cpu.state.r[29].d[0], cpu.state.r[31].d[0] = u64(SP), u64(RA)
	cpu.state.r[4].d[0] = cpu.sx32(WROTE)
	calls := cpu.learned_calls
	cpu.call(W)
	return u32(cpu.state.r[2].d[0]), cpu.learned_calls != calls
}

// The checks, run as the game's coroutine on the host (as tests/ee_learned)
// and from main on wasm32.
@(private = "file")
game :: proc(_: rawptr) {
	code, f_code, w_code := CODE, F_CODE, W_CODE
	for w, k in code {mem.wr32(T + 4 * u32(k), w)}
	for w, k in f_code {mem.wr32(F + 4 * u32(k), w)}
	for w, k in w_code {mem.wr32(W + 4 * u32(k), w)}

	interp, interp_took, interp_ran := run()
	check(!interp_ran, "a learned function ran before any was loaded")
	check(interp[0] != 0 && interp[N_WORDS - 2] > interp[N_WORDS - 3], fmt.tprintf("interpreted reads %v: no read seen", interp))

	want := WROTE
	want += 3
	wrote, wrote_ran := run_write()
	check(!wrote_ran, "a learned W ran before any was loaded")
	check(wrote == want, fmt.tprintf("interpreted read %08x after the write, want %08x", wrote, want))

	blob, skipped := r5900.learned_blob({{T, T, code[:]}, {W, W, w_code[:]}}, native.Arch(core.NATIVE_ARCH))
	check(skipped == 0, fmt.tprintf("%d runs not lowered", skipped))
	check(ps2.load_learned_blob(blob, "learned"), "load the blob")
	learned, learned_took, learned_ran := run()
	check(learned_ran, "the learned function did not run")
	check(slice.equal(learned[:], interp[:]), fmt.tprintf("learned reads %v, interpreted %v (cycles from the call)", learned, interp))
	check(learned_took == interp_took, fmt.tprintf("learned call %d cycles, interpreted %d", learned_took, interp_took))
	wrote, wrote_ran = run_write()
	check(wrote_ran, "the learned W did not run")
	check(wrote == want, fmt.tprintf("learned read %08x after the write, want %08x", wrote, want))
	if failed != 0 {
		os.exit(1)
	}
	fmt.printfln("ok ee_access_cycles: a COP0 Count read sees the cycles up to it and its own, after a fallthrough label, batched instructions and a call's return, in a delay slot, a branch-likely's and one that is a branch target, and counts from what was written to it, interpreted and learned alike (%v)", interp)
	os.exit(0)
}

main :: proc() {
	when core.FLAT && ODIN_OS != .WASI {
		fmt.eprintln("tests/ee_access_cycles runs learned code, which a host FLAT build never runs: build it without PS_FLAT, or for wasi_wasm32 (run.mjs)")
		os.exit(2)
	} else when ODIN_ARCH == .wasm32 {
		ps2.init()
		cpu.next_event = max(u64)
		game(nil)
	} else {
		ps2.init()
		cpu.next_event = max(u64)
		cpu.interp_hook = ps2.interp_call
		context.allocator = core.emu_allocator()
		core.co_allocator = context.allocator
		core.snap_run(core.co_create(game, nil))
	}
}
