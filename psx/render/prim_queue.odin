// The hi-res target's draws queued for a GPU backend (not a PS1 feature):
// each draw becomes primitives as the backend's shader reads them, with the
// portals they use, and takes a draw level (levels.odin). The backend on
// draws the queue at raster_sync (queue_submit) and empties it.
package psx_render

// Primitives queued at once and portals they use.
@(private)
QUEUE_PRIMS :: 1 << 16
@(private)
QUEUE_PORTALS :: 256
// Primitives queued before they are sent on unasked (queue_add).
@(private)
QUEUE_EAGER :: 512

// A primitive as the shader reads it (std430). See queue_tri for the
// fields.
@(private)
Gpu_Prim :: struct {
	box:  [4]i32,
	h:    [4]i32,
	t:    [4]i32,
	m:    [4]i32,
	a:    [4]i32,
	b:    [4]i32,
	c:    [4]i32,
	w:    [4]i32,
	z:    [4]f32,
	e:    [4]f32,
}

// Prim flags (Gpu_Prim.h.x).
@(private)
Gpu_Flag :: enum u32 {
	Rect,
	Textured,
	Raw,
	Semi,
	Gouraud,
	Dither, // unused: the hi-res target keeps 8 bits a channel, undithered
	Depth,
	Persp,
	Flat,
	Sprite,
	Set_Mask,
	Check_Mask,
	See_Active,
	See_Direct,
	Read_Ok,
	Flip_X,
	Flip_Y,
	Depth_On,
	Ghost_Acc,
	Bias0,
	Bias1,
	Bias2,
	Smooth,
	Glow,
	Smooth_All,
	Fog,
	Z_Test,
	Z_Write,
	Z_Plane,
	Z_Exact,
	Z_Decal,
}

@(private)
Gpu_Flags :: bit_set[Gpu_Flag;u32]

// A portal as the shader reads it: 8 corners two to a vec4, then n, turn,
// inside.
@(private)
Gpu_Portal :: struct {
	corner: [4][4]f32,
	info:   [4]f32,
}

// The hi-res target's queue (raster_queue), drawn by the GPU backend on
// (queue_submit).
@(private)
prim_queue: struct {
	// The fog of the last fogged primitive queued (Plot_Env.fog): one a
	// flush, it changing only between maps.
	fog:                                    Fog,
	prims:       [QUEUE_PRIMS]Gpu_Prim,
	prim_n:      int,
	portals:     [QUEUE_PORTALS]Gpu_Portal,
	portal_src:  [QUEUE_PORTALS]^Mask,
	portal_n:    int,
	// Each queued primitive's level (levels.odin).
	level_of:    [QUEUE_PRIMS]u8,
	// The queue by level (gl_submit), as the shader reads it.
	order:       [QUEUE_PRIMS]i32,
}

// Queue draw d of target t (raster_queue).
@(private)
queue_draw :: proc(t: ^Target, d: ^Draw) {
	assert(raster.on || t.gl, "the Vulkan target draws only on a walk's queue")
	gl_puts_apply()
	switch d.kind {
	case .Triangle:
		queue_tri(t, d)
	case .Rect:
		queue_rect(t, d)
	case .Line:
		queue_line(t, d)
	case .Ghost:
		unreachable()
	}
}

