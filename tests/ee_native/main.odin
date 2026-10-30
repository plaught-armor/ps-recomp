// EE instructions through the native backend against the interpreter, run
// on every target in CI. Each instruction is a function of its own (the
// instruction, then jr $ra), assembled by r5900.native_func for the host and
// loaded with the runtime's imports; from the same registers, the native
// function and ps2.exec_insn must leave the same cpu.state. A jal is a
// direct call when its target is in the blob, else cpu.call.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import "ps:ps2/mem"
import "ps:ps2/vu"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r5900"

Case :: struct {
	w:  u32,
	op: r5900.Op, // what the word decodes to
}

// rs = 1, rt = 2, rd = 3 throughout.
@(private = "file")
special :: proc(fn: u32) -> u32 {return 1 << 21 | 2 << 16 | 3 << 11 | fn}
@(private = "file")
mmi :: proc(fn: u32, sub: u32 = 0) -> u32 {return 0x1c << 26 | special(fn) | sub << 6}
// A shift of rt = 2 by sa into rd = 3.
@(private = "file")
shift :: proc(fn, sa: u32) -> u32 {return 2 << 16 | 3 << 11 | sa << 6 | fn}
// An immediate op of rs = 1 into rt = 3.
@(private = "file")
imm_op :: proc(op, imm: u32) -> u32 {return op << 26 | 1 << 21 | 3 << 16 | imm}
// A COP2 transfer (QMFC2 1, CFC2 2, QMTC2 5, CTC2 6) of rt = 2 and VU
// register rd.
@(private = "file")
cop2 :: proc(op, rd: u32) -> u32 {return 0x12 << 26 | op << 21 | 2 << 16 | rd << 11}
// A VU0 macro op, vf3 = vf1 fn vf2 in the dest lanes.
@(private = "file")
macro :: proc(fn: u32, dest: u32 = 15, fd: u32 = 3) -> u32 {return 0x12 << 26 | 1 << 25 | dest << 21 | 2 << 16 | 1 << 11 | fd << 6 | fn}
// A VU0 macro op in the special layout, of ft = 2 and fs = 1, key k as
// vu_op switches on it.
@(private = "file")
special2 :: proc(k: u32, dest: u32 = 15, ft: u32 = 2, fs: u32 = 1) -> u32 {
	return 0x12 << 26 | 1 << 25 | dest << 21 | ft << 16 | fs << 11 | (k >> 2) << 6 | 0x3c | (k & 3)
}

// A VU0 macro op of the integer layout, fn 0x30-0x35.
@(private = "file")
vi_op :: proc(fn, fs, ft, fd: u32) -> u32 {return 0x12 << 26 | 1 << 25 | ft << 16 | fs << 11 | fd << 6 | fn}

// A COP1 single op, f[fd] = f[fs] fn f[ft]; fmt 0x14 is a word op.
@(private = "file")
cop1 :: proc(fn: u32, fd: u32 = 3, fs: u32 = 1, ft: u32 = 2, fmt: u32 = 0x10) -> u32 {
	return 0x11 << 26 | fmt << 21 | ft << 16 | fs << 11 | fd << 6 | fn
}

// The COP1 ops native code runs inline; check_fpu checks them.
@(private = "file", rodata)
COP1_OPS := [?]r5900.Op {
	.MOV_S, .NEG_S, .ABS_S, .CVT_S_W, .ADD_S, .SUB_S, .MUL_S, .DIV_S,
	.ADDA_S, .SUBA_S, .MULA_S, .MADD_S, .MSUB_S, .MADDA_S, .MSUBA_S,
	.MAX_S, .MIN_S, .C_EQ_S, .C_LT_S, .C_LE_S, .CVT_W_S, .SQRT_S, .RSQRT_S,
	.MFC1, .C_F_S,
}

// The unaligned loads and stores; check_unaligned checks them.
@(private = "file", rodata)
UNALIGNED_OPS := [?]r5900.Op{.LWL, .LWR, .LDL, .LDR, .SWL, .SWR, .SDL, .SDR}

// The aligned loads and stores, which check_unaligned checks too, at the
// addresses their width allows.
@(private = "file", rodata)
ALIGNED_OPS := [?]r5900.Op{.LB, .LBU, .LH, .LHU, .LW, .LWU, .LD, .LQ, .SB, .SH, .SW, .SD, .SQ, .LWC1, .SWC1}

// The alignment an access needs; LQ and SQ ignore the low four bits.
@(private = "file")
align :: proc(op: r5900.Op) -> u32 {
	#partial switch op {
	case .LH, .LHU, .SH: return 2
	case .LW, .LWU, .SW, .LWC1, .SWC1: return 4
	case .LD, .SD: return 8
	}
	return 1
}

// An access of rt at off(rs = 1); rt = 1 is rs.
@(private = "file")
unaligned :: proc(op, rt: u32, off: i16 = UNALIGNED_OFF) -> u32 {return op << 26 | 1 << 21 | rt << 16 | u32(u16(off))}
// A REGIMM trap of rs = 1 against the immediate, by its rt field.
@(private = "file")
trapi :: proc(rt, imm: u32) -> u32 {return 1 << 26 | 1 << 21 | rt << 16 | imm}

// cpu.trap_hook here: whether a trap was called, and its pc.
@(private = "file")
trapped: bool
@(private = "file")
trapped_pc: u32
@(private = "file")
trap_hook :: proc(pc: u32) {trapped, trapped_pc = true, pc}

// Whether trap word w (rs = 1) traps with x in r1 and y in r2, from the
// encoding, apart from the backends.
@(private = "file")
trap_taken :: proc(w: u32, x, y: u64) -> bool {
	s, imm := x, u64(i64(i16(w)))
	t: u64
	switch (w >> 16) & 31 {
	case 1: t = x
	case 2: t = y
	}
	if w >> 26 == 0 {
		switch w & 63 {
		case 0x30: return i64(s) >= i64(t)
		case 0x31: return s >= t
		case 0x32: return i64(s) < i64(t)
		case 0x33: return s < t
		case 0x34: return s == t
		case 0x36: return s != t
		}
	} else if w >> 26 == 1 {
		switch (w >> 16) & 31 {
		case 8:  return i64(s) >= i64(imm)
		case 9:  return s >= imm
		case 10: return i64(s) < i64(imm)
		case 11: return s < imm
		case 12: return s == imm
		case 14: return s != imm
		}
	}
	return false
}

// The operation numbers native code passes to cpu.fpu_slow.
#assert(int(r5900.Fpu_Op.Add) == int(cpu.Fpu_Op.Add))
#assert(int(r5900.Fpu_Op.Sub) == int(cpu.Fpu_Op.Sub))
#assert(int(r5900.Fpu_Op.Mul) == int(cpu.Fpu_Op.Mul))
#assert(int(r5900.Fpu_Op.Div) == int(cpu.Fpu_Op.Div))
#assert(int(r5900.Fpu_Op.Sqrt) == int(cpu.Fpu_Op.Sqrt))

// Shift counts, signs and carries across the word boundary.
@(rodata)
VALS := [?]u64 {
	0,
	1,
	31,
	32,
	33,
	63,
	0x45,
	0xffffffff_ffffffff,
	0x80000000_00000000,
	0x7fffffff_ffffffff,
	0x12345678_9abcdef0,
	0xffffffff_80000000,
	0x00000000_7fffffff,
	0x80007fff_0001ffff,
	// halfword extremes: PHMADH's 0x8000 * 0x8000 twice wraps to 0x80000000
	0x80008000_80008000,
	0x7fff7fff_80007fff,
	// float words: infinities, a quiet NaN, the largest values, denormals
	0x7f800000_ff800000,
	0x7fc00000_7f7fffff,
	0xff7fffff_00400000,
	0x3f800000_ff7fffff, // as y, with x = 0x7fc00000_7f7fffff: acc.x -max, vf.x max
	0xffc00000_807fffff, // a negative NaN, a negative denormal
	0x007fffff_80000001,
	// FTOI's limits: 2^31 and -2^31, the largest float below 2^31 and 32767
	0x4f000000_cf000000,
	0x4effffff_46fffe00,
}

// f32 bits for the COP1 cases: zeros, denormals, the smallest normals,
// FMAX, infinities and NaN patterns, products and sums that overflow or
// underflow, and 1 + 2^-24 and 1 + 3 * 2^-24, ties that round to even. As
// words for CVT.S.W: 2^24 + 1, 2^24 + 3 and -(2^24 + 1), ties likewise.
@(rodata)
F_VALS := [?]u32 {
	0x00000000,
	0x80000000,
	0x00000001,
	0x807fffff,
	0x00800000,
	0x80800001,
	0x7f7fffff,
	0xff7fffff,
	0x7f800000,
	0xff800000,
	0x7fc00000,
	0x7fffffff,
	0xffffffff,
	0x7f000000,
	// exponents 254 and 255 for the scaled forms: halves at the FMAX
	// boundary, a root of a negative
	0x7f400001,
	0xfe800000,
	0xff000001,
	0x7f800001,
	0x1f800000,
	0x3f800000,
	0xbf800000,
	0x3f800001,
	0x33800000,
	0x40000000,
	0xc0490fdb,
	0x00ffffff,
	0x01000001,
	0x01000003,
	TIE_NEG,
	// for CVT.W.S: 2^31, -2^31, the largest below 2^31 either side, 0.5
	0x4f000000,
	0xcf000000,
	0x4effffff,
	0xceffffff,
	0x3f000000,
}

@(private = "file")
TIE_NEG :: ~u32(0x01000001) + 1

// ACC for the COP1 ops: 1, +0, FMAX and -(1 + 2^-23).
@(private = "file", rodata)
ACC_VALS := [?]u32{0x3f800000, 0, 0x7fffffff, 0xbf800001}

// Quadword addresses for LQC2 and SQC2, rs - MEM_BACK: unaligned RAM, its
// end, both uncached mirrors, the scratchpad, and kseg0, which only the
// runtime's bus reaches.
@(rodata)
MEM_ADDRS := [?]u32{0x00001238, 0x01fffff0, 0x20004564, 0x30008000, 0x70000ff8, 0x70003ff0, 0x80010004}
MEM_BACK :: 12 // the offset field is -12

// Addresses for the unaligned accesses: each of these plus 0 to 7, so
// every alignment, and rs = that less the offset, UNALIGNED_OFF or its
// negative, so the add carries or borrows across a 16-byte boundary for
// some. RAM, the last quadwords of RAM and
// of the scratchpad, both uncached mirrors, and kseg0.
@(rodata)
UNALIGNED_ADDRS := [?]u32{0x0000123c, 0x01ffffe8, 0x2000456c, 0x3000800c, 0x70003fe8, 0x8001000c}
UNALIGNED_OFF :: 5

ENTRY :: 0x00100000

