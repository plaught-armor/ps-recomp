package r3000

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
// which interprets from there. In context.allocator.
learned_blob :: proc(runs: []Learned, arch: native.Arch) -> []u8 {
	a := native.make_asm(arch, native_ram(), NATIVE_CACHED[:])
	spans := make([]native.Blob_Span, len(runs))
	defer delete(spans)
	for r, k in runs {
		img := mips.Image {
			base  = r.lo,
			data  = ([^]u8)(raw_data(r.words))[:4 * len(r.words)],
			entry = r.entry,
		}
		f := mips.func_make(r.entry, r.lo + 4 * u32(len(r.words)), r.lo)
		mips.discover(RULES, img, f, nil)
		ranges := make([]native.Blob_Range, 1)
		ranges[0] = {r.lo, r.words}
		spans[k] = {.Psx, r.entry, native_func(&a, f, nil, CYCLES_PER_INSN), ranges}
	}
	b := native.make_blob(&a, nil, nil, spans)
	for s in spans {delete(s.ranges)}
	return b
}
