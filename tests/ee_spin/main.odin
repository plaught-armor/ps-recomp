// The EE spin skip (ps2/spin.odin) on synthetic loops through the native
// backend, run on every target in CI. Each loop polls a RAM flag that the
// last of a few kernel alarms sets, with vblanks between them; it runs once
// with the skip on and once with it off, from the same machine state, and
// both runs must end with the same cpu.state (cycles included), the same
// memory, the same frame count and INTC_STAT, and the same alarm handler
// calls at the same cycles. A loop that leaves everything as it found it
// (a pure spin, a store of the value already there) must be skipped; one
// that changes memory (a counter) or reads a register is never skipped,
// but for INTC_STAT, which only an event or a store changes: a loop that
// polls it is skipped, one that polls GIF_STAT or a timer is not.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r5900"

FLAG :: u32(0x00100000) // what the last alarm sets; t2 points here
SAME :: FLAG + 0x10 // the same-value store's word
COUNT :: FLAG + 0x20 // the counter's word
CODE :: u32(0x00200000)
HANDLER :: u32(0x00300000) // the alarms' handler, an Odin proc
// Alarm times, in lines; the vblanks between them are events too.
ALARMS :: [?]u32{300, 700, 1200, 2000}

// t0 = 8, t1 = 9, t2 = 10, t3 = 11, t4 = 12.
lui :: proc(rt, imm: u32) -> u32 {return 0x0f << 26 | rt << 16 | imm}
addiu :: proc(rt, rs, imm: u32) -> u32 {return 0x09 << 26 | rs << 21 | rt << 16 | imm & 0xffff}
lw :: proc(rt, off, base: u32) -> u32 {return 0x23 << 26 | base << 21 | rt << 16 | off & 0xffff}
sw :: proc(rt, off, base: u32) -> u32 {return 0x2b << 26 | base << 21 | rt << 16 | off & 0xffff}
// beq t0, $0 back to the loop's first word, n words before it.
beqz_back :: proc(n: u32) -> u32 {return 0x04 << 26 | 8 << 21 | (-(n + 1)) & 0xffff}
JR_RA :: 0x03e00008

Loop :: struct {
	name:    string,
	body:    []u32, // what the loop does before it loads the flag
	skipped: bool, // what the skip must do with it
}

Call :: struct {
	id:     u64,
	cycles: u64,
}

Result :: struct {
	state:   cpu.Cpu,
	same:    u32,
	count:   u32,
	frame:   u64,
	intc:    u32,
	calls:   [len(ALARMS)]Call,
	n_calls: int,
	skipped: u64,
}

calls: [len(ALARMS)]Call
n_calls: int

// The alarm handler: note the call, and set the flag at the last.
handler :: proc() {
	calls[n_calls] = {cpu.state.r[4].d[0], cpu.state.cycles}
	n_calls += 1
	if n_calls == len(ALARMS) {mem.wr32(FLAG, 1)}
}

// The loop at CODE + 0x100 * k: t2 = FLAG and t3 = 0x10000000, then the body,
// then lw t0, (t2) and beqz back, and return.
program :: proc(l: Loop) -> []u32 {
	words := make([dynamic]u32)
	append(&words, lui(10, FLAG >> 16), lui(11, 0x1000))
	append(&words, ..l.body)
	append(&words, lw(8, 0, 10), beqz_back(u32(len(l.body)) + 1), 0, JR_RA, 0)
	return words[:]
}

