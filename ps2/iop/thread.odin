// IOP threads (thbase) and semaphores (thsemap). Each thread runs on a
// coroutine of its own, as the EE kernel's do: the interpreter keeps a MIPS
// call frame on the host stack, so a thread that waits leaves its host
// frames suspended there.
//
// Three things run the IOP, each from the EE's side and none inside
// another: a load (loadcore.odin), a command packet the EE sends to a
// module's handler (iop_cmd_deliver), and the EE's events once the IOP's
// clock is due (iop_tick). Each schedules from the caller's coroutine: it
// picks the ready thread of best priority, switches to it, and is switched
// back to when that thread waits, yields, ends, is preempted by a thread of
// better priority it readied, or spends the slice. It stops when no thread
// is ready. Threads still waiting then stay suspended, their coroutines and
// context kept, until a later run finds them ready.
//
// The IOP's clock is r3000's cycle count, which runs ahead of the EE's while
// IOP code runs and is brought up to it (at the EE's 8 cycles per IOP cycle)
// before each run. A DelayThread waits until a cycle count; a tick or a
// delivery that finds no thread ready moves the clock to the first such
// wake within its slice. iop_wake_ee is when, in EE cycles, the EE's events
// tick the IOP next: at a thread's wake, at once while one is ready, at a
// libsd interrupt (libsd.odin), or at a timer's compare (timrman.odin).
//
// A command handler, and a libsd, timer or cdvdman interrupt handler, runs
// on a coroutine of its own, not a thread's: retail runs it in an interrupt
// handler, where it may not wait. One that waits, or spins past its
// budget, is stopped there (th_intr_stop).
//
// Under FLAT (core/flat.odin) there are no coroutines: each thread, and the
// handlers, runs on a flat run of its own (r3000.Flat_Ctx, Iop_Flat), which
// keeps its call chain as data. The scheduler runs a thread's run until it
// ends or stops; a wait, a yield or an end stops it (r3000.flat_block) and
// returns to the HLE call that made it, which returns at once. What that
// call owed its caller after the wait, its v0 and the yield to a better
// thread, is then owed to the thread's resume (th_flat_stopped,
// th_flat_run). A host function that calls guest code and may wait
// inside it (sceSifRpcLoop, sdrdrv's server) runs as a continuation
// (iop_flat_step), not a nested call.
//
// A thread's context: the R3000's r[0..31], hi and lo, cop0's sr, cause and
// epc, frame_ret and tail_depth, saved when it leaves the CPU and restored
// when it gets it back. Its pc and branch state are the interpreter's
// locals, on its coroutine's stack. The cycle count is global time: never saved.
//
// The ready and wait queues are the thread table itself: a thread's status
// says which it is in, and its seq orders it in there. Removing a thread from
// the table removes it from every queue.
package ps2_iop

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import r3000 "ps:psx/cpu"

// A start's priority: the loader thread's, better than every user thread's
// (USER_HIGHEST 9), so a start that starts threads runs to its return
// before them unless it waits.
IOP_START_PRIO :: 8
// The system clock GetSystemTime reads counts the interpreter's cycles at
// the IOP's clock rate.
IOP_CLOCK :: 36_864_000
// EE cycles per IOP cycle: 294.912 MHz to 36.864 MHz.
IOP_EE_RATIO :: 8
// What a tick or a delivery runs threads for: a millisecond of IOP time.
IOP_SLICE :: 36_864
// What a command handler may spend before it is stopped as stuck.
IOP_INTR_BUDGET :: 1 << 20
// The stack command handlers run on, below the packet buffer they read.
IOP_INTR_STACK :: IOP_CMDBUF

KE_ILLEGAL_CONTEXT :: -100
KE_NO_MEMORY :: -400
KE_ILLEGAL_ATTR :: -401
KE_ILLEGAL_ENTRY :: -402
KE_ILLEGAL_PRIORITY :: -403
KE_ILLEGAL_THID :: -406
KE_UNKNOWN_THID :: -407
KE_UNKNOWN_SEMID :: -408
KE_UNKNOWN_EVFID :: -409
KE_UNKNOWN_MBXID :: -410
KE_DORMANT :: -413
KE_NOT_DORMANT :: -414
KE_CAN_NOT_WAIT :: -417
KE_SEMA_ZERO :: -419
KE_SEMA_OVF :: -420
KE_EVF_COND :: -421
KE_EVF_MULTI :: -422
KE_EVF_ILPAT :: -423
KE_MBOX_NOMSG :: -424
KE_WAIT_DELETE :: -425

@(private = "file")
PRIO_HIGHEST :: 1
@(private = "file")
PRIO_LOWEST :: 126
@(private = "file")
SA_THPRI :: 1 // a semaphore's waiters by priority, else first come
@(private = "file")
EA_MULTI :: 2 // an event flag more than one thread may wait on
@(private = "file")
WEF_OR :: 1 // a wait any of whose bits will do, else all of them
@(private = "file")
WEF_CLEAR :: 0x10 // a wait that clears the flag's bits once met

Th_Status :: enum u8 {
	Dormant,
	Ready,
	Run,
	Wait, // on a semaphore
	Evf, // on an event flag
	Lock, // on sio2man's transfer lock (th_lock)
	Sleep,
	Delay, // on DelayThread, until wake_at
	Start, // in StartModule, until the start it runs returns
}

Th_Context :: struct {
	r:          [32]u32,
	hi, lo:     u32,
	cop0:       type_of(r3000.cop0),
	frame_ret:  u32,
	tail_depth: int, // its own tail calls (r3000.jump), from 0 when it starts
}

Iop_Thread :: struct {
	id:                     u32,
	attr, option:           u32,
	entry, stack, stacksize: u32,
	gp, prio:               u32,
	init_prio:              u32, // what it was made with, StartThread's again
	status:                 Th_Status,
	start:                  bool, // a module's start
	exit_delete:            bool, // removed once it is dormant
	seq:                    i64, // its place in its ready or wait queue
	sema:                   u32, // what it waits on: a semaphore's or event flag's id
	evf_bits, evf_mode:     u32, // an event flag wait's pattern and mode
	evf_res:                u32, // and where its met bits go, 0 for nowhere
	wakeups:                u32, // WakeupThread calls while it was awake
	wake:                   u32, // what its wait returns
	wake_at:                u64, // when its Delay ends, IOP cycles
	ctx:                    Th_Context,
	co:                     ^core.Coroutine,
	flat:                   Iop_Flat,
}

// A thread's flat run under FLAT, and what its resume owes; empty otherwise.
when core.FLAT {
	Iop_Flat :: struct {
		run:  ^r3000.Flat_Ctx, // emu heap; nil until it first runs
		wait: bool, // it stopped in th_wait
		v0:   bool, // its resume puts the wait's wake in v0 (th_flat_stopped)
		post: bool, // its resume owes an HLE call's yield to a better thread
	}
} else {
	Iop_Flat :: struct {}
}

Iop_Sema :: struct {
	id, attr, option: u32,
	count, max:       i32,
	initial:          i32,
}

Iop_Evf :: struct {
	id, attr, option: u32,
	initial, bits:    u32,
}

