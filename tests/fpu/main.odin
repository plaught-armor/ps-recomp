// EE FPU model test (ps2/cpu alu.odin), run on every target in CI.
//
// Each row is a result printed by a real PS2, from ps2autotests
// (tests/cpu/ee_fpu/*.expected, https://github.com/unknownbrackets/ps2autotests),
// as collected in PS2Recomp's ps2xTest/src/ps2_float_hw_vectors.inc (GPLv3).
// Rows marked 1 are the hardware's own rounding, which is not emulated: they
// may differ in the last mantissa bit. Rows marked 2 read an operand with
// exponent 0 and a nonzero mantissa as zero, which the model does too, so
// they are checked exactly. Then fkey orders exponent-255 values above every
// host float and treats every exponent-0 value as zero. With
// -define:FALLBACK_COUNT=true, cpu.fpu_slow counts once per row that needs
// it. The forms fpu_add, fpu_sub, fpu_mul and fpu_sqrt have inline are
// checked against fpu_slow, the model, on a grid and random operands.
package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import cpu "ps:ps2/cpu"

Op :: enum u8 {Add, Sub, Mul, Div, Sqrt, Rsqrt}

Vector :: struct {
	op:          Op,
	fs, ft, res: u32,
	known:       u8,
}

@(rodata)
VECTORS := [?]Vector{
	{.Add, 0x00000000, 0x00000000, 0x00000000, 0},
	{.Add, 0x00000000, 0x80000000, 0x00000000, 0},
	{.Add, 0x80000000, 0x00000000, 0x00000000, 0},
	{.Add, 0x80000000, 0x80000000, 0x80000000, 0},
	{.Add, 0x00000000, 0x3f800000, 0x3f800000, 0},
	{.Add, 0x3f800000, 0x3f800000, 0x40000000, 0},
	{.Add, 0x3f800000, 0x00000000, 0x3f800000, 0},
	{.Add, 0x40000000, 0x40000000, 0x40800000, 0},
	{.Add, 0x40400000, 0x3f800000, 0x40800000, 0},
	{.Add, 0x40400000, 0x40400000, 0x40c00000, 0},
	{.Add, 0x7fffffff, 0x7fffffff, 0x7fffffff, 0},
	{.Add, 0x7fffffff, 0xffffffff, 0x00000000, 0},
	{.Add, 0xffffffff, 0x7fffffff, 0x00000000, 0},
	{.Add, 0xffffffff, 0xffffffff, 0xffffffff, 0},
	{.Add, 0x7fffffff, 0x00000000, 0x7fffffff, 0},
	{.Add, 0x00000000, 0x7fffffff, 0x7fffffff, 0},
	{.Add, 0x00000000, 0x7f800000, 0x7f800000, 0},
	{.Add, 0x7f800000, 0x7f800000, 0x7fffffff, 0},
	{.Add, 0xff800000, 0x7f800000, 0x00000000, 0},
	{.Add, 0x3f800000, 0xbf800000, 0x00000000, 0},
	{.Add, 0x3fffffff, 0x3f800000, 0x403fffff, 1},
	{.Add, 0x7f800001, 0x3f800000, 0x7f800001, 0},
	{.Add, 0x00000001, 0x3f800000, 0x3f800000, 0},
	{.Add, 0x3f800000, 0x3fffffff, 0x403fffff, 1},
	{.Add, 0x3f800000, 0x7f800001, 0x7f800001, 0},
	{.Add, 0x3f800000, 0x00000001, 0x3f800000, 0},
	{.Add, 0x7fffffff, 0x3f800000, 0x7fffffff, 0},
	{.Add, 0xffffffff, 0x3f800000, 0xffffffff, 0},
	{.Add, 0x3f800000, 0x7fffffff, 0x7fffffff, 0},
	{.Add, 0x3f800000, 0xffffffff, 0xffffffff, 0},
	{.Add, 0x00001337, 0xdeadbeef, 0xdeadbeef, 0},
	{.Sub, 0x00000000, 0x00000000, 0x00000000, 0},
	{.Sub, 0x00000000, 0x80000000, 0x00000000, 0},
	{.Sub, 0x80000000, 0x00000000, 0x80000000, 0},
	{.Sub, 0x80000000, 0x80000000, 0x00000000, 0},
	{.Sub, 0x00000000, 0x3f800000, 0xbf800000, 0},
	{.Sub, 0x3f800000, 0x3f800000, 0x00000000, 0},
	{.Sub, 0x3f800000, 0x00000000, 0x3f800000, 0},
	{.Sub, 0x40000000, 0x40000000, 0x00000000, 0},
	{.Sub, 0x40400000, 0x3f800000, 0x40000000, 0},
	{.Sub, 0x40400000, 0x40400000, 0x00000000, 0},
	{.Sub, 0x7fffffff, 0x7fffffff, 0x00000000, 0},
	{.Sub, 0x7fffffff, 0xffffffff, 0x7fffffff, 0},
	{.Sub, 0xffffffff, 0x7fffffff, 0xffffffff, 0},
	{.Sub, 0xffffffff, 0xffffffff, 0x00000000, 0},
	{.Sub, 0x7fffffff, 0x00000000, 0x7fffffff, 0},
	{.Sub, 0x00000000, 0x7fffffff, 0xffffffff, 0},
	{.Sub, 0x00000000, 0x7f800000, 0xff800000, 0},
	{.Sub, 0x7f800000, 0x7f800000, 0x00000000, 0},
	{.Sub, 0xff800000, 0x7f800000, 0xffffffff, 0},
	{.Sub, 0x3f800000, 0xbf800000, 0x40000000, 0},
	{.Sub, 0x3fffffff, 0x3f800000, 0x3f7ffffe, 0},
	{.Sub, 0x7f800001, 0x3f800000, 0x7f800001, 0},
	{.Sub, 0x00000001, 0x3f800000, 0xbf800000, 0},
	{.Sub, 0x3f800000, 0x3fffffff, 0xbf7ffffe, 0},
	{.Sub, 0x3f800000, 0x7f800001, 0xff800001, 0},
	{.Sub, 0x3f800000, 0x00000001, 0x3f800000, 0},
	{.Sub, 0x7fffffff, 0x3f800000, 0x7fffffff, 0},
	{.Sub, 0xffffffff, 0x3f800000, 0xffffffff, 0},
	{.Sub, 0x3f800000, 0x7fffffff, 0xffffffff, 0},
	{.Sub, 0x3f800000, 0xffffffff, 0x7fffffff, 0},
	{.Sub, 0x00001337, 0xdeadbeef, 0x5eadbeef, 0},
	{.Mul, 0x00000000, 0x00000000, 0x00000000, 0},
	{.Mul, 0x00000000, 0x80000000, 0x80000000, 0},
	{.Mul, 0x80000000, 0x00000000, 0x80000000, 0},
	{.Mul, 0x80000000, 0x80000000, 0x00000000, 0},
	{.Mul, 0x00000000, 0x3f800000, 0x00000000, 0},
	{.Mul, 0x3f800000, 0x3f800000, 0x3f800000, 0},
	{.Mul, 0x3f800000, 0x00000000, 0x00000000, 0},
	{.Mul, 0x40000000, 0x40000000, 0x40800000, 0},
	{.Mul, 0x40400000, 0x3f800000, 0x40400000, 0},
	{.Mul, 0x40400000, 0x40400000, 0x41100000, 0},
	{.Mul, 0x7fffffff, 0x7fffffff, 0x7fffffff, 0},
	{.Mul, 0x7fffffff, 0xffffffff, 0xffffffff, 0},
	{.Mul, 0xffffffff, 0x7fffffff, 0xffffffff, 0},
	{.Mul, 0xffffffff, 0xffffffff, 0x7fffffff, 0},
	{.Mul, 0x7fffffff, 0x00000000, 0x00000000, 0},
	{.Mul, 0x00000000, 0x7fffffff, 0x00000000, 0},
	{.Mul, 0x00000000, 0x7f800000, 0x00000000, 0},
	{.Mul, 0x7f800000, 0x7f800000, 0x7fffffff, 0},
	{.Mul, 0xff800000, 0x7f800000, 0xffffffff, 0},
	{.Mul, 0x3f800000, 0xbf800000, 0xbf800000, 0},
	{.Mul, 0x3fffffff, 0x3f800000, 0x3fffffff, 0},
	{.Mul, 0x7f800001, 0x3f800000, 0x7f800001, 0},
	{.Mul, 0x00000001, 0x3f800000, 0x00000000, 0},
	{.Mul, 0x3f800000, 0x3fffffff, 0x3ffffffe, 1},
	{.Mul, 0x3f800000, 0x7f800001, 0x7f800001, 0},
	{.Mul, 0x3f800000, 0x00000001, 0x00000000, 0},
	{.Mul, 0x7fffffff, 0x3f800000, 0x7fffffff, 0},
	{.Mul, 0xffffffff, 0x3f800000, 0xffffffff, 0},
	{.Mul, 0x3f800000, 0x7fffffff, 0x7ffffffe, 1},
	{.Mul, 0x3f800000, 0xffffffff, 0xfffffffe, 1},
	{.Mul, 0x00001337, 0xdeadbeef, 0x80000000, 2},
	{.Div, 0x00000000, 0x00000000, 0x7fffffff, 0},
	{.Div, 0x00000000, 0x80000000, 0xffffffff, 0},
	{.Div, 0x80000000, 0x00000000, 0xffffffff, 0},
	{.Div, 0x80000000, 0x80000000, 0x7fffffff, 0},
	{.Div, 0x00000000, 0x3f800000, 0x00000000, 0},
	{.Div, 0x3f800000, 0x3f800000, 0x3f800000, 0},
	{.Div, 0x3f800000, 0x00000000, 0x7fffffff, 0},
	{.Div, 0x40000000, 0x40000000, 0x3f800000, 0},
	{.Div, 0x40400000, 0x3f800000, 0x40400000, 0},
	{.Div, 0x40400000, 0x40400000, 0x3f800000, 0},
	{.Div, 0x7fffffff, 0x7fffffff, 0x3f800000, 0},
	{.Div, 0x7fffffff, 0xffffffff, 0xbf800000, 0},
	{.Div, 0xffffffff, 0x7fffffff, 0xbf800000, 0},
	{.Div, 0xffffffff, 0xffffffff, 0x3f800000, 0},
	{.Div, 0x7fffffff, 0x00000000, 0x7fffffff, 0},
	{.Div, 0x00000000, 0x7fffffff, 0x00000000, 0},
	{.Div, 0x00000000, 0x7f800000, 0x00000000, 0},
	{.Div, 0x7f800000, 0x7f800000, 0x3f800000, 0},
	{.Div, 0xff800000, 0x7f800000, 0xbf800000, 0},
	{.Div, 0x3f800000, 0xbf800000, 0xbf800000, 0},
	{.Div, 0x3fffffff, 0x3f800000, 0x3fffffff, 0},
	{.Div, 0x7f800001, 0x3f800000, 0x7f800001, 0},
	{.Div, 0x00000001, 0x3f800000, 0x00000000, 0},
	{.Div, 0x3f800000, 0x3fffffff, 0x3f000001, 0},
	{.Div, 0x3f800000, 0x7f800001, 0x00000000, 0},
	{.Div, 0x3f800000, 0x00000001, 0x7fffffff, 0},
	{.Div, 0x7fffffff, 0x3f800000, 0x7fffffff, 0},
	{.Div, 0xffffffff, 0x3f800000, 0xffffffff, 0},
	{.Div, 0x3f800000, 0x7fffffff, 0x00000000, 0},
	{.Div, 0x3f800000, 0xffffffff, 0x80000000, 0},
	{.Div, 0x00001337, 0xdeadbeef, 0x80000000, 0},
	{.Sqrt, 0x00000000, 0x00000000, 0x00000000, 0},
	{.Sqrt, 0x80000000, 0x00000000, 0x00000000, 0},
	{.Sqrt, 0x3f800000, 0x00000000, 0x3f800000, 0},
	{.Sqrt, 0x40000000, 0x00000000, 0x3fb504f3, 0},
	{.Sqrt, 0x40400000, 0x00000000, 0x3fddb3d7, 0},
	{.Sqrt, 0x7fffffff, 0x00000000, 0x5fb504f3, 0},
	{.Sqrt, 0xffffffff, 0x00000000, 0x5fb504f3, 0},
	{.Sqrt, 0x7f800000, 0x00000000, 0x5f800000, 0},
	{.Sqrt, 0xff800000, 0x00000000, 0x5f800000, 0},
	{.Sqrt, 0x41c80000, 0x00000000, 0x40a00000, 0},
	{.Sqrt, 0xbf800000, 0x00000000, 0x3f800000, 0},
	{.Sqrt, 0x3fffffff, 0x00000000, 0x3fb504f3, 0},
	{.Sqrt, 0x7f800001, 0x00000000, 0x5f800000, 0},
	{.Sqrt, 0x00000001, 0x00000000, 0x00000000, 0},
	{.Sqrt, 0x00001337, 0x00000000, 0x00000000, 0},
	{.Sqrt, 0xdeadbeef, 0x00000000, 0x4f152108, 0},
	{.Rsqrt, 0x00000000, 0x00000000, 0x7fffffff, 0},
	{.Rsqrt, 0x00000000, 0x80000000, 0x7fffffff, 0},
	{.Rsqrt, 0x80000000, 0x00000000, 0xffffffff, 0},
	{.Rsqrt, 0x80000000, 0x80000000, 0xffffffff, 0},
	{.Rsqrt, 0x00000000, 0x3f800000, 0x00000000, 0},
	{.Rsqrt, 0x3f800000, 0x3f800000, 0x3f800000, 0},
	{.Rsqrt, 0x3f800000, 0x00000000, 0x7fffffff, 0},
	{.Rsqrt, 0x40000000, 0x40000000, 0x3fb504f3, 0},
	{.Rsqrt, 0x40400000, 0x3f800000, 0x40400000, 0},
	{.Rsqrt, 0x40400000, 0x40400000, 0x3fddb3d7, 1},
	{.Rsqrt, 0x7fffffff, 0x7fffffff, 0x5fb504f2, 1},
	{.Rsqrt, 0x7fffffff, 0xffffffff, 0x5fb504f2, 1},
	{.Rsqrt, 0xffffffff, 0x7fffffff, 0xdfb504f2, 1},
	{.Rsqrt, 0xffffffff, 0xffffffff, 0xdfb504f2, 1},
	{.Rsqrt, 0x7fffffff, 0x00000000, 0x7fffffff, 0},
	{.Rsqrt, 0x00000000, 0x7fffffff, 0x00000000, 0},
	{.Rsqrt, 0x00000000, 0x7f800000, 0x00000000, 0},
	{.Rsqrt, 0x7f800000, 0x7f800000, 0x5f800000, 0},
	{.Rsqrt, 0xff800000, 0x7f800000, 0xdf800000, 0},
	{.Rsqrt, 0x3f800000, 0x41c80000, 0x3e4ccccd, 0},
	{.Rsqrt, 0x40a00000, 0x41c80000, 0x3f800000, 0},
	{.Rsqrt, 0x41c80000, 0x41c80000, 0x40a00000, 0},
	{.Rsqrt, 0x3f800000, 0xbf800000, 0x3f800000, 0},
	{.Rsqrt, 0x3fffffff, 0x3f800000, 0x3fffffff, 0},
	{.Rsqrt, 0x7f800001, 0x3f800000, 0x7f800001, 0},
	{.Rsqrt, 0x00000001, 0x3f800000, 0x00000000, 0},
	{.Rsqrt, 0x3f800000, 0x3fffffff, 0x3f3504f3, 0},
	{.Rsqrt, 0x3f800000, 0x7f800001, 0x1f800000, 0},
	{.Rsqrt, 0x3f800000, 0x00000001, 0x7fffffff, 0},
	{.Rsqrt, 0x7fffffff, 0x3f800000, 0x7fffffff, 0},
	{.Rsqrt, 0xffffffff, 0x3f800000, 0xffffffff, 0},
	{.Rsqrt, 0x3f800000, 0x7fffffff, 0x1f3504f3, 0},
	{.Rsqrt, 0x3f800000, 0xffffffff, 0x1f3504f3, 0},
	{.Rsqrt, 0x00001337, 0xdeadbeef, 0x00000000, 0},
}

