// The software GS's triangle rasteriser, which computes each row's run of
// pixels from the three edges, against the walk it replaced, which tested
// every pixel of the box from its left (gs.probe_tri): the same pixel calls
// with the same argument bits in the same order. Every triangle on a 9 x 9
// grid of half pixels, in every vertex order, under a wide and a tight
// scissor, then random triangles of eight shapes. The reference walk
// asserts on every pixel it tests that the stepped edge weights are the
// edge functions themselves, and names the classes each triangle met; each
// class has a floor.
package main

import "core:fmt"
import "core:os"
import "ps:ps2/gs"

@(private = "file")
failed := 0

@(private = "file")
seed: u64 = 0x9e3779b97f4a7c15

// xorshift64*, fixed seed: the same trials every run.
@(private = "file")
rnd :: proc() -> u64 {
	seed ~= seed >> 12
	seed ~= seed << 25
	seed ~= seed >> 27
	return seed * 0x2545f4914f6cdd1d
}

@(private = "file")
rndn :: proc(n: u64) -> u64 {return rnd() % n}

// A signed value in [-n, n].
@(private = "file")
rnds :: proc(n: i64) -> i64 {return i64(rndn(u64(2 * n + 1))) - n}

// A vertex in window sixteenths, before XYZOFFSET.
@(private = "file")
P :: [2]i64

@(private = "file")
ox, oy: i64 // XYZOFFSET, sixteenths

@(private = "file")
prim: u64

@(private = "file")
ref_calls: [dynamic]gs.Px_Call

@(private = "file")
counts: [gs.Tri_Class]int
@(private = "file")
triangles, calls: int

// SCISSOR of context 0, pixels.
@(private = "file")
scissor :: proc(x0, x1, y0, y1: i64) {
	gs.gs_write(0x40, u64(x0) | u64(x1) << 16 | u64(y0) << 32 | u64(y1) << 48)
}

// The context a run of triangles is drawn under: a random XYZOFFSET, and
// random shading, texturing and LOD settings.
@(private = "file")
context_random :: proc() {
	ox, oy = i64(rndn(0x8001)), i64(rndn(0x8001))
	gs.gs_write(0x18, u64(ox) | u64(oy) << 32) // XYZOFFSET
	tw, th := rndn(11), rndn(11)
	gs.gs_write(0x06, rndn(0x4000) | 1 << 14 | tw << 26 | th << 30) // TEX0
	gs.gs_write(0x14, rnd() &~ u64(0x1c)) // TEX1: LCM, L and K at random, MXL 0
	prim = 3 | rndn(2) << 3 | rndn(2) << 4 | rndn(2) << 5 | rndn(2) << 8
}

// Sends one triangle's vertices without a kick, with random attributes, and
// rasterises it both ways.
@(private = "file")
tri :: proc(p: [3]P) {
	gs.gs_write(0x00, prim)
	for v in p {
		q: f32
		switch rndn(16) {
		case 0: q = 0
		case 1: q = -1
		case: q = 0.25 + f32(rndn(1024)) / 256
		}
		gs.gs_write(0x01, rnd() & 0xffffffff | u64(transmute(u32)q) << 32) // RGBAQ
		s := transmute(u32)(f32(rndn(2048)) / 512 - 1)
		t := transmute(u32)(f32(rndn(2048)) / 512 - 1)
		gs.gs_write(0x02, u64(s) | u64(t) << 32) // ST
		gs.gs_write(0x03, rndn(0x4000) | rndn(0x4000) << 16) // UV
		x, y := u64(clamp(ox + v.x, 0, 0xffff)), u64(clamp(oy + v.y, 0, 0xffff))
		if rndn(2) == 0 {
			gs.gs_write(0x0c, x | y << 16 | (rnd() & 0xffffff) << 32 | rndn(256) << 56) // XYZF3
		} else {
			gs.gs_write(0x0d, x | y << 16 | (rnd() & 0xffffffff) << 32) // XYZ3
		}
	}
	cls := gs.probe_tri(prim, true)
	resize(&ref_calls, len(gs.probe_calls))
	copy(ref_calls[:], gs.probe_calls[:])
	gs.probe_tri(prim, false)
	got := gs.probe_calls[:]

	triangles += 1
	calls += len(ref_calls)
	for c in cls {counts[c] += 1}
	if failed > 8 {return}
	if len(got) != len(ref_calls) {
		fmt.eprintfln("triangle %d %v offset %d,%d: %d pixel calls, the reference walk %d", triangles, p, ox, oy, len(got), len(ref_calls))
		failed += 1
		return
	}
	for c, i in got {
		if c != ref_calls[i] {
			fmt.eprintfln("triangle %d %v offset %d,%d: call %d is %v, the reference walk's %v", triangles, p, ox, oy, i, c, ref_calls[i])
			failed += 1
			return
		}
	}
}

