package native

import "core:os"
import "core:slice"

// The file a program's native code goes to; the runtime's loader reads it
// (core/native.odin has the same layout). All fields are little-endian u32.
//
//   header   magic "PSRN", version, arch, n_imports, n_funcs, n_ovls,
//            n_vus, n_ranges, n_pool, code_size, imports_at
//   imports  n_imports names, each a u16 length and the bytes
//   funcs    n_funcs of {addr, off}
//   ovls     n_ovls of {addr, slot, id, sig[4], off}
//   vus      n_vus of {unit, off, range_first, n_ranges}
//   ranges   n_ranges of {pc, n_words, at}
//   pool     n_pool words
//   code     code_size bytes; the import slots are at imports_at
//
// A vu entry is a microprogram's native function (vu/native.odin) for VU
// unit 0 or 1 at code offset off. It holds only while micro memory has the
// words it was compiled from: ranges range_first up, each n_words words
// from byte pc of micro memory, found at word at of the pool. Equal ranges
// share their pool words. PS1 blobs have no vus.
BLOB_MAGIC :: 0x4e525350 // "PSRN"
BLOB_VERSION :: 2

Blob_Func :: struct {
	addr, off: u32,
}

Blob_Ovl :: struct {
	addr, slot, id: u32,
	sig:            [4]u32,
	off:            u32,
}

// A range of micro memory a vu entry was compiled from.
Blob_Range :: struct {
	pc:    u32,
	words: []u32,
}

Blob_Vu :: struct {
	unit, off: u32,
	ranges:    []Blob_Range,
}

write_blob :: proc(path: string, a: ^Asm, funcs: []Blob_Func, ovls: []Blob_Ovl, vus: []Blob_Vu = nil) -> bool {
	b := make_blob(a, funcs, ovls, vus)
	defer delete(b)
	return os.write_entire_file(path, b) == nil
}

// The file's bytes, in context.allocator; finishes a.
make_blob :: proc(a: ^Asm, funcs: []Blob_Func, ovls: []Blob_Ovl, vus: []Blob_Vu = nil) -> []u8 {
	code, imports_at := finish(a)
	// The pool, each distinct range's words once, keyed by their bytes.
	pool: [dynamic]u32
	defer delete(pool)
	at := make(map[string]u32)
	defer delete(at)
	n_ranges := 0
	for v in vus {
		for r in v.ranges {
			n_ranges += 1
			key := string(slice.to_bytes(r.words))
			if key in at {continue}
			at[key] = u32(len(pool))
			append(&pool, ..r.words)
		}
	}
	b: [dynamic]u8
	put :: proc(b: ^[dynamic]u8, v: u32) {
		append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
	for v in ([?]u32{BLOB_MAGIC, BLOB_VERSION, u32(a.arch), u32(len(a.imports)), u32(len(funcs)), u32(len(ovls)), u32(len(vus)), u32(n_ranges), u32(len(pool)), u32(len(code)), u32(imports_at)}) {
		put(&b, v)
	}
	for name in a.imports {
		append(&b, u8(len(name)), u8(len(name) >> 8))
		append(&b, name)
	}
	for f in funcs {
		put(&b, f.addr)
		put(&b, f.off)
	}
	for o in ovls {
		put(&b, o.addr)
		put(&b, o.slot)
		put(&b, o.id)
		for w in o.sig {put(&b, w)}
		put(&b, o.off)
	}
	first := 0
	for v in vus {
		put(&b, v.unit)
		put(&b, v.off)
		put(&b, u32(first))
		put(&b, u32(len(v.ranges)))
		first += len(v.ranges)
	}
	for v in vus {
		for r in v.ranges {
			put(&b, r.pc)
			put(&b, u32(len(r.words)))
			put(&b, at[string(slice.to_bytes(r.words))])
		}
	}
	for w in pool {put(&b, w)}
	append(&b, ..code)
	return b[:]
}
