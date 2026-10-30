// Interpreter for the instructions the recompiler leaves to the runtime:
// MMI (128-bit multimedia), COP0, FPU control, COP2 transfers and VU0 macro
// mode, SA register moves and traps.
package ps2

import "ps:core"
import cpu "cpu"
import kernel "kernel"
import mem "mem"
import r5900 "r5900"
import vu "vu"

@(private)
sat16 :: #force_inline proc(v: i32) -> u16 {return u16(i16(clamp(v, -0x8000, 0x7fff)))}
@(private)
sat8 :: #force_inline proc(v: i32) -> u8 {return u8(i8(clamp(v, -0x80, 0x7f)))}
@(private)
sat32 :: #force_inline proc(v: i64) -> u32 {return u32(i32(clamp(v, i64(min(i32)), i64(max(i32)))))}

exec :: proc(pc, w: u32) {
	exec_insn(r5900.decode(pc, w))
}

// Generated code passes the instruction already decoded.
exec_insn :: proc(i: r5900.Insn) #no_bounds_check {
	when cpu.FALLBACK_COUNT {cpu.fallback_ee[i.op] += 1}
	when core.COMPAT_COUNT {core.compat.interp_insns += 1}
	pc, w := i.pc, i.w
	c := &cpu.state
	s := c.r[i.rs]
	t := c.r[i.rt]
	d: cpu.Gpr
	write_rd := true
	switch i.op {
	// The low doubleword of rd only; the high one stays, as for MFHI.
	case .MFSA: if i.rd != 0 {c.r[i.rd].d[0] = u64(c.sa)}; write_rd = false
	case .MTSA: c.sa = u32(s.d[0]) & 127; write_rd = false
	case .MTSAB: c.sa = ((u32(s.d[0]) ~ u32(i.imm)) & 15) * 8; write_rd = false
	case .MTSAH: c.sa = ((u32(s.d[0]) ~ u32(i.imm)) & 7) * 16; write_rd = false
	case .TGE, .TGEU, .TLT, .TLTU, .TEQ, .TNE, .TRAPI:
		trap := false
		#partial switch i.op {
		case .TGE:  trap = s.sd[0] >= t.sd[0]
		case .TGEU: trap = s.d[0] >= t.d[0]
		case .TLT:  trap = s.sd[0] < t.sd[0]
		case .TLTU: trap = s.d[0] < t.d[0]
		case .TEQ:  trap = s.d[0] == t.d[0]
		case .TNE:  trap = s.d[0] != t.d[0]
		case .TRAPI:
			v := i64(r5900.sx16(i.imm))
			switch i.rt {
			case 8:  trap = s.sd[0] >= v
			case 9:  trap = s.d[0] >= u64(v)
			case 10: trap = s.sd[0] < v
			case 11: trap = s.d[0] < u64(v)
			case 12: trap = s.sd[0] == v
			case 14: trap = s.sd[0] != v
			}
		}
		if trap {cpu.trap(pc)}
		return
	case .MADD:   cpu.madd(i.rd, u32(s.d[0]), u32(t.d[0]), 0, true); return
	case .MADDU:  cpu.madd(i.rd, u32(s.d[0]), u32(t.d[0]), 0, false); return
	case .MADD1:  cpu.madd(i.rd, u32(s.d[0]), u32(t.d[0]), 1, true); return
	case .MADDU1: cpu.madd(i.rd, u32(s.d[0]), u32(t.d[0]), 1, false); return
	case .MTHI1: c.hi.d[1] = s.d[0]; return
	case .MTLO1: c.lo.d[1] = s.d[0]; return
	case .PLZCW: cpu.plzcw(s.w[0], s.w[1], i.rd); return
	case .PMFHL: cpu.pmfhl(i.rd, i.sa); return
	case .PMTHL:
		c.lo.w[0], c.hi.w[0], c.lo.w[2], c.hi.w[2] = s.w[0], s.w[1], s.w[2], s.w[3]
		return
	case .PSLLH: for k in 0 ..< 8 {d.h[k] = t.h[k] << (i.sa & 15)}
	case .PSRLH: for k in 0 ..< 8 {d.h[k] = t.h[k] >> (i.sa & 15)}
	case .PSRAH: for k in 0 ..< 8 {d.sh[k] = t.sh[k] >> (i.sa & 15)}
	case .PSLLW: for k in 0 ..< 4 {d.w[k] = t.w[k] << i.sa}
	case .PSRLW: for k in 0 ..< 4 {d.w[k] = t.w[k] >> i.sa}
	case .PSRAW: for k in 0 ..< 4 {d.sw[k] = t.sw[k] >> i.sa}
	// MMI0
	case .PADDW: for k in 0 ..< 4 {d.w[k] = s.w[k] + t.w[k]}
	case .PSUBW: for k in 0 ..< 4 {d.w[k] = s.w[k] - t.w[k]}
	case .PCGTW: for k in 0 ..< 4 {d.w[k] = s.sw[k] > t.sw[k] ? ~u32(0) : 0}
	case .PMAXW: for k in 0 ..< 4 {d.sw[k] = max(s.sw[k], t.sw[k])}
	case .PADDH: for k in 0 ..< 8 {d.h[k] = s.h[k] + t.h[k]}
	case .PSUBH: for k in 0 ..< 8 {d.h[k] = s.h[k] - t.h[k]}
	case .PCGTH: for k in 0 ..< 8 {d.h[k] = s.sh[k] > t.sh[k] ? ~u16(0) : 0}
	case .PMAXH: for k in 0 ..< 8 {d.sh[k] = max(s.sh[k], t.sh[k])}
	case .PADDB: for k in 0 ..< 16 {d.b[k] = s.b[k] + t.b[k]}
	case .PSUBB: for k in 0 ..< 16 {d.b[k] = s.b[k] - t.b[k]}
	case .PCGTB: for k in 0 ..< 16 {d.b[k] = s.sb[k] > t.sb[k] ? 0xff : 0}
	case .PADDSW: for k in 0 ..< 4 {d.w[k] = sat32(i64(s.sw[k]) + i64(t.sw[k]))}
	case .PSUBSW: for k in 0 ..< 4 {d.w[k] = sat32(i64(s.sw[k]) - i64(t.sw[k]))}
	case .PEXTLW: d.w = {t.w[0], s.w[0], t.w[1], s.w[1]}
	case .PPACW:  d.w = {t.w[0], t.w[2], s.w[0], s.w[2]}
	case .PADDSH: for k in 0 ..< 8 {d.h[k] = sat16(i32(s.sh[k]) + i32(t.sh[k]))}
	case .PSUBSH: for k in 0 ..< 8 {d.h[k] = sat16(i32(s.sh[k]) - i32(t.sh[k]))}
	case .PEXTLH: d.h = {t.h[0], s.h[0], t.h[1], s.h[1], t.h[2], s.h[2], t.h[3], s.h[3]}
	case .PPACH:  d.h = {t.h[0], t.h[2], t.h[4], t.h[6], s.h[0], s.h[2], s.h[4], s.h[6]}
	case .PADDSB: for k in 0 ..< 16 {d.b[k] = sat8(i32(s.sb[k]) + i32(t.sb[k]))}
	case .PSUBSB: for k in 0 ..< 16 {d.b[k] = sat8(i32(s.sb[k]) - i32(t.sb[k]))}
	case .PEXTLB: for k in 0 ..< 8 {d.b[2 * k], d.b[2 * k + 1] = t.b[k], s.b[k]}
	case .PPACB:  for k in 0 ..< 8 {d.b[k], d.b[k + 8] = t.b[2 * k], s.b[2 * k]}
	case .PEXT5:
		for k in 0 ..< 4 {
			x := t.w[k]
			d.w[k] = (x & 0x1f) << 3 | ((x >> 5) & 0x1f) << 11 | ((x >> 10) & 0x1f) << 19 | ((x >> 15) & 1) << 31
		}
	case .PPAC5:
		for k in 0 ..< 4 {
			x := t.w[k]
			d.w[k] = (x >> 3) & 0x1f | ((x >> 11) & 0x1f) << 5 | ((x >> 19) & 0x1f) << 10 | ((x >> 31) & 1) << 15
		}
	// MMI1
	case .PABSW: for k in 0 ..< 4 {d.w[k] = t.sw[k] == min(i32) ? 0x7fffffff : u32(abs(t.sw[k]))}
	case .PCEQW: for k in 0 ..< 4 {d.w[k] = s.w[k] == t.w[k] ? ~u32(0) : 0}
	case .PMINW: for k in 0 ..< 4 {d.sw[k] = min(s.sw[k], t.sw[k])}
	case .PADSBH:
		for k in 0 ..< 4 {d.h[k] = s.h[k] - t.h[k]}
		for k in 4 ..< 8 {d.h[k] = s.h[k] + t.h[k]}
	case .PABSH: for k in 0 ..< 8 {d.h[k] = t.sh[k] == min(i16) ? 0x7fff : u16(abs(t.sh[k]))}
	case .PCEQH: for k in 0 ..< 8 {d.h[k] = s.h[k] == t.h[k] ? ~u16(0) : 0}
	case .PMINH: for k in 0 ..< 8 {d.sh[k] = min(s.sh[k], t.sh[k])}
	case .PCEQB: for k in 0 ..< 16 {d.b[k] = s.b[k] == t.b[k] ? 0xff : 0}
	case .PADDUW: for k in 0 ..< 4 {d.w[k] = u32(min(u64(s.w[k]) + u64(t.w[k]), 0xffffffff))}
	case .PSUBUW: for k in 0 ..< 4 {d.w[k] = s.w[k] > t.w[k] ? s.w[k] - t.w[k] : 0}
	case .PEXTUW: d.w = {t.w[2], s.w[2], t.w[3], s.w[3]}
	case .PADDUH: for k in 0 ..< 8 {d.h[k] = u16(min(u32(s.h[k]) + u32(t.h[k]), 0xffff))}
	case .PSUBUH: for k in 0 ..< 8 {d.h[k] = s.h[k] > t.h[k] ? s.h[k] - t.h[k] : 0}
	case .PEXTUH: d.h = {t.h[4], s.h[4], t.h[5], s.h[5], t.h[6], s.h[6], t.h[7], s.h[7]}
	case .PADDUB: for k in 0 ..< 16 {d.b[k] = u8(min(u32(s.b[k]) + u32(t.b[k]), 0xff))}
	case .PSUBUB: for k in 0 ..< 16 {d.b[k] = s.b[k] > t.b[k] ? s.b[k] - t.b[k] : 0}
	case .PEXTUB: for k in 0 ..< 8 {d.b[2 * k], d.b[2 * k + 1] = t.b[k + 8], s.b[k + 8]}
	case .QFSRV:
		if c.sa == 0 {
			d.q = t.q
		} else {
			d.q = (t.q >> c.sa) | (s.q << (128 - c.sa))
		}
	// MMI2
	case .PMADDW:  cpu.pmaddw(i.rd, i.rs, i.rt); return
	case .PMSUBW:  cpu.pmsubw(i.rd, i.rs, i.rt); return
	case .PMULTW:  cpu.pmultw(i.rd, i.rs, i.rt); return
	case .PMADDUW: cpu.pmadduw(i.rd, i.rs, i.rt); return
	case .PMULTUW: cpu.pmultuw(i.rd, i.rs, i.rt); return
	case .PSLLVW: for k in 0 ..< 2 {d.d[k] = cpu.sx32(t.w[2 * k] << (s.w[2 * k] & 31))}
	case .PSRLVW: for k in 0 ..< 2 {d.d[k] = cpu.sx32(t.w[2 * k] >> (s.w[2 * k] & 31))}
	case .PSRAVW: for k in 0 ..< 2 {d.d[k] = cpu.sx32(u32(t.sw[2 * k] >> (s.w[2 * k] & 31)))}
	case .PMFHI: d = c.hi
	case .PMFLO: d = c.lo
	case .PINTH:  d.h = {t.h[0], s.h[4], t.h[1], s.h[5], t.h[2], s.h[6], t.h[3], s.h[7]}
	case .PDIVW, .PDIVUW:
		for k in 0 ..< 2 {
			div_fn := i.op == .PDIVW ? cpu.div : cpu.divu
			div_fn(s.w[2 * k], t.w[2 * k], k)
		}
		return
	case .PCPYLD: d.d = {t.d[0], s.d[0]}
	case .PMADDH: cpu.pmaddh(i.rd, i.rs, i.rt); return
	case .PMSUBH: cpu.pmsubh(i.rd, i.rs, i.rt); return
	case .PMULTH: cpu.pmulth(i.rd, i.rs, i.rt); return
	case .PHMADH: cpu.phmadh(i.rd, i.rs, i.rt); return
	case .PHMSBH: cpu.phmsbh(i.rd, i.rs, i.rt); return
	case .PAND: d.q = s.q & t.q
	case .PXOR: d.q = s.q ~ t.q
	case .PEXEH: d.h = {t.h[2], t.h[1], t.h[0], t.h[3], t.h[6], t.h[5], t.h[4], t.h[7]}
	case .PREVH: d.h = {t.h[3], t.h[2], t.h[1], t.h[0], t.h[7], t.h[6], t.h[5], t.h[4]}
	case .PDIVBW: cpu.pdivbw(i.rs, i.rt); return
	case .PEXEW:  d.w = {t.w[2], t.w[1], t.w[0], t.w[3]}
	case .PROT3W: d.w = {t.w[1], t.w[2], t.w[0], t.w[3]}
	// MMI3
	case .PMTHI: c.hi = s; return
	case .PMTLO: c.lo = s; return
	case .PINTEH: d.h = {t.h[0], s.h[0], t.h[2], s.h[2], t.h[4], s.h[4], t.h[6], s.h[6]}
	case .PCPYUD: d.d = {s.d[1], t.d[1]}
	case .POR:  d.q = s.q | t.q
	case .PNOR: d.q = ~(s.q | t.q)
	case .PEXCH: d.h = {t.h[0], t.h[2], t.h[1], t.h[3], t.h[4], t.h[6], t.h[5], t.h[7]}
	case .PCPYH:
		for k in 0 ..< 4 {d.h[k] = t.h[0]}
		for k in 4 ..< 8 {d.h[k] = t.h[4]}
	case .PEXCW: d.w = {t.w[0], t.w[2], t.w[1], t.w[3]}
	// COP0
	case .MFC0:
		v := c.cop0[i.rd]
		switch i.rd {
		case 9:  v = u32(c.cycles)
		case 15: v = 0x2e20 // PRId
		}
		if i.rt != 0 {c.r[i.rt].d[0] = cpu.sx32(v)}
		return
	case .MTC0: c.cop0[i.rd] = u32(t.d[0]); return
	case .EI: kernel.ei(); return
	case .DI: c.cop0[12] &~= 0x10000; return
	case .TLBR, .TLBWI, .TLBWR, .TLBP: return
	case .ERET: // the caller returns; just leave the exception level
		if cpu.state.cop0[12] & 4 != 0 {cpu.state.cop0[12] &~= 4} else {cpu.state.cop0[12] &~= 2}
	// FPU control and square roots
	case .CFC1:
		v: u32 = i.rd == 0 ? 0x2e30 : c.fcr31
		if i.rt != 0 {c.r[i.rt].d[0] = cpu.sx32(v)}
		return
	case .CTC1:
		if i.rd == 31 {c.fcr31 = u32(t.d[0])}
		return
	case .SQRT_S:  c.f[i.sa].f = cpu.fpu_sqrt(c.f[i.rt].f); return
	case .RSQRT_S: c.f[i.sa].f = cpu.fpu_rsqrt(c.f[i.rd].f, c.f[i.rt].f); return
	// COP2
	case .QMFC2: if i.rt != 0 {c.r[i.rt].q = vu.vu0.vf[i.rd].q}; return
	case .QMTC2: vu.vu0_set_vf(i.rd, t.q); return
	case .CFC2:  if i.rt != 0 {c.r[i.rt].d[0] = cpu.sx32(vu.vu0_ctrl_read(i.rd))}; return
	case .CTC2:  vu.vu0_ctrl_write(i.rd, u32(t.d[0])); return
	case .VU0:   vu.vu0_macro(w); return
	case .SLL, .SRL, .SRA, .SLLV, .SRLV, .SRAV, .MOVZ, .MOVN, .SYSCALL, .BREAK, .SYNC,
	     .MFHI, .MTHI, .MFLO, .MTLO, .DSLLV, .DSRLV, .DSRAV, .MULT, .MULTU, .DIV, .DIVU,
	     .ADD, .ADDU, .SUB, .SUBU, .AND, .OR, .XOR, .NOR, .SLT, .SLTU,
	     .DADD, .DADDU, .DSUB, .DSUBU, .DSLL, .DSRL, .DSRA, .DSLL32, .DSRL32, .DSRA32,
	     .ADDI, .ADDIU, .SLTI, .SLTIU, .ANDI, .ORI, .XORI, .LUI,
	     .DADDI, .DADDIU, .LDL, .LDR, .LQ, .SQ,
	     .LB, .LH, .LWL, .LW, .LBU, .LHU, .LWR, .LWU, .SB, .SH, .SWL, .SW, .SDL, .SDR, .SWR, .CACHE,
	     .LWC1, .PREF, .LQC2, .LD, .SWC1, .SQC2, .SD,
	     .MFHI1, .MFLO1, .MULT1, .MULTU1, .DIV1, .DIVU1, .MFC1, .MTC1,
	     .ADD_S, .SUB_S, .MUL_S, .DIV_S, .ABS_S, .MOV_S, .NEG_S,
	     .ADDA_S, .SUBA_S, .MULA_S, .MADD_S, .MSUB_S, .MADDA_S, .MSUBA_S, .CVT_W_S, .MAX_S, .MIN_S,
	     .C_F_S, .C_EQ_S, .C_LT_S, .C_LE_S, .CVT_S_W:
		exec_base(i)
		return
	case .INVALID, .JR, .JALR, .BLTZ, .BGEZ, .BLTZL, .BGEZL, .BLTZAL, .BGEZAL, .BLTZALL, .BGEZALL,
	     .J, .JAL, .BEQ, .BNE, .BLEZ, .BGTZ, .BEQL, .BNEL, .BLEZL, .BGTZL,
	     .BC0F, .BC0T, .BC0FL, .BC0TL, .BC1F, .BC1T, .BC1FL, .BC1TL, .BC2F, .BC2T, .BC2FL, .BC2TL:
		cpu.fatal("exec: %v at %08x is handled by the recompiler", i.op, pc)
	}
	if write_rd && i.rd != 0 {c.r[i.rd] = d}
}

