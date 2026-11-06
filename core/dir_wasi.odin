// read_dir on wasi_wasm32 (dir.odin).
package core

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:sys/wasm/wasi"

// The entries of path, from its dirents, each stat'd.
read_dir_wasi :: proc(path: string, allocator: runtime.Allocator) -> (infos: []os.File_Info, err: os.Error) {
	f := os.open(path) or_return
	defer os.close(f)
	// fd_readdir fills the buffer and cuts the last entry short when the
	// entries do not fit, so a full buffer is read again with twice the room.
	buf := make([dynamic]u8, 512, context.temp_allocator)
	n: wasi.size_t
	for {
		e: wasi.errno_t
		n, e = wasi.fd_readdir(wasi.fd_t(os.fd(f)), buf[:], 0)
		if e != .SUCCESS {return nil, os.Platform_Error(e)}
		if int(n) < len(buf) {break}
		resize(&buf, 2 * len(buf)) or_return
	}
	out := make([dynamic]os.File_Info, allocator)
	defer if err != nil {os.file_info_slice_delete(out[:], allocator)}
	rest := buf[:n]
	for len(rest) >= size_of(wasi.dirent_t) {
		d := intrinsics.unaligned_load((^wasi.dirent_t)(raw_data(rest)))
		rest = rest[size_of(wasi.dirent_t):]
		// Whole: the buffer had room to spare.
		assert(int(d.d_namlen) <= len(rest))
		name := string(rest[:d.d_namlen])
		rest = rest[d.d_namlen:]
		if name == "." || name == ".." {continue}
		full := filepath.join({path, name}, context.temp_allocator) or_return
		append(&out, os.stat(full, allocator) or_return) or_return
	}
	return out[:], nil
}
