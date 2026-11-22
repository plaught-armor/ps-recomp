// The IPU's colour conversion (CSC, and IDEC's output) matches a scalar
// per-pixel copy of its formula on random macroblocks and on the edge
// values: Y 0, 16 and 255, Cb and Cr 0, 128 and 255, TH0 off and on, TH1
// at 0, mid and 0x1ff, and the SGN offset both ways. Each pixel takes the
// chroma sample of its 2x2 block.
//
// FDEC flags the sequence end code 0x000001b7 on CTRL ECD when it sits at
// BP or past the skip, and not otherwise.
package main

import "core:fmt"
import "core:math/rand"
import "core:os"
import ipu "ps:ps2/ipu"

@(private = "file")
csc_ref :: proc(y: [16][16]u8, cb, cr: [8][8]u8, th0, th1: i32, sgn: bool) -> (out: [256]u32) {
	for row in 0 ..< 16 {
		for x in 0 ..< 16 {
			yy := i32(y[row][x])
			b_ := i32(cb[row >> 1][x >> 1]) - 128
			r_ := i32(cr[row >> 1][x >> 1]) - 128
			lum := (0x95 * max(0, yy - 16)) >> 6
			r := clamp((lum + ((0xcc * r_) >> 6) + 1) >> 1, 0, 255)
			g := clamp((lum + ((-0x68 * r_) >> 6) + ((-0x32 * b_) >> 6) + 1) >> 1, 0, 255)
			b := clamp((lum + ((0x102 * b_) >> 6) + 1) >> 1, 0, 255)
			px := u32(r) | u32(g) << 8 | u32(b) << 16
			px |= r < th1 && g < th1 && b < th1 ? 0x40 << 24 : 0x80 << 24
			if sgn {px ~= 0x808080}
			if th0 > 0 && r < th0 && g < th0 && b < th0 {px = sgn ? 0x808080 : 0}
			out[row * 16 + x] = px
		}
	}
	return
}

main :: proc() {
	failed := 0
	rand.reset(1)
	EDGE :: [3]u8{0, 16, 255}
	CEDGE :: [3]u8{0, 128, 255}
	TH :: [3][2]i32{{0, 0}, {0, 0x80}, {0x60, 0x1ff}}
	for n in 0 ..< 4000 {
		y: [16][16]u8
		cb, cr: [8][8]u8
		for &r in y {for &v in r {v = u8(rand.uint32())}}
		for &r in cb {for &v in r {v = u8(rand.uint32())}}
		for &r in cr {for &v in r {v = u8(rand.uint32())}}
		if n < 27 { // every edge triple, flat over the block
			e, c := EDGE, CEDGE
			for &r in y {for &v in r {v = e[n % 3]}}
			for &r in cb {for &v in r {v = c[(n / 3) % 3]}}
			for &r in cr {for &v in r {v = c[n / 9]}}
		}
		th := TH
		t := th[n % 3]
		if n >= 27 && n % 5 == 0 {t = {i32(rand.uint32() & 0x1ff), i32(rand.uint32() & 0x1ff)}}
		sgn := n & 8 != 0
		got := ipu.csc_probe(y, cb, cr, t[0], t[1], sgn)
		want := csc_ref(y, cb, cr, t[0], t[1], sgn)
		for i in 0 ..< 256 {
			if got[i] != want[i] {
				fmt.eprintfln("csc: case %d pixel %d: %08x, want %08x", n, i, got[i], want[i])
				failed += 1
				break
			}
		}
		if failed > 10 {break}
	}
	failed += fdec_end_code()
	if failed > 0 {
		fmt.eprintfln("ipu: %d failed", failed)
		os.exit(1)
	}
	fmt.println("ipu: ok")
}

// FDEC skip over one quadword of stream bytes (first byte in the low
// byte): ECD and the 32 bits it leaves at BP.
@(private = "file")
fdec :: proc(q: u128, skip: u32) -> (ecd: bool, data: u32) {
	ipu.ipu_write(0x10, 1 << 30) // reset
	ipu.ipu_fifo_write(q)
	ipu.ipu_write(0x00, 4 << 28 | skip)
	return ipu.ipu_read(0x10) & (1 << 14) != 0, u32(ipu.ipu_read(0x00))
}

@(private = "file")
fdec_end_code :: proc() -> (failed: int) {
	Case :: struct {
		q:    u128,
		skip: u32,
		ecd:  bool,
		data: u32,
	}
	CASES :: [?]Case {
		{0xb7010000, 0, true, 0x000001b7}, // at BP
		{0xb7010000_78563412, 32, true, 0x000001b7}, // past the skip
		{0xb7010000_78563412, 0, false, 0x12345678}, // 32 bits past BP, no skip
		{0xf0debc9a_78563412, 32, false, 0x9abcdef0},
		{0xb3010000_78563412, 32, false, 0x000001b3}, // another start code
	}
	for c, i in CASES {
		ecd, data := fdec(c.q, c.skip)
		if ecd != c.ecd || data != c.data {
			fmt.eprintfln("fdec: case %d: ecd %v data %08x, want %v %08x", i, ecd, data, c.ecd, c.data)
			failed += 1
		}
	}
	return
}
