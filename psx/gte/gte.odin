// Geometry Transformation Engine (COP2).
//
// Register numbers follow MIPS: 0-31 are data registers, 32-63 control
// registers (control register n is passed as n+32). Accumulations are carried
// in i64 and range-checked once per sum, which matches hardware for every
// input that does not overflow an intermediate term.
package psx_gte

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:simd"
import cpu "../cpu"

// Called with each projected vertex when set (render/see_through.odin).
depth_tag: proc(x, y: i32, z: i64, sub: [2]i8)

// Sub-pixel steps per pixel in the GPU's Vertex.sx, sy.
SUB_PIXEL :: 16

Gte :: struct {
	v:      [3][3]i16, // V0..V2 xyz
	rgbc:   [4]u8,
	otz:    u16,
	ir:     [4]i32, // IR0..IR3, stored sign-extended 16-bit
	sxy:    [3][2]i32, // screen XY FIFO
	sz:     [4]u32, // screen Z FIFO
	rgb:    [3][4]u8, // color FIFO
	res1:   u32,
	mac:    [4]i32,
	lzcs:   u32,
	lzcr:   u32,
	rt:     [3][3]i32,
	llm:    [3][3]i32,
	lcm:    [3][3]i32,
	tr:     [3]i32,
	bk:     [3]i32,
	fc:     [3]i32,
	ofx:    i32,
	ofy:    i32,
	h:      u32,
	dqa:    i32,
	dqb:    i32,
	zsf3:   i32,
	zsf4:   i32,
	flag:   u32,
}

state: Gte

// The screen offset the GTE last projected with (OFX, OFY), in pixels.
gte_offset :: proc() -> [2]f64 {
	return {f64(state.ofx) / 0x10000, f64(state.ofy) / 0x10000}
}

// The way from the game's camera to an exact one, in view space: exact =
// m * view + t (view units). The game builds its view from whole angles,
// distances and a 4.12 matrix, so a turning or gliding camera moves the
// picture in uneven steps; the exact projection (the sub-pixel parts) takes
// this correction while it is set for the current vblank, and polygons sit
// where unrounded values put them. The whole pixels, all the game sees, stay
// the PS1's.
Exact_View :: struct {
	m:     [3][3]f64,
	t:     [3]f64,
	// The vblank the view was built in; 0 for none.
	stamp: u64,
}

exact_view: Exact_View

// The most whole pixels the correction moves a vertex from where the GTE put
// it; further means a view it was not made for.
@(private)
EXACT_SLACK :: 2

// Called on every write to the rotation or translation matrix (control
// registers 32-39) with the register and value; returns the value to store.
// A port can use it to blend matrices for smooth motion.
gte_matrix_filter: proc(r, v: u32) -> u32

@(private)
pack16 :: #force_inline proc(lo, hi: i32) -> u32 {
	return u32(u16(i16(lo))) | u32(u16(i16(hi))) << 16
}

@(private)
sext16 :: #force_inline proc(v: u32) -> i32 {
	return i32(i16(u16(v)))
}

@(private)
saturate5 :: #force_inline proc(v: i32) -> u32 {
	return u32(clamp(v >> 7, 0, 0x1f))
}

@(private)
matrix_read :: proc(m: ^[3][3]i32, k: u32) -> u32 {
	switch k {
	case 0:
		return pack16(m[0][0], m[0][1])
	case 1:
		return pack16(m[0][2], m[1][0])
	case 2:
		return pack16(m[1][1], m[1][2])
	case 3:
		return pack16(m[2][0], m[2][1])
	}
	return u32(m[2][2])
}

@(private)
matrix_write :: proc(m: ^[3][3]i32, k, v: u32) {
	lo, hi := sext16(v), sext16(v >> 16)
	switch k {
	case 0:
		m[0][0], m[0][1] = lo, hi
	case 1:
		m[0][2], m[1][0] = lo, hi
	case 2:
		m[1][1], m[1][2] = lo, hi
	case 3:
		m[2][0], m[2][1] = lo, hi
	case:
		m[2][2] = lo
	}
}

// The whole GTE state as bytes, for checks that run code twice from one
// state and compare what each leaves.
Gte_State :: [size_of(Gte)]u8

gte_save :: proc() -> Gte_State {return transmute(Gte_State)state}

gte_load :: proc(s: Gte_State) {state = transmute(Gte)s}

// GTE data register r, 0-27, the ones whose read is a field load. Recompiled
// code calls it with a constant r, and the switch folds away.
data_read :: #force_inline proc(r: u32) -> u32 #no_bounds_check {
	g := &state
	switch r {
	case 0, 2, 4:
		v := &g.v[r / 2]
		return pack16(i32(v[0]), i32(v[1]))
	case 1, 3, 5:
		return u32(i32(g.v[r / 2][2]))
	case 6:
		return transmute(u32)g.rgbc
	case 7:
		return u32(g.otz)
	case 8 ..= 11:
		return u32(g.ir[r - 8])
	case 12 ..= 14:
		return pack16(g.sxy[r - 12][0], g.sxy[r - 12][1])
	case 15:
		return pack16(g.sxy[2][0], g.sxy[2][1])
	case 16 ..= 19:
		return g.sz[r - 16]
	case 20 ..= 22:
		return transmute(u32)g.rgb[r - 20]
	case 23:
		return g.res1
	case 24 ..= 27:
		return u32(g.mac[r - 24])
	}
	return 0
}

