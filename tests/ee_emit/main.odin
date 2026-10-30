// EE register instructions through the Odin backend (recomp/r5900.emit_op)
// against the interpreter's exec_insn. Two steps in one command: this
// program generates cases/main.odin, one proc per instruction word emit_op
// inlines (every MMI and SPECIAL word the decoder maps to a covered op, the
// MADD family, the immediate ops and REGIMM traps at each of IMMS, MFC0,
// TLBR, TLBWI, TLBWR, TLBP, MFC1, MTC1, SQRT.S,
// RSQRT.S, MUL.S, MULA.S, MADD.S, DIV.S, CVT.W.S, QMTC2, LQC2, MFSA, MTSA, MTSAB
// and MTSAH, with rd 0,
// rs/rt 0 and aliased registers, and every shift amount for the shifts by
// sa), then runs it with `odin run`. Each case runs
// from random registers (edge bytes for saturation, special floats) and must
// leave the whole cpu.state and VU0's VF registers as exec_insn leaves them.
// First FAST_HELPERS' fadd, fsub, fmul, fpdiv, fsqrt and fcvtw must give
// cpu.fpu_add, fpu_sub, fpu_mul, fpu_div, fpu_sqrt and cvt_w's bits on a grid
// of floats and random ones near the ends of the exponent range. The seed is fixed, so a
// run is reproducible. Words emit_op leaves to the interpreter are counted
// and skipped. cases/ is generated, not checked in.
//
//   odin run tests/ee_emit -collection:ps=.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:recomp/r5900"
import "ps:recomp/vu"

DIR :: #directory
CASES_DIR :: DIR + "/cases"

Ops :: bit_set[r5900.Op; [8]u64]

// gen.odin's RUNTIME_PACKAGES.
RUNTIME_PACKAGES :: [?]string{"cpu", "kernel", "mem", "vu"}

// The instructions the test covers; the other inline ops are memory,
// control or exercised elsewhere.
COVERED :: Ops{
	.PADDW, .PSUBW, .PADDH, .PSUBH, .PADDB, .PSUBB, .PADDUB, .PMAXH, .PMINH, .PCGTH, .PCEQH,
	.PSLLH, .PSRLH, .PSRAH, .PAND, .POR, .PXOR, .PNOR, .PCPYLD, .PCPYUD, .PCPYH,
	.PEXTLB, .PEXTUB, .PEXTLH, .PEXTUH, .PEXTLW, .PEXTUW, .PPACB, .PPACH,
	.PADDSH, .PADDUW, .PSRAW, .PHMADH, .MADD, .MADDU, .MADD1, .MADDU1, .MTHI1, .MTLO1, .SQRT_S, .RSQRT_S,
	.MUL_S, .MULA_S, .MADD_S, .DIV_S, .CVT_W_S, .QMTC2, .LQC2, .MFSA, .MTSA, .MTSAB, .MTSAH,
	.QFSRV, .PLZCW, .MFHI1, .MFLO1, .MULT1, .MULTU1, .DIV1, .DIVU1,
	.MTC0, .ERET, .CFC1, .CTC1, .C_F_S,
	.PADDSB, .PSUBSB, .PSUBSH, .PADDSW, .PSUBSW, .PADDUH, .PSUBUH, .PSUBUB, .PSUBUW,
	.PCGTB, .PCGTW, .PCEQB, .PCEQW, .PMAXW, .PMINW, .PABSH, .PABSW, .PSLLW, .PSRLW,
	.PPACW, .PINTH, .PINTEH, .PEXEH, .PEXEW, .PREVH, .PROT3W, .PEXCH, .PEXCW,
	.PSLLVW, .PSRLVW, .PSRAVW, .PEXT5, .PPAC5, .PADSBH,
	.PMFHI, .PMFLO, .PMTHI, .PMTLO, .PMFHL, .PMTHL, .PMULTW, .PMULTUW, .PMADDW, .PMADDUW, .PMSUBW,
	.PMULTH, .PMADDH, .PMSUBH, .PHMSBH, .PDIVW, .PDIVUW, .PDIVBW,
	.SLL, .SRL, .SRA, .SLLV, .SRLV, .SRAV, .DSLL, .DSRL, .DSRA, .DSLL32, .DSRL32, .DSRA32,
	.DSLLV, .DSRLV, .DSRAV, .MOVZ, .MOVN, .MFHI, .MFLO, .MTHI, .MTLO, .MULT, .MULTU, .DIV, .DIVU,
	.ADD, .ADDU, .SUB, .SUBU, .DADD, .DADDU, .DSUB, .DSUBU, .AND, .OR, .XOR, .NOR, .SLT, .SLTU,
	.ADDI, .ADDIU, .DADDI, .DADDIU, .SLTI, .SLTIU, .ANDI, .ORI, .XORI, .LUI, .MFC1, .MTC1, .SYNC,
	.TGE, .TGEU, .TLT, .TLTU, .TEQ, .TNE, .TRAPI, .MFC0, .TLBR, .TLBWI, .TLBWR, .TLBP,
}
// The shifts by sa and PMFHL's variants: every sa gets a case.
BY_SA :: Ops{.PSLLH, .PSRLH, .PSRAH, .PSLLW, .PSRLW, .PSRAW, .PMFHL, .SLL, .SRL, .SRA, .DSLL, .DSRL, .DSRA, .DSLL32, .DSRL32, .DSRA32}
// The immediate ops' opcodes, and immediates at zero, one and the limits
// of the sign extension.
IMM_OPS :: [?]u32{0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x18, 0x19}
IMMS :: [?]u32{0, 1, 0x7fff, 0x8000, 0xffff}

