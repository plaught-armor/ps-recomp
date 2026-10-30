// Vulkan device shared by the GPU renderers: instance, device and queue,
// buffers with device addresses, and pipelines. Headless runs have no
// surface and render the same way. VK_LOADER is per OS (vulkan_<os>.odin).
package core

import "core:dynlib"
import "core:fmt"
import "core:os"
import vk "vendor:vulkan"

Vk_Buf :: struct {
	buf:  vk.Buffer,
	mem:  vk.DeviceMemory,
	addr: vk.DeviceAddress,
	ptr:  [^]u8, // mapped, for host-visible buffers
	size: int,
}

vkc: struct {
	instance:  vk.Instance,
	phys:      vk.PhysicalDevice,
	device:    vk.Device,
	queue:     vk.Queue,
	family:    u32,
	mem_props: vk.PhysicalDeviceMemoryProperties,
	pool:      vk.CommandPool,
	surface:   vk.SurfaceKHR,
	swap:      vk.SwapchainKHR,
	swap_fmt:  vk.Format,
	swap_ext:  vk.Extent2D,
	swap_imgs: [dynamic]vk.Image,
	swap_done: [dynamic]vk.Semaphore, // per image: rendering finished, safe to present
	// VK_KHR_dynamic_rendering_local_read is on (the device has it).
	local_read: bool,
	// shaderInt64 and shaderFloat64 are on (the device has both).
	wide:       bool,
}

// Report a failed call; false when it failed.
vk_ok :: proc(r: vk.Result, what: string, loc := #caller_location) -> bool {
	if r != .SUCCESS {
		fmt.eprintfln("vulkan: %s failed: %v (%v)", what, r, loc)
	}
	return r == .SUCCESS
}

// A failed call ends the game: for calls only a broken or exhausted device
// fails, once vk_device has found one.
vk_check :: proc(r: vk.Result, what: string, loc := #caller_location) {
	if !vk_ok(r, what, loc) {
		os.exit(1)
	}
}

// Load the loader and create the instance with the surface extensions the
// window system needs; false, reported, when there is no Vulkan.
vk_instance :: proc(extensions: []cstring) -> bool {
	lib, ok := dynlib.load_library(VK_LOADER)
	if !ok {
		fmt.eprintln("vulkan:", VK_LOADER, "not found")
		return false
	}
	gipa, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	if !found {
		fmt.eprintln("vulkan:", VK_LOADER, "lacks vkGetInstanceProcAddr")
		return false
	}
	vk.load_proc_addresses_global(gipa)
	app := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "ps-recomp",
		apiVersion       = vk.API_VERSION_1_3,
	}
	info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app,
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}
	if !vk_ok(vk.CreateInstance(&info, nil, &vkc.instance), "vkCreateInstance") {
		return false
	}
	vk.load_proc_addresses_instance(vkc.instance)
	return true
}