// The flags and portal every primitive of d takes.
@(private = "file")
queue_common :: proc(d: ^Draw, p: ^Gpu_Prim) -> Gpu_Flags {
	g := &prim_queue
	e, m := &d.env, &d.m
	f: Gpu_Flags
	if m.textured {f += {.Textured}}
	if m.raw {f += {.Raw}}
	if m.semi {f += {.Semi}}
	if m.smooth {f += {.Smooth}}
	if m.glow {f += {.Glow}}
	if m.smooth_all {f += {.Smooth_All}}
	if e.fog.on {
		f += {.Fog}
		g.fog = e.fog
	}
	if e.st.set_mask {f += {.Set_Mask}}
	if e.st.check_mask {f += {.Check_Mask}}
	if e.see_active {f += {.See_Active}}
	if e.see_direct {f += {.See_Direct}}
	if e.depth_on {f += {.Depth_On}}
	if e.st.flip_x {f += {.Flip_X}}
	if e.st.flip_y {f += {.Flip_Y}}
	portal := i32(-1)
	if e.portal != nil {
		if g.portal_n > 0 && g.portal_src[g.portal_n - 1] == e.portal {
			portal = i32(g.portal_n - 1)
		} else {
			for s, i in g.portal_src[:g.portal_n] {
				if s == e.portal {
					portal = i32(i)
					break
				}
			}
		}
		if portal < 0 {
			if g.portal_n == QUEUE_PORTALS {
				queue_submit()
			}
			q := e.portal
			o := &g.portals[g.portal_n]
			for c, i in q.corner {
				o.corner[i >> 1][(i & 1) * 2] = c.x
				o.corner[i >> 1][(i & 1) * 2 + 1] = c.y
			}
			o.info = {f32(q.n), q.turn, q.inside ? 1 : 0, 0}
			g.portal_src[g.portal_n] = q
			portal = i32(g.portal_n)
			g.portal_n += 1
		}
	}
	st := &e.st
	p.h = {0, st.off_x, st.off_y, portal}
	p.t = {st.tex_x, st.tex_y, m.clut_x, m.clut_y}
	p.m = {
		i32(st.tp | st.abr << 2 | u32(m.door) << 8 | u32(depth_walk.now) << 16),
		i32(st.tw_mask_x | st.tw_mask_y << 5 | st.tw_off_x << 10 | st.tw_off_y << 15),
		0,
		0,
	}
	return f
}

@(private = "file")
rgb :: #force_inline proc(v: Vertex) -> i32 {
	return v.r | v.g << 8 | v.b << 16
}

@(private = "file")
queue_tri :: proc(t: ^Target, d: ^Draw) {
	tri, m, e := &d.tri, &d.m, &d.env
	p: Gpu_Prim
	f := queue_common(d, &p)
	v0, v1, v2 := tri.v0, tri.v1, tri.v2
	if m.gouraud {f += {.Gouraud}}
	if m.depth {f += {.Depth}}
	if tri.persp {f += {.Persp}}
	if m.flat {f += {.Flat}}
	if m.cover.sprite {f += {.Sprite}}
	if tri.read.ok {f += {.Read_Ok}}
	if tri.b0 != 0 {f += {.Bias0}}
	if tri.b1 != 0 {f += {.Bias1}}
	if tri.b2 != 0 {f += {.Bias2}}
	p.box = {tri.min_x, tri.min_y, tri.max_x, tri.max_y}
	p.m.z = tri.read.u.x & 0xffff | tri.read.u.y << 16
	p.m.w = tri.read.tv.x & 0xffff | tri.read.tv.y << 16
	p.a = {v0.sx, v0.sy, v1.sx, v1.sy}
	p.b = {v2.sx, v2.sy, rgb(v0), rgb(v1)}
	p.c = {rgb(v2), v0.u | v0.v << 8, v1.u | v1.v << 8, v2.u | v2.v << 8}
	p.z = {v0.z, v1.z, v2.z, 0}
	if tri.persp {
		p.w = {i32(tri.pw.w[0]), i32(tri.pw.w[1]), i32(tri.pw.w[2]), i32(tri.pw.shift)}
	}
	p.e = {m.cover.weight, 0, m.cover.clear, f32(m.sharp)}
	if m.z_mode != .Off && e.z_key != 0 {
		f += {.Z_Test}
		if m.z_mode == .Write {f += {.Z_Write}}
		if m.world {f += {.Z_Exact}}
		if m.decal {f += {.Z_Decal}}
		p.e.y = f32(e.z_key >> 16)
		// A sprite is never mapped with perspective: w is free.
		if m.z_plane != {} {
			f += {.Z_Plane}
			p.w.x, p.w.y, p.w.z = transmute(i32)m.z_plane.x, transmute(i32)m.z_plane.y, transmute(i32)m.z_plane.z
		}
	}
	fade := e.see_active && m.depth && (min(v0.z, v1.z, v2.z) < see_fade.near[1] + 1 || m.cover.weight > 0 || m.cover.clear > 0)
	queue_add(t, &p, f, fade)
}

@(private = "file")
queue_rect :: proc(t: ^Target, d: ^Draw) {
	st := &d.env.st
	q := &d.rect
	k := t.shift
	p: Gpu_Prim
	f := queue_common(d, &p) + {.Rect}
	p.box = {max(q.x, st.x1) << k, max(q.y, st.y1) << k, ((min(q.x + q.w - 1, st.x2) + 1) << k) - 1, ((min(q.y + q.h - 1, st.y2) + 1) << k) - 1}
	if p.box.x > p.box.z || p.box.y > p.box.w {
		return
	}
	p.a = {q.x, q.y, q.u, q.v}
	p.b.z = q.r | q.g << 8 | q.b << 16
	queue_add(t, &p, f, false)
}

