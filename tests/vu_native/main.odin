// VU microprograms through the native backend (recomp/vu native_program)
// against the interpreter, run on every target in CI. The programs are
// tests/vu_micro's (tests/vu_programs), each assembled for the host as a
// function of its own and loaded with the runtime's imports. From the same
// random state, the native function and the interpreter must leave the same
// vf, vi, ACC, Q, P, I, R, CLIP, MAC, memory and stopping pc; on VU0 status
// too, as VU0 code computes it. Every native run must end the program, and
// no program may call the interpreter for an instruction. A second pass
// registers the functions as the runtime does (unless VUNATIVE=0) and runs the
// same trials through vu0_call_micro and vu1_start, which must leave what a
// direct call leaves; after a write into a program's micro memory, they
// must interpret it instead.
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

SPECIAL := [?]u32{0, 0x80000000, 0x7f800000, 0xff800000, 0x7fffffff, 0xffffffff, 0x7f7fffff, 0xff7fffff, 1, 0x3f800000, 0xbf800000, 0x00800000, 0x007fffff}

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
	init.p = transmute(f32)rnd()
	init.mac = rand.uint32() & 0xffff
	init.clip = rand.uint32() & 0xffffff
	init.status = rand.uint32() & 0xfcf
	for &w in mem {w = rnd()}
}

// Whether got and want hold the same registers, but for the pc.
@(private = "file")
same_regs :: proc(got, want: ^vu.Vu, vu0: bool) -> bool {
	same := got.vi == want.vi && got.acc.u == want.acc.u
	for r in 0 ..< 32 {same &&= got.vf[r].u == want.vf[r].u}
	same &&= transmute(u32)got.q == transmute(u32)want.q && transmute(u32)got.p == transmute(u32)want.p
	same &&= transmute(u32)got.i == transmute(u32)want.i && got.r == want.r && got.clip == want.clip && got.mac == want.mac
	return same && (!vu0 || got.status == want.status)
}

main :: proc() {
	progs := vu_programs.programs()
	arch := native.Arch(core.NATIVE_ARCH)
	a := native.make_asm(arch, r5900.native_ram())
	vus := make([]native.Blob_Vu, len(progs))
	slow_fails := 0
	for p, k in progs {
		ranges := make([]native.Blob_Range, 1)
		ranges[0] = {0, p.words}
		slow: map[string]int
		vus[k] = {u32(p.unit), u32(rvu.native_program(&a, p.words, nil, p.entries, p.unit, &slow)), ranges}
		for key, n in slow {
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
	if len(code.vus) != len(progs) {
		fmt.eprintfln("FAIL vu_native: %d programs loaded, want %d", len(code.vus), len(progs))
		os.exit(1)
	}

	rand.reset(SEED)
	vu.vu_init()
	cases, fails, flagged, status_set := 0, 0, 0, 0
	for p, k in progs {
		run := cast(proc())rawptr(code.base + uintptr(code.vus[k].off))
		vu0 := p.unit == .VU0
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

				v^ = init
				copy(mem, mem_init)
				if vu0 {vu.vu0_call_micro(pc)} else {vu.vu1_start(pc)}
				want := v^
				copy(mem_want, mem)

				v^ = init
				copy(mem, mem_init)
				nr.pc, nr.budget = i32(pc), BUDGET
				run()
				got := v^
				got_pc := u32(nr.pc)

				if want.mac != init.mac {flagged += 1}
				if vu0 && want.status & 0x30 != 0 {status_set += 1}
				same := got_pc == want.tpc | END_BIT && same_regs(&got, &want, vu0) && slice.equal(mem, mem_want)
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
	}

	// The runtime's dispatch: the same trials, the micro generation moved
	// for each program's micro memory.
	for p, k in progs {
		vu.vu_register_native(p.unit == .VU0 ? 0 : 1, {{0, p.words}}, cast(vu.Vu_Native)rawptr(code.base + uintptr(code.vus[k].off)))
	}
	rand.reset(SEED)
	dispatch_fails := 0
	for p, k in progs {
		run := cast(proc())rawptr(code.base + uintptr(code.vus[k].off))
		vu0 := p.unit == .VU0
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

				v^ = init
				copy(mem, mem_init)
				nr.pc, nr.budget = i32(pc), BUDGET
				run()
				want := v^
				want_pc := u32(nr.pc) &~ END_BIT
				copy(mem_want, mem)

				v^ = init
				copy(mem, mem_init)
				if vu0 {vu.vu0_call_micro(pc)} else {vu.vu1_start(pc)}
				got := v^
				if got.tpc != want_pc || !same_regs(&got, &want, vu0) || !slice.equal(mem, mem_want) {
					dispatch_fails += 1
					if dispatch_fails < 10 {
						fmt.eprintfln("FAIL vu_native dispatch program %d (vu%d, from %04x): got pc %04x, want %04x; same registers %v, memory %v",
							k, vu0 ? 0 : 1, pc, got.tpc, want_pc, same_regs(&got, &want, vu0), slice.equal(mem, mem_want))
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
	fmt.printfln("vu_native %v: %d cases x %d trials, %d failing, %d failing dispatched, MAC changed in %d, VU0 I or D set in %d", arch, cases, TRIALS, fails, dispatch_fails, flagged, status_set)
	// A VU0 case whose divisors never set I or D would not test the merge.
	if status_set < TRIALS * 3 {fmt.eprintfln("FAIL vu_native: VU0 I or D set in only %d trials", status_set); os.exit(1)}
	if fails > 0 || slow_fails > 0 || dispatch_fails > 0 {os.exit(1)}
}
