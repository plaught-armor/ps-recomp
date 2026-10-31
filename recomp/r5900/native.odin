// Native code for lowered functions: the steps emit.odin renders as Odin
// source, as machine code (options native_arch, native_out). Both run the
// same instructions in the same order, so a game can switch between them
// and compare.
//
// The machine is 32-bit; a guest register is its low and high words. The
// integer, MMI, FPU and COP0 instructions, the COP2 transfers, branches,
// links, calls, jumps and cycle charges are inline, or call the cpu helper
// that owns them: the MMI multiplies (PMULTW, PMULTUW, PMADDW, PMADDUW,
// PMSUBW, PMULTH, PMADDH, PMSUBH, PHMSBH), PDIVBW, PMFHL, and FPU
// arithmetic on special operands (cpu.fpu_slow). An instruction with no
// code here calls the runtime interpreter (ps2.exec_op); a VU0 macro op
// with none calls vu.macro.
// Runtime procedures and variables are imports by name; ps2/native.odin
// lists them.
package r5900

import "core:slice"
import "../native"
import "../vu"

// Field offsets in cpu.Cpu; the loader checks them.
@(private = "file")
GPR :: 16 // bytes per register; the low word of r[n] is at GPR * n
@(private = "file")
HI :: 512
@(private = "file")
LO :: 528
@(private = "file")
SA :: 544
@(private = "file")
FPR :: 548 // f[0], 4 bytes each
@(private = "file")
ACC :: 676
@(private = "file")
FCR31 :: 680
@(private = "file")
COP0 :: 684 // cop0[0], 4 bytes each
@(private = "file")
CYCLES :: 816

// Main RAM as the Odin fast path sees it (FAST_HELPERS fast): an address
// below 32 MiB. While WATCH is on (any byte of mem.watch_len set) every store
// calls, so the runtime sees it. No page is ever armed; ps2.no_pages is all
// zeros.
@(private = "file", rodata)
RAM_GUARDS := [?]native.Guard{{"mem.watch_on", 0xff}}

native_ram :: proc() -> native.Ram {
	return {
		base = "mem.ram",
		outside = 0xfe000000,
		size = 32 << 20,
		pages = "ps2.no_pages",
		page_shift = 12,
		guards = RAM_GUARDS[:],
		// The uncached mirror, 0x20000000 and 0x30000000 up, and the
		// scratchpad.
		mirror_mask = 0xee000000,
		mirror_bits = 0x20000000,
		window = "mem.spr",
		window_at = 0x70000000,
		window_size = 16 << 10,
	}
}

// dst = the low (or high) word of guest register n.
@(private = "file")
get :: proc(a: ^native.Asm, dst: native.Reg, n: u8, high := false) {
	if n == 0 {
		native.mov_imm(a, dst, 0)
	} else {
		native.state_load(a, dst, GPR * u32(n) + (high ? 4 : 0))
	}
}

@(private = "file")
events :: proc(a: ^native.Asm) {
	skip := native.new_label(a)
	native.br_state64_below(a, CYCLES, "cpu.next_event", skip)
	native.call(a, "kernel.run_events")
	native.bind(a, skip)
}

@(private = "file")
trace :: proc(a: ^native.Asm, entry: u32) {
	skip := native.new_label(a)
	native.br_byte_clear(a, "kernel.trace_on", "", skip)
	call_imm(a, "kernel.trace_call", entry)
	native.bind(a, skip)
}

@(private = "file")
call_imm :: proc(a: ^native.Asm, name: string, v: u32) {
	native.mov_imm(a, .A, v)
	native.call(a, name, .A)
}

// The low (or high) word of guest register n = src; n is not zero.
@(private = "file")
put :: proc(a: ^native.Asm, n: u8, src: native.Reg, high := false) {
	native.state_store(a, GPR * u32(n) + (high ? 4 : 0), src)
}

// Guest register n = src sign-extended; loses src.
@(private = "file")
put_sx :: proc(a: ^native.Asm, n: u8, src: native.Reg) {
	put(a, n, src)
	native.alu_imm(a, .Sar, src, 31)
	put(a, n, src, high = true)
}

// The low doublewords of LO and HI (unit 0) or the high ones (8) = their
// low words sign-extended. Uses A.
@(private = "file")
sx_lohi :: proc(a: ^native.Asm, unit: u32) {
	for at in ([2]u32{LO + unit, HI + unit}) {
		native.state_load(a, .A, at)
		native.alu_imm(a, .Sar, .A, 31)
		native.state_store(a, at + 4, .A)
	}
}

// The 64-bit state field at dst = the one at src. Uses A.
@(private = "file")
copy64 :: proc(a: ^native.Asm, dst, src: u32) {
	native.state_load(a, .A, src)
	native.state_store(a, dst, .A)
	native.state_load(a, .A, src + 4)
	native.state_store(a, dst + 4, .A)
}

// Guest register d = guest register s; d is not zero.
@(private = "file")
move :: proc(a: ^native.Asm, d, s: u8) {
	if d == s {return}
	if s == 0 {
		native.state_store_imm(a, GPR * u32(d), 0)
		native.state_store_imm(a, GPR * u32(d) + 4, 0)
		return
	}
	copy64(a, GPR * u32(d), GPR * u32(s))
}