// Pick the first device with a graphics and compute queue (and pixel
// interlock when the caller's shaders need it), and create it with the
// features the shaders use; dynamic rendering local read and 64-bit shader
// arithmetic too when the device has them (vkc.local_read, vkc.wide). False,
// reported, when no device will do.
vk_device :: proc(pixel_interlock: bool) -> bool {
	n: u32
	vk.EnumeratePhysicalDevices(vkc.instance, &n, nil)
	devs := make([]vk.PhysicalDevice, n, context.temp_allocator)
	vk.EnumeratePhysicalDevices(vkc.instance, &n, raw_data(devs))
	for d in devs {
		lock := vk.PhysicalDeviceFragmentShaderInterlockFeaturesEXT {
			sType = .PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT,
		}
		f2 := vk.PhysicalDeviceFeatures2 {
			sType = .PHYSICAL_DEVICE_FEATURES_2,
			pNext = &lock,
		}
		vk.GetPhysicalDeviceFeatures2(d, &f2)
		if pixel_interlock && !lock.fragmentShaderPixelInterlock {continue}
		qn: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(d, &qn, nil)
		qs := make([]vk.QueueFamilyProperties, qn, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(d, &qn, raw_data(qs))
		for q, i in qs {
			if .GRAPHICS not_in q.queueFlags || .COMPUTE not_in q.queueFlags {continue}
			if vkc.surface != 0 {
				present: b32
				vk.GetPhysicalDeviceSurfaceSupportKHR(d, u32(i), vkc.surface, &present)
				if !present {continue}
			}
			vkc.phys, vkc.family = d, u32(i)
			break
		}
		if vkc.phys != nil {break}
	}
	if vkc.phys == nil {
		fmt.eprintln(
			pixel_interlock ? "vulkan: no device with fragment shader pixel interlock" : "vulkan: no device with a graphics and compute queue",
		)
		return false
	}
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(vkc.phys, &props)
	fmt.eprintfln("vulkan: %s", cstring(&props.deviceName[0]))
	vk.GetPhysicalDeviceMemoryProperties(vkc.phys, &vkc.mem_props)
	ne: u32
	vk.EnumerateDeviceExtensionProperties(vkc.phys, nil, &ne, nil)
	eps := make([]vk.ExtensionProperties, ne, context.temp_allocator)
	vk.EnumerateDeviceExtensionProperties(vkc.phys, nil, &ne, raw_data(eps))
	read := vk.PhysicalDeviceDynamicRenderingLocalReadFeatures {
		sType = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_LOCAL_READ_FEATURES,
	}
	for &e in eps {
		if cstring(&e.extensionName[0]) != vk.KHR_DYNAMIC_RENDERING_LOCAL_READ_EXTENSION_NAME {continue}
		f2 := vk.PhysicalDeviceFeatures2 {
			sType = .PHYSICAL_DEVICE_FEATURES_2,
			pNext = &read,
		}
		vk.GetPhysicalDeviceFeatures2(vkc.phys, &f2)
		vkc.local_read = bool(read.dynamicRenderingLocalRead)
	}
	read.pNext = nil
	have: vk.PhysicalDeviceFeatures
	vk.GetPhysicalDeviceFeatures(vkc.phys, &have)
	vkc.wide = bool(have.shaderInt64 && have.shaderFloat64)

	lock := vk.PhysicalDeviceFragmentShaderInterlockFeaturesEXT {
		sType                        = .PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT,
		fragmentShaderPixelInterlock = true,
	}
	v13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext            = pixel_interlock ? &lock : nil,
		dynamicRendering = true,
	}
	if vkc.local_read {
		read.pNext = v13.pNext
		v13.pNext = &read
	}
	v12 := vk.PhysicalDeviceVulkan12Features {
		sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext               = &v13,
		bufferDeviceAddress = true,
	}
	f2 := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &v12,
		features = {fragmentStoresAndAtomics = true, shaderInt64 = b32(vkc.wide), shaderFloat64 = b32(vkc.wide)},
	}
	prio: f32 = 1
	qinfo := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = vkc.family,
		queueCount       = 1,
		pQueuePriorities = &prio,
	}
	exts: [3]cstring
	n_exts: u32
	if pixel_interlock {exts[n_exts] = "VK_EXT_fragment_shader_interlock"; n_exts += 1}
	if vkc.local_read {exts[n_exts] = vk.KHR_DYNAMIC_RENDERING_LOCAL_READ_EXTENSION_NAME; n_exts += 1}
	if vkc.surface != 0 {exts[n_exts] = "VK_KHR_swapchain"; n_exts += 1}
	info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &f2,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &qinfo,
		enabledExtensionCount   = n_exts,
		ppEnabledExtensionNames = &exts[0],
	}
	if !vk_ok(vk.CreateDevice(vkc.phys, &info, nil, &vkc.device), "vkCreateDevice") {
		return false
	}
	vk.load_proc_addresses_device(vkc.device)
	vk.GetDeviceQueue(vkc.device, vkc.family, 0, &vkc.queue)
	pool := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = vkc.family,
	}
	return vk_ok(vk.CreateCommandPool(vkc.device, &pool, nil, &vkc.pool), "vkCreateCommandPool")
}

