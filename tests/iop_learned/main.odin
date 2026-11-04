// Learned IOP functions: a run compiled to a blob (recomp/r3000/learned.odin),
// loaded (psx/native/learned.odin) with the R3000 made the IOP, runs in place
// of the interpreter only while IOP RAM holds its words.
//
//   - Compiled, a loop leaves the registers the interpreter does.
//   - A host write over its code (iop_mem, as the HLE's copies and DMA
//     write; sysclib's memcpy) interprets it, and its words written back
//     run it native again.
//   - A snapshot load that puts other words back, with no guard, interprets
//     it; the words written back run it native again.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "ps:core"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"
import cpu "ps:psx/cpu"
import psx_native "ps:psx/native"
import "ps:recomp/native"
import "ps:recomp/r3000"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL iop_learned: %s (line %d)", what, loc.line)
		failed += 1
	}
}

// v0 = a0 * a1 by a loop, a1 > 0.
@(private = "file")
LOOP :: 0x00010000
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

// Where sysclib's memcpy copies from.
@(private = "file")
SRC :: 0x00020000

// Where the calls return to.
@(private = "file")
RA :: 0x00000ff0

// Written by the host, as the HLE writes IOP RAM.
@(private = "file")
put :: proc(addr, w: u32) {
	(^u32)(raw_data(iop.iop_mem(addr, 4)))^ = w
}

// Call LOOP with a0 3 and a1 5: v0, and whether a learned function ran it.
@(private = "file")
run :: proc() -> (u32, bool) {
	cpu.state.r = {}
	cpu.state.r[4], cpu.state.r[5], cpu.state.r[29], cpu.state.r[31] = 3, 5, 0x001ff000, RA
	hits := cpu.learned_hits
	cpu.call(LOOP)
	return cpu.state.r[2], cpu.learned_hits != hits
}

// sysclib's memcpy(dst, src, 4).
@(private = "file")
memcpy :: proc(dst, src: u32) {
	cpu.state.r[4], cpu.state.r[5], cpu.state.r[6] = dst, src, 4
	_, ok := iop.sysclib_fn(12)
	check(ok, "memcpy answered")
}

// Not in the snapshot: whether it was loaded.
@(private = "file")
loaded: bool

@(private = "file")
snap: core.Snapshot

game :: proc(_: rawptr) {
	loop := CODE_LOOP
	for w, k in loop {put(LOOP + 4 * u32(k), w)}
	v0, native_ran := run()
	check(v0 == 15 && !native_ran, "interpreted loop")

	tmp, err := os.make_directory_temp("", "ps_iop_learned_test_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL iop_learned: no temp directory:", err)
		os.exit(1)
	}
	path, _ := filepath.join({tmp, "a.bin"}, context.allocator)
	check(os.write_entire_file(path, r3000.learned_blob({{LOOP, LOOP, loop[:]}}, native.Arch(core.NATIVE_ARCH))) == nil, "write the blob")
	check(psx_native.load_learned(path), "load")
	v0, native_ran = run()
	check(v0 == 15 && native_ran, "learned loop not run native")

	put(LOOP, CHANGED)
	v0, native_ran = run()
	check(v0 == 16 && !native_ran, "loop written by the host ran native")
	put(LOOP, loop[0])
	v0, native_ran = run()
	check(v0 == 15 && native_ran, "loop with its word written back not run native")

	put(SRC, CHANGED)
	put(SRC + 4, loop[0])
	memcpy(LOOP, SRC)
	v0, native_ran = run()
	check(v0 == 16 && !native_ran, "loop copied over by memcpy ran native")
	memcpy(LOOP, SRC + 4)
	v0, native_ran = run()
	check(v0 == 15 && native_ran, "loop copied back by memcpy not run native")

	put(LOOP, CHANGED)
	core.snap_op, core.snap_target = .Save, &snap
	core.snap_yield()
	// Here after the save, and again after the load.
	if !loaded {
		put(LOOP, loop[0])
		v0, native_ran = run()
		check(v0 == 15 && native_ran, "loop written back before the load not run native")
		loaded = true
		core.snap_op, core.snap_target = .Load, &snap
		core.snap_yield()
	}
	v0, native_ran = run()
	check(v0 == 16 && !native_ran, "loop the load changed ran native")
	put(LOOP, loop[0])
	v0, native_ran = run()
	check(v0 == 15 && native_ran, "loop written back after the load not run native")

	if os.remove_all(tmp) != nil {
		check(false, fmt.tprintf("cannot remove %s", tmp))
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok iop_learned: learned IOP code runs native only while IOP RAM holds its words, through host writes and snapshot loads")
	os.exit(0)
}

main :: proc() {
	core.snap_init(1 << 20)
	iop.sif_snap()
	iop.spu_snap()
	mem.mem_init()
	iop.sif_init()
	context.allocator = core.emu_allocator()
	core.co_allocator = context.allocator
	core.snap_run(core.co_create(game, nil))
}
