// The hi-res target on Vulkan (GPU=vk), headless: no surface, the picture
// reaches the window through present as the software target's does. Its
// draws are queued (prim_queue.odin) and drawn here by the same
// shader body as the GL target's (shaders/hi_draw.glsl), synchronously: the
// software target's planes are host-cached memory laid out as the GPU's
// pictures, which the GPU copies over the box the queue covers and back
// once drawn, so every other path (passes, pictures, the ghost flush,
// present) reads and writes them in place after raster_sync, staying
// software.
//
// Each level is one draw, behind a barrier, as gl_submit's: a reader of a
// cell sits above that cell's writers in the same level, so the main
// picture is read in place as an input attachment (dynamic rendering local
// read) and the ghost layer and depth buffer as buffers, a pixel at
// y * w + x.
package psx_render

import "base:intrinsics"
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
	// The main picture as draw.frag's input attachment, or with interlock
	// the three pictures as its storage images.
	set:         vk.DescriptorSet,
	layout:      vk.PipelineLayout,
	// By whether the level writes the tag (levels.depth); with interlock
	// one pipeline, the tag a push constant.
	draw:        [2]vk.Pipeline,
	// draw_lock.frag draws (the device has ordered pixel interlock, and
	// the VK_INTERLOCK setting is 1; off by default): a queue is one level
	// (levels.single).
	interlock:   bool,
	cmd:         vk.CommandBuffer,
	fence:       vk.Fence,
	// Host-visible: the queue, VRAM and the uniforms.
	prims:       core.Vk_Buf,
	ports:       core.Vk_Buf,
	order:       core.Vk_Buf,
	vram:        core.Vk_Buf,
	uni:         core.Vk_Buf,
	// VRAM as last uploaded to vram (vk_vram_sync).
	shadow:      ^[VRAM_W * VRAM_H]u16,
	// The target's pictures, made and dropped with it, as VK_IMAGES and
	// VK_BUFS list them.
	img:         [len(VK_IMAGES)]vk.Image,
	view:        [len(VK_IMAGES)]vk.ImageView,
	mem:         [len(VK_IMAGES)]vk.DeviceMemory,
	bufs:        [len(VK_BUFS)]core.Vk_Buf,
	// Host-cached: the software target's planes themselves, at VK_IMAGES'
	// and VK_BUFS' offsets.
	stage:       core.Vk_Buf,
	// The box's rows, as one buffer copy each.
	rows:        []vk.BufferCopy,
	// The conversions (vk_frame): frame.comp's and bloom.comp's pipelines
	// and layout; the area's pixels copied to the device (made with the
	// target), as two runs a row at most (copies); the glow's and the
	// depth of field's blur stages at the PS1's resolution; the uniforms,
	// the lit flag, and each frame slot's pixels read back.
	frame_layout: vk.PipelineLayout,
	frame_pipe:  vk.Pipeline,
	bloom_pipe:  vk.Pipeline,
	frame_rgb:   core.Vk_Buf,
	copies:      []vk.BufferCopy,
	glow, blur:  [2]core.Vk_Buf,
	frame_uni:   core.Vk_Buf,
	frame_lit:   core.Vk_Buf,
	frames:      [EXTRA_FRAMES + 1]Vk_Frame,
	// Whether each of the last GL_MARKS conversions has a lit pixel
	// (conversion n's is bright[n % GL_MARKS]) and the conversions made.
	bright:      [GL_MARKS]bool,
	marks:       int,
}

// An area of the target converted to XRGB8888 (vk_frame): its pixels, a
// row of w each, in buf (host-cached), and its conversion's number.
@(private)
Vk_Frame :: struct {
	buf:  core.Vk_Buf,
	px:   int,
	w:    i32,
	mark: int,
}

// Where each picture's plane sits in the stage: its offset, in bytes per
// target pixel, and its pixel's size. The images, draw.frag's attachments:
// main (rgb, R32UI), walk (R16UI) and door (R8UI).
@(private = "file")
VK_IMAGES :: [3][2]int{{0, 4}, {16, 2}, {18, 1}}
@(private = "file")
VK_FORMATS :: [3]vk.Format{.R32_UINT, .R16_UINT, .R8_UINT}
// The buffers: the ghost layer's rgb, alpha and z, and the depth buffer.
@(private = "file")
VK_BUFS :: [4][2]int{{8, 4}, {19, 1}, {12, 4}, {4, 4}}
// Main's plane while a pass draws into its own buffer (Pass.hi) in place
// of the target's: the box's rows go through it.
@(private = "file")
VK_PASS :: 20
@(private = "file")
VK_STAGE :: 24

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

