// Runtime tracing, always compiled in and selected by settings (see env.odin
// for the prefix):
//
//   TRACE=io,irq,sio      channels to log (or "all"); see Trace_Channel
//   TRACE_AT=10000-10003  only while the present count is in this range
//   TRACE_PC=80171500-80171900  limit block/call/interp lines to a PC range
//   TRACE_FILE=path       write there instead of stderr
//   WATCH=80116d0c[-80116d10]  log every CPU store into the range (mem)
//
// Each line is "<present> <cycles> <channel> <message>". Call sites guard
// with `if .X in trace.active` so disabled channels cost one bit test and
// the format arguments are never evaluated.
//
// The console owns the clock: trace_init takes its present and cycle
// counters, read on every line, and the console calls trace_window once per
// present. The console also owns the lines that need its registers (blocks
// entered, watched stores); it filters them with trace_pc_ok and
// trace_watched.
package core

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Trace_Channel :: enum u8 {
	Io,     // every hardware register access
	Irq,    // raise, acknowledge, delivery
	Event,  // device scheduler events
	Sio,    // controller/memory card serial bytes
	Timer,  // root counter writes and target/overflow
	Dma,    // channel starts and completions
	Cdrom,  // commands, responses, sector reads
	Gpu,    // GPU register writes and command opcodes
	Bios,   // BIOS/kernel function calls
	Call,   // every host-level call (target, ra, sp)
	Block,  // every recompiled basic block entered
	Interp, // every interpreted instruction
	Mem,    // stores into the WATCH range
	Perf,   // host speed every PERF_PERIOD presents
	Game,   // decisions taken by the game's own hooks
}

trace: struct {
	// Channels live right now: `wanted` gated by the present window.
	active:   bit_set[Trace_Channel],
	wanted:   bit_set[Trace_Channel],
	from, to: u64,
	pc_lo:    u32,
	pc_hi:    u32,
	watch_lo: u32,
	watch_hi: u32,
	// Fast check for the store path: watch range set and Mem active.
	watching: bool,
	out:      ^os.File,
	buf:      strings.Builder,
	// The console's clock, stamped on every line.
	present:  ^u64,
	cycles:   ^u64,
}

@(private = "file")
TRACE_FLUSH_AT :: 1 << 16

@(private = "file")
parse_hex_range :: proc(spec: string) -> (lo, hi: u64, ok: bool) {
	parts := strings.split(spec, "-", context.temp_allocator)
	lo = strconv.parse_u64(parts[0], 16) or_return
	hi = lo
	if len(parts) > 1 {
		hi = strconv.parse_u64(parts[1], 16) or_return
	}
	return lo, hi, true
}

@(private = "file")
parse_dec_range :: proc(spec: string) -> (lo, hi: u64, ok: bool) {
	parts := strings.split(spec, "-", context.temp_allocator)
	lo = strconv.parse_u64(parts[0], 10) or_return
	hi = max(u64)
	if len(parts) > 1 {
		hi = strconv.parse_u64(parts[1], 10) or_return
	}
	return lo, hi, true
}

@(private = "file")
parse_channels :: proc(spec: string) -> (set: bit_set[Trace_Channel], ok: bool) {
	ok = true
	for name in strings.split(spec, ",", context.temp_allocator) {
		if name == "all" {
			set = ~{}
			continue
		}
		found := false
		for ch in Trace_Channel {
			if strings.equal_fold(name, fmt.tprint(ch)) {
				set += {ch}
				found = true
			}
		}
		if !found {
			fmt.eprintln(ENV_PREFIX + "TRACE: unknown channel", name)
			ok = false
		}
	}
	return
}

// Read the TRACE* settings; `present` and `cycles` are the console's present
// count and CPU cycle counter. Returns false on a malformed setting.
trace_init :: proc(present, cycles: ^u64) -> bool {
	assert(present != nil && cycles != nil, "trace: no clock")
	trace.present, trace.cycles = present, cycles
	trace.out = os.stderr
	trace.to = max(u64)
	trace.pc_hi = max(u32)
	strings.builder_init(&trace.buf)
	ok := true
	if spec := env("TRACE"); spec != "" {
		trace.wanted, ok = parse_channels(spec)
	}
	if spec := env("TRACE_AT"); spec != "" {
		lo, hi, good := parse_dec_range(spec)
		if !good {
			fmt.eprintln(ENV_PREFIX + "TRACE_AT: expected <from>[-<to>]:", spec)
			ok = false
		}
		trace.from, trace.to = lo, hi
	}
	if spec := env("TRACE_PC"); spec != "" {
		lo, hi, good := parse_hex_range(spec)
		if !good {
			fmt.eprintln(ENV_PREFIX + "TRACE_PC: expected <hex>[-<hex>]:", spec)
			ok = false
		}
		trace.pc_lo, trace.pc_hi = u32(lo), u32(hi)
	}
	if spec := env("WATCH"); spec != "" {
		lo, hi, good := parse_hex_range(spec)
		if !good {
			fmt.eprintln(ENV_PREFIX + "WATCH: expected <hex>[-<hex>]:", spec)
			ok = false
		}
		trace.watch_lo, trace.watch_hi = u32(lo) & 0x1fffffff, u32(hi) & 0x1fffffff
		trace.wanted += {.Mem}
	}
	if path := env("TRACE_FILE"); path != "" {
		f, err := os.create(path)
		if err != nil {
			fmt.eprintln(ENV_PREFIX + "TRACE_FILE: cannot create", path, err)
			return false
		}
		trace.out = f
	}
	trace_window()
	return ok
}

// Re-evaluate the present window; called once per present.
trace_window :: proc() {
	in_window := trace.present^ >= trace.from && trace.present^ <= trace.to
	trace.active = in_window ? trace.wanted : {}
	trace.watching = .Mem in trace.active && trace.watch_hi != 0
	trace_flush()
}

trace_flush :: proc() {
	if strings.builder_len(trace.buf) == 0 {
		return
	}
	_, err := os.write(trace.out, trace.buf.buf[:])
	if err != nil {
		fmt.eprintln("trace: write failed:", err)
		trace.wanted = {}
		trace.active = {}
	}
	strings.builder_reset(&trace.buf)
}

tracef :: proc(ch: Trace_Channel, format: string, args: ..any) {
	fmt.sbprintf(&trace.buf, "%d %d %v ", trace.present^, trace.cycles^, ch)
	fmt.sbprintfln(&trace.buf, format, ..args)
	if strings.builder_len(trace.buf) >= TRACE_FLUSH_AT {
		trace_flush()
	}
}

// Whether pc is in the TRACE_PC range.
trace_pc_ok :: #force_inline proc(pc: u32) -> bool {
	return pc >= trace.pc_lo && pc <= trace.pc_hi
}

// Whether a store of `size` bytes at a touches the WATCH range; the store
// path asks only when trace.watching is set.
trace_watched :: proc(a, size: u32) -> bool {
	p := a & 0x1fffffff
	return p + size > trace.watch_lo && p <= trace.watch_hi
}
