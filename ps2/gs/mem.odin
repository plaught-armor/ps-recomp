// Software GS: 4 MiB local memory with the hardware's page/block/column
// swizzles, host-to-local and local-to-local transfers, and the CLUT.
//
// Swizzle tables are from PCSX2 (pcsx2/GS/GSTables.cpp). Z formats use the
// colour layouts with the block number XORed by 24.
package ps2_gs

import "base:intrinsics"

PSMCT32 :: 0x00
PSMCT24 :: 0x01
PSMCT16 :: 0x02
PSMCT16S :: 0x0a
PSMT8 :: 0x13
PSMT4 :: 0x14
PSMT8H :: 0x1b
PSMT4HL :: 0x24
PSMT4HH :: 0x2c
PSMZ32 :: 0x30
PSMZ24 :: 0x31
PSMZ16 :: 0x32
PSMZ16S :: 0x3a

VRAM_WORDS :: 1 << 20

vram: [VRAM_WORDS]u32

@(private, rodata)
block32 := [4][8]u32 {
	{0, 1, 4, 5, 16, 17, 20, 21},
	{2, 3, 6, 7, 18, 19, 22, 23},
	{8, 9, 12, 13, 24, 25, 28, 29},
	{10, 11, 14, 15, 26, 27, 30, 31},
}

@(private, rodata)
block16 := [8][4]u32 {
	{0, 2, 8, 10},
	{1, 3, 9, 11},
	{4, 6, 12, 14},
	{5, 7, 13, 15},
	{16, 18, 24, 26},
	{17, 19, 25, 27},
	{20, 22, 28, 30},
	{21, 23, 29, 31},
}

@(private, rodata)
block16s := [8][4]u32 {
	{0, 2, 16, 18},
	{1, 3, 17, 19},
	{8, 10, 24, 26},
	{9, 11, 25, 27},
	{4, 6, 20, 22},
	{5, 7, 21, 23},
	{12, 14, 28, 30},
	{13, 15, 29, 31},
}

@(private, rodata)
col32 := [8][8]u32 {
	{0, 1, 4, 5, 8, 9, 12, 13},
	{2, 3, 6, 7, 10, 11, 14, 15},
	{16, 17, 20, 21, 24, 25, 28, 29},
	{18, 19, 22, 23, 26, 27, 30, 31},
	{32, 33, 36, 37, 40, 41, 44, 45},
	{34, 35, 38, 39, 42, 43, 46, 47},
	{48, 49, 52, 53, 56, 57, 60, 61},
	{50, 51, 54, 55, 58, 59, 62, 63},
}

@(private, rodata)
col16 := [8][16]u32 {
	{0, 2, 8, 10, 16, 18, 24, 26, 1, 3, 9, 11, 17, 19, 25, 27},
	{4, 6, 12, 14, 20, 22, 28, 30, 5, 7, 13, 15, 21, 23, 29, 31},
	{32, 34, 40, 42, 48, 50, 56, 58, 33, 35, 41, 43, 49, 51, 57, 59},
	{36, 38, 44, 46, 52, 54, 60, 62, 37, 39, 45, 47, 53, 55, 61, 63},
	{64, 66, 72, 74, 80, 82, 88, 90, 65, 67, 73, 75, 81, 83, 89, 91},
	{68, 70, 76, 78, 84, 86, 92, 94, 69, 71, 77, 79, 85, 87, 93, 95},
	{96, 98, 104, 106, 112, 114, 120, 122, 97, 99, 105, 107, 113, 115, 121, 123},
	{100, 102, 108, 110, 116, 118, 124, 126, 101, 103, 109, 111, 117, 119, 125, 127},
}

