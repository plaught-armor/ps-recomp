package r3000

import "core:fmt"
import "ps:core/learnfile"
import "../mips"
import "../native"

// A run the PS1 interpreter learned (core/learn.odin): entered at entry,
// its code the words from lo.
Learned :: struct {
	entry, lo: u32,
	words:     []u32,
}

// The learned runs compiled to machine code for arch: a blob
// (recomp/native/blob.odin) with no functions, a Psx span per run, valid
// while memory holds the words at lo (psx/native/learned.odin). Each
// run's code is found from its entry within its words; a branch or jump
// out of them (a path the run never took) goes through cpu.jump_unknown,
// which interprets from there. In context.allocator. exact: accesses see
// the cycles up to them (Step.seen); false for the IOP's runs.
//
// interp: the program's functions that may switch threads (its static
// blob's interp list, thread_switches, and play's known switches). On
// wasm32 a run that may is left out, counted in skipped: one entered at an
// interp entry, inside an interp function, or that switches as
// run_switches counts it, until no other run is found to (a run calling one
// left out may switch through it).
learned_blob :: proc(runs: []Learned, arch: native.Arch, exact := true, interp: []native.Blob_Interp = nil, skipped: ^int = nil) -> []u8 {
	a := native_asm(arch)
	funcs := make([]^mips.Func, len(runs))
	defer {
		for f in funcs {mips.func_free(f)}
		delete(funcs)
	}
	for r, k in runs {
		img := mips.Image {
			base  = r.lo,
			data  = ([^]u8)(raw_data(r.words))[:4 * len(r.words)],
			entry = r.entry,
		}
		funcs[k] = mips.func_make(r.entry, r.lo + 4 * u32(len(r.words)), r.lo)
		mips.discover(RULES, img, funcs[k], nil)
	}
	left := make([]bool, len(runs))
	defer delete(left)
	if arch == .Wasm32 {
		s := interp_set_make(interp)
		defer interp_set_free(s)
		for changed := true; changed; {
			changed = false
			for f, k in funcs {
				if left[k] {continue}
				if f.entry in s.entries || interp_overlaps(s, f.start, f.end) || run_switches(f, s) {
					left[k] = true
					changed = true
					interp_set_add(&s, f.entry, f.start, f.end)
				}
			}
		}
	}
	spans := make([dynamic]native.Blob_Span, 0, len(runs))
	defer delete(spans)
	for r, k in runs {
		if left[k] {
			if skipped != nil {skipped^ += 1}
			continue
		}
		ranges := make([]native.Blob_Range, 1)
		ranges[0] = {r.lo, r.words}
		append(&spans, native.Blob_Span{.Psx, r.entry, native_func(&a, funcs[k], nil, CYCLES_PER_INSN, exact), ranges})
	}
	b := native.make_blob(&a, nil, nil, spans[:])
	for s in spans {delete(s.ranges)}
	return b
}

// The PS1 runs of the LEARN file at path that code can stand for
// (learnfile.learn_compilable), each code once, after the file's records are
// compacted as play does (learnfile.learn_compact). Fails when the file cannot
// be read. The words live as long as the program.
learned_read :: proc(path: string) -> []Learned {
	compact, _ := learnfile.learn_compact(mips.read_file(path))
	recs, _ := learnfile.learn_read(compact)
	ok, large, smc := learnfile.learn_compilable(recs[:], .Psx)
	runs := make([]Learned, len(ok))
	for r, k in ok {
		runs[k] = {r.entry, r.lo, r.words}
	}
	fmt.printfln("%s: %d PS1 runs from %d records (not compiled: %d stored into their code, %d large)", path, len(runs), len(recs), smc, large)
	return runs
}
