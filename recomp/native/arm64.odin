// arm64 encoding of the operations in asm.odin (AAPCS64).
//
// x19 holds the guest state address and x20 the context pointer; T and LD
// live in w21 and w22, kept across calls. With guest RAM, x23 holds its
// address and x24 that of its page bytes. A, B and C are w9, w10 and w11,
// which a call may change. x12, x13 and x16 are temporaries inside one
// operation. x18 is never touched (the platform register on macOS and
// Windows). The cached state fields live in w4 to w7, never an argument:
// calls take at most four, the context included.
package native

import "base:intrinsics"

@(private = "file", rodata)
A64_REG := [Reg]u32{
	.A  = 9,
	.B  = 10,
	.C  = 11,
	.T  = 21,
	.LD = 22,
}

@(private = "file", rodata)
A64_CACHE := [CACHE_MAX]u32{4, 5, 6, 7}

@(private = "file")
S :: 19
@(private = "file")
CTX :: 20
@(private = "file")
RAM :: 23
@(private = "file")
PAGES :: 24
@(private = "file")
T0 :: 12
@(private = "file")
T1 :: 13
@(private = "file")
IP0 :: 16
@(private = "file")
ZR :: 31

@(private = "file", rodata)
CC := [Cond]u32{
	.Eq  = 0x0,
	.Ne  = 0x1,
	.Geu = 0x2, // hs
	.Ltu = 0x3, // lo
	.Ge  = 0xa,
	.Lt  = 0xb,
	.Gt  = 0xc,
	.Le  = 0xd,
}

@(private = "file")
rrr :: proc(a: ^Asm, op, d, n, m: u32) {
	emit32(a, op | m << 16 | n << 5 | d)
}

// ldr/str of a 4- or 8-byte field at [n + off]; past the scaled 12-bit
// offset, through x16 = n + the offset's high bits.
@(private = "file")
ldst :: proc(a: ^Asm, op, t, n, off, size: u32) {
	assert(off % size == 0 && off < 1 << 24, "native: state offset")
	n, off := n, off
	if off / size >= 4096 {
		emit32(a, 0x91400000 | off >> 12 << 10 | n << 5 | IP0) // add x16, xn, #hi, lsl #12
		n, off = IP0, off & 0xfff
	}
	emit32(a, op | off / size << 10 | n << 5 | t)
}

// x(d) = the contents of import slot k (adrp + ldr).
@(private = "file")
load_imp :: proc(a: ^Asm, d: u32, k: int) {
	append(&a.imp_refs, Fixup{at = len(a.code), target = k, kind = .A64_Adrp})
	emit32(a, 0x90000000 | d)
	emit32(a, 0xf9400000 | d << 5 | d)
}

@(private = "file")
movw :: proc(a: ^Asm, d, v: u32) {
	if v >> 16 == 0 || v & 0xffff != 0 {
		emit32(a, 0x52800000 | (v & 0xffff) << 5 | d) // movz
		if v >> 16 != 0 {emit32(a, 0x72a00000 | (v >> 16) << 5 | d)} // movk lsl 16
	} else {
		emit32(a, 0x52a00000 | (v >> 16) << 5 | d) // movz lsl 16
	}
}

@(private = "file")
branch :: proc(a: ^Asm, op: u32, kind: Fixup_Kind, l: Label) {
	append(&a.jumps, Fixup{at = len(a.code), target = int(l), kind = kind})
	emit32(a, op)
}

a64_prologue :: proc(a: ^Asm, state: int) {
	ram := a.ram.base != ""
	emit32(a, 0xa9bc7bfd if ram else 0xa9bd7bfd) // stp x29, x30, [sp, #-64 or -48]!
	emit32(a, 0x910003fd) // mov x29, sp
	emit32(a, 0xa90153f3) // stp x19, x20, [sp, #16]
	emit32(a, 0xa9025bf5) // stp x21, x22, [sp, #32]
	if ram {emit32(a, 0xa90363f7)} // stp x23, x24, [sp, #48]
	emit32(a, 0xaa0003e0 | CTX) // mov x20, x0
	load_imp(a, S, state)
	if ram {
		load_imp(a, RAM, imp(a, a.ram.base))
		load_imp(a, PAGES, imp(a, a.ram.pages))
	}
}

