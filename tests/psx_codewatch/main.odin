// psx/cpu's watch on recompiled executable code (watch.odin) on a hand-built
// dispatch table: a write to a function's page demotes the page's functions,
// each then runs native only while its first code words are the ones it was
// recompiled from, and the interpreter runs whatever was loaded over it. A
// demoted function's call puts the page's functions whose code is back into
// the fixed table again.
//
//   0x80010000  F, recompiled from CODE_F; a CPU store (sw) changes its first
//               word, so a call or an interpreted branch to it interprets;
//               the old word stored back runs F native again and puts it
//               back in the fixed table
//   0x80010100  G, F's page-mate, its code untouched: native throughout, back
//               in the fixed table at its first call; a guarded touch of the
//               page's own bytes (a RAM snapshot put back) demotes the page
//               and the next call promotes it again, twice in a row; a hook
//               set while it is demoted, or while it is back, stays its
//               procedure through demotions and promotions
//   0x80010800  data on F's page, written every frame: each write demotes
//               the page and F's next call promotes it again
//   0x80012000  K, recompiled from CODE_K; a device write (w32, as DMA does)
//               changes it, so calls and jumps to it interpret; the old bytes
//               copied back (mem_slice, as the BIOS's loaders do) run K native
//               and put it back in the fixed table
//   0x80000200  H, registered after watch_code, as the BIOS registers its
//               own: a write to its page leaves it in the fixed table
//
// With -define:FALLBACK_COUNT=true the demotions, the promotions and the calls
// that reached a demoted function count apart from overlay resolves.
package main

import "core:fmt"
import "core:os"
import cpu "ps:psx/cpu"

@(private = "file")
fail :: proc(what: string) -> ! {
	fmt.eprintln("FAIL psx_codewatch:", what)
	os.exit(1)
}

@(private = "file")
interpreted: [dynamic]u32

@(private = "file")
runs: struct {
	f, g, k, h, a, b: int,
}

@(private = "file")
hook_a :: proc() {runs.a += 1}

@(private = "file")
hook_b :: proc() {runs.b += 1}

// G's signed entry, which code_demote made.
@(private = "file")
entry_g :: proc() -> ^cpu.Ovl_Entry {
	for &e in cpu.dispatch.overlay[0x80010100] {
		if e.slot == e.addr {
			return &e
		}
	}
	fail("G has no signed entry")
}

// Frames of the data on F's page.
@(private = "file")
DATA_FRAMES :: 3

@(private = "file", rodata)
CODE_F := [4]u32{0x27bdffe8, 0xafbf0010, 0x0c004000, 0x00000000}

@(private = "file", rodata)
CODE_K := [4]u32{0x3c021f80, 0x8c421070, 0x03e00008, 0x00000000}

@(private = "file")
put :: proc(addr: u32, code: [4]u32) {
	for w, k in code {
		(^u32le)(&cpu.ram[(addr & 0x1fffff) + u32(k) * 4])^ = u32le(w)
	}
}

@(private = "file")
expect :: proc(what: string, got, want: int) {
	if got != want {
		fail(fmt.tprintf("%s: %d, want %d", what, got, want))
	}
}

