// Rollback test for a FLAT build: natively with -define:PS_FLAT=true, and for
// wasi_wasm32 under Node (tests/wasi/run.mjs), where rollback_wasi.odin
// finds the written pages by comparing with the shadows. A block allocated
// at the top of the emulated heap and freed after a commit must come back
// whole at a rewind to that commit, with the allocator's block headers: a
// save state taken at a commit and one taken after a rewind to it must be
// the same bytes. So must a block made in pages no scan has read yet, over
// the bytes of one made and freed there first. Pure: no files, no SDL.
package main

import "core:fmt"
import "core:os"
import "ps:core"

HEAP :: 2 << 20
// Takes a whole half of the heap. Made first, it is the top half (a split
// hands out its upper half), and stays the heap's last block.
BIG :: 600 << 10
// Below the big block and the small one, in pages no scan has found state in.
MID :: 200 << 10

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
	s0, s1, s2, got: core.Snapshot
	s0.id, s1.id, s2.id, got.id = 0, 1, 3, 2

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

	// A block made and written in pages no scan has read, then freed: its
	// bytes stay there in free space. One made in its place before the
	// commit is first found by that commit's scan, and its contents must
	// come back at a rewind to it.
	frame = 4
	tmp := make([]u8, MID)
	for &b in tmp {b = 0x77}
	delete(tmp)
	mid := make([]u8, MID)
	if uintptr(raw_data(mid)) >= uintptr(raw_data(low)) {
		fmt.eprintln("FAIL the mid block is not below the small one")
		os.exit(1)
	}
	for &b, i in mid {b = u8(i * 7)}
	op(.Commit)
	op(.Save, &s2)

	frame = 5
	for &b in mid {b = 0xee}
	op(.Commit)
	op(.Rewind, back = 2)
	op(.Save, &got)
	check("rewind to a block made in pages no scan had read", &s2, &got)
	for b, i in mid {
		if b != u8(i * 7) {
			fmt.eprintln("FAIL the mid block's contents at", i)
			os.exit(1)
		}
	}

	op(.Rewind, back = 3)
	op(.Save, &got)
	check("rewind to before the allocations", &s0, &got)
}
