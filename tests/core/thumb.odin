package main

import "core:fmt"
import "core:os"
import "core:slice"
import "ps:core"

// core.thumb_make: box averages, either pixel order, a row stride past the
// width, a picture smaller than the thumbnail. core.ppm_parse: what
// ppm_encode writes, a header comment, and the files it must refuse.
// core.thumb_save and core.thumb_load: a round trip, nothing without a
// path.
test_thumb :: proc() {
	fails := 0
	fail :: proc(fails: ^int, what: string) {
		fmt.eprintln("FAIL thumb:", what)
		fails^ += 1
	}
	// 320 x 240, left half red, right half blue, with a white margin past
	// each row that a stride mistake would mix in.
	W, H, STRIDE :: 320, 240, 328
	split := make([]u32, STRIDE * H, context.temp_allocator)
	for y in 0 ..< H {
		for x in 0 ..< STRIDE {
			split[y * STRIDE + x] = x < W / 2 ? 0xff0000 : x < W ? 0x0000ff : 0xffffff
		}
	}
	at :: proc(t: []u8, x, y: int) -> [3]u8 {
		o := (y * core.THUMB_W + x) * 3
		return {t[o], t[o + 1], t[o + 2]}
	}
	t := core.thumb_make(split, STRIDE, W, H, .Xrgb)
	if at(t, 0, 0) != {255, 0, 0} || at(t, 79, 119) != {255, 0, 0} || at(t, 80, 0) != {0, 0, 255} || at(t, 159, 119) != {0, 0, 255} {
		fail(&fails, "XRGB split")
	}
	tb := core.thumb_make(split, STRIDE, W, H, .Xbgr)
	if at(tb, 0, 0) != {0, 0, 255} || at(tb, 159, 0) != {255, 0, 0} {
		fail(&fails, "XBGR split")
	}
	// Black and white columns average to grey.
	stripes := make([]u32, W * H, context.temp_allocator)
	for &c, i in stripes {
		c = i % 2 == 0 ? 0 : 0xffffff
	}
	if at(core.thumb_make(stripes, W, W, H, .Xrgb), 40, 60) != {127, 127, 127} {
		fail(&fails, "box average")
	}
	// 4 x 3: each source pixel covers a block of the thumbnail.
	small := [12]u32{0x010203, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x040506}
	ts := core.thumb_make(small[:], 4, 4, 3, .Xrgb)
	if at(ts, 0, 0) != {1, 2, 3} || at(ts, 39, 39) != {1, 2, 3} || at(ts, 159, 119) != {4, 5, 6} || at(ts, 40, 0) != {0, 0, 0} {
		fail(&fails, "small picture")
	}

	ppm := core.ppm_encode(core.THUMB_W, core.THUMB_H, t)
	if w, h, rgb, ok := core.ppm_parse(ppm); !ok || w != core.THUMB_W || h != core.THUMB_H || !slice.equal(rgb, t) {
		fail(&fails, "ppm round trip")
	}
	if w, h, rgb, ok := core.ppm_parse(transmute([]u8)string("P6 # made by hand\n2\t1\n255\nabcdef")); !ok || w != 2 || h != 1 || string(rgb) != "abcdef" {
		fail(&fails, "ppm with a comment")
	}
	bad := [?]string {
		"P3\n2 1\n255\nabcdef", // text PPM
		"P6\n2 1\n65535\nabcdefabcdef", // 16-bit
		"P6\n2 1\n255\nabcde", // cut short
		"P6\n0 1\n255\n",
		"P6\n4097 1\n255\n",
		"P6\n123456 1\n255\n",
		"P6\n2 1\n255",
		"P6\n2 1\n255x",
		"P6\n2\n",
		"",
	}
	for b in bad {
		if _, _, _, ok := core.ppm_parse(transmute([]u8)b); ok {
			fail(&fails, fmt.tprintf("ppm %q parsed", b))
		}
	}

	path :: "thumb_test.ppm"
	core.thumb_path = ""
	core.thumb_save(split, STRIDE, W, H, .Xrgb)
	if os.exists(path) {
		fail(&fails, "saved with no path")
	}
	core.thumb_path = path
	core.thumb_save(split, STRIDE, W, H, .Xrgb)
	core.thumb_save(split, STRIDE, 0, H, .Xrgb) // no picture: the file stays
	back := core.thumb_load(path, context.temp_allocator)
	if !slice.equal(back, t) {
		fail(&fails, "load after save differs")
	}
	core.thumb_path = ""
	_ = os.write_entire_file(path, transmute([]u8)string("P6\n2 1\n255\nabcdef"))
	if core.thumb_load(path, context.temp_allocator) != nil {
		fail(&fails, "loaded a picture that is not THUMB_W x THUMB_H")
	}
	_ = os.remove(path)
	if core.thumb_load(path, context.temp_allocator) != nil {
		fail(&fails, "loaded a missing file")
	}
	if fails != 0 {
		os.exit(1)
	}
	fmt.println("ok thumb")
}
