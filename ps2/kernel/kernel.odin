// High-level emulation of the EE kernel: syscalls, threads, semaphores,
// interrupt handlers, alarms and the event schedule that drives vblank.
//
// Each kernel thread runs on its own coroutine; switching threads saves the
// CPU registers into the thread and loads the next one's. Interrupt
// handlers are guest functions called from `run_events` on a kernel stack
// below the program (the real kernel owns 0x00000000-0x0007ffff too).
package ps2_kernel

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import iop "../iop"
import mem "../mem"

CYCLES_PER_LINE :: cpu.CYCLES_PER_FRAME / 262

INTR_STACK_TOP :: 0x00080000

// The syscall table lives in kernel memory, where programs find it by
// searching for handlers they installed. Built-in entries hold fake kernel
// addresses; anything below 0x80000000 is a program-installed handler.
SYSCALL_TABLE :: 0x00010000

Thread_Status :: enum u32 {
	Run      = 1,
	Ready    = 2,
	Wait     = 4,
	Suspend  = 8,
	Wait_Suspend = 12,
	Dormant  = 16,
}

Wait_Kind :: enum u32 {None, Sleep, Sema}

Thread :: struct {
	id:         i32,
	status:     Thread_Status,
	entry:      u32,
	stack:      u32,
	stack_size: u32,
	gp:         u32,
	init_prio:  i32,
	prio:       i32,
	attr, option: u32,
	wait:       Wait_Kind,
	wait_id:    i32,
	wait_result: i32,
	wakeups:    i32,
	seq:        u64, // order of becoming ready, for FIFO within a priority
	regs:       cpu.Cpu,
	co:         ^core.Coroutine,
}

Sema :: struct {
	id:      i32,
	count:   i32,
	max:     i32,
	init:    i32,
	attr:    u32,
	option:  u32,
	waiters: i32,
}

Handler :: struct {
	id:      i32,
	cause:   u32,
	fn, arg: u32,
	gp:      u32,
	enabled: bool,
}

Alarm :: struct {
	id:       i32,
	deadline: u64,
	time:     u32,
	fn, arg:  u32,
	gp:       u32,
}

k: struct {
	threads:      [256]^Thread,
	thread_end:   int, // past the highest thread id ever used; loops stop here
	current:      ^Thread,
	semas:        [256]^Sema,
	intc:         [dynamic]Handler,
	dmac:         [dynamic]Handler,
	alarms:       [dynamic]Alarm,
	next_handler: i32,
	next_alarm:   i32,
	seq:          u64,
	heap_end:     u32,
	osd_config:   u32, // English, 4:3, no spdif
	vblank_start: u64, // next vblank start
	vblank_end:   u64,
	frame:        u64,
}

KE_OK :: 0
KE_ERROR :: -1
KE_RELEASE_WAIT :: -418
KE_UNKNOWN_SEMID :: -408
KE_SEMA_ZERO :: -419

kernel_init :: proc() {
	t := new(Thread)
	t.id = 1
	t.status = .Run // its coroutine is made by run
	k.threads[1] = t
	k.thread_end = 2
	k.current = t
	k.next_handler = 1
	k.osd_config = 1 << 16
	switch core.env("DEBUG") {
	case "": cpu.debug = 0
	case "2": cpu.debug = 2
	case "3": cpu.debug = 3
	case: cpu.debug = 1
	}
	trace_init()
	k.next_alarm = 1
	// Libraries test IE to tell thread context from interrupt context.
	cpu.state.cop0[12] = STATUS_USER
	for n in u32(0) ..< 256 {mem.wr32(SYSCALL_TABLE + n * 4, 0x80001000 + n * 8)}
	k.vblank_start = cpu.CYCLES_PER_FRAME - 22 * CYCLES_PER_LINE
	k.vblank_end = cpu.CYCLES_PER_FRAME
	update_next_event()
}

// ------------------------------------------------------------- syscalls

