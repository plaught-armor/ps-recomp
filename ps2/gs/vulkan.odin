// GS-only Vulkan pieces on top of core's device layer (core/vulkan.odin):
// the primitive pipeline and the optional swapchain.
package ps2_gs

import vk "vendor:vulkan"
import "ps:core"

// Triangle lists with no attachments: the fragment shader does all memory
// access itself.
@(private)
prim_pipeline :: proc(vert, frag: []u8, layout: vk.PipelineLayout) -> (p: vk.Pipeline) {
	vm, fm := core.vk_shader_module(vert), core.vk_shader_module(frag)
	defer {
		vk.DestroyShaderModule(core.vkc.device, vm, nil)
		vk.DestroyShaderModule(core.vkc.device, fm, nil)
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
	cb := vk.PipelineColorBlendStateCreateInfo {
		sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
	}
	dyn_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dyn := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = 2,
		pDynamicStates    = &dyn_states[0],
	}
	rend := vk.PipelineRenderingCreateInfo {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
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
	core.vk_check(vk.CreateGraphicsPipelines(core.vkc.device, 0, 1, &info, nil, &p), "vkCreateGraphicsPipelines")
	return
}

// (Re)create the swapchain at the surface's current size. Images are blit
// targets only.
@(private)
swap_create :: proc() {
	vk.DeviceWaitIdle(core.vkc.device)
	caps: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(core.vkc.phys, core.vkc.surface, &caps)
	ext := caps.currentExtent
	if ext.width == 0xffffffff {ext = {640, 480}}
	if ext.width == 0 || ext.height == 0 {return} // minimised
	if core.vkc.swap_fmt == .UNDEFINED {
		n: u32
		vk.GetPhysicalDeviceSurfaceFormatsKHR(core.vkc.phys, core.vkc.surface, &n, nil)
		fmts := make([]vk.SurfaceFormatKHR, n, context.temp_allocator)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(core.vkc.phys, core.vkc.surface, &n, raw_data(fmts))
		core.vkc.swap_fmt = fmts[0].format
		for f in fmts {
			if f.format == .B8G8R8A8_UNORM || f.format == .R8G8B8A8_UNORM {core.vkc.swap_fmt = f.format; break}
		}
	}
	mode := vk.PresentModeKHR.FIFO
	{
		n: u32
		vk.GetPhysicalDeviceSurfacePresentModesKHR(core.vkc.phys, core.vkc.surface, &n, nil)
		modes := make([]vk.PresentModeKHR, n, context.temp_allocator)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(core.vkc.phys, core.vkc.surface, &n, raw_data(modes))
		// The game paces itself; presentation must not block it.
		for m in modes {if m == .MAILBOX {mode = .MAILBOX}}
		if mode != .MAILBOX {for m in modes {if m == .IMMEDIATE {mode = .IMMEDIATE}}}
	}
	count := max(caps.minImageCount + 1, 3)
	if caps.maxImageCount != 0 {count = min(count, caps.maxImageCount)}
	old := core.vkc.swap
	info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = core.vkc.surface,
		minImageCount    = count,
		imageFormat      = core.vkc.swap_fmt,
		imageColorSpace  = .SRGB_NONLINEAR,
		imageExtent      = ext,
		imageArrayLayers = 1,
		imageUsage       = {.TRANSFER_DST},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = mode,
		clipped          = true,
		oldSwapchain     = old,
	}
	core.vk_check(vk.CreateSwapchainKHR(core.vkc.device, &info, nil, &core.vkc.swap), "vkCreateSwapchainKHR")
	if old != 0 {vk.DestroySwapchainKHR(core.vkc.device, old, nil)}
	core.vkc.swap_ext = ext
	n: u32
	vk.GetSwapchainImagesKHR(core.vkc.device, core.vkc.swap, &n, nil)
	resize(&core.vkc.swap_imgs, int(n))
	vk.GetSwapchainImagesKHR(core.vkc.device, core.vkc.swap, &n, raw_data(core.vkc.swap_imgs))
	for len(core.vkc.swap_done) < int(n) {
		s: vk.Semaphore
		sinfo := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
		}
		core.vk_check(vk.CreateSemaphore(core.vkc.device, &sinfo, nil, &s), "vkCreateSemaphore")
		append(&core.vkc.swap_done, s)
	}
}
