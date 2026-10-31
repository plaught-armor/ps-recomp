// EE hardware register state: timers, DMAC, INTC and the GS privileged
// registers. Package ps2 dispatches accesses (bus.odin); unhandled registers
// read back what was written.
package ps2_mem

import "ps:core"
import cpu "../cpu"

INTC_GS :: 0
INTC_SBUS :: 1
INTC_VBLANK_START :: 2
INTC_VBLANK_END :: 3
INTC_VIF0 :: 4 // INTC_VIF1 is 5
INTC_IPU :: 8
INTC_TIMER0 :: 9

DMA_VIF0 :: 0
DMA_VIF1 :: 1
DMA_GIF :: 2
DMA_FROM_IPU :: 3
DMA_TO_IPU :: 4
DMA_SIF0 :: 5
DMA_SIF1 :: 6
DMA_SIF2 :: 7
DMA_FROM_SPR :: 8
DMA_TO_SPR :: 9

// Base of each DMA channel's registers.
DMA_BASE := [10]u32{0x8000, 0x9000, 0xa000, 0xb000, 0xb400, 0xc000, 0xc400, 0xc800, 0xd000, 0xd400}

hwregs: [0x10000]u8 // 0x10000000..0x1000ffff
gsregs: [0x2000]u8 // 0x12000000..0x12001fff

intc_stat, intc_mask: u32
// Raised but not yet delivered to kernel handlers. Kept apart from
// INTC_STAT, which only software clears: libraries poll it for VBLANK
// with interrupts enabled.
intc_pending: u32
dmac_stat: u32 // D_STAT: low half status, high half mask
gs_csr: u32
gs_imr: u32 = 0x7f00

// Unchecked: the mask keeps the word inside hwregs whatever o is.
hw_reg :: #force_inline proc(o: u32) -> ^u32 #no_bounds_check {
	return (^u32)(&hwregs[o & 0xfffc])
}

// Unchecked: ch never comes from the guest. Callers pass a DMA_* constant,
// or the index of the DMA_BASE entry a CHCR write matched (bus.odin), and
// the check holds them to that; hw_reg masks the sum. An if, not assert:
// under separate modules assert is an out-of-line call on every access.
dma_reg :: #force_inline proc(ch, off: u32) -> ^u32 #no_bounds_check {
	if ch >= len(DMA_BASE) {panic("dma_reg: ch is a DMA_* channel")}
	return hw_reg(DMA_BASE[ch] + off)
}

// DMA addresses with bit 31 set refer to scratchpad.
dma_addr :: #force_inline proc(a: u32) -> u32 {
	return a & 0x80000000 != 0 ? SPR_BASE | (a & (SPR_SIZE - 1)) : a & 0x0fffffff
}

// Raise an INTC interrupt.
intc_raise :: proc(n: u32) {
	intc_stat |= 1 << n
	intc_pending |= 1 << n
	if !cpu.in_interrupt {cpu.next_event = cpu.state.cycles}
}

// Mark a DMA channel finished and raise its DMAC interrupt.
dma_finish :: proc(ch: u32) {
	chcr := dma_reg(ch, 0)
	chcr^ &~= 0x100
	dmac_stat |= 1 << ch
	if !cpu.in_interrupt {cpu.next_event = cpu.state.cycles}
}

// T_MODE bits.
T_ZRET :: 0x40 // the count goes back to 0 when it reaches T_COMP
T_CUE :: 0x80
T_CMPE :: 0x100
T_OVFE :: 0x200
T_EQUF :: 0x400 // compare happened; written 1 to clear
T_OVFF :: 0x800 // overflow happened; written 1 to clear

// Per timer: the cycle its count was last 0 at, in its clock from there
// (the count is derived, never stored), and the cycle of its next compare or
// overflow event, max(u64) for none.
timer_origin: [4]u64
timer_next := [4]u64{max(u64), max(u64), max(u64), max(u64)}

