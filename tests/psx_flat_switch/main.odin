// BIOS thread switches made by guest code: ChangeTh, syscall 3 and
// exception returns (preempt) between the main thread and a second one.
// Plain the threads are the BIOS's coroutines; under FLAT, flat runs that
// bios.flat_main switches between, which is the path games take on the web.
//
// Every thread runs DISPATCH, a loop that calls the host's STEP and then
// does the switch the step asked for: the checks are a script of host
// steps, one per STEP call in the order the threads make them, so each
// step sees the registers its thread came back with. tests/psx_bios
// thread_switches drives the same BIOS calls from host code, coroutines
// only.
//
// Last, under FLAT, a switch that cannot be made: in guest code that native
// code called. Its fatal must hand the native code to play's known switches.
package main

import "core:fmt"
import "core:os"
import bios "ps:psx/bios"
import cpu "ps:psx/cpu"
import io "ps:psx/io"

import "ps:core"

@(private = "file")
failed: int

@(private = "file")
check :: proc(what: string, got, want: u32, loc := #caller_location) {
	if got != want {
		fmt.eprintfln("FAIL psx_flat_switch: step %d: %s: got %#x, want %#x (line %d)", s.n, what, got, want, loc.line)
		failed += 1
	}
}

// The host step every DISPATCH loop calls.
@(private = "file")
STEP :: 0x80001700
// Two copies of DISPATCH: a thread started over at D_ALT (an epc write) is
// told apart from one resumed in D_MAIN by its STEP call's return address.
@(private = "file")
D_MAIN :: 0x80020000
@(private = "file")
D_ALT :: 0x80021000
@(private = "file")
THREAD_SP :: 0x801f0000
@(private = "file")
MAIN_THREAD :: 0xff000000
// A store here is an interrupt acknowledged: the test's io_write raises
// IRQ 0, whose exception return goes on with the TCB the PCB names.
@(private = "file")
TRIG :: 0x1f801050

// A word of RAM nothing reads.
@(private = "file")
SPARE :: 0x80022000

// What a step asks DISPATCH to do next (t0).
@(private = "file")
Op :: enum u32 {
	End, // return from the entry: the main thread only
	Change, // ChangeTh(a0)
	Syscall, // syscall with a0, a1
	Store, // a store to TRIG
	Jr_Store, // jr $ra back to the loop, the store to TRIG in its delay slot
}

// What a store to TRIG does after IRQ 0.
@(private = "file")
Trig :: enum {
	Irq,
	// Events come due at once: the jump after the store would run them.
	Irq_Events,
	// The PCB names the running thread again, as a second exception
	// return in the same store would leave it.
	Irq_Rename,
}

@(private = "file")
s: struct {
	steps:     [dynamic]proc(),
	n:         int, // steps run
	h:         u32, // the second thread's handle
	main_sr:   u32,
	round:     int, // slot reuse rounds done
	trig:      Trig,
	trigs:     int, // stores to TRIG
	events:    int, // run_events calls counted
	events_s0: u32, // s0 when they ran
	dropped:   u64, // cpu.flat_switches_dropped before the rename case
}

@(private = "file")
r :: proc() -> ^[32]u32 {return &cpu.state.r}

@(private = "file")
tcbs :: proc() -> u32 {return cpu.r32(0x110)}

@(private = "file")
tcb :: proc(i: u32) -> u32 {return tcbs() + i * 0xc0}

@(private = "file")
reg :: proc(t, n: u32) -> u32 {return t + 8 + 4 * n}

// The PCB's word names thread i's TCB.
@(private = "file")
on :: proc(i: u32, loc := #caller_location) {
	check(fmt.tprintf("running TCB is thread %d's", i), cpu.r32(cpu.r32(0x108)) & 0x1fffffff, tcb(i) & 0x1fffffff, loc)
}

// The DISPATCH copy the STEP call came from (its jal is the copy's second word).
@(private = "file")
from :: proc() -> u32 {return r()[31] - 12}

@(private = "file")
point_pcb :: proc(t: u32) {cpu.w32(cpu.r32(0x108), t)}

@(private = "file")
op :: proc(o: Op, a0: u32 = 0, a1: u32 = 0) {
	r()[8], r()[4], r()[5], r()[12] = u32(o), a0, a1, TRIG
}

