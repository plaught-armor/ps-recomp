// timrman as IOP modules import it (PS_IRX=1): the IOP's six hardware
// timers, allocated, given a compare handler, set up, started and stopped.
// A timer counting the system clock is timed against r3000's cycle count,
// the clock USec2SysClock converts to, divided by its prescale; its compare
// handler runs from iop_tick at each compare due (tim_intr_run), on the
// handler coroutine (th_intr), as retail runs it in the timer's interrupt.
// The handler's v0 is the next compare, counted from this one, as the
// timer's counter restarts at each compare; 0 stops the timer. A timer set
// to count another source, or gated, is set up and started as on retail and
// never fires, with a compat row.
//
// thbase's alarms (SetAlarm) run on the same path. Retail's thbase keeps
// them on a hardware timer of its own, which no module sees allocated; here
// each is due at an IOP cycle and its handler runs from tim_intr_run, after
// the timers' compares, on the handler coroutine. The handler's v0 is the
// next alarm, counted from this one, no sooner than ALARM_MIN; 0 ends it.
package ps2_iop

import "core:fmt"
import "ps:core"
import r3000 "ps:psx/cpu"

KE_NO_TIMER :: -150
KE_ILLEGAL_TIMERID :: -151
KE_ILLEGAL_SOURCE :: -152
KE_ILLEGAL_PRESCALE :: -153
KE_TIMER_BUSY :: -154
KE_TIMER_NOT_SETUP :: -155
KE_TIMER_NOT_INUSE :: -156
KE_ILLEGAL_MODE :: -405

TIMR_N :: 6
// Sources, as AllocHardTimer and SetupHardTimer take them.
TIMR_SYSCLOCK :: 1
TIMR_PIXEL :: 2
TIMR_HLINE :: 4
TIMR_HOLD :: 8
// Mode bits: compare and overflow interrupts, which a running mode with
// either enables.
TIMR_CMP :: 0x58 // interrupt on compare, the counter restarting, repeated
TIMR_RESET :: 0x08 // the counter restarts at its compare
TIMR_INTR :: 0x30
// The most compare handlers one tick runs: a timer far behind its compares
// (the EE stalled, a load ran) skips the rest.
TIMR_INTR_MAX :: 16
// The most alarms set at once. Retail takes each from its heap, so only
// running out of it refuses one; no disc seen sets more than a few.
ALARM_N :: 32
// The soonest an alarm comes, in IOP cycles: retail's 100 microseconds
// (USec2SysClock(100)), which a shorter SetAlarm or handler v0 is raised to.
ALARM_MIN :: 100 * IOP_CLOCK / 1_000_000

// A timer as the hardware has it: its registers' base, the sources it
// counts, its width, the most its prescaler divides by.
@(private = "file")
Timr_Hw :: struct {
	base:     u32,
	sources:  u8,
	bits:     u8,
	prescale: u16,
}

@(private = "file")
TIMR_HW := [TIMR_N]Timr_Hw {
	{0xbf801100, TIMR_SYSCLOCK | TIMR_PIXEL | TIMR_HOLD, 16, 1},
	{0xbf801110, TIMR_SYSCLOCK | TIMR_HLINE | TIMR_HOLD, 16, 1},
	{0xbf801120, TIMR_SYSCLOCK, 16, 8},
	{0xbf801480, TIMR_SYSCLOCK | TIMR_HLINE, 32, 1},
	{0xbf801490, TIMR_SYSCLOCK, 32, 256},
	{0xbf8014a0, TIMR_SYSCLOCK, 32, 256},
}

// The order AllocHardTimer searches the timers in.
@(private = "file")
TIMR_ORDER := [TIMR_N]u32{2, 5, 4, 3, 0, 1}

Iop_Timer :: struct {
	use:     u8, // the allocations holding it
	cmp:     u16, // TIMR_CMP when a compare handler is set, else 0
	mode:    u32, // the running mode, 0 stopped
	setup:   u32, // SetupHardTimer's mode bits, 0 none
	compare: u32,
	handler: u32, // IOP addresses; handler 0 is none
	arg:     u32,
	scale:   u32, // IOP cycles per count: the prescale, 0 a source not timed
	due:     u64, // the IOP cycle of the next compare, while armed
	start:   u64, // the IOP cycle its counter was last 0, while running
	count:   u32, // its counter when it stopped
}

// A thbase alarm: SetAlarm's handler and argument, due at an IOP cycle.
Iop_Alarm :: struct {
	handler, arg: u32, // IOP addresses
	due:          u64,
	seq:          u32, // orders alarms due together: the earlier set runs first
}