@(private, rodata)
col8 := [16][16]u32 {
	{0, 4, 16, 20, 32, 36, 48, 52, 2, 6, 18, 22, 34, 38, 50, 54},
	{8, 12, 24, 28, 40, 44, 56, 60, 10, 14, 26, 30, 42, 46, 58, 62},
	{33, 37, 49, 53, 1, 5, 17, 21, 35, 39, 51, 55, 3, 7, 19, 23},
	{41, 45, 57, 61, 9, 13, 25, 29, 43, 47, 59, 63, 11, 15, 27, 31},
	{96, 100, 112, 116, 64, 68, 80, 84, 98, 102, 114, 118, 66, 70, 82, 86},
	{104, 108, 120, 124, 72, 76, 88, 92, 106, 110, 122, 126, 74, 78, 90, 94},
	{65, 69, 81, 85, 97, 101, 113, 117, 67, 71, 83, 87, 99, 103, 115, 119},
	{73, 77, 89, 93, 105, 109, 121, 125, 75, 79, 91, 95, 107, 111, 123, 127},
	{128, 132, 144, 148, 160, 164, 176, 180, 130, 134, 146, 150, 162, 166, 178, 182},
	{136, 140, 152, 156, 168, 172, 184, 188, 138, 142, 154, 158, 170, 174, 186, 190},
	{161, 165, 177, 181, 129, 133, 145, 149, 163, 167, 179, 183, 131, 135, 147, 151},
	{169, 173, 185, 189, 137, 141, 153, 157, 171, 175, 187, 191, 139, 143, 155, 159},
	{224, 228, 240, 244, 192, 196, 208, 212, 226, 230, 242, 246, 194, 198, 210, 214},
	{232, 236, 248, 252, 200, 204, 216, 220, 234, 238, 250, 254, 202, 206, 218, 222},
	{193, 197, 209, 213, 225, 229, 241, 245, 195, 199, 211, 215, 227, 231, 243, 247},
	{201, 205, 217, 221, 233, 237, 249, 253, 203, 207, 219, 223, 235, 239, 251, 255},
}

@(private, rodata)
col4 := [16][32]u32 {
	{0, 8, 32, 40, 64, 72, 96, 104, 2, 10, 34, 42, 66, 74, 98, 106, 4, 12, 36, 44, 68, 76, 100, 108, 6, 14, 38, 46, 70, 78, 102, 110},
	{16, 24, 48, 56, 80, 88, 112, 120, 18, 26, 50, 58, 82, 90, 114, 122, 20, 28, 52, 60, 84, 92, 116, 124, 22, 30, 54, 62, 86, 94, 118, 126},
	{65, 73, 97, 105, 1, 9, 33, 41, 67, 75, 99, 107, 3, 11, 35, 43, 69, 77, 101, 109, 5, 13, 37, 45, 71, 79, 103, 111, 7, 15, 39, 47},
	{81, 89, 113, 121, 17, 25, 49, 57, 83, 91, 115, 123, 19, 27, 51, 59, 85, 93, 117, 125, 21, 29, 53, 61, 87, 95, 119, 127, 23, 31, 55, 63},
	{192, 200, 224, 232, 128, 136, 160, 168, 194, 202, 226, 234, 130, 138, 162, 170, 196, 204, 228, 236, 132, 140, 164, 172, 198, 206, 230, 238, 134, 142, 166, 174},
	{208, 216, 240, 248, 144, 152, 176, 184, 210, 218, 242, 250, 146, 154, 178, 186, 212, 220, 244, 252, 148, 156, 180, 188, 214, 222, 246, 254, 150, 158, 182, 190},
	{129, 137, 161, 169, 193, 201, 225, 233, 131, 139, 163, 171, 195, 203, 227, 235, 133, 141, 165, 173, 197, 205, 229, 237, 135, 143, 167, 175, 199, 207, 231, 239},
	{145, 153, 177, 185, 209, 217, 241, 249, 147, 155, 179, 187, 211, 219, 243, 251, 149, 157, 181, 189, 213, 221, 245, 253, 151, 159, 183, 191, 215, 223, 247, 255},
	{256, 264, 288, 296, 320, 328, 352, 360, 258, 266, 290, 298, 322, 330, 354, 362, 260, 268, 292, 300, 324, 332, 356, 364, 262, 270, 294, 302, 326, 334, 358, 366},
	{272, 280, 304, 312, 336, 344, 368, 376, 274, 282, 306, 314, 338, 346, 370, 378, 276, 284, 308, 316, 340, 348, 372, 380, 278, 286, 310, 318, 342, 350, 374, 382},
	{321, 329, 353, 361, 257, 265, 289, 297, 323, 331, 355, 363, 259, 267, 291, 299, 325, 333, 357, 365, 261, 269, 293, 301, 327, 335, 359, 367, 263, 271, 295, 303},
	{337, 345, 369, 377, 273, 281, 305, 313, 339, 347, 371, 379, 275, 283, 307, 315, 341, 349, 373, 381, 277, 285, 309, 317, 343, 351, 375, 383, 279, 287, 311, 319},
	{448, 456, 480, 488, 384, 392, 416, 424, 450, 458, 482, 490, 386, 394, 418, 426, 452, 460, 484, 492, 388, 396, 420, 428, 454, 462, 486, 494, 390, 398, 422, 430},
	{464, 472, 496, 504, 400, 408, 432, 440, 466, 474, 498, 506, 402, 410, 434, 442, 468, 476, 500, 508, 404, 412, 436, 444, 470, 478, 502, 510, 406, 414, 438, 446},
	{385, 393, 417, 425, 449, 457, 481, 489, 387, 395, 419, 427, 451, 459, 483, 491, 389, 397, 421, 429, 453, 461, 485, 493, 391, 399, 423, 431, 455, 463, 487, 495},
	{401, 409, 433, 441, 465, 473, 497, 505, 403, 411, 435, 443, 467, 475, 499, 507, 405, 413, 437, 445, 469, 477, 501, 509, 407, 415, 439, 447, 471, 479, 503, 511},
}

