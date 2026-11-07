// The mods' native code: a blob of the mods' EE functions (play's --mods
// child compiles it with recomp/r5900's mods_blob), each standing for its
// function in the mod region (mem.mod_native_set). A hook calls its
// function's code directly (mod_native_resolve); another call to one
// misses the call table (the region is outside the recompiled range) and
// reaches mod_interp_hook, which runs it; a call from one mod function to
// another is a direct call in the blob.
//
// On wasm32 each function's code is a step of the FLAT runner
// (interp_flat.odin), which looks it up at the pc it goes on at
// (flat_lookup): every word of the function stands for it, and a pc no
// block starts at leaves at once to be interpreted. Hooks reach it through
// the runner, never as a direct call.
package ps2

import "core:fmt"
import "core:os"

import "ps:core"
import cpu "cpu"
import mem "mem"

// Load the mods' functions in the blob at path, once the mods are in the
// region (mods_load). Each span is one mod function there, whole and
// entered at its first word, its words those the region holds: a blob for
// other mods (a stale or edited file) is refused whole. why, when the blob
// cannot be used, says why (temp allocator), and is not printed: the
// caller removes the blob's key first. None of it is then loaded, and the
// mods are interpreted. Its code is never freed.
// Whether mods' native code can run: not under FLAT, but for its wasm32
// steps.
MODS_NATIVE :: !core.FLAT || ODIN_ARCH == .wasm32

load_mods :: proc(path: string) -> (why: string) {
	if mem.mod_ram == nil {
		return fmt.tprintf("mods: %s: no mods in the region (load_mods comes after mods_load)", path)
	}
	blob, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return fmt.tprintf("mods: %s: %v", path, err)
	}
	defer delete(blob)
	code, msg := core.native_load(blob, native_imports())
	if msg == "" && (len(code.funcs) != 0 || len(code.ovls) != 0) {
		msg = "not a mods blob"
	}
	for s in code.spans {
		if msg != "" {break}
		if s.kind != .Ee || s.n_ranges != 1 {
			msg = "a span that is not a mod function"
			break
		}
		// The span must be one whole mod function, entered at its start,
		// with the words the region holds.
		r := code.ranges[s.range_first]
		n := mem.mod_func_words(r.pc)
		if s.entry != r.pc || n == 0 || r.n_words != n || !mod_words_ok(r.pc, code.pool[r.at:][:r.n_words]) {
			msg = fmt.tprintf("its function at %08x is not the mods' code", s.entry)
		}
	}
	if msg != "" {
		if code.base != 0 {core.native_free(&code)}
		return fmt.tprintf("mods: %s: %s", path, msg)
	}
	for s in code.spans {
		fn := cast(cpu.Func_Proc)rawptr(code.base + uintptr(s.off))
		when core.FLAT {
			r := code.ranges[s.range_first]
			for k in 0 ..< r.n_words {mem.mod_native_set(r.pc + 4 * k, fn)}
		} else {
			mem.mod_native_set(s.entry, fn)
		}
	}
	when core.FLAT {
		flat_native_on = true
	} else {
		mod_native_resolve()
	}
	fmt.eprintfln("mods: %d functions from %s", len(code.spans), path)
	delete(code.funcs)
	delete(code.ovls)
	delete(code.spans)
	delete(code.ranges)
	delete(code.pool)
	return ""
}

// Whether the region holds words at lo (a mod function's first word, so
// in the region).
@(private = "file")
mod_words_ok :: proc(lo: u32, words: []u32) -> bool {
	off := (lo & 0x0fff_ffff) - mem.MOD_BASE
	if lo & 3 != 0 || u64(off) + 4 * u64(len(words)) > u64(len(mem.mod_ram)) {return false}
	for w, i in words {
		if u32((^u32le)(&mem.mod_ram[off + u32(i) * 4])^) != w {return false}
	}
	return true
}
