// The R3000's `jr`, interpreted (psx/cpu/interp.odin) and under FLAT
// (psx/cpu/interp_flat.odin): a `jr` is a plain jump on the hardware, and
// only one to the run's return address (frame_ret) is a return.
//   - A `jr $ra` to a label of the function itself goes on there.
//   - One to the return address of an outer call still open, made with the
//     $sp the `jr` sees (a callee that pops its caller's frame and returns
//     for it), returns from both: the caller's code after its call is
//     passed over.
//   - One to that address with another $sp is a jump too: the code there
//     runs in the callee's run.
//   - A host callee that returns with $ra the calling run's own return
//     address, not its link (a coroutine's yield, FF8's LZS decoder),
//     returns for that run: the run's code after the call is passed over,
//     as cpu.call_back does in native code.
//   - A jump to a function of host code with $ra a pc the run came through
//     (a link it made, or the one it began at: a loop through a routine)
//     comes back there when the function returns to it, an interrupt's
//     ReturnFromException in the meantime or not. With $ra a pc outside the
//     run that return is the run's, as it is for a jump to a BIOS vector or
//     for a function that never returns (tests/psx_rfe).
// Each case is told apart by v0 and by the unwinds and jumps counted.
// Runs on both builds: natively, and with -define:PS_FLAT=true.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import _ "ps:psx" // the PS1 hooks: interp_run among them
import bios "ps:psx/bios"
import cpu "ps:psx/cpu"
import io "ps:psx/io"

@(private = "file")
failed: int

@(private = "file")
check :: proc(what: string, got, want: u32) {
	if got != want {
		fmt.eprintfln("FAIL psx_jr: %s = %#x, want %#x", what, got, want)
		failed += 1
	}
}

// jal MID; nop; addiu v0, v0, 1; jr s2; nop.
@(private = "file")
OUTER :: 0x80002000

// jal INNER (or INNER_SP); nop; addiu v0, v0, 100; jr s1; nop.
@(private = "file")
MID :: 0x80002100

// addiu v0, zero, 5; $ra = OUTER + 8; jr ra; nop: returns for MID.
@(private = "file")
INNER :: 0x80002200

// INNER with addiu sp, sp, -8 first: not the $sp of OUTER's call.
@(private = "file")
INNER_SP :: 0x80002300

// jr s0; nop: the way back to MID from the jump to OUTER + 8 INNER_SP's run
// makes.
@(private = "file")
BACK :: 0x80002400

// $ra = LABEL; jr ra; nop. LABEL: addiu v0, zero, 9; jr s0; nop.
@(private = "file")
JUMP :: 0x80002500
@(private = "file")
LABEL :: JUMP + 0x20

// jal OUTER; nop; addiu v0, v0, 1000; jr s3; nop: OUTER's call is not the
// first of the run, so an unwind to it stops there.
@(private = "file")
TOP :: 0x80002600

// jal YIELD; nop; addiu v0, v0, 100; jr s4; nop.
@(private = "file")
CALLER :: 0x80002700

// Host code: v0 = 1, $ra = yield_ra, return.
@(private = "file")
YIELD :: 0x80002800

@(private = "file")
yield_ra: u32

// Host code: v0 += 10, return.
@(private = "file")
LEAF :: 0x80002900

// Host code: takes an interrupt whose chain handler calls
// ReturnFromException, then v0 += 10, return.
@(private = "file")
LEAF_IRQ :: 0x80002c80
@(private = "file")
FIRST :: 0x80002d00 // first(): returns 1
@(private = "file")
SECOND :: 0x80002d80 // second(): ReturnFromException
@(private = "file")
ELEM :: 0x80006000 // the chain element {next, second, first, unused}

@(private = "file")
rfes: u32

// addiu v0, zero, 0; $ra = LINK + 20; jr s6 (LEAF); nop. LINK + 20:
// addiu v0, v0, 1; jr s5; nop.
@(private = "file")
LINK :: 0x80002a00

// addiu v0, zero, 0. AGAIN: addiu v0, v0, 1; slti t0, v0, 3; beq t0, zero,
// OUT; nop; $ra = AGAIN; j LEAF; nop. OUT: jr s5; nop.
@(private = "file")
LOOP :: 0x80002b00
@(private = "file")
AGAIN :: LOOP + 4

// addiu v0, zero, 0; $ra = LINK + 20, outside this run; j LEAF; nop.
@(private = "file")
AWAY :: 0x80002c00

@(private = "file")
put :: proc(at: u32, code: []u32) {
	for w, k in code {
		cpu.w32(at + 4 * u32(k), w)
	}
}

@(private = "file")
jal :: proc(t: u32) -> u32 {return 0x0c000000 | (t >> 2) & 0x3ffffff}

// lui ra, value >> 16; ori ra, ra, value & 0xffff.
@(private = "file")
set_ra :: proc(at, value: u32) {
	put(at, {0x3c1f0000 | value >> 16, 0x37ff0000 | value & 0xffff})
}

// Run the guest function at entry, called from $ra ra, to its return; v0,
// and the unwinds and jumps it counted.
@(private = "file")
run :: proc(entry, ra: u32) -> (v0: u32, unwinds, jumps: u32) {
	u, j := cpu.interp_unwinds, cpu.interp_jumps
	cpu.state.r[2], cpu.state.r[29], cpu.state.r[31] = 0xdead, 0x801ff000, ra
	when core.FLAT {
		x: cpu.Flat_Ctx
		cpu.flat_start(&x, entry)
		if !cpu.flat_run(&x) {
			fmt.eprintfln("FAIL psx_jr: the flat run of %08x stopped", entry)
			failed += 1
		}
		cpu.flat_free(&x)
	} else {
		cpu.call(entry)
	}
	return cpu.state.r[2], u32(cpu.interp_unwinds - u), u32(cpu.interp_jumps - j)
}

