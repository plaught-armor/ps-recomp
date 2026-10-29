// I/O register dispatch to the devices, and the wiring of the events and
// DMA channels to them.
package psx

import "core:fmt"

import "ps:core"
import cpu "cpu"
import mdec "mdec"
import host "host"
import bios "bios"
import gpu "gpu"
import spu "spu"
import io "io"

// ---------------------------------------------------------------- dispatch

@(private)
memctrl: [16]u32

io_read :: proc(p: u32, size: u32) -> u32 {
	v := io_read_reg(p, size)
	if .Io in core.trace.active {
		core.tracef(.Io, "read%d  %08x -> %x ra=%x", size * 8, p, v, cpu.state.r[31])
	}
	return v
}

@(private)
io_read_reg :: proc(p: u32, size: u32) -> u32 {
	switch p {
	case 0x1f801000 ..< 0x1f801040:
		return memctrl[(p - 0x1f801000) >> 2]
	case 0x1f801040 ..< 0x1f801050:
		return bios.sio0_read(p - 0x1f801040, size)
	case 0x1f801050 ..< 0x1f801060:
		return 0
	case 0x1f801060:
		return 0x00000b88
	case 0x1f801070:
		return io.irq_regs.stat
	case 0x1f801074:
		return io.irq_regs.mask
	case 0x1f801080 ..< 0x1f801100:
		return io.dma_read((p - 0x1f801080) & ~u32(3)) >> ((p & 3) * 8)
	case 0x1f801100 ..< 0x1f801130:
		return io.timer_read(int((p - 0x1f801100) >> 4), p & 0xf)
	case 0x1f801800 ..< 0x1f801804:
		return spu.cdrom_read(p & 3)
	case 0x1f801810:
		return gpu.gpu_read()
	case 0x1f801814:
		return gpu.gpu_stat()
	case 0x1f801820:
		return mdec.mdec_read_data()
	case 0x1f801824:
		return mdec.mdec_read_status()
	case 0x1f801c00 ..< 0x1f802000:
		v := spu.spu_read(p - 0x1f801c00)
		if size == 4 {
			v |= spu.spu_read(p - 0x1f801c00 + 2) << 16
		}
		return v
	}
	cpu.report_once(p, "io read")
	return 0
}

io_write :: proc(p, v: u32, size: u32) {
	if .Io in core.trace.active {
		core.tracef(.Io, "write%d %08x <- %x ra=%x", size * 8, p, v, cpu.state.r[31])
	}
	switch p {
	case 0x1f801000 ..< 0x1f801040:
		memctrl[(p - 0x1f801000) >> 2] = v
	case 0x1f801040 ..< 0x1f801050:
		bios.sio0_write(p - 0x1f801040, v, size)
	case 0x1f801050 ..< 0x1f801064:
	case 0x1f801070:
		if .Irq in core.trace.active {
			core.tracef(.Irq, "ack stat=%x & %x ra=%x", io.irq_regs.stat, v, cpu.state.r[31])
		}
		io.irq_regs.stat &= v
	case 0x1f801074:
		io.irq_regs.mask = v & 0x7ff
		cpu.irq_check()
	case 0x1f801080 ..< 0x1f801100:
		io.dma_write_sized(p - 0x1f801080, v, size)
	case 0x1f801100 ..< 0x1f801130:
		io.timer_write(int((p - 0x1f801100) >> 4), p & 0xf, v)
	case 0x1f801800 ..< 0x1f801804:
		spu.cdrom_write(p & 3, v & 0xff)
	case 0x1f801810:
		gpu.gp0_write(v)
	case 0x1f801814:
		gpu.gp1_write(v)
	case 0x1f801820:
		mdec.mdec_write_cmd(v)
	case 0x1f801824:
		mdec.mdec_write_ctrl(v)
	case 0x1f801c00 ..< 0x1f802000:
		spu.spu_write(p - 0x1f801c00, v & 0xffff)
		if size == 4 {
			spu.spu_write(p - 0x1f801c00 + 2, v >> 16)
		}
	case 0x1f802000 ..< 0x1f803000:
	// expansion 2: debug LEDs and POST
	case:
		fmt.eprintfln("io write %#08x = %#x", p, v)
	}
}

@(private)
event_handler_table := [io.Event]proc() {
	.VBlank     = vblank_event,
	.Cdrom      = spu.cdrom_event,
	.Cdrom_Read = spu.cdrom_read_event,
	.Dma        = io.dma_event,
	.Spu        = spu.spu_event,
	.Sio        = bios.sio_event,
	.Timer0     = io.timer0_event,
	.Timer1     = io.timer1_event,
	.Timer2     = io.timer2_event,
}

@(private)
vblank_event :: proc() {
	io.schedule(.VBlank, io.FRAME_CYCLES)
	io.irq_raise(.VBlank)
	bios.bios_pad_vblank()
	gpu.gpu_vblank()
	io.timers_vblank()
	host.platform_frame()
}

// The DMA channels' transfers.
@(private)
dma_channel_table := [7]proc(c: ^io.Dma_Channel) -> bool {
	0 = dma_mdec_in_ch,
	1 = mdec.dma_mdec_out,
	2 = dma_gpu_ch,
	3 = dma_cdrom_ch,
	4 = dma_spu_ch,
	6 = dma_otc_ch,
}

@(private = "file")
dma_mdec_in_ch :: proc(c: ^io.Dma_Channel) -> bool {mdec.dma_mdec_in(c); return true}
@(private = "file")
dma_gpu_ch :: proc(c: ^io.Dma_Channel) -> bool {gpu.dma_gpu(c); return true}
@(private = "file")
dma_cdrom_ch :: proc(c: ^io.Dma_Channel) -> bool {spu.dma_cdrom(c); return true}
@(private = "file")
dma_spu_ch :: proc(c: ^io.Dma_Channel) -> bool {spu.dma_spu(c); return true}
@(private = "file")
dma_otc_ch :: proc(c: ^io.Dma_Channel) -> bool {gpu.dma_otc(c); return true}