f :: #force_inline proc(u: u32) -> f32 {return transmute(f32)u}

// Exponent 255, or exponent 0 with a nonzero mantissa.
special :: proc(u: u32) -> bool {
	e := u & 0x7f800000
	return e == 0x7f800000 || (e == 0 && u & 0x007fffff != 0)
}

// Add to want the fpu_slow calls a row makes: the operation when an operand
// or the host's result is special, past fpu_div's zero divisor and
// fpu_rsqrt's zero b, but for an Add or Sub with an operand or result of
// exponent 255 (fpu_wide). fpu_mul and fpu_sqrt never call it.
slow_ops :: proc(v: Vector, want: ^[cpu.Fpu_Op]u64) {
	a, b := f(v.fs), f(v.ft)
	r: f32
	op: cpu.Fpu_Op
	switch v.op {
	case .Add: r, op = a + b, .Add
	case .Sub: r, op = a - b, .Sub
	case .Mul: r, op = a * b, .Mul
	case .Div, .Rsqrt:
		if v.ft & 0x7f800000 == 0 {return}
		if v.op == .Rsqrt {b = cpu.fpu_sqrt(b)}
		r, op = a / b, .Div
	case .Sqrt:
		return
	}
	if op == .Mul {return}
	ur := transmute(u32)r
	if !special(transmute(u32)a) && !special(transmute(u32)b) && !special(ur) {return}
	if op != .Div && max(transmute(u32)a & 0x7f800000, transmute(u32)b & 0x7f800000, ur & 0x7f800000) == 0x7f800000 {return}
	want[op] += 1
}

