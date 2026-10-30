// x86-64 encoding of the operations in asm.odin, for System V and Windows.
//
// rbx holds the guest state address and r12 the context pointer; T and LD
// live in r13d and r14d, which both ABIs keep across calls. With guest RAM,
// r15 holds its address and rbp that of its page bytes. A, B and C are
// eax, r10d and r11d: none is an argument register in either ABI, so moving
// arguments never overwrites one. rcx and rdx are temporaries inside one
// operation. The cached state fields live in esi, edi, r8d and r9d, which
// only the cache moves touch: a call's arguments overwrite them after they
// are written back. Windows keeps rsi and rdi across calls, so a function
// with cached fields saves them.
package native

@(private = "file", rodata)
X64_REG := [Reg]u8{
	.A  = 0,
	.B  = 10,
	.C  = 11,
	.T  = 13,
	.LD = 14,
}

@(private = "file", rodata)
X64_CACHE := [CACHE_MAX]u8{6, 7, 8, 9}

@(private = "file")
RCX :: 1
@(private = "file")
RDX :: 2
@(private = "file")
RBX :: 3
@(private = "file")
RBP :: 5
@(private = "file")
R12 :: 12
@(private = "file")
R15 :: 15

@(private = "file", rodata)
SYSV_ARGS := [4]u8{7, 6, 2, 1} // rdi rsi rdx rcx
@(private = "file", rodata)
WIN_ARGS := [4]u8{1, 2, 8, 9} // rcx rdx r8 r9

// Prologue pushes four registers (six with RAM, and two more on Windows with
// cached fields) onto a stack that was 8 off alignment; this keeps calls
// aligned and, on Windows, reserves the 32-byte shadow area.
@(private = "file")
frame :: proc(a: ^Asm) -> u8 {
	return 40 if a.arch == .X64_Win else 8
}

@(private = "file")
rex :: proc(a: ^Asm, w: bool, r, b: u8) {
	v := u8(0x40)
	if w {v |= 8}
	if r >= 8 {v |= 4}
	if b >= 8 {v |= 1}
	if v != 0x40 {emit8(a, v)}
}

// An opcode of one byte, or two (0x0f xx).
@(private = "file")
opcode :: proc(a: ^Asm, op: u32) {
	if op > 0xff {emit8(a, u8(op >> 8))}
	emit8(a, u8(op))
}

// op with register operands; `reg` may be an opcode extension digit.
@(private = "file")
op_rr :: proc(a: ^Asm, w: bool, op: u32, reg, rm: u8) {
	rex(a, w, reg, rm)
	opcode(a, op)
	emit8(a, 0xc0 | (reg & 7) << 3 | rm & 7)
}

// op with a register and [base + off], the state at rbx by default; base
// is not rsp or r12, which need a SIB byte.
@(private = "file")
op_state :: proc(a: ^Asm, w: bool, op: u32, reg: u8, off: u32, base: u8 = RBX) {
	assert(base & 7 != 4, "native: state base register")
	rex(a, w, reg, base)
	opcode(a, op)
	if off < 128 {
		emit8(a, 0x40 | (reg & 7) << 3 | base & 7, u8(off))
	} else {
		emit8(a, 0x80 | (reg & 7) << 3 | base & 7)
		emit32(a, off)
	}
}

// op with a register and import slot k, [rip + disp32]; the displacement
// must end the instruction.
@(private = "file")
op_imp :: proc(a: ^Asm, w: bool, op: u32, reg: u8, k: int) {
	rex(a, w, reg, 0)
	opcode(a, op)
	emit8(a, (reg & 7) << 3 | 5)
	append(&a.imp_refs, Fixup{at = len(a.code), target = k, kind = .Rel32})
	emit32(a, 0)
}

// Group-1 instruction (digit d) with an immediate, short form when it fits.
@(private = "file")
op_imm :: proc(a: ^Asm, d, rm: u8, v: u32) {
	if i32(v) >= -128 && i32(v) < 128 {
		op_rr(a, false, 0x83, d, rm)
		emit8(a, u8(v))
	} else {
		op_rr(a, false, 0x81, d, rm)
		emit32(a, v)
	}
}

// jcc to l, or jmp when cc < 0.
@(private = "file")
jump :: proc(a: ^Asm, cc: int, l: Label) {
	if cc < 0 {
		emit8(a, 0xe9)
	} else {
		emit8(a, 0x0f, 0x80 | u8(cc))
	}
	append(&a.jumps, Fixup{at = len(a.code), target = int(l), kind = .Rel32})
	emit32(a, 0)
}

@(private = "file", rodata)
CC := [Cond]u8{
	.Eq  = 0x4,
	.Ne  = 0x5,
	.Lt  = 0xc,
	.Ge  = 0xd,
	.Le  = 0xe,
	.Gt  = 0xf,
	.Ltu = 0x2,
	.Geu = 0x3,
}

