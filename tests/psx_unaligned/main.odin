// Fused unaligned words on the PS1 side, run on every target in CI: lower
// fuses lwl/lwr and swl/swr pairs only under its guards; cpu.lw_u and
// cpu.sw_u match the pair they stand for at every alignment, in RAM, across
// a page, at the end of RAM, in the scratchpad and across into I/O; a plain
// word or half running past the scratchpad's end stays in it; and the
// native backend's fused pair leaves what the composed pair does, and its
// lone lwl, lwr, swl and swr what the bus's do. Also the native backend's
// inline div and divu against cpu.div and cpu.divu, mfc0 against cpu.mfc0,
// and its aligned loads and stores, lwc2 and swc2 too, against the bus and
// the memory itself in and around the scratchpad.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import psx_native "ps:psx/native"
import cpu "ps:psx/cpu"
import "ps:psx/gte"
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
MFC0_V0 :: 0x40020000 // mfc0 $v0, $0, rd in bits 11-15

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
		{MFC0_V0 | 12 << 11, JR_RA, 0, 0},
		{MFC0_V0 | 13 << 11, JR_RA, 0, 0},
		{MFC0_V0 | 14 << 11, JR_RA, 0, 0},
		{MFC0_V0 | 15 << 11, JR_RA, 0, 0},
		{MFC0_V0 | 0 << 11, JR_RA, 0, 0},
		{MFC0_V0 | 8 << 11, JR_RA, 0, 0},
		{MFC0_V0 | 31 << 11, JR_RA, 0, 0},
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
	// mfc0 inline against cpu.mfc0, every COP0 field distinct.
	for k in 5 ..< len(funcs) {
		cpu.cop0.sr, cpu.cop0.cause, cpu.cop0.epc = 0x10400401, 0x8000a07c, 0x80012344
		cpu.state.r[2] = 0x5a5a5a5a
		run(code, k)
		rd := funcs[k][0] >> 11 & 31
		if want := cpu.mfc0(rd); cpu.state.r[2] != want {fail("native mfc0 %d: %08x, want %08x", rd, cpu.state.r[2], want)}
	}
	cpu.cop0 = {}
}