syscall :: proc(pc: u32) {
	c := &cpu.state
	n := i32(i16(c.r[3].d[0]))
	a0 := u32(c.r[4].d[0])
	a1 := u32(c.r[5].d[0])
	a2 := u32(c.r[6].d[0])
	a3 := u32(c.r[7].d[0])
	t0 := u32(c.r[8].d[0])
	ret: i64 = 0
	if trace_sys_on {trace_syscall(n)}
	if cpu.debug == 2 {
		fmt.eprintfln("syscall %x(%08x, %08x, %08x, %08x) thread %d pc %08x ra %08x", n, a0, a1, a2, a3, k.current.id, pc, u32(c.r[31].d[0]))
	}
	// Syscalls the program installed itself (SetSyscall, or a direct write
	// to the table) run its own code.
	if fn := mem.rd32(SYSCALL_TABLE + u32(abs(n) & 0xff) * 4); fn < 0x80000000 {
		cpu.call(fn)
		return
	}
	switch abs(n) {
	case 0x02: // SetGsCrt(interlace, mode, field)
		fmt.eprintfln("kernel: SetGsCrt(%d, %d, %d)", a0, a1, a2)
	case 0x04: // Exit
		cpu.fatal("program exited with %d", i32(a0))
	case 0x10: ret = add_handler(&k.intc, a0, a1, a3)
	case 0x11: ret = remove_handler(&k.intc, a0, i32(a1))
	case 0x12: ret = add_handler(&k.dmac, a0, a1, a3)
	case 0x13: ret = remove_handler(&k.dmac, a0, i32(a1))
	case 0x14, 0x1a: // EnableIntc
		if mem.intc_mask & (1 << a0) == 0 {mem.intc_mask |= 1 << a0; ret = 1}
	case 0x15, 0x1b: // DisableIntc
		if mem.intc_mask & (1 << a0) != 0 {mem.intc_mask &~= 1 << a0; ret = 1}
	case 0x16, 0x1c: // EnableDmac
		if mem.dmac_stat & (0x10000 << a0) == 0 {mem.dmac_stat |= 0x10000 << a0; ret = 1}
	case 0x17, 0x1d: // DisableDmac
		if mem.dmac_stat & (0x10000 << a0) != 0 {mem.dmac_stat &~= 0x10000 << a0; ret = 1}
	// 0xfc-0xff: SetAlarm, ReleaseAlarm, iSetAlarm, iReleaseAlarm as
	// re-exported by Sony's kernel patch (libkernel wrappers use 0xfc/0xfd;
	// the i-variants arrive negated).
	case 0x18, 0x1e, 0xfc, 0xfe: ret = set_alarm(a0, a1, a2)
	case 0x19, 0x1f, 0xfd, 0xff: ret = release_alarm(i32(a0))
	case 0x20: ret = create_thread(a0)
	case 0x21: ret = delete_thread(i32(a0))
	case 0x22: ret = start_thread(i32(a0), a1)
	case 0x23: exit_thread()
	case 0x24: exit_thread()
	case 0x25, 0x26: ret = terminate_thread(i32(a0))
	case 0x27, 0x28: // Disable/EnableDispatchThread
	case 0x29, 0x2a: ret = change_priority(i32(a0), i32(a1))
	case 0x2b, 0x2c: ret = rotate_ready_queue(i32(a0))
	case 0x2d, 0x2e: ret = release_wait(i32(a0))
	case 0x2f: ret = i64(k.current.id)
	case 0x30, 0x31: ret = refer_thread(i32(a0), a1)
	case 0x32: ret = sleep_thread()
	case 0x33, 0x34: ret = wakeup_thread(i32(a0))
	case 0x35, 0x36: // CancelWakeupThread
		if t := thread(i32(a0)); t != nil {ret = i64(t.wakeups); t.wakeups = 0}
	case 0x37, 0x38: ret = suspend_thread(i32(a0))
	case 0x39, 0x3a: ret = resume_thread(i32(a0))
	case 0x3c: ret = i64(setup_thread(a0, a1, a2, a3))
	case 0x3d: // SetupHeap(start, size)
		k.heap_end = a1 == 0xffffffff ? u32(c.r[29].d[0]) - 0x10000 : a0 + a1
		ret = i64(k.heap_end)
	case 0x3e: ret = i64(k.heap_end) // EndOfHeap
	case 0x40: ret = create_sema(a0)
	case 0x41: ret = delete_sema(i32(a0))
	case 0x42, 0x43: ret = signal_sema(i32(a0))
	case 0x44: ret = wait_sema(i32(a0))
	case 0x45, 0x46: ret = poll_sema(i32(a0))
	case 0x47, 0x48: ret = refer_sema(i32(a0), a1)
	case 0x4a: k.osd_config = mem.rd32(a0) // SetOsdConfigParam(*param)
	case 0x4b: mem.wr32(a0, k.osd_config) // GetOsdConfigParam(*param)
	case 0x5c ..= 0x5f: // Enable/Disable Intc/Dmac handler(cid, id)
		list := abs(n) <= 0x5d ? &k.intc : &k.dmac
		for &h in list {if h.id == i32(a0) || h.id == i32(a1) {h.enabled = abs(n) & 1 == 0}}
	case 0x5b: ret = i64(mem.rd32(SYSCALL_TABLE + (a0 & 0xff) * 4)) // GetEntryAddress
	case 0x63, 0x67: ret = i64(cpu.state.cop0[a0 & 31]) // GetCop0, iGetCop0
	case 0x64, 0x68: // FlushCache
	case 0x6b: // SifStopDma: transfers complete instantly
	case 0x70: ret = i64(mem.gs_imr) // GsGetIMR
	case 0x71: // GsPutIMR
		ret = i64(mem.gs_imr)
		mem.gs_imr = a0
	case 0x73: // SetVSyncFlag
	case 0x74: // SetSyscall(index, fn)
		mem.wr32(SYSCALL_TABLE + (a0 & 0xff) * 4, a1)
	case 0x76: ret = iop.sif_dma_stat(i32(a0))
	case 0x77: ret = i64(iop.sif_set_dma(a0, a1))
	case 0x78: // SifSetDChain
	case 0x79: iop.sif_reg_set(a0, a1)
	case 0x7a: ret = i64(iop.sif_reg_get(a0))
	case 0x7c: ret = -1 // Deci2Call: no debugger attached
	case 0x7e: ret = 0 // MachineType
	case 0x7f: ret = mem.RAM_SIZE // GetMemorySize
	case:
		fmt.eprintfln("kernel: unhandled syscall %d (a0 %08x a1 %08x) at %08x ra %08x",
			n, a0, a1, pc, u32(c.r[31].d[0]))
	}
	_ = t0
	c.r[2].d[0] = u64(ret)
}

