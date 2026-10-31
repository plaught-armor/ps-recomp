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
	n := name_words(lib)
	put(a, IMPORT, 0, 0x0101, n[0], n[1])
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
