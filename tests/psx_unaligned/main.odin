// Fused unaligned words on the PS1 side, run on every target in CI: lower
// fuses lwl/lwr and swl/swr pairs only under its guards; cpu.lw_u and
// cpu.sw_u match the pair they stand for at every alignment, in RAM, across
// a page, at the end of RAM, in the scratchpad and across into I/O; a plain
// word or half running past the scratchpad's end stays in it; and the
// native backend's fused pair leaves what the composed pair does. Also the
// native backend's inline div and divu against cpu.div and cpu.divu.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import psx_native "ps:psx/native"
import cpu "ps:psx/cpu"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"

@(private = "file")
failed: int

@(private = "file")
fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL psx_unaligned: ")
	fmt.eprintfln(format, ..args)
	failed += 1
}

LWL_V0 :: 0x88820003 // lwl $v0, 3($a0)
LWR_V0 :: 0x98820000 // lwr $v0, 0($a0)
SWL_A1 :: 0xa8850003 // swl $a1, 3($a0)
SWR_A1 :: 0xb8850000 // swr $a1, 0($a0)
ADDU_V1_V0 :: 0x00401821 // addu $v1, $v0, $0: the load delay slot
JR_RA :: 0x03e00008
DIV_A0_A1 :: 0x0085001a
DIVU_A0_A1 :: 0x0085001b

