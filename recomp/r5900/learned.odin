package r5900

import "../mips"
import "../native"

// A run the EE interpreter learned (core/learn.odin): entered at entry,
// its code the words from lo.
Learned :: struct {
	entry, lo: u32,
	words:     []u32,
}

// The learned runs compiled to machine code for arch: a blob
// (recomp/native/blob.odin) with no functions, an Ee span per run, valid
// while RAM holds the words at lo (ps2/learned.odin). Each run's code is
// found from its entry within its words; a branch or jump out of them (a
// path the run never took) goes through cpu.jump_unknown, and every call
// through cpu.call, so code outside the words is looked up as it is then;
// each `jr $ra` calls ps2.learned_jr before it returns (native_func).
// Two runs at one entry with other words are two spans. A run native_func
// cannot lower for arch (nil: wasm32's exact lowering) gets no span and
// stays interpreted; skipped counts them. In context.allocator.
learned_blob :: proc(runs: []Learned, arch: native.Arch) -> (blob: []u8, skipped: int) {
	a := native_asm(arch)
	spans := make([dynamic]native.Blob_Span, 0, len(runs))
	defer delete(spans)
	slow: map[string]int
	defer delete(slow)
	for r in runs {
		img := mips.Image {
			base  = r.lo,
			data  = ([^]u8)(raw_data(r.words))[:4 * len(r.words)],
			entry = r.entry,
		}
		f := mips.func_make(r.entry, r.lo + 4 * u32(len(r.words)), r.lo)
		mips.discover(RULES, img, f, nil)
		fs := native_func(&a, f, nil, CYCLES_PER_INSN, &slow, learned = true)
		if fs == nil {
			skipped += 1
		} else {
			ranges := make([]native.Blob_Range, 1)
			ranges[0] = {r.lo, r.words}
			append(&spans, native.Blob_Span{.Ee, r.entry, fs[0].off, ranges})
		}
		free_all(context.temp_allocator)
	}
	blob = native.make_blob(&a, nil, nil, spans[:])
	for s in spans {delete(s.ranges)}
	return blob, skipped
}

// The mods' functions (each one run, entered at its first word) compiled to
// machine code for arch, as learned_blob, but with a jal from one to another
// a direct call (and a jal to MOD_ORIGINAL one to ps2.mod_call_original):
// their words cannot change once loaded (a store into mod
// code is fatal), so no lookup is needed to find the code standing for them.
// A function lower cannot lower gets no span and no label: calls to it go
// through cpu.call and the interpreter. skipped counts them. In
// context.allocator.
mods_blob :: proc(funcs: []Learned, arch: native.Arch) -> (blob: []u8, skipped: int) {
	// wasm32 code calls through the runner, never direct.
	if arch == .Wasm32 {return learned_blob(funcs, arch)}
	a := native_asm(arch)
	// A label only for what lowers, so every label is bound below.
	labels := make(map[u32]native.Label)
	defer delete(labels)
	for r in funcs {
		f := mods_func(r)
		if lower(f, CYCLES_PER_INSN, quiet = true) != nil {labels[r.entry] = native.new_label(&a)}
		free_all(context.temp_allocator)
	}
	spans := make([dynamic]native.Blob_Span, 0, len(funcs))
	defer delete(spans)
	slow: map[string]int
	defer delete(slow)
	for r in funcs {
		f := mods_func(r)
		fs := native_func(&a, f, nil, CYCLES_PER_INSN, &slow, labels, mods = true)
		assert((fs != nil) == (r.entry in labels))
		if fs == nil {
			skipped += 1
		} else {
			ranges := make([]native.Blob_Range, 1)
			ranges[0] = {r.lo, r.words}
			append(&spans, native.Blob_Span{.Ee, r.entry, fs[0].off, ranges})
		}
		free_all(context.temp_allocator)
	}
	blob = native.make_blob(&a, nil, nil, spans[:])
	for s in spans {delete(s.ranges)}
	return blob, skipped
}

// The function r is, discovered (temp allocator).
@(private = "file")
mods_func :: proc(r: Learned) -> ^Func {
	img := mips.Image {
		base  = r.lo,
		data  = ([^]u8)(raw_data(r.words))[:4 * len(r.words)],
		entry = r.entry,
	}
	f := mips.func_make(r.entry, r.lo + 4 * u32(len(r.words)), r.lo)
	mips.discover(RULES, img, f, nil)
	return f
}
