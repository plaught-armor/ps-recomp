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
	fmt.println("vu: ok")
}
