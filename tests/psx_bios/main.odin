// The BIOS HLE's events, root counter and IRQ delivery, and the B(15h) pad
// word, on a bare machine: hand-built handler chains and guest functions
// stand in for the game, and package psx (which brings the platform layer)
// is not linked.
//
//   DeliverEvent fires an enabled event only on an exact class and spec;
//   mode 0x2000 marks it ready, mode 0x1000 calls its function if nonzero.
//   WaitEvent returns 0 when disabled, takes a ready event at once, and
//   otherwise runs time forward until the event is delivered, through
//   every device event on its due cycle.
//   deliver_irq runs the chains, the kernel's root counter handlers at the
//   tail of chain 1 and its IRQ event handler at the tail of chain 3;
//   ChangeClearRCnt's flag and ReturnFromException end the walk early,
//   skipping the HookEntryInt handler; an acknowledged counter ends it
//   with the other counters still pending. SetDefaultExitFromException
//   ends the exception after the walk without the hook. WaitEvent with
//   interrupts blocked gives up instead of hanging. syscall 3 returns 1;
//   higher numbers deliver class 0xf0000010 spec 0x4000. UnDeliverEvent
//   takes a delivery back.
//   The kernel layout games read and patch: the exception vector (at 0x00
//   too), the C0 and B0 tables (every entry callable but the B0 ones the
//   retail kernel leaves 0), and the pad driver's pointers and vblank
//   acknowledge, handed over by StartPAD and turned off by ChangeClearPad or
//   by zeroing its code. SysEnqIntRP of a queued element moves it to the
//   head; SysDeqIntRP returns the element it unlinks, or 0. CloseEvent,
//   EnableEvent and DisableEvent return 1 for any handle, InitPAD 1.
//   GetConf reads back the table sizes, or what SetConf set.
//   The memory card calls: card status, firstfile/nextfile patterns and the
//   DIRENTRY, and lseek and read on whole frames. The card images live in
//   memory only: their paths name a directory that does not exist.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import bios "ps:psx/bios"
import cpu "ps:psx/cpu"
import io "ps:psx/io"

@(private = "file")
failed: int

@(private = "file")
fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL psx_bios: ")
	fmt.eprintfln(format, ..args)
	failed += 1
}

@(private = "file")
check :: proc(what: string, got, want: u32) {
	if got != want {
		fail("%s = %#x, want %#x", what, got, want)
	}
}

// Guest functions.
@(private = "file")
FN_CALLBACK :: 0x80001000
@(private = "file")
FN_FIRST :: 0x80001100 // first(): returns 1
@(private = "file")
FN_SECOND :: 0x80001200 // second(): counts
@(private = "file")
FN_SECOND_RFE :: 0x80001300 // second(): ReturnFromException
@(private = "file")
FN_FIRST_LATE :: 0x80001400 // first() of a later chain: counts, returns 0
@(private = "file")
FN_HOOK :: 0x80001500 // the HookEntryInt handler: counts

// HookEntryInt jump buffer, and the setjmp return site it holds: a jal to
// FN_HOOK.
@(private = "file")
HOOK_BUF :: 0x2040
@(private = "file")
HOOK_SITE :: 0x80002080

// Chain elements {next, second, first, unused}.
@(private = "file")
ELEM_RFE :: 0x2000
@(private = "file")
ELEM_LATE :: 0x2010
@(private = "file")
ELEM_COUNT :: 0x2020

@(private = "file")
ELEM_NOP :: 0x2030

@(private = "file")
PAD_WORD :: 0x2100
@(private = "file")
PAD_BUF :: 0x2110

// GetConf's three words.
@(private = "file")
CONF_BUF :: 0x2200

// Card file name, DIRENTRY and read buffer.
@(private = "file")
CARD_NAME :: 0x6000
@(private = "file")
CARD_DIR :: 0x6100
@(private = "file")
CARD_BUF :: 0x6200

@(private = "file")
calls: struct {
	callback, second, late, hook: int,
}

// Vblanks until the waited-for event is delivered.
@(private = "file")
deliver_in: int