main :: proc() {
	ps2.init()
	kernel.k.threads[1].co = &core.co_main_thread
	cpu.text_range(HANDLER, HANDLER + 4)
	cpu.register(HANDLER, handler)

	loops := [?]Loop {
		{"pure spin", {}, true},
		{"same-value store", {sw(0, 0x10, 10)}, true},
		// The counter goes up in memory; t1 ends each pass at 0, so only
		// the store tells the passes apart.
		{"counter", {lw(9, 0x20, 10), addiu(9, 9, 1), sw(9, 0x20, 10), addiu(9, 0, 0)}, false},
		{"INTC_STAT load", {lui(12, 0x1001), lw(9, 0xf000, 12)}, true}, // 0x1000f000
		{"GIF_STAT load", {lw(9, 0x3020, 11)}, false},
		{"timer load", {lw(9, 0, 11)}, false}, // T0_COUNT
	}

	arch := native.Arch(core.NATIVE_ARCH)
	a := native.make_asm(arch, r5900.native_ram())
	funcs: [len(loops)]native.Blob_Func
	slow: map[string]int
	defer delete(slow)
	for l, k in loops {
		at := CODE + 0x100 * u32(k)
		words := program(l)
		data := make([]u8, 4 * len(words))
		for w, n in words {
			data[4 * n], data[4 * n + 1], data[4 * n + 2], data[4 * n + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
			mem.wr32(at + 4 * u32(n), w)
		}
		f := mips.func_make(at, at + u32(len(data)))
		mips.discover(r5900.RULES, {base = at, data = data}, f, {})
		funcs[k] = {at, r5900.native_func(&a, f, {}, 1, &slow)[0]}
		free_all(context.temp_allocator)
	}
	if len(slow) != 0 {
		fmt.eprintln("FAIL interpreter calls in native code:", slow)
		os.exit(1)
	}
	code, err := core.native_load(native.make_blob(&a, funcs[:], {}), ps2.native_imports())
	if err != "" {
		fmt.eprintln("native_load:", err)
		os.exit(1)
	}

	// The machine state each run starts from.
	start := cpu.state
	vblank_start, vblank_end, frame, next_alarm := kernel.k.vblank_start, kernel.k.vblank_end, kernel.k.frame, kernel.k.next_alarm
	intc_stat, gs_csr := mem.intc_stat, mem.gs_csr

	failed := 0
	for l, k in loops {
		got: [2]Result
		for on, n in ([2]bool{true, false}) {
			cpu.state = start
			kernel.k.vblank_start, kernel.k.vblank_end, kernel.k.frame, kernel.k.next_alarm = vblank_start, vblank_end, frame, next_alarm
			mem.intc_stat, mem.intc_pending, mem.gs_csr = intc_stat, 0, gs_csr
			mem.wr32(FLAG, 0)
			mem.wr32(SAME, 0)
			mem.wr32(COUNT, 0)
			n_calls = 0
			for t in ALARMS {kernel.set_alarm(t, HANDLER, 0)}
			ps2.spin_on, ps2.spin_tick = on, 1
			skipped := cpu.spin_cycles
			run := cast(proc())rawptr(code.base + uintptr(code.funcs[k].off))
			run()
			got[n] = {
				state   = cpu.state,
				same    = mem.rd32(SAME),
				count   = mem.rd32(COUNT),
				frame   = kernel.k.frame,
				intc    = mem.intc_stat,
				calls   = calls,
				n_calls = n_calls,
				skipped = cpu.spin_cycles - skipped,
			}
		}
		on, off := got[0], got[1]
		if on.n_calls != len(ALARMS) || len(kernel.k.alarms) != 0 {
			failed += 1
			fmt.eprintfln("FAIL %s: %d alarm calls, %d alarms left", l.name, on.n_calls, len(kernel.k.alarms))
		}
		on_skipped := on.skipped
		on.skipped = 0
		if !runtime.memory_equal(&on, &off, size_of(Result)) {
			failed += 1
			fmt.eprintfln("FAIL %s: skip on and off differ", l.name)
			fmt.eprintfln("  cycles %d %d, frame %d %d, intc %x %x, count %d %d, calls %v %v", on.state.cycles, off.state.cycles, on.frame, off.frame, on.intc, off.intc, on.count, off.count, on.calls, off.calls)
		}
		if off.skipped != 0 || (on_skipped != 0) != l.skipped {
			failed += 1
			fmt.eprintfln("FAIL %s: skipped %d cycles on, %d off; want skipped %v", l.name, on_skipped, off.skipped, l.skipped)
		}
		fmt.printfln("%-17s cycles %d, skipped %d (%.1f%%)", l.name, on.state.cycles, on_skipped, 100 * f64(on_skipped) / f64(on.state.cycles))
	}
	if failed != 0 {os.exit(1)}
	fmt.println("ok")
}
