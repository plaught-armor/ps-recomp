// The VU microprograms that tests/vu_micro (through the generated Odin)
// and tests/vu_native (through the native backend) run against the
// interpreter; tests/vu_micro says what each one checks.
package vu_programs

import "ps:recomp/vu"

// Pair halves: lower word first, as in micro memory.
NOP_L :: 0x8000033c
NOP_U :: 0x000002ff
E_BIT :: 1 << 30
FMAND_1_2 :: 0x1a << 25 | 1 << 16 | 2 << 11 // FMAND vi1, vi2

// Upper ops, dest xyzw: fd, fs, ft in their fields.
upper :: proc "contextless" (fn, fd, fs, ft: u32) -> u32 {return 15 << 21 | ft << 16 | fs << 11 | fd << 6 | fn}
upper_sp :: proc "contextless" (sp, dest, ft, fs: u32) -> u32 {return dest << 21 | ft << 16 | fs << 11 | (sp >> 2) << 6 | 0x3c | sp & 3}

// Lower ops: opcode 0x40 specials by their sp number, and the others by
// opcode, with dest (or DIV's field selects), ft, fs and imm11 in place.
lower_sp :: proc "contextless" (sp, dest, ft, fs: u32) -> u32 {
	return 0x40 << 25 | dest << 21 | ft << 16 | fs << 11 | (sp >> 2) << 6 | 0x3c | sp & 3
}
lower_op :: proc "contextless" (op, dest, ft, fs, imm: u32) -> u32 {return op << 25 | dest << 21 | ft << 16 | fs << 11 | imm}


Prog :: struct {
	words:   []u32,
	unit:    vu.Unit,
	entries: []u32, // compiled as a captured image entered at these
	pcs:     []u32, // where the trials start
	leaves:  []u32, // where trials start that must leave at once
}

