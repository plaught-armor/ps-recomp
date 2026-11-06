// Directory listings that also work on wasi_wasm32.
package core

import "base:runtime"
import "core:os"

// The entries of the directory at path, unsorted and without "." and "..",
// as os.read_all_directory_by_path gives them; free them with
// os.file_info_slice_delete. Code that runs on the web lists through this:
// on wasi the toolchain's directory iterator asserts that each entry's name
// is longer than the bytes left after its header (core/os/dir_wasi.odin,
// the test turned round), so it fails on the first entry of any directory.
// There, read_dir reads the dirents itself and stats each entry.
read_dir :: proc(path: string, allocator: runtime.Allocator) -> ([]os.File_Info, os.Error) {
	when ODIN_OS == .WASI {
		return read_dir_wasi(path, allocator)
	} else {
		return os.read_all_directory_by_path(path, allocator)
	}
}
