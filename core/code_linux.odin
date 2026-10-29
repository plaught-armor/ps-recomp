// Executable memory on Linux, mapped with the raw syscall.
package core

import "core:sys/linux"

// `code` copied into new memory that can run and not be written. On arm64
// the kernel makes the instruction cache coherent when the page becomes
// executable.
map_code :: proc(code: []u8) -> rawptr {
	n := uint(code_size(len(code)))
	page, err := linux.mmap(0, n, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	ensure(err == .NONE, "code memory")
	copy(([^]u8)(page)[:len(code)], code)
	ensure(linux.mprotect(page, n, {.READ, .EXEC}) == .NONE, "code memory")
	return page
}

// Free memory from map_code; n is the length of the code it was given.
unmap_code :: proc(base: rawptr, n: int) {
	ensure(linux.munmap(base, uint(code_size(n))) == .NONE, "code memory")
}
