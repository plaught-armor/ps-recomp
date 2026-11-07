// Learned PS1 functions (psx/cpu/learned.odin, psx/native/learned.odin,
// recomp/r3000/learned.odin): runs compiled to a blob, loaded
// and run in place of the interpreter while RAM holds their words.
//
//   - Which records are compiled (core.learn_compilable): an open run is;
//     a run marked as storing into its code, or with stores that could not
//     be checked, is not, nor any other record of the same code; nor a
//     large one, nor a duplicate, nor another processor's.
//   - A blob that cannot be loaded (no file, not a blob, one with functions)
//     registers nothing, and calls interpret.
//   - A loop, compiled, leaves the registers the interpreter does, and
//     running it is not reported as interpreting.
//   - Code whose first words match a learned function's and whose body
//     does not interprets; a second function for the same entry, compiled
//     from the words RAM holds, runs native.
//   - A CPU store into a learned function's code interprets it, and the
//     word stored back runs it native again; so does RAM put back behind
//     the guard with learned_epoch bumped, as checkpoint_restore does.
//   - Two functions registered for the same entry, start and words: the
//     first runs (a port's recompiled learned functions over the player's
//     blob), and the second is dropped.
//   - The recompiler's learned option (r3000.learned_read, write_learned):
//     a LEARN file's compilable PS1 runs become rows of lrn_NN/funcs.odin
//     that learned.odin registers; with none, learned.odin registers none
//     and no package is left behind.
//   - A wasm32 blob leaves to the interpreter a run that may switch
//     threads: one at an interpreted entry or inside an interpreted
//     function, one that calls a run that switches (to a fixed point), and
//     one that calls an entry the Switches file names (core.known_switches,
//     which keeps each entry once). A syscall or A/B table call switches
//     unless its block proves a0 or t1 another function number.
package main

import "core:fmt"
import "core:os"
import "core:hash/xxhash"
import "core:path/filepath"
import "core:strings"
import "ps:core"
import cpu "ps:psx/cpu"
import psx_native "ps:psx/native"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL psx_learned: %s (line %d)", what, loc.line)
		failed += 1
	}
}

// v0 = a0 * a1 by a loop, a1 > 0.
@(private = "file")
LOOP :: 0x80010000
@(rodata, private = "file")
CODE_LOOP := [?]u32 {
	0x24020000, // addiu v0, zero, 0
	0x00441021, // addu v0, v0, a0
	0x24a5ffff, // addiu a1, a1, -1
	0x14a0fffd, // bne a1, zero, -3
	0x00000000,
	0x03e00008, // jr ra
	0x00000000,
}

// v1 = ((a0 + 7) << 1 ^ a1) + 1; in RAM, the same first four words and
// another body: v1 + 2 after.
@(private = "file")
BODY :: 0x80011000
@(rodata, private = "file")
CODE_BODY := [?]u32 {
	0x24820007, // addiu v0, a0, 7
	0x00021040, // sll v0, v0, 1
	0x00451026, // xor v0, v0, a1
	0x24430001, // addiu v1, v0, 1
	0x03e00008, // jr ra
	0x00000000,
}
@(rodata, private = "file")
RAM_BODY := [?]u32{0x24820007, 0x00021040, 0x00451026, 0x24430001, 0x24630002, 0x03e00008, 0x00000000}

// Where the calls return to.
@(private = "file")
RA :: 0x80000ff0

@(private = "file")
put :: proc(addr: u32, code: []u32) {
	for w, k in code {
		(^u32le)(&cpu.ram[(addr & 0x1fffff) + u32(k) * 4])^ = u32le(w)
	}
}

@(private = "file")
Regs :: struct {
	r:      [32]u32,
	hi, lo: u32,
}