x64_prologue :: proc(a: ^Asm, state: int) {
	emit8(a, 0x53, 0x41, 0x54, 0x41, 0x55, 0x41, 0x56) // push rbx r12 r13 r14
	if a.ram.base != "" {
		emit8(a, 0x41, 0x57, 0x55) // push r15 rbp
	}
	if win_cache(a) {
		emit8(a, 0x56, 0x57) // push rsi rdi
	}
	emit8(a, 0x48, 0x83, 0xec, frame(a)) // sub rsp, frame
	args := SYSV_ARGS if a.arch == .X64_SysV else WIN_ARGS
	op_rr(a, true, 0x89, args[0], R12) // mov r12, ctx
	op_imp(a, true, 0x8b, RBX, state) // mov rbx, [state]
	if a.ram.base != "" {
		op_imp(a, true, 0x8b, R15, imp(a, a.ram.base))
		op_imp(a, true, 0x8b, RBP, imp(a, a.ram.pages))
	}
}

x64_epilogue :: proc(a: ^Asm) {
	emit8(a, 0x48, 0x83, 0xc4, frame(a)) // add rsp, frame
	if win_cache(a) {
		emit8(a, 0x5f, 0x5e) // pop rdi rsi
	}
	if a.ram.base != "" {
		emit8(a, 0x5d, 0x41, 0x5f) // pop rbp r15
	}
	emit8(a, 0x41, 0x5e, 0x41, 0x5d, 0x41, 0x5c, 0x5b) // pop r14 r13 r12 rbx
	emit8(a, 0xc3)
}

@(private = "file")
win_cache :: proc(a: ^Asm) -> bool {
	return a.arch == .X64_Win && len(a.cached) > 0
}

x64_cache_sync :: proc(a: ^Asm, k: int, off: u32, store: bool) {
	op_state(a, false, 0x89 if store else 0x8b, X64_CACHE[k], off)
}

// r = cached field k, or (to_cache) the field = r.
x64_cache_mov :: proc(a: ^Asm, r: Reg, k: int, to_cache: bool) {
	if to_cache {
		op_rr(a, false, 0x89, X64_REG[r], X64_CACHE[k])
	} else {
		op_rr(a, false, 0x89, X64_CACHE[k], X64_REG[r])
	}
}

x64_cache_imm :: proc(a: ^Asm, k: int, v: u32) {
	mov_imm_raw(a, X64_CACHE[k], v)
}

x64_state_load :: proc(a: ^Asm, dst: Reg, off: u32) {
	op_state(a, false, 0x8b, X64_REG[dst], off)
}

x64_state_store :: proc(a: ^Asm, off: u32, src: Reg) {
	op_state(a, false, 0x89, X64_REG[src], off)
}

x64_state_store_imm :: proc(a: ^Asm, off: u32, v: u32) {
	op_state(a, false, 0xc7, 0, off)
	emit32(a, v)
}

x64_state_add64 :: proc(a: ^Asm, off: u32, v: u32) {
	assert(v < 1 << 31, "native: add64 immediate")
	op_state(a, true, 0x81, 0, off)
	emit32(a, v)
}

x64_mov_imm :: proc(a: ^Asm, dst: Reg, v: u32) {
	mov_imm_raw(a, X64_REG[dst], v)
}

@(private = "file")
mov_imm_raw :: proc(a: ^Asm, r: u8, v: u32) {
	if v == 0 {
		op_rr(a, false, 0x31, r, r)
		return
	}
	rex(a, false, 0, r)
	emit8(a, 0xb8 | r & 7)
	emit32(a, v)
}

x64_mov :: proc(a: ^Asm, dst, src: Reg) {
	op_rr(a, false, 0x89, X64_REG[src], X64_REG[dst])
}

@(private = "file", rodata)
ALU_OP := [Alu]u32{
	.Add = 0x01,
	.Sub = 0x29,
	.And = 0x21,
	.Or  = 0x09,
	.Xor = 0x31,
	.Shl = 4, // shifts: digit of d3 / c1
	.Shr = 5,
	.Sar = 7,
}

@(private = "file", rodata)
ALU_DIGIT := [Alu]u8{
	.Add = 0,
	.Sub = 5,
	.And = 4,
	.Or  = 1,
	.Xor = 6,
	.Shl = 4,
	.Shr = 5,
	.Sar = 7,
}

x64_alu :: proc(a: ^Asm, op: Alu, dst, src: Reg) {
	switch op {
	case .Add, .Sub, .And, .Or, .Xor:
		op_rr(a, false, ALU_OP[op], X64_REG[src], X64_REG[dst])
	case .Shl, .Shr, .Sar:
		op_rr(a, false, 0x89, X64_REG[src], RCX) // mov ecx, src
		op_rr(a, false, 0xd3, ALU_DIGIT[op], X64_REG[dst])
	}
}

