// Multiply/divide and FPU helpers called from recompiled code.
package ps2_cpu

import "base:intrinsics"
import "core:math"

// R5900 MULT/MULTU also write the low word of the product to rd.
// `unit` 1 is the second pipe (MULT1), writing HI1/LO1.
//
// The multiply, divide and PLZCW procs are unchecked: unit is masked to
// the two pipes and rd to the 32 registers.
mult :: proc(rd: u8, a, b: u32, unit: int) #no_bounds_check {
	p := i64(i32(a)) * i64(i32(b))
	state.lo.d[unit & 1] = sx32(u32(p))
	state.hi.d[unit & 1] = sx32(u32(p >> 32))
	if rd != 0 {state.r[rd & 31].d[0] = state.lo.d[unit & 1]}
}

multu :: proc(rd: u8, a, b: u32, unit: int) #no_bounds_check {
	p := u64(a) * u64(b)
	state.lo.d[unit & 1] = sx32(u32(p))
	state.hi.d[unit & 1] = sx32(u32(p >> 32))
	if rd != 0 {state.r[rd & 31].d[0] = state.lo.d[unit & 1]}
}

madd :: proc(rd: u8, a, b: u32, unit: int, signed: bool) #no_bounds_check {
	acc := (state.hi.d[unit & 1] << 32) | (state.lo.d[unit & 1] & 0xffffffff)
	p := signed ? u64(i64(i32(a)) * i64(i32(b))) : u64(a) * u64(b)
	s := acc + p
	state.lo.d[unit & 1] = sx32(u32(s))
	state.hi.d[unit & 1] = sx32(u32(s >> 32))
	if rd != 0 {state.r[rd & 31].d[0] = state.lo.d[unit & 1]}
}

div :: proc(a, b: u32, unit: int) #no_bounds_check {
	n, d := i32(a), i32(b)
	switch {
	case d == 0:
		state.lo.d[unit & 1] = n < 0 ? 1 : ~u64(0)
		state.hi.d[unit & 1] = sx32(a)
	case n == min(i32) && d == -1:
		state.lo.d[unit & 1] = sx32(0x80000000)
		state.hi.d[unit & 1] = 0
	case:
		state.lo.d[unit & 1] = sx32(u32(n / d))
		state.hi.d[unit & 1] = sx32(u32(n % d))
	}
}

divu :: proc(a, b: u32, unit: int) #no_bounds_check {
	if b == 0 {
		state.lo.d[unit & 1] = ~u64(0)
		state.hi.d[unit & 1] = sx32(a)
		return
	}
	state.lo.d[unit & 1] = sx32(a / b)
	state.hi.d[unit & 1] = sx32(a % b)
}

// PLZCW: for each word of the low doubleword, a and b, the count of the
// bits after the sign bit equal to it. The high doubleword of rd stays as
// it was, as in PCSX2's MMI.cpp PLZCW, which writes UL[0] and UL[1] only.
plzcw :: proc(a, b: u32, rd: u8) #no_bounds_check {
	f :: proc(v: u32) -> u32 {
		v := v
		if v & 0x80000000 != 0 {v = ~v}
		return v == 0 ? 31 : u32(intrinsics.count_leading_zeros(v)) - 1
	}
	if rd != 0 {state.r[rd & 31].d[0] = u64(f(a)) | u64(f(b)) << 32}
}

// VU float approximation: infinities and NaNs become the largest host
// float, denormals zero. The EE FPU uses the exact model below instead.
fclamp :: #force_inline proc(x: f32) -> f32 {
	u := transmute(u32)x
	switch u & 0x7f800000 {
	case 0x7f800000: return transmute(f32)((u & 0x80000000) | 0x7f7fffff)
	case 0:          return transmute(f32)(u & 0x80000000)
	}
	return x
}

fdiv :: proc(a, b: f32) -> f32 {
	if transmute(u32)b & 0x7f800000 == 0 {
		sign := (transmute(u32)a ~ transmute(u32)b) & 0x80000000
		return transmute(f32)(sign | 0x7f7fffff)
	}
	return fclamp(a / b)
}

frsqrt :: proc(a, b: f32) -> f32 {
	s := math.sqrt(abs(b))
	if transmute(u32)s & 0x7f800000 == 0 {
		return transmute(f32)((transmute(u32)a & 0x80000000) | 0x7f7fffff)
	}
	return fclamp(a / s)
}

// EE FPU arithmetic. The EE float format has no infinities, NaNs or
// denormals: exponent 255 is an ordinary exponent (0x7f800000 is 2^128,
// FMAX the largest value), exponent 0 is zero whatever the mantissa holds,
// results of 2^129 or more saturate to +-FMAX and ones below 2^-126 flush
// to +-0, and x/0 gives +-FMAX. A host float holds neither exponent, so an
// operation that meets one goes through f64 in fpu_slow. The model follows
// PS2Recomp's ps2_runtime_macros.h (GPLv3), checked there and in
// tests/fpu against real-PS2 results from ps2autotests. Left to the host:
// the hardware rounds differently in the last bit now and then.
//
// fadd, fsub and fmul in recomp/r5900 FAST_HELPERS are inline copies of
// fpu_add, fpu_sub and fpu_mul.
FMAX :: 0x7fffffff

