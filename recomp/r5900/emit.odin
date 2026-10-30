// Odin code generation.
//
// Each function becomes `f_XXXXXXXX :: proc()` working on `cpu.state` (`c`).
// Control flow inside it is a `for { switch pc { ... } }` state machine
// whose cases are basic-block labels; straight-line code falls through.
// `jal` to a function in the same package is a direct host call, otherwise
// `cpu.call(addr)` dispatches through the runtime's table. `jr $ra` is a host
// return. Hot instructions are inlined; the rest call the runtime
// interpreter (`ps2.exec`), which owns their semantics.
package r5900

import "core:fmt"
import "core:slice"
import "core:strings"
import "../mips"
import "../vu"

Func :: mips.Func

Emitter :: struct {
	sb:     strings.Builder,
	refs:   ^mips.Set, // code addresses the program takes
	pkg_of: ^map[u32]int, // function entry -> package index
	pkg:    int,
	cycles: int, // EE cycles charged per instruction (the EE runs at 294.912 MHz)
	quiet:  bool, // no per-function warnings
	slow:   ^map[string]int, // per op, the sites that call the interpreter
}

hexu :: proc(v: u32) -> string {
	return fmt.tprintf("0x%08x", v)
}

R64 :: proc(n: u8) -> string {
	return n == 0 ? "u64(0)" : fmt.tprintf("c.r[%d].d[0]", n)
}

R32 :: proc(n: u8) -> string {
	return n == 0 ? "u32(0)" : fmt.tprintf("u32(c.r[%d].d[0])", n)
}

S64 :: proc(n: u8) -> string {
	return n == 0 ? "i64(0)" : fmt.tprintf("i64(c.r[%d].d[0])", n)
}

set64 :: proc(out: ^[dynamic]string, n: u8, expr: string) {
	if n != 0 {append(out, fmt.tprintf("c.r[%d].d[0] = %s", n, expr))}
}

set32 :: proc(out: ^[dynamic]string, n: u8, expr: string) {
	if n != 0 {append(out, fmt.tprintf("c.r[%d].d[0] = sx32(%s)", n, expr))}
}

addr_expr :: proc(i: Insn) -> string {
	off := sx16(i.imm)
	if i.rs == 0 {return hexu(u32(off))}
	if off == 0 {return R32(i.rs)}
	return fmt.tprintf("%s %s 0x%x", R32(i.rs), off > 0 ? "+" : "-", abs(off))
}

F :: proc(n: u8) -> string {return fmt.tprintf("c.f[%d].f", n)}

// Count i, a site that calls the interpreter, in slow: by op, or a VU0 macro
// op by its function as recomp/vu counts a VU1 upper one. The keys outlive
// the temp allocator, which each function frees.
count_slow :: proc(slow: ^map[string]int, i: Insn) {
	key: string
	fn := i.w & 63
	switch {
	case i.op != .VU0:
		key = fmt.tprint(i.op)
	case fn & 0x3c != 0x3c:
		key = fmt.tprintf("VU0 %02x", fn)
	case:
		key = fmt.tprintf("VU0 special %02x", ((i.w >> 4) & 0x7c) | (i.w & 3))
	}
	if key not_in slow {slow[strings.clone(key)] = 0}
	slow[key] += 1
}