// Code for i in place of the interpreter's, or false to leave it there.
// Uses A, B, C and LD; T holds a branch condition across a delay slot.
@(private = "file")
inline_op :: proc(a: ^native.Asm, i: Insn) -> bool {
	rs, rt, rd, sa := i.rs, i.rt, i.rd, u32(i.sa)
	simm := u32(sx16(i.imm))
	simm_hi := u32(i32(simm) >> 31)
	imm := u32(i.imm)
	// rd = op(rs, rt) on each word
	logic :: proc(a: ^native.Asm, op: native.Alu, d, s, t: u8, invert := false) {
		for high in ([2]bool{false, true}) {
			get(a, .A, s, high)
			get(a, .B, t, high)
			native.alu(a, op, .A, .B)
			if invert {native.not(a, .A)}
			put(a, d, .A, high)
		}
	}
	// d = s + (B, LD) as doublewords, or s - (B, LD)
	add64 :: proc(a: ^native.Asm, d, s: u8, sub: bool) {
		get(a, .A, s)
		if sub {
			native.mov(a, .C, .A)
			native.set_cond(a, .Ltu, .C, .B) // borrow
			native.alu(a, .Sub, .A, .B)
		} else {
			native.alu(a, .Add, .A, .B)
			native.mov(a, .C, .A)
			native.set_cond(a, .Ltu, .C, .B) // carry
		}
		put(a, d, .A)
		get(a, .A, s, high = true)
		native.alu(a, .Sub if sub else .Add, .A, .LD)
		native.alu(a, .Sub if sub else .Add, .A, .C)
		put(a, d, .A, high = true)
	}
	// A = s < (B, LD) as doublewords, signed or not, 1 or 0
	less64_cond :: proc(a: ^native.Asm, s: u8, signed: bool) {
		get(a, .A, s, high = true)
		native.mov(a, .C, .A)
		native.set_cond(a, .Lt if signed else .Ltu, .C, .LD)
		native.set_cond(a, .Eq, .A, .LD)
		get(a, .LD, s)
		native.set_cond(a, .Ltu, .LD, .B)
		native.alu(a, .And, .A, .LD)
		native.alu(a, .Or, .A, .C)
	}
	// d = s < (B, LD) as doublewords, signed or not
	less64 :: proc(a: ^native.Asm, d, s: u8, signed: bool) {
		less64_cond(a, s, signed)
		put(a, d, .A)
		native.state_store_imm(a, GPR * u32(d) + 4, 0)
	}
	#partial switch i.op {
	case .SLL, .SRL, .SRA:
		if rd == 0 {return true}
		get(a, .A, rt)
		if sa != 0 {native.alu_imm(a, .Shl if i.op == .SLL else .Shr if i.op == .SRL else .Sar, .A, sa)}
		put_sx(a, rd, .A)
	case .SLLV, .SRLV, .SRAV:
		if rd == 0 {return true}
		get(a, .A, rt)
		get(a, .B, rs)
		native.alu(a, .Shl if i.op == .SLLV else .Shr if i.op == .SRLV else .Sar, .A, .B)
		put_sx(a, rd, .A)
	case .ADD, .ADDU, .SUB, .SUBU:
		if rd == 0 {return true}
		get(a, .A, rs)
		get(a, .B, rt)
		native.alu(a, .Add if i.op == .ADD || i.op == .ADDU else .Sub, .A, .B)
		put_sx(a, rd, .A)
	case .ADDI, .ADDIU:
		if rt == 0 {return true}
		get(a, .A, rs)
		if simm != 0 {native.alu_imm(a, .Add, .A, simm)}
		put_sx(a, rt, .A)
	case .LUI:
		if rt == 0 {return true}
		native.state_store_imm(a, GPR * u32(rt), imm << 16)
		native.state_store_imm(a, GPR * u32(rt) + 4, u32(i32(imm << 16) >> 31))
	case .AND:
		if rd == 0 {return true}
		logic(a, .And, rd, rs, rt)
	case .OR:
		if rd == 0 {return true}
		if rt == 0 {
			move(a, rd, rs)
		} else if rs == 0 {
			move(a, rd, rt)
		} else {
			logic(a, .Or, rd, rs, rt)
		}
	case .XOR:
		if rd == 0 {return true}
		logic(a, .Xor, rd, rs, rt)
	case .NOR:
		if rd == 0 {return true}
		logic(a, .Or, rd, rs, rt, invert = true)
	case .ANDI:
		if rt == 0 {return true}
		get(a, .A, rs)
		native.alu_imm(a, .And, .A, imm)
		put(a, rt, .A)
		native.state_store_imm(a, GPR * u32(rt) + 4, 0)
	case .ORI, .XORI:
		if rt == 0 {return true}
		get(a, .A, rs)
		if imm != 0 {native.alu_imm(a, .Or if i.op == .ORI else .Xor, .A, imm)}
		put(a, rt, .A)
		if rs != rt {
			get(a, .A, rs, high = true)
			put(a, rt, .A, high = true)
		}
	case .DADD, .DADDU, .DSUB, .DSUBU:
		if rd == 0 {return true}
		sub := i.op == .DSUB || i.op == .DSUBU
		if rt == 0 {
			move(a, rd, rs)
		} else if rs == 0 && !sub {
			move(a, rd, rt)
		} else {
			get(a, .B, rt)
			get(a, .LD, rt, high = true)
			add64(a, rd, rs, sub)
		}
	case .DADDI, .DADDIU:
		if rt == 0 {return true}
		if simm == 0 {
			move(a, rt, rs)
		} else {
			native.mov_imm(a, .B, simm)
			native.mov_imm(a, .LD, simm_hi)
			add64(a, rt, rs, false)
		}
	case .SLT, .SLTU:
		if rd == 0 {return true}
		get(a, .B, rt)
		get(a, .LD, rt, high = true)
		less64(a, rd, rs, i.op == .SLT)
	case .SLTI, .SLTIU:
		if rt == 0 {return true}
		native.mov_imm(a, .B, simm)
		native.mov_imm(a, .LD, simm_hi)
		less64(a, rt, rs, i.op == .SLTI)
	case .DSLL, .DSRL, .DSRA:
		if rd == 0 {return true}
		if sa == 0 {
			move(a, rd, rt)
			return true
		}
		get(a, .A, rt)
		get(a, .B, rt, high = true)
		if i.op == .DSLL {
			// hi = hi << sa | lo >> (32 - sa); lo <<= sa
			native.mov(a, .C, .A)
			native.alu_imm(a, .Shr, .C, 32 - sa)
			native.alu_imm(a, .Shl, .B, sa)
			native.alu(a, .Or, .B, .C)
			native.alu_imm(a, .Shl, .A, sa)
		} else {
			// lo = lo >> sa | hi << (32 - sa); hi >>= sa
			native.mov(a, .C, .B)
			native.alu_imm(a, .Shl, .C, 32 - sa)
			native.alu_imm(a, .Shr, .A, sa)
			native.alu(a, .Or, .A, .C)
			native.alu_imm(a, .Shr if i.op == .DSRL else .Sar, .B, sa)
		}
		put(a, rd, .A)
		put(a, rd, .B, high = true)
	case .DSLL32:
		if rd == 0 {return true}
		get(a, .A, rt)
		if sa != 0 {native.alu_imm(a, .Shl, .A, sa)}
		put(a, rd, .A, high = true)
		native.state_store_imm(a, GPR * u32(rd), 0)
	case .DSRL32, .DSRA32:
		if rd == 0 {return true}
		get(a, .A, rt, high = true)
		native.mov(a, .B, .A)
		if i.op == .DSRL32 {
			if sa != 0 {native.alu_imm(a, .Shr, .A, sa)}
			put(a, rd, .A)
			native.state_store_imm(a, GPR * u32(rd) + 4, 0)
		} else {
			if sa != 0 {native.alu_imm(a, .Sar, .A, sa)}
			native.alu_imm(a, .Sar, .B, 31)
			put(a, rd, .A)
			put(a, rd, .B, high = true)
		}
	case .DSLLV, .DSRLV, .DSRAV:
		if rd == 0 {return true}
		// (B, A) = rt shifted by C = rs & 63. Under 32, the word crossing
		// over is shifted by 1 then by ~C & 31 = 31 - C, so C = 0 moves
		// nothing across without a branch.
		get(a, .A, rt)
		get(a, .B, rt, high = true)
		get(a, .C, rs)
		big, done := native.new_label(a), native.new_label(a)
		native.mov(a, .LD, .C)
		native.alu_imm(a, .And, .LD, 32)
		native.br_zero(a, .LD, big, nonzero = true)
		if i.op == .DSLLV {
			native.mov(a, .LD, .A)
			native.alu_imm(a, .Shr, .LD, 1)
			native.alu(a, .Shl, .A, .C)
			native.alu(a, .Shl, .B, .C)
			native.not(a, .C)
			native.alu(a, .Shr, .LD, .C)
		} else {
			native.mov(a, .LD, .B)
			native.alu_imm(a, .Shl, .LD, 1)
			native.alu(a, .Shr, .A, .C)
			native.alu(a, .Shr if i.op == .DSRLV else .Sar, .B, .C)
			native.not(a, .C)
			native.alu(a, .Shl, .LD, .C)
		}
		native.alu(a, .Or, .B if i.op == .DSLLV else .A, .LD)
		native.jmp(a, done)
		// 32 or more: one word shifted by C & 31 (the hardware's count),
		// the other zero or the sign.
		native.bind(a, big)
		if i.op == .DSLLV {
			native.mov(a, .B, .A)
			native.alu(a, .Shl, .B, .C)
			native.mov_imm(a, .A, 0)
		} else {
			native.mov(a, .A, .B)
			native.alu(a, .Shr if i.op == .DSRLV else .Sar, .A, .C)
			if i.op == .DSRLV {
				native.mov_imm(a, .B, 0)
			} else {
				native.alu_imm(a, .Sar, .B, 31)
			}
		}
		native.bind(a, done)
		put(a, rd, .A)
		put(a, rd, .B, high = true)
	case .MOVZ, .MOVN:
		if rd == 0 {return true}
		skip := native.new_label(a)
		get(a, .A, rt)
		get(a, .B, rt, high = true)
		native.alu(a, .Or, .A, .B)
		native.br_zero(a, .A, skip, nonzero = i.op == .MOVZ)
		move(a, rd, rs)
		native.bind(a, skip)
	case .MFHI, .MFLO, .MFHI1, .MFLO1:
		// The 1 forms read the second pipeline's halves of HI and LO.
		if rd == 0 {return true}
		unit: u32 = 8 if i.op == .MFHI1 || i.op == .MFLO1 else 0
		copy64(a, GPR * u32(rd), (HI if i.op == .MFHI || i.op == .MFHI1 else LO) + unit)
	case .MTHI, .MTLO, .MTHI1, .MTLO1:
		unit: u32 = 8 if i.op == .MTHI1 || i.op == .MTLO1 else 0
		at := (HI if i.op == .MTHI || i.op == .MTHI1 else LO) + unit
		if rs == 0 {
			native.state_store_imm(a, at, 0)
			native.state_store_imm(a, at + 4, 0)
		} else {
			copy64(a, at, GPR * u32(rs))
		}
	case .MULT, .MULTU, .MULT1, .MULTU1:
		// MULT1 and MULTU1 use the second pipeline's halves of LO and HI.
		unit: u32 = 8 if i.op == .MULT1 || i.op == .MULTU1 else 0
		get(a, .A, rs)
		get(a, .B, rt)
		native.mul_wide(a, i.op == .MULT || i.op == .MULT1, LO + unit, HI + unit, .A, .B)
		sx_lohi(a, unit)
		if rd != 0 {copy64(a, GPR * u32(rd), LO + unit)}
	case .MADD, .MADDU, .MADD1, .MADDU1:
		// cpu.madd: hi:lo (low words) + the product, each half sign-extended.
		unit: u32 = 8 if i.op == .MADD1 || i.op == .MADDU1 else 0
		get(a, .A, rs)
		get(a, .B, rt)
		native.state_load(a, .C, LO + unit)
		native.state_load(a, .LD, HI + unit)
		native.mul_wide(a, i.op == .MADD || i.op == .MADD1, LO + unit, HI + unit, .A, .B)
		native.state_load(a, .A, LO + unit)
		native.alu(a, .Add, .A, .C)
		native.state_store(a, LO + unit, .A)
		native.set_cond(a, .Ltu, .A, .C) // the carry
		native.state_load(a, .B, HI + unit)
		native.alu(a, .Add, .B, .LD)
		native.alu(a, .Add, .B, .A)
		native.state_store(a, HI + unit, .B)
		sx_lohi(a, unit)
		if rd != 0 {copy64(a, GPR * u32(rd), LO + unit)}
	case .PLZCW:
		// As cpu.plzcw: each word of rs's low doubleword, inverted when
		// negative, has its leading zeros less one; 0 and -1 give 31 as
		// clz's 32 does. The high doubleword of rd stays.
		if rd != 0 {
			get(a, .A, rs)
			get(a, .B, rs, high = true)
			for k in u32(0) ..< 2 {
				r: native.Reg = .A if k == 0 else .B
				native.mov(a, .C, r)
				native.alu_imm(a, .Sar, .C, 31)
				native.alu(a, .Xor, r, .C)
				native.clz(a, r)
				native.alu_imm(a, .Sub, r, 1)
			}
			native.state_store(a, GPR * u32(rd), .A)
			native.state_store(a, GPR * u32(rd) + 4, .B)
		}
	case .DIV, .DIVU, .DIV1, .DIVU1:
		// As cpu.div and cpu.divu; DIV1 and DIVU1 use the second pipeline's
		// halves of LO and HI.
		unit: u32 = 8 if i.op == .DIV1 || i.op == .DIVU1 else 0
		get(a, .A, rs)
		get(a, .B, rt)
		native.divide(a, i.op == .DIV || i.op == .DIV1, LO + unit, HI + unit)
		sx_lohi(a, unit)
	case .LB, .LBU, .LH, .LHU, .LW, .LWU:
		if rt == 0 {return true} // no access, as emit_op
		get(a, .A, rs)
		if simm != 0 {native.alu_imm(a, .Add, .A, simm)}
		#partial switch i.op {
		case .LB:  native.load(a, .B8, true, "ps2.rd8s")
		case .LBU: native.load(a, .B8, false, "ps2.rd8")
		case .LH:  native.load(a, .B16, true, "ps2.rd16s")
		case .LHU: native.load(a, .B16, false, "ps2.rd16")
		case:      native.load(a, .B32, false, "ps2.rd32")
		}
		if i.op == .LB || i.op == .LH || i.op == .LW {
			put_sx(a, rt, .A)
		} else {
			put(a, rt, .A)
			native.state_store_imm(a, GPR * u32(rt) + 4, 0)
		}
	case .LWC1:
		get(a, .A, rs)
		if simm != 0 {native.alu_imm(a, .Add, .A, simm)}
		native.load(a, .B32, false, "ps2.rd32")
		native.state_store(a, FPR + 4 * u32(rt), .A)
	case .SB, .SH, .SW, .SWC1:
		get(a, .A, rs)
		if simm != 0 {native.alu_imm(a, .Add, .A, simm)}
		if i.op == .SWC1 {
			native.state_load(a, .B, FPR + 4 * u32(rt))
		} else {
			get(a, .B, rt)
		}
		#partial switch i.op {
		case .SB: native.store(a, .B8, "ps2.wr8")
		case .SH: native.store(a, .B16, "ps2.wr16")
		case:     native.store(a, .B32, "ps2.wr32")
		}
	case .LD, .LQ, .SD, .SQ:
		if rt == 0 && (i.op == .LD || i.op == .LQ) {return true}
		get(a, .A, rs)
		if simm != 0 {native.alu_imm(a, .Add, .A, simm)}
		// A quadword access ignores the address's low four bits.
		w: native.Width = i.op == .LQ || i.op == .SQ ? .B128 : .B64
		if w == .B128 {native.alu_imm(a, .And, .A, ~u32(15))}
		#partial switch i.op {
		case .LD: native.load_state(a, w, GPR * u32(rt), u32(rt), "ps2.ld")
		case .LQ: native.load_state(a, w, GPR * u32(rt), u32(rt), "ps2.lq")
		case .SD: native.store_state(a, w, GPR * u32(rt), u32(rt), "ps2.sd", rt == 0)
		case:     native.store_state(a, w, GPR * u32(rt), u32(rt), "ps2.sq", rt == 0)
		}
	case .LWL, .LWR, .LDL, .LDR, .SWL, .SWR, .SDL, .SDR:
		// The aligned word or doubleword, read and merged (and written) in
		// place when it is RAM, else the runtime's mem procedure as emit_op
		// calls it, so MMIO and the watch see what the Odin code does.
		load := i.op == .LWL || i.op == .LWR || i.op == .LDL || i.op == .LDR
		if rt == 0 && load {return true} // no access, as emit_op
		get(a, .A, rs)
		if simm != 0 {native.alu_imm(a, .Add, .A, simm)}
		#partial switch i.op {
		case .LWL: native.unaligned(a, .LWL, GPR * u32(rt), u32(rt), "ps2.lwl")
		case .LWR: native.unaligned(a, .LWR, GPR * u32(rt), u32(rt), "ps2.lwr")
		case .LDL: native.unaligned(a, .LDL, GPR * u32(rt), u32(rt), "ps2.ldl")
		case .LDR: native.unaligned(a, .LDR, GPR * u32(rt), u32(rt), "ps2.ldr")
		case .SWL: native.unaligned(a, .SWL, GPR * u32(rt), u32(rt), "ps2.swl")
		case .SWR: native.unaligned(a, .SWR, GPR * u32(rt), u32(rt), "ps2.swr")
		case .SDL: native.unaligned(a, .SDL, GPR * u32(rt), u32(rt), "ps2.sdl")
		case:      native.unaligned(a, .SDR, GPR * u32(rt), u32(rt), "ps2.sdr")
		}
	case .QMFC2:
		if rt == 0 {return true}
		native.vec_load(a, .V0, 16 * u32(rd), "vu.vf")
		native.vec_store(a, GPR * u32(rt), .V0)
	case .QMTC2:
		// vf0 is fixed.
		if rd == 0 {return true}
		native.vec_load(a, .V0, GPR * u32(rt))
		native.vec_store(a, 16 * u32(rd), .V0, "vu.vf")
	case .CFC2:
		// As vu.vu0_ctrl_read, by register
		if rt == 0 {return true}
		if rd < 16 {
			vu.vi_get(a, .VU0, .A, u32(rd))
		} else if f, ok := vu0_ctrl(rd, true); ok {
			native.imp_load(a, .A, f)
		} else {
			native.mov_imm(a, .A, 0)
		}
		put_sx(a, rt, .A)
	case .CTC2:
		// As vu.vu0_ctrl_write, by register; a write to CMSAR1 starts VU1
		// and stays a call.
		if rd == 31 {
			get(a, .B, rt)
			native.mov_imm(a, .A, u32(rd))
			native.call(a, "vu.ctrl_write", .A, .B)
		} else if rd != 0 && rd < 16 {
			get(a, .A, rt)
			vu.vi_put(a, .VU0, u32(rd))
		} else if f, ok := vu0_ctrl(rd, false); ok {
			get(a, .A, rt)
			if rd == 20 {native.alu_imm(a, .And, .A, 0x7fffff)}
			native.imp_store(a, f, .A)
		}
	case .LQC2, .SQC2:
		// VF registers live in the VU, 16 bytes each from import vu.vf;
		// vf0 is fixed, but a store writes what it holds.
		if rt == 0 && i.op == .LQC2 {return true}
		get(a, .A, rs)
		if simm != 0 {native.alu_imm(a, .Add, .A, simm)}
		native.alu_imm(a, .And, .A, ~u32(15))
		if i.op == .LQC2 {
			native.load_state(a, .B128, 16 * u32(rt), u32(rt), "ps2.lqc2", base = "vu.vf")
		} else {
			native.store_state(a, .B128, 16 * u32(rt), u32(rt), "ps2.sqc2", base = "vu.vf")
		}
	case .MFC1:
		if rt == 0 {return true}
		native.state_load(a, .A, FPR + 4 * u32(rd))
		put_sx(a, rt, .A)
	case .MTC1:
		get(a, .A, rt)
		native.state_store(a, FPR + 4 * u32(rd), .A)
	case .MOV_S, .NEG_S, .ABS_S, .CVT_S_W, .CVT_W_S, .ADD_S, .SUB_S, .MUL_S, .DIV_S, .SQRT_S, .RSQRT_S,
	     .ADDA_S, .SUBA_S, .MULA_S, .MADD_S, .MSUB_S, .MADDA_S, .MSUBA_S,
	     .MAX_S, .MIN_S, .C_EQ_S, .C_LT_S, .C_LE_S:
		// COP1: fs = rd, ft = rt, fd = sa.
		fs, ft, fd := FPR + 4 * u32(rd), FPR + 4 * u32(rt), FPR + 4 * sa
		#partial switch i.op {
		case .MOV_S, .NEG_S, .ABS_S, .CVT_S_W:
			native.state_load(a, .A, fs)
			#partial switch i.op {
			case .NEG_S: native.alu_imm(a, .Xor, .A, 0x80000000)
			case .ABS_S: native.alu_imm(a, .And, .A, 0x7fffffff)
			case .CVT_S_W: native.int_to_float(a, .A)
			}
			native.state_store(a, fd, .A)
		case .CVT_W_S:
			// cpu.cvt_w: out of range or NaN is the i32 limit on the
			// side of the sign, where float_to_int gives 0x80000000 for
			// NaN and for out of range (arm64: a negative one only).
			native.state_load(a, .A, fs)
			native.mov(a, .B, .A)
			native.float_to_int(a, .A)
			native.mov(a, .LD, .A)
			native.set_cond_imm(a, .Eq, .LD, 0x80000000)
			native.alu_imm(a, .Shr, .B, 31)
			native.alu_imm(a, .Xor, .B, 1)
			native.alu(a, .And, .LD, .B)
			native.alu(a, .Sub, .A, .LD) // 0x7fffffff for a positive one
			native.state_store(a, fd, .A)
		case .SQRT_S:
			native.state_load(a, .A, ft)
			fpu_root(a)
			native.state_store(a, fd, .A)
		case .RSQRT_S:
			// cpu.fpu_rsqrt: a zero ft gives +-FMAX with the sign of fs,
			// any other fs / the root of ft as cpu.fpu_div. The root of
			// a nonzero exponent never has exponent 0, so the divide
			// needs no zero check.
			calc, done := native.new_label(a), native.new_label(a)
			native.state_load(a, .A, ft)
			native.mov(a, .C, .A)
			native.alu_imm(a, .And, .C, 0x7f800000)
			native.br_zero(a, .C, calc, nonzero = true)
			native.state_load(a, .A, fs)
			native.alu_imm(a, .And, .A, 0x80000000)
			native.alu_imm(a, .Or, .A, 0x7fffffff) // FMAX
			native.jmp(a, done)
			native.bind(a, calc)
			fpu_root(a)
			native.mov(a, .B, .A)
			native.state_load(a, .A, fs)
			fpu_calc(a, .Fdiv, .Div)
			native.bind(a, done)
			native.state_store(a, fd, .A)
		case .ADD_S: fpu_arith(a, .Fadd, .Add, fd, fs, ft)
		case .SUB_S: fpu_arith(a, .Fsub, .Sub, fd, fs, ft)
		case .MUL_S: fpu_arith(a, .Fmul, .Mul, fd, fs, ft)
		case .DIV_S: fpu_arith(a, .Fdiv, .Div, fd, fs, ft)
		case .ADDA_S: fpu_arith(a, .Fadd, .Add, ACC, fs, ft)
		case .SUBA_S: fpu_arith(a, .Fsub, .Sub, ACC, fs, ft)
		case .MULA_S: fpu_arith(a, .Fmul, .Mul, ACC, fs, ft)
		case .MADD_S, .MSUB_S, .MADDA_S, .MSUBA_S:
			// to = ACC +- fs * ft, each step rounded as its own operation
			native.state_load(a, .A, fs)
			native.state_load(a, .B, ft)
			fpu_calc(a, .Fmul, .Mul)
			native.mov(a, .B, .A)
			native.state_load(a, .A, ACC)
			if i.op == .MADD_S || i.op == .MADDA_S {
				fpu_calc(a, .Fadd, .Add)
			} else {
				fpu_calc(a, .Fsub, .Sub)
			}
			native.state_store(a, fd if i.op == .MADD_S || i.op == .MSUB_S else ACC, .A)
		case .MAX_S, .MIN_S:
			// fd = fs when fkey(fs) >= fkey(ft) (MAX) or <= (MIN), else ft
			pick_ft, done := native.new_label(a), native.new_label(a)
			native.state_load(a, .A, fs)
			fkey(a, .A)
			native.state_load(a, .B, ft)
			fkey(a, .B)
			native.set_cond(a, .Ge if i.op == .MAX_S else .Le, .A, .B)
			native.br_zero(a, .A, pick_ft)
			native.state_load(a, .A, fs)
			native.jmp(a, done)
			native.bind(a, pick_ft)
			native.state_load(a, .A, ft)
			native.bind(a, done)
			native.state_store(a, fd, .A)
		case .C_EQ_S: fpu_compare(a, .Eq, fs, ft)
		case .C_LT_S: fpu_compare(a, .Lt, fs, ft)
		case .C_LE_S: fpu_compare(a, .Le, fs, ft)
		}
	case .MTSA:
		// SA = rs, a bit count, masked as the interpreter does
		get(a, .A, rs)
		native.alu_imm(a, .And, .A, 127)
		native.state_store(a, SA, .A)
	case .MFSA:
		// rd's low doubleword = SA; the high one stays
		if rd == 0 {return true}
		native.state_load(a, .A, SA)
		native.state_store(a, GPR * u32(rd), .A)
		native.state_store_imm(a, GPR * u32(rd) + 4, 0)
	case .MTSAB, .MTSAH:
		// SA = (rs ^ imm) in bytes (MTSAB) or halfwords, as a bit count
		get(a, .A, rs)
		if imm != 0 {native.alu_imm(a, .Xor, .A, imm)}
		native.alu_imm(a, .And, .A, 15 if i.op == .MTSAB else 7)
		native.alu_imm(a, .Shl, .A, 3 if i.op == .MTSAB else 4)
		native.state_store(a, SA, .A)
	case .PADDH, .PSUBW, .PSUBB, .PMAXH, .PMINH, .PCGTH, .POR, .PNOR, .PAND, .PXOR, .PEXTLB, .PEXTUB,
	     .PEXTLH, .PEXTLW, .PEXTUW, .PCPYLD, .PCPYUD, .PPACB, .PPACH, .PCPYH, .PADDSH, .PADDUB, .PADDW,
	     .PADDUW, .PSUBH, .PADDB, .PCEQH, .PEXTUH, .PADDSB, .PSUBSB, .PSUBSH, .PADDSW, .PSUBSW, .PADDUH,
	     .PSUBUH, .PSUBUB, .PSUBUW, .PCGTB, .PCGTW, .PCEQB, .PCEQW, .PMAXW, .PMINW, .PPACW:
		if rd == 0 {return true}
		// rd = x op y, lane-wise, with the operands in the interpreter's order
		v: native.Vop
		x, y := rs, rt
		#partial switch i.op {
		case .PADDH: v = .Add16
		case .PSUBW: v = .Sub32
		case .PSUBB: v = .Sub8
		case .PMAXH: v = .Max16
		case .PMINH: v = .Min16
		case .PCGTH: v = .Gt16
		case .POR: v = .Or
		case .PNOR: v = .Nor
		case .PAND: v = .And
		case .PXOR: v = .Xor
		case .PEXTLB: v, x, y = .Zip_Lo8, rt, rs
		case .PEXTUB: v, x, y = .Zip_Hi8, rt, rs
		case .PEXTLH: v, x, y = .Zip_Lo16, rt, rs
		case .PEXTLW: v, x, y = .Zip_Lo32, rt, rs
		case .PEXTUW: v, x, y = .Zip_Hi32, rt, rs
		case .PCPYLD: v, x, y = .Zip_Lo64, rt, rs
		case .PCPYUD: v = .Zip_Hi64
		case .PPACB: v, x, y = .Even8, rt, rs
		case .PPACH: v, x, y = .Even16, rt, rs
		case .PCPYH: v, x, y = .Dup16, rt, rt
		case .PADDSH: v = .Adds16
		case .PADDUB: v = .Addu8
		case .PADDW: v = .Add32
		case .PADDUW: v = .Addu32
		case .PSUBH: v = .Sub16
		case .PADDB: v = .Add8
		case .PCEQH: v = .Eq16
		case .PEXTUH: v, x, y = .Zip_Hi16, rt, rs
		case .PADDSB: v = .Adds8
		case .PSUBSB: v = .Subs8
		case .PSUBSH: v = .Subs16
		case .PADDSW: v = .Adds32
		case .PSUBSW: v = .Subs32
		case .PADDUH: v = .Addu16
		case .PSUBUH: v = .Subu16
		case .PSUBUB: v = .Subu8
		case .PSUBUW: v = .Subu32
		case .PCGTB: v = .Gt8
		case .PCGTW: v = .Gt32
		case .PCEQB: v = .Eq8
		case .PCEQW: v = .Eq32
		case .PMAXW: v = .Max32
		case .PMINW: v = .Min32
		case .PPACW: v, x, y = .Even32, rt, rs
		}
		native.vec_load(a, .V0, GPR * u32(x))
		native.vec_load(a, .V1, GPR * u32(y))
		native.vec_op(a, v, .V0, .V1)
		native.vec_store(a, GPR * u32(rd), .V0)
	case .PSLLH, .PSRLH, .PSRAH:
		if rd == 0 {return true}
		native.vec_load(a, .V0, GPR * u32(rt))
		native.vec_shift16(a, .Shl if i.op == .PSLLH else .Shr if i.op == .PSRLH else .Sar, .V0, sa & 15)
		native.vec_store(a, GPR * u32(rd), .V0)
	case .PSLLW, .PSRLW, .PSRAW:
		if rd == 0 {return true}
		native.vec_load(a, .V0, GPR * u32(rt))
		native.vec_shift32(a, .Shl if i.op == .PSLLW else .Shr if i.op == .PSRLW else .Sar, .V0, sa)
		native.vec_store(a, GPR * u32(rd), .V0)
	case .PABSH, .PABSW:
		if rd == 0 {return true}
		native.vec_load(a, .V1, GPR * u32(rt))
		native.vec_op(a, .Abs16 if i.op == .PABSH else .Abs32, .V0, .V1)
		native.vec_store(a, GPR * u32(rd), .V0)
	case .PEXEH, .PREVH, .PEXCH, .PEXEW, .PROT3W, .PEXCW:
		if rd == 0 {return true}
		// rd's lanes = rt's in the order the interpreter lists them
		native.vec_load(a, .V0, GPR * u32(rt))
		#partial switch i.op {
		case .PEXEH: native.vec_shuf16(a, .V1, .V0, {2, 1, 0, 3})
		case .PREVH: native.vec_shuf16(a, .V1, .V0, {3, 2, 1, 0})
		case .PEXCH: native.vec_shuf16(a, .V1, .V0, {0, 2, 1, 3})
		case .PEXEW: native.vec_shuf32(a, .V1, .V0, {2, 1, 0, 3})
		case .PROT3W: native.vec_shuf32(a, .V1, .V0, {1, 2, 0, 3})
		case .PEXCW: native.vec_shuf32(a, .V1, .V0, {0, 2, 1, 3})
		}
		native.vec_store(a, GPR * u32(rd), .V1)
	case .PINTH, .PINTEH:
		if rd == 0 {return true}
		// PINTH: rt's halfwords 0-3 interleaved with rs's 4-7, moved down
		// by a doubleword zip. PINTEH: rt's even halfwords in the low half
		// of each word, rs's in the high.
		native.vec_load(a, .V0, GPR * u32(rt))
		native.vec_load(a, .V1, GPR * u32(rs))
		if i.op == .PINTH {
			native.vec_op(a, .Zip_Hi64, .V1, .V1)
			native.vec_op(a, .Zip_Lo16, .V0, .V1)
		} else {
			native.vec_shift32(a, .Shl, .V0, 16)
			native.vec_shift32(a, .Shr, .V0, 16)
			native.vec_shift32(a, .Shl, .V1, 16)
			native.vec_op(a, .Or, .V0, .V1)
		}
		native.vec_store(a, GPR * u32(rd), .V0)
	case .PSLLVW, .PSRLVW, .PSRAVW:
		if rd == 0 {return true}
		// The low word of each doubleword of rt shifted by that of rs (the
		// host masks the count to 5 bits as the guest does), sign-extended.
		for k in u32(0) ..< 2 {
			off := 8 * k
			if rt == 0 {native.mov_imm(a, .A, 0)} else {native.state_load(a, .A, GPR * u32(rt) + off)}
			if rs == 0 {native.mov_imm(a, .B, 0)} else {native.state_load(a, .B, GPR * u32(rs) + off)}
			native.alu(a, .Shl if i.op == .PSLLVW else .Shr if i.op == .PSRLVW else .Sar, .A, .B)
			native.state_store(a, GPR * u32(rd) + off, .A)
			native.alu_imm(a, .Sar, .A, 31)
			native.state_store(a, GPR * u32(rd) + off + 4, .A)
		}
	case .PEXT5, .PPAC5:
		if rd == 0 {return true}
		// Each field of rt's words (bit, width) isolated by a shift up and
		// one down, moved to its place and ORed into V1.
		Field :: struct {from, n, to: u32}
		EXT :: [4]Field{{0, 5, 3}, {5, 5, 11}, {10, 5, 19}, {15, 1, 31}}
		PAC :: [4]Field{{3, 5, 0}, {11, 5, 5}, {19, 5, 10}, {31, 1, 15}}
		native.vec_load(a, .V0, GPR * u32(rt))
		for f, k in (EXT if i.op == .PEXT5 else PAC) {
			t: native.Vreg = .V1 if k == 0 else .V4
			native.vec_copy(a, t, .V0)
			native.vec_shift32(a, .Shl, t, 32 - f.from - f.n)
			native.vec_shift32(a, .Shr, t, 32 - f.n)
			native.vec_shift32(a, .Shl, t, f.to)
			if k != 0 {native.vec_op(a, .Or, .V1, .V4)}
		}
		native.vec_store(a, GPR * u32(rd), .V1)
	case .PADSBH:
		if rd == 0 {return true}
		// rs - rt in the low doubleword, rs + rt in the high
		native.vec_load(a, .V0, GPR * u32(rs))
		native.vec_load(a, .V1, GPR * u32(rt))
		native.vec_copy(a, .V4, .V0)
		native.vec_op(a, .Sub16, .V0, .V1)
		native.vec_op(a, .Add16, .V4, .V1)
		native.vec_op(a, .Zip_Hi64, .V4, .V4)
		native.vec_op(a, .Zip_Lo64, .V0, .V4)
		native.vec_store(a, GPR * u32(rd), .V0)
	case .PHMADH:
		// As the interpreter: the sums v in rd, and the product of the odd
		// halfwords alone, a, with them in LO = {v0, a0, v2, a2} and
		// HI = {v1, a1, v3, a3}, which are written when rd is 0 too. The
		// odd halfwords moved down by a word shift give a.
		native.vec_load(a, .V0, GPR * u32(rs))
		native.vec_load(a, .V1, GPR * u32(rt))
		native.vec_copy(a, .V4, .V0)
		native.vec_shift32(a, .Shr, .V4, 16)
		native.vec_op(a, .Madd16, .V0, .V1)
		native.vec_shift32(a, .Shr, .V1, 16)
		native.vec_op(a, .Madd16, .V4, .V1)
		if rd != 0 {native.vec_store(a, GPR * u32(rd), .V0)}
		native.vec_copy(a, .V1, .V0)
		native.vec_op(a, .Zip_Lo32, .V1, .V4) // v0, a0, v1, a1
		native.vec_op(a, .Zip_Hi32, .V0, .V4) // v2, a2, v3, a3
		native.vec_copy(a, .V4, .V1)
		native.vec_op(a, .Zip_Lo64, .V4, .V0)
		native.vec_op(a, .Zip_Hi64, .V1, .V0)
		native.vec_store(a, LO, .V4)
		native.vec_store(a, HI, .V1)
	case .PMFHI, .PMFLO:
		if rd == 0 {return true}
		native.vec_load(a, .V0, HI if i.op == .PMFHI else LO)
		native.vec_store(a, GPR * u32(rd), .V0)
	case .PMTHI, .PMTLO:
		native.vec_load(a, .V0, GPR * u32(rs))
		native.vec_store(a, HI if i.op == .PMTHI else LO, .V0)
	case .PMTHL:
		// rs's words to LO's and HI's even words, alternately
		for k in u32(0) ..< 4 {
			native.state_load(a, .A, GPR * u32(rs) + 4 * k)
			native.state_store(a, (HI if k & 1 != 0 else LO) + 8 * (k >> 1), .A)
		}
	case .PMFHL:
		if rd == 0 {return true}
		if sa > 1 {
			// SLW, LH, SH and the zero of any other sa: cpu.pmfhl
			native.mov_imm(a, .A, u32(rd))
			native.mov_imm(a, .B, sa)
			native.call(a, "cpu.pmfhl", .A, .B)
			return true
		}
		// LW and UW: LO's and HI's even (or odd) words, alternately
		for k in u32(0) ..< 4 {
			native.state_load(a, .A, (HI if k & 1 != 0 else LO) + 8 * (k >> 1) + 4 * sa)
			native.state_store(a, GPR * u32(rd) + 4 * k, .A)
		}
	case .PDIVW, .PDIVUW:
		// As cpu.div and cpu.divu on the low word of each doubleword, into
		// that doubleword of LO and HI
		for k in u32(0) ..< 2 {
			for r in ([2]struct {dst: native.Reg, n: u8}{{.A, rs}, {.B, rt}}) {
				if r.n == 0 {native.mov_imm(a, r.dst, 0)} else {native.state_load(a, r.dst, GPR * u32(r.n) + 8 * k)}
			}
			native.divide(a, i.op == .PDIVW, LO + 8 * k, HI + 8 * k)
			sx_lohi(a, 8 * k)
		}
	case .PMULTW, .PMULTUW, .PMADDW, .PMADDUW, .PMSUBW, .PMULTH, .PMADDH, .PMSUBH, .PHMSBH:
		// the cpu helper, as emit_mmi calls it
		name: string
		#partial switch i.op {
		case .PMULTW:  name = "cpu.pmultw"
		case .PMULTUW: name = "cpu.pmultuw"
		case .PMADDW:  name = "cpu.pmaddw"
		case .PMADDUW: name = "cpu.pmadduw"
		case .PMSUBW:  name = "cpu.pmsubw"
		case .PMULTH:  name = "cpu.pmulth"
		case .PMADDH:  name = "cpu.pmaddh"
		case .PMSUBH:  name = "cpu.pmsubh"
		case:          name = "cpu.phmsbh"
		}
		native.mov_imm(a, .A, u32(rd))
		native.mov_imm(a, .B, u32(rs))
		native.mov_imm(a, .C, u32(rt))
		native.call(a, name, .A, .B, .C)
	case .PDIVBW:
		native.mov_imm(a, .A, u32(rs))
		native.mov_imm(a, .B, u32(rt))
		native.call(a, "cpu.pdivbw", .A, .B)
	case .QFSRV:
		if rd == 0 {return true}
		// rd = the 128 bits at bit SA of rs:rt, as the interpreter's u128
		// shifts give: rs for SA = 128, 0 above. A shift by whole bytes,
		// 128 too, is a funnel. Any other, which only MTSA can set, takes for lane k
		// words q + k and q + k + 1 of rs:rt, from SA = 32q + r; the
		// second is shifted by 1 then by ~r & 31 = 31 - r, so r = 0 moves
		// nothing across without a branch.
		bits, zero, done := native.new_label(a), native.new_label(a), native.new_label(a)
		native.state_load(a, .A, SA)
		native.br_cmp_imm(a, .Geu, .A, 129, zero)
		native.mov(a, .C, .A)
		native.alu_imm(a, .And, .C, 7)
		native.br_zero(a, .C, bits, nonzero = true)
		native.alu_imm(a, .Shr, .A, 3)
		native.vec_funnel8(a, GPR * u32(rd), GPR * u32(rt), GPR * u32(rs), "ps2.funnel")
		native.jmp(a, done)
		native.bind(a, bits)
		native.vec_load(a, .V0, GPR * u32(rt))
		native.vec_store(a, 0, .V0, "ps2.funnel")
		native.vec_load(a, .V0, GPR * u32(rs))
		native.vec_store(a, 16, .V0, "ps2.funnel")
		native.mov(a, .LD, .A)
		native.alu_imm(a, .And, .LD, 31)
		native.mov(a, .C, .LD)
		native.not(a, .C)
		// V1 = words q to q + 3, V2 = words q + 1 to q + 4; q <= 3, so
		// they end within the 32 bytes.
		native.alu_imm(a, .Shr, .A, 5)
		native.alu_imm(a, .Shl, .A, 2)
		native.vec_ldst_at(a, .V1, "ps2.funnel", false)
		native.alu_imm(a, .Add, .A, 4)
		native.vec_ldst_at(a, .V2, "ps2.funnel", false)
		native.vec_store(a, 0, .V1, "ps2.funnel")
		native.vec_store(a, 16, .V2, "ps2.funnel")
		for k in u32(0) ..< 4 {
			native.imp_load(a, .A, "ps2.funnel", 4 * k)
			native.imp_load(a, .B, "ps2.funnel", 16 + 4 * k)
			native.alu(a, .Shr, .A, .LD)
			native.alu_imm(a, .Shl, .B, 1)
			native.alu(a, .Shl, .B, .C)
			native.alu(a, .Or, .A, .B)
			native.state_store(a, GPR * u32(rd) + 4 * k, .A)
		}
		native.jmp(a, done)
		native.bind(a, zero)
		for k in u32(0) ..< 4 {native.state_store_imm(a, GPR * u32(rd) + 4 * k, 0)}
		native.bind(a, done)
	case .MFC0:
		if rt == 0 {return true}
		if rd == 15 {
			native.mov_imm(a, .A, 0x2e20) // PRId, as the interpreter
		} else {
			native.state_load(a, .A, CYCLES if rd == 9 else COP0 + 4 * u32(rd))
		}
		put_sx(a, rt, .A)
	case .DI:
		native.state_load(a, .A, COP0 + 4 * 12)
		native.alu_imm(a, .And, .A, ~u32(0x10000))
		native.state_store(a, COP0 + 4 * 12, .A)
	case .MTC0:
		get(a, .A, rt)
		native.state_store(a, COP0 + 4 * u32(rd), .A)
	case .ERET:
		// lower returns after it; leave ERL if set, else EXL
		erl, done := native.new_label(a), native.new_label(a)
		native.state_load(a, .A, COP0 + 4 * 12)
		native.mov(a, .B, .A)
		native.alu_imm(a, .And, .B, 4)
		native.br_zero(a, .B, erl, nonzero = true)
		native.alu_imm(a, .And, .A, ~u32(2))
		native.jmp(a, done)
		native.bind(a, erl)
		native.alu_imm(a, .And, .A, ~u32(4))
		native.bind(a, done)
		native.state_store(a, COP0 + 4 * 12, .A)
	case .CFC1:
		if rt == 0 {return true}
		if rd == 0 {
			native.mov_imm(a, .A, 0x2e30)
		} else {
			native.state_load(a, .A, FCR31)
		}
		put_sx(a, rt, .A)
	case .CTC1:
		if rd != 31 {return true}
		get(a, .A, rt)
		native.state_store(a, FCR31, .A)
	case .C_F_S:
		native.state_load(a, .A, FCR31)
		native.alu_imm(a, .And, .A, ~u32(0x800000)) // FCR31_C
		native.state_store(a, FCR31, .A)
	case .EI:
		native.call(a, "kernel.ei")
	case .SYSCALL:
		call_imm(a, "kernel.syscall", i.pc)
	case .BREAK:
		native.mov_imm(a, .A, i.pc)
		native.mov_imm(a, .B, i.w)
		native.call(a, "cpu.brk", .A, .B)
	case .TGE, .TGEU, .TLT, .TLTU, .TEQ, .TNE, .TRAPI:
		cmp, negate, by_imm, ok := trap_test(i)
		if !ok {return true}
		// (B, LD) = rt or the immediate; A = cmp, then cpu.trap unless it
		// says no. Nothing is written on the way.
		if by_imm {
			native.mov_imm(a, .B, simm)
			native.mov_imm(a, .LD, simm_hi)
		} else {
			get(a, .B, rt)
			get(a, .LD, rt, high = true)
		}
		if cmp == .Eq {
			get(a, .A, rs)
			native.alu(a, .Xor, .A, .B)
			get(a, .C, rs, high = true)
			native.alu(a, .Xor, .C, .LD)
			native.alu(a, .Or, .A, .C)
			native.set_cond_imm(a, .Eq, .A, 0)
		} else {
			less64_cond(a, rs, cmp == .Lt)
		}
		if negate {native.alu_imm(a, .Xor, .A, 1)}
		skip := native.new_label(a)
		native.br_zero(a, .A, skip)
		call_imm(a, "cpu.trap", i.pc)
		native.bind(a, skip)
	// No TLB: nothing, as the interpreter.
	case .SYNC, .CACHE, .PREF, .TLBR, .TLBWI, .TLBWR, .TLBP:
	case:
		return false
	}
	return true
}

