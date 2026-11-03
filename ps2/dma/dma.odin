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

// Bytes a source-chain or normal transfer delivers, including the tags when
// TTE is set (the upper half into a VIF, the whole tag into scratchpad).
@(private)
dma_gather :: proc(ch: u32, out: ^[dynamic]u8) {
	chcr := mem.dma_reg(ch, 0x00)
	madr := mem.dma_reg(ch, 0x10)
	qwc := mem.dma_reg(ch, 0x20)
	tadr := mem.dma_reg(ch, 0x30)

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
	for _ in 0 ..< 1 << 20 {
		t := tadr^
		tag_tte(ch, out, t)
		addr, n, _, done := src_tag(ch, t)
		data(out, addr, n)
		if done {return}
	}
	fmt.eprintfln("dma: ch %d chain did not end", ch)
}

// TTE sends the tag at t ahead of its data into a VIF and into scratchpad: a
// VIF gets the upper half, as VIF codes, and toSPR the whole quadword
// (PCSX2's SPR.cpp, _SPR1chain: SPR1transfer(ptag, 1)). The GIF takes the
// tag for MADR and QWC alone, as PCSX2's GIF chain does (Gif.cpp has no TTE
// case): appended there, the tag would shift the PATH3 stream off its
// quadwords.
@(private)
tag_tte :: proc(ch: u32, out: ^[dynamic]u8, t: u32) {
	if mem.dma_reg(ch, 0x00)^ & 0x40 == 0 {return}
	switch ch {
	case mem.DMA_TO_SPR:
		append(out, ..mem.ram_slice(mem.dma_addr(t), 16))
	case mem.DMA_VIF0, mem.DMA_VIF1:
		append(out, ..mem.ram_slice(mem.dma_addr(t + 8), 8))
	}
}

// Take the source-chain tag at t: copy its upper bits into CHCR, move TADR
// and the call stack on, and return where its data is, how many quadwords,
// the tag's ID, and whether the chain ends with it (refe, end, ret with an
// empty stack, or TIE and the tag's IRQ bit).
@(private)
src_tag :: proc(ch, t: u32) -> (addr, n, id: u32, done: bool) {
	chcr := mem.dma_reg(ch, 0x00)
	tadr := mem.dma_reg(ch, 0x30)
	asr := [2]^u32{mem.dma_reg(ch, 0x40), mem.dma_reg(ch, 0x50)}
	lo := mem.rd64(mem.dma_addr(t))
	n = u32(lo & 0xffff)
	id = u32(lo >> 28) & 7
	ref := u32(lo >> 32) & 0xfffffff0
	chcr^ = (chcr^ & 0xffff) | u32(lo >> 16) << 16
	addr = t + 16
	switch id {
	case 0: // refe
		addr, done = ref, true
	case 1: // cnt
		tadr^ = t + 16 + n * 16
	case 2: // next
		tadr^ = ref
	case 3, 4: // ref, refs
		addr = ref
		tadr^ = t + 16
	case 5: // call
		sp := (chcr^ >> 4) & 3
		if sp < 2 {
			asr[sp]^ = t + 16 + n * 16
			chcr^ = (chcr^ &~ 0x30) | (sp + 1) << 4
		}
		tadr^ = ref
	case 6: // ret
		sp := (chcr^ >> 4) & 3
		if sp == 0 {
			done = true
		} else {
			sp -= 1
			tadr^ = asr[sp]^
			chcr^ = (chcr^ &~ 0x30) | sp << 4
		}
	case 7: // end
		done = true
	}
	if chcr^ & 0x80 != 0 && lo & 0x80000000 != 0 {done = true}
	return
}

// ------------------------------------------------------------- MFIFO

