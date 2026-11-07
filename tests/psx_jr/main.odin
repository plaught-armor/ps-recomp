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
// Each case is told apart by v0 and by the unwinds and jumps counted.
// Runs on both builds: natively, and with -define:PS_FLAT=true.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import _ "ps:psx" // the PS1 hooks: interp_run among them
import cpu "ps:psx/cpu"

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
	cpu.register_funcs({}) // no recompiled code: every function interpreted
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

	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok psx_jr: jr is a plain jump, only one to frame_ret returns; a jr $ra to its own label goes on there, one to an outer call's return with its $sp returns from both, with another $sp it jumps")
}
