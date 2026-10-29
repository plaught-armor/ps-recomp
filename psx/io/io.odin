// Event scheduler, interrupt controller, root counters and the DMA
// controller. The register dispatch is in io_bus.odin.
package psx_io

import "core:fmt"
import "core:strconv"

import "ps:core"
import cpu "../cpu"

// Handler in package bios, set by package psx at init.
deliver_irq: proc()

// True between checkpoint_save and checkpoint_restore: run_events holds every
// event back.
events_frozen: bool

// True in a forked preload child (preload.odin).
preload_child: bool

// ---------------------------------------------------------------- timing

CPU_HZ :: 33_868_800
FRAME_CYCLES :: CPU_HZ / 60
SCANLINES :: 263
LINE_CYCLES :: FRAME_CYCLES / SCANLINES

Event :: enum {
	VBlank,
	Cdrom,
	Cdrom_Read,
	Dma,
	Spu,
	Sio,
	Timer0,
	Timer1,
	Timer2,
}

EVENT_OFF :: max(u64)

// CPU overclock: hardware delays and timer ticks last this many times their
// cycles, so the CPU runs that much more code per vblank while sound, disc
// and timers keep their real-time rates. 1 is the console's own speed;
// CLOCK=n sets another (testing only).
clock_mul: u64 = 1

// Change clock_mul mid-run (autoplay's `clock`): the timers count on from
// their value now at the new rate. Events already scheduled keep their due
// cycle; periodic ones take the new rate from their next period.
clock_set :: proc(mul: u64) {
	for n in 0 ..< len(timers) {
		timers[n].value = timer_value(n)
		timers[n].base = cpu.state.cycles
	}
	clock_mul = mul
	for n in 0 ..< len(timers) {
		timer_reschedule(n, cpu.state.cycles)
	}
}

events: [Event]u64

// The cycle the event being handled was due at (run_events).
@(private)
event_due: u64

schedule :: proc(e: Event, delay: u64) {
	events[e] = cpu.state.cycles + delay * clock_mul
	cpu.next_event = min(cpu.next_event, events[e])
}

// Schedule the event being handled again `period` cycles after it was due,
// not after it ran: recompiled code reaches run_events some way past the
// due cycle, and counting from there loses that much every period. A
// period already over runs again in the same run_events.
schedule_period :: proc(e: Event, period: u64) {
	events[e] = event_due + period * clock_mul
	cpu.next_event = min(cpu.next_event, events[e])
}

unschedule :: proc(e: Event) {
	events[e] = EVENT_OFF
}

// What each event does, set by package psx.
event_handlers: [Event]proc()

// Called by recompiled code when cpu.state.cycles reaches next_event.
run_events :: proc() {
	if events_frozen {
		// Inside a frozen-time pass; checkpoint_restore reschedules.
		cpu.next_event = EVENT_OFF
		return
	}
	for {
		due := false
		for e in Event {
			if events[e] <= cpu.state.cycles {
				if .Event in core.trace.active {
					core.tracef(.Event, "%v (due %d)", e, events[e])
				}
				event_due = events[e]
				events[e] = EVENT_OFF
				event_handlers[e]()
				due = true
			}
		}
		if !due {
			break
		}
	}
	cpu.next_event = EVENT_OFF
	for t in events {
		cpu.next_event = min(cpu.next_event, t)
	}
	irq_check()
}

events_init :: proc() {
	for &t in events {
		t = EVENT_OFF
	}
	cpu.next_event = EVENT_OFF
	if v, ok := strconv.parse_u64(core.env("CLOCK")); ok && v >= 1 {
		clock_mul = v
	}
	schedule(.VBlank, FRAME_CYCLES)
}

// ---------------------------------------------------------------- interrupts

Irq :: enum u32 {
	VBlank = 0,
	Gpu    = 1,
	Cdrom  = 2,
	Dma    = 3,
	Timer0 = 4,
	Timer1 = 5,
	Timer2 = 6,
	Sio0   = 7,
	Sio    = 8,
	Spu    = 9,
}

irq_regs: struct {
	stat: u32,
	mask: u32,
	// Nesting guard: hardware interrupts are not delivered while one runs.
	in_handler: bool,
}

