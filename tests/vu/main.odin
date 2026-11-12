// VU0 microprograms from the EE: VCALLMS and VCALLMSR (through CMSAR0) on a
// two-pair program, run to its E bit in the interpreter.
//
//   0x40  IADDIU vi1, vi0, 5     VADD.xyzw vf3, vf1, vf2   (E bit)
//   0x48  NOP                    NOP                       (the E bit's delay slot)
//
// A second program writes every integer register through the lower
// interpreter: IADDIU vi<n>, vi0, n for n = 1..15, then IADDIU vi0, vi0, 7,
// which must leave vi0 zero.
//
// Then single macro ops on edge values: the clamped add and multiply
// family, flags into vf0, and MAX and MINI.
//
// Then a compiled VU0 program: VCALLMS runs it while micro memory holds
// its code, and the interpreter once a write changes that code.
//
// Last, micro memory writes after a program is compiled: each write path
// (the EE mapping, VIF MPG) moves its VU's micro generation, and on VU1 a
// write that changes the compiled code makes the next start miss it and
// interpret.
//
// Then the flag delay: a micro-mode FMAND, FCGET or FSAND sees the MAC, clip
// and status as they were after the pair four executed pairs back (a branch
// counts the pairs run, not their addresses), except the sticky status bits,
// which it sees at once. A new program starts with the flags as they are.
//
// Then VIF i-bits: a code with bit 31 runs, raises its VIF's INTC once and
// stalls the VIF; what follows, in that transfer or later ones, waits until
// FBRST.STC, then runs. With VIF_ERR.MII set an i-bit does nothing.
//
// Last, the GIF paths: an XGKICK (PATH1) between two VIF1 DIRECT codes
// (PATH2) that split one packet waits for the second DIRECT to end the
// packet, then sends its own. A PATH3 IMAGE packet gives the GIF to a
// waiting XGKICK after its first 8-qword slice with GIF_MODE.IMT set, and
// only at its end without; an XGKICK that arrives mid-IMAGE goes in at once
// with IMT. A DIRECTHL stalls VIF1 until the IMAGE ends. GIF_CTRL.RST
// frees a held GIF, drops a waiting XGKICK and lets a held DIRECT in;
// FBRST.RST drops what a VIF holds.
//
// GIF_STAT shows who owns the GIF and who waits: a split DIRECT packet,
// an XGKICK queued behind it, a DIRECT held behind PATH3. MSKPATH3 holds a
// PATH3 packet that has not started (and its DMA's STR) until unmask, lets
// one in flight end, and GIF_MODE.M3R does the same; GIF_CTRL.RST clears
// the masks and finishes the held DMA. A busy GIF_STAT read again with
// nothing moved is a compat row.
//
// Then a GIF source chain with TTE set: the tags' upper halves stay out of
// PATH3, so the packet in the chain and one sent after it reach the GS. The
// same chain into scratchpad puts each whole tag ahead of its data.
//
// Then VU0's window onto VU1's registers, read and written by LQ and SQ.
//
// Then the XGKICK latch: the packet is read when the program stops or kicks
// again, not at the instruction, so a tag stored in the pair after the kick
// is the tag sent; a walk with no EOP inside VU1 memory sends nothing.
//
// Last, the branch VI delay: a conditional branch right after a pair that
// writes its VI reads it from before that write (tests/vu_programs DELAY).
//
//   odin run tests/vu -collection:ps=.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "ps:core"
import "ps:ps2/dma"
import gif "ps:ps2/gif"
import gs "ps:ps2/gs"
import "ps:ps2/mem"
import "ps:ps2/vu"
import "ps:tests/vu_programs"

@(private = "file")
fail :: proc(what: string, args: ..any) -> ! {
	fmt.eprint("FAIL vu: ")
	fmt.eprintfln(what, ..args)
	os.exit(1)
}

@(private = "file")
put :: proc(addr, w: u32) {
	(^u32)(vu.vu_mem_addr(0x11000000 + addr))^ = w
}

@(private = "file")
run :: proc(name: string, call: proc()) {
	v := &vu.vu0
	v.vf[1].f = {1, 2, 3, 4}
	v.vf[2].f = {10, 20, 30, 40}
	v.vf[3] = {}
	v.vi[1] = 0
	v.tpc = 0
	call()
	if v.vf[3].f != {11, 22, 33, 44} {fail("%s: vf3 = %v", name, v.vf[3].f)}
	if v.vi[1] != 5 {fail("%s: vi1 = %d", name, v.vi[1])}
	if v.tpc != 0x50 {fail("%s: tpc = %04x, want 0050", name, v.tpc)}
}

// An E-bit NOP pair and its delay slot.
@(private = "file")
END_CODE := [4]u32{0x8000033c, 1 << 30 | 0x000002ff, 0x8000033c, 0x000002ff}

@(private = "file")
compiled_ran: bool

// MPG the pairs of code to micro address 0 of vif's VU.
@(private = "file")
mpg :: proc(vif: ^vu.Vif, code: []u32) {
	w := make([]u32, 2 + len(code), context.temp_allocator)
	w[1] = 0x4a << 24 | u32(len(code) / 2) << 16 // after a NOP, so code is 64-bit aligned
	copy(w[2:], code)
	vu.vif_feed(vif, ([^]u8)(raw_data(w))[:len(w) * 4])
}

@(private = "file")
vu0_compiled :: proc() {
	code := [4]u32{0x08 << 25 | 1 << 16 | 5, 1 << 30 | 0xf << 21 | 2 << 16 | 1 << 11 | 3 << 6 | 0x28, 0x8000033c, 0x000002ff}
	vu.vu0_register_ranges({{0x40, code[:]}}, proc(_: u32, _: ^int) -> (u32, vu.Vu_Exit) {
		compiled_ran = true
		return 0x50, .End
	})
	call := proc(want: bool, what: string) {
		compiled_ran = false
		vu.vu0.tpc = 0
		vu.vu_op(&vu.vu0, 0x4a000038 | (0x40 / 8) << 6) // VCALLMS
		if compiled_ran != want || vu.vu0.tpc != 0x50 {fail("%s: compiled ran %v, tpc %04x", what, compiled_ran, vu.vu0.tpc)}
	}
	call(true, "VU0 VCALLMS of the compiled code")
	put(0x48, 0x8000033d)
	call(false, "VU0 VCALLMS after a write to the compiled code")
	put(0x48, 0x8000033c)
	call(true, "VU0 VCALLMS of the compiled code again")
}

@(private = "file")
micro_writes :: proc() {
	g := vu.vu0_micro_gen
	_ = vu.vu_mem_addr(0x11000000)
	if vu.vu0_micro_gen == g {fail("VU0 micro write through the EE mapping kept generation %d", g)}
	g = vu.vu0_micro_gen
	mpg(&vu.vifs[0], END_CODE[:])
	if vu.vu0_micro_gen == g {fail("VU0 MPG kept generation %d", g)}

	vu.vu1_register(END_CODE[:], proc(_: u32, _: ^int) -> (u32, vu.Vu_Exit) {
		compiled_ran = true
		return 0x10, .End
	})
	start := proc(want: bool, what: string) {
		compiled_ran = false
		vu.vu1.tpc = 0
		vu.vu1_start(0)
		if compiled_ran != want || vu.vu1.tpc != 0x10 {fail("%s: compiled ran %v, tpc %04x", what, compiled_ran, vu.vu1.tpc)}
	}
	mpg(&vu.vifs[1], END_CODE[:])
	start(true, "VU1 MPG of the compiled code")
	(^u32)(vu.vu_mem_addr(0x11008008))^ = 0x8000033d
	start(false, "VU1 write through the EE mapping")
	mpg(&vu.vifs[1], END_CODE[:])
	start(true, "VU1 MPG of the compiled code again")
	changed := END_CODE
	changed[2] = 0x8000033d
	mpg(&vu.vifs[1], changed[:])
	start(false, "VU1 MPG of other code")
}

// The add and multiply family on infinities, NaNs and denormals, which
// the VU does not have: operands clamp first, so exponent 255 is the
// largest value and exponent 0 is zero, whatever the host would do.
@(private = "file")
clamped :: proc() {
	Case :: struct {
		name:     string,
		fn:       u32,
		s, t, d:  [4]u32,
		acc:      [4]u32,
	}
	NAN_P, NAN_N, INF_P, INF_N, MAX_P, MAX_N :: 0x7fffffff, 0xffffffff, 0x7f800000, 0xff800000, 0x7f7fffff, 0xff7fffff
	ONE, DENORM :: 0x3f800000, 0x00000001
	cases := [?]Case {
		// NaN x NaN: the largest value, the xor of the signs, either order
		{"VMUL", 0x2a, {NAN_P, NAN_N, NAN_N, NAN_P}, {NAN_N, NAN_P, NAN_N, NAN_P}, {MAX_N, MAX_N, MAX_P, MAX_P}, {}},
		// inf + -inf is max - max
		{"VADD", 0x28, {INF_P, INF_N, NAN_P, DENORM}, {INF_N, INF_P, ONE, ONE}, {0, 0, MAX_P, ONE}, {}},
		{"VSUB", 0x2c, {INF_P, NAN_N, DENORM, ONE}, {INF_P, ONE, DENORM, INF_P}, {0, MAX_N, 0, MAX_N}, {}},
		// a denormal is zero: 0 x inf, not NaN
		{"VMUL", 0x2a, {DENORM, INF_P, ONE, INF_N}, {INF_P, DENORM, NAN_N, ONE}, {0, 0, MAX_N, MAX_N}, {}},
		// max x max overflows before the add, so -max + it is +max, not 0;
		// the product of -max and max overflows too
		{"VMADD", 0x29, {MAX_P, NAN_P, MAX_N, ONE}, {MAX_P, MAX_N, MAX_P, ONE}, {MAX_P, MAX_N, MAX_N, 0}, {MAX_N, MAX_P, MAX_N, 0xbf800000}},
	}
	v := &vu.vu0
	for c in cases {
		v.vf[1].u, v.vf[2].u, v.vf[3], v.acc.u = c.s, c.t, {}, c.acc
		vu.vu_op(v, 0x4a000000 | 0xf << 21 | 2 << 16 | 1 << 11 | 3 << 6 | c.fn) // fd 3, fs 1, ft 2
		if v.vf[3].u != c.d {fail("%s %08x %08x: vf3 = %08x, want %08x", c.name, c.s, c.t, v.vf[3].u, c.d)}
	}
}

// DIV, RSQRT and the EFU clamp their operands as the add and multiply
// family does, so exponent 255 is a large number the host never sees as
// an infinity: no host NaN, whose sign differs between hosts (x64 sets
// it, arm64 does not), reaches Q or P. Each value is the hardware's, where
// exponent 255 is 2^128 times the mantissa.
@(private = "file")
div_efu :: proc() {
	INF_P, INF_N :: 0x7f800000, 0xff800000
	Case :: struct {
		name: string,
		w:    u32, // fs 1, ft 2, x lanes; ESUM reads all of vf1
		s, t: [4]u32,
		want: u32,
	}
	cases := [?]Case {
		// 2^128 / 2^128 = 1: the operands clamp to FMAX, and FMAX / FMAX is 1
		{"VDIV", 0x4a0003bc, {INF_P, 0, 0, 0}, {INF_P, 0, 0, 0}, 0x3f800000},
		// -2^128 / 2^128 = -1
		{"VDIV", 0x4a0003bc, {INF_N, 0, 0, 0}, {INF_P, 0, 0, 0}, 0xbf800000},
		// 2^128 / sqrt(2^128) = 2^64: FMAX / sqrt(FMAX) is 2^64 exactly, as
		// sqrt(FMAX) rounds to 2^64 (1 - 2^-24) and FMAX is 2^128 (1 - 2^-24)
		{"VRSQRT", 0x4a0003be, {INF_P, 0, 0, 0}, {INF_P, 0, 0, 0}, 0x5f800000},
		// ESUM: 2^128 - 2^128 + 0 + 0 = 0, as FMAX - FMAX
		{"ESUM", 0x8000077e, {INF_P, INF_N, 0, 0}, {}, 0},
	}
	for c in cases {
		v := c.name == "ESUM" ? &vu.vu1 : &vu.vu0 // the EFU is VU1's
		v.vf[1].u, v.vf[2].u, v.q, v.p = c.s, c.t, 1, 1
		if c.name == "ESUM" {vu.vu_op(v, c.w | 2 << 16 | 1 << 11)} else {vu.vu0_macro(c.w | 2 << 16 | 1 << 11)}
		got := transmute(u32)(c.name == "ESUM" ? v.p_next : v.q) // P waits for the EFU's latency
		if got != c.want {fail("%s %08x %08x: %08x, want %08x", c.name, c.s.x, c.t.x, got, c.want)}
	}
	vu.vu_drain(&vu.vu1) // land the ESUM, as an E bit would
}

