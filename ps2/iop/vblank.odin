// The vblank library's waits and user handlers (PS_IRX=1), as read from the
// disc copy of VBLANK 1.1. Its start makes an event flag, empty, and hooks the vblank
// start and end interrupts: at a start its handler sets bits 1 and 2, then
// clears 1 and 8 (mask ~9); at an end sets 4 and 8, then clears 2 and 4 (mask
// ~6). So bits 1 and 4 are pulses, which wake whoever waits and are gone when
// the handler returns, and 2 and 8 are levels. Functions 4 to 7 each wait on
// that flag for one bit, OR mode, no clear, and return what the wait returns:
//
//	4 WaitVblankStart, bit 1: always the next start;
//	5 WaitVblankEnd, bit 4: always the next end;
//	6 WaitVblank, bit 2: the next start, at once while in vblank (the last
//	  edge a start);
//	7 WaitNonVblank, bit 8: the next end, at once while out of it (the last
//	  edge an end).
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
// 8 AddVblankHandler(edge, priority, handler, arg) and 9
// DelVblankHandler(edge, handler) keep a list per edge, the start for edge 0
// and the end for any other, in one table of VBL_HANDLERS entries. Retail's
// table has 16, and its start takes two for the handlers that drive the
// flag, which are not kept here. Each list runs lowest priority first, equal
// ones in the order added. Add refuses a handler already on the edge's list
// (KE_FOUND_HANDLER) and, with no entry free, KE_NO_MEMORY, a compat row
// here; Del one not on it, KE_NOTFOUND_HANDLER. Both refuse a handler's call
// (KE_ILLEGAL_CONTEXT), so a list changes during its run only by a
// handler's own return: retail calls each with its arg and drops it on 0.
//
// A list runs at its edge by the IOP's clock, at the cycle that edge's
// waiters wake, from iop_tick before the threads, as retail's interrupt
// runs before them: a thread a handler wakes runs in that tick. Each edge
// runs once: its next edge is kept here (`next`), from the kernel's schedule
// when its list gets its first handler, and moved a frame on when it runs.
// After a stall, only the latest edge due of each kind runs, the start and
// end in the order they fell; the edges before it are dropped. A handler
// that waits, spends its budget or calls what the HLE lacks is stopped
// (th_intr) and dropped, as it returned nothing to keep it. Edges are a
// frame apart, cpu.CYCLES_PER_FRAME, NTSC only as for 4 to 7.
//
// iop_tick never runs inside a load: a handler a module's start adds does
// not run during that load, so a start that waits on a thread its handler
// wakes does not finish there as on retail. The edges due during the load
// collapse to the latest, which runs at the first tick after it.
package ps2_iop

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import r3000 "ps:psx/cpu"

KE_FOUND_HANDLER :: -104
KE_NOTFOUND_HANDLER :: -105

// The user handlers one table holds: retail's 16 less its start's two.
VBL_HANDLERS :: 14

Vbl_Handler :: struct {
	end:      u32, // 0 the start's list, 1 the end's
	priority: i32,
	handler:  u32, // IOP address
	arg:      u32,
}

Iop_Vblank :: struct {
	n:    u32,
	h:    [VBL_HANDLERS]Vbl_Handler, // each list in its run order
	next: [2]u64, // the next start and end to run, EE cycles, while the list has a handler
}

// Emulated state, snapshotted (sif_snap) and reset with the loader.
iop_vbl: Iop_Vblank

// The EE kernel's next vblank start and end, EE cycles; kernel_init points
// these at its own.
ee_vblank_start, ee_vblank_end: ^u64

// Function fno of vblank, as stdio_fn.
vblank_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	if fno < 4 || fno > 9 {return 0, false}
	assert(ee_vblank_start != nil && ee_vblank_end != nil, "iop: vblank without the EE's schedule")
	r := &r3000.state.r
	switch fno {
	case 8: // AddVblankHandler(edge, priority, handler, arg)
		if iop_sched.intr {return ke(KE_ILLEGAL_CONTEXT), true}
		h := Vbl_Handler{u32(r[4] != 0), i32(r[5]), r[6], r[7]}
		if vbl_find(h.end, h.handler) >= 0 {return ke(KE_FOUND_HANDLER), true}
		if !vbl_insert(h) {
			core.compat_unknown(.Iop_Vblank_Intr, h.handler, sub = 1, pc = r[31])
			fmt.eprintfln("iop: vblank handler at %x: no room", h.handler)
			return ke(KE_NO_MEMORY), true
		}
		return KE_OK, true
	case 9: // DelVblankHandler(edge, handler)
		if iop_sched.intr {return ke(KE_ILLEGAL_CONTEXT), true}
		i := vbl_find(u32(r[4] != 0), r[5])
		if i < 0 {return ke(KE_NOTFOUND_HANDLER), true}
		vbl_remove(i)
		return KE_OK, true
	case 4, 5, 6, 7: // WaitVblankStart, WaitVblankEnd, WaitVblank, WaitNonVblank
		edge, set := vblank_wait_for(fno, r3000.state.cycles * IOP_EE_RATIO)
		if set {return th_wait_until(0), true}
		return th_wait_until((edge + IOP_EE_RATIO - 1) / IOP_EE_RATIO), true
	}
	return 0, false
}

