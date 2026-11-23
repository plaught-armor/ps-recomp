// The BIOS threads under FLAT (core/flat.odin): each runs on a flat run of
// its own (cpu.Flat_Ctx) instead of a coroutine. ChangeTh stops the running
// run (cpu.flat_block) after it has switched the registers, and flat_main,
// the owner of the runs, goes on with the thread switched to. An exception
// return in native code cannot stop its run: flat_switch_held is the owner
// inside it until that thread, or one held below it, is switched back to.
//
// A thread's TCB, registers and slot bookkeeping are as in the coroutine
// model (bios.odin): only where a thread's host continuation lives differs.
// A thread that lost its slot while running (an orphan, the coroutine
// model's zombie) runs on until it switches away; its run is then dropped,
// or started over when its slot's new thread first runs.
//
// A preempt's switch can be owed until native code returned and interrupts
// are on. A ChangeTh before then writes the PCB, which would take that switch
// back, so the owed one lands first and the ChangeTh waits on a continuation
// (change_waits): on the console the caller was preempted before it got to
// make that call.
package psx_bios

import "ps:core"

@(require) import cpu "../cpu"

when core.FLAT {
	@(private)
	Bios_Flat :: struct {
		// By slot.
		ctx:    [MAX_THREADS]cpu.Flat_Ctx,
		// The slot's thread has a run (the coroutine model's co != nil).
		live:   [MAX_THREADS]bool,
		// Its run starts over at threads[i].entry when it next runs.
		fresh:  [MAX_THREADS]bool,
		// Held in native code (flat_switch_held), the last held on top.
		held:   [MAX_THREADS]bool,
		// The running thread lost its slot.
		orphan: bool,
		// An exception return named another thread (preempt): the runs' owner
		// switches once the running run has stopped (cpu.flat_stop_soon).
		preempt_owed: bool,
		// Slot 0's run is the executable's entry's.
		boot: bool,
	}

	@(private)
	flat: Bios_Flat

	// The continuation tag of a ChangeTh that waits (beside cpu.FLAT_MOD).
	@(private = "file")
	FLAT_CHANGE :: cpu.FLAT_MOD + 1

	// Whether ChangeTh to slot i waits for the switch a preempt owes: the run
	// stops for that one, and makes the call when it next runs. Not for a
	// switch the PCB took back, nor in native code (which flat_block names),
	// nor for an orphan, whose run would be dropped with the call.
	@(private)
	change_waits :: proc(i: int) -> bool {
		if !flat.preempt_owed || !cpu.flat_can_stop() || !slot_owned() {return false}
		if _, ok := preempt_target(); !ok {return false}
		cpu.flat_push_cont(FLAT_CHANGE).w[0] = u32(i)
		cpu.flat_block("ChangeTh")
		return true
	}

	// cpu.flat_step for the PS1: a ChangeTh that waited is made, and any other
	// continuation is a mod thunk's.
	flat_step :: proc(x: ^cpu.Flat_Ctx, h: ^cpu.Flat_Host) {
		if h.tag != FLAT_CHANGE {
			cpu.mod_flat_step(x, h)
			return
		}
		i := h.w[0]
		cpu.flat_pop_cont()
		change_thread(i)
	}
}

