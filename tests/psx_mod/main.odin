// psx/cpu's mod hooks (mod.odin) on a hand-built dispatch table, one function
// for each way a hook is installed:
//
//   0x80010000  A, executable, recompiled, with a port hook (cpu.hook) the
//               mods wrap: befores of mods a then b, afters of b then a
//   0x80011000  D, executable, interpreted: b replaces it
//   0x80100100  B, overlay at 0x80100000, recompiled: after of b
//   0x80100200  C, the same overlay, interpreted: before of a, which calls
//               D, so D's chain runs inside C's before hook
//   0x80100300  an executable chain (before of b) and an overlay chain
//               (before of a) at one address: the overlay's while its id
//               is at the slot, else the executable's
//   0x80012000  E, executable, recompiled: a's before hook schedules an
//               event, raises an interrupt and clears SR
//   0x80013000  F, executable, interpreted guest code that stops the run
//               (a BIOS call that blocks, as ChangeTh does): before of a,
//               after of b. FLAT only
//   0x80014000  G, executable: b replaces it with interpreted guest code at
//               0x80190100 that stops the run; after of a. FLAT only
//   0x80015000  H, executable, recompiled: before of a, after of b, and b
//               replaces it with a function that calls its original
//               (mod_call_original) twice, and J between
//   0x80016000  J, executable, interpreted: a replaces it with a function
//               that calls its original
//   0x80017000  K, executable, interpreted guest code that stops the run:
//               b replaces it with interpreted guest code at 0x80190200
//               that calls its original; after of a. FLAT only
//   0x80018000  X, executable, recompiled: a before hook of b calls
//               mod_call_original (fatal)
//   0x80019000  T, executable, interpreted guest code that yields: b
//               replaces it with guest code at 0x80190300 that calls its
//               original twice; after of a
//   0x8001a000  U, as T, on a second thread: a replaces it with the same
//               code; after of b
//   0x80100400  R, the overlay, interpreted: a replaces it with a function
//               that loads another overlay at the slot, then calls its
//               original (fatal, naming the overlay)
//   0x8001d000  W, executable, recompiled: b replaces it with interpreted
//               guest code at 0x80190400 that calls its original; after of
//               a. FLAT only
//   0x8001e000  P, executable, interpreted guest code: a replaces it with
//               guest code at 0x80190500 that calls P on a0 - 1 while a0 is
//               above 0, then its original. FLAT only
//   0x8001e100  L, executable, interpreted guest code: a replaces it with
//               guest code at 0x80190600 that tail-calls its original (jr);
//               after of b
//   0x8001f000  Q, executable, recompiled: a replaces it with a function
//               that runs a program with Exec (A(43h)), then calls its
//               original
//
// Mod functions live at 0x80180000 (recompiled) and 0x80190000
// (interpreted). Checked: the order hooks run in; befores and afters on the
// mod stack, nested ones below the running hook's stack pointer, with
// next_event at max and every register (the cycle count too) put back after;
// afters see the arguments and the results; the replacement and the
// original in game time; an event a hook schedules or an interrupt it
// raises is handled only after it returns, at once, and cop0 is put back.
// mod_call_original runs the innermost running replacement's original,
// recompiled or interpreted, without its hooks; from a hook, a hook inside
// a replacement or no replacement it is fatal (a child process each). With
// the overlay's id or D's first word changed, calls run without hooks. Install
// errors leave nothing installed. Fatal too, the same on both builds (a
// child each): mod_call_original from inside an original (H's recompiled,
// J's interpreted), from guest code a replacement's host code calls back
// (call_callback), from a program Exec started (Q's), and for an overlay
// function whose overlay another replaced meanwhile (R's); under FLAT, from
// inside W's original and from a callback inside G's replacement, both on a
// flat run. Exec starts its program with no replacement and no hook
// running, and the replacement that made it gets its own original after.
// L's replacement tail-calls its original, plain from host code and under
// FLAT on a flat run. Under FLAT W's replacement, on the run, gets its
// recompiled original; P recursing 4 deep fills the run's continuations,
// so the call below runs nested, inside it its original, and the original
// of the one at the fourth too (call_guest); the outer three get theirs on
// the run. Under FLAT (-define:PS_FLAT=true), a guest
// call from a flat run to F or G stops inside the original or the
// replacement and goes on with the after hook when the run resumes, and so
// does one inside K's original, which K's replacement called. Through the
// BIOS's threads (ChangeTh), a replacement's original switches to a thread
// whose own replacement's original switches back: each mod_call_original
// runs its own thread's replacement's original, and each after hook runs in
// its thread, plain and under FLAT. With F's
// last CODE word changed, F stops and resumes without hooks; a call to A from
// host code while F's run is on runs A's chain nested, at once.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"
import bios "ps:psx/bios"
import cpu "ps:psx/cpu"
import io "ps:psx/io"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL psx_mod: %s (line %d)", what, loc.line)
		failed += 1
	}
}

EXE_A :: 0x80010000
EXE_D :: 0x80011000
EXE_E :: 0x80012000
FLAT_F :: 0x80013000
FLAT_G :: 0x80014000
EXE_H :: 0x80015000
EXE_J :: 0x80016000
FLAT_K :: 0x80017000
EXE_X :: 0x80018000
FLAT_W :: 0x8001d000
FLAT_P :: 0x8001e000
EXE_L :: 0x8001e100
EXE_Q :: 0x8001f000
OVL_R :: 0x80100400
// Q's program's header (Exec's).
HDR :: 0x80030000
THR_T :: 0x80019000
THR_U :: 0x8001a000
// The two threads' code: the main thread calls T, the second U.
THR_MAIN :: 0x8001b000
THR_B :: 0x8001c000
THR_B_SP :: 0x801e0000
CALLER :: 0x80020000
SLOT :: 0x80100000
ID :: 0x3c011234
OVL_B :: 0x80100100
OVL_C :: 0x80100200
BOTH :: 0x80100300
STACK :: 0x801f0000
GAME_SP :: 0x801ffe00

