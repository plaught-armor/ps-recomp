// LEARN under FLAT (psx/cpu/interp_flat.odin), on a file in the OS temp
// directory, for a FLAT build: natively with -define:PS_FLAT=true.
//
//   - A run still on the shadow stack when its flat run stops (a thread
//     switch, flat_block) stays open across the stop: nothing is written
//     while it is stopped, the run another thread runs meanwhile is written
//     when it returns, and the stopped runs are written once each when they
//     return after the resume, their ranges covering the words fetched on
//     both sides of the stop, a store the other thread made into one of
//     them marking it .Smc and not the callee whose range it misses.
//   - A run from code a standalone blob left to the interpreter
//     (cpu.flat_interp: an entry, or inside a range) is not written.
//   - A run that never returns (its flat run stopped and never resumed) is
//     written .Open at the report, the caller with the words it fetched and
//     the callee begun at the stop with its entry alone.
//
// The directory is removed at the end whether the test passes or fails.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "ps:core"
import cpu "ps:psx/cpu"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL psx_flat_learn: %s (line %d)", what, loc.line)
		failed += 1
	}
}

// addu s1, ra, zero; jal G; nop; addiu v0, v0, 1; jr s1; nop.
@(private = "file")
F :: 0x80010000
// addiu v0, zero, 5; jr ra; nop.
@(private = "file")
G :: 0x80011000
// The other thread: lui t0, 0x8001; lw t1, 0xc(t0); nop; sw t1, 0xc(t0)
// (F's addiu, stored back as it was); jr ra; nop.
@(private = "file")
H :: 0x80012000
// As F, without the addiu: addu s1, ra, zero; jal G; nop; jr s1; nop.
@(private = "file")
K :: 0x80013000
// The return address a flat run's base returns to, ending it.
@(private = "file")
RA :: 0x80001234

// Where the next events check stops the run (flat_block), 0 none.
@(private = "file")
stop_at: u32

@(private = "file")
put :: proc(at: u32, code: []u32) {
	for w, k in code {
		(^u32le)(&cpu.ram[(at & 0x1fffff) + 4 * u32(k)])^ = u32le(w)
	}
}

@(private = "file")
jal :: proc(t: u32) -> u32 {return 0x0c000000 | (t >> 2) & 0x3ffffff}

// Start a flat run of entry from RA on x, run it to its end (true) or stop.
@(private = "file")
start :: proc(x: ^cpu.Flat_Ctx, entry: u32) -> bool {
	when core.FLAT {
		cpu.state.r[31] = RA
		cpu.flat_start(x, entry)
		return cpu.flat_run(x)
	} else {
		return false
	}
}

@(private = "file")
Want :: struct {
	entry: u32,
	flags: core.Learn_Flags,
	n:     int,
}

// The records in path, by entry then flags, against want (in that order).
@(private = "file")
check_file :: proc(path: string, want: []Want, what: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		check(false, fmt.tprintf("%s: cannot read the records: %v", what, err))
		return
	}
	recs, bad := core.learn_read(data)
	check(bad == 0, fmt.tprintf("%s: %d bad records", what, bad))
	slice.sort_by(recs[:], proc(a, b: core.Learn_Record) -> bool {
		if a.entry != b.entry {return a.entry < b.entry}
		return transmute(u8)a.flags < transmute(u8)b.flags
	})
	if len(recs) != len(want) {
		check(false, fmt.tprintf("%s: %d records, want %d", what, len(recs), len(want)))
		for r in recs {fmt.eprintfln("  %08x %v n %d", r.entry, r.flags, len(r.words))}
		return
	}
	for r, i in recs {
		w := want[i]
		ok := r.cpu == .Psx && r.entry == w.entry && r.lo == w.entry && r.flags == w.flags && len(r.words) == w.n
		for v, j in r.words {
			ok &&= v == cpu.lw(r.lo + 4 * u32(j))
		}
		check(ok, fmt.tprintf("%s: record %d is %08x %v lo %08x n %d, want %08x %v n %d", what, i, r.entry, r.flags, r.lo, len(r.words), w.entry, w.flags, w.n))
	}
}