gte_read :: proc(r: u32) -> u32 #no_bounds_check {
	when cpu.FALLBACK_COUNT {cpu.helper_calls[.Gte_Read][r & 63] += 1}
	if r < 28 {
		return data_read(r)
	}
	g := &state
	switch r {
	case 28, 29:
		return saturate5(g.ir[1]) | saturate5(g.ir[2]) << 5 | saturate5(g.ir[3]) << 10
	case 30:
		return g.lzcs
	case 31:
		return g.lzcr
	case 32 ..= 36:
		return matrix_read(&g.rt, r - 32)
	case 37 ..= 39:
		return u32(g.tr[r - 37])
	case 40 ..= 44:
		return matrix_read(&g.llm, r - 40)
	case 45 ..= 47:
		return u32(g.bk[r - 45])
	case 48 ..= 52:
		return matrix_read(&g.lcm, r - 48)
	case 53 ..= 55:
		return u32(g.fc[r - 53])
	case 56:
		return u32(g.ofx)
	case 57:
		return u32(g.ofy)
	case 58:
		// Hardware bug: H reads back sign-extended.
		return u32(sext16(g.h))
	case 59:
		return u32(g.dqa)
	case 60:
		return u32(g.dqb)
	case 61:
		return u32(g.zsf3)
	case 62:
		return u32(g.zsf4)
	case 63:
		return g.flag
	}
	return 0
}

@(private)
leading_count :: proc(v: u32) -> u32 {
	return intrinsics.count_leading_zeros(v & 0x80000000 != 0 ? ~v : v)
}

// GTE data register r = v, for r 0-27 but SXYP (15): the writes that are a
// field store. Recompiled code calls it with a constant r, and the switch
// folds away.
data_write :: #force_inline proc(r, v: u32) #no_bounds_check {
	g := &state
	switch r {
	case 0, 2, 4:
		// One store for x and y: two half stores cannot forward to the
		// word loads of both that follow (little-endian, x in the low half).
		intrinsics.volatile_store((^u32)(&g.v[r / 2][0]), v)
	case 1, 3, 5:
		g.v[r / 2][2] = i16(v)
	case 6:
		g.rgbc = transmute([4]u8)v
	case 7:
		g.otz = u16(v)
	case 8 ..= 11:
		g.ir[r - 8] = sext16(v)
	case 12 ..= 14:
		g.sxy[r - 12] = {sext16(v), sext16(v >> 16)}
	case 16 ..= 19:
		g.sz[r - 16] = v & 0xffff
	case 20 ..= 22:
		g.rgb[r - 20] = transmute([4]u8)v
	case 23:
		g.res1 = v
	case 24 ..= 27:
		g.mac[r - 24] = i32(v)
	}
}

gte_write :: proc(r, v: u32) #no_bounds_check {
	when cpu.FALLBACK_COUNT {cpu.helper_calls[.Gte_Write][r & 63] += 1}
	if r < 28 && r != 15 {
		data_write(r, v)
		return
	}
	g := &state
	v := v
	if r >= 32 && r <= 39 && gte_matrix_filter != nil {
		v = gte_matrix_filter(r, v)
	}
	switch r {
	case 15:
		g.sxy[0] = g.sxy[1]
		g.sxy[1] = g.sxy[2]
		g.sxy[2] = {sext16(v), sext16(v >> 16)}
	case 28:
		g.ir[1] = i32(v & 0x1f) << 7
		g.ir[2] = i32((v >> 5) & 0x1f) << 7
		g.ir[3] = i32((v >> 10) & 0x1f) << 7
	case 30:
		g.lzcs = v
		g.lzcr = leading_count(v)
	case 29, 31:
	// read-only
	case 32 ..= 36:
		matrix_write(&g.rt, r - 32, v)
	case 37 ..= 39:
		g.tr[r - 37] = i32(v)
	case 40 ..= 44:
		matrix_write(&g.llm, r - 40, v)
	case 45 ..= 47:
		g.bk[r - 45] = i32(v)
	case 48 ..= 52:
		matrix_write(&g.lcm, r - 48, v)
	case 53 ..= 55:
		g.fc[r - 53] = i32(v)
	case 56:
		g.ofx = i32(v)
	case 57:
		g.ofy = i32(v)
	case 58:
		g.h = v & 0xffff
	case 59:
		g.dqa = sext16(v)
	case 60:
		g.dqb = i32(v)
	case 61:
		g.zsf3 = sext16(v)
	case 62:
		g.zsf4 = sext16(v)
	case 63:
		g.flag = v & 0x7ffff000
		if g.flag & 0x7f87e000 != 0 {
			g.flag |= 0x80000000
		}
	}
}

// ---------------------------------------------------------------- arithmetic

@(private)
MAC_MAX :: i64(0x7ffffffffff)
@(private)
MAC_MIN :: -i64(0x80000000000)