// Odin statements for a non-control-transfer instruction; slow when they
// call the interpreter.
emit_op :: proc(i: Insn, out: ^[dynamic]string) -> (slow: bool) {
	rs, rt, rd, sa := i.rs, i.rt, i.rd, i.sa
	imm := i.imm
	simm := sx16(imm)
	fs, ft, fd := rd, rt, sa // COP1 field names
	if emit_mmi(i, out) {return}
	switch i.op {
	case .SLL:
		if i.w == 0 {return} // nop
		set32(out, rd, fmt.tprintf("%s << %d", R32(rt), sa))
	case .SRL:  set32(out, rd, fmt.tprintf("%s >> %d", R32(rt), sa))
	case .SRA:  set32(out, rd, fmt.tprintf("u32(i32(%s) >> %d)", R32(rt), sa))
	case .SLLV: set32(out, rd, fmt.tprintf("%s << (%s & 31)", R32(rt), R32(rs)))
	case .SRLV: set32(out, rd, fmt.tprintf("%s >> (%s & 31)", R32(rt), R32(rs)))
	case .SRAV: set32(out, rd, fmt.tprintf("u32(i32(%s) >> (%s & 31))", R32(rt), R32(rs)))
	case .DSLLV: set64(out, rd, fmt.tprintf("%s << (%s & 63)", R64(rt), R32(rs)))
	case .DSRLV: set64(out, rd, fmt.tprintf("%s >> (%s & 63)", R64(rt), R32(rs)))
	case .DSRAV: set64(out, rd, fmt.tprintf("u64(%s >> (%s & 63))", S64(rt), R32(rs)))
	case .DSLL:   set64(out, rd, fmt.tprintf("%s << %d", R64(rt), sa))
	case .DSRL:   set64(out, rd, fmt.tprintf("%s >> %d", R64(rt), sa))
	case .DSRA:   set64(out, rd, fmt.tprintf("u64(%s >> %d)", S64(rt), sa))
	case .DSLL32: set64(out, rd, fmt.tprintf("%s << %d", R64(rt), sa + 32))
	case .DSRL32: set64(out, rd, fmt.tprintf("%s >> %d", R64(rt), sa + 32))
	case .DSRA32: set64(out, rd, fmt.tprintf("u64(%s >> %d)", S64(rt), sa + 32))
	case .MOVZ:
		if rd != 0 {append(out, fmt.tprintf("if %s == 0 {{c.r[%d].d[0] = %s}}", R64(rt), rd, R64(rs)))}
	case .MOVN:
		if rd != 0 {append(out, fmt.tprintf("if %s != 0 {{c.r[%d].d[0] = %s}}", R64(rt), rd, R64(rs)))}
	case .MFHI: set64(out, rd, "c.hi.d[0]")
	case .MFLO: set64(out, rd, "c.lo.d[0]")
	case .MTHI: append(out, fmt.tprintf("c.hi.d[0] = %s", R64(rs)))
	case .MTLO: append(out, fmt.tprintf("c.lo.d[0] = %s", R64(rs)))
	case .MTHI1: append(out, fmt.tprintf("c.hi.d[1] = %s", R64(rs)))
	case .MTLO1: append(out, fmt.tprintf("c.lo.d[1] = %s", R64(rs)))
	case .MTC0: append(out, fmt.tprintf("c.cop0[%d] = %s", rd, R32(rt)))
	case .ERET: // lower returns after it; leave ERL if set, else EXL
		append(out, "if c.cop0[12] & 4 != 0 {c.cop0[12] &~= 4} else {c.cop0[12] &~= 2}")
	case .CFC1: set64(out, rt, fmt.tprintf("sx32(%s)", rd == 0 ? "0x2e30" : "c.fcr31"))
	case .CTC1: if rd == 31 {append(out, fmt.tprintf("c.fcr31 = %s", R32(rt)))}
	case .MFHI1: set64(out, rd, "c.hi.d[1]")
	case .MFLO1: set64(out, rd, "c.lo.d[1]")
	case .MULT:  append(out, fmt.tprintf("cpu.mult(%d, %s, %s, 0)", rd, R32(rs), R32(rt)))
	case .MULTU: append(out, fmt.tprintf("cpu.multu(%d, %s, %s, 0)", rd, R32(rs), R32(rt)))
	case .MULT1:  append(out, fmt.tprintf("cpu.mult(%d, %s, %s, 1)", rd, R32(rs), R32(rt)))
	case .MULTU1: append(out, fmt.tprintf("cpu.multu(%d, %s, %s, 1)", rd, R32(rs), R32(rt)))
	case .MADD:   append(out, fmt.tprintf("cpu.madd(%d, %s, %s, 0, true)", rd, R32(rs), R32(rt)))
	case .MADDU:  append(out, fmt.tprintf("cpu.madd(%d, %s, %s, 0, false)", rd, R32(rs), R32(rt)))
	case .MADD1:  append(out, fmt.tprintf("cpu.madd(%d, %s, %s, 1, true)", rd, R32(rs), R32(rt)))
	case .MADDU1: append(out, fmt.tprintf("cpu.madd(%d, %s, %s, 1, false)", rd, R32(rs), R32(rt)))
	case .DIV:   append(out, fmt.tprintf("cpu.div(%s, %s, 0)", R32(rs), R32(rt)))
	case .DIVU:  append(out, fmt.tprintf("cpu.divu(%s, %s, 0)", R32(rs), R32(rt)))
	case .DIV1:  append(out, fmt.tprintf("cpu.div(%s, %s, 1)", R32(rs), R32(rt)))
	case .DIVU1: append(out, fmt.tprintf("cpu.divu(%s, %s, 1)", R32(rs), R32(rt)))
	case .PLZCW: append(out, fmt.tprintf("cpu.plzcw(%s, u32(%s >> 32), %d)", R32(rs), R64(rs), rd))
	case .QMFC2:
		if rt != 0 {append(out, fmt.tprintf("c.r[%d].q = vu.vu0.vf[%d].q", rt, rd))}
	case .QMTC2: append(out, fmt.tprintf("vu.vu0_set_vf(%d, c.r[%d].q)", rd, rt))
	case .CFC2:  set32(out, rt, fmt.tprintf("vu.vu0_ctrl_read(%d)", rd))
	case .CTC2:  append(out, fmt.tprintf("vu.vu0_ctrl_write(%d, %s)", rd, R32(rt)))
	case .VU0:
		if code, ok := vu.emit_macro(i.w); !ok {
			append(out, fmt.tprintf("vu.vu0_macro(%s)", hexu(i.w)))
			slow = true
		} else if code != "" {
			append(out, code)
		}
	case .ADD, .ADDU:
		if rt == 0 {set32(out, rd, R32(rs))} else if rs == 0 {set32(out, rd, R32(rt))} else {
			set32(out, rd, fmt.tprintf("%s + %s", R32(rs), R32(rt)))
		}
	case .SUB, .SUBU: set32(out, rd, fmt.tprintf("%s - %s", R32(rs), R32(rt)))
	case .DADD, .DADDU:
		if rt == 0 {set64(out, rd, R64(rs))} else if rs == 0 {set64(out, rd, R64(rt))} else {
			set64(out, rd, fmt.tprintf("%s + %s", R64(rs), R64(rt)))
		}
	case .DSUB, .DSUBU: set64(out, rd, fmt.tprintf("%s - %s", R64(rs), R64(rt)))
	case .AND: set64(out, rd, fmt.tprintf("%s & %s", R64(rs), R64(rt)))
	case .OR:
		if rt == 0 {set64(out, rd, R64(rs))} else if rs == 0 {set64(out, rd, R64(rt))} else {
			set64(out, rd, fmt.tprintf("%s | %s", R64(rs), R64(rt)))
		}
	case .XOR: set64(out, rd, fmt.tprintf("%s ~ %s", R64(rs), R64(rt)))
	case .NOR: set64(out, rd, fmt.tprintf("~(%s | %s)", R64(rs), R64(rt)))
	case .SLT:  set64(out, rd, fmt.tprintf("%s < %s ? 1 : 0", S64(rs), S64(rt)))
	case .SLTU: set64(out, rd, fmt.tprintf("%s < %s ? 1 : 0", R64(rs), R64(rt)))
	case .ADDI, .ADDIU:
		if rs == 0 {set64(out, rt, fmt.tprintf("0x%x", u64(i64(simm))))} else {
			set32(out, rt, fmt.tprintf("%s + %s", R32(rs), hexu(u32(simm))))
		}
	case .DADDI, .DADDIU:
		set64(out, rt, fmt.tprintf("%s + 0x%x", R64(rs), u64(i64(simm))))
	case .SLTI:  set64(out, rt, fmt.tprintf("%s < %d ? 1 : 0", S64(rs), simm))
	case .SLTIU: set64(out, rt, fmt.tprintf("%s < 0x%x ? 1 : 0", R64(rs), u64(i64(simm))))
	case .ANDI: set64(out, rt, fmt.tprintf("%s & 0x%x", R64(rs), imm))
	case .ORI:  set64(out, rt, rs == 0 ? fmt.tprintf("u64(0x%x)", imm) : fmt.tprintf("%s | 0x%x", R64(rs), imm))
	case .XORI: set64(out, rt, fmt.tprintf("%s ~ 0x%x", R64(rs), imm))
	case .LUI:  set64(out, rt, fmt.tprintf("0x%x", u64(i64(i32(u32(imm) << 16)))))
	case .LB:  set64(out, rt, fmt.tprintf("u64(i64(i8(rd8(%s))))", addr_expr(i)))
	case .LBU: set64(out, rt, fmt.tprintf("u64(rd8(%s))", addr_expr(i)))
	case .LH:  set64(out, rt, fmt.tprintf("u64(i64(i16(rd16(%s))))", addr_expr(i)))
	case .LHU: set64(out, rt, fmt.tprintf("u64(rd16(%s))", addr_expr(i)))
	case .LW:  set64(out, rt, fmt.tprintf("sx32(rd32(%s))", addr_expr(i)))
	case .LWU: set64(out, rt, fmt.tprintf("u64(rd32(%s))", addr_expr(i)))
	case .LD:  set64(out, rt, fmt.tprintf("rd64(%s)", addr_expr(i)))
	case .LQ:
		if rt != 0 {append(out, fmt.tprintf("c.r[%d].q = rd128(%s)", rt, addr_expr(i)))}
	case .SB: append(out, fmt.tprintf("wr8(%s, u8(%s))", addr_expr(i), R64(rt)))
	case .SH: append(out, fmt.tprintf("wr16(%s, u16(%s))", addr_expr(i), R64(rt)))
	case .SW: append(out, fmt.tprintf("wr32(%s, %s)", addr_expr(i), R32(rt)))
	case .SD: append(out, fmt.tprintf("wr64(%s, %s)", addr_expr(i), R64(rt)))
	case .SQ: append(out, fmt.tprintf("wr128(%s, %s)", addr_expr(i), rt == 0 ? "u128(0)" : fmt.tprintf("c.r[%d].q", rt)))
	case .LWC1: append(out, fmt.tprintf("c.f[%d].u = rd32(%s)", rt, addr_expr(i)))
	case .SWC1: append(out, fmt.tprintf("wr32(%s, c.f[%d].u)", addr_expr(i), rt))
	case .LQC2: append(out, fmt.tprintf("vu.vu0_set_vf(%d, rd128(%s))", rt, addr_expr(i)))
	case .SQC2: append(out, fmt.tprintf("wr128(%s, vu.vu0.vf[%d].q)", addr_expr(i), rt))
	case .LWL, .LWR, .LDL, .LDR:
		if rt != 0 {append(out, fmt.tprintf("c.r[%d].d[0] = mem.%v(%s, %s)", rt, i.op, addr_expr(i), R64(rt)))}
	case .SWL, .SWR, .SDL, .SDR:
		append(out, fmt.tprintf("mem.%v(%s, %s)", i.op, addr_expr(i), R64(rt)))
	case .SYNC, .CACHE, .PREF:
	case .MFC1: set64(out, rt, fmt.tprintf("sx32(c.f[%d].u)", fs))
	case .MTC1: append(out, fmt.tprintf("c.f[%d].u = %s", fs, R32(rt)))
	case .MOV_S: append(out, fmt.tprintf("c.f[%d] = c.f[%d]", fd, fs))
	case .NEG_S: append(out, fmt.tprintf("c.f[%d].u = c.f[%d].u ~ 0x80000000", fd, fs))
	case .ABS_S: append(out, fmt.tprintf("c.f[%d].u = c.f[%d].u & 0x7fffffff", fd, fs))
	case .ADD_S: append(out, fmt.tprintf("%s = fadd(%s, %s)", F(fd), F(fs), F(ft)))
	case .SUB_S: append(out, fmt.tprintf("%s = fsub(%s, %s)", F(fd), F(fs), F(ft)))
	case .MUL_S: append(out, fmt.tprintf("%s = fmul(%s, %s)", F(fd), F(fs), F(ft)))
	case .DIV_S: append(out, fmt.tprintf("%s = cpu.fpu_div(%s, %s)", F(fd), F(fs), F(ft)))
	case .SQRT_S: append(out, fmt.tprintf("%s = cpu.fpu_sqrt(%s)", F(fd), F(ft)))
	case .RSQRT_S: append(out, fmt.tprintf("%s = cpu.fpu_rsqrt(%s, %s)", F(fd), F(fs), F(ft)))
	case .MADD_S: append(out, fmt.tprintf("%s = fadd(c.acc.f, fmul(%s, %s))", F(fd), F(fs), F(ft)))
	case .MSUB_S: append(out, fmt.tprintf("%s = fsub(c.acc.f, fmul(%s, %s))", F(fd), F(fs), F(ft)))
	case .MULA_S: append(out, fmt.tprintf("c.acc.f = fmul(%s, %s)", F(fs), F(ft)))
	case .ADDA_S: append(out, fmt.tprintf("c.acc.f = fadd(%s, %s)", F(fs), F(ft)))
	case .SUBA_S: append(out, fmt.tprintf("c.acc.f = fsub(%s, %s)", F(fs), F(ft)))
	case .MADDA_S: append(out, fmt.tprintf("c.acc.f = fadd(c.acc.f, fmul(%s, %s))", F(fs), F(ft)))
	case .MSUBA_S: append(out, fmt.tprintf("c.acc.f = fsub(c.acc.f, fmul(%s, %s))", F(fs), F(ft)))
	case .MAX_S: append(out, fmt.tprintf("%s = fkey(%s) >= fkey(%s) ? %s : %s", F(fd), F(fs), F(ft), F(fs), F(ft)))
	case .MIN_S: append(out, fmt.tprintf("%s = fkey(%s) <= fkey(%s) ? %s : %s", F(fd), F(fs), F(ft), F(fs), F(ft)))
	case .C_F_S:  append(out, "c.fcr31 &= ~u32(0x800000)")
	case .C_EQ_S: append(out, fmt.tprintf("fcond(fkey(%s) == fkey(%s))", F(fs), F(ft)))
	case .C_LT_S: append(out, fmt.tprintf("fcond(fkey(%s) < fkey(%s))", F(fs), F(ft)))
	case .C_LE_S: append(out, fmt.tprintf("fcond(fkey(%s) <= fkey(%s))", F(fs), F(ft)))
	case .CVT_S_W: append(out, fmt.tprintf("%s = f32(c.f[%d].i)", F(fd), fs))
	case .CVT_W_S: append(out, fmt.tprintf("c.f[%d].i = cpu.cvt_w(%s)", fd, F(fs)))
	case .INVALID:
		append(out, fmt.tprintf("cpu.bad_insn(%s, %s)", hexu(i.pc), hexu(i.w)))
		return true
	case .SYSCALL:
		append(out, fmt.tprintf("kernel.syscall(%s)", hexu(i.pc)))
	case .BREAK:
		append(out, fmt.tprintf("cpu.brk(%s, %s)", hexu(i.pc), hexu(i.w)))
	case .J, .JAL, .JR, .JALR, .BEQ, .BNE, .BLEZ, .BGTZ, .BEQL, .BNEL, .BLEZL, .BGTZL,
	     .BLTZ, .BGEZ, .BLTZL, .BGEZL, .BLTZAL, .BGEZAL, .BLTZALL, .BGEZALL,
	     .BC0F, .BC0T, .BC0FL, .BC0TL, .BC1F, .BC1T, .BC1FL, .BC1TL, .BC2F, .BC2T, .BC2FL, .BC2TL:
		panic("control transfer in emit_op")
	case .MFSA, .MTSA, .TGE, .TGEU, .TLT, .TLTU, .TEQ, .TNE, .TRAPI, .MTSAB, .MTSAH,
	     .PMFHL, .PMTHL,
	     .PSLLH, .PSRLH, .PSRAH, .PSLLW, .PSRLW, .PSRAW,
	     .PADDW, .PSUBW, .PCGTW, .PMAXW, .PADDH, .PSUBH, .PCGTH, .PMAXH, .PADDB, .PSUBB, .PCGTB,
	     .PADDSW, .PSUBSW, .PEXTLW, .PPACW, .PADDSH, .PSUBSH, .PEXTLH, .PPACH, .PADDSB, .PSUBSB,
	     .PEXTLB, .PPACB, .PEXT5, .PPAC5,
	     .PABSW, .PCEQW, .PMINW, .PADSBH, .PABSH, .PCEQH, .PMINH, .PCEQB, .PADDUW, .PSUBUW, .PEXTUW,
	     .PADDUH, .PSUBUH, .PEXTUH, .PADDUB, .PSUBUB, .PEXTUB, .QFSRV,
	     .PMADDW, .PSLLVW, .PSRLVW, .PMSUBW, .PMFHI, .PMFLO, .PINTH, .PMULTW, .PDIVW, .PCPYLD,
	     .PMADDH, .PHMADH, .PAND, .PXOR, .PMSUBH, .PHMSBH, .PEXEH, .PREVH, .PMULTH, .PDIVBW, .PEXEW, .PROT3W,
	     .PMADDUW, .PSRAVW, .PMTHI, .PMTLO, .PINTEH, .PMULTUW, .PDIVUW, .PCPYUD, .POR, .PNOR, .PEXCH, .PCPYH, .PEXCW,
	     .MFC0, .TLBR, .TLBWI, .TLBWR, .TLBP, .EI, .DI:
		append(out, fmt.tprintf("ps2.exec_insn({{pc = %s, w = %s, op = .%v, rs = %d, rt = %d, rd = %d, sa = %d, fn = %d, imm = %d}})",
			hexu(i.pc), hexu(i.w), i.op, i.rs, i.rt, i.rd, i.sa, i.fn, i.imm))
		return true
	}
	return
}

