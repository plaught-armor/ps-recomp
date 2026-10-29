// Masks: a packet drawn only inside, or only outside, a convex shape on
// screen (not a PS1 feature).
//
// The game points mask_now at the mask of each packet the ordering-table
// walk reaches (scene_hooks packet), or at none; plot tests each pixel
// against it.
package psx_render

// Corners of a mask: an opening's four, plus one per cut at the near plane.
MASK_CORNERS :: 8

Mask :: struct {
	// The shape on screen, as packets hold positions: convex, n corners,
	// turning the way `turn` says (+1 or -1).
	corner: [MASK_CORNERS][2]f32,
	n:      int,
	turn:   f32,
	// Drawn inside the shape, or with false only outside it.
	inside: bool,
}

// The mask of the packet being drawn, during a walk.
mask_now: ^Mask

// Whether screen point `at` lies inside the convex shape of n corners
// turning `turn`; false when n < 3.
opening_holds :: proc(corner: [MASK_CORNERS][2]f32, n: int, turn: f32, at: [2]f32) -> bool {
	if n < 3 {
		return false
	}
	for i in 0 ..< n {
		a, b := corner[i], corner[(i + 1) % n]
		if ((b.x - a.x) * (at.y - a.y) - (b.y - a.y) * (at.x - a.x)) * turn < 0 {
			return false
		}
	}
	return true
}

// Whether mask p (the walk's when the pixel was drawn) lets a pixel whose
// middle is at screen x, y (as packets hold positions) be drawn.
@(private)
mask_lets :: proc(p: ^Mask, x, y: f32) -> bool {
	return opening_holds(p.corner, p.n, p.turn, {x, y}) == p.inside
}