// Call addr with a0 and a1; the registers after, and whether a learned
// function ran it.
@(private = "file")
run :: proc(addr, a0, a1: u32) -> (Regs, bool) {
	cpu.state.r = {}
	cpu.state.hi, cpu.state.lo = 0, 0
	cpu.state.r[4], cpu.state.r[5], cpu.state.r[29], cpu.state.r[31] = a0, a1, 0x801ff000, RA
	hits := cpu.learned_hits
	cpu.call(addr)
	return {cpu.state.r, cpu.state.hi, cpu.state.lo}, cpu.learned_hits != hits
}

@(private = "file")
rec :: proc(flags: core.Learn_Flags, entry: u32, words: []u32, hash: u64, c := core.Learn_Cpu.Psx) -> core.Learn_Record {
	return {cpu = c, flags = flags, entry = entry, lo = entry, hash = hash, words = words}
}

@(private = "file")
test_compilable :: proc() {
	loop, body := CODE_LOOP, CODE_BODY
	recs := [?]core.Learn_Record {
		rec({.Open}, LOOP, loop[:], 1),
		rec({}, LOOP, loop[:], 1), // the same code, returned
		rec({}, BODY, body[:], 2),
		rec({.Smc}, BODY, body[:], 2),
		rec({.Smc_Unknown}, 0x80012000, body[:], 3),
		rec({.Large}, 0x80013000, nil, 4),
		rec({}, 0x80014000, body[:], 5, .Ee),
	}
	out, large, smc := core.learn_compilable(recs[:], .Psx, context.temp_allocator)
	check(len(out) == 1 && out[0].entry == LOOP && out[0].flags == {.Open}, fmt.tprintf("compiled %v, want the open loop only", out[:]))
	check(large == 1, fmt.tprintf("large %d, want 1", large))
	check(smc == 3, fmt.tprintf("stored into %d, want 3", smc))
}

@(private = "file")
blob :: proc(runs: []r3000.Learned) -> []u8 {
	return r3000.learned_blob(runs, native.Arch(core.NATIVE_ARCH))
}

@(private = "file")
write :: proc(dir, name: string, data: []u8) -> string {
	path, _ := filepath.join({dir, name}, context.allocator)
	check(os.write_entire_file(path, data) == nil, fmt.tprintf("write %s", path))
	return path
}

@(private = "file")
same :: proc(a, b: Regs) -> bool {
	return a.r == b.r && a.hi == b.hi && a.lo == b.lo
}

