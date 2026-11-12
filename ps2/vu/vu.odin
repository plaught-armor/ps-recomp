// Vector units: register files, memories, and VU0 macro mode (COP2
// instructions issued by the EE).
//
// VU floats are IEEE singles without infinities or NaNs, clamped like the
// FPU. MAC, status and clip flags are kept as vu_put_flags, CLIP and the
// FDIV unit's status bits (VU_Q_DIV) set them.
//
// In micro mode a flag read sees the flags four pairs late: the FMAC
// pipeline writes them four cycles after an op issues, so FMAND, FCAND,
// FSAND and the rest at pair n see the flags as they were after pair n-4.
// Programs rely on it: one computes a vertex's facing from the MAC of an
// op whose MAC a later op has overwritten by the time the read runs. Vu
// keeps the three older values each flag passed through (old_mac and the
// rest), shifted once per pair by every backend (vu_flags_shift), and the
// reads take the oldest. Sticky status bits (6-11) are read as they are
// now. A stall for Q or P (vu_before) shifts the flags once per cycle, as
// an empty pair would. FMAC operand stalls are not modelled: hardware holds
// a pair whose operand an earlier FMAC op has not yet written, which moves
// later flags into the window, and integer waits likewise; VU_STALL_COUNT
// counts the reads such a stall could reach. Macro mode reads the newest
// flags: CFC2 waits for the pipeline to drain.
package ps2_vu

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
	// Each flag after the pair before last, two before, and three before:
	// [2] is what a flag read in micro mode sees. Seeded with the newest
	// flags when a microprogram starts.
	old_mac:    [3]u32,
	old_status: [3]u32,
	old_clip:   [3]u32,
	// Q as DIV, SQRT or RSQRT leaves it, and the pairs until it lands (0:
	// none pending). See VU_Q_DIV.
	q_next: f32,
	q_wait: u32,
	// P as an EFU op leaves it, and the pairs until it lands (0: none
	// pending). See VU_EFU_LATENCY.
	p_next: f32,
	p_wait: u32,
	// Status I (0x10) and D (0x20) of the pending DIV, SQRT or RSQRT, set
	// by the pair after its wait drops to VU_Q_FLAGS.
	q_flags: u32,
	// Nonzero: Q's wait has reached VU_Q_FLAGS and its I and D bits are not
	// yet in status; the next pair sets them (vu_q_due).
	q_due:   u32,
	// The pairs a branch's VI delay looks back over (vi_branch), newest
	// first, as VIH entries; 0 where control arrived by a jump or the
	// microprogram started.
	vih:    [4]u32,
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
// Not private: native code addresses it through import "vu1.mem".
vu1_mem: [VU1_MEM]u8
@(private)
vu1_micro: [16 << 10]u8

// What a native microprogram (recomp/vu/native.odin) of a unit reads and
// leaves: imports <unit>.run_pc, .run_budget and .scratch.
Native_Run :: struct #align (16) {
	scratch:    [64]u8, // SCRATCH_SIZE there
	pc, budget: i32,
}
native_run: [2]Native_Run

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
	cpu.spin_dirty |= cpu.SPIN_SIDE // the spin skip's probe (ps2/spin.odin)
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
	case 29: return u32(vu0_parked) // VPU-STAT: VU0 runs while parked, VU1 is idle
	case 31: return vu1.cmsar
	}
	return 0
}

vu0_ctrl_write :: proc(n: u8, v: u32) {
	cpu.spin_dirty |= cpu.SPIN_SIDE // the spin skip's probe (ps2/spin.odin)
	switch n {
	case 1 ..< 16:
		vu0.vi[n] = u16(v)
		// What a parked microprogram waits for: it goes on from its loop.
		if vu0_parked {vu0_exec(vu0.tpc, true)}
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
	cpu.spin_dirty |= cpu.SPIN_SIDE // the spin skip's probe (ps2/spin.odin)
	when cpu.FALLBACK_COUNT {cpu.fallback_vu0[cpu.cop2_key(w)] += 1}
	if vu0_parked {vu0_park_note(.Macro)}
	vu_op(&vu0, w)
	vu_drain(&vu0) // macro mode waits for Q, and sets I and D at once
}

// One operation in COP2 layout. Macro instructions, micro-mode upper
// words and micro-mode lower words with opcode 0x40 share this encoding:
// fn 0x00-0x2f and special 0x00-0x2f are upper ops, fn 0x30-0x3b and
// special 0x30-0x7f lower ops.
// No bounds checks here or in its nested procs: keep every index masked to
// its array's length (&31, &15, &3), constant, a 0/1 select, or bounded by
// a 0 ..< 4 loop. pc: a micro-mode lower op's address, VU_PC_MACRO for a
// macro instruction.
vu_op :: proc(v: ^Vu, w: u32, pc: u32 = VU_PC_MACRO) #no_bounds_check {
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
	// The add and multiply family's operands, clamped, and those of SQRT
	// and the EFU (cpu.fdiv and frsqrt clamp their own): the VU has no
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
		q := vu_load_q(v, v.vi[is], pc)
		if ft != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = q[k]}}
		}
		if w & 3 == 0 && is != 0 {v.vi[is] += 1}
		v.vi[0] = 0
	case 0x35, 0x37: // VSQI, VSQD: store fs to [it]
		if w & 3 == 3 {v.vi[it] -= 1}
		vu_store_q(v, v.vi[it], v.vf[fs].u, dest)
		if w & 3 == 1 && it != 0 {v.vi[it] += 1}
		v.vi[0] = 0
	case 0x38: // VDIV
		v.q_flags = vu_div_bits(s[fsf], t[ftf])
		v.q_next, v.q_wait = cpu.fdiv(s[fsf], t[ftf]), VU_Q_DIV
	case 0x39: // VSQRT
		v.q_flags = vu_div_bits(1, t[ftf] < 0 ? 0 : 1)
		v.q_next, v.q_wait = math.sqrt(abs(ct[ftf])), VU_Q_DIV
	case 0x3a: // VRSQRT
		v.q_flags = vu_div_bits(s[fsf], t[ftf])
		v.q_next, v.q_wait = cpu.frsqrt(s[fsf], t[ftf]), VU_Q_RSQRT
	case 0x3b: // VWAITQ
	case 0x3c: if it != 0 {v.vi[it] = u16(v.vf[fs].u[fsf])} // VMTIR
	case 0x3d: // VMFIR
		if ft != 0 {
			x := u32(i32(i16(v.vi[is])))
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = x}}
		}
	case 0x3e: // VILWR
		q := vu_load_q(v, v.vi[is], pc)
		if it != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vi[it] = u16(q[k])}}
		}
	case 0x3f: // VISWR
		x := u32(v.vi[it])
		vu_store_q(v, v.vi[is], {x, x, x, x}, dest)
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
	case 0x70: v.p_next, v.p_wait = vclamp(cs.x * cs.x + cs.y * cs.y + cs.z * cs.z), VU_EFU_LATENCY[0x0] // ESADD
	case 0x71: v.p_next, v.p_wait = cpu.fdiv(1, cs.x * cs.x + cs.y * cs.y + cs.z * cs.z), VU_EFU_LATENCY[0x1] // ERSADD
	case 0x72: v.p_next, v.p_wait = math.sqrt(cs.x * cs.x + cs.y * cs.y + cs.z * cs.z), VU_EFU_LATENCY[0x2] // ELENG
	case 0x73: v.p_next, v.p_wait = cpu.frsqrt(1, cs.x * cs.x + cs.y * cs.y + cs.z * cs.z), VU_EFU_LATENCY[0x3] // ERLENG
	case 0x74: v.p_next, v.p_wait = math.atan(cpu.fdiv(cs.y, cs.x)), VU_EFU_LATENCY[0x4] // EATANxy
	case 0x75: v.p_next, v.p_wait = math.atan(cpu.fdiv(cs.z, cs.x)), VU_EFU_LATENCY[0x5] // EATANxz
	case 0x76: v.p_next, v.p_wait = vclamp(cs.x + cs.y + cs.z + cs.w), VU_EFU_LATENCY[0x6] // ESUM
	case 0x78: v.p_next, v.p_wait = math.sqrt(abs(cs[fsf])), VU_EFU_LATENCY[0x8] // ESQRT
	case 0x79: v.p_next, v.p_wait = cpu.frsqrt(1, cs[fsf]), VU_EFU_LATENCY[0x9] // ERSQRT
	case 0x7a: v.p_next, v.p_wait = cpu.fdiv(1, cs[fsf]), VU_EFU_LATENCY[0xa] // ERCPR
	case 0x7b: // WAITP
	case 0x7c: v.p_next, v.p_wait = math.sin(cs[fsf]), VU_EFU_LATENCY[0xc] // ESIN
	case 0x7d: v.p_next, v.p_wait = math.atan(cs[fsf]), VU_EFU_LATENCY[0xd] // EATAN
	case 0x7e: v.p_next, v.p_wait = vclamp(math.exp(-cs[fsf])), VU_EFU_LATENCY[0xe] // EEXP
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