// Cycles at which the bystander and the delivering device events ran
// during a WaitEvent.
@(private = "file")
ran_at: [2]u64

@(private = "file")
b :: proc(fn: u32, args: ..u32) -> u32 {
	for a, k in args {
		cpu.state.r[4 + k] = a
	}
	bios.bios_b(fn)
	return cpu.state.r[2]
}

@(private = "file")
a :: proc(fn: u32, args: ..u32) -> u32 {
	for v, k in args {
		cpu.state.r[4 + k] = v
	}
	bios.bios_a(fn)
	return cpu.state.r[2]
}

@(private = "file")
c :: proc(fn: u32, args: ..u32) -> u32 {
	for a, k in args {
		cpu.state.r[4 + k] = a
	}
	bios.bios_c(fn)
	return cpu.state.r[2]
}

@(private = "file")
open :: proc(class, spec, mode: u32, func: u32 = 0) -> u32 {
	h := b(0x08, class, spec, mode, func)
	b(0x0c, h)
	return h
}

@(private = "file")
test :: proc(h: u32) -> u32 {
	return b(0x0b, h)
}

@(private = "file")
irq :: proc(n: u32) {
	io.irq_regs.stat = 1 << n
	io.irq_regs.mask = 1 << n
	bios.deliver_irq()
}

@(private = "file")
guest_string :: proc(s: string) -> u32 {
	for k in 0 ..< len(s) {
		cpu.w8(CARD_NAME + u32(k), s[k])
	}
	cpu.w8(CARD_NAME + u32(len(s)), 0)
	return CARD_NAME
}

// firstfile then nextfile until no match; the names found, in card order.
@(private = "file")
card_find :: proc(pattern: string) -> (names: [4]string, n: int) {
	r := b(0x42, guest_string(pattern), CARD_DIR)
	for r != 0 && n < len(names) {
		names[n] = strings.clone(cpu.mem_cstring(CARD_DIR), context.temp_allocator)
		n += 1
		r = b(0x43, CARD_DIR)
	}
	return
}

@(private = "file")
check_find :: proc(pattern: string, want: ..string) {
	names, n := card_find(pattern)
	if n != len(want) {
		fail("firstfile %q found %v, want %v", pattern, names[:n], want)
		return
	}
	for name, k in want {
		if names[k] != name {
			fail("firstfile %q found %v, want %v", pattern, names[:n], want)
			return
		}
	}
}

@(private = "file")
elem :: proc(a, next, second, first: u32) {
	cpu.w32(a, next)
	cpu.w32(a + 4, second)
	cpu.w32(a + 8, first)
}

