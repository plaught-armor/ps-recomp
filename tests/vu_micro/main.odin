// VU microprograms compiled whole by the VU recompiler (recomp/vu
// emit_micro) against the interpreter. Two steps in one command, as
// tests/vu_macro: this program generates cases/main.odin, one run_<n> per
// program and unit, then runs it with `odin run`. Each program runs from
// random state, once in the interpreter and once compiled, and must leave
// vf, vi, ACC, MAC, Q, P and memory the same. Every program runs on VU1 and
// on VU0; on VU0 status must match too, since compiled VU0 code computes it.
// The seed is fixed, so a run is reproducible. cases/ is generated, not
// checked in.
//
// The programs check MAC liveness: an op that leaves MAC alone (MAX, MINI)
// between a MAC write and a flag read must not let the write be dropped.
// Then hazard pairs, where the lower reads or writes the VF register the
// upper writes: the lower must read it from before the upper, and its own
// write must win unless it leaves the register as it was. The VU0-only
// programs pair DIV, SQRT and RSQRT with an upper op, so the two status
// writes merge, with divisors that set I or D on every trial.
//
// Last, the EFU: each op writes P and MFP reads it back into part of a
// register, from random P first; then an ESIN reading and an MFP writing
// the upper's dest. Then ILWR and ISWR on each field, at addresses that
// wrap past the end of VU memory. Every program must compile without a
// call into the interpreter.
//
//   odin run tests/vu_micro -collection:ps=.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:recomp/vu"

DIR :: #directory
CASES_DIR :: DIR + "/cases"

// Pair halves: lower word first, as in micro memory.
NOP_L :: 0x8000033c
NOP_U :: 0x000002ff
E_BIT :: 1 << 30
FMAND_1_2 :: 0x1a << 25 | 1 << 16 | 2 << 11 // FMAND vi1, vi2

// Upper ops, dest xyzw: fd, fs, ft in their fields.
upper :: proc(fn, fd, fs, ft: u32) -> u32 {return 15 << 21 | ft << 16 | fs << 11 | fd << 6 | fn}

// Lower ops: opcode 0x40 specials by their sp number, and the others by
// opcode, with dest (or DIV's field selects), ft, fs and imm11 in place.
lower_sp :: proc(sp, dest, ft, fs: u32) -> u32 {
	return 0x40 << 25 | dest << 21 | ft << 16 | fs << 11 | (sp >> 2) << 6 | 0x3c | sp & 3
}
lower_op :: proc(op, dest, ft, fs, imm: u32) -> u32 {return op << 25 | dest << 21 | ft << 16 | fs << 11 | imm}

