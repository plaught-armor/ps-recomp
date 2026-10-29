// Vector units: register files, memories, and VU0 macro mode (COP2
// instructions issued by the EE).
//
// VU floats are IEEE singles without infinities or NaNs, clamped like the
// FPU. MAC/status flags are not tracked yet.
package ps2_vu

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:simd"
import "core:slice"
import "ps:core"
import cpu "../cpu"
import gif "../gif"

Vf :: struct #raw_union {
	q: u128,
	f: [4]f32,
	u: [4]u32,
	i: [4]i32,
}

Vu :: struct {
	vf:     [32]Vf,
	vi:     [16]u16,
	acc:    Vf,
	q, p:   f32,
	i:      f32,
	r:      u32,
	clip:   u32,
	status: u32,
	mac:    u32,
	fbrst:  u32,
	tpc:    u32,
	cmsar:  u32,
	mem:    []u8,
	micro:  []u8,
}

vu0, vu1: Vu
// Data memory sizes in bytes. The recompiler's code wraps addresses with them.
VU0_MEM :: 4 << 10
VU1_MEM :: 16 << 10
// Not private: native code addresses it through import "vu.mem".
vu0_mem: [VU0_MEM]u8
@(private)
vu0_micro: [4 << 10]u8
@(private)
vu1_mem: [VU1_MEM]u8
@(private)
vu1_micro: [16 << 10]u8

vu_init :: proc() {
	vu0.mem, vu0.micro = vu0_mem[:], vu0_micro[:]
	vu1.mem, vu1.micro = vu1_mem[:], vu1_micro[:]
	for v in ([]^Vu{&vu0, &vu1}) {
		v.vf[0].f = {0, 0, 0, 1}
	}
	vif_init()
	vu_options()
}

// EE mapping of VU memories: 0x11000000 micro0, 0x11004000 mem0,
// 0x11008000 micro1, 0x1100c000 mem1.
vu_mem_addr :: proc(a: u32) -> rawptr {
	if a < 0x11000000 || a >= 0x11010000 {return nil}
	o := a & 0x3fff
	switch (a >> 14) & 3 {
	case 0:
		if o >= len(vu0_micro) {return nil}
		vu0_micro_touch()
		return &vu0_micro[o]
	case 1: if o < VU0_MEM {return &vu0_mem[o]}
	case 2:
		vu1_micro_touch()
		return &vu1_micro[o]
	case 3: return &vu1_mem[o]
	}
	return nil
}

// n is a 5-bit register field; the mask keeps it in range unchecked.
vu0_set_vf :: proc(n: u8, v: u128) #no_bounds_check {
	if n != 0 {vu0.vf[n & 31].q = v}
}

vu0_ctrl_read :: proc(n: u8) -> u32 {
	switch n {
	case 0 ..< 16: return u32(vu0.vi[n])
	case 16: return vu0.status
	case 17: return vu0.mac
	case 18: return vu0.clip
	case 20: return vu0.r
	case 21: return transmute(u32)vu0.i
	case 22: return transmute(u32)vu0.q
	case 26: return vu0.tpc
	case 27: return vu0.cmsar
	case 28: return vu0.fbrst
	case 29: return 0 // VPU-STAT: both VUs idle
	case 31: return vu1.cmsar
	}
	return 0
}

vu0_ctrl_write :: proc(n: u8, v: u32) {
	switch n {
	case 1 ..< 16: vu0.vi[n] = u16(v)
	case 16: vu0.status = v
	case 18: vu0.clip = v
	case 20: vu0.r = v & 0x7fffff
	case 21: vu0.i = transmute(f32)v
	case 22: vu0.q = transmute(f32)v
	case 27: vu0.cmsar = v
	case 28: vu0.fbrst = v
	case 31: vu1_start(v)
	}
}

@(private)
vclamp :: #force_inline proc(x: f32) -> f32 {return cpu.fclamp(x)}
@(private)
vclamp4 :: #force_inline proc(r: [4]f32) -> [4]f32 {return {vclamp(r.x), vclamp(r.y), vclamp(r.z), vclamp(r.w)}}

// VU0 macro instruction (COP2 with CO set).
vu0_macro :: proc(w: u32) {
	when cpu.FALLBACK_COUNT {cpu.fallback_vu0[cpu.cop2_key(w)] += 1}
	vu_op(&vu0, w)
}

