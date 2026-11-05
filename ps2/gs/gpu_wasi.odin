// No GPU GS on wasm (gpu.odin needs Vulkan): hw_init fails, so hw_on stays
// false and the software GS draws; nothing else here is reached.
package ps2_gs

import "core:fmt"
import sdl "vendor:sdl2"

hw_init :: proc(win: ^sdl.Window, scale: u32) -> bool {
	fmt.eprintln("gs: no GPU GS on wasm")
	return false
}

hw_screen :: proc() -> (px: []u32, w, h: int) {panic("gs: no GPU GS on wasm")}
hw_snap_save :: proc(id: int) {panic("gs: no GPU GS on wasm")}
hw_snap_load :: proc(id: int) {panic("gs: no GPU GS on wasm")}
hw_download :: proc() {panic("gs: no GPU GS on wasm")}
hw_upload :: proc(psm, bp, bw, x0, y0, w, start: u32, px: []u32) {panic("gs: no GPU GS on wasm")}
hw_copy :: proc(sbp, sbw, spsm, dbp, dbw, dpsm, sx, sy, dx, dy, w, h: u32) {panic("gs: no GPU GS on wasm")}
hw_clut :: proc(cpsm, cbp, cbw, cou, cov: u32, csm2: bool, n, base: u32) {panic("gs: no GPU GS on wasm")}
hw_draw :: proc(c: ^Ctx, kind: u64) {panic("gs: no GPU GS on wasm")}
hw_frame :: proc(psm, fbp, fbw, dbx, dby: u32, w, h: int) {panic("gs: no GPU GS on wasm")}