// A message box, by retail's layout: a ring through the messages' own next
// words in IOP memory, `last` the newest, its next word the oldest; 0 when
// none was ever left. Only `count` says how many are queued: a message's
// next word the guest wrote over after the send changes what a poll takes,
// never whether one is there.
Iop_Mbx :: struct {
	id, attr, option: u32,
	count:            i32,
	last:             u32,
}

// Emulated state, in the emu heap: snapshotted (sif_snap).
iop_sched: struct {
	threads:              [dynamic]Iop_Thread,
	semas:                [dynamic]Iop_Sema,
	evfs:                 [dynamic]Iop_Evf,
	mbxs:                 [dynamic]Iop_Mbx,
	next_thid, next_semid: u32,
	next_evfid:           u32,
	next_mbxid:           u32,
	lock:                 i32, // sio2man's transfer lock, a semaphore's count
	lock_holder:          u32, // the thread that last took it, 0 when given back
	head, tail:           i64, // the next seq at a queue's head, at its tail
	cur:                  u32, // the running thread, 0 on the loader
	resched:              bool, // a thread of better priority than cur became ready
	budget:               bool, // the load's budget is spent
	start_done:           bool, // the EE load's start returned, its v0 in start_result
	start_result:         u32,
	intr:                 bool, // a handler runs, on intr_co
	intr_stop:            Intr_Stop, // why it was stopped
	intr_handler:         u32, // what it runs and its arguments
	intr_a0, intr_a1:     u32,
	intr_v0:              u32, // what it returned, when it returned
	intr_co:              ^core.Coroutine, // made at the first handler
}

Intr_Stop :: enum u8 {
	None,
	Blocked, // it waited or spent its budget
	Call, // it called what the HLE lacks
}

// When the EE's events tick the IOP next, in EE cycles (iop_wake_set). Off
// unless PS_IRX=1. Emulated state: snapshotted (sif_snap).
iop_wake_ee: u64 = max(u64)

// The coroutine a load schedules from. Only set while a load runs. Under
// FLAT there is none; th_entered marks the same span.
when core.FLAT {
	@(private = "file")
	th_entered: bool
} else {
	@(private = "file")
	th_loader: ^core.Coroutine
}

// FLAT: the handlers' flat run (th_intr), emu heap.
when core.FLAT {
	@(private = "file")
	th_intr_run: ^r3000.Flat_Ctx
}

// Emulated state (sif_snap): the handlers' run under FLAT. Each thread's
// run is its Iop_Flat, in iop_sched; the runs themselves are on the emu
// heap.
th_snap :: proc() {
	when core.FLAT {core.snap_add(&th_intr_run)}
}

// FLAT: an IOP run is live. Never at an EE frame boundary, where the IOP
// has returned to the EE: a snapshot there would miss the run's host frames.
th_flat_busy :: proc() -> bool {
	when core.FLAT {return r3000.flat_cur != nil} else {return false}
}

th_init :: proc() {
	s := &iop_sched
	for &t in s.threads {th_drop(&t)}
	when !core.FLAT {if s.intr_co != nil {core.co_kill(s.intr_co)}}
	clear(&s.threads)
	clear(&s.semas)
	clear(&s.evfs)
	clear(&s.mbxs)
	s^ = {
		threads    = s.threads,
		semas      = s.semas,
		evfs       = s.evfs,
		mbxs       = s.mbxs,
		next_thid  = 1,
		next_semid = 1,
		next_evfid = 1,
		next_mbxid = 1,
		lock       = 1,
		head       = -1,
	}
	iop_wake_ee = max(u64)
}

th_find :: proc(id: u32) -> ^Iop_Thread {
	for &t in iop_sched.threads {
		if t.id == id {return &t}
	}
	return nil
}

@(private = "file")
sema_find :: proc(id: u32) -> ^Iop_Sema {
	for &m in iop_sched.semas {
		if m.id == id {return &m}
	}
	return nil
}

// A dormant thread; its context starts with `gp` and the stack's top.
th_new :: proc(entry, stack, stacksize, gp, prio: u32) -> ^Iop_Thread {
	s := &iop_sched
	append(&s.threads, Iop_Thread{id = s.next_thid, entry = entry, stack = stack, stacksize = stacksize, gp = gp, prio = prio, init_prio = prio})
	s.next_thid += 1
	t := &s.threads[len(s.threads) - 1]
	th_reset(t)
	return t
}

@(private = "file")
th_reset :: proc(t: ^Iop_Thread) {
	t.ctx = {cop0 = r3000.cop0}
	t.ctx.r[28] = t.gp
	t.ctx.r[29] = t.stack + t.stacksize - 16
	t.wakeups = 0
}

th_ready :: proc(t: ^Iop_Thread, head := false) {
	s := &iop_sched
	t.status = .Ready
	if head {
		t.seq = s.head
		s.head -= 1
	} else {
		t.seq = s.tail
		s.tail += 1
	}
}

// Readies t from the running thread, which yields once its call returns
// when t's priority is better.
@(private = "file")
th_wake :: proc(t: ^Iop_Thread, v: u32) {
	t.wake = v
	th_ready(t)
	if c := th_find(iop_sched.cur); c != nil && t.prio < c.prio {iop_sched.resched = true}
}

// ------------------------------------------------------------- the scheduler

// Runs ready threads from the calling coroutine until none is ready, the
// clock reaches `until` (the budget), or the start returned from a failed
// load. With `idle`, no thread ready moves the clock to the first wake
// before `until`, and they run on from there.
th_schedule :: proc(until: u64, idle := false) {
	s := &iop_sched
	when core.FLAT {
		assert(!th_entered && s.cur == 0, "iop: the scheduler entered while the IOP runs")
		th_entered = true
	} else {
		assert(th_loader == nil && s.cur == 0, "iop: the scheduler entered while the IOP runs")
		th_loader = core.co_current
	}
	frame, depth := r3000.frame_ret, r3000.tail_depth
	s.budget = false
	s.resched = false
	r3000.next_event = until
	r3000.run_events = th_budget
	for !s.budget && !(s.start_done && load_ee_failed()) {
		th_due()
		t := th_pick()
		if t == nil {
			w := th_next_wake()
			if !idle || w > until {break}
			r3000.state.cycles = w
			continue
		}
		id := t.id
		t.status = .Run
		s.cur = id
		when core.FLAT {
			th_flat_run(t)
		} else {
			if t.co == nil {t.co = core.co_create(th_main, rawptr(uintptr(id)))}
			core.co_switch(t.co)
		}
		s.cur = 0
		if t = th_find(id); t != nil && t.status == .Dormant {
			// A StartModule's start ended: its caller wakes, and a failed
			// one's undo may have deleted it.
			if t.start {load_start_finish(id)}
			if t = th_find(id); t != nil {th_stop(t)}
		}
	}
	th_due()
	r3000.next_event = IOP_EVENT_OFF
	r3000.run_events = proc() {}
	// A suspended thread's call has not restored them; a deleted one never will.
	r3000.frame_ret, r3000.tail_depth = frame, depth
	when core.FLAT {th_entered = false} else {th_loader = nil}
}

// Readies the delayed threads whose wake the clock reached, in the order
// they began to wait.
@(private = "file")
th_due :: proc() {
	now := r3000.state.cycles
	for {
		first: ^Iop_Thread
		for &t in iop_sched.threads {
			if t.status == .Delay && t.wake_at <= now && (first == nil || t.seq < first.seq) {first = &t}
		}
		if first == nil {return}
		th_ready(first)
	}
}

