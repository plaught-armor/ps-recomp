// PS1 VRAM uploads (GP0 A0): a block of words through gp0_write_words, as
// DMA sends it, writes VRAM and the hi-res target exactly as the same words
// through gp0_write one at a time, and both match vram_put a pixel at a
// time, as uploads wrote before.
// The cases cross VRAM's right edge mid-row (the row wraps to x 0), end on
// a word's low pixel (its high one dropped, the next word a command), and
// run under the mask bits (check_mask keeps a set pixel, set_mask sets bit
// 15 on each written one).
package main

import "core:fmt"
import "core:os"
import gpu "ps:psx/gpu"
import render "ps:psx/render"

@(private = "file")
failed: int

@(private = "file")
fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL psx_gpu_upload: ")
	fmt.eprintfln(format, ..args)
	failed += 1
	if failed > 20 {
		os.exit(1)
	}
}

@(private = "file")
Case :: struct {
	name:                string,
	x, y, w, h:          i32,
	check_mask, set_mask: bool,
}

// VRAM before each run: a pattern with bit 15 set on every third pixel.
@(private = "file")
vram_reset :: proc() {
	for &p, i in render.vram {
		p = u16(i * 7) & 0x7fff | (i % 3 == 0 ? 0x8000 : 0)
	}
	if render.target_count == 2 {
		for &c in render.targets[1].rgb {c = 0}
	}
	gpu.gp.uploading = false
	gpu.gp.need = 0
	gpu.gp.polyline = false
}

// The words of case c: the A0 command, its pixels, then a nop.
@(private = "file")
words_of :: proc(c: Case) -> []u32 {
	n := int(c.w * c.h)
	out := make([dynamic]u32, context.temp_allocator)
	append(&out, 0xa0000000, u32(c.y) << 16 | u32(c.x), u32(c.h) << 16 | u32(c.w))
	for i := 0; i < n; i += 2 {
		lo := u32(0x1000 + i) & 0x7fff
		// An odd count's dropped high half reads as GP0 02 (a fill, which
		// would take the nop and wait on one more word) if it is not dropped.
		hi := i + 1 < n ? u32(0x1000 + i + 1) & 0x7fff : 0x0200
		append(&out, hi << 16 | lo)
	}
	append(&out, 0) // a nop
	return out[:]
}

main :: proc() {
	render.render_targets_set(2)
	cases := []Case {
		{"plain", 100, 50, 16, 4, false, false},
		{"wrap", 1016, 10, 20, 3, false, false},
		{"odd", 200, 300, 5, 3, false, false},
		{"masks", 1020, 511, 9, 3, true, true},
		{"check", 64, 64, 33, 7, true, false},
		{"wide", 0, 0, 1024, 2, false, true},
	}
	want := make([]u16, len(render.vram))
	one := make([]u16, len(render.vram))
	want_hi := make([]u32, len(render.targets[1].rgb))
	one_hi := make([]u32, len(render.targets[1].rgb))
	for c in cases {
		words := words_of(c)
		// The model: each pixel in turn through vram_put, as an upload
		// wrote them before runs, wrapping in x and y.
		vram_reset()
		for i in 0 ..< c.w * c.h {
			x, y := c.x + i % c.w, c.y + i / c.w
			if c.check_mask && render.vram_at(x, y)^ & 0x8000 != 0 {continue}
			render.vram_put(x, y, u16(0x1000 + i) & 0x7fff | (c.set_mask ? 0x8000 : 0))
		}
		copy(want, render.vram[:])
		copy(want_hi, render.targets[1].rgb)

		vram_reset()
		render.gpu.check_mask, render.gpu.set_mask = c.check_mask, c.set_mask
		for w in words {gpu.gp0_write(w)}
		copy(one, render.vram[:])
		copy(one_hi, render.targets[1].rgb)
		uploading, need := gpu.gp.uploading, gpu.gp.need

		vram_reset()
		render.gpu.check_mask, render.gpu.set_mask = c.check_mask, c.set_mask
		gpu.gp0_write_words(words)
		if uploading || gpu.gp.uploading || need != 0 || gpu.gp.need != 0 {
			fail("%s: upload or command open after the nop (one at a time %v, %d words, block %v, %d)", c.name, uploading, need, gpu.gp.uploading, gpu.gp.need)
		}
		for i in 0 ..< len(want) {
			if one[i] != want[i] || render.vram[i] != want[i] {
				fail("%s: VRAM %d,%d one at a time %4x, block %4x, model %4x", c.name, i % render.VRAM_W, i / render.VRAM_W, one[i], render.vram[i], want[i])
				break
			}
		}
		for i in 0 ..< len(want_hi) {
			if one_hi[i] != want_hi[i] || render.targets[1].rgb[i] != want_hi[i] {
				fail("%s: hi-res target pixel %d one at a time %8x, block %8x, model %8x", c.name, i, one_hi[i], render.targets[1].rgb[i], want_hi[i])
				break
			}
		}
		free_all(context.temp_allocator)
	}
	if failed > 0 {
		os.exit(1)
	}
	fmt.println("ok psx_gpu_upload")
}