a64_epilogue :: proc(a: ^Asm) {
	ram := a.ram.base != ""
	if ram {emit32(a, 0xa94363f7)} // ldp x23, x24, [sp, #48]
	emit32(a, 0xa9425bf5) // ldp x21, x22, [sp, #32]
	emit32(a, 0xa94153f3) // ldp x19, x20, [sp, #16]
	emit32(a, 0xa8c47bfd if ram else 0xa8c37bfd) // ldp x29, x30, [sp], #64 or #48
	emit32(a, 0xd65f03c0) // ret
}

a64_cache_sync :: proc(a: ^Asm, k: int, off: u32, store: bool) {
	ldst(a, 0xb9000000 if store else 0xb9400000, A64_CACHE[k], S, off, 4)
}

// r = cached field k, or (to_cache) the field = r.
a64_cache_mov :: proc(a: ^Asm, r: Reg, k: int, to_cache: bool) {
	if to_cache {
		rrr(a, 0x2a0003e0, A64_CACHE[k], 0, A64_REG[r])
	} else {
		rrr(a, 0x2a0003e0, A64_REG[r], 0, A64_CACHE[k])
	}
}

a64_cache_imm :: proc(a: ^Asm, k: int, v: u32) {
	movw(a, A64_CACHE[k], v)
}

a64_state_load :: proc(a: ^Asm, dst: Reg, off: u32) {
	ldst(a, 0xb9400000, A64_REG[dst], S, off, 4)
}

a64_state_store :: proc(a: ^Asm, off: u32, src: Reg) {
	ldst(a, 0xb9000000, A64_REG[src], S, off, 4)
}

a64_state_add64 :: proc(a: ^Asm, off: u32, v: u32) {
	ldst(a, 0xf9400000, T0, S, off, 8)
	if v < 4096 {
		emit32(a, 0x91000000 | v << 10 | T0 << 5 | T0) // add x12, x12, #v
	} else {
		movw(a, T1, v)
		rrr(a, 0x8b000000, T0, T0, T1) // add x12, x12, x13
	}
	ldst(a, 0xf9000000, T0, S, off, 8)
}

a64_mov_imm :: proc(a: ^Asm, dst: Reg, v: u32) {
	movw(a, A64_REG[dst], v)
}

a64_mov :: proc(a: ^Asm, dst, src: Reg) {
	rrr(a, 0x2a0003e0, A64_REG[dst], 0, A64_REG[src]) // orr wd, wzr, wm
}

@(private = "file", rodata)
ALU_RRR := [Alu]u32{
	.Add = 0x0b000000,
	.Sub = 0x4b000000,
	.And = 0x0a000000,
	.Or  = 0x2a000000,
	.Xor = 0x4a000000,
	.Shl = 0x1ac02000, // lslv
	.Shr = 0x1ac02400, // lsrv
	.Sar = 0x1ac02800, // asrv
}

a64_alu :: proc(a: ^Asm, op: Alu, dst, src: Reg) {
	d := A64_REG[dst]
	rrr(a, ALU_RRR[op], d, d, A64_REG[src])
}

a64_alu_imm :: proc(a: ^Asm, op: Alu, dst: Reg, v: u32) {
	d := A64_REG[dst]
	switch op {
	case .Add, .Sub:
		if v < 4096 {
			emit32(a, (0x11000000 if op == .Add else 0x51000000) | v << 10 | d << 5 | d)
			return
		}
		movw(a, T0, v)
		rrr(a, ALU_RRR[op], d, d, T0)
	case .And, .Or, .Xor:
		movw(a, T0, v)
		rrr(a, ALU_RRR[op], d, d, T0)
	case .Shl:
		assert(v < 32, "native: shift count")
		emit32(a, 0x53000000 | (32 - v) % 32 << 16 | (31 - v) << 10 | d << 5 | d) // ubfm
	case .Shr:
		assert(v < 32, "native: shift count")
		emit32(a, 0x53007c00 | v << 16 | d << 5 | d) // ubfm #v, #31
	case .Sar:
		assert(v < 32, "native: shift count")
		emit32(a, 0x13007c00 | v << 16 | d << 5 | d) // sbfm #v, #31
	}
}