// frame.comp's and bloom.comp's uniforms (shaders/frame_pc.glsl).
@(private = "file")
Vk_Frame_Uni :: struct {
	area, size_k, fx, dof, vig: [4]i32,
	grade:                      [4][4]i32,
}

// frame.comp's and bloom.comp's push constants (shaders/frame_pc.glsl).
@(private = "file")
Vk_Frame_Push :: struct {
	rgb, src, dst, glow, blur, px, bright, uni: vk.DeviceAddress,
	stage, every:                               i32,
}

// draw.vert's and draw.frag's push constants (shaders/draw_pc.glsl).
@(private = "file")
Vk_Draw_Push :: struct {
	prims, ports, order, vram:              vk.DeviceAddress,
	ghost_rgb, ghost_a, ghost_z, zbuf, uni: vk.DeviceAddress,
	zpass, tags:                            i32,
}

@(private = "file")
HOST :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT}
@(private = "file")
CACHED :: vk.MemoryPropertyFlags{.HOST_VISIBLE, .HOST_COHERENT, .HOST_CACHED}

// Make the instance, device and pipelines: false, reported, with nothing
// left made, when there is no device that will do; a later failure ends
// the game (core's helpers).
@(private)
vk_init :: proc() -> bool {
	g := &gpu_vk
	want := core.env("VK_INTERLOCK") == "1"
	if !core.vk_instance({}) || !core.vk_device(pixel_interlock = false, want_interlock = want) {
		return false
	}
	if !core.vkc.local_read || !core.vkc.wide {
		fmt.eprintln(core.ENV_PREFIX + "GPU=vk: the device lacks dynamic rendering local read or 64-bit shader arithmetic")
		core.vk_release()
		return false
	}
	g.interlock = core.vkc.interlock
	for f in VK_FORMATS {
		fp: vk.FormatProperties
		vk.GetPhysicalDeviceFormatProperties(core.vkc.phys, f, &fp)
		if .STORAGE_IMAGE not_in fp.optimalTilingFeatures {
			g.interlock = false
		}
	}
	levels.single = g.interlock
	dev := core.vkc.device
	binds: [len(VK_IMAGES)]vk.DescriptorSetLayoutBinding
	for &b, i in binds {
		b = {
			binding         = u32(i),
			descriptorType  = g.interlock ? .STORAGE_IMAGE : .INPUT_ATTACHMENT,
			descriptorCount = 1,
			stageFlags      = {.FRAGMENT},
		}
	}
	linfo := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = g.interlock ? len(binds) : 1,
		pBindings    = &binds[0],
	}
	core.vk_check(vk.CreateDescriptorSetLayout(dev, &linfo, nil, &g.set_layout), "vkCreateDescriptorSetLayout")
	size := vk.DescriptorPoolSize {
		type            = binds[0].descriptorType,
		descriptorCount = linfo.bindingCount,
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
	formats := VK_FORMATS
	for tag in 0 ..< 2 {
		if g.interlock {
			g.draw[tag] = core.vk_draw_pipeline(#load("shaders/draw.vert.spv"), #load("shaders/draw_lock.frag.spv"), g.layout)
			continue
		}
		masks := [3]vk.ColorComponentFlags{ALL, tag == 1 ? ALL : {}, tag == 1 ? ALL : {}}
		g.draw[tag] = core.vk_draw_pipeline(#load("shaders/draw.vert.spv"), #load("shaders/draw.frag.spv"), g.layout, formats[:], masks[:])
	}
	g.frame_layout = core.vk_layout_create({.COMPUTE}, size_of(Vk_Frame_Push))
	g.frame_pipe = core.vk_compute_pipeline(#load("shaders/frame.comp.spv"), g.frame_layout)
	g.bloom_pipe = core.vk_compute_pipeline(#load("shaders/bloom.comp.spv"), g.frame_layout)
	for i in 0 ..< 2 {
		g.glow[i] = core.vk_buf_create(VRAM_W * VRAM_H * 4, {.STORAGE_BUFFER}, {.DEVICE_LOCAL})
		g.blur[i] = core.vk_buf_create(VRAM_W * VRAM_H * 4, {.STORAGE_BUFFER}, {.DEVICE_LOCAL})
	}
	g.frame_uni = core.vk_buf_create(size_of(Vk_Frame_Uni), {.STORAGE_BUFFER}, HOST)
	g.frame_lit = core.vk_buf_create(size_of(u32), {.STORAGE_BUFFER}, HOST)
	g.cmd, g.fence = core.vk_cmd_create()
	g.prims = core.vk_buf_create(size_of(prim_queue.prims), {.STORAGE_BUFFER}, HOST)
	g.ports = core.vk_buf_create(size_of(prim_queue.portals), {.STORAGE_BUFFER}, HOST)
	g.order = core.vk_buf_create(size_of(prim_queue.order), {.STORAGE_BUFFER}, HOST)
	g.vram = core.vk_buf_create(size_of(vram), {.STORAGE_BUFFER}, HOST)
	g.uni = core.vk_buf_create(size_of(Vk_Draw_Uni), {.STORAGE_BUFFER}, HOST)
	g.shadow = new([VRAM_W * VRAM_H]u16)
	g.shadow^ = vram
	mem.copy(g.vram.ptr, &vram[0], size_of(vram))
	g.on = true
	fmt.eprintln(core.ENV_PREFIX + "GPU: vk (hi-res target drawn and converted on Vulkan)")
	fmt.eprintln(core.ENV_PREFIX + "GPU=vk:", g.interlock ? "pixel interlock, one level a queue" : "draw levels (no pixel interlock)")
	return true
}

@(private = "file")
vk_view_create :: proc(img: vk.Image, format: vk.Format) -> (v: vk.ImageView) {
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = img,
		viewType = .D2,
		format = format,
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

// Plane `at` (an offset of VK_IMAGES' or VK_BUFS') of an n-pixel stage.
@(private = "file")
vk_plane :: proc($T: typeid, at, n: int) -> []T {
	return ([^]T)(&gpu_vk.stage.ptr[at * n])[:n]
}

// Give target t (the hi-res one, just made) its images and buffers, the
// images in the general layout from then on, and its planes (pixels,
// walk, door, ghost layer and depth buffer) in the stage.
@(private)
vk_target_make :: proc(t: ^Target) {
	g := &gpu_vk
	USAGE :: vk.ImageUsageFlags{.COLOR_ATTACHMENT, .INPUT_ATTACHMENT, .TRANSFER_SRC, .TRANSFER_DST}
	w, h := u32(t.w), u32(t.h)
	n := int(t.w * t.h)
	for f, i in VK_FORMATS {
		g.img[i], g.mem[i] = core.vk_image_create(w, h, f, g.interlock ? USAGE + {.STORAGE} : USAGE)
		g.view[i] = vk_view_create(g.img[i], f)
	}
	BUF :: vk.BufferUsageFlags{.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST}
	for b, i in VK_BUFS {
		g.bufs[i] = core.vk_buf_create(n * b.y, BUF, {.DEVICE_LOCAL})
	}
	g.stage = core.vk_buf_create(n * VK_STAGE, {.TRANSFER_SRC, .TRANSFER_DST}, CACHED)
	// Zeroed, as make's planes are: new memory's contents are undefined.
	mem.zero(g.stage.ptr, n * VK_STAGE)
	g.rows = make([]vk.BufferCopy, t.h)
	g.frame_rgb = core.vk_buf_create(n * 4, {.STORAGE_BUFFER, .TRANSFER_DST}, {.DEVICE_LOCAL})
	g.copies = make([]vk.BufferCopy, 2 * t.h)
	t.rgb = vk_plane(u32, VK_IMAGES[0].x, n)
	t.walk = vk_plane(u16, VK_IMAGES[1].x, n)
	t.door = vk_plane(u8, VK_IMAGES[2].x, n)
	gh := &t.ghost
	gh.rgb = vk_plane(u32, VK_BUFS[0].x, n)
	gh.alpha = vk_plane(u8, VK_BUFS[1].x, n)
	gh.z = vk_plane(f32, VK_BUFS[2].x, n)
	t.zbuf = vk_plane(u32, VK_BUFS[3].x, n)
	imgs: [len(VK_IMAGES)]vk.DescriptorImageInfo
	for v, i in g.view {
		imgs[i] = {imageView = v, imageLayout = .GENERAL}
	}
	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = g.set,
		dstBinding      = 0,
		descriptorCount = g.interlock ? len(imgs) : 1,
		descriptorType  = g.interlock ? .STORAGE_IMAGE : .INPUT_ATTACHMENT,
		pImageInfo      = &imgs[0],
	}
	vk.UpdateDescriptorSets(core.vkc.device, 1, &write, 0, nil)
	core.vk_begin(g.cmd, g.fence)
	bars: [len(VK_IMAGES)]vk.ImageMemoryBarrier
	for im, i in g.img {
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
	vk.CmdPipelineBarrier(g.cmd, {.TOP_OF_PIPE}, {.ALL_COMMANDS}, {}, 0, nil, 0, nil, len(bars), &bars[0])
	core.vk_submit(g.cmd, g.fence, 0, 0)
}

// Free target t's images, buffers and with the stage its planes.
@(private)
vk_target_drop :: proc(t: ^Target) {
	g := &gpu_vk
	dev := core.vkc.device
	vk.DeviceWaitIdle(dev)
	for i in 0 ..< len(VK_IMAGES) {
		vk.DestroyImageView(dev, g.view[i], nil)
		vk.DestroyImage(dev, g.img[i], nil)
		vk.FreeMemory(dev, g.mem[i], nil)
	}
	for &b in g.bufs {
		vk_buf_free(&b)
	}
	vk_buf_free(&g.stage)
	vk_buf_free(&g.frame_rgb)
	delete(g.rows)
	delete(g.copies)
	g.rows, g.copies = nil, nil
	g.img, g.view, g.mem = {}, {}, {}
}

// Whether target t's pixels are a pass's buffer, not its plane in the stage
// (which then keeps the picture saved for the pass).
@(private = "file")
vk_passing :: proc(t: ^Target) -> bool {
	return rawptr(raw_data(t.rgb)) != &gpu_vk.stage.ptr[VK_IMAGES[0].x * len(t.rgb)]
}

// The box's rows of a pass's buffer (vk_passing) to VK_PASS's plane
// (to = true) or back.
@(private = "file")
vk_pass_rows :: proc(t: ^Target, x0, y0, x1, y1: i32, to: bool) {
	plane := vk_plane(u32, VK_PASS, len(t.rgb))
	for y in y0 ..< y1 {
		row := int(y * t.w)
		a, b := plane[row + int(x0):row + int(x1)], t.rgb[row + int(x0):row + int(x1)]
		if to {
			copy(a, b)
		} else {
			copy(b, a)
		}
	}
}

// Copy the box between the planes and the drawn pictures: to them
// (to = true) or back.
@(private = "file")
vk_copy :: proc(t: ^Target, x0, y0, x1, y1: i32, to: bool) {
	g := &gpu_vk
	n := vk.DeviceSize(t.w * t.h)
	rows := g.rows[:y1 - y0]
	bufs, imgs := VK_BUFS, VK_IMAGES
	for buf, i in g.bufs {
		at, size := vk.DeviceSize(bufs[i].x) * n, vk.DeviceSize(bufs[i].y)
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
	for img, i in g.img {
		at, size := vk.DeviceSize(imgs[i].x) * n, vk.DeviceSize(imgs[i].y)
		if i == 0 && vk_passing(t) {
			at = VK_PASS * n
		}
		r := vk.BufferImageCopy {
			bufferOffset = at + vk.DeviceSize(y0 * t.w + x0) * size,
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

// Upload the VRAM cells the queued draws read (raster.reads) that changed
// since last uploaded, as gl_vram_sync: the GPU's copy is idle between
// submits (vk_target_submit waits for each), so they go straight into it.
@(private = "file")
vk_vram_sync :: proc() #no_bounds_check {
	g := &gpu_vk
	gpu := ([^]u16)(g.vram.ptr)
	for cy in 0 ..< i32(len(Cells)) {
		row := raster.reads[cy]
		for row != 0 {
			a := i32(intrinsics.count_trailing_zeros(row))
			run := i32(intrinsics.count_trailing_zeros(~(row >> u32(a))))
			row &~= (~u128(0) >> u32(128 - run)) << u32(a)
			x, w := a * 8, run * 8
			for y in cy * 8 ..< cy * 8 + 8 {
				i := y * VRAM_W + x
				if mem.compare_ptrs(&vram[i], &g.shadow[i], int(w) * 2) != 0 {
					copy(g.shadow[i:][:w], vram[i:][:w])
					mem.copy(&gpu[i], &vram[i], int(w) * 2)
				}
			}
		}
	}
}

// Draw the queue (raster_run, before its read cells are dropped) and wait
// for it: the planes hold what it drew on return.
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
	mem.copy(g.prims.ptr, &q.prims[0], q.prim_n * size_of(Gpu_Prim))
	mem.copy(g.order.ptr, &q.order[0], q.prim_n * size_of(i32))
	if q.portal_n > 0 {
		mem.copy(g.ports.ptr, &q.portals[0], q.portal_n * size_of(Gpu_Portal))
	}
	vk_vram_sync()
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
		prims     = g.prims.addr,
		ports     = g.ports.addr,
		order     = g.order.addr,
		vram      = g.vram.addr,
		ghost_rgb = g.bufs[0].addr,
		ghost_a   = g.bufs[1].addr,
		ghost_z   = g.bufs[2].addr,
		zbuf      = g.bufs[3].addr,
		uni       = g.uni.addr,
	}
	cmd := g.cmd
	passing := vk_passing(t)
	if passing {
		vk_pass_rows(t, x0, y0, x1, y1, true)
	}
	core.vk_begin(cmd, g.fence)
	vk_copy(t, x0, y0, x1, y1, true)
	core.vk_barrier(cmd)
	area := vk.Rect2D{{x0, y0}, {u32(x1 - x0), u32(y1 - y0)}}
	atts: [len(VK_IMAGES)]vk.RenderingAttachmentInfo
	for v, i in g.view {
		atts[i] = {
			sType       = .RENDERING_ATTACHMENT_INFO,
			imageView   = v,
			imageLayout = .GENERAL,
			loadOp      = .LOAD,
			storeOp     = .STORE,
		}
	}
	// With interlock the pictures are storage images: no attachments.
	rinfo := vk.RenderingInfo {
		sType                = .RENDERING_INFO,
		renderArea           = area,
		layerCount           = 1,
		colorAttachmentCount = g.interlock ? 0 : len(atts),
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
		push.tags = i32(levels.depth[lv])
		// With interlock depths are laid as drawn (hi_draw.glsl).
		if levels.z[lv] && g.interlock {
			levels.z[lv] = false
		}
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
	if passing {
		vk_pass_rows(t, x0, y0, x1, y1, false)
	}
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

// Convert the target's picture over the area (target pixels, wrapping) to
// XRGB8888 (convert_area) in frame slot `slot`, as gl_frame does, and wait
// for it: the planes are read as they stand after raster_sync.
@(private)
vk_frame :: proc(slot: int, x, y, w, h: i32) {
	g := &gpu_vk
	t := shown_target()
	f := &g.frames[slot]
	assert(t.vk, "a Vulkan conversion of a target not on the device")
	assert(w > 0 && h > 0 && w <= t.w && h <= t.h, "conversion area outside the target")
	raster_sync()
	px := int(w * h)
	if f.buf.size < px * 4 {
		if f.buf.buf != 0 {
			vk_buf_free(&f.buf)
		}
		f.buf = core.vk_buf_create(px * 4, {.STORAGE_BUFFER}, CACHED)
	}
	f.px, f.w, f.mark = px, w, g.marks
	g.marks += 1
	post := post_now()
	cols: [4][4]i32
	for j in 0 ..< 3 {
		cols[j] = {post.grade.m[0][j], post.grade.m[1][j], post.grade.m[2][j], 0}
	}
	cols[3] = {post.grade.add[0], post.grade.add[1], post.grade.add[2], 0}
	(^Vk_Frame_Uni)(g.frame_uni.ptr)^ = {
		area   = {x, y, w, h},
		size_k = {t.w, t.h, i32(t.shift), 0},
		fx     = {i32(bloom_effects), BLOOM_GAIN, i32(post.grade.on), 0},
		dof    = {post.focus, DOF_BAND, DOF_RAMP, 0},
		vig    = {i32(post.vignette), VIGNETTE_FROM, VIGNETTE_MOST, 0},
		grade  = cols,
	}
	intrinsics.volatile_store((^u32)(g.frame_lit.ptr), 0)
	// The area's rows to the device, each in two runs where it wraps; a
	// pass's buffer (vk_passing) through VK_PASS's plane.
	n := len(t.rgb)
	passing := vk_passing(t)
	at := vk.DeviceSize((passing ? VK_PASS : VK_IMAGES[0].x) * n)
	plane := vk_plane(u32, VK_PASS, n)
	cn := 0
	for r in 0 ..< h {
		row := int(((y + r) & (t.h - 1)) * t.w)
		x0, left := x & (t.w - 1), w
		for left > 0 {
			m := min(left, t.w - x0)
			o := row + int(x0)
			if passing {
				copy(plane[o:][:m], t.rgb[o:][:m])
			}
			b := vk.DeviceSize(o * 4)
			g.copies[cn] = {at + b, b, vk.DeviceSize(m * 4)}
			cn += 1
			x0, left = 0, left - m
		}
	}
	cmd := g.cmd
	core.vk_begin(cmd, g.fence)
	vk.CmdCopyBuffer(cmd, g.stage.buf, g.frame_rgb.buf, u32(cn), &g.copies[0])
	core.vk_barrier(cmd)
	push := Vk_Frame_Push {
		rgb    = g.frame_rgb.addr,
		glow   = g.glow[0].addr,
		blur   = g.blur[0].addr,
		px     = f.buf.addr,
		bright = g.frame_lit.addr,
		uni    = g.frame_uni.addr,
	}
	if bloom_effects {
		vk_blur(&push, g.glow, false, w, h, t.shift)
	}
	if post.focus > 0 {
		vk_blur(&push, g.blur, true, w, h, t.shift)
	}
	vk.CmdBindPipeline(cmd, .COMPUTE, g.frame_pipe)
	vk.CmdPushConstants(cmd, g.frame_layout, {.COMPUTE}, 0, size_of(push), &push)
	vk.CmdDispatch(cmd, u32(w + 15) / 16, u32(h + 15) / 16, 1)
	host := vk.MemoryBarrier {
		sType         = .MEMORY_BARRIER,
		srcAccessMask = {.MEMORY_WRITE},
		dstAccessMask = {.HOST_READ},
	}
	vk.CmdPipelineBarrier(cmd, {.ALL_COMMANDS}, {.HOST}, {}, 1, &host, 0, nil, 0, nil)
	core.vk_submit(cmd, g.fence, 0, 0)
	fence := g.fence
	core.vk_check(vk.WaitForFences(core.vkc.device, 1, &fence, true, max(u64)), "vkWaitForFences")
	g.bright[f.mark % GL_MARKS] = intrinsics.volatile_load((^u32)(g.frame_lit.ptr)) != 0
}

// Record bloom.comp's stages over a w x h area into bufs, ending in
// bufs[0]: the glow, or with `every` the depth of field's blur, at the
// target's shift k.
@(private = "file")
vk_blur :: proc(push: ^Vk_Frame_Push, bufs: [2]core.Vk_Buf, every: bool, w, h: i32, k: u32) {
	g := &gpu_vk
	cmd := g.cmd
	vk.CmdBindPipeline(cmd, .COMPUTE, g.bloom_pipe)
	push.every = i32(every)
	for stage in i32(0) ..< 3 {
		push.stage = stage
		push.src, push.dst = bufs[stage & 1 ~ 1].addr, bufs[stage & 1].addr
		vk.CmdPushConstants(cmd, g.frame_layout, {.COMPUTE}, 0, size_of(push^), push)
		vk.CmdDispatch(cmd, u32((w >> k) + 15) / 16, u32((h >> k) + 15) / 16, 1)
		core.vk_barrier(cmd)
	}
}

// Frame slot `slot`'s pixels (vk_frame waited for them), valid until the
// slot is converted again.
@(private)
vk_frame_take :: proc(slot: int) -> []u32 {
	f := &gpu_vk.frames[slot]
	return ([^]u32)(f.buf.ptr)[:f.px]
}

// Whether conversion `mark` (Vk_Frame.mark) has a pixel above black;
// `known` false when its flag has since been reused.
@(private)
vk_frame_bright :: proc(mark: int) -> (bright, known: bool) {
	g := &gpu_vk
	if mark < 0 || mark >= g.marks || g.marks - mark > GL_MARKS {
		return false, false
	}
	return g.bright[mark % GL_MARKS], true
}