// Set FLAG bits with a whole-word store. LLVM would narrow
// `state.flag |= 1 << k` to a one-byte OR, and gte_cmd's word load of FLAG
// right after cannot be forwarded from narrower stores: it stalls until they
// reach the cache.
@(private)
flag_set :: #force_inline proc(bits: u32) {
	intrinsics.volatile_store(&state.flag, state.flag | bits)
}

// MAC1-3 and IR1-3 follow Mednafen and DuckStation, which agree and are
// checked against hardware tests; psx-spx leaves both points open. A sum is
// range-checked after every addition and wrapped to 44 bits each time
// (mac_sum; a sum of two terms needs only the one check), and IR saturates
// from the 32-bit MAC, not from the 44-bit sum shifted (set_mac).

// Range-check a MAC1-3 sum against 44 bits and return it wrapped to 44 bits.
@(private)
check_mac :: proc(i: int, v: i64) -> i64 #no_bounds_check {
	if v > MAC_MAX {
		flag_set(1 << u32(31 - i))
	} else if v < MAC_MIN {
		flag_set(1 << u32(28 - i))
	}
	return (v << 20) >> 20
}

// t + a + b + c for MAC i, checked and wrapped after each addition (t, a
// translation << 12, needs no check of its own).
@(private)
mac_sum :: #force_inline proc(i: int, t, a, b, c: i64) -> i64 #no_bounds_check {
	return check_mac(i, check_mac(i, check_mac(i, t + a) + b) + c)
}

// Set MAC i from a sum and return it, the 32-bit value IR saturates from.
@(private)
set_mac :: proc(i: int, v: i64, shift: u32) -> i64 #no_bounds_check {
	state.mac[i] = i32(check_mac(i, v) >> shift)
	return i64(state.mac[i])
}

@(private)
set_ir :: proc(i: int, v: i64, lm: bool) #no_bounds_check {
	lo: i64 = lm ? 0 : -0x8000
	switch {
	case v < lo:
		flag_set(1 << u32(25 - i))
		state.ir[i] = i32(lo)
	case v > 0x7fff:
		flag_set(1 << u32(25 - i))
		state.ir[i] = 0x7fff
	case:
		state.ir[i] = i32(v)
	}
}

@(private)
set_mac0 :: proc(v: i64) {
	if v > 0x7fffffff {
		flag_set(1 << 16)
	} else if v < -0x80000000 {
		flag_set(1 << 15)
	}
	state.mac[0] = i32(v)
}

@(private)
set_ir0 :: proc(v: i64) {
	switch {
	case v < 0:
		flag_set(1 << 12)
		state.ir[0] = 0
	case v > 0x1000:
		flag_set(1 << 12)
		state.ir[0] = 0x1000
	case:
		state.ir[0] = i32(v)
	}
}

@(private)
push_sz :: proc(v: i64) #no_bounds_check {
	g := &state
	g.sz[0], g.sz[1], g.sz[2] = g.sz[1], g.sz[2], g.sz[3]
	switch {
	case v < 0:
		flag_set(1 << 18)
		g.sz[3] = 0
	case v > 0xffff:
		flag_set(1 << 18)
		g.sz[3] = 0xffff
	case:
		g.sz[3] = u32(v)
	}
}

@(private)
clamp_flag :: proc(v: i64, lo, hi: i64, bit: u32) -> i32 {
	if v < lo {
		flag_set(1 << bit)
		return i32(lo)
	}
	if v > hi {
		flag_set(1 << bit)
		return i32(hi)
	}
	return i32(v)
}

@(private)
push_sxy :: proc(x, y: i64) {
	g := &state
	g.sxy[0] = g.sxy[1]
	g.sxy[1] = g.sxy[2]
	g.sxy[2] = {clamp_flag(x, -0x400, 0x3ff, 14), clamp_flag(y, -0x400, 0x3ff, 13)}
}

@(private)
push_color :: proc() #no_bounds_check {
	g := &state
	c: [4]u8
	c[0] = u8(clamp_flag(i64(g.mac[1] >> 4), 0, 0xff, 21))
	c[1] = u8(clamp_flag(i64(g.mac[2] >> 4), 0, 0xff, 20))
	c[2] = u8(clamp_flag(i64(g.mac[3] >> 4), 0, 0xff, 19))
	c[3] = g.rgbc[3]
	g.rgb[0], g.rgb[1], g.rgb[2] = g.rgb[1], g.rgb[2], c
}

@(private)
unr_table: [257]u8

@(private, init)
unr_init :: proc "contextless" () {
	for i in 0 ..< 257 {
		unr_table[i] = u8(max(0, (0x40000 / (i + 0x100) + 1) / 2 - 0x101))
	}
}

// Unsigned Newton-Raphson division used by RTPS/RTPT:
// (H * 0x20000 / SZ3 + 1) / 2. Overflow sets bit 17 of `flag`.
@(private)
gte_divide :: proc(h, sz: u32, flag: ^u32) -> u32 #no_bounds_check {
	if h >= sz * 2 {
		flag^ |= 1 << 17
		return 0x1ffff
	}
	// SZ3 is 16 bits and not 0 here (h >= 0 = sz * 2 returned above).
	assert(sz <= 0xffff, "SZ3 wider than 16 bits")
	z := intrinsics.count_leading_zeros(sz) - 16
	n := u64(h) << z
	d := u64(sz) << z
	u := u64(unr_table[(d - 0x7fc0) >> 7]) + 0x101
	d = (0x2000080 - d * u) >> 8
	d = (0x0000080 + d * u) >> 8
	return u32(min(0x1ffff, (n * d + 0x8000) >> 16))
}

