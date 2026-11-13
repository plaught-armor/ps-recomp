// The software GS's specialised pixel procs (gs.PX_FAST) against the
// generic pixel, bit for bit on all of local memory (frame and Z): random
// contexts of each PX_FAST kind (its fog, alpha test and destination alpha
// test with it), and fully random ones that take the generic proc, each
// drawing random points, lines, triangles, strips, fans and sprites over
// random memory. Frame and Z buffers sit at random pages and widths,
// sometimes on the same pages, and spans cross page and block rows, so the
// rows the rasteriser seeks once per span are checked against the per-pixel
// seek too.
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

// Registers of context n for PX_FAST[fi], or a random context for fi -1,
// and one primitive kind with its vertices.
@(private = "file")
build :: proc(fi: int) {
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

	tme := fast ? f.tfx >= 0 : rndn(2) == 0
	tw, th := 1 + rndn(8), 1 + rndn(8)
	if tme {
		@(static, rodata) tpsm := [?]u64{PSMCT32, PSMCT24, PSMCT16}
		tfx := fast ? u64(f.tfx) : rndn(4)
		tcc := fast ? f.tcc : rndn(2) == 0
		t0 := rndn(0x4000) | (1 + rndn(8)) << 14 | tpsm[rndn(len(tpsm))] << 20 | tw << 26 | th << 30
		put(0x06 + u8(n), t0 | u64(tcc) << 34 | tfx << 35) // TEX0
		put(0x14 + u8(n), rnd() &~ u64(0x1c) | rndn(3) << 2) // TEX1: MXL 0..2
		put(0x34 + u8(n), rnd()) // MIPTBP1
		put(0x36 + u8(n), rnd()) // MIPTBP2
		put(0x08 + u8(n), rnd() & 0xfff_ffff_ffff) // CLAMP
	}

	kind := rndn(7)
	fst := rndn(2) == 0
	fge := fast ? f.fge : rndn(2) == 0
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
