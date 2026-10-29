// DMA into the VIFs (vu/vif.odin) and the GIF (gif/gif.odin). Transfers run
// to completion when the channel is started: the source chain is walked, the
// words are fed to the VIF or GIF, and the channel is marked finished.
package ps2_dma

import "base:intrinsics"
import "core:fmt"
import "ps:core"
import cpu "../cpu"
import gif "../gif"
import gs "../gs"
import mem "../mem"
import vu "../vu"

// ------------------------------------------------------------- DMA source

// Bytes a source-chain or normal transfer delivers, including the upper
// half of each tag when TTE is set (VIF channels).
@(private)
dma_gather :: proc(ch: u32, out: ^[dynamic]u8) {
	chcr := mem.dma_reg(ch, 0x00)
	madr := mem.dma_reg(ch, 0x10)
	qwc := mem.dma_reg(ch, 0x20)
	tadr := mem.dma_reg(ch, 0x30)
	asr := [2]^u32{mem.dma_reg(ch, 0x40), mem.dma_reg(ch, 0x50)}

	data :: proc(out: ^[dynamic]u8, addr, qwc: u32) {
		if qwc >= 1024 && cpu.debug == 2 {fmt.eprintfln("dma: data %08x qwc %x", addr, qwc)}
		if qwc != 0 {append(out, ..mem.ram_slice(mem.dma_addr(addr), qwc * 16))}
	}

	if (chcr^ >> 2) & 3 != 1 { // normal (or interleave, treated as normal)
		data(out, madr^, qwc^ & 0xffff)
		madr^ += (qwc^ & 0xffff) * 16
		qwc^ = 0
		return
	}
	// A transfer started with QWC set first drains MADR.
	if qwc^ & 0xffff != 0 {
		data(out, madr^, qwc^ & 0xffff)
		qwc^ = 0
	}
	tte := chcr^ & 0x40 != 0
	tie := chcr^ & 0x80 != 0
	for _ in 0 ..< 1 << 20 {
		t := tadr^
		lo := mem.rd64(mem.dma_addr(t))
		hi := mem.rd64(mem.dma_addr(t + 8))
		n := u32(lo & 0xffff)
		id := (lo >> 28) & 7
		addr := u32(lo >> 32) & 0xfffffff0
		chcr^ = (chcr^ & 0xffff) | u32(lo >> 16) << 16
		if tte {
			for i in 0 ..< 8 {append(out, u8(hi >> (8 * u32(i))))}
		}
		done := false
		switch id {
		case 0: // refe
			data(out, addr, n)
			done = true
		case 1: // cnt
			data(out, t + 16, n)
			tadr^ = t + 16 + n * 16
		case 2: // next
			data(out, t + 16, n)
			tadr^ = addr
		case 3, 4: // ref, refs
			data(out, addr, n)
			tadr^ = t + 16
		case 5: // call
			data(out, t + 16, n)
			sp := (chcr^ >> 4) & 3
			if sp < 2 {
				asr[sp]^ = t + 16 + n * 16
				chcr^ = (chcr^ &~ 0x30) | (sp + 1) << 4
			}
			tadr^ = addr
		case 6: // ret
			data(out, t + 16, n)
			sp := (chcr^ >> 4) & 3
			if sp == 0 {
				done = true
			} else {
				sp -= 1
				tadr^ = asr[sp]^
				chcr^ = (chcr^ &~ 0x30) | sp << 4
			}
		case 7: // end
			data(out, t + 16, n)
			done = true
		}
		if done || (tie && lo & 0x80000000 != 0) {return}
	}
	fmt.eprintfln("dma: ch %d chain did not end", ch)
}

// ------------------------------------------------------------ scratchpad

// fromSPR, normal mode: QWC quadwords from SADR in scratchpad to MADR.
dma_from_spr :: proc() {
	madr := mem.dma_reg(mem.DMA_FROM_SPR, 0x10)
	qwc := mem.dma_reg(mem.DMA_FROM_SPR, 0x20)
	sadr := mem.dma_reg(mem.DMA_FROM_SPR, 0x80)
	if (mem.dma_reg(mem.DMA_FROM_SPR, 0)^ >> 2) & 3 != 0 {
		fmt.eprintln("dma: fromSPR chain mode unsupported")
	}
	n := qwc^ & 0xffff
	if cpu.debug >= 2 {fmt.eprintfln("dma: fromSPR %04x -> %08x qwc %d", sadr^, madr^, n)}
	for _ in 0 ..< n {
		s := sadr^ & (mem.SPR_SIZE - 16)
		intrinsics.unaligned_store((^u128)(&mem.ram_slice(mem.dma_addr(madr^), 16)[0]), intrinsics.unaligned_load((^u128)(&mem.spr[s])))
		madr^ += 16
		sadr^ = (sadr^ + 16) & (mem.SPR_SIZE - 16)
	}
	qwc^ = 0
}

