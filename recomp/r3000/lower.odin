// A function lowered to steps, the one walk of its instructions that every
// backend (Odin source, native code) renders: blocks, delay slots, load
// delays, patch points and cycle charges are decided here, once.
package r3000

import "core:fmt"
import "core:slice"

Step_Kind :: enum u8 {
	Case,       // block at `target`; `check`: the previous block falls into it
	Trace,      // per-block trace hook for `target`
	Op,         // instruction `i` (no control transfer)
	Load_Delay, // load `i`, then `slot` sees the old value; `check`: rt gets the load
	Bad,        // reserved instruction `i`
	Cycles,     // charge `n` cycles
	Return,
	Patch,      // when `cond` holds, the steps up to the matching End
	Goto,       // pc = `target` within the function; `check`: run due events first
	Call,       // call the function at `target`
	Branch,     // t := the condition of branch `i`, up to the matching End
	Link,       // register `n` = `target` (a return address)
	If_Taken,   // when t, the steps up to the matching End
	Call_If,    // when t, call the function at `target`
	Jump_Reg,   // t := register `n`, up to the matching End
	Call_Reg,   // call the function at t
	Goto_Reg,   // pc = t within the function, after running due events
	End,
}

Step :: struct {
	kind:    Step_Kind,
	check:   bool,
	n:       u32,
	target:  u32,
	i, slot: Insn,
	cond:    string,
}

@(private = "file")
Lowering :: struct {
	f:         ^Func,
	insns:     map[u32]Insn, // f.insns decoded
	cycles:    int, // per instruction
	steps:     [dynamic]Step,
	open_case: bool, // current block can fall into the next label
	pending:   int, // instructions not yet charged
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
	if inside(l.f, t) && t in l.f.labels {
		put(l, {kind = .Goto, target = t, check = t <= src})
		return
	}
	put(l, {kind = .Call, target = t})
	put(l, {kind = .Return})
}

