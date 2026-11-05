// No coroutine switch on wasm: its stacks are not addressable, so the switch
// (coroutine.odin) cannot run there. These stand in for an ABI's file and an
// OS's file so the package builds; starting a coroutine stops the run.
package core

@(private)
CO_CODE := [1]u8{}

@(private)
CO_TRAMPOLINE :: 0

@(private)
co_map_stack :: proc(n: int) -> rawptr {
	panic("core: no coroutine switch on wasm yet")
}

@(private)
co_frame :: proc(co: ^Coroutine, top: uintptr) -> rawptr {
	panic("core: no coroutine switch on wasm yet")
}