// The operations of import cpu.fpu_slow, as cpu.Fpu_Op numbers them
// (tests/ee_native checks).
Fpu_Op :: enum u32 {Add, Sub, Mul, Div, Sqrt}

// A = cpu.fpu_sqrt of the f32 bits in A: exponent 0 gives +0, and 255,
// which the EE reads as a number, the root of |A| / 4 with the exponent
// one higher. Any other root is sqrtss of |A|: the f64 root rounded to f32
// is the f32 root, as 53 >= 2 * 24 + 2. Neither the operand nor the root
// is denormal, so FTZ and DAZ don't matter, but this relies on the host's
// default round to nearest, as fpu_calc does. Uses C.
@(private = "file")
fpu_root :: proc(a: ^native.Asm) {
	zero, root, done := native.new_label(a), native.new_label(a), native.new_label(a)
	native.alu_imm(a, .And, .A, 0x7fffffff)
	native.mov(a, .C, .A)
	native.alu_imm(a, .And, .C, 0x7f800000)
	native.br_zero(a, .C, zero)
	native.br_cmp_imm(a, .Ne, .C, 0x7f800000, root)
	native.alu_imm(a, .Sub, .A, 0x01000000)
	native.float_sqrt(a, .A)
	native.alu_imm(a, .Add, .A, 0x00800000)
	native.jmp(a, done)
	native.bind(a, root)
	native.float_sqrt(a, .A)
	native.jmp(a, done)
	native.bind(a, zero)
	native.mov(a, .A, .C)
	native.bind(a, done)
}

