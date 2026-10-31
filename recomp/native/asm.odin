// Native code for recompiled functions: a small register machine that the
// console backends target, encoded for x86-64 (System V and Windows) and
// arm64. One Asm holds a whole program's code plus its import table.
//
// Code is position independent. It reaches the runtime only through the
// import table, placed after the code: one 8-byte slot per name, which the
// loader fills with an address (a variable or an Odin procedure) or a value.
// Each function is an Odin `proc()`: it gets the context pointer in the
// first argument register, keeps it, and passes it as the last argument of
// every runtime procedure it calls (the Odin calling convention).
//
// Up to CACHE_MAX state fields (Asm.cached) live in host registers for the
// whole of a function: the state_* operations on one use its register. A
// function reads them in at its start and writes them back at its end and
// around every call, since a called procedure may read or change the state
// and may change the registers.
package native

import "core:fmt"

Arch :: enum u32 {
	X64_SysV = 1,
	X64_Win  = 2,
	Arm64    = 3,
}

parse_arch :: proc(s: string) -> (Arch, bool) {
	switch s {
	case "x64_sysv":
		return .X64_SysV, true
	case "x64_win":
		return .X64_Win, true
	case "arm64":
		return .Arm64, true
	}
	return {}, false
}

// Virtual registers, 32-bit. A, B and C are scratch: a call loses them.
// T and LD keep their values across calls.
Reg :: enum u8 {
	A,
	B,
	C,
	T,
	LD,
}

// 32-bit comparisons; the U ones are unsigned.
Cond :: enum u8 {
	Eq,
	Ne,
	Lt,
	Ge,
	Le,
	Gt,
	Ltu,
	Geu,
}

Alu :: enum u8 {
	Add,
	Sub,
	And,
	Or,
	Xor,
	Shl,
	Shr,
	Sar,
}

// How mac64 takes its product into the sum.
Mac :: enum u8 {
	Set, // starts it
	Add,
	Sub,
}

// 128-bit registers for vector operations on 16-byte state fields; a call
// does not keep them.
Vreg :: enum u8 {
	V0,
	V1,
	V2,
	V3,
	V4,
}

// Lane-wise operations: dst = dst op src.
Vop :: enum u8 {
	Or,
	Add16,
	Sub32,
	Max16, // signed
	Min16, // signed
	Gt16, // signed: all ones in each lane where dst > src
	Nor, // uses V2 on x64
	Zip_Lo8, // bytes 0-7 of dst and src interleaved, dst's first
	Zip_Hi8, // bytes 8-15 likewise
	Zip_Lo64, // doubleword 0 of dst, then of src
	Zip_Hi64, // doubleword 1 of dst, then of src
	Zip_Lo16, // halfwords 0-3 of dst and src interleaved, dst's first
	Even8, // the even bytes of dst, then of src; uses V2
	Even16, // the even halfwords of dst, then of src; loses src
	And,
	Andn, // src and not dst
	Eq32, // all ones in each 32-bit lane where dst == src
	Fadd, // f32 lanes, rounded to nearest
	Fsub,
	Fmul,
	Fdiv,
	Itof, // dst = the i32 lanes of src as f32, rounded to nearest
	// dst = the f32 lanes of src truncated to i32. Out of range or NaN: x64
	// gives 0x80000000, arm64 the nearest i32 and 0 for NaN.
	Ftoi,
	Gt32, // signed: all ones in each 32-bit lane where dst > src
	Xor,
	Sub8,
	Zip_Lo32, // words 0-1 of dst and src interleaved, dst's first
	Zip_Hi32, // words 2-3 likewise
	// dst = halfword 0 of src in halfwords 0-3, halfword 4 in halfwords 4-7
	Dup16,
	Adds16, // signed, saturating
	Addu8, // unsigned, saturating
	Add32,
	Addu32, // unsigned, saturating; uses V2 and V3 on x64
	// dword k = the signed products of halfwords 2k and 2k + 1 added,
	// wrapping; uses V2 and V3 on arm64
	Madd16,
	Sub16,
	Add8,
	Eq16, // all ones in each 16-bit lane where dst == src
	Zip_Hi16, // halfwords 4-7 likewise
	Adds8, // signed, saturating
	Subs8, // signed, saturating
	Subs16, // signed, saturating
	Addu16, // unsigned, saturating
	Subu8, // unsigned, saturating
	Subu16, // unsigned, saturating
	Subu32, // unsigned, saturating; uses V2 and V3 on x64
	Adds32, // signed, saturating; uses V2 and V3 and loses src on x64
	Subs32, // signed, saturating; uses V2 and V3 and loses src on x64
	Gt8, // signed: all ones in each byte where dst > src
	Eq8, // all ones in each byte where dst == src
	Max32, // signed; uses V2 on x64
	Min32, // signed; uses V2 on x64
	Abs16, // dst = the halfwords of src, absolute and saturating; dst is not src
	Abs32, // dst = the words of src, absolute and saturating; uses V2 on x64
	Even32, // words 0 and 2 of dst, then of src
}

Label :: distinct i32

@(private)
Fixup :: struct {
	at:     int, // where the field is
	target: int, // label or import index
	kind:   Fixup_Kind,
}