main :: proc() {
	cpu.interp_run = proc(start: u32) {append(&interpreted, start)}
	put(0x80010000, CODE_F)
	put(0x80010100, CODE_F)
	put(0x80012000, CODE_K)
	cpu.register_funcs(
		{
			{0x80010000, proc() {runs.f += 1}},
			{0x80010100, proc() {runs.g += 1}},
			{0x80012000, proc() {runs.k += 1}},
		},
	)
	cpu.watch_code()
	cpu.register_funcs({{0x80000200, proc() {runs.h += 1}}})

	cpu.call(0x80010000)
	expect("F runs before any write", runs.f, 1)

	// A CPU store over F's first word: F and G leave the fixed table.
	cpu.sw(0x80010000, 0x24020001)
	if cpu.registered(0x80010000) || cpu.registered(0x80010100) {
		fail("F's page still in the fixed table after a store to it")
	}
	// The interpreter's branch test (psx_cpu goto_target) reads the fixed table
	// only: a branch into F, its slot empty, interprets.
	if cpu.dispatch.fixed[cpu.fn_index(0x80010000)] != nil {
		fail("an interpreted branch into F would run its old native code")
	}
	cpu.call(0x80010000)
	cpu.call(0x80010100)
	expect("F native runs after its code changed", runs.f, 1)
	expect("G native runs, code unchanged", runs.g, 1)
	if cpu.registered(0x80010000) || !cpu.registered(0x80010100) {
		fail("after G's call: want G back in the fixed table and not F")
	}

	// The same word back (changed then restored): the store demotes G again,
	// F's signature matches again and its call promotes the page.
	cpu.sw(0x80010000, CODE_F[0])
	if cpu.registered(0x80010100) {
		fail("G still in the fixed table after a second store")
	}
	cpu.call(0x80010000)
	expect("F native runs with its code back", runs.f, 2)
	if !cpu.registered(0x80010000) || !cpu.registered(0x80010100) {
		fail("change then restore: F's page not promoted")
	}

	// A guarded touch of the page's own bytes demotes it; the next call
	// promotes it again, each time.
	for _ in 0 ..< 2 {
		cpu.ram_touch(0x80010000, cpu.RAM_PAGE)
		if cpu.registered(0x80010000) || cpu.registered(0x80010100) {
			fail("F's page still in the fixed table after a touch")
		}
		cpu.call(0x80010100)
		cpu.call(0x80010000)
		if !cpu.registered(0x80010000) || !cpu.registered(0x80010100) {
			fail("touch of the same bytes: F's page not promoted")
		}
	}
	expect("G native runs after the touches", runs.g, 3)
	expect("F native runs after the touches", runs.f, 4)

	// A hook set on G while it is demoted is its procedure from then on:
	// the call that promotes the page runs the hook and leaves it in G's
	// slot.
	cpu.ram_touch(0x80010000, cpu.RAM_PAGE)
	if _, ok := cpu.hook(0x80010100, hook_a); !ok {
		fail("hook on demoted G refused")
	}
	cpu.call(0x80010100)
	expect("hook set on demoted G runs", runs.a, 1)
	if cpu.dispatch.fixed[cpu.fn_index(0x80010100)] != hook_a {
		fail("promotion put G's old procedure over its hook")
	}

	// A hook set while G is back: the next demotion carries it into G's
	// entry, and the promotion after puts it back in G's slot.
	cpu.hook(0x80010100, hook_b)
	cpu.ram_touch(0x80010000, cpu.RAM_PAGE)
	if entry_g().fn != hook_b {
		fail("demotion left G's entry without the hook set while it was back")
	}
	cpu.call(0x80010100)
	expect("hook set on promoted G runs after a demotion", runs.b, 1)
	if cpu.dispatch.fixed[cpu.fn_index(0x80010100)] != hook_b {
		fail("re-promotion lost the hook set while G was back")
	}

	// hook_overlay on G's signed entry while it is demoted does as hook does.
	cpu.ram_touch(0x80010000, cpu.RAM_PAGE)
	if was, ok := cpu.hook_overlay(0x80010100, 0x80010100, CODE_F[0], hook_a); !ok || was != hook_b {
		fail("hook_overlay on demoted G: want ok and hook_b replaced")
	}
	cpu.call(0x80010100)
	expect("hook_overlay set on demoted G runs", runs.a, 2)
	if cpu.dispatch.fixed[cpu.fn_index(0x80010100)] != hook_a || entry_g().fn != hook_a {
		fail("hook_overlay on demoted G: slot or entry without the hook")
	}
	expect("G's own procedure while hooked", runs.g, 3)

	// Data on F's page written every frame, F called after each write.
	for k in 0 ..< DATA_FRAMES {
		cpu.sw(0x80010800, u32(k))
		if cpu.registered(0x80010000) {
			fail("F's page still in the fixed table after a data write")
		}
		cpu.call(0x80010000)
		if !cpu.registered(0x80010000) {
			fail("data write: F's page not promoted")
		}
	}
	expect("F native runs after each data write", runs.f, 4 + DATA_FRAMES)

	// A device write over K, then calls and jumps to it.
	cpu.w32(0x80012008, 0x00000000)
	cpu.call(0x80012000)
	cpu.jump_unknown(0x80011000, 0x80012000)
	expect("K native runs after a device write", runs.k, 0)
	if !cpu.has_func(0x80010000) || cpu.has_func(0x80012000) {
		fail("has_func: want F (code back) and not K (code changed)")
	}

	// K's bytes copied back whole.
	back := cpu.mem_slice(0x80012000, 16)
	for w, k in CODE_K {
		(^u32le)(&back[k * 4])^ = u32le(w)
	}
	cpu.call(0x80012000)
	cpu.jump_unknown(0x80011000, 0x80012000)
	expect("K native runs with its code back", runs.k, 2)
	if !cpu.registered(0x80012000) {
		fail("K's page not promoted with its code back")
	}

	// H's page was never watched.
	cpu.sw(0x80000300, 1)
	if !cpu.registered(0x80000200) {
		fail("a function registered after watch_code was demoted")
	}

	want := [?]u32{0x80010000, 0x80012000, 0x80012000}
	if len(interpreted) != len(want) {
		fail(fmt.tprintf("interpreted %x, want %x", interpreted[:], want))
	}
	for pc, k in want {
		if interpreted[k] != pc {
			fail(fmt.tprintf("interpreted %x, want %x", interpreted[:], want))
		}
	}

	when cpu.FALLBACK_COUNT {
		if cpu.demoted_pages != 8 + DATA_FRAMES || cpu.promoted_pages != 8 + DATA_FRAMES {
			fail(fmt.tprintf("demoted_pages = %d, promoted_pages = %d, want %d each", cpu.demoted_pages, cpu.promoted_pages, 8 + DATA_FRAMES))
		}
		calls := [?]struct {
			pc: u32,
			n:  u64,
		}{{0x80010000, 1 + DATA_FRAMES}, {0x80010100, 6}, {0x80012000, 1}}
		if len(cpu.dispatch_demoted) != len(calls) {
			fail(fmt.tprintf("dispatch_demoted = %v, want %v", cpu.dispatch_demoted, calls))
		}
		for c in calls {
			if cpu.dispatch_demoted[c.pc] != c.n {
				fail(fmt.tprintf("dispatch_demoted = %v, want %v", cpu.dispatch_demoted, calls))
			}
		}
		if len(cpu.dispatch_overlay) != 0 {
			fail(fmt.tprintf("dispatch_overlay = %v, want none", cpu.dispatch_overlay))
		}
		want_dispatch :: "kind\tpc\tfrom\tcount\n" +
			"demoted\t80010100\t-\t6\n" +
			"demoted\t80010000\t-\t4\n" +
			"demoted\t80012000\t-\t1\n" +
			"jump_call\t80012000\t80011000\t1\n"
		if _, dispatch := cpu.fallback_tsv(); dispatch != want_dispatch {
			fail(fmt.tprintf("dispatch table:\n%swant:\n%s", dispatch, want_dispatch))
		}
		cpu.fallback_dump()
		fmt.println("ok psx_codewatch: stores, touches, data writes and a device write demote 11 times, 3 funcs; changed code interprets, same code runs native and is promoted 11 times; 11 demoted calls counted")
	} else {
		fmt.println("ok psx_codewatch: stores, touches and a device write demote; changed code interprets, same code runs native and is promoted again; hooks survive both; late registrations unwatched")
	}
}