// Status I/D bits for DIV-family ops of a / b: 0/0 is invalid (0x10), x/0
// divide by zero (0x20). Held in q_flags until the pair after the wait
// drops to VU_Q_FLAGS (vu_q_due).
@(private)
vu_div_bits :: proc "contextless" (a, b: f32) -> u32 {
	if b != 0 {return 0}
	return a == 0 ? 0x10 : 0x20
}

@(private)
vu_put_r :: proc(v: ^Vu, ft, dest: u32) {
	x := 0x3f800000 | v.r
	if ft != 0 {
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = x}}
	}
}

// Quadword `n` of a VU data memory (wrapping like the hardware).
// No bounds checks: keep the index reduced % len(v.mem). VU0 loads and
// stores go through vu_load_q and vu_store_q, for the window below.
vu_mem_q :: proc(v: ^Vu, n: u16) -> ^[4]u32 #no_bounds_check {
	o := (u32(n) * 16) % u32(len(v.mem))
	return (^[4]u32)(&v.mem[o])
}

// The quadword a load at address n reads: VU0's window onto VU1's
// registers when n has VU0_WINDOW set, else data memory. pc is the
// loading op's, as vu_op takes it.
vu_load_q :: proc(v: ^Vu, n: u16, pc: u32) -> [4]u32 {
	if v == &vu0 && n & VU0_WINDOW != 0 {return vu0_window_load(n, pc)}
	return vu_mem_q(v, n)^
}

// Store the dest lanes of x at address n, as vu_load_q reads it.
vu_store_q :: proc(v: ^Vu, n: u16, x: [4]u32, dest: u32) {
	if v == &vu0 && n & VU0_WINDOW != 0 {
		vu0_window_store(n, x, dest)
		return
	}
	q := vu_mem_q(v, n)
	for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {q[k] = x[k]}}
}

// A VU0 load or store whose quadword address has bit 0x400 set reaches
// VU1's registers, not VU0 data memory, mirrored every 0x40 quadwords:
// slot n & 0x3f is VF0-VF31 at 0-31, VI0-VI15 at 32-47 (the 16 bits in
// x; y, z and w read 0), status, MAC and clip at 48-50, R, I, Q and P at 52-55
// and TPC at 58. Other slots read 0. R reads as RNEXT and RGET see it,
// 0x3f800000 | r. This is the map of PCSX2's microVU (mVUaddrFix tests
// bit 0x400) over its VU register file, VF[32] then VI[32] with the
// control registers at VI[16] on.
VU0_WINDOW :: 0x400

// The quadword of window slot n & 0x3f, loaded by the op at pc (vu_op's).
vu0_window_load :: proc(n: u16, pc: u32) -> (q: [4]u32) {
	s := n & 0x3f
	switch s {
	case 0 ..< 32: q = vu1.vf[s].u
	case 32 ..< 48: q.x = u32(vu1.vi[s - 32])
	case 48:
		if pc == VU_PC_MACRO {vu1_status_read(.Macro, 0)} else {vu1_status_read(.Window, pc)}
		q.x = vu1.status
	case 49: q.x = vu1.mac
	case 50: q.x = vu1.clip
	case 52: q.x = 0x3f800000 | vu1.r
	case 53: q.x = transmute(u32)vu1.i
	case 54: q.x = transmute(u32)vu1.q
	case 55: q.x = transmute(u32)vu1.p
	case 58: q.x = vu1.tpc
	}
	return
}

// Store the dest lanes of x to window slot n & 0x3f. Only the registers a
// program can set land: VF1-VF31, VI1-VI15 (the low 16 bits of x), R (its
// 23 bits), I, Q and P, each from x but the VFs. The writes to VF0, VI0,
// status, MAC, clip and TPC are dropped: VF0 and VI0 are constants on the
// hardware, and PCSX2, which stores them all, marks clobbering them a
// problem in its own ToDo. Lanes y, z and w of the one-word registers are
// padding and also dropped.
vu0_window_store :: proc(n: u16, x: [4]u32, dest: u32) {
	s := n & 0x3f
	if s < 32 {
		if s == 0 {return}
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {vu1.vf[s].u[k] = x[k]}}
		return
	}
	if dest & 8 == 0 {return}
	switch s {
	case 33 ..< 48: vu1.vi[s - 32] = u16(x.x)
	case 52: vu1.r = x.x & 0x7fffff
	case 53: vu1.i = transmute(f32)x.x
	case 54: vu1.q = transmute(f32)x.x
	case 55: vu1.p = transmute(f32)x.x
	}
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

