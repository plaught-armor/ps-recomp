// Depth recovery for packets the PS1 GPU draws flat (not a PS1 feature).
//
// The PS1 has no depth buffer, so depth is recovered as PGXP's vertex cache
// does it: every GTE projection (RTPS/RTPT) files the screen x, y it produced
// under its view depth (depth_tag), and when a polygon packet reaches the GPU
// its corners are looked up by the x, y the game copied into it
// (depth_fill; where vertices at different depths met at one pixel, the one
// projected with the polygon's other corners). The rasterizer interpolates
// 1 / depth across the polygon (see_through.odin, depth_buffer.odin).
package psx_render

@(private)
DEPTH_SLOT_BITS :: 17
@(private)
DEPTH_SLOTS :: 1 << DEPTH_SLOT_BITS
// Slots a lookup or tag walks before it gives up.
@(private)
DEPTH_RUN :: 64
// Depths filed at one pixel before a tag there gives up: offscreen vertices
// the GTE clamps to a screen corner pile up at one pixel by the hundred.
@(private)
DEPTH_PILE :: 8
// Vertices at one pixel whose depths differ by at most this part are one.
@(private)
DEPTH_SAME :: 0.02
// Vertices at one pixel a primitive's corner chooses among.
@(private)
DEPTH_CANDIDATES :: 4

// One depth cache slot. A probe reads key and gen, a hit the rest, so a
// slot's fields sit together (24 bytes): one cache line per lookup rather
// than one per field, the table being far larger than L2.
@(private)
Depth_Slot :: struct {
	key, gen:       u32,
	z:              f32,
	// Sixteenths of a pixel past x, y the exact projection lies (negative
	// or past a pixel under the exact view).
	sub:            [2]i8,
	// The first and last projection (by seq) that filed this vertex.
	seq_lo, seq_hi: u32,
}

// Projected vertices since the last ordering-table walk: open addressing, a
// slot counting only when its gen is `now`.
@(private)
Depth_Cache :: struct {
	slots:    [DEPTH_SLOTS]Depth_Slot,
	now:      u32,
	// Projections filed since the last walk.
	seq:      u32,
}

@(private)
depth_cache: Depth_Cache

// What a frozen-time pass changed in the depth cache, to undo at restore
// instead of copying the whole cache both ways: each slot's fields before
// the pass first wrote it (marked in `kept`, so a slot is kept once and the
// log never holds more than DEPTH_SLOTS), and the walk counters.
@(private)
Depth_Undo :: struct {
	kept:      [DEPTH_SLOTS / 64]u64,
	slot:      [DEPTH_SLOTS]u32,
	old:       [DEPTH_SLOTS]Depth_Slot,
	n:         u32,
	now, seq:  u32,
}

// Start logging depth cache changes into u (a pass begins).
depth_undo_begin :: proc(u: ^Depth_Undo) {
	assert(u.n == 0, "depth undo log not empty")
	u.now, u.seq = depth_cache.now, depth_cache.seq
}

// Put back every slot and counter u logged, leaving u empty.
depth_undo_end :: proc(u: ^Depth_Undo) #no_bounds_check {
	c := &depth_cache
	for i in 0 ..< u.n {
		s := u.slot[i]
		c.slots[s] = u.old[i]
		u.kept[s >> 6] &~= 1 << (s & 63)
	}
	u.n = 0
	c.now, c.seq = u.now, u.seq
}

// Slot s is about to change: inside a pass, log it first.
@(private)
depth_keep :: #force_inline proc(s: u32) #no_bounds_check {
	if running_pass == nil {
		return
	}
	u := &running_pass.depths
	bit := u64(1) << (s & 63)
	if u.kept[s >> 6] & bit != 0 {
		return
	}
	u.kept[s >> 6] |= bit
	u.slot[u.n] = s
	u.old[u.n] = depth_cache.slots[s]
	u.n += 1
}


@(private)
depth_key :: #force_inline proc(x, y: i32) -> u32 {
	return u32(x & 0x7ff) | u32(y & 0x7ff) << 11 | 1 << 31
}

@(private)
depth_slot :: #force_inline proc(key: u32) -> u32 {
	return (key * 2654435761) >> (32 - DEPTH_SLOT_BITS)
}

