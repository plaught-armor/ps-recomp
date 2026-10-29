// Native code for lowered functions: the steps emit.odin renders as Odin
// source, as machine code (options native_arch, native_out). Both run the
// same instructions in the same order, so a game can switch between them
// and compare.
//
// Runtime procedures and variables are imports by name; psx/native.odin
// lists them. A patch condition must name a bool variable there.
package r3000

import "core:slice"
import "../mips"
import "../native"

// Field offsets in cpu.Cpu; the loader checks them.
@(private = "file")
HI :: 128
@(private = "file")
LO :: 132
@(private = "file")
CYCLES :: 136

// A store calls cpu.sw (and the rest) while memory tracing watches or the
// cache is isolated (status bit 16, byte 2 bit 0 of cpu.cop0.sr).
@(private = "file", rodata)
RAM_GUARDS := [?]native.Guard{{"trace.watching", 0xff}, {"cpu.sr_isolate", 0x01}}

// RAM pages (psx/cpu/bus.odin RAM_PAGE_SHIFT).
PAGE_SHIFT :: 12

// PS1 main RAM as the bus decodes it (psx/cpu/bus.odin in_ram): 2 MiB
// mirrored below physical 0x800000. A store into a page armed for a
// checkpoint calls, so the runtime saves the page.
native_ram :: proc() -> native.Ram {
	return {
		base = "cpu.ram",
		outside = 0x1f800000,
		size = 2 * 1024 * 1024,
		pages = "cpu.ram_armed",
		page_shift = PAGE_SHIFT,
		guards = RAM_GUARDS[:],
	}
}

// The guest registers native code keeps in host registers (state offset
// 4 * n): the most used in the code it was tuned on, v0, v1, a0 and s0.
@(rodata)
NATIVE_CACHED := [?]u32{4 * 2, 4 * 3, 4 * 4, 4 * 16}

@(private = "file")
get :: proc(a: ^native.Asm, dst: native.Reg, n: u32) {
	if n == 0 {
		native.mov_imm(a, dst, 0)
	} else {
		native.state_load(a, dst, 4 * n)
	}
}

@(private = "file")
set :: proc(a: ^native.Asm, n: u32, src: native.Reg) {
	if n != 0 {
		native.state_store(a, 4 * n, src)
	}
}

// A = the address operand of load or store i.
@(private = "file")
address :: proc(a: ^native.Asm, i: Insn) {
	off := u32(sx16(i.imm))
	if i.rs == 0 {
		native.mov_imm(a, .A, off)
		return
	}
	native.state_load(a, .A, 4 * i.rs)
	if off != 0 {
		native.alu_imm(a, .Add, .A, off)
	}
}

@(private = "file")
events :: proc(a: ^native.Asm) {
	skip := native.new_label(a)
	native.br_state64_below(a, CYCLES, "cpu.next_event", skip)
	native.call(a, "io.run_events")
	native.bind(a, skip)
}

@(private = "file")
call_imm :: proc(a: ^native.Asm, name: string, v: u32) {
	native.mov_imm(a, .A, v)
	native.call(a, name, .A)
}

@(private = "file")
bad :: proc(a: ^native.Asm, i: Insn) {
	native.mov_imm(a, .A, i.pc)
	native.mov_imm(a, .B, i.w)
	native.call(a, "cpu.bad_insn", .A, .B)
}