x64_alu_imm :: proc(a: ^Asm, op: Alu, dst: Reg, v: u32) {
	switch op {
	case .Add, .Sub, .And, .Or, .Xor:
		op_imm(a, ALU_DIGIT[op], X64_REG[dst], v)
	case .Shl, .Shr, .Sar:
		assert(v < 32, "native: shift count")
		op_rr(a, false, 0xc1, ALU_DIGIT[op], X64_REG[dst])
		emit8(a, u8(v))
	}
}

// Without lzcnt, which baseline x86-64 lacks: 31 less the highest set bit,
// that taken as -1 for 0. Uses ecx.
x64_clz :: proc(a: ^Asm, dst: Reg) {
	d := X64_REG[dst]
	emit8(a, 0xb9, 0xff, 0xff, 0xff, 0xff) // mov ecx, -1
	op_rr(a, false, 0x0fbd, d, d) // bsr d, d
	op_rr(a, false, 0x0f44, d, RCX) // cmovz d, ecx
	op_rr(a, false, 0xf7, 3, d) // neg d
	op_imm(a, ALU_DIGIT[.Add], d, 31)
}

x64_not :: proc(a: ^Asm, dst: Reg) {
	op_rr(a, false, 0xf7, 2, X64_REG[dst])
}

// movdqu of the field at off: in the state, or, through rdx, from the
// address in import base.
x64_vec_ldst :: proc(a: ^Asm, v: Vreg, off: u32, store: bool, base := "") {
	reg: u8 = RBX
	if base != "" {
		op_imp(a, true, 0x8b, RDX, imp(a, base)) // mov rdx, [slot]
		reg = RDX
	}
	emit8(a, 0xf3)
	op_state(a, false, 0x0f7f if store else 0x0f6f, u8(v), off, reg)
}

// Through rdx = buf and xmm0.
x64_vec_funnel8 :: proc(a: ^Asm, dst, lo, hi: u32, buf: int) {
	op_imp(a, true, 0x8b, RDX, buf) // mov rdx, [slot]
	x64_vec_ldst(a, .V0, lo, false)
	emit8(a, 0xf3, 0x0f, 0x7f, 0x02) // movdqu [rdx], xmm0
	x64_vec_ldst(a, .V0, hi, false)
	emit8(a, 0xf3, 0x0f, 0x7f, 0x42, 0x10) // movdqu [rdx + 16], xmm0
	assert(X64_REG[.A] == 0, "native: funnel index register")
	emit8(a, 0xf3, 0x0f, 0x6f, 0x04, 0x02) // movdqu xmm0, [rdx + rax]
	x64_vec_ldst(a, .V0, dst, true)
}

// Through rdx = the import's address.
x64_vec_ldst_at :: proc(a: ^Asm, v: Vreg, base: int, store: bool) {
	assert(X64_REG[.A] == 0 && u8(v) < 8, "native: vector index register")
	op_imp(a, true, 0x8b, RDX, base) // mov rdx, [slot]
	emit8(a, 0xf3, 0x0f, 0x7f if store else 0x6f, 0x04 | u8(v) << 3, 0x02) // movdqu [rdx + rax]
}

