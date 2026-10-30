// The EE interpreter for whole functions: cpu.call and cpu.jump_unknown run
// an address no function is registered at here (cpu.interp_hook), so code
// the recompiler never saw, or a native blob that lacks a function, plays on
// instead of stopping. It follows the recompiled code's control flow
// (recomp/r5900/lower.odin): a call is a host call, `jr $ra` returns, and a
// jump to a registered function is a tail call to it.
package ps2

import "base:runtime"
import "core:fmt"

import cpu "cpu"
import kernel "kernel"
import mem "mem"
import r5900 "r5900"

// Addresses already reported on stderr: host state, so each is reported
// once per process.
@(private = "file")
interp_seen: map[u32]bool

@(private = "file")
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
@(private = "file")
delay_slot :: proc(pc: u32) {
	cpu.state.cycles += 1
	i := r5900.decode(pc, mem.rd32(pc))
	if i.kind == .Bad {cpu.bad_insn(pc, i.w)}
	exec_insn(i)
}

// Continue at t from the instruction at pc: a registered function there
// takes over as a tail call (true: the caller returns), else the loop goes
// on at t, checking events on a backward jump as recompiled code does.
@(private = "file")
goto_pc :: proc(pc, t: u32) -> bool {
	if fn := cpu.lookup(t); fn != nil {
		fn()
		return true
	}
	if t <= pc && cpu.state.cycles >= cpu.next_event {kernel.run_events()}
	return false
}

interp_call :: proc(entry: u32) {
	c := &cpu.state
	when cpu.FALLBACK_COUNT {
		if cpu.fallback_ee_calls == nil {
			cpu.fallback_ee_calls = make(map[u32]u64, runtime.heap_allocator())
		}
		cpu.fallback_ee_calls[entry] += 1
	}
	if entry not_in interp_seen {
		if interp_seen == nil {interp_seen = make(map[u32]bool, runtime.heap_allocator())}
		interp_seen[entry] = true
		fmt.eprintfln("ee: interpreting %08x (ra %08x): no function registered", entry, u32(c.r[31].d[0]))
	}
	if kernel.trace_on {kernel.trace_call(entry)}
	if c.cycles >= cpu.next_event {kernel.run_events()}
	pc := entry
	for {
		i := r5900.decode(pc, mem.rd32(pc))
		c.cycles += 1
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
			if !i.likely || taken {delay_slot(pc + 4)}
			if !taken {
				pc = ret
			} else if i.link {
				cpu.call(i.target)
				pc = ret
			} else {
				if goto_pc(pc, i.target) {return}
				pc = i.target
			}
		case .Jump:
			delay_slot(pc + 4)
			if goto_pc(pc, i.target) {return}
			pc = i.target
		case .Call:
			c.r[31].d[0] = u64(ret)
			delay_slot(pc + 4)
			cpu.call(i.target)
			pc = ret
		case .Jalr:
			t := u32(c.r[i.rs].d[0])
			if i.rd != 0 {c.r[i.rd].d[0] = u64(ret)}
			delay_slot(pc + 4)
			cpu.call(t)
			pc = ret
		case .Jr:
			t := u32(c.r[i.rs].d[0])
			delay_slot(pc + 4)
			if i.rs == 31 {return}
			if c.cycles >= cpu.next_event {kernel.run_events()}
			if goto_pc(pc, t) {return}
			pc = t
		}
	}
}
