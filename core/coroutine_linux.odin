// Coroutine stacks on Linux, mapped with the raw syscall.
package core

import "core:sys/linux"

@(private)
co_map_stack :: proc(n: int) -> rawptr {
	stack, err := linux.mmap(0, uint(n), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	assert(err == .NONE, "coroutine stack")
	return stack
}
