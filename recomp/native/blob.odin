package native

import "core:os"

// The file a program's native code goes to; the runtime's loader reads it
// (core/native.odin has the same layout). All fields are little-endian u32.
//
//   header   magic "PSRN", version, arch, n_imports, n_funcs, n_ovls,
//            code_size, imports_at
//   imports  n_imports names, each a u16 length and the bytes
//   funcs    n_funcs of {addr, off}
//   ovls     n_ovls of {addr, slot, id, sig[4], off}
//   code     code_size bytes; the import slots are at imports_at
BLOB_MAGIC :: 0x4e525350 // "PSRN"
BLOB_VERSION :: 1

Blob_Func :: struct {
	addr, off: u32,
}

Blob_Ovl :: struct {
	addr, slot, id: u32,
	sig:            [4]u32,
	off:            u32,
}

write_blob :: proc(path: string, a: ^Asm, funcs: []Blob_Func, ovls: []Blob_Ovl) -> bool {
	b := make_blob(a, funcs, ovls)
	defer delete(b)
	return os.write_entire_file(path, b) == nil
}

// The file's bytes, in context.allocator; finishes a.
make_blob :: proc(a: ^Asm, funcs: []Blob_Func, ovls: []Blob_Ovl) -> []u8 {
	code, imports_at := finish(a)
	b: [dynamic]u8
	put :: proc(b: ^[dynamic]u8, v: u32) {
		append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
	}
	for v in ([?]u32{BLOB_MAGIC, BLOB_VERSION, u32(a.arch), u32(len(a.imports)), u32(len(funcs)), u32(len(ovls)), u32(len(code)), u32(imports_at)}) {
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
	append(&b, ..code)
	return b[:]
}
