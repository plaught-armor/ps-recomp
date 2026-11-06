// VU microprograms through the native backend (recomp/vu native_program)
// against the interpreter, run on every target in CI. The programs are
// tests/vu_micro's (tests/vu_programs), each assembled for the host as a
// function of its own and loaded with the runtime's imports. From the same
// random state, the native function and the interpreter must leave the same
// vf, vi, ACC, Q, P, I, R, CLIP, MAC, the pending DIV's I and D bits
// (q_flags, q_due), memory and stopping pc; status too on VU0, and on VU1
// in a program that reads it (FSEQ, FSAND, FSOR), as compiled code computes
// it there. Every native run must end the program, no program may call
// the interpreter but for its status reads, and a run from
// one of a program's leaves must leave at once. A miss capture of VU1
// records only what no registered program runs, once across runs
// (test_miss_capture). A second pass
// registers the functions as the runtime does (unless VUNATIVE=0) and runs the
// same trials through vu0_call_micro and vu1_start, which must leave what a
// direct call leaves; after a write into a program's micro memory, they
// must interpret it instead. Before that, one VU1 program with no status
// read, registered alone, must make each outside read of VU1 status a
// compat row (vu_programs.stale_status).
// The seed is fixed, so a run is reproducible.
//
//   odin run tests/vu_native -collection:ps=.
package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "ps:core"
import "ps:ps2"
import "ps:ps2/vu"
import "ps:recomp/native"
import "ps:recomp/r5900"
import rvu "ps:recomp/vu"
import "ps:tests/vu_programs"

SEED :: 0x5eed_0b17
TRIALS :: 300
BUDGET :: 1000
END_BIT :: 0x80000000

SPECIAL := [?]u32{0, 0x80000000, 0x7f800000, 0xff800000, 0x7fffffff, 0xffffffff, 0x7f7fffff, 0xff7fffff, 1, 0x3f800000, 0xbf800000, 0x00800000, 0x007fffff,
	0x80800000, 0x807fffff, 0x7f800001, 0xff800001}

@(private = "file")
rnd :: proc() -> u32 {
	switch rand.uint32() % 3 {
	case 0: return SPECIAL[rand.uint32() % len(SPECIAL)]
	case 1: return transmute(u32)(rand.float32_range(-4, 4))
	}
	return rand.uint32()
}

// A random VU state to start from, with I and D clear in status, so the
// merge counts the program's.
@(private = "file")
random_state :: proc(init: ^vu.Vu, mem: []u32) {
	init.vf[0].f = {0, 0, 0, 1}
	for r in 1 ..< 32 {for l in 0 ..< 4 {init.vf[r].u[l] = rnd()}}
	for l in 0 ..< 4 {init.acc.u[l] = rnd()}
	init.vi[0] = 0
	for r in 1 ..< 16 {init.vi[r] = u16(rand.uint32())}
	init.vi[2] = 0xffff
	init.i = transmute(f32)rnd()
	init.q = transmute(f32)rnd()
	init.q_next, init.q_wait = transmute(f32)rnd(), 0 // as a microprogram starts: no Q pending
	init.q_flags, init.q_due = rand.uint32() & 0x30, 0 // a stale DIV's bits, none due
	init.p_next, init.p_wait = transmute(f32)rnd(), 0 // nor P
	init.vih = {} // nor a pair run before it (the branch VI delay's history)
	init.p = transmute(f32)rnd()
	init.mac = rand.uint32() & 0xffff
	init.clip = rand.uint32() & 0xffffff
	init.status = rand.uint32() & 0xfcf
	// As a microprogram starts: every older flag the newest.
	init.old_mac, init.old_status, init.old_clip = init.mac, init.status, init.clip
	for &w in mem {w = rnd()}
}

// At the end (pc with END_BIT), a pending Q and P land, as vu0_exec and
// vu1_exec drain them after the run.
@(private = "file")
drain :: proc(v: ^vu.Vu, pc: u32) {
	if pc & END_BIT != 0 {vu.vu_drain(v)}
}