@(private)
Fixup_Kind :: enum u8 {
	Rel32, // x86-64: 32-bit displacement from the end of the field
	A64_B26, // arm64 b/bl
	A64_B19, // arm64 b.cond/cbz
	A64_Adrp, // arm64 adrp + ldr pair at `at`
}

Asm :: struct {
	arch:      Arch,
	code:      [dynamic]u8,
	labels:    [dynamic]int, // code offset, -1 while unbound
	jumps:     [dynamic]Fixup, // to labels
	imp_refs:  [dynamic]Fixup, // to import slots
	imports:   [dynamic]string,
	imp_index: map[string]int,
	epilogue:  Label, // of the function being emitted
	ram:       Ram,
	cold:      [dynamic]Cold, // of the function being emitted
	slow:      [dynamic]Slow,
	cached:    []u32, // state field offsets, at most CACHE_MAX
	state:     string, // import: the state of the function being emitted
}

// The out-of-line end of a load that left RAM's fast path at far: a host
// call of the shared routine slow, then back to done. func_end
// places these after the epilogue so the fast path falls through.
@(private)
Cold :: struct {
	far, done, slow: Label,
}

// A shared routine that does a load (signed: sign-extended) or store of
// width w off RAM's fast path: in the RAM mirror or window in place, else
// by calling import slow with A, and B for a narrow store; finish places
// them after the last function. A store one does the whole store, fast
// path too. A B64 or B128 one is for guest register n, the state field at
// off (zero: a store of 0), and calls slow with A and n. An unal one does
// the whole unaligned access, fast path too.
@(private)
Slow :: struct {
	at:     Label,
	slow:   string,
	store:  bool,
	w:      Width,
	signed: bool,
	off:    u32,
	n:      u32,
	zero:   bool,
	base:   string, // import: the address off counts from, else the state
	unal:   Unal,
}

// Guest RAM that load and store reach in place, without calling the bus
// procedure, when an access is plain RAM. With no base every access calls.
Ram :: struct {
	base:       string, // import: the address of the RAM bytes
	outside:    u32, // an address is RAM when none of these bits is set
	size:       u32, // a power of two: the RAM offset is address & (size - 1)
	pages:      string, // import: one byte per page; a store into a page whose byte is set calls
	page_shift: u32,
	guards:     []Guard, // a store calls while any is set
	// Off the fast path, before calling: an address with address &
	// mirror_mask == mirror_bits is RAM too, at address & (size - 1) (mask
	// 0: no mirror), and one whose access lies whole in [window_at,
	// window_at + window_size) once masked with window_mask (0: unmasked)
	// is the byte that far into the memory at import window ("": none).
	mirror_mask: u32,
	mirror_bits: u32,
	window:      string,
	window_mask: u32,
	window_at:   u32,
	window_size: u32,
}

// Import `addr` is the address of a byte, set when byte & mask is not zero.
Guard :: struct {
	addr: string,
	mask: u8,
}

// B64 and B128 are only for load_state and store_state.
Width :: enum u8 {
	B8,
	B16,
	B32,
	B64,
	B128,
}

// The unaligned accesses of unaligned, as mem.LWL and the rest do them.
Unal :: enum u8 {
	None,
	LWL,
	LWR,
	LDL,
	LDR,
	SWL,
	SWR,
	SDL,
	SDR,
}

// How unaligned access op merges: over a doubleword (wide) or a word, the
// source (the memory for a load, the register for a store) shifted left or
// right by the shift count into the other, under a mask of ones shifted the
// same way. The count is 8 times the address's low bits, or with from_top
// 56 (24 for a word) less that.
@(private)
unal_shape :: proc(op: Unal) -> (wide, left, from_top, store: bool) {
	assert(op != .None, "native: unaligned op")
	wide = op == .LDL || op == .LDR || op == .SDL || op == .SDR
	from_top = op == .LWL || op == .LDL || op == .SWL || op == .SDL
	store = op >= .SWL
	return wide, from_top != store, from_top, store
}

CACHE_MAX :: 4

make_asm :: proc(arch: Arch, ram := Ram{}, cached: []u32 = nil) -> Asm {
	assert(len(cached) <= CACHE_MAX, "native: too many cached fields")
	return {arch = arch, ram = ram, cached = cached}
}

// Index of the cached field at state offset off, or -1.
@(private)
cache_index :: proc(a: ^Asm, off: u32) -> int {
	for c, k in a.cached {
		if c == off {return k}
	}
	return -1
}

// Write every cached field back to the state, or read them all in.
@(private)
cache_sync :: proc(a: ^Asm, store: bool) {
	for off, k in a.cached {
		switch a.arch {
		case .X64_SysV, .X64_Win:
			x64_cache_sync(a, k, off, store)
		case .Arm64:
			a64_cache_sync(a, k, off, store)
		}
	}
}

// Index of an import slot, added on first use.
imp :: proc(a: ^Asm, name: string) -> int {
	if k, ok := a.imp_index[name]; ok {
		return k
	}
	k := len(a.imports)
	append(&a.imports, name)
	a.imp_index[name] = k
	return k
}

