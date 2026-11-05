// Learned EE functions: native code compiled from runs the EE interpreter
// learned (recomp/r5900/learned.odin). One is never put in the call table:
// only a call the table misses looks it up (interp_call), and it runs only
// while RAM holds its words, compared on every call. Code loaded over them
// (an overlay a game copies in, a DMA, a snapshot load) is interpreted
// instead, and runs native again once the words are back. An entry can
// have several, one per code loaded there. The words are compared on entry
// only; a run whose code changed while it ran (a loader patching its
// caller's calls) is recorded .Smc (core/learn.odin) and never compiled.
package ps2

import "core:fmt"
import "core:os"

import "ps:core"
import cpu "cpu"
import mem "mem"

@(private = "file")
Learned_Fn :: struct {
	lo:    u32,
	words: []u32,
	fn:    cpu.Func_Proc,
}

// By entry. Host state: a snapshot never holds it, and every call checks
// the words, so none needs restoring.
@(private = "file")
learned_fns: map[u32][dynamic]Learned_Fn

// The learned function at entry whose words RAM holds now, else nil.
learned_find :: proc(entry: u32) -> cpu.Func_Proc #no_bounds_check {
	fns, ok := learned_fns[entry]
	if !ok {return nil}
	for &l in fns {
		n := len(l.words)
		cpu.learned_words += u64(n)
		if string(mem.ram[l.lo:][:4 * n]) == string(([^]u8)(raw_data(l.words))[:4 * n]) {
			cpu.learned_calls += 1
			return l.fn
		}
	}
	cpu.learned_stale += 1
	return nil
}

// Register the learned functions in the blob at path: its spans, each a
// function valid while RAM holds its words. False, with the reason printed,
// when the blob cannot be used; none of it is then registered. Its code and
// pool are never freed.
load_learned :: proc(path: string) -> bool {
	if mem.ram_base == nil {
		fmt.eprintln("learned: load_learned comes after init, which maps RAM")
		return false
	}
	blob, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("learned: %s: %v", path, err)
		return false
	}
	defer delete(blob)
	code, msg := core.native_load(blob, native_imports())
	if msg == "" && (len(code.funcs) != 0 || len(code.ovls) != 0) {
		msg = "not a learned blob"
	}
	for s in code.spans {
		if msg != "" {break}
		if s.kind != .Ee || s.n_ranges != 1 {
			msg = "a span that is not a learned EE function"
			break
		}
		r := code.ranges[s.range_first]
		if r.pc & 3 != 0 || r.n_words == 0 || r.pc >= mem.RAM_SIZE || r.n_words > (mem.RAM_SIZE - r.pc) / 4 || s.entry < r.pc || s.entry >= r.pc + 4 * r.n_words {
			msg = "a learned function outside RAM"
		}
	}
	if msg != "" {
		fmt.eprintfln("learned: %s: %s", path, msg)
		if code.base != 0 {core.native_free(&code)}
		return false
	}
	if learned_fns == nil {learned_fns = make(map[u32][dynamic]Learned_Fn, core.long_allocator())}
	for s in code.spans {
		r := code.ranges[s.range_first]
		fns := learned_fns[s.entry]
		if fns == nil {fns = make([dynamic]Learned_Fn, core.long_allocator())}
		append(&fns, Learned_Fn{r.pc, code.pool[r.at:][:r.n_words], cast(cpu.Func_Proc)rawptr(code.base + uintptr(s.off))})
		learned_fns[s.entry] = fns
	}
	cpu.learned_loaded += len(code.spans)
	fmt.eprintfln("learned: %d EE functions from %s", len(code.spans), path)
	delete(code.funcs)
	delete(code.ovls)
	delete(code.spans)
	delete(code.ranges)
	return true
}
