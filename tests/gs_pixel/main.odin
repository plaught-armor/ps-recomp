// The software GS's specialised pixel procs (gs.PX_FAST) against the
// generic pixel, bit for bit on all of local memory (frame and Z): random
// contexts of each PX_FAST kind (its fog, alpha test and destination alpha
// test with it), and fully random ones that take the generic proc, each
// drawing random points, lines, triangles, strips, fans and sprites over
// random memory. Frame and Z buffers sit at random pages and widths,
// sometimes on the same pages, and spans cross page and block rows, so the
// rows the rasteriser seeks once per span are checked against the per-pixel
// seek too.
//
// Then the fold of a flat texture's LOD (gs.probe_fold): contexts of five
// TEX1 classes, three flat and two not, drawn with the fold on and off, the
// same memory after both. Each class counts its pixels by LOD, those the
// fold took, and its LCM, FST, primitive kinds and texture formats, with
// floors.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import "ps:ps2/gs"

@(private = "file")
failed := 0

@(private = "file")
fail :: proc(msg: string, args: ..any) {
	fmt.eprintfln(msg, ..args)
	failed += 1
}

@(private = "file")
seed: u64 = 0x2545f4914f6cdd1d

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

@(private = "file")
PSMCT32, PSMCT24, PSMCT16, PSMCT16S :: 0x00, 0x01, 0x02, 0x0a

// Frame formats, and Z formats as ZBUF's PSM field.
@(private = "file")
FRAME_PSM := [?]u64{PSMCT32, PSMCT24, PSMCT16, PSMCT16S, 0x30, 0x31, 0x32, 0x3a}
@(private = "file")
Z_PSM := [?]u64{0x0, 0x1, 0x2, 0xa}

// One trial's register writes, replayed for each proc.
@(private = "file")
Reg_Write :: struct {
	reg: u8,
	v:   u64,
}
@(private = "file")
writes: [dynamic]Reg_Write

@(private = "file")
put :: proc(reg: u8, v: u64) {append(&writes, Reg_Write{reg, v})}

@(private = "file")
replay :: proc() {
	for h in core.snap_hooks {h.load(0)} // drop decoded textures of the memory replaced
	for w in writes {gs.gs_write(w.reg, w.v)}
}

// Local memory before a trial, and after its fast run.
@(private = "file")
before, after_fast: [1 << 20]u32

// TEX1 classes of the fold's trials. Flat: every LOD samples level 0 with
// MMAG's filter.
@(private = "file")
Fold_Class :: enum {
	Flat_Level0, // MMIN 0 or 1, MMAG the same filter
	Flat_Reserved, // MMIN 6 or 7 (bilinear at level 0), MMAG LINEAR
	Flat_Mxl0, // MMIN 2..5 with MXL 0, MMAG the same filter
	Filters_Differ, // level 0 at every LOD, but MMAG is the other filter
	Levels, // MMIN 2..5 with MXL 1..6
}

// What a fold trial's context and primitive were.
@(private = "file")
Fold_Trial :: struct {
	lcm, fst: bool,
	kind:     int, // 0 point, 1 line, 2 triangle, 3 sprite
	psm:      int, // index in TEX_PSM
}
@(private = "file")
fold_trial: Fold_Trial

@(private = "file")
TEX_PSM := [?]u64{PSMCT32, PSMCT24, PSMCT16, PSMCT16S, 0x13, 0x14, 0x1b, 0x24, 0x2c}

// TEX1 of a fold class: LCM and L at random, K small half the time so that
// LODs fall on both sides of 0.
@(private = "file")
fold_tex1 :: proc(cls: Fold_Class) -> u64 {
	mmin, mmag, mxl: u64
	bil :: proc(mmin: u64) -> u64 {return u64(mmin == 1 || mmin >= 4)}
	switch cls {
	case .Flat_Level0:
		mmin, mxl = rndn(2), rndn(7)
		mmag = bil(mmin)
	case .Flat_Reserved:
		mmin, mxl = 6 + rndn(2), rndn(7)
		mmag = 1
	case .Flat_Mxl0:
		mmin = 2 + rndn(4)
		mmag = bil(mmin)
	case .Filters_Differ:
		@(static, rodata) level0 := [?]u64{0, 1, 6, 7}
		if rndn(2) == 0 {
			mmin, mxl = level0[rndn(4)], rndn(7)
		} else {
			mmin = 2 + rndn(4)
		}
		mmag = 1 - bil(mmin)
	case .Levels:
		mmin, mxl, mmag = 2 + rndn(4), 1 + rndn(6), rndn(2)
	}
	k := rndn(2) == 0 ? rndn(49) - 24 : rnd()
	lcm := rndn(2)
	fold_trial.lcm = lcm != 0
	return lcm | mxl << 2 | mmag << 5 | mmin << 6 | rndn(4) << 19 | (k & 0xfff) << 32
}

