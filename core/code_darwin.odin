// Executable memory on macOS: MAP_JIT, the only executable memory arm64
// macOS allows a process to write (a build with the hardened runtime needs
// the com.apple.security.cs.allow-jit entitlement).
package core

import "core:sys/darwin"
import "core:sys/posix"

foreign import system "system:System"

@(private = "file")
foreign system {
	pthread_jit_write_protect_np :: proc "c" (enabled: i32) ---
	sys_icache_invalidate :: proc "c" (start: rawptr, len: uint) ---
}

// `code` copied into new memory that can run.
map_code :: proc(code: []u8) -> rawptr {
	jit := transmute(posix.Map_Flags)i32(darwin.MAP_JIT)
	page := posix.mmap(nil, uint(code_size(len(code))), {.READ, .WRITE, .EXEC}, {.PRIVATE, .ANONYMOUS} + jit)
	ensure(page != posix.MAP_FAILED, "code memory")
	// arm64: this thread's MAP_JIT pages are writable until re-protected.
	when ODIN_ARCH == .arm64 {pthread_jit_write_protect_np(0)}
	copy(([^]u8)(page)[:len(code)], code)
	when ODIN_ARCH == .arm64 {pthread_jit_write_protect_np(1)}
	sys_icache_invalidate(page, len(code))
	return page
}

// Free memory from map_code; n is the length of the code it was given.
unmap_code :: proc(base: rawptr, n: int) {
	ensure(posix.munmap(base, uint(code_size(n))) == .OK, "code memory")
}
