// Door pictures: a picture drawn elsewhere laid over the pixels a
// door's back drew (not a PS1 feature).
//
// Terms:
// - door: an opening in the scene (a doorway, a gate) that the game draws
//   as a back standing for what lies beyond it.
// - back: the polygons the game draws in a door's opening, a black fill or
//   a far wall; the picture replaces their pixels.
// - room: the scene the frame draws, around the door.
// - cover: a picture laid over the whole frame, not only a back, with an
//   opening (Cover_Hole) where the room shows through: the scene beyond a
//   door laid over the room the camera is leaving.
// - curtain: the black a cover's own scene draws in its door; the room
//   shows there.
//
// When the game wants it (scene_hooks walk_doors), the ordering-table walk
// notes per pixel which door back drew it (Target.door, pixel_door_put;
// the game says which polygon is whose back, prim_classify). Before the HUD
// (bucket 0), or failing that at the walk's end, picture_flush hands the
// game the chance to lay its pictures over those pixels (doors_lay,
// lay_picture): the back gives way to what lies beyond it, while anything
// drawn over it later stays.
package psx_render

import "core:slice"
import gte "../gte"

// A picture at the hi-res target's resolution (picture_take): its pixels,
// or with the GL target a texture of the GPU's, tex_w x tex_h, holding it
// when `held`.
Picture_Hi :: struct {
	pix:          [dynamic]u32,
	tex:          u32,
	tex_w, tex_h: i32,
	held:         bool,
}

// Forget the picture hi holds (its storage is kept).
picture_hi_clear :: proc(hi: ^Picture_Hi) {
	clear(&hi.pix)
	hi.held = false
}

// Make dst hold the picture src does.
picture_hi_copy :: proc(dst, src: ^Picture_Hi) {
	resize(&dst.pix, len(src.pix))
	copy(dst.pix[:], src.pix[:])
	dst.held = false
	if src.held {
		gl_picture_copy(dst, src)
	}
}

// A picture to lay (lay_picture): w x h pixels, at packet positions 0..w,
// 0..h, and the same at the hi-res target's resolution (nil: none).
Lay :: struct {
	pixels: []u16,
	hi:     ^Picture_Hi,
	w, ht:  i32,
	// Drawn for another view than the frame's (an in-between picture,
	// smooth motion): the frame's screen point (x, y, 1) is the picture's
	// `warp` * (x, y, 1), through a plane both views see.
	warp:   matrix[3, 3]f32,
	warped: bool,
	// Laid over the scene: its opening on the picture, and how much of the
	// picture is mixed in.
	hole:   Cover_Hole,
	alpha:  f32,
	// Laid black where it is black.
	blank:  bool,
}

// A picture's opening on it (packet positions): the
// edges (a, b, c: a x + b y + c >= 0 inside) of its outline and how many
// (0: none in sight).
Cover_Hole :: struct {
	edges: [MAX_HOLE][3]f32,
	n:     int,
}

// Target.door of a pixel the frame's clear (a fill) drew last.
DOOR_CLEAR :: 0xff
// Target.door of a pixel the game tags as the room's own under a cover.
DOOR_COVER :: 0xfe
// Corners the outline of a picture's opening may have.
MAX_HOLE :: 8

// The address of the packet the walk is drawing.
packet_now: u32

// Each target notes per pixel the picture (index + 1) whose door back
// drew it in the walk (0 none, Target.door), valid where Target.walk matches
// depth_walk.now.
depth_walk: struct {
	// The walk keeps pixel depths: pictures wait for it.
	on:  bool,
	now: u16,
}

// Whether packet position x, y of picture p lies within its opening.
@(private)
in_hole :: #force_inline proc(p: ^Lay, x, y: f32) -> bool {
	if p.hole.n == 0 {
		return false
	}
	for e in p.hole.edges[:p.hole.n] {
		if e.x * x + e.y * y + e.z < 0 {
			return false
		}
	}
	return true
}

// Start a walk: polygon depths are kept when the game's door pictures
// wait for it.
picture_walk_begin :: proc() {
	depth_walk.on = scene.walk_doors != nil && scene.walk_doors()
	if depth_walk.on {
		depth_walk.now += 1
		if depth_walk.now == 0 {
			for &t in live_targets() {
				if t.gl {
					gl_walks_clear()
				}
				slice.zero(t.walk)
			}
			depth_walk.now = 1
		}
	}
}

// Note a solid pixel at target t's index i, drawn by the back of picture `door`
// (index + 1, 0 none).
@(private)
pixel_door_put :: #force_inline proc(t: ^Target, i: i32, door: u8) #no_bounds_check {
	t.door[i] = door
	t.walk[i] = depth_walk.now
}

// Lay the walk's door pictures over its scene (scene_hooks doors_lay).
// Runs before the HUD (bucket 0) and, failing that, at the walk's end.
picture_flush :: proc() {
	if !depth_walk.on {
		return
	}
	raster_sync()
	depth_walk.on = false
	if scene.doors_lay != nil {
		scene.doors_lay()
	}
}

// Lay picture p over every drawn target's pixels the door back `door`
// drew (index + 1, or DOOR_CLEAR), and with `outside` also over those so
// tagged but where its opening shows (in_hole).
lay_picture :: proc(p: ^Lay, door: u8, outside: Maybe(u8) = nil) {
	for &t in drawn_targets() {
		picture_lay(&t, p, door, outside)
	}
}

