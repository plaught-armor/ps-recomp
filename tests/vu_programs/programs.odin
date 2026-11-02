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
// Then DIV vf1.x / vf0.x (D, or I) with Q's wait reaching four inside the
// stall of the op after it, a DIV and a WAITQ, which then take its I and D
// before a DIV vf0.w / vf1.x (neither, but for vf1.x 0) replaces them: the
// end status keeps only the sticky bit, which a late merge would miss.
PROGRAMS_VU0 := [?][]u32 {
	{lower_sp(DIV, 0, 0, 1), upper(ADD, 3, 1, 2), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
	{lower_sp(SQRT, 0b0100, 1, 0), upper(MULq, 3, 1, 0), lower_sp(RSQRT, 0b0110, 0, 2), upper(MAX, 4, 1, 2), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
	{NOP_L, upper(ADD, 3, 1, 2), lower_sp(DIV, 0b0110, 0, 3), upper(MULq, 3, 3, 0) | E_BIT, NOP_L, upper(ADD, 3, 3, 1)},
	{lower_sp(DIV, 0, 0, 1), NOP_U, lower_sp(DIV, 0b0011, 1, 0), NOP_U, NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
	{lower_sp(DIV, 0, 0, 1), NOP_U, lower_sp(WAITQ, 0, 0, 0), NOP_U, lower_sp(DIV, 0b0011, 1, 0), NOP_U | E_BIT, NOP_L, NOP_U},
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

// Late flags: a flag read sees the flags after the pair four back. vi15 =
// 0x7fff masks MAC; MUL writes a MAC other than ADD's. Each read lands at
// another depth behind the writes, so each sees another value.
CLIP :: 0x1f
B :: 0x20
fmand :: proc "contextless" (t: u32) -> u32 {return 0x1a << 25 | t << 16 | 15 << 11}
fcget :: proc "contextless" (t: u32) -> u32 {return 0x1c << 25 | t << 16}
VI15 :: 0x08 << 25 | 0xf << 21 | 15 << 16 | 0x7ff // IADDIU vi15, vi0, 0x7fff
FCAND_ALL :: 0x12 << 25 | 0xfff // FCAND vi1, 0xfff
// MAC written in pairs 0 and 1, read in pairs 1 to 6.
LATE_MAC := []u32 {
	VI15, upper(ADD, 3, 1, 2),
	fmand(3), upper(MUL, 4, 1, 2),
	fmand(4), NOP_U,
	fmand(5), NOP_U,
	fmand(6), NOP_U,
	fmand(7), NOP_U,
	fmand(8), NOP_U | E_BIT,
	NOP_L, NOP_U,
}
// Clip written by the CLIPs in pairs 0 and 1, read beside them first.
LATE_CLIP := []u32 {
	fcget(3), upper_sp(CLIP, XYZ, 2, 1),
	fcget(4), upper_sp(CLIP, XYZ, 1, 2),
	fcget(5), NOP_U,
	fcget(6), NOP_U,
	FCAND_ALL, NOP_U,
	fcget(7), NOP_U,
	fcget(8), NOP_U | E_BIT,
	NOP_L, NOP_U,
}
// A branch over pair 4 into the window: the delay counts the pairs run,
// so the target's read sees pair 0's MAC, which only the shift in the
// delay slot moves to where it reads (the fall-through reads nothing).
LATE_BRANCH := []u32 {
	VI15, upper(ADD, 3, 1, 2),
	NOP_L, NOP_U,
	lower_op(B, 0, 0, 0, 2), upper(MUL, 4, 1, 2),
	fmand(3), NOP_U,
	NOP_L, upper(ADD, 5, 1, 1),
	fmand(5), NOP_U,
	fmand(6), NOP_U,
	fmand(7), NOP_U,
	fmand(8), NOP_U | E_BIT,
	NOP_L, NOP_U,
}
// Entries inside the window, between the writes and the reads: the run
// starts with every older value equal to the newest.
LATE_MAC_PCS := []u32{0, 0x08, 0x10, 0x18}
LATE_CLIP_PCS := []u32{0, 0x08, 0x10, 0x20}
LATE_BRANCH_PCS := []u32{0, 0x18, 0x20, 0x28}

// Q latency: DIV and SQRT write Q 7 pairs after issue, RSQRT 13; MULq
// vf<n>, vf2 reads it. DIV vf0.w / vf1.x, SQRT vf1.y, RSQRT vf0.w / vf1.w.
WAITQ :: 0x3b
Q_DIV := lower_sp(DIV, 0b0011, 1, 0)
Q_SQRT := lower_sp(SQRT, 0b0100, 1, 0)
Q_RSQRT := lower_sp(RSQRT, 0b1111, 1, 0)
mulq :: proc "contextless" (fd: u32) -> u32 {return upper(MULq, fd, 2, 0)}
// Reads in the issuing pair, at DIV +1, +6 and +7, at RSQRT +12 and +13,
// with a DIV that lands the SQRT before it, a WAITQ that lands the DIV,
// and an RSQRT left pending at the E bit.
Q_LAT := []u32 {
	Q_DIV, mulq(3),
	NOP_L, mulq(4),
	NOP_L, NOP_U, NOP_L, NOP_U, NOP_L, NOP_U, NOP_L, NOP_U,
	NOP_L, mulq(5),
	NOP_L, mulq(6), // 0x38
	Q_RSQRT, mulq(7),
	NOP_L, NOP_U, NOP_L, NOP_U, NOP_L, NOP_U, NOP_L, NOP_U, NOP_L, NOP_U, NOP_L, NOP_U,
	NOP_L, NOP_U, NOP_L, NOP_U, NOP_L, NOP_U, NOP_L, NOP_U, NOP_L, NOP_U,
	NOP_L, mulq(8),
	NOP_L, mulq(9),
	Q_SQRT, mulq(10),
	Q_DIV, mulq(11), // 0xb8
	lower_sp(WAITQ, 0, 0, 0), mulq(12),
	Q_RSQRT, mulq(13) | E_BIT,
	NOP_L, mulq(14),
}
// A branch over pair 3 into the window: the target's reads are the pairs
// run, so pair 7 is DIV +6 and pair 8 DIV +7.
Q_BRANCH := []u32 {
	Q_DIV, NOP_U,
	lower_op(B, 0, 0, 0, 2), NOP_U,
	NOP_L, mulq(3),
	NOP_L, mulq(4),
	NOP_L, mulq(5), // 0x20
	NOP_L, NOP_U,
	NOP_L, NOP_U,
	NOP_L, mulq(6),
	NOP_L, mulq(7) | E_BIT,
	NOP_L, mulq(8),
}
// A loop run three times whose DIV issues with the last iteration's pending.
Q_LOOP := []u32 {
	lower_op(IADDIU, 0, 1, 0, 3), NOP_U,
	Q_DIV, mulq(3), // 0x08, the loop
	lower_op(0x40, 0, 1, 1, 0x1f << 6 | IADDI), mulq(4),
	lower_op(IBNE, 0, 1, 0, 0x7fd), mulq(5),
	NOP_L, mulq(6),
	NOP_L, mulq(7) | E_BIT,
	NOP_L, NOP_U,
}
Q_LAT_PCS := []u32{0, 0x08, 0x38, 0xb8}
Q_BRANCH_PCS := []u32{0, 0x10, 0x20}

// Stalls: WAITQ, and a Q op issued while Q is pending, stall until Q lands,
// and the late flags age through the stall. ADD's MAC, written at DIV +1,
// is four pairs back once WAITQ has stalled to DIV +7, so FMAND sees it.
// The end status holds D and I, set by the pair after Q's wait drops to
// four, here inside the WAITQ's stall (no FSAND: a status read is left to
// the interpreter). The last DIV is left
// pending at the E bit.
WAITP :: 0x7b
Q_STALL := []u32 {
	VI15, NOP_U,
	Q_DIV, NOP_U,
	NOP_L, upper(ADD, 3, 1, 2),
	lower_sp(WAITQ, 0, 0, 0), NOP_U,
	fmand(4), mulq(5), // 0x20
	NOP_L, NOP_U,
	Q_RSQRT, NOP_U,
	Q_DIV, NOP_U, // stalls on the RSQRT
	NOP_L, mulq(6), // 0x40
	NOP_L, NOP_U,
	NOP_L, NOP_U,
	NOP_L, mulq(7) | E_BIT,
	NOP_L, NOP_U,
}
// WAITP, an EFU op issued while P is pending, and MFP after each.
P_STALL := []u32 {
	lower_sp(ESQRT, 0, 0, 1), NOP_U,
	NOP_L, upper(ADD, 3, 1, 2),
	lower_sp(WAITP, 0, 0, 0), NOP_U,
	lower_sp(MFP, 0b1111, 4, 0), NOP_U,
	lower_sp(ERCPR, 0, 0, 2), NOP_U, // 0x20
	lower_sp(ESQRT, 0, 0, 3), NOP_U, // stalls on the ERCPR
	lower_sp(MFP, 0b1111, 5, 0), NOP_U,
	lower_sp(ERCPR, 0, 0, 4), NOP_U | E_BIT, // pending at the E bit
	NOP_L, NOP_U,
}
Q_STALL_PCS := []u32{0, 0x18, 0x38}
P_STALL_PCS := []u32{0, 0x10, 0x28}

// Every program, on each unit it runs on.
programs :: proc() -> (progs: [dynamic]Prog) {
	for w in PROGRAMS {append(&progs, Prog{w, .VU1, nil, AT_0, nil}, Prog{w, .VU0, nil, AT_0, nil})}
	for w in PROGRAMS_VU0 {append(&progs, Prog{w, .VU0, nil, AT_0, nil})}
	// The late-flag and Q programs, every pair labelled and as captured images
	// entered at each pc.
	late := [?]struct {
		words, pcs: []u32,
	}{{LATE_MAC, LATE_MAC_PCS}, {LATE_CLIP, LATE_CLIP_PCS}, {LATE_BRANCH, LATE_BRANCH_PCS}, {Q_LAT, Q_LAT_PCS}, {Q_BRANCH, Q_BRANCH_PCS}, {Q_LOOP, AT_0}, {Q_STALL, Q_STALL_PCS}, {P_STALL, P_STALL_PCS}}
	for l in late {
		for u in vu.Unit {append(&progs, Prog{l.words, u, nil, l.pcs, nil}, Prog{l.words, u, l.pcs, l.pcs, nil})}
	}
	for u in vu.Unit {
		captured := Prog{ELIDE, u, ELIDE_ENTRIES, ELIDE_ENTRIES, ELIDE_LEAVES}
		if !vu.VU_CLAMP_ELIDE {captured.pcs, captured.leaves = ELIDE_PCS, nil} // every pair labelled
		append(&progs, captured, Prog{ELIDE, u, nil, ELIDE_PCS, nil})
	}
	return
}