// One operation in COP2 layout. Macro instructions, micro-mode upper
// words and micro-mode lower words with opcode 0x40 share this encoding:
// fn 0x00-0x2f and special 0x00-0x2f are upper ops, fn 0x30-0x3b and
// special 0x30-0x7f lower ops.
// No bounds checks here or in its nested procs: keep every index masked to
// its array's length (&31, &15, &3), constant, a 0/1 select, or bounded by
// a 0 ..< 4 loop.
vu_op :: proc(v: ^Vu, w: u32) #no_bounds_check {
	dest := (w >> 21) & 15 // x = 8, y = 4, z = 2, w = 1
	ft := (w >> 16) & 31
	fs := (w >> 11) & 31
	fd := (w >> 6) & 31
	fn := w & 63
	bc := w & 3

	// Write lanes selected by dest and set the MAC flags from them.
	put :: proc(v: ^Vu, n: u32, dest: u32, r: [4]f32) #no_bounds_check {
		dst := n == 0 ? nil : &v.vf[n & 31]
		vu_put_flags(v, dst, dest, r)
	}
	put_acc :: proc(v: ^Vu, dest: u32, r: [4]f32) {
		vu_put_flags(v, &v.acc, dest, r)
	}
	// Write lanes without touching flags (ITOF, ABS, MFP).
	put_raw :: proc(v: ^Vu, n: u32, dest: u32, r: [4]f32) #no_bounds_check {
		if n == 0 {return}
		for k in 0 ..< 4 {
			if dest & (8 >> u32(k)) != 0 {v.vf[n & 31].f[k] = vclamp(r[k])}
		}
	}
	// Write words as they are, without touching flags (MAX, MINI).
	put_bits :: proc(v: ^Vu, n: u32, dest: u32, r: [4]u32) #no_bounds_check {
		if n == 0 {return}
		for k in 0 ..< 4 {
			if dest & (8 >> u32(k)) != 0 {v.vf[n & 31].u[k] = r[k]}
		}
	}
	s := v.vf[fs].f
	t := v.vf[ft].f
	// The add and multiply family's operands, clamped: the VU has no
	// infinities or NaNs, exponent 255 is just a large number, so two of
	// them multiply to the largest value with the xor of their signs. On
	// the host a NaN operand would leave the result to whichever NaN the
	// compiler happens to keep.
	cs, ct := vclamp4(s), vclamp4(t)
	cq, ci := vclamp(v.q), vclamp(v.i)
	su, tu, iu := v.vf[fs].u, v.vf[ft].u, transmute(u32)v.i
	splat :: proc(x: $T) -> [4]T {return {x, x, x, x}}

	if fn < 0x3c {
		switch fn {
		case 0x00 ..= 0x03: put(v, fd, dest, cs + splat(ct[bc]))
		case 0x04 ..= 0x07: put(v, fd, dest, cs - splat(ct[bc]))
		case 0x08 ..= 0x0b: put(v, fd, dest, v.acc.f + cs * splat(ct[bc]))
		case 0x0c ..= 0x0f: put(v, fd, dest, v.acc.f - cs * splat(ct[bc]))
		case 0x10 ..= 0x13: put_bits(v, fd, dest, vmax(su, splat(tu[bc])))
		case 0x14 ..= 0x17: put_bits(v, fd, dest, vmin(su, splat(tu[bc])))
		case 0x18 ..= 0x1b: put(v, fd, dest, cs * splat(ct[bc]))
		case 0x1c: put(v, fd, dest, cs * splat(cq))
		case 0x1d: put_bits(v, fd, dest, vmax(su, splat(iu)))
		case 0x1e: put(v, fd, dest, cs * splat(ci))
		case 0x1f: put_bits(v, fd, dest, vmin(su, splat(iu)))
		case 0x20: put(v, fd, dest, cs + splat(cq))
		case 0x21: put(v, fd, dest, v.acc.f + cs * splat(cq))
		case 0x22: put(v, fd, dest, cs + splat(ci))
		case 0x23: put(v, fd, dest, v.acc.f + cs * splat(ci))
		case 0x24: put(v, fd, dest, cs - splat(cq))
		case 0x25: put(v, fd, dest, v.acc.f - cs * splat(cq))
		case 0x26: put(v, fd, dest, cs - splat(ci))
		case 0x27: put(v, fd, dest, v.acc.f - cs * splat(ci))
		case 0x28: put(v, fd, dest, cs + ct)
		case 0x29: put(v, fd, dest, v.acc.f + cs * ct)
		case 0x2a: put(v, fd, dest, cs * ct)
		case 0x2b: put_bits(v, fd, dest, vmax(su, tu))
		case 0x2c: put(v, fd, dest, cs - ct)
		case 0x2d: put(v, fd, dest, v.acc.f - cs * ct)
		case 0x2e: // VOPMSUB: fd.xyz = acc - fs.yzx * ft.zxy
			r := v.acc.f - [4]f32{cs.y * ct.z, cs.z * ct.x, cs.x * ct.y, 0}
			put(v, fd, 0xe, r)
		case 0x2f: put_bits(v, fd, dest, vmin(su, tu))
		case 0x30: if fd != 0 {v.vi[fd & 15] = v.vi[fs & 15] + v.vi[ft & 15]}
		case 0x31: if fd != 0 {v.vi[fd & 15] = v.vi[fs & 15] - v.vi[ft & 15]}
		case 0x32: // VIADDI: imm5 in the fd field
			imm := u16(i16(i8(u8(fd) << 3) >> 3))
			if ft != 0 {v.vi[ft & 15] = v.vi[fs & 15] + imm}
		case 0x34: if fd != 0 {v.vi[fd & 15] = v.vi[fs & 15] & v.vi[ft & 15]}
		case 0x35: if fd != 0 {v.vi[fd & 15] = v.vi[fs & 15] | v.vi[ft & 15]}
		case 0x38: vu0_call_micro(((w >> 6) & 0x7fff) * 8)
		case 0x39: vu0_call_micro(u32(v.cmsar) * 8)
		case:
			cpu.fatal("vu%d: unknown op %08x", v == &vu1 ? 1 : 0, w)
		}
		return
	}

	fsf := (w >> 21) & 3
	ftf := (w >> 23) & 3
	is := fs & 15
	it := ft & 15
	switch ((w >> 4) & 0x7c) | (w & 3) {
	case 0x00 ..= 0x03: put_acc(v, dest, cs + splat(ct[bc]))
	case 0x04 ..= 0x07: put_acc(v, dest, cs - splat(ct[bc]))
	case 0x08 ..= 0x0b: put_acc(v, dest, v.acc.f + cs * splat(ct[bc]))
	case 0x0c ..= 0x0f: put_acc(v, dest, v.acc.f - cs * splat(ct[bc]))
	case 0x10 ..= 0x13: // ITOF0/4/12/15
		@(static, rodata) itof_scale := [4]f32{1, 1.0 / 16, 1.0 / 4096, 1.0 / 32768}
		scale := itof_scale[w & 3]
		r: [4]f32
		for k in 0 ..< 4 {r[k] = f32(v.vf[fs].i[k]) * scale}
		put_raw(v, ft, dest, r)
	case 0x14 ..= 0x17: // FTOI0/4/12/15
		@(static, rodata) ftoi_scale := [4]f32{1, 16, 4096, 32768}
		scale := ftoi_scale[w & 3]
		if ft != 0 {
			for k in 0 ..< 4 {
				if dest & (8 >> u32(k)) != 0 {v.vf[ft].i[k] = cpu.cvt_w(s[k] * scale)}
			}
		}
	case 0x18 ..= 0x1b: put_acc(v, dest, cs * splat(ct[bc]))
	case 0x1c: put_acc(v, dest, cs * splat(cq))
	case 0x1d: put_raw(v, ft, dest, {abs(s.x), abs(s.y), abs(s.z), abs(s.w)})
	case 0x1e: put_acc(v, dest, cs * splat(ci))
	case 0x1f: // VCLIP
		lim := abs(t.w)
		f: u32 = 0
		for k in 0 ..< 3 {
			if s[k] > lim {f |= 1 << (2 * u32(k))}
			if s[k] < -lim {f |= 2 << (2 * u32(k))}
		}
		v.clip = ((v.clip << 6) | f) & 0xffffff
	case 0x20: put_acc(v, dest, cs + splat(cq))
	case 0x21: put_acc(v, dest, v.acc.f + cs * splat(cq))
	case 0x22: put_acc(v, dest, cs + splat(ci))
	case 0x23: put_acc(v, dest, v.acc.f + cs * splat(ci))
	case 0x24: put_acc(v, dest, cs - splat(cq))
	case 0x25: put_acc(v, dest, v.acc.f - cs * splat(cq))
	case 0x26: put_acc(v, dest, cs - splat(ci))
	case 0x27: put_acc(v, dest, v.acc.f - cs * splat(ci))
	case 0x28: put_acc(v, dest, cs + ct)
	case 0x29: put_acc(v, dest, v.acc.f + cs * ct)
	case 0x2a: put_acc(v, dest, cs * ct)
	case 0x2c: put_acc(v, dest, cs - ct)
	case 0x2d: put_acc(v, dest, v.acc.f - cs * ct)
	case 0x2e: put_acc(v, 0xe, {cs.y * ct.z, cs.z * ct.x, cs.x * ct.y, 0}) // VOPMULA
	case 0x2f: // VNOP
	case 0x30: // VMOVE
		if ft != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = v.vf[fs].u[k]}}
		}
	case 0x31: // VMR32: rotate fs one lane: ft.x = fs.y, y = z, z = w, w = x
		r := v.vf[fs].u
		r = {r[1], r[2], r[3], r[0]}
		if ft != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = r[k]}}
		}
	case 0x34, 0x36: // VLQI, VLQD
		if w & 3 == 2 {v.vi[is] -= 1}
		q := vu_mem_q(v, v.vi[is])
		if ft != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = q[k]}}
		}
		if w & 3 == 0 && is != 0 {v.vi[is] += 1}
		v.vi[0] = 0
	case 0x35, 0x37: // VSQI, VSQD: store fs to [it]
		if w & 3 == 3 {v.vi[it] -= 1}
		q := vu_mem_q(v, v.vi[it])
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {q[k] = v.vf[fs].u[k]}}
		if w & 3 == 1 && it != 0 {v.vi[it] += 1}
		v.vi[0] = 0
	case 0x38: // VDIV
		vu_div_flags(v, s[fsf], t[ftf])
		v.q = cpu.fdiv(s[fsf], t[ftf])
	case 0x39: // VSQRT
		vu_div_flags(v, 1, t[ftf] < 0 ? 0 : 1)
		v.q = math.sqrt(abs(t[ftf]))
	case 0x3a: // VRSQRT
		vu_div_flags(v, s[fsf], t[ftf])
		v.q = cpu.frsqrt(s[fsf], t[ftf])
	case 0x3b: // VWAITQ
	case 0x3c: if it != 0 {v.vi[it] = u16(v.vf[fs].u[fsf])} // VMTIR
	case 0x3d: // VMFIR
		if ft != 0 {
			x := u32(i32(i16(v.vi[is])))
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = x}}
		}
	case 0x3e: // VILWR
		q := vu_mem_q(v, v.vi[is])
		if it != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vi[it] = u16(q[k])}}
		}
	case 0x3f: // VISWR
		q := vu_mem_q(v, v.vi[is])
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {q[k] = u32(v.vi[it])}}
	case 0x40: // VRNEXT
		x := v.r
		x = ((x << 1) | (((x >> 4) ~ (x >> 22)) & 1)) & 0x7fffff
		v.r = x
		vu_put_r(v, ft, dest)
	case 0x41: vu_put_r(v, ft, dest) // VRGET
	case 0x42: v.r = v.vf[fs].u[fsf] & 0x7fffff // VRINIT
	case 0x43: v.r = (v.r ~ v.vf[fs].u[fsf]) & 0x7fffff // VRXOR
	// Micro mode only from here on.
	case 0x64: put_raw(v, ft, dest, splat(v.p)) // MFP
	case 0x68: // XTOP (VU1 only)
		if v != &vu1 {cpu.fatal("vu0: XTOP %08x does not exist on VU0", w)}
		if it != 0 {v.vi[it] = u16(vifs[1].top)}
	case 0x69: if it != 0 {v.vi[it] = u16(vifs[v == &vu1 ? 1 : 0].itop)} // XITOP: its own VIF's ITOP
	case 0x6c: // XGKICK (VU1 only)
		if v != &vu1 {cpu.fatal("vu0: XGKICK %08x does not exist on VU0", w)}
		vu1_xgkick(v.vi[is])
	case 0x70: v.p = vclamp(s.x * s.x + s.y * s.y + s.z * s.z) // ESADD
	case 0x71: v.p = cpu.fdiv(1, s.x * s.x + s.y * s.y + s.z * s.z) // ERSADD
	case 0x72: v.p = math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z) // ELENG
	case 0x73: v.p = cpu.frsqrt(1, s.x * s.x + s.y * s.y + s.z * s.z) // ERLENG
	case 0x74: v.p = math.atan(cpu.fdiv(s.y, s.x)) // EATANxy
	case 0x75: v.p = math.atan(cpu.fdiv(s.z, s.x)) // EATANxz
	case 0x76: v.p = vclamp(s.x + s.y + s.z + s.w) // ESUM
	case 0x78: v.p = math.sqrt(abs(s[fsf])) // ESQRT
	case 0x79: v.p = cpu.frsqrt(1, s[fsf]) // ERSQRT
	case 0x7a: v.p = cpu.fdiv(1, s[fsf]) // ERCPR
	case 0x7b: // WAITP
	case 0x7c: v.p = math.sin(s[fsf]) // ESIN
	case 0x7d: v.p = math.atan(s[fsf]) // EATAN
	case 0x7e: v.p = vclamp(math.exp(-s[fsf])) // EEXP
	case:
		cpu.fatal("vu%d: unknown op %08x", v == &vu1 ? 1 : 0, w)
	}
}