irq_raise :: proc(i: Irq) {
	if .Irq in core.trace.active {
		core.tracef(.Irq, "raise %v stat=%x mask=%x sr=%x", i, irq_regs.stat, irq_regs.mask, cpu.cop0.sr)
	}
	irq_regs.stat |= 1 << u32(i)
	if cpu.next_event > cpu.state.cycles {
		// Delivered at the next event check so the raising device finishes
		// first.
		cpu.next_event = cpu.state.cycles
	}
}

irq_check :: proc() {
	if irq_regs.stat & irq_regs.mask == 0 || irq_regs.in_handler {
		return
	}
	if cpu.cop0.sr & 0x401 != 0x401 {
		return
	}
	deliver_irq()
}

// --------------------------------------------------------------- root counters

Timer :: struct {
	mode:   u32,
	target: u32,
	// Counter value at `base` cycles, and cycles per tick.
	value:  u32,
	base:   u64,
	div:    u64,
}

@(private)
timers: [3]Timer

@(private)
timer_rate :: proc(n: int) -> u64 {
	src := (timers[n].mode >> 8) & 3
	switch n {
	case 0:
		return 1 // dot clock approximated by system clock
	case 1:
		if src & 1 != 0 {
			return LINE_CYCLES
		}
	case 2:
		if src >= 2 {
			return 8
		}
	}
	return 1
}

@(private)
timer_value :: proc(n: int) -> u32 {
	return timer_value_at(n, cpu.state.cycles)
}

// The counter value at cycle `at`, not before base.
@(private)
timer_value_at :: proc(n: int, at: u64) -> u32 {
	t := &timers[n]
	ticks := (at - t.base) / (t.div * clock_mul)
	v := u64(t.value) + ticks
	if t.mode & 0x08 != 0 && t.target != 0 {
		v %= u64(t.target) + 1
	} else {
		v &= 0xffff
	}
	return u32(v)
}

// Schedule counter n's next fire from cycle `now`.
@(private)
timer_reschedule :: proc(n: int, now: u64) {
	t := &timers[n]
	e := Event(int(Event.Timer0) + n)
	unschedule(e)
	if t.mode & 0x30 == 0 {
		return
	}
	limit := u64(0x10000)
	if t.mode & 0x10 != 0 && t.target != 0 {
		limit = u64(t.target)
	}
	// Due on a tick boundary counted from base: the part of a tick already
	// run since the last boundary counts, or a /8 counter would lose it at
	// every reschedule.
	step := t.div * clock_mul
	cur := u64(timer_value_at(n, now))
	ticks := limit > cur ? limit - cur : limit
	events[e] = now - (now - t.base) % step + ticks * step
	cpu.next_event = min(cpu.next_event, events[e])
}

@(private)
timer_fire :: proc(n: int) {
	// From the cycle the target or overflow was due, not the one
	// run_events reached it at: counting from there would put the counter
	// behind by that lateness at every fire, more the more often code runs
	// long between event checks.
	t := &timers[n]
	t.value = timer_value_at(n, event_due)
	t.base = event_due
	if t.mode & 0x08 != 0 && t.mode & 0x10 != 0 {
		t.value = 0
	}
	t.mode |= 0x800 if t.mode & 0x10 != 0 else 0x1000
	if .Timer in core.trace.active {
		core.tracef(.Timer, "timer%d fire mode=%x target=%x", n, t.mode, t.target)
	}
	irq_raise(Irq(u32(Irq.Timer0) + u32(n)))
	// From the due cycle too: a fire already over runs in the same
	// run_events, so a long run between checks misses none.
	timer_reschedule(n, event_due)
}

timer0_event :: proc() {timer_fire(0)}
timer1_event :: proc() {timer_fire(1)}
timer2_event :: proc() {timer_fire(2)}

timers_vblank :: proc() {}

timers_init :: proc() {
	for &t in timers {
		t = {div = 1}
	}
}

timer_read :: proc(n: int, reg: u32) -> u32 {
	switch reg {
	case 0:
		return timer_value(n)
	case 4:
		m := timers[n].mode
		timers[n].mode &= ~u32(0x1800)
		return m
	case 8:
		return timers[n].target
	}
	return 0
}

timer_write :: proc(n: int, reg, v: u32) {
	t := &timers[n]
	if .Timer in core.trace.active {
		core.tracef(.Timer, "timer%d write reg%d <- %x", n, reg, v)
	}
	switch reg {
	case 0:
		t.value = v & 0xffff
		t.base = cpu.state.cycles
	case 4:
		t.mode = (v & 0x3ff) | 0x400
		t.value = 0
		t.base = cpu.state.cycles
		t.div = timer_rate(n)
	case 8:
		t.target = v & 0xffff
	}
	timer_reschedule(n, cpu.state.cycles)
}