// The inline special cases of fpu_add, fpu_sub, fpu_mul and fpu_sqrt
// against fpu_slow, the model, bits and fcr31 both: every pair of a grid
// of exponents (0, 1, around 2^+-64, 2^-1 to 2^1, 252 to 255) by mantissas
// and signs whose operands or host result is special, then random pairs
// with exponents near the ends. Returns the failures.
grid :: proc() -> int {
	EXPS :: [?]u32{0, 1, 2, 63, 64, 65, 126, 127, 128, 190, 191, 192, 252, 253, 254, 255}
	MANTS :: [?]u32{0, 1, 0x2aaaab, 0x400000, 0x7ffffe, 0x7fffff}
	vals: [len(EXPS) * len(MANTS) * 2]u32
	n := 0
	for e in EXPS {
		for m in MANTS {
			vals[n], vals[n + 1] = e << 23 | m, 0x80000000 | e << 23 | m
			n += 2
		}
	}
	fails := 0
	FCR31 :: 0x5a5a5a5a
	cpu.state.fcr31 = FCR31
	check :: proc(op: cpu.Fpu_Op, x, y: u32, fails: ^int) {
		a, b := f(x), f(y)
		got: f32
		host: f32
		switch op {
		case .Add:  got, host = cpu.fpu_add(a, b), a + b
		case .Sub:  got, host = cpu.fpu_sub(a, b), a - b
		case .Mul:  got, host = cpu.fpu_mul(a, b), a * b
		case .Sqrt: got = cpu.fpu_sqrt(a)
		case .Div:  return
		}
		if op != .Sqrt && !special(x) && !special(y) && !special(transmute(u32)host) {return}
		want := cpu.fpu_slow(op, a, b)
		if transmute(u32)got == transmute(u32)want && cpu.state.fcr31 == FCR31 {return}
		fails^ += 1
		if fails^ <= 10 {fmt.eprintfln("FAIL fpu %v %08x, %08x: fpu_slow gives %08x, got %08x, fcr31 %08x", op, x, y, transmute(u32)want, transmute(u32)got, cpu.state.fcr31)}
		cpu.state.fcr31 = FCR31
	}
	for x in vals {
		check(.Sqrt, x, 0, &fails)
		for y in vals {
			for op in ([?]cpu.Fpu_Op{.Add, .Sub, .Mul}) {check(op, x, y, &fails)}
		}
	}
	RAND_EXPS :: [?]u32{0, 1, 2, 3, 125, 126, 127, 128, 129, 250, 251, 252, 253, 254, 255}
	r := rand.create(0x0fb0_5eed)
	gen := rand.default_random_generator(&r)
	pick :: proc(gen: rand.Generator) -> u32 {
		exps := RAND_EXPS
		return rand.uint32(gen) & 0x807fffff | exps[rand.uint32(gen) % len(exps)] << 23
	}
	for _ in 0 ..< 1_000_000 {
		x, y := pick(gen), pick(gen)
		check(.Sqrt, x, 0, &fails)
		for op in ([?]cpu.Fpu_Op{.Add, .Sub, .Mul}) {check(op, x, y, &fails)}
	}
	// Results worked by hand: x - x at +-FMAX is +0, the root of a negative
	// exponent-255 value that of its magnitude, and sums whose half lands
	// at exponent 254 (the result at 255) or 253, or reaches 2^129.
	Hand :: struct {op: cpu.Fpu_Op, x, y, want: u32}
	HAND :: [?]Hand{
		{.Sub, 0x7fffffff, 0x7fffffff, 0x00000000},
		{.Sub, 0xffffffff, 0xffffffff, 0x00000000},
		{.Add, 0xffffffff, 0x7fffffff, 0x00000000},
		{.Sqrt, 0x7f800000, 0, 0x5f800000},
		{.Sqrt, 0xff800000, 0, 0x5f800000},
		{.Sqrt, 0xffffffff, 0, 0x5fb504f3},
		{.Add, 0x7f000000, 0x7f000000, 0x7f800000},
		{.Add, 0x7f7fffff, 0x7f7fffff, 0x7fffffff},
		{.Sub, 0x7f800000, 0x7f000000, 0x7f000000},
		{.Add, 0x7fffffff, 0x7fffffff, 0x7fffffff},
		{.Sub, 0xffffffff, 0x7f800000, 0xffffffff},
		{.Add, 0x7f800000, 0x00000001, 0x7f800000},
		{.Mul, 0x7f800000, 0x3f000000, 0x7f000000},
		{.Mul, 0x3f000000, 0xff800000, 0xff000000},
		{.Mul, 0x7f800000, 0x7f800000, 0x7fffffff},
	}
	for h in HAND {
		got: f32
		switch h.op {
		case .Add:  got = cpu.fpu_add(f(h.x), f(h.y))
		case .Sub:  got = cpu.fpu_sub(f(h.x), f(h.y))
		case .Mul:  got = cpu.fpu_mul(f(h.x), f(h.y))
		case .Sqrt: got = cpu.fpu_sqrt(f(h.x))
		case .Div:
		}
		if transmute(u32)got == h.want {continue}
		fails += 1
		fmt.eprintfln("FAIL fpu %v %08x, %08x: want %08x, got %08x", h.op, h.x, h.y, h.want, transmute(u32)got)
	}
	return fails
}

