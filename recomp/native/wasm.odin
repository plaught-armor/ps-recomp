// WebAssembly encoding of the operations in asm.odin: finish returns one
// module rather than machine code.
//
// The module imports env.memory (the runtime's linear memory), env.table
// (its function table), one immutable i32 global env.s<k> per import slot k
// (the slot's address or value; for a procedure, its index in the table)
// and env.base, the table index the module's functions start at: the
// element section puts generated function k at base + k, and a Blob_Func's
// offset is k. Odin procedures are called with call_indirect through their
// slot's global, the context last, as the Odin calling convention on
// wasm32 passes it.
//
// A generated function has type (pc, ctx: i32) -> (). The Regs, the cached
// fields and the Vregs are locals. Wasm has no goto, so the operations
// record items (code, label binds, branches) and the function is laid out
// when it is done (wasm_finalize): a forward branch's label becomes the end
// of a block, a backward one's the start of a loop, and a label whose
// constructs cannot nest is reached through a dispatch loop at the top of
// the function, which a br_table on a local enters at the label's region.
//
// The shared slow routines become functions of type (a, b: i32) -> i64:
// they do the access in place when they can and else return 1 in the high
// half, and the caller then makes the runtime call itself, since only the
// caller holds the cached fields.
package native

import "core:fmt"
import "core:slice"

// Function layout state, Asm.wa.
@(private)
Wasm :: struct {
	items:   [dynamic]Wasm_Item, // of the open function
	mark:    int, // a.code before it is not in an item yet
	at_item: map[Label]int, // the Bind item of each label bound in the open function
	calls:   [dynamic]Wasm_Fix, // call targets in a.code, of the open function
	fixes:   [dynamic]Wasm_Fix, // call targets in out
	out:     [dynamic]u8, // the function bodies, locals and code
	bodies:  [dynamic]Wasm_Body,
	types:   [dynamic]Wasm_Type,
	open:    bool, // a function is being emitted and not laid out yet
	n_funcs: int,
	st:      int, // import index of the open function's state
}

@(private)
Wasm_Item :: struct {
	kind:   Wasm_Item_Kind,
	label:  Label,
	lo, hi: int, // a.code range: Code's bytes, or Br_If's condition
}

@(private)
Wasm_Item_Kind :: enum u8 {
	Code,
	Bind,
	Br,
	Br_If,
}

// A 5-byte function index field at `at`, to be the index label is bound to.
@(private)
Wasm_Fix :: struct {
	at:    int,
	label: Label,
}

@(private)
Wasm_Body :: struct {
	lo, hi: int, // in out
	type:   int,
}

@(private)
Wasm_Type :: struct {
	params: [5]u8,
	n:      u8,
	result: u8, // 0: none
}

// Locals of a generated function: the parameters, then 12 i32, 2 i64 and
// 6 v128.
@(private = "file")
L_PC :: 0
@(private = "file")
L_CTX :: 1
@(private = "file")
L_REG :: 2 // A, B, C, T, LD
@(private = "file")
L_CACHE :: 7 // CACHE_MAX
@(private = "file")
L_D :: 11 // the dispatch region
@(private = "file")
L_T0 :: 12
@(private = "file")
L_T1 :: 13
@(private = "file")
L_ACC :: 14 // mac64's sum
@(private = "file")
L_W :: 15
@(private = "file")
L_V :: 16 // V0 to V4
@(private = "file")
L_VT :: 21

// Locals of a slow routine: a and b, then 3 i32, 2 i64 and 1 v128.
@(private = "file")
S_A :: 0
@(private = "file")
S_B :: 1
@(private = "file")
S_C :: 2
@(private = "file")
S_T :: 3
@(private = "file")
S_U :: 4
@(private = "file")
S_W :: 5
@(private = "file")
S_X :: 6

@(private = "file")
I32 :: 0x7f
@(private = "file")
I64 :: 0x7e
@(private = "file")
V128 :: 0x7b
@(private = "file")
VOID :: 0x40

// Scalar opcodes.
@(private = "file")
OP_UNREACHABLE :: 0x00
@(private = "file")
OP_BLOCK :: 0x02
@(private = "file")
OP_LOOP :: 0x03
@(private = "file")
OP_IF :: 0x04
@(private = "file")
OP_ELSE :: 0x05
@(private = "file")
OP_END :: 0x0b
@(private = "file")
OP_BR :: 0x0c
@(private = "file")
OP_BR_IF :: 0x0d
@(private = "file")
OP_BR_TABLE :: 0x0e
@(private = "file")
OP_RETURN :: 0x0f
@(private = "file")
OP_CALL :: 0x10
@(private = "file")
OP_CALL_INDIRECT :: 0x11
@(private = "file")
OP_SELECT :: 0x1b
@(private = "file")
I32_LOAD :: 0x28
@(private = "file")
I64_LOAD :: 0x29
@(private = "file")
I32_LOAD8_S :: 0x2c
@(private = "file")
I32_LOAD8_U :: 0x2d
@(private = "file")
I32_LOAD16_S :: 0x2e
@(private = "file")
I32_LOAD16_U :: 0x2f
@(private = "file")
I64_LOAD32_U :: 0x35
@(private = "file")
I32_STORE :: 0x36
@(private = "file")
I64_STORE :: 0x37
@(private = "file")
I32_STORE8 :: 0x3a
@(private = "file")
I32_STORE16 :: 0x3b
@(private = "file")
I64_STORE32 :: 0x3e
@(private = "file")
I32_EQZ :: 0x45
@(private = "file")
I32_EQ :: 0x46
@(private = "file")
I32_LT_U :: 0x49
@(private = "file")
I64_LT_U :: 0x54
@(private = "file")
F32_LT :: 0x5d
@(private = "file")
I32_CLZ :: 0x67
@(private = "file")
I32_ADD :: 0x6a
@(private = "file")
I32_SUB :: 0x6b
@(private = "file")
I32_AND :: 0x71
@(private = "file")
I32_SHL :: 0x74
@(private = "file")
I32_SHR_U :: 0x76
@(private = "file")
I32_XOR :: 0x73
@(private = "file")
I64_ADD :: 0x7c
@(private = "file")
I64_SUB :: 0x7d
@(private = "file")
I64_MUL :: 0x7e
@(private = "file")
I64_AND :: 0x83
@(private = "file")
I64_OR :: 0x84
@(private = "file")
I64_XOR :: 0x85
@(private = "file")
I64_SHL :: 0x86
@(private = "file")
I64_SHR_S :: 0x87
@(private = "file")
I64_SHR_U :: 0x88
@(private = "file")
I32_WRAP :: 0xa7
@(private = "file")
I64_EXTEND_S :: 0xac
@(private = "file")
I64_EXTEND_U :: 0xad
@(private = "file")
F32_CONVERT_S :: 0xb2
@(private = "file")
I32_REINTERPRET :: 0xbc
@(private = "file")
F32_REINTERPRET :: 0xbe

// SIMD opcodes, after the 0xfd prefix.
@(private = "file")
V_LOAD :: 0x00
@(private = "file")
V_LOAD32_SPLAT :: 0x09
@(private = "file")
V_STORE :: 0x0b
@(private = "file")
V_SHUFFLE :: 0x0d
@(private = "file")
V_I32_SPLAT :: 0x11
@(private = "file")
V_F32_LT :: 0x43
@(private = "file")
V_NOT :: 0x4d
@(private = "file")
V_AND :: 0x4e
@(private = "file")
V_ANDNOT :: 0x4f
@(private = "file")
V_OR :: 0x50
@(private = "file")
V_XOR :: 0x51
@(private = "file")
V_BITSELECT :: 0x52
@(private = "file")
V_I16_SUB_SAT_S :: 0x92
@(private = "file")
V_I16_MAX_S :: 0x98
@(private = "file")
V_I32_LT_U :: 0x3a
@(private = "file")
V_I32_GT_U :: 0x3c
@(private = "file")
V_I32_ABS :: 0xa0
@(private = "file")
V_I32_BITMASK :: 0xa4
@(private = "file")
V_I32_SHR_S :: 0xac
@(private = "file")
V_I32_ADD :: 0xae
@(private = "file")
V_I32_SUB :: 0xb1
@(private = "file")
V_TRUNC_SAT :: 0xf8
@(private = "file")
V_CONVERT :: 0xfa

