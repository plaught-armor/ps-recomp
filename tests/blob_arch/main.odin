// The blob arch word: a header is valid only with this build's arch, so a
// native build refuses arch 0 and the wasm arch (core.NATIVE_ARCH_WASM32,
// which has no emitter), and a wasm build refuses every machine-code arch.
// native_load refuses another arch's header before it maps anything, which
// on wasm (no executable memory) would panic. Pure: no files, no SDL, so it
// builds and runs for wasi_wasm32 as well as natively.
package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "ps:core"

failed: bool

check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL %s (line %d)", what, loc.line)
		failed = true
	}
}

// A blob header of this format with arch word `arch`, counts all 0.
header :: proc(arch: u32) -> []u8 {
	b := make([]u8, core.NATIVE_HEADER, context.temp_allocator)
	endian.put_u32(b[0:], .Little, core.NATIVE_MAGIC)
	endian.put_u32(b[4:], .Little, core.NATIVE_VERSION)
	endian.put_u32(b[8:], .Little, arch)
	return b
}

main :: proc() {
	when ODIN_ARCH == .wasm32 {
		check(core.NATIVE_ARCH == core.NATIVE_ARCH_WASM32, "a wasm build's arch is wasm32's")
		check(core.NATIVE_ARCH_NAME == "wasm32", "a wasm build's arch name")
	} else {
		check(core.NATIVE_ARCH != core.NATIVE_ARCH_WASM32, "a native build's arch is not wasm32's")
	}
	for arch in u32(0) ..= 5 {
		want := arch == core.NATIVE_ARCH
		check(core.blob_valid(header(arch)) == want, fmt.tprintf("arch %d valid: want %v", arch, want))
		if want {continue}
		_, err := core.native_load(header(arch), nil)
		check(strings.has_prefix(err, "built for arch"), fmt.tprintf("arch %d load: %q", arch, err))
	}
	fmt.printfln("arch %d (%s)", core.NATIVE_ARCH, core.NATIVE_ARCH_NAME)
	if failed {os.exit(1)}
	fmt.println("ok blob_arch")
}
