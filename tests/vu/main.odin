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
// Last, micro memory writes after a program is compiled: each write path
// (the EE mapping, VIF MPG) moves its VU's micro generation, and on VU1 a
// write that changes the compiled code makes the next start miss it and
// interpret.
//
//   odin run tests/vu -collection:ps=.
package main

import "core:fmt"
import "core:os"
import "ps:ps2/vu"

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
micro_writes :: proc() {
	g := vu.vu0_micro_gen
	_ = vu.vu_mem_addr(0x11000000)
	if vu.vu0_micro_gen == g {fail("VU0 micro write through the EE mapping kept generation %d", g)}
	g = vu.vu0_micro_gen
	mpg(&vu.vifs[0], END_CODE[:])
	if vu.vu0_micro_gen == g {fail("VU0 MPG kept generation %d", g)}

	vu.vu1_register(END_CODE[:], proc(_: u32, _: ^int) -> (u32, vu.Vu1_Exit) {
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
	flags()
	minmax()
	micro_writes()
	fmt.println("vu: ok")
}
