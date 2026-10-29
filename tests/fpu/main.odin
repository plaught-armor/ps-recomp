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
// it.
package main

import "core:fmt"
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

// Add to want the fpu_slow calls a row makes: Sqrt for a root of exponent
// 255, then the operation when an operand or the host's result is special,
// past fpu_div's zero divisor and fpu_rsqrt's zero b.
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
		if v.op == .Rsqrt {
			if v.ft & 0x7f800000 == 0x7f800000 {want[.Sqrt] += 1}
			// The root here is not the row's own call: leave it uncounted.
			counts := cpu.fallback_fpu_slow
			b = cpu.fpu_sqrt(b)
			cpu.fallback_fpu_slow = counts
		}
		r, op = a / b, .Div
	case .Sqrt:
		if v.fs & 0x7f800000 == 0x7f800000 {want[.Sqrt] += 1}
		return
	}
	if special(transmute(u32)a) || special(transmute(u32)b) || special(transmute(u32)r) {want[op] += 1}
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
		for n, op in want {
			if n == 0 || cpu.fallback_fpu_slow[op] != n {
				fmt.eprintfln("FAIL fallback_fpu_slow[%v] = %d, want %d (nonzero)", op, cpu.fallback_fpu_slow[op], n)
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