// EE cycles per tick of the clock a T_MODE selects: the bus clock is half
// the EE's. Hblank is a fixed period from cycle 0, not locked to the
// kernel's vblank; gating on hblank or vblank is not modelled.
@(private)
timer_div :: proc(mode: u32) -> u64 {
	switch mode & 3 {
	case 0: return 2
	case 1: return 32
	case 2: return 512
	}
	return cpu.CYCLES_PER_FRAME / 262
}

@(private)
timer_mode :: #force_inline proc(n: u32) -> ^u32 {
	return hw_reg(0x800 * n + 0x10)
}

// The count keeps running whatever T_CUE says, as it always did here;
// only the events wait for T_CUE.
timer_count :: proc(n: u32) -> u32 {
	return u32(((cpu.state.cycles - timer_origin[n]) / timer_div(timer_mode(n)^)) & 0xffff)
}

// A write to T_COUNT, T_MODE, T_COMP or T_HOLD (reg is the offset in the
// timer's block). The flags in T_MODE clear where written 1; a T_MODE write
// keeps the count, in the new clock.
timer_write :: proc(n, reg, w: u32) {
	now := cpu.state.cycles
	mode := timer_mode(n)
	switch reg {
	case 0x00:
		timer_origin[n] = now - u64(w & 0xffff) * timer_div(mode^)
	case 0x10:
		c := u64(timer_count(n))
		mode^ = mode^ & ~w & (T_EQUF | T_OVFF) | w & 0x3ff
		timer_origin[n] = now - c * timer_div(mode^)
	case:
		hw_reg(0x800 * n + reg)^ = w & 0xffff
	}
	timer_schedule(n, now)
}

// Find the timer's next event after cycle from: the count reaching T_COMP,
// when that sets a flag or resets the count, or wrapping past 0xffff, when
// that sets one.
@(private)
timer_schedule :: proc(n: u32, from: u64) {
	timer_next[n] = max(u64)
	mode := timer_mode(n)^
	if mode & T_CUE == 0 || mode & (T_CMPE | T_OVFE | T_ZRET) == 0 {return}
	div := timer_div(mode)
	ticks := (from - timer_origin[n]) / div
	count := ticks & 0xffff
	wrap := ticks - count + 0x10000 // where the count next goes past 0xffff
	next := max(u64)
	if mode & (T_CMPE | T_ZRET) != 0 {
		comp := u64(hw_reg(0x800 * n + 0x20)^ & 0xffff)
		next = comp > count ? wrap - 0x10000 + comp : wrap + comp
	}
	if mode & T_OVFE != 0 {next = min(next, wrap)}
	timer_next[n] = timer_origin[n] + next * div
	if !cpu.in_interrupt {cpu.next_event = min(cpu.next_event, timer_next[n])}
}

// Run the timer events due by now: set the flags their T_MODE asks for,
// raise INTC 9+n when one was clear, and reset counts for T_ZRET.
timer_events :: proc(now: u64) {
	for n in u32(0) ..< 4 {
		for timer_next[n] <= now {
			at := timer_next[n]
			mode := timer_mode(n)
			count := ((at - timer_origin[n]) / timer_div(mode^)) & 0xffff
			flags: u32
			if count == 0 && mode^ & T_OVFE != 0 {flags |= T_OVFF}
			if count == u64(hw_reg(0x800 * n + 0x20)^ & 0xffff) {
				if mode^ & T_CMPE != 0 {flags |= T_EQUF}
				if mode^ & T_ZRET != 0 {timer_origin[n] = at}
			}
			if flags &~ mode^ != 0 {intc_raise(INTC_TIMER0 + n)}
			mode^ |= flags
			timer_schedule(n, at)
		}
	}
}

// Emulated state, saved and restored by snapshots (snap.odin).
hw_snap :: proc() {
	core.snap_add(&hwregs)
	core.snap_add(&gsregs)
	core.snap_add(&intc_stat)
	core.snap_add(&intc_mask)
	core.snap_add(&intc_pending)
	core.snap_add(&dmac_stat)
	core.snap_add(&gs_csr)
	core.snap_add(&gs_imr)
	core.snap_add(&timer_origin)
	core.snap_add(&timer_next)
}
