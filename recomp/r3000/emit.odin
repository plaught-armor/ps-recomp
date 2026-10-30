package r3000

import "core:fmt"
import "core:slice"
import "core:strings"
import "../mips"

Func :: mips.Func
Set :: mips.Set
hexu :: mips.hexu
line :: mips.line
concat :: mips.concat
inside :: mips.inside
sx16 :: mips.sx16

// ---------------------------------------------------------------- emission

@(private = "file")
R :: proc(n: u32) -> string {
	return n == 0 ? "0" : fmt.aprintf("c.r[%d]", n)
}

@(private = "file")
signed_hex :: proc(base: string, off: i32) -> string {
	return fmt.aprintf("%s %s 0x%x", base, off > 0 ? "+" : "-", abs(off))
}

@(private = "file")
addr_expr :: proc(i: Insn) -> string {
	off := sx16(i.imm)
	switch {
	case off == 0:
		return R(i.rs)
	case i.rs == 0:
		return hexu(u32(off))
	}
	return signed_hex(R(i.rs), off)
}

@(private = "file")
set_reg :: proc(rd: u32, expr: string, side_effect := false) -> []string {
	if rd == 0 {
		return side_effect ? slice.clone([]string{fmt.aprintf("_ = %s", expr)}) : nil
	}
	return slice.clone([]string{fmt.aprintf("c.r[%d] = %s", rd, expr)})
}

@(private = "file")
one :: proc(format: string, args: ..any) -> []string {
	return slice.clone([]string{fmt.aprintf(format, ..args)})
}

// Odin statements for a non-control-transfer instruction.
@(private = "file")
emit_op :: proc(i: Insn) -> []string {
	op, rs, rt, rd, sa := i.op, i.rs, i.rt, i.rd, i.sa
	f :: fmt.aprintf
	switch {
	case op == 0:
		switch i.fn {
		case 0:
			return sa != 0 ? set_reg(rd, f("%s << %d", R(rt), sa)) : set_reg(rd, R(rt))
		case 2:
			return set_reg(rd, f("%s >> %d", R(rt), sa))
		case 3:
			return set_reg(rd, f("u32(i32(%s) >> %d)", R(rt), sa))
		case 4:
			return set_reg(rd, f("%s << (%s & 31)", R(rt), R(rs)))
		case 6:
			return set_reg(rd, f("%s >> (%s & 31)", R(rt), R(rs)))
		case 7:
			return set_reg(rd, f("u32(i32(%s) >> (%s & 31))", R(rt), R(rs)))
		case 16:
			return set_reg(rd, "c.hi")
		case 17:
			return one("c.hi = %s", R(rs))
		case 18:
			return set_reg(rd, "c.lo")
		case 19:
			return one("c.lo = %s", R(rs))
		case 24:
			return one("cpu.mult(%s, %s)", R(rs), R(rt))
		case 25:
			return one("cpu.multu(%s, %s)", R(rs), R(rt))
		case 26:
			return one("cpu.div(%s, %s)", R(rs), R(rt))
		case 27:
			return one("cpu.divu(%s, %s)", R(rs), R(rt))
		case 32, 33, 37:
			switch {
			case rt == 0:
				return set_reg(rd, R(rs))
			case rs == 0:
				return set_reg(rd, R(rt))
			}
			return set_reg(rd, f("%s %s %s", R(rs), i.fn == 37 ? "|" : "+", R(rt)))
		case 34, 35:
			return set_reg(rd, f("%s - %s", R(rs), R(rt)))
		case 36:
			return set_reg(rd, f("%s & %s", R(rs), R(rt)))
		case 38:
			return set_reg(rd, f("%s ~ %s", R(rs), R(rt)))
		case 39:
			if rs == 0 && rt == 0 {
				return set_reg(rd, "0xffffffff") // ~ of an untyped 0 fails to build
			}
			return set_reg(rd, f("~(%s | %s)", R(rs), R(rt)))
		case 42:
			return set_reg(rd, f("i32(%s) < i32(%s) ? 1 : 0", R(rs), R(rt)))
		case 43:
			return set_reg(rd, f("%s < %s ? 1 : 0", R(rs), R(rt)))
		case 12:
			return one("cpu.syscall(%s)", hexu(i.pc))
		case 13:
			return one("cpu.brk(%s, 0x%x)", hexu(i.pc), i.w >> 6 & 0xfffff)
		}
	case op == 8 || op == 9:
		imm := sx16(i.imm)
		switch {
		case rs == 0:
			return set_reg(rt, hexu(u32(imm)))
		case imm == 0:
			return set_reg(rt, R(rs))
		}
		return set_reg(rt, signed_hex(R(rs), imm))
	case op == 10:
		return set_reg(rt, f("i32(%s) < %d ? 1 : 0", R(rs), sx16(i.imm)))
	case op == 11:
		return set_reg(rt, f("%s < %s ? 1 : 0", R(rs), hexu(u32(sx16(i.imm)))))
	case op == 12:
		return set_reg(rt, f("%s & 0x%x", R(rs), i.imm))
	case op == 13:
		if rs == 0 {
			return set_reg(rt, f("0x%x", i.imm))
		}
		return set_reg(rt, f("%s | 0x%x", R(rs), i.imm))
	case op == 14:
		return set_reg(rt, f("%s ~ 0x%x", R(rs), i.imm))
	case op == 15:
		return set_reg(rt, hexu(i.imm << 16))
	case op == 16:
		switch {
		case rs == 0:
			return set_reg(rt, f("cpu.mfc0(%d)", rd))
		case rs == 4:
			return one("cpu.mtc0(%d, %s)", rd, R(rt))
		case rs == 16 && i.fn == 16:
			return one("cpu.rfe()")
		}
	case op == 18:
		switch {
		case rs == 0 || rs == 2:
			r := rs == 0 ? rd : rd + 32
			return set_reg(rt, gte_get(r))
		case rs == 4 || rs == 6:
			return one("%s, %s)", gte_put(rs == 4 ? rd : rd + 32), R(rt))
		case rs & 16 != 0:
			return one(gte_cmd_call(i.w & 0x1ffffff))
		}
	case is_load_op(op):
		a := addr_expr(i)
		if i.pair {
			return set_reg(rt, f("cpu.lw_u(%s)", a), true)
		}
		switch op {
		case 0x22, 0x26:
			return set_reg(rt, f("cpu.%s(%s, %s)", op == 0x22 ? "lwl" : "lwr", a, R(rt)), true)
		}
		names := [7]string{"lb", "lh", "", "lw", "lbu", "lhu", ""}
		return set_reg(rt, f("cpu.%s(%s)", names[op - 0x20], a), true)
	case is_store_op(op):
		names := [7]string{"sb", "sh", "swl", "sw", "", "", "swr"}
		return one("cpu.%s(%s, %s)", "sw_u" if i.pair else names[op - 0x28], addr_expr(i), R(rt))
	case op == 0x32:
		return one("%s, cpu.lw(%s))", gte_put(rt), addr_expr(i))
	case op == 0x3a:
		return one("cpu.sw(%s, %s)", addr_expr(i), gte_get(rt))
	}
	return one("cpu.bad_insn(%s, %s)", hexu(i.pc), hexu(i.w))
}