@(private = "file")
bios_b :: proc(fn: u32, args: ..u32) -> u32 {
	for x, k in args {r()[4 + k] = x}
	bios.bios_b(fn)
	return r()[2]
}

@(private = "file")
put :: proc(addr, w: u32) {
	(^u32le)(&cpu.ram[addr & 0x1fffff])^ = u32le(w)
}

// DISPATCH at base: t0 is the step's Op, a0/a1 its arguments, t4 TRIG.
@(private = "file")
put_dispatch :: proc(base: u32) {
	loop := base + 4
	code := [?]u32 {
		0x03e0b821, // 0: addu s7, ra, zero
		0x0c000000 | (STEP >> 2) & 0x3ffffff, // 1 loop: jal STEP
		0x00000000,
		0x11000017, // 3: beq t0, zero, done
		0x240b0001, // addiu t3, zero, 1
		0x110b0009, // 5: beq t0, t3, change
		0x240b0002, // addiu t3, zero, 2
		0x110b000d, // 7: beq t0, t3, sys
		0x240b0003, // addiu t3, zero, 3
		0x110b000e, // 9: beq t0, t3, store
		0x00000000,
		0x3c1f0000 | loop >> 16, // 11: lui ra, hi(loop)
		0x37ff0000 | loop & 0xffff, // ori ra, ra, lo(loop)
		0x03e00008, // jr ra
		0xad800000, // sw zero, 0(t4)
		0x240a00b0, // 15 change: addiu t2, zero, 0xb0
		0x24090010, // addiu t1, zero, 0x10
		0x0140f809, // jalr t2
		0x00000000,
		0x1000ffed, // 19: b loop
		0x00000000,
		0x0000000c, // 21 sys: syscall
		0x1000ffea, // b loop
		0x00000000,
		0xad800000, // 24 store: sw zero, 0(t4)
		0x1000ffe7, // b loop
		0x00000000,
		0x02e00008, // 27 done: jr s7
		0x00000000,
	}
	for w, k in code {put(base + u32(k) * 4, w)}
}

