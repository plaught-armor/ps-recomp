// The EE interpreter for whole functions: cpu.call and cpu.jump_unknown run
// an address no function is registered at here (cpu.interp_hook), so code
// the recompiler never saw, or a native blob that lacks a function, plays on
// instead of stopping. It follows the recompiled code's control flow
// (recomp/r5900/lower.odin): a call is a host call, `jr $ra` returns, and a
// jump to a registered function is a tail call to it. A learned function
// whose words RAM holds runs instead (learned.odin).
//
// A `jr $ra` returns from the run when $ra and sp are the run's own (its
// return address and the sp at its call). Else, to the return address of
// an outer interpreted call with that call's sp, it is a longjmp there (a
// throw that restored a catch frame's registers): the runs in between
// return, and the one that made the call goes on there
// (interp_unwind_find). Host code between them stops it: the `jr` returns
// as before (shown once under PS_DEBUG). One that no call returns to with
// that sp (a coroutine's resume, or a fiber switch one call down whose
// return address is another fiber's call's) is a jump there, the calls it
// is inside left open until a later `jr $ra` returns to one of them, when
// only the thread's start is host code under the run: else it may return
// to native code.
//
// A link branch or `jal` / `jalr` to its own return address (bal .+8, which
// reads the pc into $ra) only links: no call, as on the console.
package ps2

import "core:fmt"

import "ps:core"

import cpu "cpu"
import kernel "kernel"
import mem "mem"
import r5900 "r5900"

// Addresses already reported on stderr: host state, so each is reported
// once per process.
@(private = "file")
interp_seen: map[u32]bool

// The call an unwind returns to (interp_unwind_find): the runs above it
// return until the one that made it. Never set across a thread switch or an
// events check: not state.
@(private = "file")
interp_unwind: ^cpu.Interp_Frame

// The longjmps shown so far, each kind once under PS_DEBUG (a search past
// cpu.UNWIND_MAX once always): not state.
@(private = "file")
unwind_shown: bit_set[enum {Done, Native, Max, Jump, Under}]

@(private)
branch_taken :: proc(i: r5900.Insn) -> bool {
	c := &cpu.state
	s := i.rs == 0 ? 0 : i64(c.r[i.rs].d[0])
	t := i.rt == 0 ? 0 : i64(c.r[i.rt].d[0])
	#partial switch i.op {
	case .BEQ, .BEQL: return s == t
	case .BNE, .BNEL: return s != t
	case .BLEZ, .BLEZL: return s <= 0
	case .BGTZ, .BGTZL: return s > 0
	case .BLTZ, .BLTZL, .BLTZAL, .BLTZALL: return s < 0
	case .BGEZ, .BGEZL, .BGEZAL, .BGEZALL: return s >= 0
	case .BC1F, .BC1FL: return c.fcr31 & cpu.FCR31_C == 0
	case .BC1T, .BC1TL: return c.fcr31 & cpu.FCR31_C != 0
	}
	return bc_cond(i.w) // COP0/COP2 condition lines
}

// The delay slot at pc. A jump there is undefined on the R5900; exec_insn
// stops on it.
@(private)
delay_slot :: proc(pc: u32, lf: ^core.Learn_Frame) {
	cpu.state.cycles += cpu.CYCLES_PER_INSN
	i := r5900.decode(pc, mem.rd32(pc))
	if lf != nil {learn_note(lf, i)}
	if i.kind == .Bad {cpu.bad_insn(pc, i.w)}
	exec_insn(i)
}

// Continue at t from the instruction at pc: a registered function there
// takes over as a tail call (true: the caller returns), else the loop goes
// on at t, checking events on a backward jump as recompiled code does.
// With mods, a jump to a hooked function's entry runs its chain as a tail
// call, unless it is the entry of the run's own function: a loop, no call.
@(private = "file")
goto_pc :: proc(entry, pc, t: u32) -> bool {
	hooked := false
	if cpu.mod_on {
		site: int
		if site, hooked = mod_hooked(t); hooked && t != entry {
			mod_enter(site)
			return true
		}
	}
	if fn := hooked ? nil : cpu.lookup(t); fn != nil {
		fn()
		return true
	}
	if t <= pc && cpu.state.cycles >= cpu.next_event {kernel.run_events()}
	spin_step(pc, t)
	return false
}