main :: proc() {
	cpu.register_funcs(
		{
			{FN_CALLBACK, proc() {calls.callback += 1}},
			{FN_FIRST, proc() {cpu.state.r[2] = 1}},
			{FN_SECOND, proc() {calls.second += 1}},
			{FN_SECOND_RFE, proc() {bios.bios_b(0x17)}},
			{FN_FIRST_LATE, proc() {
					calls.late += 1
					cpu.state.r[2] = 0
				}},
			{FN_HOOK, proc() {calls.hook += 1}},
		},
	)
	io.deliver_irq = bios.deliver_irq
	bios.pad_game = proc() -> u16 {return 0x0101}

	// DeliverEvent matches class and spec exactly.
	ev := open(0xf4000001, 0x0004, 0x2000)
	bios.deliver_event(0xf4000001, 0x0104)
	check("TestEvent after a superset spec", test(ev), 0)
	bios.deliver_event(0xf4000001, 0x0004)
	check("TestEvent after the exact spec", test(ev), 1)
	spu := open(0xf0000009, 0x20, 0x2000)
	bios.deliver_event(0xf0000009, 0x21)
	check("TestEvent of a 0x20 event after 0x21", test(spu), 0)
	check("TestEvent again", test(ev), 0)
	b(0x0d, ev)
	bios.deliver_event(0xf4000001, 0x0004)
	check("TestEvent of a disabled event", test(ev), 0)

	// Mode 0x1000: the function runs and the event never becomes ready; with
	// no function nothing happens.
	cb := open(0xf0000011, 0x0100, 0x1000, FN_CALLBACK)
	nocb := open(0xf0000011, 0x0100, 0x1000)
	bios.deliver_event(0xf0000011, 0x0100)
	if calls.callback != 1 {
		fail("callback ran %d times, want 1", calls.callback)
	}
	check("TestEvent of a callback event", test(cb), 0)
	check("TestEvent of a callback event without a function", test(nocb), 0)

	// CloseEvent, EnableEvent and DisableEvent return 1 for any handle.
	check("CloseEvent", b(0x09, nocb), 1)
	check("CloseEvent of a closed event", b(0x09, nocb), 1)
	check("EnableEvent of a closed event", b(0x0c, nocb), 1)
	check("DisableEvent of a bad handle", b(0x0d, 0xf100ffff), 1)
	check("TestEvent of a closed event after EnableEvent", test(nocb), 0)

	// WaitEvent.
	check("WaitEvent of a disabled event", b(0x0a, ev), 0)
	b(0x0c, ev)
	bios.deliver_event(0xf4000001, 0x0004)
	check("WaitEvent of a ready event", b(0x0a, ev), 1)
	check("TestEvent after WaitEvent", test(ev), 0)
	io.events_init()
	io.event_handlers[.VBlank] = proc() {
		io.schedule_period(.VBlank, io.FRAME_CYCLES)
		deliver_in -= 1
		if deliver_in == 0 {
			bios.deliver_event(0xf4000001, 0x0004)
		}
	}
	// Interrupts enabled (IEc and IM2), as the game runs.
	cpu.cop0.sr = 0x401
	deliver_in = 3
	start := cpu.state.cycles
	check("WaitEvent until delivered", b(0x0a, ev), 1)
	if deliver_in != 0 || cpu.state.cycles - start < 3 * io.FRAME_CYCLES {
		fail("WaitEvent returned after %d cycles, %d vblanks early", cpu.state.cycles - start, deliver_in)
	}
	check("TestEvent after the wait", test(ev), 0)

	// The wait stops at every device event on its due cycle, runs the ones
	// that ready nothing, and returns on the cycle the event is delivered.
	io.event_handlers[.Dma] = proc() {ran_at[0] = cpu.state.cycles}
	io.event_handlers[.Spu] = proc() {
		ran_at[1] = cpu.state.cycles
		bios.deliver_event(0xf4000001, 0x0004)
	}
	start = cpu.state.cycles
	io.schedule(.Dma, 1000)
	io.schedule(.Spu, 2500)
	check("WaitEvent past another device event", b(0x0a, ev), 1)
	if ran_at != {start + 1000, start + 2500} || cpu.state.cycles != start + 2500 {
		fail("WaitEvent ran events at %v and returned at %d, from %d", ran_at, cpu.state.cycles, start)
	}
	io.event_handlers[.Dma] = nil
	io.event_handlers[.Spu] = nil

	// Root counters: vblank (counter 3) auto-acknowledges and ends the
	// exception while its ChangeClearRCnt flag is set.
	vb := open(0xf2000003, 2, 0x2000)
	vb_irq := open(0xf0000001, 0x1000, 0x2000)
	elem(ELEM_LATE, 0, FN_SECOND, FN_FIRST_LATE)
	c(0x02, 2, ELEM_LATE)
	cpu.w32(HOOK_BUF, HOOK_SITE)
	cpu.w32(HOOK_SITE, 0x0c000000 | (FN_HOOK & 0x0fffffff) >> 2)
	b(0x19, HOOK_BUF)
	check("ChangeClearRCnt(3, 1) old flag", c(0x0a, 3, 1), 0)
	irq(0)
	check("vblank root counter event", test(vb), 1)
	check("vblank IRQ acknowledged", io.irq_regs.stat, 0)
	if calls.late != 0 {
		fail("chain 2 ran %d times after the root counter ended the exception", calls.late)
	}
	check("vblank IRQ event after the exception ended", test(vb_irq), 0)
	if calls.hook != 0 {
		fail("hook ran after the root counter ended the exception")
	}
	check("ChangeClearRCnt(3, 0) old flag", c(0x0a, 3, 0), 1)
	irq(0)
	check("vblank root counter event, no acknowledge", test(vb), 1)
	check("vblank IRQ left pending", io.irq_regs.stat, 1)
	if calls.late != 1 {
		fail("chain 2 ran %d times, want 1", calls.late)
	}
	check("vblank IRQ event", test(vb_irq), 1)
	if calls.hook != 1 {
		fail("hook ran %d times, want 1", calls.hook)
	}

	// Ack-and-stop handles one counter per exception: vblank's handler runs
	// first and ends it, timer 0 waits for the next one.
	c(0x0a, 3, 1)
	c(0x0a, 0, 1)
	t0 := open(0xf2000000, 2, 0x2000)
	io.irq_regs.stat = 1 << 0 | 1 << 4
	io.irq_regs.mask = 1 << 0 | 1 << 4
	bios.deliver_irq()
	check("vblank event, first exception", test(vb), 1)
	check("timer 0 event, first exception", test(t0), 0)
	check("IRQs left after the first exception", io.irq_regs.stat, 1 << 4)
	bios.deliver_irq()
	check("timer 0 event, second exception", test(t0), 1)
	check("IRQs left after the second exception", io.irq_regs.stat, 0)
	if calls.hook != 1 || calls.late != 1 {
		fail("acknowledged counters ran the hook %d and chain 2 %d times, want 1 and 1", calls.hook, calls.late)
	}
	c(0x0a, 3, 0)

	// Timer 2 delivers its counter event and timer 1's IRQ class.
	c(0x0a, 2, 0)
	t2 := open(0xf2000002, 2, 0x2000)
	t1_irq := open(0xf0000006, 0x1000, 0x2000)
	irq(6)
	check("timer 2 root counter event", test(t2), 1)
	check("timer 2 IRQ event under timer 1's class", test(t1_irq), 1)

	// ReturnFromException in a chain 0 handler skips the later chains.
	elem(ELEM_RFE, 0, FN_SECOND_RFE, FN_FIRST)
	c(0x02, 0, ELEM_RFE)
	irq(0)
	if calls.late != 2 || calls.hook != 2 {
		fail("chain 2 (%d) or the hook (%d) ran after ReturnFromException in chain 0", calls.late, calls.hook)
	}
	check("vblank root counter event after ReturnFromException", test(vb), 0)
	c(0x03, 0, ELEM_RFE)
	elem(ELEM_COUNT, 0, FN_SECOND, FN_FIRST)
	c(0x02, 0, ELEM_COUNT)
	// Outside an interrupt ReturnFromException leaves the next one alone.
	b(0x17)
	irq(0)
	if calls.second != 1 || calls.late != 3 || calls.hook != 3 {
		fail("with no ReturnFromException: second ran %d times, chain 2 %d, hook %d, want 1, 3 and 3", calls.second, calls.late, calls.hook)
	}

	// SetDefaultExitFromException: the walk runs to the end, then the
	// exception ends without the hook; SetCustomExitFromException brings
	// it back.
	late, hook := calls.late, calls.hook
	b(0x18)
	irq(0)
	if calls.late != late + 1 || calls.hook != hook {
		fail("default exit: chain 2 ran %d times, hook %d, want 1 and 0", calls.late - late, calls.hook - hook)
	}
	b(0x19, HOOK_BUF)
	irq(0)
	if calls.hook != hook + 1 {
		fail("hook ran %d times after SetCustomExitFromException, want 1", calls.hook - hook)
	}

	// WaitEvent with interrupts blocked on an event only an IRQ readies
	// gives up instead of hanging.
	deliver_in = -1
	cpu.cop0.sr = 0
	start = cpu.state.cycles
	check("WaitEvent with interrupts blocked", b(0x0a, ev), 0)
	if cpu.state.cycles - start < io.CPU_HZ {
		fail("blocked WaitEvent gave up after %d cycles", cpu.state.cycles - start)
	}

	// B(15h) takes only the two 6-button types; B(16h) and every vblank
	// store the button word.
	check("B(15h) of an unknown type", b(0x15, 0x10000001, PAD_WORD), 0)
	check("B(15h) of a 6-button pad", b(0x15, 0x20000000, PAD_WORD), 2)
	bios.bios_pad_vblank()
	check("pad word after vblank", cpu.r32(PAD_WORD), 0xfffffefe)
	cpu.w32(PAD_WORD, 0)
	check("B(16h)", b(0x16), 0xfffffefe)
	check("pad word after B(16h)", cpu.r32(PAD_WORD), 0xfffffefe)

	// syscall: critical sections edit SR, 3 returns 1, higher numbers
	// deliver class 0xf0000010 spec 0x4000.
	cpu.bios_syscall = bios.bios_syscall
	cpu.bios_entry = bios.bios_entry
	cpu.irq_check = io.irq_check
	io.irq_regs = {}
	sr := cpu.cop0.sr
	cpu.cop0.sr = 0x401
	cpu.state.r[4] = 1
	cpu.syscall(0)
	check("EnterCriticalSection with interrupts on", cpu.state.r[2], 1)
	check("SR after EnterCriticalSection", cpu.cop0.sr & 0x401, 0)
	cpu.syscall(0)
	check("EnterCriticalSection with interrupts off", cpu.state.r[2], 0)
	cpu.state.r[4] = 2
	cpu.syscall(0)
	check("SR after ExitCriticalSection", cpu.cop0.sr & 0x401, 0x401)
	sys := open(0xf0000010, 0x4000, 0x2000)
	cpu.state.r[2] = 0
	cpu.state.r[4] = 3
	cpu.syscall(0)
	check("syscall 3", cpu.state.r[2], 1)
	check("syscall event after syscall 3", test(sys), 0)
	cpu.state.r[4] = 4
	cpu.syscall(0)
	check("syscall event after syscall 4", test(sys), 1)
	// UnDeliverEvent takes back a delivery of its class and spec only.
	b(0x07, 0xf0000010, 0x4000)
	b(0x20, 0xf0000010, 0x1000)
	b(0x20, 0xf0000011, 0x4000)
	check("event after UnDeliverEvent of another spec or class", test(sys), 1)
	b(0x07, 0xf0000010, 0x4000)
	b(0x20, 0xf0000010, 0x4000)
	check("event after UnDeliverEvent", test(sys), 0)
	b(0x07, 0xf0000010, 0x4000)
	check("event delivered after UnDeliverEvent", test(sys), 1)
	cpu.cop0.sr = sr

	// Kernel layout.
	bios.bios_init()
	check("exception vector halfword at 0x86", cpu.r32(0x84) >> 16, 0x275a)
	check("exception vector jr k0", cpu.r32(0x88), 0x03400008)
	check("exception vector nop", cpu.r32(0x8c), 0)
	for k in u32(0) ..< 4 {
		check("exception vector word at 0x00", cpu.r32(4 * k), cpu.r32(0x80 + 4 * k))
	}
	c0 := b(0x56)
	check("GetC0Table", c0, 0x674)
	check("C0(06h)", cpu.r32(c0 + 0x06 * 4), 0xc80)
	b0 := b(0x57)
	check("GetB0Table", b0, 0x874)
	pad := cpu.r32(b0 + 0x5b * 4)
	if pad < 0x500 || pad + 0x1990 > 0x10000 {
		fail("ChangeClearPad's code at %#x leaves no room in kernel RAM for its patches", pad)
	}
	// The other entries call the function they name, except the B0 ones
	// the retail kernel leaves 0.
	b0_unset := bit_set[0 ..< 0x60; u128] {
		0x11, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x5e, 0x5f,
	}
	for n in u32(0) ..< 0x60 {
		if (cpu.r32(b0 + 4 * n) == 0) != (int(n) in b0_unset) {
			fail("B0(%02xh) = %#x, want 0 exactly where the retail table is 0", n, cpu.r32(b0 + 4 * n))
		}
	}
	for n in u32(0) ..< 0x1e {
		if cpu.r32(c0 + 4 * n) == 0 {
			fail("C0(%02xh) is 0", n)
		}
	}
	cpu.call(cpu.r32(b0 + 0x56 * 4))
	check("GetC0Table through B0(56h)", cpu.state.r[2], 0x674)
	cpu.state.r[4], cpu.state.r[5] = 0, 1
	cpu.call(cpu.r32(c0 + 0x0a * 4))
	check("ChangeClearRCnt through C0(0Ah)", cpu.state.r[2], 1)

	// GetConf reports the HLE's table sizes, then what SetConf set.
	a(0x9d, CONF_BUF, CONF_BUF + 4, CONF_BUF + 8)
	check("GetConf events", cpu.r32(CONF_BUF), 32)
	check("GetConf threads", cpu.r32(CONF_BUF + 4), 16)
	check("GetConf stack", cpu.r32(CONF_BUF + 8), 0x801fff00)
	a(0x9c, 16, 4, 0x801ff000)
	a(0x9d, CONF_BUF, CONF_BUF + 4, CONF_BUF + 8)
	check("GetConf events after SetConf", cpu.r32(CONF_BUF), 16)
	check("GetConf threads after SetConf", cpu.r32(CONF_BUF + 4), 4)
	check("GetConf stack after SetConf", cpu.r32(CONF_BUF + 8), 0x801ff000)

	// libpad's pointers into the pad driver stop and restart pad reading.
	check("InitPAD", b(0x12, PAD_BUF, 0x22, 0, 0), 1)
	bios.bios_pad_vblank()
	check("pad buffer id after InitPAD", u32(cpu.r8(PAD_BUF + 1)), 0x41)
	cpu.call(pad + 0x894)
	cpu.w8(PAD_BUF + 1, 0)
	bios.bios_pad_vblank()
	check("pad buffer id with reading stopped", u32(cpu.r8(PAD_BUF + 1)), 0)
	cpu.call(pad + 0x884)
	bios.bios_pad_vblank()
	check("pad buffer id with reading restarted", u32(cpu.r8(PAD_BUF + 1)), 0x41)
	cpu.call(pad + 0x7a0)

	// StartPAD hands the vblank acknowledge to the pad driver's handler in
	// chain 2: the IRQ event no longer sees vblank, but the hook still runs.
	test(vb)
	test(vb_irq)
	io.irq_regs.stat = 1
	b(0x13)
	check("vblank pending after StartPAD", io.irq_regs.stat, 0)
	check("vblank unmasked by StartPAD", io.irq_regs.mask & 1, 1)
	hook = calls.hook
	irq(0)
	check("vblank root counter event with the pad started", test(vb), 1)
	check("vblank acknowledged by the pad driver", io.irq_regs.stat, 0)
	check("vblank IRQ event after the pad driver's acknowledge", test(vb_irq), 0)
	if calls.hook != hook + 1 {
		fail("hook ran %d times with the pad started, want 1", calls.hook - hook)
	}
	check("ChangeClearPad(0) old flag", b(0x5b, 0), 1)
	irq(0)
	check("vblank left pending by ChangeClearPad(0)", io.irq_regs.stat, 1)
	check("vblank IRQ event after ChangeClearPad(0)", test(vb_irq), 1)
	check("ChangeClearPad(1) old flag", b(0x5b, 1), 0)
	for k in u32(0) ..< 9 {
		cpu.w32(pad + 0x62c + 4 * k, 0)
	}
	irq(0)
	check("vblank left pending after _remove_ChgclrPAD", io.irq_regs.stat, 1)
	b(0x14)
	check("ChangeClearRCnt(3) flag after StopPAD", c(0x0a, 3, 0), 1)

	// StartCARD leaves a pending vblank alone.
	io.irq_regs.stat = 1
	io.irq_regs.mask = 0
	b(0x4b)
	check("vblank pending after StartCARD", io.irq_regs.stat, 1)
	check("vblank unmasked by StartCARD", io.irq_regs.mask & 1, 1)
	check("ChangeClearRCnt(3) flag after StartCARD", c(0x0a, 3, 0), 0)
	b(0x4c)

	// SysEnqIntRP of an element already queued moves it to the head.
	elem(ELEM_NOP, 0, 0, 0)
	c(0x02, 0, ELEM_NOP)
	c(0x02, 0, ELEM_COUNT)
	check("chain 0 head after re-enqueuing", bios.bios.chains[0], ELEM_COUNT)
	check("chain 0 second", cpu.r32(ELEM_COUNT), ELEM_NOP)
	check("chain 0 tail", cpu.r32(ELEM_NOP), 0)
	check("SysDeqIntRP of a queued element", c(0x03, 0, ELEM_NOP), ELEM_NOP)
	check("chain 0 after SysDeqIntRP", cpu.r32(ELEM_COUNT), 0)
	check("SysDeqIntRP of an element not queued", c(0x03, 0, ELEM_NOP), 0)
	check("SysDeqIntRP of the head", c(0x03, 0, ELEM_COUNT), ELEM_COUNT)
	check("chain 0 empty", bios.bios.chains[0], 0)

	// Memory cards.
	bios.card_files = {"/psx-bios-test-no-such-dir/1.mcd", "/psx-bios-test-no-such-dir/2.mcd"}
	if !bios.memcard_init() {
		fail("memcard_init with missing images")
	}
	save: [300]u8
	for &x, k in save {
		x = u8(k)
	}
	// Saving the image fails; the card in memory still holds the files.
	bios.card_write_file(bios.CARD_SLOT_1, "BASLUS-00001AB", save[:])
	bios.card_write_file(bios.CARD_SLOT_1, "BASLUS-00001CD", save[:])
	bios.card_write_file(bios.CARD_SLOT_1, "OTHER", save[:])
	check("_card_status", b(0x5c, 0), 1)
	check("_card_wait", b(0x5d, 0), 1)
	check_find("bu00:BASLUS*", "BASLUS-00001AB", "BASLUS-00001CD")
	check_find("bu00:", "BASLUS-00001AB", "BASLUS-00001CD", "OTHER")
	check_find("bu00:*", "BASLUS-00001AB", "BASLUS-00001CD", "OTHER")
	check_find("bu00:BASLUS-00001?D", "BASLUS-00001CD")
	check_find("bu00:OTHER??", "OTHER")
	check_find("bu00:BASLUS")
	check_find("bu10:*")
	b(0x42, guest_string("bu00:BASLUS-00001CD"), CARD_DIR)
	check("DIRENTRY attr", cpu.r32(CARD_DIR + 0x14), 0x50)
	check("DIRENTRY size", cpu.r32(CARD_DIR + 0x18), 0x2000)
	check("DIRENTRY head sector", cpu.r32(CARD_DIR + 0x20), 2 * 0x40)

	fd := b(0x32, guest_string("bu00:BASLUS-00001AB"), 1)
	check("read at 0", b(0x34, fd, CARD_BUF, 0x100), 0x100)
	check("byte 0xff read", u32(cpu.r8(CARD_BUF + 0xff)), 0xff)
	check("lseek SEEK_SET", b(0x33, fd, 0x40, 0), 0x40)
	check("read at a position inside a frame", b(0x34, fd, CARD_BUF, 0x80), 0xffffffff)
	check("lseek SEEK_CUR", b(0x33, fd, 0x40, 1), 0x80)
	check("lseek SEEK_END", b(0x33, fd, 0, 2), 0x80)
	check("lseek of an unknown whence", b(0x33, fd, 0, 3), 0xffffffff)
	check("read of a frame and a half", b(0x34, fd, CARD_BUF, 0xc0), 0x80)
	check("first byte read at 0x80", u32(cpu.r8(CARD_BUF)), 0x80)
	check("position after the read", b(0x33, fd, 0, 1), 0x100)
	b(0x33, fd, 0x2000, 0)
	check("read at the end of the file", b(0x34, fd, CARD_BUF, 0x80), 0xffffffff)
	check("close", b(0x36, fd), fd)

	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok psx_bios: event matching, WaitEvent, root counter and IRQ events, ReturnFromException, B(15h)/B(16h), kernel layout, pad driver, memory card")
}