// -------------------------------------------------------------- threads

// Thread calls return the thread id on success, as the EE kernel and the
// semaphore calls do: libraries compare it (CRI ADXM wakes a thread it
// resumed only when ResumeThread returned that thread's id).
thread :: proc(id: i32) -> ^Thread {
	if id == 0 {return k.current}
	if id < 0 || id >= len(k.threads) {return nil}
	return k.threads[id]
}

setup_thread :: proc(gp, stack, size, args: u32) -> u32 {
	cpu.state.r[28].d[0] = cpu.sx32(gp)
	top := stack == 0xffffffff ? mem.RAM_SIZE : stack + size
	t := k.current
	t.gp, t.stack, t.stack_size = gp, top - size, size
	return top - 16
}

create_thread :: proc(param: u32) -> i64 {
	id := -1
	for n in 2 ..< len(k.threads) {
		if k.threads[n] == nil {id = n; break}
	}
	if id < 0 {return KE_ERROR}
	t := new(Thread)
	t.id = i32(id)
	t.status = .Dormant
	t.entry = mem.rd32(param + 4)
	t.stack = mem.rd32(param + 8)
	t.stack_size = mem.rd32(param + 12)
	t.gp = mem.rd32(param + 16)
	t.init_prio = i32(mem.rd32(param + 20))
	t.prio = t.init_prio
	t.attr = mem.rd32(param + 28)
	t.option = mem.rd32(param + 32)
	k.threads[id] = t
	k.thread_end = max(k.thread_end, id + 1)
	return i64(id)
}

delete_thread :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil || t == k.current || t.status != .Dormant {return KE_ERROR}
	k.threads[id] = nil
	if t.co != nil {core.co_kill(t.co)}
	free(t)
	return i64(id)
}

// Body of every created thread's coroutine: run the entry, then park
// dormant until started again.
@(private)
thread_main :: proc(arg: rawptr) {
	t := (^Thread)(arg)
	for {
		cpu.call(t.entry)
		t.status = .Dormant
		reschedule()
	}
}

