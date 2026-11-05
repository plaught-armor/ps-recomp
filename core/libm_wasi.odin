// The C maths functions LLVM calls on wasi_wasm32. LLVM turns math.sin,
// math.cos and math.exp on f32, math.sin and math.pow on f64 and the simd
// reduce_max/reduce_min on f64 into calls to the C library's sinf, cosf,
// expf, sin, pow, fmax and fmin, and math.pow(2, y) into exp2(y);
// wasi_wasm32 has no C library, so without these the module would import
// them. They are ports chosen to give the same bits as the Linux x86-64
// host build, whose libm is glibc built with FMA (x86-64-v3), so a run in
// the browser computes what a desktop run computes:
//   - sinf, cosf, expf, pow and exp2 are glibc's (from Arm's
//     optimized-routines). Each multiply-add the FMA build fuses is written
//     as an explicit fma. wasm has no fma instruction, so fma is musl's exact
//     integer one.
//   - sin is fdlibm's (FreeBSD msun). It matches glibc's correctly rounded
//     sin on the inputs the tree passes (k*pi/60 for k = 0..30, adx_gain's
//     pan), not on every input.
//   - fmax and fmin have C semantics: a NaN operand gives the other operand.
//     On a tie of +0 and -0 they give +0 (fmax) or -0 (fmin), where the
//     host's maxpd and minpd pick by operand order. Whether the one caller,
//     psx/render/gpu.odin texels_read, can meet that tie is not traced.
// A NaN result's sign and payload are not matched: x86 makes 0/0 negative,
// and wasm leaves NaN signs unspecified.
// tests/libm_wasi checks sinf, cosf and expf on all 2^32 inputs, sin, pow
// and exp2 on the inputs the tree passes and on random ones, and fmax and
// fmin as texels_read calls them on pairs of edge values (the tie left
// out), against glibc. The other hosts still use their own C library; this
// file is wasm only.
//
// Sources, licences and notices:
// - glibc 2.44: sysdeps/ieee754/flt-32/s_sinf.c, s_cosf.c, s_sincosf.h,
//   s_sincosf_data.c, e_expf.c, e_exp2f_data.c and sysdeps/ieee754/dbl-64/
//   e_pow.c, e_exp2.c, e_pow_log_data.c, e_exp_data.c. Copyright (C)
//   2017-2026 Free Software Foundation, Inc. GNU Lesser General Public
//   License 2.1 or later.
// - musl: src/math/fma.c, src/math/scalbn.c. Copyright (c) 2005-2020 Rich
//   Felker, et al. MIT licence.
// - FreeBSD lib/msun/src: s_sin.c, k_sin.c, k_cos.c, e_rem_pio2.c,
//   k_rem_pio2.c, which carry this notice:
//     Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
//     Developed at SunPro, a Sun Microsystems, Inc. business.
//     Permission to use, copy, modify, and distribute this
//     software is freely granted, provided that this notice
//     is preserved.
// The tables below are printed from the compiled C data objects.
#+private file
package core

import "base:intrinsics"
import "core:math"

@(require, linkage = "strong", link_name = "sinf")
c_sinf :: proc "c" (y: f32) -> f32 {
	x := f64(y)
	p := &SINCOSF_TABLE[0]
	top := abstop12(y)
	if top < ABSTOP_PIO4 {
		// glibc forces an underflow for tiny y; wasm has no fp exceptions.
		if top < ABSTOP_TINY do return y
		return sincosf_poly(x, x * x, p, 0)
	} else if top < ABSTOP_120 {
		r, n := sincosf_reduce_fast(x)
		s := p.sign[n & 3]
		if n & 2 != 0 do p = &SINCOSF_TABLE[1]
		return sincosf_poly(r * s, r * r, p, n)
	} else if top < ABSTOP_INF {
		xi := transmute(u32)y
		sign := i32(xi >> 31)
		r, n := sincosf_reduce_large(xi)
		s := p.sign[(n + sign) & 3]
		if (n + sign) & 2 != 0 do p = &SINCOSF_TABLE[1]
		return sincosf_poly(r * s, r * r, p, n)
	}
	return (y - y) / (y - y)
}

@(require, linkage = "strong", link_name = "cosf")
c_cosf :: proc "c" (y: f32) -> f32 {
	x := f64(y)
	p := &SINCOSF_TABLE[0]
	top := abstop12(y)
	if top < ABSTOP_PIO4 {
		if top < ABSTOP_TINY do return 1
		return sincosf_poly(x, x * x, p, 1)
	} else if top < ABSTOP_120 {
		r, n := sincosf_reduce_fast(x)
		s := p.sign[n & 3]
		if n & 2 != 0 do p = &SINCOSF_TABLE[1]
		return sincosf_poly(r * s, r * r, p, n ~ 1)
	} else if top < ABSTOP_INF {
		xi := transmute(u32)y
		sign := i32(xi >> 31)
		r, n := sincosf_reduce_large(xi)
		s := p.sign[(n + sign) & 3]
		if (n + sign) & 2 != 0 do p = &SINCOSF_TABLE[1]
		return sincosf_poly(r * s, r * r, p, n ~ 1)
	}
	return (y - y) / (y - y)
}

@(require, linkage = "strong", link_name = "expf")
c_expf :: proc "c" (x: f32) -> f32 {
	xd := f64(x)
	top := abstop12(x)
	if top >= ABSTOP_88 {
		if transmute(u32)x == 0xff800000 do return 0 // -inf
		if top >= ABSTOP_INF do return x + x
		if x > EXPF_OVERFLOW do return transmute(f32)u32(0x7f800000)
		if x < EXPF_UNDERFLOW do return 0
	}
	// x*N/ln2 = k + r with r in [-1/2, 1/2] and int k.
	kd := fma(EXPF_INVLN2_SCALED, xd, EXPF_SHIFT)
	ki := transmute(u64)kd
	kd -= EXPF_SHIFT
	r := fma(EXPF_INVLN2_SCALED, xd, -kd)
	// exp(x) = 2^(k/N) * 2^(r/N) ~= s * (C0*r^3 + C1*r^2 + C2*r + 1)
	t := EXP2F_TAB[ki % 32] + (ki << (52 - 5))
	s := transmute(f64)t
	z := fma(EXPF_POLY_SCALED[0], r, EXPF_POLY_SCALED[1])
	r2 := r * r
	y := fma(EXPF_POLY_SCALED[2], r, 1)
	y = fma(z, r2, y)
	return f32(y * s)
}

@(require, linkage = "strong", link_name = "pow")
c_pow :: proc "c" (x, y: f64) -> f64 {
	sign_bias: u32 = 0
	ix := transmute(u64)x
	iy := transmute(u64)y
	topx := top12(x)
	topy := top12(y)
	if topx - 0x001 >= 0x7ff - 0x001 || (topy & 0x7ff) - 0x3be >= 0x43e - 0x3be {
		// x is subnormal, zero, inf, nan or negative, or |y| is tiny or huge.
		if pow_zeroinfnan(iy) {
			if 2 * iy == 0 do return 1
			if ix == ONE_BITS do return 1
			if 2 * ix > 2 * INF_BITS || 2 * iy > 2 * INF_BITS do return x + y
			if 2 * ix == 2 * ONE_BITS do return 1
			if (2 * ix < 2 * ONE_BITS) == (iy >> 63 == 0) do return 0 // |x|<1 && y==inf or |x|>1 && y==-inf
			return y * y
		}
		if pow_zeroinfnan(ix) {
			x2 := x * x
			if ix >> 63 != 0 && pow_checkint(iy) == 1 do x2 = -x2
			return iy >> 63 != 0 ? 1 / x2 : x2
		}
		if ix >> 63 != 0 {
			// Finite x < 0.
			yint := pow_checkint(iy)
			if yint == 0 do return (x - x) / (x - x)
			if yint == 1 do sign_bias = POW_SIGN_BIAS
			ix &= 0x7fffffffffffffff
			topx &= 0x7ff
		}
		if (topy & 0x7ff) - 0x3be >= 0x43e - 0x3be {
			// |y| is tiny or huge; x is positive here.
			if ix == ONE_BITS do return 1
			if (topy & 0x7ff) < 0x3be do return ix > ONE_BITS ? 1 + y : 1 - y
			return (ix > ONE_BITS) == (topy < 0x800) ? pow_oflow(0) : pow_uflow(0)
		}
		if topx == 0 {
			// Subnormal x: normalize.
			ix = transmute(u64)(x * 0h4330000000000000) // 0x1p52
			ix &= 0x7fffffffffffffff
			ix -= 52 << 52
		}
	}
	hi, lo := pow_log(ix)
	ehi := y * hi
	elo := fma(y, lo, fma(y, hi, -ehi))
	return pow_exp(ehi, elo, sign_bias)
}