// Store the dest lanes of `r` into `dst` (nil discards, as for VF00) and
// set MAC Z/S bits for them; status takes the OR plus sticky copies.
// Unchecked: every index is a lane k < 4.
@(private)
vu_put_flags :: proc(v: ^Vu, dst: ^Vf, dest: u32, r: [4]f32) #no_bounds_check {
	// Branchless: every lane is computed, then masked by dest.
	mac: u32 = 0
	x: [4]f32
	for k in 0 ..< 4 {
		x[k] = vclamp(r[k])
		u := transmute(u32)x[k]
		bit := u32(8) >> u32(k)
		mac |= u32(u << 1 == 0) * bit | (u >> 31) * (bit << 4)
	}
	mac &= dest | dest << 4
	if dst != nil {
		for k in 0 ..< 4 {
			if dest & (8 >> u32(k)) != 0 {dst.f[k] = x[k]}
		}
	}
	v.mac = mac
	st: u32 = 0
	if mac & 0x0f != 0 {st |= 1}
	if mac & 0xf0 != 0 {st |= 2}
	v.status = (v.status &~ 0xf) | st | st << 6
}

// Status I/D bits for DIV-family ops: 0/0 is invalid, x/0 divide by zero.
@(private)
vu_div_flags :: proc(v: ^Vu, a, b: f32) {
	f: u32 = 0
	if b == 0 {f = a == 0 ? 0x10 : 0x20}
	v.status = (v.status &~ 0x30) | f | f << 6
}

