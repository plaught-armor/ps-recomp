package core

import "core:sys/linux"

// `n` bytes of zeroed memory, committed as it is used.
@(private)
snap_map :: proc(n: int) -> []u8 {
	base, err := linux.mmap(0, uint(n), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS, .NORESERVE})
	assert(err == .NONE, "snapshot memory")
	return ([^]u8)(base)[:n]
}