main :: proc() {
	ADD :: 0x28
	MAX :: 0x2b
	MINI :: 0x2f
	MAXbc :: 0x10
	MINIi :: 0x1f
	MULq :: 0x1c
	MULi :: 0x1e
	MSUBq :: 0x25
	LQ :: 0x00
	SQ :: 0x01
	MOVE :: 0x30
	MR32 :: 0x31
	LQI :: 0x34
	SQI :: 0x35
	DIV :: 0x38
	SQRT :: 0x39
	RSQRT :: 0x3a
	MTIR :: 0x3c
	ILWR :: 0x3e
	ISWR :: 0x3f
	IADDIU :: 0x08
	IADDI :: 0x32 // an IADD-family op, imm5 in the fd field
	MFP :: 0x64
	ESADD :: 0x70
	ERSADD :: 0x71
	ELENG :: 0x72
	ERLENG :: 0x73
	EATANxy :: 0x74
	EATANxz :: 0x75
	ESUM :: 0x76
	ESQRT :: 0x78
	ERSQRT :: 0x79
	ERCPR :: 0x7a
	ESIN :: 0x7c
	EATAN :: 0x7d
	EEXP :: 0x7e
	XYZ :: 0b1110
	PROGRAMS := [?][]u32 {
		// ADD sets MAC; MAX, MINI (each form) leave it for FMAND.
		{NOP_L, upper(ADD, 3, 1, 2), NOP_L, upper(MAX, 4, 1, 2), FMAND_1_2, NOP_U | E_BIT, NOP_L, NOP_U},
		{NOP_L, upper(ADD, 3, 1, 2), NOP_L, upper(MINI, 4, 1, 2), NOP_L, upper(MINIi, 5, 1, 0), FMAND_1_2, NOP_U | E_BIT, NOP_L, NOP_U},
		{NOP_L, upper(ADD, 3, 1, 2), NOP_L, upper(MAXbc | 2, 4, 1, 2), FMAND_1_2, NOP_U | E_BIT, NOP_L, NOP_U},
		// MAX writing the register ADD wrote.
		{NOP_L, upper(ADD, 3, 1, 2), NOP_L, upper(MAX, 3, 3, 1), FMAND_1_2, NOP_U | E_BIT, NOP_L, NOP_U},
		// The lower reads the upper's dest: DIV (vf3.y / vf3.z), SQRT,
		// MTIR, SQ and SQI, MOVE and MR32 into another register.
		{lower_sp(DIV, 0b1001, 3, 3), upper(MULq, 3, 1, 0), lower_sp(MTIR, 2, 5, 3), upper(MULi, 3, 2, 0), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
		{lower_sp(SQRT, 0b0100, 4, 0), upper(ADD, 4, 1, 2), lower_op(SQ, 0b1011, 6, 4, 0x13), upper(MSUBq, 4, 2, 0), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
		{lower_sp(SQI, 0b1111, 7, 5), upper(MULq, 5, 5, 0), lower_sp(MOVE, 0b0110, 9, 5), upper(ADD, 5, 1, 5), lower_sp(MR32, 0b1111, 10, 5), upper(MULi, 5, 5, 0), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
		// The lower writes the upper's dest: MOVE of the register onto
		// itself (the upper wins), LQI (it wins), LQ of x and z (it wins,
		// keeping y and w from before the upper). Each result is read by
		// the next upper, and LQ's is left at the end.
		{lower_sp(MOVE, 0b1111, 3, 3), upper(MULi, 3, 3, 0), lower_sp(LQI, 0b1111, 3, 6), upper(MSUBq, 3, 3, 0), lower_op(LQ, 0b1010, 3, 4, 0x7f5), upper(ADD, 3, 1, 2), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
		// Hazard pairs in an E-bit pair and its successor, one case.
		{NOP_L, upper(ADD, 3, 1, 2), lower_sp(DIV, 0b0110, 1, 3), upper(MULq, 3, 3, 0) | E_BIT, lower_sp(MTIR, 3, 4, 3), upper(ADD, 3, 3, 1)},
		// The EFU's vector ops (dest xyz, or xyzw for ESUM), each read back
		// by MFP into its own register, part (xz) or whole.
		{
			lower_sp(MFP, 0b0101, 3, 0), NOP_U,
			lower_sp(ESADD, XYZ, 0, 1), NOP_U, lower_sp(MFP, 0b1010, 4, 0), NOP_U,
			lower_sp(ERSADD, XYZ, 0, 2), NOP_U, lower_sp(MFP, 0b1111, 5, 0), NOP_U,
			lower_sp(ELENG, XYZ, 0, 3), NOP_U, lower_sp(MFP, 0b1010, 6, 0), NOP_U,
			lower_sp(ERLENG, XYZ, 0, 4), NOP_U, lower_sp(MFP, 0b1111, 7, 0), NOP_U,
			lower_sp(EATANxy, 0b1100, 0, 5), NOP_U, lower_sp(MFP, 0b1010, 8, 0), NOP_U,
			lower_sp(EATANxz, 0b1010, 0, 6), NOP_U, lower_sp(MFP, 0b1111, 9, 0), NOP_U,
			lower_sp(ESUM, 0b1111, 0, 7), NOP_U, lower_sp(MFP, 0b1010, 10, 0), NOP_U,
			NOP_L, NOP_U | E_BIT, NOP_L, NOP_U,
		},
		// The scalar ops, on field x, y, z and w in turn (fsf in DIV's fs
		// select bits).
		{
			lower_sp(ESQRT, 0b0000, 0, 1), NOP_U, lower_sp(MFP, 0b1010, 3, 0), NOP_U,
			lower_sp(ERSQRT, 0b0001, 0, 2), NOP_U, lower_sp(MFP, 0b1111, 4, 0), NOP_U,
			lower_sp(ERCPR, 0b0010, 0, 3), NOP_U, lower_sp(MFP, 0b1010, 5, 0), NOP_U,
			lower_sp(ESIN, 0b0011, 0, 4), NOP_U, lower_sp(MFP, 0b1111, 6, 0), NOP_U,
			lower_sp(EATAN, 0b0001, 0, 5), NOP_U, lower_sp(MFP, 0b1010, 7, 0), NOP_U,
			lower_sp(EEXP, 0b0010, 0, 6), NOP_U, lower_sp(MFP, 0b1111, 8, 0), NOP_U,
			NOP_L, NOP_U | E_BIT, NOP_L, NOP_U,
		},
		// Hazard pairs: ESIN reads vf3.y from before the ADD that writes it;
		// MFP writes yw of vf3, which the MULi beside it writes too.
		{
			NOP_L, upper(ADD, 3, 1, 2), lower_sp(ESIN, 0b0001, 0, 3), upper(ADD, 3, 3, 1),
			lower_sp(MFP, 0b0101, 3, 0), upper(MULi, 3, 3, 0), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U,
		},
		// ILWR and ISWR on each field. vi4 = 0x7fff is the last quadword
		// of either VU's memory; one more wraps it to the first. vi6 is
		// random, so wraps too. ILWR.xyzw keeps w; ILWR to vi0 does nothing.
		{
			lower_op(IADDIU, 0xf, 4, 0, 0x7ff), NOP_U, lower_sp(ISWR, 0b1000, 3, 4), NOP_U,
			lower_sp(ILWR, 0b0100, 5, 4), NOP_U, lower_sp(ISWR, 0b0101, 7, 6), NOP_U,
			lower_op(0x40, 0, 4, 4, 1 << 6 | IADDI), NOP_U, lower_sp(ISWR, 0b0010, 11, 4), NOP_U,
			lower_sp(ILWR, 0b0010, 8, 4), NOP_U, lower_sp(ILWR, 0b1000, 10, 4), NOP_U,
			lower_sp(ILWR, 0b0001, 9, 6), NOP_U, lower_sp(ILWR, 0b1111, 12, 6), NOP_U,
			lower_sp(ILWR, 0b1111, 0, 6), NOP_U, NOP_L, NOP_U | E_BIT, NOP_L, NOP_U,
		},
	}
	// VU0 only. DIV vf1.x / vf0.x (I or D) with ADD; SQRT vf1.y with MULq,
	// then RSQRT vf2.z / vf0.y (I or D) with MAX, which leaves status;
	// DIV vf3.z / vf0.y with an E-bit MULq, after the ADD that writes vf3.
	PROGRAMS_VU0 := [?][]u32 {
		{lower_sp(DIV, 0, 0, 1), upper(ADD, 3, 1, 2), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
		{lower_sp(SQRT, 0b0100, 1, 0), upper(MULq, 3, 1, 0), lower_sp(RSQRT, 0b0110, 0, 2), upper(MAX, 4, 1, 2), NOP_L, NOP_U | E_BIT, NOP_L, NOP_U},
		{NOP_L, upper(ADD, 3, 1, 2), lower_sp(DIV, 0b0110, 0, 3), upper(MULq, 3, 3, 0) | E_BIT, NOP_L, upper(ADD, 3, 3, 1)},
	}
	Prog :: struct {
		words: []u32,
		unit:  vu.Unit,
	}
	progs: [dynamic]Prog
	for w in PROGRAMS {append(&progs, Prog{w, .VU1}, Prog{w, .VU0})}
	for w in PROGRAMS_VU0 {append(&progs, Prog{w, .VU0})}

	sb := strings.builder_make()
	fmt.sbprintln(&sb, "// Generated by tests/vu_micro: do not edit.\npackage main\n")
	fmt.sbprintln(&sb, "import \"core:fmt\"\nimport \"core:math\"\nimport \"core:math/rand\"\nimport \"core:os\"\nimport \"core:simd\"\nimport \"core:slice\"\nimport vu \"ps:ps2/vu\"\n")
	fmt.sbprintln(&sb, "_ :: math\n_ :: simd\n_ :: slice\n")
	fmt.sbprintln(&sb, vu.VU_HELPERS)
	fmt.sbprintln(&sb, vu.MACRO_HELPERS)
	fmt.sbprintln(&sb, "Case :: struct {words: []u32, run: vu.Vu_Run, vu0: bool}\n")
	fmt.sbprintln(&sb, "CASES := [?]Case{")
	for p, n in progs {fmt.sbprintfln(&sb, "\t{{code_%d[:], run_%d, %v}},", n, n, p.unit == .VU0)}
	fmt.sbprintln(&sb, "}\n")
	for p, n in progs {
		fmt.sbprintf(&sb, "code_%d := [?]u32{{", n)
		for w, k in p.words {fmt.sbprintf(&sb, "%s0x%08x", k == 0 ? "" : ", ", w)}
		fmt.sbprintln(&sb, "}\n")
		slow: map[string]int
		fmt.sbprintln(&sb, vu.emit_micro(n, p.words, p.unit, &slow))
		for op, count in slow {fail("program %d calls the interpreter for %s (%d)", n, op, count)}
	}
	fmt.sbprint(&sb, HARNESS)

	dir :: CASES_DIR
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil {fail("mkdir %s: %v", dir, err)}
	}
	path :: CASES_DIR + "/main.odin"
	if err := os.write_entire_file(path, sb.buf[:]); err != nil {fail("write %s: %v", path, err)}

	// odin exits 0 on some build errors (an -out: without .exe on Windows), so a
	// missing binary afterwards fails the test. Remove any stale one first;
	// -keep-executable leaves the new one to check.
	out :: CASES_DIR + "/vu_micro_cases" + (".exe" when ODIN_OS == .Windows else "")
	_ = os.remove(out)
	p, err := os.process_start({command = {"odin", "run", dir, "-collection:ps=" + DIR + "/../..", "-out:" + out, "-keep-executable"}, stdout = os.stdout, stderr = os.stderr})
	if err != nil {fail("odin run: %v", err)}
	st, werr := os.process_wait(p)
	if werr != nil {fail("odin run: %v", werr)}
	if !st.success {fail("cases failed (exit %d)", st.exit_code)}
	if !os.exists(out) {fail("cases not built: %s", out)}
}

@(private = "file")
fail :: proc(what: string, args: ..any) -> ! {
	fmt.eprint("FAIL vu_micro: ")
	fmt.eprintfln(what, ..args)
	os.exit(1)
}

// The generated program's runner.
HARNESS :: `SEED :: 0x5eed_0b17
TRIALS :: 300

SPECIAL := [?]u32{0, 0x80000000, 0x7f800000, 0xff800000, 0x7fffffff, 0xffffffff, 0x7f7fffff, 0xff7fffff, 1, 0x3f800000, 0xbf800000, 0x00800000, 0x007fffff}

rnd :: proc() -> u32 {
	switch rand.uint32() % 3 {
	case 0: return SPECIAL[rand.uint32() % len(SPECIAL)]
	case 1: return transmute(u32)(rand.float32_range(-4, 4))
	}
	return rand.uint32()
}

main :: proc() {
	rand.reset(SEED)
	vu.vu_init()
	fails, flagged, status_set := 0, 0, 0
	for c, n in CASES {
		v := c.vu0 ? &vu.vu0 : &vu.vu1
		mem := ([^]u32)(raw_data(v.mem))[:len(v.mem) / 4]
		mem_init := make([]u32, len(mem))
		mem_want := make([]u32, len(mem))
		for &b in v.micro {b = 0}
		copy(([^]u32)(&v.micro[0])[:len(c.words)], c.words)
		for _ in 0 ..< TRIALS {
			init := v^
			init.vf[0].f = {0, 0, 0, 1}
			for k in 1 ..< 32 {for l in 0 ..< 4 {init.vf[k].u[l] = rnd()}}
			for l in 0 ..< 4 {init.acc.u[l] = rnd()}
			init.vi[0] = 0
			for k in 1 ..< 16 {init.vi[k] = u16(rand.uint32())}
			init.vi[2] = 0xffff
			init.i = transmute(f32)rnd()
			init.q = transmute(f32)rnd()
			init.p = transmute(f32)rnd()
			init.mac = rand.uint32() & 0xffff
			init.status = rand.uint32() & 0xfcf // I and D clear, so the control counts the program's
			for &w in mem_init {w = rnd()}
			v^ = init
			copy(mem, mem_init)
			if c.vu0 {vu.vu0_call_micro(0)} else {vu.vu1_start(0)}
			want := v^
			copy(mem_want, mem)
			v^ = init
			copy(mem, mem_init)
			budget := 1000
			pc, exit := c.run(0, &budget)
			got := v^
			if want.mac != init.mac {flagged += 1}
			if c.vu0 && want.status & 0x30 != 0 {status_set += 1}
			same := exit == .End && pc == want.tpc && got.vi == want.vi && got.acc.u == want.acc.u && got.mac == want.mac
			same &&= transmute(u32)got.q == transmute(u32)want.q && transmute(u32)got.p == transmute(u32)want.p && slice.equal(mem, mem_want)
			same &&= !c.vu0 || got.status == want.status
			for k in 0 ..< 32 {same &&= got.vf[k].u == want.vf[k].u}
			if !same {
				fails += 1
				if fails < 10 {
					k := 0 // the first VF register that differs, else vf31
					for k < 31 && got.vf[k].u == want.vf[k].u {k += 1}
					fmt.eprintfln("FAIL vu_micro program %d (vu%d): got exit %v pc %04x mac %04x status %04x vi1 %04x vf%d %08x, want pc %04x mac %04x status %04x vi1 %04x vf%d %08x; same Q %v, same P %v, same memory %v",
						n, c.vu0 ? 0 : 1, exit, pc, got.mac, got.status, got.vi[1], k, got.vf[k].u, want.tpc, want.mac, want.status, want.vi[1], k, want.vf[k].u,
						transmute(u32)got.q == transmute(u32)want.q, transmute(u32)got.p == transmute(u32)want.p, slice.equal(mem, mem_want))
				}
				break
			}
		}
	}
	fmt.printfln("vu_micro: %d programs x %d trials, %d failing, MAC changed in %d, VU0 I or D set in %d", len(CASES), TRIALS, fails, flagged, status_set)
	// A VU0 case whose divisors never set I or D would not test the merge.
	if status_set < TRIALS * 3 {fmt.eprintfln("FAIL vu_micro: VU0 I or D set in only %d trials", status_set); os.exit(1)}
	if fails > 0 {os.exit(1)}
}
`