interp_call :: proc(entry: u32) {
	// Learned code for the words RAM holds at entry now runs in place of the
	// interpreter (learned.odin).
	if fn := learned_find(entry); fn != nil {
		fn()
		return
	}
	interp_enter(entry)
	if cpu.state.cycles >= cpu.next_event {kernel.run_events()}
	if !core.learn_on(.Ee) {
		interp_body(entry, nil)
		return
	}
	f := core.learn_begin(.Ee, entry)
	f = interp_body(entry, f)
	if f != nil {core.learn_end(f)}
}

// What an interpreted call does first, before its events check: count it
// and say it is interpreted.
@(private)
interp_enter :: proc(entry: u32) {
	when cpu.FALLBACK_COUNT {
		if cpu.fallback_ee_calls == nil {
			cpu.fallback_ee_calls = make(map[u32]u64, core.long_allocator())
		}
		cpu.fallback_ee_calls[entry] += 1
	}
	when core.COMPAT_COUNT {core.compat_entry(entry)}
	if entry not_in interp_seen {
		if interp_seen == nil {interp_seen = make(map[u32]bool, core.long_allocator())}
		interp_seen[entry] = true
		fmt.eprintfln("ee: interpreting %08x (ra %08x): no function registered", entry, u32(cpu.state.r[31].d[0]))
	}
	if kernel.trace_on {kernel.trace_call(entry)}
}

// Note for LEARN (core/learn.odin) that the run fetched i, and where i
// stores if it is a store.
@(private)
learn_note :: proc(f: ^core.Learn_Frame, i: r5900.Insn) {
	core.learn_fetch(f, i.pc, i.w)
	#partial switch i.op {
	case .SB, .SH, .SW, .SD, .SQ, .SWC1, .SQC2, .SWL, .SWR, .SDL, .SDR:
		core.learn_store(f, u32(cpu.state.r[i.rs].d[0]) + u32(r5900.sx16(i.imm)))
	}
}

// The run from entry; lf is its LEARN frame, nil without LEARN. Returns
// the frame still to end: nil once a jump away cut it (core.learn_cut).
@(private = "file")
interp_body :: proc(entry: u32, lf_in: ^core.Learn_Frame) -> (lf: ^core.Learn_Frame) {
	lf = lf_in
	c := &cpu.state
	pc := entry
	// Its return address, and whether the call into it is the top record
	// (cpu.Interp_Frame), or with none, the thread's base: host code
	// between, such as native code, or a mod's chain, could be.
	ra, sp := u32(c.r[31].d[0]), u32(c.r[29].d[0])
	top := cpu.interp_top
	direct := !cpu.mod_on && (top == nil ? entry == cpu.interp_base : top.target == entry && top.ret == ra && top.sp == sp)
	for {
		i := r5900.decode(pc, mem.rd32(pc))
		if lf != nil {learn_note(lf, i)}
		c.cycles += cpu.CYCLES_PER_INSN
		ret := pc + 8
		switch i.kind {
		case .Alu:
			exec_insn(i)
			pc += 4
		case .Sys:
			exec_insn(i)
			if i.op == .ERET {return}
			pc += 4
		case .Bad:
			cpu.bad_insn(pc, i.w)
		case .Branch:
			taken := branch_taken(i)
			if i.link {c.r[31].d[0] = u64(ret)}
			if !i.likely || taken {delay_slot(pc + 4, lf)}
			if !taken {
				pc = ret
			} else if i.link {
				if i.target != ret && interp_calls(ret, i.target, direct) {return}
				pc = ret
			} else {
				if goto_pc(entry, pc, i.target) {return}
				pc = i.target
			}
		case .Jump:
			delay_slot(pc + 4, lf)
			if goto_pc(entry, pc, i.target) {return}
			pc = i.target
		case .Call:
			c.r[31].d[0] = u64(ret)
			delay_slot(pc + 4, lf)
			if i.target != ret && interp_calls(ret, i.target, direct) {return}
			pc = ret
		case .Jalr:
			t := u32(c.r[i.rs].d[0])
			if i.rd != 0 {c.r[i.rd].d[0] = u64(ret)}
			delay_slot(pc + 4, lf)
			if t != ret && interp_calls(ret, t, direct) {return}
			pc = ret
		case .Jr:
			t := u32(c.r[i.rs].d[0])
			delay_slot(pc + 4, lf)
			if i.rs == 31 {
				if t == ra && u32(c.r[29].d[0]) == sp || !interp_unwind_find(t, direct) {return}
				// A jump to another fiber's code: this run ends here
				// for LEARN, so none of that code is noted in it.
				if lf != nil {
					core.learn_cut(lf)
					lf = nil
				}
				if goto_pc(entry, pc, t) {return}
				pc = t
				continue
			}
			if c.cycles >= cpu.next_event {kernel.run_events()}
			if goto_pc(entry, pc, t) {return}
			pc = t
		}
	}
}

