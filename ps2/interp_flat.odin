// The EE interpreter of a FLAT build (core/flat.odin). It does what
// interp_call does, with the same decode, execution, events checks and
// counts, but keeps the call chain as data (kernel.Flat_Ctx) instead of in
// host frames: a call pushes its return address and goes on at the target,
// and `jr $ra` or ERET pops. The host enters it for the console threads
// (flat_run) and for each guest call it makes itself (flat_call, as
// cpu.interp_hook).
//
// On wasm32, native code (recomp/r5900/native.odin) is a step of this
// runner: flat_resume enters it at a pc it has an entry for, and does what
// its exit (cpu.native_exit) leaves to the runner.
package ps2

import "core:fmt"

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
// up the run that is current then (flat_resume).
@(private = "file")
flat_loop :: proc() {
	c := &cpu.state
	x, pc, ok := flat_resume()
	if !ok {return}
	for {
		i := r5900.decode(pc, mem.rd32(pc))
		c.cycles += cpu.CYCLES_PER_INSN
		when mem.MOD_PROBE {if mem.mod_ram_has(pc) {mem.mod_probe.interp += 1}}
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
				if x, pc, ok = flat_resume(); !ok {return}
				continue
			}
			flat_sys(i)
			if x, pc, ok = flat_resume(); !ok {return}
		case .Bad:
			cpu.bad_insn(pc, i.w)
		case .Branch:
			taken := branch_taken(i)
			if i.link {c.r[31].d[0] = u64(ret)}
			if !i.likely || taken {delay_slot(pc + 4, nil)}
			if !taken {
				pc = ret
			} else if i.link && i.target != ret {
				flat_enter(x, ret, i.target)
					if x, pc, ok = flat_resume(); !ok {return}
			} else if i.link {
				pc = ret
			} else if flat_mod_tail(x, i.target) {
					if x, pc, ok = flat_resume(); !ok {return}
			} else if flat_goto(x, pc, i.target) {
				if x, pc, ok = flat_resume(); !ok {return}
			} else {
				pc = i.target
				if flat_native_at(pc) {
					x.pc = pc
					if x, pc, ok = flat_resume(); !ok {return}
				}
			}
		case .Jump:
			delay_slot(pc + 4, nil)
			if flat_mod_tail(x, i.target) {
					if x, pc, ok = flat_resume(); !ok {return}
			} else if flat_goto(x, pc, i.target) {
					if x, pc, ok = flat_resume(); !ok {return}
			} else {
				pc = i.target
				if flat_native_at(pc) {
					x.pc = pc
					if x, pc, ok = flat_resume(); !ok {return}
				}
			}
		case .Call:
			c.r[31].d[0] = u64(ret)
			delay_slot(pc + 4, nil)
			if i.target == ret {
				pc = ret
				continue
			}
			flat_enter(x, ret, i.target)
			if x, pc, ok = flat_resume(); !ok {return}
		case .Jalr:
			t := u32(c.r[i.rs].d[0])
			if i.rd != 0 {c.r[i.rd].d[0] = u64(ret)}
			delay_slot(pc + 4, nil)
			if t == ret {
				pc = ret
				continue
			}
			flat_enter(x, ret, t)
			if x, pc, ok = flat_resume(); !ok {return}
		case .Jr:
			t := u32(c.r[i.rs].d[0])
			delay_slot(pc + 4, nil)
			if i.rs == 31 && !flat_unwind(x, t) {
				if !flat_return(x, true, t) {return}
				if x, pc, ok = flat_resume(); !ok {return}
				continue
			}
			if i.rs == 31 {
				// No call returns to t: a jump there, as interp_body's.
				if flat_mod_tail(x, t) {
					if x, pc, ok = flat_resume(); !ok {return}
				} else if flat_goto(x, pc, t) {
					if x, pc, ok = flat_resume(); !ok {return}
				} else {
					pc = t
					if flat_native_at(pc) {
						x.pc = pc
						if x, pc, ok = flat_resume(); !ok {return}
					}
				}
				continue
			}
			// interp_body's two checks: the events check of every such
			// `jr`, then goto_pc's of a backward one. A switch at the first
			// leaves the second to the thread's resume (x.back). A tail call
			// into a hooked function owes its entry instead (x.enter).
			x.pc = t
			tail := flat_mod_tail(x, t)
			if c.cycles >= cpu.next_event {
				x.back = t <= pc && !tail
				kernel.flat_sync()
				kernel.run_events()
				kernel.flat_commit()
					if x, pc, ok = flat_resume(); !ok {return}
			} else if tail {
					if x, pc, ok = flat_resume(); !ok {return}
			} else {
				pc = t
				if flat_native_at(pc) {
					x.pc = pc
					if x, pc, ok = flat_resume(); !ok {return}
				}
			}
		}
	}
}

// wasm32: whether native code is loaded (load_native), which flat_resume
// and the interpreter's taken jumps then look pcs up for. With no blob
// they test it and nothing more.
flat_native_on: bool

