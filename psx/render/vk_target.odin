// The hi-res target on Vulkan (GPU=vk), headless: no surface, the picture
// reaches the window through present as the software target's does. A
// walk's draws are queued (prim_queue.odin) and drawn here by the same
// shader body as the GL target's (shaders/hi_draw.glsl), synchronously: the
// target's pixels stay in its software buffers, pushed to the GPU over the
// box the queue covers and pulled back once drawn, so every other path
// (passes, pictures, the ghost flush, present) stays software.
//
// Each level is one draw, behind a barrier, as gl_submit's: a reader of a
// cell sits above that cell's writers in the same level, so the main
// picture is read in place as an input attachment (dynamic rendering local
// read) and the ghost layer and depth buffer as buffers, a pixel at
// y * w + x.
package psx_render

import "core:fmt"
import "core:mem"
import vk "vendor:vulkan"
import "ps:core"

@(private)
gpu_vk: struct {
	// Asked for (GPU=vk) and working.
	on:          bool,
	set_layout:  vk.DescriptorSetLayout,
	pool:        vk.DescriptorPool,
	// The main picture as draw.frag's input attachment.
	set:         vk.DescriptorSet,
	layout:      vk.PipelineLayout,
	// By whether the level writes the tag (levels.depth).
	draw:        [2]vk.Pipeline,
	cmd:         vk.CommandBuffer,
	fence:       vk.Fence,
	// Host-visible: the queue, VRAM and the uniforms.
	prims:       core.Vk_Buf,
	ports:       core.Vk_Buf,
	order:       core.Vk_Buf,
	vram:        core.Vk_Buf,
	uni:         core.Vk_Buf,
	// The target's pictures, made and dropped with it: main (rgb) and tag
	// (walk << 8 | door), R32UI; the ghost layer (rgb | alpha << 24, z's
	// bits) and the depth buffer, as the software target keeps them.
	main, tag:   vk.Image,
	main_view:   vk.ImageView,
	tag_view:    vk.ImageView,
	mem:         [2]vk.DeviceMemory,
	ghost, zbuf: core.Vk_Buf,
	// Host-cached, for the CPU reads them back: main, tag, ghost and zbuf
	// at a target's size each, in that order.
	stage:       core.Vk_Buf,
	// The box's rows, as one buffer copy each.
	rows:        []vk.BufferCopy,
}

// draw.frag's uniforms (std430), gl_submit's.
@(private = "file")
Vk_Draw_Uni :: struct {
	see:   [6][4]f32,
	fog0:  [4]f32,
	fog_c: u32,
	k:     i32,
	size:  [2]f32,
	w:     i32,
}

// draw.vert's and draw.frag's push constants (shaders/draw_pc.glsl).
@(private = "file")
Vk_Draw_Push :: struct {
	prims, ports, order, vram, ghost, zbuf, uni: vk.DeviceAddress,
	zpass:                                       i32,
}

@(private = "file")
HOST :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT}
@(private = "file")
CACHED :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT, .HOST_CACHED}