// Flags of a macro op whose fd is vf0: MAC and status still update, vf0
// stays (0, 0, 0, 1). Status keeps a sticky bit set before the op (Z
// sticky, bit 6) and gains the S sticky bit; U and O clear, the rest stay.
@(private = "file")
flags :: proc() {
	v := &vu.vu0
	v.vf[1].f, v.vf[2].f = {1, -2, 0, 3}, {-1, 1, 0, 2}
	v.status, v.mac = 0x04c | 0x800, 0
	vu.vu_op(v, 0x4a000000 | 0xf << 21 | 2 << 16 | 1 << 11 | 0 << 6 | 0x28) // VADD.xyzw vf0, vf1, vf2
	if v.vf[0].f != {0, 0, 0, 1} {fail("VADD to vf0: vf0 = %v", v.vf[0].f)}
	// x = 0 (Z), y = -1 (S), z = 0 (Z), w = 5
	if v.mac != 0x4a {fail("VADD to vf0: mac = %02x, want 4a", v.mac)}
	if v.status != 0x8c3 {fail("VADD to vf0: status = %03x, want 8c3", v.status)}
}

// MAX and MINI on the raw words in sign and magnitude order: exponent 255
// is a large magnitude, denormals order as they are, -0 < +0. The result is
// the winning word unclamped, and MAC and status keep their old values. Each
// pair runs both ways round in the vector, broadcast and I forms.
@(private = "file")
minmax :: proc() {
	Pair :: struct {
		a, b, max, min: u32,
	}
	pairs := [?]Pair {
		{0x00000000, 0x80000000, 0x00000000, 0x80000000}, // +0, -0
		{0x80000000, 0x80000001, 0x80000000, 0x80000001}, // -0, -denormal
		{0x00000001, 0x00000000, 0x00000001, 0x00000000}, // denormal, +0
		{0x7f800000, 0x7f7fffff, 0x7f800000, 0x7f7fffff}, // inf, max
		{0x7fffffff, 0x7f800000, 0x7fffffff, 0x7f800000}, // NaN, inf
		{0xffffffff, 0xff800000, 0xff800000, 0xffffffff}, // -NaN, -inf
		{0xffc00000, 0x7fc00000, 0x7fc00000, 0xffc00000}, // -qNaN, qNaN
		{0xbf800000, 0x3f800000, 0x3f800000, 0xbf800000}, // -1, 1
		{0xc0000000, 0xbf800000, 0xbf800000, 0xc0000000}, // -2, -1
		{0x40000000, 0x3f800000, 0x40000000, 0x3f800000}, // 2, 1
		{0x807fffff, 0x80000000, 0x80000000, 0x807fffff}, // -denormal, -0
		{0x007fffff, 0x00800000, 0x00800000, 0x007fffff}, // denormal, smallest normal
	}
	MAC, STATUS :: 0x5a, 0x0c3
	NOISE :: 0x12345678
	v := &vu.vu0
	op :: proc(v: ^vu.Vu, dest, fd, fn: u32) {
		v.mac, v.status = MAC, STATUS
		vu.vu_op(v, 0x4a000000 | dest << 21 | 2 << 16 | 1 << 11 | fd << 6 | fn) // fs 1, ft 2
		if v.mac != MAC || v.status != STATUS {fail("fn %02x: mac %02x status %03x, want them kept", fn, v.mac, v.status)}
	}
	for p in pairs {
		for swap in 0 ..< 2 {
			a, b := swap == 0 ? p.a : p.b, swap == 0 ? p.b : p.a
			for is_max in 0 ..< 2 {
				want := is_max == 1 ? p.max : p.min
				name := is_max == 1 ? "MAX" : "MINI"
				check :: proc(form, name: string, a, b, want: u32) {
					got := vu.vu0.vf[3].u
					if got != {want, want, want, want} {fail("%s%s %08x %08x: vf3 = %08x, want %08x", name, form, a, b, got, want)}
				}
				v.vf[1].u, v.vf[2].u, v.vf[3] = {a, a, a, a}, {b, b, b, b}, {}
				op(v, 0xf, 3, is_max == 1 ? 0x2b : 0x2f)
				check("", name, a, b, want)
				for bc in u32(0) ..< 4 {
					v.vf[2].u, v.vf[3] = {NOISE, NOISE, NOISE, NOISE}, {}
					v.vf[2].u[bc] = b
					op(v, 0xf, 3, (is_max == 1 ? 0x10 : 0x14) | bc)
					check(".bc", name, a, b, want)
				}
				v.vf[3], v.i = {}, transmute(f32)b
				op(v, 0xf, 3, is_max == 1 ? 0x1d : 0x1f)
				check("i", name, a, b, want)
			}
		}
	}
	// dest .xz leaves y and w; fd 0 leaves vf0
	v.vf[1].u, v.vf[2].u = {1, 2, 3, 4}, {4, 3, 2, 1}
	v.vf[3].u = {NOISE, NOISE, NOISE, NOISE}
	op(v, 0xa, 3, 0x2b)
	if v.vf[3].u != {4, NOISE, 3, NOISE} {fail("MAX.xz: vf3 = %08x", v.vf[3].u)}
	op(v, 0xf, 0, 0x2f)
	if v.vf[0].f != {0, 0, 0, 1} {fail("MINI to vf0: vf0 = %v", v.vf[0].f)}
}

// IADDIU into each of vi1-vi15 and vi0, from 0x100.
@(private = "file")
all_vi :: proc() {
	BASE :: 0x100
	for n in u32(0) ..< 16 {
		it, imm := n == 15 ? 0 : n + 1, n == 15 ? 7 : n + 1
		put(BASE + n * 8, 0x08 << 25 | it << 16 | imm) // IADDIU vi<it>, vi0, imm
		put(BASE + n * 8 + 4, (n == 15 ? 1 << 30 : 0) | 0x000002ff) // NOP, E on the last
	}
	put(BASE + 16 * 8, 0x8000033c) // NOP
	put(BASE + 16 * 8 + 4, 0x000002ff) // NOP
	v := &vu.vu0
	for n in 1 ..< 16 {v.vi[n] = 0xffff}
	v.tpc = 0
	vu.vu_op(v, 0x4a000038 | (BASE / 8) << 6) // VCALLMS
	for n in 1 ..< 16 {
		if v.vi[n] != u16(n) {fail("IADDIU vi%d: vi%d = %d", n, n, v.vi[n])}
	}
	if v.vi[0] != 0 {fail("IADDIU vi0: vi0 = %d", v.vi[0])}
}

@(private = "file")
feed :: proc(vif: ^vu.Vif, code: ..u32) {
	w := code
	vu.vif_feed(vif, ([^]u8)(raw_data(w))[:len(w) * 4])
}

// Each pair as lower, upper.
@(private = "file")
put_pairs :: proc(addr: u32, pairs: ..[2]u32) {
	for p, k in pairs {
		put(addr + u32(k) * 8, p[0])
		put(addr + u32(k) * 8 + 4, p[1])
	}
}

// Q latency: DIV and SQRT write Q 7 pairs after issue, RSQRT 13. A read
// before then sees the old Q; a second DIV, SQRT or RSQRT, or WAITQ, lands
// the pending Q first; the E-bit end drains it; VU0 macro mode sees it at
// once. MULq vf<n>, vf2 with vf2 all ones reads Q into vf<n>.
@(private = "file")
q_latency :: proc() {
	NOP_L :: 0x8000033c
	NOP_U :: 0x000002ff
	E :: 1 << 30
	DIV :: 0x40 << 25 | 0b0011 << 21 | 1 << 16 | 0x3bc // DIV Q, vf0w, vf1x: 1 / 2
	SQRT :: 0x40 << 25 | 0b0100 << 21 | 1 << 16 | 0x3bd // SQRT Q, vf1y: sqrt 4
	RSQRT :: 0x40 << 25 | 0b1111 << 21 | 1 << 16 | 0x3be // RSQRT Q, vf0w, vf1w: 1 / sqrt 16
	WAITQ :: 0x40 << 25 | 0x3bf
	mulq :: proc(d: u32) -> u32 {return 0xf << 21 | 2 << 11 | d << 6 | 0x1c}
	v := &vu.vu0
	call := proc(v: ^vu.Vu, addr: u32) {
		v.vf[1].f, v.vf[2].f = {2, 4, 8, 16}, {1, 1, 1, 1}
		for r in 3 ..< 16 {v.vf[r] = {}}
		v.q, v.q_wait = 3, 0
		v.status = 0
		vu.vu_op(v, 0x4a000038 | (addr / 8) << 6) // VCALLMS
	}
	nops :: [2]u32{NOP_L, NOP_U}
	put_pairs(0x600, {DIV, mulq(3)}, {NOP_L, mulq(4)}, nops, nops, nops, nops, {NOP_L, mulq(5)}, {NOP_L, mulq(6)}, {RSQRT, mulq(7)},
		nops, nops, nops, nops, nops, nops, nops, nops, nops, nops, nops, {NOP_L, mulq(8)}, {NOP_L, mulq(9)},
		{SQRT, mulq(10)}, {DIV, mulq(11)}, {WAITQ, mulq(12)}, {RSQRT, mulq(13) | E}, {NOP_L, mulq(14)})
	call(v, 0x600)
	// The issuing pair and DIV +1 and +6 see 3, DIV +7 sees 1/2; RSQRT +12
	// still 1/2, +13 1/4; the DIV after the SQRT lands its 2; WAITQ lands
	// the DIV's 1/2 for the MULq beside it; the RSQRT before the E bit is
	// not seen by its delay slot, then lands at the end.
	want := [?]struct {
		r: int,
		q: f32,
	}{{3, 3}, {4, 3}, {5, 3}, {6, 0.5}, {7, 0.5}, {8, 0.5}, {9, 0.25}, {10, 0.25}, {11, 2}, {12, 0.5}, {13, 0.5}, {14, 0.5}}
	for w in want {if v.vf[w.r].f.x != w.q {fail("Q latency: vf%d.x = %v, want %v", w.r, v.vf[w.r].f.x, w.q)}}
	if v.q != 0.25 || v.q_wait != 0 {fail("Q latency: Q %v wait %d at the end, want 0.25 0", v.q, v.q_wait)}

	// B over a pair into the window: the pairs run count, so pair 7 is
	// DIV +6 and pair 8 DIV +7.
	B_2 :: 0x20 << 25 | 2 // B +2
	put_pairs(0x700, {DIV, NOP_U}, {B_2, NOP_U}, nops, {NOP_L, mulq(3)}, nops, nops, nops, {NOP_L, mulq(4)}, {NOP_L, mulq(5) | E}, nops)
	call(v, 0x700)
	if v.vf[3].f.x != 0 || v.vf[4].f.x != 3 || v.vf[5].f.x != 0.5 {fail("Q latency over a branch: vf3 %v vf4 %v vf5 %v, want 0 3 0.5", v.vf[3].f.x, v.vf[4].f.x, v.vf[5].f.x)}

	// A macro VDIV is seen by the next macro op.
	v.vf[1].f.x, v.vf[2].f.x, v.q = 1, 4, 3
	vu.vu0_macro(0x4a0003bc | 2 << 16 | 1 << 11) // VDIV Q, vf1x, vf2x
	if v.q != 0.25 || v.q_wait != 0 {fail("macro VDIV: Q %v wait %d, want 0.25 0", v.q, v.q_wait)}
}