// What native code is called as: the pc to enter it at, among its
// function's entries.
Wasm_Func :: #type proc(pc: u32)

// The run that is current now and its pc (flat_reload), after running the
// native code there is at it, on wasm32: false when a return in it ended
// the run (flat_return), which the caller then returns from. Native code
// runs from block to block of its function until the interpreter has work
// to do, and leaves the rest to here: due events, a call, a return, a
// SYSCALL, ERET, or a jump out of its blocks (to other native code, or to
// interpret).
@(private = "file")
flat_resume :: proc() -> (x: ^kernel.Flat_Ctx, pc: u32, ok: bool) {
	x, pc = flat_reload()
	when ODIN_ARCH == .wasm32 {
		for flat_native_on {
			f := flat_lookup(pc)
			if f == nil {break}
			e := &cpu.native_exit
			when mem.MOD_PROBE {mem.mod_probe.enters[int(mem.mod_ram_has(pc))] += 1}
			(cast(Wasm_Func)rawptr(f))(pc)
			switch e.reason {
			case .None:
				// An entry its code has no block for: interpret, rather
				// than enter it again.
				if e.pc == pc {
					when mem.MOD_PROBE {
						in_mod := mem.mod_ram_has(pc)
						mem.mod_probe.left[int(in_mod)] += 1
						if in_mod && mem.mod_func_words(pc) == 0 {mem.mod_probe.mid += 1}
					}
					return x, pc, true
				}
				// A jump into a hooked function reaches its chain, as the
				// interpreter's does (flat_mod_tail sets x.pc).
				if !flat_mod_tail(x, e.pc) {x.pc = e.pc}
			case .Events:
				x.pc = e.pc
				x.back = e.back != 0
				kernel.flat_sync()
				kernel.run_events()
				kernel.flat_commit()
			case .Call:
				// a jalr to its own return address: no call (.Jalr above)
				if e.arg == e.pc {
					x.pc = e.pc
				} else {
					flat_enter(x, e.arg, e.pc)
				}
			case .Return:
				// Native code's `jr $ra` returns, whatever it jumps to.
				flat_unwind(x, e.pc)
				flat_return(x, true, e.pc) or_return
			case .Sys:
				x.pc = e.pc
				flat_sys(r5900.decode(e.pc - 4, mem.rd32(e.pc - 4)))
			case .Eret:
				flat_return(x, false, 0) or_return
			}
			x, pc = flat_reload()
		}
	}
	return x, pc, true
}

// wasm32: native code at t, which a taken jump that checked nothing goes
// on in (flat_resume, after x.pc = t).
@(private = "file")
flat_native_at :: #force_inline proc(t: u32) -> bool {
	when ODIN_ARCH == .wasm32 {
		return flat_native_on && flat_lookup(t) != nil
	} else {
		return false
	}
}

// wasm32: the native code at pc, the game's (the call table) or a mod's
// (load_mods), else nil.
@(private = "file")
flat_lookup :: #force_inline proc(pc: u32) -> cpu.Func_Proc {
	if f := cpu.lookup(pc); f != nil {return f}
	if !mem.mod_func_near(pc) {return nil}
	when mem.MOD_PROBE {mem.mod_probe.fallback[int(mem.mod_ram_has(pc))] += 1}
	return mem.mod_func_at(pc)
}

// A SYSCALL, with the run's pc past it (x.pc): it may switch threads.
@(private = "file")
flat_sys :: proc(i: r5900.Insn) {
	kernel.flat_sync()
	exec_insn(i)
	kernel.flat_commit()
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
			if x.depth == 0 {x.ra, x.ra_sp = u32(cpu.state.r[31].d[0]), u32(cpu.state.r[29].d[0])}
			if cpu.mod_on {
				mod_flat_enter(x)
				// A call into the mod region, counted as the recursive
				// model's hook does (mod_interp_hook).
				if mem.mod_ram_has(x.pc) {
					if flat_native_at(x.pc) {mem.mod_native_calls += 1} else {mem.mod_interp_calls += 1}
				}
			}
			// Native code at the entry is not interpreted, and traces its
			// own entry (flat_resume runs it next).
			if !flat_native_at(x.pc) {interp_enter(x.pc)}
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

// A jump from x to t that goto_pc takes as a tail call into a hooked
// function's chain (mod_flat_tail): the run goes on at t, whose entry is
// owed (flat_reload).
@(private = "file")
flat_mod_tail :: #force_inline proc(x: ^kernel.Flat_Ctx, t: u32) -> bool {
	if !cpu.mod_on || !mod_flat_tail(x, t) {return false}
	cpu.spin_dirty |= cpu.SPIN_SIDE
	x.pc, x.enter = t, true
	return true
}

// interp_body's goto_pc with nothing registered: a backward jump from pc to
// t checks events, then steps the spin skip (spin_step). True when it ran
// them; the run goes on at x.pc.
@(private = "file")
flat_goto :: #force_inline proc(x: ^kernel.Flat_Ctx, pc, t: u32) -> bool {
	if t > pc || cpu.state.cycles < cpu.next_event {
		spin_step(pc, t)
		return false
	}
	x.pc = t
	kernel.flat_sync()
	kernel.run_events()
	kernel.flat_commit()
	return true
}

