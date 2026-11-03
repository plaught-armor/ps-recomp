// Headless draw skip: with a flipping display, a draw into a buffer the
// display has shown is skipped and a draw into any other buffer runs; a
// textured draw whose TEX0 TBP0 lies in a shown buffer latches the skip off,
// so later draws into shown buffers run; a held display skips nothing; and
// display_reset clears the set.
package main

import "core:fmt"
import "core:os"
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

	if failed > 0 {os.exit(1)}
	fmt.println("ok gs")
}