@(private = "file", rodata)
ALU_OP := [Alu]u8 {
	.Add = 0x6a,
	.Sub = 0x6b,
	.And = 0x71,
	.Or  = 0x72,
	.Xor = 0x73,
	.Shl = 0x74,
	.Shr = 0x76,
	.Sar = 0x75,
}

@(private = "file", rodata)
COND_OP := [Cond]u8 {
	.Eq  = 0x46,
	.Ne  = 0x47,
	.Lt  = 0x48,
	.Ge  = 0x4e,
	.Le  = 0x4c,
	.Gt  = 0x4a,
	.Ltu = 0x49,
	.Geu = 0x4f,
}

// The vector ops that are one SIMD instruction on dst and src; 0: not one.
@(private = "file", rodata)
VOP_SIMPLE := [Vop]u32 {
	.Or       = V_OR,
	.Add16    = 0x8e,
	.Sub32    = V_I32_SUB,
	.Max16    = V_I16_MAX_S,
	.Min16    = 0x96,
	.Gt16     = 0x31,
	.Nor      = 0,
	.Zip_Lo8  = 0,
	.Zip_Hi8  = 0,
	.Zip_Lo64 = 0,
	.Zip_Hi64 = 0,
	.Zip_Lo16 = 0,
	.Even8    = 0,
	.Even16   = 0,
	.And      = V_AND,
	.Andn     = 0,
	.Eq32     = 0x37,
	.Fadd     = 0xe4,
	.Fsub     = 0xe5,
	.Fmul     = 0xe6,
	.Fdiv     = 0xe7,
	.Itof     = 0,
	.Ftoi     = 0,
	.Gt32     = 0x3b,
	.Xor      = V_XOR,
	.Sub8     = 0x71,
	.Zip_Lo32 = 0,
	.Zip_Hi32 = 0,
	.Dup16    = 0,
	.Adds16   = 0x8f,
	.Addu8    = 0x70,
	.Add32    = V_I32_ADD,
	.Addu32   = 0,
	.Madd16   = 0xba,
	.Sub16    = 0x91,
	.Add8     = 0x6e,
	.Eq16     = 0x2d,
	.Zip_Hi16 = 0,
	.Adds8    = 0x6f,
	.Subs8    = 0x72,
	.Subs16   = V_I16_SUB_SAT_S,
	.Addu16   = 0x90,
	.Subu8    = 0x73,
	.Subu16   = 0x93,
	.Subu32   = 0,
	.Adds32   = 0,
	.Subs32   = 0,
	.Gt8      = 0x27,
	.Eq8      = 0x23,
	.Max32    = 0xb8,
	.Min32    = 0xb6,
	.Abs16    = 0,
	.Abs32    = 0,
	.Even32   = 0,
	.Min32p   = 0,
}

// ---------------------------------------------------------------- encoding

@(private = "file")
wa_uleb :: proc(buf: ^[dynamic]u8, v: u64) {
	v := v
	for {
		b := u8(v & 0x7f)
		v >>= 7
		if v == 0 {
			append(buf, b)
			return
		}
		append(buf, b | 0x80)
	}
}

@(private = "file")
wa_sleb :: proc(buf: ^[dynamic]u8, v: i64) {
	v := v
	for {
		b := u8(v & 0x7f)
		v >>= 7
		if (v == 0 && b & 0x40 == 0) || (v == -1 && b & 0x40 != 0) {
			append(buf, b)
			return
		}
		append(buf, b | 0x80)
	}
}

@(private = "file")
wa_local :: proc(a: ^Asm, op: u8, l: int) {
	emit8(a, op)
	wa_uleb(&a.code, u64(l))
}

@(private = "file")
wa_get :: proc(a: ^Asm, l: int) {wa_local(a, 0x20, l)}
@(private = "file")
wa_set :: proc(a: ^Asm, l: int) {wa_local(a, 0x21, l)}
@(private = "file")
wa_tee :: proc(a: ^Asm, l: int) {wa_local(a, 0x22, l)}
@(private = "file")
wa_global :: proc(a: ^Asm, k: int) {wa_local(a, 0x23, k)}

@(private = "file")
wa_reg :: proc(r: Reg) -> int {return L_REG + int(r)}
@(private = "file")
wa_vreg :: proc(v: Vreg) -> int {return L_V + int(v)}

@(private = "file")
wa_i32 :: proc(a: ^Asm, v: u32) {
	emit8(a, 0x41)
	wa_sleb(&a.code, i64(i32(v)))
}

@(private = "file")
wa_i64 :: proc(a: ^Asm, v: i64) {
	emit8(a, 0x42)
	wa_sleb(&a.code, v)
}

// A load or store: its memarg, the alignment's log2 and the offset.
@(private = "file")
wa_mem :: proc(a: ^Asm, op: u8, align: u32, off: u32) {
	emit8(a, op)
	wa_uleb(&a.code, u64(align))
	wa_uleb(&a.code, u64(off))
}

@(private = "file")
wa_simd :: proc(a: ^Asm, op: u32) {
	emit8(a, 0xfd)
	wa_uleb(&a.code, u64(op))
}

@(private = "file")
wa_simd_mem :: proc(a: ^Asm, op: u32, align: u32, off: u32) {
	wa_simd(a, op)
	wa_uleb(&a.code, u64(align))
	wa_uleb(&a.code, u64(off))
}

@(private = "file")
wa_shuffle :: proc(a: ^Asm, lanes: [16]u8) {
	wa_simd(a, V_SHUFFLE)
	lanes := lanes
	emit8(a, ..lanes[:])
}

@(private = "file")
wa_splat :: proc(a: ^Asm, v: u32) {
	wa_i32(a, v)
	wa_simd(a, V_I32_SPLAT)
}

// The state field at off of the open function's state.
@(private = "file")
wa_state :: proc(a: ^Asm) {wa_global(a, a.wa.st)}

// A call to the function label l is bound to: a 5-byte index, patched in
// wasm_finish.
@(private = "file")
wa_call_label :: proc(a: ^Asm, l: Label) {
	emit8(a, OP_CALL)
	append(&a.wa.calls, Wasm_Fix{len(a.code), l})
	emit8(a, 0x80, 0x80, 0x80, 0x80, 0x00)
}

@(private = "file")
wa_type :: proc(a: ^Asm, params: []u8, result: u8) -> int {
	assert(len(params) <= 5, "native: wasm32 type arity")
	t := Wasm_Type{n = u8(len(params)), result = result}
	copy(t.params[:], params)
	for u, k in a.wa.types {
		if u == t {return k}
	}
	append(&a.wa.types, t)
	return len(a.wa.types) - 1
}

// ---------------------------------------------------------------- items

// The code since the last item becomes one.
@(private = "file")
wa_flush :: proc(a: ^Asm) {
	w := &a.wa
	if len(a.code) > w.mark {
		append(&w.items, Wasm_Item{kind = .Code, lo = w.mark, hi = len(a.code)})
		w.mark = len(a.code)
	}
}

// A conditional branch to l on the i32 the code since wa_flush pushed.
@(private = "file")
wa_br_if :: proc(a: ^Asm, l: Label) {
	w := &a.wa
	append(&w.items, Wasm_Item{kind = .Br_If, label = l, lo = w.mark, hi = len(a.code)})
	w.mark = len(a.code)
}

wasm_bind :: proc(a: ^Asm, l: Label) {
	assert(a.wa.open, "native: wasm32 bind outside a function")
	w := &a.wa
	wa_flush(a)
	a.labels[l] = -2 // bound; branches resolve when the function is laid out
	w.at_item[l] = len(w.items)
	append(&w.items, Wasm_Item{kind = .Bind, label = l})
}

wasm_jmp :: proc(a: ^Asm, l: Label) {
	wa_flush(a)
	append(&a.wa.items, Wasm_Item{kind = .Br, label = l})
}