// The first memory type of `bits` with `want`. HOST_CACHED, which no device
// need have, is only preferred: without it reads back are slower, no
// different. Every device has a device-local type, and a host-visible
// coherent one for every buffer, so the rest is never missing.
vk_mem_type :: proc(bits: u32, want: vk.MemoryPropertyFlags) -> u32 {
	for need in ([2]vk.MemoryPropertyFlags{want, want - {.HOST_CACHED}}) {
		for i in 0 ..< vkc.mem_props.memoryTypeCount {
			if bits & (1 << i) != 0 && need <= vkc.mem_props.memoryTypes[i].propertyFlags {return i}
		}
	}
	fmt.panicf("vulkan: no memory type with %v", want)
}

// A buffer with a device address; host-visible ones stay mapped.
vk_buf_create :: proc(size: int, usage: vk.BufferUsageFlags, want: vk.MemoryPropertyFlags) -> (b: Vk_Buf) {
	b.size = size
	info := vk.BufferCreateInfo {
		sType = .BUFFER_CREATE_INFO,
		size  = vk.DeviceSize(size),
		usage = usage + {.SHADER_DEVICE_ADDRESS},
	}
	vk_check(vk.CreateBuffer(vkc.device, &info, nil, &b.buf), "vkCreateBuffer")
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(vkc.device, b.buf, &req)
	flags := vk.MemoryAllocateFlagsInfo {
		sType = .MEMORY_ALLOCATE_FLAGS_INFO,
		flags = {.DEVICE_ADDRESS},
	}
	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = &flags,
		allocationSize  = req.size,
		memoryTypeIndex = vk_mem_type(req.memoryTypeBits, want),
	}
	vk_check(vk.AllocateMemory(vkc.device, &alloc, nil, &b.mem), "vkAllocateMemory")
	vk_check(vk.BindBufferMemory(vkc.device, b.buf, b.mem, 0), "vkBindBufferMemory")
	addr := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = b.buf,
	}
	b.addr = vk.GetBufferDeviceAddress(vkc.device, &addr)
	if .HOST_VISIBLE in want {
		p: rawptr
		vk_check(vk.MapMemory(vkc.device, b.mem, 0, vk.DeviceSize(size), {}, &p), "vkMapMemory")
		b.ptr = ([^]u8)(p)
	}
	return
}

vk_image_create :: proc(w, h: u32, format: vk.Format, usage: vk.ImageUsageFlags) -> (img: vk.Image, mem: vk.DeviceMemory) {
	info := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {w, h, 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = usage,
		initialLayout = .UNDEFINED,
	}
	vk_check(vk.CreateImage(vkc.device, &info, nil, &img), "vkCreateImage")
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(vkc.device, img, &req)
	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = vk_mem_type(req.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	vk_check(vk.AllocateMemory(vkc.device, &alloc, nil, &mem), "vkAllocateMemory")
	vk_check(vk.BindImageMemory(vkc.device, img, mem, 0), "vkBindImageMemory")
	return
}

vk_shader_module :: proc(code: []u8) -> (m: vk.ShaderModule) {
	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = ([^]u32)(raw_data(code)),
	}
	vk_check(vk.CreateShaderModule(vkc.device, &info, nil, &m), "vkCreateShaderModule")
	return
}

vk_layout_create :: proc(stages: vk.ShaderStageFlags, push: u32, sets: []vk.DescriptorSetLayout = nil) -> (l: vk.PipelineLayout) {
	rng := vk.PushConstantRange {
		stageFlags = stages,
		size       = push,
	}
	info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = u32(len(sets)),
		pSetLayouts            = raw_data(sets),
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &rng,
	}
	vk_check(vk.CreatePipelineLayout(vkc.device, &info, nil, &l), "vkCreatePipelineLayout")
	return
}

vk_compute_pipeline :: proc(code: []u8, layout: vk.PipelineLayout) -> (p: vk.Pipeline) {
	m := vk_shader_module(code)
	defer vk.DestroyShaderModule(vkc.device, m, nil)
	info := vk.ComputePipelineCreateInfo {
		sType = .COMPUTE_PIPELINE_CREATE_INFO,
		stage = {sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.COMPUTE}, module = m, pName = "main"},
		layout = layout,
	}
	vk_check(vk.CreateComputePipelines(vkc.device, 0, 1, &info, nil, &p), "vkCreateComputePipelines")
	return
}