// The first delayed thread's wake, max(u64) when none is delayed.
@(private = "file")
th_next_wake :: proc() -> u64 {
	w := max(u64)
	for t in iop_sched.threads {
		if t.status == .Delay {w = min(w, t.wake_at)}
	}
	return w
}

// Brings the IOP's clock up to EE cycle `now`.
iop_sync :: proc(now: u64) {
	r3000.state.cycles = max(r3000.state.cycles, now / IOP_EE_RATIO)
}

// Sets iop_wake_ee from the threads, at once while one is ready, else at the
// first wake, from libsd's interrupts (sd_next_ee), the timers' compares
// (tim_next_ee), cdvdman's read callback (cd_next_ee), sifman's DMA
// completion callbacks (sif_dma_next_ee) and the vblank handlers' next
// edge (vbl_next_ee). The EE's next event moves up to it, unless the EE is
// handling events, which ends with update_next_event.
iop_wake_set :: proc() {
	w := th_next_wake()
	if th_pick() != nil {w = r3000.state.cycles}
	iop_wake_ee = min(w if w == max(u64) else w * IOP_EE_RATIO, sd_next_ee(), tim_next_ee(), cd_next_ee(), sif_dma_next_ee(), vbl_next_ee())
	if !cpu.in_interrupt {cpu.next_event = min(cpu.next_event, iop_wake_ee)}
}

// The EE's events at EE cycle `now`, the IOP's wake due: runs libsd's due
// interrupt handlers, then the timers' due compare handlers, then cdvdman's
// pending read callback, then sifman's DMA completion callbacks due, then the
// vblank handlers due, then its threads for a slice.
iop_tick :: proc(now: u64) {
	t := cpu.prof_start()
	defer cpu.prof_end(.IOP, t)
	iop_sync(now)
	sd_intr_run(now)
	tim_intr_run()
	cd_intr_run()
	sif_dma_intr_run(now)
	vbl_intr_run()
	iop_sched.start_done = false
	th_schedule(r3000.state.cycles + IOP_SLICE, idle = true)
	iop_wake_set()
}

// The ready thread of best priority, first in its queue.
@(private = "file")
th_pick :: proc() -> ^Iop_Thread {
	best: ^Iop_Thread
	for &t in iop_sched.threads {
		if t.status != .Ready {continue}
		if best == nil || t.prio < best.prio || t.prio == best.prio && t.seq < best.seq {best = &t}
	}
	return best
}

// A thread's coroutine: its entry, then ExitThread.
@(private = "file")
th_main :: proc(arg: rawptr) {
	t := th_find(u32(uintptr(arg)))
	entry := t.entry
	th_restore(t)
	r3000.call(entry)
	th_exit()
}

// FLAT: th_main and th_yield's resume for the running thread t (a pointer
// into iop_sched.threads, good only until the run). Its run
// starts at its entry when it has none; else it goes on, after what its
// stop owed (th_flat_stopped): v0, and the yield to a better thread its HLE
// call would make once the wait returned. A run that ends is the thread's
// ExitThread.
@(private = "file")
th_flat_run :: proc(t: ^Iop_Thread) {
	when core.FLAT {
		f := &t.flat
		th_restore(t)
		if f.run == nil {
			f.run = new(r3000.Flat_Ctx, core.emu_allocator())
			r3000.flat_start(f.run, t.entry)
		} else {
			if f.v0 {r3000.state.r[2] = t.wake}
			post := f.post
			f.wait, f.v0, f.post = false, false, false
			if post && iop_sched.resched {
				// th_preempt, before the run goes on: v0 is the call's.
				iop_sched.resched = false
				th_ready(t, head = true)
				th_save(t)
				return
			}
		}
		// The run may create threads, growing iop_sched.threads: t is found
		// again by id, not trusted past it.
		id := t.id
		if r3000.flat_run(f.run) {
			now := th_find(id)
			assert(now != nil, "iop: the running thread gone during its run")
			th_end(now)
		}
	}
}

// FLAT: the HLE call of the running thread stopped it (a wait, a yield or
// an end) before returning v. What it would do once the thread runs again
// is owed to th_flat_run: v0, v or a wait's wake, and its resched check.
// Nothing on a handler's run, which is dropped.
th_flat_stopped :: proc(v: u32) {
	when core.FLAT {
		t := th_find(iop_sched.cur)
		if t == nil {return}
		if t.flat.wait {
			t.flat.v0 = true
		} else {
			t.ctx.r[2] = v
		}
		t.flat.post = true
	}
}

// Drops a thread's coroutine or flat run.
@(private = "file")
th_drop :: proc(t: ^Iop_Thread) {
	when !core.FLAT {
		if t.co != nil {
			core.co_kill(t.co)
			t.co = nil
		}
	}
	when core.FLAT {
		if t.flat.run != nil {
			r3000.flat_free(t.flat.run)
			free(t.flat.run, core.emu_allocator())
		}
		t.flat = {}
	}
}

// Drops a dormant thread's coroutine, and the thread itself when it asked
// to be deleted; the RPC queues it served go (rpc_thread_gone).
@(private = "file")
th_stop :: proc(t: ^Iop_Thread) {
	if t.start {load_start_gone(t.id)}
	rpc_thread_gone(t.id)
	th_drop(t)
	if t.exit_delete {th_remove(t.id)}
}

@(private = "file")
th_remove :: proc(id: u32) {
	s := &iop_sched
	for t, i in s.threads {
		if t.id != id {continue}
		assert(t.co == nil, "iop: thread removed with its coroutine")
		sys_free(t.stack)
		ordered_remove(&s.threads, i)
		return
	}
}

@(private = "file")
th_save :: proc(t: ^Iop_Thread) {
	t.ctx = {
		r          = r3000.state.r,
		hi         = r3000.state.hi,
		lo         = r3000.state.lo,
		cop0       = r3000.cop0,
		frame_ret  = r3000.frame_ret,
		tail_depth = r3000.tail_depth,
	}
}

@(private = "file")
th_restore :: proc(t: ^Iop_Thread) {
	r3000.state.r = t.ctx.r
	r3000.state.hi = t.ctx.hi
	r3000.state.lo = t.ctx.lo
	r3000.cop0 = t.ctx.cop0
	r3000.frame_ret = t.ctx.frame_ret
	r3000.tail_depth = t.ctx.tail_depth
}

// Takes the running thread, its status already set, off the CPU, and puts
// its context back once the loader runs it again. Under FLAT it stops the
// thread's run and returns at once; th_flat_run puts the context back.
@(private = "file")
th_yield :: proc() {
	id := iop_sched.cur
	th_save(th_find(id))
	when core.FLAT {
		r3000.flat_block("an IOP thread switch")
	} else {
		core.co_switch(th_loader)
		th_restore(th_find(id))
	}
}

// The running thread back to the head of its ready queue.
th_preempt :: proc() {
	iop_sched.resched = false
	t := th_find(iop_sched.cur)
	if t == nil {return}
	th_ready(t, head = true)
	th_yield()
}