lower :: proc(f: ^Func, patches: []Patch, cycles: int) -> []Step {
	pcs := make([]u32, len(f.insns))
	n := 0
	for pc in f.insns {
		pcs[n] = pc
		n += 1
	}
	slice.sort(pcs)
	l := Lowering {
		f      = f,
		cycles = cycles,
	}
	defer delete(l.insns)
	for pc, i in f.insns {
		l.insns[pc] = decode(pc, i.w)
	}
	skip_delay: Set
	for idx := 0; idx < len(pcs); {
		pc := pcs[idx]
		idx += 1
		i := l.insns[pc]
		if pc in skip_delay {
			continue
		}
		if pc in f.labels {
			if l.open_case {
				flush(&l)
			}
			put(&l, {kind = .Case, target = pc, check = l.open_case})
			put(&l, {kind = .Trace, target = pc})
			l.open_case = true
		} else if !l.open_case {
			// Unreachable by fallthrough and unlabelled: only a delay slot can
			// get here.
			continue
		}
		for p in patches {
			if p.at != pc {
				continue
			}
			if p.target not_in f.labels {
				append(&f.warnings, fmt.aprintf("patch target %s is not a label", hexu(p.target)))
			} else {
				flush(&l)
				put(&l, {kind = .Patch, cond = p.cond})
				goto_(&l, pc, p.target)
				put(&l, {kind = .End})
			}
		}
		l.pending += 1

		if i.kind == .Alu || i.kind == .Sys || i.kind == .Bad {
			// The last instruction i stands for: a fused pair ends at pc + 4.
			last := pc
			if p, ok := fuse_pair(&l, i, patches); ok {
				i = p
				last = pc + 4
				l.pending += 1
				idx += 1
			}
			// Load delay: the next instruction still sees the old register
			// value.
			nxt, has_next := l.insns[last + 4]
			if i.is_load && i.writes != {} && has_next && last + 4 not_in f.labels && !has_delay(nxt) && last + 4 not_in skip_delay {
				rt := 0
				for r in i.writes {
					rt = r
				}
				lwlr_pair := (i.op == 0x22 || i.op == 0x26) && (nxt.op == 0x22 || nxt.op == 0x26) && int(nxt.rt) == rt
				if (rt in nxt.reads || rt in nxt.writes) && !lwlr_pair {
					// The slot instruction reads the old value. If it also
					// writes rt, its write wins and the loaded value is lost
					// (the load still happens: I/O reads have side effects).
					put(&l, {kind = .Load_Delay, i = i, slot = nxt, check = rt not_in nxt.writes})
					l.pending += 1
					idx += 1
					continue
				}
			}
			if i.kind == .Bad {
				put(&l, {kind = .Bad, i = i})
				flush(&l)
				put(&l, {kind = .Return})
				l.open_case = false
				continue
			}
			put(&l, {kind = .Op, i = i})
			if is_break_1(i) {
				flush(&l)
				put(&l, {kind = .Return})
				l.open_case = false
			}
			continue
		}

		// control transfer with delay slot
		d, has_d := l.insns[pc + 4]
		slot_op := false
		if has_d {
			if has_delay(d) {
				append(&f.warnings, fmt.aprintf("branch in delay slot at %s", hexu(pc + 4)))
			} else {
				slot_op = true
				l.pending += 1
			}
		}
		skip_delay[pc + 4] = {}
		ret := pc + 8
		delay :: proc(l: ^Lowering, d: Insn, slot_op: bool) {
			if slot_op {
				put(l, {kind = .Op, i = d})
			}
			flush(l)
		}

		#partial switch i.kind {
		case .Branch:
			link := i.op == 1 && i.rt & 0x1e == 0x10
			put(&l, {kind = .Branch, i = i})
			if link {
				put(&l, {kind = .Link, n = 31, target = ret})
			}
			delay(&l, d, slot_op)
			if link {
				put(&l, {kind = .Call_If, target = i.target})
			} else {
				put(&l, {kind = .If_Taken})
				goto_(&l, pc, i.target)
				put(&l, {kind = .End})
			}
			put(&l, {kind = .End})
			if !link && branch_always(i) {
				l.open_case = false
			}
		case .Jump:
			delay(&l, d, slot_op)
			goto_(&l, pc, i.target)
			l.open_case = false
		case .Call:
			put(&l, {kind = .Link, n = 31, target = ret})
			delay(&l, d, slot_op)
			put(&l, {kind = .Call, target = i.target})
		case .Jalr:
			put(&l, {kind = .Jump_Reg, n = i.rs})
			if i.rd != 0 {
				put(&l, {kind = .Link, n = i.rd, target = ret})
			}
			delay(&l, d, slot_op)
			put(&l, {kind = .Call_Reg})
			put(&l, {kind = .End})
		case .Jr:
			if i.rs == 31 {
				delay(&l, d, slot_op)
				put(&l, {kind = .Return})
			} else {
				put(&l, {kind = .Jump_Reg, n = i.rs})
				delay(&l, d, slot_op)
				put(&l, {kind = .Goto_Reg})
				put(&l, {kind = .End})
			}
			l.open_case = false
		}

		if pc + 4 in f.labels && has_d {
			// The delay slot is itself a jump target: give it its own block.
			if l.open_case {
				flush(&l)
				put(&l, {kind = .Goto, target = pc + 8})
			}
			if has_delay(d) {
				// A branch there (data decoded as code, as a rule) is a
				// no-op in the slot: the loop lowers it as its own block,
				// which nothing falls into.
				delete_key(&skip_delay, pc + 4)
				l.open_case = false
			} else {
				put(&l, {kind = .Case, target = pc + 4})
				put(&l, {kind = .Trace, target = pc + 4})
				put(&l, {kind = .Op, i = d})
				l.pending += 1
				l.open_case = true
			}
		}
	}

	if l.open_case {
		flush(&l)
		put(&l, {kind = .Call, target = f.end})
		put(&l, {kind = .Return})
	}
	return l.steps[:]
}

// lwl rt, off+3(rs) then lwr rt, off(rs) (or swl then swr) is a word at
// off(rs) that need not be aligned: one access, as cpu.lw_u and cpu.sw_u.
// Not when the lwr is a block label or has a patch (it is entered or left
// on its own), nor for a load with rs == rt: the lwl's write would move
// the lwr's address. That guard also keeps rt out of the second op's
// address.
@(private = "file")
fuse_pair :: proc(l: ^Lowering, i: Insn, patches: []Patch) -> (Insn, bool) {
	if i.op != 0x22 && i.op != 0x2a {
		return {}, false
	}
	pc := i.pc + 4
	nxt, ok := l.insns[pc]
	if !ok || nxt.op != i.op + 4 || nxt.rs != i.rs || nxt.rt != i.rt || sx16(i.imm) != sx16(nxt.imm) + 3 {
		return {}, false
	}
	if i.is_load && i.rs == i.rt {
		return {}, false
	}
	if pc in l.f.labels {
		return {}, false
	}
	for p in patches {
		if p.at == pc {return {}, false}
	}
	p := nxt
	p.pair = true
	if p.is_load {p.reads = {int(p.rs)} - {0}}
	return p, true
}

// beq r, r: the branch is always taken.
branch_always :: proc(i: Insn) -> bool {
	return i.op == 4 && i.rs == i.rt
}