// A pixel centre's sixteenths around which a random triangle is built, and
// the scissor it is drawn under: all of the window, or a box of up to 40
// pixels a side near the centre.
@(private = "file")
centre :: proc(tight: bool) -> P {
	cx, cy := i64(rndn(2048)), i64(rndn(2048))
	if tight {
		x0, y0 := clamp(cx + rnds(24), 0, 2047), clamp(cy + rnds(24), 0, 2047)
		scissor(x0, min(x0 + i64(rndn(40)), 2047), y0, min(y0 + i64(rndn(40)), 2047))
	} else {
		scissor(0, 2047, 0, 2047)
	}
	return {cx * 16, cy * 16}
}

@(private = "file")
random_tri :: proc(shape: int) {
	p: [3]P
	switch shape {
	case 0: // within a few pixels, any sixteenth
		c := centre(rndn(2) == 0)
		for &v in p {v = c + {rnds(40), rnds(40)}}
	case 1: // small
		c := centre(rndn(2) == 0)
		for &v in p {v = c + {rnds(200), rnds(200)}}
	case 2: // medium, cut by a tight scissor
		c := centre(true)
		for &v in p {v = c + {rnds(1600), rnds(1600)}}
	case 3: // any vertex the registers can hold, cut by a tight scissor
		centre(true)
		for &v in p {v = {i64(rndn(0x10000)) - ox, i64(rndn(0x10000)) - oy}}
	case 4: // on pixel centres: pixels on edges
		c := centre(rndn(2) == 0)
		for &v in p {v = c + {rnds(8) * 16, rnds(8) * 16}}
	case 5: // a level edge, on half pixels
		c := centre(rndn(2) == 0)
		for &v in p {v = c + {rnds(16) * 8, rnds(16) * 8}}
		p[rndn(3)].y = p[rndn(3)].y
	case 6: // an upright edge, on half pixels
		c := centre(rndn(2) == 0)
		for &v in p {v = c + {rnds(16) * 8, rnds(16) * 8}}
		p[rndn(3)].x = p[rndn(3)].x
	case 7: // a sliver: rows of the box with no pixel
		c := centre(rndn(4) == 0)
		p[0] = c + {rnds(16), rnds(16)}
		p[1] = p[0] + {rnds(640), rnds(640)}
		p[2] = p[1] + {rnds(24), rnds(24)}
	}
	if rndn(2) == 0 {p[0], p[1] = p[1], p[0]}
	tri(p)
}

main :: proc() {
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer
	gs.gs_snap()
	gs.gs_write(0x4c, 8 << 16) // FRAME: page 0, 512 wide, PSMCT32
	gs.gs_write(0x1a, 1) // PRMODECONT

	// Every triangle with its vertices on a 9 x 9 grid of half pixels, in
	// every order, so both windings and every rotation: under a scissor
	// that holds the grid, then under one that cuts it on all four sides.
	GRID :: 9
	for pass in 0 ..< 2 {
		context_random()
		prim |= 1 << 3 | 1 << 4 // IIP, TME
		bx, by := i64(100 + rndn(1800)), i64(100 + rndn(1800))
		if pass == 0 {scissor(0, 2047, 0, 2047)} else {scissor(bx + 1, bx + 2, by + 1, by + 3)}
		g: [GRID * GRID]P
		for &v, i in g {v = {bx * 16 + i64(i % GRID) * 8, by * 16 + i64(i / GRID) * 8}}
		for a in g {
			for b in g {
				for c in g {tri({a, b, c})}
			}
		}
	}
	grid := triangles
	fmt.printfln("grid triangles %d, pixel calls %d", grid, calls)

	RANDOM :: 1_000_000
	for i in 0 ..< RANDOM {
		if i % 16 == 0 {context_random()}
		random_tri(i % 8)
		if failed > 8 {break}
	}
	fmt.printfln("random triangles %d, pixel calls in all %d", triangles - grid, calls)

	// Floors: about half of what the fixed seed gives.
	floors := [gs.Tri_Class]int {
		.Drawn     = 550_000,
		.Back      = 480_000,
		.Tie_Owned = 170_000,
		.Tie_Left  = 300_000,
		.Level     = 160_000,
		.Before    = 700_000,
		.After     = 380_000,
		.Empty_Row = 640_000,
		.Clipped   = 290_000,
	}
	for c in gs.Tri_Class {
		fmt.printfln("%-10v triangles %d", c, counts[c])
		if counts[c] < floors[c] {
			fmt.eprintfln("%v: %d triangles, under the floor of %d", c, counts[c], floors[c])
			failed += 1
		}
	}
	if calls < 20_000_000 {
		fmt.eprintfln("only %d pixel calls compared", calls)
		failed += 1
	}
	if failed > 0 {
		fmt.eprintfln("gs_span: %d failed", failed)
		os.exit(1)
	}
	fmt.println("gs_span: ok")
}