// A microprogram compiled to native code (recomp/vu/native.odin): it
// starts at native_run's pc with its budget and leaves the pc it stopped
// at, bit 31 set when it ended, and the budget left there.
Vu_Native :: #type proc()

// Micro memory a compiled program was compiled from: code at pc.
Vu_Range :: struct {
	pc:   u32,
	code: []u32,
}

@(private)
Vu_Program :: struct {
	ranges:   []Vu_Range,
	run:      Vu_Run,
	native:   Vu_Native, // run instead when set
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
	// A registered program reads status (FSEQ, FSAND, FSOR), so compiled
	// VU1 code keeps status exact (recomp/vu reads_status); VUCHECK then
	// compares it on VU1 too.
	status:     bool,
}

@(private)
vu0_table: Micro_Table(len(vu0_micro) / 8)
@(private)
vu1_table: Micro_Table(len(vu1_micro) / 8)

// vu_op's pc for a macro instruction, which has no micro address.
VU_PC_MACRO :: max(u32)

// Compiled VU1 code computes status only when a registered VU1 program
// reads it (Micro_Table.status; recomp/vu reads_status), as nothing else
// can on the gate discs. Once such code has run, VU1's status, sticky bits
// and all, is stale until the end of the run: a later read is one the
// elision did not foresee. It is a compat row (Vu1_Status) on every run,
// and said once on stderr.
vu1_status_stale: bool
@(private)
vu1_status_warned: bool

// Who read VU1's status after compiled code left it stale: a VU0 micro
// load through its window onto VU1's registers (VU0_WINDOW), an EE macro
// load the same way, or FSEQ, FSAND or FSOR in VU1 code the interpreter
// runs.
Vu_Status_Reader :: enum u32 {Window, Macro, Fs}

// Note a read of VU1's status by reader at pc (0 for Macro, which has no
// micro address) when it is stale.
vu1_status_read :: proc(reader: Vu_Status_Reader, pc: u32) {
	if !vu1_status_stale {return}
	core.compat_unknown(.Vu1_Status, u32(reader), pc, pc = pc)
	if !vu1_status_warned {
		vu1_status_warned = true
		fmt.eprintfln("vu1: status read (%v, pc %04x) after compiled code that does not compute it", reader, pc)
	}
}

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

// A program in native code (ps2/native.odin load_native, unless VUNATIVE=0),
// from the given runs of unit's micro memory.
vu_register_native :: proc(unit: int, ranges: []Vu_Range, native: Vu_Native) {
	if unit == 0 {
		micro_register(&vu0_table, ranges, nil, native)
	} else {
		micro_register(&vu1_table, ranges, nil, native)
	}
}

// Whether the program of ranges reads status: FSEQ, FSAND or FSOR (lower
// 0x14, 0x16, 0x17), not under an I bit.
vu_reads_status :: proc(ranges: []Vu_Range) -> bool {
	for r in ranges {
		for k := 0; k + 1 < len(r.code); k += 2 {
			op := r.code[k] >> 25
			if r.code[k + 1] & (1 << 31) == 0 && (op == 0x14 || op == 0x16 || op == 0x17) {return true}
		}
	}
	return false
}

// Whether a program of unit's with ranges, the same addresses and words,
// is registered.
vu_registered :: proc(unit: int, ranges: []Vu_Range) -> bool {
	same :: proc(t: ^Micro_Table($N), ranges: []Vu_Range) -> bool {
		if len(ranges) == 0 {return false}
		// Only programs with ranges[0]'s first pair as a candidate there.
		outer: for p in t.candidates[(ranges[0].pc / 8) % u32(N)] {
			if len(p.ranges) != len(ranges) {continue}
			for r, k in ranges {
				if p.ranges[k].pc != r.pc || !slice.equal(p.ranges[k].code, r.code) {continue outer}
			}
			return true
		}
		return false
	}
	return same(&vu0_table, ranges) if unit == 0 else same(&vu1_table, ranges)
}

// VU1's registered programs, and whether one reads status
// (Micro_Table.status).
vu1_programs :: proc() -> (n: int, status: bool) {
	return len(vu1_table.programs), vu1_table.status
}

