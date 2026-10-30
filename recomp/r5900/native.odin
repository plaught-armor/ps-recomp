// Native code for lowered functions: the steps emit.odin renders as Odin
// source, as machine code (options native_arch, native_out). Both run the
// same instructions in the same order, so a game can switch between them
// and compare.
//
// The machine is 32-bit; a guest register is its low and high words. The
// integer instructions, branches, links, calls, jumps and cycle charges are
// inline, as are the common MMI ones; the rest call the runtime
// interpreter (ps2.exec_op).
// Runtime procedures and variables are imports by name; ps2/native.odin
// lists them.
package r5900

import "core:slice"
import "../native"

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
	// d = s < (B, LD) as doublewords, signed or not
	less64 :: proc(a: ^native.Asm, d, s: u8, signed: bool) {
		get(a, .A, s, high = true)
		native.mov(a, .C, .A)
		native.set_cond(a, .Lt if signed else .Ltu, .C, .LD)
		native.set_cond(a, .Eq, .A, .LD)
		get(a, .LD, s)
		native.set_cond(a, .Ltu, .LD, .B)
		native.alu(a, .And, .A, .LD)
		native.alu(a, .Or, .A, .C)
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
		for at in ([2]u32{LO + unit, HI + unit}) {
			native.state_load(a, .A, at)
			native.alu_imm(a, .Sar, .A, 31)
			native.state_store(a, at + 4, .A)
		}
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
		for at in ([2]u32{LO + unit, HI + unit}) {
			native.state_load(a, .A, at)
			native.alu_imm(a, .Sar, .A, 31)
			native.state_store(a, at + 4, .A)
		}
		if rd != 0 {copy64(a, GPR * u32(rd), LO + unit)}
	case .PLZCW:
		// cpu.plzcw, as emit_op calls it
		get(a, .A, rs)
		get(a, .B, rs, high = true)
		native.mov_imm(a, .C, u32(rd))
		native.call(a, "cpu.plzcw", .A, .B, .C)
	case .DIV, .DIVU, .DIV1, .DIVU1:
		// cpu.div and cpu.divu, as emit_op calls them
		get(a, .A, rs)
		get(a, .B, rt)
		native.mov_imm(a, .C, 1 if i.op == .DIV1 || i.op == .DIVU1 else 0)
		native.call(a, "cpu.div" if i.op == .DIV || i.op == .DIV1 else "cpu.divu", .A, .B, .C)
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
		// The runtime's mem procedure, as emit_op calls it: it reads the
		// aligned word or doubleword and merges, so MMIO and the watch see
		// what the Odin code does.
		load := i.op == .LWL || i.op == .LWR || i.op == .LDL || i.op == .LDR
		if rt == 0 && load {return true} // no access, as emit_op
		get(a, .A, rs)
		if simm != 0 {native.alu_imm(a, .Add, .A, simm)}
		native.mov_imm(a, .B, u32(rt))
		#partial switch i.op {
		case .LWL: native.call(a, "ps2.lwl", .A, .B)
		case .LWR: native.call(a, "ps2.lwr", .A, .B)
		case .LDL: native.call(a, "ps2.ldl", .A, .B)
		case .LDR: native.call(a, "ps2.ldr", .A, .B)
		case .SWL: native.call(a, "ps2.swl", .A, .B)
		case .SWR: native.call(a, "ps2.swr", .A, .B)
		case .SDL: native.call(a, "ps2.sdl", .A, .B)
		case:      native.call(a, "ps2.sdr", .A, .B)
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
		if rt == 0 {return true}
		native.mov_imm(a, .A, u32(rd))
		native.call(a, "vu.ctrl_read", .A)
		put_sx(a, rt, .A)
	case .CTC2:
		get(a, .B, rt)
		native.mov_imm(a, .A, u32(rd))
		native.call(a, "vu.ctrl_write", .A, .B)
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
	case .MTSAB, .MTSAH:
		// SA = (rs ^ imm) in bytes (MTSAB) or halfwords, as a bit count
		get(a, .A, rs)
		if imm != 0 {native.alu_imm(a, .Xor, .A, imm)}
		native.alu_imm(a, .And, .A, 15 if i.op == .MTSAB else 7)
		native.alu_imm(a, .Shl, .A, 3 if i.op == .MTSAB else 4)
		native.state_store(a, SA, .A)
	case .PADDH, .PSUBW, .PSUBB, .PMAXH, .PMINH, .PCGTH, .POR, .PNOR, .PAND, .PXOR, .PEXTLB, .PEXTUB,
	     .PEXTLH, .PEXTLW, .PEXTUW, .PCPYLD, .PCPYUD, .PPACB, .PPACH, .PCPYH, .PADDSH, .PADDUB, .PADDW,
	     .PADDUW:
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
	case .PSRAW:
		if rd == 0 {return true}
		native.vec_load(a, .V0, GPR * u32(rt))
		native.vec_shift32(a, .Sar, .V0, sa)
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
	case .QFSRV:
		if rd == 0 {return true}
		// A shift by whole bytes below 16 is a funnel; any other SA, which
		// only MTSA can set, goes to the interpreter.
		odd, done := native.new_label(a), native.new_label(a)
		native.state_load(a, .A, SA)
		native.mov(a, .C, .A)
		native.alu_imm(a, .And, .C, ~u32(0x78))
		native.br_zero(a, .C, odd, nonzero = true)
		native.alu_imm(a, .Shr, .A, 3)
		native.vec_funnel8(a, GPR * u32(rd), GPR * u32(rt), GPR * u32(rs), "ps2.funnel")
		native.jmp(a, done)
		native.bind(a, odd)
		interp(a, i)
		native.bind(a, done)
	case .MFC0:
		if rd == 15 {return false} // PRId stays in the interpreter
		if rt == 0 {return true}
		native.state_load(a, .A, CYCLES if rd == 9 else COP0 + 4 * u32(rd))
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
	case .EI:
		native.call(a, "kernel.ei")
	case .SYSCALL:
		call_imm(a, "kernel.syscall", i.pc)
	case .BREAK:
		native.mov_imm(a, .A, i.pc)
		native.mov_imm(a, .B, i.w)
		native.call(a, "cpu.brk", .A, .B)
	case .SYNC, .CACHE, .PREF:
	case:
		return false
	}
	return true
}

