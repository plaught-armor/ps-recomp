// Native code from the recompiler (its native_arch and native_out options)
// in place of the recompiled Odin: the same functions, as machine code built
// apart from the game. This puts its functions in the dispatch tables; the
// runtime procedures and variables it imports are named in psx/native.
//
// A game calls load_native after registering its recompiled functions and
// before installing hooks, so hooks replace the native functions as they
// would the Odin ones. Setting NATIVE=0 keeps the Odin functions, for
// comparing the two.
package psx

import "core:fmt"
import "core:os"

import "ps:core"
import cpu "cpu"
import gte "gte"
import native "native"

// The native code addresses cpu.state by these offsets
// (recomp/r3000/native.odin).
#assert(offset_of(cpu.Cpu, r) == 0)
#assert(offset_of(cpu.Cpu, hi) == 128)
#assert(offset_of(cpu.Cpu, lo) == 132)
#assert(offset_of(cpu.Cpu, cycles) == 136)

// And cpu.cop0, SR, Cause and EPC, by these.
#assert(offset_of(type_of(cpu.cop0), sr) == 0)
#assert(offset_of(type_of(cpu.cop0), cause) == 4)
#assert(offset_of(type_of(cpu.cop0), epc) == 8)
#assert(cpu.COP0_SR == 12 && cpu.COP0_CAUSE == 13 && cpu.COP0_EPC == 14)

// And gte.state by these.
#assert(offset_of(gte.Gte, v) == 0)
#assert(type_of(gte.state.v) == [3][3]i16)
#assert(offset_of(gte.Gte, rgbc) == 18)
#assert(offset_of(gte.Gte, otz) == 22)
#assert(offset_of(gte.Gte, ir) == 24)
#assert(offset_of(gte.Gte, sxy) == 40)
#assert(offset_of(gte.Gte, sz) == 64)
#assert(offset_of(gte.Gte, rgb) == 80)
#assert(offset_of(gte.Gte, res1) == 92)
#assert(offset_of(gte.Gte, mac) == 96)
#assert(offset_of(gte.Gte, lzcs) == 112)
#assert(offset_of(gte.Gte, lzcr) == 116)
#assert(offset_of(gte.Gte, rt) == 120)
#assert(type_of(gte.state.rt) == [3][3]i32)
#assert(offset_of(gte.Gte, llm) == 156)
#assert(offset_of(gte.Gte, lcm) == 192)
#assert(offset_of(gte.Gte, tr) == 228)
#assert(type_of(gte.state.tr) == [3]i32)
#assert(offset_of(gte.Gte, bk) == 240)
#assert(offset_of(gte.Gte, fc) == 252)
#assert(offset_of(gte.Gte, ofx) == 264)
#assert(offset_of(gte.Gte, ofy) == 268)
#assert(offset_of(gte.Gte, h) == 272)
#assert(offset_of(gte.Gte, dqa) == 276)
#assert(offset_of(gte.Gte, dqb) == 280)
#assert(offset_of(gte.Gte, zsf3) == 284)
#assert(offset_of(gte.Gte, zsf4) == 288)
#assert(offset_of(gte.Gte, flag) == 292)

// Replace the registered functions with the native code in the file at
// path. False, with the reason printed, when it cannot be used; the Odin
// functions then stay.
load_native :: proc(path: string) -> bool {
	if core.env("NATIVE") == "0" {
		return false
	}
	blob, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("native: %s: %v", path, err)
		return false
	}
	defer delete(blob)
	code, msg := core.native_load(blob, native.imports())
	if msg != "" {
		fmt.eprintfln("native: %s: %s", path, msg)
		return false
	}
	defer delete(code.funcs)
	defer delete(code.ovls)
	fn :: proc(code: core.Native_Code, off: u32) -> cpu.Func_Proc {
		return cast(cpu.Func_Proc)rawptr(code.base + uintptr(off))
	}
	// A function the build does not have means the blob is from other code:
	// use none of it rather than a mix.
	ovl_match :: proc(e: cpu.Ovl_Entry, o: core.Native_Ovl) -> bool {
		return e.slot == o.slot && e.id == o.id && e.sig == o.sig
	}
	missing := 0
	for f in code.funcs {
		if !cpu.registered(f.addr) {missing += 1}
	}
	for o in code.ovls {
		found := false
		for e in cpu.dispatch.overlay[o.addr] {
			if ovl_match(e, o) {found = true}
		}
		if !found {missing += 1}
	}
	if missing != 0 {
		fmt.eprintfln("native: %s: %d functions are not registered (built from other code?)", path, missing)
		return false
	}
	for f in code.funcs {
		cpu.hook(f.addr, fn(code, f.off))
	}
	for o in code.ovls {
		for &e in cpu.dispatch.overlay[o.addr] {
			if ovl_match(e, o) {e.fn = fn(code, o.off)}
		}
	}
	fmt.eprintfln("native: %d functions from %s", len(code.funcs) + len(code.ovls), path)
	return true
}