new_label :: proc(a: ^Asm) -> Label {
	append(&a.labels, -1)
	return Label(len(a.labels) - 1)
}

bind :: proc(a: ^Asm, l: Label) {
	assert(a.labels[l] == -1, "native: label bound twice")
	a.labels[l] = len(a.code)
}

@(private)
emit8 :: proc(a: ^Asm, b: ..u8) {
	append(&a.code, ..b)
}

@(private)
emit32 :: proc(a: ^Asm, v: u32) {
	append(&a.code, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private)
put32 :: proc(a: ^Asm, at: int, v: u32) {
	a.code[at] = u8(v)
	a.code[at + 1] = u8(v >> 8)
	a.code[at + 2] = u8(v >> 16)
	a.code[at + 3] = u8(v >> 24)
}

@(private)
get32 :: proc(a: ^Asm, at: int) -> u32 {
	return u32(a.code[at]) | u32(a.code[at + 1]) << 8 | u32(a.code[at + 2]) << 16 | u32(a.code[at + 3]) << 24
}

// ---------------------------------------------------------------- operations

// Start a function; returns its code offset. `state` names the import
// holding the address of the guest register file, kept in a fixed host
// register for the state_* operations. A vec_load or vec_store through
// import state uses that register too, rather than reading the slot.
func_begin :: proc(a: ^Asm, state: string) -> int {
	align_code(a)
	at := len(a.code)
	a.epilogue = new_label(a)
	a.state = state
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_prologue(a, imp(a, state))
	case .Arm64:
		a64_prologue(a, imp(a, state))
	}
	cache_sync(a, false)
	return at
}

// Bind l to off, a func_begin or func_entry result, for call_func.
bind_at :: proc(a: ^Asm, l: Label, off: int) {
	assert(a.labels[l] == -1, "native: label bound twice")
	a.labels[l] = off
}

// Another entry into the function being emitted, which shares its
// epilogue: its body jumps into the function's code. Returns its offset.
func_entry :: proc(a: ^Asm, state: string) -> int {
	assert(state == a.state, "native: an entry with another state")
	align_code(a)
	at := len(a.code)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_prologue(a, imp(a, state))
	case .Arm64:
		a64_prologue(a, imp(a, state))
	}
	cache_sync(a, false)
	return at
}

// Functions and slow routines start 16-byte aligned (arm64 needs 4).
@(private = "file")
align_code :: proc(a: ^Asm) {
	for len(a.code) % 16 != 0 {
		if a.arch == .Arm64 {
			emit32(a, 0xd503201f) // nop
		} else {
			emit8(a, 0xcc)
		}
	}
}

func_end :: proc(a: ^Asm) {
	bind(a, a.epilogue)
	cache_sync(a, true)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_epilogue(a)
	case .Arm64:
		a64_epilogue(a)
	}
	for c in a.cold {
		bind(a, c.far)
		switch a.arch {
		case .X64_SysV, .X64_Win:
			x64_call_label(a, c.slow)
		case .Arm64:
			a64_call_label(a, c.slow)
		}
		jmp(a, c.done)
	}
	clear(&a.cold)
}

// Return from the function.
ret :: proc(a: ^Asm) {
	jmp(a, a.epilogue)
}

// dst = 32-bit field at offset `off` of the guest state.
state_load :: proc(a: ^Asm, dst: Reg, off: u32) {
	k := cache_index(a, off)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		if k >= 0 {x64_cache_mov(a, dst, k, false)} else {x64_state_load(a, dst, off)}
	case .Arm64:
		if k >= 0 {a64_cache_mov(a, dst, k, false)} else {a64_state_load(a, dst, off)}
	}
}

state_store :: proc(a: ^Asm, off: u32, src: Reg) {
	k := cache_index(a, off)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		if k >= 0 {x64_cache_mov(a, src, k, true)} else {x64_state_store(a, off, src)}
	case .Arm64:
		if k >= 0 {a64_cache_mov(a, src, k, true)} else {a64_state_store(a, off, src)}
	}
}

// The 32-bit state field at off = v. May change C.
state_store_imm :: proc(a: ^Asm, off: u32, v: u32) {
	k := cache_index(a, off)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		if k >= 0 {x64_cache_imm(a, k, v)} else {x64_state_store_imm(a, off, v)}
	case .Arm64:
		if k >= 0 {
			a64_cache_imm(a, k, v)
		} else {
			a64_mov_imm(a, .C, v)
			a64_state_store(a, off, .C)
		}
	}
}

// The 64-bit field at `off` of the guest state += v; not a cached one.
state_add64 :: proc(a: ^Asm, off: u32, v: u32) {
	assert(cache_index(a, off) < 0 && cache_index(a, off + 4) < 0, "native: add64 of a cached field")
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_state_add64(a, off, v)
	case .Arm64:
		a64_state_add64(a, off, v)
	}
}

mov_imm :: proc(a: ^Asm, dst: Reg, v: u32) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_mov_imm(a, dst, v)
	case .Arm64:
		a64_mov_imm(a, dst, v)
	}
}

mov :: proc(a: ^Asm, dst, src: Reg) {
	if dst == src {
		return
	}
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_mov(a, dst, src)
	case .Arm64:
		a64_mov(a, dst, src)
	}
}