// lo and hi = A / B and A % B (signed or not), as cpu.div and cpu.divu:
// by 0, hi is A and lo is -1 (signed: 1 when A < 0). Signed by -1, lo is
// -A and hi 0, which gives the least i32 for itself without the divide
// that traps on it.
@(private = "file")
divide :: proc(a: ^native.Asm, signed: bool) {
	zero, minus, done := native.new_label(a), native.new_label(a), native.new_label(a)
	native.br_zero(a, .B, zero)
	if signed {native.br_cmp_imm(a, .Eq, .B, 0xffffffff, minus)}
	native.div_wide(a, signed, LO, HI, .A, .B)
	native.jmp(a, done)
	if signed {
		native.bind(a, minus)
		native.mov_imm(a, .C, 0)
		native.alu(a, .Sub, .C, .A)
		native.state_store(a, LO, .C)
		native.state_store_imm(a, HI, 0)
		native.jmp(a, done)
	}
	native.bind(a, zero)
	native.state_store(a, HI, .A)
	if signed {
		// A >> 31 is 0 or -1; doubled and inverted, -1 or 1.
		native.alu_imm(a, .Sar, .A, 31)
		native.alu_imm(a, .Shl, .A, 1)
		native.not(a, .A)
		native.state_store(a, LO, .A)
	} else {
		native.state_store_imm(a, LO, 0xffffffff)
	}
	native.bind(a, done)
}

// The word at A of a fused lwl/lwr or swl/swr pair (store: the value in B),
// which need not be aligned: in place when the word is inside one RAM page,
// as cpu.lw_u and cpu.sw_u do it, else by calling them. One page keeps it
// below the end of RAM and under the store's page check.
@(private = "file")
word_u :: proc(a: ^native.Asm, store: bool) {
	slow := "cpu.sw_u" if store else "cpu.lw_u"
	split, done := native.new_label(a), native.new_label(a)
	native.mov(a, .C, .A)
	native.alu_imm(a, .And, .C, (1 << PAGE_SHIFT) - 1)
	native.br_cmp_imm(a, .Geu, .C, (1 << PAGE_SHIFT) - 3, split)
	if store {
		native.store(a, .B32, slow)
	} else {
		native.load(a, .B32, false, slow)
	}
	native.jmp(a, done)
	native.bind(a, split)
	if store {
		native.call(a, slow, .A, .B)
	} else {
		native.call(a, slow, .A)
	}
	native.bind(a, done)
}

// The instruction's result is in A: to its register, or to LD for a load
// whose slot instruction must still see the old value.
@(private = "file")
result :: proc(a: ^native.Asm, n: u32, ld: bool) {
	if ld {
		native.mov(a, .LD, .A)
	} else {
		set(a, n, .A)
	}
}

