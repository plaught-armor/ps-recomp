// Native code for lowered functions: the steps emit.odin renders as Odin
// source, as machine code (options native_arch, native_out). Both run the
// same instructions in the same order, so a game can switch between them
// and compare.
//
// Runtime procedures and variables are imports by name; psx/native
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
// checkpoint calls, so the runtime saves the page. The 1K scratchpad is
// the window, at physical 0x1f800000 in every segment as the bus has it
// (load_slow, store_slow).
native_ram :: proc() -> native.Ram {
	return {
		base = "cpu.ram",
		outside = 0x1f800000,
		size = 2 * 1024 * 1024,
		pages = "cpu.ram_armed",
		page_shift = PAGE_SHIFT,
		guards = RAM_GUARDS[:],
		window = "cpu.scratch",
		window_mask = 0x1fffffff,
		window_at = 0x1f800000,
		window_size = 1024,
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

// Field offsets in gte.Gte, through import gte.state; the loader checks
// them. V0-V2 are 6 bytes apart (xy, then z at 4).
@(private = "file")
GTE_RGBC :: 18
@(private = "file")
GTE_OTZ :: 22
@(private = "file")
GTE_IR :: 24
@(private = "file")
GTE_SXY :: 40
@(private = "file")
GTE_SZ :: 64
@(private = "file")
GTE_RGB :: 80
@(private = "file")
GTE_RES1 :: 92
@(private = "file")
GTE_MAC :: 96
@(private = "file")
GTE_LZCS :: 112
@(private = "file")
GTE_LZCR :: 116
@(private = "file")
GTE_ZSF3 :: 284
@(private = "file")
GTE_ZSF4 :: 288
@(private = "file")
GTE_FLAG :: 292

// Where control register r, 32-62, is in gte.Gte, and how it maps: a
// matrix field pair (16 bits each in the register), a field written as 16
// bits masked (H) or sign-extended, or a word.
@(private = "file")
Ctrl :: struct {
	off:  u32,
	kind: enum u8 {
		Word,
		Pair,
		Half, // H: written masked, read sign-extended
		Short, // a matrix's last field, DQA, ZSF3, ZSF4: written sign-extended
	},
}

@(private = "file")
gte_ctrl :: proc(r: u32) -> Ctrl {
	switch r {
	case 32 ..= 55:
		// RT, LLM and LCM at 120, 156 and 192, five registers each; TR,
		// BK and FC at 228, 240 and 252, three each.
		n := (r - 32) / 8
		k := (r - 32) % 8
		if k < 5 {return {120 + 36 * n + 8 * k, .Pair if k < 4 else .Short}}
		return {228 + 12 * n + 4 * (k - 5), .Word}
	case 58:
		return {272, .Half}
	case 59, 61, 62:
		return {264 + 4 * (r - 56), .Short}
	}
	return {264 + 4 * (r - 56), .Word} // OFX, OFY, DQB
}

// The proc for GTE command w but NCLIP, AVSZ3 and AVSZ4: RTPS, RTPT and MVMVA their own,
// as in the Odin output; the rest gte.gte_cmd.
@(private = "file")
gte_cmd_proc :: proc(w: u32) -> string {
	switch w & 0x3f {
	case 0x01:
		return "gte.cmd_rtps"
	case 0x30:
		return "gte.cmd_rtpt"
	case 0x12:
		return "gte.cmd_mvmva"
	}
	return "gte.gte_cmd"
}

// NCLIP, as gte.gte_cmd: MAC0 = SX0*SY1 + SX1*SY2 + SX2*SY0 - SX0*SY2 -
// SX1*SY0 - SX2*SY1, summed in 64 bits; FLAG = 0, or bit 16 for a sum above
// i32 (bit 15 below) with bit 31. Loses A, B and C.
@(private = "file")
nclip :: proc(a: ^native.Asm) {
	Term :: struct {
		x, y: u32, // SXY entries: SX of x times SY of y
		op:   native.Mac,
	}
	TERMS :: [6]Term{{0, 1, .Set}, {1, 2, .Add}, {2, 0, .Add}, {0, 2, .Sub}, {1, 0, .Sub}, {2, 1, .Sub}}
	for t in TERMS {
		native.imp_load(a, .B, "gte.state", GTE_SXY + 8 * t.x)
		native.imp_load(a, .C, "gte.state", GTE_SXY + 8 * t.y + 4)
		native.mac64(a, t.op, .B, .C)
	}
	native.mac64_split(a, .B)
	native.imp_store(a, "gte.state", .A, GTE_MAC)
	// The sum fits i32 when its high half is the low half's sign.
	store := native.new_label(a)
	native.mov(a, .C, .A)
	native.alu_imm(a, .Sar, .C, 31)
	native.alu(a, .Xor, .C, .B)
	native.mov_imm(a, .A, 0)
	native.br_zero(a, .C, store)
	native.mov_imm(a, .A, 0x80010000)
	native.br_cmp_imm(a, .Ge, .B, 0, store)
	native.mov_imm(a, .A, 0x80008000)
	native.bind(a, store)
	native.imp_store(a, "gte.state", .A, GTE_FLAG)
}

// AVSZ3 (SZ1-3, scale ZSF3) or AVSZ4 (SZ0-3, ZSF4), as gte.gte_cmd: MAC0 =
// the scale times the sum (SZ unsigned, the scale signed), in 64 bits; OTZ = MAC0 >> 12 held to 0-0xffff.
// FLAG = bit 16 for a sum above i32 (bit 15 below), bit 18 for OTZ held,
// with bit 31 for either. Loses A, B and C.
@(private = "file")
avsz :: proc(a: ^native.Asm, scale: u32, first: u32) {
	native.imp_load(a, .B, "gte.state", scale)
	for k in first ..< 4 {
		native.imp_load(a, .C, "gte.state", GTE_SZ + 4 * k)
		native.mac64(a, .Set if k == first else .Add, .B, .C)
	}
	native.mac64_split(a, .B)
	// SZ is unsigned: the scale << 32 more for each with bit 31 set.
	for k in first ..< 4 {
		next := native.new_label(a)
		native.imp_load(a, .C, "gte.state", GTE_SZ + 4 * k)
		native.br_cmp_imm(a, .Ge, .C, 0, next)
		native.imp_load(a, .C, "gte.state", scale)
		native.alu(a, .Add, .B, .C)
		native.bind(a, next)
	}
	native.imp_store(a, "gte.state", .A, GTE_MAC)
	// The sum fits i32 when its high half is the low half's sign.
	fits, otz, held, store := native.new_label(a), native.new_label(a), native.new_label(a), native.new_label(a)
	native.mov(a, .C, .A)
	native.alu_imm(a, .Sar, .C, 31)
	native.alu(a, .Xor, .C, .B)
	native.br_zero(a, .C, fits)
	native.mov_imm(a, .C, 0x80010000)
	native.br_cmp_imm(a, .Ge, .B, 0, otz)
	native.mov_imm(a, .C, 0x80008000)
	native.jmp(a, otz)
	native.bind(a, fits)
	native.mov_imm(a, .C, 0)
	native.bind(a, otz)
	// Below 0 holds at 0; at 1 << 28 or above, at 0xffff.
	low := native.new_label(a)
	native.br_cmp_imm(a, .Lt, .B, 0, low)
	native.br_zero(a, .B, held, true)
	native.br_cmp_imm(a, .Geu, .A, 0x10000000, held)
	native.alu_imm(a, .Shr, .A, 12)
	native.jmp(a, store)
	native.bind(a, low)
	native.mov_imm(a, .A, 0)
	native.alu_imm(a, .Or, .C, 0x80040000)
	native.jmp(a, store)
	native.bind(a, held)
	native.mov_imm(a, .A, 0xffff)
	native.alu_imm(a, .Or, .C, 0x80040000)
	native.bind(a, store)
	native.imp_store(a, "gte.state", .A, GTE_OTZ, .B16)
	native.imp_store(a, "gte.state", .C, GTE_FLAG)
}

// A = GTE register r (control registers as 32-63), as gte.gte_read: a
// field load, or for IRGB and ORGB the IR1-3 packed. Loses B and C.
@(private = "file")
gte_get :: proc(a: ^native.Asm, r: u32) {
	switch r {
	case 0, 2, 4:
		native.imp_load(a, .A, "gte.state", 6 * (r / 2))
	case 1, 3, 5:
		native.imp_load(a, .A, "gte.state", 6 * (r / 2) + 4, .B16, true)
	case 6:
		native.imp_load(a, .A, "gte.state", GTE_RGBC)
	case 7:
		native.imp_load(a, .A, "gte.state", GTE_OTZ, .B16)
	case 8 ..= 11:
		native.imp_load(a, .A, "gte.state", GTE_IR + 4 * (r - 8))
	case 12 ..= 15:
		// SXY2 for SXYP. The low 16 bits of x and of y, packed.
		pair_get(a, GTE_SXY + 8 * (min(r, 14) - 12))
	case 16 ..= 19:
		native.imp_load(a, .A, "gte.state", GTE_SZ + 4 * (r - 16))
	case 20 ..= 22:
		native.imp_load(a, .A, "gte.state", GTE_RGB + 4 * (r - 20))
	case 23:
		native.imp_load(a, .A, "gte.state", GTE_RES1)
	case 24 ..= 27:
		native.imp_load(a, .A, "gte.state", GTE_MAC + 4 * (r - 24))
	case 28, 29:
		// IR1-3, each >> 7 and held to 0-31, five bits apiece.
		native.mov_imm(a, .A, 0)
		for k in u32(0) ..< 3 {
			low, done := native.new_label(a), native.new_label(a)
			native.imp_load(a, .C, "gte.state", GTE_IR + 4 * (k + 1))
			native.alu_imm(a, .Sar, .C, 7)
			native.br_cmp_imm(a, .Ge, .C, 0, low)
			native.mov_imm(a, .C, 0)
			native.bind(a, low)
			native.br_cmp_imm(a, .Le, .C, 0x1f, done)
			native.mov_imm(a, .C, 0x1f)
			native.bind(a, done)
			if k > 0 {native.alu_imm(a, .Shl, .C, 5 * k)}
			native.alu(a, .Or, .A, .C)
		}
	case 30:
		native.imp_load(a, .A, "gte.state", GTE_LZCS)
	case 31:
		native.imp_load(a, .A, "gte.state", GTE_LZCR)
	case 63:
		native.imp_load(a, .A, "gte.state", GTE_FLAG)
	case:
		c := gte_ctrl(r)
		switch c.kind {
		case .Pair:
			pair_get(a, c.off)
		case .Half:
			native.imp_load(a, .A, "gte.state", c.off, .B16, true)
		case .Word, .Short:
			native.imp_load(a, .A, "gte.state", c.off)
		}
	}
}

// A = the low 16 bits of the i32 fields at off and off + 4, packed.
@(private = "file")
pair_get :: proc(a: ^native.Asm, off: u32) {
	native.imp_load(a, .A, "gte.state", off)
	native.alu_imm(a, .And, .A, 0xffff)
	native.imp_load(a, .C, "gte.state", off + 4)
	native.alu_imm(a, .Shl, .C, 16)
	native.alu(a, .Or, .A, .C)
}

// The i32 fields at off and off + 4 = the sign-extended low and high 16
// bits of v. Loses v and C.
@(private = "file")
pair_put :: proc(a: ^native.Asm, off: u32, v: native.Reg) {
	native.mov(a, .C, v)
	native.alu_imm(a, .Shl, .C, 16)
	native.alu_imm(a, .Sar, .C, 16)
	native.imp_store(a, "gte.state", .C, off)
	native.alu_imm(a, .Sar, v, 16)
	native.imp_store(a, "gte.state", v, off + 4)
}

// GTE register r = v (A or B), as gte.gte_write: field stores, SXYP's push
// of the FIFO and LZCS's count among them. A rotation or translation
// register calls gte.gte_write while gte.gte_matrix_filter is set. Loses A,
// B and C.
@(private = "file")
gte_put :: proc(a: ^native.Asm, r: u32, v: native.Reg) {
	switch r {
	case 0, 2, 4:
		native.imp_store(a, "gte.state", v, 6 * (r / 2))
	case 1, 3, 5:
		native.imp_store(a, "gte.state", v, 6 * (r / 2) + 4, .B16)
	case 6:
		native.imp_store(a, "gte.state", v, GTE_RGBC)
	case 7:
		native.imp_store(a, "gte.state", v, GTE_OTZ, .B16)
	case 8 ..= 11:
		native.alu_imm(a, .Shl, v, 16)
		native.alu_imm(a, .Sar, v, 16)
		native.imp_store(a, "gte.state", v, GTE_IR + 4 * (r - 8))
	case 12 ..= 14:
		// x and y, each the sign-extended 16 bits.
		pair_put(a, GTE_SXY + 8 * (r - 12), v)
	case 15:
		// SXY0 = SXY1, SXY1 = SXY2, then SXY2 as for 14.
		for off in u32(0) ..< 4 {
			native.imp_load(a, .C, "gte.state", GTE_SXY + 4 * off + 8)
			native.imp_store(a, "gte.state", .C, GTE_SXY + 4 * off)
		}
		pair_put(a, GTE_SXY + 16, v)
	case 16 ..= 19:
		native.alu_imm(a, .And, v, 0xffff)
		native.imp_store(a, "gte.state", v, GTE_SZ + 4 * (r - 16))
	case 20 ..= 22:
		native.imp_store(a, "gte.state", v, GTE_RGB + 4 * (r - 20))
	case 23:
		native.imp_store(a, "gte.state", v, GTE_RES1)
	case 24 ..= 27:
		native.imp_store(a, "gte.state", v, GTE_MAC + 4 * (r - 24))
	case 28:
		// IR1-3 = five bits apiece << 7.
		for k in u32(0) ..< 3 {
			native.mov(a, .C, v)
			if k > 0 {native.alu_imm(a, .Shr, .C, 5 * k)}
			native.alu_imm(a, .And, .C, 0x1f)
			native.alu_imm(a, .Shl, .C, 7)
			native.imp_store(a, "gte.state", .C, GTE_IR + 4 * (k + 1))
		}
	case 29, 31:
	// read-only
	case 30:
		// LZCR: the leading bits equal to the sign bit.
		native.imp_store(a, "gte.state", v, GTE_LZCS)
		native.mov(a, .C, v)
		native.alu_imm(a, .Sar, .C, 31)
		native.alu(a, .Xor, .C, v)
		native.clz(a, .C)
		native.imp_store(a, "gte.state", .C, GTE_LZCR)
	case 63:
		// Bit 31 is set when any of bits 13-18 and 23-30 is.
		store := native.new_label(a)
		native.alu_imm(a, .And, v, 0x7ffff000)
		native.mov(a, .C, v)
		native.alu_imm(a, .And, .C, 0x7f87e000)
		native.br_zero(a, .C, store)
		native.alu_imm(a, .Or, v, 0x80000000)
		native.bind(a, store)
		native.imp_store(a, "gte.state", v, GTE_FLAG)
	case:
		done := native.new_label(a)
		if r <= 39 {
			// The filter's address, both halves, is not zero: the call.
			other: native.Reg = .A if v == .B else .B
			inline := native.new_label(a)
			native.imp_load(a, .C, "gte.matrix_filter")
			native.imp_load(a, other, "gte.matrix_filter", 4)
			native.alu(a, .Or, .C, other)
			native.br_zero(a, .C, inline)
			if v != .B {native.mov(a, .B, v)}
			native.mov_imm(a, .A, r)
			native.call(a, "gte.gte_write", .A, .B)
			native.jmp(a, done)
			native.bind(a, inline)
		}
		c := gte_ctrl(r)
		switch c.kind {
		case .Pair:
			pair_put(a, c.off, v)
		case .Half:
			native.alu_imm(a, .And, v, 0xffff)
			native.imp_store(a, "gte.state", v, c.off)
		case .Short:
			native.alu_imm(a, .Shl, v, 16)
			native.alu_imm(a, .Sar, v, 16)
			native.imp_store(a, "gte.state", v, c.off)
		case .Word:
			native.imp_store(a, "gte.state", v, c.off)
		}
		native.bind(a, done)
	}
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
			// As cpu.mfc0: SR, Cause and EPC, PRId 2, the rest 0.
			switch rd {
			case 12 ..= 14:
				native.imp_load(a, .A, "cpu.cop0", 4 * (rd - 12))
			case 15:
				native.mov_imm(a, .A, 2)
			case:
				native.mov_imm(a, .A, 0)
			}
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
			gte_get(a, rd if rs == 0 else rd + 32)
			result(a, rt, ld)
		case rs == 4 || rs == 6:
			get(a, .B, rt)
			gte_put(a, rd if rs == 4 else rd + 32, .B)
		case rs & 16 != 0 && i.w & 0x3f == 0x06:
			nclip(a)
		case rs & 16 != 0 && i.w & 0x3f == 0x2d:
			avsz(a, GTE_ZSF3, 1)
		case rs & 16 != 0 && i.w & 0x3f == 0x2e:
			avsz(a, GTE_ZSF4, 0)
		case rs & 16 != 0:
			call_imm(a, gte_cmd_proc(i.w), i.w & 0x1ffffff)
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
		gte_put(a, rt, .A)
	case op == 0x3a:
		gte_get(a, rt)
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
