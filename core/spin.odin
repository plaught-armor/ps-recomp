// Busy-wait back-off for threads waiting on each other's progress.
package core

import "base:intrinsics"
import "core:thread"

// Back off for the spin'th time while waiting on another thread: a pause
// for the first rounds, then yield the core.
spin_pause :: #force_inline proc(spin: int) {
	if spin < 256 {
		intrinsics.cpu_relax()
	} else {
		thread.yield()
	}
}