// Candidates are longest first; of the same size, native code before Odin.
@(private)
micro_register :: proc(t: ^Micro_Table($N), ranges: []Vu_Range, run: Vu_Run, native: Vu_Native = nil) {
	context.allocator = core.long_allocator()
	p := new(Vu_Program)
	p.ranges = slice.clone(ranges)
	p.run = run
	p.native = native
	for r in ranges {p.size += len(r.code) / 2}
	t.status ||= vu_reads_status(ranges)
	append(&t.programs, p)
	for r in ranges {
		for k in 0 ..< len(r.code) / 2 {
			i := (r.pc / 8 + u32(k)) % u32(N)
			c := &t.candidates[i]
			if c.allocator.procedure == nil {c^ = make([dynamic]^Vu_Program)}
			at := len(c)
			for at > 0 && (c[at - 1].size < p.size || (c[at - 1].size == p.size && native != nil && c[at - 1].native == nil)) {at -= 1}
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
	when VU_STALL_COUNT {
		for st, k in vu_stalls {
			fmt.eprintfln("vu%d: %d flag reads, %d with an FMAC stall in their window", k, st.reads, st.stalled)
		}
	}
}

@(private)
micro_stats_print :: proc(unit: int, programs: []^Vu_Program) {
	for p, k in programs {
		if p.runs == 0 && p.checks == 0 {continue}
		fmt.eprintfln("vu%d program %d at %04x, %d pairs%s: %d runs, %d checks, %d misses",
			unit, k, p.ranges[0].pc, p.size, p.native != nil ? ", native" : "", p.runs, p.checks, p.misses)
	}
}

// Run a VU1 microprogram to its E bit. The VU runs synchronously with the
// EE, without pipeline timing: results are visible to the next pair, and
// flags to reads four pairs on (the header).
vu1_start :: proc(addr: u32) {
	t := cpu.prof_start()
	defer cpu.prof_end(.VU1, t)
	if vu1_cap.on {vu_capture(&vu1, addr)}
	if vu_check && vu1_lookup(addr & u32(len(vu1_micro) - 1) &~ 7) != nil {
		vu1_compare(addr)
		return
	}
	vu1_exec(addr, true)
}

@(private)
vu1_exec :: proc(addr: u32, compiled: bool) {
	#force_no_inline vu1_run(addr, compiled)
	vu1_kick_flush() // the program stopped: at the E bit's end, or at the step limit
}

// vu1_exec without the XGKICK flush. Kept a procedure of its own, not
// inlined: with the flush call in the same body as micro_exec's inlined
// loop the interpreter ran more instructions per pair.
@(private)
vu1_run :: proc(addr: u32, compiled: bool) {
	pc, ended, _ := micro_exec(&vu1, &vu1_table, &vu1_micro_gen, vu1_pairs[:], addr, compiled, false)
	vu_drain(&vu1)
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
// including what compiled code hands back. With park, a constant, the
// interpreter may stop at a loop that can never end by itself (parked).
@(private)
micro_exec :: #force_inline proc(v: ^Vu, t: ^Micro_Table($N), gen: ^u32, pairs: []Vu_Pair_Info, addr: u32, compiled: bool, park: bool) -> (pc: u32, ended: bool, parked: bool) #no_bounds_check {
	mask := u32(len(v.micro) - 1) &~ 7
	pc = addr & mask
	vu_flags_seed(v)
	v.vih = {}
	if t.stop_gen != gen^ {
		t.stop_gen = gen^
		t.stop = t.compiled
	}
	stop := compiled ? t.stop[:] : nil
	budget := VU_STEP_LIMIT
	for budget > 0 {
		// A program that hands back a pair it compiles leaves that pair to
		// the interpreter. Compiled code starts with no Q or P pending
		// (recomp/vu's demand_waits): until both land, the interpreter runs.
		last: ^Vu_Program
		for compiled && t.stop[pc / 8] && v.q_wait | v.p_wait == 0 {
			prog := micro_lookup(t, v.micro, gen^, pc)
			if prog == nil || prog == last {break}
			last = prog
			prog.runs += 1
			exit: Vu_Exit
			when cpu.FALLBACK_COUNT {entry, before := pc, budget}
			if prog.native != nil {
				nr := &native_run[v == &vu0 ? 0 : 1]
				nr.pc, nr.budget = i32(pc), i32(budget)
				prog.native()
				budget = int(nr.budget)
				exit = nr.pc < 0 ? .End : .Leave // bit 31
				pc = u32(nr.pc)
			} else {
				pc, exit = prog.run(pc, &budget)
			}
			pc &= mask
			// A miss capture records where compiled code hands back to
			// the interpreter with no other program to run (vu_capture).
			if exit == .Leave && capture_of(v).on {vu_capture(v, pc, prog)}
			// Left at once from where it was entered: no case label there.
			when cpu.FALLBACK_COUNT {
				if compiled && exit == .Leave && pc == entry && budget == before {
					index := 0
					for q, k in t.programs {if q == prog {index = k}}
					cpu.fallback_vu_unlabelled[{v == &vu0 ? 0 : 1, u32(index), pc}] += 1
				}
			}
			if v == &vu1 && !t.status {vu1_status_stale = true}
			if exit == .End {return pc, true, false}
			if budget <= 0 {break}
		}
		if budget <= 0 {break}
		when cpu.FALLBACK_COUNT {left, from := budget, pc}
		pc, ended, parked = vu_interp(v, pairs, pc, stop, &budget, park)
		// VUCHECK's interpreter-only run is not counted.
		when cpu.FALLBACK_COUNT {
			if compiled {
				n := u64(left - budget)
				if v == &vu0 {
					cpu.fallback_vu0_micro += n
					cpu.fallback_vu0_micro_at[from / 8] += n
				} else {
					cpu.fallback_vu1_micro += n
					cpu.fallback_vu1_micro_at[from / 8] += n
				}
			}
		}
		if ended || parked {return}
	}
	return pc, false, false
}

// Interpret from pc for at least one pair, until the program ends or
// control reaches a pair marked in `stop` (compiled code may run there)
// with no branch, end, Q or P pending. Inlined into micro_exec.
// No bounds checks: callers pass a masked pc, every later pc is masked, and
// pairs holds one entry per pair of v.micro; stop is checked against len.
//
// With park, the loop a microprogram waits in for the EE stops the run
// (parked, at the loop's first pair) instead of using up the budget. The
// test is exact: a jump lands where the jump before it landed, and every
// pair run in between was idle (Vu_Pair_Info.idle), so the registers the
// branches read are what they were and the same pairs would run for ever.
// Q, P and the flags are left as that endless run leaves them: nothing
// pending, the pipeline drained.
@(private)
vu_interp :: #force_inline proc(v: ^Vu, pairs: []Vu_Pair_Info, pc: u32, stop: []bool, budget: ^int, park: bool) -> (u32, bool, bool) #no_bounds_check {
	mask := u32(len(v.micro) - 1) &~ 7
	pc := pc
	jumping, ending := false, false
	target: u32
	land := ~u32(0) // where the last jump landed
	idle := false // every pair since then was idle
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
		when VU_STALL_COUNT {vu_stall_count(v, uw, lw)}
		vu_before(v, uw, lw)
		pre := [3]u32{v.mac, v.status, v.clip}
		e := info.vih
		if e & VIH_WRITE != 0 {e |= u32(v.vi[(e >> 16) & 15])}
		vu_q_due(v)
		if info.serial {
			vu_op(v, uw)
			taken, dst = vu_lower(v, lw, pc)
		} else {
			taken, dst = vu_pair(v, uw, lw, pc)
		}
		vu_flags_shift(v, pre)
		vu_tick(v)
		v.vih = {e, v.vih[0], v.vih[1], v.vih[2]}
		if park && !info.idle {idle = false}
		if jumping { // that was the delay slot
			next = target & mask
			jumping = false
			v.vih = {}
			if park && !taken {
				if next == land && idle && v.q_wait | v.p_wait | v.q_due == 0 {
					vu_flags_seed(v)
					return next, false, true
				}
				land, idle = next, true
			}
		}
		if taken {
			jumping = true
			target = dst
		}
		if ending {return next, true, false}
		if uw & (1 << 30) != 0 {ending = true}
		pc = next
		if !jumping && !ending && v.q_wait | v.p_wait == 0 && int(pc / 8) < len(stop) && stop[pc / 8] {break}
	}
	return pc, false, false
}

// A microprogram starts with the pipeline drained: every older flag is the
// newest.
@(private)
vu_flags_seed :: proc "contextless" (v: ^Vu) {
	v.old_mac = v.mac
	v.old_status = v.status
	v.old_clip = v.clip
}

// Q latency (VU User's Manual, FDIV unit; PCSX2 microVU analyzeQreg and
// mVUincCycles): DIV and SQRT write Q 7 cycles after they issue, RSQRT 13,
// so with no stall the pair VU_Q_DIV (VU_Q_RSQRT) after the DIV is the
// first to read the new Q and the ones before read the old. The FDIV unit
// keeps one op: a WAITQ, or a DIV, SQRT or RSQRT while one is pending,
// stalls until it lands (q_wait cycles, as microVU's mVUanalyzeFDIV and
// WAITQ stall regs.q), and that pair's upper op reads the new Q. Status I
// and D of the op are set by the first pair to start after its wait drops
// to VU_Q_FLAGS, after that pair's stall, as microVU's mVUincCycles sets
// doDivFlag once q is 4 or less (counting the pair's own cycle and its
// stall) and mVUdivSet then writes them into that pair's status: the third
// pair after a DIV or SQRT, the ninth after an RSQRT, so with no stall FSAND
// reads the non-sticky bit at +7 (+13) and the sticky one at +3 (+9). The end of a microprogram (E bit) drains the unit, as microVU's
// mVUendProgram does, and macro mode reads the newest Q and status. Every
// backend runs vu_before before a pair and vu_tick after it, compiled code
// only where a DIV or an EFU op can be pending.
VU_Q_DIV :: 7
VU_Q_RSQRT :: 13
VU_Q_FLAGS :: 4