// dst = dst op src. Shift counts use their low 5 bits.
alu :: proc(a: ^Asm, op: Alu, dst, src: Reg) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_alu(a, op, dst, src)
	case .Arm64:
		a64_alu(a, op, dst, src)
	}
}

// dst = dst op v; shifts take v < 32.
alu_imm :: proc(a: ^Asm, op: Alu, dst: Reg, v: u32) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_alu_imm(a, op, dst, v)
	case .Arm64:
		a64_alu_imm(a, op, dst, v)
	}
}

// dst = the leading zero bits of dst, 32 for 0
clz :: proc(a: ^Asm, dst: Reg) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_clz(a, dst)
	case .Arm64:
		a64_clz(a, dst)
	}
}

// dst = ~dst
not :: proc(a: ^Asm, dst: Reg) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_not(a, dst)
	case .Arm64:
		a64_not(a, dst)
	}
}

// dst = dst cond src ? 1 : 0
set_cond :: proc(a: ^Asm, c: Cond, dst, src: Reg) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_set_cond(a, c, dst, src)
	case .Arm64:
		a64_set_cond(a, c, dst, src)
	}
}

// dst = dst cond v ? 1 : 0
set_cond_imm :: proc(a: ^Asm, c: Cond, dst: Reg, v: u32) {
	mov_imm(a, .C, v)
	set_cond(a, c, dst, .C)
}

// dst = the 16-byte state field at off, a multiple of 16 and no cached one;
// with base, the field at off from the address in import `base`.
vec_load :: proc(a: ^Asm, dst: Vreg, off: u32, base := "") {
	base := base
	if base == a.state {base = ""}
	if base == "" {vec_check(a, off)}
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_ldst(a, dst, off, false, base)
	case .Arm64:
		a64_vec_ldst(a, dst, off, false, base)
	}
}

vec_store :: proc(a: ^Asm, off: u32, src: Vreg, base := "") {
	base := base
	if base == a.state {base = ""}
	if base == "" {vec_check(a, off)}
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_ldst(a, src, off, true, base)
	case .Arm64:
		a64_vec_ldst(a, src, off, true, base)
	}
}

@(private = "file")
vec_check :: proc(a: ^Asm, off: u32) {
	assert(off % 16 == 0, "native: vector state offset")
	for k in u32(0) ..< 4 {
		assert(cache_index(a, off + 4 * k) < 0, "native: vector of a cached field")
	}
}

vec_op :: proc(a: ^Asm, op: Vop, dst, src: Vreg) {
	assert(op != .Even8 || (dst != .V2 && src != .V2), "native: Even8 of V2")
	SCRATCH :: bit_set[Vreg]{.V2, .V3}
	USES_SCRATCH :: bit_set[Vop]{.Addu32, .Madd16, .Subu32, .Adds32, .Subs32, .Max32, .Min32, .Abs32}
	assert(op not_in USES_SCRATCH || (dst not_in SCRATCH && src not_in SCRATCH), "native: vector op of V2 or V3")
	assert(op != .Abs16 || dst != src, "native: Abs16 in place")
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_op(a, op, dst, src)
	case .Arm64:
		a64_vec_op(a, op, dst, src)
	}
}

// dst = dst op src, Fadd, Fsub, Fmul or Fdiv, on the f32 bits in two
// registers, rounded to nearest; uses V0 and V1.
float_op :: proc(a: ^Asm, op: Vop, dst, src: Reg) {
	assert(op == .Fadd || op == .Fsub || op == .Fmul || op == .Fdiv, "native: float_op")
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_float_op(a, op, dst, src)
	case .Arm64:
		a64_float_op(a, op, dst, src)
	}
}

// r = the square root of the f32 bits in r, rounded to nearest; uses V0.
float_sqrt :: proc(a: ^Asm, r: Reg) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_float_sqrt(a, r)
	case .Arm64:
		a64_float_sqrt(a, r)
	}
}

// r = the f32 bits of the i32 in r, rounded to nearest; uses V0.
int_to_float :: proc(a: ^Asm, r: Reg) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_int_to_float(a, r)
	case .Arm64:
		a64_int_to_float(a, r)
	}
}

// r = the i32 of the f32 bits in r, rounded toward zero; NaN gives
// 0x80000000, and so does out of range, except on arm64, where a positive
// one gives 0x7fffffff. Uses V0.
float_to_int :: proc(a: ^Asm, r: Reg) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_float_to_int(a, r)
	case .Arm64:
		a64_float_to_int(a, r)
	}
}

// dst = src.
vec_copy :: proc(a: ^Asm, dst, src: Vreg) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_copy(a, dst, src)
	case .Arm64:
		a64_vec_copy(a, dst, src)
	}
}

// dst's 32-bit lane k = src's lane lanes[k]; dst is not src.
vec_shuf32 :: proc(a: ^Asm, dst, src: Vreg, lanes: [4]u8) {
	assert(dst != src, "native: shuffle in place")
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_shuf32(a, dst, src, lanes)
	case .Arm64:
		a64_vec_shuf32(a, dst, src, lanes)
	}
}

