// No Vulkan target on wasm (vk_target.odin): vk_init fails, so gpu_vk.on
// stays false and the software target draws; nothing else here is reached.
package psx_render

@(private)
gpu_vk: struct {
	on:     bool,
	frames: [EXTRA_FRAMES + 1]struct {
		mark: int,
	},
}

@(private)
vk_init :: proc() -> bool {
	return false
}

@(private)
vk_target_make :: proc(t: ^Target) {panic("render: no Vulkan on wasm")}
@(private)
vk_target_drop :: proc(t: ^Target) {panic("render: no Vulkan on wasm")}
@(private)
vk_target_submit :: proc() {panic("render: no Vulkan on wasm")}
@(private)
vk_frame :: proc(slot: int, x, y, w, h: i32) {panic("render: no Vulkan on wasm")}
@(private)
vk_frame_take :: proc(slot: int) -> []u32 {panic("render: no Vulkan on wasm")}
@(private)
vk_frame_bright :: proc(mark: int) -> (bright, known: bool) {panic("render: no Vulkan on wasm")}
