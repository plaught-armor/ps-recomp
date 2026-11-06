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
//
// Mod functions live at 0x80180000 (recompiled) and 0x80190000
// (interpreted). Checked: the order hooks run in; befores and afters on the
// mod stack, nested ones below the running hook's stack pointer, with
// next_event at max and every register (the cycle count too) put back after;
// afters see the arguments and the results; the replacement and the
// original in game time; an event a hook schedules or an interrupt it
// raises is handled only after it returns, at once, and cop0 is put back.
// With the
// overlay's id or D's first word changed, calls run without hooks. Install
// errors leave nothing installed. Under FLAT (-define:PS_FLAT=true), a guest
// call from a flat run to F or G stops inside the original or the
// replacement and goes on with the after hook when the run resumes; with F's
// last CODE word changed, F stops and resumes without hooks; a call to A from
// host code while F's run is on runs A's chain nested, at once.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"
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
M_I_BEFORE :: 0x80190000
M_I_REPLACE :: 0x80190100

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

main :: proc() {
	cpu.interp_run = proc(start: u32) {
		switch start {
		case EXE_D:
			game_fn("D", 2)
		case OVL_B:
			game_fn("iB", 3)
		case OVL_C:
			game_fn("C", 4)
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
	}
	chains, cerr := core.mod_chains(mods, order, hooks)
	check(cerr == "", cerr)

	test_errors(mods)
	cpu.mod_sp = STACK
	err := cpu.mod_install(mods, chains)
	check(err == "", err)
	check(cpu.mod_install(mods, chains) == "mod: hooks installed twice", "twice")

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

	// D's code changed: D runs as it is, without hooks.
	put(EXE_D, 0)
	v0 = call(EXE_D, 1)
	expect("D a0=1")
	check(v0 == 3, "D's result")
	put_code(EXE_D)
	call(EXE_D, 1)
	expect(fmt.tprintf("i< a0=1 v0=0; R a0=1 sp=%x", u32(GAME_SP)))

	when core.FLAT {test_flat()}

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