main :: proc() {
	cpu.next_event = max(u64)
	// No recompiled functions, as psx.run registers for a disc nobody has
	// converted, and the interpreter package psx sets (psx/hooks.odin),
	// which this test does not import: it would link SDL.
	cpu.register_funcs(nil)
	cpu.interp_run = cpu.interp_loop
	test_compilable()

	tmp, err := os.make_directory_temp("", "ps_learned_test_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL psx_learned: no temp directory:", err)
		os.exit(1)
	}
	loop, body, ram_body := CODE_LOOP, CODE_BODY, RAM_BODY
	put(LOOP, loop[:])
	put(BODY, ram_body[:])
	want_loop, native_ran := run(LOOP, 3, 5)
	check(want_loop.r[2] == 15 && !native_ran, "interpreted loop")
	want_body, _ := run(BODY, 4, 9)
	check(want_body.r[3] == ((4 + 7) << 1 ~ 9) + 3, "interpreted body")

	// Blobs that cannot be loaded.
	missing, _ := filepath.join({tmp, "none.bin"}, context.allocator)
	check(!psx_native.load_learned(missing), "no file loaded")
	check(!psx_native.load_learned(write(tmp, "junk.bin", transmute([]u8)string("not a blob"))), "junk loaded")
	{
		a := native.make_asm(native.Arch(core.NATIVE_ARCH), r3000.native_ram(), r3000.NATIVE_CACHED[:])
		f := []native.Blob_Func{{LOOP, r3000.native_func(&a, r3000_func(loop[:]), nil, r3000.CYCLES_PER_INSN)}}
		check(!psx_native.load_learned(write(tmp, "funcs.bin", native.make_blob(&a, f, nil))), "blob of functions loaded")
	}
	check(!cpu.learned_loaded, "a failed load registered functions")
	got: Regs
	got, native_ran = run(LOOP, 3, 5)
	check(same(got, want_loop) && !native_ran, "loop after failed loads")

	// The loop and the body as compiled, whose words RAM does not hold.
	check(psx_native.load_learned(write(tmp, "a.bin", blob({{LOOP, LOOP, loop[:]}, {BODY, BODY, body[:]}}))), "load")
	// The interpreted runs above reported the loop; forget that.
	delete_key(&cpu.dispatch.reported, LOOP)
	got, native_ran = run(LOOP, 3, 5)
	check(native_ran, "learned loop not run")
	check(!cpu.dispatch.reported[LOOP], "learned loop reported as interpreting")
	check(same(got, want_loop), fmt.tprintf("learned loop left %v, want %v", got, want_loop))
	got, native_ran = run(BODY, 4, 9)
	check(same(got, want_body) && !native_ran, "other body ran native")
	// Again: the compare is not redone, and still interprets.
	got, native_ran = run(BODY, 4, 9)
	check(same(got, want_body) && !native_ran, "other body ran native, called again")

	// A second function for the body's entry, from the words RAM holds.
	check(psx_native.load_learned(write(tmp, "b.bin", blob({{BODY, BODY, ram_body[:]}}))), "load the body as in RAM")
	got, native_ran = run(BODY, 4, 9)
	check(same(got, want_body) && native_ran, "body as in RAM not run native")

	// A store into the loop's code: v0 starts at 1, interpreted.
	cpu.sw(LOOP, 0x24020001)
	got, native_ran = run(LOOP, 3, 5)
	check(got.r[2] == 16 && !native_ran, "changed loop ran native")
	cpu.sw(LOOP, loop[0])
	got, native_ran = run(LOOP, 3, 5)
	check(same(got, want_loop) && native_ran, "loop with its word back not run native")

	// RAM put back behind the guard, with the epoch bumped.
	(^u32le)(&cpu.ram[LOOP & 0x1fffff])^ = 0x24020001
	cpu.learned_epoch += 1
	got, native_ran = run(LOOP, 3, 5)
	check(got.r[2] == 16 && !native_ran, "loop put back changed ran native")
	(^u32le)(&cpu.ram[LOOP & 0x1fffff])^ = u32le(loop[0])
	cpu.learned_epoch += 1
	got, native_ran = run(LOOP, 3, 5)
	check(same(got, want_loop) && native_ran, "loop put back whole not run native")

	test_first_wins()
	test_recomp(tmp)
	test_switches(tmp)

	if os.remove_all(tmp) != nil {
		check(false, fmt.tprintf("cannot remove %s", tmp))
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok psx_learned: open runs compiled and stored-into code not; failed loads register nothing; learned code runs native only while RAM holds its words, and leaves what the interpreter does; the first function for the same code wins; the recompiler writes the compilable runs as learned functions; wasm32 leaves runs that may switch threads to the interpreter")
}

// words at LOOP as one recompiled function.
@(private = "file")
r3000_func :: proc(words: []u32) -> ^mips.Func {
	f := mips.func_make(LOOP, LOOP + 4 * u32(len(words)))
	mips.discover(r3000.RULES, {base = LOOP, data = ([^]u8)(raw_data(words))[:4 * len(words)]}, f, nil)
	return f
}

@(private = "file")
first_ran, second_ran: int

// The first of two functions registered for the same code runs.
@(private = "file")
test_first_wins :: proc() {
	FIRST :: 0x80015000
	code := CODE_LOOP
	put(FIRST, code[:])
	cpu.register_learned(FIRST, FIRST, code[:], proc() {first_ran += 1})
	cpu.register_learned(FIRST, FIRST, code[:], proc() {second_ran += 1})
	check(len(cpu.learned[FIRST]) == 1, fmt.tprintf("%d functions for the same code, want 1", len(cpu.learned[FIRST])))
	_, ran := run(FIRST, 3, 5)
	check(ran && first_ran == 1 && second_ran == 0, fmt.tprintf("first ran %d, second %d; want 1, 0", first_ran, second_ran))
}

