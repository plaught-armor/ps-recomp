// Native code test, run on every target in CI. Assembles functions that use
// every operation of recomp/native for the host's ABI, loads them through
// the blob format and core.native_load, runs them over a set of inputs and
// checks each result against the same operation done in Odin.
//
// Every check is one 32-bit slot of `state`: the code computes into it from
// the inputs at IN0 and IN1, and `cases` says what it must hold. Besides the
// results, slots hold registers that an operation must leave alone, and the
// T and LD registers across calls into Odin. IN0, IN1, CA and CB are cached
// fields, in host registers while the code runs.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import "ps:recomp/native"

N_SLOTS :: 8192
// Two 16-byte guest registers for load_state and store_state at the end of
// the state, register n at 16 * n; REG0 stands for a zero register.
REGS_AT :: N_SLOTS - 8
REG0 :: REGS_AT / 4
CYCLES :: 0 // u64, compared by br_state64_below
ACC :: 8 // u64, added to by state_add64
IN0 :: 16
IN1 :: 20
CA :: 24
CB :: 28
FIRST :: 8 // first result slot

State :: struct #align (16) {
	w: [N_SLOTS]u32,
}

state: State
funnel: [32]u8
next: u64
flags: u8
seen_ctx: int

Kind :: enum u8 {
	Const, // imm
	Val, // the value `vals` gives register d
	Alu,
	Alu_Imm,
	Not,
	Mov,
	Set,
	Set_Imm,
	Mul, // imm 0 for the low word, 1 for the high
	Call3, // f3 of registers d, s, r
	Br_Zero, // flag: nonzero
	Br_Cmp, // r c imm
	Br_Below,
	Br_Byte, // imm: mask bit, or 8 for the whole byte
	Loop,
	Early,
	Cache, // what fc saw in CA and CB
	Load, // imm: the address, plus IN0 with flag
	Store, // imm: the address; the slot holds what a load there reads back
	Vec, // word imm of v over the vectors vec_in gives, or (flag) of P with itself
	Vec_Shift, // word imm of Q's lanes shifted by op and s
	Funnel, // word imm of the 16 bytes from byte n of P then Q
	Any, // not checked
}

Case :: struct {
	kind:    Kind,
	op:      native.Alu,
	c:       native.Cond,
	d, s, r: native.Reg,
	imm:     u32,
	flag:    bool,
	w:       native.Width,
	signed:  bool,
	v:       native.Vop,
	n:       u32,
}

a: native.Asm
cases: [dynamic]Case
acc_add: u64

// Byte offset of a new result slot that must hold what c says.
add :: proc(c: Case) -> u32 {
	n := FIRST + len(cases)
	assert(n < REGS_AT, "too many cases")
	append(&cases, c)
	return u32(4 * n)
}

alu :: proc(op: native.Alu, x, y: u32) -> u32 {
	switch op {
	case .Add:
		return x + y
	case .Sub:
		return x - y
	case .And:
		return x & y
	case .Or:
		return x | y
	case .Xor:
		return x ~ y
	case .Shl:
		return x << (y & 31)
	case .Shr:
		return x >> (y & 31)
	case .Sar:
		return u32(i32(x) >> (y & 31))
	}
	return 0
}

cond :: proc(c: native.Cond, x, y: u32) -> u32 {
	r: bool
	switch c {
	case .Eq:
		r = x == y
	case .Ne:
		r = x != y
	case .Lt:
		r = i32(x) < i32(y)
	case .Ge:
		r = i32(x) >= i32(y)
	case .Le:
		r = i32(x) <= i32(y)
	case .Gt:
		r = i32(x) > i32(y)
	case .Ltu:
		r = x < y
	case .Geu:
		r = x >= y
	}
	return 1 if r else 0
}

// Distinct values for the five registers, which load_vals puts in them.
K :: 0x5a5a_0f0f
vals :: proc(r: native.Reg, x, y: u32) -> u32 {
	switch r {
	case .A:
		return x
	case .B:
		return y
	case .C:
		return x + y
	case .T:
		return ~x
	case .LD:
		return K
	}
	return 0
}

load_vals :: proc() {
	native.state_load(&a, .A, IN0)
	native.state_load(&a, .B, IN1)
	native.mov(&a, .C, .A)
	native.alu(&a, .Add, .C, .B)
	native.mov(&a, .T, .A)
	native.not(&a, .T)
	native.mov_imm(&a, .LD, K)
}

// Store every register except those in `lost`, each a slot that must still
// hold its value from load_vals.
check_kept :: proc(lost: bit_set[native.Reg]) {
	for r in native.Reg {
		if r not_in lost {
			native.state_store(&a, add({kind = .Val, d = r}), r)
		}
	}
}

f0 :: proc() -> u32 {
	seen_ctx = context.user_index
	return 0xc0ffee
}

// Reads and changes cached fields, which a call must find in the state.
fc :: proc() -> u32 {
	r := state.w[CA / 4] ~ state.w[CB / 4]
	state.w[CB / 4] = 0xbeef
	return r
}

// Works through the formatter, so most registers a call may change do
// change: the native code must keep T and LD in ones it may not.
f3 :: proc(x, y, z: u32) -> u32 {
	seen_ctx = context.user_index
	buf: [64]u8
	s := fmt.bprintf(buf[:], "%x %x %x", x, y, z)
	h := u32(2166136261)
	for ch in transmute([]u8)s {h = (h ~ u32(ch)) * 16777619}
	return h
}

