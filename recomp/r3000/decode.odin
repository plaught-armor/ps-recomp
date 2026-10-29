// The R3000A (PS1 CPU) backend: decoding, and Odin source for the psx
// runtime (`cpu.state`, `cpu.lw`, ...).
package r3000

import "../mips"

Kind :: mips.Kind

// Registers an instruction reads or writes; HILO stands for hi and lo.
HILO :: 32
Regs :: bit_set[0 ..= 32;u64]

Insn :: struct {
	pc, w, target:              u32,
	op, rs, rt, rd, sa, fn, imm: u32,
	kind:                       Kind,
	reads, writes:              Regs,
	is_load:                    bool,
}

is_load_op :: proc(op: u32) -> bool {
	return op >= 0x20 && op <= 0x26
}

is_store_op :: proc(op: u32) -> bool {
	return op == 0x28 || op == 0x29 || op == 0x2a || op == 0x2b || op == 0x2e
}

decode :: proc(pc, w: u32) -> Insn {
	i := Insn {
		pc  = pc,
		w   = w,
		op  = w >> 26,
		rs  = w >> 21 & 31,
		rt  = w >> 16 & 31,
		rd  = w >> 11 & 31,
		sa  = w >> 6 & 31,
		fn  = w & 63,
		imm = w & 0xffff,
	}
	op, rs, rt, rd := i.op, i.rs, i.rt, i.rd
	switch {
	case op == 0:
		switch i.fn {
		case 0, 2, 3:
			i.reads, i.writes = {int(rt)}, {int(rd)}
		case 4, 6, 7:
			i.reads, i.writes = {int(rs), int(rt)}, {int(rd)}
		case 8:
			i.kind, i.reads = .Jr, {int(rs)}
		case 9:
			i.kind, i.reads, i.writes = .Jalr, {int(rs)}, {int(rd)}
		case 12, 13:
			i.kind = .Sys
		case 16, 18:
			i.reads, i.writes = {HILO}, {int(rd)}
		case 17, 19:
			i.reads, i.writes = {int(rs)}, {HILO}
		case 24, 25, 26, 27:
			i.reads, i.writes = {int(rs), int(rt)}, {HILO}
		case 32 ..= 39, 42, 43:
			i.reads, i.writes = {int(rs), int(rt)}, {int(rd)}
		case:
			i.kind = .Bad
		}
	case op == 1:
		if rt & 0x1e == 0x10 || rt == 0 || rt == 1 {
			i.kind, i.reads = .Branch, {int(rs)}
			i.target = pc + 4 + u32(mips.sx16(i.imm) << 2)
			if rt & 0x1e == 0x10 {
				i.writes = {31}
			}
		} else {
			i.kind = .Bad
		}
	case op == 2 || op == 3:
		i.kind = op == 2 ? .Jump : .Call
		i.target = (pc + 4) & 0xf0000000 | (w & 0x3ffffff) << 2
		if op == 3 {
			i.writes = {31}
		}
	case op >= 4 && op <= 7:
		i.kind = .Branch
		i.reads = op <= 5 ? {int(rs), int(rt)} : {int(rs)}
		i.target = pc + 4 + u32(mips.sx16(i.imm) << 2)
	case op >= 8 && op <= 14:
		i.reads, i.writes = {int(rs)}, {int(rt)}
	case op == 15:
		i.writes = {int(rt)}
	case op == 16:
		switch {
		case rs == 0:
			i.writes, i.is_load = {int(rt)}, true
		case rs == 4:
			i.reads = {int(rt)}
		case rs == 16 && i.fn == 16:
		case:
			i.kind = .Bad
		}
	case op == 18:
		switch {
		case rs == 0 || rs == 2:
			i.writes, i.is_load = {int(rt)}, true
		case rs == 4 || rs == 6:
			i.reads = {int(rt)}
		case rs & 16 != 0:
		case:
			i.kind = .Bad
		}
	case is_load_op(op):
		i.reads = {int(rs)}
		if op == 0x22 || op == 0x26 {
			i.reads += {int(rt)}
		}
		i.writes, i.is_load = {int(rt)}, true
	case is_store_op(op):
		i.reads = {int(rs), int(rt)}
	case op == 0x32 || op == 0x3a:
		i.reads = {int(rs)}
	case:
		i.kind = .Bad
	}
	i.reads -= {0}
	i.writes -= {0}
	return i
}

has_delay :: proc(i: Insn) -> bool {
	return i.kind == .Branch || i.kind == .Jump || i.kind == .Call || i.kind == .Jr || i.kind == .Jalr
}

// `break 1` after main: never returns.
is_break_1 :: proc(i: Insn) -> bool {
	return i.kind == .Sys && i.fn == 13 && i.w >> 6 & 0xfffff == 1
}

// What function discovery needs of an instruction.
front :: proc(pc, w: u32) -> mips.Insn {
	i := decode(pc, w)
	return {
		pc = pc,
		w = w,
		target = i.target,
		kind = i.kind,
		rs = u8(i.rs),
		halt = is_break_1(i),
		sp = 29 in (i.reads + i.writes),
	}
}

RULES :: mips.Rules {
	decode        = front,
	lead          = .Global_Loads,
	label_dropped = true,
	ram           = {0x80000000, 0x80200000},
}
