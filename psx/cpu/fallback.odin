// FALLBACK_COUNT: how often control leaves recompiled code, by target,
// reported when the port exits. Built with -define:FALLBACK_COUNT=true;
// without it the counters compile away.
package psx_cpu

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "ps:core"

FALLBACK_COUNT :: #config(FALLBACK_COUNT, false)

// What jump_unknown did with a jump off its function's block labels.
Jump_Outcome :: enum u8 {
	Return, // to the caller's return address
	Call,   // to a known function, or outside the function
	Interp,
}

@(private = "file", rodata)
JUMP_KINDS := [Jump_Outcome]string{.Return = "jump_return", .Call = "jump_call", .Interp = "jump_interp"}

Jump_Key :: struct {
	func, pc: u32,
	outcome:  Jump_Outcome,
}

// interp_run entries by start pc, and the instructions the interpreter ran
// (delay slots included; psx/interp.odin counts them).
fallback_interp: map[u32]u64
fallback_interp_insns: u64
// jump_unknown calls by function, target and outcome.
fallback_jump: map[Jump_Key]u64
// call_slow targets resolved to a resident overlay function.
fallback_overlay: map[u32]u64

@(private = "file")
Row :: struct {
	kind:     string,
	pc, from: u32,
	n:        u64,
}

// Totals on stderr, and every counter as fallback.tsv in the DUMP directory
// when one is set: kind, pc, from (the jumping function), count.
fallback_dump :: proc() {
	rows := make([dynamic]Row, context.temp_allocator)
	jumps: [Jump_Outcome]u64
	interp, overlay: u64
	for pc, n in fallback_interp {
		append(&rows, Row{"interp", pc, 0, n})
		interp += n
	}
	for k, n in fallback_jump {
		append(&rows, Row{JUMP_KINDS[k.outcome], k.pc, k.func, n})
		jumps[k.outcome] += n
	}
	for pc, n in fallback_overlay {
		append(&rows, Row{"overlay", pc, 0, n})
		overlay += n
	}
	fmt.eprintfln(
		"fallback: %d interp entries (%d instructions), %d unlabelled jumps interpreted, %d returned, %d called, %d overlay resolves",
		interp,
		fallback_interp_insns,
		jumps[.Interp],
		jumps[.Return],
		jumps[.Call],
		overlay,
	)
	dir := core.dump_dir()
	if dir == "" {
		return
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {
		if a.kind != b.kind {return a.kind < b.kind}
		if a.n != b.n {return a.n > b.n}
		return a.pc < b.pc
	})
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "kind\tpc\tfrom\tcount")
	fmt.sbprintfln(&b, "interp_insns\t-\t-\t%d", fallback_interp_insns)
	for r in rows {
		from := r.from == 0 ? "-" : fmt.tprintf("%08x", r.from)
		fmt.sbprintfln(&b, "%s\t%08x\t%s\t%d", r.kind, r.pc, from, r.n)
	}
	name := fmt.tprintf("%s/fallback.tsv", dir)
	if err := os.write_entire_file(name, b.buf[:]); err != nil {
		fmt.eprintln("fallback: write failed:", name, err)
	}
}
