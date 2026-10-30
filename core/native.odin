// Native code from the recompiler, the file recomp/native/blob.odin writes:
// its code mapped executable with each import slot filled by name. The
// console package (psx/native.odin) names the imports and puts the
// functions in its dispatch tables.
package core

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Native_Func :: struct {
	addr, off: u32,
}

Native_Ovl :: struct {
	addr, slot, id: u32,
	sig:            [4]u32,
	off:            u32,
}

Native_Code :: struct {
	base:  uintptr, // a function is at base + off
	size:  int, // bytes of code at base, for unmap_code
	funcs: []Native_Func,
	ovls:  []Native_Ovl,
}

@(private)
NATIVE_MAGIC :: 0x4e525350 // "PSRN"
@(private)
NATIVE_VERSION :: 1

// The blob arch this build runs (recomp/native Arch), and its name there.
NATIVE_ARCH :: 3 when ODIN_ARCH == .arm64 else (2 when ODIN_OS == .Windows else 1)
NATIVE_ARCH_NAME :: "arm64" when ODIN_ARCH == .arm64 else ("x64_win" when ODIN_OS == .Windows else "x64_sysv")

// Executable memory is mapped in 64K units, a page on every host.
@(private)
code_size :: proc(n: int) -> int {
	return (n + 0xffff) &~ 0xffff
}

// Map the blob's code; `imports` gives each slot's value (an address or a
// constant). The tables are allocated with context.allocator.
native_load :: proc(blob: []u8, imports: map[string]u64) -> (code: Native_Code, err: string) {
	at := 0
	word :: proc(blob: []u8, at: ^int) -> (u32, bool) {
		if at^ + 4 > len(blob) {return 0, false}
		b := blob[at^:]
		at^ += 4
		return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24, true
	}
	h: [8]u32
	for &v in h {
		ok: bool
		if v, ok = word(blob, &at); !ok {return {}, "short header"}
	}
	magic, version, arch, n_imports, n_funcs, n_ovls, size, imports_at := h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]
	if magic != NATIVE_MAGIC || version != NATIVE_VERSION {
		return {}, "not a native code file of this version"
	}
	if arch != NATIVE_ARCH {
		return {}, fmt.tprintf("built for arch %d, this host runs %d", arch, NATIVE_ARCH)
	}
	slots := make([]string, n_imports, context.temp_allocator)
	for &name in slots {
		if at + 2 > len(blob) {return {}, "short import table"}
		n := int(blob[at]) | int(blob[at + 1]) << 8
		at += 2
		if at + n > len(blob) {return {}, "short import table"}
		name = string(blob[at:at + n])
		at += n
	}
	if int(n_funcs) * 8 + int(n_ovls) * 32 + int(size) != len(blob) - at {
		return {}, "bad table sizes"
	}
	if imports_at % 16 != 0 || int(imports_at) + 8 * int(n_imports) != int(size) {
		return {}, "bad import slots"
	}
	defer if err != "" {
		delete(code.funcs)
		delete(code.ovls)
		code = {}
	}
	code.funcs = make([]Native_Func, n_funcs)
	for &f in code.funcs {
		f.addr, _ = word(blob, &at)
		f.off, _ = word(blob, &at)
		if f.off >= imports_at {return code, "function outside the code"}
	}
	code.ovls = make([]Native_Ovl, n_ovls)
	for &o in code.ovls {
		o.addr, _ = word(blob, &at)
		o.slot, _ = word(blob, &at)
		o.id, _ = word(blob, &at)
		for &w in o.sig {w, _ = word(blob, &at)}
		o.off, _ = word(blob, &at)
		if o.off >= imports_at {return code, "function outside the code"}
	}
	text := make([]u8, size)
	defer delete(text)
	copy(text, blob[at:])
	for name, k in slots {
		v, ok := imports[name]
		if !ok {return code, fmt.tprintf("the runtime has no %s", name)}
		p := text[int(imports_at) + 8 * k:]
		for b in 0 ..< 8 {p[b] = u8(v >> (8 * uint(b)))}
	}
	code.base = uintptr(map_code(text))
	code.size = len(text)
	when ODIN_OS == .Linux {
		if env("PERF_MAP") == "1" {perf_map(code, int(imports_at))}
	}
	return code, ""
}

// /tmp/perf-<pid>.map, which Linux perf reads to name the functions in
// mapped code: one line per function, up to the next one. The shared slow
// routines after the last function count as part of it.
@(private = "file")
perf_map :: proc(code: Native_Code, end: int) {
	offs := make([dynamic]int, 0, len(code.funcs) + len(code.ovls) + 1, context.temp_allocator)
	for f in code.funcs {append(&offs, int(f.off))}
	for o in code.ovls {append(&offs, int(o.off))}
	slice.sort(offs[:])
	append(&offs, end)
	sb := strings.builder_make(context.temp_allocator)
	for f in code.funcs {
		next, _ := slice.binary_search(offs[:], int(f.off))
		for offs[next] == int(f.off) {next += 1}
		fmt.sbprintfln(&sb, "%x %x fn_%08x", code.base + uintptr(f.off), offs[next] - int(f.off), f.addr)
	}
	for o in code.ovls {
		next, _ := slice.binary_search(offs[:], int(o.off))
		for offs[next] == int(o.off) {next += 1}
		fmt.sbprintfln(&sb, "%x %x ovl_%08x", code.base + uintptr(o.off), offs[next] - int(o.off), o.addr)
	}
	path := fmt.tprintf("/tmp/perf-%d.map", os.get_pid())
	if err := os.write_entire_file(path, sb.buf[:]); err != nil {
		fmt.eprintfln("native: %s: %v", path, err)
	}
}

// Free what native_load returned: the mapped code and the tables.
native_free :: proc(code: ^Native_Code) {
	unmap_code(rawptr(code.base), code.size)
	delete(code.funcs)
	delete(code.ovls)
	code^ = {}
}
