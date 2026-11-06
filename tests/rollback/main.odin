// Rollback test for a FLAT build: natively with -define:PS_FLAT=true, and for
// wasi_wasm32 under Node (tests/wasi/run.mjs), where rollback_wasi.odin
// finds the written pages by comparing with the shadows. A block allocated
// at the top of the emulated heap and freed after a commit must come back
// whole at a rewind to that commit, with the allocator's block headers: a
// save state taken at a commit and one taken after a rewind to it must be
// the same bytes. Pure: no files, no SDL.
package main

import "core:fmt"
import "core:os"
import "ps:core"

HEAP :: 2 << 20
// Takes a whole half of the heap. Made first, it is the top half (a split
// hands out its upper half), and stays the heap's last block.
BIG :: 600 << 10

frame: int
ram: []u8

op :: proc(o: core.Snap_Op, s: ^core.Snapshot = nil, back := 0) {
	core.snap_op, core.snap_target, core.rb_back = o, s, back
	core.snap_yield()
}

check :: proc(what: string, want, got: ^core.Snapshot) {
	if len(want.data) != len(got.data) || string(want.data[:]) != string(got.data[:]) {
		fmt.eprintln("FAIL", what, "differs from the save state taken at the commit")
		os.exit(1)
	}
	fmt.println("ok", what)
}

main :: proc() {
	when !core.FLAT {
		fmt.eprintln("tests/rollback is for a FLAT build: -define:PS_FLAT=true")
		os.exit(2)
	}
	core.snap_init(HEAP)
	core.snap_add(&frame)
	ram = core.snap_area(4 * 4096)
	context.allocator = core.emu_allocator()
	s0, s1, got: core.Snapshot
	s0.id, s1.id, got.id = 0, 1, 2

	op(.Commit)
	op(.Save, &s0)

	frame = 1
	big := make([]u8, BIG)
	low := new([8]u64)
	low[0] = 1
	if uintptr(raw_data(big)) < uintptr(raw_data(low)) {
		fmt.eprintln("FAIL the big block is not in the heap's top half")
		os.exit(1)
	}
	for &b, i in big {b = u8(i) ~ 0x5a}
	ram[0] = 1
	op(.Commit)
	op(.Save, &s1)

	// The big block freed and its bytes written, as a block made there and
	// freed again before the commit would: at the next commit the heap's
	// last block is a free one, so only its header page lies below the
	// heap's end, though the pages above it were written. The scan must
	// still list them, as the rewind puts the big block back.
	frame = 2
	delete(big)
	for &b in big {b = 0xee}
	low[0] = 2
	ram[4096] = 2
	op(.Commit)

	frame = 3
	low[1] = 3
	ram[0] = 3
	op(.Rewind, back = 2)
	op(.Save, &got)
	check("rewind past a free of the heap's top block", &s1, &got)
	for b, i in big {
		if b != u8(i) ~ 0x5a {
			fmt.eprintln("FAIL the big block's contents at", i)
			os.exit(1)
		}
	}

	op(.Rewind, back = 2)
	op(.Save, &got)
	check("rewind to before the allocations", &s0, &got)
}