// ldr/str q of the field at off: in the state, or, through x16, from the
// address in import base.
a64_vec_ldst :: proc(a: ^Asm, v: Vreg, off: u32, store: bool, base := "") {
	assert(off / 16 < 4096, "native: state offset")
	n: u32 = S
	if base != "" {
		load_imp(a, IP0, imp(a, base))
		n = IP0
	}
	emit32(a, (0x3d800000 if store else 0x3dc00000) | off / 16 << 10 | n << 5 | u32(v)) // str/ldr q
}

// Through x16 = buf and q0.
a64_vec_funnel8 :: proc(a: ^Asm, dst, lo, hi: u32, buf: int) {
	load_imp(a, IP0, buf)
	a64_vec_ldst(a, .V0, lo, false)
	emit32(a, 0x3d800000 | IP0 << 5) // str q0, [x16]
	a64_vec_ldst(a, .V0, hi, false)
	emit32(a, 0x3d800000 | 1 << 10 | IP0 << 5) // str q0, [x16, #16]
	rrr(a, 0x3ce06800, 0, IP0, A64_REG[.A]) // ldr q0, [x16, x9]
	a64_vec_ldst(a, .V0, dst, true)
}

// Through x16 = the import's address.
a64_vec_ldst_at :: proc(a: ^Asm, v: Vreg, base: int, store: bool) {
	load_imp(a, IP0, base)
	rrr(a, 0x3ca06800 if store else 0x3ce06800, u32(v), IP0, A64_REG[.A]) // str/ldr q, [x16, x9]
}

a64_vec_op :: proc(a: ^Asm, op: Vop, dst, src: Vreg) {
	OPS :: [Vop]u32 {
		.Or       = 0x4ea01c00, // orr .16b
		.Add16    = 0x4e608400, // add .8h
		.Sub32    = 0x6ea08400, // sub .4s
		.Max16    = 0x4e606400, // smax .8h
		.Min16    = 0x4e606c00, // smin .8h
		.Gt16     = 0x4e603400, // cmgt .8h
		.Nor      = 0x4ea01c00, // orr .16b, then mvn
		.Zip_Lo8  = 0x4e003800, // zip1 .16b
		.Zip_Hi8  = 0x4e007800, // zip2 .16b
		.Zip_Lo64 = 0x4ec03800, // zip1 .2d
		.Zip_Hi64 = 0x4ec07800, // zip2 .2d
		.Zip_Lo16 = 0x4e403800, // zip1 .8h
		.Even8    = 0x4e001800, // uzp1 .16b
		.Even16   = 0x4e401800, // uzp1 .8h
		.And      = 0x4e201c00, // and .16b
		.Andn     = 0x4e601c00, // bic .16b, of src and dst
		.Eq32     = 0x6ea08c00, // cmeq .4s
		.Fadd     = 0x4e20d400, // fadd .4s
		.Fsub     = 0x4ea0d400, // fsub .4s
		.Fmul     = 0x6e20dc00, // fmul .4s
		.Fdiv     = 0x6e20fc00, // fdiv .4s
		.Itof     = 0x4e21d800, // scvtf .4s
		.Ftoi     = 0x4ea1b800, // fcvtzs .4s
		.Gt32     = 0x4ea03400, // cmgt .4s
		.Xor      = 0x6e201c00, // eor .16b
		.Sub8     = 0x6e208400, // sub .16b
		.Zip_Lo32 = 0x4e803800, // zip1 .4s
		.Zip_Hi32 = 0x4e807800, // zip2 .4s
		.Dup16    = 0x4e402800, // trn1 .8h, then trn1 .4s
		.Adds16   = 0x4e600c00, // sqadd .8h
		.Addu8    = 0x6e200c00, // uqadd .16b
		.Add32    = 0x4ea08400, // add .4s
		.Addu32   = 0x6ea00c00, // uqadd .4s
		.Madd16   = 0x4ea0bc00, // addp .4s, of smull and smull2
		.Sub16    = 0x6e608400, // sub .8h
		.Add8     = 0x4e208400, // add .16b
		.Eq16     = 0x6e608c00, // cmeq .8h
		.Zip_Hi16 = 0x4e407800, // zip2 .8h
		.Adds8    = 0x4e200c00, // sqadd .16b
		.Subs8    = 0x4e202c00, // sqsub .16b
		.Subs16   = 0x4e602c00, // sqsub .8h
		.Addu16   = 0x6e600c00, // uqadd .8h
		.Subu8    = 0x6e202c00, // uqsub .16b
		.Subu16   = 0x6e602c00, // uqsub .8h
		.Subu32   = 0x6ea02c00, // uqsub .4s
		.Adds32   = 0x4ea00c00, // sqadd .4s
		.Subs32   = 0x4ea02c00, // sqsub .4s
		.Gt8      = 0x4e203400, // cmgt .16b
		.Eq8      = 0x6e208c00, // cmeq .16b
		.Max32    = 0x4ea06400, // smax .4s
		.Min32    = 0x4ea06c00, // smin .4s
		.Abs16    = 0x4e607800, // sqabs .8h
		.Abs32    = 0x4ea07800, // sqabs .4s
		.Even32   = 0x4e801800, // uzp1 .4s
	}
	ops := OPS
	if op == .Itof || op == .Ftoi || op == .Abs16 || op == .Abs32 {
		rrr(a, ops[op], u32(dst), u32(src), 0)
		return
	}
	if op == .Dup16 {
		rrr(a, ops[op], u32(dst), u32(src), u32(src)) // halfwords 0, 0, 2, 2, 4, 4, 6, 6
		rrr(a, 0x4e802800, u32(dst), u32(dst), u32(dst)) // trn1 .4s: words 0, 0, 2, 2
		return
	}
	if op == .Madd16 {
		v2, v3 := u32(Vreg.V2), u32(Vreg.V3)
		rrr(a, 0x0e60c000, v2, u32(dst), u32(src)) // smull .4s, .4h: halfwords 0-3
		rrr(a, 0x4e60c000, v3, u32(dst), u32(src)) // smull2: halfwords 4-7
		rrr(a, ops[op], u32(dst), v2, v3)
		return
	}
	if op == .Andn {
		rrr(a, ops[op], u32(dst), u32(src), u32(dst))
		return
	}
	rrr(a, ops[op], u32(dst), u32(dst), u32(src))
	if op == .Nor {emit32(a, 0x6e205800 | u32(dst) << 5 | u32(dst))} // mvn .16b
}