// dst's 16-bit lane k = src's lane lanes[k] and lane k + 4 = src's lane
// lanes[k] + 4; dst is not src.
vec_shuf16 :: proc(a: ^Asm, dst, src: Vreg, lanes: [4]u8) {
	assert(dst != src, "native: shuffle in place")
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_shuf16(a, dst, src, lanes)
	case .Arm64:
		a64_vec_shuf16(a, dst, src, lanes)
	}
}

// Every 32-bit lane of dst = the 4 bytes at the address in import base.
vec_splat_load :: proc(a: ^Asm, dst: Vreg, base: string) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_splat_load(a, dst, base)
	case .Arm64:
		a64_vec_splat_load(a, dst, base)
	}
}

// dst = the sign bits of v's 32-bit lanes, lane 0 in bit 3 to lane 3 in
// bit 0. Loses v.
vec_signs :: proc(a: ^Asm, dst: Reg, v: Vreg) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_signs(a, dst, v)
	case .Arm64:
		a64_vec_signs(a, dst, v)
	}
}

// dst = the 4 bytes (w B32) or 2 (B16, extended as signed says) at off
// from the address in import base. off is a multiple of the width, or
// under 256.
imp_load :: proc(a: ^Asm, dst: Reg, base: string, off: u32 = 0, w := Width.B32, signed := false) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_imp_ldst(a, dst, base, false, off, w, signed)
	case .Arm64:
		a64_imp_ldst(a, dst, base, false, off, w, signed)
	}
}

// The 4 bytes (w B32) or 2 (B16) at off from the address in import base =
// src. off is as for imp_load.
imp_store :: proc(a: ^Asm, base: string, src: Reg, off: u32 = 0, w := Width.B32) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_imp_ldst(a, src, base, true, off, w, false)
	case .Arm64:
		a64_imp_ldst(a, src, base, true, off, w, false)
	}
}

// Each 16-bit lane of v shifted (Shl, Shr or Sar) by n < 16.
vec_shift16 :: proc(a: ^Asm, op: Alu, v: Vreg, n: u32) {
	assert(op == .Shl || op == .Shr || op == .Sar, "native: vector shift")
	assert(n < 16, "native: vector shift count")
	if n == 0 {return}
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_shift16(a, op, v, n)
	case .Arm64:
		a64_vec_shift16(a, op, v, n)
	}
}

// Each 32-bit lane of v shifted (Shl, Shr or Sar) by n < 32.
vec_shift32 :: proc(a: ^Asm, op: Alu, v: Vreg, n: u32) {
	assert(op == .Shl || op == .Shr || op == .Sar, "native: vector shift")
	assert(n < 32, "native: vector shift count")
	if n == 0 {return}
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_shift32(a, op, v, n)
	case .Arm64:
		a64_vec_shift32(a, op, v, n)
	}
}

// The 16-byte state field at dst = the 16 bytes from byte A (at most 16) of
// the 32 bytes lo then hi, two 16-byte state fields: a funnel shift by
// bytes. Import buf is 32 bytes of scratch to put them side by side. Uses
// V0.
vec_funnel8 :: proc(a: ^Asm, dst, lo, hi: u32, buf: string) {
	vec_check(a, dst)
	vec_check(a, lo)
	vec_check(a, hi)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_funnel8(a, dst, lo, hi, imp(a, buf))
	case .Arm64:
		a64_vec_funnel8(a, dst, lo, hi, imp(a, buf))
	}
}

// v = the 16 bytes at byte A, zero-extended, from the address in import
// base, or with store those 16 bytes = v. Reads A and loses no other Reg.
vec_ldst_at :: proc(a: ^Asm, v: Vreg, base: string, store: bool) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_vec_ldst_at(a, v, imp(a, base), store)
	case .Arm64:
		a64_vec_ldst_at(a, v, imp(a, base), store)
	}
}

// 64-bit product of x and y (signed or not) into the guest state's fields
// at lo and hi, neither a cached one. Uses A and B.
mul_wide :: proc(a: ^Asm, signed: bool, lo, hi: u32, x, y: Reg) {
	assert(cache_index(a, lo) < 0 && cache_index(a, hi) < 0, "native: product into a cached field")
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_mul_wide(a, signed, lo, hi, x, y)
	case .Arm64:
		a64_mul_wide(a, signed, lo, hi, x, y)
	}
}

// A, as a 64-bit sum, = the product of x and y (each a signed 32-bit
// value), or A plus or minus it: a sum of products past 32 bits, read with
// mac64_split. x and y are not A. Uses rcx and rdx on x64.
mac64 :: proc(a: ^Asm, op: Mac, x, y: Reg) {
	assert(x != .A && y != .A, "native: mac64 operand in the sum")
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_mac64(a, op, x, y)
	case .Arm64:
		a64_mac64(a, op, x, y)
	}
}

// dst = the high 32 bits of mac64's sum in A, and A = its low 32 bits. dst
// is not A. Uses rcx on x64.
mac64_split :: proc(a: ^Asm, dst: Reg) {
	assert(dst != .A, "native: mac64_split into the sum")
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_mac64_split(a, dst)
	case .Arm64:
		a64_mac64_split(a, dst)
	}
}

