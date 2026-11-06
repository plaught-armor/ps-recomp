// No executable memory on wasm: a module cannot map machine code, so the
// coroutine switch has no host code there. A native blob's code is a wasm
// module instead, which the host (web/native.js) compiles and puts in the
// runtime's function table.
package core

map_code :: proc(code: []u8) -> rawptr {
	panic("core: no executable memory on wasm")
}

unmap_code :: proc(base: rawptr, n: int) {
	panic("core: no executable memory on wasm")
}

foreign import ps_native "system:ps_native"

@(default_calling_convention = "c")
foreign ps_native {
	// Compile and instantiate the module code[:n], its import slot k the
	// global env.s<k> = slots[k], its functions put in the table from the
	// index returned (0 when the host cannot); n_funcs^ = how many.
	@(link_name = "instantiate")
	wasm_instantiate :: proc(code: [^]u8, n: u32, slots: [^]u32, n_slots: u32, n_funcs: ^u32) -> u32 ---
	// Clear the table range instantiate returned at base and free it for
	// the next one.
	@(link_name = "release")
	wasm_release :: proc(base: u32) ---
}