// Lane-parallel MMI instructions as inline SIMD expressions; the rest go to
// the interpreter. Operands are read into s and t first because rd may alias
// either.
emit_mmi :: proc(i: Insn, out: ^[dynamic]string) -> bool {
	bin :: proc(view, op: string) -> string {return fmt.tprintf("s.%s %s t.%s", view, op, view)}
	call :: proc(f, view: string) -> string {return fmt.tprintf("intrinsics.%s(s.%s, t.%s)", f, view, view)}
	splat :: proc(n: int, v: u8) -> string {
		sb := strings.builder_make(context.temp_allocator)
		for k in 0 ..< n {fmt.sbprintf(&sb, "%s%d", k == 0 ? "" : ", ", v)}
		return strings.to_string(sb)
	}
	// Indices into the 2n-lane concatenation of t then s.
	shuffle :: proc(view: string, idx: []int) -> string {
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "intrinsics.simd_shuffle(t.%s, s.%s", view, view)
		for k in idx {fmt.sbprintf(&sb, ", %d", k)}
		fmt.sbprint(&sb, ")")
		return strings.to_string(sb)
	}
	interleave :: proc(n, base: int) -> []int {
		idx := make([]int, n, context.temp_allocator)
		for k in 0 ..< n / 2 {idx[2 * k], idx[2 * k + 1] = base + k, n + base + k}
		return idx
	}
	evens :: proc(n: int) -> []int {
		idx := make([]int, n, context.temp_allocator)
		for k in 0 ..< n {idx[k] = 2 * k}
		return idx
	}
	view, expr: string
	sh := i.sa & 15
	#partial switch i.op {
	case .MTSA:
		append(out, fmt.tprintf("c.sa = %s & 127", R32(i.rs)))
		return true
	case .MTSAB:
		append(out, fmt.tprintf("c.sa = ((%s ~ %d) & 15) * 8", R32(i.rs), u32(i.imm) & 15))
		return true
	case .MTSAH:
		append(out, fmt.tprintf("c.sa = ((%s ~ %d) & 7) * 16", R32(i.rs), u32(i.imm) & 7))
		return true
	case .MFC0:
		if i.rd == 15 {return false} // PRId stays in the interpreter
		src := i.rd == 9 ? "u32(c.cycles)" : fmt.tprintf("c.cop0[%d]", i.rd)
		if i.rt != 0 {append(out, fmt.tprintf("c.r[%d].d[0] = sx32(%s)", i.rt, src))}
		return true
	case .DI:
		append(out, "c.cop0[12] &~= 0x10000")
		return true
	case .EI:
		append(out, "kernel.ei()")
		return true
	case .PADDW: view, expr = "vw", bin("vw", "+")
	case .PSUBW: view, expr = "vw", bin("vw", "-")
	case .PADDH: view, expr = "vh", bin("vh", "+")
	case .PSUBH: view, expr = "vh", bin("vh", "-")
	case .PADDB: view, expr = "vb", bin("vb", "+")
	case .PSUBB: view, expr = "vb", bin("vb", "-")
	case .PADDUB: view, expr = "vb", call("simd_saturating_add", "vb")
	case .PADDSH: view, expr = "vh", call("simd_saturating_add", "vh")
	case .PADDUW: view, expr = "vw", call("simd_saturating_add", "vw")
	case .PMAXH: view, expr = "vh", call("simd_max", "vh")
	case .PMINH: view, expr = "vh", call("simd_min", "vh")
	case .PCGTH: view, expr = "vuh", call("simd_lanes_gt", "vh") // u16 lanes already
	case .PCEQH: view, expr = "vuh", call("simd_lanes_eq", "vh")
	case .PSLLH: view, expr = "vuh", fmt.tprintf("intrinsics.simd_shl(t.vuh, #simd[8]u16{{%s}})", splat(8, sh))
	case .PSRLH: view, expr = "vuh", fmt.tprintf("intrinsics.simd_shr(t.vuh, #simd[8]u16{{%s}})", splat(8, sh))
	case .PSRAH: view, expr = "vh", fmt.tprintf("intrinsics.simd_shr(t.vh, #simd[8]u16{{%s}})", splat(8, sh))
	case .PSRAW:
		view = "vw"
		expr = fmt.tprintf("transmute(#simd[4]u32)intrinsics.simd_shr(transmute(#simd[4]i32)t.vw, #simd[4]u32{{%s}})", splat(4, u8(i.sa)))
	case .PHMADH:
		// As the interpreter: LO and HI are written when rd is 0 too.
		rd := i.rd == 0 ? "" : fmt.tprintf("; c.r[%d].w = {{c.lo.w[0], c.hi.w[0], c.lo.w[2], c.hi.w[2]}}", i.rd)
		append(out, fmt.tprintf("{{s, t := c.r[%d], c.r[%d]; for k in 0 ..< 4 {{a := i32(s.sh[2 * k + 1]) * i32(t.sh[2 * k + 1]); v := a + i32(s.sh[2 * k]) * i32(t.sh[2 * k]); h := (k & 1) != 0 ? &c.hi : &c.lo; h.sw[k &~ 1], h.sw[k | 1] = v, a}}%s}}", i.rs, i.rt, rd))
		return true
	case .PAND:  view, expr = "q", bin("q", "&")
	case .POR:   view, expr = "q", bin("q", "|")
	case .PXOR:  view, expr = "q", bin("q", "~")
	case .PNOR:  view, expr = "q", "~(s.q | t.q)"
	case .PCPYLD: view, expr = "d", "{t.d[0], s.d[0]}"
	case .PCPYUD: view, expr = "d", "{s.d[1], t.d[1]}"
	case .PEXTLB: view, expr = "vb", shuffle("vb", interleave(16, 0))
	case .PEXTUB: view, expr = "vb", shuffle("vb", interleave(16, 8))
	case .PEXTLW: view, expr = "vw", shuffle("vw", interleave(4, 0))
	case .PEXTUW: view, expr = "vw", shuffle("vw", interleave(4, 2))
	case .PEXTLH: view, expr = "vuh", shuffle("vuh", interleave(8, 0))
	case .PEXTUH: view, expr = "vuh", shuffle("vuh", interleave(8, 4))
	case .PPACB:  view, expr = "vb", shuffle("vb", evens(16))
	case .PPACH:  view, expr = "vuh", shuffle("vuh", evens(8))
	case .PCPYH:  view, expr = "vuh", "intrinsics.simd_shuffle(t.vuh, t.vuh, 0, 0, 0, 0, 4, 4, 4, 4)"
	case .QFSRV:  view, expr = "q", "c.sa == 0 ? t.q : (t.q >> c.sa) | (s.q << (128 - c.sa))"
	case: return false
	}
	if i.rd == 0 {return true}
	#partial switch i.op {
	case .PSLLH, .PSRLH, .PSRAH, .PSRAW, .PCPYH:
		// shifts by sa and PCPYH read rt only
		append(out, fmt.tprintf("{{t := c.r[%d]; c.r[%d].%s = %s}}", i.rt, i.rd, view, expr))
	case:
		append(out, fmt.tprintf("{{s, t := c.r[%d], c.r[%d]; c.r[%d].%s = %s}}", i.rs, i.rt, i.rd, view, expr))
	}
	return true
}

