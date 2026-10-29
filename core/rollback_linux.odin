// Rollback write tracking on Linux (rollback.odin has the rest): large
// memory is registered with userfaultfd in asynchronous write-protect mode
// (Linux 6.7+), so the first write to a protected page just unprotects it
// (no signal, no handler thread), and PAGEMAP_SCAN lists the pages written
// since the last scan and protects them again in one call. Kernel writes
// (read() into guest memory) are tracked too.
package core

import "base:intrinsics"
import "core:sys/linux"

@(private)
RB_NEED :: "rollback: kernel lacks userfaultfd async write-protect (Linux 6.7+)"

@(private = "file")
rb_os: struct {
	uffd:    linux.Fd,
	pagemap: linux.Fd,
	scan:    [512]Pm_Region,
}

// linux/userfaultfd.h, linux/fs.h
@(private)
Uffd_Range :: struct {
	start, len: u64,
}
@(private)
UFFD_USER_MODE_ONLY :: 1
@(private)
UFFD_FEATURE_WP_UNPOPULATED :: 1 << 13
@(private)
UFFD_FEATURE_WP_ASYNC :: 1 << 15
@(private)
UFFDIO_API :: 0xC018AA3F
@(private)
UFFDIO_REGISTER :: 0xC020AA00
@(private)
UFFDIO_REGISTER_MODE_WP :: 2
@(private)
UFFDIO_WRITEPROTECT :: 0xC018AA06
@(private)
UFFDIO_WRITEPROTECT_MODE_WP :: 1
@(private)
PAGEMAP_SCAN :: 0xC0606610
@(private)
PM_SCAN_WP_MATCHING :: 1 << 0
@(private)
PM_SCAN_CHECK_WPASYNC :: 1 << 1
@(private)
PAGE_IS_WRITTEN :: 1 << 1
@(private)
PAGE_IS_PRESENT :: 1 << 3
@(private)
Pm_Scan_Arg :: struct {
	size, flags, start, end, walk_end, vec, vec_len, max_pages: u64,
	category_inverted, category_mask, category_anyof_mask, return_mask: u64,
}
@(private)
Pm_Region :: struct {
	start, end, categories: u64,
}

@(private)
rb_ioctl :: proc(fd: linux.Fd, req: uintptr, arg: rawptr) -> int {
	return int(intrinsics.syscall(linux.SYS_ioctl, uintptr(fd), req, uintptr(arg)))
}

// Start tracking: protect the large memory and copy what is in it to the
// shadows. Fails (returns false) if the kernel lacks asynchronous
// write-protect (Linux 6.7+).
@(private)
rb_start :: proc() -> bool {
	fd := int(intrinsics.syscall(linux.SYS_userfaultfd, uintptr(transmute(i32)linux.Open_Flags{.CLOEXEC}) | UFFD_USER_MODE_ONLY))
	if fd < 0 {return false}
	rb_os.uffd = linux.Fd(fd)
	api := struct {
		api, features, ioctls: u64,
	}{0xAA, UFFD_FEATURE_WP_ASYNC | UFFD_FEATURE_WP_UNPOPULATED, 0}
	if rb_ioctl(rb_os.uffd, UFFDIO_API, &api) < 0 {return false}
	err: linux.Errno
	rb_os.pagemap, err = linux.open("/proc/self/pagemap", {})
	if err != .NONE {return false}
	mems := make([dynamic][]u8, context.temp_allocator)
	append(&mems, ..snap_areas[:])
	append(&mems, emu_heap_mem)
	for m in mems {
		r := Uffd_Range{u64(uintptr(raw_data(m))), u64(len(m))}
		// Huge pages would be split by the first protected write anyway.
		linux.madvise(raw_data(m), uint(len(m)), .NOHUGEPAGE)
		reg := struct {
			range:        Uffd_Range,
			mode, ioctls: u64,
		}{r, UFFDIO_REGISTER_MODE_WP, 0}
		if rb_ioctl(rb_os.uffd, UFFDIO_REGISTER, &reg) < 0 {return false}
		wp := struct {
			range: Uffd_Range,
			mode:  u64,
		}{r, UFFDIO_WRITEPROTECT_MODE_WP}
		if rb_ioctl(rb_os.uffd, UFFDIO_WRITEPROTECT, &wp) < 0 {return false}
		base, merr := linux.mmap(0, uint(len(m)), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS, .NORESERVE})
		assert(merr == .NONE, "rollback shadow")
		a := Rb_Area{m, ([^]u8)(base)[:len(m)]}
		// Pages never touched are zero in both.
		rb_pagemap(a, false, proc(a: Rb_Area, off: int, _: rawptr) {
			copy(a.shadow[off:][:PAGE], a.mem[off:][:PAGE])
		}, nil)
		append(&rb.areas, a)
	}
	rb.on = true
	return true
}

// Call `f` for each page of `a` written since the last scan, protecting it
// again.
@(private)
rb_scan :: proc(a: Rb_Area, f: proc(a: Rb_Area, off: int, data: rawptr), data: rawptr) {
	rb_pagemap(a, true, f, data)
}

// rb_scan, or with `written` false, each page present.
@(private = "file")
rb_pagemap :: proc(a: Rb_Area, written: bool, f: proc(a: Rb_Area, off: int, data: rawptr), data: rawptr) {
	base := u64(uintptr(raw_data(a.mem)))
	arg := Pm_Scan_Arg {
		size        = size_of(Pm_Scan_Arg),
		start       = base,
		end         = base + u64(len(a.mem)),
		vec         = u64(uintptr(&rb_os.scan)),
		vec_len     = len(rb_os.scan),
		return_mask = PAGE_IS_WRITTEN | PAGE_IS_PRESENT,
	}
	if written {
		arg.flags = PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC
		arg.category_mask = PAGE_IS_WRITTEN
	} else {
		arg.category_mask = PAGE_IS_PRESENT
	}
	for arg.start < arg.end {
		n := rb_ioctl(rb_os.pagemap, PAGEMAP_SCAN, &arg)
		assert(n >= 0, "PAGEMAP_SCAN")
		for r in rb_os.scan[:n] {
			for p := r.start; p < r.end; p += PAGE {f(a, int(p - base), data)}
		}
		arg.start = arg.walk_end
	}
}
