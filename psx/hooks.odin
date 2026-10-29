// Each lower package calls up into the ones above it through handler
// variables; this sets them all before anything runs.
package psx

import bios "bios"
import cpu "cpu"
import gpu "gpu"
import gte "gte"
import host "host"
import io "io"
import render "render"
import spu "spu"

@(init, private = "file")
hooks_init :: proc "contextless" () {
	cpu.bios_a = bios.bios_a
	cpu.bios_b = bios.bios_b
	cpu.bios_c = bios.bios_c
	cpu.bios_syscall = bios.bios_syscall
	cpu.irq_check = io.irq_check
	cpu.interp_run = interp_run
	cpu.io_read = io_read
	cpu.io_write = io_write
	cpu.ram_keep = ram_keep
	gte.depth_tag = render.depth_tag
	io.deliver_irq = bios.deliver_irq
	bios.pad_game = host.pad_game
	bios.sticks = proc() -> (left, right: [2]f32) {
		s := host.sticks()
		return s.left, s.right
	}
	bios.pad_rumble = host.pad_rumble
	bios.gp0_write = gpu.gp0_write
	io.event_handlers = event_handler_table
	io.dma_channels = dma_channel_table
	spu.platform_audio = host.platform_audio
}
