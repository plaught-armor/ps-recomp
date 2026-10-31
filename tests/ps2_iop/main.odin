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
package main

import "core:encoding/endian"
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

	test_heap()
	test_sysmem()
	test_irx()

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

// An IRX file: ELF header, the IOPMOD and PT_LOAD headers, the module info,
// the text at 0x100, then one SHT_REL section of `rels`.
build_irx :: proc(rels: []Rel) -> []u8 {
	TEXT :: 0x100
	text_size := u32(len(irx_text) * 4)
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
	for v, i in ([?]u32{0, 0x10, 0x8010, text_size, 0, 0x40}) {w32(f, 0x74 + u32(i) * 4, v)}
	w16(f, 0x74 + 24, 0x0102)
	copy(f[0x74 + 26:], "testmod")
	for v, i in irx_text {w32(f, TEXT + u32(i) * 4, v)}
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
	img = iop.iop_ram[IRX_BASE:][:iop.irx_mem_size(x)]
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
