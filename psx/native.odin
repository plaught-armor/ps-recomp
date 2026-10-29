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
import native "native"

// The native code addresses cpu.state by these offsets
// (recomp/r3000/native.odin).
#assert(offset_of(cpu.Cpu, r) == 0)
#assert(offset_of(cpu.Cpu, hi) == 128)
#assert(offset_of(cpu.Cpu, lo) == 132)
#assert(offset_of(cpu.Cpu, cycles) == 136)

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
