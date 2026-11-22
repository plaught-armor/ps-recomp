// The trace lines that need the CPU's registers; tracing itself lives in
// ps:core (core/trace.odin).
package psx_cpu

import "ps:core"

trace_init :: proc() -> bool {
	return core.trace_init(&presents, &state.cycles)
}

// Recompiled code: entered the block at pc.
trace_block :: proc(pc: u32) {
	if !core.trace_pc_ok(pc) {
		return
	}
	r := &state.r
	core.tracef(.Block, "%08x v0=%x v1=%x a0=%x a1=%x a2=%x a3=%x t0=%x s0=%x sp=%x ra=%x",
		pc, r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[16], r[29], r[31])
}

// Called from the store path only when core.trace.watching is set. RAM
// shows four times in the first 8 MB, so a watch inside one copy sees the
// stores through every copy: FF8's decoder wrote 0x80010000 through
// 0x80210000, which a watch on 0x80010000 missed.
trace_store :: proc(a, v, size: u32) {
	if core.trace_watched(a, size) || trace_watched_ram(a, size) {
		core.tracef(.Mem, "store%d [%08x] = %x ra=%x", size * 8, a, v, state.r[31])
	}
}

// Whether a store of size bytes at a hits the watch range, both folded to
// one copy of RAM; false for a range not inside one copy of it.
@(private = "file")
trace_watched_ram :: proc(a, size: u32) -> bool {
	lo, hi := core.trace.watch_lo, core.trace.watch_hi
	if hi >= 0x800000 || lo / RAM_SIZE != hi / RAM_SIZE {return false}
	p := a & 0x1fffffff
	if p >= 0x800000 {return false}
	p &= RAM_SIZE - 1
	return p + size > lo & (RAM_SIZE - 1) && p <= hi & (RAM_SIZE - 1)
}
