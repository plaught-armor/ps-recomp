// Learned functions: native code compiled from runs the PS1 interpreter
// learned (recomp/r3000/learned.odin), apart from package psx so that
// tests can load it without its host side.
package psx_native

import "core:fmt"
import "core:os"

import "ps:core"
import cpu "../cpu"

// Register the learned functions in the blob at path (recomp/r3000
// learned.odin): its spans, each a function valid while RAM holds its
// words (cpu.register_learned). False, with the reason printed, when the
// blob cannot be used; none of it is then registered. Its code and pool
// are never freed.
load_learned :: proc(path: string) -> bool {
	blob, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("learned: %s: %v", path, err)
		return false
	}
	defer delete(blob)
	code, msg := core.native_load(blob, imports())
	if msg == "" && (len(code.funcs) != 0 || len(code.ovls) != 0) {
		msg = "not a learned blob"
	}
	for s in code.spans {
		if msg != "" {break}
		if s.kind != .Psx || s.n_ranges != 1 {
			msg = "a span that is not a learned PS1 function"
			break
		}
		r := code.ranges[s.range_first]
		if !cpu.learned_span_ok(r.pc, int(r.n_words)) || s.entry < r.pc || s.entry >= r.pc + 4 * r.n_words {
			msg = "a learned function outside RAM"
		}
	}
	if msg != "" {
		fmt.eprintfln("learned: %s: %s", path, msg)
		if code.base != 0 {core.native_free(&code)}
		return false
	}
	for s in code.spans {
		r := code.ranges[s.range_first]
		fn := cast(cpu.Func_Proc)rawptr(code.base + uintptr(s.off))
		cpu.register_learned(s.entry, r.pc, code.pool[r.at:][:r.n_words], fn)
	}
	fmt.eprintfln("learned: %d functions from %s", len(code.spans), path)
	delete(code.funcs)
	delete(code.ovls)
	delete(code.spans)
	delete(code.ranges)
	return true
}
