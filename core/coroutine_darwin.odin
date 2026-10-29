// Coroutine stacks on macOS.
package core

import "core:sys/posix"

@(private)
co_map_stack :: proc(n: int) -> rawptr {
	stack := posix.mmap(nil, uint(n), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	assert(stack != posix.MAP_FAILED, "coroutine stack")
	return stack
}
