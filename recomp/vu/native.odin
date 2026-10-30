// VU code as native machine code, through the native package's Asm: the
// VU0 macro instructions for the EE recompiler (native_macro), and whole
// microprograms (native_program), with the semantics vu.odin gives them in
// Odin and the runtime's interpreter (ps2/vu/vu.odin) has.
//
// The code reaches a unit's registers through imports the runtime binds
// (ps2/native.odin): VU0's are named vu.*, VU1's vu1.*. A microprogram is a
// function with no arguments. It reads where to start from import
// <unit>.run_pc and the taken-branch budget from <unit>.run_budget, and
// leaves in run_pc the pc it stopped at, with bit 31 set when the program
// ended (Vu_Exit .End, else .Leave), and the budget left in run_budget.
// Globals rather than arguments, as functions from the Asm take none, the
// same as the EE's.
//
// Only the Asm's operations are used, so every architecture it targets gets
// the same code.
package vu

import "../mips"
import "../native"

// The imports a unit's code uses.
@(private)
Imp :: enum u8 {
	Vf, // vf, then vi at VU_VI
	Acc,
	Q,
	I,
	P,
	Mac,
	Status,
	Clip,
	Mem, // data memory
	Upper, // the interpreter: proc(uw: u32)
	Lower, // proc(lw, pc: u32)
	Pair, // proc(uw, lw, pc: u32)
	Xgkick, // proc(addr: u16)
	Top, // the unit's VIF TOP and ITOP
	Itop,
	Call_Micro, // VCALLMS: proc(addr: u32)
	Cmsar,
	Run_Pc,
	Run_Budget,
	Scratch, // SCRATCH_SIZE bytes, 16-byte aligned
}

@(private, rodata)
IMPORTS := [Unit][Imp]string {
	.VU0 = {
		.Vf = "vu.vf",
		.Acc = "vu.acc",
		.Q = "vu.q",
		.I = "vu.i",
		.P = "vu.p",
		.Mac = "vu.mac",
		.Status = "vu.status",
		.Clip = "vu.clip",
		.Mem = "vu.mem",
		.Upper = "vu.upper",
		.Lower = "vu.lower",
		.Pair = "vu.pair",
		.Xgkick = "",
		.Top = "",
		.Itop = "vu.itop",
		.Call_Micro = "vu.call_micro",
		.Cmsar = "vu.cmsar",
		.Run_Pc = "vu.run_pc",
		.Run_Budget = "vu.run_budget",
		.Scratch = "vu.scratch",
	},
	.VU1 = {
		.Vf = "vu1.vf",
		.Acc = "vu1.acc",
		.Q = "vu1.q",
		.I = "vu1.i",
		.P = "vu1.p",
		.Mac = "vu1.mac",
		.Status = "vu1.status",
		.Clip = "vu1.clip",
		.Mem = "vu1.mem",
		.Upper = "vu1.upper",
		.Lower = "vu1.lower",
		.Pair = "vu1.pair",
		.Xgkick = "vu1.xgkick",
		.Top = "vu1.top",
		.Itop = "vu1.itop",
		.Call_Micro = "",
		.Cmsar = "",
		.Run_Pc = "vu1.run_pc",
		.Run_Budget = "vu1.run_budget",
		.Scratch = "vu1.scratch",
	},
}

// The import of the runtime's lane masks, shared by both units.
@(private = "file")
K :: "vu.k"

// Offsets in import vu.k.
@(private = "file")
VU_EXP, VU_SIGN, VU_MAX, VU_ABS, VU_ZERO, VU_DEST :: 0, 16, 32, 48, 64, 80
@(private = "file")
VU_ITOF, VU_FTOI, VU_BIG :: 336, 384, 432 // ITOF and FTOI rows for bc 1-3

// The offset of vi from vf in vu.Vu, which ps2/native.odin asserts: the VI
// registers are reached through import vf.
VU_VI :: 512

// The bytes of import scratch, and what they hold: a VF register before and
// after a hazard pair's upper op, a quadword of data memory for ILW and ISW,
// and status around a VU0 DIV-family pair's halves.
SCRATCH_SIZE :: 64
@(private = "file")
SCR_SAVED, SCR_RESULT, SCR_QUAD, SCR_ST0, SCR_UST :: 0, 16, 32, 48, 52

// Each unit's data memory size in quadwords, less one: the mask of an
// address in vi.
@(private = "file", rodata)
MEM_QUADS := [Unit]u32 {
	.VU0 = 0xff,
	.VU1 = 0x3ff,
}

// VCLIP (key 0x1f) of op w, as vu.vu_op runs it: the judgment of fs.xyz
// against +-|ft.w| shifted into clip. The interpreter compares host floats,
// with no denormal flush, which order as their magnitude bits do when
// neither is a NaN: a NaN |ft.w| or a NaN lane sets no bit, and a lane
// whose magnitude is above |ft.w|'s sets bit 2k when positive, 2k + 1 when
// negative. Uses A, B, C and LD, and keeps T.
@(private = "file")
clip :: proc(a: ^native.Asm, u: Unit, w: u32) -> bool {
	fs, ft := (w >> 11) & 31, (w >> 16) & 31
	vf := IMPORTS[u][.Vf]
	done := native.new_label(a)
	native.mov_imm(a, .LD, 0)
	// B = |ft.w| + 1: a magnitude above |ft.w| is at or above B.
	native.imp_load(a, .B, vf, 16 * ft + 12)
	native.alu_imm(a, .And, .B, 0x7fffffff)
	native.br_cmp_imm(a, .Geu, .B, 0x7f800001, done)
	native.alu_imm(a, .Add, .B, 1)
	for k in u32(0) ..< 3 {
		skip := native.new_label(a)
		native.imp_load(a, .A, vf, 16 * fs + 4 * k)
		native.mov(a, .C, .A)
		native.alu_imm(a, .And, .C, 0x7fffffff)
		native.br_cmp_imm(a, .Geu, .C, 0x7f800001, skip)
		native.set_cond(a, .Geu, .C, .B)
		native.br_zero(a, .C, skip)
		// (1 + sign) << 2k
		native.alu_imm(a, .Shr, .A, 31)
		native.alu_imm(a, .Add, .A, 1)
		if k != 0 {native.alu_imm(a, .Shl, .A, 2 * k)}
		native.alu(a, .Or, .LD, .A)
		native.bind(a, skip)
	}
	native.bind(a, done)
	// v.clip = ((v.clip << 6) | f) & 0xffffff
	native.imp_load(a, .A, IMPORTS[u][.Clip])
	native.alu_imm(a, .Shl, .A, 6)
	native.alu(a, .Or, .A, .LD)
	native.alu_imm(a, .And, .A, 0xffffff)
	native.imp_store(a, IMPORTS[u][.Clip], .A)
	return true
}

