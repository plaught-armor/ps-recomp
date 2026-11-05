package core

import "base:runtime"

// The allocator for memory kept past the current frame, whatever
// context.allocator is: the heap natively, the wasm allocator on wasm, where
// runtime.heap_allocator is not implemented.
//
// Untracked, and usable before snap_init. host_allocator (core/snap.odin)
// is the one for host memory the tracking allocator should see, such as
// snapshot buffers, but it is nil until snap_init; use long_allocator for
// memory that may be made before then or that is never freed, and
// host_allocator for host memory made after snap_init.
long_allocator :: proc() -> runtime.Allocator {
	return runtime.default_allocator()
}