x64_vec_op :: proc(a: ^Asm, op: Vop, dst, src: Vreg) {
	OPS :: [Vop]u32 {
		.Or       = 0x0feb, // por
		.Add16    = 0x0ffd, // paddw
		.Sub32    = 0x0ffa, // psubd
		.Max16    = 0x0fee, // pmaxsw
		.Min16    = 0x0fea, // pminsw
		.Gt16     = 0x0f65, // pcmpgtw
		.Nor      = 0x0feb, // por, then pxor with all ones
		.Zip_Lo8  = 0x0f60, // punpcklbw
		.Zip_Hi8  = 0x0f68, // punpckhbw
		.Zip_Lo64 = 0x0f6c, // punpcklqdq
		.Zip_Hi64 = 0x0f6d, // punpckhqdq
		.Zip_Lo16 = 0x0f61, // punpcklwd
		.Even8    = 0x0f67, // packuswb, of the words masked to their low bytes
		.Even16   = 0x0f6b, // packssdw, of the dwords sign-extended from their low halves
		.And      = 0x0fdb, // pand
		.Andn     = 0x0fdf, // pandn
		.Eq32     = 0x0f76, // pcmpeqd
		.Fadd     = 0x0f58, // addps
		.Fsub     = 0x0f5c, // subps
		.Fmul     = 0x0f59, // mulps
		.Fdiv     = 0x0f5e, // divps
		.Itof     = 0x0f5b, // cvtdq2ps
		.Ftoi     = 0x0f5b, // cvttps2dq
		.Gt32     = 0x0f66, // pcmpgtd
		.Xor      = 0x0fef, // pxor
		.Sub8     = 0x0ff8, // psubb
		.Zip_Lo32 = 0x0f62, // punpckldq
		.Zip_Hi32 = 0x0f6a, // punpckhdq
		.Dup16    = 0x0f70, // pshuflw, then pshufhw, of lanes 0
		.Adds16   = 0x0fed, // paddsw
		.Addu8    = 0x0fdc, // paddusb
		.Add32    = 0x0ffe, // paddd
		.Addu32   = 0x0ffe, // paddd, then por of where the sum is below dst
		.Madd16   = 0x0ff5, // pmaddwd
		.Sub16    = 0x0ff9, // psubw
		.Add8     = 0x0ffc, // paddb
		.Eq16     = 0x0f75, // pcmpeqw
		.Zip_Hi16 = 0x0f69, // punpckhwd
		.Adds8    = 0x0fec, // paddsb
		.Subs8    = 0x0fe8, // psubsb
		.Subs16   = 0x0fe9, // psubsw
		.Addu16   = 0x0fdd, // paddusw
		.Subu8    = 0x0fd8, // psubusb
		.Subu16   = 0x0fd9, // psubusw
		.Subu32   = 0x0ffa, // psubd, then pand with where dst is above src
		.Adds32   = 0x0ffe, // paddd, then the saturated value where it overflowed
		.Subs32   = 0x0ffa, // psubd, likewise
		.Gt8      = 0x0f64, // pcmpgtb
		.Eq8      = 0x0f74, // pcmpeqb
		.Max32    = 0x0f66, // pcmpgtd, then a select
		.Min32    = 0x0f66, // pcmpgtd, then a select
		.Abs16    = 0x0fee, // pmaxsw of src and 0 - src, saturating
		.Abs32    = 0x0ffa, // psubd of the sign mask from src ^ it, then paddd of where that is negative
		.Even32   = 0x0fc6, // shufps 0x88
	}
	ops := OPS
	sse :: proc(a: ^Asm, op: u32, dst, src: Vreg, ps := false) {
		if !ps {emit8(a, 0x66)}
		op_rr(a, false, op, u8(dst), u8(src))
	}
	if op == .Even8 {
		sse(a, 0x0f75, .V2, .V2) // pcmpeqw: all ones
		emit8(a, 0x66, 0x0f, 0x71, 0xd0 | u8(Vreg.V2), 8) // psrlw v2, 8
		sse(a, 0x0fdb, dst, .V2) // pand
		sse(a, 0x0fdb, src, .V2)
	}
	if op == .Even16 {
		for r in ([2]Vreg{dst, src}) {
			emit8(a, 0x66, 0x0f, 0x72, 0xf0 | u8(r), 16) // pslld r, 16
			emit8(a, 0x66, 0x0f, 0x72, 0xe0 | u8(r), 16) // psrad r, 16
		}
	}
	if op == .Dup16 {
		emit8(a, 0xf2)
		op_rr(a, false, ops[op], u8(dst), u8(src))
		emit8(a, 0, 0xf3)
		op_rr(a, false, ops[op], u8(dst), u8(dst))
		emit8(a, 0)
		return
	}
	if op == .Subu32 {
		// Unsigned above as signed after flipping the sign bits.
		sse(a, 0x0f76, .V3, .V3) // pcmpeqd: all ones
		emit8(a, 0x66, 0x0f, 0x72, 0xf0 | u8(Vreg.V3), 31) // pslld v3, 31
		x64_vec_copy(a, .V2, .V3)
		sse(a, 0x0fef, .V2, dst) // pxor
		sse(a, 0x0fef, .V3, src)
		sse(a, 0x0f66, .V2, .V3) // pcmpgtd
		sse(a, ops[op], dst, src)
		sse(a, 0x0fdb, dst, .V2) // pand
		return
	}
	if op == .Adds32 || op == .Subs32 {
		// Overflowed where the result's sign differs from dst's and src's
		// (add) or from dst's where src's does (subtract); the saturated
		// value is dst's sign mask ^ 0x7fffffff.
		x64_vec_copy(a, .V2, dst)
		sse(a, ops[op], dst, src)
		if op == .Adds32 {sse(a, 0x0fef, src, dst)} else {sse(a, 0x0fef, src, .V2)} // pxor
		x64_vec_copy(a, .V3, dst)
		sse(a, 0x0fef, .V3, .V2) // pxor
		sse(a, 0x0fdb, .V3, src) // pand
		emit8(a, 0x66, 0x0f, 0x72, 0xe0 | u8(Vreg.V3), 31) // psrad v3, 31
		emit8(a, 0x66, 0x0f, 0x72, 0xe0 | u8(Vreg.V2), 31) // psrad v2, 31
		sse(a, 0x0f76, src, src) // pcmpeqd: all ones
		emit8(a, 0x66, 0x0f, 0x72, 0xd0 | u8(src), 1) // psrld src, 1
		sse(a, 0x0fef, .V2, src) // pxor
		sse(a, 0x0fdb, .V2, .V3) // pand
		sse(a, 0x0fdf, .V3, dst) // pandn
		sse(a, 0x0feb, .V2, .V3) // por
		x64_vec_copy(a, dst, .V2)
		return
	}
	if op == .Max32 || op == .Min32 {
		// The mask of where dst wins, then dst & it | src &~ it.
		if op == .Max32 {
			x64_vec_copy(a, .V2, dst)
			sse(a, ops[op], .V2, src)
		} else {
			x64_vec_copy(a, .V2, src)
			sse(a, ops[op], .V2, dst)
		}
		sse(a, 0x0fdb, dst, .V2) // pand
		sse(a, 0x0fdf, .V2, src) // pandn
		sse(a, 0x0feb, dst, .V2) // por
		return
	}
	if op == .Abs16 {
		sse(a, 0x0fef, dst, dst) // pxor: 0
		sse(a, 0x0fe9, dst, src) // psubsw
		sse(a, ops[op], dst, src)
		return
	}
	if op == .Abs32 {
		// 0x80000000 comes out as itself, negative, and the paddd of
		// its sign mask makes it 0x7fffffff.
		x64_vec_copy(a, .V2, src)
		emit8(a, 0x66, 0x0f, 0x72, 0xe0 | u8(Vreg.V2), 31) // psrad v2, 31
		if dst != src {x64_vec_copy(a, dst, src)}
		sse(a, 0x0fef, dst, .V2) // pxor
		sse(a, ops[op], dst, .V2)
		x64_vec_copy(a, .V2, dst)
		emit8(a, 0x66, 0x0f, 0x72, 0xe0 | u8(Vreg.V2), 31) // psrad v2, 31
		sse(a, 0x0ffe, dst, .V2) // paddd
		return
	}
	if op == .Even32 {
		sse(a, ops[op], dst, src, ps = true)
		emit8(a, 0x88)
		return
	}
	if op == .Addu32 {
		// Unsigned below as signed after flipping the sign bits.
		sse(a, 0x0f6f, .V2, dst) // movdqa
		sse(a, ops[op], dst, src)
		sse(a, 0x0f76, .V3, .V3) // pcmpeqd: all ones
		emit8(a, 0x66, 0x0f, 0x72, 0xf0 | u8(Vreg.V3), 31) // pslld v3, 31
		sse(a, 0x0fef, .V2, .V3) // pxor
		sse(a, 0x0fef, .V3, dst)
		sse(a, 0x0f66, .V2, .V3) // pcmpgtd
		sse(a, 0x0feb, dst, .V2) // por
		return
	}
	if op == .Ftoi {emit8(a, 0xf3)}
	sse(a, ops[op], dst, src, op == .Fadd || op == .Fsub || op == .Fmul || op == .Fdiv || op == .Itof || op == .Ftoi)
	if op == .Nor {
		sse(a, 0x0f76, .V2, .V2) // pcmpeqd: all ones
		sse(a, 0x0fef, dst, .V2) // pxor
	}
}