// run_events while the IOP runs: the budget is spent. The running thread
// stays ready, first in its queue, its context saved; a command handler is
// stopped. Under FLAT, native code cannot be stopped: the clock stays past
// the budget, so the next events check once it returned stops the run.
@(private = "file")
th_budget :: proc() {
	when core.FLAT {
		if !r3000.flat_can_stop() {
			r3000.flat_put_off()
			return
		}
	}
	if iop_sched.intr {
		th_intr_stop(.Blocked)
		return
	}
	if iop_sched.cur == 0 {return}
	iop_sched.budget = true
	th_preempt()
}

// The running thread waits; what its waker gave, or KE_CAN_NOT_WAIT on the
// loader. A command handler that waits is stopped. Under FLAT the wait only
// begins: what it returns is KE_OK, and the wake is the resume's (Iop_Flat).
@(private = "file")
th_wait :: proc(status: Th_Status, sema: u32 = 0) -> u32 {
	s := &iop_sched
	if s.intr {
		th_intr_stop(.Blocked)
		return ke(KE_CAN_NOT_WAIT)
	}
	t := th_find(s.cur)
	if t == nil {return ke(KE_CAN_NOT_WAIT)}
	t.status = status
	t.sema = sema
	t.seq = s.tail
	s.tail += 1
	t.wake = KE_OK
	when core.FLAT {t.flat.wait = true}
	th_yield()
	return th_find(s.cur).wake
}

// StartModule's caller waits for the start it runs (load_start_finish).
th_start_wait :: proc() -> u32 {
	return th_wait(.Start)
}

// Thread id, waiting in StartModule, wakes with v.
th_start_wake :: proc(id, v: u32) {
	if th_start_waits(id) {th_wake(th_find(id), v)}
}

// Whether thread id is there and waits in StartModule.
th_start_waits :: proc(id: u32) -> bool {
	t := th_find(id)
	return t != nil && t.status == .Start
}

// Deletes each thread but `keep` and the running one whose stack lies in
// `blocks`, which a failed StartModule frees: their RPC queues go, and the
// transfer lock one holds is given back.
th_kill_in :: proc(blocks: []Sys_Block, keep: u32) {
	s := &iop_sched
	kill := make([dynamic]u32, 0, 8, context.temp_allocator)
	for t in s.threads {
		if t.id != keep && t.id != s.cur && sys_in(blocks, t.stack) {append(&kill, t.id)}
	}
	for id in kill {
		t := th_find(id)
		if t == nil {continue} // a start's failure deleted it already
		if s.lock_holder == id {th_unlock()}
		t.status, t.exit_delete = .Dormant, true
		th_stop(t)
	}
}

// SleepThread: the running thread sleeps, unless a wakeup came while it was
// awake, which it uses up. What its sleep returns.
th_sleep :: proc() -> u32 {
	t := th_find(iop_sched.cur)
	if t != nil && t.wakeups > 0 {
		t.wakeups -= 1
		return KE_OK
	}
	return th_wait(.Sleep)
}

// The running thread waits until IOP cycle `at` as a delayed one, so the
// scheduler wakes it with DelayThread's; at once when `at` is not ahead
// (vblank.odin). A handler is stopped even then: retail refuses a wait in
// an interrupt handler before it looks at what it would wait for.
th_wait_until :: proc(at: u64) -> u32 {
	if iop_sched.intr {
		th_intr_stop(.Blocked)
		return ke(KE_CAN_NOT_WAIT)
	}
	if at <= r3000.state.cycles {return KE_OK}
	if t := th_find(iop_sched.cur); t != nil {t.wake_at = at}
	return th_wait(.Delay)
}

// The running thread waits for its RPC's RPC_END (sifclient.odin), on what
// retail's sifcmd keeps an event flag for, so no WakeupThread ends it.
th_rpc_wait :: proc() -> u32 {
	v := th_wait(.Wait)
	// Its callers return 0, not the wake: under FLAT the resume keeps it.
	when core.FLAT {
		if t := th_find(iop_sched.cur); t != nil {t.flat.wait = false}
	}
	return v
}

// Readies thread id if it waits so; else nothing, the flag retail would set
// being one nobody waits on.
th_rpc_wake :: proc(id: u32) {
	if t := th_find(id); t != nil && t.status == .Wait && t.sema == 0 {th_wake(t, KE_OK)}
}

// WakeupThread(id): readies thread id if it sleeps, else counts a wakeup.
th_wakeup :: proc(id: u32) -> u32 {
	t := th_find(id)
	if t == nil {return ke(KE_UNKNOWN_THID)}
	if t.id == iop_sched.cur {return ke(KE_ILLEGAL_THID)}
	if t.status == .Dormant {return ke(KE_DORMANT)}
	if t.status == .Sleep {
		th_wake(t, KE_OK)
	} else {
		t.wakeups += 1
	}
	return KE_OK
}

// Ends the running thread; the loader drops its coroutine. A start's end
// is its return, v0 its result. Under FLAT it stops the thread's run and
// returns.
th_exit :: proc(delete := false) {
	t := th_find(iop_sched.cur)
	if t == nil {return}
	th_end(t, delete)
	when core.FLAT {
		r3000.flat_block("an IOP thread's end")
	} else {
		core.co_switch(th_loader)
		unreachable()
	}
}

// Thread t ends: dormant, and a start's v0 is its result.
@(private = "file")
th_end :: proc(t: ^Iop_Thread, delete := false) {
	if t.start {load_start_end(t.id, r3000.state.r[2])}
	t.status = .Dormant
	t.exit_delete ||= delete
}

// An HLE call failed in the running thread. In a start the load fails once
// the start returns, or at once at its IOP_START_GAPS-th; any other thread,
// or a command handler, is stopped there, dormant.
th_call_failed :: proc() {
	if iop_sched.intr {
		th_intr_stop(.Call)
		return
	}
	t := th_find(iop_sched.cur)
	if t == nil || t.start {
		gaps := load_gap(t.id if t != nil else 0)
		if t != nil && gaps >= IOP_START_GAPS {
			fmt.eprintfln("iop: start stopped after %d failed calls", gaps)
			th_exit()
		}
		return
	}
	fmt.eprintfln("iop: thread %d stopped", t.id)
	th_exit()
}