// File a projected vertex: screen x, y (as packets hold them) at view depth z,
// exactly sub sixteenths of a pixel further. Vertices at one pixel with
// depths apart are filed side by side; one projected again widens the run of
// projections (seq) it was filed in.
depth_tag :: proc(x, y: i32, z: i64, sub: [2]i8) #no_bounds_check {
	c := &depth_cache
	c.seq += 1
	zf := f32(max(z, 1))
	key := depth_key(x, y)
	s := depth_slot(key)
	same := 0
	for _ in 0 ..< DEPTH_RUN {
		e := &c.slots[s]
		if e.gen != c.now {
			depth_keep(s)
			e^ = {key, c.now, zf, sub, c.seq, c.seq}
			return
		}
		if e.key == key && abs(e.z - zf) <= e.z * DEPTH_SAME {
			depth_keep(s)
			e.z, e.sub, e.seq_hi = zf, sub, c.seq
			return
		}
		if e.key == key {
			same += 1
			if same == DEPTH_PILE {
				return
			}
		}
		s = (s + 1) & (DEPTH_SLOTS - 1)
	}
}

// The slots of the vertices projected to x, y this frame, at most
// DEPTH_CANDIDATES.
@(private)
depth_candidates :: proc(x, y: i32, out: ^[DEPTH_CANDIDATES]u32) -> (n: int) #no_bounds_check {
	c := &depth_cache
	key := depth_key(x, y)
	s := depth_slot(key)
	for _ in 0 ..< DEPTH_RUN {
		e := &c.slots[s]
		if e.gen != c.now {
			break
		}
		if e.key == key {
			out[n] = s
			n += 1
			if n == DEPTH_CANDIDATES {
				break
			}
		}
		s = (s + 1) & (DEPTH_SLOTS - 1)
	}
	return
}

// Give the corners of a primitive their view depths and sub-pixel parts
// (0 depth where none was projected). Where two vertices projected to one
// pixel, a corner takes the one filed nearest in projection order to the
// other corners: the game projects a face's corners together, so the
// combination whose runs of projections lie closest together wins, the later
// on a tie. One wrong depth bends a perspective-mapped texture across the
// face.
@(private)
depth_fill :: proc(vs: []Vertex) #no_bounds_check {
	assert(len(vs) <= 4, "primitive with more than 4 corners")
	c := &depth_cache
	cands: [4][DEPTH_CANDIDATES]u32
	count: [4]int
	combos := 1
	for &v, k in vs {
		count[k] = depth_candidates(v.x - gpu.off_x, v.y - gpu.off_y, &cands[k])
		combos *= max(count[k], 1)
	}
	pick: [4]int
	if combos > 1 {
		// Each candidate is filed after the ones before it at its pixel, so
		// the last is the latest; walk combinations from the latest down.
		best := max(u32)
		for combo in 0 ..< combos {
			at: [4]int
			lo, hi := u32(0), max(u32)
			r := combo
			for k in 0 ..< len(vs) {
				if count[k] == 0 {
					continue
				}
				at[k] = count[k] - 1 - r % count[k]
				r /= count[k]
				s := cands[k][at[k]]
				lo = max(lo, c.slots[s].seq_lo)
				hi = min(hi, c.slots[s].seq_hi)
			}
			gap := lo > hi ? lo - hi : 0
			if gap < best {
				best, pick = gap, at
			}
		}
	} else {
		for k in 0 ..< len(vs) {
			pick[k] = count[k] - 1
		}
	}
	for &v, k in vs {
		if count[k] == 0 {
			continue
		}
		e := &c.slots[cands[k][pick[k]]]
		v.z = e.z
		v.sx += i32(e.sub[0])
		v.sy += i32(e.sub[1])
	}
}

// The view-space point the GTE projected to screen position x, y at view
// depth z, with H `h` and screen offset `of`. Nearer than H / 2 its divide
// overflows and stops at 0x1ffff (gte_divide), so the point lies about twice
// its view x, y from the offset, whatever its depth; taken as H / z, such
// corners (of a face running up to the lens) put the face's plane anywhere,
// and its cover flipped between frames.
unproject :: #force_inline proc(x, y, z, h: f32, of: [2]f32) -> [3]f32 {
	k := max(z, h * DIVIDE_MAX) / h
	return {(x - of.x) * k, (y - of.y) * k, z}
}

// The inverse of the GTE divide's largest quotient, 0x1ffff / 0x10000.
DIVIDE_MAX :: f32(0x10000) / 0x1ffff