// Whether got and want hold the same registers, but for the pc.
@(private = "file")
same_regs :: proc(got, want: ^vu.Vu, status: bool) -> bool {
	same := got.vi == want.vi && got.acc.u == want.acc.u
	for r in 0 ..< 32 {same &&= got.vf[r].u == want.vf[r].u}
	same &&= transmute(u32)got.q == transmute(u32)want.q && transmute(u32)got.p == transmute(u32)want.p
	same &&= transmute(u32)got.q_next == transmute(u32)want.q_next && got.q_wait == want.q_wait
	same &&= transmute(u32)got.p_next == transmute(u32)want.p_next && got.p_wait == want.p_wait
	same &&= transmute(u32)got.i == transmute(u32)want.i && got.r == want.r && got.clip == want.clip && got.mac == want.mac
	same &&= got.q_flags == want.q_flags && got.q_due == want.q_due
	return same && (!status || got.status == want.status)
}

main :: proc() {
	progs := vu_programs.programs()
	arch := native.Arch(core.NATIVE_ARCH)
	a := native.make_asm(arch, r5900.native_ram())
	vus := make([]native.Blob_Span, len(progs))
	slow_fails := 0
	for p, k in progs {
		ranges := make([]native.Blob_Range, 1)
		ranges[0] = {0, p.words}
		slow: map[string]int
		reads := vu_programs.status_reads(p.words)
		vus[k] = {p.unit == .VU0 ? .Vu0 : .Vu1, 0, u32(rvu.native_program(&a, p.words, nil, p.entries, p.unit, reads > 0, &slow)), ranges}
		if slow["pair"] != reads {
			fmt.eprintfln("FAIL vu_native: program %d leaves %d status reads of %d to the interpreter", k, slow["pair"], reads)
			slow_fails += 1
		}
		for key, n in slow {
			if key == "pair" && n == reads {continue}
			fmt.eprintfln("FAIL vu_native: program %d calls the interpreter for %s (%d)", k, key, n)
			slow_fails += 1
		}
		free_all(context.temp_allocator)
	}
	code, err := core.native_load(native.make_blob(&a, nil, {}, vus), ps2.native_imports())
	if err != "" {
		fmt.eprintln("FAIL vu_native: native_load:", err)
		os.exit(1)
	}
	if len(code.spans) != len(progs) {
		fmt.eprintfln("FAIL vu_native: %d programs loaded, want %d", len(code.spans), len(progs))
		os.exit(1)
	}

	rand.reset(SEED)
	vu.vu_init()
	cases, fails, flagged, status_set, vu1_set := 0, 0, 0, 0, 0
	for p, k in progs {
		run := cast(proc())rawptr(code.base + uintptr(code.spans[k].off))
		vu0 := p.unit == .VU0
		status := vu0 || vu_programs.status_reads(p.words) > 0
		v := vu0 ? &vu.vu0 : &vu.vu1
		nr := &vu.native_run[p.unit == .VU0 ? 0 : 1]
		mem := ([^]u32)(raw_data(v.mem))[:len(v.mem) / 4]
		mem_init := make([]u32, len(mem))
		mem_want := make([]u32, len(mem))
		defer delete(mem_init)
		defer delete(mem_want)
		for &b in v.micro {b = 0}
		copy(([^]u32)(&v.micro[0])[:len(p.words)], p.words)
		for pc in p.pcs {
			cases += 1
			for _ in 0 ..< TRIALS {
				init := v^
				random_state(&init, mem_init)
				// A VU0 program reaches VU1's registers through its window.
				vu1_init := vu0 ? vu_programs.vu1_random(rnd) : vu.vu1

				if vu0 {vu.vu1 = vu1_init}
				v^ = init
				copy(mem, mem_init)
				if vu0 {vu.vu0_call_micro(pc)} else {vu.vu1_start(pc)}
				want := v^
				vu1_want := vu.vu1
				copy(mem_want, mem)

				if vu0 {vu.vu1 = vu1_init}
				v^ = init
				copy(mem, mem_init)
				nr.pc, nr.budget = i32(pc), BUDGET
				run()
				drain(v, u32(nr.pc))
				got := v^
				got_pc := u32(nr.pc)

				if want.mac != init.mac {flagged += 1}
				if vu0 && want.status & 0x30 != 0 {status_set += 1}
				if !vu0 && status && want.status & 0x30 != 0 {vu1_set += 1}
				same := got_pc == want.tpc | END_BIT && same_regs(&got, &want, status) && slice.equal(mem, mem_want)
				same &&= !vu0 || vu_programs.vu1_same(&vu.vu1, &vu1_want)
				if !same {
					fails += 1
					if fails < 10 {
						r := 0 // the first VF register that differs, else vf31
						for r < 31 && got.vf[r].u == want.vf[r].u {r += 1}
						fmt.eprintfln("FAIL vu_native program %d (vu%d, from %04x): got pc %08x mac %04x status %04x clip %06x vi1 %04x vf%d %08x, want pc %08x mac %04x status %04x clip %06x vi1 %04x vf%d %08x; same Q %v, P %v, I %v, R %v, memory %v",
							k, vu0 ? 0 : 1, pc, got_pc, got.mac, got.status, got.clip, got.vi[1], r, got.vf[r].u,
							want.tpc | END_BIT, want.mac, want.status, want.clip, want.vi[1], r, want.vf[r].u,
							transmute(u32)got.q == transmute(u32)want.q, transmute(u32)got.p == transmute(u32)want.p,
							transmute(u32)got.i == transmute(u32)want.i, got.r == want.r, slice.equal(mem, mem_want))
					}
					break
				}
			}
		}
		// A pair the clamp elision left unlabelled: the run leaves at once,
		// with nothing changed.
		for pc in p.leaves {
			cases += 1
			init := v^
			random_state(&init, mem_init)
			v^ = init
			copy(mem, mem_init)
			nr.pc, nr.budget = i32(pc), BUDGET
			run()
			if u32(nr.pc) != pc || !same_regs(v, &init, status) || !slice.equal(mem, mem_init) {
				fails += 1
				fmt.eprintfln("FAIL vu_native program %d (vu%d, from %04x): got pc %08x, want a leave at once", k, vu0 ? 0 : 1, pc, u32(nr.pc))
			}
		}
	}

	// A VU1 program with no status read, registered alone, so compiled VU1
	// code does not compute status: its outside readers are compat rows.
	stale := -1
	for p, k in progs {
		if p.unit == .VU1 && vu_programs.status_reads(p.words) == 0 {stale = k; break}
	}
	if stale < 0 {
		fmt.eprintln("FAIL vu_native: no VU1 program without a status read")
		fails += 1
	} else {
		vu.vu_register_native(1, {{0, progs[stale].words}}, cast(vu.Vu_Native)rawptr(code.base + uintptr(code.spans[stale].off)))
		if !vu_programs.stale_status(progs[stale].words, progs[stale].pcs[0]) {fails += 1}
	}

	// The runtime's dispatch: the same trials, the micro generation moved
	// for each program's micro memory.
	for p, k in progs {
		if k == stale {continue} // registered above
		vu.vu_register_native(p.unit == .VU0 ? 0 : 1, {{0, p.words}}, cast(vu.Vu_Native)rawptr(code.base + uintptr(code.spans[k].off)))
	}
	rand.reset(SEED)
	dispatch_fails := 0
	for p, k in progs {
		run := cast(proc())rawptr(code.base + uintptr(code.spans[k].off))
		vu0 := p.unit == .VU0
		status := vu0 || vu_programs.status_reads(p.words) > 0
		v := vu0 ? &vu.vu0 : &vu.vu1
		nr := &vu.native_run[vu0 ? 0 : 1]
		mem := ([^]u32)(raw_data(v.mem))[:len(v.mem) / 4]
		mem_init := make([]u32, len(mem))
		mem_want := make([]u32, len(mem))
		defer delete(mem_init)
		defer delete(mem_want)
		for &b in v.micro {b = 0}
		copy(([^]u32)(&v.micro[0])[:len(p.words)], p.words)
		if vu0 {vu.vu0_micro_touch()} else {vu.vu1_micro_touch()}
		for pc in p.pcs {
			for _ in 0 ..< TRIALS {
				init := v^
				random_state(&init, mem_init)
				vu1_init := vu0 ? vu_programs.vu1_random(rnd) : vu.vu1

				if vu0 {vu.vu1 = vu1_init}
				v^ = init
				copy(mem, mem_init)
				nr.pc, nr.budget = i32(pc), BUDGET
				run()
				drain(v, u32(nr.pc))
				want := v^
				want_pc := u32(nr.pc) &~ END_BIT
				vu1_want := vu.vu1
				copy(mem_want, mem)

				if vu0 {vu.vu1 = vu1_init}
				v^ = init
				copy(mem, mem_init)
				if vu0 {vu.vu0_call_micro(pc)} else {vu.vu1_start(pc)}
				got := v^
				if got.tpc != want_pc || !same_regs(&got, &want, status) || !slice.equal(mem, mem_want) || (vu0 && !vu_programs.vu1_same(&vu.vu1, &vu1_want)) {
					dispatch_fails += 1
					if dispatch_fails < 10 {
						fmt.eprintfln("FAIL vu_native dispatch program %d (vu%d, from %04x): got pc %04x, want %04x; same registers %v, memory %v",
							k, vu0 ? 0 : 1, pc, got.tpc, want_pc, same_regs(&got, &want, status), slice.equal(mem, mem_want))
					}
					break
				}
			}
		}
	}
	// A write into a registered program's range, which moves the micro
	// generation as every write path does, demotes it: the next call
	// interprets. The probe is run_pc, which only native code writes. The
	// write turns an upper NOP into one with dest bits, still a NOP.
	probed := false
	probe: for p in progs {
		for w, j in p.words {
			if j % 2 == 0 || w != vu_programs.NOP_U {continue}
			vu0 := p.unit == .VU0
			v := vu0 ? &vu.vu0 : &vu.vu1
			nr := &vu.native_run[vu0 ? 0 : 1]
			micro := ([^]u32)(&v.micro[0])[:len(v.micro) / 4]
			call := proc(vu0: bool, nr: ^vu.Native_Run, pc: u32) -> bool {
				if vu0 {vu.vu0_micro_touch()} else {vu.vu1_micro_touch()}
				nr.pc = -1
				if vu0 {vu.vu0_call_micro(pc)} else {vu.vu1_start(pc)}
				return nr.pc != -1
			}
			for &m in micro {m = 0}
			copy(micro, p.words)
			if !call(vu0, nr, p.pcs[0]) {
				fmt.eprintln("FAIL vu_native: the probe's program does not run native")
				dispatch_fails += 1
			}
			micro[j] = vu_programs.NOP_U | 15 << 21
			if call(vu0, nr, p.pcs[0]) {
				fmt.eprintfln("FAIL vu_native: program still runs native after a write at %04x", 4 * j)
				dispatch_fails += 1
			}
			probed = true
			break probe
		}
	}
	if !probed {
		fmt.eprintln("FAIL vu_native: no program to probe")
		dispatch_fails += 1
	}
	dispatch_fails += test_miss_capture(progs[:], arch)
	fmt.printfln("vu_native %v: %d cases x %d trials, %d failing, %d failing dispatched, MAC changed in %d, VU0 I or D set in %d, VU1 in %d", arch, cases, TRIALS, fails, dispatch_fails, flagged, status_set, vu1_set)
	// A VU0 case whose divisors never set I or D would not test the merge.
	if status_set < TRIALS * 3 {fmt.eprintfln("FAIL vu_native: VU0 I or D set in only %d trials", status_set); os.exit(1)}
	if vu1_set < TRIALS * 3 {fmt.eprintfln("FAIL vu_native: VU1 I or D set in only %d trials", vu1_set); os.exit(1)}
	if fails > 0 || slow_fails > 0 || dispatch_fails > 0 {os.exit(1)}
}