main :: proc() {
	// No recompiled code but YIELD: every other function interpreted.
	cpu.register_funcs({
		{YIELD, proc() {cpu.state.r[2], cpu.state.r[31] = 1, yield_ra}},
		{LEAF, proc() {cpu.state.r[2] += 10}},
		{LEAF_IRQ, proc() {
				io.irq_regs.stat, io.irq_regs.mask = 1, 1
				bios.deliver_irq()
				cpu.state.r[2] += 10
			}},
		{FIRST, proc() {cpu.state.r[2] = 1}},
		{SECOND, proc() {
				rfes += 1
				cpu.bios_b(0x17)
			}},
	})
	bios.bios_init()
	cpu.next_event = max(u64)
	r := &cpu.state.r

	put(JUMP, {0, 0, 0x03e00008, 0})
	set_ra(JUMP, LABEL)
	put(LABEL, {0x24020009, 0x02000008, 0})
	r[16] = BACK
	v0, unwinds, jumps := run(JUMP, BACK)
	check("v0 after a jr $ra to its own label", v0, 9)
	check("unwinds of a jr $ra to its own label", unwinds, 0)
	check("jumps of a jr $ra to its own label", jumps, 1)

	put(OUTER, {jal(MID), 0, 0x24420001, 0x02400008, 0})
	put(INNER, {0x24020005, 0, 0, 0x03e00008, 0})
	set_ra(INNER + 4, OUTER + 8)
	put(INNER_SP, {0x27bdfff8, 0x24020005, 0, 0, 0x03e00008, 0})
	set_ra(INNER_SP + 8, OUTER + 8)
	put(BACK, {0x02000008, 0})
	r[16], r[17], r[18] = MID + 8, OUTER + 8, BACK

	// 5, then OUTER's 1: MID's 100 passed over.
	put(MID, {jal(INNER), 0, 0x24420064, 0x02200008, 0})
	v0, unwinds, jumps = run(OUTER, BACK)
	check("v0 after a jr $ra to an outer call", v0, 6)
	check("unwinds of a jr $ra to an outer call", unwinds, 1)
	check("jumps of a jr $ra to an outer call", jumps, 0)

	// The same under TOP: 5, OUTER's 1, TOP's 1000.
	put(TOP, {jal(OUTER), 0, 0x244203e8, 0x02600008, 0})
	r[18], r[19] = TOP + 8, BACK
	v0, unwinds, jumps = run(TOP, BACK)
	check("v0 after a jr $ra to an outer call under TOP", v0, 1006)
	check("unwinds of a jr $ra to an outer call under TOP", unwinds, 1)
	check("jumps of a jr $ra to an outer call under TOP", jumps, 0)
	r[18] = BACK

	// 5, the jump to OUTER + 8 (1), BACK's return to MID (100), MID's
	// return to OUTER (1).
	put(MID, {jal(INNER_SP), 0, 0x24420064, 0x02200008, 0})
	v0, unwinds, jumps = run(OUTER, BACK)
	check("v0 after a jr $ra to an outer call with another $sp", v0, 107)
	check("unwinds of a jr $ra with another $sp", unwinds, 0)
	check("jumps of a jr $ra with another $sp", jumps, 1)

	// YIELD returns past CALLER, to BACK: 1, CALLER's 100 passed over.
	// Back to its link, CALLER goes on: 101.
	put(CALLER, {jal(YIELD), 0, 0x24420064, 0x02800008, 0})
	r[20] = BACK
	backs := cpu.call_backs
	yield_ra = BACK
	v0, _, _ = run(CALLER, BACK)
	check("v0 after a host callee returns past its caller", v0, 1)
	check("returns past the caller counted", u32(cpu.call_backs - backs), 1)
	yield_ra = CALLER + 8
	v0, _, _ = run(CALLER, BACK)
	check("v0 after a host callee returns to its link", v0, 101)
	check("returns past the caller counted after one to its link", u32(cpu.call_backs - backs), 1)

	r[21], r[22] = BACK, LEAF
	put(LINK, {0x24020000, 0, 0, 0x02c00008, 0, 0x24420001, 0x02a00008, 0})
	set_ra(LINK + 4, LINK + 20)
	v0, _, _ = run(LINK, BACK)
	check("v0 after host code jumped to with the link after the jr", v0, 11)

	put(ELEM, {0, SECOND, FIRST, 0})
	cpu.state.r[4], cpu.state.r[5] = 0, ELEM
	bios.bios_c(0x02) // SysEnqIntRP
	r[21], r[22] = BACK, LEAF_IRQ
	v0, _, _ = run(LINK, BACK)
	check("ReturnFromExceptions inside host code jumped to", rfes, 1)
	check("v0 after host code jumped to took an interrupt", v0, 11)

	put(LOOP, {0x24020000, 0x24420001, 0x28480003, 0x11000005, 0, 0, 0, 0x08000000 | (LEAF >> 2) & 0x3ffffff, 0, 0x02a00008, 0})
	set_ra(LOOP + 20, AGAIN)
	v0, _, _ = run(LOOP, BACK)
	check("v0 after a loop through host code", v0, 12)

	put(AWAY, {0x24020000, 0, 0, 0x08000000 | (LEAF >> 2) & 0x3ffffff, 0})
	set_ra(AWAY + 4, LINK + 20)
	v0, _, _ = run(AWAY, BACK)
	check("v0 after host code jumped to with a link outside the run", v0, 10)

	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok psx_jr: jr is a plain jump, only one to frame_ret returns; a jr $ra to its own label goes on there, one to an outer call's return with its $sp returns from both, with another $sp it jumps; a host callee's return past its caller returns for it; host code jumped to returns to the link the run came through")
}