start_thread :: proc(id: i32, arg: u32) -> i64 {
	t := thread(id)
	if t == nil || t.status != .Dormant {return KE_ERROR}
	t.regs = {}
	t.regs.r[4].d[0] = cpu.sx32(arg)
	t.regs.r[28].d[0] = cpu.sx32(t.gp)
	t.regs.r[29].d[0] = cpu.sx32(t.stack + t.stack_size - 16)
	t.regs.fcr31 = cpu.state.fcr31
	t.regs.cop0 = cpu.state.cop0
	t.regs.cop0[12] = STATUS_USER
	t.prio = t.init_prio
	t.wakeups = 0
	if t.co == nil {t.co = core.co_create(thread_main, t)}
	make_ready(t)
	reschedule()
	return i64(id)
}

exit_thread :: proc() {
	t := k.current
	t.status = .Dormant
	if t.id == 1 {cpu.fatal("main thread exited")}
	reschedule()
	// Restarted: run the entry again on a fresh frame of thread_main.
	cpu.fatal("exited thread %d resumed", t.id)
}

terminate_thread :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil || t == k.current {return KE_ERROR}
	unwait(t)
	t.status = .Dormant
	// The coroutine is parked inside a syscall; drop it so a restart begins
	// anew.
	if t.co != nil {core.co_kill(t.co); t.co = nil}
	return i64(id)
}

change_priority :: proc(id: i32, prio: i32) -> i64 {
	t := thread(id)
	if t == nil {return KE_ERROR}
	old := t.prio
	t.prio = prio
	reschedule()
	return i64(old)
}

rotate_ready_queue :: proc(prio: i32) -> i64 {
	if k.current.prio == prio {
		k.seq += 1
		k.current.seq = k.seq
	}
	for t in k.threads[:k.thread_end] {
		if t != nil && t != k.current && t.prio == prio && t.status == .Ready {
			reschedule()
			break
		}
	}
	return KE_OK
}

refer_thread :: proc(id: i32, info: u32) -> i64 {
	t := thread(id)
	if t == nil {return KE_ERROR}
	if info != 0 {
		mem.wr32(info + 0, u32(t.status))
		mem.wr32(info + 4, t.entry)
		mem.wr32(info + 8, t.stack)
		mem.wr32(info + 12, t.stack_size)
		mem.wr32(info + 16, t.gp)
		mem.wr32(info + 20, u32(t.init_prio))
		mem.wr32(info + 24, u32(t.prio))
		mem.wr32(info + 28, t.attr)
		mem.wr32(info + 32, t.option)
		mem.wr32(info + 36, u32(t.wait))
		mem.wr32(info + 40, u32(t.wait_id))
		mem.wr32(info + 44, u32(t.wakeups))
	}
	return i64(t.status)
}

sleep_thread :: proc() -> i64 {
	t := k.current
	if t.wakeups > 0 {
		t.wakeups -= 1
		return KE_OK
	}
	block(t, .Sleep, 0)
	return i64(t.wait_result)
}

wakeup_thread :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil || t == k.current && !cpu.in_interrupt {return KE_ERROR}
	if t.wait == .Sleep {
		wake(t, KE_OK)
		reschedule()
	} else {
		t.wakeups += 1
	}
	return i64(t.id)
}

suspend_thread :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil {return KE_ERROR}
	#partial switch t.status {
	case .Wait:  t.status = .Wait_Suspend
	case .Ready, .Run: t.status = .Suspend
	}
	reschedule()
	return i64(t.id)
}

resume_thread :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil {return KE_ERROR}
	#partial switch t.status {
	case .Wait_Suspend: t.status = .Wait
	case .Suspend: make_ready(t); reschedule()
	}
	return i64(t.id)
}

release_wait :: proc(id: i32) -> i64 {
	t := thread(id)
	if t == nil || t.wait == .None {return KE_ERROR}
	unwait(t)
	wake(t, KE_RELEASE_WAIT)
	reschedule()
	return i64(t.id)
}

make_ready :: proc(t: ^Thread) {
	t.status = .Ready
	k.seq += 1
	t.seq = k.seq
}

// Put the current thread to sleep on something and run others until woken.
block :: proc(t: ^Thread, kind: Wait_Kind, id: i32) {
	t.status = .Wait
	t.wait = kind
	t.wait_id = id
	reschedule()
}

wake :: proc(t: ^Thread, result: i32) {
	t.wait = .None
	t.wait_result = result
	if t.status == .Wait_Suspend {
		t.status = .Suspend
	} else {
		make_ready(t)
	}
}