@(private)
vu_put_r :: proc(v: ^Vu, ft, dest: u32) {
	x := 0x3f800000 | v.r
	if ft != 0 {
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = x}}
	}
}

// Quadword `n` of a VU data memory (wrapping like the hardware).
// No bounds checks: keep the index reduced % len(v.mem).
vu_mem_q :: proc(v: ^Vu, n: u16) -> ^[4]u32 #no_bounds_check {
	o := (u32(n) * 16) % u32(len(v.mem))
	return (^[4]u32)(&v.mem[o])
}

// MAX and MINI order the raw words by sign and magnitude: exponent 255 is
// just a large magnitude, denormals order as they are and -0 < +0. The
// winning word is written unclamped and MAC and status are left alone. This
// is the behaviour PCSX2 implements (pcsx2/VUops.cpp fp_max, fp_min and
// applyMinMax; pcsx2/x86/microVU_Upper.inl mVU_FMACa, which skips the flag
// update for them), described here, no code copied. Read as i32 the words
// order the same way, except that two negative ones order in reverse.
@(private)
vmax :: proc(a, b: [4]u32) -> [4]u32 {
	ka, kb := transmute(#simd[4]i32)a, transmute(#simd[4]i32)b
	neg := simd.lanes_lt(ka & kb, 0)
	return transmute([4]u32)simd.select(neg, simd.min(ka, kb), simd.max(ka, kb))
}
@(private)
vmin :: proc(a, b: [4]u32) -> [4]u32 {
	ka, kb := transmute(#simd[4]i32)a, transmute(#simd[4]i32)b
	neg := simd.lanes_lt(ka & kb, 0)
	return transmute([4]u32)simd.select(neg, simd.max(ka, kb), simd.min(ka, kb))
}

// ------------------------------------------------------------ micro mode

VU_STEP_LIMIT :: 1 << 24

@(private)
vu0_overrun, vu1_overrun: bool

// How compiled microcode stopped: at the E bit's end, or by handing the
// pair at the returned pc to the interpreter.
Vu_Exit :: enum u8 {End, Leave}

// A microprogram compiled ahead of time (rec/vu0, rec/vu1). `run` executes
// from a pair address below len(code)*4; taken branches count against
// budget.
Vu_Run :: #type proc(pc: u32, budget: ^int) -> (u32, Vu_Exit)

// Micro memory a compiled program was compiled from: code at pc.
Vu_Range :: struct {
	pc:   u32,
	code: []u32,
}

@(private)
Vu_Program :: struct {
	ranges:   []Vu_Range,
	run:      Vu_Run,
	size:     int, // pairs, over all ranges
	ok_gen:   u32, // the micro generation when ok was checked
	ok:       bool, // micro memory holds ranges
	// VU0_STATS, VU1_STATS: runs entered, range checks, and checks that
	// failed.
	runs, checks, misses: u64,
}

// One VU's compiled programs, N pairs of micro memory. Nothing here is
// snapshotted: what it caches is keyed by a micro generation, and a
// generation is never reused.
@(private)
Micro_Table :: struct($N: int) {
	programs:   [dynamic]^Vu_Program,
	// Per pair: the programs compiling it, longest first. A pair where none
	// does stays in the interpreter without looking.
	candidates: [N][dynamic]^Vu_Program,
	compiled:   [N]bool, // the pair has candidates
	// Per pair, for generation pick_gen[i]: the program to run there, or
	// nil to interpret.
	pick_gen:   [N]u32,
	pick:       [N]^Vu_Program,
	// compiled less the pairs found to have no matching program, for
	// stop_gen; the interpreter runs on through those.
	stop:       [N]bool,
	stop_gen:   u32,
	nocomp:     bool, // interpret everything (VUNOCOMP, capturing)
}

@(private)
vu0_table: Micro_Table(len(vu0_micro) / 8)
@(private)
vu1_table: Micro_Table(len(vu1_micro) / 8)

// Bumped on every write path into each VU's micro memory (vu0_micro_touch,
// vu1_micro_touch); the per-pair choice of program is rechecked when it
// moves.
vu0_micro_gen: u32 = 1
vu1_micro_gen: u32 = 1
// The last generation handed out, to either VU. Not snapshotted: a
// generation is never reused, even after a rollback restores an older one,
// so every cache keyed by one stays true to the micro memory it was taken
// from.
@(private)
vu_gen_last: u32 = 1

vu0_micro_touch :: #force_inline proc() {
	vu_gen_last += 1
	vu0_micro_gen = vu_gen_last
}

vu1_micro_touch :: #force_inline proc() {
	vu_gen_last += 1
	vu1_micro_gen = vu_gen_last
}

// A program compiled from micro memory starting at 0 (a .vutext program).
vu1_register :: proc(code: []u32, run: Vu_Run) {
	vu1_register_ranges({{0, code}}, run)
}

// A program compiled from the given runs of micro memory.
vu0_register_ranges :: proc(ranges: []Vu_Range, run: Vu_Run) {
	micro_register(&vu0_table, ranges, run)
}
vu1_register_ranges :: proc(ranges: []Vu_Range, run: Vu_Run) {
	micro_register(&vu1_table, ranges, run)
}

