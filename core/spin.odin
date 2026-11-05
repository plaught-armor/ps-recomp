// Busy-wait back-off for threads waiting on each other's progress.
package core

import "base:intrinsics"
@(require) import "core:thread" // used only when THREADS

// Back off for the spin'th time while waiting on another thread: a pause
// for the first rounds, then yield the core. Without threads (THREADS) it
// never yields.
spin_pause :: #force_inline proc(spin: int) {
	when THREADS {
		if spin >= 256 {
			thread.yield()
			return
		}
	}
	intrinsics.cpu_relax()
}