expect :: proc(c: Case, x, y: u32) -> u32 {
	yy := x if c.s == c.d else y
	switch c.kind {
	case .Const:
		return c.imm
	case .Cache:
		return x ~ 0x1234
	case .Val:
		return vals(c.d, x, y)
	case .Alu:
		return alu(c.op, x, yy)
	case .Alu_Imm:
		return alu(c.op, x, c.imm)
	case .Not:
		return ~x
	case .Mov:
		return y
	case .Set:
		return cond(c.c, x, yy)
	case .Set_Imm:
		return cond(c.c, x, c.imm)
	case .Mul:
		p := u64(i64(i32(x)) * i64(i32(yy))) if c.flag else u64(x) * u64(yy)
		return u32(p >> 32) if c.imm == 1 else u32(p)
	case .Call3:
		return f3(vals(c.d, x, y), vals(c.s, x, y), vals(c.r, x, y))
	case .Br_Zero, .Br_Cmp, .Br_Below, .Br_Byte:
		taken: bool
		#partial switch c.kind {
		case .Br_Zero:
			taken = (x == 0) != c.flag
		case .Br_Cmp:
			taken = cond(c.c, x, c.imm) == 1
		case .Br_Below:
			taken = cycles_of(x, y) < next_of(x, y)
		case .Br_Byte:
			f := flags_of(x, y)
			taken = f == 0 if c.imm == 8 else f & (1 << c.imm) == 0
		}
		return 0 if taken else 1
	case .Loop:
		return 3 * (x & 15)
	case .Early:
		return 1 if x != 0 else 2
	case .Load:
		addr := c.imm + (x if c.flag else 0)
		if c.w >= .B64 {return wide_load(addr &~ 15 if c.w == .B128 else addr, c.w, int(c.n))}
		if o, ok := mem_at(addr); ok {
			v: u32
			for k in 0 ..< width_bytes(c.w) {v |= u32(mem_pat(o + k)) << (8 * uint(k))}
			return narrow(v, c.w, c.signed)
		}
		if o, ok := win_at(addr); ok {return narrow(win_word(o), c.w, c.signed)}
		return narrow(FAR ~ addr, c.w, c.signed)
	case .Store:
		if c.w >= .B64 {return wide_store(c.imm, c.w, int(c.n), c.flag, x, y)}
		if o, ok := win_at(c.imm); ok {
			// A slow store, while a guard is set, leaves the window as it was.
			return narrow(y if guards_of(x, y) == {0, 0} else win_word(o), c.w, false)
		}
		o, ok := mem_at(c.imm)
		switch {
		case !ok:
			return narrow(y ~ c.imm, c.w, false)
		case guards_of(x, y) == {0, 0} && !page_set(x, o >> 12):
			return narrow(y, c.w, false)
		case:
			return narrow(y ~ SLOW_TAG, c.w, false)
		}
	case .Vec:
		p, q := vec_in(x, y)
		return vec_ref(c.v, p, p if c.flag else q)[c.imm]
	case .Vec_Shift:
		_, q := vec_in(x, y)
		h := transmute([8]u16)q
		for &l in h {
			#partial switch c.op {
			case .Shl:
				l <<= c.n
			case .Shr:
				l >>= c.n
			case .Sar:
				l = u16(i16(l) >> c.n)
			}
		}
		return (transmute([4]u32)h)[c.imm]
	case .Funnel:
		p, q := vec_in(x, y)
		pq := transmute([32]u8)[8]u32{p[0], p[1], p[2], p[3], q[0], q[1], q[2], q[3]}
		r: [16]u8
		copy(r[:], pq[c.n:][:16])
		return (transmute([4]u32)r)[c.imm]
	case .Any:
	}
	return 0
}

// The two vectors the vector checks start from.
vec_in :: proc(x, y: u32) -> (p, q: [4]u32) {
	return {x, y, x ~ 0x80008000, y + 0x7fff7fff}, {y, x, ~y, (x << 7) ~ y}
}

