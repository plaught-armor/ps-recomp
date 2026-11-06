#+build wasm32
package main

import "core:fmt"
import "core:os"
import "ps:ps2"
import "ps:ps2/mem"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r5900"

// wasm32: the program's functions that no mod hooks (its entry, G_T and
// G_J) as a wasm32 blob, which runs as steps of the FLAT runner
// (ps2/interp_flat.odin flat_resume). G_T's j and G_J's jr to hooked G_A
// leave the native code with a jump out of its blocks, which must reach
// G_A's chain as the interpreter's jumps do. Standalone: the blob's
// functions set the recompiled range (ps2.load_native).
native_program :: proc() {
	Span :: struct {
		at, size: u32,
	}
	spans := [?]Span{{ENTRY, G_A - ENTRY}, {G_T, G_J - G_T}, {G_J, G_C - G_J}}
	a := r5900.native_asm(.Wasm32)
	funcs: [len(spans)]native.Blob_Func
	slow: map[string]int
	defer delete(slow)
	for s, k in spans {
		data := make([]u8, s.size, context.temp_allocator)
		for &b, n in data {b = u8(mem.rd32(s.at + u32(n) &~ 3) >> (8 * (u32(n) & 3)))}
		f := mips.func_make(s.at, s.at + s.size)
		mips.discover(r5900.RULES, {base = s.at, data = data}, f, {})
		funcs[k] = {s.at, r5900.native_func(&a, f, {}, 1, &slow)[0].off}
		free_all(context.temp_allocator)
	}
	blob := native.make_blob(&a, funcs[:], {})
	defer delete(blob)
	if err := os.write_entire_file("native.bin", blob); err != nil {
		fmt.eprintln("FAIL ps2_mod: write native.bin:", err)
		os.exit(1)
	}
	if !ps2.load_native("native.bin") {
		fmt.eprintln("FAIL ps2_mod: the wasm32 blob did not load")
		os.exit(1)
	}
}