M_A_BEFORE :: 0x80180000
M_A_AFTER :: 0x80180010
M_B_BEFORE :: 0x80180020
M_B_AFTER :: 0x80180030
M_REPLACE :: 0x80180040
M_NEST :: 0x80180050
M_E_BEFORE :: 0x80180060
M_ORIG_H :: 0x80180070
M_ORIG_J :: 0x80180080
M_ORIG_HOOK :: 0x80180090
M_MOVE :: 0x801800a0
M_EXEC :: 0x801800b0
M_PC0 :: 0x801800c0
M_I_BEFORE :: 0x80190000
M_I_REPLACE :: 0x80190100
M_I_ORIG :: 0x80190200
M_I_THR :: 0x80190300
M_I_W :: 0x80190400
M_I_P :: 0x80190500
M_I_L :: 0x80190600
// Guest code a callback runs: it tail-calls mod_call_original (fatal).
M_I_CB :: 0x80190700

@(private = "file", rodata)
CODE := [4]u32{0x27bdffe8, 0xafbf0010, 0xafb00014, 0x00000000}

@(private = "file")
log: [dynamic]string

@(private = "file")
seen: struct {
	sp, ne: [dynamic]u64,
}

@(private = "file")
put :: proc(addr, w: u32) {
	(^u32le)(&cpu.ram[addr & 0x1fffff])^ = u32le(w)
}

@(private = "file")
put_code :: proc(addr: u32) {
	for w, k in CODE {put(addr + u32(k) * 4, w)}
}

@(private = "file")
r :: proc() -> ^[32]u32 {return &cpu.state.r}

// A before or after hook: logs what it sees, records its stack pointer and
// next_event, then clobbers what the thunk must put back.
@(private = "file")
hook_fn :: proc(tag: string) {
	append(&log, fmt.aprintf("%s a0=%x v0=%x", tag, r()[4], r()[2]))
	append(&seen.sp, u64(r()[29]))
	append(&seen.ne, cpu.next_event)
	r()[2], r()[3], r()[4], r()[16], r()[29], r()[31] = 0xbad, 0xbad, 0xdead, 0x5050, r()[29] - 64, 0
	cpu.state.cycles += 1000
}

// A function of the game: logs, returns a0 + n in v0, and takes cycles.
@(private = "file")
game_fn :: proc(tag: string, n: u32) {
	append(&log, fmt.aprintf("%s a0=%x", tag, r()[4]))
	r()[2] = r()[4] + n
	r()[8] = 0x77
	cpu.state.cycles += u64(n) * 10
}

@(private = "file")
call :: proc(addr, a0: u32) -> (v0: u32) {
	clear(&log)
	clear(&seen.sp)
	clear(&seen.ne)
	r()[2], r()[4], r()[16], r()[29], r()[31] = 0, a0, 0x1600, GAME_SP, 0x80001234
	cpu.call(addr)
	check(r()[16] == 0x1600 && r()[29] == GAME_SP && r()[31] == 0x80001234, fmt.tprintf("%08x: s0, sp, ra kept", addr))
	return r()[2]
}

@(private = "file")
logged :: proc() -> string {
	return strings.join(log[:], "; ", context.temp_allocator)
}

@(private = "file")
expect :: proc(want: string, loc := #caller_location) {
	got := logged()
	check(got == want, fmt.tprintf("\n  got  %s\n  want %s", got, want), loc)
}

@(private = "file")
key :: proc(addr: u32, slot: u32 = 0, id: u32 = 0) -> core.Mod_Key {
	return {slot = slot, id = id, addr = addr, sig = CODE}
}

@(private = "file")
schedule: bool

// J's replacement calls X too (a child's fatal case).
@(private = "file")
nest_x: bool

// Children's fatal cases: H's and J's originals, and W's, call
// mod_call_original (in_orig); J's replacement calls M_I_CB back (cb); Q's
// program calls it (exec_orig).
@(private = "file")
in_orig, cb, exec_orig: bool

// lui t2 and addiu t2 for MOD_ORIGINAL.
@(private = "file")
orig_hi :: proc() -> u32 {return 0x3c0a0000 | (cpu.MOD_ORIGINAL + 0x8000) >> 16}
@(private = "file")
orig_lo :: proc() -> u32 {return 0x254a0000 | cpu.MOD_ORIGINAL & 0xffff}