// Stalls and the FDIV and EFU timing (PCSX2 microVU: Analyze.inl
// analyzeQreg/analyzePreg, Compile.inl mVUincCycles). A WAITQ, DIV, SQRT or
// RSQRT waits for a pending Q, a WAITP or EFU op for P to be one cycle from
// landing, and each stall cycle ages the late flags as a pair does. Status
// I and D of a DIV or SQRT are set by the first pair to start, after its
// stall, once 4 cycles are left: the third pair after issue (RSQRT the
// ninth), so FSAND
// reads sticky D at +3 (+9) and D itself, 4 pairs late, at +7 (+13); or at
// the E-bit end. P lands each EFU op's latency after issue.
@(private = "file")
stalls :: proc() {
	NOP_L :: 0x8000033c
	NOP_U :: 0x000002ff
	E :: 1 << 30
	sp :: proc(key, dest, ft, fs: u32) -> u32 {return 0x40 << 25 | dest << 21 | ft << 16 | fs << 11 | (key & 0x7c) << 4 | 0x3c | key & 3}
	add :: proc(d, s, t: u32) -> u32 {return 0xf << 21 | t << 16 | s << 11 | d << 6 | 0x28} // VADD.xyzw
	fmand :: proc(t: u32) -> u32 {return 0x1a << 25 | t << 16 | 2 << 11} // FMAND vi<t>, vi2
	fsand :: proc(t, imm: u32) -> u32 {return 0x16 << 25 | (imm & 0x800) << 10 | t << 16 | imm & 0x7ff}
	mfp :: proc(t: u32) -> u32 {return sp(0x64, 0xf, t, 0)}
	DIV_0 :: 0x40 << 25 | 0b0011 << 21 | 5 << 16 | 0x3bc // DIV Q, vf0w, vf5x: 1 / 0, D
	RSQRT_0 :: 0x40 << 25 | 0b0011 << 21 | 5 << 16 | 0x3be // RSQRT Q, vf0w, vf5x: 1 / sqrt 0, D
	DIV_2 :: 0x40 << 25 | 0b0011 << 21 | 6 << 16 | 0x3bc // DIV Q, vf0w, vf6x: 1 / 2
	WAITQ :: 0x40 << 25 | 0x3bf
	nops :: [2]u32{NOP_L, NOP_U}
	end :: [2]u32{NOP_L, NOP_U | E}
	// VU0 from addr with vf1 + vf2 negative (MAC 0xf0), vf5 0, vf6.x 2.
	call := proc(addr: u32) {
		v := &vu.vu0
		v.vf[1].f, v.vf[2].f = {-1, -2, -3, -4}, {}
		for r in 3 ..< 32 {v.vf[r] = {}}
		v.vf[6].f = {2, 2, 2, 2}
		v.vi = {}
		v.vi[2] = 0xffff
		v.mac, v.status, v.clip = 0, 0, 0
		v.old_mac, v.old_status, v.old_clip = {}, {}, {}
		v.q, v.q_wait = 3, 0
		vu.vu_op(v, 0x4a000038 | (addr / 8) << 6) // VCALLMS
	}
	v := &vu.vu0

	// DIV, an ADD that changes MAC, a WAITQ for the 5 cycles left, then
	// FMAND: the stall ages MAC past the 4-pair delay, so it sees the ADD's.
	put_pairs(0x900, {DIV_2, NOP_U}, {NOP_L, add(3, 1, 2)}, {WAITQ, NOP_U}, {fmand(4), NOP_U}, end, nops)
	call(0x900)
	if v.vi[4] != 0xf0 || v.q != 0.5 {fail("WAITQ stall: FMAND %x Q %v, want f0 0.5", v.vi[4], v.q)}
	// Without the WAITQ it is two pairs after the ADD, and does not.
	put_pairs(0x900, {DIV_2, NOP_U}, {NOP_L, add(3, 1, 2)}, nops, {fmand(4), NOP_U}, end, nops)
	call(0x900)
	if v.vi[4] != 0 {fail("no stall: FMAND %x, want 0", v.vi[4])}

	// DIV by 0: sticky D (read at once) from DIV +3, D itself (read 4
	// pairs late) from DIV +7.
	put_pairs(0xa00, {DIV_0, NOP_U}, {fsand(3, 0x800), NOP_U}, {fsand(4, 0x800), NOP_U}, {fsand(5, 0x800), NOP_U}, nops, nops,
		{fsand(6, 0x20), NOP_U}, {fsand(7, 0x20), NOP_U}, end, nops)
	call(0xa00)
	got := [5]u16{v.vi[3], v.vi[4], v.vi[5], v.vi[6], v.vi[7]}
	if got != ([5]u16{0, 0, 0x800, 0, 0x20}) {fail("DIV D timing: +1 +2 +3 DS, +6 +7 D = %x, want 0 0 800 0 20", got)}
	// RSQRT: sticky from +9, D from +13.
	put_pairs(0xa00, {RSQRT_0, NOP_U}, nops, nops, nops, nops, nops, nops, nops, {fsand(3, 0x800), NOP_U}, {fsand(4, 0x800), NOP_U},
		nops, nops, {fsand(5, 0x20), NOP_U}, {fsand(6, 0x20), NOP_U}, end, nops)
	call(0xa00)
	got4 := [4]u16{v.vi[3], v.vi[4], v.vi[5], v.vi[6]}
	if got4 != ([4]u16{0, 0x800, 0, 0x20}) {fail("RSQRT D timing: +8 +9 DS, +12 +13 D = %x, want 0 800 0 20", got4)}
	// Q's wait reaches 4 inside a WAITQ's stall: the WAITQ pair sets D once
	// the flags it starts with are taken, so D reads from +5, sticky D at +2.
	put_pairs(0xa00, {DIV_0, NOP_U}, {WAITQ, NOP_U}, {fsand(3, 0x800), NOP_U}, nops, {fsand(4, 0x20), NOP_U}, {fsand(5, 0x20), NOP_U}, end, nops)
	call(0xa00)
	got3 := [3]u16{v.vi[3], v.vi[4], v.vi[5]}
	if got3 != ([3]u16{0x800, 0, 0x20}) {fail("WAITQ stall D timing: +2 DS, +4 +5 D = %x, want 800 0 20", got3)}
	// The E bit's end sets them.
	put_pairs(0xa00, {DIV_0, NOP_U | E}, nops)
	call(0xa00)
	if v.status & 0x830 != 0x820 || v.q_wait != 0 {fail("DIV D at the end: status %x wait %d, want 820 0", v.status, v.q_wait)}
	// Back-to-back: the second DIV's stall sets the first's D, its own
	// clears it, leaving only the sticky bit.
	put_pairs(0xa00, {DIV_0, NOP_U}, {DIV_2, NOP_U}, {fsand(3, 0x800), NOP_U}, nops, end, nops)
	call(0xa00)
	if v.vi[3] != 0x800 || v.status & 0x830 != 0x800 || v.q != 0.5 {fail("back-to-back DIV: DS %x status %x Q %v, want 800 800 0.5", v.vi[3], v.status & 0x830, v.q)}

	// A loop of three runs: each DIV after the first stalls 3 cycles to
	// land the one before, 1 / 2, 1 / 4 and 1 / 8 as the ADD in its pair
	// doubles vf6; ADDq sums Q three times a run: 3 3 3, 1/2 x3, 1/4 x3.
	// The IBNE reads vi1 from before the IADDI (the branch VI delay), so
	// it counts from 2 to 0, leaving vi1 -1; the IADDIU is out of its
	// reach.
	ADDQ :: 0xf << 21 | 3 << 11 | 3 << 6 | 0x20 // ADDq.xyzw vf3, vf3, Q
	put_pairs(0xb00, {0x08 << 25 | 1 << 16 | 2, NOP_U}, nops, nops, {DIV_2, add(6, 6, 6)}, {0x40 << 25 | 1 << 16 | 1 << 11 | 0x1f << 6 | 0x32, ADDQ},
		{0x29 << 25 | 1 << 16 | 0x7fd, ADDQ}, {NOP_L, ADDQ}, {NOP_L, 0xf << 21 | 5 << 6 | 0x1c | E}, nops)
	call(0xb00)
	if v.vf[3].f.x != 11.25 || v.vf[5].f.w != 0.25 || v.q != 0.125 || v.vi[1] != 0xffff {fail("Q loop: sum %v MULq %v Q %v vi1 %x, want 11.25 0.25 0.125 ffff", v.vf[3].f.x, v.vf[5].f.w, v.q, v.vi[1])}

	// VU1's EFU: each op, then MFP at issue + latency - 1 (the old P) and
	// + latency (the new).
	u := &vu.vu1
	call1 := proc(code: []u32) {
		u := &vu.vu1
		u.vf[1].f = {2, 3, 4, 5}
		u.vf[8].f, u.vf[9].f = {-1, -2, -3, -4}, {}
		for r in 3 ..< 8 {u.vf[r] = {}}
		u.vi = {}
		u.vi[2] = 0xffff
		u.mac, u.old_mac = 0, {}
		u.p, u.p_wait = 1, 0
		mpg(&vu.vifs[1], code)
		vu.vu1_start(0)
	}
	LATENCY := [?][2]u32{{0x70, 11}, {0x71, 18}, {0x72, 18}, {0x73, 24}, {0x74, 54}, {0x75, 54}, {0x76, 12}, {0x78, 12}, {0x79, 18}, {0x7a, 12}, {0x7c, 29}, {0x7d, 54}, {0x7e, 44}}
	for l in LATENCY {
		code := make([dynamic]u32, context.temp_allocator)
		append(&code, sp(l[0], 0b1110, 0, 1), NOP_U)
		for _ in 0 ..< l[1] - 2 {append(&code, NOP_L, NOP_U)}
		append(&code, mfp(3), NOP_U, mfp(4), NOP_U, NOP_L, NOP_U | E, NOP_L, NOP_U)
		call1(code[:])
		if u.vf[3].f.x != 1 || u.vf[4].f.x != u.p || u.p == 1 || u.p_wait != 0 {
			fail("EFU %x latency %d: P at -1 %v, at it %v, end %v", l[0], l[1], u.vf[3].f.x, u.vf[4].f.x, u.p)
		}
	}
	ESQRT :: 0x40 << 25 | 1 << 11 | 0x7bc // ESQRT P, vf1x: sqrt 2
	ERCPR :: 0x40 << 25 | 1 << 11 | 0x7be // ERCPR P, vf1x: 1 / 2
	// WAITP after an ADD that changes MAC: 9 stall cycles (12 less the 2
	// pairs run, less 1), so FMAND after it sees the ADD's, and P has landed.
	code := [?]u32{ESQRT, NOP_U, NOP_L, add(7, 8, 9), sp(0x7b, 0, 0, 0), NOP_U, fmand(4), NOP_U, mfp(5), NOP_U, NOP_L, NOP_U | E, NOP_L, NOP_U}
	call1(code[:])
	if u.vi[4] != 0xf0 || u.vf[5].f.x != f32(1.4142135) {fail("WAITP stall: FMAND %x P %v, want f0 1.4142135", u.vi[4], u.vf[5].f.x)}
	// An EFU op lands the one before it; one pending at the E bit lands at
	// the end.
	code2 := [?]u32{ESQRT, NOP_U, ERCPR, NOP_U, mfp(6), NOP_U, NOP_L, NOP_U | E, NOP_L, NOP_U}
	call1(code2[:])
	if u.vf[6].f.x != f32(1.4142135) || u.p != 0.5 || u.p_wait != 0 {fail("EFU after EFU: MFP %v P %v wait %d, want 1.4142135 0.5 0", u.vf[6].f.x, u.p, u.p_wait)}
}

