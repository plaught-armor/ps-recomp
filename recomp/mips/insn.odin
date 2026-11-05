// The MIPS front end shared by the r3000 and r5900 backends: what function
// discovery needs from an instruction, input tables, code images and output
// helpers. Each backend decodes with its own console's decoder and turns the
// result into an Insn; its emitter decodes the word again for everything
// else, so the front end never depends on either instruction set's details.
package mips

Kind :: enum u8 {
	Alu,
	Branch, // conditional, delay slot
	Jump, // j
	Call, // jal
	Jr,
	Jalr,
	Bad,
	Sys, // syscall, break, eret
}

Insn :: struct {
	pc, w:  u32,
	target: u32, // Branch, Jump, Call
	kind:   Kind,
	rs:     u8, // Jr: the register jumped through
	// Control never passes this instruction (PS1 `break 1` after main, EE
	// `eret`).
	halt:   bool,
	// Reads or writes $sp (r3000 only: the r5900 decoder does not track
	// registers, so pointer_leaves is not used with it).
	sp:     bool,
}

Decode :: #type proc(pc, w: u32) -> Insn

has_delay :: proc(i: Insn) -> bool {
	return i.kind == .Branch || i.kind == .Jump || i.kind == .Call || i.kind == .Jr || i.kind == .Jalr
}

sx16 :: proc(v: u32) -> i32 {
	return i32(i16(u16(v)))
}

// w has clear every field its encoding requires to be zero, when it is a
// SPECIAL instruction: rs of a shift by a constant; sa of a variable shift or
// a register ALU op; rt, rd and sa of `jr`; rt of `jalr`; and the fields
// other than the one register of mfhi, mflo, mthi and mtlo. The decoders
// ignore these fields, but a data word that decodes as one of these
// instructions usually has one of them set.
zero_fields :: proc(w: u32) -> bool {
	if w >> 26 != 0 {
		return true
	}
	rs, rt, rd, sa := w >> 21 & 31, w >> 16 & 31, w >> 11 & 31, w >> 6 & 31
	switch w & 63 {
	case 0, 2, 3, 56, 58, 59, 60, 62, 63:
		return rs == 0
	case 4, 6, 7, 10, 11, 20, 22, 23, 32 ..= 39, 42 ..= 47:
		return sa == 0
	case 8:
		return rt == 0 && rd == 0 && sa == 0
	case 9:
		return rt == 0
	case 16, 18:
		return rs == 0 && rt == 0 && sa == 0
	case 17, 19:
		return rt == 0 && rd == 0 && sa == 0
	}
	return true
}