@(private)
micro_register :: proc(t: ^Micro_Table($N), ranges: []Vu_Range, run: Vu_Run) {
	context.allocator = runtime.heap_allocator()
	p := new(Vu_Program)
	p.ranges = slice.clone(ranges)
	p.run = run
	for r in ranges {p.size += len(r.code) / 2}
	append(&t.programs, p)
	for r in ranges {
		for k in 0 ..< len(r.code) / 2 {
			i := (r.pc / 8 + u32(k)) % u32(N)
			c := &t.candidates[i]
			if c.allocator.procedure == nil {c^ = make([dynamic]^Vu_Program)}
			at := len(c)
			for at > 0 && c[at - 1].size < p.size {at -= 1}
			inject_at(c, at, p)
			t.compiled[i] = true
			t.pick_gen[i] = ~u32(0)
		}
	}
	// Picks and stops cached for the current generation predate p.
	t.stop_gen = ~u32(0)
}

// The program to run at pc, nil to interpret. pc is a pair address below
// the VU's micro memory size: every caller masks it, so pc / 8 indexes
// unchecked.
@(private)
vu0_lookup :: proc(pc: u32) -> ^Vu_Program {
	return micro_lookup(&vu0_table, vu0_micro[:], vu0_micro_gen, pc)
}
@(private)
vu1_lookup :: proc(pc: u32) -> ^Vu_Program {
	return micro_lookup(&vu1_table, vu1_micro[:], vu1_micro_gen, pc)
}

// The program of t to run at pc in micro memory of generation gen.
@(private)
micro_lookup :: #force_inline proc(t: ^Micro_Table($N), micro: []u8, gen, pc: u32) -> ^Vu_Program #no_bounds_check {
	i := pc / 8
	if t.pick_gen[i] == gen {return t.pick[i]}
	pick: ^Vu_Program
	if !t.nocomp {
		for p in t.candidates[i] {
			if p.ok_gen != gen {
				p.ok_gen = gen
				p.ok = micro_holds(p, micro)
				p.checks += 1
				if !p.ok {p.misses += 1}
			}
			if p.ok {
				pick = p
				break
			}
		}
	}
	t.pick_gen[i], t.pick[i] = gen, pick
	if pick == nil {t.stop[i] = false}
	return pick
}

@(private)
micro_holds :: proc(p: ^Vu_Program, micro: []u8) -> bool {
	micro := ([^]u32)(raw_data(micro))[:len(micro) / 4]
	for r in p.ranges {
		at := int(r.pc / 4)
		if at + len(r.code) > len(micro) {
			n := len(micro) - at
			if !slice.equal(micro[at:], r.code[:n]) || !slice.equal(micro[:len(r.code) - n], r.code[n:]) {return false}
		} else if !slice.equal(micro[at:][:len(r.code)], r.code) {return false}
	}
	return true
}

@(private)
vu_check, vu0_stats, vu1_stats: bool

// VUNOCOMP=1 runs everything in the interpreter; VUCHECK=1 runs
// every microprogram both ways and reports differences; VU0_STATS=1 and
// VU1_STATS=1 print each compiled program's counters at exit.
@(private)
vu_options :: proc() {
	nocomp := core.env("VUNOCOMP") != ""
	vu0_table.nocomp, vu1_table.nocomp = nocomp, nocomp
	vu_check = core.env("VUCHECK") != ""
	vu0_stats = core.env("VU0_STATS") != ""
	vu1_stats = core.env("VU1_STATS") != ""
	vu_capture_options()
}

vu_stats_print :: proc() {
	if vu0_stats {micro_stats_print(0, vu0_table.programs[:])}
	if vu1_stats {micro_stats_print(1, vu1_table.programs[:])}
}

@(private)
micro_stats_print :: proc(unit: int, programs: []^Vu_Program) {
	for p, k in programs {
		if p.runs == 0 && p.checks == 0 {continue}
		fmt.eprintfln("vu%d program %d at %04x, %d pairs: %d runs, %d checks, %d misses",
			unit, k, p.ranges[0].pc, p.size, p.runs, p.checks, p.misses)
	}
}

// Run a VU1 microprogram to its E bit. The VU runs synchronously with the
// EE, without pipeline timing: results are visible to the next pair.
vu1_start :: proc(addr: u32) {
	t := cpu.prof_start()
	defer cpu.prof_end(.VU1, t)
	if vu1_cap.file != nil {vu_capture(&vu1, addr)}
	if vu_check && vu1_lookup(addr & u32(len(vu1_micro) - 1) &~ 7) != nil {
		vu1_compare(addr)
		return
	}
	vu1_exec(addr, true)
}

@(private)
vu1_exec :: proc(addr: u32, compiled: bool) {
	pc, ended := micro_exec(&vu1, &vu1_table, &vu1_micro_gen, vu1_pairs[:], addr, compiled)
	if !ended && !vu1_overrun {
		vu1_overrun = true
		fmt.eprintfln("vu1: microprogram at %04x ran %d steps without ending", addr, VU_STEP_LIMIT)
	}
	vu1.tpc = pc
}

// Run v's microprogram at addr until it ends (ended) or overruns the step
// limit: t's compiled programs where micro memory of generation gen^ holds
// them, unless !compiled, and the interpreter elsewhere. Inlined into each
// VU's wrapper, so the VU, its table and its pair cache are constants there.
// No bounds checks: pc stays masked to a pair address in micro memory,
// including what compiled code hands back.
@(private)
micro_exec :: #force_inline proc(v: ^Vu, t: ^Micro_Table($N), gen: ^u32, pairs: []Vu_Pair_Info, addr: u32, compiled: bool) -> (pc: u32, ended: bool) #no_bounds_check {
	mask := u32(len(v.micro) - 1) &~ 7
	pc = addr & mask
	if t.stop_gen != gen^ {
		t.stop_gen = gen^
		t.stop = t.compiled
	}
	stop := compiled ? t.stop[:] : nil
	budget := VU_STEP_LIMIT
	for budget > 0 {
		// A program that hands back a pair it compiles leaves that pair to
		// the interpreter.
		last: ^Vu_Program
		for compiled && t.stop[pc / 8] {
			prog := micro_lookup(t, v.micro, gen^, pc)
			if prog == nil || prog == last {break}
			last = prog
			prog.runs += 1
			exit: Vu_Exit
			pc, exit = prog.run(pc, &budget)
			pc &= mask
			if exit == .End {return pc, true}
			if budget <= 0 {break}
		}
		if budget <= 0 {break}
		when cpu.FALLBACK_COUNT {left := budget}
		pc, ended = vu_interp(v, pairs, pc, stop, &budget)
		// VUCHECK's interpreter-only run is not counted.
		when cpu.FALLBACK_COUNT {if v == &vu0 && compiled {cpu.fallback_vu0_micro += u64(left - budget)}}
		if ended {return}
	}
	return pc, false
}

