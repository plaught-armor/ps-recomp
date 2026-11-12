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
// (interp_unwind_find). Native code between them returns at once too
// (cpu.unwinding). A learned function called to return there with that sp
// is such a call too, whoever made it (learned code's calls leave no
// record): the runs in between return, and it returns to its caller
// (learned_unwind). Host code's call (cpu.host_call: a handler's, a
// syscall's) stops it: the `jr` returns as before (shown once under
// PS_DEBUG). One that no call returns to with that sp (a coroutine's
// resume, or a fiber switch one call down whose return address is another
// fiber's call's) is a jump there, the calls it is inside left open until a
// later `jr $ra` returns to one of them, with no host code's call under the
// run, and at most cpu.NATIVE_STALE_MAX gaps of native code left open
// under it.
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

// The learned function's run an unwind returns to (interp_unwind_find),
// when it is no interpreted call: the runs above it return, and it returns
// to its caller, which goes on (learned_left). Never set with
// interp_unwind, nor across a thread switch or an events check: not state.
@(private = "file")
learned_unwind: ^cpu.Learned_Run

// The longjmps shown so far, each kind once under PS_DEBUG (a search past
// cpu.UNWIND_MAX once always): not state.
@(private = "file")
unwind_shown: bit_set[enum {Done, Learned, Native, Max, Jump, Under, Stale}]

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
		lr := cpu.Learned_Run{interp_run(entry), entry, cpu.learned_top}
		cpu.learned_top = &lr
		fn()
		cpu.learned_top = lr.prev
		return
	}
	interp_enter(entry)
	if cpu.state.cycles >= cpu.next_event {kernel.run_events()}
	run := interp_run(entry)
	if !core.learn_on(.Ee) {
		interp_body(entry, nil, run, entry)
		return
	}
	f := core.learn_begin(.Ee, entry)
	f = interp_body(entry, f, run, entry)
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

// The facts of the run called at entry, taken at its call (cpu.Interp_Run).
@(private = "file")
interp_run :: proc(entry: u32) -> cpu.Interp_Run {
	ra, sp := u32(cpu.state.r[31].d[0]), u32(cpu.state.r[29].d[0])
	top := cpu.interp_top
	tight := top == nil ? entry == cpu.interp_base : !top.barrier && top.target == entry && top.ret == ra && top.sp == sp
	return {ra = ra, sp = sp, gaps = (top == nil ? 0 : top.gaps) + (tight ? 0 : 1), direct = !cpu.mod_on && (top == nil || !top.barrier)}
}

// A learned function's `jr $ra` at pc, before it returns (recomp/r5900
// native.odin): one to another address than its own return address with
// another sp is an interpreted run's (interp_body), with the function's run.
// An unwind to an outer call returns from it at once (cpu.unwinding); a
// jump interprets on from there, in the learned function's place, and
// returns when that run does: an unwind to this function's own call that
// comes back through that run ends here, as the function returns. Under
// FLAT, which never runs learned code, and from code no interp_call
// entered, nothing.
learned_jr :: proc(pc: u32) {
	learned_return(pc, u32(cpu.state.r[31].d[0]))
}

// learned_jr where the delay slot may have written $ra: t is $ra as it was
// before the slot, the address interp_body's `jr` jumps to. sp is read
// after the slot by both.
learned_jr_to :: proc(pc, t: u32) {
	learned_return(pc, t)
}

@(private = "file")
learned_return :: #force_inline proc(pc, t: u32) {
	lr := cpu.learned_top
	if lr == nil {return}
	if t == lr.ra && u32(cpu.state.r[29].d[0]) == lr.sp || !interp_unwind_find(t, lr.direct, lr.gaps) {return}
	if !goto_pc(lr.entry, pc, t) {interp_body(lr.entry, nil, lr.run, t)}
	learned_left()
}