main :: proc() {
	cpu.interp_run = proc(start: u32) {
		switch start {
		case EXE_D:
			game_fn("D", 2)
		case OVL_B:
			game_fn("iB", 3)
		case OVL_C:
			game_fn("C", 4)
		case EXE_J:
			if in_orig {cpu.call(cpu.MOD_ORIGINAL)}
			game_fn("J", 3)
		case M_I_CB:
			cpu.call(cpu.MOD_ORIGINAL)
		case M_I_BEFORE:
			hook_fn("i<")
		case:
			append(&log, fmt.aprintf("interp %08x", start))
		}
	}
	put_code(EXE_A)
	put_code(EXE_D)
	put_code(EXE_E)
	put_code(FLAT_F)
	put_code(FLAT_G)
	put_code(EXE_H)
	put_code(EXE_J)
	put_code(FLAT_K)
	put_code(EXE_X)
	put_code(THR_T)
	put_code(THR_U)
	put_code(FLAT_W)
	put_code(FLAT_P)
	put_code(EXE_L)
	put_code(EXE_Q)
	put_code(OVL_R)
	// L's body after CODE: v0 = a0 + 1.
	put(EXE_L + 16, 0x24820001) // addiu v0, a0, 1
	put(EXE_L + 20, 0x03e00008) // jr ra
	put(EXE_L + 24, 0x27bd0018) // addiu sp, sp, 24
	// L's replacement: its original on a0 + 1, a tail call.
	put(M_I_L, 0x24840001) // addiu a0, a0, 1
	put(M_I_L + 4, orig_hi())
	put(M_I_L + 8, orig_lo())
	put(M_I_L + 12, 0x01400008) // jr t2
	put(M_I_L + 16, 0)
	put(M_I_CB, orig_hi())
	put(M_I_CB + 4, orig_lo())
	put(M_I_CB + 8, 0x01400008) // jr t2
	put(M_I_CB + 12, 0)
	put_code(OVL_B)
	put_code(OVL_C)
	put_code(BOTH)
	put(SLOT, ID)
	cpu.register_funcs(
		{
			{EXE_A, proc() {game_fn("A", 1)}},
			{M_A_BEFORE, proc() {hook_fn("a<")}},
			{M_A_AFTER, proc() {hook_fn("a>")}},
			{M_B_BEFORE, proc() {
					hook_fn("b<")
					if schedule {cpu.next_event = 5000}
				}},
			{M_B_AFTER, proc() {hook_fn("b>")}},
			{M_REPLACE, proc() {
					append(&log, fmt.aprintf("R a0=%x sp=%x", r()[4], r()[29]))
					r()[2] = 0x99
					cpu.state.cycles += 20
				}},
			{EXE_E, proc() {game_fn("E", 1)}},
			{M_E_BEFORE, proc() {
					append(&log, "e<")
					cpu.cop0.sr = 0
					io.schedule(.Dma, 0)
					io.irq_raise(.Dma)
					cpu.state.cycles += 1000
					// As recompiled code checks.
					if cpu.state.cycles >= cpu.next_event {io.run_events()}
				}},
			{M_NEST, proc() {
					hook_fn("N")
					r()[4] = 9
					cpu.call(EXE_D)
				}},
			{EXE_H, proc() {
					if in_orig {cpu.call(cpu.MOD_ORIGINAL)}
					game_fn("H", 1)
				}},
			{FLAT_W, proc() {
					if in_orig {cpu.call(cpu.MOD_ORIGINAL)}
					game_fn("W", 2)
				}},
			{EXE_Q, proc() {game_fn("Q", 4)}},
			{M_MOVE, proc() {
					put(SLOT, ID + 1)
					cpu.call(cpu.MOD_ORIGINAL)
				}},
			// Q's replacement: a program with Exec, then Q's original.
			{M_EXEC, proc() {
					append(&log, "RQ")
					a0 := r()[4]
					r()[4], r()[5], r()[6] = HDR, 0, 0
					bios.bios_a(0x43)
					append(&log, fmt.aprintf("exec v0=%x", r()[2]))
					r()[4] = a0
					cpu.call(cpu.MOD_ORIGINAL)
				}},
			{M_PC0, proc() {
					append(&log, fmt.aprintf("pc0 inner=%v depth=%d", cpu.mod_inner == nil, cpu.mod_depth))
					if exec_orig {cpu.call(cpu.MOD_ORIGINAL)}
				}},
			{EXE_X, proc() {game_fn("X", 1)}},
			// H's replacement: its original on a0 + 1, J (whose replacement
			// calls J's original), then H's original again, on its first
			// result.
			{M_ORIG_H, proc() {
					append(&log, fmt.aprintf("RH a0=%x", r()[4]))
					r()[4] += 1
					cpu.call(cpu.MOD_ORIGINAL)
					v := r()[2]
					append(&log, fmt.aprintf("RH v0=%x", v))
					r()[4] = 10
					cpu.call(EXE_J)
					r()[4] = v
					cpu.call(cpu.MOD_ORIGINAL)
					r()[2] += 0x100
				}},
			{M_ORIG_J, proc() {
					append(&log, fmt.aprintf("RJ a0=%x", r()[4]))
					if nest_x {cpu.call(EXE_X)}
					if cb {cpu.call_callback(M_I_CB)}
					cpu.call(cpu.MOD_ORIGINAL)
					append(&log, fmt.aprintf("RJ v0=%x", r()[2]))
				}},
			{M_ORIG_HOOK, proc() {cpu.call(cpu.MOD_ORIGINAL)}},
		},
	)
	cpu.register_overlay_funcs({{addr = OVL_B, slot = SLOT, id = ID, sig = CODE, fn = proc() {game_fn("B", 3)}}})
	port :: proc() {
		append(&log, "P")
		port_original()
	}
	orig, ok := cpu.hook(EXE_A, port)
	check(ok, "port hook")
	port_original = orig

	mods := []core.Mod_Manifest{{id = "a", version = {1, 0, 0}, api = core.MOD_API}, {id = "b", version = {1, 0, 0}, api = core.MOD_API}}
	order, oerr := core.mod_order(mods, nil)
	check(oerr == "", oerr)
	hooks := []core.Mod_Hook {
		{key(EXE_A), .After, 0, M_A_AFTER},
		{key(EXE_A), .Before, 1, M_B_BEFORE},
		{key(EXE_A), .Before, 0, M_A_BEFORE},
		{key(EXE_A), .After, 1, M_B_AFTER},
		{key(EXE_D), .Replace, 1, M_REPLACE},
		{key(EXE_D), .Before, 0, M_I_BEFORE},
		{key(OVL_B, SLOT, ID), .After, 1, M_B_AFTER},
		{key(OVL_C, SLOT, ID), .Before, 0, M_NEST},
		{key(BOTH), .Before, 1, M_B_BEFORE},
		{key(BOTH, SLOT, ID), .Before, 0, M_A_BEFORE},
		{key(EXE_E), .Before, 0, M_E_BEFORE},
		{key(FLAT_F), .Before, 0, M_A_BEFORE},
		{key(FLAT_F), .After, 1, M_B_AFTER},
		{key(FLAT_G), .Replace, 1, M_I_REPLACE},
		{key(FLAT_G), .After, 0, M_A_AFTER},
		{key(EXE_H), .Before, 0, M_A_BEFORE},
		{key(EXE_H), .Replace, 1, M_ORIG_H},
		{key(EXE_H), .After, 1, M_B_AFTER},
		{key(EXE_J), .Replace, 0, M_ORIG_J},
		{key(FLAT_K), .Replace, 1, M_I_ORIG},
		{key(FLAT_K), .After, 0, M_A_AFTER},
		{key(EXE_X), .Before, 1, M_ORIG_HOOK},
		{key(THR_T), .Replace, 1, M_I_THR},
		{key(THR_T), .After, 0, M_A_AFTER},
		{key(THR_U), .Replace, 0, M_I_THR},
		{key(THR_U), .After, 1, M_B_AFTER},
		{key(OVL_R, SLOT, ID), .Replace, 0, M_MOVE},
		{key(FLAT_W), .Replace, 1, M_I_W},
		{key(FLAT_W), .After, 0, M_A_AFTER},
		{key(FLAT_P), .Replace, 0, M_I_P},
		{key(EXE_L), .Replace, 0, M_I_L},
		{key(EXE_L), .After, 1, M_B_AFTER},
		{key(EXE_Q), .Replace, 0, M_EXEC},
	}
	chains, cerr := core.mod_chains(mods, order, hooks)
	check(cerr == "", cerr)

	test_errors(mods)
	cpu.mod_sp = STACK
	err := cpu.mod_install(mods, chains)
	check(err == "", err)
	check(cpu.mod_install(mods, chains) == "mod: hooks installed twice", "twice")
	if len(os.args) == 2 {orig_child(os.args[1])}

	// A: befores in load order, the port hook and A, afters in reverse.
	cpu.state.cycles = 100
	cpu.next_event = 1 << 40
	v0 := call(EXE_A, 5)
	expect("a< a0=5 v0=0; b< a0=5 v0=0; P; A a0=5; b> a0=5 v0=6; a> a0=5 v0=6")
	check(v0 == 6 && r()[4] == 5 && r()[8] == 0x77, "A's results kept, hooks' undone")
	check(cpu.state.cycles == 110, fmt.tprintf("cycles %d: only A's 10 count", cpu.state.cycles))
	check(cpu.next_event == 1 << 40, "next_event put back")
	check(len(seen.sp) == 4 && seen.sp[0] == STACK && seen.sp[1] == STACK && seen.sp[3] == STACK, "hooks on the mod stack")
	for ne in seen.ne {check(ne == max(u64), "time frozen in hooks")}

	// An event a hook schedules is checked for as soon as it returns.
	schedule = true
	call(EXE_A, 5)
	schedule = false
	check(cpu.next_event == 110, fmt.tprintf("next_event %d after a hook scheduled 5000: the hook's entry, 110", cpu.next_event))
	cpu.next_event = 1 << 40

	// E: its hook's event and interrupt are held while it runs, cop0 is put
	// back, and both are handled at the game's next check.
	for &t in io.events {t = io.EVENT_OFF}
	io.event_handlers[.Dma] = proc() {append(&log, "event")}
	io.deliver_irq = proc() {append(&log, "irq")}
	io.irq_regs.mask = 1 << u32(io.Irq.Dma)
	cpu.cop0.sr = 0x401
	cpu.state.cycles = 100
	call(EXE_E, 1)
	expect("e<; E a0=1")
	check(cpu.cop0.sr == 0x401, fmt.tprintf("sr %x after a hook cleared it", cpu.cop0.sr))
	check(cpu.next_event == 100, fmt.tprintf("next_event %d: held at the hook's entry, 100", cpu.next_event))
	clear(&log)
	io.run_events()
	expect("event; irq")
	io.irq_regs.stat = 0
	cpu.next_event = 1 << 40

	// D: an interpreted before hook, then the replacement on the game's
	// stack and in game time; D itself does not run.
	cpu.state.cycles = 0
	v0 = call(EXE_D, 7)
	expect(fmt.tprintf("i< a0=7 v0=0; R a0=7 sp=%x", u32(GAME_SP)))
	check(v0 == 0x99 && cpu.state.cycles == 20, "replacement's result and time")

	// B: the recompiled overlay function, then b's after hook.
	v0 = call(OVL_B, 1)
	expect("B a0=1; b> a0=1 v0=4")
	check(v0 == 4, "B's result")

	// C: its before hook calls D, whose chain runs nested below the hook's
	// stack pointer; then C is interpreted.
	v0 = call(OVL_C, 3)
	expect(fmt.tprintf("N a0=3 v0=0; i< a0=9 v0=bad; R a0=9 sp=%x; C a0=3", u32(STACK - 64)))
	check(v0 == 7, "C's result")
	check(len(seen.sp) == 2 && seen.sp[0] == STACK && seen.sp[1] == STACK - 64, "nested hook below the running one")

	// Another overlay at the slot: B and C run without hooks.
	put(SLOT, ID + 1)
	call(OVL_B, 1)
	expect("iB a0=1")
	call(OVL_C, 1)
	expect("C a0=1")
	call(BOTH, 1)
	expect("b< a0=1 v0=0; interp 80100300")
	put(SLOT, ID)
	call(OVL_B, 1)
	expect("B a0=1; b> a0=1 v0=4")
	call(BOTH, 1)
	expect("a< a0=1 v0=0; interp 80100300")

	// H: its replacement runs its original (recompiled) twice, without
	// hooks, and J between, whose replacement runs J's (interpreted).
	v0 = call(EXE_H, 5)
	expect("a< a0=5 v0=0; RH a0=5; H a0=6; RH v0=7; RJ a0=a; J a0=a; RJ v0=d; H a0=7; b> a0=5 v0=108")
	check(v0 == 0x108, fmt.tprintf("H's result %x", v0))

	// mod_call_original from a before hook, from one a replacement reached,
	// and with no replacement running: each fatal.
	self, _ := os.get_executable_path(context.allocator)
	Child :: struct {
		name, said: string,
	}
	OUTSIDE :: "fatal: mod: a call to mod_call_original (1f3ffff0) outside a replacement"
	all := [?]Child {
		{"hook", OUTSIDE},
		{"nested", OUTSIDE},
		{"none", OUTSIDE},
		{"inorig", OUTSIDE},
		{"ininterp", OUTSIDE},
		{"callback", OUTSIDE},
		{"exec", OUTSIDE},
		{"moved", "fatal: mod: mod_call_original for 80100400, in overlay 3c011234 at 80100000: that code is no longer in RAM (overlay 3c011235 there)"},
		{"flatorig", OUTSIDE}, // FLAT only
		{"flatcb", OUTSIDE},
	}
	for c in all[:len(all) - (core.FLAT ? 0 : 2)] {
		state, _, errs, perr := os.process_exec({command = {self, c.name}}, context.temp_allocator)
		check(perr == nil && state.exit_code == 1, fmt.tprintf("child %s: %v exit %d", c.name, perr, state.exit_code))
		check(strings.contains(string(errs), c.said), fmt.tprintf("child %s said %q", c.name, string(errs)))
	}
	delete(self)

	// D's code changed: D runs as it is, without hooks.
	put(EXE_D, 0)
	v0 = call(EXE_D, 1)
	expect("D a0=1")
	check(v0 == 3, "D's result")
	put_code(EXE_D)
	call(EXE_D, 1)
	expect(fmt.tprintf("i< a0=1 v0=0; R a0=1 sp=%x", u32(GAME_SP)))

	when core.FLAT {
		test_flat()
		test_flat_orig()
	}
	test_threads()
	when !core.FLAT {test_tail()}
	test_exec()

	core.mod_chains_delete(chains)
	free_all(context.temp_allocator)
	if failed != 0 {os.exit(1)}
	fmt.println("ok psx_mod")
}

