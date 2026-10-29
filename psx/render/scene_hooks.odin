// What the game says about the scene the ordering-table walk draws (not a
// PS1 feature): which packets are world polygons drawn in 3D, sprites or
// screen pictures, which are left out or masked, how each polygon covers the
// focus (see_through.odin), and the door pictures laid over the walk
// (doors.odin). Each hook is optional: without it a packet is drawn as the
// PS1 drew it, with depths from the depth cache (depth.odin).
package psx_render

// What a polygon packet draws.
Prim_Kind :: enum u8 {
	// A polygon of the scene: its corners take depths from the depth cache.
	Packet,
	// Flat on the screen (a speaker's portrait): no depth.
	Screen,
	// A sprite standing at a depth of its own (Prim_Shape z, at).
	Sprite,
	// A world polygon drawn from its corners in view space: fan.
	World,
	// Nothing: the packet is left out.
	Drop,
}

// Corners of a world polygon cut at the lens (a twisted quad cut by the near
// plane can have more than the five of a flat one).
FAN_CORNERS :: 8

Prim_Shape :: struct {
	kind:  Prim_Kind,
	// Sprite: the view depth it stands at (0 for none: the characters
	// see-through never fades) and the view-space point (its depth 0 for
	// none) whose plane the depth buffer takes; its anchor's sub-pixel part
	// (gte.state anchor_sub), which its corners take; a front one (a
	// character stepping in through a door with no wait) a waiting door
	// cover does not lay over; `clear` the share of it faded out regardless.
	z:     f32,
	at:    [3]f32,
	sub:   [2]i8,
	front: bool,
	clear: f32,
	// World: the polygon's corners round its edge, n of them, and whether it
	// is a decal lying on another (taken nearer by the depth buffer). The
	// packet's corners are replaced by at most four standing for it in the
	// tests made on whole polygons.
	fan:   [FAN_CORNERS]Vertex,
	n:     int,
	decal: bool,
}

Scene_Hooks :: struct {
	// Whether the walk about to start keeps pixel depths for door
	// pictures (picture_walk_begin).
	walk_doors:    proc() -> bool,
	// The walk is over.
	walk_end:      proc(),
	// The walk reaches the packet at address a: point mask_now at its mask.
	packet:        proc(a: u32),
	// What the polygon packet being drawn, its corners vs (verts of them),
	// draws; for World, vs and verts become the corners standing for it.
	prim_shape:    proc(vs: ^[4]Vertex, verts: ^int, shape: ^Prim_Shape),
	// Whether the polygon with corners vs and mode m is left out, before its
	// depths are settled.
	prim_drop:     proc(vs: []Vertex, m: ^Prim_Mode) -> bool,
	// Set m's cover, flat and door for the polygon with corners vs and
	// `corners` (packet positions, view depth; `whole` when the GTE
	// projected every one), a sprite when `flat` (in front of a door's
	// cover when `front`, `clear` faded out regardless); false leaves it out.
	prim_classify: proc(vs: []Vertex, corners: [][3]f32, m: ^Prim_Mode, flat, front: bool, clear: f32, whole: bool) -> bool,
	// Lay the walk's door pictures (lay_picture), before the HUD or at
	// the walk's end.
	doors_lay:     proc(),
	// A frozen-time pass begins: keep the game's scene state; and ends: put
	// it back. Passes nest, each ending before the one it runs in.
	pass_save:     proc(),
	pass_restore:  proc(),
}

scene: Scene_Hooks

// The walk reaches the packet at address a.
packet_at :: proc(a: u32) {
	if scene.packet != nil {
		scene.packet(a)
	}
	packet_now = a
}

// End a walk.
walk_end :: proc() {
	if scene.walk_end != nil {
		scene.walk_end()
	}
}

// A frozen-time pass begins (checkpoint.odin).
pass_save :: proc() {
	if scene.pass_save != nil {
		scene.pass_save()
	}
}

// A frozen-time pass ends.
pass_restore :: proc() {
	if scene.pass_restore != nil {
		scene.pass_restore()
	}
}
