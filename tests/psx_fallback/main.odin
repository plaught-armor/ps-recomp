// psx/cpu's ways out of recompiled code on a hand-built dispatch table: the
// GTE's unknown-command report keeps out of report_once's set of RAM
// addresses, each call and jump reaches the interpreter or a function as
// before, and with -define:FALLBACK_COUNT=true each one counts once under
// its target, in the fallback table (interpreter work) or the dispatch one.
//
//   0x80001000  no function: call interprets
//   0x80002000  an overlay function, resident (id 0x1234 at slot 0x80001ff0,
//               its first words zero)
//   0x80003000  the jumping function: to 0x80003010 (unlabelled, inside it)
//               interprets, to 0x80000100 (below it) calls and so interprets,
//               to 0 (frame_ret outside any call) returns
package main

import "core:fmt"
import "core:os"
import cpu "ps:psx/cpu"
import gte "ps:psx/gte"

@(private = "file")
fail :: proc(what: string) -> ! {
	fmt.eprintln("FAIL psx_fallback:", what)
	os.exit(1)
}

@(private = "file")
interpreted: [dynamic]u32

@(private = "file")
overlay_runs: int

main :: proc() {
	// Command 0x05 is unknown; RAM address 5 stays unreported.
	gte.gte_cmd(0x05)
	if 5 in cpu.dispatch.reported {
		fail("gte command 0x05 marked RAM address 5 as reported")
	}

	cpu.interp_run = proc(start: u32) {append(&interpreted, start)}
	cpu.register_funcs(nil)
	(^u32le)(&cpu.ram[0x1ff0])^ = 0x1234
	cpu.register_overlay_funcs({{addr = 0x80002000, slot = 0x80001ff0, id = 0x1234, fn = proc() {overlay_runs += 1}}})

	cpu.call(0x80001000)
	cpu.call(0x80002000)
	cpu.jump_unknown(0x80003000, 0x80003010)
	cpu.jump_unknown(0x80003000, 0x80000100)
	cpu.jump_unknown(0x80003000, 0)

	want := [?]u32{0x80001000, 0x80003010, 0x80000100}
	if len(interpreted) != len(want) {
		fail(fmt.tprintf("interpreted %x, want %x", interpreted[:], want))
	}
	for pc, k in want {
		if interpreted[k] != pc {
			fail(fmt.tprintf("interpreted %x, want %x", interpreted[:], want))
		}
	}
	if overlay_runs != 1 {
		fail(fmt.tprintf("overlay function ran %d times, want 1", overlay_runs))
	}

	when cpu.FALLBACK_COUNT {
		for pc in want {
			if n := cpu.fallback_interp[pc]; n != 1 {
				fail(fmt.tprintf("fallback_interp[%x] = %d, want 1", pc, n))
			}
		}
		if len(cpu.fallback_interp) != len(want) {
			fail(fmt.tprintf("fallback_interp has %d targets, want %d", len(cpu.fallback_interp), len(want)))
		}
		jumps := [?]cpu.Jump_Key{{0x80003000, 0x80003010, .Interp}, {0x80003000, 0x80000100, .Call}, {0x80003000, 0, .Return}}
		for k in jumps {
			if n := cpu.fallback_jump[k]; n != 1 {
				fail(fmt.tprintf("fallback_jump[%v] = %d, want 1", k, n))
			}
		}
		if len(cpu.fallback_jump) != len(jumps) {
			fail(fmt.tprintf("fallback_jump has %d keys, want %d", len(cpu.fallback_jump), len(jumps)))
		}
		if n := cpu.dispatch_overlay[0x80002000]; n != 1 || len(cpu.dispatch_overlay) != 1 {
			fail(fmt.tprintf("dispatch_overlay = %v, want 80002000 once", cpu.dispatch_overlay))
		}
		// interp_run is stubbed, so no instructions are counted.
		want_fallback :: "kind\tpc\tfrom\tcount\n" +
			"interp_insns\t-\t-\t0\n" +
			"interp\t80000100\t-\t1\n" +
			"interp\t80001000\t-\t1\n" +
			"interp\t80003010\t-\t1\n" +
			"jump_interp\t80003010\t80003000\t1\n"
		want_dispatch :: "kind\tpc\tfrom\tcount\n" +
			"jump_call\t80000100\t80003000\t1\n" +
			"jump_return\t00000000\t80003000\t1\n" +
			"overlay\t80002000\t-\t1\n"
		fallback, dispatch := cpu.fallback_tsv()
		if fallback != want_fallback {
			fail(fmt.tprintf("fallback table:\n%swant:\n%s", fallback, want_fallback))
		}
		if dispatch != want_dispatch {
			fail(fmt.tprintf("dispatch table:\n%swant:\n%s", dispatch, want_dispatch))
		}
		cpu.fallback_dump()
		fmt.println("ok psx_fallback: gte report set apart; 3 interp entries, 3 jumps, 1 overlay resolve counted; fallback and dispatch tables split")
	} else {
		fmt.println("ok psx_fallback: gte report set apart; 3 interp entries, 1 overlay call")
	}
}
