// No executable memory on wasm: a module cannot map machine code, so the
// native blob and the coroutine switch have no host code there yet (phase 8
// runs guest code as a generated wasm module instead).
package core

map_code :: proc(code: []u8) -> rawptr {
	panic("core: no executable memory on wasm")
}

unmap_code :: proc(base: rawptr, n: int) {
	panic("core: no executable memory on wasm")
}