@(private = "file")
port_original: cpu.Func_Proc

// Each refused install leaves the tables as they were: A still runs only
// its port hook.
@(private = "file")
test_errors :: proc(mods: []core.Mod_Manifest) {
	other := key(EXE_D)
	other.sig[3] = 1
	Bad :: struct {
		key: core.Mod_Key,
		err: string,
	}
	bad := []Bad {
		{key(0x80011002), "mod b: a hook on 80011002, which is not a function in RAM"},
		{key(0x1f400000), "mod b: a hook on 1f400000, which is not a function in RAM"},
		{key(OVL_B, OVL_B, ID), "mod b: a hook on 80100100 in an overlay at 80100100"},
		{key(EXE_D, 0, ID), "mod b: a hook on 80011000 with id 3c011234 and no slot"},
		{other, "mod b: the code at 80011000 is not the code it was built for"},
	}
	// A good chain on A, then one on k.
	fa := []core.Mod_Fn{{0, M_A_BEFORE}}
	fb := []core.Mod_Fn{{1, M_B_BEFORE}}
	two := [2]core.Mod_Chain{{key = key(EXE_A), before = fa}, {key = key(EXE_D), before = fb}}
	check(cpu.mod_install(mods, two[:]) == "mod: no mod stack", "no mod stack")
	cpu.mod_sp = STACK
	for b in bad {
		two[1].key = b.key
		e := cpu.mod_install(mods, two[:])
		check(e == b.err, fmt.tprintf("got %q, want %q", e, b.err))
	}
	many := make([]core.Mod_Chain, cpu.MOD_SITES + 1, context.temp_allocator)
	for &c, i in many {
		addr := 0x80120000 + u32(i) * 16
		put_code(addr)
		c = {key = key(addr), before = fa}
	}
	e := cpu.mod_install(mods, many)
	check(e == "mod: 513 functions hooked, at most 512", e)
	cpu.mod_sp = 0
	call(EXE_A, 5)
	expect("P; A a0=5")
}

