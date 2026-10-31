// IOP CPU test: psx_cpu's R3000 run as the IOP over iop_ram, with
// hand-assembled words. A store to 0x00200010 lands in RAM through the 2 MiB
// mirror and leaves the HLE's own area at that IOP address alone; a kseg1
// load reads it back; a kseg1 store to SPU2 (0x1f900000), outside psx's
// device window, reaches io_far_write at its physical address; `jr ra`
// returns from interp_run; the IOP has no GTE. A snapshot restores RAM and
// the map of logged device addresses, which grows after the save: after the
// load it is empty again and grows cleanly.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"
import r3000 "ps:psx/cpu"

CODE :: 0x1000
GROW :: 0x2000 // loads from SPU2, one per new device address
GROWN :: 16 // enough for the map to reallocate twice

failed: bool
snap: core.Snapshot
loaded: bool // not emulated state: tells the run after the load apart
far: [dynamic][3]u32 // io_far_write's address, value, size

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL %s (line %d)", what, loc.line)
		failed = true
	}
}

game :: proc(_: rawptr) {
	check(raw_data(iop.iop_ram) == &r3000.ram[0], "iop_ram is the R3000's RAM")
	check(r3000.gte_cmd == nil && r3000.gte_read == nil && r3000.gte_write == nil, "no GTE")
	check(r3000.bios_entry == nil && r3000.ram_keep == nil, "no PS1 BIOS entry or RAM watch")
	r3000.io_far_write = proc(a, v: u32, size: u32) {append(&far, [3]u32{a, v, size})}

	hle := (^u32)(raw_data(iop.iop_mem(0x200010, 4)))
	hle^ = 0x5a5a5a5a
	code := [?]u32 {
		0x3c080020, // lui   t0, 0x0020
		0x3c09dead, // lui   t1, 0xdead
		0x3529beef, // ori   t1, t1, 0xbeef
		0xad090010, // sw    t1, 0x10(t0)
		0x3c0aa000, // lui   t2, 0xa000
		0x8d4b0010, // lw    t3, 0x10(t2)
		0x3c0cbf90, // lui   t4, 0xbf90
		0xad890000, // sw    t1, 0(t4)
		0x03e00008, // jr    ra
		0x00000000, // nop
	}
	for w, i in code {(^u32)(&iop.iop_ram[CODE + 4 * i])^ = w}
	r3000.interp_run(CODE)

	check((^u32)(&iop.iop_ram[0x10])^ == 0xdeadbeef, "store through the mirror lands in RAM")
	check(hle^ == 0x5a5a5a5a, "the HLE's area untouched by IOP code")
	check(r3000.state.r[11] == 0xdeadbeef, "kseg1 load reads RAM")
	check(len(far) == 1 && far[0] == {0x1f900000, 0xdeadbeef, 4}, "SPU2 store reaches io_far_write")
	check(r3000.state.cycles == u64(len(code)) * r3000.CYCLES_PER_INSN, "every word ran once")

	(^u32)(&iop.iop_ram[GROW])^ = 0x3c0cbf90 // lui t4, 0xbf90
	for k in u32(0) ..< GROWN {(^u32)(&iop.iop_ram[GROW + 4 + 4 * k])^ = 0x8d8d0000 | 4 * k} // lw t5, 4k(t4)
	(^u32)(&iop.iop_ram[GROW + 4 + 4 * GROWN])^ = 0x03e00008 // jr ra
	(^u32)(&iop.iop_ram[GROW + 8 + 4 * GROWN])^ = 0
	check(len(iop.iop_io_seen) == 0, "no device address read yet")
	core.snap_op, core.snap_target = .Save, &snap
	core.snap_yield()
	// Here after the save, and again after the load.
	if !loaded {
		r3000.interp_run(GROW)
		check(len(iop.iop_io_seen) == GROWN, "each SPU2 address logged once")
		(^u32)(&iop.iop_ram[0x10])^ = 0
		loaded = true
		core.snap_op, core.snap_target = .Load, &snap
		core.snap_yield()
	}
	check((^u32)(&iop.iop_ram[0x10])^ == 0xdeadbeef, "IOP RAM restored by the snapshot")
	check(len(iop.iop_io_seen) == 0, "logged addresses restored by the snapshot")
	r3000.interp_run(GROW)
	check(len(iop.iop_io_seen) == GROWN, "the restored map grows again")
	for k in u32(0) ..< GROWN {check(0x1f900000 + 4 * k in iop.iop_io_seen, "SPU2 address in the map")}

	if failed {os.exit(1)}
	fmt.println("ok ps2_iop")
	os.exit(0)
}

main :: proc() {
	core.snap_init(1 << 20)
	iop.sif_snap()
	mem.mem_init()
	iop.sif_init()
	context.allocator = core.emu_allocator()
	core.co_allocator = context.allocator
	core.snap_run(core.co_create(game, nil))
}