// Runs handler `handler` (a command's or an interrupt's) with arguments a0
// and a1, on the handler coroutine, for at most IOP_INTR_BUDGET cycles; why
// it stopped early, if it did. The context it ran in is put back: no
// thread's is lost.
th_intr :: proc(handler, a0, a1: u32) -> Intr_Stop {
	s := &iop_sched
	when core.FLAT {
		assert(!th_entered && s.cur == 0, "iop: a handler run while the IOP runs")
	} else {
		assert(th_loader == nil && s.cur == 0, "iop: a handler run while the IOP runs")
	}
	saved := Th_Context{r3000.state.r, r3000.state.hi, r3000.state.lo, r3000.cop0, r3000.frame_ret, r3000.tail_depth}
	when !core.FLAT {
		if s.intr_co == nil {s.intr_co = core.co_create(th_intr_main, nil)}
	}
	s.intr, s.intr_stop = true, .None
	s.intr_handler, s.intr_a0, s.intr_a1 = handler, a0, a1
	when core.FLAT {th_entered = true} else {th_loader = core.co_current}
	r3000.next_event = r3000.state.cycles + IOP_INTR_BUDGET
	r3000.run_events = th_budget
	when core.FLAT {
		// th_intr_main's one handler, on the handlers' run: a stopped one
		// is dropped as it is, the next starting it over.
		if th_intr_run == nil {th_intr_run = new(r3000.Flat_Ctx, core.emu_allocator())}
		r := &r3000.state.r
		r[4], r[5] = a0, a1
		r[29] = IOP_INTR_STACK - 16
		r3000.flat_start(th_intr_run, handler)
		if r3000.flat_run(th_intr_run) {s.intr_v0 = r[2]}
	} else {
		core.co_switch(s.intr_co)
	}
	when core.FLAT {th_entered = false} else {th_loader = nil}
	r3000.next_event = IOP_EVENT_OFF
	r3000.run_events = proc() {}
	s.intr = false
	when !core.FLAT {
		if s.intr_stop != .None && s.intr_co != nil {
			core.co_kill(s.intr_co)
			s.intr_co = nil
		}
	}
	r3000.state.r, r3000.state.hi, r3000.state.lo = saved.r, saved.hi, saved.lo
	r3000.cop0, r3000.frame_ret, r3000.tail_depth = saved.cop0, saved.frame_ret, saved.tail_depth
	return s.intr_stop
}

when !core.FLAT {
	// The handler coroutine: each handler, then back to th_intr. It never
	// returns, so one coroutine serves every handler until one is stopped on
	// it.
	@(private = "file")
	th_intr_main :: proc(_: rawptr) {
		s := &iop_sched
		for {
			r := &r3000.state.r
			r[4], r[5] = s.intr_a0, s.intr_a1
			r[29] = IOP_INTR_STACK - 16
			r3000.call(s.intr_handler)
			s.intr_v0 = r[2]
			core.co_switch(th_loader)
		}
	}
}

// Stops the running command handler where it is; th_intr kills its
// coroutine. Under FLAT it stops the handler's run and returns.
@(private = "file")
th_intr_stop :: proc(why: Intr_Stop) {
	iop_sched.intr_stop = why
	when core.FLAT {
		r3000.flat_block("an IOP handler's stop")
	} else {
		core.co_switch(th_loader)
		unreachable()
	}
}

// The ids a load's threads, semaphores and event flags start from.
Th_Mark :: struct {
	thid, semid, evfid, mbxid: u32,
}

th_mark :: proc() -> Th_Mark {
	s := &iop_sched
	return {s.next_thid, s.next_semid, s.next_evfid, s.next_mbxid}
}

// Undoes a failed load: deletes the semaphores, event flags and threads
// made since mark `m`, killing the threads' coroutines. Their stacks are
// freed by the caller's sys_blocks restore.
th_undo :: proc(m: Th_Mark) {
	s := &iop_sched
	thid := m.thid
	for i := len(s.semas) - 1; i >= 0; i -= 1 {
		if s.semas[i].id >= m.semid {sema_delete(i)}
	}
	for i := len(s.evfs) - 1; i >= 0; i -= 1 {
		if s.evfs[i].id >= m.evfid {evf_delete(i)}
	}
	for i := len(s.mbxs) - 1; i >= 0; i -= 1 {
		if s.mbxs[i].id >= m.mbxid {ordered_remove(&s.mbxs, i)}
	}
	for i := len(s.threads) - 1; i >= 0; i -= 1 {
		t := &s.threads[i]
		if t.id < thid {continue}
		if t.start {load_start_gone(t.id)}
		th_drop(t)
		ordered_remove(&s.threads, i)
	}
	for t in s.threads {assert(t.id < thid, "iop: a failed load's thread left queued")}
	if s.lock_holder >= thid {th_unlock()}
	s.resched = false
}

// sio2man's transfer lock: the semaphore its start makes {FIFO, initial 1,
// max 0x40}, which pad2_transfer_init and mc2_transfer_init wait on and
// transfer_reset3 signals (sio2.odin). Not a numbered semaphore: no guest
// code names it. A failed load is the HLE's, not retail's, so th_undo gives
// the lock back when that load's thread was the last to take it, and a
// waiter of that load goes with its thread; the lock taken by a thread from
// before the load stays held.
SIO2_LOCK_MAX :: 0x40

// The running thread takes the lock, waiting for it if it is held.
th_lock :: proc() -> u32 {
	s := &iop_sched
	if s.lock > 0 {
		s.lock -= 1
		s.lock_holder = s.cur
		return KE_OK
	}
	return th_wait(.Lock)
}

// Gives the lock to its first waiter, else back.
th_unlock :: proc() -> u32 {
	s := &iop_sched
	w: ^Iop_Thread
	for &t in s.threads {
		if t.status == .Lock && (w == nil || t.seq < w.seq) {w = &t}
	}
	if w != nil {
		th_wake(w, KE_OK)
		s.lock_holder = w.id
	} else if s.lock >= SIO2_LOCK_MAX {
		return ke(KE_SEMA_OVF)
	} else {
		s.lock += 1
		s.lock_holder = 0
	}
	return KE_OK
}

// Removes semaphore i; its waiters wake with KE_WAIT_DELETE.
@(private = "file")
sema_delete :: proc(i: int) {
	s := &iop_sched
	id := s.semas[i].id
	ordered_remove(&s.semas, i)
	for &t in s.threads {
		if t.status == .Wait && t.sema == id {th_wake(&t, ke(KE_WAIT_DELETE))}
	}
}

// ------------------------------------------------------------- call context

Fno_Set :: bit_set[0 ..< 64; u64]
Th_Lib :: enum u8 {Base, Semap, Event, Msgbx}

// ReferThreadStatus's iop_thread_info_t at `info` for thread id: attr,
// option, status, entry, stack, stacksize, gp, initPriority,
// currentPriority, waitType, waitId and wakeupCount, the rest 0 (no
// register context or run clock is kept here). The loader, id 0, shows as
// running at IOP_START_PRIO with nothing else known. A wait shows as
// retail's kind: sleep 1, delay 2 (a vblank wait too, which retail waits
// on an event flag for), semaphore 3 (sio2man's lock too, a semaphore in
// retail's), event flag 4 (an RPC's wait too, with no id here).
@(private = "file")
th_refer :: proc(id, info: u32) -> u32 {
	TS_RUN :: 1
	TS_READY :: 2
	TS_WAIT :: 4
	TS_DORMANT :: 0x10
	TSW_SLEEP :: 1
	TSW_DELAY :: 2
	TSW_SEMA :: 3
	TSW_EVENTFLAG :: 4
	t := th_find(id)
	if t == nil && id != 0 {return ke(KE_UNKNOWN_THID)}
	for &b in iop_ram_at(info, 0x44) {b = 0}
	if t == nil {
		w32(info + 8, TS_RUN)
		w32(info + 0x1c, IOP_START_PRIO)
		w32(info + 0x20, IOP_START_PRIO)
		return KE_OK
	}
	status, wait_type, wait_id: u32
	switch t.status {
	case .Dormant: status = TS_DORMANT
	case .Ready: status = TS_READY
	case .Run: status = TS_RUN
	case .Sleep: status, wait_type = TS_WAIT, TSW_SLEEP
	case .Delay: status, wait_type = TS_WAIT, TSW_DELAY
	case .Start: status, wait_type = TS_WAIT, TSW_EVENTFLAG // modload's own event flag
	case .Wait:
		status, wait_type, wait_id = TS_WAIT, TSW_SEMA, t.sema
		if t.sema == 0 {wait_type = TSW_EVENTFLAG} // th_rpc_wait
	case .Evf: status, wait_type, wait_id = TS_WAIT, TSW_EVENTFLAG, t.sema
	case .Lock: status, wait_type = TS_WAIT, TSW_SEMA
	}
	w32(info, t.attr)
	w32(info + 4, t.option)
	w32(info + 8, status)
	w32(info + 0xc, t.entry)
	w32(info + 0x10, t.stack)
	w32(info + 0x14, t.stacksize)
	w32(info + 0x18, t.gp)
	w32(info + 0x1c, t.init_prio)
	w32(info + 0x20, t.prio)
	w32(info + 0x24, wait_type)
	w32(info + 0x28, wait_id)
	w32(info + 0x2c, t.wakeups)
	return KE_OK
}