@(private)
Cmd :: struct {
	shift: u32,
	lm:    bool,
}

@(private)
rtp :: #force_inline proc(c: Cmd) #no_bounds_check {
	g := &state
	v := g.v[0]
	vx, vy, vz := i64(v[0]), i64(v[1]), i64(v[2])
	m := &g.rt
	xfull := i64(g.tr[0]) << 12 + i64(m[0][0]) * vx + i64(m[0][1]) * vy + i64(m[0][2]) * vz
	yfull := i64(g.tr[1]) << 12 + i64(m[1][0]) * vx + i64(m[1][1]) * vy + i64(m[1][2]) * vz
	x := set_mac(1, mac_sum(1, i64(g.tr[0]) << 12, i64(m[0][0]) * vx, i64(m[0][1]) * vy, i64(m[0][2]) * vz), c.shift)
	y := set_mac(2, mac_sum(2, i64(g.tr[1]) << 12, i64(m[1][0]) * vx, i64(m[1][1]) * vy, i64(m[1][2]) * vz), c.shift)
	zfull := mac_sum(3, i64(g.tr[2]) << 12, i64(m[2][0]) * vx, i64(m[2][1]) * vy, i64(m[2][2]) * vz)
	g.mac[3] = i32(zfull >> c.shift)
	set_ir(1, x, c.lm)
	set_ir(2, y, c.lm)
	// IR3 saturates on the shifted value but flags against the >>12 value.
	z12 := zfull >> 12
	saved := g.flag
	set_ir(3, i64(g.mac[3]), c.lm)
	g.flag = saved
	if z12 < -0x8000 || z12 > 0x7fff {
		flag_set(1 << 22)
	}
	push_sz(z12)
	over: u32
	q := i64(gte_divide(g.h, g.sz[3], &over))
	g.flag |= over
	sx := i64(g.ofx) + i64(g.ir[1]) * q
	sy := i64(g.ofy) + i64(g.ir[2]) * q
	set_mac0(sx)
	set_mac0(sy)
	push_sxy(sx >> 16, sy >> 16)
	// Depths serve see-through, perspective textures and the pictures and
	// backs waiting for the walk; the exact projection's sub-pixel part
	// steadies polygons (neither a PS1 feature).
	sub: [2]i8
	if zfull > 0 {
		at := f64(g.h) / f64(zfull)
		x, y := f64(g.ofx) / 0x10000 + f64(xfull) * at, f64(g.ofy) / 0x10000 + f64(yfull) * at
		sub = {sub_pixel(x, g.sxy[2][0]), sub_pixel(y, g.sxy[2][1])}
		if exact_on() && sub_fits(x, g.sxy[2][0]) && sub_fits(y, g.sxy[2][1]) {
			sub = exact_sub({f64(xfull), f64(yfull), f64(zfull)}, g.sxy[2])
		}
	}
	if depth_tag != nil {depth_tag(g.sxy[2][0], g.sxy[2][1], z12, sub)}
	d := i64(g.dqb) + i64(g.dqa) * q
	set_mac0(d)
	set_ir0(d >> 12)
}