ADD :: 0x28
MAX :: 0x2b
MINI :: 0x2f
MAXbc :: 0x10
MINIi :: 0x1f
MULq :: 0x1c
MULi :: 0x1e
MSUBq :: 0x25
LQ :: 0x00
SQ :: 0x01
MOVE :: 0x30
MR32 :: 0x31
LQI :: 0x34
SQI :: 0x35
DIV :: 0x38
SQRT :: 0x39
RSQRT :: 0x3a
MTIR :: 0x3c
MFIR :: 0x3d
ILWR :: 0x3e
ISWR :: 0x3f
IADDIU :: 0x08
IADDI :: 0x32 // an IADD-family op, imm5 in the fd field
IBLTZ :: 0x2c
IBGEZ :: 0x2f
MFP :: 0x64
ESADD :: 0x70
ERSADD :: 0x71
ELENG :: 0x72
ERLENG :: 0x73
EATANxy :: 0x74
EATANxz :: 0x75
ESUM :: 0x76
ESQRT :: 0x78
ERSQRT :: 0x79
ERCPR :: 0x7a
ESIN :: 0x7c
EATAN :: 0x7d
EEXP :: 0x7e
XYZ :: 0b1110
PROGRAMS := [?][]u32 {
	// ADD sets MAC; MAX, MINI (each form) leave it for FMAND.
	{NOP_L, upper(ADD, 3, 1, 2), NOP_L, upper(MAX, 4, 1, 2), FMAND_1_2, NOP_U | E_BIT, NOP_L, NOP_U},
	{NOP_L, upper(ADD, 3, 1, 2), NOP_L, upper(MINI, 4, 1, 2), NOP_L, upper(MINIi, 5, 1, 0), FMAND_1_2, NOP_U | E_BIT, NOP_L, NOP_U},
	{NOP_L, upper(ADD, 3, 1, 2), NOP_L, upper(MAXbc | 2, 4, 1, 2), FMAND_1_2, NOP_U | E_BIT, NOP_L, NOP_U},
	// MAX writing the register ADD wrote.
	{NOP_L, upper(ADD, 3, 1, 2), NOP_L, upper(MAX, 3, 3, 1), FMAND_1_2, NOP_U | E_BIT, NOP_L, NOP_U},
	// The lower reads the upper's dest: DIV (vf3.y / vf3.z), SQRT,
	// MTIR, SQ and SQI, MOVE and MR32 into another register.
	{lower_sp(DIV, 0b1001, 3, 3), upper(MULq, 3, 1, 0), lower_sp(MTIR, 2, 5, 3), upper(MULi, 3, 2, 0), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
	{lower_sp(SQRT, 0b0100, 4, 0), upper(ADD, 4, 1, 2), lower_op(SQ, 0b1011, 6, 4, 0x13), upper(MSUBq, 4, 2, 0), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
	{lower_sp(SQI, 0b1111, 7, 5), upper(MULq, 5, 5, 0), lower_sp(MOVE, 0b0110, 9, 5), upper(ADD, 5, 1, 5), lower_sp(MR32, 0b1111, 10, 5), upper(MULi, 5, 5, 0), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
	// The lower writes the upper's dest: MOVE of the register onto
	// itself (the upper wins), LQI (it wins), LQ of x and z (it wins,
	// keeping y and w from before the upper). Each result is read by
	// the next upper, and LQ's is left at the end.
	{lower_sp(MOVE, 0b1111, 3, 3), upper(MULi, 3, 3, 0), lower_sp(LQI, 0b1111, 3, 6), upper(MSUBq, 3, 3, 0), lower_op(LQ, 0b1010, 3, 4, 0x7f5), upper(ADD, 3, 1, 2), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
	// Hazard pairs in an E-bit pair and its successor, one case.
	{NOP_L, upper(ADD, 3, 1, 2), lower_sp(DIV, 0b0110, 1, 3), upper(MULq, 3, 3, 0) | E_BIT, lower_sp(MTIR, 3, 4, 3), upper(ADD, 3, 3, 1)},
	// The EFU's vector ops (dest xyz, or xyzw for ESUM), each read back
	// by MFP into its own register, part (xz) or whole.
	{
		lower_sp(MFP, 0b0101, 3, 0), NOP_U,
		lower_sp(ESADD, XYZ, 0, 1), NOP_U, lower_sp(MFP, 0b1010, 4, 0), NOP_U,
		lower_sp(ERSADD, XYZ, 0, 2), NOP_U, lower_sp(MFP, 0b1111, 5, 0), NOP_U,
		lower_sp(ELENG, XYZ, 0, 3), NOP_U, lower_sp(MFP, 0b1010, 6, 0), NOP_U,
		lower_sp(ERLENG, XYZ, 0, 4), NOP_U, lower_sp(MFP, 0b1111, 7, 0), NOP_U,
		lower_sp(EATANxy, 0b1100, 0, 5), NOP_U, lower_sp(MFP, 0b1010, 8, 0), NOP_U,
		lower_sp(EATANxz, 0b1010, 0, 6), NOP_U, lower_sp(MFP, 0b1111, 9, 0), NOP_U,
		lower_sp(ESUM, 0b1111, 0, 7), NOP_U, lower_sp(MFP, 0b1010, 10, 0), NOP_U,
		NOP_L, NOP_U | E_BIT, NOP_L, NOP_U,
	},
	// The scalar ops, on field x, y, z and w in turn (fsf in DIV's fs
	// select bits).
	{
		lower_sp(ESQRT, 0b0000, 0, 1), NOP_U, lower_sp(MFP, 0b1010, 3, 0), NOP_U,
		lower_sp(ERSQRT, 0b0001, 0, 2), NOP_U, lower_sp(MFP, 0b1111, 4, 0), NOP_U,
		lower_sp(ERCPR, 0b0010, 0, 3), NOP_U, lower_sp(MFP, 0b1010, 5, 0), NOP_U,
		lower_sp(ESIN, 0b0011, 0, 4), NOP_U, lower_sp(MFP, 0b1111, 6, 0), NOP_U,
		lower_sp(EATAN, 0b0001, 0, 5), NOP_U, lower_sp(MFP, 0b1010, 7, 0), NOP_U,
		lower_sp(EEXP, 0b0010, 0, 6), NOP_U, lower_sp(MFP, 0b1111, 8, 0), NOP_U,
		NOP_L, NOP_U | E_BIT, NOP_L, NOP_U,
	},
	// Hazard pairs: ESIN reads vf3.y from before the ADD that writes it;
	// MFP writes yw of vf3, which the MULi beside it writes too.
	{
		NOP_L, upper(ADD, 3, 1, 2), lower_sp(ESIN, 0b0001, 0, 3), upper(ADD, 3, 3, 1),
		lower_sp(MFP, 0b0101, 3, 0), upper(MULi, 3, 3, 0), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U,
	},
	// ILWR and ISWR on each field. vi4 = 0x7fff is the last quadword
	// of either VU's memory; one more wraps it to the first. vi6 is
	// random, so wraps too. ILWR.xyzw keeps w; ILWR to vi0 does nothing.
	{
		lower_op(IADDIU, 0xf, 4, 0, 0x7ff), NOP_U, lower_sp(ISWR, 0b1000, 3, 4), NOP_U,
		lower_sp(ILWR, 0b0100, 5, 4), NOP_U, lower_sp(ISWR, 0b0101, 7, 6), NOP_U,
		lower_op(0x40, 0, 4, 4, 1 << 6 | IADDI), NOP_U, lower_sp(ISWR, 0b0010, 11, 4), NOP_U,
		lower_sp(ILWR, 0b0010, 8, 4), NOP_U, lower_sp(ILWR, 0b1000, 10, 4), NOP_U,
		lower_sp(ILWR, 0b0001, 9, 6), NOP_U, lower_sp(ILWR, 0b1111, 12, 6), NOP_U,
		lower_sp(ILWR, 0b1111, 0, 6), NOP_U, NOP_L, NOP_U | E_BIT, NOP_L, NOP_U,
	},
	// vi3 = -1 and vi4 = 0x7fff through MFIR (sign-extended into xw of
	// vf3, yz of vf4) and IBLTZ and IBGEZ: on vi3 IBLTZ is taken and
	// IBGEZ is not, on vi4 the reverse. An IADDIU in each delay slot
	// always runs; the one after runs only when the branch is not taken.
	{
		lower_op(0x40, 0, 3, 0, 0x1f << 6 | IADDI), NOP_U, lower_op(IADDIU, 0xf, 4, 0, 0x7ff), NOP_U,
		lower_sp(MFIR, 0b1001, 3, 3), NOP_U,
		lower_op(IBLTZ, 0, 0, 3, 2), NOP_U, lower_op(IADDIU, 0, 5, 0, 1), NOP_U, lower_op(IADDIU, 0, 6, 0, 1), NOP_U,
		lower_op(IBGEZ, 0, 0, 3, 2), NOP_U, lower_op(IADDIU, 0, 7, 0, 1), NOP_U, lower_op(IADDIU, 0, 8, 0, 1), NOP_U,
		lower_op(IBLTZ, 0, 0, 4, 2), NOP_U, lower_op(IADDIU, 0, 9, 0, 1), NOP_U, lower_op(IADDIU, 0, 10, 0, 1), NOP_U,
		lower_op(IBGEZ, 0, 0, 4, 2), NOP_U, lower_op(IADDIU, 0, 11, 0, 1), NOP_U, lower_op(IADDIU, 0, 12, 0, 1), NOP_U,
		lower_sp(MFIR, 0b0110, 4, 4), NOP_U, NOP_L, NOP_U | E_BIT, NOP_L, NOP_U,
	},
}
// VU0 only. DIV vf1.x / vf0.x (I or D) with ADD; SQRT vf1.y with MULq,
// then RSQRT vf2.z / vf0.y (I or D) with MAX, which leaves status;
// DIV vf3.z / vf0.y with an E-bit MULq, after the ADD that writes vf3.
PROGRAMS_VU0 := [?][]u32 {
	{lower_sp(DIV, 0, 0, 1), upper(ADD, 3, 1, 2), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
	{lower_sp(SQRT, 0b0100, 1, 0), upper(MULq, 3, 1, 0), lower_sp(RSQRT, 0b0110, 0, 2), upper(MAX, 4, 1, 2), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
	{NOP_L, upper(ADD, 3, 1, 2), lower_sp(DIV, 0b0110, 0, 3), upper(MULq, 3, 3, 0) | E_BIT, NOP_L, upper(ADD, 3, 3, 1)},
}
// Clamp elision. Clamped results (ADD, MUL, ITOF, and MAX of two) feed
// later operands; MOVE.xy and FTOI make lanes unclamped again. vi1
// counts the loop back to 0x10 three times; 0x48 is a second entry, a
// label the elision must keep.
MUL :: 0x2a
MADD :: 0x29
ADDx :: 0x00
ADDw :: 0x03
ITOF0 :: 0x10
FTOI0 :: 0x14
OPMULA :: 0x2e
IBNE :: 0x29
ELIDE := []u32 {
	lower_op(IADDIU, 0, 1, 0, 3), upper(ADD, 3, 1, 2),
	NOP_L, upper(MUL, 4, 3, 3),
	NOP_L, upper(ADDx, 5, 4, 3), // 0x10, the loop
	lower_sp(MOVE, 0b0110, 4, 5), upper(MUL, 6, 5, 5),
	lower_sp(MOVE, 0b1100, 6, 20), upper(MAX, 7, 5, 0),
	lower_op(0x40, 0, 1, 1, 0x1f << 6 | IADDI), upper_sp(FTOI0, 15, 5, 7),
	lower_op(IBNE, 0, 1, 0, 0x7fb), upper(MUL, 8, 7, 5),
	lower_sp(MOVE, 15, 14, 9), upper(ADD, 9, 6, 4),
	NOP_L, upper_sp(ITOF0, 15, 10, 11),
	NOP_L, upper(ADDw, 12, 10, 10), // 0x48, the second entry
	NOP_L, upper_sp(OPMULA, XYZ, 10, 12),
	NOP_L, upper(MADD, 13, 12, 10) | E_BIT,
	NOP_L, NOP_U,
}
ELIDE_ENTRIES := []u32{0, 0x48}
ELIDE_PCS := []u32{0, 0x48, 0x50}
ELIDE_LEAVES := []u32{0x08, 0x50}
AT_0 := []u32{0}

// Every program, on each unit it runs on.
programs :: proc() -> (progs: [dynamic]Prog) {
	for w in PROGRAMS {append(&progs, Prog{w, .VU1, nil, AT_0, nil}, Prog{w, .VU0, nil, AT_0, nil})}
	for w in PROGRAMS_VU0 {append(&progs, Prog{w, .VU0, nil, AT_0, nil})}
	for u in vu.Unit {
		captured := Prog{ELIDE, u, ELIDE_ENTRIES, ELIDE_ENTRIES, ELIDE_LEAVES}
		if !vu.VU_CLAMP_ELIDE {captured.pcs, captured.leaves = ELIDE_PCS, nil} // every pair labelled
		append(&progs, captured, Prog{ELIDE, u, nil, ELIDE_PCS, nil})
	}
	return
}