x64_float_op :: proc(a: ^Asm, op: Vop, dst, src: Reg) {
	SS :: #partial [Vop]u32 {
		.Fadd = 0x0f58, // addss
		.Fsub = 0x0f5c, // subss
		.Fmul = 0x0f59, // mulss
		.Fdiv = 0x0f5e, // divss
	}
	ss := SS
	emit8(a, 0x66)
	op_rr(a, false, 0x0f6e, u8(Vreg.V0), X64_REG[dst]) // movd
	emit8(a, 0x66)
	op_rr(a, false, 0x0f6e, u8(Vreg.V1), X64_REG[src])
	emit8(a, 0xf3)
	op_rr(a, false, ss[op], u8(Vreg.V0), u8(Vreg.V1))
	emit8(a, 0x66)
	op_rr(a, false, 0x0f7e, u8(Vreg.V0), X64_REG[dst]) // movd back
}

x64_float_sqrt :: proc(a: ^Asm, r: Reg) {
	emit8(a, 0x66)
	op_rr(a, false, 0x0f6e, u8(Vreg.V0), X64_REG[r]) // movd
	emit8(a, 0xf3)
	op_rr(a, false, 0x0f51, u8(Vreg.V0), u8(Vreg.V0)) // sqrtss
	emit8(a, 0x66)
	op_rr(a, false, 0x0f7e, u8(Vreg.V0), X64_REG[r]) // movd back
}

x64_int_to_float :: proc(a: ^Asm, r: Reg) {
	emit8(a, 0xf3)
	op_rr(a, false, 0x0f2a, u8(Vreg.V0), X64_REG[r]) // cvtsi2ss
	emit8(a, 0x66)
	op_rr(a, false, 0x0f7e, u8(Vreg.V0), X64_REG[r]) // movd back
}

x64_float_to_int :: proc(a: ^Asm, r: Reg) {
	emit8(a, 0x66)
	op_rr(a, false, 0x0f6e, u8(Vreg.V0), X64_REG[r]) // movd
	emit8(a, 0xf3)
	op_rr(a, false, 0x0f2c, X64_REG[r], u8(Vreg.V0)) // cvttss2si
}