// The operations of import cpu.fpu_slow, as cpu.Fpu_Op numbers them
// (tests/ee_native checks).
Fpu_Op :: enum u32 {Add, Sub, Mul, Div, Sqrt}

// A = cpu.fpu_sqrt of the f32 bits in A: exponent 0 gives +0, and 255,
// which the EE reads as a number, cpu.fpu_slow's root. Any other root is
// sqrtss of |A|: the f64 root rounded to f32 is the f32 root, as
// 53 >= 2 * 24 + 2. Neither the operand nor the root is denormal, so FTZ
// and DAZ don't matter, but this relies on the host's default round to
// nearest, as fpu_calc does. Uses B and C.
@(private = "file")
fpu_root :: proc(a: ^native.Asm) {
	zero, slow, done := native.new_label(a), native.new_label(a), native.new_label(a)
	native.alu_imm(a, .And, .A, 0x7fffffff)
	native.mov(a, .C, .A)
	native.alu_imm(a, .And, .C, 0x7f800000)
	native.br_zero(a, .C, zero)
	native.br_cmp_imm(a, .Eq, .C, 0x7f800000, slow)
	native.float_sqrt(a, .A)
	native.jmp(a, done)
	native.bind(a, zero)
	native.mov(a, .A, .C)
	native.jmp(a, done)
	native.bind(a, slow)
	native.mov_imm(a, .C, u32(Fpu_Op.Sqrt))
	native.call(a, "cpu.fpu_slow", .A, .B, .C)
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
// but for an operand of exponent 255 (fpu_mul_special). Uses B, C and LD.
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
	if op == .Mul {
		call := native.new_label(a)
		fpu_mul_special(a, call, done)
		native.bind(a, call)
	}
	native.mov_imm(a, .C, u32(op))
	native.call(a, "cpu.fpu_slow", .A, .B, .C)
	native.bind(a, done)
}

