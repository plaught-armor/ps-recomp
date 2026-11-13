// The software GS's texture cache decodes a 16 x 16 tile with a loop for
// its format; `fetch` (gs.probe_fetch) reads one texel from local memory
// and the CLUT buffer, and is what a tile stands for. Over random local
// memory and a random CLUT, seeded with the values TEXA's AEM tells apart:
// textures of every format at every size and mip level, with the level's
// base anywhere, at the start and in the last blocks, where addresses wrap,
// buffer widths narrower than the level among them, every CSA and CLUT
// format, and TEXA at random. Every texel a decoded tile holds inside the
// level is compared with fetch, and every one outside it must be as it was
// before the decode. Each class of trial has a floor.
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

@(private = "file")
Class :: enum {
	// The format of the tile: tiles compared.
	CT32,
	CT24,
	CT16,
	CT16S,
	T8,
	T4,
	T8H,
	T4HL,
	T4HH,
	Other, // no texture format
	// How the level cuts the tile.
	Whole,
	Cut_Right,
	Cut_Bottom,
	Cut_Both,
	// The tile's page reaches the end of local memory or lies past it.
	Wrap,
	// An indexed tile with a 16-bit CLUT, and one whose CSA puts entries
	// past the end of the buffer.
	Clut16,
	Csa_Wrap,
	// Texels whose alpha AEM made 0: PSMCT24, a 16-bit format, a 16-bit CLUT.
	Aem_24,
	Aem_16,
	Aem_Clut,
	// A tile not cached: its level shares a page with the frame buffer.
	Bypass,
}

@(private = "file")
counts: [Class]int
@(private = "file")
texels, outside: int

// What a tile held before its decode.
@(private = "file")
BLANK :: 0x5ca1ab1e

@(private = "file")
FORMATS := [10]u32{0x00, 0x01, 0x02, 0x0a, 0x13, 0x14, 0x1b, 0x24, 0x2c, 0x30}

// Pixels a page of the format holds each way, and whether the buffer width
// counts pairs of pages.
@(private = "file")
page :: proc(psm: u32) -> (pw, ph: u32, half: bool) {
	switch psm {
	case 0x02, 0x0a: return 64, 64, false
	case 0x13: return 128, 64, true
	case 0x14: return 128, 128, true
	}
	return 64, 32, false
}

@(private = "file")
trial :: proc(i: int) {
	f := i % len(FORMATS)
	psm := FORMATS[f]
	indexed := f >= 4
	tw, th := rndn(11), rndn(11)
	n := u32(rndn(7))
	cw, ch := max(u32(1) << tw >> n, 1), max(u32(1) << th >> n, 1)

	// Each level's base and width: anywhere, or in the first or last blocks.
	lvl: [7]u64
	tbp, tbw: u32
	for &l, j in lvl {
		bp, bw: u64
		switch rndn(4) {
		case 0: bp = rndn(64)
		case 1: bp = 0x3fff - rndn(96)
		case: bp = rndn(0x4000)
		}
		if rndn(2) == 0 {bw = 1 + rndn(16)} else {bw = rndn(64)}
		l = bp | bw << 14
		if u32(j) == n {tbp, tbw = u32(bp), u32(bw)}
	}
	cpsm: u64
	switch rndn(3) {
	case 1: cpsm = 0x2
	case 2: cpsm = 0xa
	}
	csa := rndn(32)
	aem := rndn(2)
	ta0, ta1 := 1 + rndn(255), 1 + rndn(255)
	gs.gs_write(0x06, lvl[0] | u64(psm) << 20 | tw << 26 | th << 30 | cpsm << 51 | csa << 56) // TEX0
	gs.gs_write(0x14, 6 << 2) // TEX1: MXL 6
	gs.gs_write(0x34, lvl[1] | lvl[2] << 20 | lvl[3] << 40) // MIPTBP1
	gs.gs_write(0x36, lvl[4] | lvl[5] << 20 | lvl[6] << 40) // MIPTBP2
	gs.gs_write(0x3b, ta0 | aem << 15 | ta1 << 32) // TEXA
	gs.probe_ctx(6)

	// The corner tiles and three others.
	tiles_x, tiles_y := (cw + 15) >> 4, (ch + 15) >> 4
	picks := [7][2]u32{{0, 0}, {tiles_x - 1, 0}, {0, tiles_y - 1}, {tiles_x - 1, tiles_y - 1}, {}, {}, {}}
	for &p in picks[4:] {p = {u32(rndn(u64(tiles_x))), u32(rndn(u64(tiles_y)))}}
	seen: [7]^[256]u32
	nseen := 0
	pw, ph, half := page(psm)
	pick: for p in picks {
		x0, y0 := p.x * 16, p.y * 16
		tile := gs.probe_tile(n, x0, y0)
		if tile == nil {
			counts[.Bypass] += 1
			continue
		}
		for s in seen[:nseen] {if s == tile {continue pick}}
		seen[nseen] = tile
		nseen += 1

		w, h := min(16, cw - x0), min(16, ch - y0)
		counts[Class(f)] += 1
		counts[w == 16 ? h == 16 ? .Whole : .Cut_Bottom : h == 16 ? .Cut_Right : .Cut_Both] += 1
		if tbp + ((y0 / ph) * (half ? tbw >> 1 : tbw) + x0 / pw) * 32 + 31 >= 0x4000 {counts[.Wrap] += 1}
		if indexed && cpsm != 0 {counts[.Clut16] += 1}
		if indexed && csa * 16 + (f == 4 || f == 6 ? 255 : 15) > 511 {counts[.Csa_Wrap] += 1}
		texa := f == 1 || f == 2 || f == 3 || indexed && cpsm != 0
		for y in u32(0) ..< 16 {
			for x in u32(0) ..< 16 {
				got := tile[y << 4 | x]
				if x >= w || y >= h {
					outside += 1
					if got != BLANK && failed < 8 {
						fmt.eprintfln("trial %d psm %x level %d (%d x %d) at %x width %d: tile %d,%d texel %d,%d outside the level was written %08x", i, psm, n, cw, ch, tbp, tbw, p.x, p.y, x, y, got)
						failed += 1
					}
					continue
				}
				want := gs.probe_fetch(n, x0 + x, y0 + y)
				texels += 1
				if texa && aem != 0 && want >> 24 == 0 {
					counts[f == 1 ? .Aem_24 : indexed ? .Aem_Clut : .Aem_16] += 1
				}
				if got != want && failed < 8 {
					fmt.eprintfln("trial %d psm %x level %d (%d x %d) at %x width %d, cpsm %x csa %d, texa %x %x aem %d: tile %d,%d texel %d,%d is %08x, fetch gives %08x", i, psm, n, cw, ch, tbp, tbw, cpsm, csa, ta0, ta1, aem, p.x, p.y, x, y, got, want)
					failed += 1
				}
			}
		}
	}
	// The next trial's tiles start blank again.
	for s in seen[:nseen] {s^ = BLANK}
	gs.tc_flush()
}