// What function fno (4 to 7) called at EE cycle `now` waits for: the edge, or
// `set` when its bit is up and it returns at once. A call on an edge's very
// cycle has missed that edge's pulse, and waits for the following one.
vblank_wait_for :: proc(fno: u32, now: u64) -> (edge: u64, set: bool) {
	start, end := vblank_next(ee_vblank_start^, now), vblank_next(ee_vblank_end^, now)
	inside := end < start // the last edge a start
	switch fno {
	case 4:
		return start, false
	case 6:
		return start, inside
	case 7:
		return end, !inside && start >= cpu.CYCLES_PER_FRAME
	}
	return end, false
}

// The first edge after EE cycle `now` of those every frame from `next`, an
// edge the kernel has not reached: the IOP's clock runs ahead of the EE's.
@(private = "file")
vblank_next :: proc(next, now: u64) -> u64 {
	if next > now {return next}
	return next + ((now - next) / cpu.CYCLES_PER_FRAME + 1) * cpu.CYCLES_PER_FRAME
}

// The index of `handler` on edge `end`'s list, -1 when not on it.
@(private = "file")
vbl_find :: proc(end, handler: u32) -> int {
	for x, i in iop_vbl.h[:iop_vbl.n] {
		if x.end == end && x.handler == handler {return i}
	}
	return -1
}

// Puts h on its list after every handler there of its priority or lower;
// false with no entry free. A list's first handler sets when its edge runs
// next: the kernel's next edge of that kind after the IOP's clock.
@(private = "file")
vbl_insert :: proc(h: Vbl_Handler) -> bool {
	v := &iop_vbl
	if v.n == VBL_HANDLERS {return false}
	at, first := v.n, true
	for x, i in v.h[:v.n] {
		if x.end != h.end {continue}
		first = false
		if x.priority > h.priority {
			at = u32(i)
			break
		}
	}
	if first {
		edge := ee_vblank_end^ if h.end != 0 else ee_vblank_start^
		v.next[h.end] = vblank_next(edge, r3000.state.cycles * IOP_EE_RATIO)
	}
	copy(v.h[at + 1:v.n + 1], v.h[at:v.n])
	v.h[at] = h
	v.n += 1
	iop_wake_set()
	return true
}

@(private = "file")
vbl_remove :: proc(i: int) {
	v := &iop_vbl
	copy(v.h[i:v.n - 1], v.h[i + 1:v.n])
	v.n -= 1
	v.h[v.n] = {}
}

// When, in EE cycles, the next edge with a handler is due by the IOP's
// clock; max(u64) when no list has one.
vbl_next_ee :: proc() -> u64 {
	if iop_vbl.n == 0 {return max(u64)}
	t := max(u64)
	for x in iop_vbl.h[:iop_vbl.n] {
		t = min(t, (iop_vbl.next[x.end] + IOP_EE_RATIO - 1) / IOP_EE_RATIO * IOP_EE_RATIO)
	}
	return t
}

// Runs each list whose edge is due by the IOP's clock: the latest edge due
// of each kind, the earlier first, the edges before it dropped.
vbl_intr_run :: proc() {
	v := &iop_vbl
	if v.n == 0 {return}
	now := r3000.state.cycles * IOP_EE_RATIO
	due: [2]u64 = max(u64)
	for x in v.h[:v.n] {
		e := v.next[x.end]
		if e <= now {due[x.end] = e + (now - e) / cpu.CYCLES_PER_FRAME * cpu.CYCLES_PER_FRAME}
	}
	order := [2]u32{0, 1} if due[0] <= due[1] else [2]u32{1, 0}
	for end in order {
		if due[end] == max(u64) {continue}
		v.next[end] = due[end] + cpu.CYCLES_PER_FRAME
		vbl_run(end)
	}
}

// Runs edge `end`'s list in order, each handler with its arg, dropping one
// that returns 0 or is stopped.
@(private = "file")
vbl_run :: proc(end: u32) {
	v := &iop_vbl
	for i := 0; i < int(v.n); {
		h := v.h[i]
		if h.end != end {
			i += 1
			continue
		}
		keep := false
		switch th_intr(h.handler, h.arg, 0) {
		case .None:
			keep = iop_sched.intr_v0 != 0
		case .Blocked:
			core.compat_unknown(.Iop_Vblank_Intr, h.handler, pc = h.handler)
			fmt.eprintfln("iop: vblank handler at %x blocked", h.handler)
		case .Call:
			fmt.eprintfln("iop: vblank handler at %x stopped", h.handler)
		}
		if keep {i += 1} else {vbl_remove(i)}
	}
}

// After a failed load: the handlers there when the load began (`saved`)
// are back where they were, those it removed included, with the edges they
// were to run next (no tick runs inside a load, so `saved` is exact). Those
// it added stay after them unless their handler or arg lies in `freed`, the
// memory its undo frees; one with no entry left is dropped with Add's row.
vbl_undo :: proc(saved: Iop_Vblank, freed: []Sys_Block) {
	cur := iop_vbl
	iop_vbl = saved
	for x in cur.h[:cur.n] {
		if sys_in(freed, x.handler) || sys_in(freed, x.arg) || vbl_find(x.end, x.handler) >= 0 {continue}
		if !vbl_insert(x) {
			core.compat_unknown(.Iop_Vblank_Intr, x.handler, sub = 1)
			fmt.eprintfln("iop: vblank handler at %x: no room after a failed load", x.handler)
		}
	}
}