a64_float_op :: proc(a: ^Asm, op: Vop, dst, src: Reg) {
	S_OPS :: #partial [Vop]u32 {
		.Fadd = 0x1e202800, // fadd s
		.Fsub = 0x1e203800, // fsub s
		.Fmul = 0x1e200800, // fmul s
		.Fdiv = 0x1e201800, // fdiv s
	}
	ops := S_OPS
	d, v0, v1 := A64_REG[dst], u32(Vreg.V0), u32(Vreg.V1)
	emit32(a, 0x1e270000 | d << 5 | v0) // fmov s0, wd
	emit32(a, 0x1e270000 | A64_REG[src] << 5 | v1) // fmov s1, ws
	rrr(a, ops[op], v0, v0, v1)
	emit32(a, 0x1e260000 | v0 << 5 | d) // fmov wd, s0
}

a64_float_sqrt :: proc(a: ^Asm, r: Reg) {
	d, v0 := A64_REG[r], u32(Vreg.V0)
	emit32(a, 0x1e270000 | d << 5 | v0) // fmov s0, wr
	emit32(a, 0x1e21c000 | v0 << 5 | v0) // fsqrt s0, s0
	emit32(a, 0x1e260000 | v0 << 5 | d) // fmov wr, s0
}

a64_int_to_float :: proc(a: ^Asm, r: Reg) {
	d, v0 := A64_REG[r], u32(Vreg.V0)
	emit32(a, 0x1e220000 | d << 5 | v0) // scvtf s0, wr
	emit32(a, 0x1e260000 | v0 << 5 | d) // fmov wr, s0
}

