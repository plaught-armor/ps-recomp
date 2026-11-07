// The software GS's scanout (gs.scanout) against read_raw per pixel, bit
// for bit: random local memory, then random display settings for every
// format DISPFB can name, at random pages, widths, offsets and sizes, so
// rows cross page and block rows and offsets run past 2048. The 32-, 24-
// and 16-bit colour formats take the row path; the rest take read_raw.
package main

import "core:fmt"
import "core:os"
import "ps:ps2/gs"
import mem "ps:ps2/mem"

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
set_priv :: proc(off: u32, v: u64) {(^u64)(&mem.gsregs[off])^ = v}

@(private = "file")
PSMS := [?]u32{gs.PSMCT32, gs.PSMCT24, gs.PSMCT16, gs.PSMCT16S, gs.PSMT8, gs.PSMT4, gs.PSMT8H}

@(private = "file")
TRIALS :: 64

main :: proc() {
	failed := 0
	for i in 0 ..< len(gs.vram) {gs.vram[i] = u32(rnd())}
	for psm in PSMS {
		for t in 0 ..< TRIALS {
			fbp := rndn(0x200)
			fbw := 1 + rndn(0x3f)
			dbx := t % 4 == 0 ? 2048 - 1 - rndn(64) : rndn(0x800)
			dby := t % 4 == 1 ? 2048 - 1 - rndn(64) : rndn(0x800)
			magh := rndn(4)
			magv := rndn(2)
			dw := rndn(u64(gs.DISP_W) * (magh + 1))
			dh := rndn(u64(gs.DISP_H) * (magv + 1))
			circ := u32(rndn(2))
			set_priv(0x00, circ == 0 ? 1 : 2) // PMODE: that circuit only
			set_priv(0x20, 0) // SMODE2: progressive
			set_priv(0x70 + circ * 0x20, fbp | fbw << 9 | u64(psm) << 15 | dbx << 32 | dby << 43)
			set_priv(0x80 + circ * 0x20, magh << 23 | magv << 27 | dw << 32 | dh << 44)
			w, h := gs.scanout()
			narrow := psm == gs.PSMCT16 || psm == gs.PSMCT16S
			bad := 0
			for y in 0 ..< h {
				for x in 0 ..< w {
					c := gs.read_raw(psm, u32(fbp) * 32, u32(fbw), u32(dbx) + u32(x), u32(dby) + u32(y))
					if narrow {c = (c & 0x1f) << 3 | (c & 0x3e0) << 6 | (c & 0x7c00) << 9}
					c |= 0xff000000
					got := gs.screen[y * gs.DISP_W + x]
					if got != c {
						if bad == 0 {
							fmt.eprintfln("psm %x trial %d (fbp %x fbw %d at %d,%d size %dx%d): pixel %d,%d is %08x, read_raw gives %08x",
								psm, t, fbp, fbw, dbx, dby, w, h, x, y, got, c)
						}
						bad += 1
					}
				}
			}
			if bad > 0 {failed += 1}
		}
	}
	if failed > 0 {
		fmt.eprintfln("gs_scanout: %d trials failed", failed)
		os.exit(1)
	}
	fmt.printfln("gs_scanout: ok (%d formats, %d trials each)", len(PSMS), TRIALS)
}