// Drop a thread from whatever it waits on.
unwait :: proc(t: ^Thread) {
	if t.wait == .Sema {
		if s := sema(t.wait_id); s != nil {s.waiters -= 1}
	}
}

@(private)
pick_thread :: proc() -> ^Thread {
	best: ^Thread
	for t in k.threads[:k.thread_end] {
		if t == nil || (t.status != .Ready && t.status != .Run) {continue}
		if best == nil || t.prio < best.prio || (t.prio == best.prio && t.seq < best.seq) {
			best = t
		}
	}
	return best
}

// Switch to the highest-priority runnable thread, idling (advancing time to
// the next event) while none is runnable.
// Status as the kernel starts a thread: user mode, COP0/1 usable, EIE and
// IE set, EXL clear.
STATUS_USER :: 0x70030c13 &~ 0x2

reschedule :: proc() {
	if cpu.in_interrupt {return}
	for {
		next := pick_thread()
		if next != nil {
			if next != k.current {switch_to(next)}
			return
		}
		idle()
	}
}

@(private)
switch_to :: proc(next: ^Thread) {
	cur := k.current
	cur.regs = cpu.state
	if cur.status == .Run {cur.status = .Ready}
	k.current = next
	next.status = .Run
	cycles := cpu.state.cycles
	cpu.state = next.regs
	cpu.state.cycles = cycles
	core.co_switch(next.co)
}

// Guest cycles skipped while every thread waits, for STATS.
idle_cycles: u64

@(private)
idle :: proc() {
	if cpu.next_event == max(u64) {cpu.fatal("deadlock: every thread waits and no event is pending")}
	if cpu.state.cycles < cpu.next_event {
		idle_cycles += cpu.next_event - cpu.state.cycles
		cpu.state.cycles = cpu.next_event
	}
	// The kernel idles with interrupts enabled, whatever the status of the
	// thread that blocked last.
	status := cpu.state.cop0[12]
	cpu.state.cop0[12] = STATUS_USER
	run_events()
	cpu.state.cop0[12] = status
}

// ----------------------------------------------------------- semaphores

sema :: proc(id: i32) -> ^Sema {
	if id <= 0 || id >= len(k.semas) {return nil}
	return k.semas[id]
}

create_sema :: proc(param: u32) -> i64 {
	for n in 1 ..< len(k.semas) {
		if k.semas[n] != nil {continue}
		s := new(Sema)
		s.id = i32(n)
		s.max = i32(mem.rd32(param + 4))
		s.init = i32(mem.rd32(param + 8))
		s.count = s.init
		s.attr = mem.rd32(param + 16)
		s.option = mem.rd32(param + 20)
		k.semas[n] = s
		return i64(n)
	}
	return KE_ERROR
}

delete_sema :: proc(id: i32) -> i64 {
	s := sema(id)
	if s == nil {return KE_UNKNOWN_SEMID}
	for t in k.threads[:k.thread_end] {
		if t != nil && t.wait == .Sema && t.wait_id == id {wake(t, KE_ERROR)}
	}
	k.semas[id] = nil
	free(s)
	reschedule()
	return i64(id)
}

signal_sema :: proc(id: i32) -> i64 {
	s := sema(id)
	if s == nil {return KE_UNKNOWN_SEMID}
	if s.waiters > 0 {
		// Wake the waiter that has waited longest among the highest priority.
		best: ^Thread
		for t in k.threads[:k.thread_end] {
			if t == nil || t.wait != .Sema || t.wait_id != id {continue}
			if best == nil || t.prio < best.prio || (t.prio == best.prio && t.seq < best.seq) {best = t}
		}
		s.waiters -= 1
		wake(best, id)
		reschedule()
	} else if s.count < s.max || s.max == 0 {
		s.count += 1
	}
	return i64(id)
}

wait_sema :: proc(id: i32) -> i64 {
	s := sema(id)
	if s == nil {return KE_UNKNOWN_SEMID}
	if s.count > 0 {
		s.count -= 1
		return i64(id)
	}
	s.waiters += 1
	t := k.current
	k.seq += 1
	t.seq = k.seq
	block(t, .Sema, id)
	return i64(t.wait_result)
}

poll_sema :: proc(id: i32) -> i64 {
	s := sema(id)
	if s == nil {return KE_UNKNOWN_SEMID}
	if s.count > 0 {
		s.count -= 1
		return i64(id)
	}
	return KE_SEMA_ZERO
}