x64_vec_copy :: proc(a: ^Asm, dst, src: Vreg) {
	emit8(a, 0x66)
	op_rr(a, false, 0x0f6f, u8(dst), u8(src)) // movdqa
}

x64_vec_shuf32 :: proc(a: ^Asm, dst, src: Vreg, lanes: [4]u8) {
	emit8(a, 0x66)
	op_rr(a, false, 0x0f70, u8(dst), u8(src)) // pshufd
	emit8(a, lanes[0] | lanes[1] << 2 | lanes[2] << 4 | lanes[3] << 6)
}

x64_vec_shuf16 :: proc(a: ^Asm, dst, src: Vreg, lanes: [4]u8) {
	imm := lanes[0] | lanes[1] << 2 | lanes[2] << 4 | lanes[3] << 6
	emit8(a, 0xf2)
	op_rr(a, false, 0x0f70, u8(dst), u8(src)) // pshuflw
	emit8(a, imm, 0xf3)
	op_rr(a, false, 0x0f70, u8(dst), u8(dst)) // pshufhw
	emit8(a, imm)
}

// Through rdx.
x64_vec_splat_load :: proc(a: ^Asm, dst: Vreg, base: string) {
	op_imp(a, true, 0x8b, RDX, imp(a, base)) // mov rdx, [slot]
	emit8(a, 0x66)
	op_state(a, false, 0x0f6e, u8(dst), 0, RDX) // movd
	x64_vec_shuf32(a, dst, dst, {0, 0, 0, 0})
}

x64_vec_signs :: proc(a: ^Asm, dst: Reg, v: Vreg) {
	x64_vec_shuf32(a, v, v, {3, 2, 1, 0})
	op_rr(a, false, 0x0f50, X64_REG[dst], u8(v)) // movmskps
}

// Through rdx.
x64_imp_ldst :: proc(a: ^Asm, r: Reg, base: string, store: bool, off: u32, w: Width, signed: bool) {
	assert(w == .B16 || w == .B32, "native: import access width")
	op_imp(a, true, 0x8b, RDX, imp(a, base)) // mov rdx, [slot]
	op: u32
	switch {
	case store:
		if w == .B16 {emit8(a, 0x66)}
		op = 0x89
	case w == .B16:
		op = 0x0fbf if signed else 0x0fb7 // movsx, movzx
	case:
		op = 0x8b
	}
	op_state(a, false, op, X64_REG[r], off, RDX)
}

x64_vec_shift16 :: proc(a: ^Asm, op: Alu, v: Vreg, n: u32) {
	digit: u8 = 6 if op == .Shl else 2 if op == .Shr else 4 // psllw, psrlw, psraw
	emit8(a, 0x66, 0x0f, 0x71, 0xc0 | digit << 3 | u8(v), u8(n))
}

x64_vec_shift32 :: proc(a: ^Asm, op: Alu, v: Vreg, n: u32) {
	digit: u8 = 6 if op == .Shl else 2 if op == .Shr else 4 // pslld, psrld, psrad
	emit8(a, 0x66, 0x0f, 0x72, 0xc0 | digit << 3 | u8(v), u8(n))
}

x64_set_cond :: proc(a: ^Asm, c: Cond, dst, src: Reg) {
	d := X64_REG[dst]
	op_rr(a, false, 0x39, X64_REG[src], d) // cmp dst, src
	op_rr(a, false, 0x0f90 | u32(CC[c]), 0, d) // setcc dst8
	op_rr(a, false, 0x0fb6, d, d) // movzx dst, dst8
}

x64_mul_wide :: proc(a: ^Asm, signed: bool, lo, hi: u32, x, y: Reg) {
	x, y := x, y
	if y == .A {x, y = y, x}
	mov(a, .A, x)
	op_rr(a, false, 0xf7, 5 if signed else 4, X64_REG[y]) // edx:eax = eax * y
	op_state(a, false, 0x89, 0, lo)
	op_state(a, false, 0x89, RDX, hi)
}

x64_mac64 :: proc(a: ^Asm, op: Mac, x, y: Reg) {
	op_rr(a, true, 0x63, RCX, X64_REG[x]) // movsxd rcx, x
	op_rr(a, true, 0x63, RDX, X64_REG[y]) // movsxd rdx, y
	op_rr(a, true, 0x0faf, RCX, RDX) // imul rcx, rdx
	switch op {
	case .Set:
		op_rr(a, true, 0x89, RCX, 0) // mov rax, rcx
	case .Add:
		op_rr(a, true, 0x01, RCX, 0) // add rax, rcx
	case .Sub:
		op_rr(a, true, 0x29, RCX, 0) // sub rax, rcx
	}
}