// The calls of each library retail's threadman checks the context of, of
// those served here, and which of them are its i-variants.
@(rodata)
TH_CHECKED := [Th_Lib]Fno_Set {
	.Base  = {4, 5, 6, 7, 8, 9, 10, 11, 14, 16, 20, 22, 24, 25, 26, 33},
	.Semap = {4, 5, 6, 7, 8, 9, 11, 12},
	.Event = {4, 5, 6, 7, 8, 9, 10, 11, 13, 14},
	.Msgbx = {4, 6, 9},
}
@(rodata)
TH_IVAR := [Th_Lib]Fno_Set {
	.Base  = {11, 26},
	.Semap = {7, 12},
	.Event = {7, 9, 14},
	.Msgbx = {},
}

// The calls refused so far, each shown once under PS_DEBUG; not state.
@(private = "file")
th_refused: [Th_Lib]Fno_Set

// Whether call fno of lib runs in the wrong context, as retail's threadman
// asks QueryIntrContext first: an i-variant only in a handler, its other
// checked calls only on a thread or the loader. The caller returns
// KE_ILLEGAL_CONTEXT then, before it touches anything.
@(private = "file")
th_wrong_context :: proc(lib: Th_Lib, fno: u32) -> bool {
	if fno >= 64 || int(fno) not_in TH_CHECKED[lib] || (int(fno) in TH_IVAR[lib]) == iop_sched.intr {return false}
	if cpu.debug >= 1 && int(fno) not_in th_refused[lib] {
		th_refused[lib] += {int(fno)}
		fmt.eprintfln("iop: %v fno %d in the wrong context (intr %v) ra %08x", lib, fno, iop_sched.intr, r3000.state.r[31])
	}
	return true
}

// QueryIntrContext: 1 in a handler, else 0.
iop_query_intr_context :: proc() -> u32 {return 1 if iop_sched.intr else 0}

// ------------------------------------------------------------- thbase, thsemap

// Function fno of thbase, reading a0..a2; v0, or false when the HLE lacks
// it. Thread id 0 is the caller where thbase allows it.
th_base :: proc(fno: u32) -> (v0: u32, ok: bool) {
	s := &iop_sched
	r := &r3000.state.r
	a0, a1, a2 := r[4], r[5], r[6]
	if th_wrong_context(.Base, fno) {return ke(KE_ILLEGAL_CONTEXT), true}
	switch fno {
	case 4: // CreateThread(iop_thread_t *): attr, option, entry, stacksize, priority
		entry, size, prio := r32(a0 + 8), r32(a0 + 12), r32(a0 + 16)
		if entry == 0 || entry & 3 != 0 {return ke(KE_ILLEGAL_ENTRY), true}
		if prio < PRIO_HIGHEST || prio > PRIO_LOWEST {return ke(KE_ILLEGAL_PRIORITY), true}
		stack := sys_alloc(.High, size)
		if stack == 0 || size == 0 {return ke(KE_NO_MEMORY), true}
		t := th_new(entry, stack, (size + SYS_ALIGN - 1) &~ (SYS_ALIGN - 1), r[28], prio)
		t.attr, t.option = r32(a0), r32(a0 + 4)
		if cpu.debug >= 1 {fmt.eprintfln("iop: thread %d entry %x prio %d stack %x", t.id, entry, prio, size)}
		return t.id, true
	case 5: // DeleteThread(thid)
		t := th_find(a0)
		if t == nil {return ke(KE_UNKNOWN_THID), true}
		if t.status != .Dormant {return ke(KE_NOT_DORMANT), true}
		if t.start {load_start_gone(t.id)}
		th_remove(t.id)
		return KE_OK, true
	case 6, 7: // StartThread(thid, arg), StartThreadArgs(thid, args, argp)
		t := th_find(a0)
		if t == nil {return ke(KE_UNKNOWN_THID), true}
		if t.status != .Dormant {return ke(KE_NOT_DORMANT), true}
		th_reset(t)
		t.prio = t.init_prio
		if fno == 6 {
			t.ctx.r[4] = a1
		} else {
			t.ctx.r[4], t.ctx.r[5] = a1, a2
		}
		th_wake(t, KE_OK)
		return KE_OK, true
	case 8, 9: // ExitThread, ExitDeleteThread
		th_exit(delete = fno == 9)
		return ke(KE_ILLEGAL_CONTEXT), true
	case 10, 11: // TerminateThread(thid), iTerminateThread(thid)
		t := th_find(a0)
		if t == nil {return ke(KE_UNKNOWN_THID), true}
		if t.id == s.cur {return ke(KE_ILLEGAL_THID), true}
		if t.status == .Dormant {return ke(KE_DORMANT), true}
		t.status = .Dormant
		th_stop(t)
		return KE_OK, true
	case 14: // ChangeThreadPriority(thid, prio): thid 0 the caller, prio 0 the caller's own
		// Retail checks the thread, then that it is not dormant, then the
		// priority.
		t := th_find(s.cur if a0 == 0 else a0)
		c := th_find(s.cur)
		if t == nil && a0 != 0 {return ke(KE_UNKNOWN_THID), true}
		if t != nil && t.status == .Dormant {return ke(KE_DORMANT), true}
		prio := a1
		if prio == 0 {prio = c.prio if c != nil else IOP_START_PRIO}
		if prio < PRIO_HIGHEST || prio > PRIO_LOWEST {return ke(KE_ILLEGAL_PRIORITY), true}
		// The loader's priority is IOP_START_PRIO for good: a start's
		// change of its own is taken and changes nothing.
		if t == nil {return KE_OK, true}
		#partial switch t.status {
		case .Run:
			// The caller keeps the CPU while it stays better than every
			// ready thread, else goes to the tail of its new priority's.
			t.prio = prio
			if b := th_pick(); b != nil && b.prio <= prio {
				th_ready(t)
				th_yield()
			}
		case .Ready:
			t.prio = prio
			th_ready(t)
			if c != nil && prio < c.prio {s.resched = true}
		case .Wait:
			// A waiter: retail moves one in a queue by priority to the
			// tail of its new equals; first come keeps its place. The
			// queue is by priority at the signal (sema_waiter).
			t.prio = prio
			if m := sema_find(t.sema); m != nil && m.attr & SA_THPRI != 0 {
				t.seq = s.tail
				s.tail += 1
			}
		case: t.prio = prio // the other waits are first come
		}
		return KE_OK, true
	case 16: // RotateThreadReadyQueue(prio): the caller yields to its equals
		if t := th_find(s.cur); t != nil {
			th_ready(t)
			th_yield()
		}
		return KE_OK, true
	case 20: // GetThreadId
		return s.cur, true
	case 22: // ReferThreadStatus(thid, iop_thread_info_t *): thid 0 the caller
		return th_refer(s.cur if a0 == 0 else a0, a1), true
	case 24: // SleepThread
		return th_sleep(), true
	case 25, 26: // WakeupThread(thid), iWakeupThread(thid)
		return th_wakeup(a0), true
	case 33: // DelayThread(usec)
		if t := th_find(s.cur); t != nil {t.wake_at = r3000.state.cycles + u64(a0) * (IOP_CLOCK / 1000) / 1000}
		return th_wait(.Delay), true
	case 34: // GetSystemTime(iop_sys_clock_t *)
		w32(a0, u32(r3000.state.cycles))
		w32(a0 + 4, u32(r3000.state.cycles >> 32))
		return KE_OK, true
	case 39: // USec2SysClock(usec, iop_sys_clock_t *)
		c := u64(a0) * IOP_CLOCK / 1_000_000
		w32(a1, u32(c))
		w32(a1 + 4, u32(c >> 32))
		return KE_OK, true
	case 40: // SysClock2USec(iop_sys_clock_t *, u32 *sec, u32 *usec)
		c := u64(r32(a0)) | u64(r32(a0 + 4)) << 32
		w32(a1, u32(c / IOP_CLOCK))
		w32(a2, u32(c % IOP_CLOCK * 1_000_000 / IOP_CLOCK))
		return KE_OK, true
	case 43: // GetSystemTimeLow: the system clock's low 32 bits, as 34 gives them
		return u32(r3000.state.cycles), true
	}
	return 0, false
}