// P latency per EFU op key - 0x70 (PCSX2 microVU_Lower.inl, the
// mVUanalyzeEFU1/EFU2 counts; 0 for 0x77 and WAITP, which issue nothing):
// with no stall the pair that many after the op is the first whose MFP
// reads the new P. The EFU keeps one op: a WAITP, or an EFU op while one
// is pending, stalls until one cycle is left (microVU's analyzePreg:
// p - 1), so the pair after a WAITP reads the new P, and a new EFU op lands
// the old result and issues. VU0 has no EFU, so P never waits there.
VU_EFU_LATENCY :: [15]u32 {
	11, // ESADD
	18, // ERSADD
	18, // ELENG
	24, // ERLENG
	54, // EATANxy
	54, // EATANxz
	12, // ESUM
	0,
	12, // ESQRT
	18, // ERSQRT
	12, // ERCPR
	0, // WAITP
	29, // ESIN
	54, // EATAN
	44, // EEXP
}

// Before pair (uw, lw) runs: its stall, if its lower op (no I bit) waits
// for the FDIV unit (WAITQ, DIV, SQRT, RSQRT) or the EFU (WAITP, an EFU
// op), and an EFU op's landing of the pending P.
@(private)
vu_before :: #force_inline proc "contextless" (v: ^Vu, uw, lw: u32) {
	if v.q_wait | v.p_wait == 0 || uw & (1 << 31) != 0 || lw >> 25 != 0x40 || lw & 0x3c != 0x3c {return}
	switch ((lw >> 4) & 0x7c) | (lw & 3) {
	case 0x38 ..= 0x3b: if v.q_wait != 0 {vu_wait(v, v.q_wait)}
	case 0x7b: if v.p_wait > 1 {vu_wait(v, v.p_wait - 1)}
	case 0x70 ..= 0x76, 0x78 ..= 0x7a, 0x7c ..= 0x7e:
		if v.p_wait > 1 {vu_wait(v, v.p_wait - 1)}
		if v.p_wait != 0 {v.p, v.p_wait = v.p_next, 0}
	}
}

// s stall cycles: each shifts the flags as an empty pair would and moves
// the pending Q and P on.
vu_wait :: proc "contextless" (v: ^Vu, s: u32) {
	for _ in 0 ..< s {
		vu_flags_shift(v, {v.mac, v.status, v.clip})
		vu_tick(v)
	}
}

// One cycle of the FDIV unit and the EFU, after a pair or a stall cycle.
@(private)
vu_tick :: #force_inline proc "contextless" (v: ^Vu) {
	if v.q_wait != 0 {
		v.q_wait -= 1
		if v.q_wait == VU_Q_FLAGS {
			v.q_due = 1
		} else if v.q_wait == 0 {
			v.q = v.q_next
		}
	}
	if v.p_wait != 0 {
		v.p_wait -= 1
		if v.p_wait == 0 {v.p = v.p_next}
	}
}

// Land the pending Q and P, setting I and D if not yet set: at the E-bit
// end, and before macro or EE code reads the registers.
vu_drain :: #force_inline proc "contextless" (v: ^Vu) {
	if v.q_due != 0 || v.q_wait > VU_Q_FLAGS {vu_q_flags(v)}
	if v.q_wait != 0 {v.q = v.q_next}
	v.q_wait, v.q_due = 0, 0
	if v.p_wait != 0 {v.p, v.p_wait = v.p_next, 0}
}

// I and D due from the FDIV unit, set at the start of a pair, after its
// stall and once the flags it starts with are taken.
vu_q_due :: #force_inline proc "contextless" (v: ^Vu) {
	if v.q_due != 0 {
		vu_q_flags(v)
		v.q_due = 0
	}
}

// Status I and D, each also sticky (bits 10 and 11), from q_flags.
@(private)
vu_q_flags :: #force_inline proc "contextless" (v: ^Vu) {
	v.status = (v.status &~ 0x30) | v.q_flags | v.q_flags << 6
}

// After a pair, which started with flags pre (MAC, status, clip): each
// flag's older values move back one. Every backend does this once per pair;
// compiled code only for the values a later read or an exit can see.
@(private)
vu_flags_shift :: #force_inline proc "contextless" (v: ^Vu, pre: [3]u32) {
	v.old_mac = {pre[0], v.old_mac[0], v.old_mac[1]}
	v.old_status = {pre[1], v.old_status[0], v.old_status[1]}
	v.old_clip = {pre[2], v.old_clip[0], v.old_clip[1]}
}

// -define:VU_STALL_COUNT=true counts, per VU, the flag reads the
// interpreter runs (VUNOCOMP=1 sends every pair there) and those whose
// window holds an FMAC stall, which the four-pair delay does not model: a
// pair reading a VF register an upper op of one of the three pairs before
// it writes, at that pair or one of the three before. Registers, not
// lanes, and every fs and ft field counts as read, so it is an upper bound.
VU_STALL_COUNT :: #config(VU_STALL_COUNT, false)

@(private)
Vu_Stalls :: struct {
	dests:          [3]u32, // the VF register each of the last three upper ops wrote, newest first
	window:         u8, // bit k: the pair k back stalled
	reads, stalled: u64,
}
@(private)
vu_stalls: [2]Vu_Stalls

@(private)
vu_stall_count :: proc(v: ^Vu, uw, lw: u32) {
	st := &vu_stalls[v == &vu0 ? 0 : 1]
	ibit := uw & (1 << 31) != 0
	waits :: proc(st: ^Vu_Stalls, r: u32) -> bool {
		return r != 0 && (st.dests[0] == r || st.dests[1] == r || st.dests[2] == r)
	}
	stall := uw & 0x7ff != 0x2ff && (waits(st, (uw >> 11) & 31) || waits(st, (uw >> 16) & 31))
	if !ibit && (lw >> 25 == 0x01 || (lw >> 25 == 0x40 && lw & 63 >= 0x3c)) {
		stall ||= waits(st, (lw >> 11) & 31) || (lw >> 25 == 0x40 && waits(st, (lw >> 16) & 31))
	}
	st.window = (st.window << 1 | u8(stall)) & 0xf
	switch lw >> 25 {
	case 0x10, 0x12, 0x13, 0x14, 0x16, 0x17, 0x18, 0x1a, 0x1b, 0x1c:
		if ibit {break}
		st.reads += 1
		if st.window != 0 {st.stalled += 1}
	}
	st.dests = {vu_upper_dest(uw), st.dests[0], st.dests[1]}
}

