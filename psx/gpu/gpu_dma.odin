// GPU and OTC DMA: ordering-table clears and the GPU's packet walk.
package psx_gpu

import "ps:core"
import cpu "../cpu"
import io "../io"
import render "../render"

// Ordering tables are cleared by OTC DMA; a clear of at least this many
// entries is taken as a frame's table (the last two, for double buffering).
@(private)
OT_MIN_ENTRIES :: 256

@(private)
ot_ranges: [2][2]u32

// The ordering-table bucket a linked-list node is, if it is one.
@(private)
ot_bucket :: proc(a: u32) -> (int, bool) {
	for r in ot_ranges {
		if r[1] != 0 && a >= r[0] && a <= r[1] {
			return int((a - r[0]) / 4), true
		}
	}
	return 0, false
}

dma_otc :: proc(c: ^io.Dma_Channel) {
	n := io.dma_words(c)
	a := c.madr
	if n >= OT_MIN_ENTRIES {
		ot_ranges[1] = ot_ranges[0]
		ot_ranges[0] = {(a - (n - 1) * 4) & 0x1ffffc, a & 0x1ffffc}
	}
	for i in 0 ..< n {
		cpu.w32(a, i == n - 1 ? 0x00ffffff : (a - 4) & 0x1fffff)
		a -= 4
	}
}

@(private = "file")
dma_walk_seen: [0x200000 / 4]u32 // packet address: the list walk that last passed it
@(private = "file")
dma_walk_serial: u32

dma_gpu :: proc(c: ^io.Dma_Channel) {
	switch (c.chcr >> 9) & 3 {
	case 2:
		// Linked list: walk packets from MADR.
		a := c.madr & 0x1ffffc
		render.see_begin()
		defer render.see_end()
		render.gpu_big_triangles = render.see.active
		defer render.gpu_big_triangles = false
		defer render.gpu_ghost_flush()
		defer render.walk_end()
		render.picture_walk_begin()
		defer render.picture_flush()
		// Before the walk's state above is spent, its queued draws are done.
		render.raster_begin()
		defer render.raster_end()
		dma_walk_serial += 1
		prev := u32(0)
		for _ in 0 ..< 0x100000 {
			// A packet linked twice closes a loop, which the PS1's GPU DMA
			// would walk for ever (it happens for a frame after an instant
			// door's world switch): the walk ends where it comes round.
			if dma_walk_seen[a >> 2] == dma_walk_serial {
				core.tracef(.Dma, "gpu list: packet %#x linked again from %#x, list ends", a, prev)
				break
			}
			dma_walk_seen[a >> 2] = dma_walk_serial
			prev = a
			tag := cpu.r32(a)
			n := tag >> 24
			// Ghosts go over the scene before bucket 0's HUD, which is drawn
			// after them; faded pixels there blend straight into VRAM.
			if (render.see.active && !render.see.direct) || render.depth_walk.on {
				if b, ok := ot_bucket(a); ok && b == 0 {
					if render.see.active && !render.see.direct {
						render.gpu_ghost_flush()
						render.see.direct = true
					}
					render.picture_flush()
				}
			}
			render.packet_at(a)
			for k in u32(0) ..< n {
				gp0_write(cpu.r32(a + 4 + k * 4))
			}
			if tag & 0x800000 != 0 {
				break
			}
			a = tag & 0x1ffffc
		}
	case:
		n := io.dma_words(c)
		a := c.madr & 0x1ffffc
		if c.chcr & 1 != 0 {
			for _ in 0 ..< n {
				gp0_write(cpu.r32(a))
				a += 4
			}
		} else {
			for _ in 0 ..< n {
				cpu.w32(a, gpu_read())
				a += 4
			}
		}
	}
}
