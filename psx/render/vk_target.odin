// The hi-res target on Vulkan (GPU=vk), headless: no surface, the picture
// reaches the window through present as the software target's does. The
// target's images are made and dropped with it, but it is still drawn in
// software, so its output is the software target's.
package psx_render

import "core:fmt"
import vk "vendor:vulkan"
import "ps:core"

@(private)
gpu_vk: struct {
	// Asked for (GPU=vk) and working.
	on:                     bool,
	// The target's pictures, as the GL target's textures: main and tag
	// R32UI, ghost RG32UI, zbuf R32UI.
	main, tag, ghost, zbuf: vk.Image,
	mem:                    [4]vk.DeviceMemory,
}

// Make the instance and device; a failure ends the game (core's helpers).
@(private)
vk_init :: proc() {
	core.vk_instance({})
	core.vk_device(pixel_interlock = false)
	gpu_vk.on = true
	fmt.eprintln(core.ENV_PREFIX + "GPU: vk (hi-res target drawn in software)")
}

// A forked child leaves the parent's device and images alone.
vk_fork_child :: proc() {
	gpu_vk = {}
}

// Give target t (the hi-res one, just made) its images.
@(private)
vk_target_make :: proc(t: ^Target) {
	g := &gpu_vk
	USAGE :: vk.ImageUsageFlags{.STORAGE, .TRANSFER_SRC, .TRANSFER_DST}
	w, h := u32(t.w), u32(t.h)
	g.main, g.mem[0] = core.vk_image_create(w, h, .R32_UINT, USAGE)
	g.tag, g.mem[1] = core.vk_image_create(w, h, .R32_UINT, USAGE)
	g.ghost, g.mem[2] = core.vk_image_create(w, h, .R32G32_UINT, USAGE)
	g.zbuf, g.mem[3] = core.vk_image_create(w, h, .R32_UINT, USAGE)
}

// Free target t's images (none in a forked child).
@(private)
vk_target_drop :: proc(t: ^Target) {
	g := &gpu_vk
	if g.main == 0 {
		return
	}
	vk.DeviceWaitIdle(core.vkc.device)
	for img in ([4]vk.Image{g.main, g.tag, g.ghost, g.zbuf}) {
		vk.DestroyImage(core.vkc.device, img, nil)
	}
	for m in g.mem {
		vk.FreeMemory(core.vkc.device, m, nil)
	}
	g.main, g.tag, g.ghost, g.zbuf, g.mem = 0, 0, 0, 0, {}
}
