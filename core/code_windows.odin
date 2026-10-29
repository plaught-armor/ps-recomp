// Executable memory on Windows.
package core

import win "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

@(private = "file")
@(default_calling_convention = "system")
foreign kernel32 {
	FlushInstructionCache :: proc(process: win.HANDLE, base: rawptr, size: uint) -> win.BOOL ---
}

// `code` copied into new memory that can run and not be written.
map_code :: proc(code: []u8) -> rawptr {
	n := uint(code_size(len(code)))
	page := win.VirtualAlloc(nil, n, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
	ensure(page != nil, "code memory")
	copy(([^]u8)(page)[:len(code)], code)
	old: win.DWORD
	ensure(win.VirtualProtect(page, n, win.PAGE_EXECUTE_READ, &old) == true, "code memory")
	FlushInstructionCache(win.GetCurrentProcess(), page, n)
	return page
}

// Free memory from map_code; n is the length of the code it was given
// (MEM_RELEASE frees the whole allocation and takes size 0).
unmap_code :: proc(base: rawptr, n: int) {
	_ = n
	ensure(win.VirtualFree(base, 0, win.MEM_RELEASE) == true, "code memory")
}
