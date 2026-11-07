// The EE interpreter for whole functions: cpu.call and cpu.jump_unknown run
// an address no function is registered at here (cpu.interp_hook), so code
// the recompiler never saw, or a native blob that lacks a function, plays on
// instead of stopping. It follows the recompiled code's control flow
// (recomp/r5900/lower.odin): a call is a host call, `jr $ra` returns, and a
// jump to a registered function is a tail call to it. A learned function
// whose words RAM holds runs instead (learned.odin).
//
// A `jr $ra` to another address than the run's own return address, with
// the guest sp of an outer interpreted call, is a longjmp to that call's
// return address (a throw that restored a catch frame's registers): the
// runs in between return, and the one that made the call goes on there
// (interp_unwind_find). Host code between them stops it: the `jr` returns
// as before (shown once under PS_DEBUG).
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

// The longjmps shown so far, each kind once under PS_DEBUG: not state.
@(private = "file")
unwind_shown: bit_set[enum {Done, Native, Max}]

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
	interp_body(entry, f)
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

// The run from entry; lf is its LEARN frame, nil without LEARN.
@(private = "file")
interp_body :: proc(entry: u32, lf: ^core.Learn_Frame) {
	c := &cpu.state
	pc := entry
	// Its return address, and whether the call into it is the top record
	// (cpu.Interp_Frame): host code between, or a mod's chain, could be.
	ra := u32(c.r[31].d[0])
	top := cpu.interp_top
	direct := !cpu.mod_on && top != nil && top.target == entry && top.ret == ra && top.sp == u32(c.r[29].d[0])
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
				if interp_calls(ret, i.target, direct) {return}
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
			if interp_calls(ret, i.target, direct) {return}
			pc = ret
		case .Jalr:
			t := u32(c.r[i.rs].d[0])
			if i.rd != 0 {c.r[i.rd].d[0] = u64(ret)}
			delay_slot(pc + 4, lf)
			if interp_calls(ret, t, direct) {return}
			pc = ret
		case .Jr:
			t := u32(c.r[i.rs].d[0])
			delay_slot(pc + 4, lf)
			if i.rs == 31 {
				if t != ra {interp_unwind_find(t, direct)}
				return
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
	fr := cpu.Interp_Frame {
		ret    = ret,
		sp     = u32(cpu.state.r[29].d[0]),
		target = t,
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

// A `jr $ra` to t, not the run's return address: the innermost of the
// cpu.UNWIND_MAX records above returning to t with the guest sp now is the
// call to unwind to (interp_unwind), when every run above it was called
// directly (direct, then each record's). Else the `jr` returns as before.
@(private = "file")
interp_unwind_find :: proc(t: u32, direct: bool) {
	sp := u32(cpu.state.r[29].d[0])
	ok := direct
	n := 0
	for f := cpu.interp_top; f != nil; f = f.prev {
		if n == cpu.UNWIND_MAX {
			if cpu.debug >= 1 && .Max not_in unwind_shown {
				unwind_shown += {.Max}
				fmt.eprintfln("ee: jr $ra to %08x: no call returns there in the %d innermost; returning as before", t, cpu.UNWIND_MAX)
			}
			return
		}
		n += 1
		if f.ret == t && f.sp == sp {
			if !ok {
				if cpu.debug >= 1 && .Native not_in unwind_shown {
					unwind_shown += {.Native}
					fmt.eprintfln("ee: jr $ra to %08x: the call %d out returns there, past host code; returning as before", t, n)
				}
				return
			}
			if cpu.debug >= 1 && .Done not_in unwind_shown {
				unwind_shown += {.Done}
				fmt.eprintfln("ee: jr $ra to %08x: unwound to the call %d out", t, n)
			}
			interp_unwind = f
			return
		}
		ok = ok && f.direct
	}
}