@(private = "file")
flag_delay :: proc() {
	NOP_L :: 0x8000033c
	NOP_U :: 0x000002ff
	E :: 1 << 30
	ADD_3_1_2 :: 0xf << 21 | 2 << 16 | 1 << 11 | 3 << 6 | 0x28 // VADD.xyzw vf3, vf1, vf2
	CLIP_1_2 :: 0xe << 21 | 2 << 16 | 1 << 11 | 0x1ff // VCLIPw.xyz vf1, vf2
	fmand :: proc(t: u32) -> u32 {return 0x1a << 25 | t << 16 | 2 << 11} // FMAND vi<t>, vi2
	fcget :: proc(t: u32) -> u32 {return 0x1c << 25 | t << 16}
	fsand :: proc(t: u32) -> u32 {return 0x16 << 25 | t << 16 | 0x82} // FSAND vi<t>, S | SS
	v := &vu.vu0
	call := proc(v: ^vu.Vu, addr: u32) {
		v.vf[1].f = {-1, -2, -3, -4}
		v.vf[2].f = {0, 0, 0, 0.5}
		v.vi = {}
		v.vi[2] = 0xffff
		v.mac, v.status, v.clip = 0, 0, 0
		vu.vu_op(v, 0x4a000038 | (addr / 8) << 6) // VCALLMS
	}
	// The ADD sets the four sign bits of MAC (0xf0) and status S and SS; the
	// CLIP sets the three minus bits (0x2a).
	put_pairs(0x200, {NOP_L, ADD_3_1_2}, {fmand(1), NOP_U}, {fsand(3), CLIP_1_2}, {fmand(4), NOP_U}, {fmand(5), NOP_U}, {fcget(6), NOP_U}, {fcget(7), NOP_U | E}, {fsand(8), NOP_U})
	call(v, 0x200)
	want := [?][2]u16{{1, 0}, {3, 0x80}, {4, 0}, {5, 0xf0}, {6, 0}, {7, 0x2a}, {8, 0x82}}
	for w in want {if v.vi[w[0]] != w[1] {fail("flag delay: vi%d = %x, want %x", w[0], v.vi[w[0]], w[1])}}

	// B over a pair: the FMAND after it is the third pair run after the ADD.
	B_2 :: 0x20 << 25 | 2 // B +2
	put_pairs(0x300, {NOP_L, ADD_3_1_2}, {B_2, NOP_U}, {NOP_L, NOP_U}, {fmand(9), NOP_U}, {fmand(4), NOP_U}, {fmand(5), NOP_U | E}, {NOP_L, NOP_U})
	call(v, 0x300)
	if v.vi[9] != 0 || v.vi[4] != 0 || v.vi[5] != 0xf0 {fail("flag delay over a branch: vi9 %x vi4 %x vi5 %x, want 0 0 f0", v.vi[9], v.vi[4], v.vi[5])}

	// A new program sees the flags the last one (or the EE) left at once.
	put_pairs(0x400, {fmand(1), NOP_U | E}, {NOP_L, NOP_U})
	v.mac = 0x1234
	v.vi[1], v.vi[2] = 0, 0xffff
	vu.vu_op(v, 0x4a000038 | (0x400 / 8) << 6)
	if v.vi[1] != 0x1234 {fail("flag delay at a program's start: vi1 = %x, want 1234", v.vi[1])}

	// VU1 delays its MAC too.
	vu.vu1.vf[1].f = {-1, -2, -3, -4}
	vu.vu1.vf[2] = {}
	vu.vu1.vi = {}
	vu.vu1.vi[2] = 0xffff
	vu.vu1.mac = 0
	code := [?]u32{NOP_L, ADD_3_1_2, fmand(4), NOP_U, NOP_L, NOP_U, fmand(3), NOP_U, fmand(5), NOP_U | E, NOP_L, NOP_U}
	mpg(&vu.vifs[1], code[:])
	vu.vu1_start(0)
	if vu.vu1.vi[4] != 0 || vu.vu1.vi[3] != 0 || vu.vu1.vi[5] != 0xf0 {fail("VU1 flag delay: vi4 %x vi3 %x vi5 %x, want 0 0 f0", vu.vu1.vi[4], vu.vu1.vi[3], vu.vu1.vi[5])}
}

@(private = "file")
ibit :: proc() {
	v := &vu.vifs[1]
	stat := mem.hw_reg(vu.VIF0_STAT + 0x400)
	mem.intc_stat = 0
	// STCYCL with the i-bit, then BASE 5, ITOPS 7.
	feed(v, 0x81000404, 0x03000005, 0x04000007)
	if v.cl != 4 || v.wl != 4 {fail("i-bit STCYCL did not run: cl %d wl %d", v.cl, v.wl)}
	if v.base != 0 || v.itops != 0 {fail("VIF1 ran past its i-bit: base %d itops %d", v.base, v.itops)}
	if !v.stalled || stat^ & (vu.VIF_STAT_VIS | vu.VIF_STAT_INT) != vu.VIF_STAT_VIS | vu.VIF_STAT_INT {fail("i-bit: stalled %v STAT %x", v.stalled, stat^)}
	if mem.intc_stat != 1 << 5 {fail("i-bit raised INTC %x, want VIF1's", mem.intc_stat)}
	// A later transfer waits too; MODE 1.
	mem.intc_stat = 0
	feed(v, 0x05000001)
	if v.mode != 0 || mem.intc_stat != 0 {fail("a stalled VIF1 ran a transfer: mode %d INTC %x", v.mode, mem.intc_stat)}
	vu.vif_fbrst(1, 8)
	if v.stalled || stat^ & vu.VIF_STAT_STALL != 0 {fail("STC: stalled %v STAT %x", v.stalled, stat^)}
	if v.base != 5 || v.itops != 7 || v.mode != 1 {fail("STC: base %d itops %d mode %d, want 5 7 1", v.base, v.itops, v.mode)}
	if mem.intc_stat != 0 || len(v.pending) != 0 {fail("STC: INTC %x, %d bytes left", mem.intc_stat, len(v.pending))}

	// VIF0 raises its own INTC; with MII it neither raises nor stalls.
	feed(&vu.vifs[0], 0x80000000)
	if !vu.vifs[0].stalled || mem.intc_stat != 1 << 4 {fail("VIF0 i-bit: stalled %v INTC %x", vu.vifs[0].stalled, mem.intc_stat)}
	vu.vif_fbrst(0, 8)
	mem.intc_stat = 0
	mem.hw_reg(vu.VIF0_ERR + 0x400)^ = vu.VIF_ERR_MII
	feed(v, 0x83000009, 0x05000000)
	if v.stalled || mem.intc_stat != 0 || v.base != 9 || v.mode != 0 {fail("MII i-bit: stalled %v INTC %x base %d mode %d", v.stalled, mem.intc_stat, v.base, v.mode)}
	mem.hw_reg(vu.VIF0_ERR + 0x400)^ = 0
	v.cl, v.wl, v.base, v.itops = 1, 1, 0, 0
	mem.intc_stat, mem.intc_pending = 0, 0
}

// One A+D qword: data to GS register reg.
@(private = "file")
gif_ad :: proc(reg: u8, data: u32) -> [4]u32 {return {data, 0, u32(reg), 0}}

// A PACKED GIFtag of nloop A+D qwords, with EOP.
@(private = "file")
gif_tag :: proc(nloop: u32) -> [4]u32 {return {nloop | 1 << 15, 1 << 28, 0xe, 0}}

@(private = "file")
gif_paths :: proc() {
	tag, ad40, ad41, ad42 := gif_tag(2), gif_ad(0x40, 0x1111), gif_ad(0x41, 0x2222), gif_ad(0x42, 0x3333)
	gs.state.regs[0x40], gs.state.regs[0x41], gs.state.regs[0x42] = 0, 0, 0
	// DIRECT 2: the tag and the first of its two A+D qwords.
	feed(&vu.vifs[1], 0x50000002, tag[0], tag[1], tag[2], tag[3], ad40[0], ad40[1], ad40[2], ad40[3])
	kick := [2][4]u32{gif_tag(1), ad41}
	copy(vu.vu1_mem[:32], ([^]u8)(&kick)[:32])
	vu.vu1_xgkick(0)
	vu.vu1_kick_flush()
	if gs.state.regs[0x41] != 0 {fail("XGKICK inside a split DIRECT packet went in before the packet's end")}
	feed(&vu.vifs[1], 0x50000001, ad42[0], ad42[1], ad42[2], ad42[3])
	r := gs.state.regs
	if r[0x40] != 0x1111 || r[0x41] != 0x2222 || r[0x42] != 0x3333 {
		fail("XGKICK inside a split DIRECT packet: GS 40 %x 41 %x 42 %x, want 1111 2222 3333", r[0x40], r[0x41], r[0x42])
	}
	gif_slices(true)
	gif_slices(false)
	gif_directhl()
	gif_rst()
	gif_stat_bits()
	gif_mask()
	gif_mask_rst()
	gif_guard()
}

// What each host-to-local transfer carried: its bytes, and GS register
// 0x41 (written by the test's XGKICK) when it came.
@(private = "file")
Gif_Image :: struct {
	bytes: int,
	r41:   u64,
}

@(private = "file")
gif_images: [dynamic]Gif_Image

@(private = "file")
gif_image_log :: proc(d: []u8) {append(&gif_images, Gif_Image{len(d), gs.state.regs[0x41]})}

// An IMAGE GIFtag of nloop qwords, with EOP, then the image qwords.
@(private = "file")
gif_image :: proc(nloop: u32) -> []u8 {
	b := make([]u8, 16 * (1 + int(nloop)), context.temp_allocator)
	w := ([^]u32)(raw_data(b))
	w[0], w[1] = nloop | 1 << 15, 2 << 26
	return b
}

// Put the XGKICK packet (A+D 0x2222 to 0x41) in VU1 memory and kick it.
@(private = "file")
gif_kick :: proc() {
	kick := [2][4]u32{gif_tag(1), gif_ad(0x41, 0x2222)}
	copy(vu.vu1_mem[:32], ([^]u8)(&kick)[:32])
	vu.vu1_xgkick(0)
	vu.vu1_kick_flush()
}

@(private = "file")
gif_clear :: proc() {
	gs.state.regs[0x40], gs.state.regs[0x41], gs.state.regs[0x42] = 0, 0, 0
	mem.hw_reg(0x3010)^ = 0 // GIF_MODE
	gif.gif_mskpath3(false)
	clear(&gif_images)
}

// PATH3 holds the GIF in an open PACKED tag, so an XGKICK waits; the next
// PATH3 feed ends that tag and sends a 32-qword IMAGE, which with IMT
// stops after 8 qwords for the XGKICK.
@(private = "file")
gif_slices :: proc(imt: bool) {
	gif_clear()
	gs.state.transfer = gif_image_log
	defer gs.state.transfer = nil
	if imt {mem.hw_reg(0x3010)^ = 4}
	open := [2][4]u32{{1, 1 << 28, 0xe, 0}, gif_ad(0x40, 0x1111)} // no EOP
	gif.gif_feed(2, ([^]u8)(&open)[:32])
	gif_kick()
	if gs.state.regs[0x41] != 0 {fail("XGKICK went in while PATH3 held the GIF (imt %v)", imt)}
	gif.gif_feed(2, gif_image(32))
	g := gif_images[:]
	if gs.state.regs[0x41] != 0x2222 {fail("XGKICK still waits after PATH3's packet (imt %v)", imt)}
	if imt {
		if len(g) != 2 || g[0] != {128, 0} || g[1] != {384, 0x2222} {fail("IMT slice: transfers %v, want 128 bytes before the XGKICK and 384 after", g)}
	} else if len(g) != 1 || g[0] != {512, 0} {
		fail("no IMT: transfers %v, want 512 bytes before the XGKICK", g)
	}
	// IMT: an XGKICK during an IMAGE fed in two parts goes in between them.
	if !imt {return}
	gif_clear()
	mem.hw_reg(0x3010)^ = 4
	img := gif_image(32)
	gif.gif_feed(2, img[:256])
	gif_kick()
	if gs.state.regs[0x41] != 0x2222 {fail("IMT: XGKICK between two parts of an IMAGE waited")}
	gif.gif_feed(2, img[256:])
	if len(gif_images) != 2 || gif_images[1] != {272, 0x2222} {fail("IMT: IMAGE's second part %v", gif_images[:])}
}

// A DIRECTHL during a PATH3 IMAGE stalls VIF1, IMT or not, and goes in
// once the IMAGE ends.
@(private = "file")
gif_directhl :: proc() {
	gif_clear()
	mem.hw_reg(0x3010)^ = 4
	img := gif_image(32)
	gif.gif_feed(2, img[:256])
	tag, ad42 := gif_tag(1), gif_ad(0x42, 0x3333)
	feed(&vu.vifs[1], 0x51000002, tag[0], tag[1], tag[2], tag[3], ad42[0], ad42[1], ad42[2], ad42[3])
	if gs.state.regs[0x42] != 0 || !vu.vifs[1].gif_wait {fail("DIRECTHL during a PATH3 IMAGE: GS 42 %x, VIF1 waiting %v", gs.state.regs[0x42], vu.vifs[1].gif_wait)}
	gif.gif_feed(2, img[256:])
	if gs.state.regs[0x42] != 0x3333 || vu.vifs[1].gif_wait {fail("DIRECTHL after the IMAGE: GS 42 %x, VIF1 waiting %v", gs.state.regs[0x42], vu.vifs[1].gif_wait)}
	gif_clear()
}