branch_cond :: proc(i: Insn) -> string {
	rs, rt := i.rs, i.rt
	#partial switch i.op {
	case .BEQ, .BEQL:
		if rs == rt {return "true"}
		return fmt.tprintf("%s == %s", R64(rs), R64(rt))
	case .BNE, .BNEL:     return fmt.tprintf("%s != %s", R64(rs), R64(rt))
	case .BLEZ, .BLEZL:   return fmt.tprintf("%s <= 0", S64(rs))
	case .BGTZ, .BGTZL:   return fmt.tprintf("%s > 0", S64(rs))
	case .BLTZ, .BLTZL, .BLTZAL, .BLTZALL: return fmt.tprintf("%s < 0", S64(rs))
	case .BGEZ, .BGEZL, .BGEZAL, .BGEZALL:
		if rs == 0 {return "true"}
		return fmt.tprintf("%s >= 0", S64(rs))
	case .BC1F, .BC1FL: return "c.fcr31 & 0x800000 == 0"
	case .BC1T, .BC1TL: return "c.fcr31 & 0x800000 != 0"
	}
	// COP0/COP2 condition lines
	return fmt.tprintf("ps2.bc_cond(%s)", hexu(i.w))
}

// Labels other than the entry whose address the program takes: function
// pointers into code the discovery merged into a preceding function.
interior_entries :: proc(e: ^Emitter, f: ^Func) -> []u32 {
	out := make([dynamic]u32, context.temp_allocator)
	for l in f.labels {
		if l != f.entry && l in e.refs^ {append(&out, l)}
	}
	sort_u32(out[:])
	return out[:]
}