run :: proc(v: Vector) -> u32 {
	a, b := f(v.fs), f(v.ft)
	r: f32
	switch v.op {
	case .Add:   r = cpu.fpu_add(a, b)
	case .Sub:   r = cpu.fpu_sub(a, b)
	case .Mul:   r = cpu.fpu_mul(a, b)
	case .Div:   r = cpu.fpu_div(a, b)
	case .Sqrt:  r = cpu.fpu_sqrt(a)
	case .Rsqrt: r = cpu.fpu_rsqrt(a, b)
	}
	return transmute(u32)r
}

main :: proc() {
	fails := 0
	for v in VECTORS {
		got := run(v)
		d := i64(got) - i64(v.res)
		if got == v.res || (v.known == 1 && abs(d) == 1) {continue}
		fmt.eprintfln("FAIL %v %08x, %08x: PS2 gives %08x, got %08x", v.op, v.fs, v.ft, v.res, got)
		fails += 1
	}
	fails += grid()
	// Ascending EE floats: each key must be above the one before.
	order := [?]u32{0xffffffff, 0xff800000, 0xff7fffff, 0xbf800000, 0x80800000, 0x00000000,
	                0x00800000, 0x3f800000, 0x7f7fffff, 0x7f800000, 0x7fffffff}
	for i in 1 ..< len(order) {
		if cpu.fkey(f(order[i - 1])) >= cpu.fkey(f(order[i])) {
			fmt.eprintfln("FAIL fkey %08x >= %08x", order[i - 1], order[i])
			fails += 1
		}
	}
	for z in ([?]u32{0x80000000, 0x00000001, 0x807fffff}) {
		if cpu.fkey(f(z)) != 0 {
			fmt.eprintfln("FAIL fkey %08x is not zero", z)
			fails += 1
		}
	}
	when cpu.FALLBACK_COUNT {
		cpu.fallback_fpu_slow = {}
		want: [cpu.Fpu_Op]u64
		for v in VECTORS {
			slow_ops(v, &want)
			run(v)
		}
		// Rows reach fpu_slow's Add, Sub and Div; fpu_mul and fpu_sqrt
		// have every case inline.
		for n, op in want {
			if (n == 0) != (op == .Mul || op == .Sqrt) || cpu.fallback_fpu_slow[op] != n {
				fmt.eprintfln("FAIL fallback_fpu_slow[%v] = %d, want %d (nonzero but for Mul and Sqrt)", op, cpu.fallback_fpu_slow[op], n)
				fails += 1
			}
		}
	}
	if fails > 0 {
		fmt.eprintfln("%d failed", fails)
		os.exit(1)
	}
	when cpu.FALLBACK_COUNT {
		fmt.printfln("fpu: %d vectors ok, fpu_slow counted %v", len(VECTORS), cpu.fallback_fpu_slow)
	} else {
		fmt.printfln("fpu: %d vectors ok", len(VECTORS))
	}
}