// The call to t from a run, which returns to ret; direct is the run's own
// (interp_body). True when an unwind goes on past it to an outer call: the
// run returns at once.
@(private = "file")
interp_calls :: #force_inline proc(ret, t: u32, direct: bool) -> bool {
	depth := cpu.interp_top == nil ? 1 : cpu.interp_top.depth + 1
	if depth > cpu.INTERP_DEPTH_MAX {
		cpu.fatal("ee: the call of %08x from %08x is past the limit of %d interpreted calls open at once (INTERP_DEPTH_MAX, the host stack's): calls whose callee jumped away and never returned", t, ret - 8, cpu.INTERP_DEPTH_MAX)
	}
	cpu.interp_max_depth = max(cpu.interp_max_depth, depth)
	fr := cpu.Interp_Frame {
		ret    = ret,
		sp     = u32(cpu.state.r[29].d[0]),
		target = t,
		depth  = depth,
		direct = direct,
		prev   = cpu.interp_top,
	}
	cpu.interp_top = &fr
	cpu.call(t)
	cpu.interp_top = fr.prev
	if interp_unwind == nil {return false}
	if interp_unwind != &fr {return true}
	interp_unwind = nil
	return false
}

// A `jr $ra` to t, not with the run's own return address and sp: the
// innermost of the cpu.UNWIND_MAX records above returning to t with the
// guest sp now is the call to unwind to (interp_unwind), when every run
// above it was called directly (direct, then each record's). A record that
// returns to t with another sp is no match. Else the `jr` returns as
// before, except when no record matches and every run down to the thread's
// base was called directly: true, a jump. With host code under a run, t
// may be a native caller's return address.
@(private = "file")
interp_unwind_find :: proc(t: u32, direct: bool) -> bool {
	sp := u32(cpu.state.r[29].d[0])
	ok := direct
	n := 0
	for f := cpu.interp_top; f != nil; f = f.prev {
		if n == cpu.UNWIND_MAX {
			if .Max not_in unwind_shown {
				unwind_shown += {.Max}
				fmt.eprintfln("ee: jr $ra to %08x: no call returns there in the %d innermost; returning as before", t, cpu.UNWIND_MAX)
			}
			return false
		}
		n += 1
		if f.ret == t && f.sp == sp {
			if !ok {
				if cpu.debug >= 1 && .Native not_in unwind_shown {
					unwind_shown += {.Native}
					fmt.eprintfln("ee: jr $ra to %08x: the call %d out returns there, past host code; returning as before", t, n)
				}
				return false
			}
			if cpu.debug >= 1 && .Done not_in unwind_shown {
				unwind_shown += {.Done}
				fmt.eprintfln("ee: jr $ra to %08x: unwound to the call %d out", t, n)
			}
			interp_unwind = f
			return false
		}
		ok = ok && f.direct
	}
	if !ok {
		if cpu.debug >= 1 && .Under not_in unwind_shown {
			unwind_shown += {.Under}
			fmt.eprintfln("ee: jr $ra to %08x: no call returns there, host code under the run; returning as before", t)
		}
		return false
	}
	if cpu.debug >= 1 && .Jump not_in unwind_shown {
		unwind_shown += {.Jump}
		fmt.eprintfln("ee: jr $ra to %08x: no call returns there; a jump", t)
	}
	return true
}
