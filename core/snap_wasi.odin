package core

import "core:mem"

// `n` bytes of zeroed memory, from the heap: wasm has no lazily committed
// mappings. Page aligned, as the other targets' mappings are: the emulated
// heap's buddy allocator needs its alignment from the start of the block.
// From long_allocator, as a mapping is from the OS: the caller's context may
// be the emulated heap (a snapshot area made during init), which would hold
// the area a second time, and its buddy allocator does not page-align.
@(private)
snap_map :: proc(n: int) -> []u8 {
	b, err := mem.make_aligned([]u8, n, PAGE, long_allocator())
	assert(err == nil, "snapshot memory")
	return b
}
