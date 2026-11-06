// Rollback write tracking on wasm (rollback.odin has the rest). Wasm has no
// page protection to catch writes with, so a scan compares each page of the
// large memory with its shadow: a page that differs is one written since the
// last scan. A page written back to the bytes it had is not listed, which
// changes nothing, as the shadow already holds them. Every writer is seen
// this way, guest stores, DMA and host code alike.
//
// A scan reads the memory and its shadow whole, except the emulated heap,
// which is read only up to heap_top: above the highest block the heap has
// held at any scan, there is only free space, whose bytes no state holds (a
// snapshot keeps only the header of a free block, and the default allocation
// paths zero what they hand out; a non-zeroed one, alloc_non_zeroed and the
// like, hands out whatever free space last held).
package core

import "core:mem"

@(private)
RB_NEED :: "rollback: cannot start"

// Offset in emu_heap_mem below which the heap is scanned. It only grows: a
// block freed after a commit must still be scanned at the rewind, which
// puts back its header and contents. Free space above it is not put back
// at a rewind (page protection does put it back): a block made and freed
// there between two commits leaves its bytes, which a later non-zeroed
// allocation would carry into a save state. With the heap's first block
// taking its top half, heap_top is the whole heap from the first scan.
@(private = "file")
heap_top: int

// Start tracking: copy the large memory to the shadows.
@(private)
rb_start :: proc() -> bool {
	mems := make([dynamic][]u8, context.temp_allocator)
	append(&mems, ..snap_areas[:])
	append(&mems, emu_heap_mem)
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
	end := len(a.mem)
	if raw_data(a.mem) == raw_data(emu_heap_mem) {
		heap_top = max(heap_top, heap_end())
		end = heap_top
	}
	for off := 0; off < end; off += PAGE {
		if !page_same(a.mem[off:][:PAGE], a.shadow[off:][:PAGE]) {f(a, off, data)}
	}
}

// The end of the heap's last block if it is in use, or of its header if it
// is free, rounded up to a page: the heap holds nothing above it.
@(private = "file")
heap_end :: proc() -> int {
	h := &emu_heap
	last := h.head
	for b := h.head; b < h.tail; b = mem.buddy_block_next(b) {last = b}
	n := int(uintptr(last) - uintptr(raw_data(emu_heap_mem)))
	n += last.is_free ? size_of(mem.Buddy_Block) : int(last.size)
	return mem.align_forward_int(n, PAGE)
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