// A's mac64 sum = itself wrapped to its low n bits (sign-extended from bit
// n - 1), and dst = what the wrap took off, in units of 1 << n: 0 when the
// sum fit, above 0 for a sum above, below 0 for one below. dst is not A; 0
// < n < 64. Uses rcx and rdx on x64, x12 and x13 on arm64.
mac64_wrap :: proc(a: ^Asm, n: u32, dst: Reg) {
	assert(dst != .A && 0 < n && n < 64, "native: mac64_wrap operands")
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_mac64_wrap(a, n, dst)
	case .Arm64:
		a64_mac64_wrap(a, n, dst)
	}
}

// Quotient and remainder of x by y (signed or not) into the guest state's
// fields at lo and hi, neither a cached one. y is not 0, nor -1 when x is
// the least i32 and signed: x64 traps on both. Uses A, and scratch outside
// the Regs: rcx and rdx on x64, x12 and x13 on arm64.
div_wide :: proc(a: ^Asm, signed: bool, lo, hi: u32, x, y: Reg) {
	assert(cache_index(a, lo) < 0 && cache_index(a, hi) < 0, "native: quotient into a cached field")
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_div_wide(a, signed, lo, hi, x, y)
	case .Arm64:
		a64_div_wide(a, signed, lo, hi, x, y)
	}
}

// The state's words at lo and hi = A / B and A % B (signed or not), as a
// MIPS DIV and DIVU leave them: by 0, hi is A and lo is -1 (signed: 1 when
// A < 0). Signed by -1, lo is -A and hi 0, which gives the least i32 for
// itself without the divide that traps on it. Uses A, B and C.
divide :: proc(a: ^Asm, signed: bool, lo, hi: u32) {
	zero, minus, done := new_label(a), new_label(a), new_label(a)
	br_zero(a, .B, zero)
	if signed {br_cmp_imm(a, .Eq, .B, 0xffffffff, minus)}
	div_wide(a, signed, lo, hi, .A, .B)
	jmp(a, done)
	if signed {
		bind(a, minus)
		mov_imm(a, .C, 0)
		alu(a, .Sub, .C, .A)
		state_store(a, lo, .C)
		state_store_imm(a, hi, 0)
		jmp(a, done)
	}
	bind(a, zero)
	state_store(a, hi, .A)
	if signed {
		// A >> 31 is 0 or -1; doubled and inverted, -1 or 1.
		alu_imm(a, .Sar, .A, 31)
		alu_imm(a, .Shl, .A, 1)
		not(a, .A)
		state_store(a, lo, .A)
	} else {
		state_store_imm(a, lo, 0xffffffff)
	}
	bind(a, done)
}

// Call the Odin procedure in import `name` with 32-bit arguments; a result
// comes back in A. The cached fields go to the state for it and come back
// after.
call :: proc(a: ^Asm, name: string, args: ..Reg) {
	assert(len(args) <= 3, "native: too many arguments")
	cache_sync(a, true)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_call(a, imp(a, name), args)
	case .Arm64:
		a64_call(a, imp(a, name), args)
	}
	cache_sync(a, false)
}

// Call the function at label l (bound with bind_at), passing the context
// as the runtime's call table does, so the callee's prologue is entered the
// same way. As call, the cached fields go to the state and come back after.
call_func :: proc(a: ^Asm, l: Label) {
	cache_sync(a, true)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_call_func(a, l)
	case .Arm64:
		a64_call_func(a, l)
	}
	cache_sync(a, false)
}

// A = the value at guest address A: read from RAM in place when it is
// there, else the result of import `slow` called with A. Narrow signed
// values are sign-extended. Loses B and C.
load :: proc(a: ^Asm, w: Width, signed: bool, slow: string) {
	assert(w <= .B32, "native: load width")
	if a.ram.base == "" {
		call(a, slow, .A)
		return
	}
	s := Slow{slow = slow, w = w, signed = signed}
	far, done := new_label(a), new_label(a)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_load(a, s, far)
	case .Arm64:
		a64_load(a, s, far)
	}
	bind(a, done)
	append(&a.cold, Cold{far, done, slow_path(a, s)})
}

// Guest register n, the 8- or 16-byte (w B64 or B128) state field at off,
// = the value at guest address A, which a B128 caller aligns: copied from
// RAM in place when it is there, else import `slow` called with A and n
// does it. With base, the 16-byte field is at off from the address in
// import `base` instead. Loses A, B, C and V0.
load_state :: proc(a: ^Asm, w: Width, off, n: u32, slow: string, base := "") {
	wide_check(a, w, off, base)
	if a.ram.base == "" {
		mov_imm(a, .B, n)
		call(a, slow, .A, .B)
		return
	}
	s := Slow{slow = slow, w = w, off = off, n = n, base = base}
	far, done := new_label(a), new_label(a)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_load(a, s, far)
	case .Arm64:
		a64_load(a, s, far)
	}
	bind(a, done)
	append(&a.cold, Cold{far, done, slow_path(a, s)})
}