Iop_Timr :: struct {
	t:      [TIMR_N]Iop_Timer,
	armed:  u8, // the timers whose compare handler fires: bit by index
	alarms: [ALARM_N]Iop_Alarm,
	nalarm: u32, // alarms[:nalarm] are set
	seq:    u32, // the next alarm's seq
}

// Emulated state, snapshotted (sif_snap) and reset with the loader.
iop_timr: Iop_Timr

// Function fno of timrman, as stdio_fn.
timrman_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2, a3 := r[4], r[5], r[6], r[7]
	switch fno {
	case 4: // AllocHardTimer(source, size, prescale): the timer's id
		if iop_sched.intr {return ke(KE_ILLEGAL_CONTEXT), true}
		for i in TIMR_ORDER {
			hw, t := TIMR_HW[i], &iop_timr.t[i]
			if t.use != 0 || u32(hw.sources) & a0 == 0 || u32(hw.bits) != a1 || u32(hw.prescale) < a2 {continue}
			// As retail: only marked in use, its registers and state as they were
			t.use = 1
			return tim_id(i), true
		}
		return ke(KE_NO_TIMER), true
	case 6: // FreeHardTimer(id): as retail, the whole id must name a timer,
		// KE_NO_TIMER when none or it is not in use; only its use count drops,
		// the timer left running as it was
		if iop_sched.intr {return ke(KE_ILLEGAL_CONTEXT), true}
		t := tim_find(a0)
		if t == nil || a0 != tim_id((a0 >> 28) - 1) || t.use == 0 {return ke(KE_NO_TIMER), true}
		t.use -= 1
		return KE_OK, true
	case 10: // GetTimerCounter(id): the counter's register, read as the id's base names it, no check
		i := (a0 >> 28) - 1
		if i >= TIMR_N {
			core.compat_unknown(.Iop_Call, core.compat_name("timrman"), fno, pc = r[31])
			return 0, true
		}
		return tim_count(i), true
	case 20: // SetTimerHandler(id, compare, handler, arg)
		t := tim_find(a0)
		if t == nil {return ke(KE_ILLEGAL_TIMERID), true}
		if t.mode != 0 {return ke(KE_TIMER_BUSY), true}
		t.compare, t.handler, t.arg = a1, a2, a3
		t.cmp = TIMR_CMP if a2 != 0 else 0
		return KE_OK, true
	case 22: // SetupHardTimer(id, source, mode, prescale)
		if iop_sched.intr {return ke(KE_ILLEGAL_CONTEXT), true}
		t := tim_find(a0)
		if t == nil {return ke(KE_ILLEGAL_TIMERID), true}
		if t.mode != 0 {return ke(KE_TIMER_BUSY), true}
		i := (a0 >> 28) - 1
		hw := TIMR_HW[i]
		t.setup, t.scale = 0, 0
		if a2 > 7 || a2 & 1 == 0 && a2 != 0 {return ke(KE_ILLEGAL_MODE), true}
		setup := 0x8000_0000 | a2
		switch a1 {
		case TIMR_PIXEL, TIMR_HLINE:
			if u32(hw.sources) & a1 == 0 {return ke(KE_ILLEGAL_SOURCE), true}
			setup |= 0x100
		case TIMR_SYSCLOCK:
			if u32(hw.prescale) < a3 {return ke(KE_ILLEGAL_PRESCALE), true}
			switch a3 {
			case 1:
			case 8: setup |= 0x200 if hw.bits == 16 else 0x2000
			case 16: setup |= 0x4000
			case 256: setup |= 0x6000
			case: return ke(KE_ILLEGAL_PRESCALE), true
			}
			if a2 == 0 {t.scale = a3}
		case:
			return ke(KE_ILLEGAL_SOURCE), true
		}
		t.setup = setup
		if t.scale == 0 {
			core.compat_unknown(.Iop_Timer, a1, sub = a2, pc = r[31])
			fmt.eprintfln("iop: timer %d counts source %d in mode %d, not timed here", i, a1, a2)
		}
		return KE_OK, true
	case 23: // StartHardTimer(id)
		t := tim_find(a0)
		if t == nil {return ke(KE_ILLEGAL_TIMERID), true}
		if t.mode != 0 {return ke(KE_TIMER_BUSY), true}
		if t.setup == 0 {return ke(KE_TIMER_NOT_SETUP), true}
		t.mode = t.setup | u32(t.cmp)
		t.start = r3000.state.cycles
		t.due = t.start + tim_period(a0, t.compare)
		tim_arm()
		iop_wake_set()
		return KE_OK, true
	case 24: // StopHardTimer(id)
		t := tim_find(a0)
		if t == nil {return ke(KE_ILLEGAL_TIMERID), true}
		if t.mode == 0 {return ke(KE_TIMER_NOT_INUSE), true}
		t.count = tim_count(u32(a0 >> 28) - 1)
		t.mode = 0
		tim_arm()
		return KE_OK, true
	}
	return 0, false
}