// The call for GTE command cmd: NCLIP, AVSZ3 and AVSZ4, small and without
// the shift or lm bit, through their inline procs; RTPS, RTPT and MVMVA
// through their own procs, given the command word; the rest through
// gte.gte_cmd.
@(private = "file")
gte_cmd_call :: proc(cmd: u32) -> string {
	switch cmd & 0x3f {
	case 0x06:
		return "gte.cmd_nclip()"
	case 0x2d:
		return "gte.cmd_avsz3()"
	case 0x2e:
		return "gte.cmd_avsz4()"
	case 0x01:
		return fmt.aprintf("gte.cmd_rtps(0x%x)", cmd)
	case 0x30:
		return fmt.aprintf("gte.cmd_rtpt(0x%x)", cmd)
	case 0x12:
		return fmt.aprintf("gte.cmd_mvmva(0x%x)", cmd)
	}
	return fmt.aprintf("gte.gte_cmd(0x%x)", cmd)
}

// A read of GTE register r (control registers as 32-63), inline through
// gte.data_read or gte.ctrl_read.
@(private = "file")
gte_get :: proc(r: u32) -> string {
	return fmt.aprintf("gte.%s(%d)", r < 32 ? "data_read" : "ctrl_read", r)
}

// The open call that writes GTE register r, to be closed with the value and
// ")": inline through gte.data_write or gte.ctrl_write.
@(private = "file")
gte_put :: proc(r: u32) -> string {
	return fmt.aprintf("gte.%s(%d", r < 32 ? "data_write" : "ctrl_write", r)
}

@(private = "file")
branch_cond :: proc(i: Insn) -> string {
	switch i.op {
	case 4:
		if i.rs == i.rt {
			return "true"
		}
		return fmt.aprintf("%s == %s", R(i.rs), R(i.rt))
	case 5:
		return fmt.aprintf("%s != %s", R(i.rs), R(i.rt))
	case 6:
		return fmt.aprintf("i32(%s) <= 0", R(i.rs))
	case 7:
		return fmt.aprintf("i32(%s) > 0", R(i.rs))
	}
	// REGIMM
	if i.rt & 1 != 0 {
		return fmt.aprintf("i32(%s) >= 0", R(i.rs))
	}
	return fmt.aprintf("i32(%s) < 0", R(i.rs))
}

