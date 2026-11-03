// Thumbnails: the picture a game last showed, shrunk to THUMB_W x THUMB_H
// and kept as its disc directory's thumb.ppm (data.odin) for the launcher.
// play sets thumb_path; a runtime calls thumb_save where a run ends well
// (the player quit, or a COMPAT run reached FRAMES). The file is a binary
// PPM (P6): no compression, so no inflate code to read it back.
package core

import "core:fmt"
import "core:os"
import "core:strconv"

THUMB_W :: 160
THUMB_H :: 120

// The largest picture ppm_parse accepts, in pixels per side.
PPM_MAX :: 4096

// How a u32 pixel holds its color: red in bits 16-23 (XRGB) or in bits 0-7
// (XBGR); the top byte is unused.
Pixel_Order :: enum {
	Xrgb,
	Xbgr,
}

// Where thumb_save writes; "" writes nothing.
thumb_path: string

// The w x h picture px (rows stride pixels apart) shrunk to THUMB_W x
// THUMB_H RGB888, rows top first: each pixel the average of the box of
// source pixels it covers (at least one). In temp memory.
thumb_make :: proc(px: []u32, stride, w, h: int, order: Pixel_Order) -> []u8 {
	assert(w > 0 && h > 0 && stride >= w && len(px) >= (h - 1) * stride + w)
	out := make([]u8, THUMB_W * THUMB_H * 3, context.temp_allocator)
	red: uint = order == .Xrgb ? 16 : 0
	blue: uint = 16 - red
	for ty in 0 ..< THUMB_H {
		y0 := ty * h / THUMB_H
		y1 := max((ty + 1) * h / THUMB_H, y0 + 1)
		for tx in 0 ..< THUMB_W {
			x0 := tx * w / THUMB_W
			x1 := max((tx + 1) * w / THUMB_W, x0 + 1)
			sum: [3]int
			for y in y0 ..< y1 {
				for c in px[y * stride + x0:][:x1 - x0] {
					sum += {int(c >> red & 0xff), int(c >> 8 & 0xff), int(c >> blue & 0xff)}
				}
			}
			n := (y1 - y0) * (x1 - x0)
			o := (ty * THUMB_W + tx) * 3
			out[o], out[o + 1], out[o + 2] = u8(sum.r / n), u8(sum.g / n), u8(sum.b / n)
		}
	}
	return out
}

// Write the w x h picture px (rows stride pixels apart) to thumb_path as a
// thumbnail, whole (tmp + rename). Nothing without a path or a picture; a
// failure is only reported: the run it ends is not affected.
thumb_save :: proc(px: []u32, stride, w, h: int, order: Pixel_Order) {
	if thumb_path == "" || w <= 0 || h <= 0 || stride < w || len(px) < (h - 1) * stride + w {
		return
	}
	data := ppm_encode(THUMB_W, THUMB_H, thumb_make(px, stride, w, h, order))
	if err := write_file_atomic(thumb_path, data); err != nil {
		fmt.eprintln("cannot write", thumb_path, err)
	}
}

// A w x h picture of RGB888 pixels, rows top first, as a binary PPM file.
// In temp memory.
ppm_encode :: proc(w, h: int, rgb: []u8) -> []u8 {
	assert(len(rgb) == w * h * 3)
	header := fmt.tprintf("P6\n%d %d\n255\n", w, h)
	out := make([]u8, len(header) + len(rgb), context.temp_allocator)
	copy(out, header)
	copy(out[len(header):], rgb)
	return out
}

// The size and RGB888 pixels of a binary PPM file (P6, maxval 255, `#`
// comments in the header); the pixels are a slice of data. False for any
// other file, one larger than PPM_MAX a side, or one cut short.
ppm_parse :: proc(data: []u8) -> (w, h: int, rgb: []u8, ok: bool) {
	if len(data) < 2 || data[0] != 'P' || data[1] != '6' {
		return
	}
	at := 2
	fields: [3]int
	for &f in fields {
		// Whitespace and comments, then at least one digit.
		for at < len(data) {
			switch data[at] {
			case ' ', '\t', '\n', '\r', '\v', '\f':
				at += 1
				continue
			case '#':
				for at < len(data) && data[at] != '\n' {
					at += 1
				}
				continue
			}
			break
		}
		start := at
		for at < len(data) && data[at] >= '0' && data[at] <= '9' && at - start < 5 {
			at += 1
		}
		v, parsed := strconv.parse_int(string(data[start:at]), 10)
		if !parsed || (at < len(data) && data[at] >= '0' && data[at] <= '9') {
			return
		}
		f = v
	}
	w, h = fields[0], fields[1]
	// One whitespace byte ends the header.
	if fields[2] != 255 || w <= 0 || h <= 0 || w > PPM_MAX || h > PPM_MAX || at >= len(data) {
		return
	}
	switch data[at] {
	case ' ', '\t', '\n', '\r', '\v', '\f':
	case:
		return
	}
	at += 1
	if len(data) - at < w * h * 3 {
		return
	}
	return w, h, data[at:][:w * h * 3], true
}

// The thumbnail at path: THUMB_W x THUMB_H RGB888 in `allocator`, nil when
// it is missing or not a thumbnail.
thumb_load :: proc(path: string, allocator := context.allocator) -> []u8 {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil
	}
	w, h, rgb, ok := ppm_parse(data)
	if !ok || w != THUMB_W || h != THUMB_H {
		return nil
	}
	out := make([]u8, len(rgb), allocator)
	copy(out, rgb)
	return out
}