// A child process: call mod_call_original where it is fatal, and exit 3 if
// it was not.
@(private = "file")
orig_child :: proc(name: string) {
	switch name {
	case "hook":
		call(EXE_X, 1)
	case "nested":
		nest_x = true
		call(EXE_J, 1)
	case "none":
		cpu.call(cpu.MOD_ORIGINAL)
	case "inorig":
		in_orig = true
		call(EXE_H, 1)
	case "ininterp":
		in_orig = true
		call(EXE_J, 1)
	case "callback":
		cb = true
		call(EXE_J, 1)
	case "exec":
		bios.bios_init()
		exec_orig = true
		test_exec()
	case "moved":
		call(OVL_R, 1)
	case "flatorig":
		when core.FLAT {
			in_orig = true
			flat_orig_setup()
			flat_caller(FLAT_W)
		}
	case "flatcb":
		when core.FLAT {
			flat_orig_setup()
			// G's replacement stops with B(43h), which calls M_I_CB back.
			stopper(M_I_REPLACE, 0x43, 0x24020099)
			flat_caller(FLAT_G)
		}
	}
	os.exit(3)
}

// test_threads' handle of its second thread, and how many times each
// yield (B(46h) to B(49h)) ran.
@(private = "file")
thr: struct {
	b:      u32,
	yields: [4]int,
}