main :: proc() {
	when !core.FLAT {
		fmt.eprintln("tests/psx_flat_learn is for a FLAT build: -define:PS_FLAT=true")
		os.exit(2)
	}
	tmp, err := os.make_directory_temp("", "ps_flat_learn_test_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL psx_flat_learn: no temp directory:", err)
		os.exit(1)
	}
	path, _ := filepath.join({tmp, "learn.bin"}, context.allocator)
	run(path)
	os.remove_all(tmp)
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok psx_flat_learn: a run on the shadow stack stays open across a stop and is written once when it returns, a store made meanwhile marking it; a run that never returns is written .Open at the report; code left to the interpreter is not written")
}

@(private = "file")
run :: proc(path: string) {
	cpu.register_funcs({}) // no recompiled code: every function interpreted
	put(F, {0x03e08821, jal(G), 0, 0x24420001, 0x02200008, 0})
	put(G, {0x24020005, 0x03e00008, 0})
	put(H, {0x3c088001, 0x8d09000c, 0, 0xad09000c, 0x03e00008, 0})
	put(K, {0x03e08821, jal(G), 0, 0x02200008, 0})
	core.learn_cpu(.Psx, &cpu.state.cycles, cpu.CYCLES_PER_INSN, proc(a: u32) -> u32 {return cpu.lw(a)}, cpu.RAM_SIZE, true)
	check(core.learn_open_path(path, {.Psx}), "open")
	// Every check is due; the one at stop_at stops the run.
	cpu.next_event = 0
	cpu.run_events = proc() {
		when core.FLAT {
			if stop_at != 0 && cpu.flat_cur != nil && cpu.flat_cur.pc == stop_at {
				stop_at = 0
				cpu.flat_block("a test's thread switch")
			}
		}
	}

	x, y, z: cpu.Flat_Ctx
	stop_at = G
	check(!start(&x, F), "F stops at G's entry")
	check_file(path, {}, "F stopped")
	// The other thread runs on its own registers, as a thread switch
	// saves and restores them: F's $ra (G's return) must be there again
	// as F goes on, since a `jr $ra` is a plain jump to it.
	saved := cpu.state.r
	check(start(&y, H), "H ends")
	check_file(path, {{H, {}, 6}}, "H returned")
	cpu.state.r = saved
	when core.FLAT {
		check(cpu.flat_run(&x), "F ends after the resume")
	}
	check(cpu.state.r[2] == 6, fmt.tprintf("v0 %d after F, want 6", cpu.state.r[2]))
	check_file(path, {{F, {.Smc}, 6}, {G, {}, 3}, {H, {}, 6}}, "F returned")

	// Code the blob left to the interpreter is not noted: H's entry, and
	// G inside a range, so F alone is written again.
	when core.FLAT {
		cpu.flat_interp = {{H, H, H}, {G - 4, G - 8, G + 4}}
		check(start(&y, H), "H ends, left to the interpreter")
		check(start(&y, F), "F ends, its callee G left to the interpreter")
		cpu.flat_interp = nil
	}
	check_file(path, {{F, {}, 6}, {F, {.Smc}, 6}, {G, {}, 3}, {H, {}, 6}}, "left to the interpreter")

	stop_at = G
	check(!start(&z, K), "K stops at G's entry")
	core.learn_report()
	check_file(path, {{F, {}, 6}, {F, {.Smc}, 6}, {G, {}, 3}, {G, {.Open}, 1}, {H, {}, 6}, {K, {.Open}, 3}}, "report")
	when core.FLAT {
		cpu.flat_free(&x)
		cpu.flat_free(&y)
		cpu.flat_free(&z)
	}
}
