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
// through cpu.call, so code outside the words is looked up as it is then.
// Two runs at one entry with other words are two spans. In
// context.allocator.
learned_blob :: proc(runs: []Learned, arch: native.Arch) -> []u8 {
	a := native.make_asm(arch, native_ram())
	spans := make([]native.Blob_Span, len(runs))
	defer delete(spans)
	slow: map[string]int
	defer delete(slow)
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
		spans[k] = {.Ee, r.entry, native_func(&a, f, nil, CYCLES_PER_INSN, &slow)[0], ranges}
		free_all(context.temp_allocator)
	}
	b := native.make_blob(&a, nil, nil, spans)
	for s in spans {delete(s.ranges)}
	return b
}