// A yield of test_threads, B(n): log it with the running thread's
// replacements (mod_inner's, past its markers), and switch threads as the case has it.
@(private = "file")
thr_yield :: proc(n: u32) {
	k := n - 0x46
	if k >= 4 {
		check(false, fmt.tprintf("B(%x) in test_threads", n))
		return
	}
	depth := 0
	for i := cpu.mod_inner; i != nil; i = i.prev {depth += int(i.run >= 0)}
	append(&log, fmt.aprintf("y%x %d", n, depth))
	thr.yields[k] += 1
	// T's original and U's switch the first time only; the threads' own
	// code, every time.
	to: u32
	switch n {
	case 0x46:
		if thr.yields[k] == 1 {to = thr.b}
	case 0x47:
		if thr.yields[k] == 1 {to = 0xff000000}
	case 0x48:
		to = thr.b
	case 0x49:
		to = 0xff000000
	}
	if to == 0 {return}
	// ChangeTh takes the handle in a0, the function's argument here: the
	// thread switched from gets its own a0 back.
	a0 := r()[4]
	r()[4] = to
	when core.FLAT {
		// The run stops with the other thread's registers loaded; this
		// thread's are in its TCB (the PCB's word).
		from := cpu.r32(cpu.r32(0x108))
		bios.bios_b(0x10)
		cpu.w32(from + 8 + 4 * 4, a0)
	} else {
		inner := cpu.mod_inner
		bios.bios_b(0x10)
		// Resumed on this thread.
		r()[4] = a0
		check(cpu.mod_inner == inner, fmt.tprintf("y%x: the thread's replacements back after the switch", n))
	}
}

// A replacement's original switches threads (T's yields to the second
// thread), and the second thread's replacement's original switches back
// (U's): each later mod_call_original runs its own thread's original, and
// each after hook its own thread's chain. Plain the threads are the BIOS's
// coroutines; under FLAT, flat runs that flat_main switches between.
@(private = "file")
test_threads :: proc() {
	bios.bios_init()
	when core.FLAT {
		cpu.interp_run = cpu.flat_nested
		cpu.flat_step = cpu.mod_flat_step
	} else {
		cpu.interp_run = cpu.interp_loop
	}
	cpu.bios_b = thr_yield
	thr = {}
	// T and U as K is, their original yielding.
	stopper(THR_T + 16, 0x46, 0x24820001) // addiu v0, a0, 1
	put(THR_T + 16 + 9 * 4, 0x27bd0018)
	stopper(THR_U + 16, 0x47, 0x24820001)
	put(THR_U + 16 + 9 * 4, 0x27bd0018)
	hi, lo := u32(0x3c0a0000 | (cpu.MOD_ORIGINAL + 0x8000) >> 16), u32(0x254a0000 | cpu.MOD_ORIGINAL & 0xffff)
	// The replacement: the original, then the original on 7, the sum.
	repl := [?]u32 {
		0x03e09021, // addu s2, ra, zero
		hi, // lui t2, hi
		lo, // addiu t2, t2, lo
		0x0140f809, // jalr t2
		0x00000000,
		0x00409821, // addu s3, v0, zero
		0x24040007, // addiu a0, zero, 7
		hi,
		lo,
		0x0140f809, // jalr t2
		0x00000000,
		0x00531021, // addu v0, v0, s3
		0x02400008, // jr s2
		0x00000000,
	}
	for w, k in repl {put(M_I_THR + u32(k) * 4, w)}
	// The main thread: T(5), then yield to the second thread, and return
	// T's result.
	main_code := [?]u32 {
		0x03e08821, // addu s1, ra, zero
		0x24040005, // addiu a0, zero, 5
		0x0c000000 | (THR_T >> 2) & 0x3ffffff, // jal T
		0x00000000,
		0x00408021, // addu s0, v0, zero
		0x24090048, // addiu t1, zero, 0x48
		0x240a00b0, // addiu t2, zero, 0xb0
		0x0140f809, // jalr t2
		0x00000000,
		0x02001021, // addu v0, s0, zero
		0x02200008, // jr s1
		0x00000000,
	}
	for w, k in main_code {put(THR_MAIN + u32(k) * 4, w)}
	// The second thread: U(9), then yield back to the main thread, forever.
	b_code := [?]u32 {
		0x24040009, // addiu a0, zero, 9
		0x0c000000 | (THR_U >> 2) & 0x3ffffff, // jal U
		0x00000000,
		0x24090049, // addiu t1, zero, 0x49
		0x240a00b0, // addiu t2, zero, 0xb0
		0x0140f809, // jalr t2
		0x00000000,
		0x1000fffb, // b back to the yield
		0x00000000,
	}
	for w, k in b_code {put(THR_B + u32(k) * 4, w)}
	r()[4], r()[5], r()[6] = THR_B, THR_B_SP, 0
	bios.bios_b(0x0e)
	thr.b = r()[2]
	check(thr.b == 0xff000001, fmt.tprintf("OpenTh %x", thr.b))

	clear(&log)
	r()[2], r()[29], r()[31] = 0, GAME_SP, 0x80001234
	when core.FLAT {bios.flat_main(THR_MAIN)} else {cpu.call(THR_MAIN)}
	// U's original ran on 9 then 7 (10h + 8), T's on 5 then 7 (6 + 8).
	// Plain, a thread's replacements are its own: one where an original
	// yields, none in a thread's own code. Under FLAT a replacement is a
	// continuation of its thread's run, not on the host stack.
	d := core.FLAT ? 0 : 1
	expect(fmt.tprintf("y46 %d; y47 %d; y46 %d; a> a0=5 v0=e; y48 0; y47 %d; b> a0=9 v0=12; y49 0", d, d, d, d))
	check(r()[2] == 0xe && r()[29] == GAME_SP && cpu.mod_inner == nil, fmt.tprintf("threads: v0 %x, sp %x, back on the main thread with no replacement", r()[2], r()[29]))
}