main :: proc() {
	helper_clashes()
	REGS := [?][3]u32{{1, 2, 3}, {1, 2, 0}, {0, 2, 3}, {1, 0, 3}, {4, 4, 4}, {5, 6, 5}, {5, 6, 6}} // rs, rt, rd
	words: [dynamic]u32
	for r in REGS {
		seen: Ops
		// MMI and SPECIAL words; MFSA and MTSA are below
		for major in ([?]u32{0x1c, 0}) {
			for fn in u32(0) ..< 64 {
				for sa in u32(0) ..< 32 {
					w := major << 26 | r[0] << 21 | r[1] << 16 | r[2] << 11 | sa << 6 | fn
					op := r5900.decode(0, w).op
					if op not_in COVERED || (op in seen && op not_in BY_SA) || op == .MFSA || op == .MTSA {continue}
					seen += {op}
					append(&words, w)
				}
			}
		}
		// the immediate ops, rt = rd
		for op in IMM_OPS {
			for imm in IMMS {append(&words, op << 26 | r[0] << 21 | r[2] << 16 | imm)}
		}
		// MFC1 rd = f[rs]; MTC1 f[rd] = rt
		append(&words, 0x11 << 26 | r[2] << 16 | r[0] << 11, 0x11 << 26 | 0x04 << 21 | r[1] << 16 | r[2] << 11)
		// SQRT.S f[rd] = sqrt(f[rt]), with fs = rs (unused)
		append(&words, 0x11 << 26 | 0x10 << 21 | r[1] << 16 | r[0] << 11 | r[2] << 6 | 0x04)
		// RSQRT.S f[rd] = f[rs] / sqrt(f[rt])
		append(&words, 0x11 << 26 | 0x10 << 21 | r[1] << 16 | r[0] << 11 | r[2] << 6 | 0x16)
		// MUL.S, MULA.S, MADD.S and DIV.S f[rd] = f[rs] op f[rt]
		for fn in ([?]u32{0x02, 0x1a, 0x1c, 0x03}) {
			append(&words, 0x11 << 26 | 0x10 << 21 | r[1] << 16 | r[0] << 11 | r[2] << 6 | fn)
		}
		// CVT.W.S f[rd] = f[rs]; QMTC2 vf[rd] = rt
		append(&words, 0x11 << 26 | 0x10 << 21 | r[0] << 11 | r[2] << 6 | 0x24, 0x12 << 26 | 0x05 << 21 | r[1] << 16 | r[2] << 11)
		// LQC2 vf[rt] = (base + imm), the harness pointing the base into
		// the scratchpad; a base of r0 would read below RAM
		if r[0] != 0 {
			for imm in ([?]u32{0, 0x0017, 0xfff0}) {append(&words, 0x36 << 26 | r[0] << 21 | r[1] << 16 | imm)}
		}
		// MFSA to rd; MTSA, MTSAB and MTSAH from rs
		append(&words, r[2] << 11 | 0x28)
		append(&words, r[0] << 21 | 0x29)
		append(&words, 0x01 << 26 | r[0] << 21 | 0x18 << 16 | 0xfff5, 0x01 << 26 | r[0] << 21 | 0x19 << 16 | 0x0006)
		// the REGIMM traps of rs against each of IMMS, 13 the one that never traps
		for rt in u32(8) ..= 14 {
			for imm in IMMS {append(&words, 0x01 << 26 | r[0] << 21 | rt << 16 | imm)}
		}
	}
	// COP0 and COP1 moves: MTC0 Status, EPC and Wired (from r0), ERET,
	// CFC1 fcr31, FCR0 and to r0, CTC1 fcr31 and FCR0 (ignored); C.F.S.
	append(&words, 0x40816000, 0x40827000, 0x40803000, 0x42000018, 0x4443f800, 0x44430000, 0x4440f800, 0x44c1f800, 0x44c10000, 0x46020830)
	// MFC0 Status, PRId and PRId to r0; TLBR, TLBWI, TLBWR and TLBP
	append(&words, 0x40036000, 0x4003f000, 0x4000f000, 0x42000001, 0x42000002, 0x42000006, 0x42000008)

	sb := strings.builder_make()
	fmt.sbprintln(&sb, "// Generated by tests/ee_emit: do not edit.\npackage main\n")
	// The recompiler's prelude (gen.odin), so the cases compile as they do
	// in a generated package.
	fmt.sbprintln(&sb, "import \"base:intrinsics\"\nimport \"base:runtime\"\nimport \"core:fmt\"\nimport \"core:math\"\nimport \"core:math/rand\"\nimport \"core:os\"\nimport \"core:simd\"\nimport ps2 \"ps:ps2\"\nimport r5900 \"ps:ps2/r5900\"")
	for p in RUNTIME_PACKAGES {fmt.sbprintfln(&sb, "import %s \"ps:ps2/%s\"", p, p)}
	fmt.sbprintln(&sb, "\n_ :: intrinsics\n_ :: math\n_ :: simd")
	for p in RUNTIME_PACKAGES {fmt.sbprintfln(&sb, "_ :: %s", p)}
	fmt.sbprintln(&sb, "")
	fmt.sbprintln(&sb, r5900.FAST_HELPERS)
	n, skipped := 0, 0
	covered: Ops
	body := strings.builder_make()
	fmt.sbprintln(&sb, "CASES := [?]Case{")
	for w in words {
		i := r5900.decode(0, w)
		code := make([dynamic]string)
		if r5900.emit_op(i, &code) {
			skipped += 1
			continue
		}
		covered += {i.op}
		fmt.sbprintfln(&body, "c_%d :: proc() {{\n\tc := &cpu.state; _ = c", n)
		for l in code {fmt.sbprintfln(&body, "\t%s", l)}
		fmt.sbprintln(&body, "}")
		fmt.sbprintfln(&sb, "\t{{0x%08x, c_%d}},", w, n)
		n += 1
	}
	fmt.sbprintln(&sb, "}\n")
	fmt.sbprintln(&sb, strings.to_string(body))
	fmt.sbprint(&sb, HARNESS)
	if covered != COVERED {fail("inline cases: missing %v, not listed in COVERED %v", COVERED - covered, covered - COVERED)}

	dir :: CASES_DIR
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil {fail("mkdir %s: %v", dir, err)}
	}
	path :: CASES_DIR + "/main.odin"
	if err := os.write_entire_file(path, sb.buf[:]); err != nil {fail("write %s: %v", path, err)}
	fmt.printfln("ee_emit: %d cases, %d left to the interpreter", n, skipped)

	// odin exits 0 on some build errors (an -out: without .exe on Windows), so a
	// missing binary afterwards fails the test. Remove any stale one first;
	// -keep-executable leaves the new one to check.
	out :: CASES_DIR + "/ee_emit_cases" + (".exe" when ODIN_OS == .Windows else "")
	_ = os.remove(out)
	p, err := os.process_start({command = {"odin", "run", dir, "-collection:ps=" + DIR + "/../..", "-out:" + out, "-keep-executable"}, stdout = os.stdout, stderr = os.stderr})
	if err != nil {fail("odin run: %v", err)}
	st, werr := os.process_wait(p)
	if werr != nil {fail("odin run: %v", werr)}
	if !st.success {fail("cases failed (exit %d)", st.exit_code)}
	if !os.exists(out) {fail("cases not built: %s", out)}
}