// VUCHECK: run the interpreter, then the compiled code from the same
// state, and compare (vu_compare).
@(private)
vu0_compare :: proc(addr: u32) {
	@(static) mem0, mem1: [len(vu0_mem)]u8
	vu_compare(&vu0, vu0_mem[:], mem0[:], mem1[:], vu0_table.programs[:], true, vu0_lookup(addr & u32(len(vu0_micro) - 1) &~ 7), addr, vu0_exec)
}
@(private)
vu1_compare :: proc(addr: u32) {
	@(static) mem0, mem1: [len(vu1_mem)]u8
	vu_compare(&vu1, vu1_mem[:], mem0[:], mem1[:], vu1_table.programs[:], vu1_table.status, vu1_lookup(addr & u32(len(vu1_micro) - 1) &~ 7), addr, vu1_exec)
}

// Run v's program at addr with exec in the interpreter, then compiled from
// the same state with XGKICK muted, and report differences; mem is v's data
// memory, mem0 and mem1 scratch of its size, entry the program compiled at
// addr. Status is compared when status is set: always on VU0, and on VU1
// only once a program reads it (Micro_Table.status); compiled VU1 code
// leaves it alone otherwise. The interpreter's results are kept.
@(private)
vu_compare :: proc(v: ^Vu, mem, mem0, mem1: []u8, programs: []^Vu_Program, status: bool, entry: ^Vu_Program, addr: u32, exec: proc(addr: u32, compiled: bool)) {
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
	status_bad := status && (v1.status != v2.status || v1.q_flags != v2.q_flags)
	mem_bad := !slice.equal(mem, mem1)
	prog := -1
	for p, k in programs {if p == entry {prog = k}}
	bad := kick1 != kick2 || mem_bad || vf_bad || v1.vi != v2.vi ||
		v1.acc.q != v2.acc.q || v1.q != v2.q || v1.q_next != v2.q_next || v1.q_wait != v2.q_wait || v1.q_due != v2.q_due || v1.p != v2.p ||
		v1.p_next != v2.p_next || v1.p_wait != v2.p_wait || v1.i != v2.i ||
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
// A whole pair, so these stall, shift the flags and tick Q and P too, as
// vu_interp does.
vu0_pair :: proc(uw, lw, pc: u32) {
	when cpu.FALLBACK_COUNT {cpu.fallback_vu0_pair += 1}
	vu_before(&vu0, uw, lw)
	pre := [3]u32{vu0.mac, vu0.status, vu0.clip}
	vu_q_due(&vu0)
	vu_pair(&vu0, uw, lw, pc)
	vu_flags_shift(&vu0, pre)
	vu_tick(&vu0)
}
// s stall cycles before a pair, for compiled code: as vu_before stalls.
vu0_wait :: proc(s: u32) {vu_wait(&vu0, s)}
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
	vu_before(&vu1, uw, lw)
	pre := [3]u32{vu1.mac, vu1.status, vu1.clip}
	vu_q_due(&vu1)
	vu_pair(&vu1, uw, lw, pc)
	vu_flags_shift(&vu1, pre)
	vu_tick(&vu1)
}
// s stall cycles before a pair, for compiled code: as vu_before stalls.
vu1_wait :: proc(s: u32) {vu_wait(&vu1, s)}

// The branch VI delay (PCSX2 microVU's analyzeBranchVI): when the pair
// right before an IBEQ, IBNE, IBLTZ, IBGTZ, IBLEZ or IBGEZ writes one of
// its VI sources other than vi0, the branch reads that VI as it was before
// the earliest pair to write it among the up to four pairs before the
// branch. Pairs that leave the VI alone do not end the look back. A pair
// that writes it from the flags (FSAND and the other flag reads, FCGET)
// ends it, keeping the value found so far, and right before the branch
// means no delay. So does the start of a block: the microprogram's start, a
// pair control reaches by a jump, and the pair after a branch's delay
// slot. JR and JALR read the newest VI. Unlike microVU, nothing carries
// over from the block before.
//
// Every backend keeps the pairs it runs in Vu.vih, newest first, as VIH
// entries: VIH_PAIR, plus for a pair whose lower op writes a VI, VIH_WRITE,
// the VI's number at bit 16, its value before the pair in the low 16 bits,
// and VIH_FLAGS for a flag read. A jump or the microprogram's start clears
// it. The interpreter enters every pair; compiled code only the ones a
// branch it compiles can look back to (recomp/vu's delay_pairs), as no
// other branch reads them.
VIH_WRITE :: 1 << 20
VIH_FLAGS :: 1 << 21
VIH_PAIR :: 1 << 22

// Pair (uw, lw)'s VIH entry, without the old value. As recomp/vu's
// vih_entry.
@(private)
vih_entry :: proc "contextless" (uw, lw: u32) -> u32 {
	if uw & (1 << 31) != 0 {return VIH_PAIR}
	it, is := (lw >> 16) & 15, (lw >> 11) & 15
	n, flags := u32(0), false
	switch lw >> 25 {
	case 0x04, 0x08, 0x09: n = it // ILW, IADDIU, ISUBIU
	case 0x10, 0x12, 0x13: n, flags = 1, true // FCEQ, FCAND, FCOR
	case 0x14, 0x16, 0x17, 0x18, 0x1a, 0x1b, 0x1c: n, flags = it, true // FS*, FM*, FCGET
	case 0x40:
		switch lw & 63 {
		case 0x30, 0x31, 0x34, 0x35: n = (lw >> 6) & 31 // IADD, ISUB, IAND, IOR: fd
		case 0x32: n = (lw >> 16) & 31 // IADDI
		case 0x3c ..= 0x3f:
			switch ((lw >> 4) & 0x7c) | (lw & 3) {
			case 0x34, 0x36: n = is // LQI, LQD
			case 0x35, 0x37, 0x3c, 0x3e: n = it // SQI, SQD, MTIR, ILWR
			}
		}
	}
	if n == 0 {return VIH_PAIR}
	return VIH_PAIR | VIH_WRITE | (n & 15) << 16 | (flags ? VIH_FLAGS : 0)
}

