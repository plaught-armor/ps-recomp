// The VU add and multiply (ps2/vu ps2_add, ps2_mul) against the x64 SSE
// addps and mulps under MXCSR round toward zero and flush to zero (no DAZ:
// ACC reaches MADD and MSUB unclamped, and may be denormal), on the same
// operands in the same order as recomp/vu's round_zero spans: the add's
// smaller operand cut first (as the emitter cuts it), the product added to
// ACC for MADD and MSUB, the product of a vector with a lane of magnitude
// FMAX taken from ps2_mul instead (the emitter's guard: there mulps cannot
// tell a product in [FMAX, 2^128) from one past it, which ps2_mul makes
// infinite and the add keeps so). The SSE ops run in code built here, which
// sets MXCSR itself and puts it back, so the compiler cannot move host
// float math across the mode change.
//
// Each case counts the lanes whose bits differ before the result clamp,
// after it, and in the MAC Z and S flags of the clamped value. The case
// classes: random pairs; exponent differences 0..30 with all-ones and
// all-zero mantissa bits below the cut; x + -x; results near the largest
// and smallest normal; denormal operands; results below 2^-126; MADD and
// MSUB with products past the range. A case of the add and multiply family
// that differs after the clamp fails the test.
//
// The ops a span also runs on the host's float unit (DIV, SQRT, RSQRT and
// the EFU through divss and sqrtss, the EFU's f32 adds and products, ITOF
// through cvtdq2ps) are counted the same way against their round to
// nearest reference; their counts are reported, not failed: a span must
// run them in round to nearest.
//
// PS_RZ_MUTANT=1 runs the add and multiply family with MXCSR left round to
// nearest, and PS_RZ_MUTANT=guard runs MADD and MSUB without the guard;
// the test must then fail.
//
// x64 only.
package test_vu_rz

import "core:fmt"
import "core:math"
import "core:os"
import "ps:core"
import "ps:ps2/cpu"
import "ps:ps2/vu"

#assert(ODIN_ARCH == .amd64)

// MXCSR: exceptions masked; RC = 11 (toward zero), FTZ (bit 15). These are
// recomp/native's MXCSR_RN and MXCSR_RZ.
RN_CSR :: u32(0x1f80)
RZ_CSR :: RN_CSR | 0x6000 | 0x8000

Op :: enum {Add, Mul, Div, Sqrt, Itof}
OPCODE := [Op]u8{.Add = 0x58, .Mul = 0x59, .Div = 0x5e, .Sqrt = 0x51, .Itof = 0x5b}

// out[i..i+4] = op(a[i..], b[i..]) for i in steps of 4 below n (n > 0, a
// multiple of 4), under MXCSR csr; the caller's MXCSR is put back. Sqrt
// and Itof read b only.
Run :: #type proc "c" (a, b, out: [^]u32, n: int, csr: u32)
runs: [Op]Run

build :: proc(op: u8) -> Run {
	code := [?]u8 {
		0x48, 0x83, 0xec, 0x08, // sub rsp, 8
		0x0f, 0xae, 0x1c, 0x24, // stmxcsr [rsp]
		0x44, 0x89, 0x44, 0x24, 0x04, // mov [rsp+4], r8d
		0x0f, 0xae, 0x54, 0x24, 0x04, // ldmxcsr [rsp+4]
		0x0f, 0x10, 0x07, // loop: movups xmm0, [rdi]
		0x0f, 0x10, 0x0e, // movups xmm1, [rsi] (OPps of memory needs 16-byte alignment)
		0x0f, op, 0xc1, // OPps xmm0, xmm1
		0x0f, 0x11, 0x02, // movups [rdx], xmm0
		0x48, 0x83, 0xc7, 0x10, // add rdi, 16
		0x48, 0x83, 0xc6, 0x10, // add rsi, 16
		0x48, 0x83, 0xc2, 0x10, // add rdx, 16
		0x48, 0x83, 0xe9, 0x04, // sub rcx, 4
		0x75, 0xe2, // jnz loop
		0x0f, 0xae, 0x14, 0x24, // ldmxcsr [rsp]
		0x48, 0x83, 0xc4, 0x08, // add rsp, 8
		0xc3, // ret
	}
	return cast(Run)core.map_code(code[:])
}

N :: 4096
A, B, C: [N]u32 // the case's raw operands (C: ACC)
X, Y, H, R: [N]u32 // the SSE operands, its result, the reference

seed: u64 = 0x5eed_0b17_20

r64 :: proc() -> u64 {
	seed += 0x9e3779b97f4a7c15
	z := seed
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}
r32 :: proc() -> u32 {return u32(r64() >> 32)}
mk :: proc(sign, e, m: u32) -> u32 {return (sign & 1) << 31 | (e & 0xff) << 23 | (m & 0x7fffff)}
rexp :: proc(lo, hi: u32) -> u32 {return lo + r32() % (hi - lo + 1)}