// `jr $ra` (jr, with ra the address it jumps to) or ERET ends the
// innermost call: go on at the address its call pushed (x.pc), as
// interp_body's return to its caller does. At depth 0 it ends the run:
// false for a nested run, which returns to the host. A return address
// marked by a hooked call (FLAT_MOD_MARK) runs its after hooks first
// (mod_flat_return), and may end the run. A `jr $ra` to an outer call's
// return address has unwound to it first (flat_unwind).
@(private = "file")
flat_return :: proc(x: ^kernel.Flat_Ctx, jr: bool, ra: u32) -> bool {
	if x.depth > 0 {
		x.depth -= 1
		ret := x.ret[x.depth]
		for ret & FLAT_MOD_MARK != 0 {
			again: bool
			if ret, again = mod_flat_return(ret); again {return flat_end(x)}
		}
		x.pc = ret &~ kernel.FLAT_HOST_TAIL
		when mem.MOD_PROBE {if mem.mod_ram_has(x.pc) {mem.mod_probe.returns += 1}}
		if jr && ret & kernel.FLAT_HOST_TAIL == 0 {
			cpu.flat_returns += 1
			if ra != x.pc {cpu.flat_mismatch += 1}
		}
		return true
	}
	return flat_end(x)
}

// The longjmps shown so far, each kind once under PS_DEBUG (a search past
// cpu.UNWIND_MAX once always): not state.
@(private = "file")
flat_unwind_shown: bit_set[enum {Done, Host, Max, Jump, Under}]

// interp_body's unwind (interp_unwind_find) on the shadow stacks, for a
// `jr $ra` to ra, not with the innermost call's return address and sp
// (x.ra and x.ra_sp at depth 0): the innermost of the cpu.UNWIND_MAX calls
// returning to ra with the guest sp now becomes the innermost, the calls
// above it dropped, when none between was made by the host or is a hooked
// call's (FLAT_HOST_TAIL, FLAT_MOD_MARK). A call that returns to ra with
// another sp is no match. The search goes on into the runs x is nested in
// (the host's, kernel.flat.nest, then the thread's), each one past host
// code. Else the return pops the innermost as before, except when no call
// matches: true, a jump there.
@(private = "file")
flat_unwind :: proc(x: ^kernel.Flat_Ctx, ra: u32) -> bool {
	MARKS :: kernel.FLAT_HOST_TAIL | FLAT_MOD_MARK
	sp := u32(cpu.state.r[29].d[0])
	if x.depth > 0 {
		r := x.ret[x.depth - 1]
		if r == ra && x.sp[x.depth - 1] == sp || r & MARKS != 0 {return false}
	} else if ra == x.ra && sp == x.ra_sp {
		return false
	}
	assert(x == kernel.flat_ctx())
	ok := true
	n := 1
	nest := kernel.flat.nest_depth
	for j := 0; j <= nest; j += 1 {
		c := j < nest ? &kernel.flat.nest[nest - 1 - j] : &kernel.flat.ee[kernel.k.current.id]
		top := int(c.depth) - 1
		if j == 0 {
			top -= 1
		} else {
			ok = false
		}
		for k := top; k >= 0; k -= 1 {
			if n == cpu.UNWIND_MAX {
				if .Max not_in flat_unwind_shown {
					flat_unwind_shown += {.Max}
					fmt.eprintfln("ee: jr $ra to %08x: no call returns there in the %d innermost; returning as before", ra, cpu.UNWIND_MAX)
				}
				return false
			}
			n += 1
			r := c.ret[k]
			if r & MARKS != 0 {
				ok = false
				continue
			}
			if r != ra || c.sp[k] != sp {continue}
			if !ok {
				if cpu.debug >= 1 && .Host not_in flat_unwind_shown {
					flat_unwind_shown += {.Host}
					fmt.eprintfln("ee: jr $ra to %08x: the call %d out returns there, past host code; returning as before", ra, n)
				}
				return false
			}
			if cpu.debug >= 1 && .Done not_in flat_unwind_shown {
				flat_unwind_shown += {.Done}
				fmt.eprintfln("ee: jr $ra to %08x: unwound to the call %d out", ra, n)
			}
			x.depth = u32(k) + 1
			return false
		}
	}
	if !ok {
		if cpu.debug >= 1 && .Under not_in flat_unwind_shown {
			flat_unwind_shown += {.Under}
			fmt.eprintfln("ee: jr $ra to %08x: no call returns there, host code under the run; returning as before", ra)
		}
		return false
	}
	if cpu.debug >= 1 && .Jump not_in flat_unwind_shown {
		flat_unwind_shown += {.Jump}
		fmt.eprintfln("ee: jr $ra to %08x: no call returns there; a jump", ra)
	}
	return true
}

// The end of run x, at depth 0: false for a nested run.
@(private = "file")
flat_end :: proc(x: ^kernel.Flat_Ctx) -> bool {
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