// Make the instance, device and pipelines: false, reported, when there is
// no device that will do; a later failure ends the game (core's helpers).
@(private)
vk_init :: proc() -> bool {
	g := &gpu_vk
	if !core.vk_instance({}) || !core.vk_device(pixel_interlock = false) {
		return false
	}
	if !core.vkc.local_read || !core.vkc.wide {
		fmt.eprintln(core.ENV_PREFIX + "GPU=vk: the device lacks dynamic rendering local read or 64-bit shader arithmetic")
		return false
	}
	dev := core.vkc.device
	bind := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .INPUT_ATTACHMENT,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}
	linfo := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &bind,
	}
	core.vk_check(vk.CreateDescriptorSetLayout(dev, &linfo, nil, &g.set_layout), "vkCreateDescriptorSetLayout")
	size := vk.DescriptorPoolSize {
		type            = .INPUT_ATTACHMENT,
		descriptorCount = 1,
	}
	pinfo := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = 1,
		pPoolSizes    = &size,
	}
	core.vk_check(vk.CreateDescriptorPool(dev, &pinfo, nil, &g.pool), "vkCreateDescriptorPool")
	ainfo := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = g.pool,
		descriptorSetCount = 1,
		pSetLayouts        = &g.set_layout,
	}
	core.vk_check(vk.AllocateDescriptorSets(dev, &ainfo, &g.set), "vkAllocateDescriptorSets")
	sets := [1]vk.DescriptorSetLayout{g.set_layout}
	g.layout = core.vk_layout_create({.VERTEX, .FRAGMENT}, size_of(Vk_Draw_Push), sets[:])
	ALL :: vk.ColorComponentFlags{.R, .G, .B, .A}
	formats := [2]vk.Format{.R32_UINT, .R32_UINT}
	for tag in 0 ..< 2 {
		masks := [2]vk.ColorComponentFlags{ALL, tag == 1 ? ALL : {}}
		g.draw[tag] = core.vk_draw_pipeline(#load("shaders/draw.vert.spv"), #load("shaders/draw.frag.spv"), g.layout, formats[:], masks[:])
	}
	g.cmd, g.fence = core.vk_cmd_create()
	g.prims = core.vk_buf_create(size_of(prim_queue.prims), {.STORAGE_BUFFER}, HOST)
	g.ports = core.vk_buf_create(size_of(prim_queue.portals), {.STORAGE_BUFFER}, HOST)
	g.order = core.vk_buf_create(size_of(prim_queue.order), {.STORAGE_BUFFER}, HOST)
	g.vram = core.vk_buf_create(size_of(vram), {.STORAGE_BUFFER}, HOST)
	g.uni = core.vk_buf_create(size_of(Vk_Draw_Uni), {.STORAGE_BUFFER}, HOST)
	g.on = true
	fmt.eprintln(core.ENV_PREFIX + "GPU: vk (hi-res target's walks drawn on Vulkan)")
	return true
}

// A forked child leaves the parent's device and images alone, and draws
// the target in software.
vk_fork_child :: proc() {
	gpu_vk = {}
	targets[1].vk = false
}

@(private = "file")
vk_view_create :: proc(img: vk.Image) -> (v: vk.ImageView) {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = img,
		viewType = .D2,
		format = .R32_UINT,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	core.vk_check(vk.CreateImageView(core.vkc.device, &info, nil, &v), "vkCreateImageView")
	return
}

@(private = "file")
vk_buf_free :: proc(b: ^core.Vk_Buf) {
	vk.DestroyBuffer(core.vkc.device, b.buf, nil)
	vk.FreeMemory(core.vkc.device, b.mem, nil)
	b^ = {}
}

// Give target t (the hi-res one, just made) its images and buffers, the
// images in the general layout from then on.
@(private)
vk_target_make :: proc(t: ^Target) {
	g := &gpu_vk
	USAGE :: vk.ImageUsageFlags{.COLOR_ATTACHMENT, .INPUT_ATTACHMENT, .TRANSFER_SRC, .TRANSFER_DST}
	w, h := u32(t.w), u32(t.h)
	n := int(t.w * t.h)
	g.main, g.mem[0] = core.vk_image_create(w, h, .R32_UINT, USAGE)
	g.tag, g.mem[1] = core.vk_image_create(w, h, .R32_UINT, USAGE)
	g.main_view, g.tag_view = vk_view_create(g.main), vk_view_create(g.tag)
	BUF :: vk.BufferUsageFlags{.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST}
	g.ghost = core.vk_buf_create(n * 8, BUF, {.DEVICE_LOCAL})
	g.zbuf = core.vk_buf_create(n * 4, BUF, {.DEVICE_LOCAL})
	g.stage = core.vk_buf_create(n * 20, {.TRANSFER_SRC, .TRANSFER_DST}, CACHED)
	g.rows = make([]vk.BufferCopy, t.h)
	img := vk.DescriptorImageInfo {
		imageView   = g.main_view,
		imageLayout = .GENERAL,
	}
	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = g.set,
		dstBinding      = 0,
		descriptorCount = 1,
		descriptorType  = .INPUT_ATTACHMENT,
		pImageInfo      = &img,
	}
	vk.UpdateDescriptorSets(core.vkc.device, 1, &write, 0, nil)
	core.vk_begin(g.cmd, g.fence)
	bars: [2]vk.ImageMemoryBarrier
	for im, i in ([2]vk.Image{g.main, g.tag}) {
		bars[i] = {
			sType = .IMAGE_MEMORY_BARRIER,
			dstAccessMask = {.MEMORY_READ, .MEMORY_WRITE},
			oldLayout = .UNDEFINED,
			newLayout = .GENERAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = im,
			subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		}
	}
	vk.CmdPipelineBarrier(g.cmd, {.TOP_OF_PIPE}, {.ALL_COMMANDS}, {}, 0, nil, 0, nil, 2, &bars[0])
	core.vk_submit(g.cmd, g.fence, 0, 0)
}

