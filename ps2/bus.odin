// EE hardware register dispatch: reads and writes that miss RAM, the
// scratchpad and VU memory reach the device that owns the register. Package
// ps2_mem calls these through its hooks (wired in snap.odin).
package ps2

import "core:fmt"
import cpu "cpu"
import dma "dma"
import gif "gif"
import iop "iop"
import ipu "ipu"
import mem "mem"
import vu "vu"

hw_read :: proc(addr: u32, size: int) -> u64 {
	a := addr & 0x1fffffff
	switch {
	case a >= 0x10000000 && a < 0x10010000:
		o := a & 0xffff
		switch o &~ 3 {
		case 0x0000, 0x0800, 0x1000, 0x1800:
			return u64(mem.timer_count(o >> 11))
		case 0x2000 ..= 0x203c:
			if o & 8 != 0 {return 0}
			v := ipu.ipu_read(o) >> ((u64(o) & 7) * 8)
			return size == 8 ? v : v & ((u64(1) << (u64(size) * 8)) - 1)
		case 0xb000, 0xb020, 0xb400, 0xb420: // fromIPU/toIPU CHCR, QWC
			ipu.ipu_pump()
		case 0xe010:
			ipu.ipu_pump()
			return u64(mem.dmac_stat)
		case 0xf000: return u64(mem.intc_stat)
		case 0xf010: return u64(mem.intc_mask)
		case 0xf200 ..= 0xf260: return u64(iop.sif_reg_read(o))
		}
		v := (^u64)(&mem.hwregs[o &~ 7])^ >> ((u64(o) & 7) * 8)
		return size == 8 ? v : v & ((u64(1) << (u64(size) * 8)) - 1)
	case a >= 0x12000000 && a < 0x12002000:
		o := a & 0x1fff
		switch o &~ 7 {
		case 0x1000: return u64(mem.gs_csr) | 0x551b0000 // revision/id bits
		case 0x1010: return u64(mem.gs_imr)
		}
		return (^u64)(&mem.gsregs[o &~ 7])^
	}
	unmapped(a, "read")
	return 0
}

hw_write :: proc(addr: u32, v: u64, size: int) {
	a := addr & 0x1fffffff
	switch {
	case a >= 0x10000000 && a < 0x10010000:
		o := a & 0xffff
		w := u32(v)
		switch o &~ 3 {
		case 0xe010:
			mem.dmac_stat &~= w & 0xffff
			mem.dmac_stat ~= w & 0xffff0000
			return
		case 0xf000:
			mem.intc_stat &~= w
			mem.intc_pending &~= w
			return
		case 0xf010:
			mem.intc_mask ~= w
			return
		case 0x2000 ..= 0x203c:
			if o & 0xf == 0 {ipu.ipu_write(o, w)}
			return
		case 0xf180: // SIO TX: kernel debug output
			fmt.eprintf("%c", u8(w))
			return
		case 0xf200 ..= 0xf260:
			iop.sif_reg_write(o, w)
			return
		}
		switch size {
		case 1: mem.hwregs[o] = u8(v)
		case 2: (^u16)(&mem.hwregs[o])^ = u16(v)
		case 4: (^u32)(&mem.hwregs[o])^ = w
		case 8: (^u64)(&mem.hwregs[o])^ = v
		}
		// A write to a channel's CHCR with STR set starts it.
		for base, ch in mem.DMA_BASE {
			if o == base && w & 0x100 != 0 {
				dma_start(u32(ch))
			}
		}
		return
	case a >= 0x12000000 && a < 0x12002000:
		o := a & 0x1fff
		switch o &~ 7 {
		case 0x1000:
			mem.gs_csr &~= u32(v) & 0x1f // write 1 clears interrupt bits
			return
		case 0x1010:
			mem.gs_imr = u32(v)
			return
		}
		(^u64)(&mem.gsregs[o &~ 7])^ = v
		return
	}
	unmapped(a, "write")
}

hw_read128 :: proc(a: u32) -> u128 {
	if a & 0x1ffffff0 == 0x10007000 {return ipu.ipu_fifo_read()}
	return u128(hw_read(a, 8)) | u128(hw_read(a + 8, 8)) << 64
}

hw_write128 :: proc(addr: u32, v: u128) {
	a := addr & 0x1fffffff
	switch a &~ 0xf {
	case 0x10004000, 0x10005000, 0x10006000, 0x10007010:
		fifo_write(a, v)
		return
	}
	hw_write(a, u64(v), 8)
	hw_write(a + 8, u64(v >> 64), 8)
}

unmapped_seen: map[u32]bool

@(private)
unmapped :: proc(a: u32, what: string) {
	if !unmapped_seen[a] {
		unmapped_seen[a] = true
		fmt.eprintfln("ee: unmapped %s at %08x", what, a)
	}
}

// Start a DMA transfer. Channels without an implementation complete at once.
dma_start :: proc(ch: u32) {
	if cpu.debug == 2 {fmt.eprintfln("dma: start ch %d chcr %08x tadr %08x", ch, mem.dma_reg(ch, 0)^, mem.dma_reg(ch, 0x30)^)}
	switch ch {
	case mem.DMA_VIF0, mem.DMA_VIF1: dma.dma_vif(ch)
	case mem.DMA_GIF:            dma.dma_gif()
	case mem.DMA_FROM_SPR:       dma.dma_from_spr()
	case mem.DMA_TO_SPR:         dma.dma_to_spr()
	case mem.DMA_FROM_IPU, mem.DMA_TO_IPU:
		ipu.ipu_dma_start(ch) // finishes as the IPU moves data
		return
	}
	mem.dma_finish(ch)
}

// Direct FIFO writes: VIF0, VIF1, GIF (PATH3), IPU in.
fifo_write :: proc(a: u32, v: u128) {
	v := v
	b := ([^]u8)(&v)[:16]
	switch (a >> 12) & 0xf {
	case 4: vu.vif_feed(&vu.vifs[0], b)
	case 5: vu.vif_feed(&vu.vifs[1], b)
	case 6: gif.gif_feed(2, b)
	case 7: ipu.ipu_fifo_write(v)
	}
}

