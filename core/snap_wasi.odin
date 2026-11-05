package core

import "core:mem"

// `n` bytes of zeroed memory, from the heap: wasm has no lazily committed
// mappings. Page aligned, as the other targets' mappings are: the emulated
// heap's buddy allocator needs its alignment from the start of the block.
@(private)
snap_map :: proc(n: int) -> []u8 {
	b, err := mem.make_aligned([]u8, n, PAGE)
	assert(err == nil, "snapshot memory")
	return b
}