// Learned code goes on at t from the instruction at pc, where its function's
// words hold no code it can jump to: past the last word, or at one no path
// through them reached (recomp/r5900 native_func). The code there goes on
// in the function's own run, as the interpreter would have from the entry:
// no call is made, so the run's `jr $ra` is the function's, and no events
// are checked but a backward jump's. Code learned at t runs it, entered
// with the function's run still the top one; it checks events as it is
// entered, so with one due the interpreter runs it instead, which also
// notes it under LEARN as a run from t, for the next blob. From code no
// interp_call entered, a call, as before.
learned_goto :: proc(pc, t: u32) {
	lr := cpu.learned_top
	if lr == nil {
		cpu.call(t)
		return
	}
	if !goto_pc(lr.entry, pc, t) {
		if fn := cpu.state.cycles < cpu.next_event ? learned_find(t) : nil; fn != nil {
			fn()
		} else {
			f := core.learn_on(.Ee) ? core.learn_begin(.Ee, t) : nil
			f = interp_body(lr.entry, f, lr.run, t)
			if f != nil {core.learn_end(f)}
		}
	}
	learned_left()
}

// A learned function leaves, an unwind under way (cpu.unwinding: its code
// calls this on that path alone, recomp/r5900 native_func, so a call that
// returns runs nothing more): when the unwind is to this function's own
// call, it ends here, and the function returns to its caller as from any
// call. From code no interp_call entered, nothing.
learned_left :: proc() {
	if learned_unwind == nil || learned_unwind != cpu.learned_top {return}
	learned_unwind = nil
	cpu.unwinding = false
}

// The run of the function at entry (run, from interp_run), from pc; lf is
// its LEARN frame, nil without LEARN. Returns the frame still to end: nil
// once a jump away cut it (core.learn_cut).
@(private = "file")
interp_body :: proc(entry: u32, lf_in: ^core.Learn_Frame, run: cpu.Interp_Run, start: u32) -> (lf: ^core.Learn_Frame) {
	lf = lf_in
	c := &cpu.state
	pc := start
	ra, sp, direct, gaps := run.ra, run.sp, run.direct, run.gaps
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
				if i.target != ret && interp_calls(ret, i.target, direct, gaps) {return}
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
			if i.target != ret && interp_calls(ret, i.target, direct, gaps) {return}
			pc = ret
		case .Jalr:
			t := u32(c.r[i.rs].d[0])
			if i.rd != 0 {c.r[i.rd].d[0] = u64(ret)}
			delay_slot(pc + 4, lf)
			if t != ret && interp_calls(ret, t, direct, gaps) {return}
			pc = ret
		case .Jr:
			t := u32(c.r[i.rs].d[0])
			delay_slot(pc + 4, lf)
			if i.rs == 31 {
				if t == ra && u32(c.r[29].d[0]) == sp || !interp_unwind_find(t, direct, gaps) {return}
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

// The call to t from a run, which returns to ret; direct and gaps are the
// run's own (interp_body). True when an unwind goes on past it to an outer call: the
// run returns at once.
@(private = "file")
interp_calls :: #force_inline proc(ret, t: u32, direct: bool, gaps: u32) -> bool {
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
		gaps   = gaps,
		direct = direct,
		prev   = cpu.interp_top,
	}
	cpu.interp_top = &fr
	cpu.call(t)
	cpu.interp_top = fr.prev
	if !cpu.unwinding {return false}
	if interp_unwind != &fr {return true}
	interp_unwind = nil
	cpu.unwinding = false
	return false
}

