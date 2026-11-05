// No rollback on wasm (rollback.odin has the rest): there is no page write
// tracking to find what a frame changed.
package core

@(private)
RB_NEED :: "rollback: not on wasm"

@(private)
rb_start :: proc() -> bool {
	return false
}

@(private)
rb_scan :: proc(a: Rb_Area, f: proc(a: Rb_Area, off: int, data: rawptr), data: rawptr) {
	panic("rollback: not on wasm")
}
