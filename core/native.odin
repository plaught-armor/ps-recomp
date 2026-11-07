// Native code from the recompiler, the file recomp/native/blob.odin writes:
// its code mapped executable with each import slot filled by name (on
// wasm32, a module the host instantiates with each slot a global). The
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

// What a span's code runs: a VU unit's microprogram, or a processor's
// function compiled from words it interpreted (core/learn.odin).
Native_Kind :: enum u32 {
	Vu0,
	Vu1,
	Psx,
	Iop,
	Ee,
}

// A native function valid only while its memory holds the words it was
// compiled from, ranges[range_first:][:n_ranges]: VU micro memory for a
// microprogram (entry 0), the processor's address space for a function
// (entered at entry).
Native_Span :: struct {
	kind:                  Native_Kind,
	entry, off:            u32,
	range_first, n_ranges: u32,
}

// n_words words from byte pc of the span's memory, at word at of the pool.
Native_Range :: struct {
	pc, n_words, at: u32,
}

// A function the blob's compiler left to the interpreter: its entry and
// its code's bytes [lo, hi).
Native_Interp :: struct {
	entry, lo, hi: u32,
}

Native_Code :: struct {
	base:   uintptr, // a function is at base + off (wasm32: table index)
	size:   int, // bytes of code at base, for unmap_code (wasm32: functions)
	funcs:  []Native_Func,
	ovls:   []Native_Ovl,
	spans:  []Native_Span,
	ranges: []Native_Range,
	pool:   []u32,
}

NATIVE_MAGIC :: 0x4e525350 // "PSRN"
NATIVE_VERSION :: 4
// Bytes of the header: magic, version, arch, then the counts and sizes.
NATIVE_HEADER :: 48

// The blob arch of a wasm build (recomp/native Arch .Wasm32): its code is
// a module whose functions the host puts in the runtime's function table
// (core/code_wasi.odin), and another host's machine code is refused.
NATIVE_ARCH_WASM32 :: 4

// The blob arch this build runs (recomp/native Arch, or NATIVE_ARCH_WASM32),
// and its name there.
NATIVE_ARCH :: NATIVE_ARCH_WASM32 when ODIN_ARCH == .wasm32 else (3 when ODIN_ARCH == .arm64 else (2 when ODIN_OS == .Windows else 1))
NATIVE_ARCH_NAME :: "wasm32" when ODIN_ARCH == .wasm32 else ("arm64" when ODIN_ARCH == .arm64 else ("x64_win" when ODIN_OS == .Windows else "x64_sysv"))

// Executable memory is mapped in 64K units, a page on every host.
@(private)
code_size :: proc(n: int) -> int {
	return (n + 0xffff) &~ 0xffff
}

// The blob's header words and import slot names (temp allocated, into
// blob), and the offset past them; err when it is no blob of this version
// and arch.
native_slots :: proc(blob: []u8) -> (h: [NATIVE_HEADER / 4]u32, slots: []string, at: int, err: string) {
	for &v in h {
		if at + 4 > len(blob) {return h, nil, 0, "short header"}
		v = u32(blob[at]) | u32(blob[at + 1]) << 8 | u32(blob[at + 2]) << 16 | u32(blob[at + 3]) << 24
		at += 4
	}
	if h[0] != NATIVE_MAGIC || h[1] != NATIVE_VERSION {
		return h, nil, 0, "not a native code file of this version"
	}
	if h[2] != NATIVE_ARCH {
		return h, nil, 0, fmt.tprintf("built for arch %d, this host runs %d", h[2], NATIVE_ARCH)
	}
	if u64(h[3]) > u64(len(blob)) {return h, nil, 0, "short import table"}
	slots = make([]string, h[3], context.temp_allocator)
	for &name in slots {
		if at + 2 > len(blob) {return h, nil, 0, "short import table"}
		n := int(blob[at]) | int(blob[at + 1]) << 8
		at += 2
		if at + n > len(blob) {return h, nil, 0, "short import table"}
		name = string(blob[at:at + n])
		at += n
	}
	return h, slots, at, ""
}

// Whether the tables the header h counts fill the blob's n bytes from at.
// In u64, each count first checked against n: int is 32 bits on wasm32,
// where a product or the sum would wrap.
@(private = "file")
native_tables_fit :: proc(h: [NATIVE_HEADER / 4]u32, at, n: int) -> bool {
	for k in 4 ..< 11 {
		if u64(h[k]) > u64(n) {return false}
	}
	sum := 8 * u64(h[4]) + 32 * u64(h[5]) + 12 * u64(h[6]) + 20 * u64(h[7]) + 12 * u64(h[8]) + 4 * u64(h[9]) + u64(h[10])
	return sum == u64(n - at)
}

// The functions the blob's compiler left to the interpreter on purpose
// (recomp/native/blob.odin), temp allocated; err as native_slots, or for
// tables that do not fit the blob.
native_interp :: proc(blob: []u8) -> (interp: []Native_Interp, err: string) {
	h, _, at, serr := native_slots(blob)
	if serr != "" {return nil, serr}
	if !native_tables_fit(h, at, len(blob)) {return nil, "bad table sizes"}
	at += 8 * int(h[4]) + 32 * int(h[5])
	interp = make([]Native_Interp, h[6], context.temp_allocator)
	word :: proc(b: []u8) -> u32 {return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24}
	for &v, k in interp {
		b := blob[at + 12 * k:]
		v = {word(b), word(b[4:]), word(b[8:])}
	}
	return interp, ""
}