main :: proc() {
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer
	gs.gs_snap()
	// The frame buffer: one pixel of page 0x100, no Z buffer.
	gs.gs_write(0x4c, 0x100 | 1 << 16) // FRAME
	gs.gs_write(0x4e, 0x101 | 1 << 32) // ZBUF: ZMSK
	gs.gs_write(0x40, 0) // SCISSOR
	gs.gs_write(0x1a, 1) // PRMODECONT

	// Local memory: random words, with those AEM tells apart among them,
	// a zero word, zero colour under any top byte, and halves of 0 and
	// 0x8000.
	half :: proc() -> u32 {
		switch rndn(3) {
		case 0: return 0
		case 1: return 0x8000
		}
		return u32(rnd()) & 0xffff
	}
	for &v in gs.vram {
		switch rndn(8) {
		case 0: v = 0
		case 1: v = u32(rnd()) & 0xff000000
		case 2: v = half() | half() << 16
		case: v = u32(rnd())
		}
	}
	// The CLUT: random words, a 16-bit colour of 0 or 0x8000 under any
	// upper half among them.
	buf, _, _ := gs.probe_clut()
	for &v in buf {
		switch rndn(4) {
		case 0: v = half() | u32(rnd()) & 0xffff0000
		case: v = u32(rnd())
		}
	}
	gs.probe_tiles_fill(BLANK)

	TRIALS :: 100_000
	for i in 0 ..< TRIALS {
		trial(i)
		if failed >= 8 {break}
	}
	fmt.printfln("trials %d, texels compared %d, texels outside a level %d", TRIALS, texels, outside)

	// Floors: about half of what the fixed seed gives.
	floors := [Class]int {
		.CT32       = 11_000,
		.CT24       = 11_000,
		.CT16       = 11_000,
		.CT16S      = 11_000,
		.T8         = 11_000,
		.T4         = 11_000,
		.T8H        = 11_000,
		.T4HL       = 11_000,
		.T4HH       = 11_000,
		.Other      = 11_000,
		.Whole      = 42_000,
		.Cut_Right  = 25_000,
		.Cut_Bottom = 25_000,
		.Cut_Both   = 21_000,
		.Wrap       = 18_000,
		.Clut16     = 46_000,
		.Csa_Wrap   = 10_000,
		.Aem_24     = 180_000,
		.Aem_16     = 300_000,
		.Aem_Clut   = 250_000,
		.Bypass     = 2_100,
	}
	for c in Class {
		fmt.printfln("%-10v %d", c, counts[c])
		if counts[c] < floors[c] {
			fmt.eprintfln("%v: %d, under the floor of %d", c, counts[c], floors[c])
			failed += 1
		}
	}
	if texels < 13_000_000 || outside < 16_000_000 {
		fmt.eprintfln("only %d texels compared, %d outside a level", texels, outside)
		failed += 1
	}
	if failed > 0 {
		fmt.eprintfln("gs_decode: %d failed", failed)
		os.exit(1)
	}
	fmt.println("gs_decode: ok")
}