// D_CTRL.MFD makes fromSPR write into a ring in memory, D_RBOR up to
// D_RBOR + D_RBSR + 16, and VIF1 (MFD 2) or GIF (MFD 3) drain it as a source
// chain. fromSPR's MADR is the ring's write end and the drain's TADR its
// read end. The rules follow PCSX2 (Gif.cpp mfifoGIFtransfer,
// mfifoGIFrbTransfer, QWCinGIFMFIFO, mfifoGifMaskMem, gifMFIFOInterrupt;
// Hw.cpp hwMFIFOWrite, hwMFIFOResume, FireMFIFOEmpty; SPR.cpp _SPR0chain,
// SPRFROMinterrupt):
// - Tags are read at TADR wrapped into the ring. Data that follows its tag
//   (cnt, next, call, ret, end) is wrapped into the ring too, and wraps at
//   the ring's top mid-transfer; ref, refs and refe data is read where the
//   tag points, outside the ring.
// - The drain moves only what the ring holds. When TADR or MADR reaches
//   fromSPR's MADR it stops with STR still set and raises D_STAT.MEIS: once
//   each time it runs dry, not while it waits.
// - The end of a fromSPR transfer restarts a stopped drain; nothing polls.
// VIF1 drains with the same code; only where the data goes differs.

D_CTRL :: 0xe000
D_RBSR :: 0xe040
D_RBOR :: 0xe050
D_STAT_MEIS :: 1 << 14

// Drain state, saved by snapshots: the chain's last tag has been read (only
// the data left in QWC remains), and the drain stopped on an empty ring.
@(private)
mfifo_last: bool
@(private)
mfifo_stalled: bool

// Whether ch is the channel draining the MFIFO: GIF under MFD 3, VIF1
// reading memory (CHCR.DIR set) under MFD 2.
mfifo_owns :: proc(ch: u32) -> bool {
	switch (mem.hw_reg(D_CTRL)^ >> 2) & 3 {
	case 2: return ch == mem.DMA_VIF1 && mem.dma_reg(ch, 0x00)^ & 1 != 0
	case 3: return ch == mem.DMA_GIF
	}
	return false
}

@(private)
ring_base :: proc() -> u32 {return mem.hw_reg(D_RBOR)^ & 0x7ffffff0}
@(private)
ring_mask :: proc() -> u32 {return mem.hw_reg(D_RBSR)^ & 0x7ffffff0}
@(private)
ring_wrap :: proc(a: u32) -> u32 {return ring_base() + (a & ring_mask())}
@(private)
in_ring :: proc(a: u32) -> bool {return a &~ (ring_mask() | 0xf) == ring_base()}

// Quadwords the ring holds from a up to fromSPR's MADR (QWCinGIFMFIFO).
@(private)
ring_avail :: proc(a: u32) -> u32 {
	w := mem.dma_reg(mem.DMA_FROM_SPR, 0x10)^
	if a <= w {return (w - a) >> 4}
	return (w + ring_mask() + 16 - a) >> 4 // (w - base) + (top - a)
}

// Start the drain channel ch (mfifo_owns). True when it finished at once;
// false when STR stays set: it stopped on an empty ring, or its GIF data is
// held (gif_dma_hold).
mfifo_start :: proc(ch: u32) -> bool {
	mfifo_last = (mem.dma_reg(ch, 0x00)^ >> 2) & 3 != 1 // normal mode: QWC only
	return mfifo_run(ch)
}

// The end of a fromSPR transfer: data was added, so a stopped drain goes on.
@(private)
mfifo_resume :: proc() {
	ch: u32 = mem.DMA_GIF
	if (mem.hw_reg(D_CTRL)^ >> 2) & 3 == 2 {ch = mem.DMA_VIF1}
	if !mfifo_stalled || !mfifo_owns(ch) || mem.dma_reg(ch, 0x00)^ & 0x100 == 0 {return}
	if mfifo_run(ch) {mem.dma_finish(ch)}
}