// toSPR: the source chain, normal or interleaved block into scratchpad at SADR.
dma_to_spr :: proc() {
	sadr := mem.dma_reg(mem.DMA_TO_SPR, 0x80)
	mode := (mem.dma_reg(mem.DMA_TO_SPR, 0)^ >> 2) & 3
	if mode == 2 {
		dma_to_spr_interleave(sadr)
		return
	}
	if mode != 1 { // normal: copy straight from MADR
		madr := mem.dma_reg(mem.DMA_TO_SPR, 0x10)
		qwc := mem.dma_reg(mem.DMA_TO_SPR, 0x20)
		n := (qwc^ & 0xffff) * 16
		if cpu.debug >= 2 {fmt.eprintfln("dma: toSPR %08x -> %04x bytes %d", madr^, sadr^, n)}
		if n != 0 {spr_write(sadr, mem.ram_slice(mem.dma_addr(madr^), n))}
		madr^ += n
		qwc^ = 0
		return
	}
	buf := make([dynamic]u8, context.temp_allocator)
	dma_gather(mem.DMA_TO_SPR, &buf)
	if cpu.debug >= 2 {fmt.eprintfln("dma: toSPR %08x -> %04x bytes %d", mem.dma_reg(mem.DMA_TO_SPR, 0x10)^, sadr^, len(buf))}
	spr_write(sadr, buf[:])
}

// toSPR, interleave mode: QWC quadwords from MADR in blocks of D_SQWC.TQWC,
// skipping D_SQWC.SQWC quadwords of memory after each block; scratchpad is
// written contiguously. Movie players split stereo ADPCM this way.
@(private)
dma_to_spr_interleave :: proc(sadr: ^u32) {
	madr := mem.dma_reg(mem.DMA_TO_SPR, 0x10)
	qwc := mem.dma_reg(mem.DMA_TO_SPR, 0x20)
	sqwc := mem.hw_reg(0xe030)^
	skip := sqwc & 0xff
	n := qwc^ & 0xffff
	tqwc := (sqwc >> 16) & 0xff
	if tqwc == 0 {tqwc = n}
	if cpu.debug >= 2 {fmt.eprintfln("dma: toSPR %08x -> %04x qwc %d interleave %d/%d", madr^, sadr^, n, tqwc, skip)}
	for n > 0 {
		k := min(n, tqwc)
		spr_write(sadr, mem.ram_slice(mem.dma_addr(madr^), k * 16))
		madr^ += (k + skip) * 16
		n -= k
	}
	qwc^ = 0
}

// Copy whole quadwords of src to scratchpad at sadr^, wrapping at its end.
@(private)
spr_write :: proc(sadr: ^u32, src: []u8) {
	for i := 0; i + 16 <= len(src); {
		s := sadr^ & (mem.SPR_SIZE - 16)
		n := min(len(src) - i, mem.SPR_SIZE - int(s)) &~ 15
		copy(mem.spr[s:][:n], src[i:][:n])
		i += n
		sadr^ = (sadr^ + u32(n)) & (mem.SPR_SIZE - 16)
	}
}

// ------------------------------------------------------------- channels

@(private)
dma_buf: [dynamic]u8

dma_vif :: proc(ch: u32) {
	// VIF1 to memory (CHCR.DIR clear): a GS local-to-host transfer read
	// back through the FIFO, normal mode only.
	if ch == mem.DMA_VIF1 && mem.dma_reg(ch, 0x00)^ & 1 == 0 {
		madr := mem.dma_reg(ch, 0x10)
		qwc := mem.dma_reg(ch, 0x20)
		n := (qwc^ & 0xffff) * 16
		if n != 0 {gs.readback(mem.ram_slice(mem.dma_addr(madr^), n))}
		madr^ += n
		qwc^ = 0
		return
	}
	clear(&dma_buf)
	dma_gather(ch, &dma_buf)
	vu.vif_feed(&vu.vifs[ch], dma_buf[:])
}

dma_gif :: proc() {
	clear(&dma_buf)
	dma_gather(mem.DMA_GIF, &dma_buf)
	gif.gif_feed(2, dma_buf[:])
}

// Emulated state, saved and restored by snapshots (snap.odin).
dma_snap :: proc() {
	core.snap_add(&dma_buf)
}