// Map the blob's code; `imports` gives each slot's value (an address or a
// constant). The tables are allocated with context.allocator.
native_load :: proc(blob: []u8, imports: map[string]u64) -> (code: Native_Code, err: string) {
	word :: proc(blob: []u8, at: ^int) -> (u32, bool) {
		if at^ + 4 > len(blob) {return 0, false}
		b := blob[at^:]
		at^ += 4
		return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24, true
	}
	h, slots, at, serr := native_slots(blob)
	if serr != "" {return {}, serr}
	n_imports, n_funcs, n_ovls, n_interp := h[3], h[4], h[5], h[6]
	n_spans, n_ranges, n_pool, size, imports_at := h[7], h[8], h[9], h[10], h[11]
	if !native_tables_fit(h, at, len(blob)) {return {}, "bad table sizes"}
	// A function's offset is below imports_at; on wasm32 there is no slot
	// table (imports_at is 0), and offsets are checked once the module says
	// how many functions it has.
	limit := imports_at
	when ODIN_ARCH == .wasm32 {
		if imports_at != 0 {return {}, "bad import slots"}
		limit = max(u32)
	} else {
		if imports_at % 16 != 0 || int(imports_at) + 8 * int(n_imports) != int(size) {
			return {}, "bad import slots"
		}
	}
	defer if err != "" {
		delete(code.funcs)
		delete(code.ovls)
		delete(code.spans)
		delete(code.ranges)
		delete(code.pool)
		code = {}
	}
	code.funcs = make([]Native_Func, n_funcs)
	for &f in code.funcs {
		f.addr, _ = word(blob, &at)
		f.off, _ = word(blob, &at)
		if f.off >= limit {return code, "function outside the code"}
	}
	code.ovls = make([]Native_Ovl, n_ovls)
	for &o in code.ovls {
		o.addr, _ = word(blob, &at)
		o.slot, _ = word(blob, &at)
		o.id, _ = word(blob, &at)
		for &w in o.sig {w, _ = word(blob, &at)}
		o.off, _ = word(blob, &at)
		if o.off >= limit {return code, "function outside the code"}
	}
	at += 12 * int(n_interp) // for compilers only (native_interp)
	code.spans = make([]Native_Span, n_spans)
	for &s in code.spans {
		kind, _ := word(blob, &at)
		s.entry, _ = word(blob, &at)
		s.off, _ = word(blob, &at)
		s.range_first, _ = word(blob, &at)
		s.n_ranges, _ = word(blob, &at)
		if kind > u32(max(Native_Kind)) {return code, "bad span kind"}
		s.kind = Native_Kind(kind)
		if s.off >= limit {return code, "function outside the code"}
		if u64(s.range_first) + u64(s.n_ranges) > u64(n_ranges) {return code, "bad span ranges"}
	}
	code.ranges = make([]Native_Range, n_ranges)
	for &r in code.ranges {
		r.pc, _ = word(blob, &at)
		r.n_words, _ = word(blob, &at)
		r.at, _ = word(blob, &at)
		if r.pc % 4 != 0 || u64(r.at) + u64(r.n_words) > u64(n_pool) {return code, "bad span range"}
	}
	code.pool = make([]u32, n_pool)
	for &w in code.pool {w, _ = word(blob, &at)}
	// No code (a learned blob of no functions): nothing to map, and no
	// function can point into it (its offsets are below limit, 0).
	if size == 0 {return code, ""}
	when ODIN_ARCH == .wasm32 {
		vals := make([]u32, n_imports, context.temp_allocator)
		for name, k in slots {
			v, ok := imports[name]
			if !ok {return code, fmt.tprintf("the runtime has no %s", name)}
			if v > u64(max(u32)) {return code, fmt.tprintf("%s does not fit a wasm32 slot", name)}
			vals[k] = u32(v)
		}
		n: u32
		base := wasm_instantiate(raw_data(blob[at:]), size, raw_data(vals), n_imports, &n)
		if base == 0 {return code, "the host cannot instantiate wasm32 code"}
		code.base, code.size = uintptr(base), int(n)
		outside := false
		for f in code.funcs {outside ||= f.off >= n}
		for o in code.ovls {outside ||= o.off >= n}
		for s in code.spans {outside ||= s.off >= n}
		if outside {
			// Released here: the caller's native_free must not again.
			wasm_release(base)
			code.base, code.size = 0, 0
			return code, "function outside the code"
		}
		return code, ""
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
	offs := make([dynamic]int, 0, len(code.funcs) + len(code.ovls) + len(code.spans) + 1, context.temp_allocator)
	for f in code.funcs {append(&offs, int(f.off))}
	for o in code.ovls {append(&offs, int(o.off))}
	for s in code.spans {append(&offs, int(s.off))}
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
	for s, k in code.spans {
		next, _ := slice.binary_search(offs[:], int(s.off))
		for offs[next] == int(s.off) {next += 1}
		fmt.sbprintfln(&sb, "%x %x %v_%d_%08x", code.base + uintptr(s.off), offs[next] - int(s.off), s.kind, k, s.entry)
	}
	path := fmt.tprintf("/tmp/perf-%d.map", os.get_pid())
	if err := os.write_entire_file(path, sb.buf[:]); err != nil {
		fmt.eprintfln("native: %s: %v", path, err)
	}
}

// Free what native_load returned: the mapped code and the tables.
native_free :: proc(code: ^Native_Code) {
	if code.base != 0 {
		when ODIN_ARCH == .wasm32 {
			wasm_release(u32(code.base))
		} else {
			unmap_code(rawptr(code.base), code.size)
		}
	}
	delete(code.funcs)
	delete(code.ovls)
	delete(code.spans)
	delete(code.ranges)
	delete(code.pool)
	code^ = {}
}