// ---------------------------------------------------------------- DMA

Dma_Channel :: struct {
	madr, bcr, chcr: u32,
}

// Each channel's transfer, set by package psx: false when it completes
// later (dma_finish).
dma_channels: [7]proc(c: ^Dma_Channel) -> bool

dma: struct {
	ch:      [7]Dma_Channel,
	dpcr:    u32,
	dicr:    u32,
	// Channels whose completion interrupt is pending delivery.
	pending: u32,
}

dma_init :: proc() {
	dma.dpcr = 0x07654321
}

dma_read :: proc(off: u32) -> u32 {
	if off < 0x70 {
		c := &dma.ch[off >> 4]
		switch off & 0xf {
		case 0:
			return c.madr
		case 4:
			return c.bcr
		case 8:
			return c.chcr
		}
		return 0
	}
	switch off {
	case 0x70:
		return dma.dpcr
	case 0x74:
		return dma.dicr
	}
	return 0
}

@(private)
dma_update_master :: proc() {
	d := dma.dicr
	prev := d & 0x80000000
	flag := (d & 0x8000) != 0 || ((d & 0x800000) != 0 && ((d >> 24) & (d >> 16) & 0x7f) != 0)
	dma.dicr = (d & 0x7fffffff) | (flag ? 0x80000000 : 0)
	if flag && prev == 0 {
		irq_raise(.Dma)
	}
}

// Byte and halfword stores (libcd sets DICR enables with sb) update only
// their lanes. DICR flags read back as 0 so untouched lanes ack nothing.
dma_write_sized :: proc(off, v: u32, size: u32) {
	if size == 4 {
		dma_write(off, v)
		return
	}
	base := off & ~u32(3)
	shift := (off & 3) * 8
	lanes := (size == 2 ? u32(0xffff) : u32(0xff)) << shift
	cur := dma_read(base)
	if base == 0x74 {
		cur &= ~u32(0x7f000000)
	}
	dma_write(base, (cur & ~lanes) | ((v << shift) & lanes))
}

@(private)
dma_write :: proc(off, v: u32) {
	if off < 0x70 {
		n := off >> 4
		c := &dma.ch[n]
		switch off & 0xf {
		case 0:
			c.madr = v & 0xffffff
		case 4:
			c.bcr = v
		case 8:
			c.chcr = v
			if v & 0x01000000 != 0 && dma.dpcr & (8 << (n * 4)) != 0 {
				dma_run(n)
			}
		}
		return
	}
	switch off {
	case 0x70:
		dma.dpcr = v
	case 0x74:
		// Bits 24-30 acknowledge by writing 1.
		dma.dicr = (dma.dicr & 0x7f000000 & ~(v & 0x7f000000)) | (v & 0x00ff803f)
		dma_update_master()
	}
}

@(private)
dma_run :: proc(n: u32) {
	c := &dma.ch[n]
	if .Dma in core.trace.active {
		core.tracef(.Dma, "ch%d start madr=%x bcr=%x chcr=%x", n, c.madr, c.bcr, c.chcr)
	}
	h := dma_channels[n]
	if h == nil {
		fmt.eprintfln("dma: channel %d not emulated", n)
	} else if !h(c) {
		// Completes later (MDEC output: once enough is produced).
		return
	}
	dma_finish(n)
}

// Complete channel n: clear its busy bit and raise its interrupt shortly after.
dma_finish :: proc(n: u32) {
	if .Dma in core.trace.active {
		core.tracef(.Dma, "ch%d finish", n)
	}
	dma.ch[n].chcr &= ~u32(0x11000000)
	dma.pending |= 1 << n
	schedule(.Dma, 64)
}

dma_event :: proc() {
	p := dma.pending
	dma.pending = 0
	for n in u32(0) ..< 7 {
		if p & (1 << n) != 0 && dma.dicr & (1 << (16 + n)) != 0 {
			dma.dicr |= 1 << (24 + n)
		}
	}
	dma_update_master()
}

dma_words :: proc(c: ^Dma_Channel) -> u32 {
	if (c.chcr >> 9) & 3 == 0 {
		n := c.bcr & 0xffff
		return n == 0 ? 0x10000 : n
	}
	return (c.bcr & 0xffff) * (c.bcr >> 16)
}