// Go to l when the f32 bits in r have exponent 0 or 255 and are not +-0, as
// cpu.fspecial; uses C.
@(private = "file")
br_fspecial :: proc(a: ^native.Asm, r: native.Reg, l: native.Label) {
	ok := native.new_label(a)
	native.mov(a, .C, r)
	native.alu_imm(a, .And, .C, 0x7fffffff)
	native.br_zero(a, .C, ok)
	native.alu_imm(a, .Sub, .C, 0x00800000)
	native.br_cmp_imm(a, .Geu, .C, 0x7f000000, l)
	native.bind(a, ok)
}

// A = A op B on f32 bits, as cpu.fpu_add, fpu_sub, fpu_mul and fpu_div
// with a divisor of nonzero exponent: the host's result unless an operand
// or the result is special, then cpu.fpu_slow's, which a Mul has inline
// (fpu_mul_special) and an Add or Sub too when an operand or the result
// has exponent 255 (fpu_wide). Uses B, C and LD.
@(private = "file")
fpu_calc :: proc(a: ^native.Asm, v: native.Vop, op: Fpu_Op) {
	slow, done := native.new_label(a), native.new_label(a)
	native.mov(a, .LD, .A)
	native.float_op(a, v, .LD, .B)
	br_fspecial(a, .A, slow)
	br_fspecial(a, .B, slow)
	br_fspecial(a, .LD, slow)
	native.mov(a, .A, .LD)
	native.jmp(a, done)
	native.bind(a, slow)
	switch op {
	case .Mul:
		fpu_mul_special(a, done)
		native.bind(a, done)
		return
	case .Add, .Sub:
		wide, call := native.new_label(a), native.new_label(a)
		for r in ([?]native.Reg{.A, .B, .LD}) {
			native.mov(a, .C, r)
			native.alu_imm(a, .And, .C, 0x7f800000)
			native.br_cmp_imm(a, .Eq, .C, 0x7f800000, wide)
		}
		native.jmp(a, call)
		native.bind(a, wide)
		fpu_wide(a, op == .Sub)
		native.jmp(a, done)
		native.bind(a, call)
	case .Div, .Sqrt:
	}
	native.mov_imm(a, .C, u32(op))
	native.call(a, "cpu.fpu_slow", .A, .B, .C)
	native.bind(a, done)
}

