// A plain reference for RTPS, RTPT and MVMVA, apart from package gte and
// written from the psx-spx formulas: i64 throughout, every saturation with
// its FLAG bit, the UNR divide and its table as listed there. Where psx-spx
// leaves it open this follows Mednafen: each MAC1-3 sum is checked against 44
// bits after every addition and wrapped, and IR1-3 saturate from the 32-bit
// MAC register. Run against gte.gte_cmd over random and edge states.
package main

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import gte "ps:psx/gte"

@(private = "file")
ref_seed: u32 = 0x6b43a9b5

@(private = "file")
ref_rand :: proc() -> u32 {
	ref_seed ~= ref_seed << 13
	ref_seed ~= ref_seed >> 17
	ref_seed ~= ref_seed << 5
	return ref_seed
}

@(rodata, private = "file")
REF_EDGES := [?]u32 {
	0, 1, 0x7fff, 0x8000, 0xffff, 0x10000, 0x7fff7fff, 0x80008000, 0x7fffffff, 0x80000000, 0xffffffff, 0x1000,
	0xf000f000,
}

// A register word: an edge, a small value in each half, or noise.
@(private = "file")
ref_word :: proc() -> u32 {
	n := ref_rand()
	switch n & 3 {
	case 0:
		return REF_EDGES[(n >> 2) % u32(len(REF_EDGES))]
	case 1:
		return ref_small(0x1000) | ref_small(0x1000) << 16
	}
	return ref_rand()
}

// A word in -limit..limit-1.
@(private = "file")
ref_signed :: proc(limit: u32) -> u32 {
	return ref_rand() % (2 * limit) - limit
}

// A half in base-limit..base+limit-1.
@(private = "file")
ref_small :: proc(limit: u32, base: u32 = 0) -> u32 {
	return (base + ref_signed(limit)) & 0xffff
}

@(private = "file")
Ref_Kind :: enum {
	Mixed,
	Mac_Overflow, // TR, BK, FC, RT and V at their extremes
	Divide_Overflow, // SZ3 = TRZ, small, against a large H
	Plain, // a camera-like transform: few saturations
}

// Every register written through gte_write but SXYP (it pushes), IRGB (it
// sets IR1-3) and ORGB (read only), then the kind's own.
@(private = "file")
ref_state :: proc(kind: Ref_Kind) {
	gte.state = {}
	for r in u32(0) ..< 64 {
		if r == 15 || r == 28 || r == 29 {continue}
		gte.gte_write(r, ref_word())
	}
	switch kind {
	case .Mixed:
	case .Mac_Overflow:
		ext := [?]u32{0x7fffffff, 0x80000000, 0x7ffff000, 0x80001000, 0x7fff7fff, 0x80008000}
		for r in ([?]u32{0, 1, 2, 3, 4, 5, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 47, 53, 54, 55}) {
			gte.gte_write(r, ext[ref_rand() % u32(len(ext))])
		}
	case .Divide_Overflow:
		gte.gte_write(58, ref_rand() | 0x8000) // H
		gte.gte_write(39, ref_rand() & 0x3ffff) // TRZ
		gte.gte_write(35, 0) // RT31, RT32
		gte.gte_write(36, 0) // RT33
	case .Plain:
		for r in u32(0) ..< 6 {gte.gte_write(r, ref_small(0x400) | ref_small(0x400) << 16)}
		gte.gte_write(32, ref_small(0x100, 0x1000) | ref_small(0x100) << 16) // RT11, RT12
		gte.gte_write(33, ref_small(0x100) | ref_small(0x100) << 16) // RT13, RT21
		gte.gte_write(34, ref_small(0x100, 0x1000) | ref_small(0x100) << 16) // RT22, RT23
		gte.gte_write(35, ref_small(0x100) | ref_small(0x100) << 16) // RT31, RT32
		gte.gte_write(36, ref_small(0x100, 0x1000)) // RT33
		gte.gte_write(37, ref_signed(0x400)) // TRX
		gte.gte_write(38, ref_signed(0x400)) // TRY
		gte.gte_write(39, 0x400 + ref_rand() % 0x4000) // TRZ
		gte.gte_write(56, ref_signed(0x1000000)) // OFX
		gte.gte_write(57, ref_signed(0x1000000)) // OFY
		gte.gte_write(58, 0x100 + ref_rand() % 0x300) // H
		gte.gte_write(59, ref_small(0x100)) // DQA
		gte.gte_write(60, ref_rand() % 0x1000000) // DQB
	}
}