// Guest code for test_flat: save $ra in t3, make BIOS call B(n) (which
// stops the run), set v0, v1 (0x77) and a0 (0x55), return through t3.
@(private = "file")
stopper :: proc(addr, n, v0: u32) {
	code := [?]u32 {
		0x03e05821, // addu t3, ra, zero
		0x240a00b0, // addiu t2, zero, 0xb0
		0x24090000 | n, // addiu t1, zero, n
		0x0140f809, // jalr t2
		0x00000000,
		v0, // sets v0
		0x24030077, // addiu v1, zero, 0x77
		0x24040055, // addiu a0, zero, 0x55
		0x01600008, // jr t3
		0x00000000,
	}
	for w, k in code {put(addr + u32(k) * 4, w)}
}

// Under FLAT: CALLER, run as a flat run's base, calls the function at
// target with a0 = 5. Its run stops inside the original or the
// replacement, then resumes to its end.
when core.FLAT {
	@(private = "file")
	test_flat :: proc() {
		cpu.interp_run = cpu.flat_nested
		cpu.flat_step = cpu.mod_flat_step
		// B(44h) first calls A from host code: A's chain runs nested, at once.
		cpu.bios_b = proc(n: u32) {
			if n == 0x44 {cpu.call(EXE_A)}
			append(&log, fmt.aprintf("stop %x", n))
			cpu.flat_block("a test's stop")
		}
		// F's body after CODE, which took 24 bytes of stack: the delay slot of
		// its jr t3 gives them back.
		stopper(FLAT_F + 16, 0x42, 0x24820001) // addiu v0, a0, 1
		put(FLAT_F + 16 + 9 * 4, 0x27bd0018) // jr t3's slot: addiu sp, sp, 24
		stopper(M_I_REPLACE, 0x43, 0x24020099) // addiu v0, zero, 0x99
		// K as F is, stopping with B(45h).
		stopper(FLAT_K + 16, 0x45, 0x24820001)
		put(FLAT_K + 16 + 9 * 4, 0x27bd0018)
		// K's replacement: K's original on a0 + 1, then 0x100 more.
		orig := [?]u32 {
			0x03e06021, // addu t4, ra, zero
			0x24840001, // addiu a0, a0, 1
			0x3c0a0000 | (cpu.MOD_ORIGINAL + 0x8000) >> 16, // lui t2, hi
			0x254a0000 | cpu.MOD_ORIGINAL & 0xffff, // addiu t2, t2, lo
			0x0140f809, // jalr t2
			0x00000000,
			0x24420100, // addiu v0, v0, 0x100
			0x01800008, // jr t4
			0x00000000,
		}
		for w, k in orig {put(M_I_ORIG + u32(k) * 4, w)}
		Case :: struct {
			target: u32,
			first:  string, // logged until the stop
			rest:   string, // logged after the resume
			v0:     u32,
		}
		cases := [?]Case {
			{FLAT_F, "a< a0=5 v0=0; stop 42", "b> a0=5 v0=6", 6},
			{FLAT_G, "stop 43", "a> a0=5 v0=99", 0x99},
			{FLAT_F, "stop 42", "", 6}, // F's last CODE word changed: no hooks
			{FLAT_F, "a< a0=5 v0=0; a< a0=5 v0=0; b< a0=5 v0=0; P; A a0=5; b> a0=5 v0=6; a> a0=5 v0=6; stop 44", "b> a0=5 v0=6", 6},
			// The stop is inside K's original, which its replacement called.
			{FLAT_K, "stop 45", "a> a0=5 v0=107", 0x107},
		}
		x: cpu.Flat_Ctx
		for c, i in cases {
			switch i {
			case 2:
				put(FLAT_F + 12, 0x00000021) // addu zero, zero, zero
			case 3:
				put(FLAT_F + 12, 0)
				put(FLAT_F + 16 + 2 * 4, 0x24090044) // addiu t1, zero, 0x44
			}
			code := [?]u32 {
				0x03e08821, // addu s1, ra, zero
				0x24040005, // addiu a0, zero, 5
				0x0c000000 | (c.target >> 2) & 0x3ffffff, // jal target
				0x00000000,
				0x02200008, // jr s1
				0x00000000,
			}
			for w, k in code {put(CALLER + u32(k) * 4, w)}
			clear(&log)
			r()[2], r()[3], r()[29], r()[31] = 0, 0, GAME_SP, 0x80001234
			cpu.flat_start(&x, CALLER)
			check(!cpu.flat_run(&x), fmt.tprintf("%08x: the run stops inside", c.target))
			expect(c.first)
			clear(&log)
			check(cpu.flat_run(&x), fmt.tprintf("%08x: the resumed run ends", c.target))
			expect(c.rest)
			check(r()[2] == c.v0 && r()[3] == 0x77 && r()[4] == 0x55 && r()[29] == GAME_SP, fmt.tprintf("%08x: v0 %x, v1 %x, a0 %x, sp %x: as the function left them, past the after hook", c.target, r()[2], r()[3], r()[4], r()[29]))
		}
		cpu.flat_free(&x)
	}
}