refer_sema :: proc(id: i32, info: u32) -> i64 {
	s := sema(id)
	if s == nil {return KE_UNKNOWN_SEMID}
	if info != 0 {
		mem.wr32(info + 0, u32(s.count))
		mem.wr32(info + 4, u32(s.max))
		mem.wr32(info + 8, u32(s.init))
		mem.wr32(info + 12, u32(s.waiters))
		mem.wr32(info + 16, s.attr)
		mem.wr32(info + 20, s.option)
	}
	return i64(id)
}

// --------------------------------------------- interrupts and the clock

add_handler :: proc(list: ^[dynamic]Handler, cause, fn, arg: u32) -> i64 {
	id := k.next_handler
	k.next_handler += 1
	append(list, Handler{id = id, cause = cause, fn = fn, arg = arg, gp = u32(cpu.state.r[28].d[0]), enabled = true})
	return i64(id)
}

remove_handler :: proc(list: ^[dynamic]Handler, cause: u32, id: i32) -> i64 {
	for h, n in list {
		if h.id == id {
			ordered_remove(list, n)
			return KE_OK
		}
	}
	return KE_ERROR
}

set_alarm :: proc(time, fn, arg: u32) -> i64 {
	id := k.next_alarm
	k.next_alarm += 1
	append(&k.alarms, Alarm{
		id = id, deadline = cpu.state.cycles + u64(time) * CYCLES_PER_LINE, time = time,
		fn = fn, arg = arg, gp = u32(cpu.state.r[28].d[0]),
	})
	update_next_event()
	return i64(id)
}

release_alarm :: proc(id: i32) -> i64 {
	for a, n in k.alarms {
		if a.id == id {
			ordered_remove(&k.alarms, n)
			update_next_event()
			return KE_OK
		}
	}
	return KE_ERROR
}

// Call a guest interrupt handler with the interrupted state preserved.
call_handler :: proc(fn, gp, a0, a1, a2: u32) -> u32 {
	saved := cpu.state
	cpu.state.r[4].d[0] = cpu.sx32(a0)
	cpu.state.r[5].d[0] = cpu.sx32(a1)
	cpu.state.r[6].d[0] = cpu.sx32(a2)
	cpu.state.r[28].d[0] = cpu.sx32(gp)
	cpu.state.r[29].d[0] = INTR_STACK_TOP - 16
	cpu.state.r[31].d[0] = 0
	cpu.call(fn)
	ret := u32(cpu.state.r[2].d[0])
	cycles := cpu.state.cycles
	cpu.state = saved
	cpu.state.cycles = cycles
	return ret
}

update_next_event :: proc() {
	n := min(k.vblank_start, k.vblank_end)
	for a in k.alarms {n = min(n, a.deadline)}
	cpu.next_event = n
}

// Process due events and deliver pending interrupts. Called by recompiled
// code whenever `state.cycles` reaches `next_event`.
run_events :: proc() {
	if cpu.in_interrupt {return}
	cpu.in_interrupt = true
	cpu.next_event = max(u64) // handlers run without re-entering

	now := cpu.state.cycles
	if now >= k.vblank_start {
		k.vblank_start += cpu.CYCLES_PER_FRAME
		k.frame += 1
		mem.gs_csr |= 0x8 // VSINT
		mem.gs_csr ~= 0x2000 // FIELD
		mem.intc_raise(mem.INTC_VBLANK_START)
		if mem.gs_imr & 0x800 == 0 {mem.intc_raise(mem.INTC_GS)}
		// Snapshots hold the state as of here, before the host's input for
		// the frame, so a loaded one replays with whatever input the host
		// gives it next.
		if core.snap_op != .None {core.snap_yield()}
		{
			context.allocator = core.host_allocator
			vblank_hook()
		}
		iop.pad_update()
		iop.fmod_vblank()
		if cpu.debug != 0 && k.frame % 120 == 0 {dump_threads()}
	}
	if now >= k.vblank_end {
		k.vblank_end += cpu.CYCLES_PER_FRAME
		mem.intc_raise(mem.INTC_VBLANK_END)
	}
	for n := 0; n < len(k.alarms); {
		a := k.alarms[n]
		if now >= a.deadline {
			ordered_remove(&k.alarms, n)
			call_handler(a.fn, a.gp, u32(a.id), a.time, a.arg)
		} else {
			n += 1
		}
	}
	deliver_interrupts()

	cpu.in_interrupt = false
	update_next_event()
	// A handler may have readied a thread that outranks the current one.
	if t := pick_thread(); t != nil && t != k.current && t.prio < k.current.prio {
		reschedule()
	}
}