// A package with inline COP2 macro code gets FAST_HELPERS, VU_HELPERS and
// MACRO_HELPERS together (gen.odin), so no top-level name may repeat
// across them.
@(private = "file")
helper_clashes :: proc() {
	seen: map[string]string
	for h in ([?][2]string{{"FAST_HELPERS", r5900.FAST_HELPERS}, {"VU_HELPERS", vu.VU_HELPERS}, {"MACRO_HELPERS", vu.MACRO_HELPERS}}) {
		for line in strings.split_lines(h[1]) {
			end := strings.index(line, " :: ")
			if end <= 0 || line[0] == ' ' || line[0] == '\t' || line[0] == '/' {continue}
			name := line[:end]
			if name == "_" {continue}
			if prev, ok := seen[name]; ok {fail("%s declared in both %s and %s", name, prev, h[0])}
			seen[name] = h[0]
		}
	}
}

@(private = "file")
fail :: proc(what: string, args: ..any) -> ! {
	fmt.eprint("FAIL ee_emit: ")
	fmt.eprintfln(what, ..args)
	os.exit(1)
}

// The generated program's runner.
HARNESS :: `Case :: struct {w: u32, f: proc()}

SEED :: 0x5eed_0b18
TRIALS :: 300

// Bytes at the signed and unsigned limits, for saturation and sign extension.
EDGE := [?]u8{0, 1, 0x7f, 0x80, 0x81, 0xfe, 0xff}
SPECIAL := [?]u32{0, 0x80000000, 0x7f800000, 0xff800000, 0x7fffffff, 0xffffffff, 0x7f7fffff, 0xff7fffff, 1, 0x80000001, 0x3f800000, 0xbf800000, 0x00800000, 0x40800000, 0x1f800000, 0x5f800000}

rnd128 :: proc() -> (g: cpu.Gpr) {
	switch rand.uint32() % 3 {
	case 0: for k in 0 ..< 16 {g.b[k] = EDGE[rand.uint32() % len(EDGE)]}
	case 1: for k in 0 ..< 4 {g.w[k] = rand.uint32() % 2 == 0 ? 0xffffffff : 0x80000000 - rand.uint32() % 2}
	case: g.q = rand.uint128()
	}
	return
}

trapped: bool
trapped_pc: u32
trap_hook :: proc(pc: u32) {trapped, trapped_pc = true, pc}

// Whether trap word w traps from c, from the encoding, apart from the backends.
trap_taken :: proc(w: u32, c: ^cpu.Cpu) -> bool {
	s, t, imm := c.r[(w >> 21) & 31].d[0], c.r[(w >> 16) & 31].d[0], u64(i64(i16(w)))
	if w >> 26 == 0 {
		switch w & 63 {
		case 0x30: return i64(s) >= i64(t)
		case 0x31: return s >= t
		case 0x32: return i64(s) < i64(t)
		case 0x33: return s < t
		case 0x34: return s == t
		case 0x36: return s != t
		}
	} else if w >> 26 == 1 {
		switch (w >> 16) & 31 {
		case 8:  return i64(s) >= i64(imm)
		case 9:  return s >= imm
		case 10: return i64(s) < i64(imm)
		case 11: return s < imm
		case 12: return s == imm
		case 14: return s != imm
		}
	}
	return false
}

// FAST_HELPERS' float copies against cpu's, the bits of every pair of a
// grid and of random pairs. Returns the failures.
drift :: proc() -> (fails: int) {
	EXPS := [?]u32{0, 1, 2, 3, 63, 64, 126, 127, 128, 129, 190, 191, 251, 252, 253, 254, 255}
	MANTS := [?]u32{0, 1, 0x2aaaab, 0x400000, 0x7ffffe, 0x7fffff}
	vals: [dynamic]u32
	defer delete(vals)
	for e in EXPS {
		for m in MANTS {append(&vals, e << 23 | m, 0x80000000 | e << 23 | m)}
	}
	for _ in 0 ..< 200_000 {append(&vals, rand.uint32() & 0x807fffff | EXPS[rand.uint32() % len(EXPS)] << 23)}
	same :: proc(name: string, x, y: u32, got, want: f32, fails: ^int) {
		if transmute(u32)got == transmute(u32)want {return}
		fails^ += 1
		if fails^ < 10 {fmt.eprintfln("FAIL ee_emit drift %s %08x, %08x: cpu gives %08x, FAST_HELPERS %08x", name, x, y, transmute(u32)want, transmute(u32)got)}
	}
	n := len(EXPS) * len(MANTS) * 2
	for i in 0 ..< len(vals) {
		x := vals[i]
		a := transmute(f32)x
		same("fsqrt", x, 0, fsqrt(a), cpu.fpu_sqrt(a), &fails)
		same("fcvtw", x, 0, transmute(f32)fcvtw(a), transmute(f32)cpu.cvt_w(a), &fails)
		// the grid pairs all, a random value pairs with its neighbour
		ys := i < n ? vals[:n] : vals[i - 1:i]
		for y in ys {
			b := transmute(f32)y
			same("fadd", x, y, fadd(a, b), cpu.fpu_add(a, b), &fails)
			same("fsub", x, y, fsub(a, b), cpu.fpu_sub(a, b), &fails)
			same("fmul", x, y, fmul(a, b), cpu.fpu_mul(a, b), &fails)
			same("fpdiv", x, y, fpdiv(a, b), cpu.fpu_div(a, b), &fails)
		}
	}
	return
}

main :: proc() {
	rand.reset(SEED)
	fails := drift()
	rand.reset(SEED)
	cpu.trap_hook = trap_hook
	defer cpu.trap_hook = nil
	for c in CASES {
		op := r5900.decode(0, c.w).op
		trap := op == .TGE || op == .TGEU || op == .TLT || op == .TLTU || op == .TEQ || op == .TNE || op == .TRAPI
		for n in 0 ..< TRIALS {
			init: cpu.Cpu
			for k in 1 ..< 32 {init.r[k] = rnd128()}
			init.hi, init.lo = rnd128(), rnd128()
			for k in 0 ..< 32 {init.f[k].u = rand.uint32() % 2 == 0 ? SPECIAL[rand.uint32() % len(SPECIAL)] : rand.uint32()}
			init.acc.u, init.fcr31, init.sa = rand.uint32(), rand.uint32(), rand.uint32() & 127
			init.cop0[12] = rand.uint32()
			rs, rt := (c.w >> 21) & 31, (c.w >> 16) & 31
			if trap {
				// every other trial rs equal to rt or the immediate, so the
				// equal and not-equal sides both run
				if n % 2 == 1 && rs != 0 {
					init.r[rs].d[0] = c.w >> 26 == 1 ? u64(i64(i16(c.w))) : init.r[rt].d[0]
				}
			}
			if op == .DIV || op == .DIVU || op == .DIV1 || op == .DIVU1 {
				// every fourth trial a zero divisor, every fourth MIN over -1
				switch n % 4 {
				case 1: if rt != 0 {init.r[rt].w[0] = 0}
				case 2:
					if rs != 0 {init.r[rs].w[0] = 0x80000000}
					if rt != 0 {init.r[rt].w[0] = 0xffffffff}
				}
			}
			if op == .PLZCW && rs != 0 {
				// words of 0 and all ones, either way round; rd's high
				// doubleword is random, so a write there shows
				switch n % 4 {
				case 1: init.r[rs].w[0], init.r[rs].w[1] = 0, 0xffffffff
				case 3: init.r[rs].w[0], init.r[rs].w[1] = 0xffffffff, 0
				}
			}
			taken := trap && trap_taken(c.w, &init)
			if op == .LQC2 {
				// base + imm somewhere in the scratchpad, any low bits
				init.r[(c.w >> 21) & 31].w[0] = mem.SPR_BASE + rand.uint32() % (mem.SPR_SIZE - 32) + 16 - u32(i32(i16(c.w)))
				for k in 0 ..< mem.SPR_SIZE / 16 {(^u128)(&mem.spr[k * 16])^ = rand.uint128()}
			}
			vf: [32]vu.Vf
			for k in 1 ..< 32 {vf[k].q = rand.uint128()}
			cpu.state = init
			vu.vu0.vf = vf
			trapped = false
			c.f()
			got, got_vf, got_trapped, got_pc := cpu.state, vu.vu0.vf, trapped, trapped_pc
			cpu.state = init
			vu.vu0.vf = vf
			trapped = false
			ps2.exec_insn(r5900.decode(0, c.w))
			// A trap calls cpu.trap at its pc in both, exactly when the
			// encoding says; the state compare shows nothing written. The
			// cases are at pc 0, so this pc check only shows both pass 0;
			// tests/ee_native checks a real address.
			if (taken || got_trapped || trapped) && (!taken || !got_trapped || !trapped || got_pc != 0 || trapped_pc != 0) {
				fails += 1
				if fails < 10 {fmt.eprintfln("FAIL ee_emit %08x: trap %v, emitted %v at %08x, interp %v at %08x", c.w, taken, got_trapped, got_pc, trapped, trapped_pc)}
				break
			}
			if runtime.memory_compare(&got, &cpu.state, size_of(cpu.Cpu)) != 0 || runtime.memory_compare(&got_vf, &vu.vu0.vf, size_of(got_vf)) != 0 {
				fails += 1
				if fails < 10 {
					fmt.eprintfln("FAIL ee_emit %08x: got r3 %32x hi %32x lo %32x f3 %08x, want r3 %32x hi %32x lo %32x f3 %08x",
						c.w, got.r[3].q, got.hi.q, got.lo.q, got.f[3].u, cpu.state.r[3].q, cpu.state.hi.q, cpu.state.lo.q, cpu.state.f[3].u)
				}
				break
			}
		}
	}
	fmt.printfln("ee_emit: %d cases x %d trials, %d failing", len(CASES), TRIALS, fails)
	if fails > 0 {os.exit(1)}
}
`