is_z :: #force_inline proc(psm: u32) -> bool {return psm & 0x30 == 0x30}

// Word index of a 32-bit pixel; `bp` in 256-byte blocks, `bw` in 64 pixels.
// addr32, addr16, addr8 and addr4 are unchecked: every table index is
// masked to its dimension, and the result is masked inside vram.
addr32 :: #force_inline proc(psm, bp, bw, x, y: u32) -> u32 #no_bounds_check {
	b := block32[(y >> 3) & 3][(x >> 3) & 7]
	if is_z(psm) {b ~= 24}
	blk := bp + ((y >> 5) * bw + (x >> 6)) * 32 + b
	return ((blk << 6) + col32[y & 7][x & 7]) & (VRAM_WORDS - 1)
}

// Halfword index of a 16-bit pixel.
addr16 :: #force_inline proc(psm, bp, bw, x, y: u32) -> u32 #no_bounds_check {
	b := psm == PSMCT16S || psm == PSMZ16S ? block16s[(y >> 3) & 7][(x >> 4) & 3] : block16[(y >> 3) & 7][(x >> 4) & 3]
	if is_z(psm) {b ~= 24}
	blk := bp + ((y >> 6) * bw + (x >> 6)) * 32 + b
	return ((blk << 7) + col16[y & 7][x & 15]) & (2 * VRAM_WORDS - 1)
}

// Byte index of an 8-bit pixel.
addr8 :: #force_inline proc(bp, bw, x, y: u32) -> u32 #no_bounds_check {
	blk := bp + ((y >> 6) * (bw >> 1) + (x >> 7)) * 32 + block32[(y >> 4) & 3][(x >> 4) & 7]
	return ((blk << 8) + col8[y & 15][x & 15]) & (4 * VRAM_WORDS - 1)
}

// Nibble index of a 4-bit pixel.
addr4 :: #force_inline proc(bp, bw, x, y: u32) -> u32 #no_bounds_check {
	blk := bp + ((y >> 7) * (bw >> 1) + (x >> 7)) * 32 + block16[(y >> 4) & 7][(x >> 5) & 3]
	return ((blk << 9) + col4[y & 15][x & 31]) & (8 * VRAM_WORDS - 1)
}

vram16 :: #force_inline proc() -> [^]u16 {return ([^]u16)(&vram[0])}
vram8 :: #force_inline proc() -> [^]u8 {return ([^]u8)(&vram[0])}

// One row of a frame or Z buffer in a 32-, 24- or 16-bit format: the parts
// of addr32 and addr16 that depend only on y, so a pixel along the row
// costs two table reads and a few adds. A Ctx owns its rows and sets them
// up in decode_ctx (row_init) from its own PSM; bp and bw come from the
// same Ctx, so `y` is the whole key: a context change is a new Ctx and
// starts the rows empty. `ok` is false for the other formats, which take
// read_raw and write_raw.
@(private)
Row :: struct {
	ok, wide: bool, // wide: 32 or 24 bits, else 16
	zx:       u32, // block xor: 24 for Z formats
	mask:     u32, // bits a 32-bit word stores: 0xffffff for 24-bit formats
	alt:      bool, // 16S block layout
	y:        u32, // the row held, ROW_NONE before the first
	base:     u32, // bp plus the block row, in blocks
	blk, col: [^]u32, // block and column table rows of y
}

@(private)
ROW_NONE :: max(u32)

@(private)
row_init :: proc(psm: u32) -> (r: Row) {
	switch psm {
	case PSMCT32, PSMZ32: r = {ok = true, wide = true, mask = 0xffffffff}
	case PSMCT24, PSMZ24: r = {ok = true, wide = true, mask = 0xffffff}
	case PSMCT16, PSMZ16: r = {ok = true}
	case PSMCT16S, PSMZ16S: r = {ok = true, alt = true}
	}
	if is_z(psm) {r.zx = 24}
	r.y = ROW_NONE
	return
}

