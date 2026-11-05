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
//
// Last, two threads at one priority hand the EE back and forth with
// RotateThreadReadyQueue: the main thread polls the flag between rotates,
// the other only rotates. Each pass goes round both threads, and must be
// skipped, with the same end as above and both threads' saved registers
// and ready order (seq) the same. Then the other thread rotates at two
// sites in turn, so a pass leaves it with the same registers but parked at
// the other site: the end must still be the same, skipped or not.
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
PARAM :: FLAG + 0x40 // the rotating thread's CreateThread parameters
PRIO :: 0x14 // both rotating threads'
SYSCALL :: 0x0000000c

// t0 = 8, t1 = 9, t2 = 10, t3 = 11, t4 = 12.
lui :: proc(rt, imm: u32) -> u32 {return 0x0f << 26 | rt << 16 | imm}
addiu :: proc(rt, rs, imm: u32) -> u32 {return 0x09 << 26 | rs << 21 | rt << 16 | imm & 0xffff}
lw :: proc(rt, off, base: u32) -> u32 {return 0x23 << 26 | base << 21 | rt << 16 | off & 0xffff}
sw :: proc(rt, off, base: u32) -> u32 {return 0x2b << 26 | base << 21 | rt << 16 | off & 0xffff}
// beq t0, $0 back to the loop's first word, n words before it.
beqz_back :: proc(n: u32) -> u32 {return 0x04 << 26 | 8 << 21 | (-(n + 1)) & 0xffff}
// beq $0, $0 back, n words before it.
b_back :: proc(n: u32) -> u32 {return 0x04 << 26 | (-(n + 1)) & 0xffff}
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

// What the rotating threads' run ends with.
Rotate_Result :: struct {
	state:   cpu.Cpu,
	other:   cpu.Cpu, // the other thread's saved registers
	seq:     [3]u64, // k.seq, the main thread's and the other's
	current: i64,
	frame:   u64,
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
	cpu.text_range(CODE, HANDLER + 4)
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
	// The rotating threads' loops, after the others: the main thread's
	// rotates, then polls the flag; the other's only rotates, at one site
	// or at two in turn.
	programs: [len(loops) + 3][]u32
	for l, k in loops {programs[k] = program(l)}
	programs[len(loops)] = {lui(10, FLAG >> 16), addiu(3, 0, 0x2b), addiu(4, 0, PRIO), SYSCALL, lw(8, 0, 10), beqz_back(4), 0, JR_RA, 0}
	programs[len(loops) + 1] = {addiu(3, 0, 0x2b), addiu(4, 0, PRIO), SYSCALL, b_back(3), 0, JR_RA, 0}
	programs[len(loops) + 2] = {addiu(3, 0, 0x2b), addiu(4, 0, PRIO), SYSCALL, SYSCALL, b_back(4), 0, JR_RA, 0}
	funcs: [len(programs)]native.Blob_Func
	slow: map[string]int
	defer delete(slow)
	for words, k in programs {
		at := CODE + 0x100 * u32(k)
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

	// The rotating threads, from the same machine state with the main
	// thread at PRIO, and the other created and started afresh each run.
	main_thread := kernel.k.threads[1]
	main_prio, main_seq, seq := main_thread.prio, main_thread.seq, kernel.k.seq
	main_thread.prio = PRIO
	mem.wr32(PARAM + 8, 0x00180000)
	mem.wr32(PARAM + 12, 0x1000)
	mem.wr32(PARAM + 16, 0)
	mem.wr32(PARAM + 20, PRIO)
	mem.wr32(PARAM + 28, 0)
	mem.wr32(PARAM + 32, 0)
	Rotate_Case :: struct {
		name:    string,
		other:   int, // the other thread's program
		skipped: bool, // whether the skip must take passes
	}
	cases := [?]Rotate_Case{{"rotate", len(loops) + 1, true}, {"rotate, two sites", len(loops) + 2, false}}
	for c in cases {
		other_at := CODE + 0x100 * u32(c.other)
		cpu.register(other_at, cast(cpu.Func_Proc)rawptr(code.base + uintptr(code.funcs[c.other].off)))
		mem.wr32(PARAM + 4, other_at)
		rotated: [2]Rotate_Result
		for on, n in ([2]bool{true, false}) {
			cpu.state = start
			kernel.k.vblank_start, kernel.k.vblank_end, kernel.k.frame, kernel.k.next_alarm = vblank_start, vblank_end, frame, next_alarm
			mem.intc_stat, mem.intc_pending, mem.gs_csr = intc_stat, 0, gs_csr
			kernel.k.seq, main_thread.seq = seq, main_seq
			mem.wr32(FLAG, 0)
			n_calls = 0
			for t in ALARMS {kernel.set_alarm(t, HANDLER, 0)}
			id := i32(kernel.create_thread(PARAM))
			if id < 0 || kernel.start_thread(id, 0) != i64(id) {
				fmt.eprintfln("FAIL %s: cannot start the other thread", c.name)
				os.exit(1)
			}
			ps2.spin_on, ps2.spin_tick = on, 1
			skipped := cpu.spin_cycles
			run := cast(proc())rawptr(code.base + uintptr(code.funcs[len(loops)].off))
			run()
			other := kernel.k.threads[id]
			rotated[n] = {
				state   = cpu.state,
				other   = other.regs,
				seq     = {kernel.k.seq, main_thread.seq, other.seq},
				current = i64(kernel.k.current.id),
				frame   = kernel.k.frame,
				calls   = calls,
				n_calls = n_calls,
				skipped = cpu.spin_cycles - skipped,
			}
			kernel.terminate_thread(id)
			kernel.delete_thread(id)
		}
		on, off := rotated[0], rotated[1]
		on_skipped := on.skipped
		on.skipped = 0
		if on.n_calls != len(ALARMS) || len(kernel.k.alarms) != 0 {
			failed += 1
			fmt.eprintfln("FAIL %s: %d alarm calls, %d alarms left", c.name, on.n_calls, len(kernel.k.alarms))
		}
		if !runtime.memory_equal(&on, &off, size_of(Rotate_Result)) {
			failed += 1
			fmt.eprintfln("FAIL %s: skip on and off differ", c.name)
			fmt.eprintfln("  cycles %d %d, other cycles %d %d, seq %v %v, current %d %d, frame %d %d, calls %v %v", on.state.cycles, off.state.cycles, on.other.cycles, off.other.cycles, on.seq, off.seq, on.current, off.current, on.frame, off.frame, on.calls, off.calls)
		}
		if off.skipped != 0 || c.skipped && on_skipped == 0 {
			failed += 1
			fmt.eprintfln("FAIL %s: skipped %d cycles on, %d off; want skipped %v", c.name, on_skipped, off.skipped, c.skipped)
		}
		fmt.printfln("%-17s cycles %d, skipped %d (%.1f%%)", c.name, on.state.cycles, on_skipped, 100 * f64(on_skipped) / f64(on.state.cycles))
	}
	main_thread.prio = main_prio
	if failed != 0 {os.exit(1)}
	fmt.println("ok")
}
