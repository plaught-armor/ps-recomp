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

// The MMI multiplies, PDIVBW and PMFHL, called with register numbers by the
// interpreter and recompiled code alike. rs and rt are read before anything
// is written, and LO and HI are written when rd is 0 too.

@(private = "file")
Pmul :: enum u8 {Mult, Multu, Madd, Maddu, Msub}

// PMULTW and the rest: the low words of each doubleword of rs and rt
// multiplied (and added to or subtracted from that doubleword's hi:lo
// low words), each half of the result sign-extended into LO and HI, the
// whole into rd.
@(private = "file")
pmulw :: proc(op: Pmul, rd, rs, rt: u8) #no_bounds_check {
	s, t := state.r[rs & 31], state.r[rt & 31]
	d: Gpr
	for k in 0 ..< 2 {
		p: i64
		if op == .Multu || op == .Maddu {
			p = i64(u64(s.w[2 * k]) * u64(t.w[2 * k]))
		} else {
			p = i64(s.sw[2 * k]) * i64(t.sw[2 * k])
		}
		acc := i64(u64(state.hi.w[2 * k]) << 32 | u64(state.lo.w[2 * k]))
		#partial switch op {
		case .Madd, .Maddu: p = acc + p
		case .Msub:         p = acc - p
		}
		state.lo.d[k] = sx32(u32(p))
		state.hi.d[k] = sx32(u32(u64(p) >> 32))
		d.sd[k] = p
	}
	if rd != 0 {state.r[rd & 31] = d}
}

pmultw :: proc(rd, rs, rt: u8) {pmulw(.Mult, rd, rs, rt)}
pmultuw :: proc(rd, rs, rt: u8) {pmulw(.Multu, rd, rs, rt)}
pmaddw :: proc(rd, rs, rt: u8) {pmulw(.Madd, rd, rs, rt)}
pmadduw :: proc(rd, rs, rt: u8) {pmulw(.Maddu, rd, rs, rt)}
pmsubw :: proc(rd, rs, rt: u8) {pmulw(.Msub, rd, rs, rt)}

// PMULTH, PMADDH and PMSUBH: the eight halfword products land in LO and HI
// words in the order lo0 lo1 hi0 hi1 lo2 lo3 hi2 hi3; rd gets LO and HI's
// even words.
@(private = "file")
pmulh :: proc(op: Pmul, rd, rs, rt: u8) #no_bounds_check {
	s, t := state.r[rs & 31], state.r[rt & 31]
	for k in 0 ..< 8 {
		p := i32(s.sh[k]) * i32(t.sh[k])
		dst := (k & 2) != 0 ? &state.hi : &state.lo
		lane := (k & 1) | ((k >> 1) & 2)
		#partial switch op {
		case .Madd: dst.sw[lane] += p
		case .Msub: dst.sw[lane] -= p
		case:       dst.sw[lane] = p
		}
	}
	if rd != 0 {state.r[rd & 31].w = {state.lo.w[0], state.hi.w[0], state.lo.w[2], state.hi.w[2]}}
}

pmulth :: proc(rd, rs, rt: u8) {pmulh(.Mult, rd, rs, rt)}
pmaddh :: proc(rd, rs, rt: u8) {pmulh(.Madd, rd, rs, rt)}
pmsubh :: proc(rd, rs, rt: u8) {pmulh(.Msub, rd, rs, rt)}

// PHMADH and PHMSBH: for each word, the product of the odd halfwords a plus
// or less that of the even ones, with LO = {v0, a0, v2, a2} and
// HI = {v1, a1, v3, a3}.
@(private = "file")
phm :: proc(add: bool, rd, rs, rt: u8) #no_bounds_check {
	s, t := state.r[rs & 31], state.r[rt & 31]
	for k in 0 ..< 4 {
		a := i32(s.sh[2 * k + 1]) * i32(t.sh[2 * k + 1])
		b := i32(s.sh[2 * k]) * i32(t.sh[2 * k])
		v := add ? a + b : a - b
		dst := (k & 1) != 0 ? &state.hi : &state.lo
		dst.sw[(k >> 1) * 2] = v
		dst.sw[(k >> 1) * 2 + 1] = a
	}
	if rd != 0 {state.r[rd & 31].w = {state.lo.w[0], state.hi.w[0], state.lo.w[2], state.hi.w[2]}}
}

phmadh :: proc(rd, rs, rt: u8) {phm(true, rd, rs, rt)}
phmsbh :: proc(rd, rs, rt: u8) {phm(false, rd, rs, rt)}

// PDIVBW: each word of rs divided by rt's low halfword, quotients to LO's
// words and remainders to HI's, the zero divisor and min(i32) / -1 as div.
pdivbw :: proc(rs, rt: u8) #no_bounds_check {
	s, t := state.r[rs & 31], state.r[rt & 31]
	dv := i32(t.sh[0])
	for k in 0 ..< 4 {
		n := s.sw[k]
		switch {
		case dv == 0:
			state.lo.sw[k] = n < 0 ? 1 : -1
			state.hi.sw[k] = n
		case n == min(i32) && dv == -1:
			state.lo.sw[k] = min(i32)
			state.hi.sw[k] = 0
		case:
			state.lo.sw[k] = n / dv
			state.hi.sw[k] = n % dv
		}
	}
}