wasm_br_zero :: proc(a: ^Asm, r: Reg, l: Label, nonzero: bool) {
	wa_flush(a)
	wa_get(a, wa_reg(r))
	if !nonzero {emit8(a, I32_EQZ)}
	wa_br_if(a, l)
}

wasm_br_cmp_imm :: proc(a: ^Asm, c: Cond, r: Reg, v: u32, l: Label) {
	wa_flush(a)
	wa_get(a, wa_reg(r))
	wa_i32(a, v)
	emit8(a, COND_OP[c])
	wa_br_if(a, l)
}

wasm_br_state64_below :: proc(a: ^Asm, off: u32, limit: int, l: Label) {
	wa_flush(a)
	wa_state(a)
	wa_mem(a, I64_LOAD, 3, off)
	wa_global(a, limit)
	wa_mem(a, I64_LOAD, 3, 0)
	emit8(a, I64_LT_U)
	wa_br_if(a, l)
}

wasm_br_byte_clear :: proc(a: ^Asm, addr: int, mask: int, l: Label) {
	wa_flush(a)
	wa_global(a, addr)
	wa_mem(a, I32_LOAD8_U, 0, 0)
	if mask >= 0 {
		wa_global(a, mask)
		emit8(a, I32_AND)
	}
	emit8(a, I32_EQZ)
	wa_br_if(a, l)
}

// ---------------------------------------------------------------- functions

wasm_func_begin :: proc(a: ^Asm, state: string) -> int {
	w := &a.wa
	if w.open {wasm_finalize(a)}
	a.state = state
	w.st = imp(a, state)
	a.epilogue = new_label(a)
	idx := w.n_funcs
	w.n_funcs += 1
	w.open = true
	w.mark = len(a.code)
	cache_sync(a, false)
	return idx
}

// The function's end. Code may still follow it (a shared lookup, as the
// r5900 backend places after func_end): the function is laid out at the
// next func_begin or at finish.
wasm_func_end :: proc(a: ^Asm) {
	assert(a.wa.open, "native: wasm32 func_end outside a function")
	bind(a, a.epilogue)
	wasm_ret(a)
}

wasm_ret :: proc(a: ^Asm) {
	cache_sync(a, true)
	emit8(a, OP_RETURN)
}

wasm_cache_sync :: proc(a: ^Asm, k: int, off: u32, store: bool) {
	if store {
		wa_state(a)
		wa_get(a, L_CACHE + k)
		wa_mem(a, I32_STORE, 2, off)
	} else {
		wa_state(a)
		wa_mem(a, I32_LOAD, 2, off)
		wa_set(a, L_CACHE + k)
	}
}

wasm_cache_mov :: proc(a: ^Asm, r: Reg, k: int, to_cache: bool) {
	if to_cache {
		wa_get(a, wa_reg(r))
		wa_set(a, L_CACHE + k)
	} else {
		wa_get(a, L_CACHE + k)
		wa_set(a, wa_reg(r))
	}
}

wasm_cache_imm :: proc(a: ^Asm, k: int, v: u32) {
	wa_i32(a, v)
	wa_set(a, L_CACHE + k)
}

// ---------------------------------------------------------------- scalar

wasm_state_load :: proc(a: ^Asm, dst: Reg, off: u32) {
	wa_state(a)
	wa_mem(a, I32_LOAD, 2, off)
	wa_set(a, wa_reg(dst))
}

wasm_state_store :: proc(a: ^Asm, off: u32, src: Reg) {
	wa_state(a)
	wa_get(a, wa_reg(src))
	wa_mem(a, I32_STORE, 2, off)
}

wasm_state_add64 :: proc(a: ^Asm, off, v: u32) {
	wa_state(a)
	wa_state(a)
	wa_mem(a, I64_LOAD, 3, off)
	wa_i64(a, i64(v))
	emit8(a, I64_ADD)
	wa_mem(a, I64_STORE, 3, off)
}

wasm_mov_imm :: proc(a: ^Asm, dst: Reg, v: u32) {
	wa_i32(a, v)
	wa_set(a, wa_reg(dst))
}

wasm_mov :: proc(a: ^Asm, dst, src: Reg) {
	wa_get(a, wa_reg(src))
	wa_set(a, wa_reg(dst))
}

wasm_alu :: proc(a: ^Asm, op: Alu, dst, src: Reg) {
	wa_get(a, wa_reg(dst))
	wa_get(a, wa_reg(src))
	emit8(a, ALU_OP[op])
	wa_set(a, wa_reg(dst))
}

wasm_alu_imm :: proc(a: ^Asm, op: Alu, dst: Reg, v: u32) {
	wa_get(a, wa_reg(dst))
	wa_i32(a, v)
	emit8(a, ALU_OP[op])
	wa_set(a, wa_reg(dst))
}

wasm_clz :: proc(a: ^Asm, dst: Reg) {
	wa_get(a, wa_reg(dst))
	emit8(a, I32_CLZ)
	wa_set(a, wa_reg(dst))
}

wasm_not :: proc(a: ^Asm, dst: Reg) {
	wasm_alu_imm(a, .Xor, dst, 0xffffffff)
}

wasm_set_cond :: proc(a: ^Asm, c: Cond, dst, src: Reg) {
	wa_get(a, wa_reg(dst))
	wa_get(a, wa_reg(src))
	emit8(a, COND_OP[c])
	wa_set(a, wa_reg(dst))
}

wasm_imp_ldst :: proc(a: ^Asm, r: Reg, base: string, store: bool, off: u32, w: Width, signed: bool) {
	assert(w == .B32 || w == .B16, "native: imp_load width")
	wa_global(a, imp(a, base))
	if store {
		wa_get(a, wa_reg(r))
		wa_mem(a, I32_STORE if w == .B32 else I32_STORE16, 2 if w == .B32 else 1, off)
		return
	}
	op := u8(I32_LOAD)
	if w == .B16 {op = I32_LOAD16_S if signed else I32_LOAD16_U}
	wa_mem(a, op, 2 if w == .B32 else 1, off)
	wa_set(a, wa_reg(r))
}

// ---------------------------------------------------------------- floats

wasm_float_op :: proc(a: ^Asm, op: Vop, dst, src: Reg) {
	OPS :: [4]u8{0x92, 0x93, 0x94, 0x95} // f32 add, sub, mul, div
	ops := OPS
	k := 0
	#partial switch op {
	case .Fadd:
		k = 0
	case .Fsub:
		k = 1
	case .Fmul:
		k = 2
	case .Fdiv:
		k = 3
	case:
		panic("native: float_op")
	}
	wa_get(a, wa_reg(dst))
	emit8(a, F32_REINTERPRET)
	wa_get(a, wa_reg(src))
	emit8(a, F32_REINTERPRET)
	emit8(a, ops[k])
	emit8(a, I32_REINTERPRET)
	wa_set(a, wa_reg(dst))
}

wasm_float_sqrt :: proc(a: ^Asm, r: Reg) {
	wa_get(a, wa_reg(r))
	emit8(a, F32_REINTERPRET, 0x91, I32_REINTERPRET) // f32.sqrt
	wa_set(a, wa_reg(r))
}

wasm_int_to_float :: proc(a: ^Asm, r: Reg) {
	wa_get(a, wa_reg(r))
	emit8(a, F32_CONVERT_S, I32_REINTERPRET)
	wa_set(a, wa_reg(r))
}

// trunc_sat, but 0x80000000 for NaN and at or above 2^31, as cvttss2si.
wasm_float_to_int :: proc(a: ^Asm, r: Reg) {
	wa_get(a, wa_reg(r))
	emit8(a, F32_REINTERPRET, 0xfc, 0x00) // i32.trunc_sat_f32_s
	wa_i32(a, 0x80000000)
	wa_get(a, wa_reg(r))
	emit8(a, F32_REINTERPRET)
	emit8(a, 0x43, 0x00, 0x00, 0x00, 0x4f) // f32.const 2^31
	emit8(a, F32_LT, OP_SELECT)
	wa_set(a, wa_reg(r))
}

// ---------------------------------------------------------------- vectors