// fcvtzs saturates and gives 0 for NaN; NaN becomes 0x80000000, as on x64.
// Through w12.
a64_float_to_int :: proc(a: ^Asm, r: Reg) {
	d, v0 := A64_REG[r], u32(Vreg.V0)
	emit32(a, 0x1e270000 | d << 5 | v0) // fmov s0, wr
	emit32(a, 0x1e380000 | v0 << 5 | d) // fcvtzs wr, s0
	rrr(a, 0x1e202000, 0, v0, v0) // fcmp s0, s0
	movw(a, T0, 0x80000000)
	emit32(a, 0x1a800000 | d << 16 | 0x6 << 12 | T0 << 5 | d) // csel wr, w12, wr, vs
}

a64_vec_copy :: proc(a: ^Asm, dst, src: Vreg) {
	rrr(a, 0x4ea01c00, u32(dst), u32(src), u32(src)) // orr .16b
}

a64_vec_shuf32 :: proc(a: ^Asm, dst, src: Vreg, lanes: [4]u8) {
	d, n := u32(dst), u32(src)
	if lanes == {lanes[0], lanes[0], lanes[0], lanes[0]} {
		emit32(a, 0x4e000400 | (u32(lanes[0]) << 3 | 4) << 16 | n << 5 | d) // dup .4s
		return
	}
	for l, k in lanes {
		emit32(a, 0x6e000400 | (u32(k) << 3 | 4) << 16 | u32(l) << 13 | n << 5 | d) // ins .s
	}
}

a64_vec_shuf16 :: proc(a: ^Asm, dst, src: Vreg, lanes: [4]u8) {
	d, n := u32(dst), u32(src)
	for h in 0 ..< 2 {
		for l, k in lanes {
			i, j := u32(4 * h + k), u32(4 * h) + u32(l)
			emit32(a, 0x6e000400 | (i << 2 | 2) << 16 | j << 12 | n << 5 | d) // ins .h
		}
	}
}

// Through x16.
a64_vec_splat_load :: proc(a: ^Asm, dst: Vreg, base: string) {
	load_imp(a, IP0, imp(a, base))
	emit32(a, 0x4d40c800 | IP0 << 5 | u32(dst)) // ld1r .4s
}

// Each lane's sign as a bit 16 apart, gathered by a multiply: lane k's
// bit 16k times 1 << (51 - 17k) lands on bit 51 - k, and every other
// product below bit 48. Through x16.
a64_vec_signs :: proc(a: ^Asm, dst: Reg, v: Vreg) {
	n, d := u32(v), A64_REG[dst]
	emit32(a, 0x6f000400 | 33 << 16 | n << 5 | n) // ushr .4s, #31
	emit32(a, 0x0e612800 | n << 5 | n) // xtn .4h
	emit32(a, 0x9e660000 | n << 5 | d) // fmov xd, dn
	emit32(a, 0xd2800000 | 1 << 5 | IP0) // movz x16, #1
	emit32(a, 0xf2a00000 | 2 << 5 | IP0) // movk x16, #2, lsl 16
	emit32(a, 0xf2c00000 | 4 << 5 | IP0) // movk x16, #4, lsl 32
	emit32(a, 0xf2e00000 | 8 << 5 | IP0) // movk x16, #8, lsl 48
	rrr(a, 0x9b007c00, d, d, IP0) // mul
	emit32(a, 0xd3400000 | 48 << 16 | 51 << 10 | d << 5 | d) // ubfx #48, #4
}

// Through x16.
a64_imp_ldst :: proc(a: ^Asm, r: Reg, base: string, store: bool, off: u32, w: Width, signed: bool) {
	assert(w == .B16 || w == .B32, "native: import access width")
	load_imp(a, IP0, imp(a, base))
	size: u32 = 2 if w == .B16 else 4
	op: u32
	switch {
	case store:
		op = 0x78000000 if w == .B16 else 0xb8000000 // sturh, stur w
	case w == .B16:
		op = 0x78c00000 if signed else 0x78400000 // ldursh w, ldurh
	case:
		op = 0xb8400000 // ldur w
	}
	if off % size == 0 && off / size < 4096 {
		// The scaled form: strh, str w, ldrsh w, ldrh, ldr w.
		emit32(a, op | 0x01000000 | off / size << 10 | IP0 << 5 | A64_REG[r])
	} else {
		assert(off < 256, "native: import offset")
		emit32(a, op | off << 12 | IP0 << 5 | A64_REG[r])
	}
}