// Free target t's images and buffers (none in a forked child).
@(private)
vk_target_drop :: proc(t: ^Target) {
	g := &gpu_vk
	if g.main == 0 {
		return
	}
	dev := core.vkc.device
	vk.DeviceWaitIdle(dev)
	vk.DestroyImageView(dev, g.main_view, nil)
	vk.DestroyImageView(dev, g.tag_view, nil)
	vk.DestroyImage(dev, g.main, nil)
	vk.DestroyImage(dev, g.tag, nil)
	for m in g.mem {
		vk.FreeMemory(dev, m, nil)
	}
	vk_buf_free(&g.stage)
	vk_buf_free(&g.ghost)
	vk_buf_free(&g.zbuf)
	delete(g.rows)
	g.rows = nil
	g.main, g.tag, g.main_view, g.tag_view, g.mem = 0, 0, 0, 0, {}
}

// The box x0..<x1, y0..<y1 of target t: its pixels to the GPU (to = true)
// or back.
@(private = "file")
vk_carry :: proc(t: ^Target, x0, y0, x1, y1: i32, to: bool) #no_bounds_check {
	g := &gpu_vk
	n := int(t.w * t.h)
	main := ([^]u32)(g.stage.ptr)
	tag := main[n:]
	ghost := ([^][2]u32)(main[2 * n:])
	zbuf := main[4 * n:]
	gh := &t.ghost
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			i := y * t.w + x
			if to {
				main[i] = t.rgb[i]
				tag[i] = u32(t.walk[i]) << 8 | u32(t.door[i])
				ghost[i] = {gh.rgb[i] & 0xffffff | u32(gh.alpha[i]) << 24, transmute(u32)gh.z[i]}
				zbuf[i] = t.zbuf[i]
			} else {
				t.rgb[i] = main[i]
				t.door[i], t.walk[i] = u8(tag[i]), u16(tag[i] >> 8)
				gh.rgb[i], gh.alpha[i], gh.z[i] = ghost[i].x & 0xffffff, u8(ghost[i].x >> 24), transmute(f32)ghost[i].y
				t.zbuf[i] = zbuf[i]
			}
		}
	}
}