// True when a host operation cannot be trusted with x: exponent 255, or
// exponent 0 with a nonzero mantissa.
fspecial :: #force_inline proc "contextless" (x: f32) -> bool {
	t := transmute(u32)x & 0x7fffffff
	return t != 0 && t - 0x00800000 >= 0x7f000000
}

@(private)
to_f64 :: proc "contextless" (x: f32) -> f64 {
	u := transmute(u32)x
	switch u & 0x7f800000 {
	case 0:          return f64(transmute(f32)(u & 0x80000000))
	case 0x7f800000: return f64(transmute(f32)(u - 0x00800000)) * 2
	}
	return f64(x)
}

@(private)
from_f64 :: proc "contextless" (d: f64) -> f32 {
	sign: u32 = math.sign_bit(d) ? 0x80000000 : 0
	e := (transmute(u64)d >> 52) & 0x7ff // 2^(e - 1023)
	switch {
	case e >= 1023 + 129: return transmute(f32)(sign | FMAX)
	case e < 1023 - 126:  return transmute(f32)sign
	case e == 1023 + 128:
		// Convert one exponent lower, then put exponent 255 back.
		b := transmute(u32)f32(d * 0.5)
		if b & 0x7f800000 == 0x7f800000 {return transmute(f32)(sign | FMAX)}
		return transmute(f32)(b + 0x00800000)
	}
	// Rounding up to 2^128 gives the host infinity, which is 2^128 here too.
	return f32(d)
}

Fpu_Op :: enum u8 {Add, Sub, Mul, Div}

// The f64 path of the operations, for operands or results with exponent 0
// or 255. The divisor of a Div is never zero.
fpu_slow :: proc "contextless" (op: Fpu_Op, a, b: f32) -> f32 {
	x, y := to_f64(a), to_f64(b)
	switch op {
	case .Add: return from_f64(x + y)
	case .Sub: return from_f64(x - y)
	case .Mul: return from_f64(x * y)
	case .Div: return from_f64(x / y)
	}
	return 0
}

fpu_add :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	r := a + b
	return fspecial(a) | fspecial(b) | fspecial(r) ? fpu_slow(.Add, a, b) : r
}

fpu_sub :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	r := a - b
	return fspecial(a) | fspecial(b) | fspecial(r) ? fpu_slow(.Sub, a, b) : r
}

fpu_mul :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	r := a * b
	return fspecial(a) | fspecial(b) | fspecial(r) ? fpu_slow(.Mul, a, b) : r
}

// A zero divisor gives +-FMAX with the sign of a xor b.
fpu_div :: proc "contextless" (a, b: f32) -> f32 {
	ua, ub := transmute(u32)a, transmute(u32)b
	if ub & 0x7f800000 == 0 {return transmute(f32)(((ua ~ ub) & 0x80000000) | FMAX)}
	r := a / b
	return fspecial(a) | fspecial(b) | fspecial(r) ? fpu_slow(.Div, a, b) : r
}

// sqrt(|x|), never negative.
fpu_sqrt :: proc "contextless" (x: f32) -> f32 {
	if transmute(u32)x & 0x7f800000 == 0 {return 0}
	return from_f64(math.sqrt(abs(to_f64(x))))
}

// a / sqrt(|b|). The root is rounded to a float first, as on the hardware;
// a zero b gives +-FMAX with the sign of a alone.
fpu_rsqrt :: proc "contextless" (a, b: f32) -> f32 {
	if transmute(u32)b & 0x7f800000 == 0 {
		return transmute(f32)((transmute(u32)a & 0x80000000) | FMAX)
	}
	return fpu_div(a, fpu_sqrt(b))
}

// Order of EE floats for C.cond, MAX and MIN: sign and magnitude as a
// signed integer, every exponent-0 value 0.
fkey :: #force_inline proc "contextless" (x: f32) -> i32 {
	u := transmute(u32)x
	if u & 0x7f800000 == 0 {return 0}
	m := i32(u & 0x7fffffff)
	return u & 0x80000000 != 0 ? -m : m
}

fcond :: #force_inline proc(t: bool) {
	if t {state.fcr31 |= FCR31_C} else {state.fcr31 &~= FCR31_C}
}

cvt_w :: proc(x: f32) -> i32 {
	u := transmute(u32)x
	if u & 0x7f800000 >= 0x4f000000 { // |x| >= 2^31
		return u & 0x80000000 != 0 ? min(i32) : max(i32)
	}
	return i32(x)
}