// The value of vi[reg] the conditional branch at pc compares, from v.vih.
// Every backend's conditional branches read their VIs through it.
vi_branch :: proc "contextless" (v: ^Vu, reg, pc: u32) -> u16 #no_bounds_check {
	n := reg & 15
	x := v.vi[n]
	mask := u32(len(v.micro) - 1) &~ 7
	if n == 0 || vu_after_slot(v, pc, mask) {return x}
	for k in u32(0) ..< 4 {
		e := v.vih[k]
		if e & VIH_PAIR == 0 {break} // a jump or the start
		if e & VIH_WRITE != 0 && (e >> 16) & 15 == n {
			if e & VIH_FLAGS != 0 {break}
			x = u16(e)
		} else if k == 0 {
			break
		}
		if vu_after_slot(v, pc - 8 * (k + 1), mask) {break}
	}
	return x
}

// Whether the pair at pc follows a branch's delay slot: two pairs before it
// in micro memory is a branch, which starts a block where it runs.
@(private)
vu_after_slot :: proc "contextless" (v: ^Vu, pc, mask: u32) -> bool #no_bounds_check {
	at := (pc - 16) & mask
	if (^u32)(&v.micro[at + 4])^ & (1 << 31) != 0 {return false} // I bit
	switch (^u32)(&v.micro[at])^ >> 25 {
	case 0x20, 0x21, 0x24, 0x25, 0x28, 0x29, 0x2c ..= 0x2f: return true
	}
	return false
}

// For native code, whose calls return nothing: the values of vi[it] and
// vi[is] conditional branch lw at pc compares (vi_branch), as u16s at the
// unit's Native_Run scratch offsets 0 and 2.
vu0_branch_vi :: proc(lw, pc: u32) {vu_branch_vi(&vu0, 0, lw, pc)}
vu1_branch_vi :: proc(lw, pc: u32) {vu_branch_vi(&vu1, 1, lw, pc)}
@(private)
vu_branch_vi :: proc(v: ^Vu, u: int, lw, pc: u32) {
	s := (^[2]u16)(&native_run[u].scratch)
	s^ = {vi_branch(v, lw >> 16, pc), vi_branch(v, lw >> 11, pc)}
}

// What decoding a pair tells the interpreter, cached per micro address and
// tagged with the words so uploads need no invalidation.
@(private)
Vu_Pair_Info :: struct {
	uw, lw: u32,
	valid:  bool,
	serial: bool, // running upper then lower gives the same result as vu_pair
	idle:   bool, // writes no state: vu_pair_idle
	vih:    u32, // vih_entry
}

// Whether a pair writes no state at all, so a loop of such pairs never
// ends by itself (vu_interp's park): a NOP upper with no I, E, M, D or T
// bit over a branch that links nothing (B, IBEQ, IBNE, IBLTZ, IBGTZ,
// IBLEZ, IBGEZ) or a MOVE with no field to write, the lower NOP.
@(private)
vu_pair_idle :: proc(uw, lw: u32) -> bool {
	if uw != 0x000002ff {return false}
	switch lw >> 25 {
	case 0x20, 0x28, 0x29, 0x2c ..= 0x2f: return true
	}
	return lw & 0xffe007ff == 0x8000033c
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
	info := Vu_Pair_Info{uw = uw, lw = lw, valid = true, idle = vu_pair_idle(uw, lw), vih = vih_entry(uw, lw)}
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
	// The flag reads see the flags after the pair four back (the header);
	// FSSET and the sticky status bits act on the newest.
	clip, mac := v.old_clip[2], v.old_mac[2]
	status := (v.old_status[2] & 0x3f) | (v.status & 0xfc0)
	switch w >> 25 {
	case 0x00: // LQ
		q := vu_load_q(v, vi[is] + imm11, pc)
		if ft != 0 {
			for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {v.vf[ft].u[k] = q[k]}}
		}
	case 0x01: // SQ
		vu_store_q(v, vi[it] + imm11, v.vf[fs].u, dest)
	case 0x04: // ILW
		q := vu_load_q(v, vi[is] + imm11, pc)
		for k in 0 ..< 4 {if dest & (8 >> u32(k)) != 0 {set_vi(vi, it, u16(q[k]))}}
	case 0x05: // ISW
		x := u32(vi[it])
		vu_store_q(v, vi[is] + imm11, {x, x, x, x}, dest)
	case 0x08: set_vi(vi, it, vi[is] + imm15) // IADDIU
	case 0x09: set_vi(vi, it, vi[is] - imm15) // ISUBIU
	case 0x10: vi[1] = u16(clip & 0xffffff == imm24) // FCEQ
	case 0x11: v.clip = imm24 // FCSET
	case 0x12: vi[1] = u16(clip & imm24 != 0) // FCAND
	case 0x13: vi[1] = u16((clip | imm24) & 0xffffff == 0xffffff) // FCOR
	case 0x14: // FSEQ
		if v == &vu1 {vu1_status_read(.Fs, pc)}
		set_vi(vi, it, u16(status & 0xfff == imm12))
	case 0x15: v.status = (v.status & 0x3f) | (imm12 & 0xfc0) // FSSET
	case 0x16: // FSAND
		if v == &vu1 {vu1_status_read(.Fs, pc)}
		set_vi(vi, it, u16(status & imm12))
	case 0x17: // FSOR
		if v == &vu1 {vu1_status_read(.Fs, pc)}
		set_vi(vi, it, u16((status | imm12) & 0xfff == 0xfff))
	case 0x18: set_vi(vi, it, u16(mac & 0xffff == u32(vi[is]))) // FMEQ
	case 0x1a: set_vi(vi, it, u16(mac) & vi[is]) // FMAND
	case 0x1b: set_vi(vi, it, u16((mac | u32(vi[is])) & 0xffff == 0xffff)) // FMOR
	case 0x1c: set_vi(vi, it, u16(clip & 0xfff)) // FCGET
	case 0x20: return true, branch // B
	case 0x21: // BAL
		set_vi(vi, it, u16((pc + 16) / 8))
		return true, branch
	case 0x24: // JR
		t := u32(vi[is]) * 8
		if capture_of(v).on {vu_capture(v, t)}
		return true, t
	case 0x25: // JALR
		t := u32(vi[is]) * 8
		if capture_of(v).on {vu_capture(v, t)}
		set_vi(vi, it, u16((pc + 16) / 8))
		return true, t
	case 0x28: return vi_branch(v, it, pc) == vi_branch(v, is, pc), branch // IBEQ
	case 0x29: return vi_branch(v, it, pc) != vi_branch(v, is, pc), branch // IBNE
	case 0x2c: return i16(vi_branch(v, is, pc)) < 0, branch // IBLTZ
	case 0x2d: return i16(vi_branch(v, is, pc)) > 0, branch // IBGTZ
	case 0x2e: return i16(vi_branch(v, is, pc)) <= 0, branch // IBLEZ
	case 0x2f: return i16(vi_branch(v, is, pc)) >= 0, branch // IBGEZ
	case 0x40: vu_op(v, w, pc)
	case:
		cpu.fatal("vu%d: unknown lower op %08x at %04x", v == &vu1 ? 1 : 0, w, pc)
	}
	return
}

