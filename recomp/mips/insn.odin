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
