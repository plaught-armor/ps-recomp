// Save states: a copy of all emulated state, taken at a frame boundary and
// restored in place within the same process (the base for rollback,
// rollback.odin).
//
// State holds host pointers (coroutine stacks full of return addresses,
// heap objects, containers), so a snapshot is only valid in the process
// that took it, and nothing it points at may move or be freed for good:
// - globals are copied where they are (the regions each file registers
//   with snap_add);
// - large memory (console RAM) is mapped page-aligned by snap_area, so
//   rollback can track its writes;
// - every heap allocation the console makes goes to one reserved region
//   managed by a buddy allocator (emu_allocator, the context allocator for
//   the console's init and for every coroutine), copied block by block with
//   its headers, so restoring it also restores the allocator;
// - coroutine stacks come from a pool that is never unmapped
//   (coroutine.odin), copied from each saved stack pointer up.
// Host state (window, GPU objects, audio queue, open files) is left alone;
// the renderer registers hooks for its GPU-side memory. Anything the game
// can see of the host (files it reads back, such as memory cards) must be
// emulated state too, or a replayed frame sees what the first pass did.
//
// Snapshots are taken off the game's stacks: at a frame boundary with an
// operation requested, the running coroutine calls snap_yield, and the host
// main thread (snap_run) does the copy and resumes whichever coroutine the
// state it now holds was running.
package core

import "base:runtime"
import "core:mem"

Snapshot :: struct {
	id:   int, // names this snapshot's GPU-side copies
	data: [dynamic]u8,
}

Snap_Op :: enum {
	None,
	Save,
	Load,
	Commit, // rollback: record this frame
	Rewind, // rollback: go back rb_back frames
}

// Set by the host at a frame boundary: the operation done (at the
// console's next snap_yield) before the game continues.
snap_op: Snap_Op
snap_target: ^Snapshot

// Called for GPU-side state after the CPU copy is saved and before it is
// loaded.
snap_hooks: [dynamic]Snap_Hook

Snap_Hook :: struct {
	save, load: proc(id: int),
}

// The allocator in use before snap_init: snapshot buffers and other host
// memory come from it.
host_allocator: runtime.Allocator

@(private)
snap_regions: [dynamic][]u8

// Memory from snap_area.
@(private)
snap_areas: [dynamic][]u8

// The coroutine to resume after a snapshot operation; part of the state.
@(private)
snap_resume: ^Coroutine

@(private)
emu_heap: mem.Buddy_Allocator
@(private)
emu_heap_mem: []u8

// Register a global as emulated state.
snap_add :: proc(p: ^$T) {
	append(&snap_regions, mem.ptr_to_bytes(p))
}

snap_add_bytes :: proc(b: []u8) {
	append(&snap_regions, b)
}

// Map `n` bytes (a multiple of the page size) of zeroed emulated memory.
snap_area :: proc(n: int) -> []u8 {
	b := snap_map(n)
	append(&snap_areas, b)
	return b
}

// Reserve the emulated heap, `heap` bytes (a power of two). Rollback scans
// the whole heap for written pages every frame, at a cost that grows with
// its size: keep it near what the console uses. Call before the console
// registers its state; afterwards set context.allocator and co_allocator to
// emu_allocator() for everything that is emulated state.
snap_init :: proc(heap: int) {
	assert(heap > 0 && heap & (heap - 1) == 0, "snapshot heap size not a power of two")
	host_allocator = context.allocator
	emu_heap_mem = snap_map(heap)
	mem.buddy_allocator_init(&emu_heap, emu_heap_mem, 64) // maps want cache-line alignment
	snap_add(&snap_resume)
	snap_add(&co_stack_owner)
}

emu_allocator :: proc() -> runtime.Allocator {
	return mem.buddy_allocator(&emu_heap)
}

// Host main thread: run the console from coroutine `co` (made with
// emu_allocator), serving snapshot requests. Never returns.
snap_run :: proc(co: ^Coroutine) -> ! {
	snap_resume = co
	context.allocator = host_allocator // for snapshot buffers
	for {
		co_switch(snap_resume)
		switch snap_op {
		case .None:
		case .Save: snap_save(snap_target)
		case .Load: snap_load(snap_target)
		case .Commit: rb_commit()
		case .Rewind: rb_rewind(rb_back)
		}
		snap_op = .None
	}
}

// From the console, at a frame boundary with snap_op set: hand the machine
// to snap_run for the operation.
snap_yield :: proc() {
	snap_resume = co_current
	co_switch(&co_main_thread)
}

@(private)
take :: proc(d: []u8, pos: ^int, n: int) -> []u8 {
	b := d[pos^:][:n]
	pos^ += n
	return b
}

@(private = "file")
snap_save :: proc(s: ^Snapshot) {
	clear(&s.data)
	put_regions(&s.data)
	for a in snap_areas {append(&s.data, ..a)}
	// Heap blocks in address order: whole used blocks, free ones' headers.
	h := &emu_heap
	for b := h.head; b < h.tail; b = mem.buddy_block_next(b) {
		n := b.is_free ? size_of(mem.Buddy_Block) : int(b.size)
		append(&s.data, ..([^]u8)(b)[:n])
	}
	co_stacks_put(&s.data)
	for h in snap_hooks {h.save(s.id)}
}

@(private = "file")
snap_load :: proc(s: ^Snapshot) {
	pos := 0
	take_regions(s.data[:], &pos)
	for a in snap_areas {copy(a, take(s.data[:], &pos, len(a)))}
	h := &emu_heap
	for b := h.head; b < h.tail; b = mem.buddy_block_next(b) {
		hdr := take(s.data[:], &pos, size_of(mem.Buddy_Block))
		copy(([^]u8)(b)[:len(hdr)], hdr)
		if !b.is_free {copy(([^]u8)(b)[len(hdr):b.size], take(s.data[:], &pos, int(b.size) - len(hdr)))}
	}
	co_stacks_take(s.data[:], &pos)
	assert(pos == len(s.data), "snapshot: size mismatch")
	// The frames rollback holds belong to the run before the load. Netplay
	// never loads a state; if it ever does, net.odin behind() must bound its
	// wait by the frames held, not RB_FRAMES.
	rb.count = 0
	for h in snap_hooks {h.load(s.id)}
}

@(private)
put_regions :: proc(d: ^[dynamic]u8) {
	for r in snap_regions {append(d, ..r)}
}

@(private)
take_regions :: proc(d: []u8, pos: ^int) {
	for r in snap_regions {copy(r, take(d, pos, len(r)))}
}