a64_vec_shift16 :: proc(a: ^Asm, op: Alu, v: Vreg, n: u32) {
	r := u32(v)
	switch op {
	case .Shl:
		emit32(a, 0x4f005400 | (16 + n) << 16 | r << 5 | r) // shl .8h
	case .Shr, .Sar:
		emit32(a, (0x6f000400 if op == .Shr else 0x4f000400) | (32 - n) << 16 | r << 5 | r) // ushr/sshr .8h
	case .Add, .Sub, .And, .Or, .Xor:
		unreachable()
	}
}

a64_vec_shift32 :: proc(a: ^Asm, op: Alu, v: Vreg, n: u32) {
	r := u32(v)
	switch op {
	case .Shl:
		emit32(a, 0x4f005400 | (32 + n) << 16 | r << 5 | r) // shl .4s
	case .Shr, .Sar:
		emit32(a, (0x6f000400 if op == .Shr else 0x4f000400) | (64 - n) << 16 | r << 5 | r) // ushr/sshr .4s
	case .Add, .Sub, .And, .Or, .Xor:
		unreachable()
	}
}

a64_clz :: proc(a: ^Asm, dst: Reg) {
	d := A64_REG[dst]
	rrr(a, 0x5ac01000, d, d, 0) // clz wd, wd
}

a64_not :: proc(a: ^Asm, dst: Reg) {
	d := A64_REG[dst]
	rrr(a, 0x2a2003e0, d, 0, d) // orn wd, wzr, wd
}

a64_set_cond :: proc(a: ^Asm, c: Cond, dst, src: Reg) {
	d := A64_REG[dst]
	rrr(a, 0x6b00001f, 0, d, A64_REG[src]) // cmp wd, ws
	emit32(a, 0x1a9f07e0 | (CC[c] ~ 1) << 12 | d) // cset wd, c
}

a64_mul_wide :: proc(a: ^Asm, signed: bool, lo, hi: u32, x, y: Reg) {
	rrr(a, 0x9b207c00 if signed else 0x9ba07c00, T0, A64_REG[x], A64_REG[y]) // smull/umull x12
	ldst(a, 0xb9000000, T0, S, lo, 4)
	emit32(a, 0xd360fc00 | T0 << 5 | T0) // lsr x12, x12, #32
	ldst(a, 0xb9000000, T0, S, hi, 4)
}

a64_mac64 :: proc(a: ^Asm, op: Mac, x, y: Reg) {
	d := A64_REG[.A]
	switch op {
	case .Set:
		rrr(a, 0x9b207c00, d, A64_REG[x], A64_REG[y]) // smull xA, x, y
	case .Add:
		rrr(a, 0x9b200000 | d << 10, d, A64_REG[x], A64_REG[y]) // smaddl xA, x, y, xA
	case .Sub:
		rrr(a, 0x9b208000 | d << 10, d, A64_REG[x], A64_REG[y]) // smsubl xA, x, y, xA
	}
}

a64_mac64_split :: proc(a: ^Asm, dst: Reg) {
	d := A64_REG[.A]
	emit32(a, 0x9360fc00 | d << 5 | A64_REG[dst]) // asr x dst, xA, #32
	a64_mov(a, .A, .A) // the high half cleared
}

a64_mac64_wrap :: proc(a: ^Asm, n: u32, dst: Reg) {
	d := A64_REG[.A]
	emit32(a, 0x93400000 | (n - 1) << 10 | d << 5 | T0) // sbfx x12, xA, #0, #n
	rrr(a, 0xcb000000, T1, d, T0) // sub x13, xA, x12
	emit32(a, 0x9340fc00 | n << 16 | T1 << 5 | T1) // asr x13, x13, #n
	rrr(a, 0x2a0003e0, A64_REG[dst], 0, T1) // mov w dst, w13
	rrr(a, 0xaa0003e0, d, 0, T0) // mov xA, x12
}

