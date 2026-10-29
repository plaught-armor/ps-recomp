// Root counter 2 at /8 with its IRQ at target, run on every target in CI:
// with run_events reached late by seeded amounts, as recompiled code reaches
// it, the counter and its fires stay on the ideal cycles / (8 * clock_mul)
// with no drift, at clock_mul 1 and 2. The counter shows target for a tick
// before a reset (a period of target+1); without reset it counts on through
// 0xffff and reaches target once a wrap. The overflow IRQ comes when the
// counter shows 0xffff, so never under a reset at a lower target.
package main

import "core:fmt"
import "core:os"
import cpu "ps:psx/cpu"
import io "ps:psx/io"

@(private = "file")
failed: int

@(private = "file")
fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL psx_timer: ")
	fmt.eprintfln(format, ..args)
	failed += 1
	if failed > 20 {
		os.exit(1)
	}
}

@(private = "file")
seed: u32 = 0x9e3779b9

@(private = "file")
next :: proc() -> u32 {
	seed ~= seed << 13
	seed ~= seed >> 17
	seed ~= seed << 5
	return seed
}

@(private = "file")
fires: u64

STEPS :: 200_000

// /8 (source 2), repeat, with reset at target (0x08), IRQ at target (0x10)
// and at overflow (0x20) in turn. hits: the counter values an IRQ comes
// at (0 for none); flags: the mode bits 11-12 they set.
@(rodata, private = "file")
MODES := [?]struct {
	mode, target: u32,
	period:       u64,
	hits:         [2]u64,
	flags:        u32,
}{
	{0x258, 1000, 1001, {1000, 0}, 0x800},
	{0x250, 1000, 0x10000, {1000, 0}, 0x800},
	{0x268, 1000, 1001, {0, 0}, 0},
	{0x260, 1000, 0x10000, {0xffff, 0}, 0x1000},
	{0x270, 1000, 0x10000, {1000, 0xffff}, 0x1800},
	{0x278, 1000, 1001, {1000, 0}, 0x800},
	{0x278, 0xffff, 0x10000, {0xffff, 0}, 0x1800},
}

main :: proc() {
	io.deliver_irq = proc() {}
	io.event_handlers[.Timer2] = proc() {
		fires += 1
		io.timer2_event()
	}
	checks := 0
	for m in MODES {for mul in u64(1) ..= 2 {
		for &e in io.events {e = io.EVENT_OFF}
		cpu.next_event = io.EVENT_OFF
		io.irq_regs = {}
		io.clock_mul = mul
		io.timers_init()
		cpu.state.cycles = 12345
		io.timer_write(2, 8, m.target)
		io.timer_write(2, 4, m.mode)
		start := cpu.state.cycles
		fires = 0
		flags: u32
		step := 8 * mul
		for _ in 0 ..< STEPS {
			// Mostly short runs between event checks, some past a whole period.
			n := next()
			cpu.state.cycles += u64(n % 64 + 1) if n & 0x300 != 0 else u64(n % 24_000)
			if cpu.state.cycles >= cpu.next_event {
				io.run_events()
				flags |= io.timer_read(2, 4) & 0x1800
			}
			ticks := (cpu.state.cycles - start) / step
			want := u32(ticks % m.period)
			want_fires: u64
			for v in m.hits {
				if v != 0 && ticks >= v {
					want_fires += (ticks - v) / m.period + 1
				}
			}
			if got := io.timer_read(2, 0); got != want {
				fail("mode %x target %x clock %d at tick %d: counter %d, want %d", m.mode, m.target, mul, ticks, got, want)
			}
			if fires != want_fires {
				fail("mode %x target %x clock %d at tick %d: %d fires, want %d", m.mode, m.target, mul, ticks, fires, want_fires)
			}
			checks += 1
		}
		if flags != m.flags {
			fail("mode %x target %x clock %d: flags %x, want %x", m.mode, m.target, mul, flags, m.flags)
		}
	}}
	if failed != 0 {
		os.exit(1)
	}
	fmt.printfln("ok psx_timer: %d checks", checks)
}