// DIV (key 0x38), SQRT (0x39) and RSQRT (0x3a) of op w, as vu.vu_op runs
// them: Q, and with status, status I and D with their sticky bits, as
// vu_div_flags sets them. The results use the host's float divide and
// square root with its default rounding, as the runtime's f32 code does.
// Uses A, B, C, LD, V0 and V1, and keeps T, which can hold a branch
// condition across this op in a delay slot.
@(private = "file")
div :: proc(a: ^native.Asm, u: Unit, w, key: u32, status: bool) -> bool {
	fs, fsf, ft, ftf := (w >> 11) & 31, (w >> 21) & 3, (w >> 16) & 31, (w >> 23) & 3
	native.imp_load(a, .A, IMPORTS[u][.Vf], 16 * fs + 4 * fsf)
	native.imp_load(a, .B, IMPORTS[u][.Vf], 16 * ft + 4 * ftf)
	if status {
		// LD = the status bits.
		flags := native.new_label(a)
		native.mov_imm(a, .LD, 0)
		native.mov(a, .C, .B)
		native.alu_imm(a, .And, .C, 0x7fffffff)
		if key == 0x39 {
			// vu_div_flags(v, 1, t[ftf] < 0 ? 0 : 1): D where t < 0, so a
			// nonzero magnitude that is not a NaN, with the sign set; -0
			// and a negative NaN are not below 0.
			native.alu_imm(a, .Sub, .C, 1)
			native.br_cmp_imm(a, .Geu, .C, 0x7f800000, flags)
			native.mov(a, .LD, .B)
			native.alu_imm(a, .Shr, .LD, 31)
			native.alu_imm(a, .Shl, .LD, 5)
		} else {
			// vu_div_flags(v, s[fsf], t[ftf]): `if b == 0 {f = a == 0 ?
			// 0x10 : 0x20}`, where only +-0 equals 0: I for 0/0, D for x/0.
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
		native.imp_load(a, .C, IMPORTS[u][.Status])
		native.alu_imm(a, .And, .C, ~u32(0x30))
		native.alu(a, .Or, .C, .LD)
		native.alu_imm(a, .Shl, .LD, 6)
		native.alu(a, .Or, .C, .LD)
		native.imp_store(a, IMPORTS[u][.Status], .C)
	}
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
	native.imp_store(a, IMPORTS[u][.Q], .A)
	return true
}

// r = vi[n & 15] of unit u in its low 16 bits, the rest garbage, or
// sign-extended with signed.
vi_get :: proc(a: ^native.Asm, u: Unit, r: native.Reg, n: u32, signed := false) {
	native.imp_load(a, r, IMPORTS[u][.Vf], VU_VI + 4 * ((n & 15) >> 1))
	if signed {
		if n & 1 == 0 {native.alu_imm(a, .Shl, r, 16)}
		native.alu_imm(a, .Sar, r, 16)
	} else if n & 1 != 0 {
		native.alu_imm(a, .Shr, r, 16)
	}
}

// vi[n & 15] of unit u = the low 16 bits of A, by a read and write of the
// word that holds it. Loses A and C.
vi_put :: proc(a: ^native.Asm, u: Unit, n: u32) {
	off := VU_VI + 4 * ((n & 15) >> 1)
	native.imp_load(a, .C, IMPORTS[u][.Vf], off)
	native.alu_imm(a, .And, .C, n & 1 != 0 ? 0xffff : 0xffff0000)
	native.alu_imm(a, .And, .A, 0xffff)
	if n & 1 != 0 {native.alu_imm(a, .Shl, .A, 16)}
	native.alu(a, .Or, .C, .A)
	native.imp_store(a, IMPORTS[u][.Vf], .C, off)
}

// Code for op w with fn 0x30-0x3b as vu.vu_op runs it, or false to leave
// it there: IADD, ISUB, IADDI, IAND, IOR and on VU0 VCALLMS and VCALLMSR.
// As there, an integer op is skipped on a 5-bit destination field of 0 and
// indexes with its low 4 bits, so a field of 16 writes vi[0]. Uses A, B
// and C.
@(private = "file")
int_op :: proc(a: ^native.Asm, u: Unit, w: u32) -> bool {
	ft, fs, fd := (w >> 16) & 31, (w >> 11) & 31, (w >> 6) & 31
	op: native.Alu
	switch w & 63 {
	case 0x30, 0x32: op = .Add
	case 0x31: op = .Sub
	case 0x34: op = .And
	case 0x35: op = .Or
	case 0x38:
		if u != .VU0 {return false}
		native.mov_imm(a, .A, ((w >> 6) & 0x7fff) * 8)
		native.call(a, IMPORTS[u][.Call_Micro], .A)
		return true
	case 0x39:
		if u != .VU0 {return false}
		native.imp_load(a, .A, IMPORTS[u][.Cmsar])
		native.alu_imm(a, .Shl, .A, 3)
		native.call(a, IMPORTS[u][.Call_Micro], .A)
		return true
	case: return false
	}
	if w & 63 == 0x32 {
		// IADDI: vi[ft] = vi[fs] + imm5, the fd field sign-extended
		if ft == 0 {return true}
		vi_get(a, u, .A, fs)
		native.alu_imm(a, .Add, .A, u32(i32(fd << 27) >> 27))
		vi_put(a, u, ft)
		return true
	}
	if fd == 0 {return true}
	vi_get(a, u, .A, fs)
	vi_get(a, u, .B, ft)
	native.alu(a, op, .A, .B)
	vi_put(a, u, fd)
	return true
}

// V0 = its dest lanes, V1's in the others. Loses V2.
@(private = "file")
merge_dest :: proc(a: ^native.Asm, dest: u32) {
	native.vec_load(a, .V2, VU_DEST + 16 * dest, K)
	native.vec_op(a, .And, .V0, .V2)
	native.vec_op(a, .Andn, .V2, .V1)
	native.vec_op(a, .Or, .V0, .V2)
}

// The quadword of data memory at byte A to the dest lanes of vf[r] (a
// load, not vf0), or the dest lanes of vf[r] to it (a store). Reads A and
// uses V0-V2.
@(private = "file")
quad :: proc(a: ^native.Asm, u: Unit, store: bool, dest, r: u32) {
	vf, mem := IMPORTS[u][.Vf], IMPORTS[u][.Mem]
	if store && dest != 0 {
		native.vec_load(a, .V0, 16 * r, vf)
		if dest != 15 {
			native.vec_ldst_at(a, .V1, mem, false)
			merge_dest(a, dest)
		}
		native.vec_ldst_at(a, .V0, mem, true)
	} else if !store && r != 0 && dest != 0 {
		native.vec_ldst_at(a, .V0, mem, false)
		if dest != 15 {
			native.vec_load(a, .V1, 16 * r, vf)
			merge_dest(a, dest)
		}
		native.vec_store(a, 16 * r, .V0, vf)
	}
}

// LQI (key 0x34), SQI (0x35), LQD (0x36) and SQD (0x37) of op w, as
// vu.vu_op runs them: the quadword at (vi[r] & MEM_QUADS) * 16 of data
// memory, for r = fs & 15 (a load) or ft & 15 (a store). The D forms
// decrement vi[r] first, even vi[0]; the I forms increment it after, not
// vi[0]. A load writes the dest lanes of vf[ft], not vf0; a store the dest
// lanes of the quadword from vf[fs]. vi[0] is 0 after. Uses A, B, C and
// V0-V2.
@(private = "file")
lq_sq :: proc(a: ^native.Asm, u: Unit, w, key: u32) {
	dest, ft, fs := (w >> 21) & 15, (w >> 16) & 31, (w >> 11) & 31
	store := key & 1 != 0
	r := (ft if store else fs) & 15
	vi_get(a, u, .A, r)
	if key >= 0x36 {
		native.alu_imm(a, .Sub, .A, 1)
		if r != 0 {
			native.mov(a, .B, .A)
			vi_put(a, u, r)
			native.mov(a, .A, .B)
		}
	} else if r != 0 {
		native.mov(a, .B, .A)
	}
	native.alu_imm(a, .And, .A, MEM_QUADS[u])
	native.alu_imm(a, .Shl, .A, 4)
	quad(a, u, store, dest, fs if store else ft)
	if key < 0x36 && r != 0 {
		native.mov(a, .A, .B)
		native.alu_imm(a, .Add, .A, 1)
		vi_put(a, u, r)
	}
	native.imp_load(a, .C, IMPORTS[u][.Vf], VU_VI)
	native.alu_imm(a, .And, .C, 0xffff0000)
	native.imp_store(a, IMPORTS[u][.Vf], .C, VU_VI)
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

// Code for VU0 macro op w as vu.vu_op runs it, or false to leave it there.
// MAC and status are always computed: CFC2 can read them at any time.
native_macro :: proc(a: ^native.Asm, w: u32) -> bool {
	return op(a, .VU0, w, .Mac_Status)
}

// Code for op w of unit u as vu.vu_op runs it, or false to leave it there:
// moves, waits, the float upper ops of the VF registers and ACC with their
// broadcast, Q and I forms, and ITOF, FTOI and ABS. Results clamp and set
// the flags asked for as vu_put_flags does, and the add and multiply
// operands clamp first as vu_op's do. MAX and MINI order the raw words by
// sign and magnitude and write the winner as it is, as ps2/vu vmax and
// vmin. ITOF, FTOI, ABS, MAX and MINI set no flags. MFIR, the quadword
// loads and stores of lq_sq, DIV, SQRT and RSQRT (status only with
// Mac_Status) and, through int_op, the integer ops and VCALLMS too. w is a
// macro op, or a micro upper word or a lower word of opcode 0x40, whose
// fields are the same. Uses A, B, C, LD and V0-V4, and keeps T.
@(private = "file")
op :: proc(a: ^native.Asm, u: Unit, w: u32, flags: Flags) -> bool {
	Kind :: enum u8 {Add, Sub, Mul, Madd, Msub, Max, Mini, Opmul, Opmsub, Move, Mr32, Nop, Itof, Ftoi, Abs}
	Src :: enum u8 {Vec, Bc, Q, I}
	dest, ft, fs, fd, bc := (w >> 21) & 15, (w >> 16) & 31, (w >> 11) & 31, (w >> 6) & 31, w & 3
	fn := w & 63
	upper := fn < 0x3c
	key := upper ? fn : ((w >> 4) & 0x7c) | bc
	if upper && fn >= 0x30 {return int_op(a, u, w)}
	vf, acc := IMPORTS[u][.Vf], IMPORTS[u][.Acc]
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
	case 0x1f: if !upper {return clip(a, u, w)}; kind, src = .Mini, .I
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
	case 0x2f: kind = upper ? Kind.Mini : Kind.Nop // NOP
	case 0x30: kind = .Move
	case 0x31: kind = .Mr32
	case 0x34 ..= 0x37:
		lq_sq(a, u, w, key)
		return true
	case 0x38 ..= 0x3a: return div(a, u, w, key, flags == .Mac_Status)
	case 0x3b: kind = .Nop // WAITQ
	case 0x3d:
		// MFIR: vf[ft] = vi[fs & 15] sign-extended, in the dest lanes
		if ft == 0 {return true}
		vi_get(a, u, .A, fs, signed = true)
		for k in u32(0) ..< 4 {
			if dest & (8 >> k) != 0 {native.imp_store(a, vf, .A, 16 * ft + 4 * k)}
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
		native.vec_load(a, t1, VU_EXP, K)
		native.vec_op(a, .And, t1, x)
		native.vec_load(a, t2, VU_EXP, K)
		native.vec_op(a, .Eq32, t2, t1) // exponent all ones
		native.vec_load(a, t3, VU_ZERO, K)
		native.vec_op(a, .Eq32, t3, t1) // exponent zero
		native.vec_op(a, .Or, t3, t2)
		native.vec_load(a, t1, VU_MAX, K)
		native.vec_op(a, .And, t1, t2)
		native.vec_load(a, t2, VU_SIGN, K)
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
		native.vec_load(a, .V1, 16 * fs, vf)
		native.vec_op(a, .Itof, .V0, .V1)
		if bc != 0 {
			native.vec_load(a, .V1, VU_ITOF + 16 * (bc - 1), K)
			native.vec_op(a, .Fmul, .V0, .V1)
		}
		put(a, 16 * ft, vf, dest)
		return true
	case .Ftoi:
		// cvt_w of the raw lanes times the scale: |x| >= 2^31, infinite or
		// NaN saturates by sign.
		if ft == 0 || dest == 0 {return true}
		native.vec_load(a, .V0, 16 * fs, vf)
		if bc != 0 {
			native.vec_load(a, .V1, VU_FTOI + 16 * (bc - 1), K)
			native.vec_op(a, .Fmul, .V0, .V1)
		}
		native.vec_op(a, .Ftoi, .V1, .V0)
		native.vec_load(a, .V2, VU_ABS, K)
		native.vec_op(a, .And, .V2, .V0)
		native.vec_load(a, .V3, VU_BIG, K)
		native.vec_op(a, .Gt32, .V2, .V3) // out of range
		native.vec_load(a, .V3, VU_SIGN, K)
		native.vec_op(a, .And, .V3, .V0)
		native.vec_load(a, .V4, VU_ZERO, K)
		native.vec_op(a, .Eq32, .V4, .V3) // sign clear
		native.vec_load(a, .V3, VU_SIGN, K)
		native.vec_op(a, .Xor, .V3, .V4) // 0x7fffffff or 0x80000000
		native.vec_op(a, .And, .V3, .V2)
		native.vec_op(a, .Andn, .V2, .V1)
		native.vec_op(a, .Or, .V2, .V3)
		native.vec_copy(a, .V0, .V2)
		put(a, 16 * ft, vf, dest)
		return true
	case .Abs:
		if ft == 0 {return true}
		native.vec_load(a, .V0, 16 * fs, vf)
		native.vec_load(a, .V1, VU_ABS, K)
		native.vec_op(a, .And, .V0, .V1)
		clamp(a, .V0, .V1, .V2, .V3)
		put(a, 16 * ft, vf, dest)
		return true
	case .Max, .Mini:
		if fd == 0 || dest == 0 {return true}
		native.vec_load(a, .V0, 16 * fs, vf)
		switch src {
		case .Vec:
			native.vec_load(a, .V1, 16 * ft, vf)
		case .Bc:
			native.vec_load(a, .V2, 16 * ft, vf)
			native.vec_shuf32(a, .V1, .V2, u8(bc))
		case .Q:
			native.vec_splat_load(a, .V1, IMPORTS[u][.Q])
		case .I:
			native.vec_splat_load(a, .V1, IMPORTS[u][.I])
		}
		// The order key of each word: x ^ 0x7fffffff where x < 0, so
		// signed lanes compare as sign and magnitude.
		key :: proc(a: ^native.Asm, dst, x: native.Vreg) {
			native.vec_load(a, dst, VU_ZERO, K)
			native.vec_op(a, .Gt32, dst, x)
			native.vec_load(a, .V4, VU_ABS, K)
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
		put(a, 16 * fd, vf, dest)
		return true
	case .Move, .Mr32:
		// Bits as they are, no flags.
		if ft == 0 {return true}
		if kind == .Move {
			native.vec_load(a, .V0, 16 * fs, vf)
		} else {
			native.vec_load(a, .V1, 16 * fs, vf)
			native.vec_shuf32(a, .V0, .V1, {1, 2, 3, 0})
		}
		put(a, 16 * ft, vf, dest)
		return true
	case .Opmul, .Opmsub:
		// fs.yzx * ft.zxy
		dest = 0xe
		native.vec_load(a, .V2, 16 * fs, vf)
		native.vec_shuf32(a, .V0, .V2, {1, 2, 0, 3})
		native.vec_load(a, .V2, 16 * ft, vf)
		native.vec_shuf32(a, .V1, .V2, {2, 0, 1, 3})
		clamp(a, .V0, .V2, .V3, .V4)
		clamp(a, .V1, .V2, .V3, .V4)
		native.vec_op(a, .Fmul, .V0, .V1)
	case .Add, .Sub, .Mul, .Madd, .Msub:
		native.vec_load(a, .V0, 16 * fs, vf)
		switch src {
		case .Vec:
			native.vec_load(a, .V1, 16 * ft, vf)
		case .Bc:
			native.vec_load(a, .V2, 16 * ft, vf)
			native.vec_shuf32(a, .V1, .V2, u8(bc))
		case .Q:
			native.vec_splat_load(a, .V1, IMPORTS[u][.Q])
		case .I:
			native.vec_splat_load(a, .V1, IMPORTS[u][.I])
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
		native.vec_load(a, .V1, 0, acc)
		native.vec_op(a, .Fadd if kind == .Madd else .Fsub, .V1, .V0)
		native.vec_copy(a, .V0, .V1)
	}
	clamp(a, .V0, .V1, .V2, .V3)
	if flags != .None {
		// MAC: zero lanes in bits 0-3, signs in 4-7, of the dest lanes
		native.vec_load(a, .V1, VU_ABS, K)
		native.vec_op(a, .And, .V1, .V0)
		native.vec_load(a, .V2, VU_ZERO, K)
		native.vec_op(a, .Eq32, .V1, .V2)
		native.vec_signs(a, .B, .V1)
		native.alu_imm(a, .And, .B, dest)
		native.vec_copy(a, .V1, .V0)
		native.vec_signs(a, .A, .V1)
		native.alu_imm(a, .And, .A, dest)
	}
	if kind == .Add || kind == .Sub || kind == .Mul || kind == .Madd || kind == .Msub {
		if !upper {
			put(a, 0, acc, dest)
		} else if fd != 0 {
			put(a, 16 * fd, vf, dest)
		}
	} else if kind == .Opmul {
		put(a, 0, acc, dest)
	} else if fd != 0 {
		put(a, 16 * fd, vf, dest)
	}
	if flags == .None {return true}
	native.mov(a, .C, .A)
	native.alu_imm(a, .Shl, .C, 4)
	native.alu(a, .Or, .C, .B)
	native.imp_store(a, IMPORTS[u][.Mac], .C)
	if flags == .Mac {return true}
	// status: Z and S in bits 0-1, sticky in 6-7
	native.set_cond_imm(a, .Ne, .A, 0)
	native.alu_imm(a, .Shl, .A, 1)
	native.set_cond_imm(a, .Ne, .B, 0)
	native.alu(a, .Or, .B, .A)
	native.mov(a, .A, .B)
	native.alu_imm(a, .Shl, .A, 6)
	native.alu(a, .Or, .B, .A)
	native.imp_load(a, .A, IMPORTS[u][.Status])
	native.alu_imm(a, .And, .A, ~u32(0xf))
	native.alu(a, .Or, .A, .B)
	native.imp_store(a, IMPORTS[u][.Status], .A)
	return true
}

// ---------------------------------------------------------------- micro mode

// A = the byte address in data memory of quadword vi[n] + off, as mq wraps
// it.
@(private = "file")
quad_addr :: proc(a: ^native.Asm, u: Unit, n, off: u32) {
	vi_get(a, u, .A, n)
	if off != 0 {native.alu_imm(a, .Add, .A, off)}
	native.alu_imm(a, .And, .A, MEM_QUADS[u])
	native.alu_imm(a, .Shl, .A, 4)
}

// ILW and ILWR (store false) from the quadword at byte A: vi[it] = the
// last dest lane; ISW and ISWR: the dest lanes = vi[it]. Through the
// scratch quadword, as A cannot index a lane. Uses A, B, C and V0.
@(private = "file")
ilw_isw :: proc(a: ^native.Asm, u: Unit, store: bool, dest, it: u32) {
	scratch := IMPORTS[u][.Scratch]
	if dest == 0 || (!store && it == 0) {return}
	native.vec_ldst_at(a, .V0, IMPORTS[u][.Mem], false)
	native.vec_store(a, SCR_QUAD, .V0, scratch)
	if !store {
		k := u32(3)
		for dest & (8 >> k) == 0 {k -= 1}
		native.imp_load(a, .A, scratch, SCR_QUAD + 4 * k)
		vi_put(a, u, it)
		return
	}
	vi_get(a, u, .B, it)
	native.alu_imm(a, .And, .B, 0xffff)
	for k in u32(0) ..< 4 {
		if dest & (8 >> k) != 0 {native.imp_store(a, scratch, .B, SCR_QUAD + 4 * k)}
	}
	native.vec_load(a, .V0, SCR_QUAD, scratch)
	native.vec_ldst_at(a, .V0, IMPORTS[u][.Mem], true)
}

// vi[it] = A c imm as 0 or 1, for the flag tests. Loses A and C.
@(private = "file")
vi_test :: proc(a: ^native.Asm, u: Unit, it: u32, c: native.Cond, imm: u32) {
	native.set_cond_imm(a, c, .A, imm)
	vi_put(a, u, it)
}

// Code for non-branch lower op lw at pc as vu.odin's emit_lower writes it,
// else a call of the interpreter's. status: a DIV-family op sets status
// (VU0 outside an I-bit or slow pair). Uses A, B, C, LD and V0-V4, and
// keeps T.
@(private = "file")
micro_lower :: proc(a: ^native.Asm, u: Unit, lw, pc: u32, status: bool) {
	dest := (lw >> 21) & 15
	ft, fs := (lw >> 16) & 31, (lw >> 11) & 31
	it, is := ft & 15, fs & 15
	imm11 := u32(i32(lw << 21) >> 21)
	imm15 := ((lw >> 10) & 0x7800) | (lw & 0x7ff)
	imm24 := lw & 0xffffff
	key := ((lw >> 4) & 0x7c) | (lw & 3)
	interp :: proc(a: ^native.Asm, u: Unit, lw, pc: u32) {
		native.mov_imm(a, .A, lw)
		native.mov_imm(a, .B, pc)
		native.call(a, IMPORTS[u][.Lower], .A, .B)
	}
	vf, clip, mac := IMPORTS[u][.Vf], IMPORTS[u][.Clip], IMPORTS[u][.Mac]
	switch lw >> 25 {
	case 0x00: // LQ
		if ft == 0 || dest == 0 {return}
		quad_addr(a, u, is, imm11)
		quad(a, u, false, dest, ft)
	case 0x01: // SQ
		if dest == 0 {return}
		quad_addr(a, u, it, imm11)
		quad(a, u, true, dest, fs)
	case 0x04, 0x05: // ILW, ISW
		if dest == 0 || (lw >> 25 == 0x04 && it == 0) {return}
		quad_addr(a, u, is, imm11)
		ilw_isw(a, u, lw >> 25 == 0x05, dest, it)
	case 0x08, 0x09: // IADDIU, ISUBIU
		if it == 0 {return}
		vi_get(a, u, .A, is)
		native.alu_imm(a, native.Alu.Add if lw >> 25 == 0x08 else native.Alu.Sub, .A, imm15)
		vi_put(a, u, it)
	case 0x10: // FCEQ
		native.imp_load(a, .A, clip)
		native.alu_imm(a, .And, .A, 0xffffff)
		vi_test(a, u, 1, .Eq, imm24)
	case 0x11: // FCSET
		native.mov_imm(a, .A, imm24)
		native.imp_store(a, clip, .A)
	case 0x12: // FCAND
		native.imp_load(a, .A, clip)
		native.alu_imm(a, .And, .A, imm24)
		vi_test(a, u, 1, .Ne, 0)
	case 0x13: // FCOR
		native.imp_load(a, .A, clip)
		native.alu_imm(a, .Or, .A, imm24)
		native.alu_imm(a, .And, .A, 0xffffff)
		vi_test(a, u, 1, .Eq, 0xffffff)
	case 0x18: // FMEQ
		if it == 0 {return}
		native.imp_load(a, .A, mac)
		native.alu_imm(a, .And, .A, 0xffff)
		vi_get(a, u, .B, is)
		native.alu_imm(a, .And, .B, 0xffff)
		native.set_cond(a, .Eq, .A, .B)
		vi_put(a, u, it)
	case 0x1a, 0x1b: // FMAND, FMOR
		if it == 0 {return}
		native.imp_load(a, .A, mac)
		vi_get(a, u, .B, is)
		if lw >> 25 == 0x1a {
			native.alu(a, .And, .A, .B)
			vi_put(a, u, it)
		} else {
			native.alu(a, .Or, .A, .B)
			native.alu_imm(a, .And, .A, 0xffff)
			vi_test(a, u, it, .Eq, 0xffff)
		}
	case 0x1c: // FCGET
		if it == 0 {return}
		native.imp_load(a, .A, clip)
		native.alu_imm(a, .And, .A, 0xfff)
		vi_put(a, u, it)
	case 0x40:
		if lw & 63 < 0x3c {
			switch lw & 63 {
			case 0x30, 0x31, 0x32, 0x34, 0x35: if int_op(a, u, lw) {return}
			}
			interp(a, u, lw, pc)
			return
		}
		switch key {
		case 0x30, 0x31, 0x34 ..= 0x37, 0x3b, 0x3d, 0x7b: // MOVE, MR32, LQI-SQD, WAITQ, MFIR, WAITP
			if key != 0x7b && !op(a, u, lw, .None) {interp(a, u, lw, pc)}
		case 0x38 ..= 0x3a: // DIV, SQRT, RSQRT
			div(a, u, lw, key, status)
		case 0x3c: // MTIR
			if it == 0 {return}
			native.imp_load(a, .A, vf, 16 * fs + 4 * ((lw >> 21) & 3))
			vi_put(a, u, it)
		case 0x3e, 0x3f: // ILWR, ISWR
			if dest == 0 || (key == 0x3e && it == 0) {return}
			quad_addr(a, u, is, 0)
			ilw_isw(a, u, key == 0x3f, dest, it)
		case 0x64: // MFP: no flags, clamped
			if ft == 0 || dest == 0 {return}
			native.imp_load(a, .A, IMPORTS[u][.P])
			fclamp_gpr(a, .A, .C)
			for k in u32(0) ..< 4 {
				if dest & (8 >> k) != 0 {native.imp_store(a, vf, .A, 16 * ft + 4 * k)}
			}
		case 0x68, 0x69: // XTOP (VU1 only), XITOP: as emit_lower
			if u == .VU0 && key == 0x68 {
				interp(a, u, lw, pc)
				return
			}
			if it == 0 {return}
			native.imp_load(a, .A, IMPORTS[u][Imp.Top if key == 0x68 else Imp.Itop])
			vi_put(a, u, it)
		case 0x6c: // XGKICK (VU1 only)
			if u == .VU0 {
				interp(a, u, lw, pc)
				return
			}
			vi_get(a, u, .A, is)
			native.alu_imm(a, .And, .A, 0xffff)
			native.call(a, IMPORTS[u][.Xgkick], .A)
		case: interp(a, u, lw, pc) // the EFU and the rest
		}
	case: interp(a, u, lw, pc)
	}
}

// The upper op of pair p, as emit_pair's: inline when op lowers it, else a
// call of the interpreter's. Upper words with fn 0x30-0x3b, or special
// keys from 0x30, are not upper ops: op would take them for integer or
// lower ones.
@(private = "file")
micro_upper :: proc(a: ^native.Asm, u: Unit, p: Pair) {
	flags := Flags.Mac_Status
	if u == .VU1 {flags = Flags.Mac if p.mac_live else Flags.None}
	fn := p.uw & 63
	inline := fn < 0x30 || (fn >= 0x3c && ((p.uw >> 4) & 0x7c) | (p.uw & 3) < 0x30)
	if inline && op(a, u, p.uw, flags) {return}
	native.mov_imm(a, .A, p.uw)
	native.call(a, IMPORTS[u][.Upper], .A)
}

// Pair p at pc, without its branch, as emit_pair orders its halves. Uses
// A, B, C, LD and V0-V4, and keeps T.
@(private = "file")
micro_pair :: proc(a: ^native.Asm, u: Unit, p: Pair, pc: u32) {
	vf, scratch, status := IMPORTS[u][.Vf], IMPORTS[u][.Scratch], IMPORTS[u][.Status]
	if p.ibit { // the upper still reads the old I
		micro_upper(a, u, p)
		native.mov_imm(a, .A, p.lw)
		native.imp_store(a, IMPORTS[u][.I], .A)
		return
	}
	if p.mode == .Slow {
		native.mov_imm(a, .A, p.uw)
		native.mov_imm(a, .B, p.lw)
		native.mov_imm(a, .C, pc)
		native.call(a, IMPORTS[u][.Pair], .A, .B, .C)
		return
	}
	// VU0 computes status. A DIV-family lower sets it too, and as vu_pair
	// its write replaces the upper's when it changes status at all: status
	// before the pair in SCR_ST0, after the upper in SCR_UST.
	key := ((p.lw >> 4) & 0x7c) | (p.lw & 3)
	merge := u == .VU0 && p.lw >> 25 == 0x40 && p.lw & 0x3c == 0x3c && key >= 0x38 && key <= 0x3a
	if merge {
		native.imp_load(a, .A, status)
		native.imp_store(a, scratch, .A, SCR_ST0)
	}
	upper :: proc(a: ^native.Asm, u: Unit, p: Pair, merge: bool) {
		micro_upper(a, u, p)
		if !merge {return}
		status, scratch := IMPORTS[u][.Status], IMPORTS[u][.Scratch]
		native.imp_load(a, .A, status)
		native.imp_store(a, scratch, .A, SCR_UST)
		native.imp_load(a, .A, scratch, SCR_ST0)
		native.imp_store(a, status, .A)
	}
	lower :: proc(a: ^native.Asm, u: Unit, p: Pair, pc: u32, merge: bool) {
		micro_lower(a, u, p.lw, pc, merge)
		if !merge {return}
		status, scratch := IMPORTS[u][.Status], IMPORTS[u][.Scratch]
		same := native.new_label(a)
		native.imp_load(a, .A, status)
		native.imp_load(a, .B, scratch, SCR_ST0)
		native.alu(a, .Xor, .A, .B)
		native.br_zero(a, .A, same, nonzero = true)
		native.imp_load(a, .A, scratch, SCR_UST)
		native.imp_store(a, status, .A)
		native.bind(a, same)
	}
	switch p.mode {
	case .Serial:
		upper(a, u, p, merge)
		if p.branch == .None {lower(a, u, p, pc, merge)}
	case .Lower_First:
		lower(a, u, p, pc, merge)
		upper(a, u, p, merge)
	case .Hazard:
		// As vu_pair: the lower reads the upper's dest from before the
		// upper, and its own write to it, if any, wins unless it leaves the
		// register as it was.
		ud := upper_dest(p.uw)
		native.vec_load(a, .V0, 16 * ud, vf)
		native.vec_store(a, SCR_SAVED, .V0, scratch)
		upper(a, u, p, merge)
		native.vec_load(a, .V0, 16 * ud, vf)
		native.vec_store(a, SCR_RESULT, .V0, scratch)
		native.vec_load(a, .V0, SCR_SAVED, scratch)
		native.vec_store(a, 16 * ud, .V0, vf)
		lower(a, u, p, pc, merge)
		keep := native.new_label(a)
		if (p.lw >> 16) & 31 == ud { // every lower VF write goes to ft
			native.vec_load(a, .V0, 16 * ud, vf)
			native.vec_load(a, .V1, SCR_SAVED, scratch)
			native.vec_op(a, .Eq32, .V0, .V1)
			native.vec_signs(a, .A, .V0)
			native.br_cmp_imm(a, .Ne, .A, 0xf, keep)
		}
		native.vec_load(a, .V0, SCR_RESULT, scratch)
		native.vec_store(a, 16 * ud, .V0, vf)
		native.bind(a, keep)
	case .Slow:
	}
}

// T = whether branch lw is taken, as 0 or 1, or for JR and JALR its
// target; then the link register. As emit_branch.
@(private = "file")
micro_branch :: proc(a: ^native.Asm, u: Unit, lw, pc, mask: u32) {
	it, is := (lw >> 16) & 15, (lw >> 11) & 15
	switch lw >> 25 {
	case 0x28, 0x29: // IBEQ, IBNE
		vi_get(a, u, .A, it)
		native.alu_imm(a, .And, .A, 0xffff)
		vi_get(a, u, .B, is)
		native.alu_imm(a, .And, .B, 0xffff)
		native.set_cond(a, native.Cond.Eq if lw >> 25 == 0x28 else native.Cond.Ne, .A, .B)
		native.mov(a, .T, .A)
	case 0x2c ..= 0x2f: // IBLTZ, IBGTZ, IBLEZ, IBGEZ
		CONDS := [4]native.Cond{.Lt, .Gt, .Le, .Ge}
		vi_get(a, u, .A, is, signed = true)
		native.set_cond_imm(a, CONDS[(lw >> 25) - 0x2c], .A, 0)
		native.mov(a, .T, .A)
	case 0x24, 0x25: // JR, JALR
		vi_get(a, u, .A, is)
		native.alu_imm(a, .Shl, .A, 3)
		native.alu_imm(a, .And, .A, mask)
		native.mov(a, .T, .A)
	}
	if (lw >> 25 == 0x21 || lw >> 25 == 0x25) && it != 0 {
		native.mov_imm(a, .A, ((pc + 16) / 8) & 0xffff)
		vi_put(a, u, it)
	}
}

// The native function for a microprogram of unit u: words from micro
// address 0, compiling the pairs ext marks (nil: all) and entered at
// entries, as emit_program compiles it. Returns its code offset. The run
// ABI is this file's header's.
native_program :: proc(a: ^native.Asm, words: []u32, ext: []bool, entries: []u32, u: Unit) -> int {
	mask := MASK[u]
	pairs, _ := analyze(words, ext, entries, u)
	in_ext :: proc(ext: []bool, i: int) -> bool {return ext == nil || ext[i]}
	run_pc := IMPORTS[u][.Run_Pc]
	// No EE fields are cached here: the code reaches no EE state.
	cached := a.cached
	a.cached = nil
	defer a.cached = cached
	at := native.func_begin(a, "cpu.state")
	labels := make(map[u32]native.Label, context.temp_allocator)
	pcs := make([dynamic]u32, context.temp_allocator)
	for i in 0 ..< len(pairs) {
		if !in_ext(ext, i) {continue}
		labels[u32(i) * 8] = native.new_label(a)
		append(&pcs, u32(i) * 8)
	}
	dispatch, exit := native.new_label(a), native.new_label(a)
	// Leave with pc in run_pc, or with end, End.
	leave :: proc(a: ^native.Asm, exit: native.Label, pc: u32, end := false) {
		native.mov_imm(a, .T, pc | (0x80000000 if end else 0))
		native.jmp(a, exit)
	}
	goto :: proc(a: ^native.Asm, labels: map[u32]native.Label, exit: native.Label, pc: u32) {
		if l, ok := labels[pc]; ok {
			native.jmp(a, l)
		} else {
			leave(a, exit, pc)
		}
	}
	native.imp_load(a, .T, run_pc)
	native.bind(a, dispatch)
	native.search(a, pcs[:], labels, exit) // a miss leaves at T
	plain :: proc(p: Pair) -> bool {return !p.ebit && (p.ibit || p.branch == .None)}
	for p, i in pairs {
		if !in_ext(ext, i) {continue}
		pc := u32(i) * 8
		next := i + 1 < len(pairs) ? pairs[i + 1] : Pair{}
		native.bind(a, labels[pc])
		branch := !p.ibit && p.branch != .None
		switch {
		case branch && (p.ebit || i + 1 >= len(pairs) || !plain(next)),
		     !branch && p.ebit && (i + 1 >= len(pairs) || !plain(next)):
			leave(a, exit, pc)
		case branch:
			op := p.lw >> 25
			micro_pair(a, u, p, pc)
			micro_branch(a, u, p.lw, pc, mask)
			micro_pair(a, u, next, pc + 8)
			not_taken, go := native.new_label(a), native.new_label(a)
			cond := op >= 0x28
			reg := op == 0x24 || op == 0x25
			if cond {native.br_zero(a, .T, not_taken)}
			// The budget counts taken branches; out of it, leave at the
			// target.
			budget := IMPORTS[u][.Run_Budget]
			native.imp_load(a, .A, budget)
			native.alu_imm(a, .Sub, .A, 1)
			native.imp_store(a, budget, .A)
			native.br_cmp_imm(a, .Gt, .A, 0, go)
			if reg {
				native.jmp(a, exit)
			} else {
				leave(a, exit, branch_target(p.lw, pc, mask))
			}
			native.bind(a, go)
			if reg {
				native.jmp(a, dispatch)
			} else {
				goto(a, labels, exit, branch_target(p.lw, pc, mask))
			}
			native.bind(a, not_taken)
			if cond {goto(a, labels, exit, (pc + 16) & mask)}
		case p.ebit:
			micro_pair(a, u, p, pc)
			micro_pair(a, u, next, pc + 8)
			leave(a, exit, (pc + 16) & mask, end = true)
		case:
			micro_pair(a, u, p, pc)
			if i + 1 >= len(pairs) || !in_ext(ext, i + 1) {leave(a, exit, (pc + 8) & mask)}
		}
	}
	native.bind(a, exit)
	native.imp_store(a, run_pc, .T)
	native.ret(a)
	native.func_end(a)
	return at
}

// The native functions of unit u's programs, the ones generate compiles
// to Odin, appended to a's code and to vus. Their ranges point into the
// programs' words, which stay allocated.
native_programs :: proc(a: ^native.Asm, img: mips.Image, capture: string, u: Unit, vus: ^[dynamic]native.Blob_Vu) -> bool {
	if u == .VU0 && capture == "" {return true}
	progs := load_programs(img, capture, u) or_return
	for p in progs {
		rs: []native.Blob_Range
		if p.ext == nil {
			rs = make([]native.Blob_Range, 1)
			rs[0] = {0, p.words[:]}
		} else {
			spans := ranges(p.ext)
			rs = make([]native.Blob_Range, len(spans))
			for s, k in spans {rs[k] = {u32(s[0]) * 8, p.words[s[0] * 2:s[1] * 2]}}
		}
		off := native_program(a, p.words[:], p.ext, p.entries, u)
		append(vus, native.Blob_Vu{u32(u), u32(off), rs})
		free_all(context.temp_allocator)
	}
	return true
}
