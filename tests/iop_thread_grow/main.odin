// An IOP start that creates more threads than iop_sched.threads holds, so
// the array grows while the start runs. Once the start returns it is
// removed, its stack freed, and the threads it created stay, dormant. Both
// models must end alike: the coroutine model (a default build) and FLAT
// (-define:PS_FLAT=true), whose run once ended the start through the
// thread's pointer from before the growth, into the freed array, so the
// start stayed in the live one, running, with its stack. The thread count
// is printed so the two builds' output can be compared.
package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "ps:core"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"

N :: 16 // threads the start creates

IMPORT :: 0x41e00000
JR_RA :: 0x03e00008
T0 :: 8
A0 :: 4
V0 :: 2

failed: bool

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL %s (line %d)", what, loc.line)
		failed = true
	}
}

Rel :: struct {
	off, type: u32,
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

// An import table of `lib` 1.1; the offset of its first stub.
imports :: proc(a: ^Asm, lib: string, fnos: ..u32) -> u32 {
	n: [2]u32
	copy((^[8]u8)(&n)[:], lib)
	put(a, IMPORT, 0, 0x0101, n[0], n[1])
	stubs := at(a)
	for f in fnos {put(a, JR_RA, 0x24000000 | f)}
	put(a, 0, 0)
	return stubs
}

la :: proc(a: ^Asm, rt, off: u32) {
	put_rel(a, 0x3c000000 | rt << 16, 5) // lui rt, 0
	put_rel(a, 0x24000000 | rt << 21 | rt << 16 | off, 6) // addiu rt, rt, off
}
jal :: proc(a: ^Asm, off: u32) {
	put_rel(a, 0x0c000000 | off >> 2, 4)
	put(a, 0)
}
prologue :: proc(a: ^Asm) {put(a, 0x27bdfff0, 0xafbf0000)} // addiu sp, sp, -16; sw ra, 0(sp)
epilogue :: proc(a: ^Asm) {put(a, 0x8fbf0000, JR_RA, 0x27bd0010)} // lw ra, 0(sp); jr ra; addiu sp, sp, 16

// An iop_thread_t: attr, option, entry, stack size, priority.
thread_param :: proc(a: ^Asm, entry, prio: u32) -> u32 {
	p := at(a)
	put(a, 0, 0)
	put_rel(a, entry, 2)
	put(a, 0x400, prio)
	return p
}

// An IRX file of module `name`: ELF header, the IOPMOD and PT_LOAD headers,
// the module info, the text at 0x100 and 0x40 bytes of bss, then one
// SHT_REL section of its relocations.
build_mod :: proc(name: string, a: ^Asm, entry: u32) -> []u8 {
	TEXT :: 0x100
	text_size := u32(len(a.w) * 4)
	rel := TEXT + text_size
	sh := rel + u32(len(a.rels) * 8)
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
	for v, i in a.w {w32(f, TEXT + u32(i) * 4, v)}
	for r, i in a.rels {
		w32(f, rel + u32(i) * 8, r.off)
		w32(f, rel + u32(i) * 8 + 4, r.type)
	}
	w32(f, sh + 40 + 4, 9) // SHT_REL; section 0 is the null one
	w32(f, sh + 40 + 16, rel)
	w32(f, sh + 40 + 20, u32(len(a.rels) * 8))
	return f
}

game :: proc(_: rawptr) {
	s := &iop.iop_sched
	iop.sys_init()
	iop.iop_loader_init()

	// "modg": the start creates N threads of one idle entry, starts none,
	// and returns 0.
	a: Asm
	tb := imports(&a, "thbase", 4)
	idle := at(&a)
	put(&a, JR_RA, 0)
	p := thread_param(&a, idle, 20)
	entry := at(&a)
	prologue(&a)
	for _ in 0 ..< N {
		la(&a, A0, p)
		jal(&a, tb)
	}
	put(&a, 0x24000000 | V0 << 16) // li v0, 0
	epilogue(&a)
	check(cap(s.threads) < N + 1, "grow: the start's run must grow the array")
	id, r := iop.iop_load(build_mod("modg", &a, entry), "modg", nil)
	check(id > 0 && r == 0, "grow: modg loads")
	fmt.printfln("threads %d", len(s.threads))
	check(len(s.threads) == N, fmt.tprintf("grow: %d threads, want the start's %d", len(s.threads), N))
	for t in s.threads {
		check(!t.start, "grow: the start thread is removed")
		check(t.status == .Dormant, fmt.tprintf("grow: thread %d is %v, want dormant", t.id, t.status))
	}

	if failed {os.exit(1)}
	fmt.println("ok iop_thread_grow")
	os.exit(0)
}

main :: proc() {
	core.snap_init(1 << 20)
	iop.sif_snap()
	iop.spu_snap()
	mem.mem_init()
	iop.sif_init()
	context.allocator = core.emu_allocator()
	when core.FLAT {
		game(nil)
	} else {
		core.co_allocator = context.allocator
		core.snap_run(core.co_create(game, nil))
	}
}
