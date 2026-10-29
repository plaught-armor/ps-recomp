package core

import win "core:sys/windows"

// `n` bytes of zeroed memory; Windows commits pages as they are first used.
// MEM_WRITE_WATCH lets rollback list the pages written.
@(private)
snap_map :: proc(n: int) -> []u8 {
	base := win.VirtualAlloc(nil, uint(n), win.MEM_RESERVE | win.MEM_COMMIT | MEM_WRITE_WATCH, win.PAGE_READWRITE)
	assert(base != nil, "snapshot memory")
	return ([^]u8)(base)[:n]
}