@(private = "file")
ref_unr: [257]i64

// MAC i (1-3) sum acc + term, checked against 44 bits (FLAG bit 31 - i above,
// 28 - i below) and wrapped to them.
@(private = "file")
ref_add :: proc(g: ^gte.Gte, i: int, acc, term: i64) -> i64 {
	v := acc + term
	if v > (1 << 43) - 1 {g.flag |= 1 << u32(31 - i)}
	if v < -(1 << 43) {g.flag |= 1 << u32(28 - i)}
	return (v << 20) >> 20
}

// IR i (1-3) = v saturated to -8000h (0 with lm) .. 7FFFh, FLAG bit 25 - i.
@(private = "file")
ref_ir :: proc(g: ^gte.Gte, i: int, v: i64, lm: bool) {
	lo: i64 = lm ? 0 : -0x8000
	if v < lo || v > 0x7fff {g.flag |= 1 << u32(25 - i)}
	g.ir[i] = i32(clamp(v, lo, 0x7fff))
}

// MAC0 = v, checked against 32 bits (FLAG bit 16 above, 15 below).
@(private = "file")
ref_mac0 :: proc(g: ^gte.Gte, v: i64) {
	if v > 0x7fffffff {g.flag |= 1 << 16}
	if v < -0x80000000 {g.flag |= 1 << 15}
	g.mac[0] = i32(v)
}

@(private = "file")
ref_limit :: proc(g: ^gte.Gte, v, lo, hi: i64, bit: u32) -> i64 {
	if v < lo || v > hi {g.flag |= 1 << bit}
	return clamp(v, lo, hi)
}

// (H*20000h/SZ3+1)/2 by the UNR algorithm; 1FFFFh and FLAG bit 17 when H is
// not below SZ3*2.
@(private = "file")
ref_divide :: proc(g: ^gte.Gte) -> i64 {
	h, sz := i64(g.h & 0xffff), i64(g.sz[3])
	if h >= sz * 2 {
		g.flag |= 1 << 17
		return 0x1ffff
	}
	z := uint(intrinsics.count_leading_zeros(u16(sz)))
	n := h << z
	d := sz << z
	u := ref_unr[(d - 0x7fc0) >> 7] + 0x101
	d = (0x2000080 - d * u) >> 8
	d = (0x0000080 + d * u) >> 8
	return min(0x1ffff, (n * d + 0x8000) >> 16)
}

// One vertex of RTPS or RTPT: V n through RT and TR, then projected; the
// depth cue after the last.
@(private = "file")
ref_rtp :: proc(g: ^gte.Gte, n: int, shift: uint, lm, last: bool) {
	v := [3]i64{i64(g.v[n][0]), i64(g.v[n][1]), i64(g.v[n][2])}
	full: [3]i64
	for i in 0 ..< 3 {
		acc := i64(g.tr[i]) << 12
		for k in 0 ..< 3 {acc = ref_add(g, i + 1, acc, i64(g.rt[i][k]) * v[k])}
		full[i] = acc
		g.mac[i + 1] = i32(acc >> shift)
	}
	ref_ir(g, 1, i64(g.mac[1]), lm)
	ref_ir(g, 2, i64(g.mac[2]), lm)
	// IR3 saturates from MAC3 as lm says, but its flag is checked on MAC3
	// SAR ((1-sf)*12) as if lm were off.
	lo: i64 = lm ? 0 : -0x8000
	g.ir[3] = i32(clamp(i64(g.mac[3]), lo, 0x7fff))
	if z := full[2] >> 12; z < -0x8000 || z > 0x7fff {g.flag |= 1 << 22}
	g.sz[0], g.sz[1], g.sz[2] = g.sz[1], g.sz[2], g.sz[3]
	g.sz[3] = u32(ref_limit(g, full[2] >> 12, 0, 0xffff, 18))
	q := ref_divide(g)
	x := i64(g.ofx) + i64(g.ir[1]) * q
	ref_mac0(g, x)
	y := i64(g.ofy) + i64(g.ir[2]) * q
	ref_mac0(g, y)
	g.sxy[0], g.sxy[1] = g.sxy[1], g.sxy[2]
	g.sxy[2] = {i32(ref_limit(g, x >> 16, -0x400, 0x3ff, 14)), i32(ref_limit(g, y >> 16, -0x400, 0x3ff, 13))}
	if last {
		d := i64(g.dqb) + i64(g.dqa) * q
		ref_mac0(g, d)
		g.ir[0] = i32(ref_limit(g, d >> 12, 0, 0x1000, 12))
	}
}