// A = cpu.fpu_wide of A and B, B negated first for a Sub: the host sum of
// the halves, an operand of exponent 0 or 1 halved to +-0, then a sum of
// exponent 0 as it is, 255 as +-FMAX, else with the exponent put back.
// Uses B and C.
@(private = "file")
fpu_wide :: proc(a: ^native.Asm, sub: bool) {
	if sub {native.alu_imm(a, .Xor, .B, 0x80000000)}
	for r in ([?]native.Reg{.A, .B}) {
		tiny, next := native.new_label(a), native.new_label(a)
		native.mov(a, .C, r)
		native.alu_imm(a, .And, .C, 0x7f800000)
		native.br_cmp_imm(a, .Ltu, .C, 0x01000000, tiny)
		native.alu_imm(a, .Sub, r, 0x00800000)
		native.jmp(a, next)
		native.bind(a, tiny)
		native.alu_imm(a, .And, r, 0x80000000)
		native.bind(a, next)
	}
	native.float_op(a, .Fadd, .A, .B)
	done, fmax := native.new_label(a), native.new_label(a)
	native.mov(a, .C, .A)
	native.alu_imm(a, .And, .C, 0x7f800000)
	native.br_zero(a, .C, done)
	native.br_cmp_imm(a, .Eq, .C, 0x7f800000, fmax)
	native.alu_imm(a, .Add, .A, 0x00800000)
	native.jmp(a, done)
	native.bind(a, fmax)
	native.alu_imm(a, .Or, .A, 0x7fffffff) // FMAX
	native.bind(a, done)
}