// GIF_CTRL.RST while PATH3 is inside a packet, an XGKICK waits and VIF1
// holds a DIRECT: the XGKICK is dropped, the DIRECT goes in, and PATH3's
// next qword is a tag. Then VIF1's FBRST.RST while it holds a DIRECT: the
// DIRECT and the code after it are dropped, and the end of PATH3's packet
// lets nothing in. Last, VIF0's FBRST.RST drops a code waiting out an
// i-bit stall.
@(private = "file")
gif_rst :: proc() {
	gif_clear()
	held := [2][4]u32{{2 | 1 << 15, 1 << 28, 0xe, 0}, gif_ad(0x40, 0x1111)} // 2 loops, 1 sent
	tag, ad42 := gif_tag(1), gif_ad(0x42, 0x3333)
	gif.gif_feed(2, ([^]u8)(&held)[:32])
	gif_kick()
	feed(&vu.vifs[1], 0x50000002, tag[0], tag[1], tag[2], tag[3], ad42[0], ad42[1], ad42[2], ad42[3])
	if gs.state.regs[0x42] != 0 || !vu.vifs[1].gif_wait {fail("DIRECT while PATH3 holds the GIF: GS 42 %x, VIF1 waiting %v", gs.state.regs[0x42], vu.vifs[1].gif_wait)}
	gif.gif_reset()
	r := gs.state.regs
	if r[0x41] != 0 || r[0x42] != 0x3333 || vu.vifs[1].gif_wait {
		fail("GIF_CTRL.RST: GS 41 %x 42 %x, VIF1 waiting %v, want 0 3333 false", r[0x41], r[0x42], vu.vifs[1].gif_wait)
	}
	pkt := [2][4]u32{gif_tag(1), gif_ad(0x40, 0x4444)}
	gif.gif_feed(2, ([^]u8)(&pkt)[:32])
	if gs.state.regs[0x40] != 0x4444 {fail("GIF_CTRL.RST: PATH3 did not start again on a tag: GS 40 %x", gs.state.regs[0x40])}

	gif_clear()
	gif.gif_feed(2, ([^]u8)(&held)[:32])
	feed(&vu.vifs[1], 0x50000002, tag[0], tag[1], tag[2], tag[3], ad42[0], ad42[1], ad42[2], ad42[3], 0x01000404)
	cl := vu.vifs[1].cl
	vu.vif_fbrst(1, 1)
	if len(vu.vifs[1].pending) != 0 || vu.vifs[1].gif_wait {fail("VIF1 FBRST.RST: %d bytes pending, waiting %v", len(vu.vifs[1].pending), vu.vifs[1].gif_wait)}
	end := gif_ad(0x41, 0x5555)
	gif.gif_feed(2, ([^]u8)(&end)[:16])
	r = gs.state.regs
	if r[0x41] != 0x5555 || r[0x42] != 0 || vu.vifs[1].cl != cl {
		fail("VIF1 FBRST.RST: GS 41 %x 42 %x, CL %d, want 5555 0 %d", r[0x41], r[0x42], vu.vifs[1].cl, cl)
	}

	cl = vu.vifs[0].cl
	feed(&vu.vifs[0], 0x80000000, 0x01000404) // NOP with the i-bit, then STCYCL 4,4
	if !vu.vifs[0].stalled {fail("VIF0 i-bit did not stall")}
	vu.vif_fbrst(0, 1)
	vu.vif_fbrst(0, 8)
	stat := mem.hw_reg(vu.VIF0_STAT)^
	if vu.vifs[0].stalled || len(vu.vifs[0].pending) != 0 || stat & vu.VIF_STAT_STALL != 0 || vu.vifs[0].cl != cl {
		fail("VIF0 FBRST.RST: stalled %v, %d bytes pending, STAT %x, CL %d, want CL %d", vu.vifs[0].stalled, len(vu.vifs[0].pending), stat, vu.vifs[0].cl, cl)
	}
	mem.intc_stat, mem.intc_pending = 0, 0
	gif_clear()
}

// GIF_STAT bits as named, for the checks below.
@(private = "file")
M3R, M3P, P3Q, P2Q, P1Q, OPH :: 1, 2, 1 << 6, 1 << 7, 1 << 8, 1 << 9

@(private = "file")
apath :: proc(p: u32) -> u32 {return p << 10 | OPH}

@(private = "file")
fqc :: proc(n: u32) -> u32 {return n << 24}

// GIF_STAT while a DIRECT holds the GIF in a split packet (APATH 2), with
// an XGKICK queued behind it (P1Q), then while PATH3 holds it in an open
// packet and VIF1 holds a DIRECT (APATH 3, P2Q). Idle, it reads 0.
@(private = "file")
gif_stat_bits :: proc() {
	gif_clear()
	tag, ad40, ad41, ad42 := gif_tag(2), gif_ad(0x40, 0x1111), gif_ad(0x41, 0x2222), gif_ad(0x42, 0x3333)
	feed(&vu.vifs[1], 0x50000002, tag[0], tag[1], tag[2], tag[3], ad40[0], ad40[1], ad40[2], ad40[3])
	if s := gif.gif_stat(0); s != apath(2) {fail("GIF_STAT in a split DIRECT packet %x, want %x", s, apath(2))}
	gif_kick()
	if s := gif.gif_stat(0); s != apath(2) | P1Q {fail("GIF_STAT with an XGKICK queued %x, want %x", s, apath(2) | P1Q)}
	feed(&vu.vifs[1], 0x50000001, ad42[0], ad42[1], ad42[2], ad42[3])
	if s := gif.gif_stat(0); s != 0 || gs.state.regs[0x41] != 0x2222 {fail("GIF_STAT after the DIRECT and XGKICK %x, GS 41 %x", s, gs.state.regs[0x41])}

	held := [2][4]u32{{2 | 1 << 15, 1 << 28, 0xe, 0}, ad40} // 2 loops, 1 sent
	gif.gif_feed(2, ([^]u8)(&held)[:32])
	t1 := gif_tag(1)
	feed(&vu.vifs[1], 0x50000002, t1[0], t1[1], t1[2], t1[3], ad41[0], ad41[1], ad41[2], ad41[3])
	if s := gif.gif_stat(0); s != apath(3) | P2Q {fail("GIF_STAT with a DIRECT held behind PATH3 %x, want %x", s, apath(3) | P2Q)}
	gif.gif_feed(2, ([^]u8)(&ad42)[:16])
	if s := gif.gif_stat(0); s != 0 || vu.vifs[1].gif_wait {fail("GIF_STAT after PATH3's packet %x, VIF1 waiting %v", s, vu.vifs[1].gif_wait)}
	gif_clear()
}

// Start a GIF DMA (normal mode) of an A+D packet of `loops` qwords, each
// writing data to GS register reg, as dma_start does; returns whether STR
// stays set.
@(private = "file")
gif_dma :: proc(reg: u8, data: u32, loops: u32 = 1) -> bool {
	if mem.ram == nil {mem.mem_init()}
	pkt: [GIF_BIG + 1][4]u32
	pkt[0] = gif_tag(loops)
	for i in 1 ..= loops {pkt[i] = gif_ad(reg, data)}
	n := int(loops + 1) * 16
	copy(mem.ram[0x2000:][:n], ([^]u8)(&pkt)[:n])
	mem.dma_reg(mem.DMA_GIF, 0x00)^ = 0x101 // STR, normal
	mem.dma_reg(mem.DMA_GIF, 0x10)^ = 0x2000
	mem.dma_reg(mem.DMA_GIF, 0x20)^ = loops + 1
	dma.dma_gif()
	if !gif.gif_dma_hold() {mem.dma_finish(mem.DMA_GIF)}
	return mem.dma_reg(mem.DMA_GIF, 0x00)^ & 0x100 != 0
}

// Loops in a GIF DMA packet bigger than the 16-qword GIF FIFO.
@(private = "file")
GIF_BIG :: 20

// MSKPATH3 before a PATH3 packet: a packet that fits the GIF FIFO waits
// (M3P, P3Q, FQC 2) and its DMA finishes; MSKPATH3 off runs it. A bigger
// one waits with STR set (FQC 16), and MSKPATH3 off runs it and finishes
// the channel.
// MSKPATH3 inside a packet: the packet runs to its EOP, and the next waits.
// GIF_MODE.M3R masks it the same with MSKPATH3 off.
@(private = "file")
gif_mask :: proc() {
	gif_clear()
	feed(&vu.vifs[1], 0x06008000) // MSKPATH3 on
	if gif_dma(0x40, 0x1111) || gs.state.regs[0x40] != 0 {fail("masked small PATH3: STR %v, GS 40 %x, want STR clear and 0", mem.dma_reg(mem.DMA_GIF, 0)^ & 0x100 != 0, gs.state.regs[0x40])}
	if s := gif.gif_stat(0); s != M3P | P3Q | fqc(2) {fail("GIF_STAT with masked PATH3 waiting %x, want %x", s, M3P | P3Q | fqc(2))}
	feed(&vu.vifs[1], 0x06000000) // MSKPATH3 off
	if gs.state.regs[0x40] != 0x1111 || gif.gif_stat(0) != 0 {fail("MSKPATH3 off: GS 40 %x, GIF_STAT %x, want 1111 and 0", gs.state.regs[0x40], gif.gif_stat(0))}

	gif_clear()
	feed(&vu.vifs[1], 0x06008000)
	if !gif_dma(0x40, 0x1111, GIF_BIG) || gs.state.regs[0x40] != 0 {fail("masked PATH3: STR %v, GS 40 %x, want STR set and 0", mem.dma_reg(mem.DMA_GIF, 0)^ & 0x100 != 0, gs.state.regs[0x40])}
	if s := gif.gif_stat(0); s != M3P | P3Q | fqc(16) {fail("GIF_STAT with a big masked PATH3 waiting %x, want %x", s, M3P | P3Q | fqc(16))}
	feed(&vu.vifs[1], 0x06000000)
	if gs.state.regs[0x40] != 0x1111 || mem.dma_reg(mem.DMA_GIF, 0)^ & 0x100 != 0 || gif.gif_stat(0) != 0 {
		fail("MSKPATH3 off: GS 40 %x, CHCR %x, GIF_STAT %x, want 1111, STR clear, 0", gs.state.regs[0x40], mem.dma_reg(mem.DMA_GIF, 0)^, gif.gif_stat(0))
	}

	// VIF1 FBRST.RST lifts MSKPATH3: the held packet runs, the channel finishes.
	gif_clear()
	feed(&vu.vifs[1], 0x06008000)
	if !gif_dma(0x40, 0x5555, GIF_BIG) {fail("VIF1 RST: masked big GIF DMA did not hold STR")}
	vu.vif_fbrst(1, 1)
	if gs.state.regs[0x40] != 0x5555 || mem.dma_reg(mem.DMA_GIF, 0)^ & 0x100 != 0 || gif.gif_stat(0) != 0 {
		fail("VIF1 RST: GS 40 %x, CHCR %x, GIF_STAT %x, want 5555, STR clear, 0", gs.state.regs[0x40], mem.dma_reg(mem.DMA_GIF, 0)^, gif.gif_stat(0))
	}
	mem.dmac_stat = 0

	gif_clear()
	open := [2][4]u32{{2 | 1 << 15, 1 << 28, 0xe, 0}, gif_ad(0x40, 0x1111)} // 2 loops, 1 sent
	gif.gif_feed(2, ([^]u8)(&open)[:32])
	feed(&vu.vifs[1], 0x06008000)
	if s := gif.gif_stat(0); s != M3P | apath(3) {fail("MSKPATH3 inside a packet: GIF_STAT %x, want %x", s, M3P | apath(3))}
	rest := [3][4]u32{gif_ad(0x41, 0x2222), gif_tag(1), gif_ad(0x42, 0x3333)}
	gif.gif_feed(2, ([^]u8)(&rest)[:48])
	r := gs.state.regs
	if r[0x41] != 0x2222 || r[0x42] != 0 {fail("MSKPATH3 inside a packet: GS 41 %x 42 %x, want 2222 0", r[0x41], r[0x42])}
	mem.hw_reg(0x3010)^ = 1 // GIF_MODE.M3R
	gif.gif_mask_changed()
	feed(&vu.vifs[1], 0x06000000)
	if s := gif.gif_stat(0); s != M3R | P3Q | fqc(2) || gs.state.regs[0x42] != 0 {fail("GIF_MODE.M3R: GIF_STAT %x, GS 42 %x, want %x and 0", s, gs.state.regs[0x42], M3R | P3Q | fqc(2))}
	mem.hw_reg(0x3010)^ = 0
	gif.gif_mask_changed()
	if s := gif.gif_stat(0); s != 0 || gs.state.regs[0x42] != 0x3333 {fail("GIF_MODE.M3R off: GIF_STAT %x, GS 42 %x, want 0 and 3333", s, gs.state.regs[0x42])}
	gif_clear()
}