// RTPT: rtp for V0..V2 side by side in lanes, lane 3 repeating V2 so the
// flag tests need no mask. Flags are ORs and the IR3 saturation sets none, so
// testing all lanes at once flags as the three rtp calls do; MAC and IR end
// as V2 leaves them. The divides and the depth tags run in vertex order.
@(private)
rtpt :: #force_inline proc(c: Cmd) #no_bounds_check {
	I :: #simd[4]i64
	U :: #simd[4]u64
	F :: #simd[4]f64
	g := &state
	m := &g.rt
	any :: #force_inline proc(v: U) -> bool {return simd.reduce_or(v) != 0}
	out :: #force_inline proc(v: I, lo, hi: i64) -> bool {
		return any(simd.lanes_lt(v, I(lo)) | simd.lanes_gt(v, I(hi)))
	}
	bit :: #force_inline proc(on: bool, n: u32) -> u32 {return u32(on) << n}
	wrap :: #force_inline proc(i: u32, v: I, flag: ^u32) -> I {
		flag^ |= bit(any(simd.lanes_gt(v, I(MAC_MAX))), 31 - i) | bit(any(simd.lanes_lt(v, I(MAC_MIN))), 28 - i)
		return simd.shr(simd.shl(v, U(20)), U(20))
	}
	// Gathered here and stored once: single-bit stores into state.flag stall
	// gte_cmd's word load of it (no store forwarding from narrower stores).
	flag: u32
	// One load per i16: gte_write just stored them as halves, and a vector
	// load spanning several narrower stores cannot be forwarded from them.
	e :: #force_inline proc(v: ^i16) -> i64 {return i64(intrinsics.volatile_load(v))}
	vx := I{e(&g.v[0][0]), e(&g.v[1][0]), e(&g.v[2][0]), e(&g.v[2][0])}
	vy := I{e(&g.v[0][1]), e(&g.v[1][1]), e(&g.v[2][1]), e(&g.v[2][1])}
	vz := I{e(&g.v[0][2]), e(&g.v[1][2]), e(&g.v[2][2]), e(&g.v[2][2])}
	full: [3]I
	for r in 0 ..< 3 {
		full[r] = I(i64(g.tr[r]) << 12) + I(i64(m[r][0])) * vx + I(i64(m[r][1])) * vy + I(i64(m[r][2])) * vz
	}
	// mac_sum and set_mac by lane: checked and wrapped after each addition,
	// IR1 and IR2 from the 32-bit MACs.
	sum: [3]I
	for r in 0 ..< 3 {
		a := wrap(u32(r + 1), I(i64(g.tr[r]) << 12) + I(i64(m[r][0])) * vx, &flag)
		a = wrap(u32(r + 1), a + I(i64(m[r][1])) * vy, &flag)
		sum[r] = wrap(u32(r + 1), a + I(i64(m[r][2])) * vz, &flag)
	}
	shift := U(u64(c.shift))
	low32 :: #force_inline proc(v: I) -> I {return simd.shr(simd.shl(v, U(32)), U(32))}
	x := low32(simd.shr(sum[0], shift))
	y := low32(simd.shr(sum[1], shift))
	zfull := sum[2]
	lo: i64 = c.lm ? 0 : -0x8000
	flag |= bit(out(x, lo, 0x7fff), 24)
	flag |= bit(out(y, lo, 0x7fff), 23)
	ir1 := simd.clamp(x, I(lo), I(0x7fff))
	ir2 := simd.clamp(y, I(lo), I(0x7fff))
	g.mac[1], g.mac[2] = i32(simd.extract(x, 2)), i32(simd.extract(y, 2))
	g.mac[3] = i32(simd.extract(zfull, 2) >> c.shift)
	g.ir[1], g.ir[2] = i32(simd.extract(ir1, 2)), i32(simd.extract(ir2, 2))
	g.ir[3] = i32(clamp(i64(g.mac[3]), lo, 0x7fff))
	z12 := simd.shr(zfull, U(12))
	flag |= bit(out(z12, -0x8000, 0x7fff), 22)
	flag |= bit(out(z12, 0, 0xffff), 18)
	sz := simd.clamp(z12, I(0), I(0xffff))
	g.sz[0] = g.sz[3]
	q: I
	for k in 0 ..< 3 {
		g.sz[k + 1] = u32(simd.extract(sz, k))
		q = simd.replace(q, k, i64(gte_divide(g.h, g.sz[k + 1], &flag)))
	}
	q = simd.replace(q, 3, simd.extract(q, 2))
	sx := I(i64(g.ofx)) + ir1 * q
	sy := I(i64(g.ofy)) + ir2 * q
	flag |= bit(any(simd.lanes_gt(sx, I(0x7fffffff)) | simd.lanes_gt(sy, I(0x7fffffff))), 16)
	flag |= bit(any(simd.lanes_lt(sx, I(-0x80000000)) | simd.lanes_lt(sy, I(-0x80000000))), 15)
	sx = simd.shr(sx, U(16))
	sy = simd.shr(sy, U(16))
	flag |= bit(out(sx, -0x400, 0x3ff), 14)
	flag |= bit(out(sy, -0x400, 0x3ff), 13)
	sx = simd.clamp(sx, I(-0x400), I(0x3ff))
	sy = simd.clamp(sy, I(-0x400), I(0x3ff))
	// Sub-pixel parts as in rtp, all three divides in one go; lanes with no
	// depth divide by 1 and take 0.
	near := simd.lanes_gt(zfull, I(0))
	at := F(f64(g.h)) / simd.select(near, cast(F)zfull, F(1))
	sub_lanes :: #force_inline proc(at: F, whole: I, near: U) -> (I, U) {
		d := at - cast(F)whole
		ok := near & simd.lanes_ge(d, F(-0.1)) & simd.lanes_le(d, F(1.1))
		d = simd.clamp(d, F(-0.1), F(1.1))
		s := simd.clamp(cast(I)(d * SUB_PIXEL + 0.5), I(0), I(SUB_PIXEL - 1))
		return simd.select(ok, s, I(0)), ok
	}
	subx, okx := sub_lanes(F(f64(g.ofx) / 0x10000) + cast(F)full[0] * at, sx, near)
	suby, oky := sub_lanes(F(f64(g.ofy) / 0x10000) + cast(F)full[1] * at, sy, near)
	if exact_on() {
		// Lanes the plain projection gave up on (saturation) stay at 0.
		e := &exact_view
		fx, fy, fz := cast(F)full[0], cast(F)full[1], cast(F)full[2]
		v: [3]F
		for r in 0 ..< 3 {
			v[r] = F(e.m[r][0]) * fx + F(e.m[r][1]) * fy + F(e.m[r][2]) * fz + F(e.t[r] * 0x1000)
		}
		ok := okx & oky & simd.lanes_gt(v[2], F(0))
		ate := F(f64(g.h)) / simd.select(ok, v[2], F(1))
		lanes :: #force_inline proc(at: F, whole, plain: I, ok: U) -> I {
			d := simd.clamp(at - cast(F)whole, F(-EXACT_SLACK), F(1 + EXACT_SLACK))
			return simd.select(ok, cast(I)simd.floor(d * SUB_PIXEL + 0.5), plain)
		}
		subx = lanes(F(f64(g.ofx) / 0x10000) + v[0] * ate, sx, subx, ok)
		suby = lanes(F(f64(g.ofy) / 0x10000) + v[1] * ate, sy, suby, ok)
	}
	for k in 0 ..< 3 {
		g.sxy[k] = {i32(simd.extract(sx, k)), i32(simd.extract(sy, k))}
	}
	for k in 0 ..< 3 {
		sub := [2]i8{i8(simd.extract(subx, k)), i8(simd.extract(suby, k))}
		if depth_tag != nil {depth_tag(g.sxy[k][0], g.sxy[k][1], simd.extract(z12, k), sub)}
	}
	d := i64(g.dqb) + i64(g.dqa) * simd.extract(q, 2)
	flag |= bit(d > 0x7fffffff, 16) | bit(d < -0x80000000, 15)
	g.mac[0] = i32(d)
	d12 := d >> 12
	flag |= bit(d12 < 0 || d12 > 0x1000, 12)
	g.ir[0] = i32(clamp(d12, 0, 0x1000))
	g.flag |= flag
}