@(private = "file")
build :: proc(at: u32, words: []u32, labels: []u32 = nil) -> ^mips.Func {
	data := make([]u8, 4 * len(words), context.temp_allocator)
	for w, n in words {
		data[4 * n], data[4 * n + 1], data[4 * n + 2], data[4 * n + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
	}
	f := mips.func_make(at, at + u32(len(data)))
	mips.discover(r3000.RULES, {base = at, data = data}, f, labels)
	return f
}

// The pairs lower fuses, and the ones it must leave alone.
@(private = "file")
check_lower :: proc() {
	Lower_Case :: struct {
		what:    string,
		words:   [3]u32,
		label:   bool, // the second word is a label
		patch:   bool, // a patch at the second word
		fused:   bool,
		delayed: bool, // a Load_Delay step holds the pair
	}
	CASES :: [?]Lower_Case {
		{"lwl/lwr", {LWL_V0, LWR_V0, 0}, false, false, true, false},
		{"lwl/lwr, slot reads rt", {LWL_V0, LWR_V0, ADDU_V1_V0}, false, false, true, true},
		{"swl/swr", {SWL_A1, SWR_A1, 0}, false, false, true, false},
		{"swl/swr with rs == rt", {0xa8840003, 0xb8840000, 0}, false, false, true, false},
		{"lwl/lwr with rs == rt", {0x88840003, 0x98840000, 0}, false, false, false, false},
		{"offsets 2 apart", {0x88820002, LWR_V0, 0}, false, false, false, false},
		{"other rt", {LWL_V0, 0x98830000, 0}, false, false, false, false},
		{"other rs", {LWL_V0, 0x98a20000, 0}, false, false, false, false},
		{"lwr first", {LWR_V0, LWL_V0, 0}, false, false, false, false},
		{"lwl/swr", {LWL_V0, SWR_A1, 0}, false, false, false, false},
		{"lwr a label", {LWL_V0, LWR_V0, 0}, true, false, false, false},
		{"patch at lwr", {LWL_V0, LWR_V0, 0}, false, true, false, false},
	}
	for c in CASES {
		at := u32(0x80001000)
		words := [?]u32{c.words[0], c.words[1], c.words[2], JR_RA, 0}
		f := build(at, words[:], c.label ? []u32{at + 4} : nil)
		patches := c.patch ? []r3000.Patch{{at = at + 4, cond = "false", target = at}} : nil
		pairs, singles, delayed := 0, 0, false
		for s in r3000.lower(f, patches, 1) {
			if s.kind != .Op && s.kind != .Load_Delay {continue}
			if s.i.pair {
				pairs += 1
				delayed = s.kind == .Load_Delay
				if s.i.pc != at + 4 || s.i.op != c.words[1] >> 26 {fail("%s: pair is %08x at %x", c.what, s.i.w, s.i.pc)}
			} else if s.i.pc == at || s.i.pc == at + 4 {
				singles += 1
			}
		}
		switch {
		case c.fused && (pairs != 1 || singles != 0):
			fail("%s: %d pairs, %d singles, want one pair", c.what, pairs, singles)
		case !c.fused && (pairs != 0 || singles != 2):
			fail("%s: %d pairs, %d singles, want two singles", c.what, pairs, singles)
		case delayed != c.delayed:
			fail("%s: load delay %v, want %v", c.what, delayed, c.delayed)
		}
		free_all(context.temp_allocator)
	}
}

// Every alignment in RAM; across a page; at the end of RAM, where the
// pair's high word wraps to its start; from the last RAM mirror into
// unmapped space; KSEG1 and KUSEG; the scratchpad, out of it into unmapped
// space, and from there into I/O (the memory control registers).
@(rodata, private = "file")
ADDRS := [?]u32 {
	0x80010000, 0x80010001, 0x80010002, 0x80010003,
	0x80010ffc, 0x80010ffd, 0x80010ffe, 0x80010fff,
	0x801ffffc, 0x801ffffd, 0x801ffffe, 0x801fffff,
	0x807ffffe, 0xa0010001, 0x00010002,
	0x1f800000, 0x1f800001, 0x1f8003fe, 0x1f800ffe, 0x1f800fff,
}

@(private = "file")
Mem :: struct {
	ram:     [cpu.RAM_SIZE]u8,
	scratch: [cpu.SCRATCH_SIZE]u8,
	io:      u32, // the I/O word the pairs at 0x1f800ffe and 0x1f800fff reach
}

@(private = "file")
IO_WORD :: 0x1f801000

// The memory control registers as package psx keeps them (psx/io_bus.odin),
// which the test does not link: a word per register, whatever the access
// size.
@(private = "file")
memctrl: [16]u32

@(private = "file")
io_read :: proc(p: u32, size: u32) -> u32 {
	return memctrl[(p - IO_WORD) >> 2] if p - IO_WORD < 0x40 else 0
}

@(private = "file")
io_write :: proc(p, v: u32, size: u32) {
	if p - IO_WORD < 0x40 {memctrl[(p - IO_WORD) >> 2] = v}
}

@(private = "file")
fill :: proc() {
	for &b, o in cpu.ram {b = u8(o * 7 + (o >> 8))}
	for &b, o in cpu.scratch {b = u8(o * 13 + 0x5b)}
	cpu.sw(IO_WORD, 0x1f000000)
}

@(private = "file")
snap :: proc(m: ^Mem) {
	m.ram = cpu.ram
	m.scratch = cpu.scratch
	m.io = cpu.lw(IO_WORD)
}

@(private = "file")
same_mem :: proc(a, b: ^Mem) -> bool {
	return a.ram == b.ram && a.scratch == b.scratch && a.io == b.io
}

@(private = "file")
composed_load :: proc(a, cur: u32) -> u32 {return cpu.lwr(a, cpu.lwl(a + 3, cur))}

@(private = "file")
composed_store :: proc(a, v: u32) {
	cpu.swl(a + 3, v)
	cpu.swr(a, v)
}

// cpu.lw_u and cpu.sw_u against the pairs, plain, with the cache isolated
// and while memory tracing watches.
@(private = "file")
check_bus :: proc() {
	want, got: ^Mem = new(Mem), new(Mem)
	defer free(want)
	defer free(got)
	for a in ADDRS {
		fill()
		if w, g := composed_load(a, 0x5a5a5a5a), cpu.lw_u(a); g != w {
			fail("lw_u(%08x) = %08x, want %08x", a, g, w)
		}
		// Mode 1: the cache isolated; 2: memory tracing watches.
		for mode in 0 ..< 3 {
			store :: proc(mode: int, a: u32, fused: bool) {
				fill()
				cpu.cop0.sr = 0x10000 if mode == 1 else 0
				core.trace.watching = mode == 2
				if fused {
					cpu.sw_u(a, 0xc3a59617)
				} else {
					composed_store(a, 0xc3a59617)
				}
				cpu.cop0.sr = 0
				core.trace.watching = false
			}
			store(mode, a, false)
			snap(want)
			store(mode, a, true)
			snap(got)
			if !same_mem(want, got) {fail("sw_u(%08x) in mode %d differs from swl/swr", a, mode)}
		}
	}
}

// cpu.lw, cpu.lhu, cpu.sw and cpu.sh across the scratchpad's end: the
// bytes in it are the scratchpad's, the ones past it unmapped (read 0,
// stores go nowhere), and nothing outside the scratchpad array is touched.
@(private = "file")
check_straddle :: proc() {
	want, got: ^Mem = new(Mem), new(Mem)
	defer free(want)
	defer free(got)
	for a in ([?]u32{0x1f8003fd, 0x1f8003fe, 0x1f8003ff, 0x9f8003fe}) {
		for size in ([?]u32{2, 4}) {
			if size == 2 && a & 1 == 0 {continue}
			fill()
			o := a & (cpu.SCRATCH_SIZE - 1)
			v: u32
			for j in 0 ..< size {
				if o + j < cpu.SCRATCH_SIZE {v |= u32(cpu.scratch[o + j]) << (8 * j)}
			}
			g := cpu.lw(a) if size == 4 else cpu.lhu(a)
			if g != v {fail("load%d at %08x: %08x, want %08x", size * 8, a, g, v)}
			fill()
			for j in 0 ..< size {
				if o + j < cpu.SCRATCH_SIZE {cpu.scratch[o + j] = u8(u32(0xc3a59617) >> (8 * j))}
			}
			snap(want)
			fill()
			if size == 4 {cpu.sw(a, 0xc3a59617)} else {cpu.sh(a, 0x9617)}
			snap(got)
			if !same_mem(want, got) {fail("store%d at %08x differs", size * 8, a)}
		}
	}
}

// The fused pairs as native code: a load, a load whose delay slot reads the
// old value, and a store.
@(private = "file")
check_native :: proc() {
	FUNCS :: [?][4]u32 {
		{LWL_V0, LWR_V0, JR_RA, 0},
		{LWL_V0, LWR_V0, ADDU_V1_V0, JR_RA},
		{SWL_A1, SWR_A1, JR_RA, 0},
		{DIV_A0_A1, JR_RA, 0, 0},
		{DIVU_A0_A1, JR_RA, 0, 0},
	}
	funcs := FUNCS
	arch := native.Arch(core.NATIVE_ARCH)
	na := native.make_asm(arch, r3000.native_ram(), r3000.NATIVE_CACHED[:])
	blob_funcs: [len(FUNCS)]native.Blob_Func
	for w, k in funcs {
		at := u32(0x80002000 + 0x20 * k)
		words := [?]u32{w[0], w[1], w[2], w[3], 0}
		blob_funcs[k] = {at, r3000.native_func(&na, build(at, words[:]), nil, 1)}
		free_all(context.temp_allocator)
	}
	code, err := core.native_load(native.make_blob(&na, blob_funcs[:], {}), psx_native.imports())
	if err != "" {
		fmt.eprintln("FAIL psx_unaligned: native_load:", err)
		os.exit(1)
	}
	run :: proc(code: core.Native_Code, k: int) {(cast(proc())rawptr(code.base + uintptr(code.funcs[k].off)))()}
	cpu.next_event = max(u64)
	want, got: ^Mem = new(Mem), new(Mem)
	defer free(want)
	defer free(got)
	for a in ADDRS {
		fill()
		ld := composed_load(a, 0x5a5a5a5a)
		for k in 0 ..< 2 {
			cpu.state.r[2], cpu.state.r[3], cpu.state.r[4] = 0x5a5a5a5a, 0, a
			run(code, k)
			if cpu.state.r[2] != ld {fail("native %d at %08x: v0 %08x, want %08x", k, a, cpu.state.r[2], ld)}
			if k == 1 && cpu.state.r[3] != 0x5a5a5a5a {fail("native at %08x: slot saw %08x, want the old v0", a, cpu.state.r[3])}
		}
		fill()
		composed_store(a, 0xc3a59617)
		snap(want)
		fill()
		cpu.state.r[4], cpu.state.r[5] = a, 0xc3a59617
		run(code, 2)
		snap(got)
		if !same_mem(want, got) {fail("native store at %08x differs from swl/swr", a)}
	}
	// Each by each: by 0, the least i32 by -1, every sign, and others.
	DIV_ROWS :: [?]u32 {
		0, 1, 2, 3, 7, 0x7fff, 0x10000, 0x7ffffffe, 0x7fffffff,
		0x80000000, 0x80000001, 0xfffffff9, 0xfffffffe, 0xffffffff, 0x12345678, 0x9abcdef0,
	}
	rows := DIV_ROWS
	for n in rows {
		for d in rows {
			for k in 3 ..< 5 {
				cpu.state.hi, cpu.state.lo = 0x11111111, 0x22222222
				if k == 3 {cpu.div(n, d)} else {cpu.divu(n, d)}
				hi, lo := cpu.state.hi, cpu.state.lo
				cpu.state.hi, cpu.state.lo = 0x11111111, 0x22222222
				cpu.state.r[4], cpu.state.r[5] = n, d
				run(code, k)
				if cpu.state.hi != hi || cpu.state.lo != lo {
					fail("native %s %08x, %08x: hi %08x lo %08x, want %08x %08x", "div" if k == 3 else "divu", n, d, cpu.state.hi, cpu.state.lo, hi, lo)
				}
			}
		}
	}
}

main :: proc() {
	cpu.io_read, cpu.io_write = io_read, io_write
	check_lower()
	check_bus()
	check_straddle()
	check_native()
	if failed != 0 {
		os.exit(1)
	}
	fmt.printfln("ok psx_unaligned %v: %d addresses", native.Arch(core.NATIVE_ARCH), len(ADDRS))
}