// GIF_CTRL.RST with MSKPATH3 and M3R set and a masked GIF DMA held: the
// packet is dropped, the channel finishes, the masks clear, and the next
// PATH3 packet goes in.
@(private = "file")
gif_mask_rst :: proc() {
	gif_clear()
	feed(&vu.vifs[1], 0x06008000)
	mem.hw_reg(0x3010)^ = 1
	gif.gif_mask_changed()
	if !gif_dma(0x40, 0x1111, GIF_BIG) {fail("GIF_CTRL.RST: masked GIF DMA did not hold STR")}
	gif.gif_reset()
	if mem.dma_reg(mem.DMA_GIF, 0)^ & 0x100 != 0 || mem.hw_reg(0x3010)^ != 0 || gif.gif_stat(0) != 0 || gs.state.regs[0x40] != 0 {
		fail("GIF_CTRL.RST with masks: CHCR %x, GIF_MODE %x, GIF_STAT %x, GS 40 %x", mem.dma_reg(mem.DMA_GIF, 0)^, mem.hw_reg(0x3010)^, gif.gif_stat(0), gs.state.regs[0x40])
	}
	if gif_dma(0x40, 0x4444) || gs.state.regs[0x40] != 0x4444 {fail("GIF_CTRL.RST: PATH3 still masked, GS 40 %x", gs.state.regs[0x40])}
	mem.dmac_stat = 0
	gif_clear()
}

// A busy GIF_STAT read again with nothing fed in between is one compat row
// by the reader's return address, and reads the honest value; a feed in
// between, or an idle GIF, is no row.
@(private = "file")
gif_guard :: proc() {
	row :: proc(ra: u32) -> u64 {return core.compat.calls[{.Gif_Stat_Busy, ra, 0}].n}
	gif_clear()
	open := [2][4]u32{{4 | 1 << 15, 1 << 28, 0xe, 0}, gif_ad(0x40, 0x1111)} // 4 loops, 1 sent
	gif.gif_feed(2, ([^]u8)(&open)[:32])
	gif.gif_stat(0x1000)
	if row(0x1000) != 0 {fail("guard: a first busy GIF_STAT read was a compat row")}
	if s := gif.gif_stat(0x1000); s != apath(3) || row(0x1000) != 1 {fail("guard: busy read with no progress: GIF_STAT %x, row %d, want %x and 1", s, row(0x1000), apath(3))}
	ad := gif_ad(0x41, 0x2222)
	for _ in 0 ..< 2 {
		gif.gif_feed(2, ([^]u8)(&ad)[:16])
		gif.gif_stat(0x2000)
	}
	if row(0x2000) != 0 {fail("guard: a busy read after a feed was a compat row")}
	gif.gif_feed(2, ([^]u8)(&ad)[:16]) // the packet's last loop
	gif.gif_stat(0x3000)
	gif.gif_stat(0x3000)
	if row(0x3000) != 0 {fail("guard: an idle GIF_STAT read was a compat row")}
	gif_clear()
}

// A GIF chain with CHCR.TTE: cnt with a nonzero upper half, then end. Then a
// normal transfer whose packet must start on a tag. Then the chain into
// scratchpad, which takes the tags whole.
@(private = "file")
gif_tte :: proc() {
	if mem.ram == nil {mem.mem_init()}
	gs.state.regs[0x40], gs.state.regs[0x41] = 0, 0
	pkt := [2][4]u32{gif_tag(1), gif_ad(0x40, 0x1111)}
	mem.wr64(0x1000, 1 << 28 | 2) // cnt, 2 qwords
	mem.wr64(0x1008, 0x0102030405060708)
	copy(mem.ram[0x1010:][:32], ([^]u8)(&pkt)[:32])
	mem.wr64(0x1030, 7 << 28) // end, no data
	mem.wr64(0x1038, 0x1112131415161718)
	mem.dma_reg(mem.DMA_GIF, 0x00)^ = 0x145 // STR, TTE, chain
	mem.dma_reg(mem.DMA_GIF, 0x20)^ = 0
	mem.dma_reg(mem.DMA_GIF, 0x30)^ = 0x1000
	dma.dma_gif()
	pkt = {gif_tag(1), gif_ad(0x41, 0x2222)}
	copy(mem.ram[0x2000:][:32], ([^]u8)(&pkt)[:32])
	mem.dma_reg(mem.DMA_GIF, 0x00)^ = 0x101 // STR, normal
	mem.dma_reg(mem.DMA_GIF, 0x10)^ = 0x2000
	mem.dma_reg(mem.DMA_GIF, 0x20)^ = 2
	dma.dma_gif()
	r := gs.state.regs
	if r[0x40] != 0x1111 || r[0x41] != 0x2222 {fail("GIF chain with TTE: GS 40 %x 41 %x, want 1111 2222", r[0x40], r[0x41])}
	// The same chain into scratchpad: each whole tag goes ahead of its data.
	mem.spr = {}
	mem.dma_reg(mem.DMA_TO_SPR, 0x00)^ = 0x145
	mem.dma_reg(mem.DMA_TO_SPR, 0x20)^ = 0
	mem.dma_reg(mem.DMA_TO_SPR, 0x30)^ = 0x1000
	mem.dma_reg(mem.DMA_TO_SPR, 0x80)^ = 0
	dma.dma_to_spr()
	if !slice.equal(mem.spr[:64], mem.ram[0x1000:][:64]) || mem.dma_reg(mem.DMA_TO_SPR, 0x80)^ != 64 {
		fail("toSPR chain with TTE: SADR %x, want the 4 quadwords at 1000 and 40", mem.dma_reg(mem.DMA_TO_SPR, 0x80)^)
	}
}

// fromSPR in interleave mode, as one game sends a column of an image: 6
// quadwords in blocks of TQWC 2, skipping SQWC 3 of memory after each, so
// rows of 2 at 0x3000, 0x3050 and 0x30a0 with the gaps left as they were,
// and MADR past the last skip; the scratchpad read straight through. TQWC 0
// sends all of QWC as one block, skipping once.
@(private = "file")
spr_interleave :: proc() {
	if mem.ram == nil {mem.mem_init()}
	defer mem.hw_reg(0xe030)^ = 0
	for i in 0 ..< 6 {mem.spr[i * 16] = u8(0x10 + i)}
	start :: proc(sqwc, qwc: u32) {
		mem.hw_reg(0xe030)^ = sqwc
		for i in 0 ..< 0x100 {mem.ram[0x3000 + i] = 0xee}
		mem.dma_reg(mem.DMA_FROM_SPR, 0x00)^ = 0x108 // STR, interleave
		mem.dma_reg(mem.DMA_FROM_SPR, 0x10)^ = 0x3000
		mem.dma_reg(mem.DMA_FROM_SPR, 0x20)^ = qwc
		mem.dma_reg(mem.DMA_FROM_SPR, 0x80)^ = 0
		dma.dma_from_spr()
	}
	start(2 << 16 | 3, 6)
	want := [?]u8{0x10, 0x11, 0xee, 0xee, 0xee, 0x12, 0x13, 0xee, 0xee, 0xee, 0x14, 0x15, 0xee}
	for w, i in want {
		if mem.ram[0x3000 + i * 16] != w {fail("fromSPR interleave: qword %d at %x is %x, want %x", i, 0x3000 + i * 16, mem.ram[0x3000 + i * 16], w)}
	}
	madr, sadr := mem.dma_reg(mem.DMA_FROM_SPR, 0x10)^, mem.dma_reg(mem.DMA_FROM_SPR, 0x80)^
	if madr != 0x30f0 || sadr != 0x60 || mem.dma_reg(mem.DMA_FROM_SPR, 0x20)^ != 0 {
		fail("fromSPR interleave: MADR %x SADR %x, want 30f0 60, QWC 0", madr, sadr)
	}
	start(3, 4)
	for i in 0 ..< 4 {
		if mem.ram[0x3000 + i * 16] != u8(0x10 + i) {fail("fromSPR interleave TQWC 0: qword %d is %x, want %x", i, mem.ram[0x3000 + i * 16], 0x10 + i)}
	}
	if mem.dma_reg(mem.DMA_FROM_SPR, 0x10)^ != 0x3070 {fail("fromSPR interleave TQWC 0: MADR %x, want 3070", mem.dma_reg(mem.DMA_FROM_SPR, 0x10)^)}
}

// The GIF draining an MFIFO ring of 16 quadwords at 0x100000 that fromSPR
// fills: the drain stops on an empty ring with STR set and MEIS raised, a
// cnt tag's data wraps at the ring's top mid-transfer, each fromSPR transfer
// restarts the drain, and an end tag finishes it.
@(private = "file")
mfifo :: proc() {
	if mem.ram == nil {mem.ram = make([]u8, mem.RAM_SIZE)}
	BASE :: 0x100000
	gif_chcr := mem.dma_reg(mem.DMA_GIF, 0x00)
	spr_madr := mem.dma_reg(mem.DMA_FROM_SPR, 0x10)
	mem.hw_reg(dma.D_RBOR)^, mem.hw_reg(dma.D_RBSR)^ = BASE, 0xf0
	mem.hw_reg(dma.D_CTRL)^ = 3 << 2 // MFD: GIF
	spr_madr^ = BASE + 0xe0
	mem.dma_reg(mem.DMA_GIF, 0x20)^, mem.dma_reg(mem.DMA_GIF, 0x30)^ = 0, BASE + 0xe0
	mem.dmac_stat = 0
	gs.state.regs[0x40], gs.state.regs[0x41], gs.state.regs[0x42] = 0, 0, 0
	defer {
		mem.hw_reg(dma.D_CTRL)^ = 0
		mem.dmac_stat = 0
	}
	gif_chcr^ = 0x105 // source chain, STR
	if !dma.mfifo_owns(mem.DMA_GIF) {fail("mfifo: GIF does not own the ring under MFD 3")}
	if dma.mfifo_start(mem.DMA_GIF) || mem.dmac_stat & dma.D_STAT_MEIS == 0 {
		fail("mfifo: the drain of an empty ring did not stop with MEIS (stat %08x)", mem.dmac_stat)
	}
	from_spr :: proc(qws: [][4]u32) {
		copy(mem.spr[:], slice.to_bytes(qws))
		mem.dma_reg(mem.DMA_FROM_SPR, 0x00)^ = 0x100
		mem.dma_reg(mem.DMA_FROM_SPR, 0x20)^ = u32(len(qws))
		mem.dma_reg(mem.DMA_FROM_SPR, 0x80)^ = 0
		dma.dma_from_spr()
	}
	// cnt of 3 at 0x1000e0: its data runs 0x1000f0, then 0x100000 and 0x100010.
	mem.dmac_stat = 0
	part1 := [?][4]u32{{3 | 1 << 28, 0, 0, 0}, gif_tag(2), gif_ad(0x40, 0x1111), gif_ad(0x41, 0x2222)}
	from_spr(part1[:])
	r := gs.state.regs
	if r[0x40] != 0x1111 || r[0x41] != 0x2222 {fail("mfifo: data wrapped mid-transfer: GS 40 %x 41 %x, want 1111 2222", r[0x40], r[0x41])}
	if spr_madr^ != BASE + 0x20 {fail("mfifo: fromSPR MADR %08x, want %08x", spr_madr^, BASE + 0x20)}
	if gif_chcr^ & 0x100 == 0 || mem.dmac_stat & dma.D_STAT_MEIS == 0 {
		fail("mfifo: drain ran dry at 0x100020 but CHCR %08x stat %08x", gif_chcr^, mem.dmac_stat)
	}
	// end of 2 at 0x100020: the chain ends and the channel finishes.
	mem.dmac_stat = 0
	part2 := [?][4]u32{{2 | 7 << 28, 0, 0, 0}, gif_tag(1), gif_ad(0x42, 0x3333)}
	from_spr(part2[:])
	if gs.state.regs[0x42] != 0x3333 {fail("mfifo: GS 42 %x after the end tag, want 3333", gs.state.regs[0x42])}
	if gif_chcr^ & 0x100 != 0 || mem.dmac_stat & (1 << mem.DMA_GIF) == 0 || mem.dmac_stat & dma.D_STAT_MEIS != 0 {
		fail("mfifo: end tag did not finish GIF: CHCR %08x stat %08x", gif_chcr^, mem.dmac_stat)
	}
}