// The sixteenths of a pixel the exact screen coordinate `at` lies past the
// whole pixel `whole` the GTE produced; 0 when they disagree by more than
// rounding (saturation, a divide overflow).
@(private)
sub_pixel :: proc(at: f64, whole: i32) -> i8 {
	d := at - f64(whole)
	if d < -0.1 || d > 1.1 {
		return 0
	}
	return i8(clamp(i32(d * SUB_PIXEL + 0.5), 0, SUB_PIXEL - 1))
}

// The sixteenths of a pixel past `whole` the view space point `full` (MAC,
// view units << 12) projects to, by the exact view when on: a sprite's
// anchor, which the game projected to `whole` and builds the corners from
// with offsets the CPU works out, so no vertex of it reaches depth_tag
// (a port's own sprite drawing). Its whole pixel need not be
// the one this projection rounds to (the game's point and divide differ a
// little), so the part is taken as far as EXACT_SLACK either way.
anchor_sub :: proc(full: [3]f64, whole: [2]i32) -> (sub: [2]i8) {
	g := &state
	if exact_on() {
		return exact_sub(full, whole)
	}
	if full[2] <= 0 {
		return
	}
	at := f64(g.h) / full[2]
	of := [2]f64{f64(g.ofx), f64(g.ofy)} / 0x10000
	for k in 0 ..< 2 {
		d := clamp(of[k] + full[k] * at - f64(whole[k]), -EXACT_SLACK, 1 + EXACT_SLACK)
		sub[k] = i8(math.floor(d * SUB_PIXEL + 0.5))
	}
	return
}

// Whether the exact screen coordinate `at` agrees with the GTE's whole pixel
// (sub_pixel).
@(private)
sub_fits :: #force_inline proc(at: f64, whole: i32) -> bool {
	d := at - f64(whole)
	return d >= -0.1 && d <= 1.1
}

// The exact view applies to projections made in the vblank it was built in
// or the next (a frame's drawing can run past a vblank).
exact_on :: #force_inline proc() -> bool {
	s := exact_view.stamp
	return s != 0 && cpu.presents - s <= 1
}

// The sixteenths of a pixel past `whole` the exact view puts the vertex the
// GTE saw at `full` (MAC, view units << 12), which may be negative or past
// a pixel: the camera moved it by up to EXACT_SLACK pixels.
@(private)
exact_sub :: proc(full: [3]f64, whole: [2]i32) -> (sub: [2]i8) {
	g := &state
	e := &exact_view
	v: [3]f64
	for r in 0 ..< 3 {
		v[r] = e.m[r][0] * full[0] + e.m[r][1] * full[1] + e.m[r][2] * full[2] + e.t[r] * 0x1000
	}
	if v[2] <= 0 {
		return
	}
	at := f64(g.h) / v[2]
	of := [2]f64{f64(g.ofx), f64(g.ofy)} / 0x10000
	for k in 0 ..< 2 {
		d := clamp(of[k] + v[k] * at - f64(whole[k]), -EXACT_SLACK, 1 + EXACT_SLACK)
		sub[k] = i8(math.floor(d * SUB_PIXEL + 0.5))
	}
	return
}

// [MAC1..3] = M * vec + (t << 12), then IR = MAC (saturated).
@(private)
mat_vec :: proc(c: Cmd, m: ^[3][3]i32, vec: [3]i64, t: [3]i64) #no_bounds_check {
	for i in 0 ..< 3 {
		s := mac_sum(i + 1, t[i] << 12, i64(m[i][0]) * vec[0], i64(m[i][1]) * vec[1], i64(m[i][2]) * vec[2])
		set_ir(i + 1, set_mac(i + 1, s, c.shift), c.lm)
	}
}

