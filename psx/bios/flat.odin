// The BIOS threads under FLAT (core/flat.odin): each runs on a flat run of
// its own (cpu.Flat_Ctx) instead of a coroutine. ChangeTh stops the running
// run (cpu.flat_block) after it has switched the registers, and flat_main,
// the owner of the runs, goes on with the thread switched to.
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
			boot := true // slot 0's run is the entry's
			for {
				i := cur_thread
				x := &flat.ctx[i]
				if flat.fresh[i] {
					flat.fresh[i] = false
					if i == 0 {boot = false}
					cpu.flat_start(x, threads[i].entry)
				}
				if !cpu.flat_run(x) {continue}
				if i == 0 && boot {return}
				cpu.fatal("thread %d returned from its entry %#08x", i, threads[i].entry)
			}
		}
	}
}
