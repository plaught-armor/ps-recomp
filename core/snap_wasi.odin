package core

// `n` bytes of zeroed memory, from the heap: wasm has no lazily committed
// mappings.
@(private)
snap_map :: proc(n: int) -> []u8 {
	return make([]u8, n)
}
