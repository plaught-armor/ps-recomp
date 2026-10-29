// The GPU's part of a frozen-time pass (checkpoint.odin in package psx): the
// hi-res target's saved picture, and the depth undo.
package psx_render

import io "../io"

// Kept by each pass's checkpoint.
Pass :: struct {
	// The hi-res target's pixels. During a pass the pass draws into this
	// buffer instead, swapped with the target's own (which keeps the saved
	// picture); a tile is copied in from the saved picture just before the
	// pass first uses it (hi_tiles), and restore swaps back.
	hi:         []u32,
	hi_tiles:   u128,
	hi_swapped: bool,
	// The same as a texture when the target is drawn on the host GPU
	// (gl_target.odin), and the target width it was made for.
	hi_gl:      u32,
	hi_gl_w:    i32,
	depths:     Depth_Undo,
	// The pass this one runs inside, nil for one saved from the running
	// machine.
	outer:      ^Pass,
}

// The running pass's, which hi_touch saves hi-res tiles into; nil outside a
// pass.
running_pass: ^Pass

// The hi-res target's pixels over VRAM area x, y, w x h are about to be
// read or changed: inside a pass, copy in the tiles under it the pass has
// not used yet. Call before the read, or before the change is made or
// queued.
hi_touch :: #force_inline proc(x, y, w, h: i32) {
	if io.events_frozen && w > 0 && h > 0 {
		hi_load(vram_tiles(x, y, w, h), 0)
	}
}

// As hi_touch, for an area about to be overwritten whole: tiles it covers
// entirely need no copy.
@(private)
hi_cover :: #force_inline proc(x, y, w, h: i32) {
	if io.events_frozen && w > 0 && h > 0 {
		whole: u128
		if x + w <= VRAM_W && y + h <= VRAM_H {
			for ty in (y + 63) >> 6 ..< (y + h) >> 6 {
				for tx in (x + 63) >> 6 ..< (x + w) >> 6 {
					whole |= 1 << u32(ty * 16 + tx)
				}
			}
		}
		hi_load(vram_tiles(x, y, w, h), whole)
	}
}

// Copy the tiles in mask but not in whole from the saved picture into the
// pass's buffer, once per pass. A nested pass's saved picture is the outer
// pass's buffer, which takes the tiles it lacks from its own saved picture
// first.
@(private)
hi_load :: proc(mask, whole: u128) {
	cp := running_pass
	if cp == nil || !cp.hi_swapped || !hi_saved(cp) {
		return
	}
	fresh := mask &~ cp.hi_tiles
	if fresh == 0 {
		return
	}
	cp.hi_tiles |= fresh
	gl := targets[1].gl
	if o := cp.outer; o != nil && o.hi_swapped && hi_saved(o) {
		lack := fresh &~ whole &~ o.hi_tiles
		o.hi_tiles |= lack
		if gl {
			gl_copy_tiles(cp.hi_gl, o.hi_gl, lack)
		} else {
			hi_copy_tiles(cp.hi, o.hi, lack)
		}
	}
	if gl {
		gl_copy_tiles(gpu_gl.main, cp.hi_gl, fresh &~ whole)
	} else {
		hi_copy_tiles(targets[1].rgb, cp.hi, fresh &~ whole)
	}
}

// Whether cp holds a saved picture of the hi-res target as it is now.
hi_saved :: proc(cp: ^Pass) -> bool {
	if target_count != 2 {
		return false
	}
	t := &targets[1]
	if t.gl {
		return cp.hi_gl != 0 && cp.hi_gl_w == t.w
	}
	return len(cp.hi) == len(t.rgb)
}

// Copy the hi-res target's tiles in mask (VRAM tiles, as vram_tiles) from
// src to dst, runs of neighbouring tiles at once.
@(private)
hi_copy_tiles :: proc(dst, src: []u32, mask: u128) #no_bounds_check {
	if mask == 0 {
		return
	}
	t := &targets[1]
	n := i32(64) << t.shift
	for ty in i32(0) ..< 8 {
		row := u16(mask >> u32(ty * 16))
		tx := i32(0)
		for tx < 16 {
			if row & (1 << u32(tx)) == 0 {
				tx += 1
				continue
			}
			x0 := tx
			for tx < 16 && row & (1 << u32(tx)) != 0 {
				tx += 1
			}
			for y in ty * n ..< (ty + 1) * n {
				i := y * t.w + x0 * n
				copy(dst[i:][:(tx - x0) * n], src[i:][:(tx - x0) * n])
			}
		}
	}
}

// Name the VRAM a pass has just put in place (a room's, from key 1; 0 is
// the machine's own), so the hi-res target keeps a GPU copy of each apart
// and swapping one in uploads only what changed (gl_vram_use).
vram_world :: proc(key: u32) {
	vram_key = key
	if target_count == 2 && targets[1].gl {
		gl_vram_use(key)
	}
}

// The VRAM in place, as vram_world named it.
vram_key: u32
