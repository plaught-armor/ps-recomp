// The software GS's CLUT load, which reads CSM1's entries at constant
// offsets from the block at CBP, against the load it replaced, which took
// each entry's pixel through the address procs (gs.clut_load_ref): after
// every load the whole CLUT buffer and both remembered block pointers are
// the same. Random local memory, TEX0, TEX2 and TEXCLUT: every CLD, with
// the remembered pointer equal and different, every CSA, both storage
// modes, 16 and 256 entries, every CPSM the field can hold, and block
// pointers low, anywhere, and in the last blocks, where the address
// wraps. Each class has a floor.
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
PSMCT32, PSMCT24, PSMCT16, PSMCT16S, PSMT8, PSMT4, PSMT8H :: 0x00, 0x01, 0x02, 0x0a, 0x13, 0x14, 0x1b

@(private = "file")
Class :: enum {
	CT32, // CPSM
	CT24,
	CT16,
	CT16S,
	No_Format, // a CPSM that is no CLUT format: the entries load as 0
	N16,
	N256,
	CSM1,
	CSM2,
	CLD0,
	CLD1,
	CLD2,
	CLD3,
	CLD4_Same, // CBP equal to the pointer CLD 4 remembers: no load
	CLD4_New,
	CLD5_Same,
	CLD5_New,
	CLD6,
	CLD7,
	Low, // CBP under 0x100
	Mid,
	Last, // CBP in the last 8 blocks
	Wrap32, // a CSM1 load of words that runs off the end of local memory
	Wrap16, // the same of halfwords
	Store_Wrap, // entries stored past the end of the buffer, from its start
	TEX2, // loaded by a TEX2 write
	Changed, // the load changed the buffer
}

@(private = "file")
counts: [Class]int

@(private = "file")
trials, loads: int

// One load by both loaders from the same state.
@(private = "file")
trial :: proc() {
	buf, c0, c1 := gs.probe_clut()
	cls: bit_set[Class]

	cbp: u64
	switch rndn(3) {
	case 0: cbp = rndn(0x100); cls += {.Low}
	case 1: cbp = rndn(0x4000); cls += {.Mid}
	case 2: cbp = 0x3ff8 + rndn(8); cls += {.Last}
	}
	cpsm := rndn(16)
	formats := [4]u64{PSMCT32, PSMCT24, PSMCT16, PSMCT16S}
	if rndn(4) != 0 {cpsm = formats[rndn(4)]}
	switch cpsm {
	case PSMCT32: cls += {.CT32}
	case PSMCT24: cls += {.CT24}
	case PSMCT16: cls += {.CT16}
	case PSMCT16S: cls += {.CT16S}
	case: cls += {.No_Format}
	}
	psms := [6]u64{PSMT8, PSMT8H, PSMT4, PSMCT32, PSMT8, 0x24}
	psm := psms[rndn(6)]
	n := psm == PSMT8 || psm == PSMT8H ? 256 : 16
	cls += {n == 256 ? .N256 : .N16}
	csm2 := rndn(4) == 0
	cls += {csm2 ? .CSM2 : .CSM1}
	csa := rndn(32)
	cld := rndn(8)

	// The buffer and the remembered pointers before the load: random, the
	// pointer CLD 4 or 5 compares equal to CBP half the time.
	for &w in buf {w = u32(rnd())}
	c0^, c1^ = u32(rndn(0x4000)), u32(rndn(0x4000))
	same := rndn(2) == 0
	if same && cld == 4 {c0^ = u32(cbp)}
	if same && cld == 5 {c1^ = u32(cbp)}
	loaded := true
	switch cld {
	case 0: cls += {.CLD0}; loaded = false
	case 1: cls += {.CLD1}
	case 2: cls += {.CLD2}
	case 3: cls += {.CLD3}
	case 4:
		loaded = u32(cbp) != c0^
		cls += {loaded ? .CLD4_New : .CLD4_Same}
	case 5:
		loaded = u32(cbp) != c1^
		cls += {loaded ? .CLD5_New : .CLD5_Same}
	case 6: cls += {.CLD6}; loaded = false
	case 7: cls += {.CLD7}; loaded = false
	}
	if loaded {
		if !csm2 && n == 256 {
			if (cpsm == PSMCT32 || cpsm == PSMCT24) && cbp << 6 + 255 >= gs.VRAM_WORDS {cls += {.Wrap32}}
			if (cpsm == PSMCT16 || cpsm == PSMCT16S) && cbp << 7 + 255 >= 2 * gs.VRAM_WORDS {cls += {.Wrap16}}
		}
		if int(csa) * 16 + n > 512 {cls += {.Store_Wrap}}
	}

	tex0 := rnd() & 0x1f_ffff_ffff &~ (u64(0x3f) << 20) | psm << 20 | cbp << 37 | cpsm << 51 | u64(csm2) << 55 | csa << 56 | cld << 61
	gs.gs_write(0x1c, rnd() & 0x3f_ffff) // TEXCLUT
	reg := u8(0x06 + rndn(2))
	if rndn(4) == 0 {
		// TEX2 keeps the rest of the TEX0 it is merged into.
		gs.state.regs[reg] = rnd()
		reg += 0x10
		cls += {.TEX2}
	}

	before, b0, b1 := buf^, c0^, c1^
	gs.clut_load_ref(tex0)
	want, w0, w1 := buf^, c0^, c1^
	buf^, c0^, c1^ = before, b0, b1
	gs.gs_write(reg, tex0)

	trials += 1
	if loaded {loads += 1}
	if want != before {cls += {.Changed}}
	for c in cls {counts[c] += 1}
	if (want != before) && !loaded {
		fmt.eprintfln("trial %d TEX0 %016x: the reference loaded under CLD %d, pointers %x %x", trials, tex0, cld, b0, b1)
		failed += 1
	}
	if failed > 8 {return}
	if c0^ != w0 || c1^ != w1 {
		fmt.eprintfln("trial %d TEX0 %016x: remembered pointers %x %x, the reference's %x %x", trials, tex0, c0^, c1^, w0, w1)
		failed += 1
		return
	}
	for w, i in buf {
		if w != want[i] {
			fmt.eprintfln("trial %d TEX0 %016x by register %02x: entry %d is %08x, the reference's %08x", trials, tex0, reg, i, w, want[i])
			failed += 1
			return
		}
	}
}