emit_func :: proc(e: ^Emitter, f: ^Func) {
	sb := &e.sb
	if len(interior_entries(e, f)) > 0 {
		// Enterable at several addresses: the body takes the start pc.
		fmt.sbprintfln(sb, "f_%08x :: proc() {{f_%08x_at(%s)}}\n", f.entry, f.entry, hexu(f.entry))
		fmt.sbprintfln(sb, "f_%08x_at :: proc(start: u32) {{", f.entry)
		fmt.sbprintln(sb, "\tc := &cpu.state")
		fmt.sbprintfln(sb, "\tif kernel.trace_on {{kernel.trace_call(start)}}")
		fmt.sbprintln(sb, "\tif c.cycles >= cpu.next_event {kernel.run_events()}")
		fmt.sbprintln(sb, "\tpc := start")
	} else {
		fmt.sbprintfln(sb, "f_%08x :: proc() {{", f.entry)
		fmt.sbprintln(sb, "\tc := &cpu.state")
		fmt.sbprintfln(sb, "\tif kernel.trace_on {{kernel.trace_call(%s)}}", hexu(f.entry))
		fmt.sbprintln(sb, "\tif c.cycles >= cpu.next_event {kernel.run_events()}")
		fmt.sbprintfln(sb, "\tpc: u32 = %s", hexu(f.entry))
	}
	fmt.sbprintln(sb, "\tfor {")
	fmt.sbprintln(sb, "\t\tswitch pc {")

	body := make([dynamic]string, 0, 64, context.temp_allocator)
	close_case :: proc(sb: ^strings.Builder, body: ^[dynamic]string) {
		for s in body {
			fmt.sbprintfln(sb, "\t\t\t%s", s)
		}
		clear(body)
	}
	// Open Branch, Jump_Reg and If_Taken steps; each If_Taken indents its
	// statements one tab, except cycle charges.
	open := make([dynamic]Step_Kind, 0, 4, context.temp_allocator)
	depth := 0
	for s in lower(f, e.cycles, e.quiet) {
		tab := strings.repeat("\t", depth, context.temp_allocator)
		put :: proc(body: ^[dynamic]string, tab: string, line: string) {
			append(body, fmt.tprintf("%s%s", tab, line))
		}
		switch s.kind {
		case .Case:
			if s.check {append(&body, "fallthrough")}
			close_case(sb, &body)
			fmt.sbprintfln(sb, "\t\tcase %s:", hexu(s.target))
		case .Op:
			n := len(body)
			if emit_op(s.i, &body) {count_slow(e.slow, s.i)}
			for k in n ..< len(body) {body[k] = fmt.tprintf("%s%s", tab, body[k])}
		case .Cycles:
			append(&body, fmt.tprintf("c.cycles += %d", s.n))
		case .Return:
			put(&body, tab, "return")
		case .Goto:
			put(&body, tab, fmt.tprintf("pc = %s", hexu(s.target)))
			if s.check {put(&body, tab, "if c.cycles >= cpu.next_event {kernel.run_events()}")}
			put(&body, tab, "continue")
		case .Call:
			put(&body, tab, call_stmt(e, s.target))
		case .Branch:
			put(&body, tab, "{")
			put(&body, tab, fmt.tprintf("t := %s", branch_cond(s.i)))
			append(&open, s.kind)
		case .Link:
			put(&body, tab, fmt.tprintf("c.r[%d].d[0] = %s", s.n, hexu(s.target)))
		case .If_Taken:
			put(&body, tab, "if t {")
			append(&open, s.kind)
			depth += 1
		case .Jump_Reg:
			put(&body, tab, "{")
			put(&body, tab, fmt.tprintf("t := %s", R32(u8(s.n))))
			append(&open, s.kind)
		case .Call_Reg:
			put(&body, tab, "cpu.call(t)")
		case .Goto_Reg:
			put(&body, tab, "pc = t")
			put(&body, tab, "if c.cycles >= cpu.next_event {kernel.run_events()}")
			put(&body, tab, "continue")
		case .End:
			if pop(&open) == .If_Taken {depth -= 1}
			put(&body, strings.repeat("\t", depth, context.temp_allocator), "}")
		}
	}
	close_case(sb, &body)
	fmt.sbprintln(sb, "\t\tcase:")
	// Jump to an address that is not a label: the jr target table missed it.
	fmt.sbprintfln(sb, "\t\t\tcpu.jump_unknown(%s, pc)", hexu(f.entry))
	fmt.sbprintln(sb, "\t\t\treturn")
	fmt.sbprintln(sb, "\t\t}")
	fmt.sbprintln(sb, "\t}")
	fmt.sbprintln(sb, "}")
	fmt.sbprintln(sb, "")
}

call_stmt :: proc(e: ^Emitter, t: u32) -> string {
	if pkg, ok := e.pkg_of[t]; ok && pkg == e.pkg {
		return fmt.tprintf("f_%08x()", t)
	}
	return fmt.tprintf("cpu.call(%s)", hexu(t))
}

sort_u32 :: proc(a: []u32) {
	// insertion is too slow for big functions; use the core sort
	slice.sort(a)
}
