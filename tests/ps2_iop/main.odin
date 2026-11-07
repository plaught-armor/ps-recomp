// IOP CPU test: psx_cpu's R3000 run as the IOP over iop_ram, with
// hand-assembled words. A store to 0x00200010 lands in RAM through the 2 MiB
// mirror and leaves the HLE's own area at that IOP address alone; a kseg1
// load reads it back; a kseg1 store to SPU2 (0x1f900000), outside psx's
// device window, reaches io_far_write at its physical address; `jr ra`
// returns from interp_run; the IOP has no GTE. A snapshot restores RAM and
// the map of logged device addresses, which grows after the save: after the
// load it is empty again and grows cleanly.
//
// sysmem: the EE heap RPC's addresses equal the bump allocator's it replaced
// for allocs, newest-block frees and size 0; first-fit, top-down, fixed
// address, free and merge. IRX: a synthetic module is parsed, relocated
// (each type, HI16/LO16 pairing with and without a carry, two HI16 to one
// LO16) and scanned for its library tables, with magic words outside a
// table rejected; a bad type and an orphan HI16 are refused.
//
// loadcore: synthetic modules are loaded and started. An import of a
// registered export is patched to jump to it; a pending one is patched when
// a later module registers its library, and a call before that is a compat
// row; a module allocates through its sysmem stub; an unknown function
// returns -1 with one compat row and fails the load; a failed load undoes
// what it registered, mapped, patched in another module and allocated; a
// NO_RESIDENT_END start frees the module; a spinning start runs out of its
// budget; a snapshot restores the loader, and a load after it lands where
// the first did.
//
// IOP threads: a start makes a semaphore and two threads, which run after it
// returns, best priority first; a signal that wakes a better thread yields to
// it at once. A start that waits with no thread ready fails with one compat
// row, and the undo deletes its threads, semaphores and coroutines. A path
// whose load failed is not run again until a library registers or a load
// succeeds. A thread spinning after its start returned spends
// the budget: the load still succeeds, with one compat row, and the thread
// stays ready with its context saved. intrman, printf, strtol, memset and
// memcpy answer as the C library does. A snapshot taken while a thread waits
// restores it, coroutine stack included, so a signal after the load wakes it
// where it waited.
//
// Commands: a packet the EE sends to a command with a module's handler runs
// it, and the thread it signals runs at once; that thread's DelayThread
// wakes at the cycle integer math gives, a large delay included, and the
// EE's next event moves up to that wake. The EE's events at the wake run
// the thread, and what it sends with sceSifSendCmd is in EE RAM when they
// return. One coroutine serves every handler; one that waits is stopped
// with a compat row and its coroutine killed, and the next delivery makes
// another. The loader's reset kills it.
//
// libsd: a block transfer libsd starts plays its buffer de-interleaved from
// the ADMA layout at its core's BVOL, wrapping when it loops, silent once
// stopped or at BVOL 0. Its transfer
// handler runs at each half of the buffer (and a one-shot's end, not past
// it), with a0 the channel, the EE's wake set to the crossing and the thread
// it signals running after it; one started inside its buffer crosses at the
// next half, and with no handler a block adds no wake and runs nothing. A
// snapshot before the first crossing restores the handler and drops the
// coroutine made since. Voice transfers write and read sound RAM, a keyed
// voice plays with ENVX at full, VOLX is its volume and a VOLL sweep moves
// VOLXL alone. A voice entering the block at IRQA of a core with its IRQ
// enabled runs the SPU2 handler once, a0 the core's bit, for either core,
// and the IRQ is off after; so does the input area's read reaching IRQA, at
// the EE cycle it takes that position, restored pending by a snapshot. The
// input area plays at BVOL, its read at IRQA the sample at that cycle; a
// block playing into a core takes its place, at the same BVOL. The other
// VOLL sweeps step as PCSX2's, bit 12 turning the step, and a write keeps
// the counter; it counts as PCSX2's, clamping only at a step, an
// exponential decrease rounding down, at shift 27 adding 1 and at step 3
// 0, and a sweep steps on a voice not playing. A voice transfer runs its
// channel's handler. A stopped voice still runs through its blocks and
// raises the IRQ at IRQA. Undecoded ids are compat rows; the loader's reset
// clears the handlers.
//
// cdvdman and ioman, on a synthetic disc image: SearchFile writes a file's
// record and a miss leaves it; sceCdRead copies whole sectors from the lsn
// to the buffer, zeros past the volume, and a data pattern reads nothing
// with a compat row; sceCdInit and sceCdMmode return 1; sceCdGetReadPos is
// 0 idle and after a read, no read being in flight. sceCdCallback
// returns the previous callback; a read's runs at the next tick, a0 1, and
// not for a refused read or with none set; a snapshot restores it pending;
// one that waits is a row; a failed load's is put back. ioman's open,
// read, lseek and close share fileio's fd table: a read over sectors gets
// the file's bytes, a closed fd is bad and then reused, fileio's reset
// closes ioman's files, a write open fails as fileio's, and another device
// is a compat row.
//
// cdvdfsv's SearchFile server, on a dual-layer image: an old 0x124 request
// reads its path at 0x20 and gets a 0x20 record, as does any size but 0x128
// and 0x12c; 0x128 searches the first layer; any nonzero layer word searches
// the second; a miss writes nothing. ReadDvdDualInfo answers on_dual 1 and
// the second layer's start there, on a single-layer image on_dual 0 and the
// image's sector count.
//
// padman: GetButtonMask, SetButtonMask, SetVref, GetPortMax and GetSlotMax
// answer in the result word each uses, 0 for a socket not open; a button
// mask sets the pad data's mode as the wire pad's 0x4f does: pressures and
// length 20 for the full mask, analog without them, digital for a partial
// one, back to analog on Open. GetSlotMax is 4 once the multitap is open.
// An unknown command is a row answered 0.
//
// sdrdrv: a user command handler's slot, range and previous handler; an
// EE RPC to a set slot is a row answered 0; snapshot, reset and undo.
//
// timrman: allocation order and errors; a sysclock timer's compare handler
// at its cycle, its v0 the next compare and 0 a stop; catching up; -100 and
// a stop with a row from interrupt context; 16-bit compares; another source
// a row; snapshot, reset and undo.
package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "ps:core"
import "ps:core/disc"
import iop "ps:ps2/iop"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import mem "ps:ps2/mem"
import r3000 "ps:psx/cpu"
import "ps:tests/discimg"

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
	check(r3000.bios_entry == iop.iop_hle_entry && r3000.ram_keep == nil, "the IOP's stubs, no RAM watch")
	check(len(r3000.dispatch.fixed) == r3000.RAM_SIZE / 4, "an empty dispatch table, mapped read-only")
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

	test_heap()
	test_sysmem()
	test_irx()
	test_loader_snap()
	test_loader()
	test_modload()
	test_threads()
	test_failed_paths()
	test_irx_mem_size()
	test_thread_budget()
	test_libc()
	test_sysclib()
	test_import_major()
	test_sony_stream()
	test_thread_snap()
	test_event_flags()
	test_event_snap()
	test_event_undo()
	test_sio2_lock()
	test_sio2_lock_snap()
	test_sio2_lock_undo()
	test_sio2_lock_undo_held()
	test_sio2_stat()
	test_ds2()
	test_padman()
	test_sifcmd()
	test_other_data()
	test_cmd_deliver()
	test_reply_due()
	test_rpc_bind()
	test_rpc()
	test_rpc_remove()
	test_rpc_self_remove()
	test_cdvd_poff()
	test_rpc_client()
	test_rpc_pool_kept()
	test_c1_gaps()
	test_msgbx()
	test_start_intr()
	test_call_context()
	test_sifman()
	test_sif_dma_intr()
	test_libsd()
	test_vblank_samples()
	test_cdvdman()
	test_cdvd_search_server()
	test_fileio_getstat()
	test_cd_type()
	test_sdrdrv()
	test_sdr_thread()
	test_timrman()
	test_system_time()
	test_alarm()
	test_wakeup_cancel()
	test_release_wait()
	test_vblank()
	test_vblank_handlers()
	test_fallback()
	test_usbd()
	test_boot_gaps()

	if failed {os.exit(1)}
	fmt.println("ok ps2_iop")
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

// The EE heap's allocator before sysmem: a bump over 0x40000..0x100000 that
// takes back only the newest block.
Bump :: struct {
	top, last: u32,
}

bump_alloc :: proc(b: ^Bump, req: u32) -> u32 {
	size := (req + 0xff) &~ 0xff
	if b.top + size > 0x100000 {return 0}
	a := b.top
	b.last = a
	b.top += size
	return a
}

bump_free :: proc(b: ^Bump, a: u32) {
	if a == b.last && b.last != 0 {b.top, b.last = b.last, 0}
}

test_heap :: proc() {
	iop.sys_init()
	b := Bump{top = 0x40000}
	// >= 0 allocates that many bytes (0 is a size-0 alloc); -1 frees the
	// latest result, a second time too.
	ops := [?]i32{0x10, 0x100, 0x101, 0, 0x2345, -1, 0x80, -1, -1, 0, -1, 0, 0x400, -1, 0x1000, 0x7f, -1, -1}
	got: [dynamic]u32
	defer delete(got)
	for op, i in ops {
		switch {
		case op >= 0:
			want := bump_alloc(&b, u32(op))
			a := iop.iop_heap_alloc(u32(op))
			check(a == want, fmt.tprintf("heap op %d: alloc %x at %x, bump %x", i, op, a, want))
			append(&got, a)
		case:
			a := got[len(got) - 1]
			bump_free(&b, a)
			iop.iop_heap_free(a)
		}
	}
	check(iop.iop_heap_alloc(0x40) == bump_alloc(&b, 0x40), "heap: next alloc after the sequence")
}

test_sysmem :: proc() {
	iop.sys_init()
	a := iop.sys_alloc(.Low, 0x100)
	b := iop.sys_alloc(.High, 0x1ff)
	c := iop.sys_alloc(.Addr, 0x100, 0x80000)
	check(a == 0x40000 && b == 0x1ffe00 && c == 0x80000, "sysmem: low, high, fixed")
	check(iop.sys_alloc(.Addr, 0x100, 0x80080) == 0, "sysmem: fixed address unaligned")
	check(iop.sys_alloc(.Addr, 0x100, 0x80000) == 0, "sysmem: fixed address taken")
	d := iop.sys_alloc(.Low, 0x40000)
	check(d == 0x80100, "sysmem: first fit skips a gap too small")
	check(iop.sys_alloc(.Low, 0x200000) == 0, "sysmem: larger than RAM")
	check(iop.sys_free(c) && !iop.sys_free(c), "sysmem: free once")
	check(iop.sys_alloc(.Low, 0x40000) == 0x40100, "sysmem: freed block merges with its gap")
	largest, total := iop.sys_free_sizes()
	check(largest == 0x1ffe00 - 0xc0100 && total == largest, "sysmem: free sizes")
	iop.sys_init()
	check(iop.iop_heap_alloc_at(1, 0x100, 0) == 0x1fff00, "heap rpc alloc_at: high")
	check(iop.iop_heap_alloc_at(2, 0x100, 0x80080000) == 0x80000, "heap rpc alloc_at: fixed address, kseg0 masked")
	check(iop.iop_heap_alloc_at(0, 0x100, 0x12345) == 0x40000, "heap rpc alloc_at: low ignores the address")
	check(iop.iop_heap_alloc_at(3, 0x100, 0) == 0, "heap rpc alloc_at: unknown kind gets 0")
}

IRX_BASE :: 0x40000

// The synthetic module's text: relocated words, an import table of two stubs
// to "sysmem", an export table of two functions, and three magic words that
// head no table.
irx_text := [?]u32 {
	0x00000060, // 0x00 R_MIPS_32 -> base + 0x60
	0x0c000018, // 0x04 jal 0x60, R_MIPS_26
	0x3c080001, // 0x08 lui t0, 1           HI16
	0x3c090002, // 0x0c lui t1, 2           HI16, the same LO16
	0x25088000, // 0x10 addiu t0, t0, -0x8000  LO16: carries into the HI16s
	0x3c0a0000, // 0x14 lui t2, 0           HI16
	0x254a7ff0, // 0x18 addiu t2, t2, 0x7ff0   LO16: no carry
	0x8f880010, // 0x1c lw t0, 0x10(gp)     GPREL16: unchanged
	0x00001234, // 0x20 R_MIPS_NONE
	IMPORT, 0, 0x0102, 0x6d737973, 0x00006d65, // 0x24 import "sysmem" 1.2
	JR_RA, 0x24000004, JR_RA, 0x24000005, 0, 0, // 0x38 stubs 4, 5; end
	EXPORT, 0, 0x0101, 0x74736574, 0x00646f6d, // 0x50 export "testmod" 1.1
	0x00000070, 0x00000074, 0, // 0x64 R_MIPS_32 each; end
	JR_RA, 0, // 0x70
	IMPORT, 0x00001234, // 0x78 a next link: no table
	EXPORT, 0, 0x0000ffff, 0x74736574, 0x00646f6d, 0, 0, 0, // 0x80 major version 0xff
	IMPORT, 0, 0x0101, 0x00000078, 0, JR_RA, 0x24000001, JR_RA, // 0xa0 stubs run off the text
}
IMPORT :: 0x41e00000
EXPORT :: 0x41c00000
JR_RA :: 0x03e00008

Rel :: struct {
	off, type: u32,
}

irx_rels := [?]Rel{{0x00, 2}, {0x04, 4}, {0x08, 5}, {0x0c, 5}, {0x10, 6}, {0x14, 5}, {0x18, 6}, {0x1c, 7}, {0x20, 0}, {0x64, 2}, {0x68, 2}}

// The synthetic module's IRX file with relocations `rels`.
build_irx :: proc(rels: []Rel) -> []u8 {
	return build_file("testmod", irx_text[:], rels, 0x10)
}

// An IRX file of module `name`: ELF header, the IOPMOD and PT_LOAD headers,
// the module info, `text` at 0x100 and 0x40 bytes of bss, then one SHT_REL
// section of `rels`.
build_file :: proc(name: string, text: []u32, rels: []Rel, entry: u32) -> []u8 {
	TEXT :: 0x100
	text_size := u32(len(text) * 4)
	rel := TEXT + text_size
	sh := rel + u32(len(rels) * 8)
	f := make([]u8, sh + 80, context.temp_allocator)
	w32 :: proc(f: []u8, o: u32, v: u32) {endian.put_u32(f[o:], .Little, v)}
	w16 :: proc(f: []u8, o: u32, v: u16) {endian.put_u16(f[o:], .Little, v)}
	copy(f, "\x7fELF\x01\x01\x01")
	w16(f, 16, 0xff80)
	w16(f, 18, 8)
	w32(f, 20, 1)
	w32(f, 28, 0x34)
	w32(f, 32, sh)
	w16(f, 40, 52)
	w16(f, 42, 32)
	w16(f, 44, 2)
	w16(f, 46, 40)
	w16(f, 48, 2)
	w32(f, 0x34, 0x70000080) // PT_SCE_IOPMOD
	w32(f, 0x38, 0x74)
	w32(f, 0x54, 1) // PT_LOAD at 0
	w32(f, 0x58, TEXT)
	w32(f, 0x64, text_size)
	w32(f, 0x68, text_size + 0x40)
	// module info: entry, gp, text, data, bss, version, name
	for v, i in ([?]u32{0, entry, 0x8010, text_size, 0, 0x40}) {w32(f, 0x74 + u32(i) * 4, v)}
	w16(f, 0x74 + 24, 0x0102)
	copy(f[0x74 + 26:][:8], name)
	for v, i in text {w32(f, TEXT + u32(i) * 4, v)}
	for r, i in rels {
		w32(f, rel + u32(i) * 8, r.off)
		w32(f, rel + u32(i) * 8 + 4, r.type)
	}
	w32(f, sh + 40 + 4, 9) // SHT_REL; section 0 is the null one
	w32(f, sh + 40 + 16, rel)
	w32(f, sh + 40 + 20, u32(len(rels) * 8))
	return f
}

// Loads file `f` at IRX_BASE as a loader would, and relocates it.
load_irx :: proc(f: []u8) -> (x: iop.Irx, img: []u8, err: iop.Irx_Error, detail: u32) {
	ok: bool
	x, ok = iop.irx_parse(f)
	check(ok, "irx: parses")
	size, _ := iop.irx_mem_size(x)
	img = iop.iop_ram[IRX_BASE:][:size]
	copy(img, f[x.file_off:][:x.file_size])
	for &b in img[x.file_size:] {b = 0}
	err, detail = iop.irx_relocate(f, img, IRX_BASE)
	return
}

test_irx :: proc() {
	x, img, err, _ := load_irx(build_irx(irx_rels[:]))
	check(x.name == "testmod" && x.version == 0x0102 && x.entry == 0x10 && x.gp == 0x8010, "irx: module info")
	check(x.text_size == 0xc0 && x.bss_size == 0x40 && x.file_off == 0x100 && x.file_size == 0xc0, "irx: sizes")
	check(err == .None, "irx: relocates")
	want := [?][2]u32 {
		{0x00, 0x00040060},
		{0x04, 0x0c010018},
		{0x08, 0x3c080005}, // naive (high half only) would be 4
		{0x0c, 0x3c090006},
		{0x10, 0x25088000},
		{0x14, 0x3c0a0004},
		{0x18, 0x254a7ff0},
		{0x1c, 0x8f880010},
		{0x20, 0x00001234},
		{0x64, 0x00040070},
		{0x68, 0x00040074},
	}
	for ov in want {
		off, v := ov[0], ov[1]
		got, _ := endian.get_u32(img[off:], .Little)
		check(got == v, fmt.tprintf("irx: word %02x is %08x, want %08x", off, got, v))
	}

	tables := iop.irx_tables(img[:x.text_size], IRX_BASE)
	defer delete(tables)
	check(len(tables) == 2, fmt.tprintf("irx: %d tables found, want 2", len(tables)))
	if len(tables) == 2 {
		im, ex := tables[0], tables[1]
		check(im.off == 0x24 && im.imports && im.version == 0x0102 && im.count == 2, "irx: import table")
		check(string(im.name[:6]) == "sysmem" && im.name[6] == 0, "irx: import name")
		check(ex.off == 0x50 && !ex.imports && ex.version == 0x0101 && ex.count == 2, "irx: export table")
		check(string(ex.name[:7]) == "testmod", "irx: export name")
	}

	bad := [?]Rel{{0x00, 2}, {0x04, 3}}
	_, _, err2, detail := load_irx(build_irx(bad[:]))
	check(err2 == .Type && detail == 3, "irx: R_MIPS_REL32 refused")
	orphan := [?]Rel{{0x08, 5}, {0x10, 6}, {0x14, 5}}
	_, _, err3, at := load_irx(build_irx(orphan[:]))
	check(err3 == .Orphan_Hi16 && at == 0x14, "irx: orphan HI16 refused")

	f := build_irx(irx_rels[:])
	endian.put_u16(f[16:], .Little, 2)
	_, ok := iop.irx_parse(f)
	check(!ok, "irx: an executable ELF is no IRX")
}

// File `f` from build_file with its module info's bss and its p_memsz changed.
irx_sizes :: proc(f: []u8, bss, memsz: u32) -> []u8 {
	endian.put_u32(f[0x88:], .Little, bss)
	endian.put_u32(f[0x68:], .Little, memsz)
	return f
}

test_irx_mem_size :: proc() {
	size_of_file :: proc(bss, memsz: u32) -> (u32, bool) {
		x, ok := iop.irx_parse(irx_sizes(build_irx(irx_rels[:]), bss, memsz))
		check(ok, "irx size: parses")
		return iop.irx_mem_size(x)
	}
	TEXT :: 0xc0
	RAM :: iop.IOP_RAM_SIZE
	s, ok := size_of_file(0x40, TEXT + 0x40)
	check(ok && s == TEXT + 0x40, "irx size: info and p_memsz agree")
	s, ok = size_of_file(0, TEXT + 0x100)
	check(ok && s == TEXT + 0x100, "irx size: p_memsz over an info with no bss")
	s, ok = size_of_file(0x40, TEXT)
	check(ok && s == TEXT + 0x40, "irx size: info over p_memsz")
	s, ok = size_of_file(0, RAM)
	check(ok && s == RAM, "irx size: all of RAM fits")
	_, ok = size_of_file(0, TEXT - 1)
	check(!ok, "irx size: p_memsz under the file's bytes refused")
	_, ok = size_of_file(0, RAM + 1)
	check(!ok, "irx size: p_memsz over RAM refused")
	_, ok = size_of_file(0, 0xffffffff)
	check(!ok, "irx size: largest p_memsz refused")
	_, ok = size_of_file(RAM + 1 - TEXT, TEXT)
	check(!ok, "irx size: info over RAM refused")
	_, ok = size_of_file(0xffffff41, TEXT) // wraps to 1 in 32 bits
	check(!ok, "irx size: info that wraps refused")

	// A load: the block holds p_memsz, zeroed past the file's bytes, a relocation
	// lands past what the module info says, and the next block starts after it.
	refs := [?]Rel{{TEXT_MEM + 0x10, 2}}
	TEXT_MEM :: 8
	text := [?]u32{JR_RA, 0x24020000}
	f := irx_sizes(build_file("modsz", text[:], refs[:], 0), 0, TEXT_MEM + 0x100)
	fresh()
	for &b in iop.iop_ram[iop.SYS_BASE:][:0x1000] {b = 0xaa}
	id, _ := iop.iop_load(f, "modsz", nil)
	check(id > 0, "irx size: loads")
	base := module_base(id)
	for m in iop.iop_loader.modules {
		if i32(m.id) == id {check(m.size == TEXT_MEM + 0x100, "irx size: module block")}
	}
	check(iop.iop_u32(base + TEXT_MEM + 0x10)^ == base, "irx size: relocation past the module info")
	dirty := 0
	for i in u32(TEXT_MEM) ..< TEXT_MEM + 0x100 {
		if i &~ 3 != TEXT_MEM + 0x10 && iop.iop_ram[base + i] != 0 {dirty += 1}
	}
	check(dirty == 0, "irx size: zeroed to p_memsz")
	next := iop.sys_alloc(.Low, 0x10)
	check(next >= base + TEXT_MEM + 0x100, "irx size: next block past p_memsz")

	// A refused one takes the failed load's path and leaves nothing allocated.
	refuse :: proc(path: string, bss, memsz: u32, what: string) {
		text := [?]u32{JR_RA, 0x24020000}
		f := irx_sizes(build_file(path, text[:], nil, 0), bss, memsz)
		key := core.Compat_Key{.Iop_Fallback, core.compat_name(path), 0}
		fresh()
		rows := core.compat.calls[key].n
		id, _ := iop.iop_load(f, path, nil)
		check(id == iop.KE_ERROR && core.compat.calls[key].n == rows + 1, fmt.tprintf("irx size: %s fails the load", what))
		check(len(iop.sys_blocks) == 0 && len(iop.iop_loader.modules) == 0, fmt.tprintf("irx size: %s leaves nothing", what))
		id, _ = iop.iop_load(f, path, nil)
		check(id == iop.KE_ERROR, fmt.tprintf("irx size: %s is not tried again", what))
	}
	refuse("modsz1", 0, 4, "p_memsz under the file's bytes")
	refuse("modsz2", 0, iop.IOP_RAM_SIZE + 1, "p_memsz over RAM")
	refuse("modsz3", iop.IOP_RAM_SIZE, 8, "info over RAM")
	refuse("modsz4", 0, iop.IOP_RAM_SIZE, "a block over sysmem's range")
}

// A module's text as it is assembled: words, and their relocations.
Asm :: struct {
	w:    [dynamic]u32,
	rels: [dynamic]Rel,
}

at :: proc(a: ^Asm) -> u32 {return u32(len(a.w)) * 4}
put :: proc(a: ^Asm, words: ..u32) {append(&a.w, ..words)}
put_rel :: proc(a: ^Asm, w, type: u32) {
	append(&a.rels, Rel{at(a), type})
	put(a, w)
}

name_words :: proc(s: string) -> (n: [2]u32) {
	copy((^[8]u8)(&n)[:], s)
	return
}

// An import table of `lib` 1.1; the offset of its first stub.
imports :: proc(a: ^Asm, lib: string, fnos: ..u32) -> u32 {
	return imports_v(a, lib, 0x0101, ..fnos)
}

// imports, of `lib` at `version`.
imports_v :: proc(a: ^Asm, lib: string, version: u32, fnos: ..u32) -> u32 {
	n := name_words(lib)
	put(a, IMPORT, 0, version, n[0], n[1])
	stubs := at(a)
	for f in fnos {put(a, JR_RA, 0x24000000 | f)}
	put(a, 0, 0)
	return stubs
}

// An export table of `lib` 1.1 with one function, which the caller fills in
// at word `ptr`; the table's offset.
exports :: proc(a: ^Asm, lib: string) -> (table: u32, ptr: int) {
	n := name_words(lib)
	table = at(a)
	put(a, EXPORT, 0, 0x0101, n[0], n[1])
	ptr = len(a.w)
	put_rel(a, 0, 2)
	put(a, 0)
	return
}

T0 :: 8
A0 :: 4
A1 :: 5
A2 :: 6

la :: proc(a: ^Asm, rt, off: u32) {
	put_rel(a, 0x3c000000 | rt << 16, 5) // lui rt, 0
	put_rel(a, 0x24000000 | rt << 21 | rt << 16 | off, 6) // addiu rt, rt, off
}
jal :: proc(a: ^Asm, off: u32) {
	put_rel(a, 0x0c000000 | off >> 2, 4)
	put(a, 0)
}
li :: proc(a: ^Asm, rt, imm: u32) {put(a, 0x24000000 | rt << 16 | imm)} // addiu rt, zero, imm
store_v0 :: proc(a: ^Asm, off: u32) {
	la(a, T0, off)
	put(a, 0xad020000) // sw v0, 0(t0)
}
prologue :: proc(a: ^Asm) {put(a, 0x27bdfff0, 0xafbf0000)} // addiu sp, sp, -16; sw ra, 0(sp)
// Returns v0 as it stands.
epilogue :: proc(a: ^Asm) {put(a, 0x8fbf0000, JR_RA, 0x27bd0010)} // lw ra, 0(sp); jr ra; addiu sp, sp, 16

// An IRX file of module `name` with text `a`, its start at `entry`.
build_mod :: proc(name: string, a: ^Asm, entry: u32) -> []u8 {
	return build_file(name, a.w[:], a.rels[:], entry)
}

fresh :: proc() {
	iop.sys_init()
	iop.iop_loader_init()
}

// "moda": registers "liba", whose function 0 returns 0x700.
mod_a :: proc() -> (f: []u8, f0: u32) {
	a: Asm
	lc := imports(&a, "loadcore", 6)
	tbl, ptr := exports(&a, "liba")
	f0 = at(&a)
	put(&a, JR_RA, 0x24020700) // jr ra; li v0, 0x700
	a.w[ptr] = f0
	entry := at(&a)
	prologue(&a)
	la(&a, A0, tbl)
	jal(&a, lc)
	epilogue(&a)
	return build_mod("moda", &a, entry), f0
}

// "modb": imports liba's function 0; with `call` its start returns what
// that returns, else 0.
mod_b :: proc(call: bool) -> (f: []u8, stub: u32) {
	a: Asm
	stub = imports(&a, "liba", 0)
	entry := at(&a)
	if call {
		prologue(&a)
		jal(&a, stub)
		epilogue(&a)
	} else {
		put(&a, JR_RA, 0x24020000)
	}
	return build_mod("modb", &a, entry), stub
}

// Calls `addr` from the host as a module would.
iop_call :: proc(addr: u32) -> u32 {
	r3000.state.r[31] = 0
	r3000.call(addr)
	return r3000.state.r[2]
}

module_base :: proc(id: i32) -> u32 {
	for m in iop.iop_loader.modules {
		if i32(m.id) == id {return m.base}
	}
	return 0
}

snap2: core.Snapshot
snap2_loaded: bool // not emulated state
snap2_base: u32

test_loader_snap :: proc() {
	fresh()
	core.snap_op, core.snap_target = .Save, &snap2
	core.snap_yield()
	if !snap2_loaded {
		fa, _ := mod_a()
		ida, _ := iop.iop_load(fa, "moda", nil)
		fb, _ := mod_b(true)
		idb, rb := iop.iop_load(fb, "modb", nil)
		check(ida > 0 && idb > 0 && rb == 0x700, "loader snapshot: both load")
		snap2_base = module_base(ida)
		snap2_loaded = true
		core.snap_op, core.snap_target = .Load, &snap2
		core.snap_yield()
	}
	l := &iop.iop_loader
	check(len(l.libs) == 0 && len(l.stubs) == 0 && len(l.modules) == 0 && len(l.pending) == 0, "loader snapshot: loader restored")
	check(len(iop.sys_blocks) == 0, "loader snapshot: sysmem restored")
	fa, _ := mod_a()
	ida, _ := iop.iop_load(fa, "moda", nil)
	check(ida > 0 && module_base(ida) == snap2_base, "loader snapshot: a load after it lands where the first did")
}

test_loader :: proc() {
	l := &iop.iop_loader

	// An import of a registered export.
	fresh()
	fa, f0 := mod_a()
	ida, ra := iop.iop_load(fa, "moda", nil)
	check(ida > 0 && ra == 0, "loader: moda starts resident")
	check(len(l.libs) == 1 && string(l.libs[0].name[:4]) == "liba" && l.libs[0].count == 1, "loader: liba registered")
	fb, stub := mod_b(true)
	idb, rb := iop.iop_load(fb, "modb", nil)
	check(idb > 0 && rb == 0x700, "loader: modb's start calls liba through its stub")
	bb := module_base(idb)
	fa0 := module_base(ida) + f0
	check(iop.iop_u32(bb + stub)^ == 0x08000000 | fa0 >> 2 && iop.iop_u32(bb + stub + 4)^ == 0, "loader: stub patched to j export; nop")

	// A pending import, called before and after its library is registered.
	fresh()
	fb2, stub2 := mod_b(false)
	idb2, _ := iop.iop_load(fb2, "modb", nil)
	b2 := module_base(idb2)
	check(idb2 > 0 && len(l.pending) == 1 && (b2 + stub2) in l.stubs, "loader: import of an unregistered library pends")
	key := core.Compat_Key{.Iop_Import, core.compat_name("liba"), 0}
	check(iop_call(b2 + stub2) == 0xffffffff && core.compat.calls[key].n == 1, "loader: a pending stub returns -1 with a compat row")
	ida2, _ := iop.iop_load(fa, "moda", nil)
	check(ida2 > 0 && len(l.pending) == 0 && (b2 + stub2) not_in l.stubs, "loader: registering resolves the pending import")
	check(iop_call(b2 + stub2) == 0x700, "loader: the patched stub reaches the export")

	// Allocation through sysmem, and an unknown function.
	fresh()
	c: Asm
	sm := imports(&c, "sysmem", 4, 99)
	d := at(&c)
	put(&c, 0, 0, 0)
	entry := at(&c)
	prologue(&c)
	for k in u32(0) ..< 2 {
		li(&c, A0, 0)
		li(&c, A1, 0x100)
		li(&c, A2, 0)
		jal(&c, sm)
		store_v0(&c, d + 4 * k)
	}
	epilogue(&c)
	idc, rc := iop.iop_load(build_mod("modc", &c, entry), "modc", nil)
	cb := module_base(idc)
	x, y := iop.iop_u32(cb + d)^, iop.iop_u32(cb + d + 4)^
	check(idc > 0 && rc & 3 == 0, "loader: modc starts")
	check(x != 0 && y >= x + 0x100 && x >= cb + 0x100, fmt.tprintf("loader: AllocSysMemory blocks %x %x apart from the module at %x", x, y, cb))

	e: Asm
	sm = imports(&e, "sysmem", 4, 99)
	d = at(&e)
	put(&e, 0x5a5a5a5a)
	entry = at(&e)
	prologue(&e)
	jal(&e, sm + 8)
	store_v0(&e, d)
	epilogue(&e)
	before := slice_clone(iop.sys_blocks[:])
	fe := build_mod("mode", &e, entry)
	base_e := iop.sys_alloc(.Low, 0x100) // where the module will land
	iop.sys_free(base_e)
	ide, _ := iop.iop_load(fe, "mode", nil)
	key = core.Compat_Key{.Iop_Call, core.compat_name("sysmem"), 99}
	check(ide == -1 && core.compat.calls[key].n == 1, "loader: unknown fno fails the load with a compat row")
	check(iop.iop_u32(base_e + d)^ == 0xffffffff, "loader: the unknown fno returned -1 (the write stays)")
	check(blocks_equal(before, iop.sys_blocks[:]), "loader: the failed module's memory freed")

	// A failed load undoes what it did, in another module too.
	fresh()
	p: Asm
	ps := imports(&p, "libf", 0)
	put(&p, JR_RA, 0x24020000)
	idp, _ := iop.iop_load(build_mod("modp", &p, ps + 16), "modp", nil)
	pb := module_base(idp)
	f: Asm
	lc := imports(&f, "loadcore", 6)
	fs := imports(&f, "sysmem", 4, 99)
	imports(&f, "libz", 0)
	tbl, ptr := exports(&f, "libf")
	f.w[ptr] = at(&f)
	put(&f, JR_RA, 0)
	entry = at(&f)
	prologue(&f)
	la(&f, A0, tbl)
	jal(&f, lc)
	li(&f, A0, 1)
	li(&f, A1, 0x100)
	jal(&f, fs)
	jal(&f, fs + 8)
	epilogue(&f)
	libs, pending, stubs := len(l.libs), len(l.pending), len(l.stubs)
	before = slice_clone(iop.sys_blocks[:])
	idf, _ := iop.iop_load(build_mod("modf", &f, entry), "modf", nil)
	check(idf == -1, "loader: modf fails")
	check(len(l.libs) == libs && len(l.pending) == pending && len(l.stubs) == stubs, "loader: registrations, pending imports and stubs undone")
	check(blocks_equal(before, iop.sys_blocks[:]), "loader: image and AllocSysMemory blocks freed")
	check(iop.iop_u32(pb + ps)^ == JR_RA && iop.iop_u32(pb + ps + 4)^ == 0x24000000, "loader: the stub patched in modp restored")
	check((pb + ps) in l.stubs && l.stubs[pb + ps].pending, "loader: modp's import pends again")

	// NO_RESIDENT_END frees the module and its stubs.
	g: Asm
	imports(&g, "sysmem", 4)
	entry = at(&g)
	put(&g, JR_RA, 0x24020001)
	stubs = len(l.stubs)
	before = slice_clone(iop.sys_blocks[:])
	idg, rg := iop.iop_load(build_mod("modg", &g, entry), "modg", nil)
	check(idg > 0 && rg == 1 && module_base(idg) == 0, "loader: NO_RESIDENT_END is not kept")
	check(len(l.stubs) == stubs && blocks_equal(before, iop.sys_blocks[:]), "loader: NO_RESIDENT_END frees memory and stubs")

	// A start that spins.
	sp: Asm
	entry = at(&sp)
	put_rel(&sp, 0x08000000 | entry >> 2, 4) // j .
	put(&sp, 0)
	before = slice_clone(iop.sys_blocks[:])
	ids, _ := iop.iop_load(build_mod("spin", &sp, entry), "spin", nil)
	key = core.Compat_Key{.Iop_Start, core.compat_name("spin"), 0}
	check(ids == -1 && core.compat.calls[key].n == 1, "loader: a spinning start runs out of its budget")
	check(blocks_equal(before, iop.sys_blocks[:]), "loader: the spinning module freed")
	check(r3000.next_event == iop.IOP_EVENT_OFF, "loader: the budget is off after a start")
}

// ------------------------------------------------------------- modload

// A module started from another's start: "inner" registers "libi"; with
// `gap` it then calls sysmem 99, which the HLE lacks. Its start returns
// `v0`. Named `name`.
mod_inner :: proc(name: string, gap: bool, v0: u32) -> []u8 {
	a: Asm
	lc := imports(&a, "loadcore", 6)
	sm := imports(&a, "sysmem", 99)
	tbl, ptr := exports(&a, "libi")
	a.w[ptr] = at(&a)
	put(&a, JR_RA, 0x24020700)
	entry := at(&a)
	prologue(&a)
	la(&a, A0, tbl)
	jal(&a, lc)
	if gap {jal(&a, sm)}
	li(&a, V0, v0)
	epilogue(&a)
	return build_mod(name, &a, entry)
}

// "pldm", as PLD.IRX loads: LoadModuleBuffer(buf) to word 0, FreeSysMemory
// (buf), StartModule(id, 0, 0, 0, &word 2) to word 1, StartModule of the same
// id again to word 3, of an id never loaded to word 4. Its start returns 0.
// The words' offset.
mod_pldm :: proc(buf: u32) -> (f: []u8, d: u32) {
	a: Asm
	ml := imports(&a, "modload", 10, 8)
	sm := imports(&a, "sysmem", 5)
	d = at(&a)
	put(&a, 0, 0, 0x5a5a5a5a, 0, 0, 0)
	entry := at(&a)
	put(&a, 0x27bdffe0, 0xafbf001c) // addiu sp, sp, -32; sw ra, 28(sp)
	abs :: proc(a: ^Asm, rt, v: u32) {put(a, 0x3c000000 | rt << 16 | v >> 16, 0x34000000 | rt << 21 | rt << 16 | v & 0xffff)}
	abs(&a, A0, buf)
	jal(&a, ml)
	store_v0(&a, d)
	abs(&a, A0, buf)
	jal(&a, sm)
	start :: proc(a: ^Asm, ml, d, id_at, out: u32, id: u32 = 0) {
		if id_at != 0 {lw_at(a, A0, d)} else {li(a, A0, id)}
		li(a, A1, 0)
		li(a, A2, 0)
		li(a, A3, 0)
		la(a, T0, d + 8)
		put(a, 0xafa80010) // sw t0, 16(sp)
		jal(a, ml + 8)
		store_v0(a, out)
	}
	start(&a, ml, d, 1, d + 4)
	start(&a, ml, d, 1, d + 12)
	start(&a, ml, d, 0, d + 16, 0x999)
	li(&a, V0, 0)
	put(&a, 0x8fbf001c, JR_RA, 0x27bd0020) // lw ra, 28(sp); jr ra; addiu sp, sp, 32
	return build_mod("pldm", &a, entry), d
}

// Loads pldm with `inner` in a buffer of its own; pldm's id and result, and
// its words' address.
run_pldm :: proc(inner: []u8) -> (id: i32, result, words: u32) {
	buf := iop.sys_alloc(.High, u32(len(inner)))
	copy(iop.iop_mem(buf, u32(len(inner))), inner)
	f, d := mod_pldm(buf)
	id, result = iop.iop_load(f, "pldm", nil)
	return id, result, module_base(id) + d
}

libi_registered :: proc() -> bool {
	for &b in iop.iop_loader.libs {
		if string(b.name[:4]) == "libi" {return true}
	}
	return false
}

test_modload :: proc() {
	l := &iop.iop_loader
	w :: proc(words: u32, i: u32) -> u32 {return iop.iop_u32(words + 4 * i)^}
	KE_ERROR :: 0xffffffff
	ALREADY :: transmute(u32)i32(-206)
	UNKNOWN :: transmute(u32)i32(-202)

	// A start that loads and starts another module: StartModule waits for
	// the inner start, its result written, the inner module resident.
	fresh()
	ido, ro, d := run_pldm(mod_inner("inner", false, 0x100))
	idi := i32(w(d, 0))
	check(ido > 0 && ro == 0, "modload: pldm starts resident")
	check(idi > 0 && idi != ido, fmt.tprintf("modload: LoadModuleBuffer gives inner an id of its own (%d, pldm %d)", idi, ido))
	check(w(d, 1) == u32(idi) && w(d, 2) == 0x100, fmt.tprintf("modload: StartModule returns the id, the result written (%x %x)", w(d, 1), w(d, 2)))
	check(w(d, 3) == ALREADY, "modload: a second StartModule is KE_ALREADY_STARTED")
	check(w(d, 4) == UNKNOWN, "modload: StartModule of an id never loaded is KE_UNKNOWN_MODULE")
	check(module_base(idi) != 0 && libi_registered(), "modload: inner kept, its library registered")
	check(l.depth == 0 && l.loading == 0, "modload: no start under way after the load")
	inner_base := module_base(idi)

	// An inner start that calls what the HLE lacks: only its module dropped,
	// pldm loads.
	fresh()
	key := core.Compat_Key{.Iop_Call, core.compat_name("sysmem"), 99}
	n := core.compat.calls[key].n
	ido, ro, d = run_pldm(mod_inner("inner", true, 0))
	idi = i32(w(d, 0))
	check(ido > 0 && ro == 0, "modload: pldm loads although inner's start failed")
	check(core.compat.calls[key].n == n + 1, "modload: inner's gap is one compat row")
	check(w(d, 1) == KE_ERROR && w(d, 2) == 0, "modload: the failed StartModule is KE_ERROR, the start's result written as retail writes it")
	check(!libi_registered() && module_base(idi) == 0, "modload: inner's registration and module undone")
	check(!iop.sys_in(iop.sys_blocks[:], inner_base), "modload: inner's image freed")
	check(w(d, 3) == UNKNOWN, "modload: a failed module is gone for StartModule")
	check(module_base(ido) != 0 && l.depth == 0, "modload: pldm kept")

	// NO_RESIDENT_END from the inner start.
	fresh()
	ido, ro, d = run_pldm(mod_inner("inner", false, 1))
	idi = i32(w(d, 0))
	check(ido > 0 && w(d, 1) == u32(idi) && w(d, 2) == 1, "modload: NO_RESIDENT_END is the result")
	check(module_base(idi) == 0 && !libi_registered(), "modload: a NO_RESIDENT_END inner is dropped")
	check(!iop.sys_in(iop.sys_blocks[:], inner_base), "modload: its image freed")

	// A Sony module: not run, the id 2, a resident result.
	fresh()
	ido, ro, d = run_pldm(mod_inner("cdvdfsv", false, 0x100))
	check(ido > 0 && w(d, 0) == 2 && w(d, 1) == 2 && w(d, 2) == 0, "modload: a Sony module is id 2, started resident")
	check(!libi_registered(), "modload: a Sony module's start does not run")

	// Another thread terminates the inner start while it sleeps: the caller
	// wakes with KE_ERROR, no result written, the module dropped.
	fresh()
	inner := mod_sleeper()
	buf := iop.sys_alloc(.High, u32(len(inner)))
	copy(iop.iop_mem(buf, u32(len(inner))), inner)
	f: []u8
	f, d = mod_pldt(buf)
	ido, ro = iop.iop_load(f, "pldt", nil)
	d += module_base(ido)
	idi = i32(w(d, 0))
	check(ido > 0 && ro == 0 && idi > 0, "modload: pldt loads, the sleeper linked")
	check(w(d, 2) == 0, fmt.tprintf("modload: TerminateThread of the start is KE_OK (%x)", w(d, 2)))
	check(w(d, 1) == KE_ERROR && w(d, 4) == 0x5a5a5a5a, fmt.tprintf("modload: the terminated start's StartModule is KE_ERROR, no result (%x %x)", w(d, 1), w(d, 4)))
	check(module_base(idi) == 0 && !libi_registered() && l.depth == 0, "modload: the terminated start's module dropped, its frame gone")
	waiting := false
	for t in iop.iop_sched.threads {waiting ||= t.status == .Start}
	check(!waiting, "modload: no thread left in StartModule")
}

// "sleeper": registers libi, then sleeps in its start.
mod_sleeper :: proc() -> []u8 {
	a: Asm
	lc := imports(&a, "loadcore", 6)
	tb := imports(&a, "thbase", 24)
	tbl, ptr := exports(&a, "libi")
	a.w[ptr] = at(&a)
	put(&a, JR_RA, 0x24020700)
	entry := at(&a)
	prologue(&a)
	la(&a, A0, tbl)
	jal(&a, lc)
	jal(&a, tb)
	li(&a, V0, 0)
	epilogue(&a)
	return build_mod("sleeper", &a, entry)
}

// "pldt": LoadModuleBuffer(buf) to word 0, then makes and starts thread K
// (priority 20), its id to word 3, and StartModule(id, 0, 0, 0, &word 4) to
// word 1. The start runs first and sleeps; K, ready once both wait,
// terminates it by its id, the one after its own, the result to word 2.
mod_pldt :: proc(buf: u32) -> (f: []u8, d: u32) {
	a: Asm
	ml := imports(&a, "modload", 10, 8)
	tb := imports(&a, "thbase", 4, 6, 10, 20)
	d = at(&a)
	put(&a, 0, 0, 0, 0, 0x5a5a5a5a)
	ek := at(&a)
	prologue(&a)
	jal(&a, tb + 24)
	put(&a, 0x24440001) // addiu a0, v0, 1
	jal(&a, tb + 16)
	store_v0(&a, d + 8)
	epilogue(&a)
	pk := thread_param(&a, ek, 20)
	entry := at(&a)
	put(&a, 0x27bdffe0, 0xafbf001c) // addiu sp, sp, -32; sw ra, 28(sp)
	put(&a, 0x3c000000 | A0 << 16 | buf >> 16, 0x34000000 | A0 << 21 | A0 << 16 | buf & 0xffff)
	jal(&a, ml)
	store_v0(&a, d)
	call_addr(&a, tb, pk, d + 12)
	call_word(&a, tb + 8, d + 12)
	lw_at(&a, A0, d)
	li(&a, A1, 0)
	li(&a, A2, 0)
	li(&a, A3, 0)
	la(&a, T0, d + 16)
	put(&a, 0xafa80010) // sw t0, 16(sp)
	jal(&a, ml + 8)
	store_v0(&a, d + 4)
	li(&a, V0, 0)
	put(&a, 0x8fbf001c, JR_RA, 0x27bd0020) // lw ra, 28(sp); jr ra; addiu sp, sp, 32
	return build_mod("pldt", &a, entry), d
}

slice_clone :: proc(b: []iop.Sys_Block) -> []iop.Sys_Block {
	c := make([]iop.Sys_Block, len(b), context.temp_allocator)
	copy(c, b)
	return c
}

blocks_equal :: proc(a, b: []iop.Sys_Block) -> bool {
	if len(a) != len(b) {return false}
	for x, i in a {if x != b[i] {return false}}
	return true
}

// ------------------------------------------------------------- threads

V0 :: 2

// rt = the word at `off`, then the load delay slot.
lw_at :: proc(a: ^Asm, rt, off: u32) {
	la(a, T0, off)
	put(a, 0x8d000000 | rt << 16, 0) // lw rt, 0(t0); nop
}

// A log in the module's data: a pointer to its next free word, then `n`
// words. The offset of the pointer; the log's words follow it.
log_words :: proc(a: ^Asm, n: int) -> u32 {
	p := at(a)
	put_rel(a, p + 4, 2)
	for _ in 0 ..< n {put(a, 0)}
	return p
}

// Appends `v` to the log at `logp`.
log_v :: proc(a: ^Asm, logp, v: u32) {
	la(a, T0, logp)
	put(a, 0x8d090000, 0) // lw t1, 0(t0); nop
	put(a, 0x240a0000 | v, 0xad2a0000, 0x25290004, 0xad090000) // li t2, v; sw t2, 0(t1); addiu t1, t1, 4; sw t1, 0(t0)
}

log_equal :: proc(base, logp: u32, want: []u32) -> bool {
	for v, i in want {
		if iop.iop_u32(base + logp + 4 + 4 * u32(i))^ != v {return false}
	}
	return iop.iop_u32(base + logp + 4 + 4 * u32(len(want)))^ == 0
}

// An iop_thread_t: attr, option, entry, stack size, priority.
thread_param :: proc(a: ^Asm, entry, prio: u32) -> u32 {
	p := at(a)
	put(a, 0, 0)
	put_rel(a, entry, 2)
	put(a, 0x400, prio)
	return p
}

// An iop_sema_t: attr, option, initial, max.
sema_param :: proc(a: ^Asm, attr, initial: u32) -> u32 {
	p := at(a)
	put(a, attr, 0, initial, 1)
	return p
}

// Calls `stub` with a0 the word at `arg` and a1 `a1`.
call_word :: proc(a: ^Asm, stub, arg: u32, a1: u32 = 0) {
	lw_at(a, A0, arg)
	li(a, A1, a1)
	jal(a, stub)
}

// Calls `stub` with a0 the address of `off`; v0 to `out`.
call_addr :: proc(a: ^Asm, stub, off, out: u32) {
	la(a, A0, off)
	jal(a, stub)
	store_v0(a, out)
}

coroutines :: proc() -> (n: int) {
	for co in core.co_stack_owner {
		if co != nil {n += 1}
	}
	return
}

test_threads :: proc() {
	s := &iop.iop_sched

	// "modt": the start (priority 8) makes semaphore sem and threads H
	// (10) and L (20), starts L then H, and logs 1. H logs 2 and waits on
	// sem; L logs 3 and signals it, which hands the CPU to H at once: H logs
	// 4 and ends; L logs 5.
	fresh()
	a: Asm
	tb := imports(&a, "thbase", 4, 6)
	ts := imports(&a, "thsemap", 4, 6, 8)
	logp := log_words(&a, 8)
	sem, thh, thl := at(&a), at(&a) + 4, at(&a) + 8
	put(&a, 0, 0, 0)
	semp := sema_param(&a, 1, 0)
	eh := at(&a)
	prologue(&a)
	log_v(&a, logp, 2)
	call_word(&a, ts + 16, sem)
	log_v(&a, logp, 4)
	epilogue(&a)
	el := at(&a)
	prologue(&a)
	log_v(&a, logp, 3)
	call_word(&a, ts + 8, sem)
	log_v(&a, logp, 5)
	epilogue(&a)
	ph, pl := thread_param(&a, eh, 10), thread_param(&a, el, 20)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, ts, semp, sem)
	call_addr(&a, tb, ph, thh)
	call_addr(&a, tb, pl, thl)
	call_word(&a, tb + 8, thl)
	call_word(&a, tb + 8, thh)
	log_v(&a, logp, 1)
	li(&a, V0, 0)
	epilogue(&a)
	cos := coroutines()
	id, r := iop.iop_load(build_mod("modt", &a, entry), "modt", nil)
	base := module_base(id)
	check(id > 0 && r == 0, "threads: modt loads")
	check(log_equal(base, logp, {1, 2, 3, 4, 5}), "threads: start, then by priority, a signal yields to the thread it wakes")
	check(len(s.threads) == 2 && len(s.semas) == 1, "threads: the start thread is gone, H, L and sem stay")
	for t in s.threads {check(t.status == .Dormant && t.co == nil, "threads: an ended thread is dormant, its coroutine dropped")}
	check(coroutines() == cos, "threads: no coroutine left")
	check(r3000.next_event == iop.IOP_EVENT_OFF && s.cur == 0, "threads: the budget is off after a load")

	// "modw": the start makes sem and thread L, starts it and waits on sem;
	// L waits on sem too, so nothing is ready.
	w: Asm
	tb = imports(&w, "thbase", 4, 6)
	ts = imports(&w, "thsemap", 4, 6, 8)
	sem, thl = at(&w), at(&w) + 4
	put(&w, 0, 0)
	semp = sema_param(&w, 0, 0)
	el = at(&w)
	prologue(&w)
	call_word(&w, ts + 16, sem)
	epilogue(&w)
	pl = thread_param(&w, el, 20)
	entry = at(&w)
	prologue(&w)
	call_addr(&w, ts, semp, sem)
	call_addr(&w, tb, pl, thl)
	call_word(&w, tb + 8, thl)
	call_word(&w, ts + 16, sem)
	epilogue(&w)
	threads, semas := len(s.threads), len(s.semas)
	before := slice_clone(iop.sys_blocks[:])
	idw, _ := iop.iop_load(build_mod("modw", &w, entry), "modw", nil)
	key := core.Compat_Key{.Iop_Blocked, core.compat_name("modw"), 0}
	check(idw == -1 && core.compat.calls[key].n == 1, "threads: a start waiting with nothing ready fails with a compat row")
	check(len(s.threads) == threads && len(s.semas) == semas, "threads: the failed load's threads and semaphores deleted")
	check(coroutines() == cos, "threads: the failed load's coroutines killed")
	check(blocks_equal(before, iop.sys_blocks[:]), "threads: the failed load's stacks freed")
}

// Condition: a failed path is not rerun until a library registers or a load
// succeeds.
test_failed_paths :: proc() {
	fresh()
	key := core.Compat_Key{.Iop_Import, core.compat_name("liba"), 0}
	runs := core.compat.calls[key].n
	fb, _ := mod_b(true) // calls liba, which nobody registered
	idb, _ := iop.iop_load(fb, "modb", nil)
	check(idb == -1 && core.compat.calls[key].n == runs + 1, "failed paths: modb fails on liba")
	idb, _ = iop.iop_load(fb, "modb", nil)
	check(idb == -1 && core.compat.calls[key].n == runs + 1, "failed paths: a retry is refused without running")
	g: Asm
	put(&g, JR_RA, 0x24020000)
	idg, _ := iop.iop_load(build_mod("modg", &g, 0), "modg", nil)
	idb, _ = iop.iop_load(fb, "modb", nil)
	check(idg > 0 && idb == -1 && core.compat.calls[key].n == runs + 2, "failed paths: a load that succeeds lets it run again")
	fa, _ := mod_a()
	ida, _ := iop.iop_load(fa, "moda", nil)
	idb2, rb := iop.iop_load(fb, "modb", nil)
	check(ida > 0 && idb2 > 0 && rb == 0x700, "failed paths: once liba registers, the retry runs and links")

	// However often a load succeeds in between, a path's start runs at most
	// IOP_LOAD_FAILS times; every refusal is still a fallback row.
	z: Asm
	sm := imports(&z, "sysmem", 99)
	entry := at(&z)
	prologue(&z)
	jal(&z, sm)
	epilogue(&z)
	fz := build_mod("modz", &z, entry)
	call := core.Compat_Key{.Iop_Call, core.compat_name("sysmem"), 99}
	back := core.Compat_Key{.Iop_Fallback, core.compat_name("modz"), 0}
	calls, backs := core.compat.calls[call].n, core.compat.calls[back].n
	for _ in 0 ..< 10 {
		idz, _ := iop.iop_load(fz, "modz", nil)
		idg, _ = iop.iop_load(build_mod("modg", &g, 0), "modg", nil)
		check(idz == -1 && idg > 0, "failed paths: modz fails, modg loads")
	}
	check(core.compat.calls[call].n == calls + iop.IOP_LOAD_FAILS, "failed paths: a path's start runs at most IOP_LOAD_FAILS times")
	check(core.compat.calls[back].n == backs + 10, "failed paths: each failure and refusal a fallback row")

	// A failure is the image's, not the name's: another build loaded under
	// the failed one's path still runs.
	idz, _ := iop.iop_load(fz, "modz", nil)
	check(idz == -1, "failed paths: modz still refused")
	idz, _ = iop.iop_load(build_mod("modz", &g, 0), "modz", nil)
	check(idz > 0, "failed paths: another image under the same path runs")

	// A start looping on a missing call is stopped at its IOP_START_GAPS-th,
	// one row counting them all.
	y: Asm
	sm = imports(&y, "sysmem", 98)
	entry = at(&y)
	prologue(&y)
	jal(&y, sm)
	put(&y, 0x1000fffd, 0) // b back to the jal
	loop := core.Compat_Key{.Iop_Call, core.compat_name("sysmem"), 98}
	calls = core.compat.calls[loop].n
	idy, _ := iop.iop_load(build_mod("mody", &y, entry), "mody", nil)
	check(idy == -1, "failed paths: a start looping on a missing call fails")
	check(core.compat.calls[loop].n == calls + iop.IOP_START_GAPS, "failed paths: stopped at IOP_START_GAPS calls")
	check(!iop.iop_sched.budget, "failed paths: stopped by the cap, not the budget")
}

// Condition: a budget spent after the start returned still loads.
test_thread_budget :: proc() {
	fresh()
	s := &iop.iop_sched
	a: Asm
	tb := imports(&a, "thbase", 4, 6)
	th := at(&a)
	put(&a, 0)
	el := at(&a)
	put_rel(&a, 0x08000000 | el >> 2, 4) // j el
	put(&a, 0)
	pl := thread_param(&a, el, 20)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, tb, pl, th)
	call_word(&a, tb + 8, th)
	li(&a, V0, 0)
	epilogue(&a)
	id, r := iop.iop_load(build_mod("modd", &a, entry), "modd", nil)
	key := core.Compat_Key{.Iop_Threads, core.compat_name("modd"), 0}
	check(id > 0 && r == 0 && core.compat.calls[key].n == 1, "budget: threads spinning after the start: the load succeeds with a compat row")
	t := iop.th_find(iop.iop_u32(module_base(id) + th)^)
	check(t != nil && t.status == .Ready && t.co != nil, "budget: the spinning thread stays ready with its coroutine")
	check(t != nil && t.ctx.r[29] > t.stack && t.ctx.r[29] < t.stack + t.stacksize, "budget: its context saved")
	// `j el` at its run's first word is a tail call each time round, so the
	// thread spins TAIL_DEPTH_MAX deep: its own count, not the loader's.
	check(t != nil && t.ctx.tail_depth == r3000.TAIL_DEPTH_MAX, "budget: its tail calls in its context")
	check(r3000.tail_depth == 0, "budget: none of its tail calls left on the loader")
	check(r3000.next_event == iop.IOP_EVENT_OFF && s.cur == 0, "budget: off after the load")
}

// Bytes of `s` and a NUL, padded to words; their offset.
str_words :: proc(a: ^Asm, s: string) -> u32 {
	p := at(a)
	b := make([]u8, (len(s) + 4) &~ 3, context.temp_allocator)
	copy(b, s)
	for i := 0; i < len(b); i += 4 {put(a, endian.unchecked_get_u32le(b[i:]))}
	return p
}

test_libc :: proc() {
	fresh()
	a: Asm
	intr := imports(&a, "intrman", 17)
	pf := imports(&a, "stdio", 4)
	lc := imports(&a, "sysclib", 12, 14, 36)
	state := at(&a)
	put(&a, 0x55)
	out := at(&a)
	put(&a, 0, 0, 0)
	endp := at(&a)
	put(&a, 0)
	buf := at(&a)
	put(&a, 0x11111111, 0x11111111)
	f := str_words(&a, "x=%d %s")
	str := str_words(&a, "ab")
	num := str_words(&a, "  -0x1fZ")
	entry := at(&a)
	prologue(&a)
	call_addr(&a, intr, state, out)
	la(&a, A0, f)
	li(&a, A1, 5)
	la(&a, A2, str)
	jal(&a, pf)
	store_v0(&a, out + 4)
	la(&a, A0, num)
	la(&a, A1, endp)
	li(&a, A2, 0)
	jal(&a, lc + 16)
	store_v0(&a, out + 8)
	la(&a, A0, buf)
	li(&a, A1, 0x5a)
	li(&a, A2, 3)
	jal(&a, lc + 8)
	la(&a, A0, buf + 4)
	la(&a, A1, str)
	li(&a, A2, 2)
	jal(&a, lc)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modl", &a, entry), "modl", nil)
	b := module_base(id)
	u := proc(b, o: u32) -> u32 {return iop.iop_u32(b + o)^}
	check(id > 0, "libc: modl loads")
	check(u(b, state) == 0 && u(b, out) == 0, "libc: CpuSuspendIntr writes its state and returns 0")
	check(u(b, out + 4) == 6, "libc: printf returns what it wrote")
	check(u(b, out + 8) == 0xffffffe1 && u(b, endp) == b + num + 7, "libc: strtol base 0 reads -0x1f, ends before Z")
	check(u(b, buf) == 0x115a5a5a && u(b, buf + 4) == 0x11116261, "libc: memset and memcpy")
	r := &r3000.state.r
	r[5], r[6], r[7], r[29] = 0xffffffff, 0xff, 0xab, 0x1f000
	iop.iop_u32(0x1f010)^, iop.iop_u32(0x1f014)^ = 'z', 7
	got, _ := iop.iop_format("%5d|%-3x|%08X|%c|%u%%|%ld")
	check(got == "   -1|ff |000000AB|z|7%|0", fmt.tprintf("libc: printf conversions, arguments past a3 from the stack: %q", got))
}

// sysclib's string calls over IOP RAM, from their edges; called directly.
test_sysclib :: proc() {
	fresh()
	r := &r3000.state.r
	ram := iop.iop_ram
	TOP :: iop.IOP_RAM_SIZE
	put_str :: proc(a: u32, s: string) {
		copy(iop.iop_ram[a:], s)
		iop.iop_ram[a + u32(len(s))] = 0
	}
	call :: proc(fno: u32, args: ..u32) -> u32 {
		r := &r3000.state.r
		for v, i in args {r[4 + i] = v}
		v, ok := iop.sysclib_fn(fno)
		check(ok, fmt.tprintf("sysclib: fno %d served", fno))
		return v
	}
	str :: proc(a: u32) -> string {return string(cstring(&iop.iop_ram[a]))}
	A, B, C :: 0x100000, 0x100100, 0x100200

	// look_ctype_table: classes, EOF, past the table.
	check(call(8, 'G') == 0x01 && call(8, 'c') == 0x42 && call(8, '7') == 0x04, "sysclib: ctype letters and digits")
	check(call(8, '\t') == 0x08 && call(8, ' ') == 0x18 && call(8, 1) == 0x20 && call(8, 127) == 0x20, "sysclib: ctype space, control")
	check(call(8, '~') == 0x10 && call(8, 0xffffffff) == 0 && call(8, 150) == 0, "sysclib: ctype punct; EOF and 128..158 are 0")
	ct := core.Compat_Key{.Iop_Call, core.compat_name("sysclib"), 8}
	check(core.compat.calls[ct].n == 0 && call(8, 159) == 0 && call(8, 0xfffffffe) == 0 && core.compat.calls[ct].n == 2, "sysclib: ctype past -1..158 is 0 with a row")

	// memcmp: n <= 0, first difference unsigned, -1/1.
	put_str(A, "ab\x80")
	put_str(B, "ab\x01")
	check(call(11, A, B, 0) == 0 && call(11, A, B, 0x80000000) == 0, "sysclib: memcmp n <= 0 is 0")
	check(call(11, A, B, 2) == 0 && call(11, A, B, 3) == 1 && call(11, B, A, 3) == 0xffffffff, "sysclib: memcmp unsigned, -1 or 1")
	check(call(11, TOP - 2, TOP - 2, 100) == 0, "sysclib: memcmp stops at RAM's end")

	// bzero: n <= 0, a run to RAM's end.
	ram[A], ram[A + 1] = 7, 7
	call(17, A, 1)
	check(ram[A] == 0 && ram[A + 1] == 7, "sysclib: bzero n")
	call(17, A + 1, 0x80000000)
	check(ram[A + 1] == 7, "sysclib: bzero n < 0 writes none")
	ram[TOP - 1] = 9
	call(17, TOP - 1, 100)
	check(ram[TOP - 1] == 0, "sysclib: bzero stops at RAM's end")

	// strlen, strcmp, strncmp: null rules, signed difference, n.
	put_str(A, "abc")
	put_str(B, "ab\xff")
	check(call(27, 0) == 0 && call(27, A) == 3, "sysclib: strlen, 0 for null")
	ram[TOP - 1] = 'x'
	check(call(27, TOP - 1) == 1, "sysclib: strlen of an unterminated string stops at RAM's end")
	check(call(22, 0, 0) == 0 && call(22, 0, A) == 0xffffffff && call(22, A, 0) == 1, "sysclib: strcmp null rules")
	check(call(22, A, B) == u32('c' + 1) && call(22, B, A) == ~u32('c'), "sysclib: strcmp signed difference")
	check(call(22, A, A) == 0 && call(22, TOP - 1, TOP - 1) == 0, "sysclib: strcmp equal, unterminated at RAM's end")
	check(call(29, A, B, 2) == 0 && call(29, A, B, 3) == u32('c' + 1) && call(29, A, B, 0) == 0 && call(29, A, B, 0xffffffff) == 0, "sysclib: strncmp within n, n <= 0")
	check(call(29, 0, A, 0) == 0xffffffff, "sysclib: strncmp null before n")
	put_str(C, "abc")
	check(call(29, A, C, 100) == 0, "sysclib: strncmp stops at a shared NUL")

	// strcpy, strcat: null, return, overlap, same end.
	check(call(23, 0, A) == 0 && call(23, C, 0) == 0, "sysclib: strcpy null gives 0")
	check(call(23, C, A) == C && str(C) == "abc", "sysclib: strcpy returns dst")
	put_str(A, "abcdef")
	check(call(23, A, A + 2) == A && str(A) == "cdef", "sysclib: strcpy overlap, dst before src")
	check(call(20, 0, A) == 0 && call(20, A, 0) == 0, "sysclib: strcat null gives 0")
	put_str(A, "ab")
	put_str(B, "cd")
	check(call(20, A, B) == A && str(A) == "abcd", "sysclib: strcat appends, returns dst")
	put_str(A, "abcd")
	check(call(20, A, A + 2) == 0 && str(A) == "abcd", "sysclib: strcat of strings ending at one address gives 0")
	put_str(B, "xyz")
	call(23, TOP - 2, B)
	check(ram[TOP - 2] == 'x' && ram[TOP - 1] == 'y', "sysclib: strcpy stops at RAM's end")

	// strncpy: padding, no NUL at n, n <= 0.
	for i in u32(0) ..< 8 {ram[C + i] = 0xee}
	put_str(B, "ab")
	check(call(30, C, B, 5) == C && str(C) == "ab" && ram[C + 3] == 0 && ram[C + 4] == 0 && ram[C + 5] == 0xee, "sysclib: strncpy pads with NUL to n")
	put_str(B, "wxyz")
	check(call(30, C, B, 2) == C && ram[C] == 'w' && ram[C + 1] == 'x' && ram[C + 2] == 0, "sysclib: strncpy at n writes no NUL")
	check(call(30, C, B, 0) == C && call(30, C, B, 0x80000000) == C && ram[C] == 'w', "sysclib: strncpy n <= 0 returns dst")
	check(call(30, 0, B, 2) == 0 && call(30, C, 0, 2) == 0, "sysclib: strncpy null gives 0")
	call(30, TOP - 1, B, 100)
	check(ram[TOP - 1] == 'w', "sysclib: strncpy stops at RAM's end")

	// strstr: the kernel's one pass that never backs up.
	put_str(A, "cdrom0:\\X.BIN;1")
	put_str(B, ";1")
	put_str(C, "")
	check(call(34, A, B) == A + 13, "sysclib: strstr finds the needle")
	check(call(34, A, A) == A && call(34, A, A + 14) == A + 14, "sysclib: strstr at the start, a one-character needle")
	check(call(34, A, C) == 0 && call(34, C, B) == 0, "sysclib: strstr of an empty needle or haystack is 0")
	put_str(B, ";2")
	check(call(34, A, B) == 0, "sysclib: strstr miss is 0")
	put_str(A, "aab")
	put_str(B, "ab")
	check(call(34, A, B) == 0, "sysclib: strstr does not back up after a partial match")
	put_str(A, "xaxab")
	check(call(34, A, B) == A + 3, "sysclib: strstr restarts the needle after a mismatch")
	put_str(B, "xaxabc")
	check(call(34, A, B) == 0, "sysclib: strstr of a needle longer than the haystack is 0")

	// sprintf: return, NUL, null format, RAM's end, the formatter's quirks.
	put_str(A, "%d-%s")
	put_str(B, "ok")
	for i in u32(0) ..< 8 {ram[C + i] = 0xee}
	check(call(19, C, A, 0xfffffff9, B) == 5 && str(C) == "-7-ok" && ram[C + 5] == 0, "sysclib: sprintf returns the count without the NUL")
	ram[C] = 0xee
	check(call(19, C, 0) == 0 && ram[C] == 0xee, "sysclib: sprintf of a null format writes none")
	put_str(A, "abcd")
	check(call(19, TOP - 2, A) == 4 && ram[TOP - 2] == 'a' && ram[TOP - 1] == 'b', "sysclib: sprintf stops at RAM's end")
	r[5], r[6], r[7], r[29] = 0x12345678, 0xfffffff4, 0, 0x1f000
	for v, i in ([]u32{0x1f100, 0x0003ffff, 8, 0, 0x1f104}) {iop.iop_u32(0x1f010 + 4 * u32(i))^ = v}
	iop.iop_u32(0x1f104)^ = 0xffffffff
	got, _ := iop.iop_format("%#x|%.5d|%09s|%p|%hd|%#o|%.0d|%hn|%f%%", 1)
	head :: "0x12345678|-0012|000(null)|1f100|262143|010||"
	check(got == head + "|f%", fmt.tprintf("sysclib: formatter quirks: %q", got))
	check(iop.iop_u32(0x1f104)^ == len(head), "sysclib: %hn stores the count's whole word")

	// A format's end right after % or a flag; 32-bit widths and precisions.
	out, n := iop.iop_format("ab%")
	check(out == "ab" && n == 2, "sysclib: a format ending after % prints what came before")
	out, n = iop.iop_format("ab%-0")
	check(out == "ab" && n == 2, "sysclib: a format ending after a flag prints what came before")
	r[5], r[6] = 5, 5
	out, n = iop.iop_format("%4294967297d|%.4294967295d", 1)
	check(out == "5|5", fmt.tprintf("sysclib: a digit run wraps at 32 bits, a negative precision is none: %q", out))
	r[5], r[6] = 0x80000000, 5
	out, n = iop.iop_format("%*d", 1)
	check(out == "5", "sysclib: a * width of the most negative int pads nothing")

	// Output past IOP RAM's size: counted, not kept; sprintf stops at RAM's end.
	r[5] = 5
	out, n = iop.iop_format("%2147483647d", 1)
	check(n == 0x7fffffff && len(out) == iop.IOP_RAM_SIZE, fmt.tprintf("sysclib: a huge width is counted, kept to RAM's size: %x %x", n, len(out)))
	r[5], r[6], r[7] = 0x7fffffff, 1, 0x7fffffff
	out, n = iop.iop_format("%*d%*d", 1)
	check(n == 0xfffffffe, "sysclib: the count wraps at 32 bits")
	put_str(A, "%*d")
	check(call(19, TOP - 0x10000, A, 0x7fffffff, 5) == 0x7fffffff, "sysclib: sprintf with width 0x7fffffff returns the count")
	check(ram[TOP - 1] == ' ' && ram[TOP - 0x10000] == ' ', "sysclib: sprintf with width 0x7fffffff stops at RAM's end")
}

// A Sony import of another major version is not served; another minor is.
test_import_major :: proc() {
	fresh()
	a: Asm
	v2 := imports_v(&a, "sysclib", 0x0201, 27)
	v1 := imports_v(&a, "sysclib", 0x0105, 27)
	s := str_words(&a, "abc")
	entry := at(&a)
	prologue(&a)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modv", &a, entry), "modv", nil)
	b := module_base(id)
	check(id > 0, "major: modv loads")
	r3000.state.r[4] = b + s
	check(iop_call(b + v1) == 3, "major: another minor version is served")
	key := core.Compat_Key{.Iop_Import, core.compat_name("sysclib"), 0x0201}
	r3000.state.r[4] = b + s
	check(iop_call(b + v2) == 0xffffffff && core.compat.calls[key].n == 1, "major: major 2 fails with a row, not served")

	// sio2man is served at major 2 alone.
	fresh()
	a = {}
	s2 := imports_v(&a, "sio2man", 0x0204, 26)
	s1 := imports_v(&a, "sio2man", 0x0101, 26)
	entry = at(&a)
	prologue(&a)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ = iop.iop_load(build_mod("mods", &a, entry), "mods", nil)
	b = module_base(id)
	key = core.Compat_Key{.Iop_Import, core.compat_name("sio2man"), 0x0101}
	check(id > 0 && iop_call(b + s2) == 0, "major: sio2man 2.4 is served")
	check(iop_call(b + s1) == 0xffffffff && core.compat.calls[key].n == 1, "major: sio2man major 1 fails with a row, not served")
}

// cdvdstm is a Sony library: LOADFILE does not run a module that exports
// it, and a module importing it gets the HLE's unserved-call failure and
// row, not a pending import's.
test_sony_stream :: proc() {
	fresh()
	m: Asm
	entry := at(&m)
	prologue(&m)
	li(&m, V0, 0)
	epilogue(&m)
	check(iop.iop_runs(build_mod("modn", &m, entry)), "cdvdstm: LOADFILE runs another module")
	_, ptr := exports(&m, "cdvdstm")
	m.w[ptr] = entry
	check(!iop.iop_runs(build_mod("cdvd_st_driver", &m, entry)), "cdvdstm: LOADFILE does not run the module that exports it")
	a: Asm
	st := imports(&a, "cdvdstm", 5)
	entry = at(&a)
	prologue(&a)
	jal(&a, st)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("mods", &a, entry), "mods", nil)
	call := core.Compat_Key{.Iop_Call, core.compat_name("cdvdstm"), 5}
	pending := core.Compat_Key{.Iop_Import, core.compat_name("cdvdstm"), 0}
	check(id == -1 && core.compat.calls[call].n == 1 && core.compat.calls[pending].n == 0, "cdvdstm: an import's call is the HLE's, unserved, a row")
}

snap3: core.Snapshot
snap3_loaded: bool // not emulated state

// "mods": its start signals semaphore 1 and returns.
mod_s :: proc() -> []u8 {
	a: Asm
	ts := imports(&a, "thsemap", 6)
	entry := at(&a)
	prologue(&a)
	li(&a, A0, 1)
	jal(&a, ts)
	li(&a, V0, 1) // NO_RESIDENT_END
	epilogue(&a)
	return build_mod("mods", &a, entry)
}

test_thread_snap :: proc() {
	fresh()
	// "modh": semaphore 1, and thread H, which waits on it and then logs 7.
	a: Asm
	tb := imports(&a, "thbase", 4, 6)
	ts := imports(&a, "thsemap", 4, 8)
	logp := log_words(&a, 4)
	th := at(&a)
	put(&a, 0)
	semp := sema_param(&a, 0, 0)
	eh := at(&a)
	prologue(&a)
	li(&a, A0, 1)
	jal(&a, ts + 8)
	log_v(&a, logp, 7)
	epilogue(&a)
	ph := thread_param(&a, eh, 10)
	entry := at(&a)
	prologue(&a)
	la(&a, A0, semp)
	jal(&a, ts)
	call_addr(&a, tb, ph, th)
	call_word(&a, tb + 8, th)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modh", &a, entry), "modh", nil)
	base := module_base(id)
	check(id > 0 && log_equal(base, logp, {}), "thread snapshot: H waits")
	core.snap_op, core.snap_target = .Save, &snap3
	core.snap_yield()
	if !snap3_loaded {
		ids, _ := iop.iop_load(mod_s(), "mods", nil)
		check(ids > 0 && log_equal(base, logp, {7}), "thread snapshot: a signal wakes H")
		snap3_loaded = true
		core.snap_op, core.snap_target = .Load, &snap3
		core.snap_yield()
	}
	check(log_equal(base, logp, {}), "thread snapshot: H waits again after the load")
	ids, _ := iop.iop_load(mod_s(), "mods", nil)
	check(ids > 0 && log_equal(base, logp, {7}), "thread snapshot: the restored H wakes where it waited")
}

// thevent fno with a0..a3.
ev :: proc(fno: u32, a0: u32 = 0, a1: u32 = 0, a2: u32 = 0, a3: u32 = 0) -> u32 {
	r := &r3000.state.r
	r[4], r[5], r[6], r[7] = a0, a1, a2, a3
	v, ok := iop.th_event(fno)
	check(ok, "event: a served call")
	return v
}

// A thread that waits on event flag ef for `bits` in `mode`, its met bits to
// `res`, its place in the wait queue `seq`.
evf_waiter :: proc(ef, bits, mode, res: u32, seq: i64) -> ^iop.Iop_Thread {
	t := iop.th_new(0x1000, 0x2000, 0x100, 0, 10)
	t.status, t.sema, t.seq = .Evf, ef, seq
	t.evf_bits, t.evf_mode, t.evf_res = bits, mode, res
	return t
}

// Each event-flag call against ps2sdk's thevent: attributes, AND and OR
// patterns, WEF_CLEAR, the bits a wait gets, one waiter unless EA_MULTI, a
// set waking its waiters first come first until a clear, a delete waking
// them with KE_WAIT_DELETE, and each call in its context only.
test_event_flags :: proc() {
	fresh()
	P :: 0x00040000
	word :: proc(i: u32) -> u32 {return iop.iop_u32(P + 4 * i)^}
	param :: proc(attr, bits: u32) -> u32 {
		for w, i in ([3]u32{attr, 9, bits}) {iop.iop_u32(P + 4 * u32(i))^ = w}
		return P
	}
	check(ev(4, param(1, 0)) == neg(-iop.KE_ILLEGAL_ATTR), "event: an attribute other than EA_MULTI is illegal")
	e1 := ev(4, param(0, 5))
	e2 := ev(4, param(2, 0))
	check(e1 == 1 && e2 == 2, "event: Create gives ids")
	check(ev(13, e1, P + 0x40) == 0 && word(0x10) == 0 && word(0x11) == 9 && word(0x12) == 5 && word(0x13) == 5 && word(0x14) == 0, "event: Refer by retail's layout")

	// Poll: AND needs every bit, OR any; the bits before a clear come back.
	check(ev(11, e1, 4, 0, P + 0x80) == 0 && word(0x20) == 5, "event: an AND poll met gives the bits")
	check(ev(11, e1, 6, 0, P + 0x80) == neg(-iop.KE_EVF_COND), "event: an AND poll short of a bit is unmet")
	check(ev(11, e1, 6, 1, 0) == 0, "event: an OR poll with one bit is met, no resbits")
	check(ev(11, e1, 0, 0, 0) == neg(-iop.KE_EVF_ILPAT), "event: an empty pattern is illegal")
	check(ev(11, e1, 1, 2, 0) == neg(-iop.KE_ILLEGAL_MODE), "event: an unknown mode bit is illegal")
	check(ev(11, 99, 1, 0, 0) == neg(-iop.KE_UNKNOWN_EVFID), "event: an unknown flag")
	iop.iop_u32(P + 0x80)^ = 0
	check(ev(11, e1, 1, 0x11, P + 0x80) == 0 && word(0x20) == 5, "event: an OR|CLEAR poll gives the bits before its clear")
	ev(13, e1, P + 0x40)
	check(word(0x13) == 0, "event: WEF_CLEAR leaves no bits")

	// Set ORs, Clear keeps the bits it is given.
	check(ev(6, e1, 0xff) == 0 && ev(8, e1, 0x0f) == 0 && ev(13, e1, P + 0x40) == 0 && word(0x13) == 0x0f, "event: Set ORs, Clear ANDs")
	check(ev(10, e1, 1, 0, P + 0x80) == 0 && word(0x20) == 0x0f, "event: a wait met at once returns")
	check(ev(10, e1, 0x10, 0, 0) == neg(-iop.KE_CAN_NOT_WAIT), "event: an unmet wait on the loader cannot wait")

	// One waiter unless EA_MULTI.
	w := evf_waiter(e1, 0x10, 0, 0, 0)
	check(ev(11, e1, 1, 0, 0) == neg(-iop.KE_EVF_MULTI), "event: a single flag with a waiter refuses another")
	ev(13, e1, P + 0x40)
	check(word(0x14) == 1, "event: Refer counts the waiter")
	w.status = .Dormant

	// e2: A wants 3 (AND), B 1 (OR, CLEAR), C 1 (OR), in that order.
	a := evf_waiter(e2, 3, 0, P + 0x84, 1)
	b := evf_waiter(e2, 1, 0x11, P + 0x88, 2)
	c := evf_waiter(e2, 1, 1, 0, 3)
	ida, idb, idc := a.id, b.id, c.id
	check(ev(11, e2, 4, 1, 0) == neg(-iop.KE_EVF_COND), "event: a multi flag with waiters takes another")
	ev(6, e2, 1)
	a, b, c = iop.th_find(ida), iop.th_find(idb), iop.th_find(idc)
	check(a.status == .Evf && b.status == .Ready && b.wake == 0 && word(0x22) == 1 && c.status == .Evf, "event: a set wakes the first met waiter, whose clear leaves none for the rest")
	ev(13, e2, P + 0x40)
	check(word(0x13) == 0 && word(0x14) == 2, "event: the clear took the bits")
	ev(6, e2, 3)
	a, c = iop.th_find(ida), iop.th_find(idc)
	check(a.status == .Ready && word(0x21) == 3 && c.status == .Ready && a.seq < c.seq, "event: a set wakes every met waiter, first come first")
	ev(13, e2, P + 0x40)
	check(word(0x13) == 3, "event: no clear keeps the bits")

	// Delete wakes its waiters with KE_WAIT_DELETE.
	d := evf_waiter(e2, 0x100, 0, 0, 4)
	idd := d.id
	check(ev(5, e2) == 0 && ev(13, e2, P + 0x40) == neg(-iop.KE_UNKNOWN_EVFID), "event: Delete removes the flag")
	d = iop.th_find(idd)
	check(d.status == .Ready && d.wake == neg(-iop.KE_WAIT_DELETE), "event: Delete wakes its waiter with KE_WAIT_DELETE")
	check(ev(5, e2) == neg(-iop.KE_UNKNOWN_EVFID), "event: Delete of an unknown flag")

	// Contexts: the i-variants only in a handler, the rest only on a thread.
	for fno in ([4]u32{7, 9, 14, 7}) {check(ev(fno, e1, 1, 0, P + 0x40) == neg(-iop.KE_ILLEGAL_CONTEXT), "event: an i-call on a thread is illegal")}
	iop.iop_sched.intr = true
	for fno in ([7]u32{4, 5, 6, 8, 10, 11, 13}) {check(ev(fno, e1, 1, 0, P + 0x40) == neg(-iop.KE_ILLEGAL_CONTEXT), "event: a thread's call in a handler is illegal")}
	check(ev(7, e1, 0x30) == 0 && ev(9, e1, 0x20) == 0 && ev(14, e1, P + 0x40) == 0 && word(0x13) == 0x20, "event: iSet, iClear and iRefer in a handler")
	iop.iop_sched.intr = false
	r3000.state.r[4] = e1
	_, ok12 := iop.th_event(12)
	_, ok15 := iop.th_event(15)
	check(!ok12 && !ok15, "event: thevent 12 and 15 are not served")
}

snap13: core.Snapshot
snap13_loaded: bool // not emulated state

// "mode": its start sets bit 1 of event flag 1 and returns.
mod_e :: proc() -> []u8 {
	a: Asm
	te := imports(&a, "thevent", 6)
	entry := at(&a)
	prologue(&a)
	li(&a, A0, 1)
	li(&a, A1, 1)
	jal(&a, te)
	li(&a, V0, 1) // NO_RESIDENT_END
	epilogue(&a)
	return build_mod("mode", &a, entry)
}

// A thread waiting on an event flag through a real WaitEventFlag, as
// test_thread_snap: the snapshot keeps its .Evf wait and the flag.
test_event_snap :: proc() {
	fresh()
	// "modf": event flag 1, and thread H, which waits on its bit 1 and then
	// logs 7 and the bits it got.
	a: Asm
	tb := imports(&a, "thbase", 4, 6)
	te := imports(&a, "thevent", 4, 10)
	logp := log_words(&a, 4)
	th, res := at(&a), at(&a) + 4
	put(&a, 0, 0)
	evp := at(&a)
	put(&a, 0, 0, 0)
	eh := at(&a)
	prologue(&a)
	li(&a, A0, 1)
	li(&a, A1, 1)
	li(&a, A2, 0)
	la(&a, A3, res)
	jal(&a, te + 8)
	log_v(&a, logp, 7)
	epilogue(&a)
	ph := thread_param(&a, eh, 10)
	entry := at(&a)
	prologue(&a)
	la(&a, A0, evp)
	jal(&a, te)
	call_addr(&a, tb, ph, th)
	call_word(&a, tb + 8, th)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modf", &a, entry), "modf", nil)
	base := module_base(id)
	t := iop.th_find(iop.iop_u32(base + th)^)
	check(id > 0 && log_equal(base, logp, {}) && t != nil && t.status == .Evf && t.sema == 1, "event snapshot: H waits on the flag")
	core.snap_op, core.snap_target = .Save, &snap13
	core.snap_yield()
	if !snap13_loaded {
		ids, _ := iop.iop_load(mod_e(), "mode", nil)
		check(ids > 0 && log_equal(base, logp, {7}) && iop.iop_u32(base + res)^ == 1, "event snapshot: a set wakes H with the bits")
		snap13_loaded = true
		core.snap_op, core.snap_target = .Load, &snap13
		core.snap_yield()
	}
	t = iop.th_find(iop.iop_u32(base + th)^)
	check(log_equal(base, logp, {}) && t != nil && t.status == .Evf && iop.iop_u32(base + res)^ == 0, "event snapshot: H waits again after the load")
	ids, _ := iop.iop_load(mod_e(), "mode", nil)
	check(ids > 0 && log_equal(base, logp, {7}) && iop.iop_u32(base + res)^ == 1, "event snapshot: the restored H wakes where it waited")
}

// A failed load deletes the event flags it made, waking their waiters from
// earlier loads with KE_WAIT_DELETE; earlier flags stay.
test_event_undo :: proc() {
	fresh()
	s := &iop.iop_sched
	P :: 0x00040000
	iop.iop_u32(P)^, iop.iop_u32(P + 4)^, iop.iop_u32(P + 8)^ = 0, 0, 0
	r3000.state.r[4] = P
	kept, _ := iop.th_event(4)
	// "modu": makes a flag, then calls thevent 12, which the HLE lacks.
	a: Asm
	te := imports(&a, "thevent", 4, 12)
	evp := at(&a)
	put(&a, 0, 0, 0)
	entry := at(&a)
	prologue(&a)
	la(&a, A0, evp)
	jal(&a, te)
	jal(&a, te + 8)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modu", &a, entry), "modu", nil)
	check(id == -1 && len(s.evfs) == 1 && s.evfs[0].id == kept, "event undo: the failed load's flag is deleted, the earlier one kept")
	check(s.next_evfid == kept + 2, "event undo: ids go on past the deleted flag")
}

// sio2man fno with a0 from the loader; v0.
sio2 :: proc(fno: u32, a0: u32 = 0) -> u32 {
	r3000.state.r[4] = a0
	v, ok := iop.sio2man_fn(fno)
	check(ok, "sio2: a served call")
	return v
}

// A thread waiting on sio2man's lock, its place in the queue `seq`.
lock_waiter :: proc(seq: i64) -> ^iop.Iop_Thread {
	t := iop.th_new(0x1000, 0x2000, 0x100, 0, 10)
	t.status, t.seq = .Lock, seq
	return t
}

// The lock against the v2.04 module: one holder at first, 61 and 63 take it
// and wait while it is held, 62 hands it to the first waiter first come, else
// gives it back up to 0x40; the handshake calls do nothing.
test_sio2_lock :: proc() {
	fresh()
	s := &iop.iop_sched
	check(s.lock == 1, "sio2 lock: free at first")
	check(sio2(61) == 0 && s.lock == 0, "sio2 lock: 61 takes it")
	check(sio2(63) == iop.ke(iop.KE_CAN_NOT_WAIT) && s.lock == 0, "sio2 lock: the loader cannot wait for it")
	w1, w2 := lock_waiter(5).id, lock_waiter(3).id
	check(sio2(62) == 0 && iop.th_find(w2).status == .Ready && iop.th_find(w1).status == .Lock && s.lock == 0, "sio2 lock: 62 wakes the first waiter")
	check(sio2(62) == 0 && iop.th_find(w1).status == .Ready && s.lock == 0, "sio2 lock: then the next")
	check(sio2(62) == 0 && s.lock == 1, "sio2 lock: with no waiter it is given back")
	for _ in 0 ..< 0x50 {sio2(62)}
	check(s.lock == iop.SIO2_LOCK_MAX, "sio2 lock: its count stops at 0x40")
	check(sio2(63) == 0 && s.lock == iop.SIO2_LOCK_MAX - 1, "sio2 lock: 63 takes it")
	for fno in ([9]u32{23, 24, 46, 47, 48, 49, 50, 26, 52}) {check(sio2(fno) == 0, "sio2 lock: a handshake call does nothing")}
	check(s.lock == iop.SIO2_LOCK_MAX - 1, "sio2 lock: nor touches the lock")
	r3000.state.r[4] = 0
	_, ok := iop.sio2man_fn(53)
	check(!ok, "sio2: 53 is not served")
}

snap14: core.Snapshot
snap14_loaded: bool // not emulated state

// "modr": its start gives sio2man's lock back (62) and returns.
mod_r :: proc() -> []u8 {
	a: Asm
	sm := imports_v(&a, "sio2man", 0x0204, 62)
	entry := at(&a)
	prologue(&a)
	jal(&a, sm)
	li(&a, V0, 1) // NO_RESIDENT_END
	epilogue(&a)
	return build_mod("modr", &a, entry)
}

// "modl": thread H takes the lock twice, waiting the second time, then logs
// 7. Its start makes and starts H; H's id at `th`.
mod_l :: proc() -> (f: []u8, th, logp: u32) {
	a: Asm
	tb := imports(&a, "thbase", 4, 6)
	sm := imports_v(&a, "sio2man", 0x0204, 61)
	logp = log_words(&a, 4)
	th = at(&a)
	put(&a, 0)
	eh := at(&a)
	prologue(&a)
	jal(&a, sm)
	jal(&a, sm)
	log_v(&a, logp, 7)
	epilogue(&a)
	ph := thread_param(&a, eh, 10)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, tb, ph, th)
	call_word(&a, tb + 8, th)
	li(&a, V0, 0)
	epilogue(&a)
	return build_mod("modl", &a, entry), th, logp
}

// A thread waiting on the lock through a real pad2_transfer_init, as
// test_event_snap: the snapshot keeps its .Lock wait and the lock's count.
test_sio2_lock_snap :: proc() {
	fresh()
	f, th, logp := mod_l()
	id, _ := iop.iop_load(f, "modl", nil)
	base := module_base(id)
	t := iop.th_find(iop.iop_u32(base + th)^)
	check(id > 0 && log_equal(base, logp, {}) && t != nil && t.status == .Lock && iop.iop_sched.lock == 0, "sio2 lock snapshot: H waits on the lock")
	core.snap_op, core.snap_target = .Save, &snap14
	core.snap_yield()
	if !snap14_loaded {
		ids, _ := iop.iop_load(mod_r(), "modr", nil)
		check(ids > 0 && log_equal(base, logp, {7}), "sio2 lock snapshot: 62 wakes H")
		snap14_loaded = true
		core.snap_op, core.snap_target = .Load, &snap14
		core.snap_yield()
	}
	t = iop.th_find(iop.iop_u32(base + th)^)
	check(log_equal(base, logp, {}) && t != nil && t.status == .Lock && iop.iop_sched.lock == 0, "sio2 lock snapshot: H waits again after the load")
	ids, _ := iop.iop_load(mod_r(), "modr", nil)
	check(ids > 0 && log_equal(base, logp, {7}) && iop.iop_sched.lock == 0, "sio2 lock snapshot: the restored H wakes where it waited")
}

// A failed load's thread waiting on the lock goes with the load; a waiter
// from before it keeps waiting, and the lock stays held.
test_sio2_lock_undo :: proc() {
	fresh()
	s := &iop.iop_sched
	s.lock = 0
	kept := lock_waiter(0).id
	// "modq": starts thread T, of better priority than its start, which waits
	// on the lock; then calls thevent 12, which the HLE lacks.
	a: Asm
	tb := imports(&a, "thbase", 4, 6)
	te := imports(&a, "thevent", 12)
	sm := imports_v(&a, "sio2man", 0x0204, 61)
	th := at(&a)
	put(&a, 0)
	et := at(&a)
	prologue(&a)
	jal(&a, sm)
	epilogue(&a)
	pt := thread_param(&a, et, 4)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, tb, pt, th)
	call_word(&a, tb + 8, th)
	jal(&a, te)
	li(&a, V0, 0)
	epilogue(&a)
	n := len(s.threads)
	id, _ := iop.iop_load(build_mod("modq", &a, entry), "modq", nil)
	waiting := 0
	for t in s.threads {if t.status == .Lock {waiting += 1}}
	check(id == -1 && len(s.threads) == n && waiting == 1 && iop.th_find(kept).status == .Lock, "sio2 lock undo: T goes, the earlier waiter stays")
	check(s.lock == 0, "sio2 lock undo: the lock stays held")
}

// A failed load whose start took the lock gives it back: the start's thread
// goes, and no 62 will come from it.
test_sio2_lock_undo_held :: proc() {
	fresh()
	s := &iop.iop_sched
	// "modlk": its start takes the lock (61), then calls thevent 12, which the
	// HLE lacks.
	a: Asm
	te := imports(&a, "thevent", 12)
	sm := imports_v(&a, "sio2man", 0x0204, 61)
	entry := at(&a)
	prologue(&a)
	jal(&a, sm)
	jal(&a, te)
	li(&a, V0, 0)
	epilogue(&a)
	n := len(s.threads)
	id, _ := iop.iop_load(build_mod("modlk", &a, entry), "modlk", nil)
	check(id == -1 && len(s.threads) == n, "sio2 lock undo held: the load fails")
	check(s.lock == 1 && s.lock_holder == 0, "sio2 lock undo held: the lock is given back")
	check(sio2(61) == 0 && s.lock == 0, "sio2 lock undo held: and can be taken again")
}

// One sio2man transfer (51) of frames `send`, each to its port in `ports`,
// as SIO2D builds them: each register sends and gets back its frame's
// length. The reply bytes of every frame in turn, and stat6c.
xfer :: proc(ports: []u32, send: ..[]u8) -> (reply: []u8, stat: u32) {
	TD :: 0x00040000
	IN :: TD + 0x200
	OUT :: TD + 0x400
	for o := u32(0); o < 0x94; o += 4 {iop.iop_u32(TD + o)^ = 0}
	n: u32
	for f, i in send {
		l := u32(len(f))
		iop.iop_u32(TD + 0x28 + 4 * u32(i))^ = ports[i] | 0x40 | l << 8 | l << 18
		copy(iop.iop_ram[IN + n:][:l], f)
		n += l
	}
	for i in 0 ..< n {iop.iop_ram[OUT + i] = 0x55}
	iop.iop_u32(TD + 0x6c)^, iop.iop_u32(TD + 0x70)^ = n, n
	iop.iop_u32(TD + 0x74)^, iop.iop_u32(TD + 0x78)^ = IN, OUT
	check(sio2(51, TD) == 1, "sio2: transfer returns 1")
	check(iop.iop_u32(TD + 0x24)^ == 0xf && iop.iop_u32(TD + 0x68)^ == 0, "sio2: stat70 0xf, stat74 0")
	return iop.iop_ram[OUT:][:n], iop.iop_u32(TD)^
}

// A frame to the pad on port 0: 0x01, then command `cmd`, then the bytes
// after 0x00, padded with zeros to `n` bytes.
pad_frame :: proc(cmd: u8, args: []u8 = nil, n := 21) -> []u8 {
	f := make([]u8, n, context.temp_allocator)
	f[0], f[1] = 0x01, cmd
	copy(f[3:], args)
	return f
}

all_ff :: proc(b: []u8) -> bool {
	for x in b {if x != 0xff {return false}}
	return true
}

// padman's commands 0x09..0x0d on a pad area in EE RAM, and the mode a mask
// sets against the wire pad's 0x4f.
test_padman :: proc() {
	fresh()
	iop.pad_init()
	defer iop.pad_init()
	AREA :: 0x00100000
	SID :: iop.PADMAN_SID
	buf: [128]u8
	w := ([^]u32)(&buf)
	cmd :: proc(buf: []u8, words: ..u32) {
		for &b in buf {b = 0}
		w := ([^]u32)(raw_data(buf))
		for x, i in words {w[i] = x}
		iop.sif.servers[iop.PADMAN_SID](1, buf, 128)
	}
	// A command padman does not handle: its row carries the sid called.
	r100 := core.Compat_Key{.Sif_Rpc, iop.PADMAN_SID, 0x7f}
	r101 := core.Compat_Key{.Sif_Rpc, iop.PADMAN_SID_101, 0x7f}
	n100, n101 := core.compat.calls[r100].n, core.compat.calls[r101].n
	w[0] = 0x7f
	iop.sif.servers[iop.PADMAN_SID_101](1, buf[:], 128)
	check(core.compat.calls[r101].n == n101 + 1 && core.compat.calls[r100].n == n100, "padman: an unhandled 0x80000101 call's row carries 0x80000101")
	w[0] = 0x7f
	iop.sif.servers[iop.PADMAN_SID](1, buf[:], 128)
	check(core.compat.calls[r100].n == n100 + 1 && core.compat.calls[r101].n == n101 + 1, "padman: an unhandled 0x80000100 call's row carries 0x80000100")
	cmd(buf[:], 0x09, 0, 0)
	check(w[3] == 0, "padman 0x09: a socket not open, mask 0")
	cmd(buf[:], 0x0a, 0, 0, 0xfff)
	check(w[4] == 0, "padman 0x0a: a socket not open, 0")
	cmd(buf[:], 0x0b, 0, 0)
	check(w[7] == 0, "padman 0x0b: a socket not open, 0")

	iop.pads[0].buttons = {.Cross}
	cmd(buf[:], 0x01, 0, 0, 0, AREA)
	d := mem.ram_slice(AREA, 256)
	length :: proc(d: []u8) -> u32 {return endian.unchecked_get_u32le(d[0x60:])}
	check(d[1] == iop.DS2_ANALOG && length(d) == 8 && d[8 + 6] == 0 && d[0x65] == iop.DS2_ANALOG && d[0x69] == 1, "padman: open, analog, length 8, no pressures")
	cmd(buf[:], 0x09, 0, 0)
	check(w[3] == iop.DS2_RESPONSE_DUALSHOCK2, "padman 0x09: an open DualShock 2, 0x3ffff")
	cmd(buf[:], 0x0a, 0, 0, 0xfff)
	iop.pad_update()
	check(w[4] == 1 && d[1] == iop.DS2_DUALSHOCK2 && length(d) == 20 && d[8 + 6] == 0xff && d[8 + 7] == 0 && d[0x65] == iop.DS2_DUALSHOCK2, "padman 0x0a: 0xfff, DualShock 2, length 20, cross's pressure")
	check(d[128 + 1] == iop.DS2_DUALSHOCK2 && length(d[128:]) == 20, "padman 0x0a: both frames")
	cmd(buf[:], 0x0a, 0, 0, 0)
	iop.pad_update()
	check(w[4] == 1 && d[1] == iop.DS2_ANALOG && length(d) == 8 && d[8 + 6] == 0, "padman 0x0a: 0, analog without pressures")
	cmd(buf[:], 0x0a, 0, 0, 1)
	iop.pad_update()
	check(w[4] == 1 && d[1] == iop.DS2_DIGITAL && length(d) == 4 && d[4] == 0 && d[0x69] == 0, "padman 0x0a: a partial mask, digital, no sticks")
	cmd(buf[:], 0x01, 0, 0, 0, AREA)
	check(d[1] == iop.DS2_ANALOG && length(d) == 8, "padman: open sets the analog mask again")
	cmd(buf[:], 0x0b, 0, 0, 0x02020202, 0x02020202, 0x02020202)
	check(w[7] == 1, "padman 0x0b: SetVref, 1")
	cmd(buf[:], 0x0c)
	check(w[3] == 2, "padman 0x0c: 2 ports")
	cmd(buf[:], 0x0d, 0)
	check(w[3] == 1, "padman 0x0d: 1 slot without a tap")
	iop.pads[1].connected = true
	cmd(buf[:], 0x0d, 0)
	check(w[3] == 1, "padman 0x0d: 1 slot while libmtap has not opened the tap")
	mw := ([^]u32)(&buf)
	for &b in buf {b = 0}
	mw[0] = 2
	iop.sif.servers[0x80000900](1, buf[:], 128)
	cmd(buf[:], 0x0d, 0)
	check(w[3] == 4, "padman 0x0d: 4 slots once the tap is open")
	cmd(buf[:], 0x0d, 1)
	check(w[3] == 1, "padman 0x0d: port 1, 1 slot")
	iop.pads[1].connected = false
	for &b in buf {b = 0}
	mw[0] = 2
	iop.sif.servers[0x80000900](2, buf[:], 128)

	// The HLE pad and the wire pad: one mode for each mask.
	for m in ([3]u32{iop.DS2_RESPONSE_ANALOG, iop.DS2_RESPONSE_DUALSHOCK2, 0x7f}) {
		iop.ds2_reset()
		_, _ = xfer({0}, pad_frame(0x4f, {u8(m), u8(m >> 8), u8(m >> 16)}, n = 9))
		cmd(buf[:], 0x0a, 0, 0, m >> 6)
		iop.pad_update()
		check(iop.ds2.mode == iop.ds2_mask_mode(m) && d[1] == iop.ds2.mode, fmt.tprintf("padman: mask %x, the wire pad's mode", m))
	}

	key := core.Compat_Key{.Sif_Rpc, SID, 0x30}
	clear(&core.compat.calls)
	cmd(buf[:], 0x30)
	check(w[3] == 0 && core.compat.calls[key].n == 1, "padman: an unknown command is a row, 0")
	cmd(buf[:], 0x0e, 0, 0)
}

// stat6c as PCSX2 builds it: the ports a pad frame opened, the MISSING bits
// of one no pad answers, DISCONNECTED after a frame to another device; no
// device answers 0xff.
test_sio2_stat :: proc() {
	fresh()
	iop.pad_init()
	_, st := xfer({0}, pad_frame(0x42))
	check(st == iop.SIO2_NO_DEVICES_MISSING | iop.SIO2_ONE_PORT_OPEN, "sio2 stat: one pad frame, 0x1100")
	_, st = xfer({0, 0}, pad_frame(0x42), pad_frame(0x42))
	check(st == 0x1200, "sio2 stat: two, 0x1200")
	r, st2 := xfer({1}, pad_frame(0x42))
	check(st2 == 0x2d100 && all_ff(r), "sio2 stat: no pad on port 1, its MISSING bits and 0xff")
	r, st2 = xfer({2}, pad_frame(0x42))
	check(st2 == 0x2d100 && all_ff(r), "sio2 stat: none on port 2, port 2's MISSING bits as on any port but 0")
	r, st2 = xfer({0, 2}, pad_frame(0x42), []u8{0x81, 0x11, 0, 0})
	check(st2 == iop.SIO2_DISCONNECTED && all_ff(r[21:]) && r[1] == iop.DS2_DIGITAL, "sio2 stat: a memory card frame leaves DISCONNECTED, answered 0xff")
	iop.pads[0].connected = false
	r, st2 = xfer({0}, pad_frame(0x42))
	check(st2 == iop.SIO2_DISCONNECTED && all_ff(r), "sio2 stat: a pad pulled out, 0x1d100 and 0xff")
	iop.pads[0].connected = true
	r3000.state.r[4] = 0x00040000
	iop.iop_u32(0x00040000 + 0x7c)^ = 0x1000
	_, ok := iop.sio2man_fn(51)
	check(!ok, "sio2: a DMA transfer is not served")
}

// Each DualShock 2 command against PCSX2's PadDualshock2.cpp.
test_ds2 :: proc() {
	fresh()
	iop.pad_init()
	defer iop.pad_init()
	p := &iop.pads[0]
	p.buttons = {.Cross, .Up}
	p.axes = {0x10, 0x20, 0x30, 0x40}
	b := ~transmute(u16)p.buttons
	r, _ := xfer({0}, pad_frame(0x42))
	check(r[0] == 0xff && r[1] == iop.DS2_DIGITAL && r[2] == 0x5a, "ds2: digital at first, 0xff 0x41 0x5a")
	check(r[3] == u8(b) && r[4] == u8(b >> 8) && r[5] == 0x10 && r[8] == 0x40, "ds2 0x42: buttons active low, then the sticks")
	check(r[11] == 0xff && r[15] == 0xff && r[9] == 0 && r[20] == 0, "ds2 0x42: up's and cross's pressures")
	r, _ = xfer({0}, pad_frame(0x41, n = 9))
	check(r[3] == 0 && r[5] == 0 && r[8] == 0, "ds2 0x41: a digital pad's are 0")
	r, _ = xfer({0}, pad_frame(0x43, {1}, n = 9))
	check(r[1] == iop.DS2_DIGITAL && r[3] == u8(b), "ds2 0x43: entering config answers as a poll")
	r, _ = xfer({0}, pad_frame(0x40, n = 9))
	check(r[1] == iop.DS2_CONFIG && r[5] == 0x02 && r[8] == 0x5a, "ds2 0x40: id 0xf3 in config")
	r, _ = xfer({0}, pad_frame(0x44, {1, 3}, n = 9))
	check(r[3] == 0 && iop.ds2.mode == iop.DS2_ANALOG && iop.ds2.analog_locked, "ds2 0x44: analog, locked")
	r, _ = xfer({0}, pad_frame(0x45, n = 9))
	check(r[3] == 0x03 && r[4] == 0x02 && r[5] == 1 && r[6] == 0x02 && r[7] == 0x01 && r[8] == 0, "ds2 0x45: standard pad, light on")
	r, _ = xfer({0}, pad_frame(0x41, n = 9))
	check(r[3] == 0xff && r[4] == 0xff && r[5] == 0x03 && r[8] == 0x5a, "ds2 0x41: an analog pad's")
	r, _ = xfer({0}, pad_frame(0x46, {0}, n = 9))
	check(r[5] == 0x01 && r[6] == 0x02 && r[7] == 0 && r[8] == 0x0a, "ds2 0x46: stage 0")
	r, _ = xfer({0}, pad_frame(0x46, {1}, n = 9))
	check(r[5] == 0x01 && r[6] == 0x01 && r[7] == 0x01 && r[8] == 0x14, "ds2 0x46: stage 1")
	r, _ = xfer({0}, pad_frame(0x47, n = 9))
	check(r[5] == 0x02 && r[7] == 0x01 && r[8] == 0, "ds2 0x47")
	r, _ = xfer({0}, pad_frame(0x4c, {0}, n = 9))
	check(r[6] == 0x04, "ds2 0x4c: stage 0")
	r, _ = xfer({0}, pad_frame(0x4c, {1}, n = 9))
	check(r[6] == 0x07, "ds2 0x4c: stage 1")
	r, _ = xfer({0}, pad_frame(0x4d, {0, 1, 0xff, 0xff, 0xff, 0xff}, n = 9))
	check(all_ff(r[3:9]), "ds2 0x4d: the map was all 0xff")
	r, _ = xfer({0}, pad_frame(0x4d, {0, 1, 0xff, 0xff, 0xff, 0xff}, n = 9))
	check(r[3] == 0 && r[4] == 1 && all_ff(r[5:9]), "ds2 0x4d: each byte answered by the entry it replaces")
	r, _ = xfer({0}, pad_frame(0x4f, {0xff, 0xff, 0x03}, n = 9))
	check(r[8] == 0x5a && iop.ds2.mode == iop.DS2_DUALSHOCK2, "ds2 0x4f: 0x3ffff, DualShock 2 mode")
	r, _ = xfer({0}, pad_frame(0x42))
	check(r[1] == iop.DS2_CONFIG && r[3] == u8(b), "ds2 0x42: polls in config too")
	r, _ = xfer({0}, pad_frame(0x43, {0}, n = 9))
	check(r[1] == iop.DS2_CONFIG && r[3] == 0 && !iop.ds2.config, "ds2 0x43: leaving config answers 0")
	r, _ = xfer({0}, pad_frame(0x42, {1, 0x80}))
	check(r[1] == iop.DS2_DUALSHOCK2 && p.small == 1 && p.large == 0x80, "ds2 0x42: id 0x79, the motors as mapped")
	r, _ = xfer({0}, pad_frame(0x43, {1}, n = 9))
	r, _ = xfer({0}, pad_frame(0x4f, {0x3f, 0, 0}, n = 9))
	check(iop.ds2.mode == iop.DS2_ANALOG, "ds2 0x4f: 0x3f, analog mode")
	r, _ = xfer({0}, pad_frame(0x4f, {0, 0, 0}, n = 9))
	check(iop.ds2.mode == iop.DS2_DIGITAL, "ds2 0x4f: any other mask, digital")
	r, _ = xfer({0}, pad_frame(0x44, {0, 0}, n = 9))
	check(iop.ds2.mode == iop.DS2_DIGITAL && !iop.ds2.analog_locked && iop.ds2.analog_light == 0, "ds2 0x44: digital, unlocked")
	r, _ = xfer({0}, pad_frame(0x42, n = 5))
	check(len(r) == 5 && r[4] == u8(b >> 8), "ds2: a short frame gets its own bytes")
}

// sceSifSetCmdBuffer and sceSifAddCmdHandler fill the module's table and the
// system one; a cid past either table is refused, with nothing written.
test_sifcmd :: proc() {
	fresh()
	a: Asm
	sc := imports(&a, "sifcmd", 4, 8, 10)
	out := at(&a)
	put(&a, 1, 1, 1, 1, 1, 1, 1)
	tab := at(&a)
	put(&a, 0, 0, 0, 0, 0x77777777)
	tab2 := at(&a)
	put(&a, 0, 0)
	add :: proc(a: ^Asm, stub: u32, cid_hi, cid_lo, h, harg: u32, out: u32) {
		put(a, 0x3c040000 | cid_hi, 0x34840000 | cid_lo) // lui a0, hi; ori a0, a0, lo
		li(a, A1, h)
		li(a, A2, harg)
		jal(a, stub)
		store_v0(a, out)
	}
	entry := at(&a)
	prologue(&a)
	jal(&a, sc)
	store_v0(&a, out)
	la(&a, A0, tab)
	li(&a, A1, 2)
	jal(&a, sc + 8)
	store_v0(&a, out + 4)
	add(&a, sc + 16, 0, 1, 0x1234, 0x99, out + 8)
	add(&a, sc + 16, 0, 2, 0x1111, 0x22, out + 12)
	add(&a, sc + 16, 0x8000, 5, 0x4444, 0x55, out + 16)
	add(&a, sc + 16, 0x8000, 32, 0x3333, 0x66, out + 20)
	la(&a, A0, tab2)
	li(&a, A1, 1)
	jal(&a, sc + 8)
	store_v0(&a, out + 24)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modc", &a, entry), "modc", nil)
	b := module_base(id)
	u := proc(b, o: u32) -> u32 {return iop.iop_u32(b + o)^}
	s := &iop.iop_sifcmd
	check(id > 0, "sifcmd: modc loads")
	check(u(b, out) == 0 && u(b, out + 4) == 0, "sifcmd: sceSifInitCmd returns, the first table replaces none")
	check(u(b, out + 8) == 0 && u(b, tab + 8) == 0x1234 && u(b, tab + 12) == 0x99, "sifcmd: a user handler lands in the module's table")
	check(u(b, out + 12) == 0xffffffff && u(b, tab + 16) == 0x77777777, "sifcmd: a cid past the table is refused, nothing written")
	check(u(b, out + 16) == 0 && s.sys[5].handler == 0x4444 && s.sys[5].harg == 0x55, "sifcmd: a system handler lands in the system table")
	check(u(b, out + 20) == 0xffffffff, "sifcmd: a system cid past 31 is refused")
	check(u(b, out + 24) == b + tab && s.user_tab == b + tab2 && s.user_size == 1, "sifcmd: a second table returns the first")
	iop.iop_loader_init()
	check(s^ == {}, "sifcmd: the loader's reset clears the tables")
}

// sceSifGetOtherData copies EE RAM to IOP RAM in the call, through the EE's
// uncached alias and to the IOP's kseg0 one; a source or destination past
// RAM, or a source in the EE's registers, is a row and copies nothing.
test_other_data :: proc() {
	fresh()
	fnos := [?]u32{23}
	a: Asm
	sc := imports(&a, "sifcmd", ..fnos[:])
	dst := at(&a)
	put(&a, 0, 0, 0, 0, 0x77777777)
	entry := at(&a)
	put(&a, JR_RA, 0x24020000)
	id, _ := iop.iop_load(build_mod("modg", &a, entry), "modg", nil)
	b := module_base(id)
	u := proc(at: u32) -> u32 {return iop.iop_u32(at)^}
	EE_SRC :: 0x00100400
	for i in u32(0) ..< 5 {mem.wr32(EE_SRC + 4 * i, 0x11111111 * (i + 1))}
	get :: proc(stubs, src, dest, size: u32) -> u32 {
		fnos := [?]u32{23}
		return lib_call(stubs, fnos[:], 23, 0, src, dest, size)
	}
	check(id > 0 && get(b + sc, 0x20000000 | EE_SRC, 0x80000000 | (b + dst), 16) == 0, "GetOtherData: returns 0")
	check(u(b + dst) == 0x11111111 && u(b + dst + 12) == 0x44444444 && u(b + dst + 16) == 0x77777777, "GetOtherData: 16 bytes copied, no more")
	iop.iop_u32(b + dst)^ = 0
	rows :: proc(src, size: u32) -> u64 {return core.compat.calls[core.Compat_Key{.Iop_Other_Data, src, size}].n}
	check(get(b + sc, mem.RAM_SIZE - 8, b + dst, 16) == 0 && rows(mem.RAM_SIZE - 8, 16) == 1, "GetOtherData: a source past EE RAM is a row")
	check(get(b + sc, 0x10003000, b + dst, 16) == 0 && rows(0x10003000, 16) == 1, "GetOtherData: a source in the EE's registers is a row")
	check(get(b + sc, EE_SRC, iop.IOP_RAM_SIZE - 8, 16) == 0 && rows(EE_SRC, 16) == 1, "GetOtherData: a destination past IOP RAM is a row")
	check(get(b + sc, EE_SRC, b + dst, 0xffffffff) == 0 && rows(EE_SRC, 0xffffffff) == 1, "GetOtherData: a size past both is a row")
	check(u(b + dst) == 0, "GetOtherData: nothing copied for any of them")
}

EE_LIST :: 0x00100000 // a SifSetDma list in EE RAM
EE_PKT :: 0x00100100 // the packet it sends
EE_BUF :: 0x00100200 // the EE's command buffer

// Sends the IOP a packet of command `cid`, as the EE's SifSetDma does.
send_cmd :: proc(cid: u32) {
	for w, i in ([4]u32{16, 0, cid, 0}) {mem.wr32(EE_PKT + 4 * u32(i), w)}
	for w, i in ([4]u32{EE_PKT, iop.IOP_CMDBUF, 16, 0}) {mem.wr32(EE_LIST + 4 * u32(i), w)}
	iop.sif_set_dma(EE_LIST, 1, 0)
}

test_cmd_deliver :: proc() {
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	a: Asm
	tb := imports(&a, "thbase", 4, 6, 33)
	ts := imports(&a, "thsemap", 4, 7, 8)
	sc := imports(&a, "sifcmd", 8, 10, 12)
	sem, th, dl := at(&a), at(&a) + 4, at(&a) + 8
	put(&a, 0, 0, 100)
	tab := at(&a)
	put(&a, 0, 0, 0, 0)
	pkt := at(&a)
	put(&a, 0, 0, 0, 0)
	sp := sema_param(&a, 0, 0)
	// Command 0's handler iSignalSemas harg, command 1's waits on it, which
	// a handler may not.
	h0 := at(&a)
	prologue(&a)
	put(&a, 0x00a02025) // or a0, a1, zero
	jal(&a, ts + 8)
	epilogue(&a)
	h1 := at(&a)
	prologue(&a)
	put(&a, 0x00a02025)
	jal(&a, ts + 16)
	epilogue(&a)
	// The thread: waits on sem, delays `dl`, sends command 0x10, again.
	w := at(&a)
	put(&a, 0x27bdffe8, 0xafa00010, 0xafa00014) // addiu sp, sp, -24; sw zero, 16(sp); sw zero, 20(sp)
	wl := at(&a)
	call_word(&a, ts + 16, sem)
	lw_at(&a, A0, dl)
	jal(&a, tb + 16)
	li(&a, A0, 0x10)
	la(&a, A1, pkt)
	li(&a, A2, 16)
	li(&a, 7, 0)
	jal(&a, sc + 16)
	put_rel(&a, 0x08000000 | wl >> 2, 4) // j wl
	put(&a, 0)
	tp := thread_param(&a, w, 20)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, ts, sp, sem)
	call_addr(&a, tb, tp, th)
	call_word(&a, tb + 8, th)
	la(&a, A0, tab)
	li(&a, A1, 2)
	jal(&a, sc)
	for c in ([2][2]u32{{0, h0}, {1, h1}}) {
		lw_at(&a, A2, sem)
		la(&a, A1, c[1])
		li(&a, A0, c[0])
		jal(&a, sc + 8)
	}
	li(&a, V0, 0)
	epilogue(&a)
	base := coroutines()
	id, r := iop.iop_load(build_mod("modk", &a, entry), "modk", nil)
	b := module_base(id)
	t := iop.th_find(iop.iop_u32(b + th)^)
	check(id > 0 && r == 0 && t != nil && t.status == .Wait, "deliver: the thread waits after the load")
	check(iop.iop_wake_ee == max(u64), "deliver: no wake while every thread waits")

	iop.sif.ee_buf = EE_BUF
	mem.dmac_stat &~= 1 << mem.DMA_SIF0
	cpu.state.cycles = 0
	VBLANK :: 1 << 40
	cpu.next_event = VBLANK
	send_cmd(0)
	t = iop.th_find(iop.iop_u32(b + th)^)
	check(t.status == .Delay && t.wake_at == r3000.state.cycles + 3686, "deliver: the signalled thread delays 100 us, 3686 cycles")
	check(iop.iop_wake_ee == t.wake_at * 8 && cpu.next_event == iop.iop_wake_ee, "deliver: the EE's next event is the wake, not the vblank")
	check(coroutines() == base + 2 && len(iop.sif.replies) == 0, "deliver: a handler coroutine, nothing sent yet")

	kernel.k.vblank_start, kernel.k.vblank_end = VBLANK, VBLANK
	sr := cpu.state.cop0[12]
	cpu.state.cop0[12] |= 0x10001
	cpu.state.cycles = iop.iop_wake_ee
	kernel.run_events()
	due := iop.sif_next_ee()
	check(len(iop.sif.replies) == 1 && due > cpu.state.cycles && due <= r3000.state.cycles * 8 && cpu.next_event == due, "tick: the thread's command waits for the IOP clock it was sent at")
	cpu.state.cycles = due
	kernel.run_events()
	cpu.state.cop0[12] = sr
	t = iop.th_find(iop.iop_u32(b + th)^)
	check(mem.rd32(EE_BUF) == 16 && mem.rd32(EE_BUF + 8) == 0x10 && len(iop.sif.replies) == 0, "tick: then the thread's command is in EE RAM")
	check(t.status == .Wait && iop.iop_wake_ee == max(u64) && cpu.next_event == VBLANK, "tick: the thread waits again, no wake")
	mem.dmac_stat &~= 1 << mem.DMA_SIF0

	iop.iop_u32(b + dl)^ = 0xffffffff
	send_cmd(0)
	t = iop.th_find(iop.iop_u32(b + th)^)
	check(t.status == .Delay && t.wake_at == r3000.state.cycles + 158_329_674_362, "deliver: a delay of 2^32-1 us, in u64 cycles")
	check(coroutines() == base + 2, "deliver: the handler coroutine serves again")

	key := core.Compat_Key{.Iop_Intr, 1, 0}
	send_cmd(1)
	check(core.compat.calls[key].n == 0 && coroutines() == base + 2, "deliver: WaitSema in a handler is refused, the handler returns, no row")
	check(!iop.iop_sched.intr && r3000.next_event == iop.IOP_EVENT_OFF, "deliver: the IOP off after it")
	send_cmd(0)
	check(coroutines() == base + 2 && iop.iop_sched.semas[0].count == 1, "deliver: the next delivery runs on the same coroutine")

	fresh()
	check(coroutines() == base && iop.iop_wake_ee == max(u64), "deliver: the loader's reset kills it")
}

// A reply reaches the EE no earlier than the IOP clock it was sent at.
test_reply_due :: proc() {
	fresh()
	drop_replies()
	iop.sif.ee_buf = EE_BUF
	mem.dmac_stat &~= 1 << mem.DMA_SIF0
	kernel.k.vblank_start, kernel.k.vblank_end = 1 << 40, 1 << 40
	pkt: [4]u32 = {16, 0, 0x10, 0}
	send :: proc(pkt: ^[4]u32, cid: u32) {
		pkt[2] = cid
		iop.sif_send_raw(([^]u8)(pkt)[:16])
	}
	pumped :: proc(cid: u32) -> bool {
		ok := mem.dmac_stat & (1 << mem.DMA_SIF0) != 0 && mem.rd32(EE_BUF + 8) == cid
		mem.dmac_stat &~= 1 << mem.DMA_SIF0
		mem.wr32(EE_BUF + 8, 0)
		return ok
	}

	cpu.state.cycles = 1000
	r3000.state.cycles = 500
	cpu.next_event = max(u64)
	send(&pkt, 0x11)
	check(iop.sif_next_ee() == 4000 && cpu.next_event == 4000, "reply due: the IOP ahead, due at its clock, the EE's next event")
	cpu.state.cycles = 3999
	iop.sif_pump()
	check(len(iop.sif.replies) == 1 && !pumped(0x11), "reply due: not pumped before its due")
	kernel.update_next_event()
	check(cpu.next_event == 4000, "reply due: the next event stays the due")
	cpu.state.cycles = 4000
	iop.sif_pump()
	check(len(iop.sif.replies) == 0 && pumped(0x11) && iop.sif_next_ee() == max(u64), "reply due: pumped at its due")

	r3000.state.cycles = 600
	send(&pkt, 0x12)
	r3000.state.cycles = 700
	send(&pkt, 0x13)
	check(len(iop.sif.replies) == 2 && iop.sif.replies[0].due == 4800 && iop.sif.replies[1].due == 5600, "reply due: two replies keep their dues")
	cpu.state.cycles = 5600
	iop.sif_pump()
	check(pumped(0x12), "reply due: the first sent goes first")
	iop.sif_pump()
	check(pumped(0x13) && len(iop.sif.replies) == 0, "reply due: then the second")

	cpu.state.cycles = 10000
	r3000.state.cycles = 100
	send(&pkt, 0x14)
	check(iop.sif_next_ee() == 10000, "reply due: the IOP behind, due at once")
	iop.sif_pump()
	check(pumped(0x14), "reply due: pumped at once")

	// The FIFO tail: a reply sent while the IOP is behind waits for the
	// earlier one still in flight.
	cpu.state.cycles = 1000
	r3000.state.cycles = 500
	send(&pkt, 0x15)
	r3000.state.cycles = 50
	send(&pkt, 0x16)
	check(iop.sif.replies[0].due == 4000 && iop.sif.replies[1].due == 4000, "reply due: a later reply waits for the one in flight")
	drop_replies()

	// A reply the EE side builds is due at EE now, whatever the IOP clock:
	// r3000 idles up to a slice past it.
	cpu.next_event = max(u64)
	send_pkt(iop.SIF_CMD_INIT_CMD)
	check(len(iop.sif.replies) == 2 && iop.sif.replies[0].due == 1000 && iop.sif.replies[1].due == 1000 && cpu.next_event == 1000, "reply due: an EE-side reply is due at EE now, the IOP ahead")
	// And behind an IOP reply in flight it keeps the order.
	drop_replies()
	r3000.state.cycles = 500
	send(&pkt, 0x17)
	send_pkt(iop.SIF_CMD_INIT_CMD)
	check(len(iop.sif.replies) == 3 && iop.sif.replies[2].due == 4000, "reply due: an EE-side reply behind one in flight waits for it")

	// The SIF reset drops the queued replies.
	send_pkt(iop.SIF_CMD_RESET, 0, 0, 0) // an empty path at +24
	check(len(iop.sif.replies) == 0 && iop.sif_next_ee() == max(u64), "reply due: SIF reset drops the queue")
	iop.sif.ee_buf = EE_BUF

	// Held while due: update_next_event leaves it out; what frees it wakes the EE.
	cpu.state.cycles = 4000
	send(&pkt, 0x18)
	mem.dmac_stat |= 1 << mem.DMA_SIF0
	kernel.update_next_event()
	check(cpu.next_event == 1 << 40, "reply due: a due reply held by SIF0 busy is no next event")
	mem.dmac_stat &~= 1 << mem.DMA_SIF0
	iop.sif_wake()
	check(cpu.next_event == 4000, "reply due: clearing SIF0's D_STAT bit wakes the EE")
	iop.sif_pump()
	check(pumped(0x18), "reply due: then it is pumped")
	send(&pkt, 0x19)
	iop.sif.ee_buf = 0
	kernel.update_next_event()
	check(cpu.next_event == 1 << 40, "reply due: a due reply with no receive buffer is no next event")
	send_pkt(iop.SIF_CMD_CHANGE_SADDR, EE_BUF)
	check(iop.sif.ee_buf == EE_BUF && cpu.next_event == 4000, "reply due: CHANGE_SADDR wakes the EE")
	iop.sif_pump()
	check(pumped(0x19), "reply due: then it is pumped")

	// Due under DI: not delivered, no next event; EI delivers it at once.
	sr := cpu.state.cop0[12]
	cpu.state.cop0[12] = (sr | 1) &~ 0x10000
	send(&pkt, 0x1a)
	kernel.run_events()
	check(len(iop.sif.replies) == 1 && cpu.next_event == 1 << 40, "reply due: held under DI, no next event")
	kernel.ei()
	check(cpu.next_event == 4000, "reply due: EI sets the next event to now")
	kernel.run_events()
	cpu.state.cop0[12] = sr
	check(pumped(0x1a) && len(iop.sif.replies) == 0, "reply due: then it is pumped")
	fresh()
}

// Sends the IOP a packet of command `cid` with payload `args`.
send_pkt :: proc(cid: u32, args: ..u32) {
	n := 16 + 4 * u32(len(args))
	for w, i in ([4]u32{n, 0, cid, 0}) {mem.wr32(EE_PKT + 4 * u32(i), w)}
	for w, i in args {mem.wr32(EE_PKT + 16 + 4 * u32(i), w)}
	for w, i in ([4]u32{EE_PKT, iop.IOP_CMDBUF, n, 0}) {mem.wr32(EE_LIST + 4 * u32(i), w)}
	iop.sif_set_dma(EE_LIST, 1, 0)
}

// Word w of the IOP's queued packet i.
reply_word :: proc(i, w: int) -> u32 {return ([^]u32)(raw_data(iop.sif.replies[i].p))[w]}

drop_replies :: proc() {iop.sif_drop_replies()}

// Whether the IOP's queued packets are, in order, the RPC_ENDs of the calls
// with rec_id `recs`, made to descriptor sd.
call_ends :: proc(sd: u32, recs: ..u32) -> bool {
	if len(iop.sif.replies) != len(recs) {return false}
	for rec, i in recs {
		if reply_word(i, 2) != iop.SIF_CMD_RPC_END || reply_word(i, 4) != rec {return false}
		if reply_word(i, 8) != iop.SIF_CMD_RPC_CALL || reply_word(i, 9) != sd {return false}
	}
	return true
}

A3 :: 7
T1 :: 9
T2 :: 10

li32 :: proc(a: ^Asm, rt, v: u32) {put(a, 0x3c000000 | rt << 16 | v >> 16, 0x34000000 | rt << 21 | rt << 16 | v & 0xffff)}

// bne rs, rt to a label not yet placed; its word index, for branch_to.
bne :: proc(a: ^Asm, rs, rt: u32) -> int {
	put(a, 0x14000000 | rs << 21 | rt << 16, 0)
	return len(a.w) - 2
}
branch_to :: proc(a: ^Asm, i: int) {a.w[i] |= (at(a) - 4 * u32(i) - 4) / 4 & 0xffff}

// A thread entry that serves server `sid` (sd, func, buf, qd its four
// words, IOP addresses or offsets after `rel`) on queue qd: InitRpc,
// SetRpcQueue, RegisterRpc, RpcLoop. Stubs: GetThreadId, sifcmd 14, 17, 19
// and 22 at sc, sc + 8, ...
rpc_thread :: proc(a: ^Asm, gtid, sc, sid: u32, w: [4]u32, abs: bool) -> u32 {
	addr :: proc(a: ^Asm, rt, v: u32, abs: bool) {if abs {li32(a, rt, v)} else {la(a, rt, v)}}
	sd, fn, buf, qd := w[0], w[1], w[2], w[3]
	e := at(a)
	put(a, 0x27bdffe0, 0xafbf001c) // addiu sp, sp, -32; sw ra, 28(sp)
	li(a, A0, 0)
	jal(a, sc)
	jal(a, gtid)
	addr(a, A0, qd, abs)
	put(a, 0x00402825) // or a1, v0, zero
	jal(a, sc + 16)
	addr(a, A0, sd, abs)
	li(a, A1, sid)
	addr(a, A2, fn, abs)
	addr(a, A3, buf, abs)
	addr(a, T0, qd, abs)
	put(a, 0xafa00010, 0xafa00014, 0xafa80018) // sw zero, 16(sp); sw zero, 20(sp); sw t0, 24(sp)
	jal(a, sc + 8)
	addr(a, A0, qd, abs)
	jal(a, sc + 24)
	put(a, 0x8fbf001c, JR_RA, 0x27bd0020) // lw ra, 28(sp); jr ra; addiu sp, sp, 32
	return e
}

snap5: core.Snapshot
snap5_loaded: bool // not emulated state

RPC_SID :: 0x4321
RPC_SID2 :: 0x4322 // registered by a load that fails

// With PS_IRX=1 a bind to a sid the HLE serves gets its descriptor, module
// or not, and no row; a sid nobody serves gets server 0 and one row, however
// often the EE binds again, and the table past SIF_BIND_SIDS sids counts by
// rows alone. Without PS_IRX an unknown sid gets a descriptor and a row.
test_rpc_bind :: proc() {
	drop_replies()
	defer drop_replies()
	iop.sif_bind_retries = {}
	HLE_SID :: 0x80000003 // the HLE's IOP heap server
	UNK :: 0x5a5a0000
	iop.iop_irx = true
	send_pkt(iop.SIF_CMD_RPC_BIND, 1, 0, 0, 0, HLE_SID)
	sd := reply_word(0, 9)
	check(sd != 0 && iop.iop_u32(sd)^ == HLE_SID && core.compat.calls[{.Sif_Bind, HLE_SID, 0}].n == 0, "bind: a sid the HLE serves gets its descriptor with PS_IRX=1, no row")
	check(iop.sif_bind_retries.used == 0, "bind: and is not counted as a retry")
	drop_replies()
	for i in u32(0) ..< 5 {send_pkt(iop.SIF_CMD_RPC_BIND, 2 + i, 0, 0, 0, UNK)}
	zero := true
	for i in 0 ..< 5 {zero &&= reply_word(i, 9) == 0}
	t := &iop.sif_bind_retries
	check(zero && core.compat.calls[{.Sif_Bind, UNK, 0}].n == 1 && t.n[0] == 4 && UNK not_in iop.sif.bound, "bind: an unserved sid gets server 0 five times, one row, four retries")
	drop_replies()
	for i in u32(1) ..= iop.SIF_BIND_SIDS {send_pkt(iop.SIF_CMD_RPC_BIND, 10, 0, 0, 0, UNK + i)}
	last := u32(UNK + iop.SIF_BIND_SIDS)
	send_pkt(iop.SIF_CMD_RPC_BIND, 11, 0, 0, 0, last)
	check(t.used == iop.SIF_BIND_SIDS && core.compat.calls[{.Sif_Bind, last, 0}].n == 2, "bind: a sid past the table counts by its row")
	drop_replies()

	// A call with server 0, as a client that did not bind again sends it,
	// or a server word past the descriptors handed out: a row, nothing run,
	// no RPC_END, IOP memory untouched.
	low := iop.iop_u32(0x100)^
	far := iop.IOP_SERVERS + 0x10000 * u32(len(iop.sif.bound))
	send_pkt(iop.SIF_CMD_RPC_CALL, 13, 0, 0, 0, 7, 8, 0x00100400, 8, 0, 0)
	send_pkt(iop.SIF_CMD_RPC_CALL, 14, 0, 0, 0, 7, 8, 0x00100400, 8, 0, 0)
	send_pkt(iop.SIF_CMD_RPC_CALL, 15, 0, 0, 0, 7, 8, 0x00100400, 8, 0, far)
	send_pkt(iop.SIF_CMD_RPC_CALL, 16, 0, 0, 0, 7, 8, 0x00100400, 8, 0, sd + 4)
	check(len(iop.sif.replies) == 0 && core.compat.calls[{.Sif_Rpc, 0, 7}].n == 2 && core.compat.calls[{.Sif_Rpc, far, 7}].n == 1 && core.compat.calls[{.Sif_Rpc, sd + 4, 7}].n == 1, "bind: a call to no descriptor is a row and gets no RPC_END")
	check(iop.iop_u32(0x100)^ == low, "bind: and touches no IOP memory")
	iop.iop_irx = false
	send_pkt(iop.SIF_CMD_RPC_BIND, 12, 0, 0, 0, UNK)
	sd = reply_word(0, 9)
	check(sd != 0 && iop.iop_u32(sd)^ == UNK && core.compat.calls[{.Sif_Bind, UNK, 0}].n == 2, "bind: without PS_IRX an unknown sid gets a descriptor and a row")
	delete_key(&iop.sif.bound, UNK)
	delete_key(&iop.sif.bound, HLE_SID)
	iop.sif_bind_retries = {}
}

// Conditions: a bind made before the module registers answers server 0, one
// made after reaches its server;
// the EE's request and reply are bounded by the server's buffer and EE
// RAM; calls are served first come first, one queued while the function
// waits is kept, and both survive a snapshot; a request whose RPC_END never
// comes leaves a row; a queue whose thread a failed load's undo killed is
// dropped, a bind to its server answered server 0; of two servers for one id,
// the first registered takes the calls, and dropping it leaves the other.
test_rpc :: proc() {
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	drop_replies()
	defer drop_replies()
	iop.sif_bind_retries = {}
	cpu.state.cycles = 0
	cpu.next_event = 1 << 40
	// "modr": thread R serves RPC_SID with func, which logs fno and size;
	// fno 2 waits on sem, fno 3 calls what sifcmd lacks; it returns buf,
	// or 0 for fno 0.
	a: Asm
	tb := imports(&a, "thbase", 4, 6, 20)
	ts := imports(&a, "thsemap", 4, 6, 8)
	sc := imports(&a, "sifcmd", 14, 17, 19, 22, 21)
	logp := log_words(&a, 24)
	sem, th := at(&a), at(&a) + 4
	put(&a, 0, 0)
	sd := at(&a)
	for _ in 0 ..< 18 {put(&a, 0)}
	qd := at(&a)
	for _ in 0 ..< 8 {put(&a, 0)}
	buf := at(&a)
	for _ in 0 ..< 16 {put(&a, 0)}
	sd2 := at(&a)
	for _ in 0 ..< 18 {put(&a, 0)}
	qd2 := at(&a)
	for _ in 0 ..< 8 {put(&a, 0)}
	buf2 := at(&a)
	for _ in 0 ..< 16 {put(&a, 0)}
	sd3 := at(&a)
	for _ in 0 ..< 18 {put(&a, 0)}
	qd3 := at(&a)
	for _ in 0 ..< 8 {put(&a, 0)}
	semp := sema_param(&a, 0, 0)
	fn := at(&a)
	put(&a, 0x27bdfff0, 0xafbf0000, 0xafa50004, 0xafa40008) // addiu sp, sp, -16; sw ra, 0(sp); sw a1, 4(sp); sw a0, 8(sp)
	la(&a, T0, logp)
	put(&a, 0x8d090000, 0, 0xad240000, 0xad260004, 0x25290008, 0xad090000) // lw t1, 0(t0); nop; sw a0, 0(t1); sw a2, 4(t1); addiu t1, t1, 8; sw t1, 0(t0)
	li(&a, T2, 2)
	l1 := bne(&a, A0, T2)
	lw_at(&a, A0, sem)
	jal(&a, ts + 16)
	branch_to(&a, l1)
	put(&a, 0x8fa40008, 0) // lw a0, 8(sp); nop
	li(&a, T2, 3)
	l2 := bne(&a, A0, T2)
	jal(&a, sc + 32)
	branch_to(&a, l2)
	put(&a, 0x8fa20004, 0x8fa40008, 0) // lw v0, 4(sp); lw a0, 8(sp); nop
	l3 := bne(&a, A0, 0)
	li(&a, V0, 0)
	branch_to(&a, l3)
	epilogue(&a)
	er := rpc_thread(&a, tb + 16, sc, RPC_SID, {sd, fn, buf, qd}, false)
	tp := thread_param(&a, er, 10)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, ts, semp, sem)
	call_addr(&a, tb, tp, th)
	call_word(&a, tb + 8, th)
	li(&a, V0, 0)
	epilogue(&a)

	// The bind comes first: server 0, as retail answers a sid nobody
	// registered; the EE's bind again is only counted.
	send_pkt(iop.SIF_CMD_RPC_BIND, 1, 0, 0, 0, RPC_SID)
	check(len(iop.sif.replies) == 1 && reply_word(0, 8) == iop.SIF_CMD_RPC_BIND && reply_word(0, 9) == 0 && reply_word(0, 10) == 0, "rpc: a bind before the module answers server 0")
	drop_replies()
	send_pkt(iop.SIF_CMD_RPC_BIND, 2, 0, 0, 0, RPC_SID)
	t := &iop.sif_bind_retries
	check(len(iop.sif.replies) == 1 && reply_word(0, 9) == 0 && RPC_SID not_in iop.sif.bound, "rpc: a bind again before the module answers server 0, nothing bound")
	check(t.used == 1 && t.sid[0] == RPC_SID && t.n[0] == 1 && core.compat.calls[{.Sif_Bind, RPC_SID, 0}].n == 1, "rpc: the bind again is counted, one row for the sid")
	drop_replies()
	id, r := iop.iop_load(build_mod("modr", &a, entry), "modr", nil)
	b := module_base(id)
	s := &iop.iop_rpc
	check(id > 0 && r == 0 && s.n_servers == 1 && s.servers[0] == {RPC_SID, b + sd, b + qd}, "rpc: R registers its server")
	check(iop.iop_u32(b + sd)^ == RPC_SID && iop.iop_u32(b + sd + 4)^ == b + fn && iop.iop_u32(b + sd + 8)^ == b + buf && iop.iop_u32(b + sd + 0x40)^ == b + qd, "rpc: RegisterRpc fills the descriptor")
	check(iop.iop_u32(b + qd)^ == iop.iop_u32(b + th)^ && s.n_queues == 1 && !s.queues[0].busy, "rpc: SetRpcQueue names R, which sleeps")
	send_pkt(iop.SIF_CMD_RPC_BIND, 3, 0, 0, 0, RPC_SID)
	check(core.compat.calls[{.Sif_Bind, RPC_SID, 0}].n == 1, "rpc: a bind to a sid a module serves leaves no row")
	hsd := reply_word(0, 9)
	check(len(iop.sif.replies) == 1 && hsd != 0 && iop.iop_u32(hsd)^ == RPC_SID && t.n[0] == 1, "rpc: once the module registers, the bind gets the HLE's descriptor")
	drop_replies()

	// A call reaches func with the request copied in; the reply is the
	// rsize bytes func returned, then RPC_END.
	EE_RECV :: 0x00100400
	call :: proc(rec, fno, size, recv, rsize, sd: u32) {
		send_pkt(iop.SIF_CMD_RPC_CALL, rec, 0, 0, 0, fno, size, recv, rsize, 0, sd)
	}
	iop.iop_u32(hsd + 0x100)^, iop.iop_u32(hsd + 0x104)^ = 0x11111111, 0x22222222
	call(10, 1, 8, EE_RECV, 8, hsd)
	check(log_equal(b, logp, {1, 8}) && s.calls == 1, "rpc: the call reaches func with fno and size")
	check(mem.rd32(EE_RECV) == 0x11111111 && mem.rd32(EE_RECV + 4) == 0x22222222, "rpc: the request in buf, the reply from what func returned")
	check(call_ends(hsd, 10), "rpc: then RPC_END")
	drop_replies()

	mem.wr32(EE_RECV, 0xaaaaaaaa)
	call(11, 0, 8, EE_RECV, 8, hsd)
	check(log_equal(b, logp, {1, 8, 0, 8}) && mem.rd32(EE_RECV) == 0xaaaaaaaa && call_ends(hsd, 11), "rpc: func returning 0 copies nothing, RPC_END all the same")
	drop_replies()

	// Out of bounds: the request past the module's block, the reply past EE
	// RAM; a row each, and RPC_END.
	row := core.Compat_Key{.Iop_Rpc, RPC_SID, 1}
	call(12, 1, 0x8000, EE_RECV, 8, hsd)
	check(log_equal(b, logp, {1, 8, 0, 8, 1, 0}) && core.compat.calls[row].n == 1 && call_ends(hsd, 12), "rpc: a request past the buffer's block is cut to 0 bytes, a row")
	drop_replies()
	call(13, 1, 8, mem.RAM_SIZE - 4, 8, hsd)
	check(core.compat.calls[row].n == 2 && call_ends(hsd, 13), "rpc: a reply past EE RAM is not copied, a row")
	drop_replies()

	// Calls made one after another, each after the last one's RPC_END, as
	// an EE client that waits makes them: the server never holds one when the
	// next comes.
	busy :: proc(fno: u32) -> u64 {return core.compat.calls[core.Compat_Key{.Iop_Rpc_Busy, RPC_SID, fno}].n}
	check(busy(0) == 0 && busy(1) == 0, "rpc: calls one after another are no busy row")

	// fno 2 waits in func; a call made meanwhile is queued behind it, with a
	// busy row: retail's descriptor holds one request, and the EE's bytes
	// land in the buffer fno 2 may still read.
	call(20, 2, 4, 0, 0, hsd)
	check(busy(2) == 0, "rpc: a call to an idle server is no busy row")
	call(21, 1, 4, 0, 0, hsd)
	want := []u32{1, 8, 0, 8, 1, 0, 1, 8, 2, 4}
	check(log_equal(b, logp, want) && len(iop.sif.replies) == 0 && s.n_reqs == 1 && s.queues[0].busy, "rpc: a call while func waits is queued, no RPC_END yet")
	check(busy(1) == 1, "rpc: a call while func waits is a busy row")
	core.snap_op, core.snap_target = .Save, &snap5
	core.snap_yield()
	if !snap5_loaded {
		ids, _ := iop.iop_load(mod_s(), "mods", nil)
		check(ids > 0 && log_equal(b, logp, {1, 8, 0, 8, 1, 0, 1, 8, 2, 4, 1, 4}) && call_ends(hsd, 20, 21), "rpc: the signal ends fno 2, then the queued call runs, in order")
		drop_replies()
		snap5_loaded = true
		core.snap_op, core.snap_target = .Load, &snap5
		core.snap_yield()
	}
	drop_replies()
	check(log_equal(b, logp, want) && s.n_reqs == 1 && s.queues[0].busy && s.queues[0].cur.rec_id == 20, "rpc: the snapshot keeps the request in func and the one queued")
	ids, _ := iop.iop_load(mod_s(), "mods", nil)
	check(ids > 0 && log_equal(b, logp, {1, 8, 0, 8, 1, 0, 1, 8, 2, 4, 1, 4}) && call_ends(hsd, 20, 21) && s.n_reqs == 0, "rpc: after the load both end as before")
	drop_replies()

	// A full queue: the call is lost with a row, no busy row, func not run.
	for &v in s.reqs {v = {sid = 0x7e570000, sd = 1, qd = 1}}
	s.n_reqs = iop.IOP_RPC_REQS
	call(22, 5, 4, 0, 0, hsd)
	check(core.compat.calls[{.Iop_Rpc, RPC_SID, 5}].n == 1 && busy(5) == 0 && len(iop.sif.replies) == 0 && s.n_reqs == iop.IOP_RPC_REQS, "rpc: a call past a full queue gets no RPC_END, a row")
	check(log_equal(b, logp, {1, 8, 0, 8, 1, 0, 1, 8, 2, 4, 1, 4}), "rpc: func does not run it")
	s.n_reqs = 0

	// A failed load whose threads registered RPC_SID2, and RPC_SID again,
	// their descriptors and queues in modr's resident memory: the undo kills
	// the threads, their queues and servers go, and a bind to RPC_SID2 gets
	// server 0; RPC_SID is still R's.
	q: Asm
	qtb := imports(&q, "thbase", 4, 6, 20)
	qsc := imports(&q, "sifcmd", 14, 17, 19, 22)
	qsm := imports(&q, "sysmem", 99)
	qth := at(&q)
	put(&q, 0, 0)
	eq := rpc_thread(&q, qtb + 16, qsc, RPC_SID2, {b + sd2, b + fn, b + buf2, b + qd2}, true)
	qtp := thread_param(&q, eq, 4) // ahead of the start, which it preempts
	eq3 := rpc_thread(&q, qtb + 16, qsc, RPC_SID, {b + sd3, b + fn, b + buf2, b + qd3}, true)
	qtp3 := thread_param(&q, eq3, 4)
	qentry := at(&q)
	prologue(&q)
	call_addr(&q, qtb, qtp, qth)
	call_word(&q, qtb + 8, qth)
	call_addr(&q, qtb, qtp3, qth + 4)
	call_word(&q, qtb + 8, qth + 4)
	jal(&q, qsm)
	li(&q, V0, 0)
	epilogue(&q)
	idq, _ := iop.iop_load(build_mod("modq", &q, qentry), "modq", nil)
	check(idq <= 0 && iop.iop_u32(b + sd2)^ == RPC_SID2, "rpc: modq's thread registered RPC_SID2 before its load failed")
	check(iop.iop_u32(b + sd3)^ == RPC_SID, "rpc: modq's other thread registered RPC_SID again")
	check(s.n_servers == 1 && s.n_queues == 1 && s.servers[0] == {RPC_SID, b + sd, b + qd}, "rpc: the undo drops the queues of the killed threads and their servers, R's stays")
	call(31, 1, 4, 0, 0, hsd)
	want = []u32{1, 8, 0, 8, 1, 0, 1, 8, 2, 4, 1, 4, 1, 4}
	check(log_equal(b, logp, want) && call_ends(hsd, 31), "rpc: a call to RPC_SID still reaches R's func")
	drop_replies()
	drop_replies()
	send_pkt(iop.SIF_CMD_RPC_BIND, 2, 0, 0, 0, RPC_SID2)
	check(reply_word(0, 9) == 0 && core.compat.calls[{.Sif_Bind, RPC_SID2, 0}].n == 1, "rpc: a bind to the dropped server answers server 0, a row")
	drop_replies()

	// "modp" loads and registers RPC_SID again, with a func that logs
	// nothing and returns 0: the first server, R's, still takes the calls.
	p: Asm
	ptb := imports(&p, "thbase", 4, 6, 20)
	psc := imports(&p, "sifcmd", 14, 17, 19, 22)
	pth := at(&p)
	put(&p, 0)
	psd := at(&p)
	for _ in 0 ..< 18 {put(&p, 0)}
	pqd := at(&p)
	for _ in 0 ..< 8 {put(&p, 0)}
	pfn := at(&p)
	put(&p, JR_RA, 0x24020000) // jr ra; li v0, 0
	ep := rpc_thread(&p, ptb + 16, psc, RPC_SID, {psd, pfn, psd, pqd}, false)
	ptp := thread_param(&p, ep, 4)
	pentry := at(&p)
	prologue(&p)
	call_addr(&p, ptb, ptp, pth)
	call_word(&p, ptb + 8, pth)
	li(&p, V0, 0)
	epilogue(&p)
	idp, _ := iop.iop_load(build_mod("modp", &p, pentry), "modp", nil)
	bp := module_base(idp)
	check(idp > 0 && s.n_servers == 2 && s.servers[1] == {RPC_SID, bp + psd, bp + pqd}, "rpc: modp registers RPC_SID a second time")
	call(32, 1, 4, 0, 0, hsd)
	want = []u32{1, 8, 0, 8, 1, 0, 1, 8, 2, 4, 1, 4, 1, 4, 1, 4}
	check(log_equal(b, logp, want) && call_ends(hsd, 32), "rpc: the first server registered takes the call")
	drop_replies()

	// fno 3 calls what sifcmd lacks: R is stopped, the call gets no RPC_END
	// and leaves a row; its server goes, and the next call is modp's.
	call(40, 3, 0, 0, 0, hsd)
	lost := core.Compat_Key{.Iop_Rpc, RPC_SID, 3}
	check(core.compat.calls[{.Iop_Call, core.compat_name("sifcmd"), 21}].n == 1 && core.compat.calls[lost].n == 1, "rpc: a call that stops R leaves an Iop_Call row and an Iop_Rpc one")
	check(len(iop.sif.replies) == 0 && s.n_servers == 1 && s.n_queues == 1 && s.servers[0].sd == bp + psd, "rpc: no RPC_END, R's server dropped, modp's left")
	call(41, 3, 0, 0, 0, hsd)
	want = []u32{1, 8, 0, 8, 1, 0, 1, 8, 2, 4, 1, 4, 1, 4, 1, 4, 3, 0} // R logged fno 3 before it stopped
	check(log_equal(b, logp, want) && core.compat.calls[{.Sif_Rpc, RPC_SID, 3}].n == 0 && call_ends(hsd, 41), "rpc: the next call is modp's, RPC_END and no row")
}

// sceSifRemoveRpc and sceSifRemoveRpcQueue return as retail's list walk: the
// one removed when it was first, else the one before it, 0 when it is not
// there; the servers left keep their order, so the first registered still
// takes the calls; requests queued for what goes are lost with rows, the one
// a queue's thread runs is not. A failed load's removals come back where
// they were, the requests stay lost; one with no room to come back is a row.
test_rpc_remove :: proc() {
	fresh()
	s := &iop.iop_rpc
	call :: proc(fno: u32, args: ..u32) -> u32 {
		r := &r3000.state.r
		for v, i in args {r[4 + i] = v}
		v, ok := iop.sifcmd_fn(fno)
		check(ok, fmt.tprintf("rpc remove: sifcmd fno %d served", fno))
		return v
	}
	sds :: proc(want: ..u32) -> bool {
		s := &iop.iop_rpc
		if s.n_servers != len(want) {return false}
		for v, i in s.servers[:s.n_servers] {
			if v.sd != want[i] {return false}
		}
		return true
	}
	qds :: proc(want: ..u32) -> bool {
		s := &iop.iop_rpc
		if s.n_queues != len(want) {return false}
		for v, i in s.queues[:s.n_queues] {
			if v.qd != want[i] {return false}
		}
		return true
	}
	Q1, Q2, Q3 :: 0x1f0000, 0x1f0100, 0x1f0200
	A, B, C, D :: 0x1f1000, 0x1f1100, 0x1f1200, 0x1f1300
	SID :: 0x5500
	reset :: proc() {
		s := &iop.iop_rpc
		s^ = {}
		s.servers[0] = {SID, A, Q1}
		s.servers[1] = {SID, B, Q1}
		s.servers[2] = {SID + 2, C, Q2}
		s.servers[3] = {SID, D, Q1}
		s.n_servers = 4
		s.queues[0] = {qd = Q1}
		s.queues[1] = {qd = Q2}
		s.queues[2] = {qd = Q3}
		s.n_queues = 3
	}

	reset()
	s.reqs[0] = {sid = SID, sd = B, qd = Q1, fno = 7}
	s.reqs[1] = {sid = SID, sd = A, qd = Q1, fno = 8}
	s.n_reqs = 2
	check(call(24, B, Q1) == A && sds(A, C, D), "rpc remove: a server after the first returns the one before it")
	check(core.compat.calls[{.Iop_Rpc, SID, 7}].n == 1 && s.n_reqs == 1 && s.reqs[0].sd == A, "rpc remove: its queued request is lost with a row, the other's kept")
	check(call(24, D, Q1) == A && sds(A, C), "rpc remove: one after a server on another queue returns the one before it on its own")
	check(call(24, C, Q1) == 0 && sds(A, C), "rpc remove: a server on another queue is not removed, 0")
	check(call(24, A, Q1) == A && sds(C) && s.n_reqs == 0, "rpc remove: the first returns itself")
	check(call(24, A, Q1) == 0 && sds(C), "rpc remove: one not there is 0, nothing done")
	check(core.compat.calls[{.Iop_Rpc, SID, 8}].n == 1, "rpc remove: the first's queued request is lost with a row")

	reset()
	check(call(24, B, Q1) == A && sds(A, C, D), "rpc remove: the first registered for the id is still first, the rest in order")

	reset()
	s.queues[1].busy, s.queues[1].cur = true, {sid = SID + 2, sd = C, qd = Q2, fno = 9}
	s.reqs[0] = {sid = SID + 2, sd = C, qd = Q2, fno = 10}
	s.n_reqs = 1
	check(call(25, Q2) == Q1 && qds(Q1, Q3) && sds(A, B, D), "rpc remove: a queue after the first returns the one before it, its server goes")
	check(core.compat.calls[{.Iop_Rpc, SID + 2, 10}].n == 1 && s.n_reqs == 0, "rpc remove: a request queued on it is lost with a row")
	check(core.compat.calls[{.Iop_Rpc, SID + 2, 9}].n == 0, "rpc remove: the one its thread runs is not lost")
	check(call(25, Q3) == Q1 && qds(Q1), "rpc remove: the last returns the one before it")
	check(call(25, Q1) == Q1 && s.n_queues == 0 && s.n_servers == 0, "rpc remove: the first returns itself, its servers go")
	check(call(25, Q1) == 0, "rpc remove: a queue not there is 0")

	// "modx" removes B and queue Q2, then its load fails: both come back,
	// where they were, with C; B's queued request stays lost.
	reset()
	for &q in s.queues[:s.n_queues] {
		q.thread = iop.iop_sched.next_thid
		append(&iop.iop_sched.threads, iop.Iop_Thread{id = q.thread})
		iop.iop_sched.next_thid += 1
	}
	s.reqs[0] = {sid = SID, sd = B, qd = Q1, fno = 11}
	s.n_reqs = 1
	x: Asm
	xsc := imports(&x, "sifcmd", 24, 25)
	xsm := imports(&x, "sysmem", 99)
	xentry := at(&x)
	prologue(&x)
	li32(&x, A0, B)
	li32(&x, A1, Q1)
	jal(&x, xsc)
	li32(&x, A0, Q2)
	jal(&x, xsc + 8)
	jal(&x, xsm)
	li(&x, V0, 0)
	epilogue(&x)
	saved := s^
	idx, _ := iop.iop_load(build_mod("modx", &x, xentry), "modx", nil)
	check(idx <= 0 && sds(A, B, C, D) && qds(Q1, Q2, Q3), "rpc remove: a failed load's removals come back where they were")
	check(s.servers == saved.servers && s.queues == saved.queues, "rpc remove: as they were")
	check(core.compat.calls[{.Iop_Rpc, SID, 11}].n == 1 && s.n_reqs == 0, "rpc remove: the request the removal lost stays lost, its row kept")

	// A load removed B and registered two servers in memory that stays, the
	// table full: B comes back where it was, the first new one after the
	// servers there before, the second has no room and is a row.
	reset()
	for &q, i in s.queues[:s.n_queues] {q.thread = saved.queues[i].thread}
	for i in 4 ..< 31 {s.servers[i] = {SID + 0x100 + u32(i), 0x1f2000 + 0x10 * u32(i), Q1}}
	s.n_servers = 31
	saved = s^
	call(24, B, Q1)
	s.servers[30] = {SID + 0x200, 0x1f4000, Q1}
	s.servers[31] = {SID + 0x201, 0x1f4100, Q1}
	s.n_servers = iop.IOP_RPC_SERVERS
	iop.rpc_undo(saved, nil)
	same := s.n_servers == iop.IOP_RPC_SERVERS
	for i in 0 ..< 31 {same &&= s.servers[i] == saved.servers[i]}
	check(same && s.servers[31].sid == SID + 0x200, "rpc remove: the server put back takes its place, the first new one follows")
	check(core.compat.calls[{.Iop_Rpc, SID + 0x201, max(u32)}].n == 1, "rpc remove: the one with no room is a row")

	// A load removed Q2 and set queue QN, with a server and a request queued
	// for it, the queues full: Q2 comes back, QN has no room and is a row, its
	// server goes with it, a row too, and its request is lost.
	QN :: 0x1f0f00
	reset()
	for i in 3 ..< iop.IOP_RPC_QUEUES {s.queues[i] = {qd = Q1 + 0x100 * u32(i)}}
	s.n_queues = iop.IOP_RPC_QUEUES
	for &q in s.queues[:s.n_queues] {
		q.thread = iop.iop_sched.next_thid
		append(&iop.iop_sched.threads, iop.Iop_Thread{id = q.thread})
		iop.iop_sched.next_thid += 1
	}
	saved = s^
	call(25, Q2)
	s.queues[iop.IOP_RPC_QUEUES - 1] = {qd = QN, thread = saved.queues[0].thread}
	s.n_queues = iop.IOP_RPC_QUEUES
	s.servers[s.n_servers] = {SID + 0x300, 0x1f5000, QN}
	s.n_servers += 1
	s.reqs[0] = {sid = SID + 0x300, sd = 0x1f5000, qd = QN, fno = 12}
	s.n_reqs = 1
	iop.rpc_undo(saved, nil)
	check(s.queues == saved.queues && s.n_queues == iop.IOP_RPC_QUEUES && sds(A, B, C, D), "rpc remove: the queue put back takes its place, the new one and its server go")
	check(core.compat.calls[{.Iop_Rpc, QN, max(u32)}].n == 1, "rpc remove: the queue with no room is a row")
	check(core.compat.calls[{.Iop_Rpc, SID + 0x300, max(u32)}].n == 1, "rpc remove: its server is a row")
	check(core.compat.calls[{.Iop_Rpc, SID + 0x300, 12}].n == 1 && s.n_reqs == 0, "rpc remove: the request queued for it is lost with a row")
}

RPC_SID3 :: 0x4323

// A served function that removes its own queue: its call ends with RPC_END,
// and the next call to the id is the HLE's.
test_rpc_self_remove :: proc() {
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	drop_replies()
	defer drop_replies()
	cpu.state.cycles = 0
	cpu.next_event = 1 << 40
	// "modv": thread V serves RPC_SID3 with func, which removes V's queue
	// and returns 0.
	a: Asm
	tb := imports(&a, "thbase", 4, 6, 20)
	sc := imports(&a, "sifcmd", 14, 17, 19, 22, 25)
	th := at(&a)
	put(&a, 0)
	sd := at(&a)
	for _ in 0 ..< 18 {put(&a, 0)}
	qd := at(&a)
	for _ in 0 ..< 8 {put(&a, 0)}
	fn := at(&a)
	prologue(&a)
	la(&a, A0, qd)
	jal(&a, sc + 32)
	li(&a, V0, 0)
	epilogue(&a)
	ev := rpc_thread(&a, tb + 16, sc, RPC_SID3, {sd, fn, sd, qd}, false)
	tp := thread_param(&a, ev, 10)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, tb, tp, th)
	call_word(&a, tb + 8, th)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modv", &a, entry), "modv", nil)
	b := module_base(id)
	s := &iop.iop_rpc
	check(id > 0 && s.n_servers == 1 && s.servers[0] == {RPC_SID3, b + sd, b + qd} && s.n_queues == 1, "rpc self remove: V registers its server")
	send_pkt(iop.SIF_CMD_RPC_BIND, 1, 0, 0, 0, RPC_SID3)
	hsd := reply_word(0, 9)
	drop_replies()

	send_pkt(iop.SIF_CMD_RPC_CALL, 2, 0, 0, 0, 1, 0, 0, 0, 0, hsd)
	check(call_ends(hsd, 2) && s.n_queues == 0 && s.n_servers == 0, "rpc self remove: the call ends with RPC_END, the queue and server gone")
	check(core.compat.calls[{.Iop_Rpc, RPC_SID3, 1}].n == 0, "rpc self remove: the call is not lost")
	drop_replies()
	send_pkt(iop.SIF_CMD_RPC_CALL, 3, 0, 0, 0, 4, 0, 0, 0, 0, hsd)
	check(core.compat.calls[{.Sif_Rpc, RPC_SID3, 4}].n == 1 && call_ends(hsd, 3), "rpc self remove: the next call is the HLE's, a row and RPC_END")
	drop_replies()
	// Bound while served, the server gone: a bind again answers server 0,
	// the sid keeping its descriptor for when a module serves it again.
	send_pkt(iop.SIF_CMD_RPC_BIND, 4, 0, 0, 0, RPC_SID3)
	check(len(iop.sif.replies) == 1 && reply_word(0, 9) == 0 && iop.sif.bound[RPC_SID3] == hsd, "rpc self remove: a bind after the server went answers server 0")
}

// A module's RPC client, the EE faked. Conditions: a blocking bind or call
// waits for its RPC_END, and no WakeupThread ends that; the send bytes are in
// the EE's buffer by the time its packet is; the reply bytes reach recv before
// RPC_END, so the waiter and the end function read them; two clients in flight
// end in either order, each with its own end function's argument; an end
// function that waits is stopped, with a row, and the waiter still wakes; a
// NOWAIT call with no end function asks no RPC_END and the EE's DMA frees its
// packet; the 33rd packet out returns -1; an unbound client or a pointer past
// RAM is refused with a row; a bind no server answers returns 0 with a row; a
// stray RPC_END and one for a client a failed load freed are rows; without
// PS_IRX RPC_END is left to sif_command's row, the client untouched.
test_rpc_client :: proc() {
	fresh()
	clear(&core.compat.calls)
	iop.iop_irx = true
	defer iop.iop_irx = false
	drop_replies()
	defer drop_replies()
	cpu.state.cycles = 0
	cpu.next_event = 1 << 40
	EE_SRV :: 0x00100800
	EE_DATA :: 0x00100c00
	SID :: 0x200

	a: Asm
	tb := imports(&a, "thbase", 4, 6, 24)
	sc := imports(&a, "sifcmd", 15, 16)
	ub := imports(&a, "usbd", 6)
	logp := log_words(&a, 32)
	cl := [5]u32{}
	for &c in cl {
		c = at(&a)
		for _ in 0 ..< 10 {put(&a, 0)}
	}
	send := at(&a)
	put(&a, 0x5a5a1234)
	recv := at(&a)
	put(&a, 0, 0, 0)
	stack := at(&a)
	for _ in 0 ..< 12 {put(&a, 0)}
	thid := at(&a)
	put(&a, 0)
	log_reg :: proc(a: ^Asm, logp, rs: u32) {
		la(a, T0, logp)
		put(a, 0x8d090000, 0, 0xad200000 | rs << 16, 0x25290004, 0xad090000) // lw t1, 0(t0); nop; sw rs, 0(t1); addiu t1, t1, 4; sw t1, 0(t0)
	}
	// Logs its argument, then the word of recv it was told to read.
	end := at(&a)
	prologue(&a)
	log_reg(&a, logp, A0)
	la(&a, T0, recv)
	put(&a, 0x00882021, 0x8c840000, 0) // addu a0, a0, t0; lw a0, 0(a0); nop
	log_reg(&a, logp, A0)
	epilogue(&a)
	// An end function that sleeps.
	bad := at(&a)
	prologue(&a)
	jal(&a, tb + 16)
	put(&a, 0)
	epilogue(&a)
	// An end function that logs nothing, for the pool's 32: the log holds 32 words.
	idle := at(&a)
	put(&a, JR_RA, 0)
	// An end function that reaches a gap.
	gap := at(&a)
	prologue(&a)
	jal(&a, ub)
	put(&a, 0)
	epilogue(&a)
	call :: proc(a: ^Asm, sc, client, fno, mode, send, recv, end, param: u32) {
		la(a, A0, client)
		li(a, A1, fno)
		li(a, A2, mode)
		la(a, A3, send)
		li(a, T0, 4)
		put(a, 0xafa80010, 0xafa80018) // sw t0, 16(sp); sw t0, 24(sp)
		la(a, T0, recv)
		put(a, 0xafa80014) // sw t0, 20(sp)
		if end != 0 {la(a, T0, end)} else {li(a, T0, 0)}
		put(a, 0xafa8001c) // sw t0, 28(sp)
		li(a, T0, param)
		put(a, 0xafa80020) // sw t0, 32(sp)
		jal(a, sc + 8)
		put(a, 0)
	}
	th := at(&a)
	put(&a, 0x27bdffd0, 0xafbf0028) // addiu sp, sp, -48; sw ra, 40(sp)
	la(&a, A0, cl[0])
	li(&a, A1, SID)
	li(&a, A2, 0)
	jal(&a, sc)
	put(&a, 0)
	log_v(&a, logp, 1)
	call(&a, sc, cl[0], 1, 0, send, recv, 0, 0)
	lw_at(&a, A0, recv)
	log_reg(&a, logp, A0)
	// Two clients in flight, reply words recv + 4 and recv + 8.
	call(&a, sc, cl[0], 2, iop.RPC_NOWAIT, send, recv + 4, end, 4)
	call(&a, sc, cl[1], 3, iop.RPC_NOWAIT, send, recv + 8, end, 8)
	log_v(&a, logp, 9)
	put(&a, 0x8fbf0028, JR_RA, 0x27bd0030) // lw ra, 40(sp); jr ra; addiu sp, sp, 48
	tp := thread_param(&a, th, 10)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, tb, tp, thid)
	call_word(&a, tb + 8, thid)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modr", &a, entry), "modr", nil)
	check(id > 0, "rpc client: modr loads")
	b := module_base(id)

	// The EE's RPC_END with `n` reply bytes ahead of it in one DMA list.
	ee_end :: proc(client, cid, server, buff, data, dest, n: u32) {
		e: u32 = 0
		if n != 0 {
			mem.wr32(EE_DATA, data)
			for w, i in ([4]u32{EE_DATA, dest, n, 0}) {mem.wr32(EE_LIST + 4 * u32(i), w)}
			e = 16
		}
		for w, i in ([4]u32{64, 0, iop.SIF_CMD_RPC_END, 0}) {mem.wr32(EE_PKT + 4 * u32(i), w)}
		for w, i in ([8]u32{0, EE_PKT, 0, client, cid, server, buff, 0xcb0f}) {mem.wr32(EE_PKT + 16 + 4 * u32(i), w)}
		for w, i in ([4]u32{EE_PKT, iop.IOP_CMDBUF, 64, 0}) {mem.wr32(EE_LIST + e + 4 * u32(i), w)}
		iop.sif_set_dma(EE_LIST, 1 if n == 0 else 2, 0)
	}
	word :: proc(b, o: u32) -> u32 {return iop.iop_u32(b + o)^}
	c0, c1 := b + cl[0], b + cl[1]
	t := iop.th_find(iop.iop_sched.next_thid - 1)

	// The bind waits, and WakeupThread does not end that.
	check(len(iop.sif.replies) == 1 && reply_word(0, 2) == iop.SIF_CMD_RPC_BIND && reply_word(0, 7) == c0 && reply_word(0, 8) == SID, "rpc client: the bind's packet goes to the EE")
	check(reply_word(0, 4) & 6 == 6 && reply_word(0, 5) == word(c0, 0) && reply_word(0, 6) != 0 && word(c0, 4) == reply_word(0, 5) + 0x18, "rpc client: its rec_id, address and rpc_id are as retail's")
	check(t != nil && t.status == .Wait && word(b, logp + 4) == 0, "rpc client: the bind waits")
	iop.th_wakeup(t.id)
	check(t.status == .Wait, "rpc client: WakeupThread does not end the wait")
	drop_replies()
	iop.iop_u32(c1 + iop.CL_SERVER)^ = 0x8000
	iop.iop_u32(c1 + iop.CL_BUFF)^ = EE_SRV + 0x40

	// RPC_END of the bind: the server, then the call goes out, its bytes first.
	ee_end(c0, iop.SIF_CMD_RPC_BIND, 0x7000, EE_SRV, 0, 0, 0)
	check(word(c0, iop.CL_SERVER) == 0x7000 && word(c0, iop.CL_BUFF) == EE_SRV && word(c0, iop.CL_CBUF) == 0xcb0f, "rpc client: RPC_END of the bind writes server and buffer")
	check(word(b, logp + 4) == 1, "rpc client: the bind's waiter wakes")
	check(len(iop.sif.replies) == 1 && reply_word(0, 2) == iop.SIF_CMD_RPC_CALL && reply_word(0, 8) == 1 && reply_word(0, 9) == 4 && reply_word(0, 10) == b + recv && reply_word(0, 11) == 4 && reply_word(0, 12) == 1 && reply_word(0, 13) == 0x7000, "rpc client: the call's packet as retail's")
	check(reply_word(0, 1) == EE_SRV && mem.rd32(EE_SRV) == 0x5a5a1234 && word(b, logp + 8) == 0, "rpc client: the send bytes are in the buffer, the call waits")
	drop_replies()

	// RPC_END of the call, the reply bytes ahead of it; two calls then in flight.
	ee_end(c0, iop.SIF_CMD_RPC_CALL, 0, 0, 0xfeed, b + recv, 4)
	check(word(b, logp + 8) == 0xfeed, "rpc client: the waiter reads the reply")
	check(word(b, logp + 12) == 9 && len(iop.sif.replies) == 2 && reply_word(0, 12) == 1 && reply_word(1, 7) == c1 && mem.rd32(EE_SRV + 0x40) == 0x5a5a1234, "rpc client: two NOWAIT calls with end functions go out, each to its buffer")
	drop_replies()
	ee_end(c1, iop.SIF_CMD_RPC_CALL, 0, 0, 0xb1, b + recv + 8, 4)
	check(word(b, logp + 16) == 8 && word(b, logp + 20) == 0xb1, "rpc client: the second client's RPC_END first: its end function reads its reply")
	ee_end(c0, iop.SIF_CMD_RPC_CALL, 0, 0, 0xa1, b + recv + 4, 4)
	check(word(b, logp + 24) == 4 && word(b, logp + 28) == 0xa1, "rpc client: then the first's")
	check(word(c0, iop.CL_PKT) == 0 && word(c1, iop.CL_PKT) == 0 && len(core.compat.calls) == 0, "rpc client: the packets are freed, no row")

	// From the loader, which cannot wait.
	stk := b + stack
	r := &r3000.state.r
	saved_sp := r[29]
	defer r[29] = saved_sp
	fn_call :: proc(stk, client, fno, mode, s, ssize, recv, rsize, end, param: u32) -> u32 {
		r := &r3000.state.r
		r[29] = stk
		r[4], r[5], r[6], r[7] = client, fno, mode, s
		for v, i in ([5]u32{ssize, recv, rsize, end, param}) {iop.iop_u32(stk + 16 + 4 * u32(i))^ = v}
		v, ok := iop.sifcmd_fn(16)
		check(ok, "rpc client: sceSifCallRpc served")
		return v
	}
	c2, c3 := b + cl[2], b + cl[3]
	row :: proc(id, sub: u32) -> u64 {return core.compat.calls[core.Compat_Key{.Iop_Rpc, id, sub}].n}

	// Refused: unbound; send, recv or buffer past RAM; a bad client.
	check(fn_call(stk, c2, 7, 1, b + send, 4, b + recv, 4, 0, 0) == 0xfffffffe && row(c2, 7) == 1 && len(iop.sif.replies) == 0, "rpc client: an unbound client is refused, a row")
	iop.iop_u32(c2 + iop.CL_SERVER)^ = 0x7100
	iop.iop_u32(c2 + iop.CL_BUFF)^ = EE_SRV
	check(fn_call(stk, c2, 8, 1, 0x3ffffc, 8, b + recv, 4, 0, 0) == 0xfffffffe && row(c2, 8) == 1, "rpc client: send past IOP RAM is refused")
	check(fn_call(stk, c2, 9, 1, b + send, 4, 0x3ffffc, 8, 0, 0) == 0xfffffffe && row(c2, 9) == 1, "rpc client: recv past IOP RAM is refused")
	iop.iop_u32(c2 + iop.CL_BUFF)^ = 0x70000000
	check(fn_call(stk, c2, 10, 1, b + send, 4, b + recv, 4, 0, 0) == 0xfffffffe && row(c2, 10) == 1, "rpc client: a buffer outside EE RAM is refused")
	iop.iop_u32(c2 + iop.CL_BUFF)^ = EE_SRV
	check(fn_call(stk, c2 + 1, 11, 1, b + send, 4, b + recv, 4, 0, 0) == 0xfffffffe && row(c2 + 1, 11) == 1, "rpc client: a misaligned client is refused")
	check(fn_call(stk, c2, 12, 1, b + send, 4, b + recv, 4, 0x7ffffff0, 0) == 0xfffffffe && row(c2, 12) == 1 && len(iop.sif.replies) == 0, "rpc client: an end function outside IOP RAM is refused")
	check(len(iop.sif.replies) == 0, "rpc client: nothing refused was sent")

	// NOWAIT with no end function: no RPC_END asked; the EE's DMA frees it.
	check(fn_call(stk, c2, 3, 1, b + send, 4, b + recv, 4, 0, 0) == 0 && reply_word(0, 12) == 0, "rpc client: NOWAIT with no end function asks no RPC_END")
	pkt := word(c2, iop.CL_PKT)
	drop_replies()
	for i in u32(0) ..< 16 {mem.wr32(EE_PKT + 4 * i, 0)}
	for w, i in ([4]u32{EE_PKT, pkt, 64, 0}) {mem.wr32(EE_LIST + 4 * u32(i), w)}
	iop.sif_set_dma(EE_LIST, 1, 0)
	check(fn_call(stk, c2, 4, 1, b + send, 4, b + recv, 4, end + b, 0) == 0 && word(c2, iop.CL_PKT) == pkt, "rpc client: the EE's DMA freed the packet")
	drop_replies()
	ee_end(c2, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)

	// The pool: 32 out, the 33rd refused; an END frees one.
	for _ in 0 ..< iop.RPC_PKTS {
		check(fn_call(stk, c2, 5, 1, b + send, 4, b + recv, 4, b + idle, 0) == 0, "rpc client: 32 packets out")
	}
	check(fn_call(stk, c2, 5, 1, b + send, 4, b + recv, 4, b + idle, 0) == 0xffffffff, "rpc client: the 33rd returns -1")
	iop.iop_u32(c3 + iop.CL_SERVER)^ = 0x7200
	r[4], r[5], r[6] = c3, 0x124, 1
	bv, bok := iop.sifcmd_fn(15)
	check(bok && bv == 0xffffffff && word(c3, iop.CL_SERVER) == 0x7200, "rpc client: a bind with no free packet leaves the client as it was")
	drop_replies()
	for _ in 0 ..< iop.RPC_PKTS {ee_end(c2, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)}
	check(word(c2, iop.CL_PKT) == 0, "rpc client: each END frees one")
	for _ in 0 ..< iop.RPC_PKTS {
		check(fn_call(stk, c2, 5, 1, b + send, 4, b + recv, 4, b + idle, 0) == 0, "rpc client: all 32 are free again")
	}
	check(fn_call(stk, c2, 5, 1, b + send, 4, b + recv, 4, b + idle, 0) == 0xffffffff, "rpc client: and the 33rd is still refused")
	drop_replies()
	for _ in 0 ..< iop.RPC_PKTS {ee_end(c2, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)}
	check(fn_call(stk, c2, 5, 1, b + send, 4, b + recv, 4, 0, 0) == 0, "rpc client: NOWAIT again")
	drop_replies()
	for w, i in ([4]u32{EE_PKT, word(c2, iop.CL_PKT), 64, 0}) {mem.wr32(EE_LIST + 4 * u32(i), w)}
	iop.sif_set_dma(EE_LIST, 1, 0)

	// A bind no server answers: 0, a row, the client left unbound.
	r[4], r[5], r[6] = c3, 0x123, 1
	v, ok := iop.sifcmd_fn(15)
	check(ok && v == 0 && reply_word(0, 8) == 0x123 && reply_word(0, 12) == 1, "rpc client: NOWAIT bind sent, asking its RPC_END in a slot a NOWAIT call used")
	drop_replies()
	ee_end(c3, iop.SIF_CMD_RPC_BIND, 0, 0, 0, 0, 0)
	check(word(c3, iop.CL_SERVER) == 0 && row(0x123, iop.RPC_NO_SERVER) == 1, "rpc client: a bind to no server is 0, with a row")

	// An end function that sleeps gets -100, as in any handler, and returns:
	// no row, the packet freed.
	iop.iop_u32(c3 + iop.CL_SERVER)^ = 0x7200
	iop.iop_u32(c3 + iop.CL_BUFF)^ = EE_SRV
	check(fn_call(stk, c3, 6, 1, b + send, 4, b + recv, 4, b + bad, 0) == 0, "rpc client: a call with a bad end function")
	drop_replies()
	ee_end(c3, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)
	blocked := core.compat.calls[core.Compat_Key{.Iop_Intr, iop.SIF_CMD_RPC_CALL, 0}].n
	check(blocked == 0 && word(c3, iop.CL_PKT) == 0, "rpc client: an end function that sleeps is no row, the packet freed")
	check(fn_call(stk, c3, 6, 1, b + send, 4, b + recv, 4, b + gap, 0) == 0, "rpc client: a call with an end function at a gap")
	drop_replies()
	ee_end(c3, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)
	blocked = core.compat.calls[core.Compat_Key{.Iop_Intr, iop.SIF_CMD_RPC_CALL, 0}].n
	check(blocked == 1 && word(c3, iop.CL_PKT) == 0, "rpc client: an end function at a gap is a row, the packet freed")

	// A waited call with no thread: sent, with a row, and nothing waits.
	check(fn_call(stk, c3, 13, 0, b + send, 4, b + recv, 4, 0, 0) == 0 && row(c3, iop.RPC_NO_THREAD) == 1 && len(iop.sif.replies) == 1, "rpc client: a waited call from the loader is a row")
	drop_replies()
	ee_end(c3, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)

	// Two packets on one client: each END frees one, the client's packet the
	// one left.
	lg := word(b, logp)
	check(fn_call(stk, c3, 6, 1, b + send, 4, b + recv, 4, b + end, 0) == 0 && fn_call(stk, c3, 6, 1, b + send, 4, b + recv, 4, b + end, 0) == 0, "rpc client: two calls on one client")
	drop_replies()
	ee_end(c3, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)
	check(word(c3, iop.CL_PKT) != 0 && word(word(c3, iop.CL_PKT), iop.PK_REC_ID) & iop.PK_IN_USE != 0 && word(c3, iop.CL_RPC_ID) == word(c3, iop.CL_PKT) + iop.PK_RPC_ID, "rpc client: after the first END the client names the packet still out")
	ee_end(c3, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)
	check(word(c3, iop.CL_PKT) == 0 && word(b, logp) == lg + 16, "rpc client: the second END ends it, each ran the end function")

	// A packet no END answers is not taken for one that is.
	check(fn_call(stk, c3, 6, 1, b + send, 4, b + recv, 4, 0, 0) == 0, "rpc client: a call that asks no END")
	quiet := word(c3, iop.CL_PKT)
	check(fn_call(stk, c3, 6, 1, b + send, 4, b + recv, 4, b + end, 0) == 0, "rpc client: and one that does")
	drop_replies()
	ee_end(c3, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)
	check(word(quiet, iop.PK_REC_ID) & iop.PK_IN_USE != 0, "rpc client: END leaves the packet that asked none")
	for i in u32(0) ..< 16 {mem.wr32(EE_PKT + 4 * i, 0)}
	for w, i in ([4]u32{EE_PKT, quiet, 64, 0}) {mem.wr32(EE_LIST + 4 * u32(i), w)}
	iop.sif_set_dma(EE_LIST, 1, 0)

	// A stray RPC_END; one whose client a failed load freed.
	before := len(iop.sif.replies)
	ee_end(0x1234, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)
	check(row(0x1234, iop.SIF_CMD_RPC_CALL) == 1 && len(iop.sif.replies) == before, "rpc client: a stray RPC_END is a row")
	check(fn_call(stk, c3, 6, 1, b + send, 4, b + recv, 4, b + end, 0) == 0, "rpc client: a call out when the load fails")
	drop_replies()
	log_at := word(b, logp)
	orphan := word(c3, iop.CL_PKT)
	waiter := iop.th_new(0x1000, 0x2000, 0x100, 0, 10)
	waiter.status = .Wait
	iop.iop_u32(c3 + iop.CL_WAITER)^ = waiter.id
	iop.rpc_client_freed({{addr = c3, size = 0x28}})
	check(waiter.status != .Wait, "rpc client: freeing a client wakes its waiter")
	waiter.status = .Dormant
	check(word(orphan, iop.PK_REC_ID) & iop.PK_IN_USE != 0 && word(orphan, iop.PK_CLIENT) == c3 | 1, "rpc client: the packet stays reserved, an orphan")
	// The memory reused for a client whose call follows: the EE answers the older first.
	check(fn_call(stk, c3, 6, 1, b + send, 4, b + recv, 4, b + end, 0) == 0, "rpc client: a client at the same address")
	drop_replies()
	ee_end(c3, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)
	check(row(c3, iop.SIF_CMD_RPC_CALL) == 1 && word(b, logp) == log_at && word(orphan, iop.PK_REC_ID) & iop.PK_IN_USE == 0, "rpc client: RPC_END for a freed client is a row, the packet freed, its end function not run")
	ee_end(c3, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)
	check(word(b, logp) == log_at + 8 && word(c3, iop.CL_PKT) == 0, "rpc client: the new client's RPC_END is its own")

	// An end function freed from under a client that lives on.
	log_at = word(b, logp)
	check(fn_call(stk, c3, 6, 1, b + send, 4, b + recv, 4, b + end, 0) == 0, "rpc client: a call with an end function")
	drop_replies()
	iop.rpc_client_freed({{addr = b + end, size = 4}})
	ee_end(c3, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)
	check(word(c3, iop.CL_END) == 0 && word(b, logp) == log_at && word(c3, iop.CL_PKT) == 0 && row(c3, iop.SIF_CMD_RPC_CALL) == 1, "rpc client: its RPC_END runs none and frees the packet")

	// A module that stays no more, its block freed as any: the client in it.
	cx := iop.sys_alloc(.Low, 0x40)
	for i in u32(0) ..< 16 {iop.iop_u32(cx + 4 * i)^ = 0}
	iop.iop_u32(cx + iop.CL_SERVER)^ = 0x7200
	iop.iop_u32(cx + iop.CL_BUFF)^ = EE_SRV
	check(fn_call(stk, cx, 6, 1, b + send, 4, b + recv, 4, b + end, 0) == 0, "rpc client: a call on a client in a block")
	drop_replies()
	check(iop.sys_free(cx), "rpc client: the block frees")
	ee_end(cx, iop.SIF_CMD_RPC_CALL, 0, 0, 0, 0, 0)
	check(row(cx, iop.SIF_CMD_RPC_CALL) == 1 && word(b, logp) == log_at, "rpc client: sys_free orphans what the block held")

	// Without PS_IRX, as before: the client untouched, its packet still out, a row.
	c4 := b + cl[4]
	iop.iop_u32(c4 + iop.CL_SERVER)^ = 0x7400
	iop.iop_u32(c4 + iop.CL_BUFF)^ = EE_SRV
	check(fn_call(stk, c4, 6, 1, b + send, 4, b + recv, 4, b + end, 0) == 0, "rpc client: a packet out when PS_IRX goes off")
	drop_replies()
	out := word(c4, iop.CL_PKT)
	log_at = word(b, logp)
	rows := len(core.compat.calls)
	iop.iop_irx = false
	ee_end(c4, iop.SIF_CMD_RPC_BIND, 0x7300, EE_SRV, 0, 0, 0)
	check(word(c4, iop.CL_SERVER) == 0x7400 && word(c4, iop.CL_PKT) == out && word(out, iop.PK_REC_ID) & iop.PK_IN_USE != 0 && word(b, logp) == log_at && len(core.compat.calls) > rows, "rpc client: without PS_IRX RPC_END writes nothing and is a row")
}

// A load that fails after its start allocated the pool: the pool stays, so what
// the EE owes finds it, and the client that was in the module is an orphan.
test_rpc_pool_kept :: proc() {
	fresh()
	clear(&core.compat.calls)
	iop.iop_irx = true
	defer iop.iop_irx = false
	drop_replies()
	defer drop_replies()
	iop.iop_sifcmd.rpc_pool = 0
	a: Asm
	sc := imports(&a, "sifcmd", 15)
	ub := imports(&a, "usbd", 6)
	client := at(&a)
	for _ in 0 ..< 10 {put(&a, 0)}
	entry := at(&a)
	prologue(&a)
	la(&a, A0, client)
	li(&a, A1, 0x200)
	li(&a, A2, iop.RPC_NOWAIT)
	jal(&a, sc)
	put(&a, 0)
	jal(&a, ub)
	put(&a, 0)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modp", &a, entry), "modp", nil)
	check(id <= 0, "rpc pool: the load fails")
	pool := iop.iop_sifcmd.rpc_pool
	check(pool != 0 && iop.sys_in(iop.sys_blocks[:], pool), "rpc pool: the pool is kept, its block still held")
	check(iop.iop_u32(pool + iop.PK_REC_ID)^ & iop.PK_IN_USE != 0 && iop.iop_u32(pool + iop.PK_CLIENT)^ & 1 == 1, "rpc pool: the failed module's packet is an orphan")
	check(iop.sys_alloc(.Addr, 0x100, pool) == 0, "rpc pool: nothing else can have its memory")
}


// A USB class driver's start registers its LDD and loads; the rest of usbd
// needs a device, so a start reaching it does not.
test_usbd :: proc() {
	start_calls :: proc(name: string, fno: u32) -> int {
		fresh()
		a: Asm
		f := imports(&a, "usbd", fno)
		entry := at(&a)
		prologue(&a)
		jal(&a, f)
		put(&a, 0)
		li(&a, V0, 0)
		epilogue(&a)
		id, _ := iop.iop_load(build_mod(name, &a, entry), name, nil)
		return int(id)
	}
	check(start_calls("usb4", 4) > 0, "usbd: a start that calls sceUsbdRegisterLdd loads")
	check(start_calls("usb5", 5) > 0, "usbd: a start that calls sceUsbdUnregisterLdd loads")
	check(start_calls("usb6", 6) <= 0, "usbd: a start that calls usbd 6 still fails")
}

// The calls a boot can make before its first frame that the HLE served none
// of: secrman's card handlers and its card authentication, which no card
// answers; cdvdman's Stop, Pause, Break and ReadClock and the status they
// leave; ChangeThreadPriority and ReferThreadStatus by retail's rules and
// layout; sceSdGetCoreAttr giving back what Set left, and sceSdPitch2Note;
// memmove in both directions.
test_boot_gaps :: proc() {
	fresh()
	a: Asm
	sm := imports(&a, "secrman", 4, 5, 6)
	entry := at(&a)
	prologue(&a)
	jal(&a, sm)
	put(&a, 0)
	jal(&a, sm + 8)
	put(&a, 0)
	jal(&a, sm + 16) // its 0 the start's v0
	put(&a, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("mods", &a, entry), "mods", nil)
	check(id > 0, "boot: SecrSetMcCommandHandler, SecrSetMcDevIDHandler and SecrAuthCard each give 0")

	cd :: proc(fno: u32, a0: u32 = 0) -> u32 {
		r3000.state.r[4] = a0
		v, ok := iop.cdvdman_fn(fno)
		check(ok, "boot: a served cdvdman call")
		return v
	}
	P :: 0x00040000
	iop.iop_cd = {}
	check(cd(28) == iop.CD_STAT_PAUSE, "boot: the disc spins at first")
	check(cd(15) == 1 && cd(28) == iop.CD_STAT_STOP, "boot: sceCdStop stops it")
	check(iop.iop_cd.n_pending == 0, "boot: no callback without one set")
	iop.iop_cd.callback = 0x1000
	check(cd(38) == 1 && cd(28) == iop.CD_STAT_PAUSE, "boot: sceCdPause spins it up again")
	check(cd(15) == 1 && cd(5) == 1 && cd(28) == iop.CD_STAT_PAUSE, "boot: so does sceCdStandby")
	check(iop.iop_cd.n_pending == 3 && iop.iop_cd.pending[0] == iop.CD_FUNC_PAUSE && iop.iop_cd.pending[1] == iop.CD_FUNC_STOP, "boot: Pause and Stop owe their callbacks")
	check(cd(39) == 1 && iop.iop_cd.n_pending == 3, "boot: sceCdBreak, nothing to break")
	iop.iop_cd = {}
	cd(15)
	r3000.state.r[5], r3000.state.r[6], r3000.state.r[7] = 1, P, 0
	check(cd(6, 0) == 1 && cd(28) == iop.CD_STAT_PAUSE, "boot: a read spins a stopped disc up")
	iop.iop_cd = {}
	for i in u32(0) ..< 3 {iop.iop_u32(P + 4 * i)^ = 0xffffffff}
	check(cd(24, P) == 1 && iop.iop_u32(P)^ == 0 && iop.iop_u32(P + 4)^ == 0 && iop.iop_u32(P + 8)^ == 0xffffffff, "boot: sceCdReadClock, eight zero bytes")

	fresh()
	s := &iop.iop_sched
	base :: proc(fno, a0, a1: u32) -> u32 {
		r3000.state.r[4], r3000.state.r[5] = a0, a1
		v, ok := iop.th_base(fno)
		check(ok, "boot: a served thbase call")
		return v
	}
	t := iop.th_new(0x1000, 0x2000, 0x100, 0x80, 20)
	u := iop.th_new(0x1100, 0x2100, 0x200, 0x80, 30)
	tid, uid := t.id, u.id
	check(base(14, tid, 40) == neg(-iop.KE_DORMANT), "boot: a dormant thread's priority stays")
	check(base(14, tid + 100, 40) == neg(-iop.KE_UNKNOWN_THID), "boot: an unknown thread")
	check(base(14, tid + 100, 127) == neg(-iop.KE_UNKNOWN_THID) && base(14, tid, 127) == neg(-iop.KE_DORMANT), "boot: the thread is checked before the priority")
	check(base(14, 0, 40) == 0 && base(14, 0, 0) == 0, "boot: the loader's own is taken")
	check(base(14, 0, 127) == neg(-iop.KE_ILLEGAL_PRIORITY), "boot: but not past the lowest")
	check(base(6, tid, 0) == 0 && base(6, uid, 0) == 0, "boot: StartThread")
	t, u = iop.th_find(tid), iop.th_find(uid)
	check(base(14, uid, 127) == neg(-iop.KE_ILLEGAL_PRIORITY) && base(14, uid, 0) == 0 && u.prio == iop.IOP_START_PRIO, "boot: a priority past the lowest; 0 on the loader its IOP_START_PRIO")
	s.resched = false
	check(base(14, uid, 40) == 0 && u.prio == 40 && !s.resched, "boot: a ready thread's priority on the loader")
	s.cur = tid
	t.status = .Run
	check(base(14, uid, 0) == 0 && u.prio == 20 && !s.resched, "boot: priority 0 is the caller's, and an equal readies no switch")
	check(base(14, uid, 10) == 0 && u.prio == 10 && s.resched, "boot: a better one than the caller's is switched to")
	s.resched = false
	u.status, u.sema = .Wait, 7
	check(base(14, uid, 50) == 0 && u.prio == 50 && u.status == .Wait, "boot: a waiter keeps waiting")
	check(base(14, 0, 25) == 0 && t.prio == 25 && t.status == .Run, "boot: the caller keeps the CPU when no ready thread is as good")
	for w, i in ([4]u32{1, 0, 0, 1}) {iop.iop_u32(P + 4 * u32(i))^ = w} // SA_THPRI, a count of 0 to 1
	r3000.state.r[4] = P
	semid, sok := iop.th_semap(4)
	check(sok && i32(semid) > 0, "boot: CreateSema by priority")
	seq := u.seq
	u.sema = semid
	check(base(14, uid, 50) == 0 && u.seq > seq, "boot: a waiter by priority goes to the tail of its new equals")
	seq = u.seq
	u.sema = 7
	check(base(14, uid, 50) == 0 && u.seq == seq, "boot: a first-come waiter keeps its place")
	s.intr = true
	check(base(14, uid, 40) == neg(-iop.KE_ILLEGAL_CONTEXT) && u.prio == 50, "boot: ChangeThreadPriority in a handler is illegal")
	check(base(22, uid, P) == neg(-iop.KE_ILLEGAL_CONTEXT), "boot: so is ReferThreadStatus")
	s.intr = false

	info :: proc(i: u32) -> u32 {return iop.iop_u32(P + 4 * i)^}
	for i in u32(0) ..< 18 {iop.iop_u32(P + 4 * i)^ = 0xffffffff}
	u.attr, u.option, u.wakeups = 0x02000000, 9, 2
	check(base(22, uid, P) == 0, "boot: ReferThreadStatus")
	check(info(0) == 0x02000000 && info(1) == 9 && info(2) == 4 && info(3) == 0x1100 && info(4) == u.stack && info(5) == 0x200 && info(6) == 0x80, "boot: a thread's attributes by retail's layout")
	check(info(7) == 30 && info(8) == 50 && info(9) == 3 && info(10) == 7 && info(11) == 2 && info(12) == 0 && info(16) == 0 && info(17) == 0xffffffff, "boot: its priorities and semaphore wait, the rest 0")
	u.status = .Sleep
	base(22, uid, P)
	check(info(2) == 4 && info(9) == 1 && info(10) == 0, "boot: a sleeper")
	u.status, u.sema = .Evf, 3
	base(22, uid, P)
	check(info(2) == 4 && info(9) == 4 && info(10) == 3, "boot: an event flag's waiter")
	check(base(22, 0, P) == 0 && info(2) == 1 && info(8) == 25 && info(9) == 0, "boot: thid 0 the caller, running")
	check(base(22, tid + 100, P) == neg(-iop.KE_UNKNOWN_THID), "boot: an unknown thread's status")
	s.cur = 0
	check(base(22, 0, P) == 0 && info(2) == 1 && info(7) == iop.IOP_START_PRIO && info(3) == 0, "boot: the loader's")
	t.status = .Dormant
	check(base(6, tid, 0) == 0 && t.prio == 20, "boot: StartThread gives back the priority it was made with")

	C_EFFECT_ENABLE, C_IRQ_ENABLE, C_MUTE, C_NOISE_CLK, C_SPDIF :: u32(0x2), u32(0x4), u32(0x6), u32(0x8), u32(0xa) // libsd's core attributes
	sd :: proc(fno, a0: u32, a1: u32 = 0, a2: u32 = 0) -> u32 {
		r3000.state.r[4], r3000.state.r[5], r3000.state.r[6] = a0, a1, a2
		v, ok := iop.libsd_fn(fno)
		check(ok, "boot: a served libsd call")
		return v
	}
	sd(11, C_MUTE, 2)
	sd(11, C_MUTE | 1, 3)
	sd(11, C_NOISE_CLK, 0x7f)
	sd(11, C_NOISE_CLK | 1, 0)
	sd(11, C_IRQ_ENABLE, 0)
	sd(11, C_IRQ_ENABLE | 1, 1)
	sd(11, C_EFFECT_ENABLE | 1, 0)
	check(sd(12, C_MUTE | 1) == 1 && sd(12, C_MUTE) == 0, "boot: MUTE per core, its bit 0")
	check(sd(12, C_NOISE_CLK) == 0x3f && sd(12, C_NOISE_CLK | 1) == 0, "boot: NOISE_CLK's six bits")
	check(sd(12, C_IRQ_ENABLE | 1) == 1 && sd(12, C_IRQ_ENABLE) == 0, "boot: IRQ_ENABLE")
	sd(11, C_EFFECT_ENABLE, 1)
	check(sd(12, C_EFFECT_ENABLE) == 1 && sd(12, C_EFFECT_ENABLE | 1) == 0, "boot: EFFECT_ENABLE")
	sd(11, C_SPDIF, 0x102)
	sd(11, C_SPDIF, 0x5)
	check(sd(12, C_SPDIF) == 0x102, "boot: SPDIF keeps a known out mode only")
	sd(4, 0)
	check(sd(12, C_EFFECT_ENABLE) == 0 && sd(12, C_SPDIF) == 0x102, "boot: sceSdInit turns the effect off and keeps SPDIF")
	check(sd(14, 60, 0, 0) == 0xac00, "boot: sceSdPitch2Note of pitch 0, retail's center - 144 (-84) in the high byte")
	check(sd(14, 60, 0, 0x1000) == 60 << 8 && sd(14, 60, 0, 0x2000) == 72 << 8 && sd(14, 60, 0, 0x4000) == sd(14, 60, 0, 0x3fff), "boot: sceSdPitch2Note, pitch 0x1000 the center, its octave above, 0x3fff the most")
	p := sd(13, 60, 0, 67)
	n := sd(14, 60, 0, p)
	check(n >> 8 == 67 || n >> 8 == 66 && n & 0xff >= 0x7c, "boot: sceSdPitch2Note undoes sceSdNote2Pitch")

	iop.iop_u32(P)^, iop.iop_u32(P + 4)^ = 0x03020100, 0x07060504
	sys :: proc(a0, a1, a2: u32) -> u32 {
		r3000.state.r[4], r3000.state.r[5], r3000.state.r[6] = a0, a1, a2
		v, ok := iop.sysclib_fn(13)
		check(ok, "boot: a served sysclib call")
		return v
	}
	bytes :: proc() -> [8]u8 {return transmute([8]u8)[2]u32{iop.iop_u32(P)^, iop.iop_u32(P + 4)^}}
	check(sys(P + 2, P, 5) == P + 2 && bytes() == [8]u8{0, 1, 0, 1, 2, 3, 4, 7}, "boot: memmove up over itself")
	check(sys(P, P + 2, 5) == P && bytes() == [8]u8{0, 1, 2, 3, 4, 3, 4, 7}, "boot: memmove down over itself")
	check(sys(P, P + 4, 0xffffffff) == P && sys(0, P, 4) == 0 && bytes() == [8]u8{0, 1, 2, 3, 4, 3, 4, 7}, "boot: memmove copies none for n <= 0 or a null dst")
}

// A start that spins on a flag its libsd transfer handler sets, as a sound
// driver syncs a voice transfer: the handler runs between the start's
// slices, so the start returns.
test_start_intr :: proc() {
	fresh()
	a: Asm
	sd := imports(&a, "libsd", 17, 26)
	flag := at(&a)
	put(&a, 0)
	src := at(&a)
	put(&a, 0, 0, 0, 0, 0, 0, 0, 0)
	h := at(&a) // the handler: flag = 1, returns 0
	la(&a, T0, flag)
	li(&a, T2, 1)
	put(&a, 0xad000000 | T2 << 16, JR_RA, 0x24020000) // sw t2, 0(t0); jr ra; li v0, 0
	entry := at(&a)
	put(&a, 0x27bdffe0, 0xafbf001c) // addiu sp, sp, -32; sw ra, 28(sp)
	li(&a, A0, 0)
	la(&a, A1, h)
	li(&a, A2, 0)
	jal(&a, sd + 8) // sceSdSetTransIntrHandler(0, h, 0)
	li(&a, T2, 32)
	put(&a, 0xafa00010 | T2 << 16) // sw t2, 16(sp): the size
	li(&a, A0, 0)
	li(&a, A1, 0)
	la(&a, A2, src)
	li32(&a, 7, 0x5000)
	jal(&a, sd) // sceSdVoiceTrans(0, write, src, 0x5000, 32)
	spin := at(&a)
	lw_at(&a, T2, flag)
	put(&a, 0x11400000 | (spin - at(&a) - 4) / 4 & 0xffff, 0) // beqz t2, spin
	li(&a, V0, 0)
	put(&a, 0x8fbf001c, JR_RA, 0x27bd0020) // lw ra, 28(sp); jr ra; addiu sp, sp, 32
	id, _ := iop.iop_load(build_mod("modsp", &a, entry), "modsp", nil)
	check(id > 0, "start: a start spinning on its transfer handler's flag returns")
	check(id > 0 && iop.iop_u32(module_base(id) + flag)^ == 1, "start: the handler set the flag")
	test_start_block_cross()
}

// A start that spins on what its block transfer's handler sets at the first
// half-buffer crossing: the crossing comes due by the IOP's clock, the EE's
// standing still over the load, and its handler runs between slices.
test_start_block_cross :: proc() {
	fresh()
	a: Asm
	sd := imports(&a, "libsd", 18, 26)
	flag := at(&a)
	put(&a, 0)
	buf := at(&a)
	for _ in 0 ..< 0x100 {put(&a, 0)}
	h := at(&a) // the handler: flag = 1, returns 0
	la(&a, T0, flag)
	li(&a, T2, 1)
	put(&a, 0xad000000 | T2 << 16, JR_RA, 0x24020000) // sw t2, 0(t0); jr ra; li v0, 0
	entry := at(&a)
	put(&a, 0x27bdffe0, 0xafbf001c) // addiu sp, sp, -32; sw ra, 28(sp)
	li(&a, A0, 0)
	la(&a, A1, h)
	li(&a, A2, 0)
	jal(&a, sd + 8) // sceSdSetTransIntrHandler(0, h, 0)
	put(&a, 0xafa00010) // sw zero, 16(sp): the start address
	li(&a, A0, 0)
	li(&a, A1, 0x10)
	la(&a, A2, buf)
	li32(&a, 7, 0x400)
	jal(&a, sd) // sceSdBlockTrans(0, loop, buf, 0x400, 0)
	spin := at(&a)
	lw_at(&a, T2, flag)
	put(&a, 0x11400000 | (spin - at(&a) - 4) / 4 & 0xffff, 0) // beqz t2, spin
	li(&a, V0, 0)
	put(&a, 0x8fbf001c, JR_RA, 0x27bd0020) // lw ra, 28(sp); jr ra; addiu sp, sp, 32
	id, _ := iop.iop_load(build_mod("modbt", &a, entry), "modbt", nil)
	check(id > 0 && iop.iop_u32(module_base(id) + flag)^ == 1, "start: a start spinning on its block transfer's crossing returns, the handler run")
}

// thmsgbx in a start: CreateMbx gives an id; SendMbx queues first come, or by
// priority in an MBA_MSPRI box; PollMbx takes the first, then NOMSG once
// empty, and a send after that is taken again. Emptiness is the box's count:
// a message whose next word the guest wrote over before the poll is taken
// once, and the box is empty after it.
test_msgbx :: proc() {
	fresh()
	a: Asm
	mb := imports(&a, "thmsgbx", 4, 6, 9)
	create, send, poll := mb, mb + 8, mb + 16
	param := at(&a)
	put(&a, 0, 0, 4, 0, 2, 0) // attr, option: first come, MBA_MSPRI, then a bit retail lacks
	msg: [4]u32
	prio := [4]u32{5, 1, 3, 0}
	for &m, i in msg {
		m = at(&a)
		put(&a, 0xffffffff, prio[i]) // next (a send sets it), priority
	}
	// A ring the guest breaks: two of priority 0, then one that ranks below both.
	brk: [3]u32
	brk_prio := [3]u32{0, 0, 0xff}
	for &m, i in brk {
		m = at(&a)
		put(&a, 0xffffffff, brk_prio[i])
	}
	ids := at(&a)
	put(&a, 0, 0, 0, 0, 0)
	out := at(&a) // per box, per poll: v0, the message it took; then a send's v0
	for _ in 0 ..< 25 {put(&a, 0)}
	entry := at(&a)
	prologue(&a)
	poll_to :: proc(a: ^Asm, poll, box, o: u32) {
		la(a, A0, o + 4)
		lw_at(a, A1, box)
		jal(a, poll)
		store_v0(a, o)
	}
	for b in 0 ..< u32(2) {
		la(&a, A0, param + 8 * b)
		jal(&a, create)
		store_v0(&a, ids + 4 * b)
		for m in msg[:3] {
			lw_at(&a, A0, ids + 4 * b)
			la(&a, A1, m)
			jal(&a, send)
		}
		for p in 0 ..< u32(4) {poll_to(&a, poll, ids + 4 * b, out + 32 * b + 8 * p)}
	}
	// The first come box drained: a send there is taken again.
	lw_at(&a, A0, ids)
	la(&a, A1, msg[0])
	jal(&a, send)
	poll_to(&a, poll, ids, out + 64)
	poll_to(&a, poll, ids, out + 72)
	la(&a, A0, param + 16)
	jal(&a, create)
	store_v0(&a, ids + 8)
	// A third box, first come: one message, its next word then written over
	// by its sender, as a stack message's is once the frame is reused.
	la(&a, A0, param)
	jal(&a, create)
	store_v0(&a, ids + 12)
	lw_at(&a, A0, ids + 12)
	la(&a, A1, msg[3])
	jal(&a, send)
	li(&a, V0, 2)
	store_v0(&a, msg[3])
	poll_to(&a, poll, ids + 12, out + 80)
	poll_to(&a, poll, ids + 12, out + 88)
	// A fourth box, MBA_MSPRI: one message, then the ring broken so it leads to
	// a second message that links to itself, never back to the last.
	la(&a, A0, param + 8)
	jal(&a, create)
	store_v0(&a, ids + 16)
	lw_at(&a, A0, ids + 16)
	la(&a, A1, brk[0])
	jal(&a, send)
	la(&a, V0, brk[1])
	store_v0(&a, brk[0])
	store_v0(&a, brk[1])
	lw_at(&a, A0, ids + 16)
	la(&a, A1, brk[2])
	jal(&a, send)
	store_v0(&a, out + 96)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("mbx", &a, entry), "mbx", nil)
	base := module_base(id)
	check(id > 0, "msgbx: a start that creates, sends and polls loads")
	w :: proc(base, off: u32) -> u32 {return iop.iop_u32(base + off)^}
	check(w(base, ids) == 1 && w(base, ids + 4) == 2, "msgbx: CreateMbx gives ids 1 and 2")
	check(w(base, ids + 8) == transmute(u32)i32(-401), "msgbx: CreateMbx refuses an attr bit retail lacks")
	nomsg := transmute(u32)i32(-424)
	for b in 0 ..< u32(2) {
		orders := [2][3]u32{{msg[0], msg[1], msg[2]}, {msg[1], msg[2], msg[0]}}
		order := orders[b]
		got := true
		for p in 0 ..< u32(3) {
			o := out + 32 * b + 8 * p
			got &&= w(base, o) == 0 && w(base, o + 4) == base + order[p]
		}
		got &&= w(base, out + 32 * b + 24) == nomsg && w(base, out + 32 * b + 28) == 0
		check(id > 0 && got, "msgbx: PollMbx takes by priority under MBA_MSPRI, then NOMSG" if b == 1 else "msgbx: PollMbx takes the messages first come, then NOMSG")
	}
	check(w(base, out + 64) == 0 && w(base, out + 68) == base + msg[0] && w(base, out + 72) == nomsg, "msgbx: a send after the box drained is taken, then NOMSG")
	check(w(base, ids + 12) == 3 && w(base, out + 80) == 0 && w(base, out + 88) == nomsg, "msgbx: a message whose next word was written over is taken once, then NOMSG")
	cap_ok := w(base, ids + 16) == 4 && w(base, out + 96) == 0
	for m in iop.iop_sched.mbxs {
		if m.id == 4 {cap_ok &&= m.count == 2 && m.last == base + brk[2]}
	}
	cap_ok &&= w(base, brk[0]) == base + brk[2] && w(base, brk[2]) == base + brk[1]
	check(cap_ok, "msgbx: a send into a ring with no way back to the last goes in as the newest, counted once")
}

// The calls an audio service's module needs at load and in play: CpuEnableIntr
// in a start; ReferSemaStatus and iReferSemaStatus by retail's layout, each only
// in its context; sceSdGetEffectAttr gives back what Set left, delay and
// feedback only in the echo modes; sceSdGetParam reads EVOL.
test_c1_gaps :: proc() {
	fresh()
	a: Asm
	ie := imports(&a, "intrman", 9)
	entry := at(&a)
	prologue(&a)
	jal(&a, ie)
	put(&a, 0)
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modg", &a, entry), "modg", nil)
	check(id > 0, "c1: a start that calls CpuEnableIntr loads")

	// CpuDisableIntr, CpuEnableIntr, then CpuDisableIntr again, whose v0
	// (KE_OK, no state kept) the start returns: a start returning other than
	// 0 does not stay resident
	b: Asm
	di := imports(&b, "intrman", 8, 9)
	entry = at(&b)
	prologue(&b)
	jal(&b, di)
	put(&b, 0)
	jal(&b, di + 8)
	put(&b, 0)
	jal(&b, di)
	put(&b, 0)
	epilogue(&b)
	id, _ = iop.iop_load(build_mod("modh", &b, entry), "modh", nil)
	check(id > 0, "c1: CpuDisableIntr, CpuEnableIntr, CpuDisableIntr each give KE_OK")
	c: Asm
	en := imports(&c, "intrman", 6, 7)
	res := at(&c)
	put(&c, 0xffffffff)
	entry = at(&c)
	prologue(&c)
	li(&c, A0, 40)
	jal(&c, en)
	li(&c, A0, 40)
	la(&c, A1, res)
	jal(&c, en + 8)
	li(&c, A0, 41)
	li(&c, A1, 0)
	jal(&c, en + 8)
	epilogue(&c)
	id, _ = iop.iop_load(build_mod("modi", &c, entry), "modi", nil)
	check(id > 0, "c1: EnableIntr, DisableIntr with and without res each give KE_OK")
	check(id > 0 && iop.iop_u32(module_base(id) + res)^ == 40, "c1: DisableIntr writes the line's old state, enabled, to res")

	P :: 0x00040000
	r := &r3000.state.r
	for w, i in ([4]u32{1, 7, 2, 5}) {iop.iop_u32(P + 4 * u32(i))^ = w}
	r[4] = P
	semid, ok := iop.th_semap(4)
	check(ok, "c1: CreateSema")
	t := iop.th_new(0x1000, 0x2000, 0x100, 0, 10)
	t.status, t.sema = .Wait, semid
	r[4], r[5] = semid, P + 0x40
	v, ok2 := iop.th_semap(11)
	info :: proc(i: u32) -> u32 {return iop.iop_u32(P + 0x40 + 4 * i)^}
	check(ok2 && v == 0 && info(0) == 1 && info(1) == 7 && info(2) == 2 && info(3) == 5 && info(4) == 2 && info(5) == 1, "c1: ReferSemaStatus by retail's layout")
	v, _ = iop.th_semap(12)
	check(v == neg(-iop.KE_ILLEGAL_CONTEXT), "c1: iReferSemaStatus on a thread is illegal")
	iop.iop_sched.intr = true
	v, _ = iop.th_semap(11)
	check(v == neg(-iop.KE_ILLEGAL_CONTEXT), "c1: ReferSemaStatus in a handler is illegal")
	iop.iop_u32(P + 0x40 + 16)^ = 0
	v, _ = iop.th_semap(12)
	check(v == 0 && info(4) == 2, "c1: iReferSemaStatus in a handler")
	iop.iop_sched.intr = false
	r[4] = semid + 100
	v, _ = iop.th_semap(11)
	check(v == neg(-iop.KE_UNKNOWN_SEMID), "c1: an unknown semaphore")

	set :: proc(core, mode, depth, delay, feedback: u32) -> u32 {
		for w, i in ([5]u32{core, mode, depth, delay, feedback}) {iop.iop_u32(P + 4 * u32(i))^ = w}
		r3000.state.r[4], r3000.state.r[5] = core, P
		v, _ := iop.libsd_fn(23)
		return v
	}
	get :: proc(core: u32) -> [5]u32 {
		r3000.state.r[4], r3000.state.r[5] = core, P + 0x40
		iop.libsd_fn(24)
		return {info(0), info(1), info(2), info(3), info(4)}
	}
	check(set(1, 7 | 0x100, 0x20001000, 40, 50) == 0 && get(1) == [5]u32{1, 7, 0x20001000, 40, 50}, "c1: an echo mode's attributes come back, the clear bit not")
	check(set(0, 3, 0x30003000, 40, 50) == 0 && get(0) == [5]u32{0, 3, 0x30003000, 0, 0}, "c1: other modes have no delay or feedback")
	check(get(1) == [5]u32{1, 7, 0x20001000, 40, 50}, "c1: per core")
	r[4] = 0x0b01
	v, _ = iop.libsd_fn(6)
	check(v == 0x1000, "c1: sceSdGetParam reads EVOLL")
	r[4] = 0x0c80
	v, _ = iop.libsd_fn(6)
	check(v == 0x3000, "c1: sceSdGetParam reads EVOLR, the id's other bits aside")
}

// Each thbase and thsemap call in the context retail's threadman allows and
// in the other: in a handler a thread's call gets KE_ILLEGAL_CONTEXT and
// changes nothing, as an i-variant does on a thread; QueryIntrContext says
// which context it is.
test_call_context :: proc() {
	fresh()
	s := &iop.iop_sched
	ill := neg(-iop.KE_ILLEGAL_CONTEXT)
	dormant := neg(-iop.KE_DORMANT)
	base :: proc(fno: u32, a0: u32 = 0) -> u32 {
		r3000.state.r[4] = a0
		v, ok := iop.th_base(fno)
		check(ok, "context: a served thbase call")
		return v
	}
	sema :: proc(fno: u32, a0: u32 = 0) -> u32 {
		r3000.state.r[4] = a0
		v, ok := iop.th_semap(fno)
		check(ok, "context: a served thsemap call")
		return v
	}
	query :: proc(stubs: u32) -> u32 {
		fnos := [?]u32{23}
		return lib_call(stubs, fnos[:], 23)
	}
	count :: proc(id: u32) -> i32 {
		for m in iop.iop_sched.semas {if m.id == id {return m.count}}
		return -1
	}

	a: Asm
	ie := imports(&a, "intrman", 23)
	entry := at(&a)
	put(&a, JR_RA, 0x24020000)
	id, _ := iop.iop_load(build_mod("modq", &a, entry), "modq", nil)
	check(id > 0, "context: a module that imports QueryIntrContext loads")
	qs := module_base(id) + ie

	P :: 0x00040000
	for w, i in ([5]u32{0, 0, 0x1000, 0x800, 20}) {iop.iop_u32(P + 4 * u32(i))^ = w}
	for w, i in ([4]u32{0, 0, 1, 5}) {iop.iop_u32(P + 0x20 + 4 * u32(i))^ = w}
	check(query(qs) == 0, "context: QueryIntrContext on the loader")
	tid := base(4, P)
	semid := sema(4, P + 0x20)
	check(i32(tid) > 0 && i32(semid) > 0, "context: CreateThread and CreateSema on the loader")
	check(base(11, tid) == ill && base(26, tid) == ill, "context: iTerminateThread and iWakeupThread on a thread are illegal")
	check(sema(7, semid) == ill && count(semid) == 1, "context: iSignalSema on a thread is illegal and signals nothing")

	threads, semas := len(s.threads), len(s.semas)
	s.intr = true
	check(query(qs) == 1, "context: QueryIntrContext in a handler")
	for fno in ([10]u32{4, 5, 6, 7, 10, 16, 20, 24, 25, 33}) {check(base(fno, tid) == ill, "context: a thread's thbase call in a handler is illegal")}
	for fno in ([5]u32{4, 5, 6, 8, 9}) {check(sema(fno, semid) == ill, "context: a thread's thsemap call in a handler is illegal")}
	t := iop.th_find(tid)
	check(len(s.threads) == threads && len(s.semas) == semas && t != nil && t.status == .Dormant, "context: a refused call makes, starts and deletes nothing")
	check(count(semid) == 1 && s.intr_stop == .None, "context: a refused wait or poll takes no count and stops no handler")
	check(base(11, tid) == dormant && base(26, tid) == dormant, "context: iTerminateThread and iWakeupThread run in a handler")
	check(sema(7, semid) == 0 && count(semid) == 2, "context: iSignalSema signals in a handler")
	s.intr = false

	check(sema(9, semid) == 0 && sema(8, semid) == 0 && count(semid) == 0, "context: PollSema and WaitSema take a count on the loader")
	check(sema(6, semid) == 0 && count(semid) == 1, "context: SignalSema on the loader")
	check(base(20) == 0 && base(25, tid) == dormant, "context: GetThreadId and WakeupThread run on the loader")
	check(base(5, tid) == 0 && sema(5, semid) == 0 && len(s.threads) == threads - 1 && len(s.semas) == semas - 1, "context: DeleteThread and DeleteSema on the loader")
}

// sceSifInit finds SIF set up, as at boot, and sceSifCheckInit says so.
test_sifman :: proc() {
	v5, ok5 := iop.sifman_fn(5)
	v29, ok29 := iop.sifman_fn(29)
	check(ok5 && v5 == 1 && ok29 && v29 == 1, "sifman: sceSifInit returns the flag set at boot, sceSifCheckInit it")
}

SIFMAN_FNOS := [?]u32{7, 32}

snap15: core.Snapshot
snap15_loaded: bool // not emulated state

// sceSifSetDmaIntr: the copy at once, as sceSifSetDma; the callback owed
// until its transfer's time is up, after those owed before it, and run at
// the tick then with a0 its arg as retail's SIF0 interrupt does, so a
// thread it signals runs after. One that sets another runs once per due.
test_sif_dma_intr :: proc() {
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	// "mods": a thread that waits on sem and counts its passes; a callback
	// that records a0, counts its calls and iSignalSemas sem; one that
	// waits; one that counts its calls and sets itself again.
	a: Asm
	tb := imports(&a, "thbase", 4, 6)
	ts := imports(&a, "thsemap", 4, 7, 8)
	sm := imports(&a, "sifman", ..SIFMAN_FNOS[:])
	d := at(&a) // callback calls, its last a0, thread passes, sem, th
	put(&a, 0, 0, 0, 0, 0)
	src := at(&a)
	put(&a, 0x11223344, 0x55667788, 0x99aabbcc, 0xddeeff00)
	dmat := at(&a) // {src, dest, size, attr}, filled in below
	put(&a, 0, 0, 0, 0)
	semp := at(&a)
	put(&a, 0, 0, 0, 64) // attr, option, initial, max
	rd := at(&a) // the calls of the one that sets itself again
	put(&a, 0)
	h := at(&a)
	prologue(&a)
	la(&a, T0, d)
	put(&a, 0xad040004) // sw a0, 4(t0)
	put(&a, 0x8d090000, 0, 0x25290001, 0xad090000) // lw t1, 0(t0); nop; addiu t1, t1, 1; sw t1, 0(t0)
	put(&a, 0x8d04000c, 0) // lw a0, 12(t0); nop
	jal(&a, ts + 8)
	epilogue(&a)
	hb := at(&a)
	prologue(&a)
	call_word(&a, ts + 16, d + 12)
	epilogue(&a)
	hr := at(&a)
	prologue(&a)
	la(&a, T0, rd)
	put(&a, 0x8d090000, 0, 0x25290001, 0xad090000) // lw t1, 0(t0); nop; addiu t1, t1, 1; sw t1, 0(t0)
	la(&a, A0, dmat)
	li(&a, A1, 1)
	la(&a, A2, hr)
	put(&a, 0x24070000) // li a3, 0
	jal(&a, sm + 8)
	epilogue(&a)
	w := at(&a)
	call_word(&a, ts + 16, d + 12)
	la(&a, T0, d)
	put(&a, 0x8d090008, 0, 0x25290001, 0xad090008) // lw t1, 8(t0); nop; addiu t1, t1, 1; sw t1, 8(t0)
	put_rel(&a, 0x08000000 | w >> 2, 4) // j w
	put(&a, 0)
	tp := thread_param(&a, w, 20)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, ts, semp, d + 12)
	call_addr(&a, tb, tp, d + 16)
	call_word(&a, tb + 8, d + 16)
	li(&a, V0, 0)
	epilogue(&a)
	id, res := iop.iop_load(build_mod("mods", &a, entry), "mods", nil)
	b := module_base(id)
	word :: proc(b, d, i: u32) -> u32 {return iop.iop_u32(b + d + 4 * i)^}
	check(id > 0 && res == 0 && word(b, d, 2) == 0, "sifman 32: the module loads, its thread waits")
	EE_DEST :: 0x100000
	t := iop.iop_mem(b + dmat, 16)
	endian.put_u32(t[0:], .Little, b + src)
	endian.put_u32(t[4:], .Little, EE_DEST)
	endian.put_u32(t[8:], .Little, 16)
	call :: proc(b, sm, fno: u32, args: ..u32) -> u32 {
		fnos := SIFMAN_FNOS
		return lib_call(b + sm, fnos[:], fno, ..args)
	}
	s := &iop.iop_sifcmd

	r3000.state.cycles = 1000
	id7 := call(b, sm, 7, b + dmat, 1)
	copy(mem.ram_slice(EE_DEST, 16), make([]u8, 16, context.temp_allocator))
	id32 := call(b, sm, 32, b + dmat, 1, b + h, 0x55)
	check(id32 != 0 && id32 != id7 && string(mem.ram_slice(EE_DEST, 16)) == string(iop.iop_mem(b + src, 16)), "sifman 32: the copy is done at the call, a new id")
	now := max(cpu.state.cycles, r3000.state.cycles * iop.IOP_EE_RATIO)
	due := now + 16 * iop.SIF_DMA_CYCLES_PER_BYTE
	check(word(b, d, 0) == 0 && s.n_dma_cb == 1 && s.dma_cb[0].due == due && iop.sif_dma_next_ee() == due && iop.iop_wake_ee == due, "sifman 32: the callback is owed, not run, the wake when its bytes have crossed")
	iop.iop_tick(due - 1)
	check(word(b, d, 0) == 0 && s.n_dma_cb == 1, "sifman 32: not run before it is due")
	core.snap_op, core.snap_target = .Save, &snap15
	core.snap_yield()
	if !snap15_loaded {
		iop.iop_tick(iop.iop_wake_ee)
		check(word(b, d, 0) == 1 && s.n_dma_cb == 0, "sifman 32: the tick runs it")
		snap15_loaded = true
		core.snap_op, core.snap_target = .Load, &snap15
		core.snap_yield()
	}
	check(word(b, d, 0) == 0 && s.n_dma_cb == 1 && s.dma_cb[0] == {b + h, 0x55, due}, "sifman 32: the load puts the owed callback back")
	iop.iop_tick(iop.iop_wake_ee)
	check(word(b, d, 0) == 1 && word(b, d, 1) == 0x55 && word(b, d, 2) == 1, "sifman 32: the callback gets its arg, the thread it signals runs after")
	check(s.n_dma_cb == 0 && iop.sif_dma_next_ee() == max(u64), "sifman 32: none owed, no wake")

	ok := true
	for i in 0 ..< iop.SIF_DMA_CBS {ok &&= call(b, sm, 32, b + dmat, 1, b + h, u32(i)) != 0}
	for c, i in s.dma_cb[1:] {ok &&= c.due == s.dma_cb[i].due + 16 * iop.SIF_DMA_CYCLES_PER_BYTE}
	check(ok && call(b, sm, 32, b + dmat, 1, b + h, 99) == 0, "sifman 32: one past the callbacks owed returns 0, each due after the one before")
	check(call(b, sm, 32, b + dmat, 1, 0, 0) != 0, "sifman 32: one with no callback is still sent")
	iop.iop_tick(s.dma_cb[iop.SIF_DMA_CBS - 1].due)
	check(word(b, d, 0) == 1 + iop.SIF_DMA_CBS && word(b, d, 1) == iop.SIF_DMA_CBS - 1 && word(b, d, 2) == 1 + iop.SIF_DMA_CBS, "sifman 32: all run first owed first, the thread passing for each")

	// Dues per entry: a short transfer, then a long one; each runs at its own.
	call(b, sm, 32, b + dmat, 1, b + h, 1)
	endian.put_u32(t[8:], .Little, 64)
	call(b, sm, 32, b + dmat, 1, b + h, 2)
	endian.put_u32(t[8:], .Little, 16)
	d1, d2 := s.dma_cb[0].due, s.dma_cb[1].due
	check(d2 == d1 + 64 * iop.SIF_DMA_CYCLES_PER_BYTE && iop.iop_wake_ee == d1, "sifman 32: each owed has its own due, the wake the first")
	iop.iop_tick(d1)
	check(word(b, d, 1) == 1 && s.n_dma_cb == 1 && iop.sif_dma_next_ee() == d2 && iop.iop_wake_ee == d2, "sifman 32: the tick runs only the one due, the wake moves to the next")
	iop.iop_tick(d2)
	check(word(b, d, 1) == 2 && s.n_dma_cb == 0, "sifman 32: the next runs at its own due")

	key := core.Compat_Key{.Iop_Sif_Intr, b + hb, 0}
	call(b, sm, 32, b + dmat, 1, b + hb, 0)
	call(b, sm, 32, b + dmat, 1, b + h, 7)
	iop.iop_tick(s.dma_cb[1].due)
	check(core.compat.calls[key].n == 0 && word(b, d, 1) == 7 && s.n_dma_cb == 0, "sifman 32: one that waits gets -100 and returns, no row, the next runs")

	// One whose transfer went to the EE's command buffer waits for that
	// packet's due there, here held back behind one queued later in EE time.
	ee_cycles := cpu.state.cycles
	cpu.state.cycles = 1_000_000
	iop.sif_send_raw(make([]u8, 16, context.temp_allocator))
	cpu.state.cycles = ee_cycles
	iop.sif.ee_buf = EE_DEST
	call(b, sm, 32, b + dmat, 1, b + h, 3)
	pkt := iop.sif.replies[len(iop.sif.replies) - 1].due
	check(pkt == 1_000_000 && s.dma_cb[0].due == pkt && iop.iop_wake_ee == pkt, "sifman 32: a callback for a transfer to ee_buf is due no earlier than its packet")
	iop.iop_tick(pkt - 1)
	check(word(b, d, 1) == 7 && s.n_dma_cb == 1, "sifman 32: not run before its packet is due")
	iop.iop_tick(pkt)
	check(word(b, d, 1) == 3 && s.n_dma_cb == 0, "sifman 32: run once its packet is due")
	iop.sif_drop_replies()
	iop.sif.ee_buf = 0

	// One that sets itself again, the IOP idle: it runs once per due, and
	// the next due is later, so the EE's time moves on between them.
	call(b, sm, 32, b + dmat, 1, b + hr, 0)
	w1 := iop.iop_wake_ee
	iop.iop_tick(w1)
	w2 := iop.iop_wake_ee
	check(word(b, rd, 0) == 1 && s.n_dma_cb == 1 && w2 > w1, "sifman 32: one that sets itself again runs once, its next due later")
	iop.iop_tick(w1)
	check(word(b, rd, 0) == 1, "sifman 32: a second tick at the same time runs nothing")
	iop.iop_tick(w2)
	check(word(b, rd, 0) == 2 && iop.iop_wake_ee > w2, "sifman 32: it runs again at its next due")
	fresh()
	check(iop.iop_sifcmd.n_dma_cb == 0, "sifman 32: the loader's reset clears the callbacks owed")
}

// libsd's functions, in the order "modl" imports them.
LIBSD_FNOS := [?]u32{4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 16, 17, 18, 19, 20, 23, 25, 26, 27, 28}

// "modl" as loaded: its base, the offsets of its libsd stubs, its data
// (handler calls, the handler's a0 and a1, thread passes, sem, th) and a
// stack for calls with arguments past a3.
sdm: struct {
	b, lsd, d, sp: u32,
}

// Calls libsd function fno through modl's stub, with args from a0 on.
sd_call :: proc(fno: u32, args: ..u32) -> u32 {
	r := &r3000.state.r
	sp := sdm.b + sdm.sp
	for v, i in args {
		if i < 4 {r[4 + i] = v} else {iop.iop_u32(sp + 16 + 4 * u32(i - 4))^ = v}
	}
	r[29] = sp
	for f, i in LIBSD_FNOS {
		if f == fno {return iop_call(sdm.b + sdm.lsd + 8 * u32(i))}
	}
	return 0xdeadbeef
}

// modl's data word i: 0 handler calls, 1 and 2 its last a0 and a1, 3 the
// thread's passes.
sd_word :: proc(i: u32) -> u32 {return iop.iop_u32(sdm.b + sdm.d + 4 * i)^}

snap4: core.Snapshot
snap4_loaded: bool // not emulated state
snap12: core.Snapshot
snap12_loaded: bool // not emulated state

// The host's mix per vblank follows the input clock, 800.8 samples a
// vblank at 59.94 Hz, so the mixed total never drifts from it.
test_vblank_samples :: proc() {
	want := [?]int{800, 801, 801, 801, 800, 801, 801, 801, 801, 800}
	for n, i in want {check(iop.vblank_samples(u64(i + 1)) == n, "vblank_samples: 800 or 801, 800.8 on average")}
	sum: u64
	for v in u64(1) ..= 60000 {sum += u64(iop.vblank_samples(v))}
	check(sum == 60000 * cpu.CYCLES_PER_FRAME * iop.MIX_RATE / cpu.EE_CLOCK, "vblank_samples: 60000 vblanks mix the input clock's samples")
	check(sum == 48047998, "vblank_samples: 60000 vblanks, 1001 seconds less 2 samples")
}

SD_HALF :: 0x1000 * cpu.EE_CLOCK / (48000 * 4) // EE cycles to move half of a 0x2000-byte buffer

test_libsd :: proc() {
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	// "modl": a thread that waits on sem and counts its passes; a handler
	// that records a0, a1, counts its calls and signals sem.
	a: Asm
	tb := imports(&a, "thbase", 4, 6)
	ts := imports(&a, "thsemap", 4, 7, 8)
	lsd := imports(&a, "libsd", ..LIBSD_FNOS[:])
	d := at(&a)
	put(&a, 0, 0, 0, 0, 0, 0)
	sp := at(&a)
	for _ in 0 ..< 16 {put(&a, 0)}
	adp := at(&a) // two ADPCM blocks of 0x7000s, the second end and repeat
	put(&a, 0x77770000, 0x77777777, 0x77777777, 0x77777777, 0x77770300, 0x77777777, 0x77777777, 0x77777777)
	rd := at(&a)
	for _ in 0 ..< 8 {put(&a, 0)}
	semp := sema_param(&a, 0, 0)
	h := at(&a)
	prologue(&a)
	la(&a, T0, d)
	put(&a, 0xad040004, 0xad050008) // sw a0, 4(t0); sw a1, 8(t0)
	put(&a, 0x8d090000, 0, 0x25290001, 0xad090000) // lw t1, 0(t0); nop; addiu t1, t1, 1; sw t1, 0(t0)
	put(&a, 0x8d040010, 0) // lw a0, 16(t0); nop
	jal(&a, ts + 8)
	epilogue(&a)
	w := at(&a)
	call_word(&a, ts + 16, d + 16)
	la(&a, T0, d)
	put(&a, 0x8d09000c, 0, 0x25290001, 0xad09000c) // lw t1, 12(t0); nop; addiu t1, t1, 1; sw t1, 12(t0)
	put_rel(&a, 0x08000000 | w >> 2, 4) // j w
	put(&a, 0)
	tp := thread_param(&a, w, 20)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, ts, semp, d + 16)
	call_addr(&a, tb, tp, d + 20)
	call_word(&a, tb + 8, d + 20)
	li(&a, V0, 0)
	epilogue(&a)
	buf := at(&a) // 0x2000 bytes for block transfers
	for _ in 0 ..< 0x800 {put(&a, 0)}
	base := coroutines()
	id, res := iop.iop_load(build_mod("modl", &a, entry), "modl", nil)
	sdm = {module_base(id), lsd, d, sp}
	b := sdm.b
	check(id > 0 && res == 0 && sd_word(3) == 0 && coroutines() == base + 1, "libsd: the module loads, its thread waits")
	check(sd_call(4, 0) == 0, "libsd: sceSdInit")

	// After sceSdInit every voice rests stopped on its block at 0x5000,
	// looping on itself: the IRQ enabled on both cores at IRQA 0, nothing
	// keyed, no voice raises it.
	sd_call(9, 0x1f00, 0)
	sd_call(9, 0x1f01, 0)
	sd_call(11, 0x4, 1)
	sd_call(11, 0x5, 1)
	iop.spu_mix(make([]i32, 64, context.temp_allocator))
	check(iop.iop_sd.pending == 0 && sd_call(10, 0x2244) == 0x5000 && sd_call(10, 0x2240 | 1 | 23 << 1) == 0x5000, "libsd: after sceSdInit, the IRQ enabled at IRQA 0 with nothing keyed, no voice raises it")
	sd_call(11, 0x4, 0)
	sd_call(11, 0x5, 0)

	// sceSdNote2Pitch(center note, center fine, note, fine): 0x1000 at the
	// center, by semitones and 128ths of one, doubling per octave up to two;
	// further up it stays at two octaves'. Values as retail libsd 1.5 gives.
	pitches := [?][5]u32 {
		{12, 0, 12, 0, 0x1000},
		{60, 0, 60, 0, 0x1000},
		{12, 0, 24, 0, 0x2000},
		{12, 0, 0, 0, 0x800},
		{60, 0, 48, 0, 0x800},
		{12, 0, 36, 0, 0x4000},
		{12, 0, 47, 0, 0x78d0},
		{12, 0, 13, 0, 0x10f4},
		{12, 0, 11, 0, 0xf1a},
		{12, 0, 12, 64, 0x1078},
		{12, 0, 12, 0xffffffc0, 0xf8b}, // fine -64
		{12, 0, 23, 127, 0x1ffc}, // under the octave by a 128th
		{0, 0, 12, 0xffffffff, 0x1ffc}, // under it from above, the fine borrowing
		{12, 0, 11, 0xffffffff, 0xf18},
		{60, 0, 61, 0xffffff9c, 0x1034}, // fine -100
		{12, 5, 12, 0xfffffffb, 0x1000}, // the fines cancel
		{12, 0, 12, 0xffffff80, 0xf1a}, // fine -128, a whole semitone down
		{12, 0x7fff, 12, 0x7fff, 0x6580}, // the fines' semitones move the note
		{12, 0, 0xffff, 0, 0x78d}, // notes as 16 bits: 13 under
		{12, 0, 0x7fff, 0, 0x5fe4}, // far up, shifted by the low 5 bits
		{12, 0, 0x8000, 0, 0x6597},
		{12, 0, 0x7ff0, 0xffffffff, 0x5098},
	}
	for p in pitches {
		v := sd_call(13, p[0], p[1], p[2], p[3])
		check(v == p[4], fmt.tprintf("libsd: sceSdNote2Pitch(%d, %d, %x, %d) is %x, got %x", p[0], i32(p[1]), p[2], i32(p[3]), p[4], v))
	}
	sd_rows := core.compat.calls[core.Compat_Key{.Iop_Sd, 0xff7f, 13}].n
	check(sd_call(13, 12, 0, 12, 0xffffff7f) == 0, "libsd: a fine under -128 off a semitone, past retail's tables, is 0")
	check(core.compat.calls[core.Compat_Key{.Iop_Sd, 0xff7f, 13}].n == sd_rows + 1, "libsd: and a row")

	// A block transfer plays its buffer in the ADMA layout: per 1024 bytes,
	// 256 left samples then 256 right, at its core's BVOL. Looping, it wraps
	// to the start. BVOL -0x8000 negates exactly.
	pcm := iop.iop_mem(b + buf, 2048)
	for k in 0 ..< 2 {
		for j in 0 ..< 256 {
			v := u16(k * 256 + j + 1)
			endian.put_u16(pcm[k * 1024 + j * 2:], .Little, v)
			endian.put_u16(pcm[k * 1024 + 512 + j * 2:], .Little, ~v + 1)
		}
	}
	cpu.state.cycles = 1000
	sd_call(5, 0x0f00, 0x8000)
	sd_call(5, 0x1000, 0x8000)
	check(sd_call(18, 0, 0x10, b + buf, 2048, 0) == 0, "libsd: a looping block transfer starts")
	check(iop.iop_wake_ee == max(u64), "libsd: a block transfer with no handler adds no wake")
	out := make([]i32, 2 * 600, context.temp_allocator)
	iop.spu_mix(out)
	played := true
	for n in 0 ..< 600 {
		v := i32(n % 512 + 1)
		played &&= out[2 * n] == -v && out[2 * n + 1] == v
	}
	check(played, "libsd: the block plays de-interleaved, wrapping, at BVOL")
	iop.iop_tick(1000 + 4 * SD_HALF)
	check(sd_word(0) == 0, "libsd: a block's crossings run no handler while it has none")
	sd_call(18, 0, 2)
	for &x in out {x = 0}
	iop.spu_mix(out)
	check(out[0] == 0, "libsd: a stopped block is silent")
	sd_call(5, 0x0f00, 0)
	sd_call(5, 0x1000, 0)
	sd_call(18, 0, 0x10, b + buf, 2048, 0)
	for &x in out {x = 0}
	iop.spu_mix(out)
	check(out[0] == 0 && out[1] == 0, "libsd: a block plays nothing at BVOL 0")
	sd_call(18, 0, 2)

	// A transfer handler runs at each half of a block transfer's buffer,
	// with a0 the channel and a1 its argument, and the thread it signals
	// runs after it. Taken after a snapshot, whose load drops the handler
	// coroutine made since.
	check(sd_call(26, 1, b + h, 7) == 0, "libsd: SetTransIntrHandler returns the previous handler, none")
	check(sd_call(28, 1) == 7 && sd_call(28, 0) == 0, "libsd: GetTransIntrHandlerArgument is the channel's argument 26 set")
	check(sd_call(28, 2) == 0 && core.compat.calls[{.Iop_Sd, 2, 28}].n == 1, "libsd: GetTransIntrHandlerArgument of a channel past 1 is 0 and a row")
	C0 :: 5000
	cpu.state.cycles = C0
	sd_call(18, 1, 0x10, b + buf, 0x2000, 0)
	check(iop.iop_wake_ee == C0 + SD_HALF, "libsd: the wake is the first half-buffer crossing")
	saved := coroutines()
	sd_call(7, 0x1301, 0x123456)
	core.snap_op, core.snap_target = .Save, &snap4
	core.snap_yield()
	if !snap4_loaded {
		sd_call(7, 0x1301, 0)
		iop.iop_tick(C0 + SD_HALF - 1)
		check(sd_word(0) == 0, "libsd: no handler before the crossing")
		iop.iop_tick(C0 + SD_HALF)
		check(sd_word(0) == 1 && coroutines() == saved + 1, "libsd: the handler runs at the crossing, on a coroutine made for it")
		snap4_loaded = true
		core.snap_op, core.snap_target = .Load, &snap4
		core.snap_yield()
	}
	check(sd_word(0) == 0 && coroutines() == saved && iop.iop_sd.trans[1] == {b + h, 7}, "libsd: the load restores the handler and drops the coroutine")
	check(sd_call(8, 0x1301) == 0x123456, "libsd: the load restores a SetSwitch mask")
	iop.iop_tick(C0 + SD_HALF)
	check(sd_word(0) == 1 && sd_word(1) == 1 && sd_word(2) == 7 && sd_word(3) == 1, "libsd: the handler gets channel and argument, the thread runs after")
	check(iop.iop_wake_ee == C0 + 2 * SD_HALF, "libsd: the next wake is the second half")
	iop.iop_tick(C0 + 2 * SD_HALF)
	check(sd_word(0) == 2 && iop.iop_wake_ee == C0 + 3 * SD_HALF, "libsd: a looping block crosses every half")
	C1 :: C0 + 3 * SD_HALF
	cpu.state.cycles = C1
	sd_call(18, 1, 0, b + buf, 0x2000, 0)
	check(sd_call(20, 1, 0) == (b + buf) & 0xffffff, "libsd: BlockTransStatus, the first half at the start")
	cpu.state.cycles = C1 + SD_HALF
	check(sd_call(20, 1, 0) == 1 << 24 | (b + buf + 0x1000) & 0xffffff, "libsd: BlockTransStatus, bit 24 the second half")
	cpu.state.cycles = C1
	iop.iop_tick(C1 + SD_HALF)
	check(sd_word(0) == 3 && iop.iop_wake_ee == C1 + 2 * SD_HALF, "libsd: a one-shot block crosses at its half")
	iop.iop_tick(C1 + 2 * SD_HALF)
	check(sd_word(0) == 4 && iop.iop_wake_ee == max(u64), "libsd: and at its end, then no more")
	C2 :: C1 + 3 * SD_HALF
	cpu.state.cycles = C2
	sd_call(18, 1, 0x13, b + buf, 0x2000, b + buf + 0x17fc)
	check(iop.iop_wake_ee == C2 + 0x804 * SD_HALF / 0x1000, "libsd: one started inside its buffer crosses at the next half")
	sd_call(18, 1, 2)
	check(iop.iop_wake_ee == max(u64), "libsd: a stopped block has no wake")

	// Voices: a voice transfer, the voice's parameters, key on, ENVX.
	check(sd_call(17, 0, 0, b + adp, 0x5000, 32) == 32, "libsd: VoiceTrans writes")
	check(sd_call(17, 0, 1, b + rd, 0x5000, 32) == 32 && mem_eq(b + rd, b + adp, 32), "libsd: VoiceTrans reads it back")
	sd_call(9, 0x2040, 0x5000)
	sd_call(5, 0x0200, 0x1000)
	sd_call(5, 0x0000, 0x3fff)
	sd_call(5, 0x0100, 0x3fff)
	sd_call(5, 0x0300, 0x000f)
	sd_call(5, 0x0400, 0)
	check(sd_call(6, 0x0200) == 0x1000 && sd_call(6, 0x0000) == 0x3fff && sd_call(6, 0x0300) == 0x000f, "libsd: GetParam returns what SetParam set")
	// A call sees the voices at its own IOP cycle, not the last mix's: ENVX
	// read at the key on's sample is 0, and two samples (768 IOP cycles
	// each) on, the attack at rate 0 has stepped twice, 0x3800 a sample.
	// The mix first takes the samples rendered ahead, and the clock moves to
	// a sample's start.
	out = make([]i32, 2 * 800, context.temp_allocator)
	iop.spu_mix(out)
	r3000.state.cycles = (r3000.state.cycles / 768 + 1) * 768
	sd_call(7, 0x1500, 1)
	check(sd_call(6, 0x0500) == 0, "libsd: ENVX read at the key on's sample is 0")
	r3000.state.cycles += 2 * 768
	check(sd_call(6, 0x0500) == 0x7000, fmt.tprintf("libsd: ENVX two samples after the key on is 0x7000, got %x", sd_call(6, 0x0500)))
	iop.spu_mix(out)
	st := iop.spu_voice_status(0, 0)
	check(st.on && sd_call(6, 0x0500) == 0x7fff && sd_call(10, 0x2240) &~ 15 == st.nax, "libsd: the keyed voice plays, ENVX at full, NAX")
	check(sd_call(6, 0x0600) == 0x7ffe && sd_call(6, 0x0700) == 0x7ffe, "libsd: VOLX is the volume, twice VOL's level, apart from the envelope")
	// The IOP's clock runs a few samples past the vblank a mix takes (800.8
	// samples a vblank, the IOP's slice ahead of the EE) with a whole
	// vblank's 800 already rendered ahead: a key on there still renders, and
	// ENVX two samples on reads the attack. Two mixes then leave none ahead.
	r3000.state.cycles = (r3000.state.cycles / 768 + 1) * 768
	iop.spu_mix(out)
	r3000.state.cycles += 800 * 768
	check(sd_call(6, 0x0500) == 0x7fff, "libsd: ENVX a vblank on, rendered ahead, at full")
	r3000.state.cycles += 3 * 768
	sd_call(7, 0x1500, 1)
	r3000.state.cycles += 2 * 768
	check(sd_call(6, 0x0500) == 0x7000, fmt.tprintf("libsd: ENVX two samples after a key on past a vblank ahead is 0x7000, got %x", sd_call(6, 0x0500)))
	iop.spu_mix(out)
	iop.spu_mix(out)
	// A linear decrease at rate 0x30 steps by 8 every second sample, from
	// where the volume is; VOLL reads back without bit 15.
	sd_call(5, 0x0000, 0xa030)
	iop.spu_mix(out)
	check(sd_call(6, 0x0600) == 0x7ffe - 400 * 8 && sd_call(6, 0x0700) == 0x7ffe && sd_call(6, 0x0000) == 0x2030, "libsd: a VOLL sweep moves VOLXL alone")
	// The other sweeps, as PCSX2's V_VolumeSlide: a linear increase by 7
	// every second sample; with bit 12 (the negative phase) it heads for
	// -0x8000, and a decrease rises to 0 from below, a positive volume going
	// straight to 0. An exponential increase slows to a quarter over 0x6000.
	// The voice plays on through them all. VOLX reads as 16 bits.
	sweeps := [?][3]u32 {
		{0x0000, 0x8030, 2800},
		{0x0000, 0x9030, u32(u16(0x10000 - 2800))},
		{0x4000, 0xb030, u32(u16(0x10000 - 29568))}, // from -0x8000
		{0x1000, 0xb030, 0},
		{0x2fff, 0xc030, 25274}, // from 0x5ffe; ends 6 samples into a step
	}
	for w in sweeps {
		sd_call(5, 0x0000, w[0])
		sd_call(5, 0x0000, w[1])
		iop.spu_mix(out)
		check(sd_call(6, 0x0600) == w[2], fmt.tprintf("libsd: VOLL %x from %x gives VOLXL %x, got %x", w[1], w[0], w[2], sd_call(6, 0x0600)))
	}
	check(iop.spu_voice_status(0, 0).on, "libsd: the voice plays on through the sweeps")
	// A write keeps the counter: 6 samples in, the next sample steps.
	sd_call(5, 0x0000, 0)
	sd_call(5, 0x0000, 0x8030)
	iop.spu_mix(out[:2])
	check(sd_call(6, 0x0600) == 7, "libsd: a write keeps the sweep's counter")
	// The counter as PCSX2 runs it: each sample adds 0x8000 >> (shift - 11)
	// (at least 1, but 0 in a sweep at step 3 or shift 31) and the level
	// steps, and only then clamps, once it reaches 0x8000. That last step
	// left it at 0.
	// A slow decrease in the negative phase (bit 12) from +0x3000, rate 0x70
	// (shift 28 adds 1): no step for 0x8000 samples, so it holds 0x3000.
	sd_call(5, 0x0000, 0x1800)
	sd_call(5, 0x0000, 0xb070)
	iop.spu_mix(out)
	check(sd_call(6, 0x0600) == 0x3000, "libsd: a slow decrease holds a positive volume until its step")
	// Rate 0x30 then, the counter kept: 800 + 0x4000 is short of 0x8000, so
	// one sample holds 0x3000; the next steps it, clamped to 0.
	sd_call(5, 0x0000, 0xb030)
	iop.spu_mix(out[:2])
	check(sd_call(6, 0x0600) == 0x3000, "libsd: a rate change keeps the counter's count")
	iop.spu_mix(out[:2])
	check(sd_call(6, 0x0600) == 0, "libsd: the step clamps the volume to 0")
	// An exponential increase, rate 0x30: one sample from 0x5ff8 counts
	// 0x4000; the volume then written to 0x7000, over 0x6000 the add is
	// 0x1000, so the step (+7) comes 4 samples on, at 0x8000.
	sd_call(5, 0x0000, 0x2ffc)
	sd_call(5, 0x0000, 0xc030)
	iop.spu_mix(out[:2])
	sd_call(5, 0x0000, 0x3800)
	sd_call(5, 0x0000, 0xc030)
	iop.spu_mix(out[:6])
	check(sd_call(6, 0x0600) == 0x7000, "libsd: over 0x6000 the count goes on at a quarter")
	iop.spu_mix(out[:2])
	check(sd_call(6, 0x0600) == 0x7007, "libsd: the step comes at 0x8000")
	// An exponential decrease scales -8 by the volume and rounds down:
	// -8 * 0x3002 >> 15 = -4 (-3.0005); from 2, -1 then -1 to 0.
	sd_call(5, 0x0000, 0x1801)
	sd_call(5, 0x0000, 0xe030)
	iop.spu_mix(out[:4])
	check(sd_call(6, 0x0600) == 0x2ffe, "libsd: an exponential decrease rounds down")
	sd_call(5, 0x0000, 0x0001)
	sd_call(5, 0x0000, 0xe030)
	iop.spu_mix(out[:8])
	check(sd_call(6, 0x0600) == 0, "libsd: an exponential decrease reaches 0")
	// Voice 1 is not playing; its sweeps step all the same. At shift 27 the
	// add is 1: step 0 (rate 0x6c) steps at 0x8000 and 0x10000 samples, +7
	// each; step 3 (rate 0x6f) adds 0 and never steps.
	check(!iop.spu_voice_status(0, 1).on, "libsd: voice 1 is not playing")
	sd_call(5, 0x0002, 0)
	sd_call(5, 0x0102, 0)
	sd_call(5, 0x0002, 0x8030)
	sd_call(5, 0x0102, 0x8030)
	iop.spu_mix(out)
	check(sd_call(6, 0x0602) == 2800 && sd_call(6, 0x0702) == 2800, "libsd: a sweep steps on a voice not playing")
	sd_call(5, 0x0002, 0x806c)
	sd_call(5, 0x0102, 0x806f)
	for _ in 0 ..< 82 {iop.spu_mix(out)} // 65600 samples
	check(sd_call(6, 0x0602) == 2800 + 14 && sd_call(6, 0x0702) == 2800, "libsd: shift 27 adds 1, at step 3 0")
	sd_call(5, 0x0002, 0)
	sd_call(5, 0x0102, 0)
	sd_call(5, 0x0000, 0x3fff)
	check(iop.iop_sd.pending == 0, "libsd: no IRQ while it is off")

	// The SPU2 handler runs once a voice enters the block at IRQA, with a0
	// the core's bit.
	check(sd_call(27, b + h, 9) == 0, "libsd: SetSpu2IntrHandler returns the previous handler, none")
	sd_call(9, 0x1f00, 0x5010)
	check(sd_call(10, 0x1f00) == 0x5010, "libsd: GetAddr returns IRQA")
	sd_call(11, 0x4, 1)
	iop.spu_mix(out)
	check(iop.iop_sd.pending == iop.SD_PENDING_SPU2 && iop.iop_wake_ee == r3000.state.cycles * 8, "libsd: the voice at IRQA raises core 0's IRQ, the wake at once")
	n0 := sd_word(0)
	iop.iop_tick(cpu.state.cycles)
	check(sd_word(0) == n0 + 1 && sd_word(1) == 1 && sd_word(2) == 9 && iop.iop_sd.pending == 0, "libsd: the SPU2 handler runs once, a0 the core's bit")
	sd_call(11, 0x4, 0)
	iop.spu_mix(out)
	check(iop.iop_sd.pending == 0, "libsd: no IRQ once it is disabled")
	sd_call(9, 0x2041, 0x5000)
	sd_call(5, 0x0201, 0x1000)
	sd_call(7, 0x1501, 1)
	sd_call(9, 0x1f01, 0x5010)
	sd_call(11, 0x5, 1)
	iop.spu_mix(out)
	iop.iop_tick(cpu.state.cycles)
	check(sd_word(0) == n0 + 2 && sd_word(1) == 2, "libsd: core 1's IRQ, a0 its bit")
	iop.spu_mix(out)
	check(iop.iop_sd.pending == 0, "libsd: a raised IRQ is taken: off until enabled again")
	sd_call(11, 0x5, 0)

	// The input area's read raises a core's IRQ at IRQA: core 1's at 0x4a00,
	// position 0x100 of its left half (0x4e00, its right half's, the same),
	// is due when the read, at 48 kHz of EE time, takes it. At IOP cycle
	// 0x2100000 (EE 0x10800000), 0xb000 samples read, the next at 0x100 is
	// read 0xb100, taken once 0xb101 samples are read, at 0xb101 * 6144. The
	// handler runs once there, not a cycle before, a0 core 1's bit, and the
	// IRQ is off after; a snapshot while it is pending restores it. Enabled
	// again just after the read 0xb300, it is due at the read 0xb500.
	SAMPLE :: cpu.EE_CLOCK / 48000
	IN_DUE :: 0xb101 * SAMPLE
	check(r3000.state.cycles <= 0x2100000 && cpu.state.cycles <= 0x10800000, "libsd: the clocks are before the input IRQ test's")
	r3000.state.cycles, cpu.state.cycles = 0x2100000, 0x10800000
	// The voices are silenced here, at the jump: the calls catch them up to
	// the IOP's cycle, so the samples up to the input area's mix below are
	// rendered from now on, at these volumes.
	vols := [?]u32{0x0000, 0x0100, 0x0001, 0x0101}
	for v in vols {sd_call(5, v, 0)}
	sd_call(9, 0x1f01, 0x4e00)
	sd_call(11, 0x5, 1)
	check(iop.iop_wake_ee == IN_DUE, "libsd: an enabled IRQA in the input area's right half wakes the IOP at the read there")
	sd_call(9, 0x1f01, 0x4a00)
	check(iop.iop_wake_ee == IN_DUE, "libsd: and in its left half, at the read there")
	core.snap_op, core.snap_target = .Save, &snap12
	core.snap_yield()
	if !snap12_loaded {
		iop.iop_tick(IN_DUE)
		check(sd_word(0) == n0 + 3, "libsd: the input IRQ runs before the snapshot's load")
		snap12_loaded = true
		core.snap_op, core.snap_target = .Load, &snap12
		core.snap_yield()
	}
	check(sd_word(0) == n0 + 2 && iop.iop_wake_ee == IN_DUE, "libsd: the load restores the input IRQ pending")
	iop.iop_tick(IN_DUE - 1)
	check(sd_word(0) == n0 + 2, "libsd: no IRQ before the read reaches IRQA")
	iop.iop_tick(IN_DUE)
	check(sd_word(0) == n0 + 3 && sd_word(1) == 2, "libsd: the read at IRQA runs the SPU2 handler, a0 core 1's bit")
	iop.iop_tick(IN_DUE + 0x200 * SAMPLE)
	check(sd_word(0) == n0 + 3, "libsd: the IRQ is off once taken")
	sd_call(11, 0x5, 1)
	check(iop.iop_wake_ee == 0xb501 * SAMPLE, "libsd: enabled again, it is due at the next pass")
	sd_call(11, 0x5, 0)

	// The input area plays at its core's BVOL: core 1's, filled 2(i + 1) at
	// left position i and the negative at right, at BVOL 0x4000 plays i + 1.
	// Mixed at IN_DUE, its last sample is the read at IRQA, position 0x100.
	// The voices are silent (above).
	inp := iop.iop_mem(b + buf, 0x800)
	for i in 0 ..< 512 {
		endian.put_u16(inp[i * 2:], .Little, u16(2 * (i + 1)))
		endian.put_u16(inp[0x400 + i * 2:], .Little, u16(0x10000 - 2 * (i + 1)))
	}
	check(sd_call(17, 0, 0, b + buf, 0x4800, 0x800) == 0x800, "libsd: VoiceTrans fills core 1's input area")
	sd_call(5, 0x0f01, 0x4000)
	sd_call(5, 0x1001, 0x4000)
	cpu.state.cycles = IN_DUE
	for &x in out {x = 0}
	iop.spu_mix(out)
	inplay := out[len(out) - 2] == 0x101 && out[len(out) - 1] == -0x101
	for n in 0 ..< len(out) / 2 {
		v := i32((0xb100 - (len(out) / 2 - 1) + n) & 0x1ff) + 1
		inplay &&= out[2 * n] == v && out[2 * n + 1] == -v
	}
	check(inplay, "libsd: core 1's input area plays at its BVOL, the read at IRQA last at its cycle")
	sd_call(5, 0x0f01, 0)
	sd_call(5, 0x1001, 0)

	// A block playing into a core takes its input's place: core 0's input
	// area filled 0xfff left and -0x800 right, a looping block of -0x1000,
	// BVOL 0x7fff and 0x4000.
	for i in 0 ..< 512 {
		endian.put_u16(inp[i * 2:], .Little, 0x0fff)
		endian.put_u16(inp[0x400 + i * 2:], .Little, 0xf800)
	}
	sd_call(17, 0, 0, b + buf, 0x4000, 0x800)
	for i in 0 ..< 512 {endian.put_u16(inp[i * 2:], .Little, 0xf000)}
	sd_call(5, 0x0f00, 0x7fff)
	sd_call(5, 0x1000, 0x4000)
	sd_call(18, 0, 0x10, b + buf, 1024, 0)
	for &x in out {x = 0}
	iop.spu_mix(out)
	blk := true
	for n in 0 ..< len(out) / 2 {blk &&= out[2 * n] == -0x1000 && out[2 * n + 1] == -0x800}
	check(blk, "libsd: a playing block takes the input area's place, at BVOL")
	sd_call(18, 0, 2)
	for &x in out {x = 0}
	iop.spu_mix(out)
	check(out[0] == 0xffe && out[1] == -0x400, "libsd: stopped, the input area plays")
	sd_call(5, 0x0f00, 0)
	sd_call(5, 0x1000, 0)
	sd_call(11, 0x5, 0)

	// A voice transfer on a channel with a handler raises it, done at once.
	sd_call(26, 0, b + h, 5)
	sd_call(17, 0, 0, b + adp, 0x5000, 32)
	iop.iop_tick(cpu.state.cycles)
	check(sd_word(0) == n0 + 4 && sd_word(1) == 0 && sd_word(2) == 5, "libsd: the transfer handler runs, a0 the channel")

	// A stopped voice runs on through its blocks at its pitch, as PCSX2's
	// MixVoice runs every voice for its IRQs: voice 0, keyed off with
	// release rate 0 (0x7fff, 0x3fff, then 0 and stopped), still raises
	// core 0's IRQ entering the block at IRQA, 0x5010, within one 56-sample
	// pass of its two blocks.
	sd_call(7, 0x1600, 1)
	iop.spu_mix(out[:4])
	check(!iop.spu_voice_status(0, 0).on && sd_call(6, 0x0500) == 0, "libsd: voice 0 keyed off stops, ENVX 0")
	sd_call(11, 0x4, 1)
	n1 := sd_word(0)
	iop.spu_mix(make([]i32, 2 * 64, context.temp_allocator))
	check(iop.iop_sd.pending == iop.SD_PENDING_SPU2, "libsd: a stopped voice entering the block at IRQA raises the IRQ")
	iop.iop_tick(cpu.state.cycles)
	check(sd_word(0) == n1 + 1 && sd_word(1) == 1 && sd_word(2) == 9, "libsd: and the SPU2 handler runs, a0 core 0's bit")
	sd_call(11, 0x4, 0)

	// Every voice's block start at IRQA raises the IRQ the sample after IRQA
	// is set, whatever the voice does there (PCSX2's UpdateBlockHeader):
	// voice 2, keyed on at pitch 0 at 0x6000 with the IRQ off, raises core
	// 0's once it is enabled at 0x6000; parked there, keyed off and stopped,
	// it raises it again, and core 1's at 0x6000 too.
	sd_call(17, 0, 0, b + adp, 0x6000, 32)
	iop.iop_tick(cpu.state.cycles) // the transfer handler on channel 0
	n2 := sd_word(0)
	sd_call(9, 0x2044, 0x6000)
	sd_call(5, 0x0204, 0)
	sd_call(9, 0x1f00, 0x6000)
	sd_call(7, 0x1500, 1 << 2)
	iop.spu_mix(out[:2])
	check(iop.iop_sd.pending == 0 && sd_call(10, 0x2244) == 0x6000, "libsd: voice 2 keyed on at IRQA with the IRQ off raises nothing")
	sd_call(11, 0x4, 1)
	iop.spu_mix(out[:2])
	check(iop.iop_sd.pending == iop.SD_PENDING_SPU2, "libsd: a pitch-0 voice at IRQA raises the IRQ the sample after it is enabled")
	iop.iop_tick(cpu.state.cycles)
	check(sd_word(0) == n2 + 1 && sd_word(1) == 1, "libsd: the SPU2 handler runs, a0 core 0's bit")
	sd_call(7, 0x1600, 1 << 2)
	iop.spu_mix(out[:16])
	check(!iop.spu_voice_status(0, 2).on && sd_call(10, 0x2244) == 0x6000 && iop.iop_sd.pending == 0, "libsd: voice 2 keyed off stops, parked at 0x6000")
	sd_call(11, 0x4, 1)
	iop.spu_mix(out[:2])
	check(iop.iop_sd.pending == iop.SD_PENDING_SPU2, "libsd: a stopped pitch-0 voice at IRQA raises the IRQ the sample after it is enabled")
	iop.iop_tick(cpu.state.cycles)
	check(sd_word(0) == n2 + 2 && sd_word(1) == 1, "libsd: and the SPU2 handler runs, a0 core 0's bit")
	sd_call(9, 0x1f01, 0x6000)
	sd_call(11, 0x5, 1)
	iop.spu_mix(out[:2])
	check(iop.iop_sd.pending == iop.SD_PENDING_SPU2 << 1, "libsd: a core 0 voice at core 1's IRQA raises core 1's IRQ")
	iop.iop_tick(cpu.state.cycles)
	check(sd_word(0) == n2 + 3 && sd_word(1) == 2, "libsd: the SPU2 handler runs, a0 core 1's bit")

	// A voice playing in the block at IRQA raises the IRQ once it is
	// enabled there mid-block, not at its next block: voice 2 at pitch
	// 0x1000, 8 samples into the block at 0x6000.
	sd_call(5, 0x0204, 0x1000)
	sd_call(7, 0x1500, 1 << 2)
	iop.spu_mix(out[:8])
	check(iop.spu_voice_status(0, 2).on && sd_call(10, 0x2244) == 0x6000 && iop.iop_sd.pending == 0, "libsd: voice 2 plays mid-block at 0x6000, the IRQ off")
	sd_call(11, 0x4, 1)
	iop.spu_mix(out[:2])
	check(iop.iop_sd.pending == iop.SD_PENDING_SPU2, "libsd: enabled mid-block at the playing voice's block, the IRQ is raised")
	iop.iop_tick(cpu.state.cycles)
	check(sd_word(0) == n2 + 4, "libsd: and the SPU2 handler runs")
	sd_call(7, 0x1600, 1 << 2)
	sd_call(5, 0x0204, 0)
	iop.spu_mix(out[:16])

	// IRQA in the output areas below the input areas, written every sample
	// (PCSX2's spu2M_WriteFast), raises the IRQ on the input read's clock:
	// core 0's at 0x800 within one pass of 0x200 samples.
	sd_call(9, 0x1f00, 0x800)
	sd_call(11, 0x4, 1)
	out_due := iop.iop_wake_ee
	check(out_due > r3000.state.cycles * 8 && out_due <= r3000.state.cycles * 8 + 0x201 * SAMPLE, "libsd: an enabled IRQA in the output area wakes the IOP within a pass")
	iop.iop_tick(out_due)
	check(sd_word(0) == n2 + 5 && sd_word(1) == 1, "libsd: the write at IRQA runs the SPU2 handler, a0 core 0's bit")

	// GetSwitch: the masks as sceSdInit leaves them, LIBSD 1.5's four mixes
	// all ones and PMON, NON 0, then as SetSwitch writes them, 24 bits, a
	// core each. An id's other low bits are ignored, as LIBSD 1.5 takes
	// the core from bit 0 alone.
	sd_call(4, 0)
	check(sd_call(8, 0x1800) == 0xffffff && sd_call(8, 0x1901) == 0xffffff && sd_call(8, 0x1a00) == 0xffffff && sd_call(8, 0x1b01) == 0xffffff && sd_call(8, 0x1300) == 0 && sd_call(8, 0x1401) == 0, "libsd: GetSwitch after sceSdInit: the mixes all ones, PMON and NON 0")
	SWITCHES :: [?]u32{0x1300, 0x1400, 0x1800, 0x1900, 0x1a00, 0x1b00}
	for id, i in SWITCHES {
		sd_call(7, id, 0xff000000 | u32(i + 1))
		sd_call(7, id | 0x81, u32(i + 1) << 16)
	}
	same := true
	for id, i in SWITCHES {
		same &&= sd_call(8, id) == u32(i + 1) && sd_call(8, id | 1) == u32(i + 1) << 16 && sd_call(8, id | 0x42) == u32(i + 1)
	}
	check(same, "libsd: GetSwitch returns the mask SetSwitch wrote, 24 bits, per core, other low bits ignored")
	sd_call(7, 0x1700, 0)
	check(sd_call(8, 0x1700) == 0, "libsd: GetSwitch ENDX after SetSwitch clears it")
	check(sd_call(8, 0x1500) == 0 && core.compat.calls[core.Compat_Key{.Iop_Sd, 0x1500, 8}].n == 1, "libsd: GetSwitch KON is 0 and a row")

	// The input area plays dry at BVOL: core 0's left at 0x4000 and right at
	// 0x4400, silent at sceSdInit's BVOL 0, then each sample times BVOL >> 15.
	for i in u32(0) ..< 0x100 {iop.iop_u32(b + buf + 4 * i)^ = 0x10001000}
	sd_call(17, 0, 0, b + buf, 0x4000, 0x400)
	for i in u32(0) ..< 0x100 {iop.iop_u32(b + buf + 4 * i)^ = 0xf000f000}
	sd_call(17, 0, 0, b + buf, 0x4400, 0x400)
	out = make([]i32, 2 * 800, context.temp_allocator)
	iop.spu_mix(out)
	silent := true
	for x in out {silent &&= x == 0}
	check(silent, "libsd: the input area is silent at BVOL 0")
	sd_call(5, 0x0f00, 0x7fff)
	sd_call(5, 0x1000, 0x4000)
	out = make([]i32, 2 * 800, context.temp_allocator)
	iop.spu_mix(out)
	input := true
	for n := 0; n < len(out); n += 2 {input &&= out[n] == 0xfff && out[n + 1] == -0x800}
	check(input, "libsd: the input area plays at BVOL, left and right")

	// sceSdProcBatch: each {func, entry, value} in order, its result to
	// returns: SetAddr and GetAddr of SSA and of NAX (16-byte blocks), a word
	// written to IOP memory and one sent to the EE.
	EE_WORD :: 0x100000
	bat, ret, word := b + buf, b + buf + 0x100, b + buf + 0x200
	batch :: proc(at: u32, e: ..[3]u32) {
		for x, i in e {
			iop.iop_u32(at + 8 * u32(i))^ = x[0] | x[1] << 16
			iop.iop_u32(at + 8 * u32(i) + 4)^ = x[2]
		}
	}
	rets :: proc(at: u32) -> []u32 {return ([^]u32)(raw_data(iop.iop_mem(at, 4 * 32)))[:32]}
	slice.fill(rets(ret), 0xffffffff)
	mem.wr32(EE_WORD, 0)
	batch(bat, {3, 0x2044, 0x6000}, {19, 0x2044, 0}, {3, 0x2244, 0x7008}, {19, 0x2244, 0}, {5, 0x1234, word}, {6, 0xbeef, EE_WORD})
	n := sd_call(15, bat, ret, 6)
	r := rets(ret)
	check(n == 6 && slice.equal(r[:7], []u32{0, 0x6000, 0, 0x7000, 0, 0, 0xffffffff}), "libsd: sceSdProcBatch runs each entry, its result to returns")
	check(sd_call(10, 0x2044) == 0x6000 && sd_call(10, 0x2244) == 0x7000 && iop.iop_u32(word)^ == 0x1234 && mem.rd32(EE_WORD) == 0xbeef, "libsd: sceSdProcBatch's sets land; NAX in blocks; the IOP and EE writes")
	check(sd_call(15, bat, 0, 2) == 2, "libsd: sceSdProcBatch without returns")
	slice.fill(rets(ret), 0xffffffff)
	batch(bat, {19, 0x2044, 0}, {8, 0, 0}, {19, 0x2244, 0})
	n = sd_call(15, bat, ret, 3)
	check(n == ~u32(1) && r[0] == 0x6000 && r[1] == 0xffffffff && r[2] == 0xffffffff, "libsd: sceSdProcBatch stops at an unknown func, ~its index")

	// sceSdProcBatchEx: an entry for all voices (0x3e in a param's, 0x7e in
	// an address's) runs on the voices of the mask, 3 and 5. A set takes a
	// slot per voice, 0 in the last; GetAddr one per voice in the mask;
	// GetParam all 24, a voice not in it the read before; each get's last
	// written again.
	slice.fill(rets(ret), 0xffffffff)
	batch(bat, {3, 0x207e, 0x8000}, {19, 0x207e, 0})
	n = sd_call(16, bat, ret, 2, 1 << 3 | 1 << 5)
	check(n == 4 && slice.equal(r[:5], []u32{0xffffffff, 0, 0x8000, 0x8000, 0xffffffff}), "libsd: sceSdProcBatchEx SetAddr and GetAddr on the mask's voices")
	check(sd_call(10, 0x2046) == 0x8000 && sd_call(10, 0x204a) == 0x8000 && sd_call(10, 0x2048) != 0x8000, "libsd: sceSdProcBatchEx sets only the mask's voices")
	slice.fill(rets(ret), 0xffffffff)
	batch(bat, {1, 0x023e, 0x1234}, {17, 0x023e, 0})
	n = sd_call(16, bat, ret, 2, 1 << 3 | 1 << 5)
	check(n == 26 && r[1] == 0 && slice.equal(r[2:5], []u32{0, 0, 0}) && r[5] == 0x1234 && r[6] == 0x1234 && r[25] == 0x1234 && r[26] == 0xffffffff, "libsd: sceSdProcBatchEx GetParam fills all 24 slots")
	check(sd_call(6, 0x0206) == 0x1234 && sd_call(6, 0x020a) == 0x1234 && sd_call(6, 0x0208) != 0x1234, "libsd: sceSdProcBatchEx SetParam only on the mask's voices")

	// An id libsd_fn does not decode raises a compat row.
	sd_call(5, 0x3f00, 0)
	sd_call(11, 0xc, 1)
	check(core.compat.calls[core.Compat_Key{.Iop_Sd, 0x3f00, 5}].n == 1 && core.compat.calls[core.Compat_Key{.Iop_Sd, 0xc, 11}].n == 1, "libsd: undecoded ids are compat rows")

	fresh()
	check(iop.iop_sd == {} && coroutines() == base, "libsd: the loader's reset clears its handlers")
}

CDVDMAN_FNOS := [?]u32{4, 5, 6, 8, 10, 11, 12, 13, 28, 37, 44, 75, 83, 84}
IOMAN_FNOS := [?]u32{4, 5, 6, 8}

// Calls function fno of `fnos`, whose stubs are at `stubs`, with a0 on.
lib_call :: proc(stubs: u32, fnos: []u32, fno: u32, args: ..u32) -> u32 {
	for v, i in args {r3000.state.r[4 + i] = v}
	for f, i in fnos {
		if f == fno {return iop_call(stubs + 8 * u32(i))}
	}
	return 0xdeadbeef
}

cd_call :: proc(stubs, fno: u32, args: ..u32) -> u32 {return lib_call(stubs, CDVDMAN_FNOS[:], fno, ..args)}
io_call :: proc(stubs, fno: u32, args: ..u32) -> u32 {return lib_call(stubs, IOMAN_FNOS[:], fno, ..args)}

neg :: proc(e: i32) -> u32 {return u32(-e)}

SECTOR :: 2048

// cdvdfsv's SearchFile server on a dual-layer image, the EE request in buf
// and its record written at an EE address: the old 0x124 request with its
// 0x20 record, 0x128 on the first layer, and any nonzero layer the second.
// fileio GETSTAT (fno 12): the reply carries the result, the EE stat
// buffer's address and the stat, as the cdrom device fills it.
test_fileio_getstat :: proc() {
	dir, err := os.make_directory_temp("", "ps_iop_stat_test_*", context.allocator)
	if err != nil {
		check(false, "getstat: no temp directory")
		return
	}
	defer os.remove_all(dir)
	iso := discimg.make_iso(discimg.CNF_PS2)
	root := discimg.sector(iso, 20)
	rec := root[strings.index(string(root), "Big.Bin;1") - 33:]
	copy(rec[18:25], []u8{99, 12, 31, 23, 59, 58, 0}) // 1999-12-31 23:59:58
	path := fmt.tprintf("%s/cd.iso", dir)
	_ = os.write_entire_file(path, iso)
	if !iop.disc_image_open(path) {
		check(false, "getstat: the image opens")
		return
	}
	defer iop.disc_image_close() // before the directory is removed
	iop.fileio_reset()
	fresh()

	REPLY :: 0x00100800
	STAT :: 0x00100a00
	fio := iop.sif.servers[0x80000001]
	init: [8]u8
	(^u32)(&init[0])^ = REPLY
	check(fio(255, init[:], 8), "getstat: fileio init answers")
	// Sends the name with STAT as the EE buffer; the reply's result, its
	// stat address and the stat.
	stat :: proc(fio: iop.Rpc_Server, name: string) -> (result: i32, at: u32, st: []u8) {
		buf: [0x110]u8
		w := ([^]u32)(raw_data(buf[:]))
		w[0], w[1], w[2], w[3] = 0xe, 0x00100900, 4, STAT
		copy(buf[0x10:], name)
		for i in u32(0) ..< 0x58 / 4 {mem.wr32(REPLY + 4 * i, 0xaaaaaaaa)}
		check(fio(12, buf[:], 0x110) && w[0] == 1, "getstat: fno 12 answers")
		r := mem.ram_slice(REPLY, 0x58)
		check(endian.unchecked_get_u32le(r[4:]) == 12, "getstat: the reply's command")
		return i32(endian.unchecked_get_u32le(r[0x10:])), endian.unchecked_get_u32le(r[0x14:]), r[0x18:]
	}
	u32_at :: proc(b: []u8, at: int) -> u32 {return endian.unchecked_get_u32le(b[at:])}

	res, at, st := stat(fio, "cdrom0:\\BIG.BIN;1")
	time := []u8{0, 58, 59, 23, 31, 12, 1999 & 0xff, 1999 >> 8}
	check(res == 0 && at == STAT, "getstat: a file is found, 0, the reply names the EE buffer")
	check(u32_at(st, 0) == 0x2124 && u32_at(st, 4) == 0 && u32_at(st, 8) == discimg.BIG, "getstat: a file's mode, attr and size")
	check(slice.equal(st[0x0c:0x14], time) && slice.equal(st[0x14:0x1c], time) && slice.equal(st[0x1c:0x24], time), "getstat: ctime, atime and mtime are the record's date")
	check(slice.all_of(st[0x24:0x40], 0), "getstat: hisize and the private words are 0")
	res, _, st = stat(fio, "cdrom0:\\DATA")
	check(res == 0 && u32_at(st, 0) == 0x116d && u32_at(st, 8) == disc.DATA, "getstat: a directory's mode and size")
	check(slice.equal(st[0x0c:0x14], []u8{0, 0, 0, 0, 0, 0, 1900 & 0xff, 1900 >> 8}), "getstat: a zero date is 1900")
	res, _, st = stat(fio, "cdrom:\\DATA\\SUB.TXT")
	check(res == 0 && u32_at(st, 0) == 0x2124 && u32_at(st, 8) == u32(len(discimg.SUB)), "getstat: no version and no unit find the file")
	for name in ([]string{"cdrom0:", "cdrom0:.", "cdrom0:\\.", "cdrom0:\\"}) {
		res, _, st = stat(fio, name)
		check(res == 0 && u32_at(st, 0) == 0x116d, fmt.tprintf("getstat: %q is the root", name))
	}
	res, _, st = stat(fio, "cdrom0:\\NOPE.BIN;1")
	check(res == -2 && u32_at(st, 0) == 0, "getstat: a missing file is -ENOENT, no stat")
	res, _, _ = stat(fio, "cdrom1:\\BIG.BIN;1")
	check(res == -2, "getstat: unit 1 is the second layer, none on this disc")
	for name in ([]string{"host:x", "mc0:x", "x"}) {
		res, _, _ = stat(fio, name)
		check(res == -19, fmt.tprintf("getstat: %q is another device, -ENODEV", name))
	}
}

test_cdvd_search_server :: proc() {
	dir, err := os.make_directory_temp("", "ps_iop_search_test_*", context.allocator)
	if err != nil {
		check(false, "search server: no temp directory")
		return
	}
	defer os.remove_all(dir)
	V :: discimg.VOLUME
	iso := discimg.make_iso(discimg.CNF_PS2, udf = true)
	img := make([]u8, 2 * len(iso), context.temp_allocator)
	copy(img, iso)
	copy(img[len(iso):], iso)
	path := fmt.tprintf("%s/dl.iso", dir)
	_ = os.write_entire_file(path, img)
	if !iop.disc_image_open(path) {
		check(false, "search server: the image opens")
		return
	}
	defer iop.disc_image_close() // before the directory is removed
	iop.fileio_reset()
	fresh()

	EE_DEST :: 0x00100400
	search := iop.sif.servers[0x80000597]
	// Sends name at path_at with the EE address after it and the layer word
	// at 0x128, then returns the found word and the record at EE_DEST.
	ask :: proc(search: iop.Rpc_Server, size, path_at, layer: u32, name: string) -> (found: u32, rec: []u8) {
		buf: [0x12c]u8
		w := ([^]u32)(raw_data(buf[:]))
		copy(buf[path_at:], name)
		w[(path_at + 0x100) / 4] = EE_DEST
		w[0x128 / 4] = layer
		for i in u32(0) ..< 0x28 / 4 {mem.wr32(EE_DEST + 4 * i, 0xaaaaaaaa)}
		ok := search(0, buf[:], size)
		check(ok, "search server: fno 0 answers")
		return w[0], mem.ram_slice(EE_DEST, 0x28)
	}
	lsn :: proc(rec: []u8) -> u32 {return endian.unchecked_get_u32le(rec)}

	found, rec := ask(search, 0x124, 0x20, 1, "\\BIG.BIN;1")
	check(found == 1 && lsn(rec) == 23 && endian.unchecked_get_u32le(rec[4:]) == discimg.BIG && string(rec[8:17]) == "BIG.BIN;1", "search server: an old request reads the path at 0x20")
	check(endian.unchecked_get_u32le(rec[0x20:]) == 0xaaaaaaaa, "search server: an old request's record is 0x20 bytes")
	found, rec = ask(search, 0x128, 0x24, 1, "\\BIG.BIN;1")
	check(found == 1 && lsn(rec) == 23 && endian.unchecked_get_u32le(rec[0x24:]) == 0xaaaaaaaa, "search server: 0x128 searches the first layer, a 0x24 record")
	found, rec = ask(search, 0x12c, 0x24, 0, "\\BIG.BIN;1")
	check(found == 1 && lsn(rec) == 23, "search server: layer 0")
	found, rec = ask(search, 0x12c, 0x24, 1, "\\BIG.BIN;1")
	check(found == 1 && lsn(rec) == V + 23, "search server: layer 1")
	found, rec = ask(search, 0x12c, 0x24, 3, "\\BIG.BIN;1")
	check(found == 1 && lsn(rec) == V + 23, "search server: any nonzero layer is the second")
	found, rec = ask(search, 0x12c, 0x24, 0, "\\NOPE.BIN;1")
	check(found == 0 && lsn(rec) == 0xaaaaaaaa, "search server: a miss returns 0 and writes nothing")
	found, rec = ask(search, 0x130, 0x20, 1, "\\BIG.BIN;1")
	check(found == 1 && lsn(rec) == 23 && endian.unchecked_get_u32le(rec[0x20:]) == 0xaaaaaaaa, "search server: another size is an old request")

	on_dual, start := dual_info()
	check(on_dual == 1 && start == V, "dual info: a dual-layer image's second layer start")
	// One layer with 11 sectors past its volume: the image's count, not
	// the volume's.
	SINGLE :: V + 11
	one := make([]u8, SINGLE * SECTOR, context.temp_allocator)
	copy(one, iso)
	path = fmt.tprintf("%s/sl.iso", dir)
	_ = os.write_entire_file(path, one)
	if !iop.disc_image_open(path) {
		check(false, "dual info: the single-layer image opens")
		return
	}
	on_dual, start = dual_info()
	check(on_dual == 0 && start == SINGLE, "dual info: a single-layer image's sector count")
}

// ReadDvdDualInfo through cdvdfsv's S-command server: {result, on_dual,
// layer1_start}, the result checked to be 1.
dual_info :: proc() -> (on_dual, start: u32) {
	buf: [64]u8
	w := ([^]u32)(raw_data(buf[:]))
	ok := iop.sif.servers[0x80000593](0x27, buf[:], 0)
	check(ok && w[0] == 1, "dual info: answers 1")
	return w[1], w[2]
}

// The disk type and the dual-layer info by the image's medium, through
// cdvdman (exports 12 and 83) and cdvdfsv (S-commands 0x03 and 0x27), which
// must agree, and sceCdLayerSearchFile (export 84).
test_cd_type :: proc() {
	dir, err := os.make_directory_temp("", "ps_iop_cd_type_test_*", context.allocator)
	if err != nil {
		check(false, "cd type: no temp directory")
		return
	}
	defer os.remove_all(dir)
	defer iop.disc_image_close() // before the directory is removed

	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	a: Asm
	cdo := imports(&a, "cdvdman", ..CDVDMAN_FNOS[:])
	big := str_words(&a, "\\BIG.BIN;1")
	nope := str_words(&a, "\\NOPE.BIN;1")
	file := at(&a)
	for _ in 0 ..< iop.CD_FILE / 4 {put(&a, 0)}
	out := at(&a)
	put(&a, 0, 0)
	entry := at(&a)
	prologue(&a)
	li(&a, V0, 0)
	epilogue(&a)
	id, res := iop.iop_load(build_mod("modt", &a, entry), "modt", nil)
	b := module_base(id)
	check(id > 0 && res == 0, "cd type: the module loads")
	cd := b + cdo

	// Writes img as name in dir and opens it as the disc; its path.
	open_img :: proc(dir, name: string, img: []u8) -> string {
		path := fmt.tprintf("%s/%s", dir, name)
		_ = os.write_entire_file(path, img)
		check(iop.disc_image_open(path), fmt.tprintf("cd type: %s opens", name))
		return path
	}
	// The disk type, the same through both paths.
	kind :: proc(cd: u32) -> u32 {
		buf: [64]u8
		ok := iop.sif.servers[0x80000593](0x03, buf[:], 0)
		t := endian.unchecked_get_u32le(buf[:])
		check(ok && t == cd_call(cd, 12), "cd type: GetDiskType and sceCdGetDiskType agree")
		return t
	}
	// sceCdReadDvdDualInfo's outputs, both written over 0xaaaaaaaa, the same
	// as S-command 0x27's.
	dual :: proc(cd, out: u32) -> (on_dual, start: u32) {
		iop.iop_u32(out)^, iop.iop_u32(out + 4)^ = 0xaaaaaaaa, 0xaaaaaaaa
		check(cd_call(cd, 83, out, out + 4) == 1, "cd type: sceCdReadDvdDualInfo returns 1")
		on_dual, start = iop.iop_u32(out)^, iop.iop_u32(out + 4)^
		o, s := dual_info()
		check(o == on_dual && s == start, "cd type: export 83 and S-command 0x27 agree")
		return
	}
	// sceCdLayerSearchFile's result and the record's lsn, written over
	// 0xaaaaaaaa.
	search :: proc(cd, file, name, layer: u32) -> (found, lsn: u32) {
		iop.iop_u32(file)^ = 0xaaaaaaaa
		found = cd_call(cd, 84, file, name, layer)
		return found, iop.iop_u32(file)^
	}

	V :: discimg.VOLUME
	udf := discimg.make_iso(discimg.CNF_PS2, udf = true)
	plain := discimg.make_iso(discimg.CNF_PS2)

	// Dual layer with UDF: a DVD; layer 1, or any nonzero one, the second.
	two := make([]u8, 2 * len(udf), context.temp_allocator)
	copy(two, udf)
	copy(two[len(udf):], udf)
	open_img(dir, "dl.iso", two)
	check(kind(cd) == iop.CD_DISK_PS2_DVD, "cd type: a dual-layer UDF image is a PS2 DVD")
	on_dual, start := dual(cd, b + out)
	check(on_dual == 1 && start == V, "cd type: a dual-layer DVD's second layer start")
	found, lsn := search(cd, b + file, b + big, 0)
	check(found == 1 && lsn == 23, "cd type: LayerSearchFile layer 0")
	found, lsn = search(cd, b + file, b + big, 1)
	rec := iop.iop_mem(b + file, iop.CD_FILE)
	check(found == 1 && lsn == V + 23 && endian.unchecked_get_u32le(rec[4:]) == discimg.BIG && string(rec[8:17]) == "BIG.BIN;1", "cd type: LayerSearchFile layer 1, its record")
	found, lsn = search(cd, b + file, b + big, 3)
	check(found == 1 && lsn == V + 23, "cd type: LayerSearchFile, any nonzero layer the second")
	found, lsn = search(cd, b + file, b + nope, 1)
	check(found == 0 && lsn == 0xaaaaaaaa, "cd type: LayerSearchFile, a miss returns 0 and writes nothing")
	iop.iop_u32(b + file)^ = 0xaaaaaaaa
	check(cd_call(cd, 10, b + file, b + big) == 1 && iop.iop_u32(b + file)^ == 23, "cd type: sceCdSearchFile searches layer 0")

	// One layer with UDF, 11 sectors past its volume: a DVD of that count.
	one := make([]u8, (V + 11) * SECTOR, context.temp_allocator)
	copy(one, udf)
	open_img(dir, "sl.iso", one)
	check(kind(cd) == iop.CD_DISK_PS2_DVD, "cd type: a single-layer UDF image is a PS2 DVD")
	on_dual, start = dual(cd, b + out)
	check(on_dual == 0 && start == V + 11, "cd type: a single-layer DVD's sector count")

	// CD-sized, no UDF, a one-sector root: a CD, no dual info, no second layer.
	open_img(dir, "cd.iso", plain)
	check(kind(cd) == iop.CD_DISK_PS2_CD, "cd type: a CD-sized image without UDF, one-sector root, is a PS2 CD")
	on_dual, start = dual(cd, b + out)
	check(on_dual == 0 && start == 0, "cd type: a CD's dual info is zeros")
	found, lsn = search(cd, b + file, b + big, 0)
	check(found == 1 && lsn == 23, "cd type: LayerSearchFile layer 0 on a CD")
	found, lsn = search(cd, b + file, b + big, 1)
	check(found == 0 && lsn == 0xaaaaaaaa, "cd type: a CD has no second layer")

	// The same with a root of two sectors: PCSX2's test fails, so a DVD.
	wide := slice.clone(plain, context.temp_allocator)
	endian.put_u32(wide[16 * SECTOR + 156 + 10:][:4], .Little, 2 * SECTOR)
	open_img(dir, "wide.iso", wide)
	check(kind(cd) == iop.CD_DISK_PS2_DVD, "cd type: a CD-sized image without UDF, two-sector root, is a PS2 DVD")

	// Without UDF but more sectors than a CD holds: a DVD.
	path := open_img(dir, "big.iso", plain)
	if f, ferr := os.open(path, {.Write}); ferr == nil {
		_ = os.truncate(f, (disc.CD_MAX_SECTORS + 1) * SECTOR)
		os.close(f)
	}
	check(iop.disc_image_open(path) && kind(cd) == iop.CD_DISK_PS2_DVD, "cd type: an image past a CD's sectors is a PS2 DVD")

	// Raw sectors: a CD, UDF or not; with an audio track, one with audio.
	open_img(dir, "raw.bin", discimg.make_raw(udf, 2))
	check(kind(cd) == iop.CD_DISK_PS2_CD, "cd type: a raw image is a PS2 CD, UDF or not")
	_ = os.write_entire_file(fmt.tprintf("%s/m2.bin", dir), discimg.make_raw(plain, 2))
	_ = os.write_entire_file(fmt.tprintf("%s/a.bin", dir), discimg.make_audio(4)) // small: the emu allocator is bounded
	open_img(dir, "cdda.cue", transmute([]u8)string("FILE \"m2.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\nFILE \"a.bin\" BINARY\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n"))
	check(kind(cd) == iop.CD_DISK_PS2_CDDA, "cd type: a CD with an audio track is a PS2 CDDA")
	on_dual, start = dual(cd, b + out)
	check(on_dual == 0 && start == 0, "cd type: a CDDA's dual info is zeros")

	// disc_dir: no image to judge, a PS2 DVD with no sector count.
	iop.disc_image_close()
	check(kind(cd) == iop.CD_DISK_PS2_DVD, "cd type: disc_dir is a PS2 DVD")
	on_dual, start = dual(cd, b + out)
	check(on_dual == 0 && start == 0, "cd type: disc_dir's dual info is zeros")
}

test_cdvdman :: proc() {
	dir, err := os.make_directory_temp("", "ps_iop_cd_test_*", context.allocator)
	if err != nil {
		check(false, "cdvdman: no temp directory")
		return
	}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/cd.iso", dir)
	_ = os.write_entire_file(path, discimg.make_iso(discimg.CNF_PS2))
	if !iop.disc_image_open(path) {
		check(false, "cdvdman: the image opens")
		return
	}
	defer iop.disc_image_close() // before the directory is removed
	iop.fileio_reset()

	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	// "modc": imports of cdvdman and ioman, names, a file record, a read
	// mode and a buffer of three sectors.
	a: Asm
	cdo := imports(&a, "cdvdman", ..CDVDMAN_FNOS[:])
	ioo := imports(&a, "ioman", ..IOMAN_FNOS[:])
	big := str_words(&a, "\\BIG.BIN;1")
	nope := str_words(&a, "\\NOPE.BIN;1")
	sub := str_words(&a, "cdrom0:\\DATA\\SUB.TXT;1")
	bigf := str_words(&a, "cdrom0:\\BIG.BIN;1")
	host := str_words(&a, "host:x")
	stm := str_words(&a, "cdrom_stm0:\\X;1")
	file := at(&a)
	for _ in 0 ..< iop.CD_FILE / 4 {put(&a, 0)}
	mode := at(&a)
	put(&a, 0)
	buf := at(&a)
	for _ in 0 ..< 3 * SECTOR / 4 {put(&a, 0)}
	// The callbacks: cb counts its calls and records each a0 after the
	// count, in call order; cbb waits.
	ts := imports(&a, "thbase", 24) // SleepThread
	cbw := at(&a)
	put(&a, 0, 0, 0, 0, 0, 0, 0, 0)
	cb := at(&a)
	la(&a, T0, cbw)
	put(&a, 0x8d090000, 0, 0x00095080, 0x01485021) // lw t1, 0(t0); nop; sll t2, t1, 2; addu t2, t2, t0
	put(&a, 0xad440004, 0x25290001, 0xad090000) // sw a0, 4(t2); addiu t1, t1, 1; sw t1, 0(t0)
	put(&a, JR_RA, 0x24020001) // jr ra; li v0, 1
	cbb := at(&a)
	prologue(&a)
	jal(&a, ts)
	epilogue(&a)
	entry := at(&a)
	prologue(&a)
	li(&a, V0, 0)
	epilogue(&a)
	id, res := iop.iop_load(build_mod("modc", &a, entry), "modc", nil)
	b := module_base(id)
	check(id > 0 && res == 0, "cdvdman: the module loads")
	cd, io := b + cdo, b + ioo

	check(cd_call(cd, 13, 0) == 2 && cd_call(cd, 8) == 0 && cd_call(cd, 11, 0) == 0, "cdvdman: DiskReady 2, no error, Sync done")
	check(cd_call(cd, 4, 0) == 1 && cd_call(cd, 4, 1) == 1 && cd_call(cd, 4, 5) == 1 && cd_call(cd, 4, 0xffffffff) == 1, "cdvdman: sceCdInit returns 1 for every mode")
	check(cd_call(cd, 75, 1) == 1 && cd_call(cd, 75, 2) == 1 && cd_call(cd, 75, 0xff) == 1, "cdvdman: sceCdMmode returns 1")
	check(cd_call(cd, 12) == iop.CD_DISK_PS2_CD, "cdvdman: sceCdGetDiskType is a PS2 CD on a CD-sized image without UDF")
	check(cd_call(cd, 28) == 0x0a, "cdvdman: sceCdStatus is paused")
	check(cd_call(cd, 44) == 0, "cdvdman: sceCdGetReadPos is 0 with no read")
	check(cd_call(cd, 5) == 1 && iop.iop_cd == {}, "cdvdman: sceCdStandby with no callback returns 1, no run owed")
	check(cd_call(cd, 10, b + file, b + big) == 1, "cdvdman: SearchFile finds the file")
	rec := iop.iop_mem(b + file, iop.CD_FILE)
	check(endian.unchecked_get_u32le(rec) == 23 && endian.unchecked_get_u32le(rec[4:]) == discimg.BIG && string(rec[8:17]) == "BIG.BIN;1", "cdvdman: the record's lsn, size and name")
	check(cd_call(cd, 10, b + file, b + nope) == 0 && endian.unchecked_get_u32le(rec) == 23, "cdvdman: a miss returns 0 and leaves the record")

	// Three sectors from the file's lsn, at the buffer; past the volume, zeros.
	data := iop.iop_mem(b + buf, 3 * SECTOR)
	check(cd_call(cd, 6, 23, 3, b + buf, b + mode) == 1, "cdvdman: sceCdRead returns 1")
	good := true
	for i in 0 ..< len(data) {good &&= data[i] == (i < discimg.BIG ? discimg.big_byte(i) : 0)}
	check(good, "cdvdman: the sectors read are the file's")
	check(cd_call(cd, 44) == 0, "cdvdman: sceCdGetReadPos is 0 after a read")
	for &x in data {x = 0xff}
	cd_call(cd, 6, discimg.VOLUME, 1, b + buf + SECTOR, 0)
	good = true
	for i in 0 ..< len(data) {good &&= data[i] == (i / SECTOR == 1 ? 0 : 0xff)}
	check(good, "cdvdman: a sector past the volume reads as zeros, nothing else written")
	iop.iop_u32(b + mode)^ = 0x00010000 // datapattern 1
	check(cd_call(cd, 6, 23, 1, b + buf, b + mode) == 0 && data[0] == 0xff, "cdvdman: a data pattern reads nothing")
	check(core.compat.calls[core.Compat_Key{.Iop_Cd, 1, 0}].n == 1, "cdvdman: the data pattern is a compat row")

	// sceCdCallback: a read's callback runs at the next tick, a0 1, in
	// interrupt context.
	iop.iop_u32(b + mode)^ = 0
	check(iop.iop_cd == {} && cd_call(cd, 37, b + cb) == 0 && cd_call(cd, 37, b + cb) == b + cb, "cdvdman: sceCdCallback returns the previous callback")
	check(iop.iop_cd.n_pending == 0 && iop.cd_next_ee() == max(u64), "cdvdman: no callback due before a read")
	cd_call(cd, 6, 23, 1, b + buf, b + mode)
	now := r3000.state.cycles * 8
	check(iop.iop_cd.n_pending == 1 && iop.iop_cd.pending[0] == iop.CD_FUNC_READ && iop.cd_next_ee() == now && iop.iop_wake_ee == now && iop.iop_u32(b + cbw)^ == 0, "cdvdman: a read's callback is due at once, not run in the call")
	core.snap_op, core.snap_target = .Save, &snap8
	core.snap_yield()
	if !snap8_loaded {
		iop.iop_tick(now)
		check(iop.iop_u32(b + cbw)^ == 1, "cdvdman: the callback runs")
		snap8_loaded = true
		core.snap_op, core.snap_target = .Load, &snap8
		core.snap_yield()
	}
	check(iop.iop_cd == {callback = b + cb, n_pending = 1, pending = {iop.CD_FUNC_READ, 0, 0, 0}} && iop.iop_u32(b + cbw)^ == 0, "cdvdman: the load restores the pending callback")
	iop.iop_tick(now)
	check(iop.iop_u32(b + cbw)^ == 1 && iop.iop_u32(b + cbw + 4)^ == iop.CD_FUNC_READ && iop.iop_cd.n_pending == 0 && iop.cd_next_ee() == max(u64), "cdvdman: the callback runs once, a0 the read's code")

	// Read, read, standby: one run each, in the order made, at one tick;
	// a fifth command with four owed is dropped with a row.
	iop.iop_u32(b + cbw)^ = 0
	cd_call(cd, 6, 23, 1, b + buf, b + mode)
	cd_call(cd, 6, 23, 1, b + buf, b + mode)
	check(cd_call(cd, 5) == 1 && iop.iop_cd.n_pending == 3 && iop.iop_u32(b + cbw)^ == 0, "cdvdman: three commands owe three runs, none run in the call")
	iop.iop_tick(r3000.state.cycles * 8)
	runs := iop.iop_mem(b + cbw, 16)
	check(endian.unchecked_get_u32le(runs) == 3 && endian.unchecked_get_u32le(runs[4:]) == iop.CD_FUNC_READ && endian.unchecked_get_u32le(runs[8:]) == iop.CD_FUNC_READ && endian.unchecked_get_u32le(runs[12:]) == iop.CD_FUNC_STANDBY, "cdvdman: read, read, standby run 3 times in order")
	check(iop.iop_cd.n_pending == 0 && iop.cd_next_ee() == max(u64), "cdvdman: none owed after the tick")
	iop.iop_u32(b + cbw)^ = 0
	for _ in 0 ..< iop.CD_PENDING {cd_call(cd, 6, 23, 1, b + buf, b + mode)}
	check(cd_call(cd, 5) == 1 && iop.iop_cd.n_pending == iop.CD_PENDING, "cdvdman: a command past the runs owed is still accepted")
	check(core.compat.calls[core.Compat_Key{.Iop_Cd_Intr, b + cb, iop.CD_FUNC_STANDBY}].n == 1, "cdvdman: its run is dropped with a row")
	iop.iop_tick(r3000.state.cycles * 8)
	check(iop.iop_u32(b + cbw)^ == iop.CD_PENDING && iop.iop_u32(b + cbw + 4 * iop.CD_PENDING)^ == iop.CD_FUNC_READ, "cdvdman: the runs owed are made, the dropped one not")

	iop.iop_u32(b + mode)^ = 0x00010000
	cd_call(cd, 6, 23, 1, b + buf, b + mode)
	check(iop.iop_cd.n_pending == 0, "cdvdman: a read refused for its data pattern has no callback")
	iop.iop_u32(b + mode)^ = 0
	cd_call(cd, 37, 0)
	cd_call(cd, 6, 23, 1, b + buf, b + mode)
	check(iop.iop_cd.n_pending == 0, "cdvdman: no callback set, none due")
	// A callback that sleeps gets -100 and returns, no row; the next owed runs.
	cd_call(cd, 37, b + cbb)
	cd_call(cd, 6, 23, 1, b + buf, b + mode)
	cd_call(cd, 5)
	iop.iop_tick(r3000.state.cycles * 8)
	check(core.compat.calls[core.Compat_Key{.Iop_Cd_Intr, b + cbb, 0}].n == 0 && iop.iop_cd.n_pending == 0, "cdvdman: a callback that sleeps is no row, each run")

	// "modk" sets its own callback, reads, then fails: modc's put back, the
	// load's run dropped; a run owed before the load stays.
	cd_call(cd, 37, b + cb)
	k: Asm
	kcd := imports(&k, "cdvdman", 6, 37)
	ksm := imports(&k, "sysmem", 99)
	kh := at(&k)
	put(&k, JR_RA, 0)
	entry = at(&k)
	prologue(&k)
	la(&k, A0, kh)
	jal(&k, kcd + 8)
	li(&k, A0, 23)
	li(&k, A1, 0)
	li(&k, A2, 0)
	li(&k, A3, 0)
	jal(&k, kcd)
	jal(&k, ksm)
	epilogue(&k)
	check(load_buffer(build_mod("modk", &k, entry)) == {2, 0} && iop.iop_cd == {callback = b + cb}, "cdvdman: modk falls back, modc's callback put back, nothing pending")
	cd_call(cd, 6, 23, 1, b + buf, b + mode)
	saved := iop.iop_cd
	check(load_buffer(build_mod("modk", &k, entry)) == {2, 0} && iop.iop_cd == saved && saved.n_pending == 1, "cdvdman: modk fails with a run owed before it, which stays")
	iop.iop_u32(b + cbw)^ = 0
	iop.iop_tick(r3000.state.cycles * 8)
	check(iop.iop_u32(b + cbw)^ == 1 && iop.iop_u32(b + cbw + 4)^ == iop.CD_FUNC_READ && iop.iop_cd.n_pending == 0, "cdvdman: it runs once with modc's callback, its own code")

	// ioman, over fileio's files.
	fd := io_call(io, 4, b + sub, 1)
	check(fd == 0, "ioman: open gets the first fd")
	check(io_call(io, 6, fd, b + buf, 4) == 4 && string(data[:4]) == "sub ", "ioman: read")
	check(io_call(io, 8, fd, 0, 1) == 4 && io_call(io, 8, fd, neg(3), 2) == 7, "ioman: lseek from the position and the end")
	check(io_call(io, 6, fd, b + buf, 10) == 3 && string(data[:3]) == "e!\n", "ioman: a read stops at the end")
	check(io_call(io, 8, fd, 2, 0) == 2 && io_call(io, 8, fd, 0, 3) == neg(22), "ioman: lseek from the start; a bad whence")
	fd2 := io_call(io, 4, b + bigf, 1)
	check(fd2 == 1 && io_call(io, 8, fd2, 100, 0) == 100, "ioman: a second file gets the next fd")
	check(io_call(io, 6, fd2, b + buf, 3 * SECTOR) == discimg.BIG - 100, "ioman: a read over sectors gets the rest of the file")
	good = true
	for i in 0 ..< discimg.BIG - 100 {good &&= data[i] == discimg.big_byte(100 + i)}
	check(good, "ioman: the bytes read over sectors are the file's")
	check(io_call(io, 5, fd) == 0 && io_call(io, 5, fd) == neg(9) && io_call(io, 6, fd, b + buf, 1) == neg(9), "ioman: close; a closed fd is bad")
	check(io_call(io, 4, b + sub, 1) == fd, "ioman: a closed fd is reused")
	iop.fileio_reset() // the EE's files
	check(io_call(io, 6, fd2, b + buf, 1) == neg(9), "ioman: fileio's table is the same")
	check(io_call(io, 4, b + sub, 2) == neg(2), "ioman: a write open fails as fileio's")
	check(io_call(io, 4, b + host, 1) == neg(19), "ioman: another device is not here")
	dev := [4]u8{'h', 'o', 's', 't'}
	check(core.compat.calls[core.Compat_Key{.Iop_Io, transmute(u32)dev, 0}].n == 1, "ioman: another device is a compat row")
	// cdvdstm's stream device is not served: an open fails with the same
	// row, named by the device's first four bytes.
	stm_dev := [4]u8{'c', 'd', 'r', 'o'}
	check(io_call(io, 4, b + stm, 1) == neg(19) && core.compat.calls[core.Compat_Key{.Iop_Io, transmute(u32)stm_dev, 0}].n == 1, "ioman: the stream device is not here, a compat row")
}

mem_eq :: proc(x, y, n: u32) -> bool {
	for i: u32 = 0; i < n; i += 4 {
		if iop.iop_u32(x + i)^ != iop.iop_u32(y + i)^ {return false}
	}
	return true
}

// LOADFILE's LoadModuleBuffer of IRX file `f`, put in IOP RAM: its reply.
load_buffer :: proc(f: []u8) -> [2]u32 {
	at := iop.sys_alloc(.High, u32(len(f)))
	copy(iop.iop_mem(at, u32(len(f))), f)
	buf: [0x208]u8
	w := ([^]u32)(&buf)
	w[0] = at
	iop.sif.servers[0x80000006](6, buf[:], 0)
	iop.sys_free(at)
	return {w[0], w[1]}
}

snap6: core.Snapshot
snap6_loaded: bool // not emulated state

ori :: proc(a: ^Asm, rt, imm: u32) {put(a, 0x34000000 | rt << 16 | imm)} // ori rt, zero, imm

// sdrdrv's SetUserCommandFunction: the slot is bits 4-7 of a command in
// 0x9000..0x90f0, the previous handler returned, -1 out of range; an EE
// RPC to a set slot is a row and answers 0, and none without PS_IRX; the
// EE's callback init and quit answer 0 with no row, a transfer interrupt
// handler stays unknown; the slots survive a snapshot, the loader's reset clears them, and a failed
// load puts back the ones it replaced.
test_sdrdrv :: proc() {
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	a: Asm
	sdr := imports(&a, "sdrdrv", 5)
	h := at(&a)
	put(&a, JR_RA, 0)
	entry := at(&a)
	put(&a, JR_RA, 0x24020000)
	id, _ := iop.iop_load(build_mod("modr", &a, entry), "modr", nil)
	b := module_base(id)
	set :: proc(stub, cmd, f: u32) -> u32 {return lib_call(stub, {5}, 5, cmd, f)}
	check(id > 0 && set(b + sdr, 0x9000, b + h) == 0, "sdrdrv: slot 0 set, none before")
	check(set(b + sdr, 0x9001, 0x1234) == b + h && iop.iop_sdr.user[0] == 0x1234, "sdrdrv: 0x9001 is slot 0, the previous handler returned")
	check(set(b + sdr, 0x90f0, b + h) == 0 && iop.iop_sdr.user[15] == b + h, "sdrdrv: 0x90f0 is slot 15")
	check(set(b + sdr, 0x90f1, 7) == 0xffffffff && set(b + sdr, 0x8fff, 7) == 0xffffffff && set(b + sdr, 0x9100, 7) == 0xffffffff && set(b + sdr, 0, 7) == 0xffffffff, "sdrdrv: out of range -1")
	check(iop.iop_sdr.user[15] == b + h && iop.iop_sdr.user[0] == 0x1234, "sdrdrv: out of range sets nothing")
	check(iop.sdr_user_handler(0x90f3) == b + h && iop.sdr_user_handler(0x9010) == 0 && iop.sdr_user_handler(0x9100) == 0, "sdrdrv: an RPC's handler by bits 4-15")

	// The EE's RPC: a row naming the command, the reply 0.
	buf: [64]u8
	w := ([^]u32)(&buf)
	w[0], w[1] = 0x55, 0x66
	key := core.Compat_Key{.Iop_Sdr, 0x90f0, 0}
	clear(&core.compat.calls)
	check(iop.sif.servers[0x80000701](0x90f0, buf[:], 64) && w[0] == 0 && core.compat.calls[key].n == 1, "sdrdrv: an RPC to a set slot is a row, the reply 0")
	iop.sif.servers[0x80000701](0x9010, buf[:], 64)
	check(len(core.compat.calls) == 1, "sdrdrv: an RPC to an empty slot is no row")
	iop.iop_irx = false
	iop.sif.servers[0x80000701](0x90f0, buf[:], 64)
	check(core.compat.calls[key].n == 1, "sdrdrv: none without PS_IRX")
	iop.iop_irx = true

	// The EE's callback init and quit answer 0, no row; arming a transfer
	// interrupt handler is still one.
	clear(&core.compat.calls)
	w[0] = 0x55
	check(iop.sif.servers[0x80000701](0xe620, buf[:], 64) && w[0] == 0 && iop.sif.servers[0x80000701](0xe630, buf[:], 64) && len(core.compat.calls) == 0, "sdrdrv: callback init and quit answer 0, no row")
	w[1], w[2] = 0, 0x1234
	check(!iop.sif.servers[0x80000701](0x8160, buf[:], 64), "sdrdrv: a transfer interrupt handler is unknown")

	core.snap_op, core.snap_target = .Save, &snap6
	core.snap_yield()
	if !snap6_loaded {
		set(b + sdr, 0x90f0, 0)
		snap6_loaded = true
		core.snap_op, core.snap_target = .Load, &snap6
		core.snap_yield()
	}
	check(iop.iop_sdr.user[15] == b + h && iop.iop_sdr.user[0] == 0x1234, "sdrdrv: the load restores the slots")

	// "modu" sets slot 0, over modr's, and slot 2, then fails.
	u: Asm
	usd := imports(&u, "sdrdrv", 5)
	usm := imports(&u, "sysmem", 99)
	uh := at(&u)
	put(&u, JR_RA, 0)
	entry = at(&u)
	prologue(&u)
	for cmd in ([2]u32{0x9000, 0x9020}) {
		ori(&u, A0, cmd)
		la(&u, A1, uh)
		jal(&u, usd)
	}
	jal(&u, usm)
	epilogue(&u)
	check(load_buffer(build_mod("modu", &u, entry)) == {2, 0}, "sdrdrv: modu falls back")
	check(iop.iop_sdr.user[0] == 0x1234 && iop.iop_sdr.user[2] == 0 && iop.iop_sdr.user[15] == b + h, "sdrdrv: its slots put back, modr's kept")

	fresh()
	check(iop.iop_sdr == {}, "sdrdrv: the loader's reset clears the slots")
}

snap11: core.Snapshot
snap11_loaded: bool // not emulated state

// "modk": slots 0 and 1 set to a handler that logs the command and the
// request's second word, waits on its semaphore (id 1) for 0x9010, and
// returns 0x5a5a. The module's base, the log's offset and sdrdrv's stub.
mod_k :: proc() -> (b, logp, sdr: u32) {
	a: Asm
	sdr = imports(&a, "sdrdrv", 5)
	ts := imports(&a, "thsemap", 4, 8)
	logp = log_words(&a, 16)
	sem := at(&a)
	put(&a, 0)
	semp := sema_param(&a, 0, 0)
	h := at(&a)
	prologue(&a)
	la(&a, T0, logp)
	put(&a, 0x8d090000, 0x8caa0004, 0xad240000, 0xad2a0004, 0x25290008, 0xad090000) // lw t1, 0(t0); lw t2, 4(a1); sw a0, 0(t1); sw t2, 4(t1); addiu t1, t1, 8; sw t1, 0(t0)
	ori(&a, T2, 0x9010)
	l := bne(&a, A0, T2)
	lw_at(&a, A0, sem)
	jal(&a, ts + 8)
	branch_to(&a, l)
	ori(&a, V0, 0x5a5a)
	epilogue(&a)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, ts, semp, sem)
	for cmd in ([2]u32{0x9000, 0x9010}) {
		ori(&a, A0, cmd)
		la(&a, A1, h)
		jal(&a, sdr)
	}
	li(&a, V0, 0)
	epilogue(&a)
	id, _ := iop.iop_load(build_mod("modk", &a, entry), "modk", nil)
	check(id > 0 && iop.iop_sdr.user[0] != 0 && iop.iop_sdr.user[1] != 0, "sdrdrv thread: modk sets slots 0 and 1")
	return module_base(id), logp, sdr
}

// Conditions: the EE's first sdrdrv RPC after a handler is set starts the
// sdrdrv thread, never during a load; from there each RPC runs on it in the
// order sent: a handler that waits holds back its RPC_END and the calls
// behind it, and both survive a snapshot; a slot cleared since is not
// called; a host command's reply bytes are those of the host path. With no
// memory the host answers on, the row each call; without PS_IRX nothing
// starts.
test_sdr_thread :: proc() {
	fresh()
	clear(&core.compat.calls)
	iop.iop_irx = true
	defer iop.iop_irx = false
	drop_replies()
	defer drop_replies()
	cpu.state.cycles = 0
	cpu.next_event = 1 << 40
	EE_RECV :: 0x00100400
	// The EE client every call is made from, which the rows name.
	EE_CLIENT :: 0x00100600
	call :: proc(rec, fno, size, recv, rsize, sd: u32) {
		send_pkt(iop.SIF_CMD_RPC_CALL, rec, 0, 0, EE_CLIENT, fno, size, recv, rsize, 0, sd)
	}
	bind :: proc() -> u32 {
		send_pkt(iop.SIF_CMD_RPC_BIND, 1, 0, 0, 0, iop.SDR_SID)
		hsd := reply_word(0, 9)
		drop_replies()
		iop.iop_u32(hsd + 0x104)^ = 0x77
		return hsd
	}
	d := &iop.iop_sdr
	s := &iop.iop_rpc
	b, logp, sdr := mod_k()
	check(d.thread == 0 && s.n_servers == 0, "sdrdrv thread: none when the handlers are set")
	hsd := bind()
	check(len(core.compat.calls) == 0, "sdrdrv thread: the bind is no row")

	// A user command: the handler runs on the thread with the request; the
	// reply its result, the rest of the first 64 bytes 0.
	iop.iop_u32(hsd + 0x100)^ = 0x11
	mem.wr32(EE_RECV + 4, 0xffffffff)
	call(1, 0x9003, 8, EE_RECV, 8, hsd)
	t := iop.th_find(d.thread)
	check(t != nil && t.prio == iop.SDR_PRIO && s.n_servers == 1 && s.servers[0].sid == iop.SDR_SID, "sdrdrv thread: the first call starts it, the server on it")
	check(log_equal(b, logp, {0x9003, 0x77}) && mem.rd32(EE_RECV) == 0x5a5a && mem.rd32(EE_RECV + 4) == 0, "sdrdrv thread: the handler gets the command and the request, the EE its result")
	check(call_ends(hsd, 1) && len(core.compat.calls) == 0, "sdrdrv thread: RPC_END, no row")
	drop_replies()

	// 0x9010 waits in the handler; a host command made meanwhile waits
	// behind it.
	call(2, 0x9010, 8, EE_RECV, 4, hsd)
	mem.wr32(EE_RECV + 0x10, 0xffffffff)
	iop.iop_u32(hsd + 0x100)^ = 0x33
	call(3, 0x80f0, 8, EE_RECV + 0x10, 4, hsd)
	want := []u32{0x9003, 0x77, 0x9010, 0x77}
	check(log_equal(b, logp, want) && len(iop.sif.replies) == 0 && s.n_reqs == 1 && mem.rd32(EE_RECV + 0x10) == 0xffffffff, "sdrdrv thread: a call while the handler waits is queued, no RPC_END yet")
	// Not a call that waits for the last one's end: a busy row, and its bytes
	// are in the buffer the handler is still reading, as the EE's write
	// would put them on retail.
	sbuf := iop.iop_u32(s.servers[0].sd + 8)^
	check(core.compat.calls[{.Iop_Rpc_Busy, iop.SDR_SID, 0x80f0}].n == 1 && core.compat.calls[{.Iop_Rpc_Busy, iop.SDR_SID, 0x9010}].n == 0, "sdrdrv thread: a call while the handler waits is a busy row")
	check(iop.iop_u32(sbuf)^ == 0x33, "sdrdrv thread: its bytes land in the buffer the handler reads")
	core.snap_op, core.snap_target = .Save, &snap11
	core.snap_yield()
	if !snap11_loaded {
		ids, _ := iop.iop_load(mod_s(), "mods", nil)
		check(ids > 0 && call_ends(hsd, 2, 3) && mem.rd32(EE_RECV + 0x10) == 1, "sdrdrv thread: the signal ends 0x9010, then the host command runs")
		drop_replies()
		snap11_loaded = true
		core.snap_op, core.snap_target = .Load, &snap11
		core.snap_yield()
	}
	drop_replies()
	check(log_equal(b, logp, want) && s.n_reqs == 1 && d.thread == t.id, "sdrdrv thread: the snapshot keeps the waiting call and the queued one")
	ids, _ := iop.iop_load(mod_s(), "mods", nil)
	check(ids > 0 && call_ends(hsd, 2, 3) && mem.rd32(EE_RECV) == 0x5a5a && mem.rd32(EE_RECV + 0x10) == 1, "sdrdrv thread: after the load both end as before")
	drop_replies()

	// Slot 0 cleared: 0x9000 is a host command, no handler called, no row.
	row := core.Compat_Key{.Iop_Sdr, 0x9000, 0}
	lib_call(b + sdr, {5}, 5, 0x9000, 0)
	mem.wr32(EE_RECV, 0xffffffff)
	call(4, 0x9000, 8, EE_RECV, 4, hsd)
	check(log_equal(b, logp, want) && mem.rd32(EE_RECV) == 0 && core.compat.calls[row].n == 0 && call_ends(hsd, 4), "sdrdrv thread: a slot cleared since is a host command, no handler called")
	drop_replies()

	// A host command's reply: the bytes the host path gives.
	req: [0x80]u8
	for &x, i in req {x = u8(i * 7 + 3)}
	(^u32)(&req[4])^ = 0
	copy(iop.iop_mem(hsd + 0x100, 0x80), req[:])
	host := req
	iop.sif.servers[iop.SDR_SID](0x8100, host[:], 0x80)
	call(5, 0x8100, 0x80, EE_RECV, 0x80, hsd)
	check(call_ends(hsd, 5) && string(mem.ram_slice(EE_RECV, 0x80)) == string(host[:]), "sdrdrv thread: a host command's reply bytes are the host path's")
	drop_replies()

	// Host commands as retail picks them, by fno & 0xfff0. `req` is the EE's
	// request words; the reply's words come back.
	clear(&core.compat.calls)
	host_cmd :: proc(rec, fno, hsd: u32, req: []u32, rsize: u32 = 0x40) -> []u32 {
		for x, i in req {iop.iop_u32(hsd + 0x100 + u32(i) * 4)^ = x}
		for i in u32(0) ..< rsize / 4 {mem.wr32(EE_RECV + i * 4, 0xffffffff)}
		call(rec, fno, max(0x40, u32(len(req)) * 4), EE_RECV, rsize, hsd)
		return ([^]u32)(raw_data(mem.ram_slice(EE_RECV, rsize)))[:rsize / 4]
	}
	zero :: proc(w: []u32) -> bool {
		for x in w {if x != 0 {return false}}
		return true
	}
	// 0x8131: sceSdSetEffectAttr on core 1, the attr the request; 0x8141
	// reads it back, the attr the reply. Core 0 stays as it was.
	r := host_cmd(8, 0x8131, hsd, {0, 7, 0x2345_1234, 0x40, 0x50})
	check(call_ends(hsd, 8) && zero(r), "sdrdrv thread: 0x8131 sets core 1's effect, result 0")
	drop_replies()
	r = host_cmd(9, 0x8141, hsd, {})
	check(call_ends(hsd, 9) && r[0] == 1 && r[1] == 7 && r[2] == 0x2345_1234 && r[3] == 0x40 && r[4] == 0x50 && zero(r[5:]), "sdrdrv thread: 0x8141 answers core 1's effect attr")
	drop_replies()
	r = host_cmd(10, 0x8140, hsd, {})
	check(call_ends(hsd, 10) && r[0] == 0 && r[1] == 0 && r[3] == 0, "sdrdrv thread: 0x8140 answers core 0's, untouched")
	drop_replies()
	// 0x8070: sceSdSetCoreAttr {?, entry, value}, entry and value u16: the
	// high bits are not read. Entry 3 is core 1's effect enable; 0x40 is none,
	// libsd's row.
	host_cmd(11, 0x8070, hsd, {0, 0xffff_0003, 0x1_0001})
	check(call_ends(hsd, 11) && len(core.compat.calls) == 0, "sdrdrv thread: 0x8070 sets a core attr, no row")
	drop_replies()
	host_cmd(16, 0x8070, hsd, {0, 0x40, 1})
	check(call_ends(hsd, 16) && core.compat.calls[{.Iop_Sd, 0x40, 11}].n == 1, "sdrdrv thread: 0x8070 with an entry libsd does not know, its row")
	drop_replies()
	clear(&core.compat.calls)
	// 0x8101: sceSdBlockTransStatus with the half bit, as libsd's.
	host_cmd(12, 0x80e0, hsd, {0, 1, 0x13, 0x30000, 0x4000, 0x32004})
	r = host_cmd(13, 0x8101, hsd, {0, 1, 0})
	check(call_ends(hsd, 12, 13) && r[0] == 0x32004 | 1 << 24 && zero(r[1:]), "sdrdrv thread: 0x8101 answers the position and the half")
	drop_replies()
	host_cmd(14, 0x80e0, hsd, {0, 1, 2})
	drop_replies()
	// A command sdrdrv does not know: answered 0, and a row.
	r = host_cmd(15, 0x81e0, hsd, {0, 1, 2})
	unk := core.compat.calls[{.Sif_Rpc, iop.SDR_SID, 0x81e0}]
	check(call_ends(hsd, 15) && zero(r) && unk.n == 1, "sdrdrv thread: an unknown command answers 0, a row")
	check(unk.client == EE_CLIENT && unk.pc == 0 && unk.ra == 0, "sdrdrv thread: the row names the EE client, no IOP pc")
	drop_replies()
	clear(&core.compat.calls)
	// The longest reply the EE asks, retail's int[384]: the result, then 0s,
	// none of the request's bytes nor any past the area.
	junk: [iop.SDR_BUF / 4]u32
	for &x, i in junk {x = 0x5a00_0000 | u32(i)}
	junk[0] = 0
	r = host_cmd(17, 0x80f0, hsd, junk[:], iop.SDR_RET)
	check(call_ends(hsd, 17) && r[0] == 1 && zero(r[1:]), "sdrdrv thread: a reply of SDR_RET bytes is the result, then 0s")
	drop_replies()
	// A user command's too, whatever the area held before: 0x9010 waits in
	// its handler until mod_s loads.
	res := sbuf - iop.SDR_BUF_AT + iop.SDR_RES
	for i in u32(0) ..< iop.SDR_RET / 4 {iop.iop_u32(res + i * 4)^ = 0xa5a5_a5a5}
	for i in u32(0) ..< iop.SDR_RET / 4 {mem.wr32(EE_RECV + i * 4, 0xffffffff)}
	call(18, 0x9010, 8, EE_RECV, iop.SDR_RET, hsd)
	ids, _ = iop.iop_load(mod_s(), "mods", nil)
	r = ([^]u32)(raw_data(mem.ram_slice(EE_RECV, iop.SDR_RET)))[:iop.SDR_RET / 4]
	check(ids > 0 && call_ends(hsd, 18) && r[0] == 0x5a5a && zero(r[1:]), "sdrdrv thread: a user command's reply of SDR_RET bytes is its result, then 0s")
	drop_replies()

	// During a load nothing starts; the call after does.
	fresh()
	iop.iop_irx = true
	clear(&core.compat.calls)
	b, logp, _ = mod_k()
	hsd = bind()
	iop.iop_loader.loading = 9
	call(6, 0x9000, 8, EE_RECV, 4, hsd)
	iop.iop_loader.loading = 0
	check(d.thread == 0 && core.compat.calls[row].n == 1 && call_ends(hsd, 6), "sdrdrv thread: not started during a load, the host answers with the row")
	check(core.compat.calls[row].client == EE_CLIENT && core.compat.calls[row].pc == d.user[0] && iop.sif.call_client == 0, "sdrdrv thread: the host's row names the handler and the EE client, the client cleared after")
	drop_replies()
	iop.iop_u32(hsd + 0x104)^ = 0x77 // the host's reply zeroed it
	call(7, 0x9000, 8, EE_RECV, 4, hsd)
	check(d.thread != 0 && log_equal(b, logp, {0x9000, 0x77}) && core.compat.calls[row].n == 1 && call_ends(hsd, 7), "sdrdrv thread: the call after the load starts it")
	drop_replies()

	// No memory: the host answers on, the row each call.
	fresh()
	iop.iop_irx = true
	clear(&core.compat.calls)
	b, logp, _ = mod_k()
	hsd = bind()
	for iop.sys_alloc(.Low, iop.SYS_ALIGN) != 0 {}
	call(8, 0x9000, 8, EE_RECV, 4, hsd)
	call(9, 0x9000, 8, EE_RECV, 4, hsd)
	check(d.thread == 0 && d.failed && s.n_servers == 0 && core.compat.calls[row].n == 2 && call_ends(hsd, 8, 9), "sdrdrv thread: no memory, the host answers with the row each call")
	drop_replies()

	// Without PS_IRX nothing starts.
	fresh()
	iop.iop_irx = true
	clear(&core.compat.calls)
	b, logp, _ = mod_k()
	hsd = bind()
	iop.iop_irx = false
	call(10, 0x9000, 8, EE_RECV, 4, hsd)
	iop.iop_irx = true
	check(d.thread == 0 && log_equal(b, logp, {}) && call_ends(hsd, 10), "sdrdrv thread: none without PS_IRX")
	drop_replies()
	fresh()
	clear(&core.compat.calls)
}

// Conditions: a failed start is answered as a module not run, with a row;
// it leaves no handler, fd or block transfer in the memory its undo frees;
// a module importing a library of a failed one fails and falls back too.
test_fallback :: proc() {
	dir, err := os.make_directory_temp("", "ps_iop_fb_test_*", context.allocator)
	if err != nil {
		check(false, "fallback: no temp directory")
		return
	}
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/cd.iso", dir)
	_ = os.write_entire_file(path, discimg.make_iso(discimg.CNF_PS2))
	if !iop.disc_image_open(path) {
		check(false, "fallback: the image opens")
		return
	}
	defer iop.disc_image_close() // before the directory is removed
	iop.fileio_reset()
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	l := &iop.iop_loader

	// The reply: {2, 0} as without PS_IRX, then a refusal answers the same.
	z: Asm
	sm := imports(&z, "sysmem", 99)
	entry := at(&z)
	prologue(&z)
	jal(&z, sm)
	epilogue(&z)
	fz := build_mod("modx", &z, entry)
	back := core.Compat_Key{.Iop_Fallback, core.compat_name("modx"), 0}
	clear(&core.compat.calls) // earlier tests' fallbacks
	check(!core.compat_line().fallback, "fallback: no compat line says so before")
	check(load_buffer(fz) == {2, 0} && core.compat.calls[back].n == 1, "fallback: a failed start replies {2, 0} with a row")
	check(core.compat_line().fallback, "fallback: the compat line says so")
	check(load_buffer(fz) == {2, 0} && core.compat.calls[back].n == 2, "fallback: a refused retry replies the same, another count")
	fa, _ := mod_a()
	r := load_buffer(fa)
	check(r[0] >= 3 && r[1] == 0, "fallback: a start that returns replies its id")

	// "modo", resident, holds an fd open; "modh"'s start sets sifcmd and
	// libsd handlers in itself, one over modo's, starts a block transfer
	// from its buffer, opens a file, then calls what the HLE lacks.
	fresh()
	iop.iop_irx = true
	o: Asm
	ioo := imports(&o, "ioman", ..IOMAN_FNOS[:])
	sub := str_words(&o, "cdrom0:\\DATA\\SUB.TXT;1")
	ow := at(&o)
	put(&o, 0)
	oh := at(&o)
	put(&o, JR_RA, 0)
	entry = at(&o)
	put(&o, JR_RA, 0x24020000)
	ido, _ := iop.iop_load(build_mod("modo", &o, entry), "modo", nil)
	ob := module_base(ido)
	fd := io_call(ob + ioo, 4, ob + sub, 1)
	check(ido > 0 && fd == 0, "fallback: modo loads and opens fd 0")
	iop.iop_sifcmd.sys[6] = {ob + oh, 7}

	h: Asm
	sc := imports(&h, "sifcmd", 8, 10)
	lsd := imports(&h, "libsd", 18, 26)
	hio := imports(&h, "ioman", 4)
	hsm := imports(&h, "sysmem", 99)
	big := str_words(&h, "cdrom0:\\BIG.BIN;1")
	tab := at(&h)
	put(&h, 0, 0, 0, 0)
	hh := at(&h)
	put(&h, JR_RA, 0)
	buf := at(&h)
	for _ in 0 ..< 0x40 {put(&h, 0)}
	entry = at(&h)
	put(&h, 0x27bdffe0, 0xafbf0000) // addiu sp, sp, -32; sw ra, 0(sp)
	la(&h, A0, tab)
	li(&h, A1, 2)
	jal(&h, sc)
	for cid in ([3]u32{0x80000005, 0x80000006, 1}) {
		if cid & 0x80000000 != 0 {
			put(&h, 0x3c040000 | 0x8000, 0x34840000 | cid & 0xffff) // lui a0, 0x8000; ori a0, a0, cid
		} else {
			li(&h, A0, cid)
		}
		la(&h, A1, hh)
		li(&h, A2, 0)
		jal(&h, sc + 8)
	}
	li(&h, A0, 0)
	la(&h, A1, hh)
	li(&h, A2, 0)
	jal(&h, lsd + 8)
	li(&h, A0, 0)
	li(&h, A1, 0)
	la(&h, A2, buf)
	li(&h, 7, 0x100)
	jal(&h, lsd)
	la(&h, A0, big)
	li(&h, A1, 1)
	jal(&h, hio)
	jal(&h, hsm)
	put(&h, 0x8fbf0000, JR_RA, 0x27bd0020) // lw ra, 0(sp); jr ra; addiu sp, sp, 32
	fh := build_mod("modh", &h, entry)
	cos := coroutines()
	before := slice_clone(iop.sys_blocks[:])
	r = load_buffer(fh)
	back = core.Compat_Key{.Iop_Fallback, core.compat_name("modh"), 0}
	check(r == {2, 0} && core.compat.calls[back].n == 1, "fallback: modh falls back")
	check(blocks_equal(before, iop.sys_blocks[:]) && coroutines() == cos, "fallback: modh's memory and threads undone")
	sc_ := &iop.iop_sifcmd
	check(sc_.sys[5] == {} && sc_.sys[6] == {ob + oh, 7}, "fallback: its system handler dropped, modo's put back")
	check(sc_.user_tab == 0 && sc_.user_size == 0, "fallback: its user table dropped")
	check(!iop.iop_cmd_deliver(0x80000005) && !iop.iop_cmd_deliver(1), "fallback: its commands deliver nowhere")
	check(iop.iop_sd.trans[0] == {} && iop.iop_sd.pending == 0, "fallback: its libsd handler dropped")
	iop.iop_sd.trans[0] = {ob + oh, 0}
	check(iop.sd_next_ee() == max(u64), "fallback: its block transfer stopped: none due with a handler")
	iop.iop_sd.trans[0] = {}
	check(io_call(ob + ioo, 6, 1, ob + ow, 1) == neg(9), "fallback: the fd it opened closed")
	check(io_call(ob + ioo, 6, fd, ob + ow, 1) == 1, "fallback: modo's fd still open")
	iop.iop_tick(cpu.state.cycles + 1 << 30)
	check(coroutines() == cos, "fallback: no handler runs after")

	// "modq" registers liba, then fails: modb, which calls liba, fails and
	// falls back too, its stub never patched into modq's freed image.
	fresh()
	iop.iop_irx = true
	q: Asm
	lc := imports(&q, "loadcore", 6)
	qsm := imports(&q, "sysmem", 99)
	tbl, ptr := exports(&q, "liba")
	q.w[ptr] = at(&q)
	put(&q, JR_RA, 0x24020700)
	entry = at(&q)
	prologue(&q)
	la(&q, A0, tbl)
	jal(&q, lc)
	jal(&q, qsm)
	epilogue(&q)
	check(load_buffer(build_mod("modq", &q, entry)) == {2, 0} && len(l.libs) == 0, "fallback: modq falls back, liba gone")
	imp := core.Compat_Key{.Iop_Import, core.compat_name("liba"), 0}
	back = core.Compat_Key{.Iop_Fallback, core.compat_name("modb"), 0}
	n_imp, n_back := core.compat.calls[imp].n, core.compat.calls[back].n
	fb, _ := mod_b(true)
	check(load_buffer(fb) == {2, 0}, "fallback: modb, importing liba, replies {2, 0}")
	check(core.compat.calls[imp].n == n_imp + 1 && core.compat.calls[back].n == n_back + 1, "fallback: modb's call reached no export, a row each")
	check(len(l.stubs) == 0 && len(l.pending) == 0 && len(l.modules) == 0, "fallback: nothing of modb is left")
}

snap8: core.Snapshot
snap8_loaded: bool // not emulated state

snap7: core.Snapshot
snap7_loaded: bool // not emulated state

TIMR_FNOS := [?]u32{4, 6, 20, 22, 23, 24}

// timrman's ids: the timer's number from 1 in the top 4 bits, its base.
TIMER0 :: 0x1bf80110
TIMER1 :: 0x2bf80111
TIMER2 :: 0x3bf80112
TIMER3 :: 0x4bf80148
TIMER4 :: 0x5bf80149
TIMER5 :: 0x6bf8014a

// timrman: AllocHardTimer's search order and matching, FreeHardTimer, and
// each call's errors; a sysclock timer's compare handler runs at the cycle
// its compare and prescale give, its v0 the next compare, 0 stopping it; a
// timer far behind runs 16 and drops the rest; a handler that allocates
// gets -100, one that waits is stopped with a row; a 16-bit timer's compare
// is its low 16 bits, 0 a full wrap; another source is a row and never
// fires; the timers survive a snapshot, the loader's reset clears them, and
// a failed load puts back the timer it allocated.
test_timrman :: proc() {
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	// "modt": d {count, a0, next compare, an allocation's result}. h counts,
	// records a0 and returns d's next compare; ha allocates and returns 0;
	// hb waits.
	a: Asm
	tmo := imports(&a, "timrman", ..TIMR_FNOS[:])
	ts := imports(&a, "thbase", 24) // SleepThread
	d := at(&a)
	put(&a, 0, 0, 0, 0)
	h := at(&a)
	la(&a, T0, d)
	put(&a, 0x8d090000, 0, 0x25290001, 0xad090000) // lw t1, 0(t0); nop; addiu t1, t1, 1; sw t1, 0(t0)
	put(&a, 0xad040004, 0x8d020008, JR_RA, 0) // sw a0, 4(t0); lw v0, 8(t0); jr ra
	ha := at(&a)
	prologue(&a)
	li(&a, A0, 1)
	li(&a, A1, 32)
	li(&a, A2, 1)
	jal(&a, tmo)
	la(&a, T0, d)
	put(&a, 0xad02000c) // sw v0, 12(t0)
	li(&a, V0, 0)
	epilogue(&a)
	hb := at(&a)
	prologue(&a)
	jal(&a, ts)
	li(&a, V0, 100)
	epilogue(&a)
	entry := at(&a)
	put(&a, JR_RA, 0x24020000)
	id, _ := iop.iop_load(build_mod("modt", &a, entry), "modt", nil)
	b := module_base(id)
	tm :: proc(stubs, fno: u32, args: ..u32) -> u32 {return lib_call(stubs, TIMR_FNOS[:], fno, ..args)}
	t := b + tmo
	word :: proc(at: u32) -> u32 {return iop.iop_u32(at)^}
	check(id > 0 && iop.tim_next_ee() == max(u64), "timrman: the module loads, no timer due")

	check(tm(t, 4, 1, 32, 1) == TIMER5 && tm(t, 4, 1, 32, 1) == TIMER4 && tm(t, 4, 1, 32, 1) == TIMER3, "timrman: 32-bit sysclock timers in the order 5, 4, 3")
	check(tm(t, 4, 1, 32, 1) == neg(150) && tm(t, 4, 1, 32, 256) == neg(150), "timrman: none free")
	check(tm(t, 4, 1, 16, 8) == TIMER2 && tm(t, 4, 1, 16, 2) == neg(150), "timrman: timer 2 for prescale 8, none for a 16-bit prescale 2 left")
	check(tm(t, 4, 2, 16, 1) == TIMER0 && tm(t, 4, 4, 16, 1) == TIMER1, "timrman: the pixel and hline sources")
	check(tm(t, 6, 0) == neg(151) && tm(t, 6, 0x7bf80000) == neg(151), "timrman: FreeHardTimer of no timer")
	check(tm(t, 6, TIMER4) == 0 && tm(t, 6, TIMER3) == 0 && tm(t, 6, TIMER0) == 0 && tm(t, 6, TIMER1) == 0 && tm(t, 6, TIMER4) == neg(151), "timrman: FreeHardTimer, once")
	check(tm(t, 22, TIMER5, 1, 2, 1) == neg(405) && tm(t, 22, TIMER5, 1, 0, 3) == neg(153) && tm(t, 22, TIMER2, 1, 0, 16) == neg(153), "timrman: a bad mode, prescale")
	check(tm(t, 22, TIMER5, 2, 0, 1) == neg(152) && tm(t, 22, TIMER5, 3, 0, 1) == neg(152), "timrman: a source the timer lacks")
	check(tm(t, 23, TIMER5) == neg(155) && tm(t, 24, TIMER5) == neg(156), "timrman: start before setup, stop before start")

	// Timer 5 counts the sysclock at prescale 1: the handler at compare.
	check(tm(t, 20, TIMER5, 1000, b + h, 0x55) == 0 && tm(t, 22, TIMER5, 1, 0, 1) == 0, "timrman: handler set, set up")
	C :: 100_000
	r3000.state.cycles = C
	check(tm(t, 23, TIMER5) == 0 && iop.tim_next_ee() == (C + 1000) * 8 && iop.iop_wake_ee == (C + 1000) * 8, "timrman: started, the wake at its compare")
	check(tm(t, 23, TIMER5) == neg(154) && tm(t, 20, TIMER5, 5, b + h, 0) == neg(154) && tm(t, 22, TIMER5, 1, 0, 1) == neg(154), "timrman: busy while running")
	iop.iop_u32(b + d + 8)^ = 500
	iop.iop_tick((C + 999) * 8)
	check(word(b + d) == 0, "timrman: no handler before the compare")
	iop.iop_tick((C + 1000) * 8)
	check(word(b + d) == 1 && word(b + d + 4) == 0x55 && iop.tim_next_ee() == (C + 1500) * 8, "timrman: the handler at the compare, its arg in a0, its v0 the next compare")
	core.snap_op, core.snap_target = .Save, &snap7
	core.snap_yield()
	if !snap7_loaded {
		iop.iop_tick((C + 1500) * 8)
		check(word(b + d) == 2, "timrman: the next compare")
		snap7_loaded = true
		core.snap_op, core.snap_target = .Load, &snap7
		core.snap_yield()
	}
	check(word(b + d) == 1 && iop.iop_timr.t[5].due == C + 1500 && iop.iop_timr.armed == 1 << 5, "timrman: the load restores the timer")
	iop.iop_tick((C + 21_500) * 8)
	check(word(b + d) == 17 && iop.iop_timr.t[5].due == C + 22_000, "timrman: far behind, 16 run and the rest dropped, the grid kept")
	iop.iop_u32(b + d + 8)^ = 0
	iop.iop_tick((C + 22_000) * 8)
	check(word(b + d) == 18 && iop.iop_timr.armed == 0 && iop.tim_next_ee() == max(u64) && tm(t, 24, TIMER5) == neg(156), "timrman: v0 0 stops the timer")
	check(tm(t, 23, TIMER5) == 0 && iop.iop_timr.armed == 1 << 5 && tm(t, 24, TIMER5) == 0 && iop.iop_timr.armed == 0, "timrman: started again, stopped")

	// Handlers in interrupt context: an allocation is -100, and so is a sleep,
	// after which the handler's v0 keeps its timer going.
	tm(t, 20, TIMER5, 100, b + ha, 0)
	cur := r3000.state.cycles
	tm(t, 23, TIMER5)
	iop.iop_tick((cur + 100) * 8)
	check(word(b + d + 12) == neg(100) && iop.iop_timr.armed == 0, "timrman: AllocHardTimer in a handler is -100, its v0 0 stops it")
	tm(t, 20, TIMER5, 100, b + hb, 0)
	cur = r3000.state.cycles
	tm(t, 23, TIMER5)
	iop.iop_tick((cur + 100) * 8)
	check(core.compat.calls[core.Compat_Key{.Iop_Timer_Intr, b + hb, 0}].n == 0 && iop.iop_timr.armed == 1 << 5, "timrman: a handler that sleeps is no row, its v0 100 keeps the timer")
	check(tm(t, 24, TIMER5) == 0 && iop.iop_timr.armed == 0, "timrman: then stopped")

	// A 16-bit timer: the compare's low 16 bits, 0 a full count, by the prescale.
	tm(t, 20, TIMER2, 0x12345, b + h, 0)
	check(tm(t, 22, TIMER2, 1, 0, 8) == 0, "timrman: timer 2 at prescale 8")
	cur = r3000.state.cycles
	tm(t, 23, TIMER2)
	check(iop.tim_next_ee() == (cur + 0x2345 * 8) * 8, "timrman: a 16-bit compare's low bits")
	tm(t, 24, TIMER2)
	tm(t, 20, TIMER2, 0x10000, b + h, 0)
	tm(t, 23, TIMER2)
	check(iop.tim_next_ee() == (cur + 0x10000 * 8) * 8, "timrman: compare 0 counts the full 16 bits")
	tm(t, 24, TIMER2)

	// Another source: set up and started, never fires, a row.
	t0 := tm(t, 4, 2, 16, 1)
	tm(t, 20, t0, 10, b + h, 0)
	check(tm(t, 22, t0, 2, 0, 1) == 0 && core.compat.calls[core.Compat_Key{.Iop_Timer, 2, 0}].n == 1, "timrman: the pixel source is a row")
	check(tm(t, 23, t0) == 0 && iop.iop_timr.armed == 0, "timrman: started, never due")
	check(tm(t, 24, t0) == 0 && tm(t, 6, t0) == 0, "timrman: stopped, freed")

	// "modv" starts timer 4 with its handler, then fails: put back, timer 5 kept.
	iop.iop_u32(b + d + 8)^ = 500
	tm(t, 20, TIMER5, 500, b + h, 0)
	tm(t, 23, TIMER5)
	before := iop.iop_timr.t[4]
	v: Asm
	vt := imports(&v, "timrman", 4, 20, 22, 23)
	vsm := imports(&v, "sysmem", 99)
	vd := at(&v)
	put(&v, 0)
	vh := at(&v)
	put(&v, JR_RA, 0)
	entry = at(&v)
	prologue(&v)
	li(&v, A0, 1)
	li(&v, A1, 32)
	li(&v, A2, 1)
	jal(&v, vt)
	la(&v, T0, vd)
	put(&v, 0xad020000) // sw v0, 0(t0)
	la(&v, T0, vd)
	put(&v, 0x8d040000) // lw a0, 0(t0)
	li(&v, A1, 50)
	la(&v, A2, vh)
	li(&v, A3, 0)
	jal(&v, vt + 8)
	la(&v, T0, vd)
	put(&v, 0x8d040000)
	li(&v, A1, 1)
	li(&v, A2, 0)
	li(&v, A3, 1)
	jal(&v, vt + 16)
	la(&v, T0, vd)
	put(&v, 0x8d040000)
	jal(&v, vt + 24)
	jal(&v, vsm)
	epilogue(&v)
	check(load_buffer(build_mod("modv", &v, entry)) == {2, 0}, "timrman: modv falls back")
	check(iop.iop_timr.t[4] == before && iop.iop_timr.armed == 1 << 5 && iop.iop_timr.t[5].handler == b + h, "timrman: its timer put back, modt's kept")

	fresh()
	check(iop.iop_timr == {} && iop.tim_next_ee() == max(u64), "timrman: the loader's reset clears the timers")
}

// thbase 43 GetSystemTimeLow: the low word of what 34 GetSystemTime gives,
// tracking the IOP's clock past 32 bits.
test_system_time :: proc() {
	fresh()
	fnos := [?]u32{34, 43}
	a: Asm
	tb := imports(&a, "thbase", ..fnos[:])
	d := at(&a)
	put(&a, 0, 0)
	entry := at(&a)
	put(&a, JR_RA, 0x24020000)
	id, _ := iop.iop_load(build_mod("mods", &a, entry), "mods", nil)
	b := module_base(id)
	C :: u64(0x1_2345_6789)
	r3000.state.cycles = C
	check(id > 0 && lib_call(b + tb, fnos[:], 34, b + d) == 0, "thbase: GetSystemTime")
	lo, hi := iop.iop_u32(b + d)^, iop.iop_u32(b + d + 4)^
	check(lo == 0x2345_6789 && hi == 1 && lib_call(b + tb, fnos[:], 43) == lo, "thbase: GetSystemTimeLow is GetSystemTime's low word")
	r3000.state.cycles = C + 1000
	check(lib_call(b + tb, fnos[:], 43) == lo + 1000, "thbase: GetSystemTimeLow tracks the clock")
}

// thbase fno with a0..a2, from the context iop_sched.intr names.
tb_call :: proc(fno: u32, a0: u32 = 0, a1: u32 = 0, a2: u32 = 0) -> u32 {
	r := &r3000.state.r
	r[4], r[5], r[6] = a0, a1, a2
	v, ok := iop.th_base(fno)
	check(ok, "thbase: a served call")
	return v
}

// thbase 35 SetAlarm against ps2sdk's thbase: a thread's call only; a clock
// under 100 microseconds raised to it and written back, one with a high word
// kept; a second alarm of the same handler and argument -104; the handler
// at the due cycle, its argument in a0, its v0 the next alarm counted from
// this one and raised to the minimum, 0 ending it; the loader's reset and a
// failed load's undo, of an alarm whose handler it frees, ending alarms.
test_alarm :: proc() {
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	// "moda": d {count, a0, v0, clock lo, clock hi}; h counts, records a0
	// and returns d's v0.
	a: Asm
	d := at(&a)
	put(&a, 0, 0, 0, 0, 0)
	h := at(&a)
	la(&a, T0, d)
	put(&a, 0x8d090000, 0, 0x25290001, 0xad090000) // lw t1, 0(t0); nop; addiu t1, t1, 1; sw t1, 0(t0)
	put(&a, 0xad040004, 0x8d020008, JR_RA, 0) // sw a0, 4(t0); lw v0, 8(t0); jr ra
	entry := at(&a)
	put(&a, JR_RA, 0x24020000)
	id, _ := iop.iop_load(build_mod("moda", &a, entry), "moda", nil)
	b := module_base(id)
	word :: proc(at: u32) -> u32 {return iop.iop_u32(at)^}
	clock := b + d + 12
	x := &iop.iop_timr
	MIN :: u64(iop.ALARM_MIN)
	check(id > 0 && MIN == 3686, "alarm: the module loads, the minimum 100 microseconds")

	iop.iop_sched.intr = true
	check(tb_call(35, clock, b + h, 0x55) == neg(-iop.KE_ILLEGAL_CONTEXT) && x.nalarm == 0, "alarm: SetAlarm in a handler is illegal")
	iop.iop_sched.intr = false
	C :: u64(100_000)
	r3000.state.cycles = C
	iop.iop_u32(clock)^ = 10
	check(tb_call(35, clock, b + h, 0x55) == 0 && word(clock) == u32(MIN), "alarm: set, its short clock raised and written back")
	check(x.nalarm == 1 && x.alarms[0].due == C + MIN && iop.tim_next_ee() == (C + MIN) * 8 && iop.iop_wake_ee == (C + MIN) * 8, "alarm: due at the minimum, the wake there")
	check(tb_call(35, clock, b + h, 0x55) == neg(104) && x.nalarm == 1, "alarm: the same handler and argument again is -104")
	iop.iop_u32(clock)^, iop.iop_u32(clock + 4)^ = 5, 1
	check(tb_call(35, clock, b + h, 0x66) == 0 && word(clock) == 5 && x.alarms[1].due == C + 1 << 32 + 5, "alarm: another argument; a clock with a high word kept")

	iop.iop_u32(b + d + 8)^ = 10
	iop.iop_tick((C + MIN - 1) * 8)
	check(word(b + d) == 0, "alarm: no handler before it is due")
	iop.iop_tick((C + MIN) * 8)
	check(word(b + d) == 1 && word(b + d + 4) == 0x55, "alarm: the handler when due, its argument in a0")
	check(x.nalarm == 2 && iop.tim_next_ee() == (C + 2 * MIN) * 8, "alarm: a v0 under the minimum raised to it, counted from the last")
	iop.iop_u32(b + d + 8)^ = 0
	iop.iop_tick((C + 2 * MIN) * 8)
	check(word(b + d) == 2 && x.nalarm == 1 && x.alarms[0].arg == 0x66, "alarm: v0 0 ends it")
	check(tb_call(35, clock, b + h, 0x55) == 0 && x.nalarm == 2, "alarm: an ended alarm set again")

	// The undo of a load that freed the handler ends its alarms; one whose
	// handler and argument lie outside stays.
	iop.iop_u32(clock)^, iop.iop_u32(clock + 4)^ = 1000, 0
	check(tb_call(35, clock, 0x1000, 0x2000) == 0 && x.nalarm == 3, "alarm: one outside the module")
	saved := x^
	iop.tim_undo(saved, {{b, at(&a), 0}})
	check(x.nalarm == 1 && x.alarms[0].handler == 0x1000, "alarm: a failed load's undo ends the alarms of the memory it frees")

	fresh()
	check(iop.iop_timr.nalarm == 0 && iop.tim_next_ee() == max(u64), "alarm: the loader's reset clears the alarms")
}

// thbase 27 CancelWakeupThread: a thread's call only; the thread's wakeups,
// 0 the caller's, returned and cleared; an unknown thread -407.
test_wakeup_cancel :: proc() {
	fresh()
	s := &iop.iop_sched
	t := iop.th_new(0x1000, 0x2000, 0x100, 0, 10)
	id := t.id
	t.wakeups = 3
	s.intr = true
	check(tb_call(27, id) == neg(-iop.KE_ILLEGAL_CONTEXT) && t.wakeups == 3, "cancel wakeup: in a handler illegal")
	s.intr = false
	check(tb_call(27, id) == 3 && t.wakeups == 0 && tb_call(27, id) == 0, "cancel wakeup: the count returned and cleared")
	check(tb_call(27, id + 1) == neg(-iop.KE_UNKNOWN_THID), "cancel wakeup: an unknown thread")
	cur := s.cur
	s.cur, t.wakeups = id, 2
	check(tb_call(27, 0) == 2 && t.wakeups == 0, "cancel wakeup: thread 0 is the caller")
	s.cur = cur
	fresh()
}

// thbase 19 iReleaseWaitThread: a handler's call only; thread 0 -406, an
// unknown thread -407, one not waiting -416; a waiting thread, of any wait,
// ready with its wait returning KE_RELEASE_WAIT.
test_release_wait :: proc() {
	fresh()
	s := &iop.iop_sched
	t := iop.th_new(0x1000, 0x2000, 0x100, 0, 10)
	id := t.id
	t.status = .Sleep
	check(tb_call(19, id) == neg(-iop.KE_ILLEGAL_CONTEXT) && t.status == .Sleep, "release wait: on a thread illegal")
	s.intr = true
	check(tb_call(19, 0) == neg(-iop.KE_ILLEGAL_THID) && tb_call(19, id + 1) == neg(-iop.KE_UNKNOWN_THID), "release wait: thread 0, an unknown thread")
	check(tb_call(19, id) == 0 && t.status == .Ready && t.wake == neg(-iop.KE_RELEASE_WAIT), "release wait: a sleeper ready, its wait KE_RELEASE_WAIT")
	check(tb_call(19, id) == neg(-iop.KE_NOT_WAIT), "release wait: a ready thread is not waiting")
	for st in ([?]iop.Th_Status{.Wait, .Evf, .Delay, .Start}) {
		t.status, t.wake = st, 0
		check(tb_call(19, id) == 0 && t.status == .Ready && t.wake == neg(-iop.KE_RELEASE_WAIT), fmt.tprintf("release wait: a %v wait released", st))
	}
	t.status = .Dormant
	check(tb_call(19, id) == neg(-iop.KE_NOT_WAIT), "release wait: a dormant thread is not waiting")
	s.intr = false
	fresh()
}

// The EE kernel's next vblank start and end the vblank test hands the IOP
// (not emulated state: kernel_init points the IOP at the kernel's own).
vbl_start, vbl_end: u64
snap9: core.Snapshot
snap9_loaded: bool // not emulated state
snap10: core.Snapshot
snap10_loaded: bool // not emulated state

// vblank 4 and 6 wait for the next vblank start and return at once in
// vblank; 5 and 7 the same for the end, out of it; none at once before the
// first start. A waiter is a delayed thread, woken at its edge with every
// other on it; it survives a snapshot, a failed load's undo leaves none, a
// handler that calls one is stopped.
test_vblank :: proc() {
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	s := &iop.iop_sched
	F :: cpu.CYCLES_PER_FRAME
	L :: F / 262
	iop.ee_vblank_start, iop.ee_vblank_end = &vbl_start, &vbl_end
	defer iop.ee_vblank_start, iop.ee_vblank_end = nil, nil
	// "modq": threads A and B (priority 20) wait for the end by 5 and log 1
	// and 2; C (20) waits for vblank by 6 and logs 3; handlers h4 and h7 call
	// 4 and 7.
	a: Asm
	VB_FNOS :: [4]u32{4, 5, 6, 7}
	fnos := VB_FNOS
	vb := imports(&a, "vblank", ..fnos[:])
	tb := imports(&a, "thbase", 4, 6)
	logp := log_words(&a, 4)
	ths := at(&a)
	put(&a, 0, 0, 0)
	ea := at(&a)
	prologue(&a)
	jal(&a, vb + 8)
	log_v(&a, logp, 1)
	epilogue(&a)
	eb := at(&a)
	prologue(&a)
	jal(&a, vb + 8)
	log_v(&a, logp, 2)
	epilogue(&a)
	ec := at(&a)
	prologue(&a)
	jal(&a, vb + 16)
	log_v(&a, logp, 3)
	epilogue(&a)
	h4 := at(&a)
	prologue(&a)
	jal(&a, vb)
	epilogue(&a)
	h7 := at(&a)
	prologue(&a)
	jal(&a, vb + 24)
	epilogue(&a)
	params := [3]u32{thread_param(&a, ea, 20), thread_param(&a, eb, 20), thread_param(&a, ec, 20)}
	entry := at(&a)
	prologue(&a)
	for p, i in params {
		call_addr(&a, tb, p, ths + 4 * u32(i))
		call_word(&a, tb + 8, ths + 4 * u32(i))
	}
	li(&a, V0, 0)
	epilogue(&a)

	// Called with no thread: 0 at once, KE_CAN_NOT_WAIT for a wait.
	vb_at :: proc(b, vb: u32, ee: u64) -> [4]u32 {
		r3000.state.cycles = (ee + 7) / 8
		out: [4]u32
		fnos := VB_FNOS
		for f, i in fnos {out[i] = lib_call(b + vb, fnos[:], f)}
		return out
	}
	WAIT := neg(417)
	vbl_start, vbl_end = F - 22 * L, F
	cpu.state.cycles, r3000.state.cycles = 0, 0 // a load brings the IOP's clock up to the EE's
	id, r := iop.iop_load(build_mod("modq", &a, entry), "modq", nil)
	b := module_base(id)
	check(id > 0 && r == 0, "vblank: modq loads")
	check(vb_at(b, vb, 0) == {WAIT, WAIT, WAIT, WAIT} && vb_at(b, vb, F - 22 * L - 8) == {WAIT, WAIT, WAIT, WAIT}, "vblank: before the first start every call waits")
	check(vb_at(b, vb, F - 22 * L) == {WAIT, WAIT, 0, WAIT} && vb_at(b, vb, F - 8) == {WAIT, WAIT, 0, WAIT}, "vblank: from a start, 6 at once, 4, 5 and 7 wait")
	check(vb_at(b, vb, F) == {WAIT, WAIT, WAIT, 0} && vb_at(b, vb, 2 * F - 22 * L - 8) == {WAIT, WAIT, WAIT, 0}, "vblank: from an end, 7 at once, 4, 5 and 6 wait")
	check(vb_at(b, vb, 10 * F + 1) == {WAIT, WAIT, WAIT, 0} && vb_at(b, vb, 11 * F - 21 * L) == {WAIT, WAIT, 0, WAIT}, "vblank: the IOP's clock frames past the kernel's next edges")
	vbl_start, vbl_end = 2 * F - 22 * L, 2 * F
	check(vb_at(b, vb, F + 8) == {WAIT, WAIT, WAIT, 0}, "vblank: the kernel's next edges, past its last end")

	// A call on an edge's very cycle has missed its pulse: 4 and 5 wait for the
	// following edge. 6 and 7 are up from that cycle.
	vbl_start, vbl_end = F - 22 * L, F
	edge4, set4 := iop.vblank_wait_for(4, F - 22 * L)
	edge5, set5 := iop.vblank_wait_for(5, F)
	check(edge4 == 2 * F - 22 * L && !set4, "vblank: 4 on the start's cycle waits for the following start")
	check(edge5 == 2 * F && !set5, "vblank: 5 on the end's cycle waits for the following end")
	_, set6 := iop.vblank_wait_for(6, F - 22 * L)
	_, set7 := iop.vblank_wait_for(7, F)
	check(set6 && set7, "vblank: 6 and 7 pass on the edge's cycle")

	// modq's threads, started in vblank: C passes, A and B wait for the end.
	fresh()
	vbl_start, vbl_end = 2 * F - 22 * L, F
	cpu.state.cycles = F - 21 * L
	r3000.state.cycles = cpu.state.cycles / 8
	id, r = iop.iop_load(build_mod("modq", &a, entry), "modq", nil)
	b = module_base(id)
	th :: proc(b, ths: u32, i: u32) -> ^iop.Iop_Thread {return iop.th_find(iop.iop_u32(b + ths + 4 * i)^)}
	WAKE :: (F + 7) / 8
	check(id > 0 && r == 0 && log_equal(b, logp, {3}), "vblank: in vblank a waiter by 6 passes at once")
	ta, tb2 := th(b, ths, 0), th(b, ths, 1)
	check(ta.status == .Delay && tb2.status == .Delay && ta.wake_at == WAKE && tb2.wake_at == WAKE, "vblank: the end waiters are delayed to the end")
	check(iop.iop_wake_ee == WAKE * 8 && iop.iop_wake_ee >= F, "vblank: the IOP's wake is the end, not before it")
	iop.iop_tick((F - 21 * L) & ~u64(7))
	check(log_equal(b, logp, {3}) && th(b, ths, 0).status == .Delay, "vblank: a tick short of the end runs nothing, no thread ready")
	core.snap_op, core.snap_target = .Save, &snap9
	core.snap_yield()
	if !snap9_loaded {
		iop.iop_tick(F)
		check(log_equal(b, logp, {3, 1, 2}), "vblank: at the end both waiters wake, in the order they waited")
		snap9_loaded = true
		core.snap_op, core.snap_target = .Load, &snap9
		core.snap_yield()
	}
	check(log_equal(b, logp, {3}) && th(b, ths, 0).status == .Delay && th(b, ths, 1).wake_at == WAKE, "vblank: the load puts the waiters back")
	iop.iop_tick(F)
	check(log_equal(b, logp, {3, 1, 2}), "vblank: the restored waiters wake at the end")

	// Out of vblank, a handler is stopped, whether its call would wait (4)
	// or pass (7).
	check(iop.th_intr(b + h4, 0, 0) == .Blocked, "vblank: a handler waiting for the start is stopped")
	check(iop.th_intr(b + h7, 0, 0) == .Blocked, "vblank: a handler whose call would pass is stopped too")

	// "modz": its thread (priority 5) waits for the end, then its start
	// fails: the thread and its wait are gone.
	cpu.state.cycles = 2 * F - 21 * L
	vbl_start, vbl_end = 3 * F - 22 * L, 2 * F
	z: Asm
	zvb := imports(&z, "vblank", 5)
	ztb := imports(&z, "thbase", 4, 6)
	zsm := imports(&z, "sysmem", 99)
	zth := at(&z)
	put(&z, 0)
	ze := at(&z)
	prologue(&z)
	jal(&z, zvb)
	epilogue(&z)
	zp := thread_param(&z, ze, 5)
	entry = at(&z)
	prologue(&z)
	call_addr(&z, ztb, zp, zth)
	call_word(&z, ztb + 8, zth)
	jal(&z, zsm)
	li(&z, V0, 0)
	epilogue(&z)
	threads := len(s.threads)
	idz, _ := iop.iop_load(build_mod("modz", &z, entry), "modz", nil)
	delayed := 0
	for t in s.threads {if t.status == .Delay {delayed += 1}}
	check(idz <= 0 && len(s.threads) == threads && delayed == 0, "vblank: a failed load's waiting thread leaves no waiter")

	// "modw", started in vblank: threads of priority 30, 10 and 20 wait for the
	// end by 5 and log 1, 2 and 3; one of 40 waits by 4, in vblank already, and
	// logs 4. The end wakes the three, best priority first, and not the fourth;
	// the next start wakes it.
	fresh()
	vbl_start, vbl_end = 2 * F - 22 * L, F
	cpu.state.cycles = F - 21 * L
	r3000.state.cycles = cpu.state.cycles / 8
	w: Asm
	wvb := imports(&w, "vblank", 4, 5)
	wtb := imports(&w, "thbase", 4, 6)
	wlog := log_words(&w, 5)
	wth := at(&w)
	put(&w, 0, 0, 0, 0)
	WAITERS := [4][3]u32{{8, 1, 30}, {8, 2, 10}, {8, 3, 20}, {0, 4, 40}}
	wparams: [4]u32
	for v, i in WAITERS {
		e := at(&w)
		prologue(&w)
		jal(&w, wvb + v[0])
		log_v(&w, wlog, v[1])
		epilogue(&w)
		wparams[i] = thread_param(&w, e, v[2])
	}
	entry = at(&w)
	prologue(&w)
	for p, i in wparams {
		call_addr(&w, wtb, p, wth + 4 * u32(i))
		call_word(&w, wtb + 8, wth + 4 * u32(i))
	}
	li(&w, V0, 0)
	epilogue(&w)
	id, r = iop.iop_load(build_mod("modw", &w, entry), "modw", nil)
	b = module_base(id)
	check(id > 0 && r == 0 && log_equal(b, wlog, {}), "vblank: in vblank 4 waits like 5")
	check(th(b, wth, 3).wake_at == (2 * F - 22 * L + 7) / 8, "vblank: 4 in vblank is delayed to the next start")
	iop.iop_tick(F)
	check(log_equal(b, wlog, {2, 3, 1}), "vblank: waiters on one edge wake in priority order, 4 not among them")
	iop.iop_tick(2 * F - 22 * L)
	check(log_equal(b, wlog, {2, 3, 1, 4}), "vblank: the next start wakes the waiter by 4")
}

// vblank 8 and 9: a list per edge, lowest priority first, equal ones in the
// order added; Add refuses a duplicate and, full, is a row; Del one not
// there. A list runs once at its edge, before the threads, a handler that
// returns 0 or waits dropped; after a stall only the latest edge of each
// kind runs, in the order they fell. A handler's Add or Del is refused. It
// survives a snapshot; a failed load's undo puts back what it removed and
// drops what it added.
test_vblank_handlers :: proc() {
	fresh()
	iop.iop_irx = true
	defer iop.iop_irx = false
	F :: cpu.CYCLES_PER_FRAME
	L :: F / 262
	up8 :: proc(x: u64) -> u64 {return (x + 7) / 8 * 8}
	iop.ee_vblank_start, iop.ee_vblank_end = &vbl_start, &vbl_end
	defer iop.ee_vblank_start, iop.ee_vblank_end = nil, nil
	// "modv": thread T (priority 20) sleeps, then logs 9. Handlers h1 and h3
	// log 1 and 3 and return 1, h2 logs 2 and returns 0; hw wakes T and
	// logs 4; ha and hd log 5 and 6 after calling Add and Del, keeping what
	// they return; hb waits for the start.
	a: Asm
	VFN :: [3]u32{4, 8, 9}
	vfn := VFN
	vb := imports(&a, "vblank", ..vfn[:])
	tb := imports(&a, "thbase", 4, 6, 24, 26)
	logp := log_words(&a, 24)
	ths := at(&a)
	put(&a, 0, 0, 0)
	out := ths + 4
	et := at(&a)
	prologue(&a)
	jal(&a, tb + 16)
	log_v(&a, logp, 9)
	li(&a, V0, 0)
	epilogue(&a)
	hv := [4]u32{}
	for v, i in ([3]u32{1, 2, 3}) {
		hv[i] = at(&a)
		prologue(&a)
		log_v(&a, logp, v)
		li(&a, V0, u32(v != 2))
		epilogue(&a)
	}
	h1, h2, h3 := hv[0], hv[1], hv[2]
	hw := at(&a)
	prologue(&a)
	lw_at(&a, A0, ths)
	jal(&a, tb + 24)
	log_v(&a, logp, 4)
	li(&a, V0, 1)
	epilogue(&a)
	ha := at(&a)
	prologue(&a)
	li(&a, A0, 0)
	li(&a, A1, 0)
	li(&a, A2, 0)
	li(&a, A3, 0)
	jal(&a, vb + 8)
	store_v0(&a, out)
	log_v(&a, logp, 5)
	li(&a, V0, 1)
	epilogue(&a)
	hd := at(&a)
	prologue(&a)
	li(&a, A0, 0)
	li(&a, A1, 0)
	jal(&a, vb + 16)
	store_v0(&a, out + 4)
	log_v(&a, logp, 6)
	li(&a, V0, 1)
	epilogue(&a)
	hb := at(&a)
	prologue(&a)
	jal(&a, vb)
	li(&a, V0, 1)
	epilogue(&a)
	tp := thread_param(&a, et, 20)
	entry := at(&a)
	prologue(&a)
	call_addr(&a, tb, tp, ths)
	call_word(&a, tb + 8, ths)
	li(&a, V0, 0)
	epilogue(&a)

	vbl_start, vbl_end = F - 22 * L, F
	cpu.state.cycles, r3000.state.cycles = 0, 0
	id, r := iop.iop_load(build_mod("modv", &a, entry), "modv", nil)
	b := module_base(id)
	check(id > 0 && r == 0 && log_equal(b, logp, {}), "vblank handlers: modv loads, T sleeps")
	v := &iop.iop_vbl
	check(iop.vbl_next_ee() == max(u64), "vblank handlers: none, no wake")
	add :: proc(b, vb, end, prio, h: u32) -> u32 {
		vfn := VFN
		return lib_call(b + vb, vfn[:], 8, end, prio, h, 0)
	}
	del :: proc(b, vb, end, h: u32) -> u32 {
		vfn := VFN
		return lib_call(b + vb, vfn[:], 9, end, h)
	}
	check(add(b, vb, 1, 10, b + h1) == 0 && add(b, vb, 7, 5, b + h3) == 0 && add(b, vb, 1, 5, b + h2) == 0 && add(b, vb, 0, 0, b + hw) == 0, "vblank handlers: Add returns 0")
	order :: proc(v: ^iop.Iop_Vblank) -> (o: [iop.VBL_HANDLERS]u32) {
		for x, i in v.h[:v.n] {o[i] = x.handler}
		return
	}
	check(v.n == 4 && order(v) == {0 = b + h3, 1 = b + h2, 2 = b + h1, 3 = b + hw} && v.h[0].end == 1 && v.h[3].end == 0, "vblank handlers: lowest priority first, equal after, any nonzero edge the end")
	check(v.next == {F - 22 * L, F} && iop.vbl_next_ee() == up8(F - 22 * L), "vblank handlers: the next edges are the kernel's, the wake the start")
	check(add(b, vb, 1, 0, b + h1) == neg(-iop.KE_FOUND_HANDLER), "vblank handlers: Add of one already on the edge is KE_FOUND_HANDLER")
	check(add(b, vb, 0, 0, b + h1) == 0 && del(b, vb, 0, b + h1) == 0 && del(b, vb, 0, b + h1) == neg(-iop.KE_NOTFOUND_HANDLER) && v.n == 4, "vblank handlers: one handler on both edges; Del of one not there is KE_NOTFOUND_HANDLER")

	iop.iop_tick(up8(F - 22 * L))
	check(log_equal(b, logp, {4, 9}) && v.next[0] == 2 * F - 22 * L, "vblank handlers: at the start hw runs, the thread it wakes in that tick")
	iop.iop_tick(up8(F - 22 * L))
	check(log_equal(b, logp, {4, 9}), "vblank handlers: an edge runs once")
	core.snap_op, core.snap_target = .Save, &snap10
	core.snap_yield()
	if !snap10_loaded {
		iop.iop_tick(up8(F))
		check(log_equal(b, logp, {4, 9, 3, 2, 1}) && v.n == 3, "vblank handlers: at the end h3, h2, h1, h2 dropped on 0")
		snap10_loaded = true
		core.snap_op, core.snap_target = .Load, &snap10
		core.snap_yield()
	}
	check(log_equal(b, logp, {4, 9}) && v.n == 4 && v.next == {2 * F - 22 * L, F}, "vblank handlers: the load puts the handlers and their edges back")
	iop.iop_tick(up8(F))
	check(log_equal(b, logp, {4, 9, 3, 2, 1}) && v.n == 3 && v.next[1] == 2 * F, "vblank handlers: the restored end runs, dropping h2")
	iop.iop_tick(5 * F + 16)
	check(log_equal(b, logp, {4, 9, 3, 2, 1, 4, 3, 1}) && v.next == {6 * F - 22 * L, 6 * F}, "vblank handlers: after a stall the latest start, then the latest end, once each")
	iop.iop_tick(up8(8 * F - 22 * L))
	check(log_equal(b, logp, {4, 9, 3, 2, 1, 4, 3, 1, 3, 1, 4}) && v.next == {9 * F - 22 * L, 8 * F}, "vblank handlers: the end first when it fell first")

	rows := core.compat.calls[core.Compat_Key{.Iop_Vblank_Intr, b + hb, 0}].n
	check(del(b, vb, 0, b + hw) == 0 && add(b, vb, 0, 0, b + ha) == 0 && add(b, vb, 0, 1, b + hd) == 0 && add(b, vb, 0, 2, b + hb) == 0, "vblank handlers: ha, hd and hb added")
	iop.iop_tick(up8(9 * F - 22 * L))
	check(log_equal(b, logp, {4, 9, 3, 2, 1, 4, 3, 1, 3, 1, 4, 3, 1, 5, 6}) && iop.iop_u32(b + out)^ == neg(-iop.KE_ILLEGAL_CONTEXT) && iop.iop_u32(b + out + 4)^ == neg(-iop.KE_ILLEGAL_CONTEXT), "vblank handlers: a handler's Add and Del are KE_ILLEGAL_CONTEXT")
	check(core.compat.calls[core.Compat_Key{.Iop_Vblank_Intr, b + hb, 0}].n == rows + 1 && v.n == 4 && order(v) == {0 = b + h3, 1 = b + h1, 2 = b + ha, 3 = b + hd}, "vblank handlers: a handler that waits is stopped, a row, dropped")
	check(del(b, vb, 0, b + ha) == 0 && del(b, vb, 0, b + hd) == 0 && v.n == 2, "vblank handlers: ha and hd removed")

	full := b + 0x10000
	for i in 0 ..< u32(iop.VBL_HANDLERS - 2) {check(add(b, vb, 0, 0, full + 4 * i) == 0, "vblank handlers: the table fills")}
	rows = core.compat.calls[core.Compat_Key{.Iop_Vblank_Intr, full + 0x100, 1}].n
	check(add(b, vb, 0, 0, full + 0x100) == neg(-iop.KE_NO_MEMORY) && v.n == iop.VBL_HANDLERS, "vblank handlers: Add to a full table is KE_NO_MEMORY")
	check(core.compat.calls[core.Compat_Key{.Iop_Vblank_Intr, full + 0x100, 1}].n == rows + 1, "vblank handlers: and a row")
	for i in 0 ..< u32(iop.VBL_HANDLERS - 2) {check(del(b, vb, 0, full + 4 * i) == 0, "vblank handlers: the table empties")}

	// "modu": its start removes h1, adds its own hu, then fails.
	u: Asm
	uvb := imports(&u, "vblank", 8, 9)
	usm := imports(&u, "sysmem", 99)
	hu := at(&u)
	put(&u, JR_RA, 0x24020001) // jr ra; li v0, 1
	entry = at(&u)
	prologue(&u)
	li(&u, A0, 1)
	put(&u, 0x3c050000 | (b + h1) >> 16, 0x34a50000 | (b + h1) & 0xffff) // lui a1, hi; ori a1, a1, lo
	jal(&u, uvb + 8)
	li(&u, A0, 1)
	li(&u, A1, 0)
	la(&u, A2, hu)
	li(&u, A3, 0)
	jal(&u, uvb)
	jal(&u, usm)
	li(&u, V0, 0)
	epilogue(&u)
	before := v^
	idu, _ := iop.iop_load(build_mod("modu", &u, entry), "modu", nil)
	check(idu <= 0 && v^ == before, "vblank handlers: a failed load's removal comes back, its own handler is dropped")

	// A module whose start deletes handler `dh` from edge `de`, adds `ah`
	// to edge `ae` (each skipped when 0), then fails.
	fails :: proc(name: string, de, dh, ae, ah: u32) -> i32 {
		u: Asm
		uvb := imports(&u, "vblank", 8, 9)
		usm := imports(&u, "sysmem", 99)
		entry := at(&u)
		prologue(&u)
		if dh != 0 {
			li(&u, A0, de)
			put(&u, 0x3c050000 | dh >> 16, 0x34a50000 | dh & 0xffff) // lui a1, hi; ori a1, a1, lo
			jal(&u, uvb + 8)
		}
		if ah != 0 {
			li(&u, A0, ae)
			li(&u, A1, 0)
			put(&u, 0x3c060000 | ah >> 16, 0x34c60000 | ah & 0xffff) // lui a2, hi; ori a2, a2, lo
			li(&u, A3, 0)
			jal(&u, uvb)
		}
		jal(&u, usm)
		li(&u, V0, 0)
		epilogue(&u)
		id, _ := iop.iop_load(build_mod(name, &u, entry), name, nil)
		return id
	}
	check(del(b, vb, 1, b + h1) == 0 && v.n == 1 && v.next[1] == 9 * F, "vblank handlers: h3 alone on the end, due at the next tick")
	before = v^
	check(fails("modd", 1, b + h3, 0, 0) <= 0 && v^ == before, "vblank handlers: a failed load that deleted an edge's only handler puts it back, its next edge unchanged")
	iop.iop_tick(up8(9 * F))
	iop.iop_tick(up8(9 * F))
	check(log_equal(b, logp, {4, 9, 3, 2, 1, 4, 3, 1, 3, 1, 4, 3, 1, 5, 6, 3}) && v.next[1] == 10 * F, "vblank handlers: and it runs at that edge once")
	check(fails("moda", 0, 0, 0, b + h2) <= 0 && v.n == 2 && v.h[1] == {0, 0, b + h2, 0} && v.next[0] == 10 * F - 22 * L, "vblank handlers: a failed load's handler outside its memory stays, its new list from the kernel's next edge")
	iop.iop_tick(up8(10 * F - 22 * L))
	check(log_equal(b, logp, {4, 9, 3, 2, 1, 4, 3, 1, 3, 1, 4, 3, 1, 5, 6, 3, 2}) && v.n == 1, "vblank handlers: and runs at that edge")
	for i in 0 ..< u32(iop.VBL_HANDLERS - 1) {check(add(b, vb, 0, 0, full + 4 * i) == 0, "vblank handlers: the table fills again")}
	before = v^
	rows = core.compat.calls[core.Compat_Key{.Iop_Vblank_Intr, b + h1, 1}].n
	check(fails("modf", 0, full, 0, b + h1) <= 0 && v^ == before, "vblank handlers: with no entry left, the deleted one comes back")
	check(core.compat.calls[core.Compat_Key{.Iop_Vblank_Intr, b + h1, 1}].n == rows + 1, "vblank handlers: the one added is dropped with Add's row")
}

// cdvdfsv's power-off server with PS_IRX=1: a bind gets its descriptor at
// once, no row; fn 1 stays open, no RPC_END and no row; any other fno is
// refused with a row and ends.
test_cdvd_poff :: proc() {
	POFF_SID :: 0x80000596
	drop_replies()
	defer drop_replies()
	irx := iop.iop_irx
	defer iop.iop_irx = irx
	iop.iop_irx = true
	send_pkt(iop.SIF_CMD_RPC_BIND, 1, 0, 0, 0, POFF_SID)
	sd := reply_word(0, 9)
	check(len(iop.sif.replies) == 1 && sd != 0 && iop.iop_u32(sd)^ == POFF_SID && core.compat.calls[{.Sif_Bind, POFF_SID, 0}].n == 0, "poff: a bind gets its descriptor, no row")
	drop_replies()
	send_pkt(iop.SIF_CMD_RPC_CALL, 2, 0, 0, 0, 1, 0, 0, 0, 0, sd)
	check(len(iop.sif.replies) == 0 && core.compat.calls[{.Sif_Rpc, POFF_SID, 1}].n == 0, "poff: fn 1 stays open, no RPC_END, no row")
	send_pkt(iop.SIF_CMD_RPC_CALL, 3, 0, 0, 0, 2, 0, 0, 0, 0, sd)
	check(call_ends(sd, 3) && core.compat.calls[{.Sif_Rpc, POFF_SID, 2}].n == 1, "poff: fn 2 is refused with a row and ends")
}