// Registers of context n for PX_FAST[fi], or a random context for fi -1,
// and one primitive kind with its vertices. With fold, a texture-mapped
// context of that class, its texture of any format.
@(private = "file")
build :: proc(fi: int, fold: Maybe(Fold_Class) = nil) {
	clear(&writes)
	n := rndn(2)
	fast := fi >= 0
	f: gs.Px_Fast
	if fast {
		fs := gs.PX_FAST
		f = fs[fi]
	}

	fbp, fbw := rndn(512), 1 + rndn(16)
	fpsm := fast ? u64(f.fpsm) : FRAME_PSM[rndn(len(FRAME_PSM))]
	fbmsk: u64
	if fast ? f.fbmsk : rndn(4) == 0 {
		for fbmsk == 0 {fbmsk = rnd() & 0xffffffff}
	}
	put(0x4c + u8(n), fbp | fbw << 16 | fpsm << 24 | fbmsk << 32) // FRAME
	zbp := rndn(8) == 0 ? fbp : rndn(512)
	zpsm := fast ? u64(f.zpsm & 0xf) : Z_PSM[rndn(len(Z_PSM))]
	zmsk := fast ? f.zmsk : rndn(2) == 0
	put(0x4e + u8(n), zbp | zpsm << 24 | u64(zmsk) << 32) // ZBUF
	w := fbw * 64
	x0, y0 := rndn(64), rndn(64)
	x1, y1 := min(x0 + rndn(w + 64), 2047), min(y0 + rndn(512), 2047)
	put(0x40 + u8(n), x0 | x1 << 16 | y0 << 32 | y1 << 48) // SCISSOR
	test: u64
	if fast {
		if f.atst != 1 {
			test = 1 | u64(f.atst) << 1 | rndn(256) << 4 | u64(f.afail) << 12 // ATE, the row's ATST and AFAIL
		} else if rndn(2) == 0 {
			test = 1 | 1 << 1 | rndn(256) << 4 | rndn(4) << 12 // ATE, ATST ALWAYS
		} else {
			test = rndn(8) << 1 | rndn(256) << 4 | rndn(4) << 12 // no ATE
		}
		test |= u64(f.date != 0) << 14 | u64(f.date == 2) << 15 // DATE, DATM
		test |= 1 << 16 | u64(f.ztst) << 17
	} else {
		test = rnd() & 0x7ffff
	}
	put(0x47 + u8(n), test) // TEST
	al := rnd() & 0xff | rndn(256) << 32
	if fast && f.bl != 0xff {al = u64(f.bl) | rndn(256) << 32}
	put(0x42 + u8(n), al) // ALPHA
	put(0x49, fast ? 0 : rndn(2)) // PABE
	put(0x4a + u8(n), fast ? 0 : rndn(2)) // FBA
	put(0x46, fast ? 1 : rndn(2)) // COLCLAMP
	put(0x3d, rnd() & 0xffffff) // FOGCOL
	put(0x3b, rnd() & 0xff | rndn(2) << 15 | (rnd() & 0xff) << 32) // TEXA
	ox, oy := rndn(1024), rndn(1024)
	put(0x18 + u8(n), (ox << 4) | (oy << 4) << 32) // XYZOFFSET
	put(0x1a, 1) // PRMODECONT
	put(0x0a, rndn(256) << 56) // FOG: the vertex fog an XYZ2 keeps

	cls, folds := fold.?
	tme := fast ? f.tfx >= 0 : folds || rndn(2) == 0
	tw, th := 1 + rndn(8), 1 + rndn(8)
	if tme {
		@(static, rodata) tpsm := [?]u64{PSMCT32, PSMCT24, PSMCT16}
		tfx := fast ? u64(f.tfx) : rndn(4)
		tcc := fast ? f.tcc : rndn(2) == 0
		t0 := rndn(0x4000) | (1 + rndn(8)) << 14 | tw << 26 | th << 30
		if folds {
			// Any format, its CLUT loaded from random memory.
			fold_trial.psm = int(rndn(len(TEX_PSM)))
			t0 |= TEX_PSM[fold_trial.psm] << 20 | rndn(0x4000) << 37 | rndn(2) << 52 | rndn(32) << 56 | 1 << 61
			put(0x14 + u8(n), fold_tex1(cls)) // TEX1
		} else {
			t0 |= tpsm[rndn(len(tpsm))] << 20
			put(0x14 + u8(n), rnd() &~ u64(0x1c) | rndn(3) << 2) // TEX1: MXL 0..2
		}
		put(0x34 + u8(n), rnd()) // MIPTBP1
		put(0x36 + u8(n), rnd()) // MIPTBP2
		put(0x08 + u8(n), rnd() & 0xfff_ffff_ffff) // CLAMP
		put(0x06 + u8(n), t0 | u64(tcc) << 34 | tfx << 35) // TEX0
	}

	kind := rndn(7)
	fst := rndn(2) == 0
	fge := fast ? f.fge : rndn(2) == 0
	@(static, rodata) kinds := [7]int{0, 1, 1, 2, 2, 2, 3}
	fold_trial.fst, fold_trial.kind = fst, kinds[kind]
	prim := kind | rndn(2) << 3 | u64(tme) << 4 | u64(fge) << 5 | u64(fst) << 8 | n << 9
	if fast ? f.bl != 0xff : rndn(2) == 0 {prim |= 1 << 6} // ABE
	put(0x00, prim)

	@(static, rodata) need := [7]u64{1, 2, 2, 3, 3, 3, 2}
	nv := need[kind] * (1 + rndn(3)) + rndn(3)
	// Vertices round a centre in the scissor box, some outside it.
	cx, cy := x0 + rndn(x1 - x0 + 1), y0 + rndn(y1 - y0 + 1)
	size := 8 + rndn(kind == 6 ? 256 : 160)
	for _ in 0 ..< nv {
		q := transmute(u32)(0.5 + f32(rndn(1024)) / 512)
		put(0x01, rnd() & 0xffffffff | u64(q) << 32) // RGBAQ
		if fst {
			put(0x03, rndn(16 << tw) | rndn(16 << th) << 16) // UV
		} else {
			s := transmute(u32)(f32(rndn(1024)) / 512 - 0.25)
			t := transmute(u32)(f32(rndn(1024)) / 512 - 0.25)
			put(0x02, u64(s) | u64(t) << 32) // ST
		}
		x := (ox + cx) * 16 + rndn(size * 32) - size * 16
		y := (oy + cy) * 16 + rndn(size * 32) - size * 16
		if (fast && fge) || rndn(4) == 0 { // a fog row: a fog value on every vertex
			put(0x04, x | y << 16 | (rnd() & 0xffffff) << 32 | rndn(256) << 56) // XYZF2
		} else {
			put(0x05, x | y << 16 | (rnd() & 0xffffffff) << 32) // XYZ2
		}
	}
}