// Code for a non-control-transfer instruction, as emit_op; false for one
// that is not an instruction (emit_op's cpu.bad_insn).
@(private = "file")
op :: proc(a: ^native.Asm, i: Insn, ld := false) -> bool {
	SHIFT :: [8]native.Alu{0 = .Shl, 2 = .Shr, 3 = .Sar, 4 = .Shl, 6 = .Shr, 7 = .Sar}
	op, rs, rt, rd := i.op, i.rs, i.rt, i.rd
	switch {
	case op == 0:
		switch i.fn {
		case 0, 2, 3:
			if rd == 0 {return true}
			shift := SHIFT
			get(a, .A, rt)
			if i.sa != 0 {native.alu_imm(a, shift[i.fn], .A, i.sa)}
			result(a, rd, ld)
		case 4, 6, 7:
			if rd == 0 {return true}
			shift := SHIFT
			get(a, .A, rt)
			get(a, .B, rs)
			native.alu(a, shift[i.fn], .A, .B)
			result(a, rd, ld)
		case 16, 18:
			if rd == 0 {return true}
			native.state_load(a, .A, HI if i.fn == 16 else LO)
			result(a, rd, ld)
		case 17, 19:
			get(a, .A, rs)
			native.state_store(a, HI if i.fn == 17 else LO, .A)
		case 24, 25:
			get(a, .A, rs)
			get(a, .B, rt)
			native.mul_wide(a, i.fn == 24, LO, HI, .A, .B)
		case 26, 27:
			get(a, .A, rs)
			get(a, .B, rt)
			divide(a, i.fn == 26)
		case 32, 33, 34, 35, 36, 37, 38, 39, 42, 43:
			if rd == 0 {return true}
			get(a, .A, rs)
			get(a, .B, rt)
			switch i.fn {
			case 32, 33:
				native.alu(a, .Add, .A, .B)
			case 34, 35:
				native.alu(a, .Sub, .A, .B)
			case 36:
				native.alu(a, .And, .A, .B)
			case 37:
				native.alu(a, .Or, .A, .B)
			case 38:
				native.alu(a, .Xor, .A, .B)
			case 39:
				native.alu(a, .Or, .A, .B)
				native.not(a, .A)
			case 42:
				native.set_cond(a, .Lt, .A, .B)
			case 43:
				native.set_cond(a, .Ltu, .A, .B)
			}
			result(a, rd, ld)
		case 12:
			call_imm(a, "cpu.syscall", i.pc)
		case 13:
			native.mov_imm(a, .A, i.pc)
			native.mov_imm(a, .B, i.w >> 6 & 0xfffff)
			native.call(a, "cpu.brk", .A, .B)
		case:
			return false
		}
	case op >= 8 && op <= 15:
		if rt == 0 {return true}
		if op == 15 {
			native.mov_imm(a, .A, i.imm << 16)
			result(a, rt, ld)
			return true
		}
		get(a, .A, rs)
		simm := u32(sx16(i.imm))
		switch op {
		case 8, 9:
			if simm != 0 {native.alu_imm(a, .Add, .A, simm)}
		case 10:
			native.set_cond_imm(a, .Lt, .A, simm)
		case 11:
			native.set_cond_imm(a, .Ltu, .A, simm)
		case 12:
			native.alu_imm(a, .And, .A, i.imm)
		case 13:
			native.alu_imm(a, .Or, .A, i.imm)
		case 14:
			native.alu_imm(a, .Xor, .A, i.imm)
		}
		result(a, rt, ld)
	case op == 16:
		switch {
		case rs == 0:
			call_imm(a, "cpu.mfc0", rd)
			result(a, rt, ld)
		case rs == 4:
			native.mov_imm(a, .A, rd)
			get(a, .B, rt)
			native.call(a, "cpu.mtc0", .A, .B)
		case rs == 16 && i.fn == 16:
			native.call(a, "cpu.rfe")
		case:
			return false
		}
	case op == 18:
		switch {
		case rs == 0 || rs == 2:
			call_imm(a, "gte.gte_read", rd if rs == 0 else rd + 32)
			result(a, rt, ld)
		case rs == 4 || rs == 6:
			native.mov_imm(a, .A, rd if rs == 4 else rd + 32)
			get(a, .B, rt)
			native.call(a, "gte.gte_write", .A, .B)
		case rs & 16 != 0:
			call_imm(a, "gte.gte_cmd", i.w & 0x1ffffff)
		case:
			return false
		}
	case is_load_op(op):
		LOADS :: [7]string{"cpu.lb", "cpu.lh", "cpu.lwl", "cpu.lw", "cpu.lbu", "cpu.lhu", "cpu.lwr"}
		WIDTHS :: [7]native.Width{.B8, .B16, .B32, .B32, .B8, .B16, .B32}
		loads, widths := LOADS, WIDTHS
		address(a, i)
		if i.pair {
			word_u(a, false)
		} else if op == 0x22 || op == 0x26 {
			get(a, .B, rt)
			native.call(a, loads[op - 0x20], .A, .B)
		} else {
			native.load(a, widths[op - 0x20], op < 0x24, loads[op - 0x20])
		}
		result(a, rt, ld)
	case is_store_op(op):
		STORES :: [7]string{"cpu.sb", "cpu.sh", "cpu.swl", "cpu.sw", "", "", "cpu.swr"}
		stores := STORES
		address(a, i)
		get(a, .B, rt)
		switch {
		case i.pair:
			word_u(a, true)
		case op == 0x28:
			native.store(a, .B8, "cpu.sb")
		case op == 0x29:
			native.store(a, .B16, "cpu.sh")
		case op == 0x2b:
			native.store(a, .B32, "cpu.sw")
		case:
			native.call(a, stores[op - 0x28], .A, .B)
		}
	case op == 0x32:
		address(a, i)
		native.load(a, .B32, false, "cpu.lw")
		native.mov(a, .B, .A)
		native.mov_imm(a, .A, rt)
		native.call(a, "gte.gte_write", .A, .B)
	case op == 0x3a:
		call_imm(a, "gte.gte_read", rt)
		native.mov(a, .B, .A)
		address(a, i)
		native.store(a, .B32, "cpu.sw")
	case:
		return false
	}
	return true
}