// Interpret from pc for at least one pair, until the program ends or
// control reaches a pair marked in `stop` (compiled code may run there)
// with no branch or end pending. Inlined into micro_exec.
// No bounds checks: callers pass a masked pc, every later pc is masked, and
// pairs holds one entry per pair of v.micro; stop is checked against len.
@(private)
vu_interp :: #force_inline proc(v: ^Vu, pairs: []Vu_Pair_Info, pc: u32, stop: []bool, budget: ^int) -> (u32, bool) #no_bounds_check {
	mask := u32(len(v.micro) - 1) &~ 7
	pc := pc
	jumping, ending := false, false
	target: u32
	for budget^ > 0 {
		budget^ -= 1
		lw := (^u32)(&v.micro[pc])^
		uw := (^u32)(&v.micro[pc + 4])^
		next := (pc + 8) & mask
		info := &pairs[pc >> 3]
		if info.uw != uw || info.lw != lw || !info.valid {
			info^ = vu_pair_info(uw, lw)
		}
		taken: bool
		dst: u32
		if info.serial {
			vu_op(v, uw)
			taken, dst = vu_lower(v, lw, pc)
		} else {
			taken, dst = vu_pair(v, uw, lw, pc)
		}
		if jumping { // that was the delay slot
			next = target & mask
			jumping = false
		}
		if taken {
			jumping = true
			target = dst
		}
		if ending {return next, true}
		if uw & (1 << 30) != 0 {ending = true}
		pc = next
		if !jumping && !ending && int(pc / 8) < len(stop) && stop[pc / 8] {break}
	}
	return pc, false
}

// VUCHECK: run the interpreter, then the compiled code from the same
// state, and compare (vu_compare).
@(private)
vu0_compare :: proc(addr: u32) {
	@(static) mem0, mem1: [len(vu0_mem)]u8
	vu_compare(&vu0, vu0_mem[:], mem0[:], mem1[:], vu0_table.programs[:], vu0_lookup(addr & u32(len(vu0_micro) - 1) &~ 7), addr, vu0_exec)
}
@(private)
vu1_compare :: proc(addr: u32) {
	@(static) mem0, mem1: [len(vu1_mem)]u8
	vu_compare(&vu1, vu1_mem[:], mem0[:], mem1[:], vu1_table.programs[:], vu1_lookup(addr & u32(len(vu1_micro) - 1) &~ 7), addr, vu1_exec)
}

// Run v's program at addr with exec in the interpreter, then compiled from
// the same state with XGKICK muted, and report differences; mem is v's data
// memory, mem0 and mem1 scratch of its size, entry the program compiled at
// addr. Status is compared on VU0 only: compiled VU1 code never computes it.
// The interpreter's results are kept.
@(private)
vu_compare :: proc(v: ^Vu, mem, mem0, mem1: []u8, programs: []^Vu_Program, entry: ^Vu_Program, addr: u32, exec: proc(addr: u32, compiled: bool)) {
	@(static) reported: int
	v0 := v^
	copy(mem0, mem)
	vu1_kick_hash = 0
	exec(addr, false)
	v1, kick1 := v^, vu1_kick_hash
	copy(mem1, mem)
	v^ = v0
	copy(mem, mem0)
	vu1_kick_hash, vu1_kick_mute = 0, true
	exec(addr, true)
	vu1_kick_mute = false
	v2, kick2 := v^, vu1_kick_hash
	unit := v == &vu1 ? 1 : 0
	vf_bad := false
	for k in 0 ..< 32 {vf_bad ||= v1.vf[k].q != v2.vf[k].q}
	status_bad := unit == 0 && v1.status != v2.status
	mem_bad := !slice.equal(mem, mem1)
	prog := -1
	for p, k in programs {if p == entry {prog = k}}
	bad := kick1 != kick2 || mem_bad || vf_bad || v1.vi != v2.vi ||
		v1.acc.q != v2.acc.q || v1.q != v2.q || v1.p != v2.p || v1.i != v2.i ||
		v1.r != v2.r || v1.clip != v2.clip || v1.mac != v2.mac || status_bad || v1.tpc != v2.tpc
	if bad && reported < 20 {
		reported += 1
		fmt.eprintfln("vucheck: vu%d program %d entry %04x differs: kick %v vf %v vi %v acc %v q %v p %v i %v clip %v mac %v (%04x/%04x) status %v (%04x/%04x) tpc %v mem %v",
			unit, prog, addr, kick1 != kick2, vf_bad, v1.vi != v2.vi,
			v1.acc.q != v2.acc.q, v1.q != v2.q, v1.p != v2.p, v1.i != v2.i, v1.clip != v2.clip,
			v1.mac != v2.mac, v1.mac, v2.mac, status_bad, v1.status, v2.status, v1.tpc != v2.tpc, mem_bad)
		for k in 0 ..< 32 {
			if v1.vf[k].q != v2.vf[k].q {fmt.eprintfln("  vf%d %v / %v", k, v1.vf[k].f, v2.vf[k].f)}
		}
		for k in 0 ..< 16 {
			if v1.vi[k] != v2.vi[k] {fmt.eprintfln("  vi%d %04x / %04x", k, v1.vi[k], v2.vi[k])}
		}
	}
	v^ = v1
	copy(mem, mem1)
}

