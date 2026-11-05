// Coroutine stacks on macOS.
package core

@(require) import "core:sys/posix" // used only without FLAT

// Not under FLAT, which has no coroutines (coroutine.odin).
when !FLAT {
	@(private)
	co_map_stack :: proc(n: int) -> rawptr {
		stack := posix.mmap(nil, uint(n), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
		assert(stack != posix.MAP_FAILED, "coroutine stack")
		return stack
	}
}
