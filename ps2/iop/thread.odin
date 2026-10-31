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
// tick the IOP next: at a thread's wake, at once while one is ready, or at
// a libsd interrupt (libsd.odin).
//
// A command handler, and a libsd interrupt handler, runs on a coroutine of
// its own, not a thread's: retail runs it in an interrupt handler, where it
// may not wait. One that waits, or spins past its budget, is stopped there
// (th_intr_stop).
//
// A thread's context: the R3000's r[0..31], hi and lo, cop0's sr, cause and
// epc, and frame_ret, saved when it leaves the CPU and restored when it gets
// it back. Its pc and branch state are the interpreter's locals, on its
// coroutine's stack. The cycle count is global time: never saved.
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
KE_ILLEGAL_ENTRY :: -402
KE_ILLEGAL_PRIORITY :: -403
KE_ILLEGAL_THID :: -406
KE_UNKNOWN_THID :: -407
KE_UNKNOWN_SEMID :: -408
KE_DORMANT :: -413
KE_NOT_DORMANT :: -414
KE_CAN_NOT_WAIT :: -417
KE_SEMA_ZERO :: -419
KE_SEMA_OVF :: -420
KE_WAIT_DELETE :: -425

@(private = "file")
PRIO_HIGHEST :: 1
@(private = "file")
PRIO_LOWEST :: 126
@(private = "file")
SA_THPRI :: 1 // a semaphore's waiters by priority, else first come

Th_Status :: enum u8 {
	Dormant,
	Ready,
	Run,
	Wait, // on a semaphore
	Sleep,
	Delay, // on DelayThread, until wake_at
}

Th_Context :: struct {
	r:         [32]u32,
	hi, lo:    u32,
	cop0:      type_of(r3000.cop0),
	frame_ret: u32,
}

Iop_Thread :: struct {
	id:                     u32,
	attr, option:           u32,
	entry, stack, stacksize: u32,
	gp, prio:               u32,
	status:                 Th_Status,
	start:                  bool, // a module's start
	exit_delete:            bool, // removed once it is dormant
	seq:                    i64, // its place in its ready or wait queue
	sema:                   u32, // what it waits on
	wakeups:                u32, // WakeupThread calls while it was awake
	wake:                   u32, // what its wait returns
	wake_at:                u64, // when its Delay ends, IOP cycles
	ctx:                    Th_Context,
	co:                     ^core.Coroutine,
}

Iop_Sema :: struct {
	id, attr, option: u32,
	count, max:       i32,
}