// An MFIFO GIF drain that reaches its end tag with more PATH3 data held
// behind MSKPATH3 than the GIF FIFO takes keeps STR set, as a GIF DMA from
// memory does; MSKPATH3 off runs the packet and finishes the channel.
@(private = "file")
mfifo_hold :: proc() {
	gif_clear()
	BASE :: 0x100000
	gif_chcr := mem.dma_reg(mem.DMA_GIF, 0x00)
	mem.hw_reg(dma.D_RBOR)^, mem.hw_reg(dma.D_RBSR)^ = BASE, 0x3f0 // 64 quadwords
	mem.hw_reg(dma.D_CTRL)^ = 3 << 2
	defer {
		mem.hw_reg(dma.D_CTRL)^ = 0
		mem.dmac_stat = 0
		gif_clear()
	}
	// end of GIF_BIG + 1 at the ring's base, with its data behind it.
	pkt: [GIF_BIG + 2][4]u32
	pkt[0] = {(GIF_BIG + 1) | 7 << 28, 0, 0, 0}
	pkt[1] = gif_tag(GIF_BIG)
	for i in 2 ..< GIF_BIG + 2 {pkt[i] = gif_ad(0x40, 0x6666)}
	copy(mem.ram[BASE:][:size_of(pkt)], slice.to_bytes(pkt[:]))
	mem.dma_reg(mem.DMA_FROM_SPR, 0x10)^ = BASE + size_of(pkt)
	mem.dma_reg(mem.DMA_GIF, 0x20)^, mem.dma_reg(mem.DMA_GIF, 0x30)^ = 0, BASE
	mem.dmac_stat = 0
	feed(&vu.vifs[1], 0x06008000) // MSKPATH3 on
	gif_chcr^ = 0x105
	if dma.mfifo_start(mem.DMA_GIF) || gs.state.regs[0x40] != 0 {
		fail("mfifo hold: masked big drain finished at once (GS 40 %x), want STR held", gs.state.regs[0x40])
	}
	if mem.dmac_stat & dma.D_STAT_MEIS != 0 {fail("mfifo hold: a drain that reached its end tag raised MEIS")}
	feed(&vu.vifs[1], 0x06000000) // MSKPATH3 off
	if gs.state.regs[0x40] != 0x6666 || gif_chcr^ & 0x100 != 0 || mem.dmac_stat & (1 << mem.DMA_GIF) == 0 {
		fail("mfifo hold: MSKPATH3 off: GS 40 %x, CHCR %08x, stat %08x, want 6666, STR clear, GIF done", gs.state.regs[0x40], gif_chcr^, mem.dmac_stat)
	}
}

// VU0's window onto VU1's registers: a VU0 LQ or SQ at a quadword address
// with bit 0x400 set reads and writes VU1's VF, VI and control registers,
// not VU0 memory, mirrored every 0x40 quadwords. The stores to VF0, VI0
// and status are dropped; R keeps 23 bits, a VI 16.
@(private = "file")
window :: proc() {
	v, u := &vu.vu0, &vu.vu1
	LQ :: proc(dest, ft, is, imm: u32) -> u32 {return 0x00 << 25 | dest << 21 | ft << 16 | is << 11 | (imm & 0x7ff)}
	SQ :: proc(dest, it, fs, imm: u32) -> u32 {return 0x01 << 25 | dest << 21 | it << 16 | fs << 11 | (imm & 0x7ff)}
	u.vf[5].u = {1, 2, 3, 4}
	u.vi[3], u.r, u.i, u.status, u.tpc = 0x1234, 0x123, 2.5, 0xabc, 0x2a8
	v.vi[1] = 0x400
	before := slice.clone(v.mem)
	defer delete(before)
	vu.vu0_lower(LQ(0xf, 3, 1, 5), 0)
	if v.vf[3].u != {1, 2, 3, 4} {fail("window LQ of vf5: %v", v.vf[3].u)}
	vu.vu0_lower(LQ(0xf, 3, 1, 0x47), 0) // mirror of slot 7
	if v.vf[3].u != u.vf[7].u {fail("window LQ of vf7's mirror: %v, want %v", v.vf[3].u, u.vf[7].u)}
	reads := [?][2]u32{{0x23, 0x1234}, {0x30, 0xabc}, {0x34, 0x3f800123}, {0x35, transmute(u32)f32(2.5)}, {0x3a, 0x2a8}, {0x39, 0}}
	for r in reads {
		vu.vu0_lower(LQ(0xf, 3, 1, r[0]), 0)
		if v.vf[3].u != {r[1], 0, 0, 0} {fail("window LQ of slot %02x: %v, want x %08x", r[0], v.vf[3].u, r[1])}
	}
	v.vf[6].u = {0x11117777, 0x22220001, 0x33330002, 0x44440003}
	want9 := u.vf[9].u
	want9.y, want9.z = 0x22220001, 0x33330002
	vu.vu0_lower(SQ(0b0110, 1, 6, 9), 0) // .yz to vf9
	if u.vf[9].u != want9 {fail("window SQ.yz to vf9: %v, want %v", u.vf[9].u, want9)}
	vu.vu0_lower(SQ(0xf, 1, 6, 0), 0)
	if u.vf[0].f != {0, 0, 0, 1} {fail("window SQ to vf0: %v", u.vf[0].f)}
	vu.vu0_lower(SQ(0x8, 1, 6, 0x24), 0)
	if u.vi[4] != 0x7777 {fail("window SQ.x to vi4: %04x", u.vi[4])}
	vu.vu0_lower(SQ(0x8, 1, 6, 0x20), 0)
	if u.vi[0] != 0 {fail("window SQ.x to vi0: %04x", u.vi[0])}
	vu.vu0_lower(SQ(0x8, 1, 6, 0x30), 0)
	if u.status != 0xabc {fail("window SQ.x to status: %03x", u.status)}
	vu.vu0_lower(SQ(0x8, 1, 6, 0x34), 0)
	if u.r != 0x117777 {fail("window SQ.x to R: %06x", u.r)}
	vu.vu0_lower(SQ(0x7, 1, 6, 0x35), 0) // no x: I stays
	if u.i != 2.5 {fail("window SQ.yzw to I: %v", u.i)}
	if !slice.equal(v.mem, before) {fail("window LQ or SQ touched VU0 memory")}
}

// tests/vu_programs DELAY at micro address 0, which the earlier tests are
// done with, then a jump into the middle of a window.
@(private = "file")
branch_delay :: proc() {
	v := &vu.vu0
	for w, k in vu_programs.DELAY {put(u32(k) * 4, w)}
	v.vi = {}
	v.status = 0
	vu.vu_op(v, 0x4a000038) // VCALLMS 0
	want := [16]u16{0, 6, 6, 4, 0, 10, 0, 7, 1, 1, 0xd0 / 8, 0, 3, 2, 1, 0}
	if v.vi != want {fail("branch VI delay: vi %v, want %v", v.vi, want)}
	// Started at 0x60, inside the window: the program's start ends the
	// look back, so the IBEQ compares vi5 from before 0x60, 8, against 7,
	// and is not taken.
	v.vi = {}
	v.vi[5], v.vi[7] = 8, 7
	vu.vu_op(v, 0x4a000038 | (0x60 / 8) << 6)
	if v.vi[5] != 10 || v.vi[6] != 1 {fail("branch VI delay from 0x60: vi5 %d vi6 %d, want 10 1", v.vi[5], v.vi[6])}
}

// A microprogram that waits for the EE parks (vu.vu0_call_micro): two
// loops of idle pairs, each ended by a CTC2 of 0 to the register it tests,
// then the E bit. A loop that writes state is no such wait.
@(private = "file")
park :: proc() {
	v := &vu.vu0
	NOP :: 0x8000033c
	UNOP :: 0x000002ff
	iaddiu :: proc(it, is, imm: u32) -> u32 {return 0x08 << 25 | it << 16 | is << 11 | imm}
	ibeq :: proc(it, is: u32, off: i32) -> u32 {return 0x28 << 25 | it << 16 | is << 11 | u32(off) & 0x7ff}
	b :: proc(off: i32) -> u32 {return 0x20 << 25 | u32(off) & 0x7ff}
	put_pairs(0x200,
		{iaddiu(1, 0, 1), UNOP},
		{iaddiu(2, 0, 1), UNOP},
		{ibeq(1, 0, 3), UNOP}, // 0x210: vi1 == 0 leaves for 0x230
		{NOP, UNOP},
		{b(-3), UNOP}, // back to 0x210
		{NOP, UNOP},
		{iaddiu(3, 0, 7), UNOP}, // 0x230
		{ibeq(2, 0, 3), UNOP}, // 0x238: vi2 == 0 leaves for 0x258
		{NOP, UNOP},
		{b(-3), UNOP}, // back to 0x238
		{NOP, UNOP},
		{iaddiu(4, 3, 2), 1 << 30 | UNOP}, // 0x258, E
		{NOP, UNOP},
	)
	stat :: proc() -> u32 {return vu.vu0_ctrl_read(29)}
	v.vi = {}
	vu.vu_op(v, 0x4a000038 | (0x200 / 8) << 6)
	if !vu.vu0_parked || stat() != 1 || v.tpc != 0x210 {fail("park: parked %v, VPU-STAT %d, tpc %04x; want true, 1, 0210", vu.vu0_parked, stat(), v.tpc)}
	if v.vi[1] != 1 || v.vi[2] != 1 || v.vi[3] != 0 {fail("park: vi1-3 %d %d %d at the first loop, want 1 1 0", v.vi[1], v.vi[2], v.vi[3])}

	// A write that does not end the loop: parked there again.
	vu.vu0_ctrl_write(5, 9)
	if !vu.vu0_parked || v.tpc != 0x210 || v.vi[3] != 0 {fail("park: after a CTC2 to vi5 parked %v, tpc %04x, vi3 %d", vu.vu0_parked, v.tpc, v.vi[3])}
	// Nothing but a CTC2 to vi1-vi15 lets it go on.
	vu.vu0_ctrl_write(16, v.status)
	_ = vu.vu0_ctrl_read(1)
	if !vu.vu0_parked || v.tpc != 0x210 || v.vi[3] != 0 {fail("park: went on with no CTC2 to an integer register: parked %v, tpc %04x, vi3 %d", vu.vu0_parked, v.tpc, v.vi[3])}

	// The parked program is state: it comes back with a copy of it, as a
	// snapshot's does, after another program ran to its end.
	saved, saved_parked := v^, vu.vu0_parked
	put_pairs(0x3c0, {NOP, 1 << 30 | UNOP}, {NOP, UNOP})
	vu.vu_op(v, 0x4a000038 | (0x3c0 / 8) << 6)
	if vu.vu0_parked || stat() != 0 || v.tpc != 0x3d0 {fail("park: a new program over a parked one: parked %v, VPU-STAT %d, tpc %04x", vu.vu0_parked, stat(), v.tpc)}
	v^, vu.vu0_parked = saved, saved_parked

	// vi1 = 0: on to the second loop.
	vu.vu0_ctrl_write(1, 0)
	if !vu.vu0_parked || stat() != 1 || v.tpc != 0x238 {fail("park: second loop: parked %v, VPU-STAT %d, tpc %04x; want true, 1, 0238", vu.vu0_parked, stat(), v.tpc)}
	if v.vi[3] != 7 || v.vi[4] != 0 {fail("park: vi3 %d vi4 %d at the second loop, want 7 0", v.vi[3], v.vi[4])}
	// vi2 = 0: on to the E bit.
	vu.vu0_ctrl_write(2, 0)
	if vu.vu0_parked || stat() != 0 || v.tpc != 0x268 {fail("park: end: parked %v, VPU-STAT %d, tpc %04x; want false, 0, 0268", vu.vu0_parked, stat(), v.tpc)}
	if v.vi[1] != 0 || v.vi[2] != 0 || v.vi[3] != 7 || v.vi[4] != 9 || v.vi[5] != 9 {fail("park: vi1-5 %d %d %d %d %d at the end, want 0 0 7 9 9", v.vi[1], v.vi[2], v.vi[3], v.vi[4], v.vi[5])}
	// Not parked: a CTC2 runs nothing.
	vu.vu0_ctrl_write(3, 1)
	if v.vi[4] != 9 || v.tpc != 0x268 {fail("park: a CTC2 with nothing parked ran code: vi4 %d, tpc %04x", v.vi[4], v.tpc)}

	// A loop that counts down writes state: it runs to its own end.
	put_pairs(0x300,
		{iaddiu(6, 0, 1000), UNOP},
		{0x09 << 25 | 6 << 16 | 6 << 11 | 1, UNOP}, // 0x308: ISUBIU vi6, vi6, 1
		{NOP, UNOP}, // the branch reads vi6 as written
		{NOP, UNOP},
		{0x29 << 25 | 0 << 16 | 6 << 11 | u32(-4 & 0x7ff), UNOP}, // 0x320: IBNE vi0, vi6, 0x308
		{NOP, UNOP},
		{NOP, 1 << 30 | UNOP},
		{NOP, UNOP},
	)
	vu.vu_op(v, 0x4a000038 | (0x300 / 8) << 6)
	if vu.vu0_parked || v.vi[6] != 0 || v.tpc != 0x340 {fail("park: counting loop: parked %v, vi6 %d, tpc %04x; want false, 0, 0340", vu.vu0_parked, v.vi[6], v.tpc)}

	// An endless loop that writes state is not a wait: it runs to the step
	// limit, as before.
	put_pairs(0x380,
		{iaddiu(7, 7, 1), UNOP}, // 0x380
		{b(-2), UNOP}, // back to 0x380
		{NOP, UNOP},
	)
	v.vi[7] = 0
	vu.vu_op(v, 0x4a000038 | (0x380 / 8) << 6)
	if vu.vu0_parked || stat() != 0 {fail("park: a loop that writes vi7 parked at %04x", v.tpc)}
	// 1 << 24 steps of three pairs a turn.
	if v.vi[7] != ((1 << 24) + 2) / 3 & 0xffff {fail("park: the loop that writes vi7 did not run to the limit: vi7 %d", v.vi[7])}
}