// A line as draw_line steps it: each point a block of target pixels.
@(private = "file")
queue_line :: proc(t: ^Target, d: ^Draw) {
	st := &d.env.st
	m := &d.m
	a, b := d.line[0], d.line[1]
	dx, dy := b.x - a.x, b.y - a.y
	if abs(dx) >= 1024 || abs(dy) >= 512 {
		return
	}
	k := t.shift
	p: Gpu_Prim
	f := queue_common(d, &p) + {.Rect}
	level_group(true)
	steps := max(abs(dx), abs(dy))
	for i: i32 = 0; i <= steps; i += 1 {
		x, y := a.x, a.y
		r, g, bl := a.r, a.g, a.b
		if steps > 0 {
			x = a.x + dx * i / steps
			y = a.y + dy * i / steps
			if m.gouraud {
				r = a.r + (b.r - a.r) * i / steps
				g = a.g + (b.g - a.g) * i / steps
				bl = a.b + (b.b - a.b) * i / steps
			}
		}
		if x >= st.x1 && x <= st.x2 && y >= st.y1 && y <= st.y2 {
			p.box = {x << k, y << k, (x << k) + (1 << k) - 1, (y << k) + (1 << k) - 1}
			p.a = {x, y, 0, 0}
			p.b.z = r | g << 8 | bl << 16
			queue_add(t, &p, f, false)
		}
	}
	level_group(false)
}

// Add primitive p with flags f, fading possibly (fade), to the queue,
// cutting a segment where it must not share one with what came before.
@(private = "file")
queue_add :: proc(t: ^Target, p: ^Gpu_Prim, f: Gpu_Flags, fade: bool) {
	g := &prim_queue
	f := f
	k := t.shift
	x0, y0 := p.box.x >> k, p.box.y >> k
	w, h := (p.box.z >> k) - x0 + 1, (p.box.w >> k) - y0 + 1
	ghosts, reader, acc := level_kinds(f, fade, x0, y0, w, h)
	if acc {
		f += {.Ghost_Acc}
	}
	if g.prim_n == QUEUE_PRIMS || levels_full() {
		queue_submit()
	}
	g.level_of[g.prim_n] = level_place(x0, y0, w, h, ghosts, reader, acc, fade, .Depth_On in f, .Z_Write in f, g.prim_n > 0)
	if ghosts {
		gh := &t.ghost
		gh.lo = {min(gh.lo.x, p.box.x), min(gh.lo.y, p.box.y)}
		gh.hi = {max(gh.hi.x, p.box.z + 1), max(gh.hi.y, p.box.w + 1)}
	}
	p.h.x = transmute(i32)f
	g.prims[g.prim_n] = p^
	g.prim_n += 1
	// Sent on before the frame ends, the GL target draws while the CPU runs
	// on: a pull then waits only for the rest. (The Vulkan target's draws
	// are waited for, so it sends only full queues and pulls.)
	if g.prim_n >= QUEUE_EAGER && !levels.group && gpu_gl.on {
		queue_submit()
	}
}

// Order the queue by level, keeping queue order within one: level lv's
// primitives are order[first[lv]:first[lv + 1]], for lv in 1 ..= top.
@(private)
queue_order :: proc() -> (first: [LEVELS + 2]i32, top: int) {
	g := &prim_queue
	top = int(levels.top)
	for lv in g.level_of[:g.prim_n] {
		first[lv + 1] += 1
	}
	for lv in 1 ..= top {
		first[lv + 1] += first[lv]
	}
	next := first
	for lv, i in g.level_of[:g.prim_n] {
		g.order[next[lv]] = i32(i)
		next[lv] += 1
	}
	return
}

// Draw the queue on the GPU backend on (raster_run, before its read cells
// are dropped).
@(private)
queue_submit :: proc() {
	if gpu_gl.on {
		gl_submit()
	} else if gpu_vk.on {
		vk_target_submit()
	}
}

// Empty the queue once drawn.
@(private)
queue_reset :: proc() {
	g := &prim_queue
	g.prim_n, g.portal_n = 0, 0
	levels_reset()
}