vec_ref :: proc(op: native.Vop, d, s: [4]u32) -> [4]u32 {
	db, sb := transmute([16]u8)d, transmute([16]u8)s
	dh, sh := transmute([8]i16)d, transmute([8]i16)s
	r: [16]u8
	rh: [8]i16
	r4: [4]u32
	switch op {
	case .Or:
		return d | s
	case .Nor:
		return ~(d | s)
	case .And:
		return d & s
	case .Andn:
		return s &~ d
	case .Eq32:
		for k in 0 ..< 4 {r4[k] = max(u32) if d[k] == s[k] else 0}
		return r4
	case .Fadd, .Fsub, .Fmul, .Fdiv:
		df, sf := transmute([4]f32)d, transmute([4]f32)s
		rf := df + sf if op == .Fadd else df - sf if op == .Fsub else df * sf if op == .Fmul else df / sf
		return transmute([4]u32)rf
	case .Itof:
		for k in 0 ..< 4 {r4[k] = transmute(u32)f32(i32(s[k]))}
		return r4
	case .Ftoi:
		// Out of range or NaN as the host's instruction gives it.
		for k in 0 ..< 4 {
			f := transmute(f32)s[k]
			switch {
			case f >= 2147483648.0: r4[k] = 0x80000000 when ODIN_ARCH == .amd64 else 0x7fffffff
			case f < -2147483648.0: r4[k] = 0x80000000
			case f != f: r4[k] = 0x80000000 when ODIN_ARCH == .amd64 else 0
			case: r4[k] = u32(i32(f))
			}
		}
		return r4
	case .Gt32:
		for k in 0 ..< 4 {r4[k] = max(u32) if i32(d[k]) > i32(s[k]) else 0}
		return r4
	case .Xor:
		return d ~ s
	case .Gt16:
		for k in 0 ..< 8 {rh[k] = -1 if dh[k] > sh[k] else 0}
		return transmute([4]u32)rh
	case .Add16, .Max16, .Min16:
		for k in 0 ..< 8 {
			rh[k] = dh[k] + sh[k] if op == .Add16 else max(dh[k], sh[k]) if op == .Max16 else min(dh[k], sh[k])
		}
		return transmute([4]u32)rh
	case .Zip_Lo8, .Zip_Hi8:
		h := 8 if op == .Zip_Hi8 else 0
		for k in 0 ..< 8 {r[2 * k], r[2 * k + 1] = db[h + k], sb[h + k]}
	case .Zip_Lo64:
		return {d[0], d[1], s[0], s[1]}
	case .Zip_Hi64:
		return {d[2], d[3], s[2], s[3]}
	case .Zip_Lo16:
		for k in 0 ..< 4 {rh[2 * k], rh[2 * k + 1] = dh[k], sh[k]}
		return transmute([4]u32)rh
	case .Sub32:
		return d - s
	case .Sub8:
		for k in 0 ..< 16 {r[k] = db[k] - sb[k]}
	case .Zip_Lo32:
		return {d[0], s[0], d[1], s[1]}
	case .Zip_Hi32:
		return {d[2], s[2], d[3], s[3]}
	case .Dup16:
		for k in 0 ..< 4 {rh[k], rh[k + 4] = sh[0], sh[4]}
		return transmute([4]u32)rh
	case .Even8:
		for k in 0 ..< 8 {r[k], r[k + 8] = db[2 * k], sb[2 * k]}
	case .Even16:
		for k in 0 ..< 4 {rh[k], rh[k + 4] = dh[2 * k], sh[2 * k]}
		return transmute([4]u32)rh
	}
	return transmute([4]u32)r
}

// Guest RAM for load and store: 64K mirrored below physical 0x40000, in
// 16 pages, and again at 0x10000000 up, a mirror off the fast path. `far`
// is what a slow store outside RAM got; a slow load outside RAM reads far
// ^ address. A slow store into RAM writes the value ^ SLOW_TAG, so a load
// back tells which path it took. The window is 1K at WIN_AT, reached in
// place off the fast path.
MEM_SIZE :: 0x10000
mem: [MEM_SIZE + 16]u8 // the tail is what a wide access at the last bytes reads
mem_pages: [MEM_SIZE >> 12]u8
guard: [2]u8
far: u32
FAR :: 0x13579bdf
SLOW_TAG :: 0x5a5a5a5a
MEM_GUARDS := [?]native.Guard{{"guard0", 0x04}, {"guard1", 0xff}}
MIRROR_MASK :: 0xfffc0000
MIRROR_BITS :: 0x10000000
WIN_AT :: 0x1f800000
WIN_SIZE :: 0x400
win: [WIN_SIZE + 16]u8

mem_ram :: proc() -> native.Ram {
	return {
		base = "mem",
		outside = 0x1ffc0000,
		size = MEM_SIZE,
		pages = "mem_pages",
		page_shift = 12,
		guards = MEM_GUARDS[:],
		mirror_mask = MIRROR_MASK,
		mirror_bits = MIRROR_BITS,
		window = "win",
		window_at = WIN_AT,
		window_size = WIN_SIZE,
	}
}

mem_at :: proc(addr: u32) -> (int, bool) {
	p := addr & 0x1fffffff
	return int(p & (MEM_SIZE - 1)), p < 0x40000 || addr & MIRROR_MASK == MIRROR_BITS
}

win_at :: proc(addr: u32) -> (int, bool) {return int(addr - WIN_AT), addr - WIN_AT < WIN_SIZE}
win_pat :: proc(o: int) -> u8 {return u8(o * 11 + 0x5b)}

win_word :: proc(o: int) -> u32 {
	v: u32
	for j in 0 ..< 4 {v |= u32(win_pat(o + j)) << (8 * uint(j))}
	return v
}

mem_pat :: proc(o: int) -> u8 {return u8(o * 7 + (o >> 8))}
page_set :: proc(x: u32, k: int) -> bool {return (x >> 16 >> uint(k)) & 1 != 0}
// guard0 is tested with mask 4, guard1 whole; the result keeps only those bits.
guards_of :: proc(x, y: u32) -> [2]u8 {return {u8(y >> 24) & 0x04, u8(x >> 24) & 1}}

width_bytes :: proc(w: native.Width) -> int {return 1 << uint(w)}