@(private = "file")
ref_widen :: proc(m: [3][3]i32) -> (w: [3][3]i64) {
	for r in 0 ..< 3 {
		for c in 0 ..< 3 {w[r][c] = i64(m[r][c])}
	}
	return
}

@(private = "file")
ref_mvmva :: proc(g: ^gte.Gte, cmd: u32, shift: uint, lm: bool) {
	m: [3][3]i64
	switch (cmd >> 17) & 3 {
	case 0:
		m = ref_widen(g.rt)
	case 1:
		m = ref_widen(g.llm)
	case 2:
		m = ref_widen(g.lcm)
	case 3:
		// The garbage matrix: -R*10h, R*10h, IR0; RT13 thrice; RT22 thrice.
		r := i64(g.rgbc[0]) << 4
		a, b := i64(g.rt[0][2]), i64(g.rt[1][1])
		m = {{-r, r, i64(g.ir[0])}, {a, a, a}, {b, b, b}}
	}
	v: [3]i64
	switch n := (cmd >> 15) & 3; n {
	case 3:
		v = {i64(g.ir[1]), i64(g.ir[2]), i64(g.ir[3])}
	case:
		v = {i64(g.v[n][0]), i64(g.v[n][1]), i64(g.v[n][2])}
	}
	t: [3]i64
	cv := (cmd >> 13) & 3
	switch cv {
	case 0:
		t = {i64(g.tr[0]), i64(g.tr[1]), i64(g.tr[2])}
	case 1:
		t = {i64(g.bk[0]), i64(g.bk[1]), i64(g.bk[2])}
	case 2:
		t = {i64(g.fc[0]), i64(g.fc[1]), i64(g.fc[2])}
	}
	for i in 0 ..< 3 {
		acc := t[i] << 12
		first := 0
		if cv == 2 {
			// FC is added wrongly: FC and the first column set flags, IR's
			// as if lm were off, and are lost; the result is the other two
			// columns alone.
			acc = ref_add(g, i + 1, acc, m[i][0] * v[0])
			ref_ir(g, i + 1, i64(i32(acc >> shift)), false)
			acc, first = 0, 1
		}
		for k in first ..< 3 {acc = ref_add(g, i + 1, acc, m[i][k] * v[k])}
		g.mac[i + 1] = i32(acc >> shift)
	}
	for i in 1 ..< 4 {ref_ir(g, i, i64(g.mac[i]), lm)}
}

@(private = "file")
ref_cmd :: proc(g: ^gte.Gte, cmd: u32) {
	shift := uint((cmd >> 19) & 1) * 12
	lm := (cmd >> 10) & 1 != 0
	g.flag = 0
	switch cmd & 0x3f {
	case 0x01:
		ref_rtp(g, 0, shift, lm, true)
	case 0x30:
		for n in 0 ..< 3 {ref_rtp(g, n, shift, lm, n == 2)}
	case 0x12:
		ref_mvmva(g, cmd, shift, lm)
	}
	// Bit 31: bits 30-23 and 18-13 ORed.
	if g.flag & 0x7f87e000 != 0 {g.flag |= 0x80000000}
}