// VU1 data memory as 32-bit words.
@(private = "file")
vu1_words :: proc() -> [^]u32 {return ([^]u32)(raw_data(vu.vu1_mem[:]))}

// Each case of kick_latch as the interpreter runs it and as registered
// compiled code that makes the same calls and stores.
@(private = "file")
Kick_Case :: struct {
	name:     string,
	setup:    proc(),
	pairs:    [][2]u32,
	compiled: vu.Vu_Run,
	check:    proc(how: string),
}

@(private = "file")
KICK_NOP :: 0x8000033c
@(private = "file")
KICK_UNOP :: 0x000002ff
@(private = "file")
KICK_E :: 1 << 30 | KICK_UNOP

@(private = "file")
kick_xg :: proc(is: u32) -> u32 {return 0x800006fc | is << 11}
// ISW.x vi<it>, imm(vi<is>)
@(private = "file")
kick_isw :: proc(it, is, imm: u32) -> u32 {return 0x05 << 25 | 8 << 21 | it << 16 | is << 11 | imm}

// PATH1 is idle when a DIRECT goes straight in.
@(private = "file")
kick_path1_idle :: proc(name, how: string) {
	tag, ad := gif_tag(1), gif_ad(0x43, 0x4343)
	gs.state.regs[0x43] = 0
	feed(&vu.vifs[1], 0x50000002, tag[0], tag[1], tag[2], tag[3], ad[0], ad[1], ad[2], ad[3])
	if gs.state.regs[0x43] != 0x4343 || vu.vifs[1].gif_wait {fail("%s (%s): PATH1 kept the GIF, a DIRECT after it waits", name, how)}
	if vu.vu1_kick_latched {fail("%s (%s): a kick is still latched after the program", name, how)}
}

@(private = "file")
kick_latch :: proc() {
	cases := []Kick_Case {
		{
			name = "XGKICK in the E-bit pair, EOP stored in the next pair",
			setup = proc() {
				w := vu1_words()
				// A tag of one A+D qword, no EOP; what follows is no tag.
				w[0], w[1], w[2], w[3] = 1, 1 << 28, 0xe, 0
				w[4], w[5], w[6], w[7] = 0x2222, 0, 0x41, 0
				w[8], w[9], w[10], w[11] = 0x40, 0x40, 0x40, 0x80
				vu.vu1.vi[1], vu.vu1.vi[2] = 0, 0x8001
			},
			pairs = {{kick_xg(1), KICK_E}, {kick_isw(2, 1, 0), KICK_UNOP}},
			compiled = proc(_: u32, _: ^int) -> (u32, vu.Vu_Exit) {
				compiled_ran = true
				vu.vu1_xgkick(vu.vu1.vi[1])
				vu1_words()[0] = u32(vu.vu1.vi[2])
				return 0x10, .End
			},
			check = proc(how: string) {
				if gs.state.regs[0x41] != 0x2222 {fail("XGKICK with its EOP stored in the next pair (%s): GS 41 %x, want 2222 (read at the instruction, or never sent)", how, gs.state.regs[0x41])}
				kick_path1_idle("XGKICK with its EOP stored in the next pair", how)
			},
		},
		{
			name = "two XGKICKs in one program",
			setup = proc() {
				w := vu1_words()
				t := gif_tag(2)
				w[0], w[1], w[2], w[3] = t[0], t[1], t[2], t[3]
				w[4], w[5], w[6], w[7] = 0x1111, 0, 0x40, 0
				w[8], w[9], w[10], w[11] = 0x2222, 0, 0x41, 0
				w[16], w[17], w[18], w[19] = t[0], t[1], t[2], t[3]
				w[20], w[21], w[22], w[23] = 0x3333, 0, 0x41, 0
				w[24], w[25], w[26], w[27] = 0x4444, 0, 0x42, 0
				vu.vu1.vi[1], vu.vu1.vi[2], vu.vu1.vi[3], vu.vu1.vi[4], vu.vu1.vi[5] = 0, 4, 0x5555, 0x7777, 0x6666
			},
			pairs = {
				{kick_xg(1), KICK_UNOP},
				{kick_isw(3, 1, 1), KICK_UNOP}, // the first packet's 40: 5555
				{kick_xg(2), KICK_UNOP},
				{kick_isw(4, 1, 1), KICK_E}, // too late for the first packet
				{kick_isw(5, 2, 2), KICK_UNOP}, // the second packet's 42: 6666
			},
			compiled = proc(_: u32, _: ^int) -> (u32, vu.Vu_Exit) {
				w, vi := vu1_words(), &vu.vu1.vi
				compiled_ran = true
				vu.vu1_xgkick(vi[1])
				w[4] = u32(vi[3])
				vu.vu1_xgkick(vi[2])
				w[4] = u32(vi[4])
				w[24] = u32(vi[5])
				return 0x28, .End
			},
			check = proc(how: string) {
				r := gs.state.regs
				// 41 is written by both: the second packet's value shows the order.
				if r[0x40] != 0x5555 || r[0x41] != 0x3333 || r[0x42] != 0x6666 {
					fail("two XGKICKs in one program (%s): GS 40 %x 41 %x 42 %x, want 5555 3333 6666", how, r[0x40], r[0x41], r[0x42])
				}
				kick_path1_idle("two XGKICKs in one program", how)
			},
		},
		{
			name = "XGKICK walk with no EOP inside VU1 memory",
			setup = proc() {
				w := vu1_words()
				w[0], w[1], w[2], w[3] = 1, 1 << 28, 0xe, 0
				w[4], w[5], w[6], w[7] = 0x2222, 0, 0x41, 0
				w[8], w[9], w[10], w[11] = 0x40, 0x40, 0x40, 0x80 // 1025 qwords, no EOP
				vu.vu1.vi[1] = 0
			},
			pairs = {{kick_xg(1), KICK_E}, {KICK_NOP, KICK_UNOP}},
			compiled = proc(_: u32, _: ^int) -> (u32, vu.Vu_Exit) {
				compiled_ran = true
				vu.vu1_xgkick(vu.vu1.vi[1])
				return 0x10, .End
			},
			check = proc(how: string) {
				if gs.state.regs[0x41] != 0 {fail("XGKICK walk with no EOP (%s): GS 41 %x, the walk was fed", how, gs.state.regs[0x41])}
				kick_path1_idle("XGKICK walk with no EOP", how)
			},
		},
	}
	for c in cases {
		code := make([]u32, 2 * len(c.pairs), context.temp_allocator)
		for p, k in c.pairs {code[2 * k], code[2 * k + 1] = p[0], p[1]}
		for how in ([]string{"interpreted", "compiled"}) {
			gif.gif_reset()
			gif_clear()
			for &b in vu.vu1_mem {b = 0}
			// Other code first, so what a compiled case registered is gone.
			mpg(&vu.vifs[1], END_CODE[:])
			if how == "compiled" {vu.vu1_register(code, c.compiled)}
			mpg(&vu.vifs[1], code)
			c.setup()
			compiled_ran = false
			vu.vu1_start(0)
			if compiled_ran != (how == "compiled") {fail("%s (%s): compiled code ran %v", c.name, how, compiled_ran)}
			c.check(how)
		}
	}

	// A program that kicks and never ends stops at the step limit: the kick
	// is sent there.
	gif.gif_reset()
	gif_clear()
	for &b in vu.vu1_mem {b = 0}
	w := vu1_words()
	t := gif_tag(1)
	w[0], w[1], w[2], w[3] = t[0], t[1], t[2], t[3]
	w[4], w[5], w[6], w[7] = 0x2222, 0, 0x41, 0
	vu.vu1.vi[1] = 0
	loop := [?]u32{kick_xg(1), KICK_UNOP, 0x08 << 25 | 7 << 16 | 7 << 11 | 1, KICK_UNOP, 0x20 << 25 | u32(-2 & 0x7ff), KICK_UNOP, KICK_NOP, KICK_UNOP}
	mpg(&vu.vifs[1], loop[:])
	vu.vu1_start(0)
	if gs.state.regs[0x41] != 0x2222 {fail("XGKICK in a program stopped at the step limit: GS 41 %x, want 2222", gs.state.regs[0x41])}
	kick_path1_idle("XGKICK in a program stopped at the step limit", "interpreted")
}

main :: proc() {
	vu.vu_init()
	put(0x40, 0x08 << 25 | 1 << 16 | 5) // IADDIU vi1, vi0, 5
	put(0x44, 1 << 30 | 0xf << 21 | 2 << 16 | 1 << 11 | 3 << 6 | 0x28) // VADD.xyzw vf3, vf1, vf2 + E
	put(0x48, 0x8000033c) // NOP
	put(0x4c, 0x000002ff) // NOP

	run("VCALLMS", proc() {vu.vu_op(&vu.vu0, 0x4a000038 | (0x40 / 8) << 6)})
	run("VCALLMSR", proc() {
		vu.vu0.cmsar = 0x40 / 8
		vu.vu_op(&vu.vu0, 0x4a000039)
	})
	all_vi()
	clamped()
	div_efu()
	flags()
	minmax()
	vu0_compiled()
	micro_writes()
	flag_delay()
	q_latency()
	stalls()
	ibit()
	gif_paths()
	gif_tte()
	spr_interleave()
	mfifo()
	mfifo_hold()
	window()
	kick_latch()
	branch_delay()
	park()
	fmt.println("vu: ok")
}