narrow :: proc(v: u32, w: native.Width, signed: bool) -> u32 {
	switch w {
	case .B8:
		return u32(i32(i8(v))) if signed else v & 0xff
	case .B16:
		return u32(i32(i16(v))) if signed else v & 0xffff
	case .B32, .B64, .B128:
	}
	return v
}

load_far :: proc(addr: u32, w: native.Width, signed: bool) -> u32 {
	seen_ctx = context.user_index
	return narrow(far ~ addr, w, signed)
}

store_far :: proc(addr, v: u32, w: native.Width) {
	seen_ctx = context.user_index
	o, ok := mem_at(addr)
	if !ok {
		far = v
		return
	}
	for k in 0 ..< width_bytes(w) {mem[o + k] = u8((v ~ SLOW_TAG) >> (8 * uint(k)))}
}

// A wide access off the fast path, for guest register n: outside RAM it
// reads far_wide ^ address and writes far_wide; in RAM like store_far.
// Register REG0 stores as zero.
far_wide: [4]u32
FAR_WIDE := [4]u32{0x2468ace0, 0x369cf258, 0x48d159e2, 0x5ae2c3f4}

wide_far :: proc(addr, n: u32, w: native.Width, store: bool) {
	seen_ctx = context.user_index
	addr := addr &~ 15 if w == .B128 else addr
	reg := state.w[4 * n:][:width_bytes(w) / 4]
	o, ok := mem_at(addr)
	for &v, k in reg {
		switch {
		case !store && !ok:
			v = far_wide[k] ~ addr
		case !store:
			v = mem_word(o + 4 * k)
		case !ok:
			far_wide[k] = 0 if n == REG0 else v
		case:
			src := (0 if n == REG0 else v) ~ SLOW_TAG
			for j in 0 ..< 4 {mem[o + 4 * k + j] = u8(src >> (8 * uint(j)))}
		}
	}
}

mem_word :: proc(o: int) -> u32 {
	v: u32
	for j in 0 ..< 4 {v |= u32(mem_pat(o + j)) << (8 * uint(j))}
	return v
}

// Word k of a register that a wide load from addr (aligned for B128) gave;
// one the load does not reach keeps the junk it held.
wide_load :: proc(addr: u32, w: native.Width, k: int) -> u32 {
	if 4 * k >= width_bytes(w) {return junk(k)}
	if o, ok := mem_at(addr); ok {return mem_word(o + 4 * k)}
	if o, ok := win_at(addr); ok {return win_word(o + 4 * k)}
	return FAR_WIDE[k] ~ addr
}

junk :: proc(k: int) -> u32 {return 0xdead0000 | u32(k)}

// Word k of the source register a wide store takes (zero: REG0, so 0).
wide_src :: proc(y: u32, k: int, zero: bool) -> u32 {return 0 if zero else y + u32(k) * 0x01010101}

// Word k that a wide load from addr reads back after a wide store there.
wide_store :: proc(addr: u32, w: native.Width, k: int, zero: bool, x, y: u32) -> u32 {
	v := wide_src(y, k, zero)
	if o, ok := win_at(addr); ok {return v if guards_of(x, y) == {0, 0} else win_word(o + 4 * k)}
	o, ok := mem_at(addr)
	switch {
	case !ok:
		return v ~ addr
	case guards_of(x, y) == {0, 0} && !page_set(x, o >> 12):
		return v
	case:
		return v ~ SLOW_TAG
	}
}

ld_far :: proc(a, n: u32) {wide_far(a, n, .B64, false)}
lq_far :: proc(a, n: u32) {wide_far(a, n, .B128, false)}
sd_far :: proc(a, n: u32) {wide_far(a, n, .B64, true)}
sq_far :: proc(a, n: u32) {wide_far(a, n, .B128, true)}

lb_far :: proc(a: u32) -> u32 {return load_far(a, .B8, true)}
lbu_far :: proc(a: u32) -> u32 {return load_far(a, .B8, false)}
lh_far :: proc(a: u32) -> u32 {return load_far(a, .B16, true)}
lhu_far :: proc(a: u32) -> u32 {return load_far(a, .B16, false)}
lw_far :: proc(a: u32) -> u32 {return load_far(a, .B32, false)}
sb_far :: proc(a, v: u32) {store_far(a, v, .B8)}
sh_far :: proc(a, v: u32) {store_far(a, v, .B16)}
sw_far :: proc(a, v: u32) {store_far(a, v, .B32)}

LOAD_SLOW := [native.Width][2]string {
	.B8   = {"lbu_far", "lb_far"},
	.B16  = {"lhu_far", "lh_far"},
	.B32  = {"lw_far", "lw_far"},
	.B64  = {"ld_far", "ld_far"},
	.B128 = {"lq_far", "lq_far"},
}
STORE_SLOW := [native.Width]string {
	.B8   = "sb_far",
	.B16  = "sh_far",
	.B32  = "sw_far",
	.B64  = "sd_far",
	.B128 = "sq_far",
}
NARROW :: [?]native.Width{.B8, .B16, .B32}
WIDE :: [?]native.Width{.B64, .B128}