// Emulated state, in the emu heap: snapshotted (sif_snap).
iop_sched: struct {
	threads:              [dynamic]Iop_Thread,
	semas:                [dynamic]Iop_Sema,
	next_thid, next_semid: u32,
	head, tail:           i64, // the next seq at a queue's head, at its tail
	cur:                  u32, // the running thread, 0 on the loader
	resched:              bool, // a thread of better priority than cur became ready
	budget:               bool, // the load's budget is spent
	start_done:           bool, // the start returned, its v0 in start_result
	start_result:         u32,
	intr:                 bool, // a handler runs, on intr_co
	intr_stop:            Intr_Stop, // why it was stopped
	intr_handler:         u32, // what it runs and its arguments
	intr_a0, intr_a1:     u32,
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

// The coroutine a load schedules from. Only set while a load runs.
@(private = "file")
th_loader: ^core.Coroutine

th_init :: proc() {
	s := &iop_sched
	for &t in s.threads {
		if t.co != nil {core.co_kill(t.co)}
	}
	if s.intr_co != nil {core.co_kill(s.intr_co)}
	clear(&s.threads)
	clear(&s.semas)
	s^ = {
		threads    = s.threads,
		semas      = s.semas,
		next_thid  = 1,
		next_semid = 1,
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
	append(&s.threads, Iop_Thread{id = s.next_thid, entry = entry, stack = stack, stacksize = stacksize, gp = gp, prio = prio})
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
	assert(th_loader == nil && s.cur == 0, "iop: the scheduler entered while the IOP runs")
	th_loader = core.co_current
	frame := r3000.frame_ret
	s.budget = false
	s.resched = false
	r3000.next_event = until
	r3000.run_events = th_budget
	for !s.budget && !(s.start_done && iop_loader.failed) {
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
		if t.co == nil {t.co = core.co_create(th_main, rawptr(uintptr(id)))}
		core.co_switch(t.co)
		s.cur = 0
		if t = th_find(id); t != nil && t.status == .Dormant {th_stop(t)}
	}
	th_due()
	r3000.next_event = IOP_EVENT_OFF
	r3000.run_events = proc() {}
	r3000.frame_ret = frame // a suspended thread's call has not restored it
	th_loader = nil
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
// first wake, and from libsd's interrupts (sd_next_ee). The EE's next event
// moves up to it, unless the EE is handling events, which ends with
// update_next_event.
iop_wake_set :: proc() {
	w := th_next_wake()
	if th_pick() != nil {w = r3000.state.cycles}
	iop_wake_ee = min(w if w == max(u64) else w * IOP_EE_RATIO, sd_next_ee())
	if !cpu.in_interrupt {cpu.next_event = min(cpu.next_event, iop_wake_ee)}
}

// The EE's events at EE cycle `now`, the IOP's wake due: runs libsd's due
// interrupt handlers, then its threads for a slice.
iop_tick :: proc(now: u64) {
	iop_sync(now)
	sd_intr_run(now)
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

// Drops a dormant thread's coroutine, and the thread itself when it asked
// to be deleted.
@(private = "file")
th_stop :: proc(t: ^Iop_Thread) {
	if t.co != nil {
		core.co_kill(t.co)
		t.co = nil
	}
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
		r         = r3000.state.r,
		hi        = r3000.state.hi,
		lo        = r3000.state.lo,
		cop0      = r3000.cop0,
		frame_ret = r3000.frame_ret,
	}
}

@(private = "file")
th_restore :: proc(t: ^Iop_Thread) {
	r3000.state.r = t.ctx.r
	r3000.state.hi = t.ctx.hi
	r3000.state.lo = t.ctx.lo
	r3000.cop0 = t.ctx.cop0
	r3000.frame_ret = t.ctx.frame_ret
}

// Takes the running thread, its status already set, off the CPU, and puts
// its context back once the loader runs it again.
@(private = "file")
th_yield :: proc() {
	id := iop_sched.cur
	th_save(th_find(id))
	core.co_switch(th_loader)
	th_restore(th_find(id))
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
// stopped.
@(private = "file")
th_budget :: proc() {
	if iop_sched.intr {th_intr_stop(.Blocked)}
	if iop_sched.cur == 0 {return}
	iop_sched.budget = true
	th_preempt()
}

// The running thread waits; what its waker gave, or KE_CAN_NOT_WAIT on the
// loader. A command handler that waits is stopped.
@(private = "file")
th_wait :: proc(status: Th_Status, sema: u32 = 0) -> u32 {
	s := &iop_sched
	if s.intr {th_intr_stop(.Blocked)}
	t := th_find(s.cur)
	if t == nil {return ke(KE_CAN_NOT_WAIT)}
	t.status = status
	t.sema = sema
	t.seq = s.tail
	s.tail += 1
	t.wake = KE_OK
	th_yield()
	return th_find(s.cur).wake
}

// Ends the running thread; the loader drops its coroutine. A start's end
// is its return, v0 its result.
th_exit :: proc(delete := false) {
	s := &iop_sched
	t := th_find(s.cur)
	if t == nil {return}
	if t.start {
		s.start_done = true
		s.start_result = r3000.state.r[2]
	}
	t.status = .Dormant
	t.exit_delete ||= delete
	core.co_switch(th_loader)
	unreachable()
}

// An HLE call failed in the running thread. In a start the load fails once
// the start returns; any other thread, or a command handler, is stopped
// there, dormant.
th_call_failed :: proc() {
	if iop_sched.intr {th_intr_stop(.Call)}
	t := th_find(iop_sched.cur)
	if t == nil || t.start {
		iop_loader.failed = true
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
	assert(th_loader == nil && s.cur == 0, "iop: a handler run while the IOP runs")
	saved := Th_Context{r3000.state.r, r3000.state.hi, r3000.state.lo, r3000.cop0, r3000.frame_ret}
	if s.intr_co == nil {s.intr_co = core.co_create(th_intr_main, nil)}
	s.intr, s.intr_stop = true, .None
	s.intr_handler, s.intr_a0, s.intr_a1 = handler, a0, a1
	th_loader = core.co_current
	r3000.next_event = r3000.state.cycles + IOP_INTR_BUDGET
	r3000.run_events = th_budget
	core.co_switch(s.intr_co)
	th_loader = nil
	r3000.next_event = IOP_EVENT_OFF
	r3000.run_events = proc() {}
	s.intr = false
	if s.intr_stop != .None {
		core.co_kill(s.intr_co)
		s.intr_co = nil
	}
	r3000.state.r, r3000.state.hi, r3000.state.lo = saved.r, saved.hi, saved.lo
	r3000.cop0, r3000.frame_ret = saved.cop0, saved.frame_ret
	return s.intr_stop
}

// The handler coroutine: each handler, then back to th_intr. It never
// returns, so one coroutine serves every handler until one is stopped on it.
@(private = "file")
th_intr_main :: proc(_: rawptr) {
	s := &iop_sched
	for {
		r := &r3000.state.r
		r[4], r[5] = s.intr_a0, s.intr_a1
		r[29] = IOP_INTR_STACK - 16
		r3000.call(s.intr_handler)
		core.co_switch(th_loader)
	}
}

// Stops the running command handler where it is; th_intr kills its
// coroutine.
@(private = "file")
th_intr_stop :: proc(why: Intr_Stop) {
	iop_sched.intr_stop = why
	core.co_switch(th_loader)
	unreachable()
}

// Undoes a failed load: deletes the semaphores and threads made since ids
// `thid` and `semid`, killing the threads' coroutines. Their stacks are
// freed by the caller's sys_blocks restore.
th_undo :: proc(thid, semid: u32) {
	s := &iop_sched
	for i := len(s.semas) - 1; i >= 0; i -= 1 {
		if s.semas[i].id >= semid {sema_delete(i)}
	}
	for i := len(s.threads) - 1; i >= 0; i -= 1 {
		t := &s.threads[i]
		if t.id < thid {continue}
		if t.co != nil {core.co_kill(t.co)}
		ordered_remove(&s.threads, i)
	}
	for t in s.threads {assert(t.id < thid, "iop: a failed load's thread left queued")}
	s.resched = false
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

// ------------------------------------------------------------- thbase, thsemap

// Function fno of thbase, reading a0..a2; v0, or false when the HLE lacks
// it. Thread id 0 is the caller where thbase allows it.
th_base :: proc(fno: u32) -> (v0: u32, ok: bool) {
	s := &iop_sched
	r := &r3000.state.r
	a0, a1, a2 := r[4], r[5], r[6]
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
		th_remove(t.id)
		return KE_OK, true
	case 6, 7: // StartThread(thid, arg), StartThreadArgs(thid, args, argp)
		t := th_find(a0)
		if t == nil {return ke(KE_UNKNOWN_THID), true}
		if t.status != .Dormant {return ke(KE_NOT_DORMANT), true}
		th_reset(t)
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
	case 16: // RotateThreadReadyQueue(prio): the caller yields to its equals
		if t := th_find(s.cur); t != nil {
			th_ready(t)
			th_yield()
		}
		return KE_OK, true
	case 20: // GetThreadId
		return s.cur, true
	case 24: // SleepThread
		t := th_find(s.cur)
		if t != nil && t.wakeups > 0 {
			t.wakeups -= 1
			return KE_OK, true
		}
		return th_wait(.Sleep), true
	case 25, 26: // WakeupThread(thid), iWakeupThread(thid)
		t := th_find(a0)
		if t == nil {return ke(KE_UNKNOWN_THID), true}
		if t.id == s.cur {return ke(KE_ILLEGAL_THID), true}
		if t.status == .Dormant {return ke(KE_DORMANT), true}
		if t.status == .Sleep {
			th_wake(t, KE_OK)
		} else {
			t.wakeups += 1
		}
		return KE_OK, true
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
	}
	return 0, false
}

// Function fno of thsemap, as th_base.
th_semap :: proc(fno: u32) -> (v0: u32, ok: bool) {
	s := &iop_sched
	a0 := r3000.state.r[4]
	switch fno {
	case 4: // CreateSema(iop_sema_t *): attr, option, initial, max
		append(&s.semas, Iop_Sema{s.next_semid, r32(a0), r32(a0 + 4), i32(r32(a0 + 8)), i32(r32(a0 + 12))})
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
