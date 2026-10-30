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

// A VU microprogram's native function, valid while micro memory of VU
// unit (0 or 1) holds ranges[range_first:][:n_ranges].
Native_Vu :: struct {
	unit, off:             u32,
	range_first, n_ranges: u32,
}

// n_words words from byte pc of micro memory, at word at of the pool.
Native_Range :: struct {
	pc, n_words, at: u32,
}

Native_Code :: struct {
	base:   uintptr, // a function is at base + off
	size:   int, // bytes of code at base, for unmap_code
	funcs:  []Native_Func,
	ovls:   []Native_Ovl,
	vus:    []Native_Vu, // none for PS1
	ranges: []Native_Range,
	pool:   []u32,
}

NATIVE_MAGIC :: 0x4e525350 // "PSRN"
NATIVE_VERSION :: 2
// Bytes of the header: magic, version, arch, then the counts and sizes.
NATIVE_HEADER :: 44

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
	h: [NATIVE_HEADER / 4]u32
	for &v in h {
		ok: bool
		if v, ok = word(blob, &at); !ok {return {}, "short header"}
	}
	magic, version, arch, n_imports, n_funcs, n_ovls := h[0], h[1], h[2], h[3], h[4], h[5]
	n_vus, n_ranges, n_pool, size, imports_at := h[6], h[7], h[8], h[9], h[10]
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
	if int(n_funcs) * 8 + int(n_ovls) * 32 + int(n_vus) * 16 + int(n_ranges) * 12 + int(n_pool) * 4 + int(size) != len(blob) - at {
		return {}, "bad table sizes"
	}
	if imports_at % 16 != 0 || int(imports_at) + 8 * int(n_imports) != int(size) {
		return {}, "bad import slots"
	}
	defer if err != "" {
		delete(code.funcs)
		delete(code.ovls)
		delete(code.vus)
		delete(code.ranges)
		delete(code.pool)
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
	code.vus = make([]Native_Vu, n_vus)
	for &v in code.vus {
		v.unit, _ = word(blob, &at)
		v.off, _ = word(blob, &at)
		v.range_first, _ = word(blob, &at)
		v.n_ranges, _ = word(blob, &at)
		if v.unit > 1 {return code, "bad VU unit"}
		if v.off >= imports_at {return code, "function outside the code"}
		if u64(v.range_first) + u64(v.n_ranges) > u64(n_ranges) {return code, "bad VU ranges"}
	}
	code.ranges = make([]Native_Range, n_ranges)
	for &r in code.ranges {
		r.pc, _ = word(blob, &at)
		r.n_words, _ = word(blob, &at)
		r.at, _ = word(blob, &at)
		if r.pc % 4 != 0 || u64(r.at) + u64(r.n_words) > u64(n_pool) {return code, "bad VU range"}
	}
	code.pool = make([]u32, n_pool)
	for &w in code.pool {w, _ = word(blob, &at)}
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
	offs := make([dynamic]int, 0, len(code.funcs) + len(code.ovls) + len(code.vus) + 1, context.temp_allocator)
	for f in code.funcs {append(&offs, int(f.off))}
	for o in code.ovls {append(&offs, int(o.off))}
	for v in code.vus {append(&offs, int(v.off))}
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
	for v, k in code.vus {
		next, _ := slice.binary_search(offs[:], int(v.off))
		for offs[next] == int(v.off) {next += 1}
		fmt.sbprintfln(&sb, "%x %x vu%d_%d", code.base + uintptr(v.off), offs[next] - int(v.off), v.unit, k)
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
	delete(code.vus)
	delete(code.ranges)
	delete(code.pool)
	code^ = {}
}