// Timer i's id: its number from 1 in the top 4 bits, its registers' base.
@(private = "file")
tim_id :: proc(i: u32) -> u32 {
	return (i + 1) << 28 | TIMR_HW[i].base >> 4
}

// The timer id `id` names by its top 4 bits, nil past the six. Retail reads
// nothing else of it.
@(private = "file")
tim_find :: proc(id: u32) -> ^Iop_Timer {
	i := (id >> 28) - 1
	return &iop_timr.t[i] if i < TIMR_N else nil
}

// The IOP cycles from a compare, or the start, to the next of timer `id`
// with compare value `compare`: a 16-bit timer's compare is its low 16 bits,
// and 0 comes round once the counter wraps.
@(private = "file")
tim_period :: proc(id, compare: u32) -> u64 {
	i := (id >> 28) - 1
	t := &iop_timr.t[i]
	c := u64(compare)
	if TIMR_HW[i].bits == 16 {c &= 0xffff}
	if c == 0 {c = 1 << TIMR_HW[i].bits}
	return c * u64(t.scale)
}

// Timer i's counter now: while it runs timed, its counts of `scale` cycles
// since its start, restarting at each compare when its mode says so, else
// wrapping at its width; stopped, or counting a source not timed here, the
// count it stopped at.
@(private = "file")
tim_count :: proc(i: u32) -> u32 {
	t := &iop_timr.t[i]
	if t.mode == 0 || t.scale == 0 {return t.count}
	n := (r3000.state.cycles - t.start) / u64(t.scale)
	wrap := u64(1) << TIMR_HW[i].bits
	if t.mode & TIMR_RESET != 0 {wrap = tim_period(tim_id(i), t.compare) / u64(t.scale)}
	return u32(n % wrap)
}

// Sets armed from the timers: running, timed, with a compare handler.
@(private = "file")
tim_arm :: proc() {
	iop_timr.armed = 0
	for t, i in iop_timr.t {
		if t.mode & TIMR_INTR != 0 && t.scale != 0 && t.handler != 0 {iop_timr.armed |= 1 << u32(i)}
	}
}

// When, in EE cycles, a timer's compare or an alarm is due next; max(u64)
// when none is.
tim_next_ee :: proc() -> u64 {
	t := max(u64)
	for a in iop_timr.alarms[:iop_timr.nalarm] {t = min(t, a.due * IOP_EE_RATIO)}
	if iop_timr.armed == 0 {return t}
	for x, i in iop_timr.t {
		if iop_timr.armed & (1 << u32(i)) != 0 {t = min(t, x.due * IOP_EE_RATIO)}
	}
	return t
}

// SetAlarm(clock, handler, arg): an alarm `clock`'s 64-bit count of IOP
// cycles from now, raised to ALARM_MIN in the guest's clock as retail
// does. KE_FOUND_HANDLER when handler and arg already have one.
alarm_set :: proc(clock, handler, arg: u32) -> u32 {
	x := &iop_timr
	for a in x.alarms[:x.nalarm] {
		if a.handler == handler && a.arg == arg {return ke(KE_FOUND_HANDLER)}
	}
	if x.nalarm == ALARM_N {return ke(KE_NO_MEMORY)}
	lo, hi := r32(clock), r32(clock + 4)
	if hi == 0 && lo < ALARM_MIN {
		lo = ALARM_MIN
		w32(clock, lo)
	}
	alarm_add({handler = handler, arg = arg, due = r3000.state.cycles + (u64(hi) << 32 | u64(lo))})
	iop_wake_set()
	return KE_OK
}

// CancelAlarm(handler, arg): the alarm of handler and arg ended before it
// comes; KE_NOTFOUND_HANDLER when none is set. An alarm whose handler is
// running is off its list, so its handler cannot cancel it: its v0 decides.
alarm_cancel :: proc(handler, arg: u32) -> u32 {
	x := &iop_timr
	for a, i in x.alarms[:x.nalarm] {
		if a.handler != handler || a.arg != arg {continue}
		alarm_remove(u32(i))
		iop_wake_set()
		return KE_OK
	}
	return ke(KE_NOTFOUND_HANDLER)
}

@(private = "file")
alarm_add :: proc(a: Iop_Alarm) {
	x := &iop_timr
	x.alarms[x.nalarm] = a
	x.alarms[x.nalarm].seq = x.seq
	x.nalarm += 1
	x.seq += 1
}

@(private = "file")
alarm_remove :: proc(i: u32) {
	x := &iop_timr
	x.nalarm -= 1
	x.alarms[i] = x.alarms[x.nalarm]
}