// Store the low bytes of B at guest address A: in place when the address
// is RAM and no guard or page byte is set, else through import `slow`
// called with A and B. Loses A, B and C. Nothing waits on a store, so it
// is a host call of a shared routine: inline, the guard and page checks
// made the code half again as large for no measured speed.
store :: proc(a: ^Asm, w: Width, slow: string) {
	if a.ram.base == "" {
		call(a, slow, .A, .B)
		return
	}
	assert(w <= .B32, "native: store width")
	call_label(a, slow_path(a, {slow = slow, store = true, w = w}))
}

// The value at guest address A, which a B128 caller aligns, = guest
// register n, the 8- or 16-byte (w B64 or B128) state field at off, or 0
// with zero; import `slow` called with A and n does it off the fast path.
// base is as for load_state. Like store, a host call of a shared routine,
// one per register. Loses A, B, C and V0.
store_state :: proc(a: ^Asm, w: Width, off, n: u32, slow: string, zero := false, base := "") {
	wide_check(a, w, off, base)
	if a.ram.base == "" {
		mov_imm(a, .B, n)
		call(a, slow, .A, .B)
		return
	}
	call_label(a, slow_path(a, {slow = slow, store = true, w = w, off = off, n = n, zero = zero, base = base}))
}

// Guest register n, the 8-byte state field at off, and the word or
// doubleword guest address A rounds down to merge as op does (mem.LWL and
// the rest). Like store_state, a host call of a shared routine, one per op
// and register: in place when the address is RAM (and, for a store, no
// guard or page byte is set), else import `slow` called with A and n does
// it. Loses A, B and C.
unaligned :: proc(a: ^Asm, op: Unal, off, n: u32, slow: string) {
	wide_check(a, .B64, off, "")
	_, _, _, store := unal_shape(op)
	if a.ram.base == "" {
		mov_imm(a, .B, n)
		call(a, slow, .A, .B)
		return
	}
	call_label(a, slow_path(a, {slow = slow, store = store, w = .B64, off = off, n = n, unal = op}))
}

@(private = "file")
wide_check :: proc(a: ^Asm, w: Width, off: u32, base: string) {
	assert(w >= .B64, "native: wide width")
	size := u32(8 if w == .B64 else 16)
	assert(off % size == 0, "native: wide state offset")
	if base != "" {
		assert(w == .B128 && off < 16 << 12, "native: wide field off a base")
		return
	}
	for k := u32(0); k < size; k += 4 {
		assert(cache_index(a, off + k) < 0, "native: wide access to a cached field")
	}
}

@(private = "file")
call_label :: proc(a: ^Asm, l: Label) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_call_label(a, l)
	case .Arm64:
		a64_call_label(a, l)
	}
}

// The label of the shared routine s describes, made on first use.
@(private = "file")
slow_path :: proc(a: ^Asm, s: Slow) -> Label {
	for t in a.slow {
		k := s
		k.at = t.at
		if t == k {return t.at}
	}
	s := s
	s.at = new_label(a)
	append(&a.slow, s)
	return s.at
}

// A shared slow routine: a host call into it left the stack 8 off
// alignment on x86-64 and the link register in use on arm64, so it keeps a
// frame of its own around the runtime call.
@(private = "file")
emit_slow :: proc(a: ^Asm, s: Slow) {
	align_code(a)
	bind(a, s.at)
	far, guarded := new_label(a), new_label(a)
	if s.unal != .None {
		switch a.arch {
		case .X64_SysV, .X64_Win:
			x64_unaligned(a, s, far, guarded)
			x64_return(a)
		case .Arm64:
			a64_unaligned(a, s, far, guarded)
			a64_return(a)
		}
	} else if s.store {
		switch a.arch {
		case .X64_SysV, .X64_Win:
			x64_store(a, s, far, guarded)
			x64_return(a)
		case .Arm64:
			a64_store(a, s, far, guarded)
			a64_return(a)
		}
	}
	bind(a, far)
	r := a.ram
	if r.mirror_mask != 0 {
		// A load reads the RAM address in place; a store or an unaligned
		// access starts over with it, so the checks of RAM decide.
		next := new_label(a)
		mov(a, .C, .A)
		alu_imm(a, .And, .C, r.mirror_mask)
		br_cmp_imm(a, .Ne, .C, r.mirror_bits, next)
		alu_imm(a, .And, .A, r.size - 1)
		if s.store || s.unal != .None {
			jmp(a, s.at)
		} else {
			switch a.arch {
			case .X64_SysV, .X64_Win:
				x64_load(a, s, next)
				x64_return(a)
			case .Arm64:
				a64_load(a, s, next)
				a64_return(a)
			}
		}
		bind(a, next)
	}
	if r.window != "" {
		// An access running past the end calls, so the bus decides it.
		mov(a, .C, .A)
		if r.window_mask != 0 {alu_imm(a, .And, .C, r.window_mask)}
		alu_imm(a, .Sub, .C, r.window_at)
		br_cmp_imm(a, .Geu, .C, r.window_size - (u32(1) << u32(s.w)) + 1, guarded)
		switch a.arch {
		case .X64_SysV, .X64_Win:
			x64_window(a, s)
			x64_return(a)
		case .Arm64:
			a64_window(a, s)
			a64_return(a)
		}
	}
	bind(a, guarded)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_slow_frame(a, true)
	case .Arm64:
		a64_slow_frame(a, true)
	}
	if s.w >= .B64 {
		mov_imm(a, .B, s.n)
		call(a, s.slow, .A, .B)
	} else if s.store {
		call(a, s.slow, .A, .B)
	} else {
		call(a, s.slow, .A)
	}
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_slow_frame(a, false)
		x64_return(a)
	case .Arm64:
		a64_slow_frame(a, false)
		a64_return(a)
	}
}