// T = the condition of branch i, 1 or 0.
@(private = "file")
branch_cond :: proc(a: ^native.Asm, i: Insn) {
	if branch_always(i) {
		native.mov_imm(a, .T, 1)
		return
	}
	get(a, .T, i.rs)
	switch i.op {
	case 4, 5:
		get(a, .B, i.rt)
		native.set_cond(a, .Eq if i.op == 4 else .Ne, .T, .B)
	case 6:
		native.set_cond_imm(a, .Le, .T, 0)
	case 7:
		native.set_cond_imm(a, .Gt, .T, 0)
	case:
		// REGIMM
		native.set_cond_imm(a, .Ge if i.rt & 1 != 0 else .Lt, .T, 0)
	}
}

// pc = t: the block at t, or outside the function's blocks.
@(private = "file")
go :: proc(a: ^native.Asm, f: ^Func, labels: map[u32]native.Label, t: u32) {
	if l, ok := labels[t]; ok {
		native.jmp(a, l)
		return
	}
	native.mov_imm(a, .A, f.start)
	native.mov_imm(a, .B, t)
	native.call(a, "cpu.jump_unknown", .A, .B)
	native.ret(a)
}

@(private = "file")
is_ident :: proc(s: string) -> bool {
	for ch in s {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '.':
		case:
			return false
		}
	}
	return s != ""
}

// Machine code for f into a; returns its code offset.
native_func :: proc(a: ^native.Asm, f: ^Func, patches: []Patch, cycles: int) -> u32 {
	steps := lower(f, patches, cycles)
	labels: map[u32]native.Label
	defer delete(labels)
	pcs: [dynamic]u32
	defer delete(pcs)
	for s in steps {
		if s.kind == .Case {
			labels[s.target] = native.new_label(a)
			append(&pcs, s.target)
		}
	}
	slice.sort(pcs[:])
	at := native.func_begin(a, "cpu.state")
	events(a)
	go(a, f, labels, f.entry)
	// Open ifs: the label each one ends at, or -1 for a group (Branch,
	// Jump_Reg) that only scopes t.
	ifs: [dynamic]native.Label
	defer delete(ifs)
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
		case .Trace:
			skip := native.new_label(a)
			native.br_byte_clear(a, "trace.block_byte", "trace.block_bit", skip)
			call_imm(a, "cpu.trace_block", s.target)
			native.bind(a, skip)
		case .Op:
			if !op(a, s.i) {bad(a, s.i)}
		case .Load_Delay:
			ok := op(a, s.i, ld = true)
			assert(ok, "native: load delay on a non-load")
			if !op(a, s.slot) {bad(a, s.slot)}
			if s.check {set(a, s.i.rt, .LD)}
		case .Bad:
			bad(a, s.i)
		case .Cycles:
			native.state_add64(a, CYCLES, s.n)
		case .Return:
			native.ret(a)
			leaves = true
		case .Patch:
			if !is_ident(s.cond) {
				mips.fail("native: patch condition %q is not a variable", s.cond)
			}
			skip := native.new_label(a)
			native.br_byte_clear(a, s.cond, "", skip)
			append(&ifs, skip)
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
			if s.n != 0 {native.state_store_imm(a, 4 * s.n, s.target)}
		case .If_Taken:
			skip := native.new_label(a)
			native.br_zero(a, .T, skip)
			append(&ifs, skip)
		case .Call_If:
			skip := native.new_label(a)
			native.br_zero(a, .T, skip)
			call_imm(a, "cpu.call", s.target)
			native.bind(a, skip)
		case .Jump_Reg:
			get(a, .T, s.n)
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
		native.mov_imm(a, .A, f.start)
		native.mov(a, .B, .T)
		native.call(a, "cpu.jump_unknown", .A, .B)
		native.ret(a)
	}
	return u32(at)
}
