// Checks core/libm_wasi.odin, the C maths functions of the wasi_wasm32
// build, against the host C library. Built once for the host and once for
// wasi_wasm32, it prints the same lines from both; tests/libm_wasi/run.mjs
// runs both and compares. A development tool, not run in CI: the full check
// is 3 * 2^32 calls.
//
//   hash <s|c|e> <lo> <hi>   sinf, cosf or expf on every f32 input in
//                            chunks lo..hi-1 of 2^24 inputs: one line per
//                            chunk, "<f> <chunk> <hash of the results>"
//   list <s|c|e> <chunk>     one line per input of one chunk, "<x> <f(x)>"
//   domain                   sin and pow(2, y) on the inputs the tree passes
//                            them (ps2/iop/adx.odin, ps2/iop/libsd.odin), and
//                            fmax and fmin as psx/render/gpu.odin calls them
//                            (simd.reduce_max and simd.reduce_min on f64
//                            lanes) on pairs
//                            of NaNs, signed zeros and edge values, one line
//                            each;
//                            then pow and exp2 on random inputs, a hash per
//                            block of 4096
//   randomblock <block>      the random calls of one block, "<x> <y>
//                            <result>" as hex bits
//   pow <x> <y>              one pow call, operands as hex bits
//
// The calls go through core:math as the tree's do, so LLVM emits the same
// libcalls; the wasi build links core for its definitions (link_wasi.odin).
// A NaN result is printed as 0x7fc00000: its payload is not specified.
package main

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:simd"
import "core:strconv"
import "core:strings"

CHUNK :: 1 << 24

out: strings.Builder

flush :: proc() {
	_, _ = os.write(os.stdout, out.buf[:])
	strings.builder_reset(&out)
}

emit :: proc(format: string, args: ..any) {
	fmt.sbprintf(&out, format, ..args)
	if len(out.buf) >= 1 << 20 do flush()
}

f32_call :: proc(f: u8, x: f32) -> u32 {
	r: f32
	switch f {
	case 's':
		r = math.sin(x)
	case 'c':
		r = math.cos(x)
	case:
		r = math.exp(x)
	}
	return r != r ? 0x7fc00000 : transmute(u32)r
}

// FNV-1a over the result bytes, low byte first.
fnv :: proc(h: u64, v: u64, bytes: int) -> u64 {
	h := h
	for i in 0 ..< bytes {
		h = (h ~ (v >> uint(8 * i) & 0xff)) * 1099511628211
	}
	return h
}

FNV_START :: 1469598103934665603

f64_bits :: proc(r: f64) -> u64 {
	return r != r ? 0x7ff8000000000000 : transmute(u64)r
}

