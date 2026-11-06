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
	imports()
	exact_steps()
	fmt.println("ok lower:", len(r5900_firsts), "r5900 and", len(r3000_firsts), "r3000 branches with a branch in a jump-target delay slot; beql cycles; import placeholders; exact steps")
}

// The function of `words` at `base`, discovered with the r5900 rules.
@(private = "file")
func_of :: proc(base: u32, words: []u32) -> ^mips.Func {
	data := make([]u8, len(words) * 4, context.temp_allocator)
	for w, k in words {
		data[4 * k], data[4 * k + 1], data[4 * k + 2], data[4 * k + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
	}
	f := mips.func_make(base, base + u32(len(data)))
	mips.discover(r5900.RULES, {base = base, data = data}, f, {})
	return f
}

// r5900.drop_imports: in an image with a `jal 0` placeholder, both the
// function that holds it and a `lui r,0` leaf (a data import) go to the
// interpreter; in an image without one, the `lui r,0` leaf stays compiled.
@(private = "file")
imports :: proc() {
	call := func_of(0x1000, {0x0c000000, 0, 0x03e00008, 0}) // jal 0; nop; jr ra; nop
	leaf := func_of(0x2000, {0x3c020000, 0x03e00008, 0x8c420000}) // lui v0,0; jr ra; lw v0,0(v0)
	plain := func_of(0x3000, {0x03e00008, 0}) // jr ra; nop
	with: [dynamic]^mips.Func
	append(&with, call, leaf, plain)
	if n := r5900.drop_imports(&with, true); n != 2 || len(with) != 1 || with[0] != plain {
		fmt.eprintfln("FAIL r5900 drop_imports: %d dropped, %d kept, from an image with jal 0", n, len(with))
		os.exit(1)
	}
	without: [dynamic]^mips.Func
	append(&without, leaf, plain)
	if n := r5900.drop_imports(&without, true); n != 0 || len(without) != 2 {
		fmt.eprintfln("FAIL r5900 drop_imports: %d dropped from an image without jal 0", n)
		os.exit(1)
	}
	delete(with)
	delete(without)
	free_all(context.temp_allocator)
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

// One step as exact_steps writes it: an Op by its instruction's pc.
@(private = "file")
Want :: struct {
	kind:      r5900.Step_Kind,
	check:     bool,
	n, target: u32,
	pc:        u32,
}

// r5900.lower's exact mode (wasm32 native code, a step of the FLAT
// runner), step by step:
//
//   0x1000  jal 0x2000
//   0x1004  nop
//   0x1008  syscall                 the runner comes back here after the jal
//   0x100c  jalr $t0                and here after the syscall
//   0x1010  nop
//   0x1014  beql $a0, $0, 0x102c    and here after the jalr
//   0x1018  addiu $v0, $v0, 1
//   0x101c  bne $a1, $0, 0x1008     a block (beql's not taken); backward: events first
//   0x1020  nop
//   0x1024  jr $t0                  a block (bne's not taken); a Goto_Reg
//   0x1028  nop
//   0x102c  jr $ra                  its target read before the delay slot
//   0x1030  nop
//
// Each instruction's cycles just before it (a delay slot's inside the
// slot, a likely one's only when taken), a block with n = 1 after each
// call and the SYSCALL, and the branches as Gotos.
@(private = "file")
exact_steps :: proc() {
	f := func_of(0x1000, {0x0c000800, 0, 0x0000000c, 0x0100f809, 0, 0x50800005, 0x24420001, 0x14a0fffa, 0, 0x01000008, 0, 0x03e00008, 0})
	want := [?]Want {
		{kind = .Case, target = 0x1000},
		{kind = .Cycles, n = 1},
		{kind = .Link, n = 31, target = 0x1008},
		{kind = .Cycles, n = 1},
		{kind = .Op, pc = 0x1004},
		{kind = .Call, target = 0x2000, n = 0x1008},
		{kind = .Case, target = 0x1008, check = true, n = 1},
		{kind = .Cycles, n = 1},
		{kind = .Op, pc = 0x1008},
		{kind = .Case, target = 0x100c, check = true, n = 1},
		{kind = .Cycles, n = 1},
		{kind = .Jump_Reg, n = 8},
		{kind = .Link, n = 31, target = 0x1014},
		{kind = .Cycles, n = 1},
		{kind = .Op, pc = 0x1010},
		{kind = .Call_Reg, n = 0x1014},
		{kind = .End},
		{kind = .Case, target = 0x1014, check = true, n = 1},
		{kind = .Cycles, n = 1},
		{kind = .Branch, pc = 0x1014},
		{kind = .If_Taken},
		{kind = .Cycles, n = 1},
		{kind = .Op, pc = 0x1018},
		{kind = .Goto, target = 0x102c, n = 0x1014},
		{kind = .End},
		{kind = .End},
		{kind = .Case, target = 0x101c, check = true},
		{kind = .Cycles, n = 1},
		{kind = .Branch, pc = 0x101c},
		{kind = .Cycles, n = 1},
		{kind = .Op, pc = 0x1020},
		{kind = .If_Taken},
		{kind = .Goto, target = 0x1008, check = true, n = 0x101c},
		{kind = .End},
		{kind = .End},
		{kind = .Case, target = 0x1024, check = true},
		{kind = .Cycles, n = 1},
		{kind = .Jump_Reg, n = 8},
		{kind = .Cycles, n = 1},
		{kind = .Op, pc = 0x1028},
		{kind = .Goto_Reg, n = 0x1024},
		{kind = .End},
		{kind = .Case, target = 0x102c},
		{kind = .Cycles, n = 1},
		{kind = .Jump_Reg, n = 31},
		{kind = .Cycles, n = 1},
		{kind = .Op, pc = 0x1030},
		{kind = .Return},
		{kind = .End},
	}
	steps := r5900.lower(f, 1, true, exact = true)
	got := make([]Want, len(steps), context.temp_allocator)
	for s, k in steps {
		got[k] = {kind = s.kind, check = s.check, n = s.n, target = s.target}
		if s.kind == .Op || s.kind == .Branch {got[k].pc = s.i.pc}
	}
	for k in 0 ..< max(len(got), len(want)) {
		if k < len(got) && k < len(want) && got[k] == want[k] {continue}
		fmt.eprintfln("FAIL r5900 exact lower: step %d of %d (want %d)", k, len(got), len(want))
		for g, j in got {fmt.eprintfln("  %d %v", j, g)}
		os.exit(1)
	}
	free_all(context.temp_allocator)
}
