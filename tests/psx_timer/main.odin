// Root counters, run on every target in CI. Counter 2 at /8 and counter 1
// on hblank (a line: a fraction of cycles, NTSC and PAL), with their IRQ at
// target: with run_events reached late by seeded amounts, as recompiled code
// reaches it, the counter and its fires stay on the ideal cycles / (step *
// clock_mul) with no drift, at clock_mul 1 and 2. The counter shows target
// for a tick before a reset (a period of target+1); without reset it counts
// on through 0xffff and reaches target once a wrap. The overflow IRQ comes
// when the counter shows 0xffff, so never under a reset at a lower target.
// Vblank fields, progressive and interlaced, NTSC and PAL, sum to the exact
// rational time of their lines, and a switch between NTSC and PAL carries
// the remainder and keeps an hblank counter's count.
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

// The counters and clocks run: counter 2 at /8 (source 2), counter 1 on
// the NTSC and the PAL line (source 1).
@(rodata, private = "file")
CLOCKS := [?]struct {
	n:    int,
	src:  u32,
	line: io.Period,
	step: io.Period,
}{
	{2, 0x200, io.LINE_NTSC, {8, 1}},
	{1, 0x100, io.LINE_NTSC, io.LINE_NTSC},
	{1, 0x100, io.LINE_PAL, io.LINE_PAL},
}

// Ticks of `step` in `cycles` at clock_mul `mul`.
@(private = "file")
ticks_in :: proc(cycles: u64, step: io.Period, mul: u64) -> u64 {
	return u64(u128(cycles) * u128(step.den) / u128(step.num * mul))
}

main :: proc() {
	io.deliver_irq = proc() {}
	io.event_handlers[.Timer1] = proc() {
		fires += 1
		io.timer1_event()
	}
	io.event_handlers[.Timer2] = proc() {
		fires += 1
		io.timer2_event()
	}
	checks := 0
	for c in CLOCKS {for m in MODES {for mul in u64(1) ..= 2 {
		mode := m.mode &~ 0x300 | c.src
		for &e in io.events {e = io.EVENT_OFF}
		cpu.next_event = io.EVENT_OFF
		io.irq_regs = {}
		io.clock_mul = mul
		io.video = io.Video{line = c.line}
		io.timers_init()
		cpu.state.cycles = 12345
		io.timer_write(c.n, 8, m.target)
		io.timer_write(c.n, 4, mode)
		start := cpu.state.cycles
		fires = 0
		flags: u32
		// Hblank ticks come every 2153 cycles, not 8: longer runs, as many
		// wraps.
		scale := u64(1) if c.n == 2 else 256
		for _ in 0 ..< STEPS {
			// Mostly short runs between event checks, some past a whole period.
			n := next()
			cpu.state.cycles += scale * (u64(n % 64 + 1) if n & 0x300 != 0 else u64(n % 24_000))
			if cpu.state.cycles >= cpu.next_event {
				io.run_events()
				flags |= io.timer_read(c.n, 4) & 0x1800
			}
			ticks := ticks_in(cpu.state.cycles - start, c.step, mul)
			want := u32(ticks % m.period)
			want_fires: u64
			for v in m.hits {
				if v != 0 && ticks >= v {
					want_fires += (ticks - v) / m.period + 1
				}
			}
			if got := io.timer_read(c.n, 0); got != want {
				fail("counter %d mode %x target %x clock %d at tick %d: counter %d, want %d", c.n, mode, m.target, mul, ticks, got, want)
			}
			if fires != want_fires {
				fail("counter %d mode %x target %x clock %d at tick %d: %d fires, want %d", c.n, mode, m.target, mul, ticks, fires, want_fires)
			}
			checks += 1
		}
		if flags != m.flags {
			fail("counter %d mode %x target %x clock %d: flags %x, want %x", c.n, mode, m.target, mul, flags, m.flags)
		}
	}}}
	io.clock_mul = 1
	checks += fields()
	checks += switch_line()
	checks += vsync_lock()
	if failed != 0 {
		os.exit(1)
	}
	fmt.printfln("ok psx_timer: %d checks", checks)
}

FIELDS :: 3600