// The instructions the Odin backend inlines (recomp/r5900/emit.odin
// emit_op), with the same semantics, for native code that leaves them here.
@(private)
exec_base :: proc(i: r5900.Insn) #no_bounds_check {
	c := &cpu.state
	rs, rt, rd, sa := i.rs, i.rt, i.rd, i.sa
	fs, ft, fd := rd, rt, sa // COP1 field names
	s, t := c.r[rs].d[0], c.r[rt].d[0]
	s32, t32 := u32(s), u32(t)
	simm := u64(i64(r5900.sx16(i.imm)))
	imm := u64(i.imm)
	addr := s32 + u32(simm)
	f := &c.f
	set :: #force_inline proc(c: ^cpu.Cpu, n: u8, v: u64) {if n != 0 {c.r[n].d[0] = v}}
	sx :: cpu.sx32
	#partial switch i.op {
	case .LB, .LBU, .LH, .LHU, .LW, .LWU, .LD, .LQ, .LWL, .LWR, .LDL, .LDR:
		if rt == 0 {return} // no access, as the Odin backend
	}
	#partial switch i.op {
	case .SLL:    set(c, rd, sx(t32 << sa))
	case .SRL:    set(c, rd, sx(t32 >> sa))
	case .SRA:    set(c, rd, sx(u32(i32(t32) >> sa)))
	case .SLLV:   set(c, rd, sx(t32 << (s32 & 31)))
	case .SRLV:   set(c, rd, sx(t32 >> (s32 & 31)))
	case .SRAV:   set(c, rd, sx(u32(i32(t32) >> (s32 & 31))))
	case .DSLLV:  set(c, rd, t << (s32 & 63))
	case .DSRLV:  set(c, rd, t >> (s32 & 63))
	case .DSRAV:  set(c, rd, u64(i64(t) >> (s32 & 63)))
	case .DSLL:   set(c, rd, t << sa)
	case .DSRL:   set(c, rd, t >> sa)
	case .DSRA:   set(c, rd, u64(i64(t) >> sa))
	case .DSLL32: set(c, rd, t << (sa + 32))
	case .DSRL32: set(c, rd, t >> (sa + 32))
	case .DSRA32: set(c, rd, u64(i64(t) >> (sa + 32)))
	case .MOVZ:   if t == 0 {set(c, rd, s)}
	case .MOVN:   if t != 0 {set(c, rd, s)}
	case .MFHI:   set(c, rd, c.hi.d[0])
	case .MFLO:   set(c, rd, c.lo.d[0])
	case .MTHI:   c.hi.d[0] = s
	case .MTLO:   c.lo.d[0] = s
	case .MFHI1:  set(c, rd, c.hi.d[1])
	case .MFLO1:  set(c, rd, c.lo.d[1])
	case .MULT:   cpu.mult(rd, s32, t32, 0)
	case .MULTU:  cpu.multu(rd, s32, t32, 0)
	case .MULT1:  cpu.mult(rd, s32, t32, 1)
	case .MULTU1: cpu.multu(rd, s32, t32, 1)
	case .DIV:    cpu.div(s32, t32, 0)
	case .DIVU:   cpu.divu(s32, t32, 0)
	case .DIV1:   cpu.div(s32, t32, 1)
	case .DIVU1:  cpu.divu(s32, t32, 1)
	case .ADD, .ADDU:   set(c, rd, sx(s32 + t32))
	case .SUB, .SUBU:   set(c, rd, sx(s32 - t32))
	case .DADD, .DADDU: set(c, rd, s + t)
	case .DSUB, .DSUBU: set(c, rd, s - t)
	case .AND:  set(c, rd, s & t)
	case .OR:   set(c, rd, s | t)
	case .XOR:  set(c, rd, s ~ t)
	case .NOR:  set(c, rd, ~(s | t))
	case .SLT:  set(c, rd, i64(s) < i64(t) ? 1 : 0)
	case .SLTU: set(c, rd, s < t ? 1 : 0)
	case .ADDI, .ADDIU:   set(c, rt, sx(s32 + u32(simm)))
	case .DADDI, .DADDIU: set(c, rt, s + simm)
	case .SLTI:  set(c, rt, i64(s) < i64(simm) ? 1 : 0)
	case .SLTIU: set(c, rt, s < simm ? 1 : 0)
	case .ANDI:  set(c, rt, s & imm)
	case .ORI:   set(c, rt, s | imm)
	case .XORI:  set(c, rt, s ~ imm)
	case .LUI:   set(c, rt, sx(u32(i.imm) << 16))
	case .LB:  set(c, rt, u64(i64(i8(mem.rd8(addr)))))
	case .LBU: set(c, rt, u64(mem.rd8(addr)))
	case .LH:  set(c, rt, u64(i64(i16(mem.rd16(addr)))))
	case .LHU: set(c, rt, u64(mem.rd16(addr)))
	case .LW:  set(c, rt, sx(mem.rd32(addr)))
	case .LWU: set(c, rt, u64(mem.rd32(addr)))
	case .LD:  set(c, rt, mem.rd64(addr))
	case .LQ:  c.r[rt].q = mem.rd128(addr)
	case .SB:  mem.wr8(addr, u8(t))
	case .SH:  mem.wr16(addr, u16(t))
	case .SW:  mem.wr32(addr, t32)
	case .SD:  mem.wr64(addr, t)
	case .SQ:  mem.wr128(addr, rt == 0 ? 0 : c.r[rt].q)
	case .LWC1: f[rt].u = mem.rd32(addr)
	case .SWC1: mem.wr32(addr, f[rt].u)
	case .LQC2: vu.vu0_set_vf(rt, mem.rd128(addr))
	case .SQC2: mem.wr128(addr, vu.vu0.vf[rt].q)
	case .LWL: c.r[rt].d[0] = mem.LWL(addr, t)
	case .LWR: c.r[rt].d[0] = mem.LWR(addr, t)
	case .LDL: c.r[rt].d[0] = mem.LDL(addr, t)
	case .LDR: c.r[rt].d[0] = mem.LDR(addr, t)
	case .SWL: mem.SWL(addr, t)
	case .SWR: mem.SWR(addr, t)
	case .SDL: mem.SDL(addr, t)
	case .SDR: mem.SDR(addr, t)
	case .SYNC, .CACHE, .PREF:
	case .MFC1:  set(c, rt, sx(f[fs].u))
	case .MTC1:  f[fs].u = t32
	case .MOV_S: f[fd] = f[fs]
	case .NEG_S: f[fd].u = f[fs].u ~ 0x80000000
	case .ABS_S: f[fd].u = f[fs].u & 0x7fffffff
	case .ADD_S: f[fd].f = cpu.fpu_add(f[fs].f, f[ft].f)
	case .SUB_S: f[fd].f = cpu.fpu_sub(f[fs].f, f[ft].f)
	case .MUL_S: f[fd].f = cpu.fpu_mul(f[fs].f, f[ft].f)
	case .DIV_S: f[fd].f = cpu.fpu_div(f[fs].f, f[ft].f)
	case .MADD_S:  f[fd].f = cpu.fpu_add(c.acc.f, cpu.fpu_mul(f[fs].f, f[ft].f))
	case .MSUB_S:  f[fd].f = cpu.fpu_sub(c.acc.f, cpu.fpu_mul(f[fs].f, f[ft].f))
	case .MULA_S:  c.acc.f = cpu.fpu_mul(f[fs].f, f[ft].f)
	case .ADDA_S:  c.acc.f = cpu.fpu_add(f[fs].f, f[ft].f)
	case .SUBA_S:  c.acc.f = cpu.fpu_sub(f[fs].f, f[ft].f)
	case .MADDA_S: c.acc.f = cpu.fpu_add(c.acc.f, cpu.fpu_mul(f[fs].f, f[ft].f))
	case .MSUBA_S: c.acc.f = cpu.fpu_sub(c.acc.f, cpu.fpu_mul(f[fs].f, f[ft].f))
	case .MAX_S: f[fd] = cpu.fkey(f[fs].f) >= cpu.fkey(f[ft].f) ? f[fs] : f[ft]
	case .MIN_S: f[fd] = cpu.fkey(f[fs].f) <= cpu.fkey(f[ft].f) ? f[fs] : f[ft]
	case .C_F_S:  c.fcr31 &= ~u32(cpu.FCR31_C)
	case .C_EQ_S: cpu.fcond(cpu.fkey(f[fs].f) == cpu.fkey(f[ft].f))
	case .C_LT_S: cpu.fcond(cpu.fkey(f[fs].f) < cpu.fkey(f[ft].f))
	case .C_LE_S: cpu.fcond(cpu.fkey(f[fs].f) <= cpu.fkey(f[ft].f))
	case .CVT_S_W: f[fd].f = f32(f[fs].i)
	case .CVT_W_S: f[fd].i = cpu.cvt_w(f[fs].f)
	case .SYSCALL: kernel.syscall(i.pc)
	case .BREAK:   cpu.brk(i.pc, i.w)
	case: cpu.fatal("exec: %v at %08x is not a base instruction", i.op, i.pc)
	}
}

// Condition line of a COP0/COP2 branch: CPCOND0 (DMA idle) and VU0 busy
// are both false here.
bc_cond :: proc(w: u32) -> bool {
	switch (w >> 26) & 3 {
	case 0: return (w >> 16) & 1 == 1 // bc0t: DMA done
	}
	return (w >> 16) & 1 == 0 // bc2f: VU0 not running
}