// L's replacement tail-calls its original (jr t2), called from host code
// and interpreted. Plain only: FLAT interprets only inside a flat run
// (test_flat_orig).
@(private = "file")
test_tail :: proc() {
	v0 := call(EXE_L, 5)
	expect("b> a0=5 v0=7")
	check(v0 == 7, fmt.tprintf("L's result %x", v0))
}

// Q's replacement runs a program with Exec: it starts inside no replacement
// and no hook, and the replacement gets Q's original after it returns.
@(private = "file")
test_exec :: proc() {
	for k in u32(0) ..< 15 {cpu.w32(HDR + 4 * k, 0)}
	cpu.w32(HDR, M_PC0)
	v0 := call(EXE_Q, 5)
	expect("RQ; pc0 inner=true depth=0; exec v0=1; Q a0=5")
	check(v0 == 9, fmt.tprintf("Q's result %x", v0))
}

when core.FLAT {
	// The code test_flat_orig runs, and its BIOS calls: B(43h) calls M_I_CB
	// back (flatcb); B(4bh), in P's original, logs a0 and whether a stop may
	// come there (not inside a nested run).
	@(private = "file")
	flat_orig_setup :: proc() {
		cpu.interp_run = cpu.flat_nested
		cpu.flat_step = cpu.mod_flat_step
		cpu.bios_b = proc(n: u32) {
			switch n {
			case 0x43:
				cpu.call_callback(M_I_CB)
			case 0x4b:
				append(&log, fmt.aprintf("4b a0=%x nested=%v", r()[4], !cpu.flat_can_stop()))
			case:
				check(false, fmt.tprintf("B(%x) in test_flat_orig", n))
			}
		}
		// W's replacement: W's original on a0 + 1, then 0x100 more.
		w := [?]u32 {
			0x03e06021, // addu t4, ra, zero
			0x24840001, // addiu a0, a0, 1
			orig_hi(),
			orig_lo(),
			0x0140f809, // jalr t2
			0x00000000,
			0x24420100, // addiu v0, v0, 0x100
			0x01800008, // jr t4
			0x00000000,
		}
		for v, k in w {put(M_I_W + u32(k) * 4, v)}
		// P's replacement: P(a0 - 1) while a0 is above 0, then P's original
		// on a0.
		p := [?]u32 {
			0x27bdfff0, // addiu sp, sp, -16
			0xafbf0000, // sw ra, 0(sp)
			0xafa40004, // sw a0, 4(sp)
			0x10800003, // beq a0, zero, past the call
			0x00000000,
			0x0c000000 | (FLAT_P >> 2) & 0x3ffffff, // jal P
			0x2484ffff, // addiu a0, a0, -1
			0x8fa40004, // lw a0, 4(sp)
			orig_hi(),
			orig_lo(),
			0x0140f809, // jalr t2
			0x00000000,
			0x8fbf0000, // lw ra, 0(sp)
			0x03e00008, // jr ra
			0x27bd0010, // addiu sp, sp, 16
		}
		for v, k in p {put(M_I_P + u32(k) * 4, v)}
		// P's body after CODE: B(4bh), then v0 = a0 + 1.
		body := [?]u32 {
			0x240a00b0, // addiu t2, zero, 0xb0
			0x2409004b, // addiu t1, zero, 0x4b
			0x0140f809, // jalr t2
			0x00000000,
			0x8fbf0010, // lw ra, 16(sp)
			0x24820001, // addiu v0, a0, 1
			0x03e00008, // jr ra
			0x27bd0018, // addiu sp, sp, 24
		}
		for v, k in body {put(FLAT_P + 16 + u32(k) * 4, v)}
	}

	// Run CALLER, calling target with a0 as a flat run's base, to its end
	// (true) or a stop.
	@(private = "file")
	flat_caller :: proc(target: u32, a0: u32 = 5) -> (ended: bool) {
		code := [?]u32 {
			0x03e08821, // addu s1, ra, zero
			0x24040000 | a0, // addiu a0, zero, a0
			0x0c000000 | (target >> 2) & 0x3ffffff, // jal target
			0x00000000,
			0x02200008, // jr s1
			0x00000000,
		}
		for w, k in code {put(CALLER + u32(k) * 4, w)}
		clear(&log)
		r()[2], r()[3], r()[29], r()[31] = 0, 0, GAME_SP, 0x80001234
		cpu.next_event = 1 << 40
		x: cpu.Flat_Ctx
		cpu.flat_start(&x, CALLER)
		ended = cpu.flat_run(&x)
		cpu.flat_free(&x)
		return
	}

	// W's replacement on a flat run gets W's recompiled original; P's
	// recursion fills the run's continuations (FLAT_HOST): P(0) runs nested
	// and gets its original there, P(1)'s original runs nested
	// (call_guest), and the outer three get theirs on the run; L's
	// replacement tail-calls its original on the run.
	@(private = "file")
	test_flat_orig :: proc() {
		flat_orig_setup()
		check(flat_caller(FLAT_W), "W: the run ends")
		expect("W a0=6; a> a0=5 v0=108")
		check(r()[2] == 0x108 && r()[29] == GAME_SP, fmt.tprintf("W: v0 %x, sp %x", r()[2], r()[29]))
		check(flat_caller(FLAT_P, 4), "P: the run ends")
		expect("4b a0=0 nested=true; 4b a0=1 nested=true; 4b a0=2 nested=false; 4b a0=3 nested=false; 4b a0=4 nested=false")
		check(r()[2] == 5 && r()[29] == GAME_SP, fmt.tprintf("P: v0 %x, sp %x", r()[2], r()[29]))
		check(flat_caller(EXE_L), "L: the run ends")
		expect("b> a0=5 v0=7")
		check(r()[2] == 7 && r()[29] == GAME_SP, fmt.tprintf("L: v0 %x, sp %x", r()[2], r()[29]))
	}
}
