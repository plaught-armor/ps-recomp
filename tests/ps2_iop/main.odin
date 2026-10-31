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
// succeeds. A thread spinning on DelayThread after its start returned spends
// the budget: the load still succeeds, with one compat row, and the thread
// stays ready with its context saved. intrman, printf, strtol, memset and
// memcpy answer as the C library does. A snapshot taken while a thread waits
// restores it, coroutine stack included, so a signal after the load wakes it
// where it waited.
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
	test_threads()
	test_failed_paths()
	test_thread_budget()
	test_libc()
	test_thread_snap()
	test_sifcmd()

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
}

// Condition: a budget spent after the start returned still loads.
test_thread_budget :: proc() {
	fresh()
	s := &iop.iop_sched
	a: Asm
	tb := imports(&a, "thbase", 4, 6, 33)
	th := at(&a)
	put(&a, 0)
	el := at(&a)
	li(&a, A0, 100)
	jal(&a, tb + 16) // DelayThread(100)
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
	got := iop.iop_format("%5d|%-3x|%08X|%c|%u%%|%ld")
	check(got == "   -1|ff |000000AB|z|7%|0", fmt.tprintf("libc: printf conversions, arguments past a3 from the stack: %q", got))
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