// Drain as far as the ring allows and feed what was read to ch's unit.
@(private)
mfifo_run :: proc(ch: u32) -> bool {
	madr := mem.dma_reg(ch, 0x10)
	qwc := mem.dma_reg(ch, 0x20)
	tadr := mem.dma_reg(ch, 0x30)
	clear(&dma_buf)
	mfifo_stalled = false
	for _ in 0 ..< 1 << 20 {
		if qwc^ & 0xffff == 0 {
			if mfifo_last {break}
			tadr^ = ring_wrap(tadr^)
			if ring_avail(tadr^) == 0 {
				mfifo_stalled = true
				break
			}
			t := tadr^
			tag_tte(ch, &dma_buf, t)
			addr, n, id, last := src_tag(ch, t)
			switch id {
			case 1, 2, 5, 6, 7: addr = ring_wrap(addr) // the data follows the tag
			}
			tadr^ = ring_wrap(tadr^)
			madr^, qwc^, mfifo_last = addr, n, last
			continue
		}
		n := qwc^ & 0xffff
		if !in_ring(madr^) {
			append(&dma_buf, ..mem.ram_slice(mem.dma_addr(madr^), n * 16))
			madr^ += n * 16
			qwc^ = 0
			continue
		}
		k := min(n, ring_avail(madr^))
		if k == 0 {
			mfifo_stalled = true
			break
		}
		top := ring_base() + ring_mask() + 16
		first := min(k, (top - madr^) >> 4)
		append(&dma_buf, ..mem.ram_slice(mem.dma_addr(madr^), first * 16))
		if k > first {append(&dma_buf, ..mem.ram_slice(mem.dma_addr(ring_base()), (k - first) * 16))}
		madr^ = ring_wrap(madr^ + k * 16)
		qwc^ = n - k
	}
	if len(dma_buf) != 0 {
		if ch == mem.DMA_GIF {
			gif.gif_feed(2, dma_buf[:])
		} else {
			vu.vif_feed(&vu.vifs[ch], dma_buf[:])
		}
	}
	if mfifo_stalled {
		mem.dmac_stat |= D_STAT_MEIS
		return false
	}
	// A finished GIF drain keeps STR set while PATH3 data waits past the
	// GIF FIFO; gif_arbitrate finishes it once the queue has run.
	return !(ch == mem.DMA_GIF && gif.gif_dma_hold())
}

// ------------------------------------------------------------ scratchpad

// fromSPR, normal mode: QWC quadwords from SADR in scratchpad to MADR.
// No bounds checks here: the scratchpad offset is masked and the RAM slice
// is 16 bytes long; ram_slice still checks the guest address.
dma_from_spr :: proc() #no_bounds_check {
	madr := mem.dma_reg(mem.DMA_FROM_SPR, 0x10)
	qwc := mem.dma_reg(mem.DMA_FROM_SPR, 0x20)
	sadr := mem.dma_reg(mem.DMA_FROM_SPR, 0x80)
	if (mem.dma_reg(mem.DMA_FROM_SPR, 0)^ >> 2) & 3 != 0 {
		fmt.eprintln("dma: fromSPR chain mode unsupported")
	}
	n := qwc^ & 0xffff
	if cpu.debug >= 2 {fmt.eprintfln("dma: fromSPR %04x -> %08x qwc %d", sadr^, madr^, n)}
	// Under MFD, a transfer into the ring wraps at its top (_SPR0chain).
	ring := (mem.hw_reg(D_CTRL)^ >> 2) & 3 != 0 && ring_mask() != 0 && in_ring(madr^)
	for _ in 0 ..< n {
		s := sadr^ & (mem.SPR_SIZE - 16)
		intrinsics.unaligned_store((^u128)(&mem.ram_slice(mem.dma_addr(madr^), 16)[0]), intrinsics.unaligned_load((^u128)(&mem.spr[s])))
		madr^ = ring ? ring_wrap(madr^ + 16) : madr^ + 16
		sadr^ = (sadr^ + 16) & (mem.SPR_SIZE - 16)
	}
	qwc^ = 0
	mfifo_resume()
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
	core.snap_add(&mfifo_last)
	core.snap_add(&mfifo_stalled)
}
