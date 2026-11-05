// What the software GS shares with the GPU GS (gpu.odin), which not every
// target builds: the switch between them, local memory's page count, and
// the save state regions.
package ps2_gs

import "core:mem"

// Set by hw_init: draws, transfers and scanout go to the GPU.
hw_on: bool

@(private)
PAGES :: 512 // 8 KiB pages of local memory

@(private)
Page_Set :: [PAGES / 64]u64

// Emulated GS state outside gs, for save states (add registers a
// region): the front end's, and local memory itself when the software GS
// holds it; the GPU GS saves its copy through hw_snap_save/hw_snap_load.
snap_regions :: proc(add: proc(b: []u8)) {
	add(mem.ptr_to_bytes(&xfer))
	add(mem.ptr_to_bytes(&clut))
	add(mem.ptr_to_bytes(&cbp0))
	add(mem.ptr_to_bytes(&cbp1))
	add(mem.ptr_to_bytes(&cur))
	add(mem.ptr_to_bytes(&queue))
	add(mem.ptr_to_bytes(&nq))
	if !hw_on {add(mem.ptr_to_bytes(&vram))}
}