// Points `r` at row y. Only for an `ok` row.
@(private)
row_seek :: #force_inline proc(r: ^Row, bp, bw, y: u32) #no_bounds_check {
	if r.y == y {return}
	r.y = y
	if r.wide {
		r.base = bp + (y >> 5) * bw * 32
		r.blk = &block32[(y >> 3) & 3][0]
		r.col = &col32[y & 7][0]
	} else {
		r.base = bp + (y >> 6) * bw * 32
		r.blk = r.alt ? &block16s[(y >> 3) & 7][0] : &block16[(y >> 3) & 7][0]
		r.col = &col16[y & 7][0]
	}
}

// Index of pixel x on the row held: the vram word for a wide row, as
// addr32 gives it, else the vram16 halfword, as addr16 gives it.
@(private)
row_addr :: #force_inline proc(r: ^Row, x: u32) -> u32 {
	return r.wide ? row_addr_w(r, x, true) : row_addr_w(r, x, false)
}

// row_addr, row_read and row_write for a row known to be wide or not.
@(private)
row_addr_w :: #force_inline proc(r: ^Row, x: u32, $WIDE: bool) -> u32 #no_bounds_check {
	when WIDE {
		blk := r.base + (x >> 6) * 32 + (r.blk[(x >> 3) & 7] ~ r.zx)
		return ((blk << 6) + r.col[x & 7]) & (VRAM_WORDS - 1)
	} else {
		blk := r.base + (x >> 6) * 32 + (r.blk[(x >> 4) & 3] ~ r.zx)
		return ((blk << 7) + r.col[x & 15]) & (2 * VRAM_WORDS - 1)
	}
}

// read_raw and write_raw at a row_addr index.
@(private)
row_read :: #force_inline proc(r: ^Row, a: u32) -> u32 {
	return r.wide ? row_read_w(r, a, true) : row_read_w(r, a, false)
}

@(private)
row_read_w :: #force_inline proc(r: ^Row, a: u32, $WIDE: bool) -> u32 #no_bounds_check {
	when WIDE {return vram[a] & r.mask} else {return u32(vram16()[a])}
}

@(private)
row_write :: #force_inline proc(r: ^Row, a, v: u32) {
	if r.wide {row_write_w(r, a, v, true)} else {row_write_w(r, a, v, false)}
}

@(private)
row_write_w :: #force_inline proc(r: ^Row, a, v: u32, $WIDE: bool) #no_bounds_check {
	when WIDE {
		p := &vram[a]
		p^ = (p^ &~ r.mask) | (v & r.mask)
	} else {
		vram16()[a] = u16(v)
	}
}

// Stored value of a pixel: the full word for 32-bit formats, 24 bits for
// 24-bit ones, the halfword for 16-bit ones and the index for 8/4-bit ones.
// read_raw and write_raw are unchecked: the addr procs mask every index
// inside vram (vram16 and vram8 are multi-pointers over it).
read_raw :: proc(psm, bp, bw, x, y: u32) -> u32 #no_bounds_check {
	switch psm {
	case PSMCT32, PSMZ32: return vram[addr32(psm, bp, bw, x, y)]
	case PSMCT24, PSMZ24: return vram[addr32(psm, bp, bw, x, y)] & 0xffffff
	case PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: return u32(vram16()[addr16(psm, bp, bw, x, y)])
	case PSMT8: return u32(vram8()[addr8(bp, bw, x, y)])
	case PSMT4:
		n := addr4(bp, bw, x, y)
		return u32(vram8()[n >> 1] >> ((n & 1) * 4)) & 15
	case PSMT8H: return vram[addr32(PSMCT32, bp, bw, x, y)] >> 24
	case PSMT4HL: return (vram[addr32(PSMCT32, bp, bw, x, y)] >> 24) & 15
	case PSMT4HH: return vram[addr32(PSMCT32, bp, bw, x, y)] >> 28
	}
	return 0
}

write_raw :: #force_inline proc(psm, bp, bw, x, y, v: u32) #no_bounds_check {
	switch psm {
	case PSMCT32, PSMZ32: vram[addr32(psm, bp, bw, x, y)] = v
	case PSMCT24, PSMZ24:
		p := &vram[addr32(psm, bp, bw, x, y)]
		p^ = (p^ & 0xff000000) | (v & 0xffffff)
	case PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: vram16()[addr16(psm, bp, bw, x, y)] = u16(v)
	case PSMT8: vram8()[addr8(bp, bw, x, y)] = u8(v)
	case PSMT4:
		n := addr4(bp, bw, x, y)
		b := &vram8()[n >> 1]
		sh := u8(n & 1) * 4
		b^ = (b^ &~ (15 << sh)) | (u8(v & 15) << sh)
	case PSMT8H:
		p := &vram[addr32(PSMCT32, bp, bw, x, y)]
		p^ = (p^ & 0x00ffffff) | (v << 24)
	case PSMT4HL:
		p := &vram[addr32(PSMCT32, bp, bw, x, y)]
		p^ = (p^ & 0xf0ffffff) | ((v & 15) << 24)
	case PSMT4HH:
		p := &vram[addr32(PSMCT32, bp, bw, x, y)]
		p^ = (p^ & 0x0fffffff) | ((v & 15) << 28)
	}
}

