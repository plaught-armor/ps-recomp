// The BIOS threads under FLAT (core/flat.odin): each runs on a flat run of
// its own (cpu.Flat_Ctx) instead of a coroutine. ChangeTh stops the running
// run (cpu.flat_block) after it has switched the registers, and flat_main,
// the owner of the runs, goes on with the thread switched to. An exception
// return in native code cannot stop its run: flat_switch_held is the owner
// inside it until that thread is switched back to.
//
// A thread's TCB, registers and slot bookkeeping are as in the coroutine
// model (bios.odin): only where a thread's host continuation lives differs.
// A thread that lost its slot while running (an orphan, the coroutine
// model's zombie) runs on until it switches away; its run is then dropped,
// or started over when its slot's new thread first runs.
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
				cpu.fatal("thread %d returned from its entry %#08x", i, threads[i].entry)
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

	// Switch to thread j from inside the running thread's native code, which h
	// holds, and own the runs until that thread is switched back to: its
	// registers are loaded then, and the native code goes on. The host frames
	// cannot be dropped, so a thread started over meanwhile, or a run that
	// ended, is fatal as a switch in native code is, naming it for play to
	// leave to the interpreter.
	@(private)
	flat_switch_held :: proc(h: ^cpu.Flat_Hold, j: int) {
		home := cur_thread
		// The replacements running are the held thread's, as in switch_to.
		inner := cpu.mod_inner
		cpu.mod_inner = nil
		flat.preempt_owed = false
		switch_to(j)
		ended := false
		// The scheduler's loop, as flat_main's: it lasts as long as the others run.
		for cur_thread != home && !ended {ended = flat_run_current()}
		cpu.mod_inner = inner
		cpu.flat_resume(h)
		if ended || flat.fresh[home] {
			cpu.flat_block("a thread's end or restart with a thread held")
		}
	}
}