// RAM, a page boundary, mirrors in each segment, the end of RAM and past
// it, the slow mirror and its end, the window, its end and past it, and
// the BIOS.
MEM_ADDRS := [?]u32 {
	0x100,
	0x80001204,
	0xa0012308,
	0x3f30c,
	0x8000510e,
	0x9ffd,
	0xfffe,
	0x3ffff,
	0x40000,
	0x1000a10c,
	0x1003fff8,
	0x1f800010,
	0x1f8003f8,
	0x1f800400,
	0xbfc00000,
}

// Loads, then stores each read back, every one with its registers checked.
// The wide ones go through guest register REG0 + 1 and, for a store, REG0
// as a zero register; a B128 address is aligned first, as callers do.
build_mem :: proc() {
	for addr in MEM_ADDRS {
		for w in NARROW {
			for signed in ([?]bool{false, true}) {
				for from_x in ([?]bool{false, true}) {
					load_vals()
					if from_x {
						native.state_load(&a, .A, IN0)
						if addr != 0 {native.alu_imm(&a, .Add, .A, addr)}
					} else {
						native.mov_imm(&a, .A, addr)
					}
					native.load(&a, w, signed, LOAD_SLOW[w][1 if signed else 0])
					native.state_store(&a, add({kind = .Load, imm = addr, flag = from_x, w = w, signed = signed}), .A)
					check_kept({.A, .B, .C})
				}
			}
		}
		for w in WIDE {
			for from_x in ([?]bool{false, true}) {
				n := u32(REG0 + 1)
				load_vals()
				for k in u32(0) ..< 4 {native.state_store_imm(&a, 16 * n + 4 * k, junk(int(k)))}
				if from_x {
					native.state_load(&a, .A, IN0)
					if addr != 0 {native.alu_imm(&a, .Add, .A, addr)}
				} else {
					native.mov_imm(&a, .A, addr)
				}
				if w == .B128 {native.alu_imm(&a, .And, .A, ~u32(15))}
				native.load_state(&a, w, 16 * n, n, LOAD_SLOW[w][0])
				check_kept({.A, .B, .C})
				for k in u32(0) ..< 4 {
					native.state_load(&a, .A, 16 * n + 4 * k)
					native.state_store(&a, add({kind = .Load, imm = addr, flag = from_x, w = w, n = k}), .A)
				}
			}
		}
	}
	for addr in MEM_ADDRS {
		for w in WIDE {
			for zero in ([?]bool{false, true}) {
				n := u32(REG0 if zero else REG0 + 1)
				aligned := addr &~ 15 if w == .B128 else addr
				load_vals()
				// The source register; REG0 holds the same, which zero ignores.
				for k in u32(0) ..< 4 {
					native.state_store(&a, 16 * n + 4 * k, .B)
					native.alu_imm(&a, .Add, .B, 0x01010101)
				}
				native.mov_imm(&a, .A, addr)
				if w == .B128 {native.alu_imm(&a, .And, .A, ~u32(15))}
				native.store_state(&a, w, 16 * n, n, STORE_SLOW[w], zero)
				check_kept({.A, .B, .C})
				m := u32(REG0 + 1)
				native.mov_imm(&a, .A, aligned)
				native.load_state(&a, w, 16 * m, m, LOAD_SLOW[w][0])
				for k in 0 ..< width_bytes(w) / 4 {
					native.state_load(&a, .A, 16 * m + 4 * u32(k))
					native.state_store(&a, add({kind = .Store, imm = aligned, w = w, n = u32(k), flag = zero}), .A)
				}
			}
		}
	}
	for addr in MEM_ADDRS {
		for w in NARROW {
			load_vals()
			native.mov_imm(&a, .A, addr)
			native.state_load(&a, .B, IN1)
			native.store(&a, w, STORE_SLOW[w])
			check_kept({.A, .B, .C})
			native.mov_imm(&a, .A, addr)
			native.load(&a, w, false, LOAD_SLOW[w][0])
			native.state_store(&a, add({kind = .Store, imm = addr, w = w}), .A)
		}
	}
}

cycles_of :: proc(x, y: u32) -> u64 {return u64(x) << 32 | u64(y)}
next_of :: proc(x, y: u32) -> u64 {return u64(y) << 32 | u64(x)}
flags_of :: proc(x, y: u32) -> u8 {return u8(x ~ y)}

// The register after r, for a second operand.
other :: proc(r: native.Reg) -> native.Reg {
	return native.Reg((int(r) + 1) % len(native.Reg))
}

IMMS := [?]u32{0, 1, 5, 31, 0x7f, 0x80, 0xfff, 0x1000, 0xffff, 0x10000, 0x12340000, 0xffff0000, 0x12345678, 0x7fffffff, 0x80000000, 0xffffff80, 0xffffffff}

// A branch to l that a case of kind k (on register d) describes.
branch :: proc(c: Case, l: native.Label) {
	#partial switch c.kind {
	case .Br_Zero:
		native.br_zero(&a, c.d, l, c.flag)
	case .Br_Cmp:
		native.br_cmp_imm(&a, c.c, c.d, c.imm, l)
	case .Br_Below:
		native.br_state64_below(&a, CYCLES, "next", l)
	case .Br_Byte:
		native.br_byte_clear(&a, "flags", "" if c.imm == 8 else fmt.tprintf("m%d", c.imm), l)
	}
}