// Bits per pixel of a transfer format.
psm_bits :: proc(psm: u32) -> u32 {
	switch psm {
	case PSMCT32, PSMZ32: return 32
	case PSMCT24, PSMZ24: return 24
	case PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: return 16
	case PSMT8, PSMT8H: return 8
	}
	return 4
}

// ------------------------------------------------------------- transfers

@(private)
xfer: struct {
	active:       bool,
	bp, bw, psm:  u32,
	x0, y0, w, h: u32,
	x, y:         u32,
	bits:         u64, // leftover bits of a pixel split across packets
	nbits:        u32,
	out:          bool, // local-to-host: read back through VIF1, not written
}

// TRXDIR write: start a host-to-local or local-to-host transfer, or run a
// local copy.
@(private)
xfer_start :: proc(dir: u32) {
	blt := state.regs[0x50]
	pos := state.regs[0x51]
	reg := state.regs[0x52]
	switch dir & 3 {
	case 0, 1:
		// Host-to-local writes the destination, local-to-host reads the
		// source: the high and low halves of BITBLTBUF and TRXPOS.
		blt, pos := blt, pos
		if dir & 3 == 0 {blt, pos = blt >> 32, pos >> 32}
		xfer = {
			active = true,
			bp     = u32(blt) & 0x3fff,
			bw     = u32(blt >> 16) & 0x3f,
			psm    = u32(blt >> 24) & 0x3f,
			x0     = u32(pos) & 0x7ff,
			y0     = u32(pos >> 16) & 0x7ff,
			w      = u32(reg) & 0xfff,
			h      = u32(reg >> 32) & 0xfff,
			out    = dir & 3 == 1,
		}
		if xfer.w == 0 || xfer.h == 0 {xfer.active = false}
		if xfer.active && xfer.out {shown_read(xfer.bp, xfer.bw, xfer.psm, xfer.y0, xfer.h)}
		// The pixels are those local memory holds once the commands before
		// TRXDIR have run.
		if xfer.active && xfer.out && hw_on {hw_download()}
	case 2:
		sbp, sbw, spsm := u32(blt) & 0x3fff, u32(blt >> 16) & 0x3f, u32(blt >> 24) & 0x3f
		dbp, dbw, dpsm := u32(blt >> 32) & 0x3fff, u32(blt >> 48) & 0x3f, u32(blt >> 56) & 0x3f
		sx, sy := u32(pos) & 0x7ff, u32(pos >> 16) & 0x7ff
		dx, dy := u32(pos >> 32) & 0x7ff, u32(pos >> 48) & 0x7ff
		w, h := u32(reg) & 0xfff, u32(reg >> 32) & 0xfff
		shown_read(sbp, sbw, spsm, sy, h)
		if hw_on {
			hw_copy(sbp, sbw, spsm, dbp, dbw, dpsm, sx, sy, dx, dy, w, h)
			return
		}
		tc_write_rect(dbp, dbw, dpsm, dx, dy, w, h)
		for y in 0 ..< h {
			for x in 0 ..< w {
				v := read_raw(spsm, sbp, sbw, (sx + x) & 2047, (sy + y) & 2047)
				write_raw(dpsm, dbp, dbw, (dx + x) & 2047, (dy + y) & 2047, v)
			}
		}
	case:
		xfer.active = false
	}
}

// IMAGE data for the active host-to-local transfer. The GPU renderer keeps
// local memory on the GPU alone, so only the position advances here.
transfer :: proc(data: []u8) {
	if !xfer.active || xfer.out {return}
	if !hw_on {
		transfer_cpu(data)
		return
	}
	// The pixels this data completes, after any bits left over from the
	// last packet: whole 32-bit pixels straight from the data, others
	// unpacked one word each.
	t := &xfer
	bpp := psm_bits(t.psm)
	start := t.y * t.w + t.x
	n := u32(min((u64(t.nbits) + u64(len(data)) * 8) / u64(bpp), u64(t.w * t.h - start)))
	rest := data
	if bpp == 32 && t.nbits == 0 {
		hw_upload(t.psm, t.bp, t.bw, t.x0, t.y0, t.w, start, ([^]u32)(raw_data(data))[:n])
		rest = data[n * 4:]
	} else if n > 0 {
		px := make([]u32, n, context.temp_allocator)
		k: u32 = 0
		unpack: for b, i in data {
			t.bits |= u64(b) << t.nbits
			t.nbits += 8
			for t.nbits >= bpp {
				px[k] = u32(t.bits & ((u64(1) << bpp) - 1))
				t.bits >>= bpp
				t.nbits -= bpp
				k += 1
				if k == n {
					rest = data[i + 1:]
					break unpack
				}
			}
		}
		if k < n {rest = nil}
		hw_upload(t.psm, t.bp, t.bw, t.x0, t.y0, t.w, start, px)
	}
	end := start + n
	if end == t.w * t.h {
		t.active = false
		return
	}
	t.x, t.y = end % t.w, end / t.w
	for b in rest {
		t.bits |= u64(b) << t.nbits
		t.nbits += 8
	}
}