// The script, in the order the threads call STEP.
@(private = "file")
script :: proc() {
	add :: proc(p: proc()) {append(&s.steps, p)}
	// A round trip: the thread starts on its TCB's registers and comes back
	// to the main thread's with v0 1, its own left in its TCB.
	add(proc() {
		on(0)
		s.h = bios_b(0x0e, D_MAIN, THREAD_SP, 0x80012345)
		check("OpenTh", s.h, 0xff000001)
		r()[16], r()[29] = 0xaaaa, 0x801ffe00
		s.main_sr = cpu.cop0.sr
		op(.Change, s.h)
	})
	add(proc() {
		on(1)
		check("thread s0 at entry", r()[16], 0)
		check("thread gp at entry", r()[28], 0x80012345)
		check("thread sr at entry, the TCB's after rfe", cpu.cop0.sr, 0x40000401)
		r()[16] = 0x1111
		op(.Change, MAIN_THREAD)
	})
	add(proc() {
		on(0)
		check("main thread v0 after ChangeTh", r()[2], 1)
		check("main thread s0 after ChangeTh", r()[16], 0xaaaa)
		check("main thread sp after ChangeTh", r()[29], 0x801ffe00)
		check("main thread sr after ChangeTh", cpu.cop0.sr, s.main_sr)
		check("main thread's s0 in its TCB", cpu.r32(reg(tcb(0), 16)), 0xaaaa)
		check("suspended thread's s0 in its TCB", cpu.r32(reg(tcb(1), 16)), 0x1111)
		check("suspended thread's v0 in its TCB", cpu.r32(reg(tcb(1), 2)), 1)
		// A guest write to a suspended TCB's s0 is what the thread resumes with.
		cpu.w32(reg(tcb(1), 16), 0x2222)
		op(.Change, s.h)
	})
	add(proc() {
		on(1)
		check("thread v0 after its ChangeTh", r()[2], 1)
		check("thread s0 after a write to its TCB", r()[16], 0x2222)
		op(.Change, MAIN_THREAD)
	})
	// A guest write of its epc starts it over there; the continuation it
	// left is never resumed.
	add(proc() {
		on(0)
		cpu.w32(tcb(1) + 0x88, D_ALT)
		cpu.w32(tcb(1) + 0x94, 0x40000010)
		op(.Change, s.h)
	})
	add(proc() {
		on(1)
		check("thread after an epc write runs from it", from(), D_ALT)
		check("restarted thread's s0", r()[16], 0x2222)
		check("restarted thread's sr after a write to its TCB", cpu.cop0.sr, 0x40000014)
		op(.Change, MAIN_THREAD)
	})
	// syscall 3 to its TCB, in any segment, switches as ChangeTh does; to any
	// other address it stays on the running thread.
	add(proc() {
		r()[16] = 0xbbbb
		op(.Syscall, 3, 0x80000000 | (tcb(1) & 0x1fffffff))
	})
	add(proc() {
		on(1)
		check("thread resumes after syscall 3", from(), D_ALT)
		op(.Change, MAIN_THREAD)
	})
	add(proc() {
		on(0)
		check("syscall 3 to a TCB", r()[2], 1)
		check("main thread s0 after syscall 3", r()[16], 0xbbbb)
		r()[2] = 0
		op(.Syscall, 3, tcb(1) + 4)
	})
	add(proc() {
		on(0)
		check("syscall 3 inside a TCB", r()[2], 1)
		r()[2] = 0
		op(.Syscall, 3, tcb(16))
	})
	add(proc() {
		on(0)
		check("syscall 3 past the table", r()[2], 1)
		r()[2] = 0
		op(.Syscall, 3, 0x1234)
	})
	// CloseTh frees the TCB; so does a guest write of its status. OpenTh
	// then reuses the slot, the new thread starting at its own entry.
	add(proc() {
		on(0)
		check("syscall 3 to another address", r()[2], 1)
		check("CloseTh", bios_b(0x0f, s.h), 1)
		check("CloseTh status", cpu.r32(tcb(1)), 0x1000)
		op(.Change, s.h)
	})
	add(proc() {
		on(0)
		check("ChangeTh to a closed thread", r()[2], 0)
		s.h = bios_b(0x0e, D_ALT, THREAD_SP, 0)
		check("OpenTh of a freed slot", s.h, 0xff000001)
		op(.Change, s.h)
	})
	ROUNDS :: 40
	for _ in 0 ..< ROUNDS {
		add(proc() {
			on(1)
			check("reused slot's thread starts fresh", r()[22], 0)
			check("reused slot's thread at its entry", from(), D_ALT)
			r()[22] = 1
			op(.Change, MAIN_THREAD)
		})
		add(proc() {op(.Change, s.h)})
		add(proc() {
			on(1)
			check("reused slot's thread resumes", r()[22], 1)
			op(.Change, MAIN_THREAD)
		})
		add(proc() {
			on(0)
			if s.round % 2 == 0 {
				check("CloseTh of a reused slot", bios_b(0x0f, s.h), 1)
			} else {
				cpu.w32(tcb(1), 0x1000)
			}
			s.round += 1
			if s.round < ROUNDS {
				s.h = bios_b(0x0e, D_ALT, THREAD_SP, 0)
				check("OpenTh of a freed slot", s.h, 0xff000001)
				op(.Change, s.h)
				return
			}
			preempt_start()
		})
	}
	// An exception return goes on with the TCB the PCB names: a store's
	// interrupt pointing it at the other thread switches there, the main
	// thread's registers saved, and the thread pointing it back returns at
	// its own next store. A PCB naming no open thread's TCB stays put.
	add(proc() {
		on(1)
		check("preempted-to thread s0 at entry", r()[16], 0)
		check("preempted-to thread at its entry", from(), D_MAIN)
		check("stores to TRIG", u32(s.trigs), 1)
		r()[16] = 0x4444
		point_pcb(tcb(0))
		op(.Store)
	})
	add(proc() {
		on(0)
		check("main thread s0 back from the thread", r()[16], 0xcccc)
		check("preempted thread's s0 in its TCB", cpu.r32(reg(tcb(1), 16)), 0x4444)
		cpu.w32(reg(tcb(1), 16), 0x3333)
		point_pcb(tcb(1))
		op(.Store)
	})
	add(proc() {
		on(1)
		check("resumed thread's s0 from its TCB", r()[16], 0x3333)
		point_pcb(tcb(0))
		op(.Store)
	})
	add(proc() {
		on(0)
		check("main thread s0 after the second round", r()[16], 0xcccc)
		point_pcb(0x1234)
		op(.Store)
	})
	// A store in a jr $ra's delay slot that preempts: the switch lands after
	// the store, and the events due at the jump run on the thread switched
	// to, not on the one stopping (75cba40: under FLAT they ran first, and a
	// callback they delivered nested under a run that had to stop).
	add(proc() {
		check("PCB naming no TCB: no switch", from(), D_MAIN)
		check("PCB naming no TCB: main thread's s0", r()[16], 0xcccc)
		check("PCB naming no TCB: the BIOS leaves it", cpu.r32(cpu.r32(0x108)), 0x1234)
		point_pcb(tcb(0))
		on(0)
		r()[16] = 0xeeee
		s.trig, s.events = .Irq_Events, 0
		point_pcb(tcb(1))
		op(.Jr_Store)
	})
	add(proc() {
		on(1)
		check("events run once after the delay slot's store", u32(s.events), 1)
		check("events run on the thread switched to (its s0)", s.events_s0, 0x3333)
		s.trig = .Irq
		point_pcb(tcb(0))
		op(.Store)
	})
	add(proc() {
		on(0)
		check("main thread back at the jump's target", from(), D_MAIN)
		check("main thread s0 after the delay slot's switch", r()[16], 0xeeee)
		when core.FLAT {
			// The PCB names the running thread again before the run stops:
			// flat_main drops the switch it owed.
			s.dropped = cpu.flat_switches_dropped
			s.trig = .Irq_Rename
			point_pcb(tcb(1))
			op(.Store)
		} else {
			irq_in_native()
		}
	})
	when core.FLAT {
		add(proc() {
			on(0)
			check("owed switch dropped", u32(cpu.flat_switches_dropped - s.dropped), 1)
			irq_in_native()
		})
	}
	// An exception return in native code (a step is native) that names the
	// other thread: that thread is the next to run guest code. The switch
	// does not wait for a later exception return, which under FLAT left
	// MGS1's scheduler counting on a task that was not running.
	add(proc() {
		check("switched when the native code returned (the thread's s0)", r()[16], 0x3333)
		s.trig = .Irq
		point_pcb(tcb(0))
		op(.Store)
	})
	add(proc() {
		check("main thread s0 after the native code's switch", r()[16], 0xabcd)
		when core.FLAT {
			// Native code that entered a critical section after that exception
			// return: the switch waits for interrupts to be on again.
			r()[16] = 0x5151
			point_pcb(tcb(1))
			irq_now()
			cpu.cop0.sr &= ~u32(0x401)
			op_ram_store()
		} else {
			finish()
		}
	})
	when core.FLAT {
		add(proc() {
			check("no switch in a critical section", r()[16], 0x5151)
			cpu.cop0.sr |= 0x401
			op_ram_store()
		})
		add(proc() {
			check("switched once interrupts are on (the thread's s0)", r()[16], 0x3333)
			point_pcb(tcb(0))
			op(.Store)
		})
		add(proc() {
			check("main thread s0 after the critical section's switch", r()[16], 0x5151)
			finish()
		})
	}
}