// Function fno of thsemap, as th_base.
th_semap :: proc(fno: u32) -> (v0: u32, ok: bool) {
	s := &iop_sched
	a0 := r3000.state.r[4]
	if th_wrong_context(.Semap, fno) {return ke(KE_ILLEGAL_CONTEXT), true}
	switch fno {
	case 4: // CreateSema(iop_sema_t *): attr, option, initial, max
		append(&s.semas, Iop_Sema{s.next_semid, r32(a0), r32(a0 + 4), i32(r32(a0 + 8)), i32(r32(a0 + 12)), i32(r32(a0 + 8))})
		s.next_semid += 1
		return s.next_semid - 1, true
	case 5: // DeleteSema(semid)
		for m, i in s.semas {
			if m.id == a0 {
				sema_delete(i)
				return KE_OK, true
			}
		}
		return ke(KE_UNKNOWN_SEMID), true
	case 6, 7: // SignalSema(semid), iSignalSema(semid)
		m := sema_find(a0)
		if m == nil {return ke(KE_UNKNOWN_SEMID), true}
		if w := sema_waiter(m^); w != nil {
			th_wake(w, KE_OK)
		} else if m.count >= m.max {
			return ke(KE_SEMA_OVF), true
		} else {
			m.count += 1
		}
		return KE_OK, true
	case 8: // WaitSema(semid)
		m := sema_find(a0)
		if m == nil {return ke(KE_UNKNOWN_SEMID), true}
		if m.count > 0 {
			m.count -= 1
			return KE_OK, true
		}
		return th_wait(.Wait, m.id), true
	case 9: // PollSema(semid)
		m := sema_find(a0)
		if m == nil {return ke(KE_UNKNOWN_SEMID), true}
		if m.count == 0 {return ke(KE_SEMA_ZERO), true}
		m.count -= 1
		return KE_OK, true
	case 11, 12: // ReferSemaStatus(semid, iop_sema_info_t *), iReferSemaStatus
		m := sema_find(a0)
		if m == nil {return ke(KE_UNKNOWN_SEMID), true}
		waiters: u32
		for t in s.threads {
			if t.status == .Wait && t.sema == m.id {waiters += 1}
		}
		info := r3000.state.r[5]
		for w, i in ([6]u32{m.attr, m.option, u32(m.initial), u32(m.max), u32(m.count), waiters}) {
			w32(info + 4 * u32(i), w)
		}
		return KE_OK, true
	}
	return 0, false
}

// The waiter a signal wakes: first by priority for SA_THPRI, else first come.
@(private = "file")
sema_waiter :: proc(m: Iop_Sema) -> ^Iop_Thread {
	best: ^Iop_Thread
	for &t in iop_sched.threads {
		if t.status != .Wait || t.sema != m.id {continue}
		better := best == nil || t.seq < best.seq
		if m.attr & SA_THPRI != 0 && best != nil {
			better = t.prio < best.prio || t.prio == best.prio && t.seq < best.seq
		}
		if better {best = &t}
	}
	return best
}

// ------------------------------------------------------------- thmsgbx

MBA_THPRI :: 1 // waiters by priority, else first come: no waiter here
MBA_MSPRI :: 4 // a box's messages queue by priority, else first come
// The most messages an MBA_MSPRI send walks over: as many as IOP RAM holds,
// so a ring the guest broke by hand ends.
@(private = "file")
MBX_WALK_MAX :: IOP_RAM_SIZE / 8

// Whether a broken ring was shown yet, once under PS_DEBUG; not state.
@(private = "file")
mbx_ring_broken: bool

// Function fno of thmsgbx, as th_base: CreateMbx, SendMbx and PollMbx. No
// ReceiveMbx here, so no thread ever waits on a box and a send only queues.
th_msgbx :: proc(fno: u32) -> (v0: u32, ok: bool) {
	s := &iop_sched
	a0, a1 := r3000.state.r[4], r3000.state.r[5]
	if th_wrong_context(.Msgbx, fno) {return ke(KE_ILLEGAL_CONTEXT), true}
	switch fno {
	case 4: // CreateMbx(iop_mbx_t *): attr, option
		if r32(a0) &~ (MBA_THPRI | MBA_MSPRI) != 0 {return ke(KE_ILLEGAL_ATTR), true}
		append(&s.mbxs, Iop_Mbx{id = s.next_mbxid, attr = r32(a0), option = r32(a0 + 4)})
		s.next_mbxid += 1
		return s.next_mbxid - 1, true
	case 6: // SendMbx(mbxid, iop_message_t *): next word, then a priority byte
		m := mbx_find(a0)
		if m == nil {return ke(KE_UNKNOWN_MBXID), true}
		mbx_put(m, a1)
		return KE_OK, true
	// recvmsg is written unchecked, null too, as retail's PollMbx does.
	// The oldest is `last`'s next word, read now: what retail takes.
	case 9: // PollMbx(void **recvmsg, mbxid): the first message, or NOMSG
		m := mbx_find(a1)
		if m == nil {return ke(KE_UNKNOWN_MBXID), true}
		if m.count <= 0 {return ke(KE_MBOX_NOMSG), true}
		m.count -= 1
		first := r32(m.last)
		after := r32(first)
		if after == first {m.last = 0} else {w32(m.last, after)}
		w32(a0, first)
		return KE_OK, true
	}
	return 0, false
}