// The next bytes of the active local-to-host transfer, packed as a
// host-to-local transfer of the same format would be; bytes past its end,
// or with none active, read 0.
readback :: proc(dst: []u8) {
	t := &xfer
	bpp := psm_bits(t.psm)
	for &b in dst {
		for t.nbits < 8 && t.active && t.out {
			v := read_raw(t.psm, t.bp, t.bw, (t.x0 + t.x) & 2047, (t.y0 + t.y) & 2047)
			t.bits |= u64(v & u32((u64(1) << bpp) - 1)) << t.nbits
			t.nbits += bpp
			t.x += 1
			if t.x == t.w {
				t.x = 0
				t.y += 1
				if t.y == t.h {t.active = false}
			}
		}
		b = u8(t.bits)
		t.bits >>= 8
		t.nbits = t.nbits > 8 ? t.nbits - 8 : 0
	}
}

@(private)
transfer_cpu :: proc(data: []u8) {
	tc_write_rect(xfer.bp, xfer.bw, xfer.psm, xfer.x0, xfer.y0, xfer.w, xfer.h)
	bpp := psm_bits(xfer.psm)
	// A pixel split across calls goes through the bit queue; whole pixels
	// take the fast loops.
	i := 0
	for ; i < len(data) && xfer.nbits != 0; i += 1 {transfer_byte(data[i], bpp)}
	if !xfer.active {return}
	body := data[i:][:(len(data) - i) * 8 / int(bpp) * int(bpp) / 8]
	if bpp == 32 {
		transfer32(([^]u32)(raw_data(body))[:len(body) / 4])
	} else {
		transfer_px(body, bpp)
	}
	for b in data[i + len(body):] {transfer_byte(b, bpp)}
}

@(private)
transfer_byte :: proc(b: u8, bpp: u32) {
	if !xfer.active {return}
	xfer.bits |= u64(b) << xfer.nbits
	xfer.nbits += 8
	for xfer.nbits >= bpp {
		v := u32(xfer.bits & ((u64(1) << bpp) - 1))
		xfer.bits >>= bpp
		xfer.nbits -= bpp
		write_raw(xfer.psm, xfer.bp, xfer.bw, (xfer.x0 + xfer.x) & 2047, (xfer.y0 + xfer.y) & 2047, v)
		xfer.x += 1
		if xfer.x == xfer.w {
			xfer.x = 0
			xfer.y += 1
			if xfer.y == xfer.h {
				xfer.active = false
				return
			}
		}
	}
}

// Whole 24/16/8/4-bit pixels, low nibble first for 4-bit.
@(private)
transfer_px :: proc(data: []u8, bpp: u32) #no_bounds_check {
	psm, bp, bw := xfer.psm, xfer.bp, xfer.bw
	for i in 0 ..< len(data) * 8 / int(bpp) {
		v: u32
		switch bpp {
		case 24: v = u32(data[3 * i]) | u32(data[3 * i + 1]) << 8 | u32(data[3 * i + 2]) << 16
		case 16: v = u32(data[2 * i]) | u32(data[2 * i + 1]) << 8
		case 8:  v = u32(data[i])
		case:    v = u32(data[i >> 1] >> (u8(i & 1) * 4)) & 15
		}
		write_raw(psm, bp, bw, (xfer.x0 + xfer.x) & 2047, (xfer.y0 + xfer.y) & 2047, v)
		xfer.x += 1
		if xfer.x == xfer.w {
			xfer.x = 0
			xfer.y += 1
			if xfer.y == xfer.h {
				xfer.active = false
				return
			}
		}
	}
}