// cpu.fpu_mul's special cases for A * B, the host's product in LD: +-0
// when an operand or LD has exponent 0; else, with B swapped into A when
// B has exponent 255, A = the product with A one exponent lower and the
// exponent put back, or +-FMAX from 2^129. Then on to done. Uses B, C and
// LD.
@(private = "file")
fpu_mul_special :: proc(a: ^native.Asm, done: native.Label) {
	zero, fmax, keep := native.new_label(a), native.new_label(a), native.new_label(a)
	for r in ([?]native.Reg{.A, .B, .LD}) {
		native.mov(a, .C, r)
		native.alu_imm(a, .And, .C, 0x7f800000)
		native.br_zero(a, .C, zero)
	}
	native.mov(a, .C, .B)
	native.alu_imm(a, .And, .C, 0x7f800000)
	native.br_cmp_imm(a, .Ne, .C, 0x7f800000, keep)
	native.mov(a, .C, .A)
	native.mov(a, .A, .B)
	native.mov(a, .B, .C)
	native.bind(a, keep)
	native.mov(a, .C, .A)
	native.alu(a, .Xor, .C, .B)
	native.alu_imm(a, .And, .C, 0x80000000)
	native.alu_imm(a, .Sub, .A, 0x00800000)
	native.float_op(a, .Fmul, .A, .B)
	native.mov(a, .LD, .A)
	native.alu_imm(a, .And, .LD, 0x7f800000)
	native.br_cmp_imm(a, .Eq, .LD, 0x7f800000, fmax)
	native.alu_imm(a, .Add, .A, 0x00800000)
	native.jmp(a, done)
	native.bind(a, fmax)
	native.mov(a, .A, .C)
	native.alu_imm(a, .Or, .A, 0x7fffffff) // FMAX
	native.jmp(a, done)
	native.bind(a, zero)
	native.alu(a, .Xor, .A, .B)
	native.alu_imm(a, .And, .A, 0x80000000)
	native.jmp(a, done)
}