@(private = "file")
mbx_find :: proc(id: u32) -> ^Iop_Mbx {
	for &m in iop_sched.mbxs {
		if m.id == id {return &m}
	}
	return nil
}

// Queues message `msg` in box `m` as retail does: newest, or under
// MBA_MSPRI after every message of the same or a better (lower) priority,
// walking the ring from the oldest. A message sent again while still queued
// is linked again, as on retail, which leaves the ring as retail leaves it:
// the same message sent twice to an empty box counts 2 on a one-message
// ring, and the second poll reads through a last of 0. Retail's PollMbx
// does the same, so this is on purpose; no refusal of a resend belongs here.
// A ring the guest broke so the walk never comes back to the last message
// stops at MBX_WALK_MAX, and the message then goes in as the newest.
@(private = "file")
mbx_put :: proc(m: ^Iop_Mbx, msg: u32) {
	m.count += 1
	if m.last == 0 {
		m.last = msg
		w32(msg, msg)
		return
	}
	// After `at`: the newest when no message ranks below it.
	at, newest := m.last, true
	if m.attr & MBA_MSPRI != 0 {
		prio := u8(r32(msg + 4))
		newest = false
		walked := 0
		for ; walked < MBX_WALK_MAX; walked += 1 {
			next := r32(at)
			if prio < u8(r32(next + 4)) {break}
			at = next
			if at == m.last {
				newest = true
				break
			}
		}
		if walked == MBX_WALK_MAX {
			if cpu.debug >= 1 && !mbx_ring_broken {
				mbx_ring_broken = true
				fmt.eprintfln("iop: mbx %d ring has no way back to its last message %08x; message %08x goes in as the newest", m.id, m.last, msg)
			}
			at, newest = m.last, true
		}
	}
	w32(msg, r32(at))
	w32(at, msg)
	if newest {m.last = msg}
}

// ------------------------------------------------------------- thevent

// Function fno of thevent, as th_base. Each call runs only in its context:
// the i-variants in a handler, the rest on a thread or the loader.
th_event :: proc(fno: u32) -> (v0: u32, ok: bool) {
	s := &iop_sched
	r := &r3000.state.r
	a0, a1, a2, a3 := r[4], r[5], r[6], r[7]
	if fno < 4 || fno > 14 || fno == 12 {return 0, false}
	if th_wrong_context(.Event, fno) {return ke(KE_ILLEGAL_CONTEXT), true}
	switch fno {
	case 4: // CreateEventFlag(iop_event_t *): attr, option, bits
		attr := r32(a0)
		if attr &~ EA_MULTI != 0 {return ke(KE_ILLEGAL_ATTR), true}
		append(&s.evfs, Iop_Evf{s.next_evfid, attr, r32(a0 + 4), r32(a0 + 8), r32(a0 + 8)})
		s.next_evfid += 1
		return s.next_evfid - 1, true
	case 5: // DeleteEventFlag(ef)
		for e, i in s.evfs {
			if e.id == a0 {
				evf_delete(i)
				return KE_OK, true
			}
		}
		return ke(KE_UNKNOWN_EVFID), true
	case 6, 7: // SetEventFlag(ef, bits), iSetEventFlag(ef, bits)
		e := evf_find(a0)
		if e == nil {return ke(KE_UNKNOWN_EVFID), true}
		e.bits |= a1
		evf_wake(e)
		return KE_OK, true
	case 8, 9: // ClearEventFlag(ef, bits), iClearEventFlag(ef, bits): the bits kept
		e := evf_find(a0)
		if e == nil {return ke(KE_UNKNOWN_EVFID), true}
		e.bits &= a1
		return KE_OK, true
	case 10, 11: // WaitEventFlag(ef, bits, mode, u32 *resbits), PollEventFlag
		if a2 &~ (WEF_OR | WEF_CLEAR) != 0 {return ke(KE_ILLEGAL_MODE), true}
		if a1 == 0 {return ke(KE_EVF_ILPAT), true}
		e := evf_find(a0)
		if e == nil {return ke(KE_UNKNOWN_EVFID), true}
		// Retail threadman tests EA_MULTI before the bits, in Wait and Poll alike.
		if e.attr & EA_MULTI == 0 && evf_waiters(e.id) > 0 {return ke(KE_EVF_MULTI), true}
		if evf_met(e^, a1, a2) {
			if a3 != 0 {w32(a3, e.bits)}
			if a2 & WEF_CLEAR != 0 {e.bits = 0}
			return KE_OK, true
		}
		if fno == 11 {return ke(KE_EVF_COND), true}
		if t := th_find(s.cur); t != nil {t.evf_bits, t.evf_mode, t.evf_res = a1, a2, a3}
		return th_wait(.Evf, e.id), true
	case 13, 14: // ReferEventFlagStatus(ef, iop_event_info_t *), iReferEventFlagStatus
		e := evf_find(a0)
		if e == nil {return ke(KE_UNKNOWN_EVFID), true}
		// Five words, as retail threadman writes; reserved1/2 are left as they are.
		for w, i in ([5]u32{e.attr, e.option, e.initial, e.bits, evf_waiters(e.id)}) {
			w32(a1 + 4 * u32(i), w)
		}
		return KE_OK, true
	}
	return 0, false
}

@(private = "file")
evf_find :: proc(id: u32) -> ^Iop_Evf {
	for &e in iop_sched.evfs {
		if e.id == id {return &e}
	}
	return nil
}

@(private = "file")
evf_waiters :: proc(id: u32) -> (n: u32) {
	for t in iop_sched.threads {
		if t.status == .Evf && t.sema == id {n += 1}
	}
	return
}

// Whether e's bits meet pattern `bits` in `mode`: any of them for WEF_OR,
// else all.
@(private = "file")
evf_met :: proc(e: Iop_Evf, bits, mode: u32) -> bool {
	m := e.bits & bits
	return m != 0 if mode & WEF_OR != 0 else m == bits
}

// Wakes e's waiters its bits now meet, first come first. Each gets the bits
// as they were before its own WEF_CLEAR, which leaves none for the rest.
@(private = "file")
evf_wake :: proc(e: ^Iop_Evf) {
	for e.bits != 0 {
		first: ^Iop_Thread
		for &t in iop_sched.threads {
			if t.status != .Evf || t.sema != e.id || !evf_met(e^, t.evf_bits, t.evf_mode) {continue}
			if first == nil || t.seq < first.seq {first = &t}
		}
		if first == nil {return}
		if first.evf_res != 0 {w32(first.evf_res, e.bits)}
		if first.evf_mode & WEF_CLEAR != 0 {e.bits = 0}
		th_wake(first, KE_OK)
	}
}

// Removes event flag i; its waiters wake with KE_WAIT_DELETE.
@(private = "file")
evf_delete :: proc(i: int) {
	s := &iop_sched
	id := s.evfs[i].id
	ordered_remove(&s.evfs, i)
	for &t in s.threads {
		if t.status == .Evf && t.sema == id {th_wake(&t, ke(KE_WAIT_DELETE))}
	}
}
