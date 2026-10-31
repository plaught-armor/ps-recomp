// sysmem: the one allocator over IOP RAM. A list of used blocks sorted by
// address, searched first-fit as retail sysmem does. Allocation depends only
// on the order of calls, which is emulated, so it is deterministic. The EE's
// heap RPC (sceSifAllocIopHeap) and the IOP's AllocSysMemory share it, so
// their blocks never overlap.
//
// Addresses can differ from retail: retail's kernel and modules sit below
// and among the blocks, and the HLE's do not.
package ps2_iop

// Nothing of the HLE lives in IOP RAM above this; the command buffer
// (IOP_CMDBUF) and the exception vectors lie below.
SYS_BASE :: 0x00040000
SYS_END :: IOP_RAM_SIZE
SYS_ALIGN :: 0x100

Sys_Alloc :: enum u32 {
	Low  = 0, // the lowest gap that fits
	High = 1, // the highest gap that fits, at its top
	Addr = 2, // exactly at the given address
}

Sys_Block :: struct {
	addr, size: u32,
}

// Emulated state: the array's storage is in the emu heap, so it is
// snapshotted with it (sif_snap).
sys_blocks: [dynamic]Sys_Block

sys_init :: proc() {
	clear(&sys_blocks)
}

// A block of `req` bytes rounded up to SYS_ALIGN, or 0 when none fits. A
// size of 0 returns where a block of SYS_ALIGN would go and allocates
// nothing, as the EE heap's old bump allocator did: not the empty gap
// between two adjacent blocks.
sys_alloc :: proc(kind: Sys_Alloc, req: u32, addr: u32 = 0) -> u32 {
	if req > SYS_END - SYS_BASE {return 0}
	size := (req + SYS_ALIGN - 1) &~ (SYS_ALIGN - 1)
	need := max(size, SYS_ALIGN)
	at, i: u32
	found: bool
	switch kind {
	case .Low:
		for g in 0 ..= u32(len(sys_blocks)) {
			lo, hi := sys_gap(g)
			if hi - lo >= need {at, i, found = lo, g, true; break}
		}
	case .High:
		for g := len(sys_blocks); g >= 0; g -= 1 {
			lo, hi := sys_gap(u32(g))
			if hi - lo >= need {at, i, found = hi - size, u32(g), true; break}
		}
	case .Addr:
		if addr % SYS_ALIGN != 0 {return 0}
		for g in 0 ..= u32(len(sys_blocks)) {
			lo, hi := sys_gap(g)
			if addr >= lo && u64(addr) + u64(need) <= u64(hi) {at, i, found = addr, g, true; break}
		}
	}
	if !found {return 0}
	if size > 0 {inject_at(&sys_blocks, i, Sys_Block{at, size})}
	return at
}

// Frees the block starting at `addr`; false when no block starts there.
sys_free :: proc(addr: u32) -> bool {
	for b, i in sys_blocks {
		if b.addr == addr {
			ordered_remove(&sys_blocks, i)
			return true
		}
	}
	return false
}

// The largest free gap, and the sum of all of them.
sys_free_sizes :: proc() -> (largest, total: u32) {
	for g in 0 ..= u32(len(sys_blocks)) {
		lo, hi := sys_gap(g)
		largest = max(largest, hi - lo)
		total += hi - lo
	}
	return
}

// The gap before block g, or after the last block when g is the count.
@(private = "file")
sys_gap :: proc(g: u32) -> (lo, hi: u32) {
	lo = SYS_BASE if g == 0 else sys_blocks[g - 1].addr + sys_blocks[g - 1].size
	hi = SYS_END if g == u32(len(sys_blocks)) else sys_blocks[g].addr
	return
}