// Copy the box between the staged and the drawn pictures.
@(private = "file")
vk_copy :: proc(t: ^Target, x0, y0, x1, y1: i32, to: bool) {
	g := &gpu_vk
	n := t.w * t.h
	rows := g.rows[:y1 - y0]
	for buf, i in ([2]core.Vk_Buf{g.ghost, g.zbuf}) {
		size := vk.DeviceSize(8 >> uint(i))
		at := vk.DeviceSize(n) * (8 + 8 * vk.DeviceSize(i))
		for &r, j in rows {
			px := vk.DeviceSize((y0 + i32(j)) * t.w + x0)
			r = {at + px * size, px * size, vk.DeviceSize(x1 - x0) * size}
			if !to {
				r.srcOffset, r.dstOffset = r.dstOffset, r.srcOffset
			}
		}
		if to {
			vk.CmdCopyBuffer(g.cmd, g.stage.buf, buf.buf, u32(len(rows)), &rows[0])
		} else {
			vk.CmdCopyBuffer(g.cmd, buf.buf, g.stage.buf, u32(len(rows)), &rows[0])
		}
	}
	for img, i in ([2]vk.Image{g.main, g.tag}) {
		r := vk.BufferImageCopy {
			bufferOffset = vk.DeviceSize((i32(i) * n + y0 * t.w + x0) * 4),
			bufferRowLength = u32(t.w),
			imageSubresource = {aspectMask = {.COLOR}, layerCount = 1},
			imageOffset = {x0, y0, 0},
			imageExtent = {u32(x1 - x0), u32(y1 - y0), 1},
		}
		if to {
			vk.CmdCopyBufferToImage(g.cmd, g.stage.buf, img, .GENERAL, 1, &r)
		} else {
			vk.CmdCopyImageToBuffer(g.cmd, img, .GENERAL, g.stage.buf, 1, &r)
		}
	}
}

