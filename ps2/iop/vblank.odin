// The vblank library's waits (PS_IRX=1), as read from the disc copy of
// VBLANK 1.1. Its start makes an event flag, empty, and hooks the vblank
// start and end interrupts: at a start its handler sets bits 1 and 2 and
// clears 4 and 8, at an end sets 4 and 8 and clears 1 and 2. Functions 4
// to 7 each wait on that flag for one bit, OR mode, and return what the
// wait returns:
//
//	4 WaitVblankStart, bit 1, and 6 WaitVblank, bit 2: the next start, at
//	  once while in vblank (the last edge a start);
//	5 WaitVblankEnd, bit 4, and 7 WaitNonVblank, bit 8: the next end, at
//	  once while out of it (the last edge an end).
//
// The flag is not kept here: it follows from the EE kernel's vblank
// schedule, the clock the EE's own vblank interrupts come from, so the two
// sides cannot drift. That schedule is NTSC only (cpu.CYCLES_PER_FRAME);
// PAL follows when it has one. The flag is taken as of the last edge since
// boot, before the first start as retail's empty one. A waiter is a thread
// delayed to its edge, so the scheduler wakes it with DelayThread's, every
// waiter on one edge in the order they began to wait, and snapshots and a
// failed load's undo carry or drop it with the thread. A handler that
// calls one is stopped (th_wait_until).
//
// 8 and 9, which add and remove a user's vblank handler, stay unserved.
package ps2_iop

import cpu "../cpu"
import r3000 "ps:psx/cpu"

// The EE kernel's next vblank start and end, EE cycles; kernel_init points
// these at its own.
ee_vblank_start, ee_vblank_end: ^u64

// Function fno of vblank, as stdio_fn.
vblank_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	if fno < 4 || fno > 7 {return 0, false}
	assert(ee_vblank_start != nil && ee_vblank_end != nil, "iop: vblank without the EE's schedule")
	now := r3000.state.cycles * IOP_EE_RATIO
	start, end := vblank_next(ee_vblank_start^, now), vblank_next(ee_vblank_end^, now)
	inside := end < start // the last edge a start
	edge, set := end, !inside && start >= cpu.CYCLES_PER_FRAME
	if fno == 4 || fno == 6 {edge, set = start, inside}
	if set {return th_wait_until(0), true}
	return th_wait_until((edge + IOP_EE_RATIO - 1) / IOP_EE_RATIO), true
}

// The first edge after EE cycle `now` of those every frame from `next`, an
// edge the kernel has not reached: the IOP's clock runs ahead of the EE's.
@(private = "file")
vblank_next :: proc(next, now: u64) -> u64 {
	if next > now {return next}
	return next + ((now - next) / cpu.CYCLES_PER_FRAME + 1) * cpu.CYCLES_PER_FRAME
}
