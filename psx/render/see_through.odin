// See-through: what stands between the host camera and the focus is faded
// per pixel, by real depth, the way modern third-person games keep the
// player in view (not a PS1 feature).
//
// Terms: the host camera is the port's own camera (cpu.host_camera), which
// builds the view and calls see_through_set; the focus is the point it keeps
// in view (see_through_set's `target`), say the player character, with a
// middle and feet below it.
//
// The PS1 has no depth buffer, so depth is recovered as PGXP's vertex cache
// does it: every GTE projection (RTPS/RTPT) files the screen x, y it produced
// under its view depth (depth_tag), and when a polygon packet reaches the GPU
// its corners are looked up by the x, y the game copied into it (depth_fill;
// where vertices at different depths met at one pixel, the one projected with
// the polygon's other corners). The rasterizer interpolates 1 / depth across
// the polygon, and each pixel's opacity comes from see_alpha:
// - Pixels right in front of the lens are not drawn at all, fading in from
//   see_fade.near[0] to [1]: what the camera sits in is cut away.
// - A face covers the focus when its plane has the lens on one side and the
//   focus's middle on the other (see_cover): walls turned to the camera in
//   front of it, roofs over it. Only such a face's pixels that hide it
//   are ghosts: those nearer than the focus and inside the cone from the
//   lens to see_fade.radius round its middle, so on screen a disc about its
//   sprite, the same size however near the lens the face stands. Ghosts are
//   more opaque the nearer the focus, from see_fade.ghost[0] at the camera
//   to [1] at it.
// - Every one of those choices fades over a margin (see_fade.soft and the
//   game's own)
//   instead of switching: a face whose plane passes close to the focus or
//   the lens is half ghosted, so a face does not pop between solid and ghost
//   as the camera moves. A quad is judged as one face, so its two triangles
//   never disagree.
// - Everything else (the ground, walls beside or past it) is drawn as usual.
// Faces turned away from the lens stay dropped by the game (NCLIP): the
// walls of a building the camera is over do not show, only its roof.
//
// Which faces cover the focus, and the sprites and black fill that take part,
// is the game's to say (scene_hooks prim_classify): it hands each polygon a
// See_Cover, and its fade margins and opacities in see_fade.
//
// Ghosts are drawn into the GPU's ghost layer and laid over the scene before
// the HUD (gpu_ghost_flush), the nearest one at a pixel the only one shown;
// a solid pixel drawn nearer than a ghost takes the pixel back. Packets
// without projected corners (character sprites, shadows, the HUD) are
// drawn as usual; one drawn over a ghost before the flush stands before it
// in the ordering table, so the ghost is laid down under it first.
package psx_render

import "base:intrinsics"
import "core:math/linalg"
import cpu "../cpu"
import gte "../gte"

// The game's fade margins and opacities (view units, 128 a grid cell), set
// once at start.
See_Fade :: struct {
	// The depths over which the lens's cut fades in.
	near:         [2]f32,
	// The radius of the ghosted cone at the focus and the width of its
	// soft edge there (both shrink toward the lens).
	radius, soft: f32,
	// The share of radius the cone keeps at the lens, so it never closes.
	cone_min:     f32,
	// The stretch before the focus left solid.
	gap:          f32,
	// Below the focus's feet (shrinking toward the lens as the cone does)
	// where the cone is cut off, softly between the two.
	floor:        [2]f32,
	// Opacity at the camera's and at the focus's end of the tube, for a
	// face and for a sprite.
	ghost:        [2]f32,
	sprite_ghost: [2]f32,
}

see_fade: See_Fade

// Vblanks a see_through setting stays good for after its stamp.
@(private)
SEE_VBLANKS :: 2

// Set by the host camera for the view it just built.
see_through: struct {
	on:     bool,
	stamp:  u64,
	// The projection: GTE H and screen offset.
	h:      f32,
	of:     [2]f32,
	// The focus's middle and world up, in view space.
	target: [3]f32,
	up:     [3]f32,
	// How far the focus's middle stands above its feet.
	rise:   f32,
}

// How a face stands to the focus: how much it is in the way (0 not, 1 its
// plane well between it and the lens); whether it is a sprite; the share of
// it faded out on top of that (a sprite's Flat.clear).
See_Cover :: struct {
	weight: f32,
	sprite: bool,
	clear:  f32,
}

// Set while the ordering-table walk draws with see_through; `direct` once
// the ghost layer has been laid down (bucket 0), so ghosts blend straight
// into VRAM.
see: struct {
	active, direct: bool,
	// From see_through: |target|^2 and the share of the way to the focus
	// past which nothing is faded.
	reach2, stop:   f32,
	// World up's part across the line to the focus (its length the sine
	// of the camera's tilt from looking straight down, so the floor cut
	// fades out as the camera looks down on it) and its feet's distance
	// along it under its middle, at the focus: see_cover_alpha's floor.
	across:         [3]f32,
	drop:           f32,
	// The walk's depth buffer key (z_walk_begin), with a hi-res target.
	z_key:          u32,
}