f :: #force_inline proc(u: u32) -> f32 {return transmute(f32)u}
u :: #force_inline proc(x: f32) -> u32 {return transmute(u32)x}
fc :: #force_inline proc(x: u32) -> u32 {return u(cpu.fclamp(f(x)))}

// The emitter's cut: big holds the larger magnitude (b only where strictly
// larger), small loses the bits below big's last mantissa bit.
cut :: proc(a, b: u32) -> (big, small: u32) {
	big, small = a, b
	if b & 0x7fffffff > a & 0x7fffffff {big, small = b, a}
	d := (big >> 23 & 0xff) - (small >> 23 & 0xff)
	if d >= 24 {small &= 0x80000000} else {small &~= (u32(1) << d) - 1}
	return
}

Kind :: enum {Add, Sub, Mul, Madd, Msub, Div, Sqrt, Itof, Efu_Add, Efu_Mul, Rn_Add}

Stat :: struct {
	name:                  string,
	kind:                  Kind,
	n, raw, clamped, flag: int,
	pos0, neg0:            int, // reference results +0 and -0
	finite:                int, // clamped mismatches whose reference is not infinite
	guarded:               int, // MADD and MSUB vectors the guard sent to ps2_mul
	shown:                 int,
}

stats: [dynamic]Stat
mutant, no_guard: bool

// Run the batch in A, B, C as kind and tally it into s.
batch :: proc(s: ^Stat) {
	csr := mutant ? RN_CSR : RZ_CSR
	switch s.kind {
	case .Add, .Sub:
		for i in 0 ..< N {
			ca, cb := fc(A[i]), fc(B[i])
			if s.kind == .Sub {cb ~= 0x80000000}
			X[i], Y[i] = cut(ca, cb)
			R[i] = u(vu.ps2_add(f(ca), f(cb)))
		}
		runs[.Add](&X[0], &Y[0], &H[0], N, csr)
	case .Mul:
		for i in 0 ..< N {
			X[i], Y[i] = fc(A[i]), fc(B[i])
			R[i] = u(vu.ps2_mul(f(X[i]), f(Y[i])))
		}
		runs[.Mul](&X[0], &Y[0], &H[0], N, csr)
	case .Madd, .Msub:
		// vu_op: vadd(acc, +-vmul(fs, ft)), ACC as it is; the emitter: the
		// product in V0, its sign flipped for MSUB, ACC in V1.
		neg := s.kind == .Msub ? u32(0x80000000) : 0
		for i in 0 ..< N {
			X[i], Y[i] = fc(A[i]), fc(B[i])
			p := u(vu.ps2_mul(f(X[i]), f(Y[i]))) ~ neg
			R[i] = u(vu.ps2_add(f(C[i]), f(p)))
		}
		runs[.Mul](&X[0], &Y[0], &H[0], N, csr)
		// the guard: a vector with a lane of magnitude FMAX takes ps2_mul's
		for g := 0; g < N && !no_guard; g += 4 {
			hit := false
			for i in g ..< g + 4 {hit ||= H[i] & 0x7fffffff == 0x7f7fffff}
			if !hit {continue}
			s.guarded += 1
			for i in g ..< g + 4 {H[i] = u(vu.ps2_mul(f(X[i]), f(Y[i])))}
		}
		for i in 0 ..< N {X[i], Y[i] = cut(H[i] ~ neg, C[i])}
		runs[.Add](&X[0], &Y[0], &H[0], N, csr)
	case .Div:
		// cpu.fdiv past its exponent-0 divisor case: fclamp(x / y)
		for i in 0 ..< N {
			X[i], Y[i] = fc(A[i]), fc(B[i])
			if Y[i] & 0x7f800000 == 0 {Y[i] |= 0x3f800000}
			R[i] = u(f(X[i]) / f(Y[i]))
		}
		runs[.Div](&X[0], &Y[0], &H[0], N, RZ_CSR)
	case .Sqrt:
		for i in 0 ..< N {
			Y[i] = fc(B[i]) & 0x7fffffff
			R[i] = u(math.sqrt(f(Y[i])))
		}
		runs[.Sqrt](&X[0], &Y[0], &H[0], N, RZ_CSR)
	case .Itof:
		for i in 0 ..< N {
			Y[i] = B[i]
			R[i] = u(f32(i32(B[i])))
		}
		runs[.Itof](&X[0], &Y[0], &H[0], N, RZ_CSR)
	case .Efu_Add, .Rn_Add:
		for i in 0 ..< N {
			X[i], Y[i] = fc(A[i]), fc(B[i])
			R[i] = u(f(X[i]) + f(Y[i]))
		}
		runs[.Add](&X[0], &Y[0], &H[0], N, s.kind == .Rn_Add ? RN_CSR : RZ_CSR)
	case .Efu_Mul:
		for i in 0 ..< N {
			X[i], Y[i] = fc(A[i]), fc(B[i])
			R[i] = u(f(X[i]) * f(Y[i]))
		}
		runs[.Mul](&X[0], &Y[0], &H[0], N, RZ_CSR)
	}
	for i in 0 ..< N {
		r, h := R[i], H[i]
		rc, hc := fc(r), fc(h)
		s.n += 1
		if rc << 1 == 0 {
			if rc >> 31 == 0 {s.pos0 += 1} else {s.neg0 += 1}
		}
		if r != h {s.raw += 1}
		if rc != hc {
			s.clamped += 1
			if r & 0x7fffffff != 0x7f800000 {s.finite += 1}
			if s.shown < 3 {
				s.shown += 1
				fmt.printfln("  %s: a %08x b %08x acc %08x ref %08x sse %08x", s.name, A[i], B[i], C[i], r, h)
			}
		}
		zs :: proc(x: u32) -> u32 {return u32(x << 1 == 0) | (x >> 31) << 1}
		if zs(rc) != zs(hc) {s.flag += 1}
	}
}