// A LEARN record of words at entry.
@(private = "file")
learn_bytes :: proc(b: ^[dynamic]u8, flags: core.Learn_Flags, entry: u32, words: []u32) {
	bytes := ([^]u8)(raw_data(words))[:4 * len(words)]
	h: [core.LEARN_HEADER]u8
	h[0], h[1], h[2] = core.LEARN_TAG, u8(core.Learn_Cpu.Psx), transmute(u8)flags
	(^u32le)(&h[4])^ = u32le(entry)
	(^u32le)(&h[8])^ = u32le(entry)
	(^u32le)(&h[12])^ = u32le(len(words))
	(^u64le)(&h[16])^ = u64le(xxhash.XXH3_64_default(bytes))
	append(b, ..h[:])
	append(b, ..bytes)
}

@(private = "file")
read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	check(err == nil, fmt.tprintf("read %s", path))
	return string(data)
}

@(private = "file")
test_recomp :: proc(tmp: string) {
	loop, body := CODE_LOOP, CODE_BODY
	file: [dynamic]u8
	learn_bytes(&file, {}, LOOP, loop[:])
	learn_bytes(&file, {}, LOOP, loop[:]) // the same run again
	learn_bytes(&file, {.Open}, BODY, body[:])
	learn_bytes(&file, {.Smc}, 0x80012000, body[:])
	runs := r3000.learned_read(write(tmp, "psx.bin", file[:]))
	check(len(runs) == 2 && runs[0].entry == LOOP && runs[1].entry == BODY, fmt.tprintf("runs %v, want the loop and the body", runs))

	out, _ := filepath.join({tmp, "rec"}, context.allocator)
	check(os.make_directory(out) == nil, "make rec")
	r3000.write_learned(out, "ps:psx", runs, 50000)
	reg, _ := filepath.join({out, "learned.odin"}, context.allocator)
	funcs, _ := filepath.join({out, "lrn_00", "funcs.odin"}, context.allocator)
	text := read_text(reg)
	check(strings.contains(text, "\tcpu.register_learned_funcs(lrn_00.FUNCS[:], lrn_00.WORDS[:])\n"), "learned.odin does not register lrn_00")
	text = read_text(funcs)
	check(strings.contains(text, "\t{0x80010000, 0x80010000, 0, 7, l_80010000_0},\n"), "no row for the loop")
	check(strings.contains(text, "\t{0x80011000, 0x80011000, 7, 6, l_80011000_1},\n"), "no row for the body")
	check(strings.contains(text, "cpu.jump_unknown(0x80010000, pc)"), "the loop does not jump out through jump_unknown")
	check(!strings.contains(text, "0x80012000"), "the stored-into run was written")

	// No runs: learned.odin registers none, and lrn_00 is removed.
	r3000.write_learned(out, "ps:psx", nil, 50000)
	text = read_text(reg)
	check(strings.contains(text, "register_learned :: proc() {\n}\n") && !strings.contains(text, "import"), "learned.odin with no runs")
	check(!os.exists(funcs), "lrn_00/funcs.odin left behind")
}

// The runs a wasm32 blob of runs leaves to the interpreter, given interp.
@(private = "file")
switch_skips :: proc(runs: []r3000.Learned, interp: []native.Blob_Interp) -> int {
	n := 0
	b := r3000.learned_blob(runs, .Wasm32, interp = interp, skipped = &n)
	delete(b)
	return n
}