x64_mac64_split :: proc(a: ^Asm, dst: Reg) {
	op_rr(a, true, 0x89, 0, RCX) // mov rcx, rax
	op_rr(a, true, 0xc1, 7, RCX) // sar rcx, 32
	emit8(a, 32)
	op_rr(a, false, 0x89, RCX, X64_REG[dst]) // mov dst, ecx
	op_rr(a, false, 0x89, 0, 0) // mov eax, eax: the high half cleared
}

x64_mac64_wrap :: proc(a: ^Asm, n: u32, dst: Reg) {
	op_rr(a, true, 0x89, 0, RCX) // mov rcx, rax
	op_rr(a, true, 0xc1, 4, RCX) // shl rcx, 64 - n
	emit8(a, u8(64 - n))
	op_rr(a, true, 0xc1, 7, RCX) // sar rcx, 64 - n
	emit8(a, u8(64 - n))
	op_rr(a, true, 0x89, 0, RDX) // mov rdx, rax
	op_rr(a, true, 0x29, RCX, RDX) // sub rdx, rcx
	op_rr(a, true, 0xc1, 7, RDX) // sar rdx, n
	emit8(a, u8(n))
	op_rr(a, false, 0x89, RDX, X64_REG[dst]) // mov dst, edx
	op_rr(a, true, 0x89, RCX, 0) // mov rax, rcx
}

x64_div_wide :: proc(a: ^Asm, signed: bool, lo, hi: u32, x, y: Reg) {
	d := X64_REG[y]
	if y == .A {
		op_rr(a, false, 0x89, d, RCX) // mov ecx, eax
		d = RCX
	}
	mov(a, .A, x)
	if signed {
		emit8(a, 0x99) // cdq
	} else {
		op_rr(a, false, 0x31, RDX, RDX) // xor edx, edx
	}
	op_rr(a, false, 0xf7, 7 if signed else 6, d) // eax, edx = edx:eax / d, % d
	op_state(a, false, 0x89, 0, lo)
	op_state(a, false, 0x89, RDX, hi)
}

x64_call :: proc(a: ^Asm, k: int, args: []Reg) {
	regs := SYSV_ARGS if a.arch == .X64_SysV else WIN_ARGS
	for r, n in args {
		op_rr(a, false, 0x89, X64_REG[r], regs[n])
	}
	op_rr(a, true, 0x89, R12, regs[len(args)]) // the context, last
	op_imp(a, false, 0xff, 2, k) // call [slot]
}

// x64_call's sequence with no arguments, to a label in the code.
x64_call_func :: proc(a: ^Asm, l: Label) {
	regs := SYSV_ARGS if a.arch == .X64_SysV else WIN_ARGS
	op_rr(a, true, 0x89, R12, regs[0]) // the context
	x64_call_label(a, l)
}

x64_jmp :: proc(a: ^Asm, l: Label) {
	jump(a, -1, l)
}

x64_br_zero :: proc(a: ^Asm, r: Reg, l: Label, nonzero: bool) {
	op_rr(a, false, 0x85, X64_REG[r], X64_REG[r])
	jump(a, 0x5 if nonzero else 0x4, l)
}

x64_br_cmp_imm :: proc(a: ^Asm, c: Cond, r: Reg, v: u32, l: Label) {
	op_imm(a, 7, X64_REG[r], v)
	jump(a, int(CC[c]), l)
}

x64_br_state64_below :: proc(a: ^Asm, off: u32, limit: int, l: Label) {
	op_imp(a, true, 0x8b, RCX, limit) // mov rcx, [slot]
	emit8(a, 0x48, 0x8b, 0x09) // mov rcx, [rcx]
	op_state(a, true, 0x39, RCX, off) // cmp [rbx+off], rcx
	jump(a, 0x2, l) // jb
}

x64_br_byte_clear :: proc(a: ^Asm, addr, mask: int, l: Label) {
	op_imp(a, true, 0x8b, RCX, addr) // mov rcx, [slot]
	emit8(a, 0x0f, 0xb6, 0x09) // movzx ecx, byte [rcx]
	if mask >= 0 {
		op_imp(a, false, 0x85, RCX, mask) // test [slot], ecx
	} else {
		emit8(a, 0x85, 0xc9) // test ecx, ecx
	}
	jump(a, 0x4, l) // jz
}

// To far when the guest address in A is not RAM.
@(private = "file")
br_outside :: proc(a: ^Asm, far: Label) {
	assert(X64_REG[.A] == 0, "native: test eax")
	emit8(a, 0xa9) // test eax, outside
	emit32(a, a.ram.outside)
	jump(a, 0x5, far) // jnz
}

// op with a register and RAM at [r15 + index]; w: 64-bit.
@(private = "file")
op_ram :: proc(a: ^Asm, op: u32, reg, index: u8, w := false) {
	v := u8(0x41)
	if w {v |= 8}
	if reg >= 8 {v |= 4}
	if index >= 8 {v |= 2}
	emit8(a, v)
	opcode(a, op)
	emit8(a, (reg & 7) << 3 | 4, (index & 7) << 3 | R15 & 7)
}