// Runs the alarms due by the IOP's clock, earliest first, at most
// TIMR_INTR_MAX; the rest run at the next tick. Each is off its list while
// its handler runs, as on retail, so the handler may set it again; its v0
// then puts it back. A handler stopped for waiting or a call the HLE lacks
// ends its alarm.
@(private = "file")
alarm_run :: proc() {
	x := &iop_timr
	now := r3000.state.cycles
	for _ in 0 ..< TIMR_INTR_MAX {
		first := -1
		for a, i in x.alarms[:x.nalarm] {
			if a.due > now {continue}
			b := x.alarms[first] if first >= 0 else Iop_Alarm{}
			if first < 0 || a.due < b.due || a.due == b.due && a.seq < b.seq {first = i}
		}
		if first < 0 {return}
		a := x.alarms[first]
		alarm_remove(u32(first))
		next: u32
		switch th_intr(a.handler, a.arg, 0) {
		case .None:
			next = iop_sched.intr_v0
		case .Blocked:
			core.compat_unknown(.Iop_Timer_Intr, a.handler, pc = a.handler)
			fmt.eprintfln("iop: alarm handler at %x blocked", a.handler)
		case .Call:
			fmt.eprintfln("iop: alarm handler at %x stopped", a.handler)
		}
		if next == 0 {continue}
		if x.nalarm == ALARM_N {
			// Retail's heap would take it; ALARM_N is this HLE's bound.
			fmt.eprintfln("iop: alarm handler at %x ended, its re-add finding all %d alarms set", a.handler, ALARM_N)
			continue
		}
		a.due += u64(max(next, ALARM_MIN))
		alarm_add(a)
	}
}

// Runs the compare handlers due by the IOP's clock, earliest first, at most
// TIMR_INTR_MAX; a timer still behind then has its missed compares dropped.
// Then the alarms due (alarm_run).
tim_intr_run :: proc() {
	tim_cmp_run()
	alarm_run()
}

@(private = "file")
tim_cmp_run :: proc() {
	if iop_timr.armed == 0 {return}
	now := r3000.state.cycles
	for _ in 0 ..< TIMR_INTR_MAX {
		first := -1
		for t, i in iop_timr.t {
			if iop_timr.armed & (1 << u32(i)) == 0 || t.due > now {continue}
			if first < 0 || t.due < iop_timr.t[first].due {first = i}
		}
		if first < 0 {return}
		tim_intr(u32(first))
	}
	for &t, i in iop_timr.t {
		if iop_timr.armed & (1 << u32(i)) == 0 || t.due > now {continue}
		p := tim_period(tim_id(u32(i)), t.compare)
		t.due += (now - t.due) / p * p + p
	}
}

// Runs timer i's compare handler with its argument. Its v0 is the next
// compare; 0, or a handler stopped for waiting or a call the HLE lacks,
// stops the timer. A handler that stops and restarts its own timer and
// returns nonzero has v0's period added to the restart's due; retail would
// count v0 alone from the restart.
@(private = "file")
tim_intr :: proc(i: u32) {
	t := &iop_timr.t[i]
	handler := t.handler
	next: u32
	switch th_intr(handler, t.arg, 0) {
	case .None:
		next = iop_sched.intr_v0
	case .Blocked:
		core.compat_unknown(.Iop_Timer_Intr, handler, pc = handler)
		fmt.eprintfln("iop: timer handler at %x blocked", handler)
	case .Call:
		fmt.eprintfln("iop: timer handler at %x stopped", handler)
	}
	if t.mode == 0 { // the handler stopped it
		tim_arm()
		return
	}
	if next == 0 {
		t.count = tim_count(i)
		t.mode = 0
		tim_arm()
		return
	}
	t.compare = next
	// A counter that restarts at the compare was 0 there; one that runs
	// free to its width keeps its start.
	if t.mode & TIMR_RESET != 0 {t.start = t.due}
	t.due += tim_period(tim_id(i), next)
}

// After a failed load: puts back, as it was when the load began (`saved`),
// each timer the load allocated, or left with its handler or argument in
// `freed`, the memory its undo frees. An alarm whose handler or argument is
// in `freed` ends; one the load set with both outside it stays.
tim_undo :: proc(saved: Iop_Timr, freed: []Sys_Block) {
	for &t, i in iop_timr.t {
		if t.use > saved.t[i].use || sys_in(freed, t.handler) || sys_in(freed, t.arg) {t = saved.t[i]}
	}
	tim_arm()
	for i := iop_timr.nalarm; i > 0; i -= 1 {
		a := iop_timr.alarms[i - 1]
		if sys_in(freed, a.handler) || sys_in(freed, a.arg) {alarm_remove(i - 1)}
	}
}