// What a fold class's trials held.
@(private = "file")
Fold_Count :: struct {
	trials, fast: int,
	lod:          [2]int, // pixels with LOD <= 0, > 0
	folded:       int, // pixels with LOD > 0 of a flat texture
	lcm, fst:     [2]int, // trials
	kind:         [4]int,
	psm:          [len(TEX_PSM)]int,
}

// Each class's contexts drawn with the fold on and off: the same local
// memory, word for word, and a flat texture exactly in the flat classes.
// Three trials in four take a textured PX_FAST row's context.
@(private = "file")
fold_trials :: proc() {
	TRIALS :: 240 // per class
	fs := gs.PX_FAST
	textured: [dynamic]int
	defer delete(textured)
	for f, i in fs {
		if f.tfx >= 0 {append(&textured, i)}
	}
	counts: [Fold_Class]Fold_Count
	for i in 0 ..< TRIALS * len(Fold_Class) {
		cls := Fold_Class(i % len(Fold_Class))
		fi := i % 4 == 3 ? -1 : textured[i / 4 * 3 % len(textured)]
		build(fi, cls)
		before = gs.vram

		gs.probe_fold(true)
		replay()
		after_fast = gs.vram
		flat := gs.probe_flat()
		if flat != (cls <= .Flat_Mxl0) {fail("fold trial %d (%v): flat %v", i, cls, flat)}

		gs.vram = before
		gs.probe_fold(false)
		replay()
		if gs.probe_flat() {fail("fold trial %d (%v): flat with the fold off", i, cls)}
		if after_fast != gs.vram {
			for v, j in after_fast {
				if v != gs.vram[j] {
					fail("fold trial %d (%v, PX_FAST %d): word %x folded %08x, not folded %08x", i, cls, fi, j, v, gs.vram[j])
					break
				}
			}
		}

		// The LODs the pixels have with the fold off, then with it on: a
		// folded pixel's LOD was above 0 and is not.
		gs.vram = before
		gs.probe_tally(true)
		replay()
		off := gs.probe_lods
		gs.probe_fold(true)
		gs.probe_tally(true)
		replay()
		on := gs.probe_lods
		gs.probe_tally(false)
		if on[0] + on[1] != off[0] + off[1] {fail("fold trial %d (%v): %v pixels folded, %v not", i, cls, on, off)}

		c := &counts[cls]
		c.trials += 1
		c.fast += int(fi >= 0)
		c.lod += off
		c.folded += off[1] - on[1]
		c.lcm[int(fold_trial.lcm)] += 1
		c.fst[int(fold_trial.fst)] += 1
		c.kind[fold_trial.kind] += 1
		c.psm[fold_trial.psm] += 1
		if failed > 8 {break}
	}
	for c, cls in counts {
		fmt.printfln("fold %-14v trials %d (fast %d)  pixels LOD <= 0 %d, > 0 %d, folded %d  LCM %v FST %v kinds %v formats %v",
			cls, c.trials, c.fast, c.lod[0], c.lod[1], c.folded, c.lcm, c.fst, c.kind, c.psm)
		if c.trials < 200 {fail("fold %v: only %d trials", cls, c.trials)}
		if c.lod[0] < 100_000 || c.lod[1] < 100_000 {fail("fold %v: pixels by LOD %v", cls, c.lod)}
		// A flat class folds every pixel with LOD > 0; the others none.
		if c.folded != (cls <= .Flat_Mxl0 ? c.lod[1] : 0) {fail("fold %v: %d of %d pixels folded", cls, c.folded, c.lod[1])}
		for n in c.lcm {if n < 60 {fail("fold %v: LCM %v", cls, c.lcm)}}
		for n in c.fst {if n < 60 {fail("fold %v: FST %v", cls, c.fst)}}
		for n in c.kind {if n < 15 {fail("fold %v: kinds %v", cls, c.kind)}}
		for n in c.psm {if n < 8 {fail("fold %v: formats %v", cls, c.psm)}}
	}
}