@(private)
ir_vec :: proc() -> [3]i64 {
	return {i64(state.ir[1]), i64(state.ir[2]), i64(state.ir[3])}
}

// MAC = MAC + (FC - MAC) * IR0, with MAC holding values pre-scaled by 1<<12.
@(private)
interpolate :: proc(c: Cmd, m: [3]i64) #no_bounds_check {
	g := &state
	for i in 0 ..< 3 {
		set_ir(i + 1, set_mac(i + 1, i64(g.fc[i]) << 12 - m[i], c.shift), false)
	}
	for i in 0 ..< 3 {
		set_ir(i + 1, set_mac(i + 1, i64(g.ir[i + 1]) * i64(g.ir[0]) + m[i], c.shift), c.lm)
	}
	push_color()
}

@(private)
color_scaled :: proc() -> [3]i64 {
	g := &state
	return {
		(i64(g.rgbc[0]) * i64(g.ir[1])) << 4,
		(i64(g.rgbc[1]) * i64(g.ir[2])) << 4,
		(i64(g.rgbc[2]) * i64(g.ir[3])) << 4,
	}
}

@(private)
Light_Tail :: enum {
	None,  // NCS: color from lighting
	Color, // NCC/CC: multiply by RGBC
	Depth, // NCD/CDP: multiply by RGBC and depth-cue
}

@(private)
light_color :: proc(c: Cmd, tail: Light_Tail) {
	g := &state
	mat_vec(c, &g.lcm, ir_vec(), {i64(g.bk[0]), i64(g.bk[1]), i64(g.bk[2])})
	switch tail {
	case .None:
		push_color()
	case .Color:
		m := color_scaled()
		for i in 0 ..< 3 {
			set_ir(i + 1, set_mac(i + 1, m[i], c.shift), c.lm)
		}
		push_color()
	case .Depth:
		interpolate(c, color_scaled())
	}
}

@(private)
light_vertex :: proc(c: Cmd, n: int, tail: Light_Tail) #no_bounds_check {
	g := &state
	v := g.v[n]
	mat_vec(c, &g.llm, {i64(v[0]), i64(v[1]), i64(v[2])}, {})
	light_color(c, tail)
}

@(private)
mvmva :: #force_inline proc(c: Cmd, cmd: u32) #no_bounds_check {
	g := &state
	m: ^[3][3]i32
	garbage: [3][3]i32
	switch (cmd >> 17) & 3 {
	case 0:
		m = &g.rt
	case 1:
		m = &g.llm
	case 2:
		m = &g.lcm
	case:
		r := i32(g.rgbc[0]) << 4
		garbage = {{-r, r, g.ir[0]}, {g.rt[0][2], g.rt[0][2], g.rt[0][2]}, {g.rt[1][1], g.rt[1][1], g.rt[1][1]}}
		m = &garbage
	}
	vec: [3]i64
	switch (cmd >> 15) & 3 {
	case 3:
		vec = ir_vec()
	case:
		v := g.v[(cmd >> 15) & 3]
		vec = {i64(v[0]), i64(v[1]), i64(v[2])}
	}
	t: [3]i64
	switch (cmd >> 13) & 3 {
	case 0:
		t = {i64(g.tr[0]), i64(g.tr[1]), i64(g.tr[2])}
	case 1:
		t = {i64(g.bk[0]), i64(g.bk[1]), i64(g.bk[2])}
	case 2:
		// FC translation is bugged on hardware; only the last column survives.
		for i in 0 ..< 3 {
			set_ir(i + 1, set_mac(i + 1, i64(g.fc[i]) << 12 + i64(m[i][0]) * vec[0], c.shift), false)
			set_ir(i + 1, set_mac(i + 1, i64(m[i][1]) * vec[1] + i64(m[i][2]) * vec[2], c.shift), c.lm)
		}
		return
	}
	mat_vec(c, m, vec, t)
}

@(private)
avsz :: proc(scale: i32, sum: i64) {
	g := &state
	v := i64(scale) * sum
	set_mac0(v)
	g.otz = u16(clamp_flag(v >> 12, 0, 0xffff, 18))
}

// Unknown commands already reported, by function field: a set of their own,
// as cpu.report_once's is keyed by RAM address.
@(private = "file")
unknown_reported: [64]bool

// NCLIP, AVSZ3 and AVSZ4 whole, FLAG included: small commands that use
// neither the shift nor the lm bit, for the Odin output to inline in place
// of a gte_cmd call.
cmd_nclip :: #force_inline proc() {
	state.flag = 0
	nclip()
	flag_sum()
}

cmd_avsz3 :: #force_inline proc() {
	state.flag = 0
	avsz(state.zsf3, i64(state.sz[1]) + i64(state.sz[2]) + i64(state.sz[3]))
	flag_sum()
}

cmd_avsz4 :: #force_inline proc() {
	state.flag = 0
	avsz(state.zsf4, i64(state.sz[0]) + i64(state.sz[1]) + i64(state.sz[2]) + i64(state.sz[3]))
	flag_sum()
}