// Whole 32-bit pixels: the FMV and texture upload path.
@(private)
transfer32 :: proc(words: []u32) #no_bounds_check {
	psm, bp, bw := xfer.psm, xfer.bp, xfer.bw
	x0, y0, w, h := xfer.x0, xfer.y0, xfer.w, xfer.h
	tx, ty := xfer.x, xfer.y
	defer {xfer.x, xfer.y = tx, ty}
	for i := 0; i < len(words); {
		x, y := (x0 + tx) & 2047, (y0 + ty) & 2047
		// x & 7 == 0 keeps x + 7 inside both the block and the 2048 wrap.
		if x & 7 == 0 && tx + 8 <= w && i + 8 <= len(words) {
			// Eight pixels across one block row (Z formats too: is_z only
			// moves the block). Each col32 row is four pairs of adjacent
			// words 4 apart (col32_pairs), so the eight pixels are four
			// 64-bit copies from the first pixel's word.
			d := addr32(psm, bp, bw, x, y)
			for j in 0 ..< u32(4) {
				v := intrinsics.unaligned_load((^u64)(&words[i + 2 * int(j)]))
				intrinsics.unaligned_store((^u64)(&vram[d + 4 * j]), v)
			}
			i += 8
			tx += 8
		} else {
			vram[addr32(psm, bp, bw, x, y)] = words[i]
			i += 1
			tx += 1
		}
		if tx == w {
			tx = 0
			ty += 1
			if ty == h {
				xfer.active = false
				return
			}
		}
	}
}

// The transfer32 fast path's layout claim, checked once at startup:
// col32[r][2j] == col32[r][0] + 4j and col32[r][2j + 1] == col32[r][2j] + 1.
@(init, private)
col32_pairs :: proc "contextless" () {
	for r in 0 ..< 8 {
		for j in 0 ..< 4 {
			if col32[r][2 * j] != col32[r][0] + u32(4 * j) || col32[r][2 * j + 1] != col32[r][2 * j] + 1 {
				intrinsics.trap()
			}
		}
	}
}

// ------------------------------------------------------------------ CLUT

// Raw CLUT entries: 32-bit colours, or 16-bit ones in the low half.
@(private)
clut: [512]u32
@(private)
cbp0, cbp1: u32

// Where CSM1 keeps CLUT entry i, from the first word of the block at CBP:
// what addr32 (clut_off32, in words) and addr16 (clut_off16, in halfwords,
// the same for PSMCT16 and PSMCT16S) give for a buffer 64 pixels wide and
// pixel (x, y) of the entry. 256 entries are 16 x 16 pixels in rows of 16
// with bits 3 and 4 of i swapped; 16 entries are 8 x 2 in rows of 8, the
// first 16 of the same table. Constants, so a load has no address
// arithmetic an entry beyond one add; tests/gs_clut holds them to the
// address procs.
@(private, rodata)
clut_off32 := [256]u8 {
	0, 1, 4, 5, 8, 9, 12, 13, 2, 3, 6, 7, 10, 11, 14, 15,
	64, 65, 68, 69, 72, 73, 76, 77, 66, 67, 70, 71, 74, 75, 78, 79,
	16, 17, 20, 21, 24, 25, 28, 29, 18, 19, 22, 23, 26, 27, 30, 31,
	80, 81, 84, 85, 88, 89, 92, 93, 82, 83, 86, 87, 90, 91, 94, 95,
	32, 33, 36, 37, 40, 41, 44, 45, 34, 35, 38, 39, 42, 43, 46, 47,
	96, 97, 100, 101, 104, 105, 108, 109, 98, 99, 102, 103, 106, 107, 110, 111,
	48, 49, 52, 53, 56, 57, 60, 61, 50, 51, 54, 55, 58, 59, 62, 63,
	112, 113, 116, 117, 120, 121, 124, 125, 114, 115, 118, 119, 122, 123, 126, 127,
	128, 129, 132, 133, 136, 137, 140, 141, 130, 131, 134, 135, 138, 139, 142, 143,
	192, 193, 196, 197, 200, 201, 204, 205, 194, 195, 198, 199, 202, 203, 206, 207,
	144, 145, 148, 149, 152, 153, 156, 157, 146, 147, 150, 151, 154, 155, 158, 159,
	208, 209, 212, 213, 216, 217, 220, 221, 210, 211, 214, 215, 218, 219, 222, 223,
	160, 161, 164, 165, 168, 169, 172, 173, 162, 163, 166, 167, 170, 171, 174, 175,
	224, 225, 228, 229, 232, 233, 236, 237, 226, 227, 230, 231, 234, 235, 238, 239,
	176, 177, 180, 181, 184, 185, 188, 189, 178, 179, 182, 183, 186, 187, 190, 191,
	240, 241, 244, 245, 248, 249, 252, 253, 242, 243, 246, 247, 250, 251, 254, 255,
}
@(private, rodata)
clut_off16 := [256]u8 {
	0, 2, 8, 10, 16, 18, 24, 26, 4, 6, 12, 14, 20, 22, 28, 30,
	1, 3, 9, 11, 17, 19, 25, 27, 5, 7, 13, 15, 21, 23, 29, 31,
	32, 34, 40, 42, 48, 50, 56, 58, 36, 38, 44, 46, 52, 54, 60, 62,
	33, 35, 41, 43, 49, 51, 57, 59, 37, 39, 45, 47, 53, 55, 61, 63,
	64, 66, 72, 74, 80, 82, 88, 90, 68, 70, 76, 78, 84, 86, 92, 94,
	65, 67, 73, 75, 81, 83, 89, 91, 69, 71, 77, 79, 85, 87, 93, 95,
	96, 98, 104, 106, 112, 114, 120, 122, 100, 102, 108, 110, 116, 118, 124, 126,
	97, 99, 105, 107, 113, 115, 121, 123, 101, 103, 109, 111, 117, 119, 125, 127,
	128, 130, 136, 138, 144, 146, 152, 154, 132, 134, 140, 142, 148, 150, 156, 158,
	129, 131, 137, 139, 145, 147, 153, 155, 133, 135, 141, 143, 149, 151, 157, 159,
	160, 162, 168, 170, 176, 178, 184, 186, 164, 166, 172, 174, 180, 182, 188, 190,
	161, 163, 169, 171, 177, 179, 185, 187, 165, 167, 173, 175, 181, 183, 189, 191,
	192, 194, 200, 202, 208, 210, 216, 218, 196, 198, 204, 206, 212, 214, 220, 222,
	193, 195, 201, 203, 209, 211, 217, 219, 197, 199, 205, 207, 213, 215, 221, 223,
	224, 226, 232, 234, 240, 242, 248, 250, 228, 230, 236, 238, 244, 246, 252, 254,
	225, 227, 233, 235, 241, 243, 249, 251, 229, 231, 237, 239, 245, 247, 253, 255,
}

