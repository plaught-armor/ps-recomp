// Learned EE functions: a run compiled to a blob (recomp/r5900/learned.odin)
// and loaded (ps2/learned.odin) runs where no function is registered, in
// place of the interpreter, only while RAM holds its words.
//
//   - Compiled, a loop leaves the registers the interpreter does.
//   - A host write over its code interprets it, and its words written back
//     run it native again.
//   - A DMA write over its code (fromSPR) does the same.
//   - A snapshot load that puts other words back interprets it; the words
//     written back run it native again.
//   - Two versions at one entry: each runs native while RAM holds its words.
//   - A record stored into (.Smc, .Smc_Unknown) or too large (.Large) is not
//     compiled (core.learn_compilable).
//   - A blob of no functions loads, with no code to map.
//   - A run wasm32 cannot lower (a SYSCALL in a delay slot) gets no span and
//     is counted.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import dma "ps:ps2/dma"
import mem "ps:ps2/mem"
import "ps:recomp/native"
import "ps:recomp/r5900"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL ee_learned: %s (line %d)", what, loc.line)
		failed += 1
	}
}

// v0 = a0 * a1 by a loop, a1 > 0.
@(private = "file")
LOOP :: 0x00100000
@(rodata, private = "file")
CODE_LOOP := [?]u32 {
	0x24020000, // addiu v0, zero, 0
	0x00441021, // addu v0, v0, a0
	0x24a5ffff, // addiu a1, a1, -1
	0x14a0fffd, // bne a1, zero, -3
	0x00000000,
	0x03e00008, // jr ra
	0x00000000,
}

// The loop's first word changed: v0 starts at 1.
@(private = "file")
CHANGED :: 0x24020001

// Where the calls return to.
@(private = "file")
RA :: 0x00000ff0

// Written by the host.
@(private = "file")
put :: proc(addr, w: u32) {
	mem.wr32(addr, w)
}

// The loop's words, its first one first.
@(private = "file")
put_loop :: proc(first: u32) {
	loop := CODE_LOOP
	loop[0] = first
	for w, k in loop {put(LOOP + 4 * u32(k), w)}
}

// Call LOOP with a0 3 and a1 5: v0, and whether a learned function ran it.
@(private = "file")
run :: proc() -> (u32, bool) {
	cpu.state.r = {}
	cpu.state.r[4].d[0], cpu.state.r[5].d[0], cpu.state.r[29].d[0], cpu.state.r[31].d[0] = 3, 5, 0x001ff000, RA
	calls := cpu.learned_calls
	cpu.call(LOOP)
	return u32(cpu.state.r[2].d[0]), cpu.learned_calls != calls
}

// fromSPR: the quadword at the scratchpad's start to LOOP, its first word w.
@(private = "file")
dma_first :: proc(w: u32) {
	qw := [1][4]u32{{w, CODE_LOOP[1], CODE_LOOP[2], CODE_LOOP[3]}}
	copy(mem.spr[:], slice.to_bytes(qw[:]))
	mem.dma_reg(mem.DMA_FROM_SPR, 0x00)^ = 0x100
	mem.dma_reg(mem.DMA_FROM_SPR, 0x10)^ = LOOP
	mem.dma_reg(mem.DMA_FROM_SPR, 0x20)^ = 1
	mem.dma_reg(mem.DMA_FROM_SPR, 0x80)^ = 0
	dma.dma_from_spr()
}

@(private = "file")
rec :: proc(flags: core.Learn_Flags, entry: u32, words: []u32, hash: u64) -> core.Learn_Record {
	return {cpu = .Ee, flags = flags, entry = entry, lo = entry, hash = hash, words = words}
}

@(private = "file")
test_compilable :: proc() {
	loop := CODE_LOOP
	recs := [?]core.Learn_Record {
		rec({}, LOOP, loop[:], 1),
		rec({.Smc}, LOOP + 0x100, loop[:], 2),
		rec({.Smc_Unknown}, LOOP + 0x200, loop[:], 3),
		rec({.Large}, LOOP + 0x300, nil, 4),
	}
	out, large, smc := core.learn_compilable(recs[:], .Ee, context.temp_allocator)
	check(len(out) == 1 && out[0].entry == LOOP, fmt.tprintf("compiled %v, want the loop only", out[:]))
	check(large == 1, fmt.tprintf("large %d, want 1", large))
	check(smc == 2, fmt.tprintf("stored into %d, want 2", smc))
}