splitmix :: proc(s: ^u64) -> u64 {
	s^ += 0x9e3779b97f4a7c15
	z := s^
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// Hides a value from the optimizer, which would otherwise fold the calls
// below at compile time with the compiler's own libm.
opaque :: proc(x: i32) -> i32 {
	v := x
	return intrinsics.volatile_load(&v)
}

opaque_f64 :: proc(x: u64) -> f64 {
	v := x
	return transmute(f64)intrinsics.volatile_load(&v)
}

// fmax and fmin operands, as bits: NaNs, signed zeros, infinities, the
// subnormal and finite extremes, and values around integers (texels_read
// floors and truncates its results).
EDGE_INPUTS :: [?]u64 {
	0x7ff8000000000000, // NaN
	0xfff8000000000000, // -NaN
	0x0000000000000000, // +0
	0x8000000000000000, // -0
	0x7ff0000000000000, // +inf
	0xfff0000000000000, // -inf
	0x0000000000000001, // the least subnormal
	0x8000000000000001, // its negative
	0x7fefffffffffffff, // the largest finite
	0xffefffffffffffff, // its negative
	0x3ff0000000000000, // 1
	0xbff0000000000000, // -1
	0x3ff8000000000000, // 1.5
	0xbff8000000000000, // -1.5
	0x3fefffffffffffff, // just below 1
	0xbfefffffffffffff, // just above -1
}

domain :: proc() {
	// The expressions are the tree's, so each host build makes the calls the
	// tree makes; LLVM turns pow(2, y) into exp2(y).
	for k in i32(0) ..= 30 {
		emit("sin %d %016x\n", k, f64_bits(math.sin(f64(opaque(k)) * math.PI / 60)))
	}
	for s in i32(0) ..< 12 {
		emit("pow2 semi %d %016x\n", s, f64_bits(math.pow(2, f64(opaque(s)) / 12)))
	}
	for f in i32(0) ..< 128 {
		emit("pow2 f %d %016x\n", f, f64_bits(math.pow(2, f64(opaque(f)) / 1536)))
	}
	// psx/render/gpu.odin texels_read's simd.reduce_max and simd.reduce_min
	// on f64 lanes, which call fmax and fmin on wasm (simd.max and simd.min
	// compare and select instead), on every pair of EDGE_INPUTS but +0 with
	// -0, whose result differs by design (docs/testing.md).
	F :: #simd[4]f64
	for x, i in EDGE_INPUTS {
		for y, j in EDGE_INPUTS {
			if x != y && x | y == 0x8000000000000000 {
				continue
			}
			a, b := opaque_f64(x), opaque_f64(y)
			emit("fmax %d %d %016x\n", i, j, f64_bits(simd.reduce_max(F{a, b, b, b})))
			emit("fmin %d %d %016x\n", i, j, f64_bits(simd.reduce_min(F{a, b, b, b})))
		}
	}
	seed: u64 = 1
	for b in 0 ..< RANDOM_BLOCKS {
		h: u64 = FNV_START
		for _ in 0 ..< 4096 {
			_, _, r := random_call(&seed, b)
			h = fnv(h, r, 8)
		}
		emit("random %03x %016x\n", b, h)
	}
}

// Blocks of 4096 random calls: pow, then exp2.
RANDOM_BLOCKS :: 320
RANDOM_POW :: 256

// One random call of block b: its operands and result, as bits. pow takes x
// with an exponent in [-64, 64) and y in [-64, 64), which reaches every path
// short of overflow; exp2 takes x in [-1088, 1088), past both ends of its
// range. 1 in 4 calls take raw bits instead, which reach the special cases.
random_call :: proc(seed: ^u64, b: int) -> (x, y, r: u64) {
	r1, r2 := splitmix(seed), splitmix(seed)
	raw := r1 >> 62 == 0
	if b < RANDOM_POW {
		xf := transmute(f64)(u64(0x3ff - 64 + r1 % 128) << 52 | r1 >> 12 & (1 << 52 - 1))
		yf := f64(i64(r2)) * 0h3C60000000000000 // 0x1p-57
		if raw do xf, yf = transmute(f64)r1, transmute(f64)r2
		return transmute(u64)xf, transmute(u64)yf, f64_bits(math.pow(xf, yf))
	}
	yf := f64(i64(r2)) * 0h3BC1000000000000 // 0x1.1p-67, 1088 = 0x1.1p10
	if raw do yf = transmute(f64)r2
	return 0x4000000000000000, transmute(u64)yf, f64_bits(math.pow(2, yf))
}

// Lists the random calls of one block, one per line, "<x> <y> <result>".
random_block :: proc(block: int) {
	seed: u64 = 1
	for b in 0 ..= block {
		for _ in 0 ..< 4096 {
			x, y, r := random_call(&seed, b)
			if b == block do emit("%016x %016x %016x\n", x, y, r)
		}
	}
}

usage :: proc() -> ! {
	fmt.eprintln("usage: libm_wasi hash <s|c|e> <lo> <hi> | list <s|c|e> <chunk> | domain | randomblock <block> | pow <x bits> <y bits>")
	os.exit(2)
}

number :: proc(s: string) -> int {
	n, ok := strconv.parse_int(s, 10)
	if !ok do usage()
	return n
}

bits :: proc(s: string) -> u64 {
	n, ok := strconv.parse_u64_of_base(s, 16)
	if !ok do usage()
	return n
}

func :: proc(s: string) -> u8 {
	if s != "s" && s != "c" && s != "e" do usage()
	return s[0]
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 do usage()
	switch args[0] {
	case "hash":
		if len(args) != 4 do usage()
		f := func(args[1])
		for c in number(args[2]) ..< number(args[3]) {
			h: u64 = FNV_START
			for i in 0 ..< CHUNK {
				h = fnv(h, u64(f32_call(f, transmute(f32)(u32(c) << 24 | u32(i)))), 4)
			}
			emit("%c %03x %016x\n", f, c, h)
			flush()
		}
	case "list":
		if len(args) != 3 do usage()
		f := func(args[1])
		c := number(args[2])
		for i in 0 ..< CHUNK {
			x := u32(c) << 24 | u32(i)
			emit("%08x %08x\n", x, f32_call(f, transmute(f32)x))
		}
	case "domain":
		domain()
	case "randomblock":
		if len(args) != 2 || number(args[1]) >= RANDOM_BLOCKS do usage()
		random_block(number(args[1]))
	case "pow":
		if len(args) != 3 do usage()
		x := transmute(f64)bits(args[1])
		y := transmute(f64)bits(args[2])
		emit("%016x\n", f64_bits(math.pow(x, y)))
	case:
		usage()
	}
	flush()
}