build_main :: proc() {
	for d in native.Reg {
		for s in native.Reg {
			for op in native.Alu {
				native.state_load(&a, d, IN0)
				native.state_load(&a, s, IN1)
				native.state_load(&a, d, IN0)
				native.alu(&a, op, d, s)
				native.state_store(&a, add({kind = .Alu, op = op, d = d, s = s}), d)
			}
			for c in native.Cond {
				native.state_load(&a, s, IN1)
				native.state_load(&a, d, IN0)
				native.set_cond(&a, c, d, s)
				native.state_store(&a, add({kind = .Set, c = c, d = d, s = s}), d)
			}
			for signed in ([?]bool{false, true}) {
				native.state_load(&a, s, IN1)
				native.state_load(&a, d, IN0)
				hi := add({kind = .Mul, d = d, s = s, imm = 1, flag = signed})
				lo := add({kind = .Mul, d = d, s = s, imm = 0, flag = signed})
				native.mul_wide(&a, signed, lo, hi, d, s)
			}
			if d != s {
				native.state_load(&a, s, IN1)
				native.mov(&a, d, s)
				native.state_store(&a, add({kind = .Mov, d = d, s = s}), d)
			}
		}
		for v in IMMS {
			for op in native.Alu {
				if op >= .Shl && v >= 32 {continue}
				native.state_load(&a, d, IN0)
				native.alu_imm(&a, op, d, v)
				native.state_store(&a, add({kind = .Alu_Imm, op = op, d = d, imm = v}), d)
			}
			if d != .C {
				for c in native.Cond {
					native.state_load(&a, d, IN0)
					native.set_cond_imm(&a, c, d, v)
					native.state_store(&a, add({kind = .Set_Imm, c = c, d = d, imm = v}), d)
				}
			}
			native.mov_imm(&a, d, v)
			native.state_store(&a, add({kind = .Const, imm = v}), d)
			native.state_store_imm(&a, add({kind = .Const, imm = v ~ 0x0f0f}), v ~ 0x0f0f)
		}
		native.state_load(&a, d, IN0)
		native.not(&a, d)
		native.state_store(&a, add({kind = .Not, d = d}), d)
	}

	// What each operation must leave alone.
	for d in native.Reg {
		for op in native.Alu {
			load_vals()
			native.alu(&a, op, d, other(d))
			check_kept({d})
			load_vals()
			native.alu_imm(&a, op, d, 7 if op >= .Shl else 0x12345678)
			check_kept({d})
		}
		load_vals()
		native.not(&a, d)
		check_kept({d})
		load_vals()
		native.mov_imm(&a, d, 0x87654321)
		check_kept({d})
		load_vals()
		native.set_cond(&a, .Lt, d, other(d))
		check_kept({d})
		if d != .C {
			load_vals()
			native.set_cond_imm(&a, .Ltu, d, 0x9999)
			check_kept({d, .C})
		}
		load_vals()
		native.mul_wide(&a, true, add({kind = .Any}), add({kind = .Any}), d, other(d))
		check_kept({.A, .B})
	}
	for v in ([?]u32{1, 4095, 4096, 0x12345, 0x7fffffff}) {
		load_vals()
		native.state_add64(&a, ACC, v)
		acc_add += u64(v)
		check_kept({})
	}
	load_vals()
	native.state_store_imm(&a, add({kind = .Const, imm = 0xabcd}), 0xabcd)
	check_kept({.C})

	// Branches, each taken or not: F is 0 after a taken one, 1 otherwise.
	brs: [dynamic]Case
	defer delete(brs)
	for d in native.Reg {
		append(&brs, Case{kind = .Br_Zero, d = d}, Case{kind = .Br_Zero, d = d, flag = true})
		for v in ([?]u32{0, 7, 0x80001000, 0xffffffff, 0x12345678}) {
			append(&brs, Case{kind = .Br_Cmp, c = .Eq, d = d, imm = v})
		}
		for v in ([?]u32{7, 0x80001000, 0xffffffff}) {
			for cc in native.Cond {
				if cc != .Eq {append(&brs, Case{kind = .Br_Cmp, c = cc, d = d, imm = v})}
			}
		}
	}
	append(&brs, Case{kind = .Br_Below})
	for m in 0 ..= 8 {append(&brs, Case{kind = .Br_Byte, imm = u32(m)})}
	for c in brs {
		f: native.Reg = .LD if c.d != .LD else .T
		load_vals()
		native.state_load(&a, c.d, IN0)
		skip := native.new_label(&a)
		native.mov_imm(&a, f, 0)
		branch(c, skip)
		native.mov_imm(&a, f, 1)
		native.bind(&a, skip)
		native.state_store(&a, add(c), f)
	}
	// Taken or not, a branch changes no register.
	for c in brs {
		load_vals()
		skip := native.new_label(&a)
		branch(c, skip)
		native.bind(&a, skip)
		check_kept({})
	}

	// A backward jump: B = 3 * (IN0 & 15).
	native.state_load(&a, .T, IN0)
	native.alu_imm(&a, .And, .T, 15)
	native.mov_imm(&a, .B, 0)
	top := native.new_label(&a)
	done := native.new_label(&a)
	native.bind(&a, top)
	native.br_zero(&a, .T, done)
	native.alu_imm(&a, .Add, .B, 3)
	native.alu_imm(&a, .Sub, .T, 1)
	native.jmp(&a, top)
	native.bind(&a, done)
	native.state_store(&a, add({kind = .Loop}), .B)

	// Cached fields: written in host registers, in the state for a call,
	// read in again after it.
	native.state_load(&a, .A, IN0)
	native.state_store(&a, CA, .A)
	native.state_store_imm(&a, CB, 0x1234)
	native.call(&a, "fc")
	native.state_store(&a, add({kind = .Cache}), .A)
	native.state_load(&a, .B, CB)
	native.state_store(&a, add({kind = .Const, imm = 0xbeef}), .B)

	// Calls: arguments from any registers, the result in A, T and LD kept.
	native.call(&a, "f0")
	native.state_store(&a, add({kind = .Const, imm = 0xc0ffee}), .A)
	for x in native.Reg {
		for y in native.Reg {
			for z in native.Reg {
				load_vals()
				native.call(&a, "f3", x, y, z)
				native.state_store(&a, add({kind = .Call3, d = x, s = y, r = z}), .A)
				check_kept({.A, .B, .C})
			}
		}
	}
	build_mem()
	build_vec()
	native.ret(&a)
}