// IRQ 0 here, in a step, with interrupts on as io delivers one.
@(private = "file")
irq_now :: proc() {
	cpu.cop0.sr |= 0x401
	io.irq_regs.stat, io.irq_regs.mask = 1, 1
	bios.deliver_irq()
}

// The step's op is a store to RAM: DISPATCH goes on with no interrupt.
@(private = "file")
op_ram_store :: proc() {
	op(.Store)
	r()[12] = SPARE
}

// The main thread's step that an exception return switches from.
@(private = "file")
irq_in_native :: proc() {
	r()[16] = 0xabcd
	point_pcb(tcb(1))
	irq_now()
	op_ram_store()
}

// The last reuse round's main step: the preempt cases' first.
@(private = "file")
preempt_start :: proc() {
	s.h = bios_b(0x0e, D_MAIN, THREAD_SP, 0)
	check("OpenTh for the preempt cases", s.h, 0xff000001)
	r()[16] = 0xcccc
	point_pcb(tcb(1))
	op(.Store)
}

@(private = "file")
finish :: proc() {
	check("CloseTh of the preempted thread", bios_b(0x0f, s.h), 1)
	op(.End)
}

main :: proc() {
	bios.bios_init()
	cpu.bios_a, cpu.bios_b, cpu.bios_c = bios.bios_a, bios.bios_b, bios.bios_c
	cpu.bios_syscall = bios.bios_syscall
	when core.FLAT {
		cpu.interp_run = cpu.flat_nested
		cpu.flat_step = cpu.mod_flat_step
	} else {
		cpu.interp_run = cpu.interp_loop
	}
	cpu.register_funcs({{STEP, proc() {
				if s.n >= len(s.steps) {
					fmt.eprintfln("FAIL psx_flat_switch: STEP call %d past the script's %d", s.n + 1, len(s.steps))
					os.exit(1)
				}
				s.n += 1
				s.steps[s.n - 1]()
			}}})
	cpu.io_write = proc(p, v: u32, size: u32) {
		if p != TRIG {return}
		s.trigs += 1
		io.irq_regs.stat, io.irq_regs.mask = 1, 1
		bios.deliver_irq()
		switch s.trig {
		case .Irq:
		case .Irq_Events:
			cpu.next_event = 0
		case .Irq_Rename:
			point_pcb(tcb(0))
			io.irq_regs.stat, io.irq_regs.mask = 1, 1
			bios.deliver_irq()
		}
	}
	cpu.run_events = proc() {
		s.events += 1
		s.events_s0 = r()[16]
		cpu.next_event = max(u64)
	}
	cpu.next_event = max(u64)
	put_dispatch(D_MAIN)
	put_dispatch(D_ALT)
	script()

	r()[29], r()[31] = 0x801ffe00, 0x80001234
	when core.FLAT {bios.flat_main(D_MAIN)} else {cpu.call(D_MAIN)}
	check("steps run", u32(s.n), u32(len(s.steps)))
	check("back on the main thread's sp", r()[29], 0x801ffe00)
	when core.FLAT {cpu.flat_print()}
	if failed > 0 {
		fmt.eprintfln("psx_flat_switch: %d failed", failed)
		os.exit(1)
	}
	when core.FLAT {switch_under_native()}
	passed()
}

