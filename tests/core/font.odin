package main

import "core:fmt"
import "core:os"
import "ps:core"

// core.font_glyph: a glyph's pixels at scale 1, the same pixels as squares
// at scale 2, clipping at the picture's edges, nothing for a byte outside
// ASCII 32..126.
test_font :: proc() {
	W :: 20
	one: [W * W]u32
	two: [W * W]u32
	core.font_glyph(one[:], W, '!', 0, 0, 1)
	core.font_glyph(two[:], W, '!', 0, 0, 1, 2)
	ok := true
	// '!' is {0x18, 0x3c, 0x3c, 0x18, 0x18, 0x00, 0x18, 0x00}: bit 0 leftmost.
	bang := [8]u8{0x18, 0x3c, 0x3c, 0x18, 0x18, 0x00, 0x18, 0x00}
	for y in 0 ..< 8 {
		for x in 0 ..< 8 {
			want := u32(bang[y] >> u8(x) & 1)
			if one[y * W + x] != want || two[2 * y * W + 2 * x] != want || two[(2 * y + 1) * W + 2 * x + 1] != want {
				ok = false
			}
		}
	}
	// Half off every edge: no out-of-range write, the inside drawn.
	edge: [W * W]u32
	for p in ([4][2]int{{-4, 0}, {W - 4, 0}, {0, -4}, {0, W - 4}}) {
		core.font_glyph(edge[:], W, '#', p[0], p[1], 1, 1)
	}
	lit := 0
	for v in edge {lit += int(v)}
	none: [W * W]u32
	core.font_glyph(none[:], W, 200, 0, 0, 1)
	core.font_glyph(none[:], W, 31, 0, 0, 1)
	for v in none {if v != 0 {ok = false}}
	if !ok || lit == 0 {
		fmt.eprintln("FAIL font_glyph")
		os.exit(1)
	}
	fmt.println("ok font_glyph")
}