// Four slots for a vector, the first at a multiple of 16 bytes.
add_vec :: proc(c: Case) -> u32 {
	for (FIRST + len(cases)) % 4 != 0 {add({kind = .Any})}
	at := add(c)
	for k in u32(1) ..< 4 {
		c := c
		c.imm = k
		add(c)
	}
	return at
}

// Vector operations on P and Q (vec_in), built in the state from IN0 and IN1.
build_vec :: proc() {
	p := add_vec({kind = .Any})
	q := add_vec({kind = .Any})
	native.state_load(&a, .A, IN0)
	native.state_load(&a, .B, IN1)
	native.state_store(&a, p, .A)
	native.state_store(&a, q + 4, .A)
	native.state_store(&a, p + 4, .B)
	native.state_store(&a, q, .B)
	native.mov(&a, .C, .A)
	native.alu_imm(&a, .Xor, .C, 0x80008000)
	native.state_store(&a, p + 8, .C)
	native.mov(&a, .C, .B)
	native.alu_imm(&a, .Add, .C, 0x7fff7fff)
	native.state_store(&a, p + 12, .C)
	native.mov(&a, .C, .B)
	native.not(&a, .C)
	native.state_store(&a, q + 8, .C)
	native.mov(&a, .C, .A)
	native.alu_imm(&a, .Shl, .C, 7)
	native.alu(&a, .Xor, .C, .B)
	native.state_store(&a, q + 12, .C)
	// dst = P, src = Q (or P too), then dst = dst op src
	run :: proc(op: native.Vop, d, s: native.Vreg, p, q: u32) {
		native.vec_load(&a, s, q)
		native.vec_load(&a, d, p)
		native.vec_op(&a, op, d, s)
		native.vec_store(&a, add_vec({kind = .Vec, v = op, flag = d == s}), d)
	}
	for op in native.Vop {
		run(op, .V0, .V1, p, q)
		run(op, .V1, .V0, p, q)
	}
	for d in native.Vreg {
		for s in native.Vreg {
			run(.Zip_Lo8, d, s, p, q)
		}
	}
	for op in ([?]native.Alu{.Shl, .Shr, .Sar}) {
		for n in ([?]u32{1, 15}) {
			native.vec_load(&a, .V2, q)
			native.vec_shift16(&a, op, .V2, n)
			native.vec_store(&a, add_vec({kind = .Vec_Shift, op = op, n = n}), .V2)
		}
	}
	for n in ([?]u32{0, 1, 7, 8, 15}) {
		native.mov_imm(&a, .A, n)
		native.vec_funnel8(&a, add_vec({kind = .Funnel, n = n}), p, q, "funnel")
	}
	// vec_shift16 by 0 does nothing.
	native.vec_load(&a, .V1, p)
	native.vec_shift16(&a, .Shl, .V1, 0)
	native.vec_store(&a, add_vec({kind = .Vec, v = .Or, flag = true}), .V1)
}

// A second function: returns early when IN0 is not zero.
build_early :: proc() {
	slot := add({kind = .Early})
	native.state_store_imm(&a, slot, 1)
	native.state_load(&a, .T, IN0)
	l := native.new_label(&a)
	native.br_zero(&a, .T, l)
	native.ret(&a)
	native.bind(&a, l)
	native.state_store_imm(&a, slot, 2)
}

CACHED := [?]u32{IN0, IN1, CA, CB}

VECTORS := [?][2]u32 {
	{0, 0},
	{1, 2},
	{7, 7},
	{0xffffffff, 1},
	{1, 0xffffffff},
	{0x80000000, 0x7fffffff},
	{0x7fffffff, 0x80000000},
	{5, 0xfffffffb},
	{0x12345678, 0x9abcdef0},
	{0xfffffffe, 0xffffffff},
	{3, 33},
	{0x80001000, 0x10},
	{0, 0xdeadbeef},
}

