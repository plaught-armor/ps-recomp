package core

import "core:sys/posix"

// `n` bytes of zeroed memory, committed as it is used.
@(private)
snap_map :: proc(n: int) -> []u8 {
	base := posix.mmap(nil, uint(n), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	assert(base != posix.MAP_FAILED, "snapshot memory")
	return ([^]u8)(base)[:n]
}