// RTPS, RTPT and MVMVA whole, FLAG included: commands recompiled code runs
// often but too large to inline, so the Odin output calls them directly in
// place of gte_cmd (no switch, no helper count). gte_cmd runs them through
// these too, the only copy of each.
cmd_rtps :: proc(cmd: u32) #no_bounds_check {
	state.flag = 0
	rtp(cmd_fields(cmd))
	flag_sum()
}

cmd_rtpt :: proc(cmd: u32) #no_bounds_check {
	state.flag = 0
	rtpt(cmd_fields(cmd))
	flag_sum()
}

cmd_mvmva :: proc(cmd: u32) #no_bounds_check {
	state.flag = 0
	mvmva(cmd_fields(cmd), cmd)
	flag_sum()
}

@(private)
cmd_fields :: #force_inline proc(cmd: u32) -> Cmd {
	return {shift = ((cmd >> 19) & 1) * 12, lm = (cmd >> 10) & 1 != 0}
}

@(private)
nclip :: #force_inline proc() {
	s := &state.sxy
	n :=
		i64(s[0][0]) * i64(s[1][1]) + i64(s[1][0]) * i64(s[2][1]) + i64(s[2][0]) * i64(s[0][1]) -
		i64(s[0][0]) * i64(s[2][1]) - i64(s[1][0]) * i64(s[0][1]) - i64(s[2][0]) * i64(s[1][1])
	set_mac0(n)
}

// FLAG bit 31: set when any of its error bits is.
@(private)
flag_sum :: #force_inline proc() {
	if state.flag & 0x7f87e000 != 0 {
		state.flag |= 0x80000000
	}
}

gte_cmd :: proc(cmd: u32) #no_bounds_check {
	when cpu.FALLBACK_COUNT {cpu.helper_calls[.Gte_Cmd][cmd & 0x3f] += 1}
	g := &state
	c := cmd_fields(cmd)
	g.flag = 0
	switch cmd & 0x3f {
	case 0x01:
		cmd_rtps(cmd)
	case 0x30:
		cmd_rtpt(cmd)
	case 0x06:
		nclip()
	case 0x0c:
		d1, d2, d3 := i64(g.rt[0][0]), i64(g.rt[1][1]), i64(g.rt[2][2])
		i1, i2, i3 := i64(g.ir[1]), i64(g.ir[2]), i64(g.ir[3])
		set_ir(1, set_mac(1, i3 * d2 - i2 * d3, c.shift), c.lm)
		set_ir(2, set_mac(2, i1 * d3 - i3 * d1, c.shift), c.lm)
		set_ir(3, set_mac(3, i2 * d1 - i1 * d2, c.shift), c.lm)
	case 0x10:
		interpolate(c, {i64(g.rgbc[0]) << 16, i64(g.rgbc[1]) << 16, i64(g.rgbc[2]) << 16})
	case 0x2a:
		for _ in 0 ..< 3 {
			c0 := g.rgb[0]
			interpolate(c, {i64(c0[0]) << 16, i64(c0[1]) << 16, i64(c0[2]) << 16})
		}
	case 0x11:
		iv := ir_vec()
		interpolate(c, {iv[0] << 12, iv[1] << 12, iv[2] << 12})
	case 0x29:
		interpolate(c, color_scaled())
	case 0x12:
		cmd_mvmva(cmd)
	case 0x13:
		light_vertex(c, 0, .Depth)
	case 0x16:
		for n in 0 ..< 3 {light_vertex(c, n, .Depth)}
	case 0x1b:
		light_vertex(c, 0, .Color)
	case 0x3f:
		for n in 0 ..< 3 {light_vertex(c, n, .Color)}
	case 0x1e:
		light_vertex(c, 0, .None)
	case 0x20:
		for n in 0 ..< 3 {light_vertex(c, n, .None)}
	case 0x1c:
		light_color(c, .Color)
	case 0x14:
		light_color(c, .Depth)
	case 0x28:
		iv := ir_vec()
		for i in 0 ..< 3 {
			set_ir(i + 1, set_mac(i + 1, iv[i] * iv[i], c.shift), c.lm)
		}
	case 0x2d:
		avsz(g.zsf3, i64(g.sz[1]) + i64(g.sz[2]) + i64(g.sz[3]))
	case 0x2e:
		avsz(g.zsf4, i64(g.sz[0]) + i64(g.sz[1]) + i64(g.sz[2]) + i64(g.sz[3]))
	case 0x3d:
		iv := ir_vec()
		for i in 0 ..< 3 {
			set_ir(i + 1, set_mac(i + 1, i64(g.ir[0]) * iv[i], c.shift), c.lm)
		}
		push_color()
	case 0x3e:
		iv := ir_vec()
		for i in 0 ..< 3 {
			set_ir(i + 1, set_mac(i + 1, i64(g.mac[i + 1]) << c.shift + i64(g.ir[0]) * iv[i], c.shift), c.lm)
		}
		push_color()
	case:
		if k := cmd & 0x3f; !unknown_reported[k] {
			unknown_reported[k] = true
			fmt.eprintfln("gte: unknown command %#02x (ra %#08x) at present %d", k, cpu.state.r[31], cpu.presents)
		}
	}
	flag_sum()
}
