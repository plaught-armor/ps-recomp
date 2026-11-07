package ps2_cpu

import "base:intrinsics"
import "core:time"

_ :: time // used on wasm only

// Host time per subsystem, inclusive of nested work (VIF runs VU1
// microprograms, which kick GIF packets; VU0 microprograms run from VCALLMS
// or VIF0; GIF packets run the GS, so GIF holds the software rasterizer).
// prof_top is the time inside an outermost section: what the frame spent
// outside the EE's own code, so STATS takes the EE as the rest. STATS prints
// the shares.
Prof :: enum {VU0, VU1, VIF, GIF, IPU, MIX, IOP, PRESENT}
prof: [Prof]u64
prof_top: u64
prof_depth: int

// Natively TSC ticks. wasm has no cycle counter (read_cycle_counter is 0
// there), so it reads the monotonic clock in ns: a host import, ~100 ns in a
// browser, so only once STATS sets prof_on. A crossOriginIsolated page's
// clock has 5 us steps.
prof_on: bool

when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
	prof_now :: #force_inline proc() -> u64 {return prof_on ? u64(time.tick_now()._nsec) : 0}
} else {
	prof_now :: #force_inline proc() -> u64 {return u64(intrinsics.read_cycle_counter())}
}

prof_start :: #force_inline proc() -> u64 {
	prof_depth += 1
	return prof_now()
}

// Unchecked: p is a Prof, and every caller names one.
prof_end :: #force_inline proc(p: Prof, t: u64) #no_bounds_check {
	d := prof_now() - t
	prof[p] += d
	prof_depth -= 1
	if prof_depth == 0 {prof_top += d}
}