// Patch points (the patches table): before the instruction at the address,
// when the Odin condition holds, go to the target (a label in the same
// function) instead. For changes inside a function that a whole-function
// hook cannot reach.
Patch :: struct {
	at:     u32,
	cond:   string,
	target: u32,
}

// Per-block hook for <prefix>TRACE=block; one bit test when tracing is off.
@(private = "file")
trace_stmt :: proc(pc: u32) -> string {
	return fmt.aprintf("if .Block in core.trace.active {{cpu.trace_block(%s)}}", hexu(pc))
}

// Odin source for a lowered function: one switch case per block.
emit_func :: proc(f: ^Func, out: ^strings.Builder, name: string, patches: []Patch, cycles: int) {
	line(out, "%s :: proc() {{", name)
	line(out, "\tc := &cpu.state")
	line(out, "\tif c.cycles >= cpu.next_event {io.run_events()}")
	line(out, "\tpc: u32 = %s", hexu(f.entry))
	line(out, "\tfor {")
	line(out, "\t\tswitch pc {")
	// Statements inside a Patch or If_Taken are indented one more level.
	ifs: [dynamic]bool
	defer delete(ifs)
	depth := 0
	put :: proc(out: ^strings.Builder, depth: int, s: string) {
		strings.write_string(out, "\t\t\t")
		for _ in 0 ..< depth {
			strings.write_byte(out, '\t')
		}
		strings.write_string(out, s)
		strings.write_byte(out, '\n')
	}
	for s in lower(f, patches, cycles) {
		switch s.kind {
		case .Case:
			if s.check {
				put(out, depth, "fallthrough")
			}
			line(out, "\t\tcase %s:", hexu(s.target))
		case .Trace:
			put(out, depth, trace_stmt(s.target))
		case .Op:
			for st in emit_op(s.i) {
				put(out, depth, st)
			}
		case .Load_Delay:
			stmts := emit_op(s.i)
			_, _, expr := strings.partition(stmts[0], " = ")
			put(out, depth, "{")
			put(out, depth, concat("ld := ", expr))
			for st in emit_op(s.slot) {
				put(out, depth, st)
			}
			if s.check {
				put(out, depth, fmt.aprintf("c.r[%d] = ld", s.i.rt))
			} else {
				put(out, depth, "_ = ld")
			}
			put(out, depth, "}")
		case .Bad:
			put(out, depth, fmt.aprintf("cpu.bad_insn(%s, %s)", hexu(s.i.pc), hexu(s.i.w)))
		case .Cycles:
			put(out, depth, fmt.aprintf("c.cycles += %d", s.n))
		case .Return:
			put(out, depth, "return")
		case .Patch:
			put(out, depth, fmt.aprintf("if %s {{", s.cond))
			append(&ifs, true)
			depth += 1
		case .Goto:
			put(out, depth, fmt.aprintf("pc = %s", hexu(s.target)))
			if s.check {
				put(out, depth, "if c.cycles >= cpu.next_event {io.run_events()}")
			}
			put(out, depth, "continue")
		case .Call:
			put(out, depth, fmt.aprintf("cpu.call(%s)", hexu(s.target)))
		case .Branch:
			put(out, depth, "{")
			put(out, depth, concat("t := ", branch_cond(s.i)))
			append(&ifs, false)
		case .Link:
			put(out, depth, fmt.aprintf("c.r[%d] = %s", s.n, hexu(s.target)))
		case .If_Taken:
			put(out, depth, "if t {")
			append(&ifs, true)
			depth += 1
		case .Call_If:
			put(out, depth, fmt.aprintf("if t {{cpu.call(%s)}}", hexu(s.target)))
		case .Jump_Reg:
			put(out, depth, "{")
			put(out, depth, fmt.aprintf("t: u32 = %s", R(s.n)))
			append(&ifs, false)
		case .Call_Reg:
			put(out, depth, "cpu.call(t)")
		case .Goto_Reg:
			put(out, depth, "pc = t")
			put(out, depth, "if c.cycles >= cpu.next_event {io.run_events()}")
			put(out, depth, "continue")
		case .End:
			if pop(&ifs) {
				depth -= 1
			}
			put(out, depth, "}")
		}
	}
	line(out, "\t\tcase:")
	line(out, "\t\t\tcpu.jump_unknown(%s, pc)", hexu(f.start))
	line(out, "\t\t\treturn")
	line(out, "\t\t}")
	line(out, "\t}")
	line(out, "}")
	line(out, "")
}