// Public entry points for compiled microcode.
vu0_upper :: proc(uw: u32) {
	when cpu.FALLBACK_COUNT {cpu.fallback_vu0_upper[cpu.cop2_key(uw)] += 1}
	vu_op(&vu0, uw)
}
vu0_lower :: proc(lw, pc: u32) {
	when cpu.FALLBACK_COUNT {cpu.fallback_vu0_lower[lw >> 25 == 0x40 ? 128 + cpu.cop2_key(lw) : lw >> 25] += 1}
	vu_lower(&vu0, lw, pc)
}
vu0_pair :: proc(uw, lw, pc: u32) {
	when cpu.FALLBACK_COUNT {cpu.fallback_vu0_pair += 1}
	vu_pair(&vu0, uw, lw, pc)
}
vu1_upper :: proc(uw: u32) {
	when cpu.FALLBACK_COUNT {cpu.fallback_vu1_upper[cpu.cop2_key(uw)] += 1}
	vu_op(&vu1, uw)
}
vu1_lower :: proc(lw, pc: u32) {
	when cpu.FALLBACK_COUNT {cpu.fallback_vu1_lower[lw >> 25 == 0x40 ? 128 + cpu.cop2_key(lw) : lw >> 25] += 1}
	vu_lower(&vu1, lw, pc)
}
vu1_pair :: proc(uw, lw, pc: u32) {
	when cpu.FALLBACK_COUNT {cpu.fallback_vu1_pair += 1}
	vu_pair(&vu1, uw, lw, pc)
}

// What decoding a pair tells the interpreter, cached per micro address and
// tagged with the words so uploads need no invalidation.
@(private)
Vu_Pair_Info :: struct {
	uw, lw: u32,
	valid:  bool,
	serial: bool, // running upper then lower gives the same result as vu_pair
}

@(private)
vu0_pairs: [len(vu0_micro) / 8]Vu_Pair_Info
@(private)
vu1_pairs: [len(vu1_micro) / 8]Vu_Pair_Info

// A pair can run in sequence when the lower op neither reads nor writes the
// VF register the upper writes and leaves the flags alone: the upper writes
// nothing else the lower reads (VI, Q, P and R belong to the lower side).
@(private)
vu_pair_info :: proc(uw, lw: u32) -> Vu_Pair_Info {
	info := Vu_Pair_Info{uw = uw, lw = lw, valid = true}
	if uw & (1 << 31) != 0 {return info} // I bit: vu_pair's own path
	ud := vu_upper_dest(uw)
	ft, fs := (lw >> 16) & 31, (lw >> 11) & 31
	touches := ud != 0 && (ft == ud || fs == ud)
	switch lw >> 25 {
	case 0x00: info.serial = ud == 0 || ft != ud // LQ
	case 0x01: info.serial = ud == 0 || fs != ud // SQ
	case 0x04, 0x05, 0x08, 0x09, 0x20, 0x21, 0x24, 0x25, 0x28, 0x29, 0x2c ..= 0x2f:
		info.serial = true // VI, memory and branches
	case 0x40:
		if lw & 63 < 0x3c {
			info.serial = true // IADD family
			break
		}
		switch ((lw >> 4) & 0x7c) | (lw & 3) {
		case 0x38 ..= 0x3a: // DIV family sets status
		case 0x3b, 0x3e, 0x3f, 0x68, 0x69, 0x6c, 0x7b: info.serial = true
		case: info.serial = !touches
		}
	}
	return info
}

// Execute one upper/lower pair. Both halves read registers before either
// writes; when both write the same VF register the lower result wins.
// No bounds checks: keep every index masked to its array's length (&31,
// &15, &3), constant or bounded by a 0 ..< 4 loop.
@(private)
vu_pair :: proc(v: ^Vu, uw, lw, pc: u32) -> (taken: bool, target: u32) #no_bounds_check {
	if uw & (1 << 31) != 0 { // I bit: the lower word is a float for I
		vu_op(v, uw) // the upper still reads the old I
		v.i = transmute(f32)lw
		return
	}
	ud := vu_upper_dest(uw) & 31
	saved := v.vf[ud]
	flags := [3]u32{v.mac, v.status, v.clip}
	vu_op(v, uw)
	result := v.vf[ud]
	uflags := [3]u32{v.mac, v.status, v.clip}
	v.vf[ud] = saved
	v.mac, v.status, v.clip = flags[0], flags[1], flags[2]
	taken, target = vu_lower(v, lw, pc)
	if v.vf[ud].q == saved.q {v.vf[ud] = result}
	if v.mac == flags[0] {v.mac = uflags[0]}
	if v.status == flags[1] {v.status = uflags[1]}
	if v.clip == flags[2] {v.clip = uflags[2]}
	return
}

// The VF register an upper op writes (0 for ACC-only or none).
@(private)
vu_upper_dest :: proc(w: u32) -> u32 {
	if w & 63 < 0x3c {return (w >> 6) & 31}
	switch ((w >> 4) & 0x7c) | (w & 3) {
	case 0x10 ..= 0x17, 0x1d: return (w >> 16) & 31
	}
	return 0
}