when core.FLAT {
	// Run the executable's entry pc as the main thread (slot 0), and the
	// threads it switches to, until the entry returns.
	flat_main :: proc(pc: u32) {
		when core.FLAT {
			threads[0].entry = pc
			cpu.flat_start(&flat.ctx[0], pc)
			flat.boot = true
			for {
				i := cur_thread
				if !flat_run_current() {continue}
				if i == 0 && flat.boot {return}
				thread_returned(i)
			}
		}
	}

	// Run the current thread until it ends (true) or stops, and take the
	// switch it owed then.
	@(private = "file")
	flat_run_current :: proc() -> bool {
		i := cur_thread
		x := &flat.ctx[i]
		if flat.fresh[i] {
			flat.fresh[i] = false
			if i == 0 {flat.boot = false}
			cpu.flat_start(x, threads[i].entry)
		}
		ended := cpu.flat_run(x)
		if !flat.preempt_owed {return ended}
		flat.preempt_owed = false
		if ended {return true}
		if j, ok := preempt_target(); ok {
			switch_to(j)
		} else {
			cpu.flat_switches_dropped += 1
		}
		return false
	}

	@(private = "file")
	thread_returned :: proc(i: int) -> ! {
		cpu.fatal("thread %d returned from its entry %#08x", i, threads[i].entry)
	}

	// Switch to thread j from inside the running thread's native code, which h
	// holds, and own the runs until that thread, or one held below it, is
	// switched back to. Its native code goes on then with its registers. For
	// one below, whose frames cannot go on before these, that switch is owed
	// as a preempt's in native code is: the native code returns first, and the
	// thread below is late by as long.
	//
	// The host frames cannot be dropped, so a held thread closed or started
	// over is fatal, naming the native code for play to leave to the
	// interpreter. A thread's return from its entry is fatal as in flat_main,
	// and the executable's with a thread held, its frames being above
	// flat_main's: neither is the native code's, so neither names it. A thread
	// held never runs, so is never held again.
	@(private)
	flat_switch_held :: proc(h: ^cpu.Flat_Hold, j: int) {
		home := cur_thread
		flat.preempt_owed = false
		to := flat_held_run(home, j)
		cpu.flat_resume(h)
		if flat.fresh[home] || to != home && !resumable(home) {
			cpu.flat_block("a thread closed or started over while held")
		} else if to != home {
			switch_to(home)
			cpu.w32(pcb(), KSEG1 | tcb(to))
			cpu.flat_stop_soon()
			flat.preempt_owed = true
		}
	}

	// Whether switch_to would go on with thread i's host continuation: it
	// kept its slot, and its TCB the epc it stopped with.
	@(private = "file")
	resumable :: proc(i: int) -> bool {
		return i < thread_count() && thread_started(i) && cpu.r32(tcb(i) + TCB_EPC) == TCB_PARKED
	}

	// Hold thread home, switch to thread j (none for -1: a ChangeTh made
	// it), and own the runs until a held thread is switched to: that one is
	// returned.
	@(private = "file")
	flat_held_run :: proc(home, j: int) -> int {
		flat.held[home] = true
		// The replacements running are the held thread's, as in switch_to.
		inner := cpu.mod_inner
		cpu.mod_inner = nil
		if j >= 0 {switch_to(j)}
		ended := false
		// The scheduler's loop, as flat_main's: it lasts as long as the others run.
		for !ended && !flat.held[cur_thread] {ended = flat_run_current()}
		to := cur_thread
		if ended {
			if to == 0 && flat.boot {
				cpu.fatal("the executable returned from its entry with a thread held in native code (FLAT)")
			}
			thread_returned(to)
		}
		flat.held[home] = false
		cpu.mod_inner = inner
		return to
	}

	// cpu.flat_thread: the running thread's slot.
	flat_thread :: proc() -> int {return cur_thread}

	// cpu.flat_others: the run of thread home, inside a game task held in
	// its native code (cpu.task_go), stopped for a thread switch, a preempt's
	// owed or a ChangeTh's made. The others run, as in flat_switch_held, until
	// home is switched back to; its run goes on then. A switch to a thread
	// held below cannot be owed on past the native code, as flat_switch_held
	// owes it: the run that stopped is the other game task's, not the native
	// code's.
	flat_others :: proc(home: int) {
		j := -1
		if flat.preempt_owed {
			flat.preempt_owed = false
			if i, ok := preempt_target(); ok {
				j = i
			} else {
				cpu.flat_switches_dropped += 1
			}
		}
		if j < 0 && cur_thread == home {return}
		if to := flat_held_run(home, j); to != home {
			cpu.fatal("thread %d switched to inside thread %d's game task held in native code (FLAT): it is held below", to, home)
		}
	}
}
