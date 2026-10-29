// FALLBACK_COUNT: how often control leaves recompiled code, by target,
// reported when the port exits: interpreter work (the fallback) apart from
// dispatch that stays in recompiled code. Built with -define:FALLBACK_COUNT=true;
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

// Interpreter work, the fallback proper: interp_run entries by start pc, and
// the instructions the interpreter ran (delay slots included; psx/interp.odin
// counts them).
fallback_interp: map[u32]u64
fallback_interp_insns: u64
// jump_unknown calls by function, target and outcome. Only .Interp is a
// fallback; .Return and .Call are dispatch.
fallback_jump: map[Jump_Key]u64
// Dispatch, not fallback: call_slow targets resolved to a resident overlay
// function.
dispatch_overlay: map[u32]u64

@(private = "file")
Row :: struct {
	kind:     string,
	pc, from: u32,
	n:        u64,
}

// Totals on stderr, two lines: "fallback:" counts interpreter work only,
// "dispatch:" the ways out of a function that reach recompiled code (or a
// BIOS vector) without the interpreter. With a DUMP directory, every
// counter as rows too (fallback_tsv).
fallback_dump :: proc() {
	jumps: [Jump_Outcome]u64
	interp, overlay: u64
	for _, n in fallback_interp {interp += n}
	for k, n in fallback_jump {jumps[k.outcome] += n}
	for _, n in dispatch_overlay {overlay += n}
	fmt.eprintfln(
		"fallback: %d interp entries (%d instructions), %d unlabelled jumps interpreted",
		interp,
		fallback_interp_insns,
		jumps[.Interp],
	)
	fmt.eprintfln(
		"dispatch: %d unlabelled jumps returned, %d called, %d overlay resolves",
		jumps[.Return],
		jumps[.Call],
		overlay,
	)
	dir := core.dump_dir()
	if dir == "" {
		return
	}
	fallback, dispatch := fallback_tsv()
	for f in ([?][2]string{{"fallback.tsv", fallback}, {"dispatch.tsv", dispatch}}) {
		name := fmt.tprintf("%s/%s", dir, f[0])
		if err := os.write_entire_file(name, transmute([]u8)f[1]); err != nil {
			fmt.eprintln("fallback: write failed:", name, err)
		}
	}
}

// The counters as two tables (temp allocator), columns kind, pc, from (the
// jumping function), count; rows by kind, then count down, pc, from.
// fallback: interp_insns, then interp and jump_interp rows. dispatch:
// jump_call, jump_return and overlay rows.
fallback_tsv :: proc() -> (fallback, dispatch: string) {
	fb := make([dynamic]Row, context.temp_allocator)
	dp := make([dynamic]Row, context.temp_allocator)
	for pc, n in fallback_interp {
		append(&fb, Row{"interp", pc, 0, n})
	}
	for k, n in fallback_jump {
		append(k.outcome == .Interp ? &fb : &dp, Row{JUMP_KINDS[k.outcome], k.pc, k.func, n})
	}
	for pc, n in dispatch_overlay {
		append(&dp, Row{"overlay", pc, 0, n})
	}
	return tsv(fb[:], fmt.tprintf("interp_insns\t-\t-\t%d\n", fallback_interp_insns)), tsv(dp[:], "")
}

@(private = "file")
tsv :: proc(rows: []Row, first: string) -> string {
	slice.sort_by(rows, proc(a, b: Row) -> bool {
		if a.kind != b.kind {return a.kind < b.kind}
		if a.n != b.n {return a.n > b.n}
		if a.pc != b.pc {return a.pc < b.pc}
		return a.from < b.from
	})
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "kind\tpc\tfrom\tcount")
	strings.write_string(&b, first)
	for r in rows {
		from := r.from == 0 ? "-" : fmt.tprintf("%08x", r.from)
		fmt.sbprintfln(&b, "%s\t%08x\t%s\t%d", r.kind, r.pc, from, r.n)
	}
	return strings.to_string(b)
}
