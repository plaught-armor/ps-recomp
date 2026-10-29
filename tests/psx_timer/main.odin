// Root counter 2 at /8 in reset-at-target mode with its IRQ, run on every
// target in CI: with run_events reached late by seeded amounts, as
// recompiled code reaches it, the counter and its fires stay on the ideal
// cycles / (8 * clock_mul) with no drift, at clock_mul 1 and 2.
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

TARGET :: 1000
// /8 (source 2), reset at target, IRQ at target, repeat.
MODE :: 0x258
STEPS :: 200_000

main :: proc() {
	io.deliver_irq = proc() {}
	io.event_handlers[.Timer2] = proc() {
		fires += 1
		io.timer2_event()
	}
	checks := 0
	for mul in u64(1) ..= 2 {
		for &e in io.events {e = io.EVENT_OFF}
		cpu.next_event = io.EVENT_OFF
		io.irq_regs = {}
		io.clock_mul = mul
		io.timers_init()
		cpu.state.cycles = 12345
		io.timer_write(2, 8, TARGET)
		io.timer_write(2, 4, MODE)
		start := cpu.state.cycles
		fires = 0
		step := 8 * mul
		for _ in 0 ..< STEPS {
			// Mostly short runs between event checks, some past a whole period.
			n := next()
			cpu.state.cycles += u64(n % 64 + 1) if n & 0x300 != 0 else u64(n % (3 * TARGET * 8))
			if cpu.state.cycles >= cpu.next_event {
				io.run_events()
			}
			ticks := (cpu.state.cycles - start) / step
			want := u32(ticks % TARGET)
			if got := io.timer_read(2, 0); got != want {
				fail("clock %d at tick %d: counter %d, want %d", mul, ticks, got, want)
			}
			if fires != ticks / TARGET {
				fail("clock %d at tick %d: %d fires, want %d", mul, ticks, fires, ticks / TARGET)
			}
			checks += 1
		}
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.printfln("ok psx_timer: %d checks", checks)
}