// B64 and B128 copy into the field at s.off, through rcx or xmm0.
x64_load :: proc(a: ^Asm, s: Slow, far: Label) {
	br_outside(a, far)
	emit8(a, 0x25) // and eax, size - 1
	emit32(a, a.ram.size - 1)
	load_at(a, s)
}

// The load from [r15 + rax].
@(private = "file")
load_at :: proc(a: ^Asm, s: Slow) {
	OPS :: [Width][2]u32 {
		.B8   = {0x0fb6, 0x0fbe}, // movzx, movsx
		.B16  = {0x0fb7, 0x0fbf},
		.B32  = {0x8b, 0x8b},
		.B64  = {},
		.B128 = {},
	}
	ops := OPS
	ra := X64_REG[.A]
	switch s.w {
	case .B8, .B16, .B32:
		op_ram(a, ops[s.w][1 if s.signed else 0], ra, ra)
	case .B64:
		op_ram(a, 0x8b, RCX, ra, true) // mov rcx, [r15 + rax]
		op_state(a, true, 0x89, RCX, s.off)
	case .B128:
		emit8(a, 0xf3)
		op_ram(a, 0x0f6f, 0, ra) // movdqu xmm0, [r15 + rax]
		x64_vec_ldst(a, .V0, s.off, true, s.base)
	}
}

// The slow path needs A, so the offset goes in ecx. To guarded when a
// guard is set, to far when the address is not RAM or its page byte is set.
x64_store :: proc(a: ^Asm, s: Slow, far, guarded: Label) {
	r := a.ram
	for g in r.guards {
		op_imp(a, true, 0x8b, RDX, imp(a, g.addr)) // mov rdx, [slot]
		emit8(a, 0xf6, 0x02, g.mask) // test byte [rdx], mask
		jump(a, 0x5, guarded) // jnz
	}
	br_outside(a, far)
	op_rr(a, false, 0x89, X64_REG[.A], RCX) // mov ecx, A
	op_imm(a, 4, RCX, r.size - 1) // and
	op_rr(a, false, 0x89, RCX, RDX) // mov edx, ecx
	op_rr(a, false, 0xc1, 5, RDX) // shr edx, page_shift
	emit8(a, u8(r.page_shift))
	emit8(a, 0x80, 0x7c, 0x15, 0x00, 0x00) // cmp byte [rbp + rdx], 0
	jump(a, 0x5, far) // jne
	store_at(a, s)
}

// The store to [r15 + rcx]. B64 and B128 copy the field at s.off (or zero)
// through rdx or xmm0.
@(private = "file")
store_at :: proc(a: ^Asm, s: Slow) {
	switch s.w {
	case .B8, .B16, .B32:
		src := X64_REG[.B]
		// Without a REX prefix, byte registers 4 to 7 would be ah to bh.
		assert(s.w != .B8 || src < 4 || src >= 8, "native: byte store register")
		if s.w == .B16 {emit8(a, 0x66)}
		op_ram(a, 0x88 if s.w == .B8 else 0x89, src, RCX)
	case .B64:
		if s.zero {
			op_rr(a, false, 0x31, RDX, RDX) // xor edx, edx
		} else {
			op_state(a, true, 0x8b, RDX, s.off)
		}
		op_ram(a, 0x89, RDX, RCX, true) // mov [r15 + rcx], rdx
	case .B128:
		if s.zero {
			emit8(a, 0x66, 0x0f, 0xef, 0xc0) // pxor xmm0, xmm0
		} else {
			x64_vec_ldst(a, .V0, s.off, false, s.base)
		}
		emit8(a, 0xf3)
		op_ram(a, 0x0f7f, 0, RCX) // movdqu [r15 + rcx], xmm0
	}
}

// The load or store s at byte C of the window: its address less r15 plus
// C makes the index, rax for a load, rcx for a store.
x64_window :: proc(a: ^Asm, s: Slow) {
	index := RCX if s.store else X64_REG[.A]
	op_imp(a, true, 0x8b, index, imp(a, a.ram.window)) // mov index, [slot]
	op_rr(a, true, 0x29, R15, index) // sub index, r15
	op_rr(a, true, 0x01, X64_REG[.C], index) // add index, r11
	if s.store {
		store_at(a, s)
	} else {
		load_at(a, s)
	}
}

x64_call_label :: proc(a: ^Asm, l: Label) {
	emit8(a, 0xe8)
	append(&a.jumps, Fixup{at = len(a.code), target = int(l), kind = .Rel32})
	emit32(a, 0)
}

x64_return :: proc(a: ^Asm) {
	emit8(a, 0xc3)
}

// A slow routine's call into the runtime: the return address left the
// stack 8 off alignment, as at a function's entry, so it takes the same
// frame.
x64_slow_frame :: proc(a: ^Asm, enter: bool) {
	emit8(a, 0x48, 0x83, 0xec if enter else 0xc4, frame(a)) // sub/add rsp, frame
}