wasm_vec_ldst :: proc(a: ^Asm, v: Vreg, off: u32, store: bool, base: string) {
	wa_global(a, a.wa.st if base == "" else imp(a, base))
	if store {
		wa_get(a, wa_vreg(v))
		wa_simd_mem(a, V_STORE, 4, off)
	} else {
		wa_simd_mem(a, V_LOAD, 4, off)
		wa_set(a, wa_vreg(v))
	}
}

wasm_vec_copy :: proc(a: ^Asm, dst, src: Vreg) {
	wa_get(a, wa_vreg(src))
	wa_set(a, wa_vreg(dst))
}

// The bytes of i8x16.shuffle for op; 0-15 are dst's and 16-31 src's. false:
// op is not a shuffle.
@(private = "file")
wa_vop_shuffle :: proc(op: Vop) -> (lanes: [16]u8, ok: bool) {
	#partial switch op {
	case .Zip_Lo8, .Zip_Hi8:
		at := u8(0 if op == .Zip_Lo8 else 8)
		for i in u8(0) ..< 8 {lanes[2 * i], lanes[2 * i + 1] = at + i, 16 + at + i}
	case .Zip_Lo64:
		for i in u8(0) ..< 8 {lanes[i], lanes[8 + i] = i, 16 + i}
	case .Zip_Hi64:
		for i in u8(0) ..< 8 {lanes[i], lanes[8 + i] = 8 + i, 24 + i}
	case .Zip_Lo16, .Zip_Hi16:
		at := u8(0 if op == .Zip_Lo16 else 4)
		for i in u8(0) ..< 4 {
			h := 2 * (at + i)
			lanes[4 * i], lanes[4 * i + 1] = h, h + 1
			lanes[4 * i + 2], lanes[4 * i + 3] = 16 + h, 17 + h
		}
	case .Zip_Lo32, .Zip_Hi32:
		at := u8(0 if op == .Zip_Lo32 else 2)
		for i in u8(0) ..< 2 {
			for j in u8(0) ..< 4 {
				lanes[8 * i + j] = 4 * (at + i) + j
				lanes[8 * i + 4 + j] = 16 + 4 * (at + i) + j
			}
		}
	case .Even8:
		for i in u8(0) ..< 16 {lanes[i] = 2 * i}
	case .Even16:
		for i in u8(0) ..< 8 {
			lanes[2 * i] = 4 * i
			lanes[2 * i + 1] = 4 * i + 1
		}
	case .Even32:
		for i in u8(0) ..< 4 {
			for j in u8(0) ..< 4 {lanes[4 * i + j] = 8 * i + j}
		}
	case:
		return {}, false
	}
	return lanes, true
}

wasm_vec_op :: proc(a: ^Asm, op: Vop, dst, src: Vreg) {
	d, s := wa_vreg(dst), wa_vreg(src)
	if code := VOP_SIMPLE[op]; code != 0 {
		wa_get(a, d)
		wa_get(a, s)
		wa_simd(a, code)
		wa_set(a, d)
		return
	}
	if lanes, ok := wa_vop_shuffle(op); ok {
		wa_get(a, d)
		wa_get(a, s)
		wa_shuffle(a, lanes)
		wa_set(a, d)
		return
	}
	#partial switch op {
	case .Nor:
		wa_get(a, d)
		wa_get(a, s)
		wa_simd(a, V_OR)
		wa_simd(a, V_NOT)
	case .Andn:
		wa_get(a, s)
		wa_get(a, d)
		wa_simd(a, V_ANDNOT)
	case .Itof:
		wa_get(a, s)
		wa_simd(a, V_CONVERT)
	case .Ftoi:
		// trunc_sat where src < 2^31, else 0x80000000 (NaN too), as cvttps2dq.
		wa_get(a, s)
		wa_simd(a, V_TRUNC_SAT)
		wa_splat(a, 0x80000000)
		wa_get(a, s)
		wa_splat(a, 0x4f000000)
		wa_simd(a, V_F32_LT)
		wa_simd(a, V_BITSELECT)
	case .Dup16:
		lanes: [16]u8
		for i in u8(0) ..< 4 {
			lanes[2 * i], lanes[2 * i + 1] = 0, 1
			lanes[8 + 2 * i], lanes[9 + 2 * i] = 8, 9
		}
		wa_get(a, s)
		wa_get(a, s)
		wa_shuffle(a, lanes)
	case .Addu32:
		// The sum, or all ones where it wrapped below dst.
		wa_get(a, d)
		wa_get(a, s)
		wa_simd(a, V_I32_ADD)
		wa_tee(a, L_VT)
		wa_get(a, L_VT)
		wa_get(a, d)
		wa_simd(a, V_I32_LT_U)
		wa_simd(a, V_OR)
	case .Subu32:
		// The difference where dst > src, else 0.
		wa_get(a, d)
		wa_get(a, s)
		wa_simd(a, V_I32_SUB)
		wa_get(a, d)
		wa_get(a, s)
		wa_simd(a, V_I32_GT_U)
		wa_simd(a, V_AND)
	case .Adds32, .Subs32:
		// r = dst op src; where it overflowed (r's sign differs from dst's
		// and from src's for an add, from dst's and not src's for a
		// subtract), the limit on dst's side.
		wa_get(a, d)
		wa_get(a, s)
		wa_simd(a, V_I32_ADD if op == .Adds32 else V_I32_SUB)
		wa_set(a, L_VT)
		wa_get(a, d)
		wa_i32(a, 31)
		wa_simd(a, V_I32_SHR_S)
		wa_splat(a, 0x7fffffff)
		wa_simd(a, V_XOR)
		wa_get(a, L_VT)
		wa_get(a, L_VT)
		wa_get(a, d)
		wa_simd(a, V_XOR)
		if op == .Adds32 {
			wa_get(a, L_VT)
			wa_get(a, s)
		} else {
			wa_get(a, d)
			wa_get(a, s)
		}
		wa_simd(a, V_XOR)
		wa_simd(a, V_AND)
		wa_i32(a, 31)
		wa_simd(a, V_I32_SHR_S)
		wa_simd(a, V_BITSELECT)
	case .Abs16:
		wa_splat(a, 0)
		wa_get(a, s)
		wa_simd(a, V_I16_SUB_SAT_S)
		wa_get(a, s)
		wa_simd(a, V_I16_MAX_S)
	case .Abs32:
		// abs leaves the least i32 as itself; adding its sign makes it the
		// largest.
		wa_get(a, s)
		wa_simd(a, V_I32_ABS)
		wa_tee(a, L_VT)
		wa_get(a, L_VT)
		wa_i32(a, 31)
		wa_simd(a, V_I32_SHR_S)
		wa_simd(a, V_I32_ADD)
	case .Min32p:
		wa_get(a, d)
		wa_get(a, s)
		wa_get(a, d)
		wa_get(a, s)
		wa_simd(a, V_F32_LT)
		wa_simd(a, V_BITSELECT)
	case:
		fmt.panicf("native: wasm32 vector op %v", op)
	}
	wa_set(a, d)
}

wasm_vec_shuf32 :: proc(a: ^Asm, dst, src: Vreg, lanes: [4]u8) {
	b: [16]u8
	for k in 0 ..< 4 {
		for j in u8(0) ..< 4 {b[4 * k + int(j)] = 4 * lanes[k] + j}
	}
	wa_get(a, wa_vreg(src))
	wa_get(a, wa_vreg(src))
	wa_shuffle(a, b)
	wa_set(a, wa_vreg(dst))
}

wasm_vec_shuf16 :: proc(a: ^Asm, dst, src: Vreg, lanes: [4]u8) {
	b: [16]u8
	for k in 0 ..< 4 {
		for j in u8(0) ..< 2 {
			b[2 * k + int(j)] = 2 * lanes[k] + j
			b[8 + 2 * k + int(j)] = 8 + 2 * lanes[k] + j
		}
	}
	wa_get(a, wa_vreg(src))
	wa_get(a, wa_vreg(src))
	wa_shuffle(a, b)
	wa_set(a, wa_vreg(dst))
}

wasm_vec_splat_load :: proc(a: ^Asm, dst: Vreg, base: string, off: u32) {
	wa_global(a, imp(a, base))
	wa_simd_mem(a, V_LOAD32_SPLAT, 2, off)
	wa_set(a, wa_vreg(dst))
}