main :: proc() {
	cases := [?]Case {
		{special(0x14), .DSLLV},
		{special(0x16), .DSRLV},
		{special(0x17), .DSRAV},
		{special(0x18), .MULT},
		{special(0x19), .MULTU},
		{special(0x1a) &~ (31 << 11), .DIV},
		{special(0x1b) &~ (31 << 11), .DIVU},
		{mmi(0x18), .MULT1},
		{mmi(0x19), .MULTU1},
		{mmi(0x1a) &~ (31 << 11), .DIV1},
		{mmi(0x1b) &~ (31 << 11), .DIVU1},
		{mmi(0x10), .MFHI1},
		{mmi(0x12), .MFLO1},
		{mmi(0x11), .MTHI1},
		{mmi(0x13), .MTLO1},
		{mmi(0x11) &~ (31 << 21), .MTHI1}, // from r0
		{mmi(0x08, 0x06), .PCGTH},
		{mmi(0x29, 0x13), .PNOR},
		{mmi(0x08, 0x17), .PPACH},
		{mmi(0x08, 0x16), .PEXTLH},
		{mmi(0x08, 0x01), .PSUBW},
		{mmi(0x08, 0x09), .PSUBB},
		{mmi(0x08, 0x12), .PEXTLW},
		{mmi(0x28, 0x12), .PEXTUW},
		{mmi(0x09, 0x12), .PAND},
		{mmi(0x09, 0x13), .PXOR},
		{mmi(0x29, 0x1b), .PCPYH},
		{mmi(0x29, 0x1b) &~ (31 << 16) | 3 << 16, .PCPYH}, // rt = rd
		{mmi(0x08, 0x12) &~ (31 << 21) | 3 << 21, .PEXTLW}, // rs = rd
		{mmi(0x00), .MADD},
		{mmi(0x01), .MADDU},
		{mmi(0x20), .MADD1},
		{mmi(0x21), .MADDU1},
		{mmi(0x00) &~ (31 << 11), .MADD}, // rd = 0
		{mmi(0x29, 0x0e), .PCPYUD},
		{mmi(0x08, 0x14), .PADDSH},
		{mmi(0x08, 0x14) &~ (31 << 16) | 3 << 16, .PADDSH}, // rt = rd
		{mmi(0x08, 0x14) &~ (31 << 11), .PADDSH}, // rd = 0
		{mmi(0x28, 0x10), .PADDUW},
		{mmi(0x28, 0x10) &~ (31 << 21) | 3 << 21, .PADDUW}, // rs = rd
		{mmi(0x28, 0x18), .PADDUB},
		{mmi(0x08, 0x00), .PADDW},
		{mmi(0x3f, 0), .PSRAW},
		{mmi(0x3f, 1), .PSRAW},
		{mmi(0x3f, 31) &~ (31 << 16) | 3 << 16, .PSRAW}, // rt = rd
		{mmi(0x3f, 16) &~ (31 << 11), .PSRAW}, // rd = 0
		{mmi(0x09, 0x11), .PHMADH},
		{mmi(0x09, 0x11) &~ (31 << 16) | 3 << 16, .PHMADH}, // rt = rd
		{mmi(0x09, 0x11) &~ (31 << 21) | 3 << 21, .PHMADH}, // rs = rd
		{mmi(0x09, 0x11) &~ (31 << 11), .PHMADH}, // rd = 0: LO and HI only
		{mmi(0x29, 0x0e) &~ (31 << 21 | 31 << 16) | 3 << 21 | 3 << 16, .PCPYUD}, // rs = rt = rd
		{0x42000039, .DI},
		{0x40816000, .MTC0}, // Status = r1
		{0x40827000, .MTC0}, // EPC = r2
		{0x40803000, .MTC0}, // Wired = r0
		{0x42000018, .ERET},
		{0x4443f800, .CFC1}, // r3 = fcr31
		{0x44430000, .CFC1}, // r3 = FCR0
		{0x4440f800, .CFC1}, // to r0
		{0x44c1f800, .CTC1}, // fcr31 = r1
		{0x44c10000, .CTC1}, // FCR0 stays
		{mmi(0x04) &~ (31 << 16), .PLZCW},
		{mmi(0x08, 0x04), .PADDH},
		{mmi(0x08, 0x05), .PSUBH},
		{mmi(0x08, 0x05) &~ (31 << 16) | 3 << 16, .PSUBH}, // rt = rd
		{mmi(0x08, 0x05) &~ (31 << 11), .PSUBH}, // rd = 0
		{mmi(0x08, 0x08), .PADDB},
		{mmi(0x08, 0x08) &~ (31 << 21) | 3 << 21, .PADDB}, // rs = rd
		{mmi(0x08, 0x08) &~ (31 << 11), .PADDB}, // rd = 0
		{mmi(0x28, 0x06), .PCEQH},
		{mmi(0x28, 0x06) &~ (31 << 21 | 31 << 16) | 3 << 21 | 3 << 16, .PCEQH}, // rs = rt = rd
		{mmi(0x28, 0x06) &~ (31 << 11), .PCEQH}, // rd = 0
		{mmi(0x28, 0x16), .PEXTUH},
		{mmi(0x28, 0x16) &~ (31 << 16) | 3 << 16, .PEXTUH}, // rt = rd
		{mmi(0x28, 0x16) &~ (31 << 21) | 3 << 21, .PEXTUH}, // rs = rd
		{mmi(0x28, 0x16) &~ (31 << 11), .PEXTUH}, // rd = 0
		{0x46020830, .C_F_S},
		{mmi(0x08, 0x18), .PADDSB},
		{mmi(0x08, 0x18) &~ (31 << 16) | 3 << 16, .PADDSB}, // rt = rd
		{mmi(0x08, 0x18) &~ (31 << 21) | 3 << 21, .PADDSB}, // rs = rd
		{mmi(0x08, 0x18) &~ (31 << 11), .PADDSB}, // rd = 0
		{mmi(0x08, 0x19), .PSUBSB},
		{mmi(0x08, 0x19) &~ (31 << 16) | 3 << 16, .PSUBSB}, // rt = rd
		{mmi(0x08, 0x19) &~ (31 << 21) | 3 << 21, .PSUBSB}, // rs = rd
		{mmi(0x08, 0x19) &~ (31 << 11), .PSUBSB}, // rd = 0
		{mmi(0x08, 0x15), .PSUBSH},
		{mmi(0x08, 0x15) &~ (31 << 16) | 3 << 16, .PSUBSH}, // rt = rd
		{mmi(0x08, 0x15) &~ (31 << 21) | 3 << 21, .PSUBSH}, // rs = rd
		{mmi(0x08, 0x15) &~ (31 << 11), .PSUBSH}, // rd = 0
		{mmi(0x08, 0x10), .PADDSW},
		{mmi(0x08, 0x10) &~ (31 << 16) | 3 << 16, .PADDSW}, // rt = rd
		{mmi(0x08, 0x10) &~ (31 << 21) | 3 << 21, .PADDSW}, // rs = rd
		{mmi(0x08, 0x10) &~ (31 << 11), .PADDSW}, // rd = 0
		{mmi(0x08, 0x11), .PSUBSW},
		{mmi(0x08, 0x11) &~ (31 << 16) | 3 << 16, .PSUBSW}, // rt = rd
		{mmi(0x08, 0x11) &~ (31 << 21) | 3 << 21, .PSUBSW}, // rs = rd
		{mmi(0x08, 0x11) &~ (31 << 11), .PSUBSW}, // rd = 0
		{mmi(0x28, 0x14), .PADDUH},
		{mmi(0x28, 0x14) &~ (31 << 16) | 3 << 16, .PADDUH}, // rt = rd
		{mmi(0x28, 0x14) &~ (31 << 21) | 3 << 21, .PADDUH}, // rs = rd
		{mmi(0x28, 0x14) &~ (31 << 11), .PADDUH}, // rd = 0
		{mmi(0x28, 0x15), .PSUBUH},
		{mmi(0x28, 0x15) &~ (31 << 16) | 3 << 16, .PSUBUH}, // rt = rd
		{mmi(0x28, 0x15) &~ (31 << 21) | 3 << 21, .PSUBUH}, // rs = rd
		{mmi(0x28, 0x15) &~ (31 << 11), .PSUBUH}, // rd = 0
		{mmi(0x28, 0x19), .PSUBUB},
		{mmi(0x28, 0x19) &~ (31 << 16) | 3 << 16, .PSUBUB}, // rt = rd
		{mmi(0x28, 0x19) &~ (31 << 21) | 3 << 21, .PSUBUB}, // rs = rd
		{mmi(0x28, 0x19) &~ (31 << 11), .PSUBUB}, // rd = 0
		{mmi(0x28, 0x11), .PSUBUW},
		{mmi(0x28, 0x11) &~ (31 << 16) | 3 << 16, .PSUBUW}, // rt = rd
		{mmi(0x28, 0x11) &~ (31 << 21) | 3 << 21, .PSUBUW}, // rs = rd
		{mmi(0x28, 0x11) &~ (31 << 11), .PSUBUW}, // rd = 0
		{mmi(0x08, 0x0a), .PCGTB},
		{mmi(0x08, 0x0a) &~ (31 << 16) | 3 << 16, .PCGTB}, // rt = rd
		{mmi(0x08, 0x0a) &~ (31 << 21) | 3 << 21, .PCGTB}, // rs = rd
		{mmi(0x08, 0x0a) &~ (31 << 11), .PCGTB}, // rd = 0
		{mmi(0x08, 0x02), .PCGTW},
		{mmi(0x08, 0x02) &~ (31 << 16) | 3 << 16, .PCGTW}, // rt = rd
		{mmi(0x08, 0x02) &~ (31 << 21) | 3 << 21, .PCGTW}, // rs = rd
		{mmi(0x08, 0x02) &~ (31 << 11), .PCGTW}, // rd = 0
		{mmi(0x28, 0x0a), .PCEQB},
		{mmi(0x28, 0x0a) &~ (31 << 16) | 3 << 16, .PCEQB}, // rt = rd
		{mmi(0x28, 0x0a) &~ (31 << 21) | 3 << 21, .PCEQB}, // rs = rd
		{mmi(0x28, 0x0a) &~ (31 << 11), .PCEQB}, // rd = 0
		{mmi(0x28, 0x02), .PCEQW},
		{mmi(0x28, 0x02) &~ (31 << 16) | 3 << 16, .PCEQW}, // rt = rd
		{mmi(0x28, 0x02) &~ (31 << 21) | 3 << 21, .PCEQW}, // rs = rd
		{mmi(0x28, 0x02) &~ (31 << 11), .PCEQW}, // rd = 0
		{mmi(0x08, 0x03), .PMAXW},
		{mmi(0x08, 0x03) &~ (31 << 16) | 3 << 16, .PMAXW}, // rt = rd
		{mmi(0x08, 0x03) &~ (31 << 21) | 3 << 21, .PMAXW}, // rs = rd
		{mmi(0x08, 0x03) &~ (31 << 11), .PMAXW}, // rd = 0
		{mmi(0x28, 0x03), .PMINW},
		{mmi(0x28, 0x03) &~ (31 << 16) | 3 << 16, .PMINW}, // rt = rd
		{mmi(0x28, 0x03) &~ (31 << 21) | 3 << 21, .PMINW}, // rs = rd
		{mmi(0x28, 0x03) &~ (31 << 11), .PMINW}, // rd = 0
		{mmi(0x28, 0x05) &~ (31 << 21), .PABSH},
		{mmi(0x28, 0x05) &~ (31 << 21) &~ (31 << 16) | 3 << 16, .PABSH}, // rt = rd
		{mmi(0x28, 0x05) &~ (31 << 21) &~ (31 << 11), .PABSH}, // rd = 0
		{mmi(0x28, 0x01) &~ (31 << 21), .PABSW},
		{mmi(0x28, 0x01) &~ (31 << 21) &~ (31 << 16) | 3 << 16, .PABSW}, // rt = rd
		{mmi(0x28, 0x01) &~ (31 << 21) &~ (31 << 11), .PABSW}, // rd = 0
		{mmi(0x08, 0x13), .PPACW},
		{mmi(0x08, 0x13) &~ (31 << 16) | 3 << 16, .PPACW}, // rt = rd
		{mmi(0x08, 0x13) &~ (31 << 21) | 3 << 21, .PPACW}, // rs = rd
		{mmi(0x08, 0x13) &~ (31 << 11), .PPACW}, // rd = 0
		{mmi(0x09, 0x0a), .PINTH},
		{mmi(0x09, 0x0a) &~ (31 << 16) | 3 << 16, .PINTH}, // rt = rd
		{mmi(0x09, 0x0a) &~ (31 << 21) | 3 << 21, .PINTH}, // rs = rd
		{mmi(0x09, 0x0a) &~ (31 << 11), .PINTH}, // rd = 0
		{mmi(0x29, 0x0a), .PINTEH},
		{mmi(0x29, 0x0a) &~ (31 << 16) | 3 << 16, .PINTEH}, // rt = rd
		{mmi(0x29, 0x0a) &~ (31 << 21) | 3 << 21, .PINTEH}, // rs = rd
		{mmi(0x29, 0x0a) &~ (31 << 11), .PINTEH}, // rd = 0
		{mmi(0x09, 0x1a) &~ (31 << 21), .PEXEH},
		{mmi(0x09, 0x1a) &~ (31 << 21) &~ (31 << 16) | 3 << 16, .PEXEH}, // rt = rd
		{mmi(0x09, 0x1a) &~ (31 << 21) &~ (31 << 11), .PEXEH}, // rd = 0
		{mmi(0x09, 0x1b) &~ (31 << 21), .PREVH},
		{mmi(0x09, 0x1b) &~ (31 << 21) &~ (31 << 16) | 3 << 16, .PREVH}, // rt = rd
		{mmi(0x09, 0x1b) &~ (31 << 21) &~ (31 << 11), .PREVH}, // rd = 0
		{mmi(0x29, 0x1a) &~ (31 << 21), .PEXCH},
		{mmi(0x29, 0x1a) &~ (31 << 21) &~ (31 << 16) | 3 << 16, .PEXCH}, // rt = rd
		{mmi(0x29, 0x1a) &~ (31 << 21) &~ (31 << 11), .PEXCH}, // rd = 0
		{mmi(0x09, 0x1e) &~ (31 << 21), .PEXEW},
		{mmi(0x09, 0x1e) &~ (31 << 21) &~ (31 << 16) | 3 << 16, .PEXEW}, // rt = rd
		{mmi(0x09, 0x1e) &~ (31 << 21) &~ (31 << 11), .PEXEW}, // rd = 0
		{mmi(0x09, 0x1f) &~ (31 << 21), .PROT3W},
		{mmi(0x09, 0x1f) &~ (31 << 21) &~ (31 << 16) | 3 << 16, .PROT3W}, // rt = rd
		{mmi(0x09, 0x1f) &~ (31 << 21) &~ (31 << 11), .PROT3W}, // rd = 0
		{mmi(0x29, 0x1e) &~ (31 << 21), .PEXCW},
		{mmi(0x29, 0x1e) &~ (31 << 21) &~ (31 << 16) | 3 << 16, .PEXCW}, // rt = rd
		{mmi(0x29, 0x1e) &~ (31 << 21) &~ (31 << 11), .PEXCW}, // rd = 0
		{mmi(0x09, 0x02), .PSLLVW},
		{mmi(0x09, 0x02) &~ (31 << 16) | 3 << 16, .PSLLVW}, // rt = rd
		{mmi(0x09, 0x02) &~ (31 << 21) | 3 << 21, .PSLLVW}, // rs = rd
		{mmi(0x09, 0x02) &~ (31 << 21), .PSLLVW}, // rs = 0
		{mmi(0x09, 0x02) &~ (31 << 16), .PSLLVW}, // rt = 0
		{mmi(0x09, 0x02) &~ (31 << 11), .PSLLVW}, // rd = 0
		{mmi(0x09, 0x03), .PSRLVW},
		{mmi(0x09, 0x03) &~ (31 << 16) | 3 << 16, .PSRLVW}, // rt = rd
		{mmi(0x09, 0x03) &~ (31 << 21) | 3 << 21, .PSRLVW}, // rs = rd
		{mmi(0x09, 0x03) &~ (31 << 21), .PSRLVW}, // rs = 0
		{mmi(0x09, 0x03) &~ (31 << 16), .PSRLVW}, // rt = 0
		{mmi(0x09, 0x03) &~ (31 << 11), .PSRLVW}, // rd = 0
		{mmi(0x29, 0x03), .PSRAVW},
		{mmi(0x29, 0x03) &~ (31 << 16) | 3 << 16, .PSRAVW}, // rt = rd
		{mmi(0x29, 0x03) &~ (31 << 21) | 3 << 21, .PSRAVW}, // rs = rd
		{mmi(0x29, 0x03) &~ (31 << 21), .PSRAVW}, // rs = 0
		{mmi(0x29, 0x03) &~ (31 << 16), .PSRAVW}, // rt = 0
		{mmi(0x29, 0x03) &~ (31 << 11), .PSRAVW}, // rd = 0
		{mmi(0x08, 0x1e) &~ (31 << 21), .PEXT5},
		{mmi(0x08, 0x1e) &~ (31 << 21) &~ (31 << 16) | 3 << 16, .PEXT5}, // rt = rd
		{mmi(0x08, 0x1e) &~ (31 << 21) &~ (31 << 11), .PEXT5}, // rd = 0
		{mmi(0x08, 0x1f) &~ (31 << 21), .PPAC5},
		{mmi(0x08, 0x1f) &~ (31 << 21) &~ (31 << 16) | 3 << 16, .PPAC5}, // rt = rd
		{mmi(0x08, 0x1f) &~ (31 << 21) &~ (31 << 11), .PPAC5}, // rd = 0
		{mmi(0x28, 0x04), .PADSBH},
		{mmi(0x28, 0x04) &~ (31 << 16) | 3 << 16, .PADSBH}, // rt = rd
		{mmi(0x28, 0x04) &~ (31 << 21) | 3 << 21, .PADSBH}, // rs = rd
		{mmi(0x28, 0x04) &~ (31 << 21), .PADSBH}, // rs = 0
		{mmi(0x28, 0x04) &~ (31 << 16), .PADSBH}, // rt = 0
		{mmi(0x28, 0x04) &~ (31 << 11), .PADSBH}, // rd = 0
		{mmi(0x09, 0x0c), .PMULTW},
		{mmi(0x09, 0x0c) &~ (31 << 16) | 3 << 16, .PMULTW}, // rt = rd
		{mmi(0x09, 0x0c) &~ (31 << 21) | 3 << 21, .PMULTW}, // rs = rd
		{mmi(0x09, 0x0c) &~ (31 << 21), .PMULTW}, // rs = 0
		{mmi(0x09, 0x0c) &~ (31 << 16), .PMULTW}, // rt = 0
		{mmi(0x09, 0x0c) &~ (31 << 11), .PMULTW}, // rd = 0: LO and HI only
		{mmi(0x29, 0x0c), .PMULTUW},
		{mmi(0x29, 0x0c) &~ (31 << 16) | 3 << 16, .PMULTUW}, // rt = rd
		{mmi(0x29, 0x0c) &~ (31 << 21) | 3 << 21, .PMULTUW}, // rs = rd
		{mmi(0x29, 0x0c) &~ (31 << 21), .PMULTUW}, // rs = 0
		{mmi(0x29, 0x0c) &~ (31 << 16), .PMULTUW}, // rt = 0
		{mmi(0x29, 0x0c) &~ (31 << 11), .PMULTUW}, // rd = 0: LO and HI only
		{mmi(0x09, 0x00), .PMADDW},
		{mmi(0x09, 0x00) &~ (31 << 16) | 3 << 16, .PMADDW}, // rt = rd
		{mmi(0x09, 0x00) &~ (31 << 21) | 3 << 21, .PMADDW}, // rs = rd
		{mmi(0x09, 0x00) &~ (31 << 21), .PMADDW}, // rs = 0
		{mmi(0x09, 0x00) &~ (31 << 16), .PMADDW}, // rt = 0
		{mmi(0x09, 0x00) &~ (31 << 11), .PMADDW}, // rd = 0: LO and HI only
		{mmi(0x29, 0x00), .PMADDUW},
		{mmi(0x29, 0x00) &~ (31 << 16) | 3 << 16, .PMADDUW}, // rt = rd
		{mmi(0x29, 0x00) &~ (31 << 21) | 3 << 21, .PMADDUW}, // rs = rd
		{mmi(0x29, 0x00) &~ (31 << 21), .PMADDUW}, // rs = 0
		{mmi(0x29, 0x00) &~ (31 << 16), .PMADDUW}, // rt = 0
		{mmi(0x29, 0x00) &~ (31 << 11), .PMADDUW}, // rd = 0: LO and HI only
		{mmi(0x09, 0x04), .PMSUBW},
		{mmi(0x09, 0x04) &~ (31 << 16) | 3 << 16, .PMSUBW}, // rt = rd
		{mmi(0x09, 0x04) &~ (31 << 21) | 3 << 21, .PMSUBW}, // rs = rd
		{mmi(0x09, 0x04) &~ (31 << 21), .PMSUBW}, // rs = 0
		{mmi(0x09, 0x04) &~ (31 << 16), .PMSUBW}, // rt = 0
		{mmi(0x09, 0x04) &~ (31 << 11), .PMSUBW}, // rd = 0: LO and HI only
		{mmi(0x09, 0x1c), .PMULTH},
		{mmi(0x09, 0x1c) &~ (31 << 16) | 3 << 16, .PMULTH}, // rt = rd
		{mmi(0x09, 0x1c) &~ (31 << 21) | 3 << 21, .PMULTH}, // rs = rd
		{mmi(0x09, 0x1c) &~ (31 << 21), .PMULTH}, // rs = 0
		{mmi(0x09, 0x1c) &~ (31 << 16), .PMULTH}, // rt = 0
		{mmi(0x09, 0x1c) &~ (31 << 11), .PMULTH}, // rd = 0: LO and HI only
		{mmi(0x09, 0x10), .PMADDH},
		{mmi(0x09, 0x10) &~ (31 << 16) | 3 << 16, .PMADDH}, // rt = rd
		{mmi(0x09, 0x10) &~ (31 << 21) | 3 << 21, .PMADDH}, // rs = rd
		{mmi(0x09, 0x10) &~ (31 << 21), .PMADDH}, // rs = 0
		{mmi(0x09, 0x10) &~ (31 << 16), .PMADDH}, // rt = 0
		{mmi(0x09, 0x10) &~ (31 << 11), .PMADDH}, // rd = 0: LO and HI only
		{mmi(0x09, 0x14), .PMSUBH},
		{mmi(0x09, 0x14) &~ (31 << 16) | 3 << 16, .PMSUBH}, // rt = rd
		{mmi(0x09, 0x14) &~ (31 << 21) | 3 << 21, .PMSUBH}, // rs = rd
		{mmi(0x09, 0x14) &~ (31 << 21), .PMSUBH}, // rs = 0
		{mmi(0x09, 0x14) &~ (31 << 16), .PMSUBH}, // rt = 0
		{mmi(0x09, 0x14) &~ (31 << 11), .PMSUBH}, // rd = 0: LO and HI only
		{mmi(0x09, 0x15), .PHMSBH},
		{mmi(0x09, 0x15) &~ (31 << 16) | 3 << 16, .PHMSBH}, // rt = rd
		{mmi(0x09, 0x15) &~ (31 << 21) | 3 << 21, .PHMSBH}, // rs = rd
		{mmi(0x09, 0x15) &~ (31 << 21), .PHMSBH}, // rs = 0
		{mmi(0x09, 0x15) &~ (31 << 16), .PHMSBH}, // rt = 0
		{mmi(0x09, 0x15) &~ (31 << 11), .PHMSBH}, // rd = 0: LO and HI only
		{mmi(0x09, 0x0d) &~ (31 << 11), .PDIVW},
		{mmi(0x09, 0x0d) &~ (31 << 11) &~ (31 << 16), .PDIVW}, // by zero
		{mmi(0x09, 0x0d) &~ (31 << 11) &~ (31 << 21), .PDIVW}, // rs = 0
		{mmi(0x09, 0x0d) &~ (31 << 11) &~ (31 << 16) | 1 << 16, .PDIVW}, // rs = rt
		{mmi(0x29, 0x0d) &~ (31 << 11), .PDIVUW},
		{mmi(0x29, 0x0d) &~ (31 << 11) &~ (31 << 16), .PDIVUW}, // by zero
		{mmi(0x29, 0x0d) &~ (31 << 11) &~ (31 << 21), .PDIVUW}, // rs = 0
		{mmi(0x29, 0x0d) &~ (31 << 11) &~ (31 << 16) | 1 << 16, .PDIVUW}, // rs = rt
		{mmi(0x09, 0x1d) &~ (31 << 11), .PDIVBW},
		{mmi(0x09, 0x1d) &~ (31 << 11) &~ (31 << 16), .PDIVBW}, // by zero
		{mmi(0x09, 0x1d) &~ (31 << 11) &~ (31 << 21), .PDIVBW}, // rs = 0
		{mmi(0x09, 0x1d) &~ (31 << 11) &~ (31 << 16) | 1 << 16, .PDIVBW}, // rs = rt
		{mmi(0x09, 0x08) &~ (31 << 21 | 31 << 16), .PMFHI},
		{mmi(0x09, 0x08) &~ (31 << 21 | 31 << 16) &~ (31 << 11), .PMFHI}, // rd = 0
		{mmi(0x09, 0x09) &~ (31 << 21 | 31 << 16), .PMFLO},
		{mmi(0x09, 0x09) &~ (31 << 21 | 31 << 16) &~ (31 << 11), .PMFLO}, // rd = 0
		{mmi(0x29, 0x08) &~ (31 << 16 | 31 << 11), .PMTHI},
		{mmi(0x29, 0x08) &~ (31 << 16 | 31 << 11) &~ (31 << 21), .PMTHI}, // from r0
		{mmi(0x29, 0x09) &~ (31 << 16 | 31 << 11), .PMTLO},
		{mmi(0x29, 0x09) &~ (31 << 16 | 31 << 11) &~ (31 << 21), .PMTLO}, // from r0
		{mmi(0x31, 0x00) &~ (31 << 16 | 31 << 11), .PMTHL},
		{mmi(0x31, 0x00) &~ (31 << 16 | 31 << 11) &~ (31 << 21), .PMTHL}, // from r0
		{mmi(0x30, 0) &~ (31 << 21 | 31 << 16), .PMFHL},
		{mmi(0x30, 1) &~ (31 << 21 | 31 << 16), .PMFHL},
		{mmi(0x30, 2) &~ (31 << 21 | 31 << 16), .PMFHL},
		{mmi(0x30, 3) &~ (31 << 21 | 31 << 16), .PMFHL},
		{mmi(0x30, 4) &~ (31 << 21 | 31 << 16), .PMFHL},
		{mmi(0x30, 5) &~ (31 << 21 | 31 << 16), .PMFHL}, // no such variant: zero
		{mmi(0x30, 2) &~ (31 << 21 | 31 << 16 | 31 << 11), .PMFHL}, // rd = 0
		{mmi(0x30, 0) &~ (31 << 21 | 31 << 16 | 31 << 11), .PMFHL}, // rd = 0
		{mmi(0x3c, 0) &~ (31 << 21), .PSLLW},
		{mmi(0x3c, 1) &~ (31 << 21), .PSLLW},
		{mmi(0x3c, 31) &~ (31 << 21 | 31 << 16) | 3 << 16, .PSLLW}, // rt = rd
		{mmi(0x3c, 16) &~ (31 << 21 | 31 << 11), .PSLLW}, // rd = 0
		{mmi(0x3e, 0) &~ (31 << 21), .PSRLW},
		{mmi(0x3e, 1) &~ (31 << 21), .PSRLW},
		{mmi(0x3e, 31) &~ (31 << 21 | 31 << 16) | 3 << 16, .PSRLW}, // rt = rd
		{mmi(0x3e, 16) &~ (31 << 21 | 31 << 11), .PSRLW}, // rd = 0
		{mmi(0x08, 0x07), .PMAXH},
		{mmi(0x28, 0x07), .PMINH},
		{mmi(0x08, 0x1a), .PEXTLB},
		{mmi(0x28, 0x1a), .PEXTUB},
		{mmi(0x08, 0x1b), .PPACB},
		{mmi(0x09, 0x0e), .PCPYLD},
		{mmi(0x09, 0x0e) &~ (31 << 21) | 3 << 21, .PCPYLD}, // rs = rd
		{mmi(0x29, 0x12), .POR},
		{mmi(0x34, 0), .PSLLH},
		{mmi(0x34, 15), .PSLLH},
		{mmi(0x36, 1), .PSRLH},
		{mmi(0x36, 9) &~ (31 << 16) | 3 << 16, .PSRLH}, // rt = rd
		{mmi(0x37, 15), .PSRAH},
		{mmi(0x37, 7) &~ (31 << 11), .PSRAH}, // rd = 0
		// SA from the start state: whole bytes take the funnel, the rest
		// the interpreter
		{mmi(0x28, 0x1b), .QFSRV},
		{mmi(0x28, 0x1b) &~ (31 << 16) | 3 << 16, .QFSRV}, // rt = rd
		{mmi(0x28, 0x1b) &~ (31 << 21) | 3 << 21, .QFSRV}, // rs = rd
		{mmi(0x28, 0x1b) &~ (31 << 11), .QFSRV}, // rd = 0
		{0x40036000, .MFC0}, // r3 = Status
		{0x40037000, .MFC0}, // r3 = EPC
		{0x40007000, .MFC0}, // to r0
		{0x4003f000, .MFC0}, // PRId
		// Traps: a taken one calls cpu.trap_hook, set here
		{special(0x30), .TGE},
		{special(0x31), .TGEU},
		{special(0x32), .TLT},
		{special(0x33), .TLTU},
		{special(0x34), .TEQ},
		{special(0x36), .TNE},
		{special(0x34) &~ (31 << 16), .TEQ}, // rt = 0
		{special(0x36) &~ (31 << 16) | 1 << 16, .TNE}, // rs = rt: never
		{trapi(8, 0), .TRAPI}, // TGEI
		{trapi(8, 0x8000), .TRAPI},
		{trapi(9, 0xffff), .TRAPI}, // TGEIU
		{trapi(9, 0x7fff), .TRAPI},
		{trapi(10, 0), .TRAPI}, // TLTI
		{trapi(10, 0x7fff), .TRAPI},
		{trapi(11, 0x8000), .TRAPI}, // TLTIU
		{trapi(11, 1), .TRAPI},
		{trapi(12, 0x45), .TRAPI}, // TEQI
		{trapi(12, 0xffff), .TRAPI},
		{trapi(13, 0), .TRAPI}, // never traps
		{trapi(14, 0), .TRAPI}, // TNEI
		{trapi(14, 0x8000), .TRAPI},
		{0x42000001, .TLBR},
		{0x42000002, .TLBWI},
		{0x42000006, .TLBWR},
		{0x42000008, .TLBP},
		{0x44811800, .MTC1}, // f3 = r1
		{0x44030800, .MFC1}, // r3 = f1, sign-extended
		{cop2(1, 3), .QMFC2},
		{cop2(1, 0), .QMFC2}, // vf0
		{cop2(5, 3), .QMTC2},
		{cop2(5, 0), .QMTC2}, // vf0 stays
		// Every VU0 control register, and the ones that read as 0 (19, 29);
		// a CTC2 to CMSAR1 starts VU1 and is a call either way.
		{cop2(2, 0), .CFC2},
		{cop2(2, 1), .CFC2},
		{cop2(2, 2), .CFC2},
		{cop2(2, 3), .CFC2},
		{cop2(2, 15), .CFC2},
		{cop2(2, 16), .CFC2},
		{cop2(2, 17), .CFC2},
		{cop2(2, 18), .CFC2},
		{cop2(2, 19), .CFC2},
		{cop2(2, 20), .CFC2},
		{cop2(2, 21), .CFC2},
		{cop2(2, 22), .CFC2},
		{cop2(2, 26), .CFC2},
		{cop2(2, 27), .CFC2},
		{cop2(2, 28), .CFC2},
		{cop2(2, 29), .CFC2},
		{cop2(2, 31), .CFC2},
		{cop2(2, 3) &~ (31 << 16), .CFC2}, // to r0
		{cop2(6, 0), .CTC2},
		{cop2(6, 1), .CTC2},
		{cop2(6, 2), .CTC2},
		{cop2(6, 3), .CTC2},
		{cop2(6, 15), .CTC2},
		{cop2(6, 16), .CTC2},
		{cop2(6, 17), .CTC2},
		{cop2(6, 18), .CTC2},
		{cop2(6, 19), .CTC2},
		{cop2(6, 20), .CTC2},
		{cop2(6, 21), .CTC2},
		{cop2(6, 22), .CTC2},
		{cop2(6, 26), .CTC2},
		{cop2(6, 27), .CTC2},
		{cop2(6, 28), .CTC2},
		{cop2(6, 29), .CTC2},
		{macro(0x28), .VU0}, // VADD
		{macro(0x2a, 9), .VU0}, // VMUL.xw
		{macro(0x29), .VU0}, // VMADD
		{macro(0x01), .VU0}, // VADDy
		{macro(0x07, 0xc), .VU0}, // VSUBw.xy
		{macro(0x08, 5), .VU0}, // VMADDx.yw
		{macro(0x0e), .VU0}, // VMSUBz
		{macro(0x19, 2), .VU0}, // VMULy.z
		{macro(0x1c), .VU0}, // VMULq
		{macro(0x1e), .VU0}, // VMULi
		{macro(0x20), .VU0}, // VADDq
		{macro(0x21, 3), .VU0}, // VMADDq.zw
		{macro(0x22), .VU0}, // VADDi
		{macro(0x23), .VU0}, // VMADDi
		{macro(0x24), .VU0}, // VSUBq
		{macro(0x25), .VU0}, // VMSUBq
		{macro(0x26), .VU0}, // VSUBi
		{macro(0x27, 8), .VU0}, // VMSUBi.x
		{macro(0x2c), .VU0}, // VSUB
		{macro(0x2d, 6), .VU0}, // VMSUB.yz
		{macro(0x2e), .VU0}, // VOPMSUB
		{macro(0x28, 15, 0), .VU0}, // VADD to vf0: flags only
		{macro(0x28, 0), .VU0}, // VADD of no lanes
		// MAX and MINI against the interpreter's raw sign and magnitude
		// order: the values put +0 and -0, NaNs and infinities of both
		// signs and denormals against each other across lanes.
		{macro(0x2b), .VU0}, // VMAX
		{macro(0x2b, 0xa, 0), .VU0}, // VMAX.xz to vf0: nothing
		{macro(0x2f, 6), .VU0}, // VMINI.yz
		{macro(0x10), .VU0}, // VMAXx
		{macro(0x13, 9), .VU0}, // VMAXw.xw
		{macro(0x15), .VU0}, // VMINIy
		{macro(0x16, 4), .VU0}, // VMINIz.y
		{macro(0x1d), .VU0}, // VMAXi
		{macro(0x1f, 3), .VU0}, // VMINIi.zw
		{special2(0x02), .VU0}, // VADDAz
		{special2(0x29, 9), .VU0}, // VMADDA.xw
		{special2(0x1c), .VU0}, // VMULAq
		{special2(0x27), .VU0}, // VMSUBAi
		{special2(0x2a), .VU0}, // VMULA
		{special2(0x2e), .VU0}, // VOPMULA
		{special2(0x2f), .VU0}, // VNOP
		{special2(0x30, 0xa), .VU0}, // VMOVE.xz
		{special2(0x30, 15, 0), .VU0}, // VMOVE to vf0
		{special2(0x31), .VU0}, // VMR32
		{special2(0x31, 5, 1), .VU0}, // VMR32.yw in place
		{special2(0x10), .VU0}, // VITOF0
		{special2(0x11, 0xc), .VU0}, // VITOF4.xy
		{special2(0x12), .VU0}, // VITOF12
		{special2(0x13, 3, 1), .VU0}, // VITOF15.zw in place
		{special2(0x10, 15, 0), .VU0}, // VITOF0 to vf0
		{special2(0x14), .VU0}, // VFTOI0
		{special2(0x15, 5), .VU0}, // VFTOI4.yw
		{special2(0x16), .VU0}, // VFTOI12
		{special2(0x17, 15, 1), .VU0}, // VFTOI15 in place
		{special2(0x14, 15, 0), .VU0}, // VFTOI0 to vf0
		{special2(0x1d), .VU0}, // VABS
		{special2(0x1d, 0xa, 1), .VU0}, // VABS.xz in place
		{0x00001828, .MFSA}, // r3 = SA
		{0x00200029, .MTSA}, // r1 & 127
		{0x04380005, .MTSAB}, // r1 ^ 5
		{0x0439fffb, .MTSAH}, // r1 ^ 0xfffb
		{cop1(0x00), .ADD_S},
		{cop1(0x00, fd = 1), .ADD_S}, // fd = fs
		{cop1(0x01), .SUB_S},
		{cop1(0x02), .MUL_S},
		{cop1(0x02, fd = 2, fs = 2), .MUL_S}, // all one register
		{cop1(0x06), .MOV_S},
		{cop1(0x34) &~ (31 << 6), .C_LT_S},
		{cop1(0x34, fd = 0, ft = 1), .C_LT_S}, // fs = ft
		{cop1(0x07), .NEG_S},
		{cop1(0x07, fd = 1), .NEG_S}, // fd = fs
		{cop1(0x05), .ABS_S},
		{cop1(0x20, fmt = 0x14), .CVT_S_W},
		{cop1(0x03), .DIV_S},
		{cop1(0x03, fd = 2), .DIV_S}, // fd = ft
		{cop1(0x18), .ADDA_S},
		{cop1(0x19), .SUBA_S},
		{cop1(0x1a), .MULA_S},
		{cop1(0x1c), .MADD_S},
		{cop1(0x1c, fd = 2, fs = 2), .MADD_S}, // all one register
		{cop1(0x1d), .MSUB_S},
		{cop1(0x1e), .MADDA_S},
		{cop1(0x1f), .MSUBA_S},
		{cop1(0x28), .MAX_S},
		{cop1(0x28, fd = 1), .MAX_S}, // fd = fs
		{cop1(0x29), .MIN_S},
		{cop1(0x29, fd = 2), .MIN_S}, // fd = ft
		{cop1(0x32) &~ (31 << 6), .C_EQ_S},
		{cop1(0x36) &~ (31 << 6), .C_LE_S},
		{cop1(0x36, fd = 0, ft = 1), .C_LE_S}, // fs = ft
		{cop1(0x24), .CVT_W_S},
		{cop1(0x24, fd = 1), .CVT_W_S}, // fd = fs
		{cop1(0x04), .SQRT_S},
		{cop1(0x04, fd = 2), .SQRT_S}, // fd = ft
		{cop1(0x16), .RSQRT_S},
		{cop1(0x16, fd = 1), .RSQRT_S}, // fd = fs
		{cop1(0x16, fd = 2), .RSQRT_S}, // fd = ft
		{cop1(0x16, fs = 2), .RSQRT_S}, // fs = ft
		// The base ISA's register ops.
		{shift(0x00, 0), .SLL},
		{shift(0x00, 1), .SLL},
		{shift(0x00, 31), .SLL},
		{shift(0x00, 7) &~ (31 << 11), .SLL}, // rd = 0
		{shift(0x02, 0), .SRL},
		{shift(0x02, 1), .SRL},
		{shift(0x02, 31), .SRL},
		{shift(0x03, 0), .SRA},
		{shift(0x03, 1), .SRA},
		{shift(0x03, 31), .SRA},
		{shift(0x38, 0), .DSLL},
		{shift(0x38, 1), .DSLL},
		{shift(0x38, 31), .DSLL},
		{shift(0x3a, 0), .DSRL},
		{shift(0x3a, 31), .DSRL},
		{shift(0x3b, 0), .DSRA},
		{shift(0x3b, 31), .DSRA},
		{shift(0x3c, 0), .DSLL32},
		{shift(0x3c, 31), .DSLL32},
		{shift(0x3e, 0), .DSRL32},
		{shift(0x3e, 31), .DSRL32},
		{shift(0x3f, 0), .DSRA32},
		{shift(0x3f, 31), .DSRA32},
		{shift(0x3f, 5) &~ (31 << 16) | 3 << 16, .DSRA32}, // rt = rd
		{special(0x04), .SLLV},
		{special(0x06), .SRLV},
		{special(0x07), .SRAV},
		{special(0x04) &~ (31 << 16) | 3 << 16, .SLLV}, // rt = rd
		{special(0x07) &~ (31 << 21) | 3 << 21, .SRAV}, // rs = rd
		{special(0x0a), .MOVZ},
		{special(0x0b), .MOVN},
		{special(0x0a) &~ (31 << 16), .MOVZ}, // rt = 0: always
		{special(0x0b) &~ (31 << 16), .MOVN}, // rt = 0: never
		{special(0x0a) &~ (31 << 11), .MOVZ}, // rd = 0
		{special(0x0b) &~ (31 << 16) | 3 << 16, .MOVN}, // rt = rd
		{0x0000000f, .SYNC},
		{3 << 11 | 0x10, .MFHI},
		{3 << 11 | 0x12, .MFLO},
		{0x10, .MFHI}, // to r0
		{1 << 21 | 0x11, .MTHI},
		{1 << 21 | 0x13, .MTLO},
		{0x13, .MTLO}, // from r0
		{special(0x20), .ADD},
		{special(0x21), .ADDU},
		{special(0x22), .SUB},
		{special(0x23), .SUBU},
		{special(0x2c), .DADD},
		{special(0x2d), .DADDU},
		{special(0x2e), .DSUB},
		{special(0x2f), .DSUBU},
		{special(0x24), .AND},
		{special(0x25), .OR},
		{special(0x26), .XOR},
		{special(0x27), .NOR},
		{special(0x2a), .SLT},
		{special(0x2b), .SLTU},
		{special(0x21) &~ (31 << 21), .ADDU}, // rs = 0
		{special(0x21) &~ (31 << 16), .ADDU}, // rt = 0
		{special(0x21) &~ (31 << 11), .ADDU}, // rd = 0
		{special(0x2d) &~ (31 << 21), .DADDU},
		{special(0x2d) &~ (31 << 16), .DADDU},
		{special(0x25) &~ (31 << 21), .OR},
		{special(0x25) &~ (31 << 16), .OR},
		{special(0x23) &~ (31 << 16) | 1 << 16, .SUBU}, // rs = rt
		{special(0x2a) &~ (31 << 16) | 1 << 16, .SLT},
		{special(0x2b) &~ (31 << 21), .SLTU}, // 0 < rt
		{imm_op(0x08, 0x7fff), .ADDI},
		{imm_op(0x09, 0x8000), .ADDIU},
		{imm_op(0x09, 0xffff), .ADDIU},
		{imm_op(0x09, 0x1234) &~ (31 << 21), .ADDIU}, // li
		{imm_op(0x09, 1) &~ (31 << 16), .ADDIU}, // rt = 0
		{imm_op(0x09, 0x7fff) &~ (31 << 16) | 1 << 16, .ADDIU}, // rt = rs
		{imm_op(0x18, 0x8000), .DADDI},
		{imm_op(0x19, 0x7fff), .DADDIU},
		{imm_op(0x19, 0xffff), .DADDIU},
		{imm_op(0x0a, 0x8000), .SLTI},
		{imm_op(0x0a, 1), .SLTI},
		{imm_op(0x0b, 0xffff), .SLTIU},
		{imm_op(0x0b, 0x45), .SLTIU},
		{imm_op(0x0c, 0xffff), .ANDI},
		{imm_op(0x0c, 0x8001), .ANDI},
		{imm_op(0x0d, 0x8001), .ORI},
		{imm_op(0x0d, 0xbeef) &~ (31 << 21), .ORI}, // rs = 0
		{imm_op(0x0e, 0xffff), .XORI},
		{imm_op(0x0e, 0) &~ (31 << 16) | 1 << 16, .XORI}, // rt = rs
		{imm_op(0x0f, 0x8000) &~ (31 << 21), .LUI},
		{imm_op(0x0f, 0x7fff) &~ (31 << 21), .LUI},
		{imm_op(0x0f, 0xffff) &~ (31 << 21 | 31 << 16), .LUI}, // to r0
		{47 << 26 | 1 << 21 | 0x07 << 16 | 0x40, .CACHE}, // DXWBIN
		{51 << 26 | 1 << 21 | 0x40, .PREF},
		{unaligned(34, 2), .LWL},
		{unaligned(34, 1), .LWL}, // rt = rs
		{unaligned(34, 0), .LWL},
		{unaligned(34, 2, -UNALIGNED_OFF), .LWL},
		{unaligned(38, 2), .LWR},
		{unaligned(38, 1), .LWR},
		{unaligned(38, 0), .LWR},
		{unaligned(38, 2, -UNALIGNED_OFF), .LWR},
		{unaligned(26, 2), .LDL},
		{unaligned(26, 1), .LDL},
		{unaligned(26, 0), .LDL},
		{unaligned(26, 2, -UNALIGNED_OFF), .LDL},
		{unaligned(27, 2), .LDR},
		{unaligned(27, 1), .LDR},
		{unaligned(27, 0), .LDR},
		{unaligned(27, 2, -UNALIGNED_OFF), .LDR},
		{unaligned(42, 2), .SWL},
		{unaligned(42, 1), .SWL},
		{unaligned(42, 0), .SWL},
		{unaligned(42, 2, -UNALIGNED_OFF), .SWL},
		{unaligned(46, 2), .SWR},
		{unaligned(46, 1), .SWR},
		{unaligned(46, 0), .SWR},
		{unaligned(46, 2, -UNALIGNED_OFF), .SWR},
		{unaligned(44, 2), .SDL},
		{unaligned(44, 1), .SDL},
		{unaligned(44, 0), .SDL},
		{unaligned(44, 2, -UNALIGNED_OFF), .SDL},
		{unaligned(45, 2), .SDR},
		{unaligned(45, 1), .SDR},
		{unaligned(45, 0), .SDR},
		{unaligned(45, 2, -UNALIGNED_OFF), .SDR},
		// the aligned ones
		{unaligned(32, 2), .LB},
		{unaligned(32, 1), .LB},
		{unaligned(32, 0), .LB},
		{unaligned(36, 2), .LBU},
		{unaligned(36, 1), .LBU},
		{unaligned(36, 0), .LBU},
		{unaligned(33, 2), .LH},
		{unaligned(33, 1), .LH},
		{unaligned(33, 0), .LH},
		{unaligned(37, 2), .LHU},
		{unaligned(37, 1), .LHU},
		{unaligned(37, 0), .LHU},
		{unaligned(35, 2), .LW},
		{unaligned(35, 1), .LW},
		{unaligned(35, 0), .LW},
		{unaligned(39, 2), .LWU},
		{unaligned(39, 1), .LWU},
		{unaligned(39, 0), .LWU},
		{unaligned(55, 2), .LD},
		{unaligned(55, 1), .LD},
		{unaligned(55, 0), .LD},
		{unaligned(30, 2), .LQ},
		{unaligned(30, 1), .LQ},
		{unaligned(30, 0), .LQ},
		{unaligned(40, 2), .SB},
		{unaligned(40, 1), .SB},
		{unaligned(40, 0), .SB},
		{unaligned(41, 2), .SH},
		{unaligned(41, 1), .SH},
		{unaligned(41, 0), .SH},
		{unaligned(43, 2), .SW},
		{unaligned(43, 1), .SW},
		{unaligned(43, 0), .SW},
		{unaligned(63, 2), .SD},
		{unaligned(63, 1), .SD},
		{unaligned(63, 0), .SD},
		{unaligned(31, 2), .SQ},
		{unaligned(31, 1), .SQ},
		{unaligned(31, 0), .SQ},
		{unaligned(49, 2), .LWC1}, // f2
		{unaligned(57, 2), .SWC1},
		{unaligned(57, 0), .SWC1}, // f0
		{special2(0x3b), .VU0}, // VWAITQ
		{special2(0x1f), .VU0}, // VCLIP
		{special2(0x1f, ft = 1), .VU0}, // VCLIP vf1, vf1w
		{special2(0x1f, ft = 0), .VU0}, // VCLIP vf1, vf0w = 1
		{special2(0x38, 0), .VU0}, // VDIV vf1x / vf2x
		{special2(0x38, 0xb), .VU0}, // VDIV vf1w / vf2z
		{special2(0x38, 0x6, 1), .VU0}, // VDIV vf1z / vf1y
		{special2(0x38, 0x5, 1), .VU0}, // VDIV vf1y / vf1y
		{special2(0x39, 0), .VU0}, // VSQRT vf2x
		{special2(0x39, 0xc), .VU0}, // VSQRT vf2w
		{special2(0x39, 0x8, 1), .VU0}, // VSQRT vf1z
		{special2(0x3a, 0), .VU0}, // VRSQRT vf1x / sqrt(vf2x)
		{special2(0x3a, 0xe), .VU0}, // VRSQRT vf1z / sqrt(vf2w)
		{special2(0x3a, 0x9, 1), .VU0}, // VRSQRT vf1y / sqrt(vf1z)
		{special2(0x3a, 0xf, 1), .VU0}, // VRSQRT vf1w / sqrt(vf1w)
		{vi_op(0x30, 1, 2, 3), .VU0}, // VIADD
		{vi_op(0x30, 1, 2, 0), .VU0}, // VIADD to vi0, skipped
		{vi_op(0x30, 1, 2, 16), .VU0}, // VIADD with fd 16, which writes vi0
		{vi_op(0x30, 17, 18, 4), .VU0}, // VIADD of fs 17 and ft 18, vi1 and vi2
		{vi_op(0x30, 3, 4, 3), .VU0}, // VIADD in place, odd
		{vi_op(0x30, 4, 5, 4), .VU0}, // VIADD in place, even
		{vi_op(0x30, 2, 2, 2), .VU0}, // VIADD all one register
		{vi_op(0x31, 1, 2, 3), .VU0}, // VISUB
		{vi_op(0x31, 2, 1, 6), .VU0}, // VISUB
		{vi_op(0x34, 5, 6, 7), .VU0}, // VIAND
		{vi_op(0x35, 5, 6, 8), .VU0}, // VIOR
		{vi_op(0x35, 5, 6, 16), .VU0}, // VIOR with fd 16
		{vi_op(0x32, 1, 3, 0x0f), .VU0}, // VIADDI 15
		{vi_op(0x32, 1, 3, 0x10), .VU0}, // VIADDI -16
		{vi_op(0x32, 19, 4, 0x1f), .VU0}, // VIADDI -1 of fs 19
		{vi_op(0x32, 1, 0, 5), .VU0}, // VIADDI to vi0, skipped
		{vi_op(0x32, 1, 16, 1), .VU0}, // VIADDI with ft 16, which writes vi0
		{special2(0x3d), .VU0}, // VMFIR vf2 = vi1
		{special2(0x3d, 5, 2, 2), .VU0}, // VMFIR.yw vf2 = vi2
		{special2(0x3d, 0, 2, 3), .VU0}, // VMFIR of no lanes
		{special2(0x3d, 15, 0, 3), .VU0}, // VMFIR to vf0, skipped
		{special2(0x3d, 0xa, 18, 16), .VU0}, // VMFIR.xz vf18 = vi0, fs 16
		{special2(0x3d, 15, 3, 19), .VU0}, // VMFIR vf3 = vi3, fs 19
		{special2(0x34), .VU0}, // VLQI vf2 = [vi1++], vi1 0xffff wraps
		{special2(0x34, 0xa, 3, 2), .VU0}, // VLQI.xz, an even vi
		{special2(0x34, 0, 3, 4), .VU0}, // VLQI of no lanes, still increments
		{special2(0x34, 15, 0, 3), .VU0}, // VLQI to vf0, still increments
		{special2(0x34, 15, 2, 0), .VU0}, // VLQI of [vi0], no increment
		{special2(0x34, 15, 2, 16), .VU0}, // VLQI with fs 16, vi0
		{special2(0x34, 5, 18, 19), .VU0}, // VLQI.yw vf18 = [vi3++], fs 19
		{special2(0x36, 15, 2, 0), .VU0}, // VLQD of [--vi0], vi0 stays 0
		{special2(0x36, 15, 2, 3), .VU0}, // VLQD vf2 = [--vi3]
		{special2(0x36, 6, 4, 1), .VU0}, // VLQD.yz vf4 = [--vi1]
		{special2(0x35, 15, 1, 2), .VU0}, // VSQI vf2 to [vi1++]
		{special2(0x35, 0xa, 2, 3), .VU0}, // VSQI.xz, an even vi
		{special2(0x35, 0, 2, 3), .VU0}, // VSQI of no lanes, still increments
		{special2(0x35, 15, 0, 3), .VU0}, // VSQI to [vi0], no increment
		{special2(0x35, 15, 16, 3), .VU0}, // VSQI with ft 16, vi0
		{special2(0x35, 9, 18, 0), .VU0}, // VSQI.xw vf0 to [vi2++], ft 18
		{special2(0x37, 15, 0, 3), .VU0}, // VSQD to [--vi0], vi0 stays 0
		{special2(0x37, 15, 2, 4), .VU0}, // VSQD vf4 to [--vi2]
		{special2(0x37, 3, 1, 5), .VU0}, // VSQD.zw vf5 to [--vi1]
		{0x4a000038 | (0x40 / 8) << 6, .VU0}, // VCALLMS 0x40
		{0x4a000039, .VU0}, // VCALLMSR, CMSAR0 0x40 / 8
		{special(0x0d), .BREAK}, // compiled only: cpu.brk exits
		{54 << 26 | 1 << 21 | 2 << 16 | (0x10000 - MEM_BACK), .LQC2},
		{54 << 26 | 1 << 21 | (0x10000 - MEM_BACK), .LQC2}, // vf0 stays
		{62 << 26 | 1 << 21 | 2 << 16 | (0x10000 - MEM_BACK), .SQC2},
		{62 << 26 | 1 << 21 | (0x10000 - MEM_BACK), .SQC2}, // vf0 as it is
	}
	// The reference CVT.W.S checks against: the i32 limit on the side of
	// the sign for a NaN or an infinity, as for any |x| >= 2^31.
	CVT_W :: [?][2]u32 {
		{0x7fc00000, 0x7fffffff},
		{0x7f800000, 0x7fffffff},
		{0x4f000000, 0x7fffffff},
		{0xffc00000, 0x80000000},
		{0xff800000, 0x80000000},
		{0xcf000000, 0x80000000},
	}
	for v in CVT_W {
		if got := u32(cpu.cvt_w(transmute(f32)v[0])); got != v[1] {
			fmt.eprintfln("FAIL cpu.cvt_w(%08x) = %08x, want %08x", v[0], got, v[1])
			os.exit(1)
		}
	}
	// The MMI multiplies' arithmetic, which native and interpreter share in
	// cpu, against hand-computed results: from r1, r2, LO and HI, r3, LO and
	// HI after ps2.exec. Words low first.
	Fixed :: struct {w: u32, r1, r2, lo, hi, want_r3, want_lo, want_hi: [4]u32}
	fixed := [?]Fixed {
		// PMULTW: -2 * 5 and 3 * min(i32), each half sign-extended
		{mmi(0x09, 0x0c), {0xfffffffe, 0, 3, 0}, {5, 0, 0x80000000, 0}, {}, {},
		 {0xfffffff6, 0xffffffff, 0x80000000, 0xfffffffe},
		 {0xfffffff6, 0xffffffff, 0x80000000, 0xffffffff}, {0xffffffff, 0xffffffff, 0xfffffffe, 0xffffffff}},
		// PMADDW: 0xffffffff + 2 * 3 carries into HI; min(i64) + -1 * 1 wraps
		{mmi(0x09, 0x00), {2, 0, 0xffffffff, 0}, {3, 0, 1, 0}, {0xffffffff, 0, 0, 0}, {0, 0, 0x80000000, 0},
		 {5, 1, 0xffffffff, 0x7fffffff}, {5, 0, 0xffffffff, 0xffffffff}, {1, 0, 0x7fffffff, 0}},
		// PDIVW: 7 / 0 and min(i32) / -1; rd stays
		{mmi(0x09, 0x0d), {7, 0, 0x80000000, 0}, {0, 0, 0xffffffff, 0}, {}, {},
		 {}, {0xffffffff, 0xffffffff, 0x80000000, 0xffffffff}, {7, 0, 0, 0}},
		// PMFHL.SLW: 2^31 and -2^32 + max(i32) saturate
		{mmi(0x30, 2), {}, {}, {0x80000000, 0, 0x7fffffff, 0}, {0, 0, 0xffffffff, 0},
		 {0x7fffffff, 0, 0x80000000, 0xffffffff}, {0x80000000, 0, 0x7fffffff, 0}, {0, 0, 0xffffffff, 0}},
		// PHMSBH: 3 * 11 - 2 * 7, 5 * 1 - 4 * 1, -0x8000 * 1 - -0x8000 * -0x8000, 1 * 1 - 1 * 2;
		// the odd words of LO and HI the complements of 33, 5, -0x8000 and 1
		{mmi(0x09, 0x15), {0x00030002, 0x00050004, 0x80008000, 0x00010001}, {0x000b0007, 0x00010001, 0x00018000, 0x00010002}, {}, {},
		 {19, 1, 0xbfff8000, 0xffffffff}, {19, 0xffffffde, 0xbfff8000, 0x00007fff}, {1, 0xfffffffa, 0xffffffff, 0xfffffffe}},
		// PDIVBW: min(i32) / -1, 7 / -1, -7 / -1 and 0 / -1, the divisor rt's
		// low halfword alone
		{mmi(0x09, 0x1d), {0x80000000, 7, 0xfffffff9, 0}, {0x1234ffff, 0, 0, 0}, {}, {},
		 {}, {0x80000000, 0xfffffff9, 7, 0}, {}},
		// PDIVBW by zero: the quotient 1 for a negative word, -1 for the rest;
		// the remainder the word
		{mmi(0x09, 0x1d), {5, 0xfffffffb, 0, 0x80000000}, {0xabcd0000, 0, 0, 0}, {}, {},
		 {}, {0xffffffff, 1, 0xffffffff, 1}, {5, 0xfffffffb, 0, 0x80000000}},
		// DIV1: min(i32) / -1 into LO and HI's upper halves; the lower stay
		{mmi(0x1a), {0x80000000, 0, 0, 0}, {0xffffffff, 0, 0, 0}, {1, 2, 3, 4}, {5, 6, 7, 8},
		 {}, {1, 2, 0x80000000, 0xffffffff}, {5, 6, 0, 0}},
	}
	for v in fixed {
		cpu.state = {}
		cpu.state.r[1].w, cpu.state.r[2].w, cpu.state.lo.w, cpu.state.hi.w = v.r1, v.r2, v.lo, v.hi
		ps2.exec(0, v.w)
		got := [3][4]u32{cpu.state.r[3].w, cpu.state.lo.w, cpu.state.hi.w}
		want := [3][4]u32{v.want_r3, v.want_lo, v.want_hi}
		if got != want {
			fmt.eprintfln("FAIL %08x: r3 lo hi %x, want %x", v.w, got, want)
			os.exit(1)
		}
	}
	mem.mem_init()
	vu.vu_init()
	// The microprogram at 0x40 VCALLMS and VCALLMSR run: a NOP with the E
	// bit, then the NOP in its delay slot.
	for v, n in ([?]u32{0x8000033c, 0x400002ff, 0x8000033c, 0x000002ff}) {
		(^u32)(&vu.vu0.micro[0x40 + 4 * n])^ = v
	}
	arch := native.Arch(core.NATIVE_ARCH)
	a := native.make_asm(arch, r5900.native_ram())
	funcs: [len(cases)]native.Blob_Func
	slow: map[string]int
	for c, k in cases {
		if got := r5900.decode(0, c.w).op; got != c.op {
			fmt.eprintfln("FAIL %08x decodes to %v, want %v", c.w, got, c.op)
			os.exit(1)
		}
		at := u32(ENTRY + 16 * k)
		words := [?]u32{c.w, 0x03e00008, 0}
		data: [len(words) * 4]u8
		for w, n in words {
			data[4 * n], data[4 * n + 1], data[4 * n + 2], data[4 * n + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
		}
		f := mips.func_make(at, at + len(data))
		mips.discover(r5900.RULES, {base = at, data = data[:]}, f, {})
		funcs[k] = {at, r5900.native_func(&a, f, {}, 1, &slow)[0]}
		free_all(context.temp_allocator)
	}
	if len(slow) != 0 {
		fmt.eprintln("FAIL interpreter calls in native code:", slow)
		os.exit(1)
	}
	code, err := core.native_load(native.make_blob(&a, funcs[:], {}), ps2.native_imports())
	if err != "" {
		fmt.eprintln("native_load:", err)
		os.exit(1)
	}
	cpu.next_event = max(u64)
	cpu.trap_hook = trap_hook
	defer cpu.trap_hook = nil
	failed, checks := 0, 0
	// VU0 data memory as each check starts and as the native code leaves it.
	vu_mem, native_mem: [vu.VU0_MEM]u8
	for c, k in cases {
		run := cast(proc())rawptr(code.base + uintptr(code.funcs[k].off))
		if slice.contains(COP1_OPS[:], c.op) {
			failed, checks = check_fpu(c, funcs[k].addr, run, failed, checks)
			continue
		}
		if slice.contains(UNALIGNED_OPS[:], c.op) || slice.contains(ALIGNED_OPS[:], c.op) {
			failed, checks = check_unaligned(c, funcs[k].addr, run, failed, checks)
			continue
		}
		if c.op == .BREAK {continue}
		if c.op == .LQC2 || c.op == .SQC2 {
			failed, checks = check_mem(c, funcs[k].addr, run, failed, checks)
			continue
		}
		for x in VALS {
			for y in VALS {
				start: cpu.Cpu
				start.r[1].d = {x, ~x ~ y}
				start.r[2].d = {y, x * 0x9e3779b9}
				start.r[3].d = {0xdead_beef_0bad_f00d, x ~ (y << 1)}
				start.hi.d = {x ~ 0x5555, y}
				start.lo.d = {y ~ 0xaaaa, x}
				start.cop0[12] = u32(x) | 0x10000
				start.fcr31 = u32(y)
				start.sa = u32(x) & 127
				// QFSRV: every SA, and the 128 to 255 only direct state can
				// hold: 128 gives rs, the others shift everything out.
				if c.op == .QFSRV {
					start.sa = u32(x ~ y) & 255
					if x == y && x & 1 != 0 {start.sa = 128}
				}
				// VU0: the values' words as floats, NaNs, infinities and
				// denormals among them.
				vu_start := vu.vu0
				vu_start.vf[0].f = {0, 0, 0, 1}
				for &v, n in vu_start.vf[1:] {v.u = {u32(x), u32(y >> 32), u32(y), u32(x >> 32) ~ u32(n)}}
				for &r, n in vu_start.vi[1:] {r = u16(x >> (4 * u32(n))) ~ u16(y) ~ u16(n * 0x1111)}
				// vi0 is nonzero after an integer op with a field of 16.
				vu_start.vi[0] = u16(y >> 48) ~ u16(x)
				vu_start.cmsar = 0x40 / 8
				vu_start.acc.u = {u32(y), u32(x), u32(x >> 32), u32(y >> 32)}
				vu_start.q = transmute(f32)u32(y ~ (x >> 32))
				vu_start.i = transmute(f32)u32(x ~ (y >> 32))
				// Not rt's word, so a CTC2 to the read-only MAC shows.
				vu_start.mac = u32(y ~ (x << 11)) ~ 0x5a5a
				vu_start.status = u32(x >> 7) & 0xfff
				// Bits above the 24 too, which the shift drops.
				vu_start.clip = u32(x ~ (y << 7))
				// R's bits above the 23 too, which a write drops.
				vu_start.r = u32(y ~ (x << 3))
				vu_start.tpc = u32(x >> 16)
				vu_start.fbrst = u32(y >> 8)
				vu.vu1.cmsar = u32(x ~ y) & 0xffff
				// VCLIP of vf2w: every value against every value of vf1x.
				if c.w == special2(0x1f) {vu_start.vf[2].u[3] = u32(y)}
				// A pattern of the row too, so a store of what is there
				// already cannot pass.
				for &b, i in vu_mem {b = u8(u32(i) * 0x9d ~ u32(k) * 0x3b ~ u32(x) ~ u32(i >> 8))}
				cpu.state, vu.vu0 = start, vu_start
				copy(vu.vu0.mem, vu_mem[:])
				trapped = false
				run()
				native_trapped, native_pc := trapped, trapped_pc
				native_got, native_vu := cpu.state, vu.vu0
				copy(native_mem[:], vu.vu0.mem)
				cpu.state, vu.vu0 = start, vu_start
				copy(vu.vu0.mem, vu_mem[:])
				trapped = false
				ps2.exec_insn(r5900.decode(funcs[k].addr, c.w))
				// A trap calls cpu.trap at its pc in both, exactly when the
				// encoding says; the state compare below shows nothing written.
				if taken := trap_taken(c.w, x, y); taken || native_trapped || trapped {
					checks += 1
					if !taken || !native_trapped || !trapped || native_pc != funcs[k].addr || trapped_pc != funcs[k].addr {
						failed += 1
						fmt.eprintfln("FAIL %v %08x rs %016x rt %016x: trap %v, native %v at %08x, interp %v at %08x",
							c.op, c.w, x, y, taken, native_trapped, native_pc, trapped, trapped_pc)
					}
				}
				// The native function charges its cycles; the interpreter
				// leaves that to its caller.
				native_got.cycles = cpu.state.cycles
				checks += 1
				// PLZCW writes the low doubleword of rd only, as PCSX2's
				// MMI.cpp PLZCW does (UL[0] and UL[1]); rd's high one
				// starts nonzero here. MFSA too, as PCSX2's MFSA writes UD[0].
				if (c.op == .PLZCW || c.op == .MFSA) && cpu.state.r[3].d[1] != start.r[3].d[1] {
					failed += 1
					fmt.eprintfln("FAIL %v rd high %016x, want %016x", c.op, cpu.state.r[3].d[1], start.r[3].d[1])
				}
				interp_vu := vu.vu0
				vu_same := runtime.memory_equal(&native_vu, &interp_vu, size_of(vu.Vu))
				mem_same := slice.equal(native_mem[:], vu.vu0.mem)
				if !same(native_got, cpu.state) || !vu_same || !mem_same {
					failed += 1
					if failed > 20 {continue}
					fmt.eprintfln("FAIL %v %08x rs %016x rt %016x", c.op, c.w, x, y)
					diff(native_got, cpu.state)
					if !vu_same {vu_diff(native_vu, interp_vu)}
					for o := 0; o < len(native_mem); o += 16 {
						if !slice.equal(native_mem[o:][:16], vu.vu0.mem[o:][:16]) {
							fmt.eprintfln("  VU0 memory %03x native %02x interp %02x", o, native_mem[o:][:16], vu.vu0.mem[o:][:16])
						}
					}
				}
			}
		}
	}
	failed += check_calls(arch)
	checks += 2
	if failed != 0 {
		fmt.eprintfln("%d of %d checks failed", failed, checks)
		os.exit(1)
	}
	fmt.printfln("ok ee_native %v: %d instructions, %d checks", arch, len(cases), checks)
}

// A jal to a function in the blob is a direct call to its native code, one
// to a function outside it goes through cpu.call. The function in the blob
// is registered too, as an Odin function adding something else, so a call
// through the table would show.
@(private = "file")
check_calls :: proc(arch: native.Arch) -> (failed: int) {
	IN, OUT, CALL_IN, CALL_OUT :: u32(0x00200000), u32(0x00200100), u32(0x00200200), u32(0x00200300)
	jal :: proc(t: u32) -> u32 {return 0x03 << 26 | (t >> 2) & 0x3ffffff}
	addiu :: proc(rt, rs: u32, imm: u32) -> u32 {return 0x09 << 26 | rs << 21 | rt << 16 | imm}
	JR_RA :: 0x03e00008
	Prog :: struct {
		at:    u32,
		words: [5]u32,
	}
	// The callee adds 1 to r3; each caller sets r2 in the delay slot and
	// adds 0x10 to r3 after the call.
	progs := [?]Prog {
		{IN, {addiu(3, 3, 1), JR_RA, 0, 0, 0}},
		{CALL_IN, {jal(IN), addiu(2, 0, 5), addiu(3, 3, 0x10), JR_RA, 0}},
		{CALL_OUT, {jal(OUT), addiu(2, 0, 6), addiu(3, 3, 0x10), JR_RA, 0}},
	}
	a := native.make_asm(arch, r5900.native_ram())
	labels := make(map[u32]native.Label)
	defer delete(labels)
	for p in progs {labels[p.at] = native.new_label(&a)}
	funcs: [len(progs)]native.Blob_Func
	slow: map[string]int
	defer delete(slow)
	for p, k in progs {
		data: [len(p.words) * 4]u8
		for w, n in p.words {
			data[4 * n], data[4 * n + 1], data[4 * n + 2], data[4 * n + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
		}
		f := mips.func_make(p.at, p.at + len(data))
		mips.discover(r5900.RULES, {base = p.at, data = data[:]}, f, {})
		funcs[k] = {p.at, r5900.native_func(&a, f, {}, 1, &slow, labels)[0]}
		free_all(context.temp_allocator)
	}
	code, err := core.native_load(native.make_blob(&a, funcs[:], {}), ps2.native_imports())
	if err != "" {
		fmt.eprintln("native_load:", err)
		os.exit(1)
	}
	cpu.text_range(IN, CALL_OUT + 0x100)
	cpu.register(IN, proc() {cpu.state.r[3].d[0] += 0x1000})
	cpu.register(OUT, proc() {cpu.state.r[3].d[0] += 0x100})
	for k in 1 ..< len(progs) {
		cpu.state = {}
		run := cast(proc())rawptr(code.base + uintptr(code.funcs[k].off))
		run()
		want := [3]u64{k == 1 ? 0x11 : 0x110, u64(4 + k), u64(progs[k].at + 8)}
		got := [3]u64{cpu.state.r[3].d[0], cpu.state.r[2].d[0], cpu.state.r[31].d[0]}
		if got != want {
			failed += 1
			fmt.eprintfln("FAIL jal %08x: r3 r2 ra %x, want %x", progs[k].words[0], got, want)
		}
	}
	return
}

// A VU0 quadword load or store at each of MEM_ADDRS, with the watch byte
// clear and set (which sends a store to the runtime): the native function
// and the interpreter must leave the same cpu.state, VF registers and
// quadword in memory.
@(private = "file")
check_mem :: proc(c: Case, addr: u32, run: proc(), failed, checks: int) -> (int, int) {
	failed, checks := failed, checks
	for at in MEM_ADDRS {
		for watch in ([?]u8{0, 1}) {
			Got :: struct {
				state: cpu.Cpu,
				vf:    [32]u128,
				q:     u128,
			}
			start: cpu.Cpu
			start.r[1].d = {u64(at + MEM_BACK), 0x0123_4567_89ab_cdef}
			start.r[2].d = {u64(at), ~u64(at)}
			got: [2]Got
			for interp in 0 ..< 2 {
				for &v, n in vu.vu0.vf[1:] {v.q = u128(at) << 64 | u128(n + 1) * 0x0101_0101_0101_0101}
				mem.wr128(at, u128(0xfeed_face_cafe_f00d) << 64 | u128(at))
				mem.watch_on = watch
				cpu.state = start
				if interp == 0 {
					run()
				} else {
					ps2.exec_insn(r5900.decode(addr, c.w))
				}
				mem.watch_on = 0
				got[interp].state = cpu.state
				for v, n in vu.vu0.vf {got[interp].vf[n] = v.q}
				got[interp].q = mem.rd128(at)
			}
			got[0].state.cycles = got[1].state.cycles
			checks += 1
			if !same(got[0].state, got[1].state) || got[0].vf != got[1].vf || got[0].q != got[1].q {
				failed += 1
				if failed > 20 {continue}
				fmt.eprintfln("FAIL %v %08x at %08x watch %d", c.op, c.w, at, watch)
				diff(got[0].state, got[1].state)
				for n in 0 ..< 32 {
					if got[0].vf[n] != got[1].vf[n] {fmt.eprintfln("  vf%d native %032x interp %032x", n, got[0].vf[n], got[1].vf[n])}
				}
				if got[0].q != got[1].q {fmt.eprintfln("  memory native %032x interp %032x", got[0].q, got[1].q)}
			}
		}
	}
	return failed, checks
}

// An unaligned load or store at each of UNALIGNED_ADDRS plus 0 to 7, an
// aligned one at those of them its width allows, with the watch byte clear
// and set and two values in rt (and f2): the native function and the
// interpreter must leave the same cpu.state and the same two quadwords
// around the address.
@(private = "file")
check_unaligned :: proc(c: Case, addr: u32, run: proc(), failed, checks: int) -> (int, int) {
	failed, checks := failed, checks
	for base in UNALIGNED_ADDRS {
		for k in u32(0) ..< 8 {
			at := base + k
			if at % align(c.op) != 0 {continue}
			q0 := base &~ 15
			for watch in ([?]u8{0, 1}) {
				for v in ([?]u64{0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210}) {
					start: cpu.Cpu
					start.r[1].d = {0x5a5a_5a5a_0000_0000 | u64(at - u32(i32(i16(c.w)))), ~v}
					start.r[2].d = {v, v ~ 0x5555}
					for &f, n in start.f {f.u = 0x5a5a0000 | u32(n)}
					start.f[2].u = u32(v >> 16)
					got: [2]struct {
						state: cpu.Cpu,
						q:     [2]u128,
					}
					for interp in 0 ..< 2 {
						mem.wr128(q0, u128(0xfeed_face_cafe_f00d) << 64 | u128(0x8899_aabb_ccdd_ee00) | u128(k))
						mem.wr128(q0 + 16, u128(0x0f1e_2d3c_4b5a_6978) << 64 | u128(at))
						mem.watch_on = watch
						cpu.state = start
						if interp == 0 {
							run()
						} else {
							ps2.exec_insn(r5900.decode(addr, c.w))
						}
						mem.watch_on = 0
						got[interp].state = cpu.state
						got[interp].q = {mem.rd128(q0), mem.rd128(q0 + 16)}
					}
					got[0].state.cycles = got[1].state.cycles
					checks += 1
					if !same(got[0].state, got[1].state) || got[0].q != got[1].q {
						failed += 1
						if failed > 20 {continue}
						fmt.eprintfln("FAIL %v %08x at %08x watch %d rt %016x", c.op, c.w, at, watch, v)
						diff(got[0].state, got[1].state)
						if got[0].q != got[1].q {fmt.eprintfln("  memory native %032x interp %032x", got[0].q, got[1].q)}
					}
				}
			}
		}
	}
	return failed, checks
}

// A COP1 op over each pair of F_VALS in fs and ft, with each of ACC_VALS
// in ACC and FCR31's C bit set and clear: the native function and the
// interpreter must leave the same cpu.state.
@(private = "file")
check_fpu :: proc(c: Case, addr: u32, run: proc(), failed, checks: int) -> (int, int) {
	failed, checks := failed, checks
	for x in F_VALS {
		for y in F_VALS {
			for acc in ACC_VALS {
				for cond in ([?]u32{0, cpu.FCR31_C}) {
					start: cpu.Cpu
					for &f, n in start.f {f.u = 0x5a5a0000 | u32(n)}
					start.f[1].u, start.f[2].u = x, y
					start.acc.u = acc
					start.fcr31 = 0x01000001 | cond
					got: [2]cpu.Cpu
					for interp in 0 ..< 2 {
						cpu.state = start
						if interp == 0 {
							run()
						} else {
							ps2.exec_insn(r5900.decode(addr, c.w))
						}
						got[interp] = cpu.state
					}
					got[0].cycles = got[1].cycles
					checks += 1
					if !same(got[0], got[1]) {
						failed += 1
						if failed > 20 {continue}
						fmt.eprintfln("FAIL %v %08x fs %08x ft %08x acc %08x fcr31 %08x", c.op, c.w, x, y, acc, start.fcr31)
						for n in 0 ..< 32 {
							if got[0].f[n].u != got[1].f[n].u {fmt.eprintfln("  f%d native %08x interp %08x", n, got[0].f[n].u, got[1].f[n].u)}
						}
						if got[0].acc.u != got[1].acc.u {fmt.eprintfln("  acc native %08x interp %08x", got[0].acc.u, got[1].acc.u)}
						if got[0].fcr31 != got[1].fcr31 {fmt.eprintfln("  fcr31 native %08x interp %08x", got[0].fcr31, got[1].fcr31)}
					}
				}
			}
		}
	}
	return failed, checks
}

// The fields where native and interp differ.
@(private = "file")
diff :: proc(n, i: cpu.Cpu) {
	for r in 0 ..< 32 {
		if n.r[r].q != i.r[r].q {fmt.eprintfln("  r%d native %032x interp %032x", r, n.r[r].q, i.r[r].q)}
	}
	if n.hi.q != i.hi.q {fmt.eprintfln("  hi native %032x interp %032x", n.hi.q, i.hi.q)}
	if n.lo.q != i.lo.q {fmt.eprintfln("  lo native %032x interp %032x", n.lo.q, i.lo.q)}
	if n.cop0 != i.cop0 {fmt.eprintfln("  cop0 native %x interp %x", n.cop0, i.cop0)}
	if n.sa != i.sa || n.fcr31 != i.fcr31 || transmute([32]u32)n.f != transmute([32]u32)i.f || n.acc.u != i.acc.u {fmt.eprintln("  sa, fcr31, f or acc")}
}

@(private = "file")
vu_diff :: proc(n, i: vu.Vu) {
	for r in 0 ..< 32 {
		if n.vf[r].q != i.vf[r].q {fmt.eprintfln("  vf%d native %08x interp %08x", r, n.vf[r].u, i.vf[r].u)}
	}
	if n.acc.q != i.acc.q {fmt.eprintfln("  acc native %08x interp %08x", n.acc.u, i.acc.u)}
	if n.mac != i.mac || n.status != i.status {fmt.eprintfln("  mac/status native %x/%x interp %x/%x", n.mac, n.status, i.mac, i.status)}
	if n.vi != i.vi || n.q != i.q || n.p != i.p || n.i != i.i || n.r != i.r || n.clip != i.clip {fmt.eprintln("  vi, q, p, i, r or clip")}
}

@(private = "file")
same :: proc(n, i: cpu.Cpu) -> bool {
	n, i := n, i
	return runtime.memory_equal(&n, &i, size_of(cpu.Cpu))
}