// A lone lwl, lwr, swl and swr as native code against cpu.lwl and the
// others at every address and 3 past it, which reaches the I/O word: a
// load, one whose delay slot reads the old value, one with rt the base
// register, and the stores, plain, with the cache isolated and while memory
// tracing watches.
@(private = "file")
check_lone :: proc() {
	FUNCS :: [?][3]u32 {
		{0x88820000, JR_RA, 0}, // lwl $v0, 0($a0)
		{0x98820000, JR_RA, 0}, // lwr $v0, 0($a0)
		{0x88820000, ADDU_V1_V0, JR_RA},
		{0x98820000, ADDU_V1_V0, JR_RA},
		{0x88840000, JR_RA, 0}, // lwl $a0, 0($a0)
		{0x98840000, JR_RA, 0}, // lwr $a0, 0($a0)
		{0xa8850000, JR_RA, 0}, // swl $a1, 0($a0)
		{0xb8850000, JR_RA, 0}, // swr $a1, 0($a0)
	}
	funcs := FUNCS
	arch := native.Arch(core.NATIVE_ARCH)
	na := native.make_asm(arch, r3000.native_ram(), r3000.NATIVE_CACHED[:])
	blob_funcs: [len(FUNCS)]native.Blob_Func
	for w, k in funcs {
		at := u32(0x80004000 + 0x20 * k)
		words := [?]u32{w[0], w[1], w[2], 0, 0}
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
	V :: 0xc3a59617
	for base in ADDRS {
		for a in ([2]u32{base, base + 3}) {
			for k in 0 ..< 6 {
				left := funcs[k][0] >> 26 == 0x22
				fill()
				cur := a if k >= 4 else 0x5a5a5a5a
				ld := cpu.lwl(a, cur) if left else cpu.lwr(a, cur)
				cpu.state.r[2], cpu.state.r[3], cpu.state.r[4] = 0x5a5a5a5a, 0, a
				run(code, k)
				g := cpu.state.r[4] if k >= 4 else cpu.state.r[2]
				if g != ld {fail("native %08x at %08x: %08x, want %08x", funcs[k][0], a, g, ld)}
				if k == 2 || k == 3 {
					if cpu.state.r[3] != 0x5a5a5a5a {fail("native %08x at %08x: slot saw %08x, want the old v0", funcs[k][0], a, cpu.state.r[3])}
				}
			}
			for k in 6 ..< 8 {
				for mode in 0 ..< 3 {
					store :: proc(code: core.Native_Code, k: int, mode: int, a: u32, natively: bool) {
						fill()
						cpu.cop0.sr = 0x10000 if mode == 1 else 0
						core.trace.watching = mode == 2
						if natively {
							cpu.state.r[4], cpu.state.r[5] = a, V
							run(code, k)
						} else if k == 6 {
							cpu.swl(a, V)
						} else {
							cpu.swr(a, V)
						}
						cpu.cop0.sr = 0
						core.trace.watching = false
					}
					store(code, k, mode, a, false)
					snap(want)
					store(code, k, mode, a, true)
					snap(got)
					if !same_mem(want, got) {fail("native %08x at %08x in mode %d differs from the bus", funcs[k][0], a, mode)}
				}
			}
		}
	}
}

// Each aligned load and store, lwc2 and swc2 through GTE data register 0,
// as native code in and around the scratchpad, in each segment: the bus
// (psx/cpu/bus.odin SCRATCH_MASK) has it at 0x1f800000 and 0x9f800000
// only, so kseg1 and kseg2 there reach nothing, while a kseg1 RAM word is
// still RAM. The loads read what is there (nothing past the scratchpad
// until I/O), and the stores leave what the cpu.sb, cpu.sh and cpu.sw ones
// do, plain, with the cache isolated and while memory tracing watches.
@(private = "file")
check_scratch :: proc() {
	Op :: struct {
		w:      u32,
		size:   u32,
		signed: bool,
		store:  bool,
	}
	OPS :: [?]Op {
		{0x80820000, 1, true, false}, // lb $v0, 0($a0)
		{0x84820000, 2, true, false}, // lh
		{0x8c820000, 4, false, false}, // lw
		{0x90820000, 1, false, false}, // lbu
		{0x94820000, 2, false, false}, // lhu
		{0xc8800000, 4, false, false}, // lwc2 $0, 0($a0)
		{0xa0850000, 1, false, true}, // sb $a1, 0($a0)
		{0xa4850000, 2, false, true}, // sh
		{0xac850000, 4, false, true}, // sw
		{0xe8800000, 4, false, true}, // swc2 $0, 0($a0)
	}
	ADDRS :: [?]u32 {
		0x1f800000, 0x9f800000, 0xbf800000, 0x1f800022, 0x9f800001,
		0x1f8003fc, 0x9f8003fc, 0xbf8003fc, 0x1f8003fe, 0x1f8003ff,
		0x1f800400, IO_WORD, 0x9f801000, 0xff800000, 0xa0101230,
	}
	ops := OPS
	arch := native.Arch(core.NATIVE_ARCH)
	na := native.make_asm(arch, r3000.native_ram(), r3000.NATIVE_CACHED[:])
	blob_funcs: [len(OPS)]native.Blob_Func
	for op, k in ops {
		at := u32(0x80003000 + 0x20 * k)
		words := [?]u32{op.w, JR_RA, 0, 0}
		blob_funcs[k] = {at, r3000.native_func(&na, build(at, words[:]), nil, 1)}
		free_all(context.temp_allocator)
	}
	code, err := core.native_load(native.make_blob(&na, blob_funcs[:], {}), psx_native.imports())
	if err != "" {
		fmt.eprintln("FAIL psx_unaligned: native_load:", err)
		os.exit(1)
	}
	run :: proc(code: core.Native_Code, k: int) {(cast(proc())rawptr(code.base + uintptr(code.funcs[k].off)))()}
	// What is at a, read straight from the memory, and whether anything is.
	held :: proc(a, size: u32) -> (v: u32, mapped: bool) {
		p := a & 0x1fffffff
		switch {
		case a & cpu.SCRATCH_MASK == cpu.SCRATCH_BASE:
			for j in 0 ..< size {v |= u32(cpu.scratch[p - cpu.SCRATCH_BASE + j]) << (8 * j)}
			return v, true
		case p < cpu.RAM_SIZE:
			for j in 0 ..< size {v |= u32(cpu.ram[p + j]) << (8 * j)}
			return v, true
		case p == IO_WORD:
			return memctrl[0] & (u32(0xffffffff) >> (32 - 8 * size)), true
		}
		return 0, false
	}
	cpu.next_event = max(u64)
	want, got: ^Mem = new(Mem), new(Mem)
	defer free(want)
	defer free(got)
	V :: 0xc3a59617
	for a in ADDRS {
		for op, k in ops {
			if a % op.size != 0 {continue}
			if !op.store {
				fill()
				v, _ := held(a, op.size)
				if op.signed {v = u32(i32(v << (32 - 8 * op.size)) >> (32 - 8 * op.size))}
				bus: u32
				switch op.size {
				case 1:
					bus = cpu.lb(a) if op.signed else cpu.lbu(a)
				case 2:
					bus = cpu.lh(a) if op.signed else cpu.lhu(a)
				case:
					bus = cpu.lw(a)
				}
				if bus != v {fail("bus %08x at %08x: %08x, want %08x", op.w, a, bus, v)}
				cpu.state.r[2], cpu.state.r[4] = 0x5a5a5a5a, a
				gte.data_write(0, 0x5a5a5a5a)
				run(code, k)
				g := gte.data_read(0) if op.w >> 26 == 0x32 else cpu.state.r[2]
				if g != v {fail("native %08x at %08x: %08x, want %08x", op.w, a, g, v)}
				continue
			}
			for mode in 0 ..< 3 {
				store :: proc(code: core.Native_Code, k: int, op: Op, mode: int, a: u32, natively: bool) {
					fill()
					cpu.cop0.sr = 0x10000 if mode == 1 else 0
					core.trace.watching = mode == 2
					if natively {
						cpu.state.r[4], cpu.state.r[5] = a, V
						gte.data_write(0, V)
						run(code, k)
					} else {
						switch op.size {
						case 1:
							cpu.sb(a, V)
						case 2:
							cpu.sh(a, V)
						case:
							cpu.sw(a, V)
						}
					}
					cpu.cop0.sr = 0
					core.trace.watching = false
				}
				store(code, k, op, mode, a, false)
				snap(want)
				if v, mapped := held(a, op.size); mapped && mode != 1 && v != u32(V) & (u32(0xffffffff) >> (32 - 8 * op.size)) {
					fail("bus %08x at %08x in mode %d left %08x", op.w, a, mode, v)
				}
				store(code, k, op, mode, a, true)
				snap(got)
				if !same_mem(want, got) {fail("native %08x at %08x in mode %d differs from the bus", op.w, a, mode)}
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
	check_lone()
	check_scratch()
	if failed != 0 {
		os.exit(1)
	}
	fmt.printfln("ok psx_unaligned %v: %d addresses", native.Arch(core.NATIVE_ARCH), len(ADDRS))
}