@(require, linkage = "strong", link_name = "exp2")
c_exp2 :: proc "c" (x: f64) -> f64 {
	abstop := top12(x) & 0x7ff
	if abstop - 0x3c9 >= 0x408 - 0x3c9 { 	// top12(0x1p-54), top12(512.0)
		if abstop - 0x3c9 >= 0x80000000 do return 1 + x // tiny x
		if abstop >= 0x409 { 	// top12(1024.0)
			ix := transmute(u64)x
			if ix == 0xfff0000000000000 do return 0 // -inf
			if abstop >= 0x7ff do return 1 + x
			if ix >> 63 == 0 do return pow_oflow(0)
			if ix >= 0xc090cc0000000000 do return pow_uflow(0) // -1075.0
		}
		if 2 * transmute(u64)x > 2 * 0x408d000000000000 do abstop = 0 // |x| > 928: exp2_specialcase
	}
	// exp2(x) = 2^(k/N) * 2^r, with 2^r in [2^(-1/2N),2^(1/2N)].
	kd := x + EXP2_SHIFT
	ki := transmute(u64)kd
	kd -= EXP2_SHIFT
	r := x - kd
	idx := 2 * (ki % 128)
	top := ki << (52 - 7)
	tail := transmute(f64)EXP_TAB[idx]
	sbits := EXP_TAB[idx + 1] + top
	r2 := r * r
	c := &EXP2_POLY
	tmp := fma(fma(r, c[4], c[3]), r2 * r2, fma(fma(r, c[2], c[1]), r2, fma(r, c[0], tail)))
	if abstop == 0 do return exp2_specialcase(tmp, sbits, ki)
	scale := transmute(f64)sbits
	return fma(scale, tmp, scale)
}

@(require, linkage = "strong", link_name = "sin")
c_sin :: proc "c" (x: f64) -> f64 {
	ix := u32(transmute(u64)x >> 32) & 0x7fffffff
	if ix <= 0x3fe921fb { 	// |x| ~< pi/4
		if ix < 0x3e500000 do return x // |x| < 2^-26
		return k_sin(x, 0, false)
	}
	if ix >= 0x7ff00000 do return x - x // inf or nan
	n, y0, y1 := rem_pio2(x)
	switch n & 3 {
	case 0:
		return k_sin(y0, y1, true)
	case 1:
		return k_cos(y0, y1)
	case 2:
		return -k_sin(y0, y1, true)
	}
	return -k_cos(y0, y1)
}

@(require, linkage = "strong", link_name = "fmax")
c_fmax :: proc "c" (x, y: f64) -> f64 {
	if x != x do return y
	if y != y do return x
	sx, sy := transmute(u64)x >> 63, transmute(u64)y >> 63
	if sx != sy do return sx != 0 ? y : x
	return x < y ? y : x
}

@(require, linkage = "strong", link_name = "fmin")
c_fmin :: proc "c" (x, y: f64) -> f64 {
	if x != x do return y
	if y != y do return x
	sx, sy := transmute(u64)x >> 63, transmute(u64)y >> 63
	if sx != sy do return sx != 0 ? x : y
	return x < y ? x : y
}

// musl's fma: x*y + z rounded once, in integer arithmetic. Exact for every
// input; wasm only lacks the floating-point exception flags.

FMA_ZEROINFNAN :: 0x7ff - 0x3ff - 52 - 1

fma_normalize :: proc "contextless" (x: f64) -> (m: u64, e: i32, neg: bool) {
	ix := transmute(u64)x
	e = i32(ix >> 52)
	neg = e & 0x800 != 0
	e &= 0x7ff
	if e == 0 {
		ix = transmute(u64)(x * 0h43E0000000000000) // 0x1p63
		e = i32(ix >> 52 & 0x7ff)
		e = e != 0 ? e - 63 : 0x800
	}
	ix &= 1 << 52 - 1
	ix |= 1 << 52
	ix <<= 1
	e -= 0x3ff + 52 + 1
	return ix, e, neg
}

fma_mul :: proc "contextless" (x, y: u64) -> (hi, lo: u64) {
	xlo, xhi := x & 0xffffffff, x >> 32
	ylo, yhi := y & 0xffffffff, y >> 32
	t1 := xlo * ylo
	t2 := xlo * yhi + xhi * ylo
	t3 := xhi * yhi
	lo = t1 + (t2 << 32)
	hi = t3 + (t2 >> 32) + (t1 > lo ? 1 : 0)
	return
}

fma :: proc "contextless" (x, y, z: f64) -> f64 {
	// Normalize so the top 10 bits and the last bit are 0.
	xm, xe, xneg := fma_normalize(x)
	ym, ye, yneg := fma_normalize(y)
	zm, ze, zneg := fma_normalize(z)
	if xe >= FMA_ZEROINFNAN || ye >= FMA_ZEROINFNAN do return x * y + z
	if ze >= FMA_ZEROINFNAN {
		if ze > FMA_ZEROINFNAN do return x * y + z // z == 0
		return z
	}

	// r = x*y; either the top 20 or 21 bits of rhi and the last 2 bits of
	// rlo are 0.
	rhi, rlo := fma_mul(xm, ym)

	// Align the exponents: z <<= kz, r >>= kr with kz+kr == d, e = e+kr.
	e := xe + ye
	d := ze - e
	zhi, zlo: u64
	if d > 0 {
		if d < 64 {
			zlo = zm << uint(d)
			zhi = zm >> uint(64 - d)
		} else {
			zlo = 0
			zhi = zm
			e = ze - 64
			d -= 64
			if d == 0 {
			} else if d < 64 {
				rlo = rhi << uint(64 - d) | rlo >> uint(d) | (rlo << uint(64 - d) != 0 ? 1 : 0)
				rhi = rhi >> uint(d)
			} else {
				rlo = 1
				rhi = 0
			}
		}
	} else {
		zhi = 0
		d = -d
		if d == 0 {
			zlo = zm
		} else if d < 64 {
			zlo = zm >> uint(d) | (zm << uint(64 - d) != 0 ? 1 : 0)
		} else {
			zlo = 1
		}
	}

	// Add.
	neg := xneg != yneg
	nonzero := true
	if neg == zneg {
		rlo += zlo
		rhi += zhi + (rlo < zlo ? 1 : 0)
	} else {
		t := rlo
		rlo -= zlo
		rhi = rhi - zhi - (t < rlo ? 1 : 0)
		if rhi >> 63 != 0 {
			rlo = ~rlo + 1
			rhi = ~rhi + 1 - (rlo != 0 ? 1 : 0)
			neg = !neg
		}
		nonzero = rhi != 0
	}

	// Set rhi to the top 63 bits of the result (the last bit is sticky).
	if nonzero {
		e += 64
		d = i32(intrinsics.count_leading_zeros(rhi)) - 1 // d > 0
		rhi = rhi << uint(d) | rlo >> uint(64 - d) | (rlo << uint(d) != 0 ? 1 : 0)
	} else if rlo != 0 {
		d = i32(intrinsics.count_leading_zeros(rlo)) - 1
		if d < 0 {
			rhi = rlo >> 1 | (rlo & 1)
		} else {
			rhi = rlo << uint(d)
		}
	} else {
		return x * y + z // exact +-0
	}
	e -= d

	// Convert to double; i is in [1<<62, (1<<63)-1].
	i := i64(rhi)
	if neg do i = -i
	r := f64(i) // |r| is in [0x1p62, 0x1p63]

	if e < -1022 - 62 {
		// The result is subnormal before rounding.
		if e == -1022 - 63 {
			c := f64(0h43E0000000000000) // 0x1p63
			if neg do c = -c
			if r == c {
				// Min normal after rounding: the double to float
				// conversion imitates the rounding.
				fltmin := f32(0h341FFFFFF0000000 * r) // 0x0.ffffff8p-63*FLT_MIN
				return 0h07F0000000000000 * f64(fltmin) // DBL_MIN/FLT_MIN
			}
			// One bit is lost when scaled: add another top bit so the
			// conversion rounds once if it is inexact.
			if rhi << 53 != 0 {
				i = i64(rhi >> 1 | (rhi & 1) | 1 << 62)
				if neg do i = -i
				r = f64(i)
				r = 2 * r - c // remove the top bit
			}
		} else {
			// Round only once when scaled.
			i = i64((rhi >> 10 | (rhi << 54 != 0 ? 1 : 0)) << 10)
			if neg do i = -i
			r = f64(i)
		}
	}
	return scalbn(r, e)
}

scalbn :: proc "contextless" (x: f64, n_in: i32) -> f64 {
	y := x
	n := n_in
	if n > 1023 {
		y *= 0h7FE0000000000000 // 0x1p1023
		n -= 1023
		if n > 1023 {
			y *= 0h7FE0000000000000
			n -= 1023
			if n > 1023 do n = 1023
		}
	} else if n < -1022 {
		// Keep the final n < -53 to avoid double rounding in the
		// subnormal range.
		y *= 0h0360000000000000 // 0x1p-1022 * 0x1p53
		n += 1022 - 53
		if n < -1022 {
			y *= 0h0360000000000000
			n += 1022 - 53
			if n < -1022 do n = -1022
		}
	}
	return y * transmute(f64)(u64(0x3ff + n) << 52)
}

