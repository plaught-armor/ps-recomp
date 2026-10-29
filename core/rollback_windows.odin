// Rollback write tracking on Windows (rollback.odin has the rest): large
// memory is mapped with MEM_WRITE_WATCH (snap_map), and GetWriteWatch lists
// the pages written since the last scan and resets them in one call.
package core

import win "core:sys/windows"

@(private)
RB_NEED :: "rollback: cannot start"

@(private)
MEM_WRITE_WATCH :: 0x200000

@(private = "file")
WRITE_WATCH_FLAG_RESET :: 1

// Room for every page of the largest tracked memory, so one call lists all
// of an area's written pages.
@(private = "file")
rb_addrs: []rawptr

// Start tracking: copy what has been written to the large memory since it
// was mapped to the shadows.
@(private)
rb_start :: proc() -> bool {
	mems := make([dynamic][]u8, context.temp_allocator)
	append(&mems, ..snap_areas[:])
	append(&mems, emu_heap_mem)
	most := 0
	for m in mems {most = max(most, len(m))}
	rb_addrs = make([]rawptr, most / PAGE)
	for m in mems {
		base := win.VirtualAlloc(nil, uint(len(m)), win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
		assert(base != nil, "rollback shadow")
		a := Rb_Area{m, ([^]u8)(base)[:len(m)]}
		// Pages never written are zero in both.
		rb_scan(a, proc(a: Rb_Area, off: int, _: rawptr) {
			copy(a.shadow[off:][:PAGE], a.mem[off:][:PAGE])
		}, nil)
		append(&rb.areas, a)
	}
	rb.on = true
	return true
}

// Call `f` for each page of `a` written since the last scan, resetting it.
@(private)
rb_scan :: proc(a: Rb_Area, f: proc(a: Rb_Area, off: int, data: rawptr), data: rawptr) {
	n := win.ULONG_PTR(len(rb_addrs))
	gran: win.DWORD
	r := win.GetWriteWatch(WRITE_WATCH_FLAG_RESET, raw_data(a.mem), uint(len(a.mem)), &rb_addrs[0], &n, &gran)
	assert(r == 0 && gran == PAGE, "GetWriteWatch")
	base := uintptr(raw_data(a.mem))
	for p in rb_addrs[:n] {f(a, int(uintptr(p) - base), data)}
}