// Every field count's vblanks, progressive and interlaced, NTSC and PAL,
// fall on the exact time of their lines, rounded down.
@(private = "file")
fields :: proc() -> int {
	checks := 0
	for pal in ([2]bool{false, true}) {for interlace in ([2]bool{false, true}) {
		line := io.LINE_PAL if pal else io.LINE_NTSC
		io.video = io.Video{line = line}
		// Progressive fields are all the long one; interlaced the even
		// field, which comes first, is the long one and the odd field a line
		// shorter.
		long: u64 = 314 if pal else 263
		if interlace {
			long = 313 if pal else 263
		}
		short := long - 1 if interlace else long
		odd := false
		io.video_vblank(pal, interlace, odd)
		for k in u64(1) ..= FIELDS {
			odd = !odd
			io.video_vblank(pal, interlace, odd)
			lines := (k + 1) / 2 * long + k / 2 * short
			want := u64(u128(lines) * u128(line.num) / u128(line.den))
			if io.video.elapsed != want {
				fail("pal %v interlace %v: %d fields in %d cycles, want %d", pal, interlace, k, io.video.elapsed, want)
			}
			checks += 1
		}
	}}
	// The NTSC progressive figure by hand: 3600 × 263 lines of
	// 33638528 / 15625 cycles.
	io.video = io.Video{line = io.LINE_NTSC}
	for _ in 0 ..= FIELDS {
		io.video_vblank(false, false, false)
	}
	if io.video.elapsed != 2_038_333_331 {
		fail("3600 NTSC fields in %d cycles, want 2038333331", io.video.elapsed)
	}
	return checks + 1
}

// From NTSC to PAL: the fields sum to the exact time within the cycle the
// remainder's conversion rounds off, and a free-running counter on hblank
// keeps its count across the switch, then counts PAL lines.
@(private = "file")
switch_line :: proc() -> int {
	N :: io.LINE_NTSC
	P :: io.LINE_PAL
	for &e in io.events {e = io.EVENT_OFF}
	cpu.next_event = io.EVENT_OFF
	io.video = io.Video{line = N}
	io.timers_init()
	cpu.state.cycles = 1000
	io.timer_write(1, 4, 0x100)
	io.video_vblank(false, false, false)
	for _ in 0 ..< 1000 {
		io.video_vblank(false, false, false)
	}
	at := u64(1000) + 5_000_003
	// The switch at a vblank due on `at`, run as the event it is.
	io.event_handlers[.VBlank] = proc() {io.video_vblank(true, false, false)}
	io.events[.VBlank] = at
	cpu.next_event = at
	cpu.state.cycles = at
	io.run_events()
	for _ in 1 ..< 1000 {
		io.video_vblank(true, false, false)
	}
	// 1001 NTSC fields of 263 lines (the one running at the switch is
	// NTSC), then 999 PAL of 314.
	a := u128(1001 * 263) * u128(N.num) * u128(P.den)
	b := u128(999 * 314) * u128(P.num) * u128(N.den)
	want := u64((a + b) / (u128(N.den) * u128(P.den)))
	if got := io.video.elapsed; got != want && got + 1 != want {
		fail("NTSC then PAL fields in %d cycles, want %d", got, want)
	}
	before := ticks_in(at - 1000, N, 1)
	if got := u64(io.timer_read(1, 0)); got != before & 0xffff {
		fail("hblank counter %d at the switch, want %d", got, before & 0xffff)
	}
	cpu.state.cycles = at + 7_777_777
	after := before + ticks_in(7_777_777, P, 1)
	if got := u64(io.timer_read(1, 0)); got != after & 0xffff {
		fail("hblank counter %d after the switch, want %d", got, after & 0xffff)
	}
	return 3
}

// The display rates the host locks presents to, per video mode: the sound
// queue follows the display clock only within core.audio_rate_fits, so PAL
// progressive (49.747 Hz) at 50 Hz, 0.509% off, sleep-paces.
@(private = "file")
vsync_lock :: proc() -> int {
	Case :: struct {
		hz:              f64,
		pal, interlace:  bool,
		shows:           int,
	}
	NTSC_HZ :: 60.0 * 1000 / 1001
	cases := []Case {
		{60, false, false, 1}, {NTSC_HZ, false, false, 1}, {50, false, false, 0},
		{60, false, true, 1}, {NTSC_HZ, false, true, 1}, {50, false, true, 0},
		{60, true, false, 0}, {NTSC_HZ, true, false, 0}, {50, true, false, 0},
		{60, true, true, 0}, {NTSC_HZ, true, true, 0}, {50, true, true, 1},
		{120, false, false, 2}, {240, false, true, 4}, {100, true, true, 2},
		{144, false, false, 0}, {100, true, false, 0},
	}
	for c in cases {
		if got := io.vsync_shows(c.hz, c.pal, c.interlace, 4); got != c.shows {
			fail("vsync at %.3f Hz pal %v interlace %v: %d shows, want %d", c.hz, c.pal, c.interlace, got, c.shows)
		}
	}
	return len(cases)
}