main :: proc() {
	arch := native.Arch(core.NATIVE_ARCH)
	a = native.make_asm(arch, mem_ram(), CACHED[:])
	main_at := native.func_begin(&a, "state")
	build_main()
	native.func_end(&a)
	early_at := native.func_begin(&a, "state")
	build_early()
	native.func_end(&a)

	ovl := native.Blob_Ovl{addr = 0x80100010, slot = 0x80100000, id = 0x1234, sig = {1, 2, 3, 4}, off = u32(early_at)}
	blob := native.make_blob(&a, {{addr = 0x80010000, off = u32(main_at)}}, {ovl})

	p :: proc(v: rawptr) -> u64 {return u64(uintptr(v))}
	imports: map[string]u64
	imports["state"] = p(&state)
	imports["next"] = p(&next)
	imports["flags"] = p(&flags)
	imports["f0"] = p(rawptr(f0))
	imports["f3"] = p(rawptr(f3))
	imports["fc"] = p(rawptr(fc))
	for m in 0 ..< 8 {imports[fmt.aprintf("m%d", m)] = 1 << uint(m)}
	imports["mem"] = p(&mem)
	imports["funnel"] = p(&funnel)
	imports["mem_pages"] = p(&mem_pages)
	imports["win"] = p(&win)
	imports["guard0"] = p(&guard[0])
	imports["guard1"] = p(&guard[1])
	imports["lb_far"] = p(rawptr(lb_far))
	imports["lbu_far"] = p(rawptr(lbu_far))
	imports["lh_far"] = p(rawptr(lh_far))
	imports["lhu_far"] = p(rawptr(lhu_far))
	imports["lw_far"] = p(rawptr(lw_far))
	imports["sb_far"] = p(rawptr(sb_far))
	imports["sh_far"] = p(rawptr(sh_far))
	imports["sw_far"] = p(rawptr(sw_far))
	imports["ld_far"] = p(rawptr(ld_far))
	imports["lq_far"] = p(rawptr(lq_far))
	imports["sd_far"] = p(rawptr(sd_far))
	imports["sq_far"] = p(rawptr(sq_far))
	code, err := core.native_load(blob, imports)
	if err != "" {
		fmt.eprintln("native_load:", err)
		os.exit(1)
	}
	o := code.ovls[0]
	if len(code.funcs) != 1 || code.funcs[0] != (core.Native_Func{0x80010000, u32(main_at)}) || len(code.ovls) != 1 ||
	   o.addr != ovl.addr || o.slot != ovl.slot || o.id != ovl.id || o.sig != ovl.sig || o.off != ovl.off {
		fmt.eprintln("blob tables do not round-trip:", code.funcs, code.ovls)
		os.exit(1)
	}
	run_main := cast(proc())rawptr(code.base + uintptr(code.funcs[0].off))
	run_early := cast(proc())rawptr(code.base + uintptr(code.ovls[0].off))

	failed := 0
	for v in VECTORS {
		x, y := v[0], v[1]
		state = {}
		state.w[IN0 / 4], state.w[IN1 / 4] = x, y
		c := cycles_of(x, y)
		state.w[CYCLES / 4], state.w[CYCLES / 4 + 1] = u32(c), u32(c >> 32)
		acc := u64(x) << 20
		state.w[ACC / 4], state.w[ACC / 4 + 1] = u32(acc), u32(acc >> 32)
		next = next_of(x, y)
		flags = flags_of(x, y)
		for &b, o in mem {b = mem_pat(o)}
		for &b, o in win {b = win_pat(o)}
		for &b, k in mem_pages {b = 1 if page_set(x, k) else 0}
		guard = {u8(y >> 24), u8(x >> 24) & 1}
		far = FAR
		far_wide = FAR_WIDE
		seen_ctx = 0
		context.user_index = 77
		run_main()
		run_early()
		// The end of a function writes the cached fields back.
		if state.w[IN0 / 4] != x || state.w[IN1 / 4] != y || state.w[CA / 4] != x || state.w[CB / 4] != 0xbeef {
			fmt.eprintfln("%08x %08x: cached fields not written back: %x", x, y, state.w[4:8])
			failed += 1
		}
		if seen_ctx != 77 {
			fmt.eprintfln("%08x %08x: called procedures got the wrong context", x, y)
			failed += 1
		}
		got_acc := u64(state.w[ACC / 4]) | u64(state.w[ACC / 4 + 1]) << 32
		if got_acc != acc + acc_add {
			fmt.eprintfln("%08x %08x: state_add64 gave %x, want %x", x, y, got_acc, acc + acc_add)
			failed += 1
		}
		for cs, k in cases {
			want := expect(cs, x, y)
			if cs.kind == .Any {continue}
			if got := state.w[FIRST + k]; got != want {
				if failed < 30 {
					fmt.eprintfln("%08x %08x: slot %d %v: got %08x, want %08x", x, y, FIRST + k, cs, got, want)
				}
				failed += 1
			}
		}
	}
	core.native_free(&code)
	// Map and free a small blob many times over; a failed munmap or
	// VirtualFree stops at the ensure in unmap_code.
	for _ in 0 ..< 1024 {
		core.unmap_code(core.map_code(blob[:16]), 16)
	}
	fmt.printfln("native %v: %d checks on %d inputs, %d bytes of code", arch, len(cases), len(VECTORS), len(blob))
	if failed != 0 {
		fmt.eprintfln("%d failed", failed)
		os.exit(1)
	}
}
