// The spin skip: an EE loop that comes back to the same state skips ahead
// to just before the next event, charging the cycles it would have spent.
//
// Native code (recomp/r5900/native.odin spin) counts spin_tick down at the
// backward branch of each small loop, after its events check, and calls
// spin_probe with the branch's pc when it reaches 0. The first call arms
// the probe: it snapshots the EE state (cpu.state but cycles, and VU0),
// clears cpu.spin_dirty and sends every store to mem.spin_store. The next
// call at the same branch compares. With the same state, no store that
// changed memory or reached a register, and nothing else in cpu.spin_dirty
// (a register read, a syscall, the interpreter, COP0 Count, run_events),
// one pass of the loop took d cycles and left everything as it found it, so
// each pass after it does the same until an event runs; and only an event
// (cycles reaching cpu.next_event, then run_events) changes what the loop
// sees, as every deadline the EE has is in next_event. The probe then adds
// the passes that end before next_event at once: n passes of d cycles, with
// n the most for which cycles + n*d <= next_event - 1. Every events check
// in the passes skipped is at a cycle count at most the end of its pass, so
// below next_event: none of them would have run run_events, and the run is
// the same as without the skip, cycle for cycle.
//
// A pass may also go round other threads at the loop's priority: a loop
// that yields with RotateThreadReadyQueue to one that yields back (a thread
// idling while another polls). The probe then passes the other loops'
// branches on its way back round, and waits for its own (SPIN_FOREIGN_MAX).
// The rotate marks cpu.SPIN_ROTATE in place of SPIN_SIDE, and the probe
// compares the threads as well (kernel/spin.odin): with the same thread
// current, each thread as it was (the registers it saved, its status and
// wait), and the ready order kept, the pass repeats like any other, the
// threads switching back and forth at the same points; the skip then moves
// the ready order on by n passes as well.
//
// SPIN=0 turns it off. STATS counts the cycles it skipped (cpu.spin_cycles);
// they are not idle cycles.
package ps2

import "base:runtime"
import cpu "cpu"
import kernel "kernel"
import mem "mem"
import vu "vu"

// Backward branches until the next probe. Not private: native code
// imports it as ps2.spin_tick.
spin_tick: i32 = 1

// SPIN=0 sets it false (load_native).
spin_on := true

// The probe waits this many backward branches after one that fails on the
// loop's own work, doubling each time up to the most.
@(private = "file")
SPIN_BACK_MIN :: 64
@(private = "file")
SPIN_BACK_MAX :: 4096

// The other loops' branches an armed probe passes before it gives up on
// coming back to its own. A pass that rotates round the threads at one
// priority passes one for each other thread spinning there, and these are
// few (an idle thread and a poller); 16 leaves room for more, and for a
// loop nested in the one armed, while a probe that never comes back costs
// only 16 branches of stores checked on the slow path before it backs off
// as at a failed compare.
@(private = "file")
SPIN_FOREIGN_MAX :: 16

// The EE state the probe compares: cpu.state up to cycles
// (cpu.STATE_BYTES), and VU0's registers up to the memory slices.
@(private = "file")
VU_BYTES :: int(offset_of(vu.Vu, cmsar)) + size_of(u32)

@(private = "file")
spin: struct {
	site:   u32, // the backward branch armed at
	cycles: u64, // cycles when armed
	back:   i32,
	passed: i32, // other branches passed since armed
	cpu:    cpu.Cpu,
	vu0:    vu.Vu,
}

spin_probe :: proc(site: u32) {
	if !spin_on {
		spin_tick = max(i32)
		return
	}
	if spin.back == 0 {spin.back = SPIN_BACK_MIN}
	if mem.spin_armed {
		if site != spin.site && spin.passed < SPIN_FOREIGN_MAX {
			spin.passed += 1
			spin_tick = 1
			return
		}
		spin_disarm()
		dirty := cpu.spin_dirty
		same :=
			site == spin.site &&
			runtime.memory_equal(&cpu.state, &spin.cpu, cpu.STATE_BYTES) &&
			runtime.memory_equal(&vu.vu0, &spin.vu0, VU_BYTES)
		now, next := cpu.state.cycles, cpu.next_event
		d := now - spin.cycles
		rotated := dirty & cpu.SPIN_ROTATE != 0
		skip := same && dirty &~ cpu.SPIN_ROTATE == 0 && d > 0 && now < next && !cpu.in_interrupt && next != max(u64)
		if skip && rotated {skip = kernel.spin_threads_same()}
		if skip {
			// Every pass skipped ends at or before now + n*d <= next - 1,
			// below next_event; see the top of the file.
			n := (next - 1 - now) / d
			cpu.state.cycles = now + n * d
			cpu.spin_cycles += n * d
			if rotated {kernel.spin_threads_skip(n, d)}
			spin.back = SPIN_BACK_MIN
			spin_tick = 1 // arm again for the pass after the event
			return
		}
		if dirty == cpu.SPIN_EVENT {
			// Only an event ran in the pass, which may have changed the
			// state: arm again past it.
			spin_tick = 1
			return
		}
		spin.back = min(spin.back * 2, SPIN_BACK_MAX)
		spin_tick = spin.back
		return
	}
	if cpu.in_interrupt || cpu.next_event == max(u64) || mem.watch_len != 0 {
		spin_tick = spin.back
		return
	}
	spin.site, spin.cycles, spin.passed = site, cpu.state.cycles, 0
	spin.cpu, spin.vu0 = cpu.state, vu.vu0
	cpu.spin_dirty = 0
	mem.spin_armed = true
	mem.watch_on, mem.fast_lim = 1, 0
	spin_tick = 1
}

// Stores back to their fast paths, as WATCH leaves them.
@(private = "file")
spin_disarm :: proc() {
	mem.spin_armed = false
	watch := mem.watch_len != 0
	mem.watch_on = watch ? 1 : 0
	mem.fast_lim = watch ? 0 : mem.RAM_SIZE
}