// The f32 field at to = the one at fs op the one at ft, as fpu_calc; a
// Div by a divisor of exponent 0 gives +-FMAX with the sign of fs xor ft,
// as cpu.fpu_div.
@(private = "file")
fpu_arith :: proc(a: ^native.Asm, v: native.Vop, op: Fpu_Op, to, fs, ft: u32) {
	native.state_load(a, .A, fs)
	native.state_load(a, .B, ft)
	if op != .Div {
		fpu_calc(a, v, op)
	} else {
		calc, done := native.new_label(a), native.new_label(a)
		native.mov(a, .C, .B)
		native.alu_imm(a, .And, .C, 0x7f800000)
		native.br_zero(a, .C, calc, nonzero = true)
		native.alu(a, .Xor, .A, .B)
		native.alu_imm(a, .And, .A, 0x80000000)
		native.alu_imm(a, .Or, .A, 0x7fffffff) // FMAX
		native.jmp(a, done)
		native.bind(a, calc)
		fpu_calc(a, v, op)
		native.bind(a, done)
	}
	native.state_store(a, to, .A)
}

// r = cpu.fkey of the f32 bits in r: 0 for exponent 0, else the magnitude
// bits, negated when the sign is set. Uses C.
@(private = "file")
fkey :: proc(a: ^native.Asm, r: native.Reg) {
	keep := native.new_label(a)
	native.mov(a, .C, r)
	native.alu_imm(a, .Sar, .C, 31)
	native.alu_imm(a, .And, r, 0x7fffffff)
	native.br_cmp_imm(a, .Geu, r, 0x00800000, keep)
	native.mov_imm(a, r, 0)
	native.bind(a, keep)
	native.alu(a, .Xor, r, .C)
	native.alu(a, .Sub, r, .C)
}

// FCR31's C bit = fkey(fs) c fkey(ft), as cpu.fcond.
@(private = "file")
fpu_compare :: proc(a: ^native.Asm, c: native.Cond, fs, ft: u32) {
	native.state_load(a, .A, fs)
	fkey(a, .A)
	native.state_load(a, .B, ft)
	fkey(a, .B)
	native.set_cond(a, c, .A, .B)
	native.alu_imm(a, .Shl, .A, 23) // FCR31_C
	native.state_load(a, .B, FCR31)
	native.alu_imm(a, .And, .B, ~u32(0x800000))
	native.alu(a, .Or, .B, .A)
	native.state_store(a, FCR31, .B)
}

