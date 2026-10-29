// FALLBACK_COUNT: how often recompiled code hands an instruction to the
// interpreter, per op, printed when the host exits. Built with
// -define:FALLBACK_COUNT=true; without it the counters compile away.
package ps2_cpu

import "core:fmt"
import "core:slice"
import r5900 "../r5900"

FALLBACK_COUNT :: #config(FALLBACK_COUNT, false)

// A COP2-layout word (VU0 macro, VU upper, VU lower opcode 0x40) as an
// index: fn for 0x00-0x3b, 64 + special for the rest.
@(private = "file")
COP2_KEYS :: 64 + 128

// EE ops run by exec_insn.
fallback_ee: [r5900.Op]u64
// VU0 macro ops (vu0_macro), and each VU's upper ops, lower ops and whole
// pairs that recompiled microcode leaves to the interpreter.
fallback_vu0, fallback_vu0_upper, fallback_vu1_upper: [COP2_KEYS]u64
fallback_vu0_lower, fallback_vu1_lower: [128 + COP2_KEYS]u64 // opcode, then 128 + the 0x40 key
fallback_vu0_pair, fallback_vu1_pair: u64
// VU0 micro-mode pairs the interpreter runs outside compiled programs.
fallback_vu0_micro: u64
// fpu_slow calls, by op: not the interpreter, so outside the calls total.
fallback_fpu_slow: [Fpu_Op]u64

cop2_key :: #force_inline proc "contextless" (w: u32) -> u32 {
	fn := w & 63
	return fn < 0x3c ? fn : 64 + (((w >> 4) & 0x7c) | (w & 3))
}

@(private = "file")
cop2_name :: proc(k: int) -> string {
	return k < 64 ? fmt.tprintf("fn %02x", k) : fmt.tprintf("special %02x", k - 64)
}

// Every non-zero counter, most first, on stderr.
fallback_print :: proc() {
	Row :: struct {
		name: string,
		n:    u64,
	}
	rows := make([dynamic]Row, context.temp_allocator)
	total: u64
	add :: proc(rows: ^[dynamic]Row, total: ^u64, name: string, n: u64) {
		if n == 0 {return}
		append(rows, Row{name, n})
		total^ += n
	}
	// VU0 counts again below, by op.
	for n, op in fallback_ee {if op != .VU0 {add(&rows, &total, fmt.tprintf("ee %v", op), n)}}
	for n, k in fallback_vu0 {add(&rows, &total, fmt.tprintf("vu0 %s", cop2_name(k)), n)}
	units := [2]struct {
		upper: ^[COP2_KEYS]u64,
		lower: ^[128 + COP2_KEYS]u64,
		pair:  u64,
	}{{&fallback_vu0_upper, &fallback_vu0_lower, fallback_vu0_pair}, {&fallback_vu1_upper, &fallback_vu1_lower, fallback_vu1_pair}}
	for u, unit in units {
		for n, k in u.upper {add(&rows, &total, fmt.tprintf("vu%d upper %s", unit, cop2_name(k)), n)}
		for n, k in u.lower {
			name := k < 128 ? fmt.tprintf("vu%d lower %02x", unit, k) : fmt.tprintf("vu%d lower 40 %s", unit, cop2_name(k - 128))
			add(&rows, &total, name, n)
		}
		add(&rows, &total, fmt.tprintf("vu%d pair", unit), u.pair)
	}
	add(&rows, &total, "vu0 micro interpreted pair", fallback_vu0_micro)
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.n > b.n})
	fmt.eprintfln("fallback: %d calls", total)
	for r in rows {fmt.eprintfln("fallback: %d\t%.2f%%\t%s", r.n, 100 * f64(r.n) / f64(total), r.name)}
	slow: u64
	for n in fallback_fpu_slow {slow += n}
	fmt.eprintfln("fallback: %d fpu_slow calls", slow)
	for n, op in fallback_fpu_slow {if n != 0 {fmt.eprintfln("fallback: %d\tfpu_slow %v", n, op)}}
}