stat :: proc(name: string, kind: Kind) -> ^Stat {
	append(&stats, Stat{name = name, kind = kind})
	return &stats[len(stats) - 1]
}

// Fill A, B, C with gen for each of batches batches, run each as kinds.
cases :: proc(name: string, batches: int, gen: proc(i: int), kinds: ..Kind) {
	first := len(stats)
	for k in kinds {stat(fmt.aprintf("%s/%v", name, k), k)}
	for _ in 0 ..< batches {
		for i in 0 ..< N {gen(i)}
		for j in first ..< len(stats) {batch(&stats[j])}
	}
}

sweep_d: u32

// An exponent for macc_acc's ACC: 0 (denormal or zero), 1, 2 or 255.
acc_e :: proc() -> u32 {
	es := [4]u32{0, 1, 2, 255}
	return es[r32() % 4]
}

main :: proc() {
	for op in Op {runs[op] = build(OPCODE[op])}
	mutant = os.get_env("PS_RZ_MUTANT", context.temp_allocator) == "1"
	no_guard = os.get_env("PS_RZ_MUTANT", context.temp_allocator) == "guard"

	// The code built here, in round to nearest, is the host's f32 add.
	cases("sanity", 16, proc(i: int) {A[i], B[i], C[i] = r32(), r32(), 0}, .Rn_Add)

	// 10^8 random pairs (24415 batches of 4096 = 100003840): random sign,
	// exponent and mantissa.
	cases("random", 24415, proc(i: int) {A[i], B[i], C[i] = r32(), r32(), r32()}, .Add, .Sub, .Mul)

	// Exponent differences 0..30: big of any normal exponent and a mantissa
	// of all zeros, all ones or random; small d exponents down with its
	// bits below the cut all ones or all zeros; every sign; either order.
	for d in u32(0) ..= 30 {
		sweep_d = d
		cases(fmt.aprintf("d%02d", d), 64, proc(i: int) {
			d := sweep_d
			eb := rexp(1 + d, 254)
			bms := [3]u32{0, 0x7fffff, r32()}
			bm := bms[r32() % 3]
			low := d >= 23 ? u32(0x7fffff) : (u32(1) << d) - 1
			sm := r32() &~ low
			if r32() & 1 != 0 {sm |= low}
			big, small := mk(r32(), eb, bm), mk(r32(), eb - d, sm)
			if r32() & 1 != 0 {big, small = small, big}
			A[i], B[i], C[i] = big, small, 0
		}, .Add, .Sub)
	}

	// x + -x (and x - x): the zero's sign.
	cases("zero", 64, proc(i: int) {
		x := mk(r32(), rexp(0, 255), r32())
		A[i], B[i], C[i] = x, x ~ 0x80000000, 0
	}, .Add)
	cases("zero_sub", 64, proc(i: int) {
		x := mk(r32(), rexp(0, 255), r32())
		A[i], B[i], C[i] = x, x, 0
	}, .Sub)

	// Near the largest normal: sums of exponents 252..255, products whose
	// exponents sum to 381 (2^127) +- 3.
	cases("max", 256, proc(i: int) {
		A[i], B[i], C[i] = mk(r32(), rexp(252, 255), r32()), mk(r32(), rexp(252, 255), r32()), 0
	}, .Add, .Sub)
	cases("max_mul", 256, proc(i: int) {
		ea := rexp(127, 255)
		eb := clamp(381 - ea + rexp(0, 6) - 3, 1, 255)
		A[i], B[i], C[i] = mk(r32(), ea, r32()), mk(r32(), eb, r32()), 0
	}, .Mul)

	// Near the smallest normal and below 2^-126: sums and differences of
	// exponents 1..4, nearly equal magnitudes of opposite sign, products
	// whose exponents sum to 128 (2^-126) +- 3.
	cases("min", 256, proc(i: int) {
		A[i], B[i], C[i] = mk(r32(), rexp(1, 4), r32()), mk(r32(), rexp(1, 4), r32()), 0
	}, .Add, .Sub)
	cases("min_near", 256, proc(i: int) {
		x := mk(r32(), rexp(1, 3), r32())
		A[i], B[i], C[i] = x, (x ~ 0x80000000) + (r32() % 64) - 32, 0
	}, .Add)
	cases("min_mul", 256, proc(i: int) {
		ea := rexp(1, 254)
		eb := clamp(i64(128) - i64(ea) + i64(rexp(0, 6)) - 3, 1, 254)
		A[i], B[i], C[i] = mk(r32(), ea, r32()), mk(r32(), u32(eb), r32()), 0
	}, .Mul)

	// Denormal (exponent 0) operands, which the operand clamp makes a zero
	// of their sign; and exponent 255.
	cases("den", 64, proc(i: int) {
		A[i], B[i], C[i] = mk(r32(), 0, r32()), mk(r32(), rexp(0, 255), r32()), 0
	}, .Add, .Sub, .Mul)
	cases("e255", 64, proc(i: int) {
		A[i], B[i], C[i] = mk(r32(), 255, r32()), mk(r32(), rexp(0, 255), r32()), 0
	}, .Add, .Sub, .Mul)

	// MADD and MSUB: random; then products past the range against an ACC of
	// exponent 254 or 255.
	cases("macc", 2048, proc(i: int) {A[i], B[i], C[i] = r32(), r32(), r32()}, .Madd, .Msub)
	cases("macc_over", 256, proc(i: int) {
		ea := rexp(190, 255)
		eb := clamp(381 - ea + rexp(0, 8), 1, 255)
		A[i], B[i], C[i] = mk(r32(), ea, r32()), mk(r32(), eb, r32()), mk(r32(), rexp(253, 255), r32())
	}, .Madd, .Msub)
	// Products of exactly FMAX and in [FMAX, 2^128): FMAX times 1, and
	// products whose exponents sum to 2^127 with mantissas near all ones.
	cases("macc_fmax", 256, proc(i: int) {
		switch r32() % 3 {
		case 0: A[i], B[i] = mk(r32(), 254, 0x7fffff), mk(r32(), 127, 0)
		case:
			ea := rexp(128, 254)
			A[i], B[i] = mk(r32(), ea, 0x7fffff - r32() % 16), mk(r32(), 381 - ea, 0x7fffff - r32() % 16)
		}
		C[i] = mk(r32(), rexp(250, 255), r32())
	}, .Madd, .Msub)
	// ACC as it is: denormal, zero or exponent 255 against small products
	// and products that are zero.
	cases("macc_acc", 256, proc(i: int) {
		A[i], B[i] = mk(r32(), rexp(0, 70), r32()), mk(r32(), rexp(0, 70), r32())
		C[i] = mk(r32(), acc_e(), r32() % 4 == 0 ? 0 : r32())
	}, .Madd, .Msub)

	// The span's other host float ops under the same MXCSR, against round to
	// nearest.
	cases("rn_ops", 256, proc(i: int) {A[i], B[i], C[i] = r32(), r32(), 0}, .Div, .Sqrt, .Itof, .Efu_Add, .Efu_Mul)

	fmt.printfln("%-22s %10s %9s %9s %9s %9s %9s %9s %9s", "case", "lanes", "raw", "clamped", "flags", "ref+0", "ref-0", "finite", "guarded")
	fail := false
	for s in stats {
		fmt.printfln("%-22s %10v %9v %9v %9v %9v %9v %9v %9v", s.name, s.n, s.raw, s.clamped, s.flag, s.pos0, s.neg0, s.finite, s.guarded)
		switch s.kind {
		case .Add, .Sub, .Mul, .Madd, .Msub, .Rn_Add:
			if s.clamped != 0 || s.flag != 0 {fail = true}
		case .Div, .Sqrt, .Itof, .Efu_Add, .Efu_Mul:
		}
	}
	fmt.println(fail ? "vu_rz: FAIL" : "vu_rz: ok")
	if fail {os.exit(1)}
}