jmp :: proc(a: ^Asm, l: Label) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_jmp(a, l)
	case .Arm64:
		a64_jmp(a, l)
	}
}

// Go to l when r is zero (or, with nonzero, when it is not).
br_zero :: proc(a: ^Asm, r: Reg, l: Label, nonzero := false) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_br_zero(a, r, l, nonzero)
	case .Arm64:
		a64_br_zero(a, r, l, nonzero)
	}
}

// Go to l when r c v.
br_cmp_imm :: proc(a: ^Asm, c: Cond, r: Reg, v: u32, l: Label) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_br_cmp_imm(a, c, r, v, l)
	case .Arm64:
		a64_br_cmp_imm(a, c, r, v, l)
	}
}

// Go to l when the 64-bit state field at off is below the u64 at the
// address in import `limit`.
br_state64_below :: proc(a: ^Asm, off: u32, limit: string, l: Label) {
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_br_state64_below(a, off, imp(a, limit), l)
	case .Arm64:
		a64_br_state64_below(a, off, imp(a, limit), l)
	}
}

// Go to l when the byte at the address in import `addr`, masked with the
// value of import `mask` (or with 0xff when mask is ""), is zero.
br_byte_clear :: proc(a: ^Asm, addr, mask: string, l: Label) {
	m := mask == "" ? -1 : imp(a, mask)
	switch a.arch {
	case .X64_SysV, .X64_Win:
		x64_br_byte_clear(a, imp(a, addr), m, l)
	case .Arm64:
		a64_br_byte_clear(a, imp(a, addr), m, l)
	}
}

// Binary search of the sorted pcs for t: a hit goes to its label, a miss
// to miss. Small ranges compare each pc in turn.
search :: proc(a: ^Asm, pcs: []u32, labels: map[u32]Label, miss: Label) {
	LINEAR :: 4
	Range :: struct {
		lo, hi: int,
		at:     Label, // bound where the range's code starts, or -1
	}
	todo: [dynamic]Range
	defer delete(todo)
	append(&todo, Range{0, len(pcs), -1})
	for len(todo) > 0 {
		r := pop(&todo)
		if r.at >= 0 {bind(a, r.at)}
		if r.hi - r.lo <= LINEAR {
			for pc in pcs[r.lo:r.hi] {br_cmp_imm(a, .Eq, .T, pc, labels[pc])}
			jmp(a, miss)
			continue
		}
		mid := (r.lo + r.hi) / 2
		low := new_label(a)
		br_cmp_imm(a, .Ltu, .T, pcs[mid], low)
		append(&todo, Range{r.lo, mid, low}, Range{mid, r.hi, -1})
	}
}

// ---------------------------------------------------------------- output

// Resolve the jumps, place the import table after the code and return the
// code; the import slots start at the returned offset.
finish :: proc(a: ^Asm) -> (code: []u8, imports_at: int) {
	for s in a.slow {
		emit_slow(a, s)
	}
	for len(a.code) % 16 != 0 {
		emit8(a, 0)
	}
	imports_at = len(a.code)
	for _ in a.imports {
		for _ in 0 ..< 8 {
			emit8(a, 0)
		}
	}
	for f in a.jumps {
		to := a.labels[f.target]
		if to < 0 {
			fmt.panicf("native: unbound label %d", f.target)
		}
		patch(a, f, to)
	}
	for f in a.imp_refs {
		patch(a, f, imports_at + 8 * f.target)
	}
	return a.code[:], imports_at
}

@(private)
patch :: proc(a: ^Asm, f: Fixup, to: int) {
	switch f.kind {
	case .Rel32:
		put32(a, f.at, u32(i32(to - (f.at + 4))))
	case .A64_B26:
		d := (to - f.at) / 4
		if d < -(1 << 25) || d >= 1 << 25 {
			fmt.panicf("native: branch out of range (+-128 MiB) at %d to %d, code %d bytes", f.at, to, len(a.code))
		}
		put32(a, f.at, get32(a, f.at) | u32(d) & 0x3ffffff)
	case .A64_B19:
		d := (to - f.at) / 4
		assert(d >= -(1 << 18) && d < 1 << 18, "native: branch out of range")
		put32(a, f.at, get32(a, f.at) | (u32(d) & 0x7ffff) << 5)
	case .A64_Adrp:
		// adrp at f.at, then an ldr whose 12-bit offset is in 8-byte units.
		pages := (to >> 12) - (f.at >> 12)
		assert(pages >= -(1 << 20) && pages < 1 << 20, "native: import out of range")
		p := u32(pages)
		put32(a, f.at, get32(a, f.at) | (p & 3) << 29 | (p >> 2 & 0x7ffff) << 5)
		put32(a, f.at + 4, get32(a, f.at + 4) | u32(to & 0xfff) / 8 << 10)
	}
}