// glibc sinf, cosf (s_sinf.c, s_cosf.c, s_sincosf.h).

abstop12 :: #force_inline proc "contextless" (x: f32) -> u32 {
	return (transmute(u32)x >> 20) & 0x7ff
}

ABSTOP_PIO4 :: 0x3f4 // abstop12(0x1.921FB6p-1f)
ABSTOP_TINY :: 0x398 // abstop12(0x1p-12f)
ABSTOP_120 :: 0x42f // abstop12(120.0f)
ABSTOP_88 :: 0x42b // abstop12(88.0f)
ABSTOP_INF :: 0x7f8 // abstop12(INFINITY)

Sincosf :: struct {
	sign:    [4]f64, // sign of sine in quadrants 0..3
	hpi_inv: f64, // 2/PI * 2^24
	hpi:     f64, // PI/2
	c0, c1, c2, c3, c4: f64, // cosine polynomial
	s1, s2, s3: f64, // sine polynomial
}

// Polynomial for sin(x) (n even) or cos(x) (n odd), |x| <= pi/4.
sincosf_poly :: proc "contextless" (x, x2: f64, p: ^Sincosf, n: i32) -> f32 {
	if n & 1 == 0 {
		x3 := x * x2
		s1 := fma(x2, p.s3, p.s2)
		x7 := x3 * x2
		s := fma(x3, p.s1, x)
		return f32(fma(x7, s1, s))
	}
	x4 := x2 * x2
	c2 := fma(x2, p.c4, p.c3)
	c1 := fma(x2, p.c1, p.c0)
	x6 := x4 * x2
	c := fma(x4, p.c2, c1)
	return f32(fma(x6, c2, c))
}

// Fast range reduction for |x| < 120: x - n*pi/2 with n the quadrant.
sincosf_reduce_fast :: proc "contextless" (x: f64) -> (f64, i32) {
	p := &SINCOSF_TABLE[0]
	r := x * p.hpi_inv
	n := (i32(r) + 0x800000) >> 24
	return fma(-f64(n), p.hpi, x), n
}

// Range reduction for finite |x| >= 120, in integer arithmetic with
// INV_PIO4, 4/PI as a 192-bit fraction.
sincosf_reduce_large :: proc "contextless" (xi_in: u32) -> (f64, i32) {
	arr := INV_PIO4[(xi_in >> 26) & 15:]
	shift := (xi_in >> 23) & 7
	xi := ((xi_in & 0xffffff) | 0x800000) << shift
	r0 := u64(xi * arr[0]) // a 32-bit product, as in C
	r1 := u64(xi) * u64(arr[4])
	r2 := u64(xi) * u64(arr[8])
	r0 = (r2 >> 32) | (r0 << 32)
	r0 += r1
	n := (r0 + 1 << 61) >> 62
	r0 -= n << 62
	return f64(i64(r0)) * PI63, i32(n)
}

PI63 :: 0h3C1921FB54442D18 // 0x1.921FB54442D18p-62

// glibc expf (e_expf.c, e_exp2f_data.c).

EXPF_OVERFLOW :: f32(0h42B17217) // 0x1.62e42ep6f
EXPF_UNDERFLOW :: f32(0hC2CFF1B4) // -0x1.9fe368p6f

// glibc pow and exp2 (e_pow.c, e_exp2.c, e_pow_log_data.c, e_exp_data.c).

ONE_BITS :: 0x3ff0000000000000
INF_BITS :: 0x7ff0000000000000
POW_SIGN_BIAS :: 0x800 << 7

top12 :: #force_inline proc "contextless" (x: f64) -> u32 {
	return u32(transmute(u64)x >> 52)
}

// 0 if iy is not an integer, 1 if odd, 2 if even.
pow_checkint :: proc "contextless" (iy: u64) -> int {
	e := int(iy >> 52 & 0x7ff)
	if e < 0x3ff do return 0
	if e > 0x3ff + 52 do return 2
	if iy & (u64(1) << uint(0x3ff + 52 - e) - 1) != 0 do return 0
	if iy & (u64(1) << uint(0x3ff + 52 - e)) != 0 do return 1
	return 2
}

// True if i is the bits of 0, inf or nan.
pow_zeroinfnan :: proc "contextless" (i: u64) -> bool {
	return 2 * i - 1 >= 2 * INF_BITS - 1
}

// glibc returns 0x1p769*0x1p769 and 0x1p-767*0x1p-767 to raise the flags.
pow_oflow :: proc "contextless" (sign: u32) -> f64 {
	inf := transmute(f64)u64(INF_BITS)
	return sign != 0 ? -inf : inf
}

pow_uflow :: proc "contextless" (sign: u32) -> f64 {
	return sign != 0 ? -0.0 : 0.0
}

// log(x) as hi + tail, with x the bits of a positive normal double.
pow_log :: proc "contextless" (ix: u64) -> (f64, f64) {
	// x = 2^k z; where z is in range [OFF,2*OFF) and exact.
	tmp := ix - 0x3fe6955500000000
	i := (tmp >> (52 - 7)) % 128
	k := i64(tmp) >> 52
	iz := ix - (tmp & (0xfff << 52))
	z := transmute(f64)iz
	kd := f64(k)
	// log(x) = k*Ln2 + log(c) + log1p(z/c-1).
	invc, logc, logctail := POW_INVC[i], POW_LOGC[i], POW_LOGCTAIL[i]
	r := fma(z, invc, -1)
	t1 := fma(kd, POW_LN2HI, logc)
	t2 := t1 + r
	lo1 := fma(kd, POW_LN2LO, logctail)
	lo2 := t1 - t2 + r
	a := &POW_POLY
	ar := a[0] * r
	ar2 := r * ar
	ar3 := r * ar2
	hi := t2 + ar2
	lo3 := fma(r, ar, -ar2)
	lo4 := t2 - hi + ar2
	q := fma(ar2, fma(ar2, fma(r, a[6], a[5]), fma(r, a[4], a[3])), fma(r, a[2], a[1]))
	lo := fma(ar3, q, lo1 + lo2 + lo3 + lo4)
	y := hi + lo
	return y, hi - y + lo
}

// exp(x + xtail) for pow, when the result needs extra care: tiny or huge.
pow_specialcase :: proc "contextless" (tmp: f64, sbits_in: u64, ki: u64) -> f64 {
	sbits := sbits_in
	if ki & 0x80000000 == 0 {
		// k > 0, the exponent of scale might have overflowed.
		sbits -= 1009 << 52
		scale := transmute(f64)sbits
		return fma(tmp, scale, scale) * 0h7F00000000000000 // 0x1p1009
	}
	// k < 0, need special care in the subnormal range.
	sbits += 1022 << 52
	scale := transmute(f64)sbits
	st := scale * tmp
	y := scale + st
	if abs(y) < 1 {
		one := 1.0
		if y < 0 do one = -1
		lo := scale - y + st
		hi := one + y
		lo = one - hi + y + lo
		y = (hi + lo) - one
		if y == 0 do y = transmute(f64)(sbits & 0x8000000000000000)
	}
	return 0h0010000000000000 * y // 0x1p-1022
}

pow_exp :: proc "contextless" (x, xtail: f64, sign_bias: u32) -> f64 {
	abstop := top12(x) & 0x7ff
	if abstop - 0x3c9 >= 0x408 - 0x3c9 { 	// top12(0x1p-54), top12(512.0)
		if abstop - 0x3c9 >= 0x80000000 {
			// Tiny x: exp(x) is 1 + x.
			one := 1 + x
			return sign_bias != 0 ? -one : one
		}
		if abstop >= 0x409 { 	// top12(1024.0)
			if transmute(u64)x >> 63 != 0 do return pow_uflow(sign_bias)
			return pow_oflow(sign_bias)
		}
		abstop = 0 // large x, handled by pow_specialcase
	}
	// exp(x) = 2^(k/N) * exp(r), with exp(r) in [2^(-1/2N),2^(1/2N)].
	kd := fma(x, EXP_INVLN2N, EXP_SHIFT)
	ki := transmute(u64)kd
	kd -= EXP_SHIFT
	r := fma(kd, EXP_NEGLN2LON, fma(kd, EXP_NEGLN2HIN, x))
	r += xtail
	idx := 2 * (ki % 128)
	top := (ki + u64(sign_bias)) << (52 - 7)
	tail := transmute(f64)EXP_TAB[idx]
	sbits := EXP_TAB[idx + 1] + top
	r2 := r * r
	c := &EXP_POLY
	tmp := fma(r2 * r2, fma(r, c[3], c[2]), fma(r2, fma(r, c[1], c[0]), tail + r))
	if abstop == 0 do return pow_specialcase(tmp, sbits, ki)
	scale := transmute(f64)sbits
	return fma(tmp, scale, scale)
}