a64_div_wide :: proc(a: ^Asm, signed: bool, lo, hi: u32, x, y: Reg) {
	rrr(a, 0x1ac00c00 if signed else 0x1ac00800, T0, A64_REG[x], A64_REG[y]) // sdiv/udiv w12
	emit32(a, 0x1b008000 | A64_REG[y] << 16 | A64_REG[x] << 10 | T0 << 5 | T1) // msub w13, w12, y, x
	ldst(a, 0xb9000000, T0, S, lo, 4)
	ldst(a, 0xb9000000, T1, S, hi, 4)
}

a64_call :: proc(a: ^Asm, k: int, args: []Reg) {
	for r, n in args {
		rrr(a, 0x2a0003e0, u32(n), 0, A64_REG[r]) // mov wn, r
	}
	emit32(a, 0xaa0003e0 | CTX << 16 | u32(len(args))) // the context, last
	load_imp(a, IP0, k)
	emit32(a, 0xd63f0000 | IP0 << 5) // blr x16
	rrr(a, 0x2a0003e0, A64_REG[.A], 0, 0) // mov w9, w0
}

// a64_call's sequence with no arguments, to a label in the code.
a64_call_func :: proc(a: ^Asm, l: Label) {
	emit32(a, 0xaa0003e0 | CTX << 16) // mov x0, the context
	a64_call_label(a, l)
}

a64_jmp :: proc(a: ^Asm, l: Label) {
	branch(a, 0x14000000, .A64_B26, l)
}

a64_br_zero :: proc(a: ^Asm, r: Reg, l: Label, nonzero: bool) {
	branch(a, (0x35000000 if nonzero else 0x34000000) | A64_REG[r], .A64_B19, l) // cbnz/cbz
}

a64_br_cmp_imm :: proc(a: ^Asm, c: Cond, r: Reg, v: u32, l: Label) {
	if v < 4096 {
		emit32(a, 0x7100001f | v << 10 | A64_REG[r] << 5) // cmp wr, #v
	} else {
		movw(a, T0, v)
		rrr(a, 0x6b00001f, 0, A64_REG[r], T0)
	}
	branch(a, 0x54000000 | CC[c], .A64_B19, l)
}

a64_br_state64_below :: proc(a: ^Asm, off: u32, limit: int, l: Label) {
	load_imp(a, T0, limit)
	emit32(a, 0xf9400000 | T0 << 5 | T0) // ldr x12, [x12]
	ldst(a, 0xf9400000, T1, S, off, 8)
	rrr(a, 0xeb00001f, 0, T1, T0) // cmp x13, x12
	branch(a, 0x54000000 | CC[.Ltu], .A64_B19, l) // b.lo
}

a64_br_byte_clear :: proc(a: ^Asm, addr, mask: int, l: Label) {
	load_imp(a, T0, addr)
	emit32(a, 0x39400000 | T0 << 5 | T0) // ldrb w12, [x12]
	if mask < 0 {
		branch(a, 0x34000000 | T0, .A64_B19, l) // cbz
		return
	}
	load_imp(a, T1, mask)
	rrr(a, 0x6a00001f, 0, T0, T1) // tst w12, w13
	branch(a, 0x54000000 | CC[.Eq], .A64_B19, l)
}

// The immr and imms fields of a 32-bit logical immediate: one run of ones.
@(private = "file")
logical :: proc(v: u32) -> u32 {
	lo := u32(intrinsics.count_trailing_zeros(v))
	n := u32(intrinsics.count_trailing_zeros(~(v >> lo)))
	assert(v != 0 && n < 32 && v >> lo == 1 << n - 1, "native: logical immediate")
	return (32 - lo) % 32 << 16 | (n - 1) << 10
}

// w12 = the RAM offset of the guest address in A; to far when it is not RAM.
@(private = "file")
ram_index :: proc(a: ^Asm, far: Label) {
	r := a.ram
	emit32(a, 0x7200001f | logical(r.outside) | A64_REG[.A] << 5) // tst wA, #outside
	branch(a, 0x54000000 | CC[.Ne], .A64_B19, far)
	emit32(a, 0x12000000 | logical(r.size - 1) | A64_REG[.A] << 5 | T0) // and w12, wA, #size - 1
}

// B64 and B128 copy into the field at s.off, through x13 or q0.
a64_load :: proc(a: ^Asm, s: Slow, far: Label) {
	ram_index(a, far)
	load_at(a, s)
}