main :: proc() {
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer
	gs.gs_snap()
	for &v in gs.vram {v = u32(rnd())}

	FAST :: len(gs.PX_FAST)
	TRIALS :: 4800 // over 100 for each PX_FAST row
	// Per PX_FAST index, then random contexts. A trial's pixels are the
	// words its fast run changed; all of local memory is compared.
	trials, pixels: [FAST + 1]int
	random_fast := 0
	for i in 0 ..< TRIALS {
		fi := i % 4 == 3 ? -1 : (i / 4 * 3 + i % 4) % FAST // 3 in 4 fast
		build(fi)
		before = gs.vram

		gs.probe_generic(false)
		replay()
		got := gs.probe_fast()
		after_fast = gs.vram
		if fi >= 0 && got != fi {fail("trial %d: context of PX_FAST[%d] took proc %d", i, fi, got)}
		if fi < 0 && got >= 0 {random_fast += 1}
		changed := 0
		for v, j in after_fast {changed += int(v != before[j])}
		slot := fi >= 0 ? fi : FAST
		trials[slot] += 1
		pixels[slot] += changed

		gs.vram = before
		gs.probe_generic(true)
		replay()
		if gs.probe_fast() != -1 {fail("trial %d: generic run took a fast proc", i)}
		if after_fast != gs.vram {
			for v, j in after_fast {
				if v != gs.vram[j] {
					fail("trial %d (PX_FAST %d): word %x fast %08x generic %08x", i, fi, j, v, gs.vram[j])
					break
				}
			}
		}
		if failed > 8 {break}
	}
	gs.probe_generic(false)
	fold_trials()

	total := 0
	for k in 0 ..= FAST {
		name := k < FAST ? fmt.tprintf("PX_FAST[%d]", k) : "random"
		fmt.printfln("%-11s trials %4d  pixels compared %8d", name, trials[k], pixels[k])
		total += pixels[k]
		if k < FAST && trials[k] < 100 {fail("%s: only %d trials", name, trials[k])}
		if trials[k] == 0 || pixels[k] == 0 {fail("%s: no pixels drawn", name)}
	}
	fmt.printfln("random contexts on a fast proc: %d; words changed: %d", random_fast, total)
	if total < 1_000_000 {fail("only %d words changed", total)}
	if failed > 0 {
		fmt.eprintfln("gs_pixel: %d failed", failed)
		os.exit(1)
	}
	fmt.println("gs_pixel: ok")
}