// cpu.fpu_mul's special cases for A * B, the host's product in LD: +-0
// when an operand or LD has exponent 0; on to call when an operand has
// exponent 255; else LD is an infinity, and A = the product one exponent
// lower with the exponent put back, or +-FMAX from 2^129. Then on to done.
// Uses C and LD.
@(private = "file")
fpu_mul_special :: proc(a: ^native.Asm, call, done: native.Label) {
	zero, fmax := native.new_label(a), native.new_label(a)
	for r in ([?]native.Reg{.A, .B, .LD}) {
		native.mov(a, .C, r)
		native.alu_imm(a, .And, .C, 0x7f800000)
		native.br_zero(a, .C, zero)
	}
	for r in ([?]native.Reg{.A, .B}) {
		native.mov(a, .C, r)
		native.alu_imm(a, .And, .C, 0x7f800000)
		native.br_cmp_imm(a, .Eq, .C, 0x7f800000, call)
	}
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

// Offsets in import vu.k, the runtime's lane masks.
@(private = "file")
VU_EXP, VU_SIGN, VU_MAX, VU_ABS, VU_ZERO, VU_DEST :: 0, 16, 32, 48, 64, 80
@(private = "file")
VU_ITOF, VU_FTOI, VU_BIG :: 336, 384, 432 // ITOF and FTOI rows for bc 1-3

// VDIV (key 0x38), VSQRT (0x39) and VRSQRT (0x3a) of VU0 macro op w, as
// vu.vu_op runs them: Q, and status I and D with their sticky bits, as
// vu_div_flags sets them. The results use the host's float divide and
// square root with its default rounding, as the runtime's f32 code does.
// Uses A, B, C, LD, V0 and V1, and keeps T, which can hold a branch
// condition across this op in a delay slot.
@(private = "file")
vu0_div :: proc(a: ^native.Asm, w, key: u32) -> bool {
	fs, fsf, ft, ftf := (w >> 11) & 31, (w >> 21) & 3, (w >> 16) & 31, (w >> 23) & 3
	native.imp_load(a, .A, "vu.vf", 16 * fs + 4 * fsf)
	native.imp_load(a, .B, "vu.vf", 16 * ft + 4 * ftf)
	// LD = the status bits.
	flags := native.new_label(a)
	native.mov_imm(a, .LD, 0)
	native.mov(a, .C, .B)
	native.alu_imm(a, .And, .C, 0x7fffffff)
	if key == 0x39 {
		// vu_div_flags(v, 1, t[ftf] < 0 ? 0 : 1): D where t < 0, so a
		// nonzero magnitude that is not a NaN, with the sign set; -0 and
		// a negative NaN are not below 0.
		native.alu_imm(a, .Sub, .C, 1)
		native.br_cmp_imm(a, .Geu, .C, 0x7f800000, flags)
		native.mov(a, .LD, .B)
		native.alu_imm(a, .Shr, .LD, 31)
		native.alu_imm(a, .Shl, .LD, 5)
	} else {
		// vu_div_flags(v, s[fsf], t[ftf]): `if b == 0 {f = a == 0 ? 0x10
		// : 0x20}`, where only +-0 equals 0: I for 0/0, D for x/0.
		native.br_zero(a, .C, flags, nonzero = true)
		// set_cond_imm takes C for the 0.
		native.mov(a, .LD, .A)
		native.alu_imm(a, .And, .LD, 0x7fffffff)
		native.set_cond_imm(a, .Eq, .LD, 0)
		native.alu_imm(a, .Shl, .LD, 4)
		native.mov_imm(a, .C, 0x20)
		native.alu(a, .Sub, .C, .LD)
		native.mov(a, .LD, .C)
	}
	native.bind(a, flags)
	// v.status = (v.status &~ 0x30) | f | f << 6
	native.imp_load(a, .C, "vu.status")
	native.alu_imm(a, .And, .C, ~u32(0x30))
	native.alu(a, .Or, .C, .LD)
	native.alu_imm(a, .Shl, .LD, 6)
	native.alu(a, .Or, .C, .LD)
	native.imp_store(a, "vu.status", .C)
	// Q into A, from the clamped operands as cpu.fdiv and frsqrt and
	// vu_op's VSQRT take them.
	if key != 0x39 {fclamp_gpr(a, .A, .C)}
	fclamp_gpr(a, .B, .C)
	store, fmax := native.new_label(a), native.new_label(a)
	switch key {
	case 0x38:
		// cpu.fdiv: a divisor of exponent 0 gives +-FMAX with the sign of
		// a ^ b, else fclamp(a / b).
		native.mov(a, .C, .B)
		native.alu_imm(a, .And, .C, 0x7f800000)
		native.mov(a, .LD, .A)
		native.alu(a, .Xor, .LD, .B)
		native.br_zero(a, .C, fmax)
		native.float_op(a, .Fdiv, .A, .B)
	case 0x39:
		// math.sqrt(abs(ct[ftf])), the root not clamped
		native.mov(a, .A, .B)
		native.alu_imm(a, .And, .A, 0x7fffffff)
		native.float_sqrt(a, .A)
		native.jmp(a, store)
	case 0x3a:
		// cpu.frsqrt: s = sqrt(|b|); s of exponent 0 gives +-FMAX with
		// the sign of a, else fclamp(a / s).
		native.alu_imm(a, .And, .B, 0x7fffffff)
		native.float_sqrt(a, .B)
		native.mov(a, .C, .B)
		native.alu_imm(a, .And, .C, 0x7f800000)
		native.mov(a, .LD, .A)
		native.br_zero(a, .C, fmax)
		native.float_op(a, .Fdiv, .A, .B)
	}
	fclamp_gpr(a, .A, .C)
	native.jmp(a, store)
	native.bind(a, fmax) // the sign in LD
	native.mov(a, .A, .LD)
	native.alu_imm(a, .And, .A, 0x80000000)
	native.alu_imm(a, .Or, .A, 0x7f7fffff)
	native.bind(a, store)
	native.imp_store(a, "vu.q", .A)
	return true
}

// The offset of vi from vf in vu.Vu, which ps2/native.odin asserts: the VI
// registers are reached through import vu.vf.
@(private = "file")
VU_VI :: 512

// r = VU0's vi[n & 15] in its low 16 bits, the rest garbage, or
// sign-extended with signed.
@(private = "file")
vi_get :: proc(a: ^native.Asm, r: native.Reg, n: u32, signed := false) {
	native.imp_load(a, r, "vu.vf", VU_VI + 4 * ((n & 15) >> 1))
	if signed {
		if n & 1 == 0 {native.alu_imm(a, .Shl, r, 16)}
		native.alu_imm(a, .Sar, r, 16)
	} else if n & 1 != 0 {
		native.alu_imm(a, .Shr, r, 16)
	}
}

// VU0's vi[n & 15] = the low 16 bits of A, by a read and write of the word
// that holds it. Loses A and C.
@(private = "file")
vi_put :: proc(a: ^native.Asm, n: u32) {
	off := VU_VI + 4 * ((n & 15) >> 1)
	native.imp_load(a, .C, "vu.vf", off)
	native.alu_imm(a, .And, .C, n & 1 != 0 ? 0xffff : 0xffff0000)
	native.alu_imm(a, .And, .A, 0xffff)
	if n & 1 != 0 {native.alu_imm(a, .Shl, .A, 16)}
	native.alu(a, .Or, .C, .A)
	native.imp_store(a, "vu.vf", .C, off)
}

// Code for VU0 macro op w with fn 0x30-0x3b as vu.vu_op runs it, or false
// to leave it there: VIADD, VISUB, VIADDI, VIAND, VIOR, VCALLMS and
// VCALLMSR. As there, an integer op is skipped on a 5-bit destination
// field of 0 and indexes with its low 4 bits, so a field of 16 writes
// vi[0]. Uses A, B and C.
@(private = "file")
vu0_lower :: proc(a: ^native.Asm, w: u32) -> bool {
	ft, fs, fd := (w >> 16) & 31, (w >> 11) & 31, (w >> 6) & 31
	op: native.Alu
	switch w & 63 {
	case 0x30, 0x32: op = .Add
	case 0x31: op = .Sub
	case 0x34: op = .And
	case 0x35: op = .Or
	case 0x38:
		call_imm(a, "vu.call_micro", ((w >> 6) & 0x7fff) * 8)
		return true
	case 0x39:
		native.imp_load(a, .A, "vu.cmsar")
		native.alu_imm(a, .Shl, .A, 3)
		native.call(a, "vu.call_micro", .A)
		return true
	case: return false
	}
	if w & 63 == 0x32 {
		// VIADDI: vi[ft] = vi[fs] + imm5, the fd field sign-extended
		if ft == 0 {return true}
		vi_get(a, .A, fs)
		native.alu_imm(a, .Add, .A, u32(i32(fd << 27) >> 27))
		vi_put(a, ft)
		return true
	}
	if fd == 0 {return true}
	vi_get(a, .A, fs)
	vi_get(a, .B, ft)
	native.alu(a, op, .A, .B)
	vi_put(a, fd)
	return true
}

// V0 = its dest lanes, V1's in the others. Loses V2.
@(private = "file")
merge_dest :: proc(a: ^native.Asm, dest: u32) {
	native.vec_load(a, .V2, VU_DEST + 16 * dest, "vu.k")
	native.vec_op(a, .And, .V0, .V2)
	native.vec_op(a, .Andn, .V2, .V1)
	native.vec_op(a, .Or, .V0, .V2)
}

// VLQI (key 0x34), VSQI (0x35), VLQD (0x36) and VSQD (0x37) of VU0 macro
// op w, as vu.vu_op runs them: the quadword at (vi[r] & 0xff) * 16 of data
// memory, import vu.mem, for r = fs & 15 (a load) or ft & 15 (a store).
// The D forms decrement vi[r] first, even vi[0]; the I forms increment it
// after, not vi[0]. A load writes the dest lanes of vf[ft], not vf0; a
// store the dest lanes of the quadword from vf[fs]. vi[0] is 0 after.
// Uses A, B, C and V0-V2.
@(private = "file")
vu0_lq_sq :: proc(a: ^native.Asm, w, key: u32) {
	dest, ft, fs := (w >> 21) & 15, (w >> 16) & 31, (w >> 11) & 31
	store := key & 1 != 0
	r := (ft if store else fs) & 15
	vi_get(a, .A, r)
	if key >= 0x36 {
		native.alu_imm(a, .Sub, .A, 1)
		if r != 0 {
			native.mov(a, .B, .A)
			vi_put(a, r)
			native.mov(a, .A, .B)
		}
	} else if r != 0 {
		native.mov(a, .B, .A)
	}
	native.alu_imm(a, .And, .A, 0xff)
	native.alu_imm(a, .Shl, .A, 4)
	if store && dest != 0 {
		native.vec_load(a, .V0, 16 * fs, "vu.vf")
		if dest != 15 {
			native.vec_ldst_at(a, .V1, "vu.mem", false)
			merge_dest(a, dest)
		}
		native.vec_ldst_at(a, .V0, "vu.mem", true)
	} else if !store && ft != 0 && dest != 0 {
		native.vec_ldst_at(a, .V0, "vu.mem", false)
		if dest != 15 {
			native.vec_load(a, .V1, 16 * ft, "vu.vf")
			merge_dest(a, dest)
		}
		native.vec_store(a, 16 * ft, .V0, "vu.vf")
	}
	if key < 0x36 && r != 0 {
		native.mov(a, .A, .B)
		native.alu_imm(a, .Add, .A, 1)
		vi_put(a, r)
	}
	native.imp_load(a, .C, "vu.vf", VU_VI)
	native.alu_imm(a, .And, .C, 0xffff0000)
	native.imp_store(a, "vu.vf", .C, VU_VI)
}

// r = cpu.fclamp of the f32 bits in r: exponent 255 to +-FMAX, exponent 0
// to +-0. Uses t.
@(private = "file")
fclamp_gpr :: proc(a: ^native.Asm, r, t: native.Reg) {
	zero, done := native.new_label(a), native.new_label(a)
	native.mov(a, t, r)
	native.alu_imm(a, .And, t, 0x7f800000)
	native.br_zero(a, t, zero)
	native.br_cmp_imm(a, .Ne, t, 0x7f800000, done)
	native.alu_imm(a, .And, r, 0x80000000)
	native.alu_imm(a, .Or, r, 0x7f7fffff)
	native.jmp(a, done)
	native.bind(a, zero)
	native.alu_imm(a, .And, r, 0x80000000)
	native.bind(a, done)
}

// Code for VU0 macro op w as vu.vu_op runs it, or false to leave it there:
// moves, waits, the float upper ops of the VF registers and ACC with their
// broadcast, Q and I forms, and ITOF, FTOI and ABS. Results clamp and set
// MAC and status as vu_put_flags does, and the add and multiply operands
// clamp first as vu_op's do. MAX and MINI order the raw words by sign and
// magnitude and write the winner as it is, as ps2/vu vmax and vmin. ITOF,
// FTOI, ABS, MAX and MINI set no flags. VMFIR, the quadword loads and
// stores of vu0_lq_sq and, through vu0_lower, the integer ops and VCALLMS
// too. Uses A, B, C and V0-V4.
@(private = "file")
vu0_op :: proc(a: ^native.Asm, w: u32) -> bool {
	Kind :: enum u8 {Add, Sub, Mul, Madd, Msub, Max, Mini, Opmul, Opmsub, Move, Mr32, Nop, Itof, Ftoi, Abs}
	Src :: enum u8 {Vec, Bc, Q, I}
	dest, ft, fs, fd, bc := (w >> 21) & 15, (w >> 16) & 31, (w >> 11) & 31, (w >> 6) & 31, w & 3
	fn := w & 63
	upper := fn < 0x3c
	key := upper ? fn : ((w >> 4) & 0x7c) | bc
	if upper && fn >= 0x30 {return vu0_lower(a, w)}
	kind: Kind
	src := Src.Vec
	switch key {
	case 0x00 ..= 0x03: kind, src = .Add, .Bc
	case 0x04 ..= 0x07: kind, src = .Sub, .Bc
	case 0x08 ..= 0x0b: kind, src = .Madd, .Bc
	case 0x0c ..= 0x0f: kind, src = .Msub, .Bc
	case 0x10 ..= 0x13: kind, src = upper ? Kind.Max : Kind.Itof, .Bc
	case 0x14 ..= 0x17: kind, src = upper ? Kind.Mini : Kind.Ftoi, .Bc
	case 0x18 ..= 0x1b: kind, src = .Mul, .Bc
	case 0x1c: kind, src = .Mul, .Q
	case 0x1d: kind, src = upper ? Kind.Max : Kind.Abs, .I
	case 0x1e: kind, src = .Mul, .I
	case 0x1f: if !upper {return false}; kind, src = .Mini, .I // not VCLIP
	case 0x20: kind, src = .Add, .Q
	case 0x21: kind, src = .Madd, .Q
	case 0x22: kind, src = .Add, .I
	case 0x23: kind, src = .Madd, .I
	case 0x24: kind, src = .Sub, .Q
	case 0x25: kind, src = .Msub, .Q
	case 0x26: kind, src = .Sub, .I
	case 0x27: kind, src = .Msub, .I
	case 0x28: kind = .Add
	case 0x29: kind = .Madd
	case 0x2a: kind = .Mul
	case 0x2b: if !upper {return false}; kind = .Max
	case 0x2c: kind = .Sub
	case 0x2d: kind = .Msub
	case 0x2e: kind = upper ? .Opmsub : .Opmul
	case 0x2f: kind = upper ? Kind.Mini : Kind.Nop // VNOP
	case 0x30: kind = .Move
	case 0x31: kind = .Mr32
	case 0x34 ..= 0x37:
		vu0_lq_sq(a, w, key)
		return true
	case 0x38 ..= 0x3a: return vu0_div(a, w, key)
	case 0x3b: kind = .Nop // VWAITQ
	case 0x3d:
		// VMFIR: vf[ft] = vi[fs & 15] sign-extended, in the dest lanes
		if ft == 0 {return true}
		vi_get(a, .A, fs, signed = true)
		for k in u32(0) ..< 4 {
			if dest & (8 >> k) != 0 {native.imp_store(a, "vu.vf", .A, 16 * ft + 4 * k)}
		}
		return true
	case: return false
	}
	// The dest lanes of V0 into the field at off from import base; loses V1
	// and V2.
	put :: proc(a: ^native.Asm, off: u32, base: string, dest: u32) {
		if dest == 0 {return}
		if dest != 15 {
			native.vec_load(a, .V1, off, base)
			merge_dest(a, dest)
		}
		native.vec_store(a, off, .V0, base)
	}
	// vclamp of x: an infinite or NaN lane to the largest finite value of
	// its sign, a denormal one to zero of its sign. Loses t1, t2 and t3.
	clamp :: proc(a: ^native.Asm, x, t1, t2, t3: native.Vreg) {
		native.vec_load(a, t1, VU_EXP, "vu.k")
		native.vec_op(a, .And, t1, x)
		native.vec_load(a, t2, VU_EXP, "vu.k")
		native.vec_op(a, .Eq32, t2, t1) // exponent all ones
		native.vec_load(a, t3, VU_ZERO, "vu.k")
		native.vec_op(a, .Eq32, t3, t1) // exponent zero
		native.vec_op(a, .Or, t3, t2)
		native.vec_load(a, t1, VU_MAX, "vu.k")
		native.vec_op(a, .And, t1, t2)
		native.vec_load(a, t2, VU_SIGN, "vu.k")
		native.vec_op(a, .And, t2, x)
		native.vec_op(a, .Or, t1, t2)
		native.vec_op(a, .And, t1, t3)
		native.vec_op(a, .Andn, t3, x)
		native.vec_op(a, .Or, t3, t1)
		native.vec_copy(a, x, t3)
	}
	switch kind {
	case .Nop:
		return true
	case .Itof:
		// No clamp: an i32 times 1, 2^-4, 2^-12 or 2^-15 is never infinite,
		// NaN or denormal.
		if ft == 0 {return true}
		native.vec_load(a, .V1, 16 * fs, "vu.vf")
		native.vec_op(a, .Itof, .V0, .V1)
		if bc != 0 {
			native.vec_load(a, .V1, VU_ITOF + 16 * (bc - 1), "vu.k")
			native.vec_op(a, .Fmul, .V0, .V1)
		}
		put(a, 16 * ft, "vu.vf", dest)
		return true
	case .Ftoi:
		// cvt_w of the raw lanes times the scale: |x| >= 2^31, infinite or
		// NaN saturates by sign.
		if ft == 0 || dest == 0 {return true}
		native.vec_load(a, .V0, 16 * fs, "vu.vf")
		if bc != 0 {
			native.vec_load(a, .V1, VU_FTOI + 16 * (bc - 1), "vu.k")
			native.vec_op(a, .Fmul, .V0, .V1)
		}
		native.vec_op(a, .Ftoi, .V1, .V0)
		native.vec_load(a, .V2, VU_ABS, "vu.k")
		native.vec_op(a, .And, .V2, .V0)
		native.vec_load(a, .V3, VU_BIG, "vu.k")
		native.vec_op(a, .Gt32, .V2, .V3) // out of range
		native.vec_load(a, .V3, VU_SIGN, "vu.k")
		native.vec_op(a, .And, .V3, .V0)
		native.vec_load(a, .V4, VU_ZERO, "vu.k")
		native.vec_op(a, .Eq32, .V4, .V3) // sign clear
		native.vec_load(a, .V3, VU_SIGN, "vu.k")
		native.vec_op(a, .Xor, .V3, .V4) // 0x7fffffff or 0x80000000
		native.vec_op(a, .And, .V3, .V2)
		native.vec_op(a, .Andn, .V2, .V1)
		native.vec_op(a, .Or, .V2, .V3)
		native.vec_copy(a, .V0, .V2)
		put(a, 16 * ft, "vu.vf", dest)
		return true
	case .Abs:
		if ft == 0 {return true}
		native.vec_load(a, .V0, 16 * fs, "vu.vf")
		native.vec_load(a, .V1, VU_ABS, "vu.k")
		native.vec_op(a, .And, .V0, .V1)
		clamp(a, .V0, .V1, .V2, .V3)
		put(a, 16 * ft, "vu.vf", dest)
		return true
	case .Max, .Mini:
		if fd == 0 || dest == 0 {return true}
		native.vec_load(a, .V0, 16 * fs, "vu.vf")
		switch src {
		case .Vec:
			native.vec_load(a, .V1, 16 * ft, "vu.vf")
		case .Bc:
			native.vec_load(a, .V2, 16 * ft, "vu.vf")
			native.vec_shuf32(a, .V1, .V2, u8(bc))
		case .Q:
			native.vec_splat_load(a, .V1, "vu.q")
		case .I:
			native.vec_splat_load(a, .V1, "vu.i")
		}
		// The order key of each word: x ^ 0x7fffffff where x < 0, so
		// signed lanes compare as sign and magnitude.
		key :: proc(a: ^native.Asm, dst, x: native.Vreg) {
			native.vec_load(a, dst, VU_ZERO, "vu.k")
			native.vec_op(a, .Gt32, dst, x)
			native.vec_load(a, .V4, VU_ABS, "vu.k")
			native.vec_op(a, .And, dst, .V4)
			native.vec_op(a, .Xor, dst, x)
		}
		key(a, .V2, .V0)
		key(a, .V3, .V1)
		// Where the mask is set fs wins, else t.
		if kind == .Max {
			native.vec_op(a, .Gt32, .V2, .V3)
		} else {
			native.vec_op(a, .Gt32, .V3, .V2)
			native.vec_copy(a, .V2, .V3)
		}
		native.vec_op(a, .And, .V0, .V2)
		native.vec_op(a, .Andn, .V2, .V1)
		native.vec_op(a, .Or, .V0, .V2)
		put(a, 16 * fd, "vu.vf", dest)
		return true
	case .Move, .Mr32:
		// Bits as they are, no flags.
		if ft == 0 {return true}
		if kind == .Move {
			native.vec_load(a, .V0, 16 * fs, "vu.vf")
		} else {
			native.vec_load(a, .V1, 16 * fs, "vu.vf")
			native.vec_shuf32(a, .V0, .V1, {1, 2, 3, 0})
		}
		put(a, 16 * ft, "vu.vf", dest)
		return true
	case .Opmul, .Opmsub:
		// fs.yzx * ft.zxy
		dest = 0xe
		native.vec_load(a, .V2, 16 * fs, "vu.vf")
		native.vec_shuf32(a, .V0, .V2, {1, 2, 0, 3})
		native.vec_load(a, .V2, 16 * ft, "vu.vf")
		native.vec_shuf32(a, .V1, .V2, {2, 0, 1, 3})
		clamp(a, .V0, .V2, .V3, .V4)
		clamp(a, .V1, .V2, .V3, .V4)
		native.vec_op(a, .Fmul, .V0, .V1)
	case .Add, .Sub, .Mul, .Madd, .Msub:
		native.vec_load(a, .V0, 16 * fs, "vu.vf")
		switch src {
		case .Vec:
			native.vec_load(a, .V1, 16 * ft, "vu.vf")
		case .Bc:
			native.vec_load(a, .V2, 16 * ft, "vu.vf")
			native.vec_shuf32(a, .V1, .V2, u8(bc))
		case .Q:
			native.vec_splat_load(a, .V1, "vu.q")
		case .I:
			native.vec_splat_load(a, .V1, "vu.i")
		}
		clamp(a, .V0, .V2, .V3, .V4)
		clamp(a, .V1, .V2, .V3, .V4)
		#partial switch kind {
		case .Add: native.vec_op(a, .Fadd, .V0, .V1)
		case .Sub: native.vec_op(a, .Fsub, .V0, .V1)
		case: native.vec_op(a, .Fmul, .V0, .V1)
		}
	}
	if kind == .Madd || kind == .Msub || kind == .Opmsub {
		// acc + or - the product, rounded on its own first
		native.vec_load(a, .V1, 0, "vu.acc")
		native.vec_op(a, .Fadd if kind == .Madd else .Fsub, .V1, .V0)
		native.vec_copy(a, .V0, .V1)
	}
	clamp(a, .V0, .V1, .V2, .V3)
	// MAC: zero lanes in bits 0-3, signs in 4-7, of the dest lanes
	native.vec_load(a, .V1, VU_ABS, "vu.k")
	native.vec_op(a, .And, .V1, .V0)
	native.vec_load(a, .V2, VU_ZERO, "vu.k")
	native.vec_op(a, .Eq32, .V1, .V2)
	native.vec_signs(a, .B, .V1)
	native.alu_imm(a, .And, .B, dest)
	native.vec_copy(a, .V1, .V0)
	native.vec_signs(a, .A, .V1)
	native.alu_imm(a, .And, .A, dest)
	if kind == .Add || kind == .Sub || kind == .Mul || kind == .Madd || kind == .Msub {
		if !upper {
			put(a, 0, "vu.acc", dest)
		} else if fd != 0 {
			put(a, 16 * fd, "vu.vf", dest)
		}
	} else if kind == .Opmul {
		put(a, 0, "vu.acc", dest)
	} else if fd != 0 {
		put(a, 16 * fd, "vu.vf", dest)
	}
	native.mov(a, .C, .A)
	native.alu_imm(a, .Shl, .C, 4)
	native.alu(a, .Or, .C, .B)
	native.imp_store(a, "vu.mac", .C)
	// status: Z and S in bits 0-1, sticky in 6-7
	native.set_cond_imm(a, .Ne, .A, 0)
	native.alu_imm(a, .Shl, .A, 1)
	native.set_cond_imm(a, .Ne, .B, 0)
	native.alu(a, .Or, .B, .A)
	native.mov(a, .A, .B)
	native.alu_imm(a, .Shl, .A, 6)
	native.alu(a, .Or, .B, .A)
	native.imp_load(a, .A, "vu.status")
	native.alu_imm(a, .And, .A, ~u32(0xf))
	native.alu(a, .Or, .A, .B)
	native.imp_store(a, "vu.status", .A)
	return true
}

// Code for a non-control-transfer instruction, as emit_op; slow when it
// calls the interpreter.
@(private = "file")
op :: proc(a: ^native.Asm, i: Insn) -> (slow: bool) {
	if i.op == .SLL && i.w == 0 {return} // nop
	if i.op == .VU0 {
		// vu.vu0_macro, as emit_op calls it, for what vu0_op leaves
		if vu0_op(a, i.w) {return}
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
// interpreter in slow, per op.
native_func :: proc(a: ^native.Asm, f: ^Func, entries: []u32, cycles: int, slow: ^map[string]int) -> []u32 {
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
			call_imm(a, "cpu.call", s.target)
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
