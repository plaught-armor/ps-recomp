// The mods' native code: a blob of the mods' functions (play's --mods
// child compiles it with recomp/r3000's learned_blob), each standing for its
// function in the mod region (cpu.mod_native_set).
package psx_native

import "core:fmt"
import "core:os"

import "ps:core"
import cpu "../cpu"

// Load the mods' functions in the blob at path, once the mods are in the
// region (cpu.mod_ram_load). Each span is one mod function there, whole
// and entered at its first word, its words those the region holds: a blob
// for other mods (a stale or edited file) is refused whole. False, with
// the reason printed, when the blob cannot be used; none of it is then
// loaded, and the mods are interpreted. Its code is never freed.
load_mods :: proc(path: string) -> bool {
	blob, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("mods: %s: %v", path, err)
		return false
	}
	defer delete(blob)
	m := imports()
	m["io.run_events"] = u64(uintptr(rawptr(run_events)))
	code, msg := core.native_load(blob, m)
	if msg == "" && (len(code.funcs) != 0 || len(code.ovls) != 0) {
		msg = "not a mods blob"
	}
	for s in code.spans {
		if msg != "" {break}
		if s.kind != .Psx || s.n_ranges != 1 {
			msg = "a span that is not a mod function"
			break
		}
		// The span must be one whole mod function, entered at its start,
		// with the words the region holds.
		r := code.ranges[s.range_first]
		n := cpu.mod_func_words(r.pc)
		if s.entry != r.pc || n == 0 || r.n_words != n || !mod_words_ok(r.pc, code.pool[r.at:][:r.n_words]) {
			msg = fmt.tprintf("its function at %08x is not the mods' code", s.entry)
		}
	}
	if msg != "" {
		fmt.eprintfln("mods: %s: %s; the mods are interpreted", path, msg)
		if code.base != 0 {core.native_free(&code)}
		return false
	}
	for s in code.spans {
		cpu.mod_native_set(s.entry, cast(cpu.Func_Proc)rawptr(code.base + uintptr(s.off)))
	}
	fmt.eprintfln("mods: %d functions from %s", len(code.spans), path)
	delete(code.funcs)
	delete(code.ovls)
	delete(code.spans)
	delete(code.ranges)
	delete(code.pool)
	return true
}

// Whether the region holds words at lo.
@(private = "file")
mod_words_ok :: proc(lo: u32, words: []u32) -> bool {
	off := (lo & 0x1fff_ffff) - cpu.MOD_BASE
	if lo & 3 != 0 || u64(off) + 4 * u64(len(words)) > u64(len(cpu.mod_ram)) {return false}
	for w, i in words {
		if u32((^u32le)(&cpu.mod_ram[off + u32(i) * 4])^) != w {return false}
	}
	return true
}