// exp2(x) when the result may overflow or underflow: scale*(1+tmp) with
// scale's exponent out of range.
exp2_specialcase :: proc "contextless" (tmp: f64, sbits_in: u64, ki: u64) -> f64 {
	sbits := sbits_in
	if ki & 0x80000000 == 0 {
		// k > 0, the exponent of scale might have overflowed by 1.
		sbits -= 1 << 52
		scale := transmute(f64)sbits
		y := fma(scale, tmp, scale)
		return y + y
	}
	// k < 0, need special care in the subnormal range.
	sbits += 1022 << 52
	scale := transmute(f64)sbits
	st := scale * tmp
	y := scale + st
	if y < 1 {
		// Round y once before it is scaled into the subnormal range.
		lo := scale - y + st
		hi := 1 + y
		lo = 1 - hi + y + lo
		y = (hi + lo) - 1
		if y == 0 do y = 0 // no -0
	}
	return 0h0010000000000000 * y // 0x1p-1022
}

// fdlibm sin (s_sin.c, k_sin.c, k_cos.c, e_rem_pio2.c, k_rem_pio2.c).

// sin(x+y) for |x| ~< pi/4, y the tail of x; tail is false when y is 0.
k_sin :: proc "contextless" (x, y: f64, tail: bool) -> f64 {
	z := x * x
	w := z * z
	r := K_SIN_S2 + z * (K_SIN_S3 + z * K_SIN_S4) + z * w * (K_SIN_S5 + z * K_SIN_S6)
	v := z * x
	if !tail do return x + v * (K_SIN_S1 + z * r)
	return x - ((z * (0.5 * y - v * r) - y) - v * K_SIN_S1)
}

// cos(x+y) for |x| ~< pi/4, y the tail of x.
k_cos :: proc "contextless" (x, y: f64) -> f64 {
	z := x * x
	w := z * z
	r := z * (K_COS_C1 + z * (K_COS_C2 + z * K_COS_C3)) + w * w * (K_COS_C4 + z * (K_COS_C5 + z * K_COS_C6))
	hz := 0.5 * z
	w = 1 - hz
	return w + (((1 - w) - hz) + (z * r - x * y))
}

TWO24 :: 0h4170000000000000 // 0x1p24
TWON24 :: 0h3E70000000000000 // 0x1p-24

// x - n*pi/2 as y0 + y1, for finite |x| > pi/4; n is returned.
rem_pio2 :: proc "contextless" (x: f64) -> (n: i32, y0, y1: f64) {
	hx := u32(transmute(u64)x >> 32)
	ix := hx & 0x7fffffff
	pos := hx >> 31 == 0
	k := 0 // the n of the small cases, |x| ~<= 9pi/4
	if ix <= 0x400f6a7a { 	// |x| ~<= 5pi/4
		if ix & 0xfffff != 0x921fb { 	// not near pi/2 or pi
			k = ix <= 0x4002d97c ? 1 : 2
		}
	} else if ix <= 0x401c463b { 	// |x| ~<= 9pi/4
		if ix <= 0x4015fdbc { 	// |x| ~<= 7pi/4
			if ix != 0x4012d97c do k = 3 // not near 3pi/2
		} else if ix != 0x401921fb { 	// not near 2pi
			k = 4
		}
	}
	if k != 0 {
		fk := f64(k)
		if pos {
			z := x - fk * REM_PIO2_1
			y0 = z - fk * REM_PIO2_1T
			return i32(k), y0, (z - y0) - fk * REM_PIO2_1T
		}
		z := x + fk * REM_PIO2_1
		y0 = z + fk * REM_PIO2_1T
		return -i32(k), y0, (z - y0) + fk * REM_PIO2_1T
	}
	if ix < 0x413921fb { 	// |x| ~< 2^20*(pi/2), medium size
		// rint for |x*invpio2| < 2^51
		fn := (x * REM_INVPIO2 + 0h4338000000000000) - 0h4338000000000000
		n = i32(fn)
		r := x - fn * REM_PIO2_1
		w := fn * REM_PIO2_1T // 1st round, good to 85 bits
		j := i32(ix >> 20)
		y0 = r - w
		i := j - i32((u32(transmute(u64)y0 >> 32) >> 20) & 0x7ff)
		if i > 16 { 	// 2nd round, good to 118 bits
			t := r
			w = fn * REM_PIO2_2
			r = t - w
			w = fn * REM_PIO2_2T - ((t - r) - w)
			y0 = r - w
			i = j - i32((u32(transmute(u64)y0 >> 32) >> 20) & 0x7ff)
			if i > 49 { 	// 3rd round, good to 151 bits
				t = r
				w = fn * REM_PIO2_3
				r = t - w
				w = fn * REM_PIO2_3T - ((t - r) - w)
				y0 = r - w
			}
		}
		return n, y0, (r - y0) - w
	}
	// All other (large) arguments; inf and nan do not get here.
	// z = scalbn(|x|, -ilogb(x) + 23)
	e0 := i32(ix >> 20) - 1046
	z := transmute(f64)(u64(ix - (u32(e0) << 20)) << 32 | (transmute(u64)x & 0xffffffff))
	tx: [3]f64
	for i in 0 ..< 2 {
		tx[i] = f64(i32(z))
		z = (z - tx[i]) * TWO24
	}
	tx[2] = z
	nx := i32(3)
	for tx[nx - 1] == 0 do nx -= 1
	ty: [2]f64
	n = k_rem_pio2(&tx, &ty, e0, nx)
	if !pos do return -n, -ty[0], -ty[1]
	return n, ty[0], ty[1]
}

// fdlibm __kernel_rem_pio2 with prec 1 (53-bit y[0] and y[1]): x*2^e0 mod
// pi/2, x given as nx 24-bit pieces.
k_rem_pio2 :: proc "contextless" (x: ^[3]f64, y: ^[2]f64, e0: i32, nx: i32) -> i32 {
	JK :: 4 // init_jk[prec]: terms of ipio2 for prec 1
	JP :: JK
	iq: [20]i32
	f, fq, q: [20]f64

	// jx+1 terms of x; jv is the index of the first ipio2 term used.
	jx := nx - 1
	jv := (e0 - 3) / 24
	if jv < 0 do jv = 0
	q0 := e0 - 24 * (jv + 1)

	// f[0..jx+jk] = ipio2[jv-jx..jv+jk].
	j := jv - jx
	for i in 0 ..= jx + JK {
		f[i] = j < 0 ? 0 : f64(IPIO2[j])
		j += 1
	}
	// q[0..jk] = sum x[i]*f[i+j]
	for i in 0 ..= i32(JK) {
		fw := 0.0
		for jj in 0 ..= jx do fw += x[jj] * f[jx + i - jj]
		q[i] = fw
	}

	jz := i32(JK)
	for {
		// Distill q[] into iq[] reversingly.
		z := q[jz]
		for jj, i := jz, 0; jj > 0; jj, i = jj - 1, i + 1 {
			fw := f64(i32(TWON24 * z))
			iq[i] = i32(z - TWO24 * fw)
			z = q[jj - 1] + fw
		}

		// Compute n.
		z = scalbn(z, q0) // actual value of z
		z -= 8 * math.floor(z * 0.125) // trim off integer >= 8
		n := i32(z)
		z -= f64(n)
		ih: i32 = 0
		if q0 > 0 { 	// need iq[jz-1] to determine n
			i := iq[jz - 1] >> uint(24 - q0)
			n += i
			iq[jz - 1] -= i << uint(24 - q0)
			ih = iq[jz - 1] >> uint(23 - q0)
		} else if q0 == 0 {
			ih = iq[jz - 1] >> 23
		} else if z >= 0.5 {
			ih = 2
		}

		if ih > 0 { 	// q > 0.5
			n += 1
			carry := false
			for i in 0 ..< jz { 	// compute 1-q
				jj := iq[i]
				if !carry {
					if jj != 0 {
						carry = true
						iq[i] = 0x1000000 - jj
					}
				} else {
					iq[i] = 0xffffff - jj
				}
			}
			switch q0 { 	// rare case: chance is 1 in 12
			case 1:
				iq[jz - 1] &= 0x7fffff
			case 2:
				iq[jz - 1] &= 0x3fffff
			}
			if ih == 2 {
				z = 1 - z
				if carry do z -= scalbn(1, q0)
			}
		}

		// Check if recomputation is needed.
		if z == 0 {
			jj: i32 = 0
			for i := jz - 1; i >= JK; i -= 1 do jj |= iq[i]
			if jj == 0 { 	// need recomputation
				k: i32 = 1
				for iq[JK - k] == 0 do k += 1 // k = no. of terms needed
				for i in jz + 1 ..= jz + k { 	// add q[jz+1] to q[jz+k]
					f[jx + i] = f64(IPIO2[jv + i])
					fw := 0.0
					for jx2 in 0 ..= jx do fw += x[jx2] * f[jx + i - jx2]
					q[i] = fw
				}
				jz += k
				continue
			}
		}

		// Chop off zero terms.
		if z == 0 {
			jz -= 1
			q0 -= 24
			for iq[jz] == 0 {
				jz -= 1
				q0 -= 24
			}
		} else { 	// break z into 24-bit if necessary
			z = scalbn(z, -q0)
			if z >= TWO24 {
				fw := f64(i32(TWON24 * z))
				iq[jz] = i32(z - TWO24 * fw)
				jz += 1
				q0 += 24
				iq[jz] = i32(fw)
			} else {
				iq[jz] = i32(z)
			}
		}

		// Convert integer "bit" chunk to floating-point value.
		fw := scalbn(1, q0)
		for i := jz; i >= 0; i -= 1 {
			q[i] = fw * f64(iq[i])
			fw *= TWON24
		}

		// Compute PIo2[0,...,jp]*q[jz,...,0].
		for i := jz; i >= 0; i -= 1 {
			fw = 0
			for k: i32 = 0; k <= JP && k <= jz - i; k += 1 do fw += PIO2_PARTS[k] * q[i + k]
			fq[jz - i] = fw
		}

		// Compress fq[] into y[].
		fw = 0
		for i := jz; i >= 0; i -= 1 do fw += fq[i]
		y[0] = ih == 0 ? fw : -fw
		fw = fq[0] - fw
		for i in 1 ..= jz do fw += fq[i]
		y[1] = ih == 0 ? fw : -fw
		return n & 7
	}
}