// Lay picture p over target t's pixels its door back drew, and a cover also
// over those tagged `outside` but where its opening shows (in_hole). A picture
// without pixels at t's resolution is laid as blocks of its VRAM pixels.
@(private)
picture_lay :: proc(t: ^Target, p: ^Lay, door: u8, outside: Maybe(u8) = nil) #no_bounds_check {
	k := t.shift
	pw := p.w << k
	hi := false
	if t.shift > 0 && p.hi != nil {
		hi = t.gl ? p.hi.held && p.hi.tex_w == pw && p.hi.tex_h == p.ht << k : i64(len(p.hi.pix)) >= i64(pw) * i64(p.ht << k)
	}
	// The back's pixels, not the opening's outline, bound the picture: the
	// back may reach past the opening's sides.
	x0 := max(0, (gpu.x1 - gpu.off_x) << k)
	y0 := max(0, (gpu.y1 - gpu.off_y) << k)
	x1 := min(((gpu.x2 - gpu.off_x + 1) << k) - 1, pw - 1)
	y1 := min(((gpu.y2 - gpu.off_y + 1) << k) - 1, (p.ht << k) - 1)
	if k > 0 {
		hi_touch((x0 >> k) + gpu.off_x, (y0 >> k) + gpu.off_y, (x1 >> k) - (x0 >> k) + 1, (y1 >> k) - (y0 >> k) + 1)
	}
	if t.gl {
		if x0 <= x1 && y0 <= y1 {
			gl_picture_lay(p, door, outside, x0, y0, x1, y1, hi)
		}
		return
	}
	if k > 0 {
		picture_rows(u32, t, p, door, outside, hi, x0, y0, x1, y1)
	} else {
		picture_rows(u16, t, p, door, outside, hi, x0, y0, x1, y1)
	}
}

// picture_lay's software drawing, over pixels of type P (target_pix).
@(private)
picture_rows :: proc($P: typeid, t: ^Target, p: ^Lay, door: u8, outside: Maybe(u8), hi: bool, x0, y0, x1, y1: i32) #no_bounds_check {
	k := t.shift
	pw := p.w << k
	pix := target_pix(t, P)
	M := pixel_kept(P)
	// A warped picture is read where the warp takes each pixel (packet
	// positions; the hi-res target's are 1 << k to one).
	scale := f32(i32(1) << u32(k))
	step := [3]f32{p.warp[0, 0], p.warp[1, 0], p.warp[2, 0]} / scale
	for y in y0 ..= y1 {
		at := p.warp * [3]f32{f32(x0) / scale, f32(y) / scale, 1}
		for x in x0 ..= x1 {
			from := at
			at += step
			i := target_index(t, x + gpu.off_x << k, y + gpu.off_y << k)
			if t.walk[i] != depth_walk.now {
				continue
			}
			back := t.door[i] == door
			if !back {
				o, cover := outside.?
				if !cover || t.door[i] != o {
					continue
				}
			}
			px, py := x, y
			if p.warped {
				if from.z <= 0 {
					continue
				}
				px = i32(from.x / from.z * scale + 0.5)
				py = i32(from.y / from.z * scale + 0.5)
				// A cover covers the frame to its edges: its own edge
				// stands for what lies past it.
				if outside == nil {
					if px < 0 || py < 0 || px >= pw || py >= p.ht << k {
						continue
					}
				}
				px, py = clamp(px, 0, pw - 1), clamp(py, 0, (p.ht << k) - 1)
			}
			c: P
			when P == u32 {
				c = hi ? p.hi.pix[py * pw + px] : hi_pixel(p.pixels[(py >> k) * p.w + (px >> k)])
			} else {
				c = p.pixels[(py >> k) * p.w + (px >> k)]
			}
			// The cover's scene shows its door's curtain (left out, black)
			// there: the room's own drawn shows through.
			if !back && pixel_black(c) && in_hole(p, (f32(px) + 0.5) / scale, (f32(py) + 0.5) / scale) {
				continue
			}
			// Nothing of the room drawn there (its black curtain is left
			// out): the cover scene's own back shows. A cover's black is
			// that scene's sky.
			if pixel_black(c) && outside == nil && !p.blank {
				continue
			}
			if p.alpha > 0 && p.alpha < 1 {
				c = fade_mix(pix[i], c, p.alpha)
			}
			pix[i] = c &~ M | pix[i] & M
			when P == u32 {
				if c & HI_GLOW != 0 {
					bloom_mark(t, x + gpu.off_x << k, y + gpu.off_y << k)
				}
			}
		}
	}
}

// Copy the VRAM area x, y, w x h into `pixels`, and the same area of the
// hi-res target into `hi`, made to fit; hi is left empty without that
// target. For a door picture.
picture_take :: proc(x, y, w, h: i32, pixels: []u16, hi: ^Picture_Hi) #no_bounds_check {
	raster_sync()
	hi_touch(x, y, w, h)
	for row in 0 ..< h {
		for col in 0 ..< w {
			pixels[row * w + col] = vram_at(x + col, y + row)^
		}
	}
	picture_hi_clear(hi)
	if target_count < 2 {
		return
	}
	t := &targets[1]
	k := t.shift
	if t.gl {
		gl_picture_take(hi, x << k, y << k, w << k, h << k)
		return
	}
	resize(&hi.pix, int(w << k) * int(h << k))
	for row in 0 ..< h << k {
		for col in 0 ..< w << k {
			hi.pix[row * (w << k) + col] = t.rgb[target_index(t, x << k + col, y << k + row)]
		}
	}
}

// The GTE's projection: H, and the screen offset as packets hold positions.
gte_projection :: proc() -> (h: u32, of: [2]f32) {
	return gte.state.h, [2]f32{f32(gte.state.ofx), f32(gte.state.ofy)} / 0x10000
}

gte_set_h :: proc(h: u32) {
	gte.state.h = h
}