// Lane 0's sign in bit 3: the lanes reversed, then bitmask.
wasm_vec_signs :: proc(a: ^Asm, dst: Reg, v: Vreg) {
	b: [16]u8
	for k in u8(0) ..< 4 {
		for j in u8(0) ..< 4 {b[4 * k + j] = 4 * (3 - k) + j}
	}
	wa_get(a, wa_vreg(v))
	wa_get(a, wa_vreg(v))
	wa_shuffle(a, b)
	wa_simd(a, V_I32_BITMASK)
	wa_set(a, wa_reg(dst))
}

wasm_vec_shift16 :: proc(a: ^Asm, op: Alu, v: Vreg, n: u32) {
	OPS :: [3]u32{0x8b, 0x8d, 0x8c} // i16x8 shl, shr_u, shr_s
	wasm_vec_shift(a, OPS, op, v, n)
}

wasm_vec_shift32 :: proc(a: ^Asm, op: Alu, v: Vreg, n: u32) {
	OPS :: [3]u32{0xab, 0xad, 0xac} // i32x4 shl, shr_u, shr_s
	wasm_vec_shift(a, OPS, op, v, n)
}

@(private = "file")
wasm_vec_shift :: proc(a: ^Asm, ops: [3]u32, op: Alu, v: Vreg, n: u32) {
	k := 0
	#partial switch op {
	case .Shl:
		k = 0
	case .Shr:
		k = 1
	case .Sar:
		k = 2
	case:
		panic("native: vector shift")
	}
	wa_get(a, wa_vreg(v))
	wa_i32(a, n)
	wa_simd(a, ops[k])
	wa_set(a, wa_vreg(v))
}

// lo and hi side by side in buf, then the 16 bytes from byte A.
wasm_vec_funnel8 :: proc(a: ^Asm, dst, lo, hi: u32, buf: int) {
	wa_global(a, buf)
	wa_state(a)
	wa_simd_mem(a, V_LOAD, 4, lo)
	wa_simd_mem(a, V_STORE, 4, 0)
	wa_global(a, buf)
	wa_state(a)
	wa_simd_mem(a, V_LOAD, 4, hi)
	wa_simd_mem(a, V_STORE, 4, 16)
	wa_state(a)
	wa_global(a, buf)
	wa_get(a, wa_reg(.A))
	emit8(a, I32_ADD)
	wa_simd_mem(a, V_LOAD, 0, 0)
	wa_simd_mem(a, V_STORE, 4, dst)
}

wasm_vec_ldst_at :: proc(a: ^Asm, v: Vreg, base: int, store: bool) {
	wa_global(a, base)
	wa_get(a, wa_reg(.A))
	emit8(a, I32_ADD)
	if store {
		wa_get(a, wa_vreg(v))
		wa_simd_mem(a, V_STORE, 0, 0)
	} else {
		wa_simd_mem(a, V_LOAD, 0, 0)
		wa_set(a, wa_vreg(v))
	}
}

// ---------------------------------------------------------------- wide

// The 64-bit product in w; lo and hi get its halves and A the low one, as
// x64 leaves eax.
wasm_mul_wide :: proc(a: ^Asm, signed: bool, lo, hi: u32, x, y: Reg) {
	ext := u8(I64_EXTEND_S if signed else I64_EXTEND_U)
	wa_get(a, wa_reg(x))
	emit8(a, ext)
	wa_get(a, wa_reg(y))
	emit8(a, ext)
	emit8(a, I64_MUL)
	wa_set(a, L_W)
	wa_state(a)
	wa_get(a, L_W)
	wa_mem(a, I64_STORE32, 2, lo)
	wa_state(a)
	wa_get(a, L_W)
	wa_i64(a, 32)
	emit8(a, I64_SHR_U)
	wa_mem(a, I64_STORE32, 2, hi)
	wa_get(a, L_W)
	emit8(a, I32_WRAP)
	wa_set(a, wa_reg(.A))
}

wasm_div_wide :: proc(a: ^Asm, signed: bool, lo, hi: u32, x, y: Reg) {
	div, rem := u8(0x6d), u8(0x6f) // i32.div_s, rem_s
	if !signed {div, rem = 0x6e, 0x70}
	wa_get(a, wa_reg(x))
	wa_get(a, wa_reg(y))
	emit8(a, div)
	wa_set(a, L_T0)
	wa_get(a, wa_reg(x))
	wa_get(a, wa_reg(y))
	emit8(a, rem)
	wa_set(a, L_T1)
	wa_state(a)
	wa_get(a, L_T0)
	wa_mem(a, I32_STORE, 2, lo)
	wa_state(a)
	wa_get(a, L_T1)
	wa_mem(a, I32_STORE, 2, hi)
	wa_get(a, L_T0)
	wa_set(a, wa_reg(.A))
}

// The sum lives in its own i64 local, and A gets its low half after each
// step. A write to A between steps does not reach the sum, as it does on
// x64; the backends start each sum with Set after one.
wasm_mac64 :: proc(a: ^Asm, op: Mac, x, y: Reg) {
	if op != .Set {wa_get(a, L_ACC)}
	wa_get(a, wa_reg(x))
	emit8(a, I64_EXTEND_S)
	wa_get(a, wa_reg(y))
	emit8(a, I64_EXTEND_S)
	emit8(a, I64_MUL)
	switch op {
	case .Set:
	case .Add:
		emit8(a, I64_ADD)
	case .Sub:
		emit8(a, I64_SUB)
	}
	wa_tee(a, L_ACC)
	emit8(a, I32_WRAP)
	wa_set(a, wa_reg(.A))
}

wasm_mac64_split :: proc(a: ^Asm, dst: Reg) {
	wa_get(a, L_ACC)
	wa_i64(a, 32)
	emit8(a, I64_SHR_S, I32_WRAP)
	wa_set(a, wa_reg(dst))
	wa_get(a, L_ACC)
	wa_i64(a, 0xffffffff)
	emit8(a, I64_AND)
	wa_tee(a, L_ACC)
	emit8(a, I32_WRAP)
	wa_set(a, wa_reg(.A))
}

wasm_mac64_wrap :: proc(a: ^Asm, n: u32, dst: Reg) {
	wa_get(a, L_ACC)
	wa_i64(a, i64(64 - n))
	emit8(a, I64_SHL)
	wa_i64(a, i64(64 - n))
	emit8(a, I64_SHR_S)
	wa_set(a, L_W)
	wa_get(a, L_ACC)
	wa_get(a, L_W)
	emit8(a, I64_SUB)
	wa_i64(a, i64(n))
	emit8(a, I64_SHR_S, I32_WRAP)
	wa_set(a, wa_reg(dst))
	wa_get(a, L_W)
	wa_tee(a, L_ACC)
	emit8(a, I32_WRAP)
	wa_set(a, wa_reg(.A))
}

// ---------------------------------------------------------------- calls

wasm_call :: proc(a: ^Asm, k: int, args: []Reg) {
	name := a.imports[k]
	if len(a.sig_index) == 0 {
		for s, i in a.sigs {a.sig_index[s.name] = i}
	}
	i, ok := a.sig_index[name]
	if !ok {fmt.panicf("native: wasm32 call of %s, which has no signature", name)}
	sig := a.sigs[i]
	if int(sig.args) != len(args) {
		fmt.panicf("native: wasm32 call of %s with %d arguments; its signature has %d", name, len(args), sig.args)
	}
	params := [5]u8{I32, I32, I32, I32, I32}
	t := wa_type(a, params[:sig.args + 1], I32 if sig.result else 0)
	for r in args {wa_get(a, wa_reg(r))}
	wa_get(a, L_CTX)
	wa_global(a, k)
	emit8(a, OP_CALL_INDIRECT)
	wa_uleb(&a.code, u64(t))
	emit8(a, 0x00) // table 0
	if sig.result {wa_set(a, wa_reg(.A))}
}

wasm_call_func :: proc(a: ^Asm, l: Label) {
	wa_i32(a, 0)
	wa_get(a, L_CTX)
	wa_call_label(a, l)
}

