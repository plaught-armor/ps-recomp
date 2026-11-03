// Headless draw skip: with a flipping display, a draw into a buffer the
// display has shown is skipped and a draw into any other buffer runs; a
// textured draw whose TEX0 TBP0 lies in a shown buffer latches the skip off,
// so later draws into shown buffers run, and so does a local copy whose
// rectangle reaches a shown buffer from base 0; a held display skips
// nothing; display_reset clears the latch and a snapshot load does not; and
// nothing is skipped while replays is set.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import "ps:ps2/gs"
import "ps:ps2/mem"

@(private = "file")
failed := 0

@(private = "file")
fail :: proc(msg: string, args: ..any) {
	fmt.eprintfln(msg, ..args)
	failed += 1
}

// Buffers in pages (2048 words; blocks are pages * 32), 64x64 PSMCT32.
@(private = "file")
A, B, C, Z :: 0x20, 0x40, 0x60, 0x100

// Show page p on read circuit 1 at one vblank.
@(private = "file")
vblank :: proc(p: u64) {
	(^u64)(&mem.gsregs[0x00])^ = 1 // PMODE: circuit 1
	(^u64)(&mem.gsregs[0x70])^ = p | 1 << 9 // DISPFB1: FBP, FBW 1, PSMCT32
	(^u64)(&mem.gsregs[0x80])^ = 63 << 32 | 63 << 44 // DISPLAY1: 64x64
	_, _ = gs.scanout()
}

// Fill a 16x16 sprite at the origin of page p with colour col, textured
// from block tbp when tbp >= 0.
@(private = "file")
sprite :: proc(p: u64, col: u64, tbp := -1) {
	gs.gs_write(0x4c, p | 1 << 16) // FRAME_1: FBP, FBW 1, PSMCT32
	gs.gs_write(0x4e, Z | 1 << 32) // ZBUF_1: ZMSK
	gs.gs_write(0x40, 63 << 16 | 63 << 48) // SCISSOR_1: 0..63
	gs.gs_write(0x18, 0) // XYZOFFSET_1
	gs.gs_write(0x1a, 1) // PRMODECONT: attributes from PRIM
	prim: u64 = 6 | 1 << 8 // SPRITE, FST (UV)
	if tbp >= 0 {
		gs.gs_write(0x06, u64(tbp) | 1 << 14 | 6 << 26 | 6 << 30 | 1 << 35) // TEX0_1: 64x64, DECAL
		prim |= 1 << 4
	}
	gs.gs_write(0x00, prim)
	gs.gs_write(0x01, col)
	gs.gs_write(0x05, 0)
	gs.gs_write(0x05, 16 << 4 | (16 << 4) << 16)
}

// Local copy of 8x8 pixels at row sy of the 64-wide PSMCT32 buffer at
// block 0 to page C.
@(private = "file")
copy_rows :: proc(sy: u64) {
	gs.gs_write(0x50, 0 | 1 << 16 | (C * 32) << 32 | 1 << 48) // BITBLTBUF: SBP 0, DBP C
	gs.gs_write(0x51, sy << 16) // TRXPOS: SSAY
	gs.gs_write(0x52, 8 | 8 << 32) // TRXREG: 8x8
	gs.gs_write(0x53, 2) // TRXDIR: local copy
}

// Show A then B (a flip) after a display reset.
@(private = "file")
flip :: proc() {
	gs.display_reset()
	vblank(A)
	vblank(B)
}

@(private = "file")
px :: proc(p: u32) -> u32 {return gs.read_raw(0, p * 32, 1, 4, 4)}

main :: proc() {
	gs.state.write = gs.write
	gs.skip_readout = true
	gs.skip_wanted = true
	vblank(A)
	vblank(B) // a flip: A and B shown

	sprite(A, 0x11)
	if px(A) != 0 {fail("draw into shown buffer A ran while flipping: %x", px(A))}
	sprite(C, 0x22)
	if px(C) != 0x22 {fail("offscreen draw into C skipped: %x", px(C))}

	sprite(C, 0x33, A * 32) // reads shown buffer A: latch
	sprite(B, 0x44)
	if px(B) != 0x44 {fail("draw into shown buffer B skipped after the feedback latch: %x", px(B))}

	gs.display_reset()
	vblank(A)
	vblank(B)
	sprite(B, 0x55)
	if px(B) != 0x44 {fail("display_reset did not clear the latch: B %x", px(B))}

	for _ in 0 ..< 3 {vblank(B)} // held: no flip for 3 vblanks
	sprite(B, 0x66)
	if px(B) != 0x66 {fail("draw into a held screen skipped: %x", px(B))}

	gs.skip_wanted = false
	vblank(A)
	sprite(A, 0x77)
	if px(A) != 0x77 {fail("draw skipped with skip_wanted off: %x", px(A))}
	gs.skip_wanted = true

	// Rows 0..7 of base 0 (page 0) miss A; rows from A's first row reach it.
	flip()
	copy_rows(0)
	sprite(A, 0x88)
	if px(A) != 0x77 {fail("a copy outside the shown buffers latched: A %x", px(A))}
	copy_rows(A * 32) // page A starts at row A * 32 of a 1-page-wide buffer
	sprite(A, 0x99)
	if px(A) != 0x99 {fail("a base-0 copy reaching shown buffer A did not latch: A %x", px(A))}

	gs.gs_snap()
	for h in core.snap_hooks {h.load(0)}
	vblank(A)
	vblank(B)
	sprite(B, 0xaa)
	if px(B) != 0xaa {fail("a snapshot load cleared the latch: B %x", px(B))}

	gs.replays = true
	flip()
	sprite(A, 0xbb)
	if px(A) != 0xbb {fail("draw skipped with replays set: %x", px(A))}

	if failed > 0 {os.exit(1)}
	fmt.println("ok gs")
}