// A `jr $ra` to t, not with the run's own return address and sp: the
// innermost of the cpu.UNWIND_MAX records above returning to t with the
// guest sp now is the call to unwind to (interp_unwind), when every run
// above it has no host code's call under it (direct, then each record's):
// native code between returns at once (cpu.unwinding). A record that
// returns to t with another sp is no match. Else the `jr` returns as
// before, except when no record matches and no run down to the thread's
// base has host code's call under it: true, a jump, the native code under
// the run (gaps, the run's) left open, at most cpu.NATIVE_STALE_MAX gaps.
// A barrier record (host code's call) is under every run above it, and not
// counted.
//
// A learned function's run (cpu.learned_top's chain) whose own return
// address and sp at its call are t and that sp is a call returning there
// too, the only record of one learned or native code made: the innermost
// of the cpu.UNWIND_MAX runs above. It is the call to unwind to
// (learned_unwind) when it is inside every record that matches, with no
// barrier record inside it and no mods. The order of the two chains is the
// host stack's: every record and run of a thread is a local on that
// thread's stack, which grows down, so in each chain prev is at a higher
// address (asserted here), and of a record and a run the one at the lower
// address is the inner.
@(private = "file")
interp_unwind_find :: proc(t: u32, direct: bool, gaps: u32) -> bool {
	sp := u32(cpu.state.r[29].d[0])
	lm: ^cpu.Learned_Run
	for l, k := cpu.learned_top, 0; l != nil && k < cpu.UNWIND_MAX; l, k = l.prev, k + 1 {
		assert(l.prev == nil || uintptr(l.prev) > uintptr(l), "ee: a learned run under an older one on the host stack")
		if l.ra == t && l.sp == sp {
			lm = l
			break
		}
	}
	ok := direct
	barred := cpu.mod_on
	n := 0
	for f := cpu.interp_top; f != nil; f = f.prev {
		assert(f.prev == nil || uintptr(f.prev) > uintptr(f), "ee: a call record under an older one on the host stack")
		if lm != nil && uintptr(f) > uintptr(lm) {break}
		// Host code's call (cpu.host_call): not a call to match. The run
		// above it is not direct, so ok is already false past it.
		if f.barrier {
			barred = true
			continue
		}
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
					fmt.eprintfln("ee: jr $ra to %08x: the call %d out returns there, past host code's call; returning as before", t, n)
				}
				return false
			}
			if cpu.debug >= 1 && .Done not_in unwind_shown {
				unwind_shown += {.Done}
				fmt.eprintfln("ee: jr $ra to %08x: unwound to the call %d out", t, n)
			}
			interp_unwind = f
			cpu.unwinding = true
			cpu.interp_unwinds += 1
			if gaps > f.gaps {cpu.interp_unwinds_native += 1}
			return false
		}
		ok = ok && f.direct
	}
	if lm != nil {
		if barred {
			if cpu.debug >= 1 && .Native not_in unwind_shown {
				unwind_shown += {.Native}
				fmt.eprintfln("ee: jr $ra to %08x: the learned function %08x was called to return there, past host code's call; returning as before", t, lm.entry)
			}
			return false
		}
		if cpu.debug >= 1 && .Learned not_in unwind_shown {
			unwind_shown += {.Learned}
			fmt.eprintfln("ee: jr $ra to %08x: unwound to the call of the learned function %08x", t, lm.entry)
		}
		learned_unwind = lm
		cpu.unwinding = true
		cpu.interp_unwinds += 1
		cpu.interp_unwinds_native += 1
		return false
	}
	if !ok {
		if cpu.debug >= 1 && .Under not_in unwind_shown {
			unwind_shown += {.Under}
			fmt.eprintfln("ee: jr $ra to %08x: no call returns there, host code's call under the run; returning as before", t)
		}
		return false
	}
	if gaps > cpu.NATIVE_STALE_MAX {
		cpu.interp_stale += 1
		if .Stale not_in unwind_shown {
			unwind_shown += {.Stale}
			fmt.eprintfln("ee: jr $ra to %08x: no call returns there, and a jump would leave %d gaps of native code open under the run, past %d (NATIVE_STALE_MAX); returning as before", t, gaps, cpu.NATIVE_STALE_MAX)
		}
		return false
	}
	if cpu.debug >= 1 && .Jump not_in unwind_shown {
		unwind_shown += {.Jump}
		fmt.eprintfln("ee: jr $ra to %08x: no call returns there; a jump", t)
	}
	cpu.interp_jumps += 1
	if gaps > 0 {cpu.interp_jumps_native += 1}
	return true
}