// The fields of got that differ from the reference's, for a failure.
@(private = "file")
ref_diff :: proc(got, want: gte.Gte) -> string {
	b := strings.builder_make(context.temp_allocator)
	if got.flag != want.flag {fmt.sbprintf(&b, " flag %08x (ref %08x)", got.flag, want.flag)}
	if got.mac != want.mac {fmt.sbprintf(&b, " mac %x (ref %x)", got.mac, want.mac)}
	if got.ir != want.ir {fmt.sbprintf(&b, " ir %x (ref %x)", got.ir, want.ir)}
	if got.sxy != want.sxy {fmt.sbprintf(&b, " sxy %x (ref %x)", got.sxy, want.sxy)}
	if got.sz != want.sz {fmt.sbprintf(&b, " sz %x (ref %x)", got.sz, want.sz)}
	rest := got
	rest.flag, rest.mac, rest.ir, rest.sxy, rest.sz = want.flag, want.mac, want.ir, want.sxy, want.sz
	if transmute(gte.Gte_State)rest != transmute(gte.Gte_State)want {strings.write_string(&b, " and other fields")}
	return strings.to_string(b)
}

// RTPS, RTPT and every MVMVA form, each with both shifts and lm settings,
// against the reference; every FLAG bit the commands set, and FLAG 0, must
// show up. Returns the checks done.
ref_check :: proc() -> int {
	for i in 0 ..< 257 {
		ref_unr[i] = max(0, (0x40000 / i64(i + 0x100) + 1) / 2 - 0x101)
	}
	words := make([dynamic]u32)
	defer delete(words)
	for sf in u32(0) ..< 2 {
		for lm in u32(0) ..< 2 {
			bits := sf << 19 | lm << 10
			append(&words, 0x100001 | bits, 0x200030 | bits)
			for mx in u32(0) ..< 4 {
				for v in u32(0) ..< 4 {
					for cv in u32(0) ..< 4 {append(&words, 0x400012 | bits | mx << 17 | v << 15 | cv << 13)}
				}
			}
		}
	}
	Class :: enum {
		Rtps,
		Rtpt,
		Mvmva,
	}
	WANT_BITS :: [Class]u32 {
		.Rtps  = 0xffc7f000,
		.Rtpt  = 0xffc7f000,
		.Mvmva = 0xffc00000,
	}
	seen: [Class]u32
	clean: [Class]bool
	runs, bad: [Class]int
	shown := 0
	for k in 0 ..< 1200 {
		ref_state(Ref_Kind(k % len(Ref_Kind)))
		start := gte.gte_save()
		for w in words {
			class := Class.Mvmva
			switch w & 0x3f {
			case 0x01:
				class = .Rtps
			case 0x30:
				class = .Rtpt
			}
			gte.gte_load(start)
			want := gte.state
			ref_cmd(&want, w)
			gte.gte_cmd(w)
			seen[class] |= want.flag
			if want.flag == 0 {clean[class] = true}
			runs[class] += 1
			if gte.gte_save() == transmute(gte.Gte_State)want {continue}
			bad[class] += 1
			if shown < 20 {
				shown += 1
				s := transmute(gte.Gte)start
				fmt.eprintfln("ref %07x from state %d (tr %x h %x v %x):%s", w, k, s.tr, s.h, s.v, ref_diff(gte.state, want))
			}
		}
		free_all(context.temp_allocator)
	}
	want_bits := WANT_BITS
	for c in Class {
		if bad[c] != 0 {fail("ref %v: %d of %d runs differ from gte_cmd", c, bad[c], runs[c])}
		if missing := want_bits[c] &~ seen[c]; missing != 0 {fail("ref %v: FLAG bits %08x never set", c, missing)}
		if !clean[c] {fail("ref %v: no run with FLAG 0", c)}
	}
	return runs[.Rtps] + runs[.Rtpt] + runs[.Mvmva]
}
