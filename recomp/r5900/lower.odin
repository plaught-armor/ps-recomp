// A function lowered to steps, the one walk of its instructions that every
// backend (Odin source, native code) renders: blocks, delay slots, likely
// branches and cycle charges are decided here, once.
package r5900

import "core:fmt"

Step_Kind :: enum u8 {
	Case,     // block at `target`; `check`: the previous block falls into it; `n`: 1 where the runner goes on (exact: every block)
	Op,       // instruction `i` (no control transfer)
	Cycles,   // charge `n` cycles
	Return,   // exact: t = the address `jr $ra` jumps to; `check`: ERET's instead
	Goto,     // pc = `target` within the function (exact: or outside it); `check`: run due events first; `n`: the jump's pc
	Call,     // call the function at `target`, returning to `n`
	Branch,   // t := the condition of branch `i`, up to the matching End
	Link,     // register `n` = `target` (a return address)
	If_Taken, // when t, the steps up to the matching End
	Jump_Reg, // t := register `n`, up to the matching End
	Call_Reg, // call the function at t, returning to `n`
	Goto_Reg, // pc = t within the function, after running due events; `n`: the jr's pc
	End,
}

Step :: struct {
	kind:   Step_Kind,
	check:  bool,
	n:      u32,
	target: u32,
	i:      Insn,
}

@(private = "file")
Lowering :: struct {
	f:         ^Func,
	cycles:    int, // per instruction
	steps:     [dynamic]Step,
	open_case: bool, // current block can fall into the next label
	pending:   int, // instructions not yet charged
	// Each instruction charged as the interpreter does it, just before it
	// runs, and each place the code can be left and gone on at a block
	// (lower's exact).
	exact:     bool,
	resume:    map[u32]bool, // exact: a block after each call and SYSCALL, also where no branch targets
}

// A block starts at pc.
@(private = "file")
is_label :: proc(l: ^Lowering, pc: u32) -> bool {
	return pc in l.f.labels || pc in l.resume
}

// Charge the instruction about to be put; exact puts its cycles now, else
// they wait for the next flush.
@(private = "file")
charge :: proc(l: ^Lowering) {
	if l.exact {
		put(l, {kind = .Cycles, n = u32(l.cycles)})
	} else {
		l.pending += 1
	}
}

@(private = "file")
put :: proc(l: ^Lowering, s: Step) {
	append(&l.steps, s)
}

@(private = "file")
flush :: proc(l: ^Lowering) {
	if l.pending != 0 {
		put(l, {kind = .Cycles, n = u32(l.pending * l.cycles)})
		l.pending = 0
	}
}

// Transfer control to t from instruction src.
@(private = "file")
goto_ :: proc(l: ^Lowering, src, t: u32) {
	if l.exact || t >= l.f.start && t < l.f.end && is_label(l, t) {
		put(l, {kind = .Goto, target = t, check = t <= src, n = src})
		return
	}
	put(l, {kind = .Call, target = t, n = src + 8})
	put(l, {kind = .Return})
}

