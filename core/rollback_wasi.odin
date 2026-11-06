// Rollback write tracking on wasm (rollback.odin has the rest). Wasm has no
// page protection to catch writes with, so a scan compares each page of the
// large memory with its shadow: a page that differs is one written since the
// last scan. A page written back to the bytes it had is not listed, which
// changes nothing, as the shadow already holds them. Every writer is seen
// this way, guest stores, DMA and host code alike.
//
// A scan reads the memory and its shadow whole, except the emulated heap,
// of which it reads only the pages in heap_seen: elsewhere there is only
// free space, whose bytes no state holds (a snapshot keeps only the header of
// a free block, and the default allocation paths zero what they hand out; a
// non-zeroed one, alloc_non_zeroed and the like, hands out whatever free
// space last held).
package core

import "core:mem"

@(private)
RB_NEED :: "rollback: cannot start"

// The pages of emu_heap_mem a scan reads, one bit each: every page that
// has held a block header or part of a block in use at any scan. A bit is
// never cleared: a block freed after a commit must still be scanned at the
// rewind, which puts back its header and contents.
//
// A page gets its bit at the first scan that finds state in it. Its shadow
// was last copied at rb_start, so it can differ from the page as of the last
// commit: a block made and freed there between two commits leaves its bytes.
// That page held no state at the last commit (no scan had found any), so
// the stale shadow bytes are only free space bytes, both in the undo log the
// commit takes and in what a rewind puts back. Free space outside the bits
// is not put back at a rewind (page protection does put it back), so a later
// non-zeroed allocation could carry those bytes into a save state.
//
// The buddy allocator hands out the upper half at each split, so the heap
// fills from its top down, with holes, and the scan skips every page no
// block has reached.
@(private = "file")
heap_seen: []u64

// Start tracking: copy the large memory to the shadows.
@(private)
rb_start :: proc() -> bool {
	mems := make([dynamic][]u8, context.temp_allocator)
	append(&mems, ..snap_areas[:])
	append(&mems, emu_heap_mem)
	heap_seen = make([]u64, (len(emu_heap_mem) / PAGE + 63) / 64, long_allocator())
	for m in mems {
		a := Rb_Area{m, snap_map(len(m))}
		copy(a.shadow, a.mem)
		append(&rb.areas, a)
	}
	rb.on = true
	return true
}

// Call `f` for each page of `a` that differs from its shadow. `f` makes the
// two the same again (copying one to the other); if it does not, the page
// is listed again at the next scan.
@(private)
rb_scan :: proc(a: Rb_Area, f: proc(a: Rb_Area, off: int, data: rawptr), data: rawptr) {
	if raw_data(a.mem) != raw_data(emu_heap_mem) {
		for off := 0; off < len(a.mem); off += PAGE {
			if !page_same(a.mem[off:][:PAGE], a.shadow[off:][:PAGE]) {f(a, off, data)}
		}
		return
	}
	heap_mark()
	for w, i in heap_seen {
		if w == 0 {continue}
		for j in 0 ..< uint(64) {
			if w & (1 << j) == 0 {continue}
			off := (i * 64 + int(j)) * PAGE
			if !page_same(a.mem[off:][:PAGE], a.shadow[off:][:PAGE]) {f(a, off, data)}
		}
	}
}

// Set the heap_seen bits of the pages holding a block header, or part of a
// block in use, now.
@(private = "file")
heap_mark :: proc() {
	h := &emu_heap
	base := uintptr(raw_data(emu_heap_mem))
	for b := h.head; b < h.tail; b = mem.buddy_block_next(b) {
		o := int(uintptr(b) - base)
		n := b.is_free ? size_of(mem.Buddy_Block) : int(b.size)
		for p := o / PAGE; p < (o + n + PAGE - 1) / PAGE; p += 1 {
			heap_seen[p / 64] |= 1 << uint(p % 64)
		}
	}
}

@(private = "file")
page_same :: proc(x, y: []u8) -> bool {
	p := ([^]u64)(raw_data(x))
	q := ([^]u64)(raw_data(y))
	for i in 0 ..< PAGE / size_of(u64) {
		if p[i] != q[i] {return false}
	}
	return true
}