// ---------------------------------------------------------------- RAM

// The RAM address of guest address local l masked with mask.
@(private = "file")
wa_ram_at :: proc(a: ^Asm, l: int, mask: u32) {
	wa_global(a, imp(a, a.ram.base))
	wa_get(a, l)
	wa_i32(a, mask)
	emit8(a, I32_AND, I32_ADD)
}

// A, or a wide field, = the value at the address on the stack.
@(private = "file")
wa_load_at :: proc(a: ^Asm, s: Slow, base: int) {
	switch s.w {
	case .B8:
		emit8(a, I32_LOAD8_S if s.signed else I32_LOAD8_U, 0, 0)
	case .B16:
		emit8(a, I32_LOAD16_S if s.signed else I32_LOAD16_U, 1, 0)
	case .B32:
		emit8(a, I32_LOAD, 2, 0)
	case .B64:
		emit8(a, I64_LOAD, 3, 0)
		wa_mem(a, I64_STORE, 3, s.off)
	case .B128:
		wa_simd_mem(a, V_LOAD, 0, 0)
		wa_simd_mem(a, V_STORE, 4, s.off)
	}
	_ = base
}

// The state global a wide field of s is in.
@(private = "file")
wa_field :: proc(a: ^Asm, s: Slow) -> int {
	return imp(a, s.base) if s.base != "" else imp(a, s.state)
}

// The access the generated code makes off RAM's fast path: the slow routine
// s, then the runtime call when it returns its need.
@(private = "file")
wa_slow_seq :: proc(a: ^Asm, s: Slow) {
	s := s
	if s.w >= .B64 || s.unal != .None {s.state = a.state}
	at := slow_path(a, s)
	wa_get(a, wa_reg(.A))
	if s.store && s.w <= .B32 {wa_get(a, wa_reg(.B))} else {wa_i32(a, 0)}
	wa_call_label(a, at)
	wa_tee(a, L_W)
	emit8(a, I32_WRAP)
	wa_set(a, wa_reg(.A))
	wa_get(a, L_W)
	wa_i64(a, 32)
	emit8(a, I64_SHR_U, I32_WRAP)
	emit8(a, OP_IF, VOID)
	wa_runtime(a, s)
	emit8(a, OP_END)
}

// The runtime call of slow routine s.
@(private = "file")
wa_runtime :: proc(a: ^Asm, s: Slow) {
	if s.w >= .B64 {
		mov_imm(a, .B, s.n)
		call(a, s.slow, .A, .B)
	} else if s.store {
		call(a, s.slow, .A, .B)
	} else {
		call(a, s.slow, .A)
	}
}

wasm_load :: proc(a: ^Asm, s: Slow) {
	r := a.ram
	wa_get(a, wa_reg(.A))
	wa_i32(a, r.outside)
	emit8(a, I32_AND)
	emit8(a, OP_IF, VOID)
	if r.mirror_mask == 0 && r.window == "" {
		wa_runtime(a, s)
	} else {
		wa_slow_seq(a, s)
	}
	emit8(a, OP_ELSE)
	if s.w <= .B32 {
		wa_ram_at(a, wa_reg(.A), r.size - 1)
		wa_load_at(a, s, 0)
		wa_set(a, wa_reg(.A))
	} else {
		wa_global(a, a.wa.st if s.base == "" else imp(a, s.base))
		wa_ram_at(a, wa_reg(.A), r.size - 1)
		wa_load_at(a, s, 0)
	}
	emit8(a, OP_END)
}

wasm_slow_call :: proc(a: ^Asm, s: Slow) {
	wa_slow_seq(a, s)
}

// ---------------------------------------------------------------- slow routines

// i64 a | 1 << 32: not done, call the runtime with a.
@(private = "file")
wa_need :: proc(a: ^Asm) {
	wa_get(a, S_A)
	emit8(a, I64_EXTEND_U)
	wa_i64(a, 1 << 32)
	emit8(a, I64_OR)
}

// The access of s at the address on the stack, from a slow routine, then
// its return; c is the address local for an unaligned access.
@(private = "file")
wa_slow_access :: proc(a: ^Asm, s: Slow) {
	if s.unal != .None {
		wa_unal(a, s)
		wa_i64(a, 0)
		emit8(a, OP_RETURN)
		return
	}
	if !s.store {
		if s.w <= .B32 {
			wa_load_at(a, s, 0)
			emit8(a, I64_EXTEND_U)
		} else {
			// The field's global under the address: the address goes to u.
			wa_set(a, S_U)
			wa_global(a, wa_field(a, s))
			wa_get(a, S_U)
			wa_load_at(a, s, 0)
			wa_i64(a, 0)
		}
		emit8(a, OP_RETURN)
		return
	}
	switch s.w {
	case .B8:
		wa_get(a, S_B)
		wa_mem(a, I32_STORE8, 0, 0)
	case .B16:
		wa_get(a, S_B)
		wa_mem(a, I32_STORE16, 1, 0)
	case .B32:
		wa_get(a, S_B)
		wa_mem(a, I32_STORE, 2, 0)
	case .B64:
		if s.zero {
			wa_i64(a, 0)
		} else {
			wa_global(a, wa_field(a, s))
			wa_mem(a, I64_LOAD, 3, s.off)
		}
		wa_mem(a, I64_STORE, 0, 0)
	case .B128:
		if s.zero {
			wa_splat(a, 0)
		} else {
			wa_global(a, wa_field(a, s))
			wa_simd_mem(a, V_LOAD, 4, s.off)
		}
		wa_simd_mem(a, V_STORE, 0, 0)
	}
	wa_i64(a, 0)
	emit8(a, OP_RETURN)
}

// The merge of unaligned access s with the word or doubleword at the
// address on the stack, as merge_at in x64.odin: in i64, the register's
// field read as 32 bits for a word op, so a right shift brings in zeros.
@(private = "file")
wa_unal :: proc(a: ^Asm, s: Slow) {
	wide, left, from_top, store := unal_shape(s.unal)
	st := imp(a, s.state)
	wa_set(a, S_U)
	wa_get(a, S_U)
	if wide {wa_mem(a, I64_LOAD, 0, 0)} else {wa_mem(a, I64_LOAD32_U, 0, 0)}
	wa_set(a, S_W)
	wa_global(a, st)
	if wide {wa_mem(a, I64_LOAD, 3, s.off)} else {wa_mem(a, I64_LOAD32_U, 2, s.off)}
	wa_set(a, S_X)
	// t = 8 * the address's low bits, or the top count less that.
	if from_top {wa_i32(a, 56 if wide else 24)}
	wa_get(a, S_A)
	wa_i32(a, 7 if wide else 3)
	emit8(a, I32_AND)
	wa_i32(a, 3)
	emit8(a, I32_SHL)
	if from_top {emit8(a, I32_SUB)}
	wa_set(a, S_T)
	src, dst := S_W, S_X
	if store {src, dst = S_X, S_W}
	sh := u8(I64_SHL if left else I64_SHR_U)
	if store {
		wa_get(a, S_U)
	} else if s.unal != .LWR {
		wa_global(a, st)
	}
	// (((src sh t) ^ dst) & (mask sh t)) ^ dst
	wa_get(a, src)
	wa_get(a, S_T)
	emit8(a, I64_EXTEND_U, sh)
	wa_get(a, dst)
	emit8(a, I64_XOR)
	wa_i64(a, -1 if wide else 0xffffffff)
	wa_get(a, S_T)
	emit8(a, I64_EXTEND_U, sh, I64_AND)
	wa_get(a, dst)
	emit8(a, I64_XOR)
	if store {
		if wide {wa_mem(a, I64_STORE, 0, 0)} else {wa_mem(a, I64_STORE32, 0, 0)}
		return
	}
	if wide {
		wa_mem(a, I64_STORE, 3, s.off)
		return
	}
	if s.unal == .LWR {
		// The word's sign extends only with all four bytes loaded.
		wa_set(a, S_W)
		wa_global(a, st)
		wa_get(a, S_W)
		wa_get(a, S_T)
		wa_i32(a, 0x18)
		emit8(a, I32_AND)
		emit8(a, OP_IF, VOID)
		wa_mem(a, I64_STORE32, 2, s.off)
		emit8(a, OP_ELSE)
		emit8(a, I32_WRAP, I64_EXTEND_S)
		wa_mem(a, I64_STORE, 3, s.off)
		emit8(a, OP_END)
		return
	}
	emit8(a, I32_WRAP, I64_EXTEND_S)
	wa_mem(a, I64_STORE, 3, s.off)
}

