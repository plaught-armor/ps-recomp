// Coroutine stacks on Linux, mapped with the raw syscall.
package core

@(require) import "core:sys/linux" // used only without FLAT

// Not under FLAT, which has no coroutines (coroutine.odin).
when !FLAT {
	@(private)
	co_map_stack :: proc(n: int) -> rawptr {
		stack, err := linux.mmap(0, uint(n), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
		assert(err == .NONE, "coroutine stack")
		return stack
	}
}