// TEX0/TEX2 write: load the CLUT when CLD asks for it. Unchecked: every
// clut index is masked to 511 and every local memory index to its size.
// CSM2 inlines read_raw so each entry skips the call.
@(private)
clut_load :: proc(tex0: u64) #no_bounds_check {
	cbp := u32(tex0 >> 37) & 0x3fff
	switch (tex0 >> 61) & 7 {
	case 0: return
	case 2: cbp0 = cbp
	case 3: cbp1 = cbp
	case 4:
		if cbp == cbp0 {return}
		cbp0 = cbp
	case 5:
		if cbp == cbp1 {return}
		cbp1 = cbp
	case 6, 7: return
	}
	psm := u32(tex0 >> 20) & 0x3f
	cpsm := u32(tex0 >> 51) & 0xf
	csm2 := tex0 & (1 << 55) != 0
	csa := u32(tex0 >> 56) & 0x1f
	n: u32 = (psm == PSMT8 || psm == PSMT8H) ? 256 : 16
	base := csa * 16
	tc := state.regs[0x1c] // TEXCLUT: CBW, COU, COV
	cbw, cou, cov := u32(tc) & 0x3f, u32(tc >> 6) & 0x3f, u32(tc >> 12) & 0x3ff
	// CSM2 reads one row of a cbw-wide buffer; CSM1 at most 4 blocks.
	if csm2 {shown_read(cbp, cbw, cpsm, cov, 1)} else {shown_read_blocks(cbp, cbp + 4)}
	if hw_on {
		hw_clut(cpsm, cbp, cbw, cou, cov, csm2, n, base)
		return
	}
	clut_gen += 1
	if csm2 {
		for i in 0 ..< n {
			clut[(base + i) & 511] = #force_inline read_raw(cpsm, cbp, cbw, cou * 16 + i, cov)
		}
		return
	}
	// CSM1: the entries sit in the blocks at CBP, at constant offsets.
	switch cpsm {
	case PSMCT32:
		w := cbp << 6
		for i in 0 ..< n {clut[(base + i) & 511] = vram[(w + u32(clut_off32[i])) & (VRAM_WORDS - 1)]}
	case PSMCT24:
		w := cbp << 6
		for i in 0 ..< n {clut[(base + i) & 511] = vram[(w + u32(clut_off32[i])) & (VRAM_WORDS - 1)] & 0xffffff}
	case PSMCT16, PSMCT16S:
		h := cbp << 7
		for i in 0 ..< n {clut[(base + i) & 511] = u32(vram16()[(h + u32(clut_off16[i])) & (2 * VRAM_WORDS - 1)])}
	case:
		for i in 0 ..< n {clut[(base + i) & 511] = 0}
	}
}