// wasm32 cannot lower a SYSCALL in a delay slot (r5900.lower's exact): that
// run gets no span and is counted, the loop beside it compiled.
@(private = "file")
test_wasm_skip :: proc() {
	loop := CODE_LOOP
	slot := [?]u32 {
		0x03e00008, // jr ra
		0x0000000c, // syscall
	}
	blob, skipped := r5900.learned_blob({{LOOP, LOOP, loop[:]}, {LOOP + 0x100, LOOP + 0x100, slot[:]}}, .Wasm32)
	defer delete(blob)
	check(skipped == 1, fmt.tprintf("wasm32 skipped %d runs, want 1", skipped))
	// The header's n_spans, its eighth field (recomp/native/blob.odin).
	n_spans := len(blob) < 32 ? -1 : int(u32(blob[28]) | u32(blob[29]) << 8 | u32(blob[30]) << 16 | u32(blob[31]) << 24)
	check(n_spans == 1, fmt.tprintf("wasm32 blob has %d spans, want 1", n_spans))
}

@(private = "file")
write_blob :: proc(dir, name: string, runs: []r5900.Learned) -> string {
	path, _ := filepath.join({dir, name}, context.allocator)
	blob, skipped := r5900.learned_blob(runs, native.Arch(core.NATIVE_ARCH))
	check(skipped == 0, fmt.tprintf("%s: %d runs skipped", name, skipped))
	check(os.write_entire_file(path, blob) == nil, fmt.tprintf("write %s", path))
	return path
}

// Not in the snapshot: whether it was loaded.
@(private = "file")
loaded: bool

@(private = "file")
snap: core.Snapshot

@(private = "file")
tmp: string

game :: proc(_: rawptr) {
	if !loaded {
		test_compilable()
		test_wasm_skip()
		put_loop(CODE_LOOP[0])
		v0, native_ran := run()
		check(v0 == 15 && !native_ran, "interpreted loop")

		err: os.Error
		tmp, err = os.make_directory_temp("", "ps_ee_learned_test_*", context.allocator)
		if err != nil {
			fmt.eprintln("FAIL ee_learned: no temp directory:", err)
			os.exit(1)
		}
		// A blob of no functions (every record stored into) has no code.
		check(ps2.load_learned(write_blob(tmp, "empty.bin", {})), "load empty")
		loop := CODE_LOOP
		check(ps2.load_learned(write_blob(tmp, "a.bin", {{LOOP, LOOP, loop[:]}})), "load")
		v0, native_ran = run()
		check(v0 == 15 && native_ran, "learned loop not run native")

		put(LOOP, CHANGED)
		v0, native_ran = run()
		check(v0 == 16 && !native_ran, "loop written by the host ran native")
		put(LOOP, CODE_LOOP[0])
		v0, native_ran = run()
		check(v0 == 15 && native_ran, "loop with its word written back not run native")

		dma_first(CHANGED)
		v0, native_ran = run()
		check(v0 == 16 && !native_ran, "loop written by DMA ran native")
		dma_first(CODE_LOOP[0])
		v0, native_ran = run()
		check(v0 == 15 && native_ran, "loop written back by DMA not run native")

		put(LOOP, CHANGED)
		core.snap_op, core.snap_target = .Save, &snap
		core.snap_yield()
	}
	// Here after the save, and again after the load.
	if !loaded {
		put(LOOP, CODE_LOOP[0])
		v0, native_ran := run()
		check(v0 == 15 && native_ran, "loop written back before the load not run native")
		loaded = true
		core.snap_op, core.snap_target = .Load, &snap
		core.snap_yield()
	}
	v0, native_ran := run()
	check(v0 == 16 && !native_ran, "loop the load changed ran native")
	put(LOOP, CODE_LOOP[0])
	v0, native_ran = run()
	check(v0 == 15 && native_ran, "loop written back after the load not run native")

	// A second version at the same entry: each runs while RAM holds it.
	changed := CODE_LOOP
	changed[0] = CHANGED
	check(ps2.load_learned(write_blob(tmp, "b.bin", {{LOOP, LOOP, changed[:]}})), "load the second version")
	put(LOOP, CHANGED)
	v0, native_ran = run()
	check(v0 == 16 && native_ran, "second version not run native")
	put(LOOP, CODE_LOOP[0])
	v0, native_ran = run()
	check(v0 == 15 && native_ran, "first version not run native beside the second")
	put(LOOP, 0x24020002) // addiu v0, zero, 2: neither
	v0, native_ran = run()
	check(v0 == 17 && !native_ran, "code neither version holds ran native")

	if os.remove_all(tmp) != nil {
		check(false, fmt.tprintf("cannot remove %s", tmp))
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok ee_learned: learned EE code runs native only while RAM holds its words, through host and DMA writes and snapshot loads, one version per code at an entry")
	os.exit(0)
}

main :: proc() {
	core.snap_init(64 << 20)
	mem.mem_init()
	cpu.next_event = max(u64)
	cpu.interp_hook = ps2.interp_call
	context.allocator = core.emu_allocator()
	core.co_allocator = context.allocator
	core.snap_run(core.co_create(game, nil))
}
