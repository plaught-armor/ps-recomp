// Rollback write tracking on macOS (rollback.odin has the rest). macOS has
// no call that lists written pages, so the large memory is kept read-only
// and the first write to each page faults: the handler marks the page
// written and makes it writable again. A scan protects the written pages
// again. Pages are the OS's (16K on arm64), reported to rollback.odin as
// PAGE-sized pieces.
//
// Kernel writes into tracked memory (read() into guest memory) fail with
// EFAULT instead of faulting, so tracked memory must only be written from
// user code. Scans run on the emulation thread with the game suspended; no
// other thread may write tracked memory meanwhile.
package core

import "base:intrinsics"
import "core:sys/posix"

@(private)
RB_NEED :: "rollback: cannot start"

@(private = "file")
OS_PAGE :: 16384 when ODIN_ARCH == .arm64 else 4096

@(private = "file")
rb_os: struct {
	dirty: [dynamic][]u64, // per area in rb.areas, one bit per OS page
	old:   [2]posix.sigaction_t, // SIGBUS, SIGSEGV handlers before ours
}

// Start tracking: copy the large memory to the shadows, protect it and
// catch the first write to each page.
@(private)
rb_start :: proc() -> bool {
	mems := make([dynamic][]u8, context.temp_allocator)
	append(&mems, ..snap_areas[:])
	append(&mems, emu_heap_mem)
	for m in mems {
		assert(uintptr(raw_data(m)) % OS_PAGE == 0, "rollback: area not page aligned")
		base := posix.mmap(nil, uint(len(m)), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
		assert(base != posix.MAP_FAILED, "rollback shadow")
		a := Rb_Area{m, ([^]u8)(base)[:len(m)]}
		// Pages never touched are zero in both; skipping them keeps them
		// uncommitted in the shadow.
		for off := 0; off < len(m); off += OS_PAGE {
			p := a.mem[off:min(off + OS_PAGE, len(m))]
			if !page_zero(p) {copy(a.shadow[off:], p)}
		}
		append(&rb.areas, a)
		append(&rb_os.dirty, make([]u64, (len(m) + OS_PAGE * 64 - 1) / (OS_PAGE * 64)))
	}
	act := posix.sigaction_t {
		sa_sigaction = rb_fault,
		sa_flags     = {.SIGINFO},
	}
	posix.sigemptyset(&act.sa_mask)
	if posix.sigaction(.SIGBUS, &act, &rb_os.old[0]) != .OK {return false}
	if posix.sigaction(.SIGSEGV, &act, &rb_os.old[1]) != .OK {return false}
	for a in rb.areas {
		if posix.mprotect(raw_data(a.mem), uint(len(a.mem)), {.READ}) != .OK {return false}
	}
	rb.on = true
	return true
}

@(private = "file")
page_zero :: proc(p: []u8) -> bool {
	w := ([^]u64)(raw_data(p))[:len(p) / 8]
	for v in w {if v != 0 {return false}}
	return true
}

// A write to a protected page: mark it written and let the write go on. A
// fault outside tracked memory puts the old handler back and returns, so
// the fault repeats and goes to it.
@(private = "file")
rb_fault :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uctx: rawptr) {
	addr := uintptr(info.si_addr)
	for a, i in rb.areas {
		base := uintptr(raw_data(a.mem))
		if addr < base || addr >= base + uintptr(len(a.mem)) {continue}
		p := (addr - base) / OS_PAGE
		intrinsics.atomic_or(&rb_os.dirty[i][p / 64], 1 << (p % 64))
		posix.mprotect(rawptr(base + p * OS_PAGE), OS_PAGE, {.READ, .WRITE})
		return
	}
	posix.sigaction(sig, &rb_os.old[0 if sig == .SIGBUS else 1], nil)
}

// Call `f` for each page of `a` written since the last scan, protecting it
// again.
@(private)
rb_scan :: proc(a: Rb_Area, f: proc(a: Rb_Area, off: int, data: rawptr), data: rawptr) {
	i := 0
	for raw_data(rb.areas[i].mem) != raw_data(a.mem) {i += 1}
	dirty := rb_os.dirty[i]
	for &word, wi in dirty {
		// Take the word first: a write by `f` marks its page again.
		w := intrinsics.atomic_exchange(&word, 0)
		for w != 0 {
			b := intrinsics.count_trailing_zeros(w)
			w &= w - 1
			off := (wi * 64 + int(b)) * OS_PAGE
			r := posix.mprotect(raw_data(a.mem[off:]), OS_PAGE, {.READ})
			assert(r == .OK, "rollback: mprotect")
			for sub := off; sub < min(off + OS_PAGE, len(a.mem)); sub += PAGE {f(a, sub, data)}
		}
	}
}
