// The EE interpreter of a FLAT build (core/flat.odin). It does what
// interp_call does, with the same decode, execution, events checks and
// counts, but keeps the call chain as data (kernel.Flat_Ctx) instead of in
// host frames: a call pushes its return address and goes on at the target,
// and `jr $ra` or ERET pops. The host enters it for the console threads
// (flat_run) and for each guest call it makes itself (flat_call, as
// cpu.interp_hook).
package ps2

import cpu "cpu"
import kernel "kernel"
import mem "mem"
import r5900 "r5900"

// Run the console threads, from the current one's run. Never returns: a
// thread's run ends in a switch to another, or fatally.
flat_run :: proc() -> ! {
	flat_loop()
	cpu.fatal("the EE threads' run ended")
}

// cpu.interp_hook under FLAT: run the guest code at entry until it returns.
flat_call :: proc(entry: u32) {
	kernel.flat_nest_push(entry)
	flat_loop()
	kernel.flat_nest_pop()
}

// Run the innermost run (kernel.flat_ctx) until it ends. A nested run's end
// returns; a thread's switches to the next thread's run.
//
// The pc is kept in the run (x.pc) before each syscall and events check:
// one may switch threads, or load a snapshot. After it, flat_reload picks
// up the run that is current then.
@(private = "file")
flat_loop :: proc() {
	c := &cpu.state
	x, pc := flat_reload()
	for {
		i := r5900.decode(pc, mem.rd32(pc))
		c.cycles += cpu.CYCLES_PER_INSN
		ret := pc + 8
		switch i.kind {
		case .Alu:
			exec_insn(i)
			pc += 4
		case .Sys:
			x.pc = pc + 4
			if i.op == .ERET {
				exec_insn(i)
				if !flat_return(x, false, 0) {return}
				x, pc = flat_reload()
				continue
			}
			kernel.flat_sync()
			exec_insn(i)
			kernel.flat_commit()
			x, pc = flat_reload()
		case .Bad:
			cpu.bad_insn(pc, i.w)
		case .Branch:
			taken := branch_taken(i)
			if i.link {c.r[31].d[0] = u64(ret)}
			if !i.likely || taken {delay_slot(pc + 4, nil)}
			if !taken {
				pc = ret
			} else if i.link {
				flat_enter(x, ret, i.target)
				x, pc = flat_reload()
			} else if flat_goto(x, pc, i.target) {
				x, pc = flat_reload()
			} else {
				pc = i.target
			}
		case .Jump:
			delay_slot(pc + 4, nil)
			if flat_goto(x, pc, i.target) {
				x, pc = flat_reload()
			} else {
				pc = i.target
			}
		case .Call:
			c.r[31].d[0] = u64(ret)
			delay_slot(pc + 4, nil)
			flat_enter(x, ret, i.target)
			x, pc = flat_reload()
		case .Jalr:
			t := u32(c.r[i.rs].d[0])
			if i.rd != 0 {c.r[i.rd].d[0] = u64(ret)}
			delay_slot(pc + 4, nil)
			flat_enter(x, ret, t)
			x, pc = flat_reload()
		case .Jr:
			t := u32(c.r[i.rs].d[0])
			delay_slot(pc + 4, nil)
			if i.rs == 31 {
				if !flat_return(x, true, t) {return}
				x, pc = flat_reload()
				continue
			}
			// interp_body's two checks: the events check of every such
			// `jr`, then goto_pc's of a backward one. A switch at the first
			// leaves the second to the thread's resume (x.back).
			x.pc = t
			if c.cycles >= cpu.next_event {
				x.back = t <= pc
				kernel.flat_sync()
				kernel.run_events()
				kernel.flat_commit()
				x, pc = flat_reload()
			} else {
				pc = t
			}
		}
	}
}

// The run that is current now, and its pc, after the checks it owes: a
// call's on entry (interp_call), or a backward jump's events check. Each
// may switch to another run, which may owe its own.
@(private = "file")
flat_reload :: proc() -> (^kernel.Flat_Ctx, u32) {
	for {
		x := kernel.flat_ctx()
		check := false
		if x.enter {
			x.enter = false
			interp_enter(x.pc)
			check = true
		} else if x.back {
			x.back = false
			check = true
		}
		if check && cpu.state.cycles >= cpu.next_event {
			kernel.flat_sync()
			kernel.run_events()
			kernel.flat_commit()
			continue
		}
		return x, x.pc
	}
}

// A call from x to t returning to ret, as cpu.call does: its entry checks
// are owed (flat_reload).
@(private = "file")
flat_enter :: #force_inline proc(x: ^kernel.Flat_Ctx, ret, t: u32) {
	cpu.spin_dirty |= cpu.SPIN_SIDE
	kernel.flat_push(x, ret, t)
}

// interp_body's goto_pc with nothing registered: a backward jump from pc to
// t checks events. True when it ran them; the run goes on at x.pc.
@(private = "file")
flat_goto :: #force_inline proc(x: ^kernel.Flat_Ctx, pc, t: u32) -> bool {
	if t > pc || cpu.state.cycles < cpu.next_event {return false}
	x.pc = t
	kernel.flat_sync()
	kernel.run_events()
	kernel.flat_commit()
	return true
}

// `jr $ra` (jr, with ra the address it jumps to) or ERET ends the
// innermost call: go on at the address its call pushed (x.pc), as
// interp_body's return to its caller does. At depth 0 it ends the run:
// false for a nested run, which returns to the host.
@(private = "file")
flat_return :: proc(x: ^kernel.Flat_Ctx, jr: bool, ra: u32) -> bool {
	if x.depth > 0 {
		x.depth -= 1
		x.pc = x.ret[x.depth]
		if jr {
			cpu.flat_returns += 1
			if ra != x.pc {cpu.flat_mismatch += 1}
		}
		return true
	}
	switch x.end {
	case .Call:
		return false
	case .Main:
		cpu.fatal("entry returned")
	case .Exec:
		cpu.fatal("program %08x started by ExecPS2 returned", kernel.k.current.entry)
	case .Thread:
		kernel.flat_thread_end()
	}
	return true
}