// Turn see-through on for the view just built: the GTE's projection, the
// focus's middle `target` and world `up` in view space, and how far its
// middle `rise`s above its feet.
see_through_set :: proc(target, up: [3]f32, rise: f32) {
	see_through = {
		on     = true,
		stamp  = cpu.vblanks(),
		h      = f32(gte.state.h),
		of     = [2]f32{f32(gte.state.ofx), f32(gte.state.ofy)} / 0x10000,
		target = target,
		up     = up,
		rise   = rise,
	}
}

// Start an ordering-table walk: see-through applies when set lately.
see_begin :: proc() {
	s := &see_through
	see = {}
	if !s.on || cpu.vblanks() - s.stamp > SEE_VBLANKS || s.h <= 0 {
		return
	}
	reach2 := linalg.dot(s.target, s.target)
	if reach2 < 1 {
		return
	}
	across := s.up - s.target * (linalg.dot(s.up, s.target) / reach2)
	see = {
		active = true,
		reach2 = reach2,
		stop   = 1 - see_fade.gap / linalg.sqrt(reach2),
		across = across,
		drop   = s.rise * linalg.dot(across, across),
	}
	if target_count == 2 {
		see.z_key = z_walk_begin()
	}
}

// End a walk: the vertices filed for it are spent.
see_end :: proc() {
	see = {}
	depth_cache.now += 1
	depth_cache.seq = 0
}

// The view-space point at packet screen position x, y and view depth z.
see_point :: #force_inline proc(x, y, z: f32) -> [3]f32 {
	s := &see_through
	return unproject(x, y, z, s.h, s.of)
}

// Opacity of a pixel at packet screen position x, y and view depth z, on a
// face covering the focus as `cover` says. Most pixels are on faces that do
// not cover it: those only take the lens's cut, here without a call.
see_alpha :: #force_inline proc(x, y, z: f32, cover: See_Cover) -> f32 #no_bounds_check {
	if cover.weight <= 0 {
		return smooth(see_fade.near[0], see_fade.near[1], z) * (1 - cover.clear)
	}
	return see_cover_alpha(x, y, z, cover) * (1 - cover.clear)
}

// The margin by which a pixel's squared distance from the line to the focus
// passes the cone's squared radius when its distance, rounded, is surely
// past the radius: well over the few float roundings between the two.
@(private = "file")
CONE_MARGIN :: f32(1.001)

@(private = "file")
see_cover_alpha :: proc(x, y, z: f32, cover: See_Cover) -> f32 #no_bounds_check {
	f := &see_fade
	near := smooth(f.near[0], f.near[1], z)
	if cover.weight <= 0 || near <= 0 {
		return near
	}
	s := &see_through
	p := see_point(x, y, z)
	t := dot3(p, s.target) / see.reach2
	if t >= see.stop {
		return near
	}
	t = max(t, 0)
	v := p - s.target * t
	r := max(t, f.cone_min)
	cone := [2]f32{(f.radius - f.soft) * r, f.radius * r}
	cut := [2]f32{f.floor[0] * r, f.floor[1] * r}
	// Past the cone's edge `inside` is 0 and the result `near`, as long as
	// every term it multiplies is a number: skip the square root and the
	// rest.
	d2 := dot3(v, v)
	if cone[0] < cone[1] && cut[0] < cut[1] && see.stop > 0 && d2 >= cone[1] * cone[1] * CONE_MARGIN {
		return near
	}
	d := intrinsics.sqrt(d2)
	// How far below the line from the lens to its feet.
	below := -dot3(v, see.across) - see.drop * r
	inside := cover.weight * (1 - smooth(cone[0], cone[1], d)) * (1 - smooth(cut[0], cut[1], below))
	g := cover.sprite ? f.sprite_ghost : f.ghost
	ghost := g[0] + (g[1] - g[0]) * t / see.stop
	return min(near, 1 - inside * (1 - ghost))
}

// linalg.dot, inlined: the same sum in the same order.
@(private = "file")
dot3 :: #force_inline proc "contextless" (a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

// 0 at or below lo, 1 at or above hi and smoothly between. The ends are
// taken without the divide, to the same value: past either, the quotient
// clamps to it.
smooth :: #force_inline proc(lo, hi, v: f32) -> f32 {
	if hi > lo {
		if v >= hi {
			return 1
		}
		if v <= lo {
			return 0
		}
	}
	t := clamp((v - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}