// The import holding VU0 control register n (16 up) as vu.vu0_ctrl_read
// reads it (read) or vu0_ctrl_write writes it, else false: the read-only
// ones on a write, and those that read as 0. A write to R keeps its low
// 23 bits; CMSAR1's is the caller's.
@(private = "file")
vu0_ctrl :: proc(n: u8, read: bool) -> (string, bool) {
	switch n {
	case 16: return "vu.status", true
	case 17: return "vu.mac", read
	case 18: return "vu.clip", true
	case 20: return "vu.r", true
	case 21: return "vu.i", true
	case 22: return "vu.q", true
	case 26: return "vu.tpc", read
	case 27: return "vu.cmsar", true
	case 28: return "vu.fbrst", true
	case 31: return "vu.cmsar1", read
	}
	return "", false
}

// Code for a non-control-transfer instruction, as emit_op; slow when it
// calls the interpreter.
@(private = "file")
op :: proc(a: ^native.Asm, i: Insn) -> (slow: bool) {
	if i.op == .SLL && i.w == 0 {return} // nop
	if i.op == .VU0 {
		// vu.vu0_macro, as emit_op calls it, for what native_macro leaves
		if vu.native_macro(a, i.w) {return}
		call_imm(a, "vu.macro", i.w)
		return true
	}
	if inline_op(a, i) {return}
	interp(a, i)
	return true
}

// Call the interpreter for i.
@(private = "file")
interp :: proc(a: ^native.Asm, i: Insn) {
	native.mov_imm(a, .A, i.pc)
	native.mov_imm(a, .B, i.w)
	if i.op == .INVALID {
		native.call(a, "cpu.bad_insn", .A, .B)
	} else {
		native.mov_imm(a, .C, u32(i.op))
		native.call(a, "ps2.exec_op", .A, .B, .C)
	}
}

// T = the condition of branch i, 1 or 0, from the words of its registers.
@(private = "file")
branch_cond :: proc(a: ^native.Asm, i: Insn) {
	if branch_always(i) {
		native.mov_imm(a, .T, 1)
		return
	}
	// T = 1 when rs as a signed doubleword is <= 0
	le_zero :: proc(a: ^native.Asm, rs: u8) {
		get(a, .B, rs)
		get(a, .C, rs, high = true)
		native.alu(a, .Or, .B, .C)
		native.set_cond_imm(a, .Eq, .B, 0)
		get(a, .T, rs, high = true)
		native.set_cond_imm(a, .Lt, .T, 0)
		native.alu(a, .Or, .T, .B)
	}
	rs, rt := i.rs, i.rt
	#partial switch i.op {
	case .BEQ, .BEQL, .BNE, .BNEL:
		get(a, .T, rs)
		get(a, .B, rt)
		native.alu(a, .Xor, .T, .B)
		get(a, .B, rs, high = true)
		get(a, .C, rt, high = true)
		native.alu(a, .Xor, .B, .C)
		native.alu(a, .Or, .T, .B)
		native.set_cond_imm(a, .Eq if i.op == .BEQ || i.op == .BEQL else .Ne, .T, 0)
	case .BLEZ, .BLEZL:
		le_zero(a, rs)
	case .BGTZ, .BGTZL:
		le_zero(a, rs)
		native.alu_imm(a, .Xor, .T, 1)
	case .BLTZ, .BLTZL, .BLTZAL, .BLTZALL:
		get(a, .T, rs, high = true)
		native.set_cond_imm(a, .Lt, .T, 0)
	case .BGEZ, .BGEZL, .BGEZAL, .BGEZALL:
		get(a, .T, rs, high = true)
		native.set_cond_imm(a, .Ge, .T, 0)
	case .BC1F, .BC1FL, .BC1T, .BC1TL:
		native.state_load(a, .T, FCR31)
		native.alu_imm(a, .And, .T, 0x800000)
		native.set_cond_imm(a, .Eq if i.op == .BC1F || i.op == .BC1FL else .Ne, .T, 0)
	case:
		// COP0/COP2 condition lines
		call_imm(a, "ps2.bc_cond", i.w)
		native.mov(a, .T, .A)
	}
}

// pc = t: the block at t, or outside the function's blocks.
@(private = "file")
go :: proc(a: ^native.Asm, f: ^Func, labels: map[u32]native.Label, t: u32) {
	if l, ok := labels[t]; ok {
		native.jmp(a, l)
		return
	}
	native.mov_imm(a, .A, f.entry)
	native.mov_imm(a, .B, t)
	native.call(a, "cpu.jump_unknown", .A, .B)
	native.ret(a)
}

// Machine code for f into a: its entry, then one for each of entries (the
// interior ones the program takes the address of). Returns their code
// offsets, in context.temp_allocator. Counts the sites that call the
// interpreter in slow, per op. funcs holds a label in a for the entry of
// each function a gets: f's is bound here, and a jal to one is a direct
// call, where cpu.call would look the same code up in its table and call
// it (nothing registers over the native functions after load_native).
native_func :: proc(a: ^native.Asm, f: ^Func, entries: []u32, cycles: int, slow: ^map[string]int, funcs: map[u32]native.Label = nil) -> []u32 {
	steps := lower(f, cycles, quiet = true) // emit_func warned
	labels := make(map[u32]native.Label, context.temp_allocator)
	pcs := make([dynamic]u32, context.temp_allocator)
	for s in steps {
		if s.kind == .Case {
			labels[s.target] = native.new_label(a)
			append(&pcs, s.target)
		}
	}
	slice.sort(pcs[:])
	offs := make([]u32, 1 + len(entries), context.temp_allocator)
	offs[0] = u32(native.func_begin(a, "cpu.state"))
	if l, ok := funcs[f.entry]; ok {native.bind_at(a, l, int(offs[0]))}
	trace(a, f.entry)
	events(a)
	go(a, f, labels, f.entry)
	// Open ifs: the label each one ends at, or -1 for a group (Branch,
	// Jump_Reg) that only scopes t.
	ifs := make([dynamic]native.Label, context.temp_allocator)
	// The block so far always leaves; else it ends like the Odin switch case,
	// which runs the case again (pc is still the block's own).
	leaves := true
	block := native.Label(-1)
	lookup := native.Label(-1)
	again :: proc(a: ^native.Asm, leaves: bool, block: native.Label) {
		if !leaves && block >= 0 {native.jmp(a, block)}
	}
	for s in steps {
		was := leaves
		leaves = false
		switch s.kind {
		case .Case:
			if !s.check {again(a, was, block)}
			block = labels[s.target]
			native.bind(a, block)
		case .Op:
			if op(a, s.i) {count_slow(slow, s.i)}
		case .Cycles:
			native.state_add64(a, CYCLES, s.n)
		case .Return:
			native.ret(a)
			leaves = true
		case .Goto:
			if s.check {events(a)}
			go(a, f, labels, s.target)
			leaves = true
		case .Call:
			if l, ok := funcs[s.target]; ok {
				native.call_func(a, l)
			} else {
				call_imm(a, "cpu.call", s.target)
			}
		case .Branch:
			branch_cond(a, s.i)
			append(&ifs, -1)
		case .Link:
			native.state_store_imm(a, GPR * s.n, s.target)
			native.state_store_imm(a, GPR * s.n + 4, 0)
		case .If_Taken:
			skip := native.new_label(a)
			native.br_zero(a, .T, skip)
			append(&ifs, skip)
		case .Jump_Reg:
			get(a, .T, u8(s.n))
			append(&ifs, -1)
		case .Call_Reg:
			native.mov(a, .A, .T)
			native.call(a, "cpu.call", .A)
		case .Goto_Reg:
			events(a)
			if lookup < 0 {lookup = native.new_label(a)}
			native.jmp(a, lookup)
			leaves = true
		case .End:
			if l := pop(&ifs); l >= 0 {
				native.bind(a, l)
			} else {
				leaves = was
			}
		}
	}
	again(a, leaves, block)
	native.func_end(a)
	// One lookup of t among the case pcs, shared by every Goto_Reg.
	if lookup >= 0 {
		native.bind(a, lookup)
		miss := native.new_label(a)
		native.search(a, pcs[:], labels, miss)
		native.bind(a, miss)
		native.mov_imm(a, .A, f.entry)
		native.mov(a, .B, .T)
		native.call(a, "cpu.jump_unknown", .A, .B)
		native.ret(a)
	}
	// Interior entries share the body and its epilogue.
	for e, k in entries {
		offs[1 + k] = u32(native.func_entry(a, "cpu.state"))
		trace(a, e)
		events(a)
		native.jmp(a, labels[e])
	}
	return offs
}