@(private = "file")
test_switches :: proc(tmp: string) {
	JR_RA :: 0x03e00008
	ret := [?]u32{JR_RA, 0}
	plain := [?]r3000.Learned{{0x80020000, 0x80020000, ret[:]}}
	check(switch_skips(plain[:], nil) == 0, "plain run left to the interpreter")

	// H1: the run's entry is interpreted, or its words lie inside an
	// interpreted function (a loop head or the return point after a jal).
	at_entry := [?]native.Blob_Interp{{0x80020000, 0x80020000, 0x80020000}}
	check(switch_skips(plain[:], at_entry[:]) == 1, "run at an interpreted entry compiled")
	inside := [?]r3000.Learned{{0x80022010, 0x80022010, ret[:]}}
	holder := [?]native.Blob_Interp{{0x80022000, 0x80022000, 0x80022040}}
	check(switch_skips(inside[:], holder[:]) == 1, "run inside an interpreted function compiled")
	check(switch_skips(plain[:], holder[:]) == 0, "run outside the interpreted function left")

	// H2: A calls B, B switches (a syscall); A comes first, so leaving it
	// takes a second pass.
	a := [?]u32{0x0c009000, 0, JR_RA, 0} // jal 0x80024000
	b := [?]u32{0x0000000c, JR_RA, 0} // syscall
	chain := [?]r3000.Learned{{0x80023000, 0x80023000, a[:]}, {0x80024000, 0x80024000, b[:]}, plain[0]}
	check(switch_skips(chain[:], nil) == 2, "run calling a learned run that switches compiled")

	// M4: a function number proven in the block (the delay slot too) is
	// no switch unless it is one; one not proven is.
	Stub :: struct {
		words: []u32,
		skips: int,
		what:  string,
	}
	stubs := [?]Stub {
		{{0x24040001, 0x0000000c, JR_RA, 0}, 0, "EnterCriticalSection"},
		{{0x24040003, 0x0000000c, JR_RA, 0}, 1, "ChangeThreadSubFunction"},
		{{0x02002021, 0x0000000c, JR_RA, 0}, 1, "syscall with a0 moved"},
		{{0x240a00b0, 0x01400008, 0x2409000b}, 0, "B(0Bh)"},
		{{0x240a00b0, 0x01400008, 0x24090010}, 1, "B(10h) ChangeTh"},
		{{0x240a00b0, 0x01400008, 0x01204821}, 1, "B call with t1 moved"},
		{{0x240a00a0, 0x01400008, 0x24090044}, 0, "A(44h)"},
		{{0x240a00a0, 0x01400008, 0x24090043}, 1, "A(43h) Exec"},
		{{0x240a00a0, 0x01400008, 0x24090051}, 1, "A(51h) LoadExec"},
	}
	for st in stubs {
		run := [?]r3000.Learned{{0x80027000, 0x80027000, st.words}}
		check(switch_skips(run[:], nil) == st.skips, fmt.tprintf("%s: %d left, want %d", st.what, switch_skips(run[:], nil), st.skips))
	}

	// M3(ii): a fatal's entries, kept once, leave a run that calls one.
	dir, _ := filepath.join({tmp, "switches"}, context.temp_allocator)
	check(os.make_directory(dir) == nil, "make the switches directory")
	SWITCHED :: 0x80026000
	check(core.known_switches_add(dir, {SWITCHED, 0, SWITCHED}), "write the known switches")
	check(core.known_switches_add(dir, {SWITCHED}), "write the known switches again")
	known := core.known_switches(dir)
	check(len(known) == 1 && known[0] == SWITCHED, fmt.tprintf("known switches %x, want one %x", known, SWITCHED))
	c := [?]u32{0x0c009800, 0, JR_RA, 0} // jal SWITCHED
	caller := [?]r3000.Learned{{0x80025000, 0x80025000, c[:]}}
	check(switch_skips(caller[:], nil) == 0, "caller left with no known switches")
	healed := [?]native.Blob_Interp{{SWITCHED, SWITCHED, SWITCHED}}
	check(switch_skips(caller[:], healed[:]) == 1, "run calling a known switch compiled")
}