// A ChangeTh in guest code that native code called is fatal under FLAT, the
// nested run and the native frame both being in the host's. The fatal must
// first name that native code (flat_native_fatal), or every later run dies
// the same way (MGS1's 0x800150c4, above the nested 0x8001fc3c). The hook
// runs just before the fatal, so it ends the test.
when core.FLAT {
	@(private = "file")
	switch_under_native :: proc() {
		OUTER :: 0x80030000
		NATIVE :: 0x80030100
		TASK :: 0x80030200
		outer := [?]u32{0x0c00c040, 0, 0x03e00008, 0} // jal NATIVE
		task := [?]u32{0x240a00b0, 0x01400008, 0x24090010} // PSY-Q's ChangeTh stub
		for w, k in outer {cpu.w32(OUTER + 4 * u32(k), w)}
		for w, k in task {cpu.w32(TASK + 4 * u32(k), w)}
		cpu.register_funcs({{NATIVE, proc() {cpu.call(TASK)}}})
		cpu.bios_b = proc(_: u32) {cpu.flat_block("a test's ChangeTh")}
		cpu.flat_native_fatal = proc(entries: []u32) {
			if len(entries) != 1 || entries[0] != NATIVE {
				fmt.eprintfln("FAIL psx_flat_switch: a switch under native code names %x, want %x", entries, u32(NATIVE))
				os.exit(1)
			}
			passed()
			os.exit(0)
		}
		x: cpu.Flat_Ctx
		cpu.flat_start(&x, OUTER)
		cpu.flat_run(&x)
		fmt.eprintln("FAIL psx_flat_switch: a switch under native code was not fatal")
		os.exit(1)
	}
}

@(private = "file")
passed :: proc() {
	fmt.println("ok psx_flat_switch: ChangeTh round trip, TCB writes, epc restart, syscall 3, slot reuse, preempt, a preempt in a jr's delay slot, a dropped owed switch, a preempt in native code")
}