// PMFHL by its sa field: LW, UW, SLW, LH, SH; any other sa writes zero.
pmfhl :: proc(rd, sa: u8) #no_bounds_check {
	sat16 :: #force_inline proc(v: i32) -> u16 {return u16(i16(clamp(v, -0x8000, 0x7fff)))}
	sat32 :: #force_inline proc(v: i64) -> u32 {return u32(i32(clamp(v, i64(min(i32)), i64(max(i32)))))}
	d: Gpr
	lo, hi := state.lo, state.hi
	switch sa {
	case 0: d.w = {lo.w[0], hi.w[0], lo.w[2], hi.w[2]}
	case 1: d.w = {lo.w[1], hi.w[1], lo.w[3], hi.w[3]}
	case 2:
		d.d[0] = sx32(sat32(i64(u64(hi.w[0]) << 32 | u64(lo.w[0]))))
		d.d[1] = sx32(sat32(i64(u64(hi.w[2]) << 32 | u64(lo.w[2]))))
	case 3: d.h = {lo.h[0], lo.h[2], hi.h[0], hi.h[2], lo.h[4], lo.h[6], hi.h[4], hi.h[6]}
	case 4:
		d.h = {sat16(lo.sw[0]), sat16(lo.sw[1]), sat16(hi.sw[0]), sat16(hi.sw[1]),
		       sat16(lo.sw[2]), sat16(lo.sw[3]), sat16(hi.sw[2]), sat16(hi.sw[3])}
	}
	if rd != 0 {state.r[rd & 31] = d}
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

// fdiv and frsqrt clamp their operands first, as vu_op does for the add
// and multiply family: the host then never meets an infinity or NaN, and
// exponent 255 divides as the large number it is (2^128 / 2^128 is 1, not
// a NaN whose sign is the host's).
fdiv :: proc(a, b: f32) -> f32 {
	x, y := fclamp(a), fclamp(b)
	if transmute(u32)y & 0x7f800000 == 0 {
		sign := (transmute(u32)x ~ transmute(u32)y) & 0x80000000
		return transmute(f32)(sign | 0x7f7fffff)
	}
	return fclamp(x / y)
}

frsqrt :: proc(a, b: f32) -> f32 {
	x := fclamp(a)
	s := math.sqrt(abs(fclamp(b)))
	if transmute(u32)s & 0x7f800000 == 0 {
		return transmute(f32)((transmute(u32)x & 0x80000000) | 0x7f7fffff)
	}
	return fclamp(x / s)
}

// EE FPU arithmetic. The EE float format has no infinities, NaNs or
// denormals: exponent 255 is an ordinary exponent (0x7f800000 is 2^128,
// FMAX the largest value), exponent 0 is zero whatever the mantissa holds,
// results of 2^129 or more saturate to +-FMAX and ones below 2^-126 flush
// to +-0, and x/0 gives +-FMAX. A host float holds neither exponent, so an
// operation that meets one goes through f64 in fpu_slow (fpu_mul only for
// an operand of exponent 255). The model follows
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

Fpu_Op :: enum u8 {Add, Sub, Mul, Div, Sqrt}

// The f64 path of the operations, for operands or results with exponent 0
// or 255. The divisor of a Div is never zero; Sqrt is sqrt(|a|) for an a
// of exponent 255 and ignores b.
fpu_slow :: proc "contextless" (op: Fpu_Op, a, b: f32) -> f32 {
	when FALLBACK_COUNT {fallback_fpu_slow[op] += 1}
	x, y := to_f64(a), to_f64(b)
	switch op {
	case .Add: return from_f64(x + y)
	case .Sub: return from_f64(x - y)
	case .Mul: return from_f64(x * y)
	case .Div: return from_f64(x / y)
	case .Sqrt: return from_f64(math.sqrt(abs(x)))
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

// The special cases inline but one, as fpu_slow gives them: an operand of
// exponent 0, or a host result below 2^-126, gives +-0, and a host
// infinity from two host floats is their product one exponent lower with
// the exponent put back, or +-FMAX from 2^129. Only an operand of exponent
// 255 times a nonzero goes to fpu_slow.
fpu_mul :: #force_inline proc "contextless" (a, b: f32) -> f32 {
	r := a * b
	if !(fspecial(a) | fspecial(b) | fspecial(r)) {return r}
	ua, ub := transmute(u32)a, transmute(u32)b
	sign := (ua ~ ub) & 0x80000000
	ea, eb := ua & 0x7f800000, ub & 0x7f800000
	if ea == 0 || eb == 0 || transmute(u32)r & 0x7f800000 == 0 {return transmute(f32)sign}
	if ea == 0x7f800000 || eb == 0x7f800000 {return fpu_slow(.Mul, a, b)}
	// The product is near 2^128, so a is 1 or more and a / 2 a host float.
	h := transmute(u32)(transmute(f32)(ua - 0x00800000) * b)
	return transmute(f32)(h & 0x7f800000 == 0x7f800000 ? sign | FMAX : h + 0x00800000)
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
	switch transmute(u32)x & 0x7f800000 {
	case 0:          return 0
	case 0x7f800000: return fpu_slow(.Sqrt, x, 0)
	}
	return from_f64(math.sqrt(abs(f64(x))))
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