// The steps of f, in context.temp_allocator. With exact (wasm32 native
// code, which leaves the function wherever the interpreter's FLAT runner
// takes over): cycles per instruction in the interpreter's order, a block
// after each call and each SYSCALL (where the runner comes back in), every
// block a place the runner goes on at (n = 1: a label is where a due-events
// exit leaves and where the interpreter's jumps land, and both go on in
// native code there only if the block is an entry), a jump
// out of the function as a Goto, and the address `jr $ra` jumps to read
// before its delay slot. nil when exact cannot lower f: a SYSCALL, BREAK or
// ERET in a delay slot.
lower :: proc(f: ^Func, cycles: int, quiet: bool, exact := false) -> []Step {
	pcs := make([dynamic]u32, 0, len(f.insns), context.temp_allocator)
	for a in f.insns {append(&pcs, a)}
	sort_u32(pcs[:])
	l := Lowering {
		f      = f,
		cycles = cycles,
		steps  = make([dynamic]Step, 0, 2 * len(f.insns), context.temp_allocator),
		exact  = exact,
	}
	l.resume.allocator = context.temp_allocator
	if exact {
		for pc in pcs {
			i := decode(pc, f.insns[pc].w)
			at := u32(0)
			if i.kind == .Call || i.kind == .Jalr || i.kind == .Branch && i.link {
				at = pc + 8
			} else if i.op == .SYSCALL {
				at = pc + 4
			}
			if at != 0 && at in f.insns && at not_in f.delay {l.resume[at] = true}
		}
	}
	skip: map[u32]bool
	skip.allocator = context.temp_allocator
	for pc in pcs {
		i := decode(pc, f.insns[pc].w)
		if pc in skip {continue}
		if is_label(&l, pc) {
			if l.open_case {flush(&l)}
			put(&l, {kind = .Case, target = pc, check = l.open_case, n = 1 if l.exact else 0})
			l.open_case = true
		} else if !l.open_case {
			continue // unreachable except as a delay slot
		}
		charge(&l)

		if !has_delay(i) {
			put(&l, {kind = .Op, i = i})
			if i.kind == .Bad || i.op == .ERET {
				flush(&l)
				put(&l, {kind = .Return, check = exact && i.op == .ERET})
				l.open_case = false
			}
			continue
		}

		// control transfer with a delay slot
		dw, has_d := f.insns[pc + 4]
		d := decode(pc + 4, dw.w)
		slot_op := false
		if has_d {
			if has_delay(d) {
				if !quiet {fmt.eprintfln("warning %s: branch in delay slot at %s", hexu(f.entry), hexu(pc + 4))}
			} else {
				if exact && d.kind == .Sys {return nil}
				slot_op = true
				if !exact {l.pending += 1}
			}
		}
		skip[pc + 4] = true
		ret := pc + 8
		delay :: proc(l: ^Lowering, d: Insn, slot_op: bool) {
			if slot_op {
				if l.exact {put(l, {kind = .Cycles, n = u32(l.cycles)})}
				put(l, {kind = .Op, i = d})
			}
			flush(l)
		}
		taken :: proc(l: ^Lowering, i: Insn) {
			if i.link {
				put(l, {kind = .Call, target = i.target, n = i.pc + 8})
			} else {
				goto_(l, i.pc, i.target)
			}
		}

		#partial switch i.kind {
		case .Branch:
			put(&l, {kind = .Branch, i = i})
			if i.link {put(&l, {kind = .Link, n = 31, target = ret})}
			if i.likely {
				// delay slot only when taken; the branch and everything
				// before it count on both paths
				if slot_op && !exact {l.pending -= 1}
				flush(&l)
				if slot_op && !exact {l.pending += 1}
				put(&l, {kind = .If_Taken})
				delay(&l, d, slot_op)
				taken(&l, i)
			} else {
				delay(&l, d, slot_op)
				put(&l, {kind = .If_Taken})
				taken(&l, i)
			}
			put(&l, {kind = .End})
			put(&l, {kind = .End})
			if branch_always(i) && !i.link {l.open_case = false}
		case .Jump:
			delay(&l, d, slot_op)
			goto_(&l, pc, i.target)
			l.open_case = false
		case .Call:
			put(&l, {kind = .Link, n = 31, target = ret})
			delay(&l, d, slot_op)
			put(&l, {kind = .Call, target = i.target, n = ret})
		case .Jalr:
			put(&l, {kind = .Jump_Reg, n = u32(i.rs)})
			if i.rd != 0 {put(&l, {kind = .Link, n = u32(i.rd), target = ret})}
			delay(&l, d, slot_op)
			put(&l, {kind = .Call_Reg, n = ret})
			put(&l, {kind = .End})
		case .Jr:
			if i.rs == 31 && exact {
				put(&l, {kind = .Jump_Reg, n = 31})
				delay(&l, d, slot_op)
				put(&l, {kind = .Return})
				put(&l, {kind = .End})
			} else if i.rs == 31 {
				delay(&l, d, slot_op)
				put(&l, {kind = .Return})
			} else {
				put(&l, {kind = .Jump_Reg, n = u32(i.rs)})
				delay(&l, d, slot_op)
				put(&l, {kind = .Goto_Reg, n = pc})
				put(&l, {kind = .End})
			}
			l.open_case = false
		}

		if (pc + 4) in f.labels && has_d {
			// The delay slot is itself a jump target: give it its own block.
			if l.open_case {
				flush(&l)
				put(&l, {kind = .Goto, target = pc + 8})
			}
			if has_delay(d) {
				// A branch there (data decoded as code, as a rule) is a
				// no-op in the slot: the loop lowers it as its own block,
				// which nothing falls into.
				delete_key(&skip, pc + 4)
				l.open_case = false
			} else {
				put(&l, {kind = .Case, target = pc + 4})
				if exact {put(&l, {kind = .Cycles, n = u32(l.cycles)})}
				put(&l, {kind = .Op, i = d})
				if !exact {l.pending += 1}
				l.open_case = true
			}
		}
	}
	if l.open_case && exact {
		put(&l, {kind = .Goto, target = f.end})
	} else if l.open_case {
		flush(&l)
		put(&l, {kind = .Call, target = f.end})
		put(&l, {kind = .Return})
	}
	return l.steps[:]
}

// The branch is always taken: beq r, r or bgez $zero (and their forms).
branch_always :: proc(i: Insn) -> bool {
	#partial switch i.op {
	case .BEQ, .BEQL:
		return i.rs == i.rt
	case .BGEZ, .BGEZL, .BGEZAL, .BGEZALL:
		return i.rs == 0
	}
	return false
}