// EI: unmask interrupts, and deliver at once any left pending while masked.
ei :: proc() {
	cpu.state.cop0[12] |= 0x10000
	if mem.intc_pending & mem.intc_mask != 0 || mem.dmac_stat & (mem.dmac_stat >> 16) & 0x3ff != 0 || len(iop.sif.replies) != 0 {
		cpu.next_event = cpu.state.cycles
	}
}

deliver_interrupts :: proc() {
	// Masked by DI: pending bits stay set in INTC_STAT/D_STAT, where code
	// polling with interrupts off (sceGsSyncV and friends) expects them.
	// EI re-arms delivery.
	if cpu.state.cop0[12] & 0x10001 != 0x10001 {return}
	for {
		iop.sif_pump()
		pending := mem.intc_pending & mem.intc_mask
		dpending := mem.dmac_stat & (mem.dmac_stat >> 16) & 0x3ff
		if pending == 0 && dpending == 0 {return}
		for cause in u32(0) ..< 15 {
			if pending & (1 << cause) == 0 {continue}
			mem.intc_pending &~= 1 << cause
	for h in k.intc {
				if h.cause == cause && h.enabled {
					if i32(call_handler(h.fn, h.gp, cause, h.arg, 0)) < 0 {break} // a negative return ends the chain
				}
			}
		}
		for ch in u32(0) ..< 10 {
			if dpending & (1 << ch) == 0 {continue}
			mem.dmac_stat &~= 1 << ch
			for h in k.dmac {
				if h.cause == ch && h.enabled {
					if i32(call_handler(h.fn, h.gp, ch, h.arg, 0)) < 0 {break} // a negative return ends the chain
				}
			}
		}
	}
}

// Called on every vblank start, for the host side (present, input, pacing).
vblank_hook: proc() = proc() {}

dump_threads :: proc() {
	fmt.eprintfln("--- frame %d, current thread %d", k.frame, k.current.id)
	for t in k.threads[:k.thread_end] {
		if t == nil {continue}
		regs := t == k.current ? cpu.state : t.regs
		fmt.eprintfln("thread %2d prio %3d %v wait %v/%d entry %08x ra %08x sp %08x",
			t.id, t.prio, t.status, t.wait, t.wait_id, t.entry, u32(regs.r[31].d[0]), u32(regs.r[29].d[0]))
		// Words on the stack that point into code: likely return addresses.
		sp := u32(regs.r[29].d[0]) & 0x0fffffff
		fmt.eprint("    stack:")
		for o: u32 = 0; o < 0x200 && sp + o + 4 <= mem.RAM_SIZE; o += 4 {
			w := mem.ram_slice(sp + o, 4)
			v := u32(w[0]) | u32(w[1]) << 8 | u32(w[2]) << 16 | u32(w[3]) << 24
			if v >= cpu.text_lo && v < cpu.text_hi && v & 3 == 0 {fmt.eprintf(" %x", v)}
		}
		fmt.eprintln()
	}
	for s in k.semas {
		if s == nil {continue}
		fmt.eprintf("sema %d %d/%d w%d  ", s.id, s.count, s.max, s.waiters)
	}
	fmt.eprintln()
	fmt.eprintfln("intc mask %x pend %x  dmac stat %08x  status %08x  gs csr %x imr %x  vif1 chcr %x gif chcr %x",
		mem.intc_mask, mem.intc_pending, mem.dmac_stat, cpu.state.cop0[12], mem.gs_csr, mem.gs_imr, mem.dma_reg(mem.DMA_VIF1, 0)^, mem.dma_reg(mem.DMA_GIF, 0)^)
	for h in k.intc {fmt.eprintf("intc %d:%x%s ", h.cause, h.fn, h.enabled ? "" : "(off)")}
	for h in k.dmac {fmt.eprintf("dmac %d:%x%s ", h.cause, h.fn, h.enabled ? "" : "(off)")}
	fmt.eprintln()
}

// Emulated state, saved and restored by snapshots (snap.odin).
kernel_snap :: proc() {
	core.snap_add(&k)
	core.snap_add(&idle_cycles)
}