// The load from [x23, x12].
@(private = "file")
load_at :: proc(a: ^Asm, s: Slow) {
	OPS :: [Width][2]u32 {
		.B8   = {0x38606800, 0x38e06800}, // ldrb, ldrsb w
		.B16  = {0x78606800, 0x78e06800}, // ldrh, ldrsh w
		.B32  = {0xb8606800, 0xb8606800}, // ldr w
		.B64  = {},
		.B128 = {},
	}
	ops := OPS
	switch s.w {
	case .B8, .B16, .B32:
		rrr(a, ops[s.w][1 if s.signed else 0], A64_REG[.A], RAM, T0) // [x23, x12]
	case .B64:
		rrr(a, 0xf8606800, T1, RAM, T0) // ldr x13, [x23, x12]
		ldst(a, 0xf9000000, T1, S, s.off, 8)
	case .B128:
		rrr(a, 0x3ce06800, 0, RAM, T0) // ldr q0, [x23, x12]
		a64_vec_ldst(a, .V0, s.off, true, s.base)
	}
}

// To guarded when a guard is set, to far when the address is not RAM or
// its page byte is set.
a64_store :: proc(a: ^Asm, s: Slow, far, guarded: Label) {
	r := a.ram
	for g in r.guards {
		load_imp(a, T1, imp(a, g.addr))
		emit32(a, 0x39400000 | T1 << 5 | T1) // ldrb w13, [x13]
		emit32(a, 0x7200001f | logical(u32(g.mask)) | T1 << 5) // tst w13, #mask
		branch(a, 0x54000000 | CC[.Ne], .A64_B19, guarded)
	}
	ram_index(a, far)
	emit32(a, 0x53007c00 | r.page_shift << 16 | T0 << 5 | T1) // lsr w13, w12, #page_shift
	rrr(a, 0x38606800, T1, PAGES, T1) // ldrb w13, [x24, x13]
	branch(a, 0x35000000 | T1, .A64_B19, far) // cbnz
	store_at(a, s)
}

// The store to [x23, x12]. B64 and B128 copy the field at s.off (or zero)
// through x13 or q0.
@(private = "file")
store_at :: proc(a: ^Asm, s: Slow) {
	OPS :: [Width]u32 {
		.B8   = 0x38206800, // strb
		.B16  = 0x78206800, // strh
		.B32  = 0xb8206800, // str w
		.B64  = 0xf8206800, // str x
		.B128 = 0x3ca06800, // str q
	}
	ops := OPS
	src := A64_REG[.B]
	switch s.w {
	case .B8, .B16, .B32:
	case .B64:
		src = ZR
		if !s.zero {
			src = T1
			ldst(a, 0xf9400000, T1, S, s.off, 8)
		}
	case .B128:
		src = 0
		if s.zero {
			emit32(a, 0x6f00e400) // movi v0.2d, #0
		} else {
			a64_vec_ldst(a, .V0, s.off, false, s.base)
		}
	}
	rrr(a, ops[s.w], src, RAM, T0) // [x23, x12]
}

// The load or store s at byte C of the window: its address less x23 plus
// C makes the index in x12.
a64_window :: proc(a: ^Asm, s: Slow) {
	load_imp(a, T0, imp(a, a.ram.window))
	rrr(a, 0xcb000000, T0, T0, RAM) // sub x12, x12, x23
	rrr(a, 0x8b000000, T0, T0, A64_REG[.C]) // add x12, x12, x11
	if s.store {
		store_at(a, s)
	} else {
		load_at(a, s)
	}
}

a64_call_label :: proc(a: ^Asm, l: Label) {
	branch(a, 0x94000000, .A64_B26, l) // bl
}

a64_return :: proc(a: ^Asm) {
	emit32(a, 0xd65f03c0) // ret
}

// A slow routine's call into the runtime keeps the link register on the stack.
a64_slow_frame :: proc(a: ^Asm, enter: bool) {
	emit32(a, 0xa9bf7bfd if enter else 0xa8c17bfd) // stp x29, x30, [sp, #-16]! / ldp x29, x30, [sp], #16
}