main :: proc() {
	gs.state.write = gs.write
	gs.state.transfer = gs.transfer
	gs.gs_snap()
	for &w in gs.vram {w = u32(rnd())}

	TRIALS :: 400_000
	for _ in 0 ..< TRIALS {
		trial()
		if failed > 8 {break}
	}
	fmt.printfln("loads compared %d, %d of them loading", trials, loads)

	// Floors: about half of what the fixed seed gives.
	floors := [Class]int {
		.CT32       = 40_000,
		.CT24       = 40_000,
		.CT16       = 40_000,
		.CT16S      = 40_000,
		.No_Format  = 37_000,
		.N16        = 100_000,
		.N256       = 100_000,
		.CSM1       = 150_000,
		.CSM2       = 50_000,
		.CLD0       = 25_000,
		.CLD1       = 25_000,
		.CLD2       = 25_000,
		.CLD3       = 25_000,
		.CLD4_Same  = 12_000,
		.CLD4_New   = 12_000,
		.CLD5_Same  = 12_000,
		.CLD5_New   = 12_000,
		.CLD6       = 25_000,
		.CLD7       = 25_000,
		.Low        = 66_000,
		.Mid        = 66_000,
		.Last       = 66_000,
		.Wrap32     = 1_900,
		.Wrap16     = 600,
		.Store_Wrap = 23_000,
		.TEX2       = 50_000,
		.Changed    = 100_000,
	}
	for c in Class {
		fmt.printfln("%-10v loads %d", c, counts[c])
		if counts[c] < floors[c] {
			fmt.eprintfln("%v: %d loads, under the floor of %d", c, counts[c], floors[c])
			failed += 1
		}
	}
	if failed > 0 {
		fmt.eprintfln("gs_clut: %d failed", failed)
		os.exit(1)
	}
	fmt.println("gs_clut: ok")
}