// Micro-mode lower word. Returns a branch and its target byte address.
// No bounds checks here or in set_vi: keep every index masked to its
// array's length (&31, &15, &3), constant or bounded by a 0 ..< 4 loop.
@(private)
vu_lower :: proc(v: ^Vu, w, pc: u32) -> (taken: bool, target: u32) #no_bounds_check {
	dest := (w >> 21) & 15
	ft, fs := (w >> 16) & 31, (w >> 11) & 31
	it, is := ft & 15, fs & 15
	imm11 := u16(i16(u16(w & 0x7ff) << 5) >> 5)
	imm12 := ((w >> 10) & 0x800) | (w & 0x7ff)
	imm15 := u16(((w >> 10) & 0x7800) | (w & 0x7ff))
	imm24 := w & 0xffffff
	vi := &v.vi
	branch := pc + 8 + u32(i32(i16(imm11))) * 8
	set_vi :: #force_inline proc(vi: ^[16]u16, n: u32, x: u16) #no_bounds_check {if n != 0 {vi[n & 15] = x}}
	switch w >> 25 {
	case 0x00: // LQ
		q := vu_mem_q(v, vi[is] + imm11)
		if ft != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = q[k]}}
		}
	case 0x01: // SQ
		q := vu_mem_q(v, vi[it] + imm11)
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {q[k] = v.vf[fs].u[k]}}
	case 0x04: // ILW
		q := vu_mem_q(v, vi[is] + imm11)
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {set_vi(vi, it, u16(q[k]))}}
	case 0x05: // ISW
		q := vu_mem_q(v, vi[is] + imm11)
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {q[k] = u32(vi[it])}}
	case 0x08: set_vi(vi, it, vi[is] + imm15) // IADDIU
	case 0x09: set_vi(vi, it, vi[is] - imm15) // ISUBIU
	case 0x10: vi[1] = u16(v.clip & 0xffffff == imm24) // FCEQ
	case 0x11: v.clip = imm24 // FCSET
	case 0x12: vi[1] = u16(v.clip & imm24 != 0) // FCAND
	case 0x13: vi[1] = u16((v.clip | imm24) & 0xffffff == 0xffffff) // FCOR
	case 0x14: set_vi(vi, it, u16(v.status & 0xfff == imm12)) // FSEQ
	case 0x15: v.status = (v.status & 0x3f) | (imm12 & 0xfc0) // FSSET
	case 0x16: set_vi(vi, it, u16(v.status & imm12)) // FSAND
	case 0x17: set_vi(vi, it, u16((v.status | imm12) & 0xfff == 0xfff)) // FSOR
	case 0x18: set_vi(vi, it, u16(v.mac & 0xffff == u32(vi[is]))) // FMEQ
	case 0x1a: set_vi(vi, it, u16(v.mac) & vi[is]) // FMAND
	case 0x1b: set_vi(vi, it, u16((v.mac | u32(vi[is])) & 0xffff == 0xffff)) // FMOR
	case 0x1c: set_vi(vi, it, u16(v.clip & 0xfff)) // FCGET
	case 0x20: return true, branch // B
	case 0x21: // BAL
		set_vi(vi, it, u16((pc + 16) / 8))
		return true, branch
	case 0x24: // JR
		t := u32(vi[is]) * 8
		if capture_of(v).file != nil {vu_capture(v, t)}
		return true, t
	case 0x25: // JALR
		t := u32(vi[is]) * 8
		if capture_of(v).file != nil {vu_capture(v, t)}
		set_vi(vi, it, u16((pc + 16) / 8))
		return true, t
	case 0x28: return vi[it] == vi[is], branch // IBEQ
	case 0x29: return vi[it] != vi[is], branch // IBNE
	case 0x2c: return i16(vi[is]) < 0, branch // IBLTZ
	case 0x2d: return i16(vi[is]) > 0, branch // IBGTZ
	case 0x2e: return i16(vi[is]) <= 0, branch // IBLEZ
	case 0x2f: return i16(vi[is]) >= 0, branch // IBGEZ
	case 0x40: vu_op(v, w)
	case:
		cpu.fatal("vu%d: unknown lower op %08x at %04x", v == &vu1 ? 1 : 0, w, pc)
	}
	return
}

// XGKICK: send the GIF packet at quadword `addr` of VU1 memory down PATH1,
// following tags to the one with EOP.
@(private)
vu1_kick_hash: u64
@(private)
vu1_kick_mute: bool

// The packet is fed to the GIF straight out of VU1 memory, split where it
// wraps past the end. gif_feed keeps no pointer into the data past the call
// and raises interrupts only as pending, so nothing writes VU1 memory while
// the packet is read.
vu1_xgkick :: proc(addr: u16) {
	qwords := u32(len(vu1_mem) / 16)
	start := u32(addr) % qwords
	a := start
	total: u32 = 0
	for total < qwords {
		lo := (^u64)(&vu1_mem[a * 16])^
		nloop, nreg := u32(lo & 0x7fff), u32(lo >> 60)
		if nreg == 0 {nreg = 16}
		n: u32 = 1
		switch (lo >> 58) & 3 {
		case 0: n += nloop * nreg
		case 1: n += (nloop * nreg + 1) / 2
		case: n += nloop
		}
		a = (a + n) % qwords
		total += n
		if lo & 0x8000 != 0 {break}
	}
	if vu_check {
		a = start
		for left := total; left > 0; {
			seg := min(left, qwords - a)
			for b in vu1_mem[a * 16:][:seg * 16] {vu1_kick_hash = (vu1_kick_hash ~ u64(b)) * 0x100000001b3}
			a = (a + seg) % qwords
			left -= seg
		}
		if vu1_kick_mute {return}
	}
	a = start
	for left := total; left > 0; {
		seg := min(left, qwords - a)
		gif.gif_feed(1, vu1_mem[a * 16:][:seg * 16])
		a = (a + seg) % qwords
		left -= seg
	}
}

// Run a VU0 microprogram (VCALLMS, VCALLMSR, VIF0 MSCAL) to its E bit, as
// vu1_start: compiled programs (rec/vu0) where they hold, the interpreter
// elsewhere. Like VU1 it runs synchronously, so VU0 is never busy when the
// EE next looks: the EE is charged no cycles, where hardware would stall it
// only for a VCALLMS while VU0 still runs or a QMFC2.I/CFC2.I that waits
// for the end. No state outlives the call but tpc and the registers.
vu0_call_micro :: proc(addr: u32) {
	t := cpu.prof_start()
	defer cpu.prof_end(.VU0, t)
	if vu0_cap.file != nil {vu_capture(&vu0, addr)}
	if vu_check && vu0_lookup(addr & u32(len(vu0_micro) - 1) &~ 7) != nil {
		vu0_compare(addr)
		return
	}
	vu0_exec(addr, true)
}

@(private)
vu0_exec :: proc(addr: u32, compiled: bool) {
	pc, ended := micro_exec(&vu0, &vu0_table, &vu0_micro_gen, vu0_pairs[:], addr, compiled)
	if !ended && !vu0_overrun {
		vu0_overrun = true
		fmt.eprintfln("vu0: microprogram at %04x ran %d steps without ending", addr, VU_STEP_LIMIT)
	}
	vu0.tpc = pc
}

// Emulated state, saved and restored by snapshots (snap.odin).
vu_snap :: proc() {
	core.snap_add(&vu0)
	core.snap_add(&vu1)
	core.snap_add(&vu0_mem)
	core.snap_add(&vu0_micro)
	core.snap_add(&vu1_mem)
	core.snap_add(&vu1_micro)
	core.snap_add(&vu0_overrun)
	core.snap_add(&vu1_overrun)
	core.snap_add(&vu0_micro_gen)
	core.snap_add(&vu1_micro_gen)
	core.snap_add(&vu0_pairs)
	core.snap_add(&vu1_pairs)
	core.snap_add(&vu1_kick_hash)
	core.snap_add(&vu1_kick_mute)
}
