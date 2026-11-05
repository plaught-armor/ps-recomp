// No compatibility runs on wasm: it cannot start a child process
// (compat.odin), so no run is ever a child to watch its parent.
package play

@(private)
parent_gone_wait :: proc(pid: int) {
	panic("play: no compat child on wasm")
}

@(private)
parent_exit :: proc(status: int) -> ! {
	panic("play: no compat child on wasm")
}
