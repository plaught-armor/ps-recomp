package ps2_cpu

import "base:intrinsics"

// Host time per subsystem in TSC ticks, inclusive of nested work (VIF runs
// VU1 microprograms, which kick GIF packets; VU0 microprograms run from
// VCALLMS or VIF0). STATS prints the shares.
Prof :: enum {VU0, VU1, VIF, GIF, IPU, MIX}
prof: [Prof]u64

prof_start :: #force_inline proc() -> u64 {return u64(intrinsics.read_cycle_counter())}
// Unchecked: p is a Prof, and every caller names one.
prof_end :: #force_inline proc(p: Prof, t: u64) #no_bounds_check {prof[p] += u64(intrinsics.read_cycle_counter()) - t}