// Triangle lists, unblended, into colour attachments of `formats` written
// through `masks` (one each); with none, the fragment shader does all
// memory access itself.
vk_draw_pipeline :: proc(vert, frag: []u8, layout: vk.PipelineLayout, formats: []vk.Format = nil, masks: []vk.ColorComponentFlags = nil) -> (p: vk.Pipeline) {
	assert(len(formats) == len(masks) && len(formats) <= 4)
	vm, fm := vk_shader_module(vert), vk_shader_module(frag)
	defer {
		vk.DestroyShaderModule(vkc.device, vm, nil)
		vk.DestroyShaderModule(vkc.device, fm, nil)
	}
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vm, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fm, pName = "main"},
	}
	vin := vk.PipelineVertexInputStateCreateInfo {
		sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}
	ia := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}
	vp := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}
	rs := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		cullMode    = {},
		frontFace   = .COUNTER_CLOCKWISE,
		lineWidth   = 1,
	}
	ms := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}
	blend: [4]vk.PipelineColorBlendAttachmentState
	for m, i in masks {
		blend[i].colorWriteMask = m
	}
	cb := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = u32(len(masks)),
		pAttachments    = &blend[0],
	}
	dyn_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dyn := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = 2,
		pDynamicStates    = &dyn_states[0],
	}
	rend := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = u32(len(formats)),
		pColorAttachmentFormats = raw_data(formats),
	}
	info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &rend,
		stageCount          = 2,
		pStages             = &stages[0],
		pVertexInputState   = &vin,
		pInputAssemblyState = &ia,
		pViewportState      = &vp,
		pRasterizationState = &rs,
		pMultisampleState   = &ms,
		pColorBlendState    = &cb,
		pDynamicState       = &dyn,
		layout              = layout,
	}
	vk_check(vk.CreateGraphicsPipelines(vkc.device, 0, 1, &info, nil, &p), "vkCreateGraphicsPipelines")
	return
}

// Make every command before visible to every command after.
vk_barrier :: proc(cmd: vk.CommandBuffer) {
	mb := vk.MemoryBarrier {
		sType         = .MEMORY_BARRIER,
		srcAccessMask = {.MEMORY_READ, .MEMORY_WRITE},
		dstAccessMask = {.MEMORY_READ, .MEMORY_WRITE},
	}
	vk.CmdPipelineBarrier(cmd, {.ALL_COMMANDS}, {.ALL_COMMANDS}, {}, 1, &mb, 0, nil, 0, nil)
}

// A primary command buffer and its fence, made signalled (vk_begin waits
// for it first).
vk_cmd_create :: proc() -> (cmd: vk.CommandBuffer, fence: vk.Fence) {
	alloc := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = vkc.pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	vk_check(vk.AllocateCommandBuffers(vkc.device, &alloc, &cmd), "vkAllocateCommandBuffers")
	finfo := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	vk_check(vk.CreateFence(vkc.device, &finfo, nil, &fence), "vkCreateFence")
	return
}

// Wait for cmd's last submit, then begin recording it again.
vk_begin :: proc(cmd: vk.CommandBuffer, fence: vk.Fence) {
	fence := fence
	vk.WaitForFences(vkc.device, 1, &fence, true, max(u64))
	vk.ResetFences(vkc.device, 1, &fence)
	vk.ResetCommandBuffer(cmd, {})
	info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &info), "vkBeginCommandBuffer")
}

// End cmd and submit it, signalling fence; waiting for semaphore `wait`
// before transfers and signalling `signal`, each when not 0.
vk_submit :: proc(cmd: vk.CommandBuffer, fence: vk.Fence, wait, signal: vk.Semaphore) {
	cmd, wait, signal := cmd, wait, signal
	vk_check(vk.EndCommandBuffer(cmd), "vkEndCommandBuffer")
	stage := vk.PipelineStageFlags{.TRANSFER}
	info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = wait != 0 ? 1 : 0,
		pWaitSemaphores      = &wait,
		pWaitDstStageMask    = &stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &cmd,
		signalSemaphoreCount = signal != 0 ? 1 : 0,
		pSignalSemaphores    = &signal,
	}
	vk_check(vk.QueueSubmit(vkc.queue, 1, &info, fence), "vkQueueSubmit")
}