// A miss capture (VU_CAPTURE=miss, ps2/vu/capture.odin) of VU1 into a file
// of its own: a start where a registered program holds records nothing;
// one where its micro memory differs records the image and the start, once;
// a reopen (the next run) appends nothing and cuts off a last record cut
// short; and past CAPTURE_IMAGES images a start records no new image. Into
// a second file: a compiled program that leaves to a pc outside it records
// that pc, and so does one that leaves at once from a pair it has no label
// for (a clamp elision leave). The failures.
@(private = "file")
test_miss_capture :: proc(progs: []vu_programs.Prog, arch: native.Arch) -> (fails: int) {
	fail :: proc(fails: ^int, msg: string) {
		fmt.eprintln("FAIL vu_native capture:", msg)
		fails^ += 1
	}
	IMAGE :: 9 + 16 * 1024
	ENTRY :: 13
	// The file's length and its images; -1 for a record that is not whole.
	parse :: proc(path: string) -> (n: int, images: int) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {return -1, -1}
		for pos := 0; pos < len(data); {
			switch data[pos] {
			case 'I': pos += IMAGE; images += 1
			case 'E': pos += ENTRY
			case: return -1, -1
			}
			if pos > len(data) {return -1, -1}
		}
		return len(data), images
	}
	prog: ^vu_programs.Prog
	nop := -1
	find: for &p in progs {
		if p.unit != .VU1 {continue}
		for w, j in p.words {
			if j % 2 == 1 && w == vu_programs.NOP_U {prog, nop = &p, j; break find}
		}
	}
	if prog == nil {
		fail(&fails, "no VU1 program with an upper NOP")
		return
	}
	dir, err := os.make_directory_temp("", "ps_vu_capture_*", context.temp_allocator)
	if err != nil {
		fail(&fails, fmt.tprint("no temp directory:", err))
		return
	}
	path := fmt.tprintf("%s/vu1.cap", dir)
	_ = os.set_env(core.env_name("VU1_CAPTURE"), path)
	_ = os.set_env(core.env_name("VU_CAPTURE"), "miss")
	defer {
		os.unset_env(core.env_name("VU1_CAPTURE"))
		os.unset_env(core.env_name("VU_CAPTURE"))
		vu.vu_capture_reopen()
		_ = os.remove_all(dir)
	}
	micro := ([^]u32)(&vu.vu1.micro[0])[:len(vu.vu1.micro) / 4]
	// Load the program, with its upper NOP given dest bits (still a NOP,
	// but no registered program holds it) unless dest is 0, and the last
	// word of micro memory, outside every program, set to tag.
	start :: proc(micro: []u32, prog: ^vu_programs.Prog, nop: int, dest, tag: u32) {
		for &m in micro {m = 0}
		copy(micro, prog.words)
		micro[nop] = vu_programs.NOP_U | dest << 21
		micro[len(micro) - 1] = tag
		vu.vu1_micro_touch()
		vu.vu1_start(prog.pcs[0])
	}
	vu.vu_capture_reopen()
	start(micro, prog, nop, 0, 0)
	// The file is made at the first record, so none exists yet.
	if os.exists(path) {fail(&fails, "a start a program runs made a capture file")}
	start(micro, prog, nop, 15, 0)
	n, images := parse(path)
	if n < IMAGE + ENTRY || images != 1 || (n - IMAGE) % ENTRY != 0 {fail(&fails, fmt.tprintf("a start no program runs left %d bytes, %d images", n, images))}
	start(micro, prog, nop, 15, 0)
	if again, _ := parse(path); again != n {fail(&fails, fmt.tprintf("the same start again grew the file from %d to %d bytes", n, again))}
	vu.vu_capture_reopen()
	start(micro, prog, nop, 15, 0)
	if again, _ := parse(path); again != n {fail(&fails, fmt.tprintf("a second run grew the file from %d to %d bytes", n, again))}
	// A last record cut short, then a reopen and a new image: the cut is gone.
	if f, e := os.open(path, {.Write, .Append}); e == nil {
		os.write(f, []u8{'E', 1, 2, 3, 4})
		_ = os.close(f)
	}
	vu.vu_capture_reopen()
	start(micro, prog, nop, 14, 0)
	grown, more := parse(path)
	if grown < n + IMAGE + ENTRY || more != 2 {fail(&fails, fmt.tprintf("after a cut record: %d bytes, %d images, want whole records past %d and 2 images", grown, more, n))}
	// Images up to the cap, then one more, which runs but is not recorded.
	for tag in 1 ..= u32(vu.CAPTURE_IMAGES - 2) {start(micro, prog, nop, 15, tag)}
	if _, full := parse(path); full != vu.CAPTURE_IMAGES {fail(&fails, fmt.tprintf("%d images, want %d", full, vu.CAPTURE_IMAGES))}
	at_cap, _ := parse(path)
	start(micro, prog, nop, 15, max(u32))
	if past, _ := parse(path); past != at_cap {fail(&fails, fmt.tprintf("past the cap the file grew from %d to %d bytes", at_cap, past))}

	// The pcs of the file's entries, in order.
	entries :: proc(path: string) -> (pcs: [dynamic]u32) {
		pcs.allocator = context.temp_allocator
		data, _ := os.read_entire_file(path, context.temp_allocator)
		for pos := 0; pos < len(data); {
			if data[pos] == 'E' && pos + ENTRY <= len(data) {append(&pcs, u32((^u32le)(&data[pos + 9])^))}
			pos += data[pos] == 'I' ? IMAGE : ENTRY
		}
		return
	}
	path = fmt.tprintf("%s/vu1-leave.cap", dir)
	_ = os.set_env(core.env_name("VU1_CAPTURE"), path)
	vu.vu_capture_reopen()
	// vi1 = TARGET / 8, then JR vi1 to a pair outside the program, which
	// ends there; compiled with its start as its only entry.
	TARGET :: 0x100
	words := []u32 {
		vu_programs.lower_op(vu_programs.IADDIU, 0, 1, 0, TARGET / 8), vu_programs.NOP_U,
		vu_programs.lower_op(vu_programs.JR, 0, 0, 1, 0), vu_programs.NOP_U,
		vu_programs.NOP_L, vu_programs.NOP_U,
	}
	a := native.make_asm(arch, r5900.native_ram())
	off := u32(rvu.native_program(&a, words, nil, []u32{0}, .VU1, false))
	code, err2 := core.native_load(native.make_blob(&a, nil, {}, []native.Blob_Span{{.Vu1, 0, off, []native.Blob_Range{{0, words}}}}), ps2.native_imports())
	if err2 != "" {
		fail(&fails, fmt.tprint("native_load:", err2))
		return
	}
	vu.vu_register_native(1, {{0, words}}, cast(vu.Vu_Native)rawptr(code.base + uintptr(code.spans[0].off)))
	for &m in micro {m = 0}
	copy(micro, words)
	micro[TARGET / 4], micro[TARGET / 4 + 1] = vu_programs.NOP_L, vu_programs.NOP_U | vu_programs.E_BIT
	micro[TARGET / 4 + 2], micro[TARGET / 4 + 3] = vu_programs.NOP_L, vu_programs.NOP_U
	vu.vu1_micro_touch()
	vu.vu1_start(0)
	if pcs := entries(path); len(pcs) != 1 || pcs[0] != TARGET {fail(&fails, fmt.tprintf("a leave to %04x outside the program recorded %v", TARGET, pcs[:]))}
	// A clamp elision leave: the program runs there, but leaves at once.
	elided := false
	for &p in progs {
		if p.unit != .VU1 || len(p.leaves) == 0 {continue}
		for &m in micro {m = 0}
		copy(micro, p.words)
		vu.vu1_micro_touch()
		vu.vu1_start(p.leaves[0])
		pcs := entries(path)
		if len(pcs) != 2 || pcs[1] != p.leaves[0] {fail(&fails, fmt.tprintf("a leave at once from %04x recorded %v", p.leaves[0], pcs[:]))}
		elided = true
		break
	}
	if !elided && rvu.VU_CLAMP_ELIDE {fail(&fails, "no VU1 program with a leave")}
	return
}
