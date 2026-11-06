// A run that creates more threads than iop_sched.threads holds, so the
// array grows while it runs: an IOP start, and a thread the start creates
// and starts. Once the start returns it is removed, its stack freed; once
// the thread returns it is dormant; the threads they created stay, dormant.
// Both models must end alike: the coroutine model (a default build) and
// FLAT (-define:PS_FLAT=true), whose run once ended the thread through its
// pointer from before the growth, into the freed array, so the thread
// stayed in the live one, running. The thread counts are printed so the
// two builds' output can be compared. A last case checks, in both models,
// that a thread's tail calls stay in its context across its runs.
package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "ps:core"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"
import r3000 "ps:psx/cpu"

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

LW_A0_T0 :: 0x8d040000 // lw a0, 0(t0)
SW_V0_T0 :: 0xad020000 // sw v0, 0(t0)

// Code that creates n threads of entry `idle` from param `p`.
create_n :: proc(a: ^Asm, tb, p: u32, n: int) {
	for _ in 0 ..< n {
		la(a, A0, p)
		jal(a, tb)
	}
}

// The threads are all dormant and none is a start.
all_dormant :: proc(what: string) {
	for t in iop.iop_sched.threads {
		check(!t.start, fmt.tprintf("%s: the start thread is removed", what))
		check(t.status == .Dormant, fmt.tprintf("%s: thread %d is %v, want dormant", what, t.id, t.status))
	}
}

// "modg": the start creates N threads of one idle entry, starts none, and
// returns 0.
case_start :: proc() {
	s := &iop.iop_sched
	iop.sys_init()
	iop.iop_loader_init()
	a: Asm
	tb := imports(&a, "thbase", 4)
	idle := at(&a)
	put(&a, JR_RA, 0)
	p := thread_param(&a, idle, 20)
	entry := at(&a)
	prologue(&a)
	create_n(&a, tb, p, N)
	put(&a, 0x24000000 | V0 << 16) // li v0, 0
	epilogue(&a)
	check(cap(s.threads) < N + 1, "start: the start's run must grow the array")
	id, r := iop.iop_load(build_mod("modg", &a, entry), "modg", nil)
	check(id > 0 && r == 0, "start: modg loads")
	fmt.printfln("start: threads %d", len(s.threads))
	check(len(s.threads) == N, fmt.tprintf("start: %d threads, want the start's %d", len(s.threads), N))
	all_dormant("start")
}

// "modh": the start creates and starts thread A and returns 0; A creates n
// threads of one idle entry and returns. sys_init clears the threads but
// keeps the array's capacity, so n is that capacity: A and its n threads
// do not fit, and the array grows during A's run.
case_thread :: proc() {
	s := &iop.iop_sched
	iop.sys_init()
	iop.iop_loader_init()
	n := max(N, cap(s.threads))
	a: Asm
	tb := imports(&a, "thbase", 4, 6)
	th := at(&a)
	put(&a, 0)
	idle := at(&a)
	put(&a, JR_RA, 0)
	p := thread_param(&a, idle, 20)
	body := at(&a)
	prologue(&a)
	create_n(&a, tb, p, n)
	epilogue(&a)
	pa := thread_param(&a, body, 20)
	entry := at(&a)
	prologue(&a)
	la(&a, A0, pa)
	jal(&a, tb)
	la(&a, T0, th)
	put(&a, SW_V0_T0)
	put(&a, LW_A0_T0)
	put(&a, 0x24000000 | 5 << 16) // li a1, 0
	jal(&a, tb + 8)
	put(&a, 0x24000000 | V0 << 16) // li v0, 0
	epilogue(&a)
	check(cap(s.threads) < n + 1, "thread: A's run must grow the array")
	id, r := iop.iop_load(build_mod("modh", &a, entry), "modh", nil)
	check(id > 0 && r == 0, "thread: modh loads")
	fmt.printfln("thread: threads %d", len(s.threads))
	check(len(s.threads) == n + 1, fmt.tprintf("thread: %d threads, want A and its %d", len(s.threads), n))
	all_dormant("thread")
}

// "modj": the start creates and starts thread B and returns 0. B's entry
// is `j body`, a tail call at its run's first word, and body spins. Each
// budget takes B off the CPU one tail call deep: its count saved in its
// context and given back when it runs again, never left on the loader.
case_tail :: proc() {
	s := &iop.iop_sched
	iop.sys_init()
	iop.iop_loader_init()
	a: Asm
	tb := imports(&a, "thbase", 4, 6)
	th := at(&a)
	put(&a, 0)
	body := at(&a)
	put(&a, 0x1000ffff, 0) // b body
	b := at(&a)
	put_rel(&a, 0x08000000 | body >> 2, 4) // j body
	put(&a, 0)
	pb := thread_param(&a, b, 20)
	entry := at(&a)
	prologue(&a)
	la(&a, A0, pb)
	jal(&a, tb)
	la(&a, T0, th)
	put(&a, SW_V0_T0)
	put(&a, LW_A0_T0)
	put(&a, 0x24000000 | 5 << 16) // li a1, 0
	jal(&a, tb + 8)
	put(&a, 0x24000000 | V0 << 16) // li v0, 0
	epilogue(&a)
	id, r := iop.iop_load(build_mod("modj", &a, entry), "modj", nil)
	check(id > 0 && r == 0, "tail: modj loads")
	check(len(s.threads) == 1 && s.threads[0].status == .Ready, "tail: B spins, ready")
	check(r3000.tail_depth == 0, "tail: B's tail call not left on the loader")
	check(s.threads[0].ctx.tail_depth == 1, "tail: B's tail call in its context")
	iop.th_schedule(r3000.state.cycles + 10_000)
	check(r3000.tail_depth == 0, "tail: B's tail call not left on the loader after its next run")
	check(s.threads[0].ctx.tail_depth == 1, "tail: B's tail call given back for its next run")
}

game :: proc(_: rawptr) {
	case_start()
	case_thread()
	case_tail()
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