// The body of slow routine s, in a.code:
//
//	loop $top
//	  block $call
//	    block $far
//	      guards (to $call), outside and page checks (to $far): store, unal
//	      the access in place: store, unal
//	    end
//	    mirror: masked and in place (a load), or masked and again ($top)
//	    window: in place
//	  end
//	  return the need
//	end
wasm_emit_slow :: proc(a: ^Asm, s: Slow) {
	r := a.ram
	ustore := false
	if s.unal != .None {_, _, _, ustore = unal_shape(s.unal)}
	guarded := s.store || ustore
	inline := s.store || s.unal != .None
	emit8(a, OP_LOOP, VOID, OP_BLOCK, VOID, OP_BLOCK, VOID)
	mask := r.size - 1
	if s.unal != .None {
		wide, _, _, _ := unal_shape(s.unal)
		mask &~= 7 if wide else 3
	}
	if guarded {
		for g in r.guards {
			wa_global(a, imp(a, g.addr))
			wa_mem(a, I32_LOAD8_U, 0, 0)
			wa_i32(a, u32(g.mask))
			emit8(a, I32_AND, OP_BR_IF, 1)
		}
	}
	if inline {
		wa_get(a, S_A)
		wa_i32(a, r.outside)
		emit8(a, I32_AND, OP_BR_IF, 0)
	}
	if guarded {
		wa_global(a, imp(a, r.pages))
		wa_get(a, S_A)
		wa_i32(a, mask)
		emit8(a, I32_AND)
		wa_i32(a, r.page_shift)
		emit8(a, I32_SHR_U, I32_ADD)
		wa_mem(a, I32_LOAD8_U, 0, 0)
		emit8(a, OP_BR_IF, 0)
	}
	if inline {
		wa_ram_at(a, S_A, mask)
		wa_slow_access(a, s)
	}
	emit8(a, OP_END) // $far
	if r.mirror_mask != 0 {
		// A load reads the RAM address in place; a store or an unaligned
		// access starts over with it, so the checks of RAM decide.
		wa_get(a, S_A)
		wa_i32(a, r.mirror_mask)
		emit8(a, I32_AND)
		wa_i32(a, r.mirror_bits)
		emit8(a, I32_EQ, OP_IF, VOID)
		wa_get(a, S_A)
		wa_i32(a, r.size - 1)
		emit8(a, I32_AND)
		wa_set(a, S_A)
		if inline {
			emit8(a, OP_BR, 2)
		} else {
			wa_get(a, S_A)
			wa_i32(a, r.outside)
			emit8(a, I32_AND, I32_EQZ, OP_IF, VOID)
			wa_ram_at(a, S_A, r.size - 1)
			wa_slow_access(a, s)
			emit8(a, OP_END)
		}
		emit8(a, OP_END)
	}
	if r.window != "" {
		// An access running past the end calls, so the bus decides it.
		wa_get(a, S_A)
		if r.window_mask != 0 {
			wa_i32(a, r.window_mask)
			emit8(a, I32_AND)
		}
		wa_i32(a, r.window_at)
		emit8(a, I32_SUB)
		wa_tee(a, S_C)
		wa_i32(a, r.window_size - (u32(1) << u32(s.w)) + 1)
		emit8(a, I32_LT_U, OP_IF, VOID)
		wa_global(a, imp(a, r.window))
		wa_get(a, S_C)
		if s.unal != .None {
			wide, _, _, _ := unal_shape(s.unal)
			wa_i32(a, ~u32(7 if wide else 3))
			emit8(a, I32_AND)
		}
		emit8(a, I32_ADD)
		wa_slow_access(a, s)
		emit8(a, OP_END)
	}
	emit8(a, OP_END) // $call
	wa_need(a)
	emit8(a, OP_RETURN, OP_END, OP_UNREACHABLE) // $top
}

// ---------------------------------------------------------------- layout

