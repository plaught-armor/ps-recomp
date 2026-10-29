// r5900.lower and r3000.lower on a hand-built function: a delay slot that is
// a jump target and holds a branch, run on every target in CI.
//
//   0x1000  X                      beq, beql (bne on r3000) or jal: its delay
//                                  slot is 0x1004
//   0x1004  bne $a1, $0, 0x1010    a label, and the delay slot of X
//   0x1008  beq $a2, $0, 0x1010    the delay slot of 0x1004
//   0x100c  addiu $v0, $v0, 1      the delay slot of 0x1008
//   0x1010  jr $ra
//   0x1014  nop
//
// A branch in a delay slot is a no-op there, so after X (not taken, or
// returned from) the code goes on at 0x1008, not 0x1004; the branches at
// 0x1004 and 0x1008 run only as blocks of their own, never as an Op.
package main

import "core:fmt"
import "core:os"
import "ps:recomp/mips"
import "ps:recomp/r3000"
import "ps:recomp/r5900"

@(private = "file")
fail :: proc(cpu: string, x: u32, what: string) -> ! {
	fmt.eprintfln("FAIL %s lower (%08x at 0x1000): %s", cpu, x, what)
	os.exit(1)
}

// The function with `x` at 0x1000, discovered with `rules`.
@(private = "file")
build :: proc(cpu: string, x: u32, rules: mips.Rules) -> ^mips.Func {
	words := [?]u32{x, 0x14a00002, 0x10c00001, 0x24420001, 0x03e00008, 0}
	data: [len(words) * 4]u8
	for w, k in words {
		data[4 * k], data[4 * k + 1], data[4 * k + 2], data[4 * k + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
	}
	f := mips.func_make(0x1000, 0x1018)
	// 0x1004 labelled as a jump target from elsewhere; discover labels
	// 0x1008 and 0x100c, the successors of labelled delay slots.
	mips.discover(rules, {base = 0x1000, data = data[:]}, f, {0x1004})
	for a in ([?]u32{0x1004, 0x1008, 0x100c}) {if a not_in f.labels {fail(cpu, x, fmt.tprintf("discover left %x unlabelled", a))}}
	return f
}

// The blocks at 0x1004 and 0x1008 come after a goto past them, each lowers
// its branch, and no Op holds a branch.
@(private = "file")
check :: proc(cpu: string, x: u32, steps: []$S, has_delay: proc(i: $I) -> bool) {
	cases, branches := 0, 0
	for s, k in steps {
		if s.kind == .Branch && (s.i.pc == 0x1004 || s.i.pc == 0x1008) {branches += 1}
		if s.kind == .Op && has_delay(s.i) {fail(cpu, x, fmt.tprintf("branch at %x as an Op", s.i.pc))}
		if s.kind != .Case || (s.target != 0x1004 && s.target != 0x1008) {continue}
		cases += 1
		if s.check {fail(cpu, x, fmt.tprintf("falls into the branch at %x", s.target))}
		if k == 0 || steps[k - 1].kind != .Goto || steps[k - 1].target != s.target + 4 {
			fail(cpu, x, fmt.tprintf("no goto %x before the block at %x", s.target + 4, s.target))
		}
	}
	if cases != 2 {fail(cpu, x, "a block for 0x1004 or 0x1008 is missing")}
	if branches != 2 {fail(cpu, x, "the branch at 0x1004 or 0x1008 is dropped")}
}

main :: proc() {
	r5900_firsts := [?]u32 {
		0x10800003, // beq $a0, $0, 0x1010
		0x50800003, // beql $a0, $0, 0x1010
		0x0c000800, // jal 0x2000
	}
	for x in r5900_firsts {
		check("r5900", x, r5900.lower(build("r5900", x, r5900.RULES), 1, true), r5900.has_delay)
		free_all(context.temp_allocator)
	}
	r3000_firsts := [?]u32 {
		0x10800003, // beq $a0, $0, 0x1010
		0x14800003, // bne $a0, $0, 0x1010
		0x0c000800, // jal 0x2000
	}
	for x in r3000_firsts {
		check("r3000", x, r3000.lower(build("r3000", x, r3000.RULES), nil, 1), r3000.has_delay)
		free_all(context.temp_allocator)
	}
	likely_cycles()
	fmt.println("ok lower:", len(r5900_firsts), "r5900 and", len(r3000_firsts), "r3000 branches with a branch in a jump-target delay slot; beql cycles")
}

// A likely branch charges what comes before it and itself on both paths,
// and its delay slot only when taken:
//
//   0x1000  addiu $v0, $v0, 1
//   0x1004  beql $a0, $0, 0x100c
//   0x1008  addiu $v0, $v0, 1      the delay slot
//   0x100c  jr $ra
//   0x1010  nop
@(private = "file")
likely_cycles :: proc() {
	words := [?]u32{0x24420001, 0x50800001, 0x24420001, 0x03e00008, 0}
	data: [len(words) * 4]u8
	for w, k in words {
		data[4 * k], data[4 * k + 1], data[4 * k + 2], data[4 * k + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
	}
	f := mips.func_make(0x1000, 0x1014)
	mips.discover(r5900.RULES, {base = 0x1000, data = data[:]}, f, {})
	// Cycles charged before the If_Taken, and inside it.
	before, taken, depth := 0, 0, 0
	for s in r5900.lower(f, 1, true) {
		#partial switch s.kind {
		case .If_Taken: depth = 1
		case .End: if depth == 1 {depth = 2}
		case .Cycles:
			switch depth {
			case 0: before += int(s.n)
			case 1: taken += int(s.n)
			}
		}
	}
	free_all(context.temp_allocator)
	if before != 2 || taken != 1 {
		fmt.eprintfln("FAIL r5900 beql cycles: %d before the branch (want 2), %d in the delay slot (want 1)", before, taken)
		os.exit(1)
	}
}
