// Learned functions: native code compiled from runs the R3000 interpreter
// learned (recomp/r3000/learned.odin), the PS1's or a PS2's IOP, apart
// from package psx so that tests and ps2 can load it without its host side.
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
	return load_learned_blob(blob, path)
}

// load_learned of a blob in memory, which it does not keep; name stands
// for it in the messages.
load_learned_blob :: proc(blob: []u8, name: string) -> bool {
	path := name
	// Through the hook, which is the IOP's when the R3000 is the IOP
	// (ps2/iop/iop_cpu.odin) and io.run_events for the PS1.
	m := imports()
	m["io.run_events"] = u64(uintptr(rawptr(run_events)))
	code, msg := core.native_load(blob, m)
	if msg == "" && (len(code.funcs) != 0 || len(code.ovls) != 0) {
		msg = "not a learned blob"
	}
	for s in code.spans {
		if msg != "" {break}
		if s.kind != .Psx || s.n_ranges != 1 {
			msg = "a span that is not a learned R3000 function"
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

@(private)
run_events :: proc() {cpu.run_events()}