// Tables and constants.
@(rodata)
SINCOSF_TABLE := [2]Sincosf {
	{
		sign = {0h3FF0000000000000, 0hBFF0000000000000, 0hBFF0000000000000, 0h3FF0000000000000},
		hpi_inv = 0h41645F306DC9C883, // 0x1.45f306dc9c883p+23
		hpi = 0h3FF921FB54442D18, // 0x1.921fb54442d18p+0
		c0 = 0h3FF0000000000000, // 0x1p+0
		c1 = 0hBFDFFFFFFD0C621C, // -0x1.ffffffd0c621cp-2
		c2 = 0h3FA55553E1068F19, // 0x1.55553e1068f19p-5
		c3 = 0hBF56C087E89A359D, // -0x1.6c087e89a359dp-10
		c4 = 0h3EF99343027BF8C3, // 0x1.99343027bf8c3p-16
		s1 = 0hBFC555545995A603, // -0x1.555545995a603p-3
		s2 = 0h3F81107605230BC4, // 0x1.1107605230bc4p-7
		s3 = 0hBF2994EB3774CF24, // -0x1.994eb3774cf24p-13
	},
	{
		sign = {0h3FF0000000000000, 0hBFF0000000000000, 0hBFF0000000000000, 0h3FF0000000000000},
		hpi_inv = 0h41645F306DC9C883, // 0x1.45f306dc9c883p+23
		hpi = 0h3FF921FB54442D18, // 0x1.921fb54442d18p+0
		c0 = 0hBFF0000000000000, // -0x1p+0
		c1 = 0h3FDFFFFFFD0C621C, // 0x1.ffffffd0c621cp-2
		c2 = 0hBFA55553E1068F19, // -0x1.55553e1068f19p-5
		c3 = 0h3F56C087E89A359D, // 0x1.6c087e89a359dp-10
		c4 = 0hBEF99343027BF8C3, // -0x1.99343027bf8c3p-16
		s1 = 0hBFC555545995A603, // -0x1.555545995a603p-3
		s2 = 0h3F81107605230BC4, // 0x1.1107605230bc4p-7
		s3 = 0hBF2994EB3774CF24, // -0x1.994eb3774cf24p-13
	},
}
@(rodata)
INV_PIO4 := [24]u32{
	0x000000A2, 0x0000A2F9, 0x00A2F983, 0xA2F9836E, 0xF9836E4E, 0x836E4E44,
	0x6E4E4415, 0x4E441529, 0x441529FC, 0x1529FC27, 0x29FC2757, 0xFC2757D1,
	0x2757D1F5, 0x57D1F534, 0xD1F534DD, 0xF534DDC0, 0x34DDC0DB, 0xDDC0DB62,
	0xC0DB6295, 0xDB629599, 0x6295993C, 0x95993C43, 0x993C4390, 0x3C439041,
}
@(rodata)
EXP2F_TAB := [32]u64{
	0x3FF0000000000000, 0x3FEFD9B0D3158574, 0x3FEFB5586CF9890F, 0x3FEF9301D0125B51,
	0x3FEF72B83C7D517B, 0x3FEF54873168B9AA, 0x3FEF387A6E756238, 0x3FEF1E9DF51FDEE1,
	0x3FEF06FE0A31B715, 0x3FEEF1A7373AA9CB, 0x3FEEDEA64C123422, 0x3FEECE086061892D,
	0x3FEEBFDAD5362A27, 0x3FEEB42B569D4F82, 0x3FEEAB07DD485429, 0x3FEEA47EB03A5585,
	0x3FEEA09E667F3BCD, 0x3FEE9F75E8EC5F74, 0x3FEEA11473EB0187, 0x3FEEA589994CCE13,
	0x3FEEACE5422AA0DB, 0x3FEEB737B0CDC5E5, 0x3FEEC49182A3F090, 0x3FEED503B23E255D,
	0x3FEEE89F995AD3AD, 0x3FEEFF76F2FB5E47, 0x3FEF199BDD85529C, 0x3FEF3720DCEF9069,
	0x3FEF5818DCFBA487, 0x3FEF7C97337B9B5F, 0x3FEFA4AFA2A490DA, 0x3FEFD0765B6E4540,
}
EXPF_SHIFT :: 0h4338000000000000 // 0x1.8p+52
EXPF_INVLN2_SCALED :: 0h40471547652B82FE // 0x1.71547652b82fep+5
@(rodata)
EXPF_POLY_SCALED := [3]f64{
	0h3EBC6AF84B912394, 0h3F2EBFCE50FAC4F3, 0h3F962E42FF0C52D6,
}
POW_LN2HI :: 0h3FE62E42FEFA3800 // 0x1.62e42fefa38p-1
POW_LN2LO :: 0h3D2EF35793C76730 // 0x1.ef35793c7673p-45
@(rodata)
POW_POLY := [7]f64{
	0hBFE0000000000000, 0hBFE5555555555560, 0h3FE0000000000006, 0h3FE999999959554E,
	0hBFE555555529A47A, 0hBFF2495B9B4845E9, 0h3FF0002B8B263FC3,
}
@(rodata)
POW_INVC := [128]f64{
	0h3FF6A00000000000, 0h3FF6800000000000, 0h3FF6600000000000, 0h3FF6400000000000,
	0h3FF6200000000000, 0h3FF6000000000000, 0h3FF5E00000000000, 0h3FF5C00000000000,
	0h3FF5A00000000000, 0h3FF5800000000000, 0h3FF5600000000000, 0h3FF5600000000000,
	0h3FF5400000000000, 0h3FF5200000000000, 0h3FF5000000000000, 0h3FF4E00000000000,
	0h3FF4C00000000000, 0h3FF4A00000000000, 0h3FF4A00000000000, 0h3FF4800000000000,
	0h3FF4600000000000, 0h3FF4400000000000, 0h3FF4200000000000, 0h3FF4000000000000,
	0h3FF4000000000000, 0h3FF3E00000000000, 0h3FF3C00000000000, 0h3FF3A00000000000,
	0h3FF3A00000000000, 0h3FF3800000000000, 0h3FF3600000000000, 0h3FF3400000000000,
	0h3FF3400000000000, 0h3FF3200000000000, 0h3FF3000000000000, 0h3FF3000000000000,
	0h3FF2E00000000000, 0h3FF2C00000000000, 0h3FF2C00000000000, 0h3FF2A00000000000,
	0h3FF2800000000000, 0h3FF2600000000000, 0h3FF2600000000000, 0h3FF2400000000000,
	0h3FF2400000000000, 0h3FF2200000000000, 0h3FF2000000000000, 0h3FF2000000000000,
	0h3FF1E00000000000, 0h3FF1C00000000000, 0h3FF1C00000000000, 0h3FF1A00000000000,
	0h3FF1A00000000000, 0h3FF1800000000000, 0h3FF1600000000000, 0h3FF1600000000000,
	0h3FF1400000000000, 0h3FF1400000000000, 0h3FF1200000000000, 0h3FF1000000000000,
	0h3FF1000000000000, 0h3FF0E00000000000, 0h3FF0E00000000000, 0h3FF0C00000000000,
	0h3FF0C00000000000, 0h3FF0A00000000000, 0h3FF0A00000000000, 0h3FF0800000000000,
	0h3FF0800000000000, 0h3FF0600000000000, 0h3FF0400000000000, 0h3FF0400000000000,
	0h3FF0200000000000, 0h3FF0200000000000, 0h3FF0000000000000, 0h3FF0000000000000,
	0h3FEFC00000000000, 0h3FEF800000000000, 0h3FEF400000000000, 0h3FEF000000000000,
	0h3FEEC00000000000, 0h3FEE800000000000, 0h3FEE400000000000, 0h3FEE200000000000,
	0h3FEDE00000000000, 0h3FEDA00000000000, 0h3FED600000000000, 0h3FED400000000000,
	0h3FED000000000000, 0h3FECC00000000000, 0h3FECA00000000000, 0h3FEC600000000000,
	0h3FEC400000000000, 0h3FEC000000000000, 0h3FEBE00000000000, 0h3FEBA00000000000,
	0h3FEB800000000000, 0h3FEB400000000000, 0h3FEB200000000000, 0h3FEAE00000000000,
	0h3FEAC00000000000, 0h3FEAA00000000000, 0h3FEA600000000000, 0h3FEA400000000000,
	0h3FEA000000000000, 0h3FE9E00000000000, 0h3FE9C00000000000, 0h3FE9A00000000000,
	0h3FE9600000000000, 0h3FE9400000000000, 0h3FE9200000000000, 0h3FE9000000000000,
	0h3FE8C00000000000, 0h3FE8A00000000000, 0h3FE8800000000000, 0h3FE8600000000000,
	0h3FE8400000000000, 0h3FE8200000000000, 0h3FE7E00000000000, 0h3FE7C00000000000,
	0h3FE7A00000000000, 0h3FE7800000000000, 0h3FE7600000000000, 0h3FE7400000000000,
	0h3FE7200000000000, 0h3FE7000000000000, 0h3FE6E00000000000, 0h3FE6C00000000000,
}
@(rodata)
POW_LOGC := [128]f64{
	0hBFD62C82F2B9C800, 0hBFD5D1BDBF580800, 0hBFD5767717455800, 0hBFD51AAD872DF800,
	0hBFD4BE5F95777800, 0hBFD4618BC21C6000, 0hBFD404308686A800, 0hBFD3A64C55694800,
	0hBFD347DD9A988000, 0hBFD2E8E2BAE12000, 0hBFD2895A13DE8800, 0hBFD2895A13DE8800,
	0hBFD22941FBCF7800, 0hBFD1C898C1699800, 0hBFD1675CABABA800, 0hBFD1058BF9AE4800,
	0hBFD0A324E2739000, 0hBFD0402594B4D000, 0hBFD0402594B4D000, 0hBFCFB9186D5E4000,
	0hBFCEF0ADCBDC6000, 0hBFCE27076E2AF000, 0hBFCD5C216B4FC000, 0hBFCC8FF7C79AA000,
	0hBFCC8FF7C79AA000, 0hBFCBC286742D9000, 0hBFCAF3C94E80C000, 0hBFCA23BC1FE2B000,
	0hBFCA23BC1FE2B000, 0hBFC9525A9CF45000, 0hBFC87FA06520D000, 0hBFC7AB890210E000,
	0hBFC7AB890210E000, 0hBFC6D60FE719D000, 0hBFC5FF3070A79000, 0hBFC5FF3070A79000,
	0hBFC526E5E3A1B000, 0hBFC44D2B6CCB8000, 0hBFC44D2B6CCB8000, 0hBFC371FC201E9000,
	0hBFC29552F81FF000, 0hBFC1B72AD52F6000, 0hBFC1B72AD52F6000, 0hBFC0D77E7CD09000,
	0hBFC0D77E7CD09000, 0hBFBFEC9131DBE000, 0hBFBE27076E2B0000, 0hBFBE27076E2B0000,
	0hBFBC5E548F5BC000, 0hBFBA926D3A4AE000, 0hBFBA926D3A4AE000, 0hBFB8C345D631A000,
	0hBFB8C345D631A000, 0hBFB6F0D28AE56000, 0hBFB51B073F062000, 0hBFB51B073F062000,
	0hBFB341D7961BE000, 0hBFB341D7961BE000, 0hBFB16536EEA38000, 0hBFAF0A30C0118000,
	0hBFAF0A30C0118000, 0hBFAB42DD71198000, 0hBFAB42DD71198000, 0hBFA77458F632C000,
	0hBFA77458F632C000, 0hBFA39E87B9FEC000, 0hBFA39E87B9FEC000, 0hBF9F829B0E780000,
	0hBF9F829B0E780000, 0hBF97B91B07D58000, 0hBF8FC0A8B0FC0000, 0hBF8FC0A8B0FC0000,
	0hBF7FE02A6B100000, 0hBF7FE02A6B100000, 0h0000000000000000, 0h0000000000000000,
	0h3F80101575890000, 0h3F90205658938000, 0h3F98492528C90000, 0h3FA0415D89E74000,
	0h3FA466AED42E0000, 0h3FA894AA149FC000, 0h3FACCB73CDDDC000, 0h3FAEEA31C006C000,
	0h3FB1973BD1466000, 0h3FB3BDF5A7D1E000, 0h3FB5E95A4D97A000, 0h3FB700D30AEAC000,
	0h3FB9335E5D594000, 0h3FBB6AC88DAD6000, 0h3FBC885801BC4000, 0h3FBEC739830A2000,
	0h3FBFE89139DBE000, 0h3FC1178E8227E000, 0h3FC1AA2B7E23F000, 0h3FC2D1610C868000,
	0h3FC365FCB0159000, 0h3FC4913D8333B000, 0h3FC527E5E4A1B000, 0h3FC6574EBE8C1000,
	0h3FC6F0128B757000, 0h3FC7898D85445000, 0h3FC8BEAFEB390000, 0h3FC95A5ADCF70000,
	0h3FCA93ED3C8AE000, 0h3FCB31D8575BD000, 0h3FCBD087383BE000, 0h3FCC6FFBC6F01000,
	0h3FCDB13DB0D49000, 0h3FCE530EFFE71000, 0h3FCEF5ADE4DD0000, 0h3FCF991C6CB3B000,
	0h3FD07138604D5800, 0h3FD0C42D67616000, 0h3FD1178E8227E800, 0h3FD16B5CCBACF800,
	0h3FD1BF99635A6800, 0h3FD214456D0EB800, 0h3FD2BEF07CDC9000, 0h3FD314F1E1D36000,
	0h3FD36B6776BE1000, 0h3FD3C25277333000, 0h3FD419B423D5E800, 0h3FD4718DC271C800,
	0h3FD4C9E09E173000, 0h3FD522AE0738A000, 0h3FD57BF753C8D000, 0h3FD5D5BDDF596000,
}
@(rodata)
POW_LOGCTAIL := [128]f64{
	0h3CFAB42428375680, 0hBD1CA508D8E0F720, 0hBD2362A4D5B6506D, 0hBCE684E49EB067D5,
	0hBD041B6993293EE0, 0h3D13D82F484C84CC, 0h3CDC42F3ED820B3A, 0h3D20B1C686519460,
	0h3D25594DD4C58092, 0h3D267B1E99B72BD8, 0h3D15CA14B6CFB03F, 0h3D15CA14B6CFB03F,
	0hBD165A242853DA76, 0hBD1FAFBC68E75404, 0h3D1F1FC63382A8F0, 0hBD26A8C4FD055A66,
	0hBD0C6BEE7EF4030E, 0hBCF036B89EF42D7F, 0hBCF036B89EF42D7F, 0h3D0D572AAB993C87,
	0h3D2B26B79C86AF24, 0hBD172F4F543FFF10, 0h3D21BA91BBCA681B, 0h3D27794F689F8434,
	0h3D27794F689F8434, 0h3D194EB0318BB78F, 0h3CBA4E633FCD9066, 0hBD258C64DC46C1EA,
	0hBD258C64DC46C1EA, 0hBD2AD1D904C1D4E3, 0h3D2BBDBF7FDBFA09, 0h3D2BDB9072534A58,
	0h3D2BDB9072534A58, 0hBD10E46AA3B2E266, 0hBD1E9E439F105039, 0hBD1E9E439F105039,
	0hBD20DE8B90075B8F, 0h3D170CC16135783C, 0h3D170CC16135783C, 0h3CF178864D27543A,
	0hBD248D301771C408, 0hBD2E80A41811A396, 0hBD2E80A41811A396, 0h3D0A699688E85BF4,
	0h3D0A699688E85BF4, 0hBD2575545CA333F2, 0h3D2A342C2AF0003C, 0h3D2A342C2AF0003C,
	0hBD1D0C57585FBE06, 0h3D253935E85BAAC8, 0h3D253935E85BAAC8, 0h3D137C294D2F5668,
	0h3D137C294D2F5668, 0hBD269737C93373DA, 0h3D1F025B61C65E57, 0h3D1F025B61C65E57,
	0h3D2C5EDACCF913DF, 0h3D2C5EDACCF913DF, 0h3D147C5E768FA309, 0h3D2D599E83368E91,
	0h3D2D599E83368E91, 0h3D1C827AE5D6704C, 0h3D1C827AE5D6704C, 0hBD2CFC4634F2A1EE,
	0hBD2CFC4634F2A1EE, 0h3CF502B7F526FEAA, 0h3CF502B7F526FEAA, 0hBD2980267C7E09E4,
	0hBD2980267C7E09E4, 0hBD288D5493FAA639, 0hBCDF1E7CF6D3A69C, 0hBCDF1E7CF6D3A69C,
	0hBD19E23F0DDA40E4, 0hBD19E23F0DDA40E4, 0h0000000000000000, 0h0000000000000000,
	0hBD10C76B999D2BE8, 0hBD23DC5B06E2F7D2, 0hBD2AA0BA325A0C34, 0h3D0111C05CF1D753,
	0hBD2C167375BDFD28, 0hBD197995D05A267D, 0hBD1A68F247D82807, 0hBD0E113E4FC93B7B,
	0hBD25325D560D9E9B, 0h3D2CC85EA5DB4ED7, 0hBD2C69063C5D1D1E, 0h3CEC1E8DA99DED32,
	0h3D23115C3ABD47DA, 0hBD1390802BF768E5, 0h3D2646D1C65AACD3, 0hBD2DC068AFE645E0,
	0hBD2534D64FA10AFD, 0h3D21EF78CE2D07F2, 0h3D2CA78E44389934, 0h3D039D6CCB81B4A1,
	0h3CC62FA8234B7289, 0h3D25837954FDB678, 0h3D2633E8E5697DC7, 0h3D19CF8B2C3C2E78,
	0hBD25118DE59C21E1, 0hBD1C661070914305, 0hBD073D54AAE92CD1, 0h3D07F22858A0FF6F,
	0hBD28724350562169, 0hBD0C358D4EACE1AA, 0hBD2D4BC4595412B6, 0hBCF1EC72C5962BD2,
	0hBD2AFF2AF715B035, 0h3CC212276041F430, 0hBCCA211565BB8E11, 0h3D1BCBECCA0CDF30,
	0h3CF89CDB16ED4E91, 0h3D27188B163CEAE9, 0hBD2C210E63A5F01C, 0h3D2B9ACDF7A51681,
	0h3D2CA6ED5147BDB7, 0h3D0A87DEBA46BAEA, 0h3D2A9CFA4A5004F4, 0hBD28E27AD3213CB8,
	0h3D116ECDB0F177C8, 0h3D183B54B606BD5C, 0h3D08E436EC90E09D, 0hBD2F27CE0967D675,
	0hBD2E20891B0AD8A4, 0h3D2EBE708164C759, 0h3D1FADEDEE5D40EF, 0hBD0A0B2A08A465DC,
}
EXP_INVLN2N :: 0h40671547652B82FE // 0x1.71547652b82fep+7
EXP_NEGLN2HIN :: 0hBF762E42FEFA0000 // -0x1.62e42fefap-8
EXP_NEGLN2LON :: 0hBD0CF79ABC9E3B3A // -0x1.cf79abc9e3b3ap-47
EXP_SHIFT :: 0h4338000000000000 // 0x1.8p+52
EXP2_SHIFT :: 0h42C8000000000000 // 0x1.8p+45
@(rodata)
EXP2_POLY := [5]f64{
	0h3FE62E42FEFA39EF, 0h3FCEBFBDFF82C424, 0h3FAC6B08D70CF4B5, 0h3F83B2ABD24650CC,
	0h3F55D7E09B4E3A84,
}
@(rodata)
EXP_POLY := [4]f64{
	0h3FDFFFFFFFFFFDBD, 0h3FC555555555543C, 0h3FA55555CF172B91, 0h3F81111167A4D017,
}
@(rodata)
EXP_TAB := [256]u64{
	0x0000000000000000, 0x3FF0000000000000, 0x3C9B3B4F1A88BF6E, 0x3FEFF63DA9FB3335,
	0xBC7160139CD8DC5D, 0x3FEFEC9A3E778061, 0xBC905E7A108766D1, 0x3FEFE315E86E7F85,
	0x3C8CD2523567F613, 0x3FEFD9B0D3158574, 0xBC8BCE8023F98EFA, 0x3FEFD06B29DDF6DE,
	0x3C60F74E61E6C861, 0x3FEFC74518759BC8, 0x3C90A3E45B33D399, 0x3FEFBE3ECAC6F383,
	0x3C979AA65D837B6D, 0x3FEFB5586CF9890F, 0x3C8EB51A92FDEFFC, 0x3FEFAC922B7247F7,
	0x3C3EBE3D702F9CD1, 0x3FEFA3EC32D3D1A2, 0xBC6A033489906E0B, 0x3FEF9B66AFFED31B,
	0xBC9556522A2FBD0E, 0x3FEF9301D0125B51, 0xBC5080EF8C4EEA55, 0x3FEF8ABDC06C31CC,
	0xBC91C923B9D5F416, 0x3FEF829AAEA92DE0, 0x3C80D3E3E95C55AF, 0x3FEF7A98C8A58E51,
	0xBC801B15EAA59348, 0x3FEF72B83C7D517B, 0xBC8F1FF055DE323D, 0x3FEF6AF9388C8DEA,
	0x3C8B898C3F1353BF, 0x3FEF635BEB6FCB75, 0xBC96D99C7611EB26, 0x3FEF5BE084045CD4,
	0x3C9AECF73E3A2F60, 0x3FEF54873168B9AA, 0xBC8FE782CB86389D, 0x3FEF4D5022FCD91D,
	0x3C8A6F4144A6C38D, 0x3FEF463B88628CD6, 0x3C807A05B0E4047D, 0x3FEF3F49917DDC96,
	0x3C968EFDE3A8A894, 0x3FEF387A6E756238, 0x3C875E18F274487D, 0x3FEF31CE4FB2A63F,
	0x3C80472B981FE7F2, 0x3FEF2B4565E27CDD, 0xBC96B87B3F71085E, 0x3FEF24DFE1F56381,
	0x3C82F7E16D09AB31, 0x3FEF1E9DF51FDEE1, 0xBC3D219B1A6FBFFA, 0x3FEF187FD0DAD990,
	0x3C8B3782720C0AB4, 0x3FEF1285A6E4030B, 0x3C6E149289CECB8F, 0x3FEF0CAFA93E2F56,
	0x3C834D754DB0ABB6, 0x3FEF06FE0A31B715, 0x3C864201E2AC744C, 0x3FEF0170FC4CD831,
	0x3C8FDD395DD3F84A, 0x3FEEFC08B26416FF, 0xBC86A3803B8E5B04, 0x3FEEF6C55F929FF1,
	0xBC924AEDCC4B5068, 0x3FEEF1A7373AA9CB, 0xBC9907F81B512D8E, 0x3FEEECAE6D05D866,
	0xBC71D1E83E9436D2, 0x3FEEE7DB34E59FF7, 0xBC991919B3CE1B15, 0x3FEEE32DC313A8E5,
	0x3C859F48A72A4C6D, 0x3FEEDEA64C123422, 0xBC9312607A28698A, 0x3FEEDA4504AC801C,
	0xBC58A78F4817895B, 0x3FEED60A21F72E2A, 0xBC7C2C9B67499A1B, 0x3FEED1F5D950A897,
	0x3C4363ED60C2AC11, 0x3FEECE086061892D, 0x3C9666093B0664EF, 0x3FEECA41ED1D0057,
	0x3C6ECCE1DAA10379, 0x3FEEC6A2B5C13CD0, 0x3C93FF8E3F0F1230, 0x3FEEC32AF0D7D3DE,
	0x3C7690CEBB7AAFB0, 0x3FEEBFDAD5362A27, 0x3C931DBDEB54E077, 0x3FEEBCB299FDDD0D,
	0xBC8F94340071A38E, 0x3FEEB9B2769D2CA7, 0xBC87DECCDC93A349, 0x3FEEB6DAA2CF6642,
	0xBC78DEC6BD0F385F, 0x3FEEB42B569D4F82, 0xBC861246EC7B5CF6, 0x3FEEB1A4CA5D920F,
	0x3C93350518FDD78E, 0x3FEEAF4736B527DA, 0x3C7B98B72F8A9B05, 0x3FEEAD12D497C7FD,
	0x3C9063E1E21C5409, 0x3FEEAB07DD485429, 0x3C34C7855019C6EA, 0x3FEEA9268A5946B7,
	0x3C9432E62B64C035, 0x3FEEA76F15AD2148, 0xBC8CE44A6199769F, 0x3FEEA5E1B976DC09,
	0xBC8C33C53BEF4DA8, 0x3FEEA47EB03A5585, 0xBC845378892BE9AE, 0x3FEEA34634CCC320,
	0xBC93CEDD78565858, 0x3FEEA23882552225, 0x3C5710AA807E1964, 0x3FEEA155D44CA973,
	0xBC93B3EFBF5E2228, 0x3FEEA09E667F3BCD, 0xBC6A12AD8734B982, 0x3FEEA012750BDABF,
	0xBC6367EFB86DA9EE, 0x3FEE9FB23C651A2F, 0xBC80DC3D54E08851, 0x3FEE9F7DF9519484,
	0xBC781F647E5A3ECF, 0x3FEE9F75E8EC5F74, 0xBC86EE4AC08B7DB0, 0x3FEE9F9A48A58174,
	0xBC8619321E55E68A, 0x3FEE9FEB564267C9, 0x3C909CCB5E09D4D3, 0x3FEEA0694FDE5D3F,
	0xBC7B32DCB94DA51D, 0x3FEEA11473EB0187, 0x3C94ECFD5467C06B, 0x3FEEA1ED0130C132,
	0x3C65EBE1ABD66C55, 0x3FEEA2F336CF4E62, 0xBC88A1C52FB3CF42, 0x3FEEA427543E1A12,
	0xBC9369B6F13B3734, 0x3FEEA589994CCE13, 0xBC805E843A19FF1E, 0x3FEEA71A4623C7AD,
	0xBC94D450D872576E, 0x3FEEA8D99B4492ED, 0x3C90AD675B0E8A00, 0x3FEEAAC7D98A6699,
	0x3C8DB72FC1F0EAB4, 0x3FEEACE5422AA0DB, 0xBC65B6609CC5E7FF, 0x3FEEAF3216B5448C,
	0x3C7BF68359F35F44, 0x3FEEB1AE99157736, 0xBC93091FA71E3D83, 0x3FEEB45B0B91FFC6,
	0xBC5DA9B88B6C1E29, 0x3FEEB737B0CDC5E5, 0xBC6C23F97C90B959, 0x3FEEBA44CBC8520F,
	0xBC92434322F4F9AA, 0x3FEEBD829FDE4E50, 0xBC85CA6CD7668E4B, 0x3FEEC0F170CA07BA,
	0x3C71AFFC2B91CE27, 0x3FEEC49182A3F090, 0x3C6DD235E10A73BB, 0x3FEEC86319E32323,
	0xBC87C50422622263, 0x3FEECC667B5DE565, 0x3C8B1C86E3E231D5, 0x3FEED09BEC4A2D33,
	0xBC91BBD1D3BCBB15, 0x3FEED503B23E255D, 0x3C90CC319CEE31D2, 0x3FEED99E1330B358,
	0x3C8469846E735AB3, 0x3FEEDE6B5579FDBF, 0xBC82DFCD978E9DB4, 0x3FEEE36BBFD3F37A,
	0x3C8C1A7792CB3387, 0x3FEEE89F995AD3AD, 0xBC907B8F4AD1D9FA, 0x3FEEEE07298DB666,
	0xBC55C3D956DCAEBA, 0x3FEEF3A2B84F15FB, 0xBC90A40E3DA6F640, 0x3FEEF9728DE5593A,
	0xBC68D6F438AD9334, 0x3FEEFF76F2FB5E47, 0xBC91EEE26B588A35, 0x3FEF05B030A1064A,
	0x3C74FFD70A5FDDCD, 0x3FEF0C1E904BC1D2, 0xBC91BDFBFA9298AC, 0x3FEF12C25BD71E09,
	0x3C736EAE30AF0CB3, 0x3FEF199BDD85529C, 0x3C8EE3325C9FFD94, 0x3FEF20AB5FFFD07A,
	0x3C84E08FD10959AC, 0x3FEF27F12E57D14B, 0x3C63CDAF384E1A67, 0x3FEF2F6D9406E7B5,
	0x3C676B2C6C921968, 0x3FEF3720DCEF9069, 0xBC808A1883CCB5D2, 0x3FEF3F0B555DC3FA,
	0xBC8FAD5D3FFFFA6F, 0x3FEF472D4A07897C, 0xBC900DAE3875A949, 0x3FEF4F87080D89F2,
	0x3C74A385A63D07A7, 0x3FEF5818DCFBA487, 0xBC82919E2040220F, 0x3FEF60E316C98398,
	0x3C8E5A50D5C192AC, 0x3FEF69E603DB3285, 0x3C843A59AC016B4B, 0x3FEF7321F301B460,
	0xBC82D52107B43E1F, 0x3FEF7C97337B9B5F, 0xBC892AB93B470DC9, 0x3FEF864614F5A129,
	0x3C74B604603A88D3, 0x3FEF902EE78B3FF6, 0x3C83C5EC519D7271, 0x3FEF9A51FBC74C83,
	0xBC8FF7128FD391F0, 0x3FEFA4AFA2A490DA, 0xBC8DAE98E223747D, 0x3FEFAF482D8E67F1,
	0x3C8EC3BC41AA2008, 0x3FEFBA1BEE615A27, 0x3C842B94C3A9EB32, 0x3FEFC52B376BBA97,
	0x3C8A64A931D185EE, 0x3FEFD0765B6E4540, 0xBC8E37BAE43BE3ED, 0x3FEFDBFDAD9CBE14,
	0x3C77893B4D91CD9D, 0x3FEFE7C1819E90D8, 0x3C5305C14160CC89, 0x3FEFF3C22B8F71F1,
}
K_SIN_S1 :: 0hBFC5555555555549 // -0x1.5555555555549p-3
K_SIN_S2 :: 0h3F8111111110F8A6 // 0x1.111111110f8a6p-7
K_SIN_S3 :: 0hBF2A01A019C161D5 // -0x1.a01a019c161d5p-13
K_SIN_S4 :: 0h3EC71DE357B1FE7D // 0x1.71de357b1fe7dp-19
K_SIN_S5 :: 0hBE5AE5E68A2B9CEB // -0x1.ae5e68a2b9cebp-26
K_SIN_S6 :: 0h3DE5D93A5ACFD57C // 0x1.5d93a5acfd57cp-33
K_COS_C1 :: 0h3FA555555555554C // 0x1.555555555554cp-5
K_COS_C2 :: 0hBF56C16C16C15177 // -0x1.6c16c16c15177p-10
K_COS_C3 :: 0h3EFA01A019CB1590 // 0x1.a01a019cb159p-16
K_COS_C4 :: 0hBE927E4F809C52AD // -0x1.27e4f809c52adp-22
K_COS_C5 :: 0h3E21EE9EBDB4B1C4 // 0x1.1ee9ebdb4b1c4p-29
K_COS_C6 :: 0hBDA8FAE9BE8838D4 // -0x1.8fae9be8838d4p-37
@(rodata)
PIO2_PARTS := [8]f64{
	0h3FF921FB40000000, 0h3E74442D00000000, 0h3CF8469880000000, 0h3B78CC5160000000,
	0h39F01B8380000000, 0h387A252040000000, 0h36E3822280000000, 0h3569F31D00000000,
}
@(rodata)
IPIO2 := [66]i32{
	0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62,
	0x95993C, 0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A,
	0x424DD2, 0xE00649, 0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129,
	0xA73EE8, 0x8235F5, 0x2EBB44, 0x84E99C, 0x7026B4, 0x5F7E41,
	0x3991D6, 0x398353, 0x39F49C, 0x845F8B, 0xBDF928, 0x3B1FF8,
	0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D, 0x367ECF,
	0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
	0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08,
	0x560330, 0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3,
	0x91615E, 0xE61B08, 0x659985, 0x5F14A0, 0x68408D, 0xFFD880,
	0x4D7327, 0x310606, 0x1556CA, 0x73A8C9, 0x60E27B, 0xC08C6B,
}
REM_INVPIO2 :: 0h3FE45F306DC9C883 // 0x1.45f306dc9c883p-1
REM_PIO2_1 :: 0h3FF921FB54400000 // 0x1.921fb544p+0
REM_PIO2_1T :: 0h3DD0B4611A626331 // 0x1.0b4611a626331p-34
REM_PIO2_2 :: 0h3DD0B4611A600000 // 0x1.0b4611a6p-34
REM_PIO2_2T :: 0h3BA3198A2E037073 // 0x1.3198a2e037073p-69
REM_PIO2_3 :: 0h3BA3198A2E000000 // 0x1.3198a2ep-69
REM_PIO2_3T :: 0h397B839A252049C1 // 0x1.b839a252049c1p-104