@(private)
vu1_kick_hash: u64
@(private)
vu1_kick_mute: bool

// An XGKICK whose packet has not been read yet, and its address. Empty
// whenever no VU1 program runs: vu1_exec sends it when the program stops.
vu1_kick_latched: bool
vu1_kick_addr: u16
// A packet was dropped (vu1_kick_send); reported once.
vu1_kick_dropped: bool

// XGKICK: send the GIF packet at quadword `addr` of VU1 memory down PATH1.
// The GIF does not read the packet at the instruction: it starts a cycle on
// and reads while the program runs, so a program may kick first and store
// the tag (its EOP, say) in the pairs that follow. The kick is latched here
// and the packet read when the program stops (vu1_exec) or kicks again,
// whichever comes first. The interpreter, emitted and native code all call
// this.
vu1_xgkick :: proc(addr: u16) {
	vu1_kick_flush()
	vu1_kick_addr, vu1_kick_latched = addr, true
}

// Send the latched XGKICK, if any.
vu1_kick_flush :: proc() {
	if !vu1_kick_latched {return}
	vu1_kick_latched = false
	vu1_kick_send(vu1_kick_addr)
}

// Send the packet at quadword `addr` down PATH1, following tags to the one
// with EOP. The packet is fed to the GIF straight out of VU1 memory, split
// where it wraps past the end. gif_feed keeps no pointer into the data past
// the call and raises interrupts only as pending, so nothing writes VU1
// memory while the packet is read.
//
// A walk that passes the size of VU1 memory without meeting EOP is not a
// packet: nothing is fed, so PATH1 does not keep the GIF waiting for an end
// that never comes. PCSX2 does the same: Gif_Unit::GetGSPacketSize
// (Gif_Unit.h) gives size 0 for a PATH1 packet as large as VU memory, and
// _vuXGKICKTransfer (VUops.cpp) ends the transfer on size 0.
@(private)
vu1_kick_send :: proc(addr: u16) {
	qwords := u32(len(vu1_mem) / 16)
	start := u32(addr) % qwords
	a := start
	total: u32 = 0
	eop := false
	for total < qwords && !eop {
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
		eop = lo & 0x8000 != 0
	}
	if !eop {
		if vu_check {vu1_kick_hash = (vu1_kick_hash ~ 0xd809) * 0x100000001b3}
		if !vu1_kick_dropped {
			vu1_kick_dropped = true
			fmt.eprintfln("vu1: XGKICK at %03x has no EOP within VU1 memory, dropped", start)
		}
		return
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
		gif.gif_feed(0, vu1_mem[a * 16:][:seg * 16]) // PATH1
		a = (a + seg) % qwords
		left -= seg
	}
}

// Run a VU0 microprogram (VCALLMS, VCALLMSR, VIF0 MSCAL) to its E bit, as
// vu1_start: compiled programs (rec/vu0) where they hold, the interpreter
// elsewhere. Like VU1 it runs synchronously, so VU0 is not busy when the
// EE next looks: the EE is charged no cycles, where hardware would stall it
// only for a VCALLMS while VU0 still runs or a QMFC2.I/CFC2.I that waits
// for the end. No state outlives the call but tpc and the registers.
//
// The exception is a program that waits for the EE: one in a loop of idle
// pairs that only a CTC2 to an integer register can end. The interpreter
// parks it there (vu_interp): tpc is the loop, vu0_parked is set and
// VPU-STAT reads VU0 as running, until a CTC2 to vi1-vi15 lets it go on
// (vu0_ctrl_write) to its E bit or to its next such loop. A VCALLMS,
// VCALLMSR or MSCAL meanwhile starts the new program and drops the parked
// one, where hardware would first let it end. A macro operation or an
// interlocked CFC2 or CTC2 meanwhile runs at once against the parked
// registers, where hardware would wait for the program's end or M bit.
// Compiled code never parks: such a loop inside a compiled program still
// runs to the step limit.
vu0_call_micro :: proc(addr: u32) {
	cpu.spin_dirty |= cpu.SPIN_SIDE // the spin skip's probe (ps2/spin.odin)
	if vu0_parked {vu0_park_note(.Call)}
	t := cpu.prof_start()
	defer cpu.prof_end(.VU0, t)
	if vu0_cap.on {vu_capture(&vu0, addr)}
	if vu_check && vu0_lookup(addr & u32(len(vu0_micro) - 1) &~ 7) != nil {
		vu0_compare(addr)
		return
	}
	vu0_exec(addr, true)
}

@(private)
vu0_exec :: proc(addr: u32, compiled: bool) {
	pc, ended, parked := micro_exec(&vu0, &vu0_table, &vu0_micro_gen, vu0_pairs[:], addr, compiled, true)
	vu_drain(&vu0)
	vu0_parked = parked
	if !ended && !parked && !vu0_overrun {
		vu0_overrun = true
		fmt.eprintfln("vu0: microprogram at %04x ran %d steps without ending", addr, VU_STEP_LIMIT)
	}
	vu0.tpc = pc
}

// Whether VU0's microprogram is parked in a loop that waits for the EE
// (vu0_call_micro); vu0.tpc is the loop then.
vu0_parked: bool

// What ran over a parked VU0 without waiting for it, each kind shown once
// under PS_DEBUG; not state.
Vu_Park_Note :: enum {
	Call, // VCALLMS, VCALLMSR, MSCAL: the parked program is dropped
	Macro, // a COP2 macro operation
	Interlock, // CFC2 or CTC2 with the interlock bit
}
@(private)
vu0_park_noted: bit_set[Vu_Park_Note]

vu0_park_note :: proc(what: Vu_Park_Note) {
	if cpu.debug < 1 || what in vu0_park_noted {return}
	vu0_park_noted += {what}
	@(static, rodata) text := [Vu_Park_Note]string {
		.Call      = "a new microprogram starts: the parked one is dropped",
		.Macro     = "a macro operation runs without waiting for it",
		.Interlock = "an interlocked CFC2 or CTC2 runs without waiting for it",
	}
	fmt.eprintfln("vu0: parked at %04x, %s", vu0.tpc, text[what])
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
	core.snap_add(&vu0_parked)
	core.snap_add(&vu1_overrun)
	core.snap_add(&vu1_status_stale)
	core.snap_add(&vu0_micro_gen)
	core.snap_add(&vu1_micro_gen)
	core.snap_add(&vu0_pairs)
	core.snap_add(&vu1_pairs)
	core.snap_add(&vu1_kick_hash)
	core.snap_add(&vu1_kick_mute)
	core.snap_add(&vu1_kick_latched)
	core.snap_add(&vu1_kick_addr)
	core.snap_add(&vu1_kick_dropped)
}