// Draw the queue (raster_run, before its read cells are dropped) and wait
// for it: the target's pixels it covers are the software target's again
// on return.
@(private)
vk_target_submit :: proc() #no_bounds_check {
	g, q := &gpu_vk, &prim_queue
	if q.prim_n == 0 {
		return
	}
	t := &targets[1]
	first, top := queue_order()
	// The box drawn, with the ghost layer's.
	x0, y0, x1, y1 := t.w, t.h, i32(0), i32(0)
	if gh := &t.ghost; gh.lo.x < gh.hi.x && gh.lo.y < gh.hi.y {
		x0, y0, x1, y1 = max(gh.lo.x, 0), max(gh.lo.y, 0), min(gh.hi.x, t.w), min(gh.hi.y, t.h)
	}
	for &p in q.prims[:q.prim_n] {
		x0, y0 = min(x0, max(p.box.x, 0)), min(y0, max(p.box.y, 0))
		x1, y1 = max(x1, min(p.box.z + 1, t.w)), max(y1, min(p.box.w + 1, t.h))
	}
	if x0 >= x1 || y0 >= y1 {
		queue_reset()
		return
	}
	vk_carry(t, x0, y0, x1, y1, true)
	mem.copy(g.prims.ptr, &q.prims[0], q.prim_n * size_of(Gpu_Prim))
	mem.copy(g.order.ptr, &q.order[0], q.prim_n * size_of(i32))
	if q.portal_n > 0 {
		mem.copy(g.ports.ptr, &q.portals[0], q.portal_n * size_of(Gpu_Portal))
	}
	mem.copy(g.vram.ptr, &vram[0], size_of(vram))
	s, f := &see_through, &see_fade
	(^Vk_Draw_Uni)(g.uni.ptr)^ = {
		see = {
			{s.h, s.of.x, s.of.y, see.reach2},
			{s.target.x, s.target.y, s.target.z, see.stop},
			{see.across.x, see.across.y, see.across.z, see.drop},
			{f.near[0], f.near[1], f.radius - f.soft, f.radius},
			{f.floor[0], f.floor[1], f.cone_min, 0},
			{f.ghost[0], f.ghost[1], f.sprite_ghost[0], f.sprite_ghost[1]},
		},
		fog0 = {q.fog.near, q.fog.inv, f32(q.fog.most), 0},
		fog_c = q.fog.color,
		k = i32(t.shift),
		size = {f32(t.w), f32(t.h)},
		w = t.w,
	}
	push := Vk_Draw_Push {
		prims = g.prims.addr,
		ports = g.ports.addr,
		order = g.order.addr,
		vram  = g.vram.addr,
		ghost = g.ghost.addr,
		zbuf  = g.zbuf.addr,
		uni   = g.uni.addr,
	}
	cmd := g.cmd
	core.vk_begin(cmd, g.fence)
	vk_copy(t, x0, y0, x1, y1, true)
	core.vk_barrier(cmd)
	area := vk.Rect2D{{x0, y0}, {u32(x1 - x0), u32(y1 - y0)}}
	atts: [2]vk.RenderingAttachmentInfo
	for v, i in ([2]vk.ImageView{g.main_view, g.tag_view}) {
		atts[i] = {
			sType       = .RENDERING_ATTACHMENT_INFO,
			imageView   = v,
			imageLayout = .GENERAL,
			loadOp      = .LOAD,
			storeOp     = .STORE,
		}
	}
	rinfo := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = area,
		layerCount           = 1,
		colorAttachmentCount = 2,
		pColorAttachments    = &atts[0],
	}
	vk.CmdBeginRendering(cmd, &rinfo)
	view := vk.Viewport{0, 0, f32(t.w), f32(t.h), 0, 1}
	vk.CmdSetViewport(cmd, 0, 1, &view)
	vk.CmdSetScissor(cmd, 0, 1, &area)
	vk.CmdBindDescriptorSets(cmd, .GRAPHICS, g.layout, 0, 1, &g.set, 0, nil)
	// What a level drew is seen by the next, at the same pixel.
	bar := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {.SHADER_STORAGE_WRITE, .COLOR_ATTACHMENT_WRITE},
		dstStageMask  = {.FRAGMENT_SHADER, .COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE, .INPUT_ATTACHMENT_READ, .COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE},
	}
	dep := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		dependencyFlags    = {.BY_REGION},
		memoryBarrierCount = 1,
		pMemoryBarriers    = &bar,
	}
	STAGES :: vk.ShaderStageFlags{.VERTEX, .FRAGMENT}
	for lv in 1 ..= top {
		n := first[lv + 1] - first[lv]
		if n == 0 {
			continue
		}
		vk.CmdPipelineBarrier2(cmd, &dep)
		vk.CmdBindPipeline(cmd, .GRAPHICS, g.draw[levels.depth[lv] ? 1 : 0])
		if levels.z[lv] {
			levels.z[lv] = false
			push.zpass = 1
			vk.CmdPushConstants(cmd, g.layout, STAGES, 0, size_of(push), &push)
			vk.CmdDraw(cmd, u32(n * 6), 1, u32(first[lv] * 6), 0)
			vk.CmdPipelineBarrier2(cmd, &dep)
			push.zpass = 0
		}
		vk.CmdPushConstants(cmd, g.layout, STAGES, 0, size_of(push), &push)
		vk.CmdDraw(cmd, u32(n * 6), 1, u32(first[lv] * 6), 0)
	}
	vk.CmdEndRendering(cmd)
	core.vk_barrier(cmd)
	vk_copy(t, x0, y0, x1, y1, false)
	host := vk.MemoryBarrier {
		sType         = .MEMORY_BARRIER,
		srcAccessMask = {.MEMORY_WRITE},
		dstAccessMask = {.HOST_READ},
	}
	vk.CmdPipelineBarrier(cmd, {.ALL_COMMANDS}, {.HOST}, {}, 1, &host, 0, nil, 0, nil)
	core.vk_submit(cmd, g.fence, 0, 0)
	fence := g.fence
	core.vk_check(vk.WaitForFences(core.vkc.device, 1, &fence, true, max(u64)), "vkWaitForFences")
	vk_carry(t, x0, y0, x1, y1, false)
	// The shader marks glowing pixels in the picture only: mark the tiles
	// (bloom_mark) under every additive glowing primitive, which
	// bloom_prepare clears again where none was drawn.
	sh := t.shift + 4
	for &p in q.prims[:q.prim_n] {
		f := transmute(Gpu_Flags)p.h.x
		if .Glow not_in f || .Semi not_in f || (p.m.x >> 2) & 3 != 1 {
			continue
		}
		for ty in max(p.box.y, 0) >> sh ..= min(p.box.w, t.h - 1) >> sh {
			for tx in max(p.box.x, 0) >> sh ..= min(p.box.z, t.w - 1) >> sh {
				glow_tiles[ty][tx] = true
			}
		}
	}
	queue_reset()
}