// Lay out the open function from its items into out.
@(private)
wasm_finalize :: proc(a: ^Asm) {
	w := &a.wa
	assert(w.open, "native: wasm32 layout with no function")
	wa_flush(a)
	items := w.items[:]
	n_items := len(items)

	Con :: struct {
		o, c:  int, // opens before item o, closes before item c
		label: Label,
		loop:  bool,
		dead:  bool,
	}
	Use :: struct {
		bind, fmin, bmax: int,
		block, loop:      int, // Con index, or -1
	}
	uses := make(map[Label]Use, context.temp_allocator)
	for it, i in items {
		if it.kind != .Br && it.kind != .Br_If {continue}
		b, ok := w.at_item[it.label]
		if !ok {fmt.panicf("native: wasm32 branch to label %d, not bound in its function", it.label)}
		u := uses[it.label] or_else Use{b, max(int), -1, -1, -1}
		if i < b {u.fmin = min(u.fmin, i)} else {u.bmax = max(u.bmax, i)}
		uses[it.label] = u
	}
	// Constructs in bind order, so the layout does not depend on the map's.
	cons := make([dynamic]Con, context.temp_allocator)
	for it in items {
		if it.kind != .Bind {continue}
		u, ok := &uses[it.label]
		if !ok {continue}
		if u.fmin < u.bind {
			u.block = len(cons)
			append(&cons, Con{o = u.fmin, c = u.bind, label = it.label})
		}
		if u.bmax > u.bind {
			u.loop = len(cons)
			append(&cons, Con{o = u.bind, c = u.bmax + 1, label = it.label, loop = true})
		}
	}
	demoted := make(map[Label]bool, context.temp_allocator)
	demote :: proc(cons: []Con, uses: map[Label]Use, demoted: ^map[Label]bool, l: Label) {
		demoted[l] = true
		u := uses[l]
		if u.block >= 0 {cons[u.block].dead = true}
		if u.loop >= 0 {cons[u.loop].dead = true}
	}
	order := make([]int, len(cons), context.temp_allocator)
	for &k, i in order {k = i}
	by_open :: proc(cons: []Con, order: []int) {
		context.user_ptr = raw_data(cons)
		slice.sort_by(order, proc(x, y: int) -> bool {
			cs := ([^]Con)(context.user_ptr)
			p, q := cs[x], cs[y]
			if p.o != q.o {return p.o < q.o}
			if p.c != q.c {return p.c > q.c}
			return x < y
		})
	}
	// One sweep in opening order makes the constructs nest: a block that
	// would cross the one it opens in opens before it instead, and a loop
	// that would ends with it; a loop that crosses a block makes the
	// block's label go through the dispatch.
	by_open(cons[:], order)
	stack := make([dynamic]int, context.temp_allocator)
	held := make([dynamic]int, context.temp_allocator)
	for x in order {
		X := &cons[x]
		if X.dead {continue}
		for len(stack) > 0 && (cons[stack[len(stack) - 1]].c <= X.o || cons[stack[len(stack) - 1]].dead) {
			pop(&stack)
		}
		clear(&held)
		for len(stack) > 0 {
			t := stack[len(stack) - 1]
			T := &cons[t]
			if T.dead {
				pop(&stack)
				continue
			}
			if T.c >= X.c {break}
			if !X.loop {
				X.o = T.o
				pop(&stack)
				append(&held, t)
			} else if T.loop {
				T.c = X.c
				pop(&stack)
				append(&held, t)
			} else {
				demote(cons[:], uses, &demoted, T.label)
				pop(&stack)
			}
		}
		if !X.loop {
			// X now holds what it was lifted over.
			append(&stack, x)
			#reverse for t in held {if !cons[t].dead {append(&stack, t)}}
		} else {
			// The extended loops hold X.
			#reverse for t in held {if !cons[t].dead {append(&stack, t)}}
			append(&stack, x)
		}
	}
	// A dispatch region starts at each demoted label; no construct may
	// span a start, so one that does is demoted too, until none does.
	starts := make([dynamic]int, context.temp_allocator)
	for {
		clear(&starts)
		append(&starts, 0)
		for it, i in items {
			if it.kind == .Bind && demoted[it.label] {append(&starts, i)}
		}
		changed := false
		for &c in cons {
			if c.dead {continue}
			// The first start after c.o.
			k, _ := slice.binary_search(starts[:], c.o + 1)
			for k < len(starts) && starts[k] <= c.o {k += 1}
			if k < len(starts) && starts[k] < c.c {
				demote(cons[:], uses, &demoted, c.label)
				changed = true
			}
		}
		if !changed {break}
	}
	n_regions := len(starts)
	region := proc(starts: []int, b: int) -> int {
		k, found := slice.binary_search(starts, b)
		assert(found, "native: wasm32 region")
		return k
	}

	// Emit.
	by_open(cons[:], order)
	body := &w.out
	lo := len(body)
	wa_uleb(body, 3)
	append(body, 12, I32, 2, I64, 6, V128)
	if n_regions > 1 {
		append(body, OP_LOOP, VOID)
		for _ in 0 ..< n_regions {append(body, OP_BLOCK, VOID)}
		append(body, 0x20)
		wa_uleb(body, L_D)
		append(body, OP_BR_TABLE)
		wa_uleb(body, u64(n_regions))
		for k in 0 ..< n_regions {wa_uleb(body, u64(k))}
		wa_uleb(body, 0)
		append(body, OP_END) // region 0 starts
	}
	clear(&stack)
	next := 0 // in order
	k := 0 // the region
	ci := 0 // in w.calls
	for g in 0 ..= n_items {
		for len(stack) > 0 && cons[stack[len(stack) - 1]].c == g {
			append(body, OP_END)
			pop(&stack)
		}
		if k + 1 < n_regions && starts[k + 1] == g {
			assert(len(stack) == 0, "native: wasm32 construct across a region")
			append(body, OP_END)
			k += 1
		}
		for next < len(order) && cons[order[next]].o <= g {
			c := cons[order[next]]
			if !c.dead {
				assert(c.o == g, "native: wasm32 construct opened late")
				append(body, OP_LOOP if c.loop else OP_BLOCK, VOID)
				append(&stack, order[next])
			}
			next += 1
		}
		if g == n_items {break}
		it := items[g]
		switch it.kind {
		case .Code:
			at := len(body)
			append(body, ..a.code[it.lo:it.hi])
			for ci < len(w.calls) && w.calls[ci].at < it.hi {
				f := w.calls[ci]
				assert(f.at >= it.lo, "native: wasm32 call outside code")
				append(&w.fixes, Wasm_Fix{at + f.at - it.lo, f.label})
				ci += 1
			}
		case .Bind:
		case .Br, .Br_If:
			if it.kind == .Br_If {append(body, ..a.code[it.lo:it.hi])}
			if demoted[it.label] {
				r := region(starts[:], w.at_item[it.label])
				depth := len(stack) + n_regions - 1 - k
				if it.kind == .Br_If {
					append(body, OP_IF, VOID)
					depth += 1
				}
				append(body, 0x41)
				wa_sleb(body, i64(r))
				append(body, 0x21)
				wa_uleb(body, L_D)
				append(body, OP_BR)
				wa_uleb(body, u64(depth))
				if it.kind == .Br_If {append(body, OP_END)}
			} else {
				u := uses[it.label]
				target := u.block if g < u.bind else u.loop
				depth := -1
				#reverse for s, j in stack {
					if s == target {
						depth = len(stack) - 1 - j
						break
					}
				}
				assert(depth >= 0, "native: wasm32 branch out of its construct")
				append(body, OP_BR_IF if it.kind == .Br_If else OP_BR)
				wa_uleb(body, u64(depth))
			}
		}
	}
	assert(len(stack) == 0 && ci == len(w.calls), "native: wasm32 layout")
	if n_regions > 1 {append(body, OP_END)} // the dispatch loop
	append(body, OP_END)
	append(&w.bodies, Wasm_Body{lo, len(body), wa_type(a, {I32, I32}, 0)})

	clear(&w.items)
	clear(&w.calls)
	clear(&w.at_item)
	clear(&a.code)
	w.mark = 0
	w.open = false
}

// ---------------------------------------------------------------- module

@(private = "file")
wa_name :: proc(m: ^[dynamic]u8, s: string) {
	wa_uleb(m, u64(len(s)))
	append(m, s)
}

@(private = "file")
wa_section :: proc(m: ^[dynamic]u8, id: u8, body: []u8) {
	append(m, id)
	wa_uleb(m, u64(len(body)))
	append(m, ..body)
}

wasm_finish :: proc(a: ^Asm) -> []u8 {
	w := &a.wa
	if w.open {wasm_finalize(a)}
	n_gen := w.n_funcs
	slow_type := wa_type(a, {I32, I32}, I64)
	for s in a.slow {
		bind_at(a, s.at, w.n_funcs)
		w.n_funcs += 1
		clear(&a.code)
		wasm_emit_slow(a, s)
		lo := len(w.out)
		wa_uleb(&w.out, 3)
		append(&w.out, 3, I32, 2, I64, 1, V128)
		append(&w.out, ..a.code[:])
		append(&w.bodies, Wasm_Body{lo, len(w.out), slow_type})
	}
	clear(&a.code)
	for f in w.fixes {
		idx := a.labels[f.label]
		if idx < 0 {fmt.panicf("native: wasm32 call of unbound function label %d", f.label)}
		v := u32(idx)
		for j in 0 ..< 4 {w.out[f.at + j] = u8(v >> (7 * u32(j))) & 0x7f | 0x80}
		w.out[f.at + 4] = u8(v >> 28) & 0x7f
	}

	m := make([dynamic]u8)
	append(&m, 0x00, 'a', 's', 'm', 0x01, 0x00, 0x00, 0x00)
	sec := make([dynamic]u8, context.temp_allocator)
	// Types.
	wa_uleb(&sec, u64(len(w.types)))
	for t in w.types {
		append(&sec, 0x60)
		wa_uleb(&sec, u64(t.n))
		t := t
		append(&sec, ..t.params[:t.n])
		if t.result != 0 {append(&sec, 1, t.result)} else {append(&sec, 0)}
	}
	wa_section(&m, 1, sec[:])
	// Imports: memory, table, the slots and base.
	clear(&sec)
	wa_uleb(&sec, u64(3 + len(a.imports)))
	wa_name(&sec, "env")
	wa_name(&sec, "memory")
	append(&sec, 0x02, 0x00, 0x00)
	wa_name(&sec, "env")
	wa_name(&sec, "table")
	append(&sec, 0x01, 0x70, 0x00, 0x00)
	for _, k in a.imports {
		wa_name(&sec, "env")
		wa_name(&sec, fmt.tprintf("s%d", k))
		append(&sec, 0x03, I32, 0x00)
	}
	wa_name(&sec, "env")
	wa_name(&sec, "base")
	append(&sec, 0x03, I32, 0x00)
	wa_section(&m, 2, sec[:])
	// Functions.
	clear(&sec)
	wa_uleb(&sec, u64(len(w.bodies)))
	for b in w.bodies {wa_uleb(&sec, u64(b.type))}
	wa_section(&m, 3, sec[:])
	// Elements: the generated functions from base.
	clear(&sec)
	wa_uleb(&sec, 1)
	append(&sec, 0x00, 0x23)
	wa_uleb(&sec, u64(len(a.imports)))
	append(&sec, OP_END)
	wa_uleb(&sec, u64(n_gen))
	for k in 0 ..< n_gen {wa_uleb(&sec, u64(k))}
	wa_section(&m, 9, sec[:])
	// Code.
	clear(&sec)
	wa_uleb(&sec, u64(len(w.bodies)))
	for b in w.bodies {
		wa_uleb(&sec, u64(b.hi - b.lo))
		append(&sec, ..w.out[b.lo:b.hi])
	}
	wa_section(&m, 10, sec[:])
	return m[:]
}
