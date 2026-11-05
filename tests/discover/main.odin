// mips.mixed_words and mips.vtable_entries on a hand-built writable
// executable section, code and tables together, with r5900 rules. Entries
// 0x1000, 0x1040, 0x1100, 0x1140, 0x1180 and 0x1200 (prologues elsewhere)
// are given.
//
//   0x1000  li $v0, 1; jr $ra; nop          F0
//   0x100c  j 0x1200; nop                   thunk after `jr $ra`: entry
//   0x1014  j 0x1200; nop                   thunk after a `j` out: entry
//   0x101c  lw; jr $ra; sw                  leaf after a `j` out: entry
//   0x1028  lw $t9; jr $t9; nop             stub after `jr $ra`: entry
//   0x1034  lw $t9; jr $t9; nop             stub after `jr $t9`: entry
//   0x1040  lw $t9; jr $t9; nop             G, a stub
//   0x104c  lw $t9; jr $t9; nop             stubs in a row in G, which
//   0x1058  lw $t9; jr $t9; nop               builds no table: entries
//   0x1100  li; j 0x1114; nop               F1
//   0x110c  jr $ra; nop                     after a `j` inside F1: not
//   0x1114  jr $ra; nop
//   0x111c  lw $v0, 0($sp); jr $ra; nop     uses $sp: not
//   0x1128  jal 0x1200; nop; jr $ra; nop    calls: not
//   0x1140  lw $v0; jr $v0; nop             J, a jump through its table
//   0x114c  li $v0, 1; b 0x1160; nop        case
//   0x1158  li $v0, 2; nop                  case after a `b`: not
//   0x1160  jr $ra; nop
//   0x1168  li $v0, 3; jr $ra; nop          case after `jr $ra`: J's table
//   0x1174  lui; addiu 0x1340; addiu 0x1370 J's tables, built
//   0x1180  lw $v0; jr $v0; nop             K, a jump through its table
//   0x118c  li $v0, 1; b 0x1198; nop        case after `jr $v0`: K's table
//   0x1198  jr $ra; nop
//   0x11a0  li $v0, 2; jr $ra; nop          case after `jr $ra`: K's table
//   0x11ac  lui; addiu 0x1378               K's table, built
//   0x1200  jr $ra; nop                     F9
//   0x1208  jr $ra; nop                     in a pair only: not
//   0x1210  `jr $v0` with rt set; nop       data, not a `jr`
//   0x1218  jr $ra; nop                     after that: not
//   0x1220  j 0x1000; j 0x1000; nop         a jump in a delay slot: data
//   0x122c  jr $ra; nop                     after that: not
//   0x1300  the tables: eight runs of three or more code pointers and a
//           pair, each ended by a word that is no pointer; at 0x1370,
//           J's table and K's next to each other
//
// The case at 0x1158 is also in a run with other functions' words; it stays
// a label of J through build_module.
//
// Then mips.drop_data_labels on a second image, code and data in one
// section, entries 0x1000 and 0x1060, guessed 0x1080, jump table label
// 0x1088:
//
//   0x1000  lui + addiu for 0x1080, 0x1040, 0x1050 and 0x1068;
//           jal 0x1060; nop; jr $ra; nop
//   0x1040  addiu $sp, -16; jr $ra; addiu $sp, 16   a callback: stays
//   0x1050  li $v0, 1; jr $ra; nop                  a leaf no code reaches
//                                                    and no prologue, which
//                                                    runs to its return: stays
//   0x1060  li; li; li (0x1068); jr $ra; nop        0x1068 reached: stays
//   0x1074  addu with sa set; jr $ra; nop           data: goes
//   0x1080  "abcdefgh" (a guessed entry)            data: goes
//   0x1088  a jump table label                      stays
//
// In a section that holds code only, every label stays.
//
// Then mips.discover on secondary functions, which share their container's
// range, on a third image (code only), extra labels 0x100c, 0x1028, 0x104c:
//
//   0x1000  li $v0, 1; jr $ra; nop          C, the container
//   0x100c  li $v0, 2; jr $ra; nop          L, an extra label T never reaches
//   0x1018  li $v0, 3                       T, a secondary of C
//   0x101c  bne $a0, $0, 0x1000; nop        back into C
//   0x1024  j 0x1100                        out
//   0x1028  li $v0, 4                       D, its delay slot, an extra label
//   0x102c  li $v0, 5; jr $ra; nop          reached only by walking on from D
//   0x1040  lw $v0, 0($a0); jr $v0; nop     K, a jump through a register
//   0x104c  li $v0, 1; jr $ra; nop          Q, K's case, an extra label
//   0x1058  li $v0, 2; b 0x1040; nop        S, a secondary of K
//
// T keeps D (the probe reached it) and drops L; D is walked as code before
// the `j` claims it as a delay slot, so 0x102c is decoded and labelled. S's
// probe meets `jr $v0`, so S keeps Q.
package main

import "core:fmt"
import "core:os"
import "ps:recomp/mips"
import "ps:recomp/r5900"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL discover: %s (line %d)", what, loc.line)
		failed += 1
	}
}

@(private = "file")
NOP :: 0
@(private = "file")
JR_RA :: 0x03e00008

@(private = "file")
j :: proc(t: u32) -> u32 {return 0x08000000 | t >> 2 & 0x3ffffff}

@(private = "file")
put :: proc(data: []u8, a: u32, words: ..u32) {
	for w, k in words {
		o := int(a - 0x1000) + 4 * k
		data[o], data[o + 1], data[o + 2], data[o + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
	}
}

@(private = "file")
set :: proc(addrs: ..u32) -> (s: mips.Set) {
	for a in addrs {s[a] = {}}
	return
}

main :: proc() {
	data := make([]u8, 0x13a0)
	put(data, 0x1000, 0x24020001, JR_RA, NOP)
	put(data, 0x100c, j(0x1200), NOP, j(0x1200), NOP)
	put(data, 0x101c, 0x8c830004, JR_RA, 0xac800010) // lw $v1, 4($a0); sw $0, 16($a0)
	put(data, 0x1028, 0x8c990000, 0x03200008, NOP, 0x8c990000, 0x03200008, NOP) // lw $t9, 0($a0); jr $t9
	put(data, 0x1040, 0x8c990000, 0x03200008, NOP, 0x8c990000, 0x03200008, NOP, 0x8c990000, 0x03200008, NOP) // G
	put(data, 0x1100, 0x24020001, j(0x1114), NOP, JR_RA, NOP, JR_RA, NOP)
	put(data, 0x111c, 0x8fa20000, JR_RA, NOP) // lw $v0, 0($sp)
	put(data, 0x1128, 0x0c000480, NOP, JR_RA, NOP) // jal 0x1200
	put(data, 0x1140, 0x8c820000, 0x00400008, NOP) // lw $v0, 0($a0); jr $v0
	put(data, 0x114c, 0x24020001, 0x10000003, NOP, 0x24020002, NOP, JR_RA, NOP) // b 0x1160
	put(data, 0x1168, 0x24020003, JR_RA, NOP)
	put(data, 0x1174, 0x3c010000, 0x24211340, 0x24211370) // lui $at, 0; addiu $at, $at, ...
	put(data, 0x1180, 0x8c820000, 0x00400008, NOP) // K
	put(data, 0x11ac, 0x3c010000, 0x24211378)
	put(data, 0x118c, 0x24020001, 0x10000001, NOP, JR_RA, NOP, 0x24020002, JR_RA, NOP) // b 0x1198
	put(data, 0x1200, JR_RA, NOP, JR_RA, NOP)
	put(data, 0x1210, 0x00450008, NOP, JR_RA, NOP, j(0x1000), j(0x1000), NOP, JR_RA, NOP)
	X :: 0xffffffff
	put(data, 0x1300, 0x100c, 0x1014, 0x101c, X, 0x1028, 0x1034, 0x1200, X)
	put(data, 0x1320, 0x110c, 0x111c, 0x1128, X, 0x1158, 0x1200, 0x100c, X)
	put(data, 0x1340, 0x114c, 0x1158, 0x1168, X, 0x1208, 0x1200, X)
	put(data, 0x1360, 0x1218, 0x122c, 0x1000, X, 0x114c, 0x1168, 0x118c, 0x11a0, X, 0x104c, 0x1058, 0x1200, X)
	img := mips.Image {
		base     = 0x1000,
		data     = data,
		sections = {{name = ".text", addr = 0x1000, size = u32(len(data)), data = data, flags = mips.SHF_ALLOC | mips.SHF_WRITE | mips.SHF_EXEC}},
	}
	LO, HI :: 0x1000, 0x1300

	words: mips.Set
	runs: [dynamic]mips.Run
	mips.mixed_words(img, LO, HI, &words, &runs)
	check(len(runs) == 8, fmt.tprintf("%d runs, want 8 (the pair is none)", len(runs)))
	check(0x1208 in words, "the pair's words are mixed words")

	base := [?]u32{0x1000, 0x1040, 0x1100, 0x1140, 0x1180, 0x1200}
	entries := set(..base[:])
	mips.vtable_entries(r5900.RULES, img, LO, HI, runs[:], {}, &entries)
	for e in ([?]u32{0x100c, 0x1014, 0x101c, 0x1028, 0x1034, 0x104c, 0x1058}) {
		check(e in entries, fmt.tprintf("%x not an entry", e))
	}
	for e in ([?]u32{0x110c, 0x111c, 0x1128, 0x114c, 0x1158, 0x1168, 0x118c, 0x11a0, 0x1208, 0x1218, 0x122c}) {
		check(e not_in entries, fmt.tprintf("%x an entry", e))
	}
	check(len(entries) == len(base) + 7, fmt.tprintf("%d entries, want %d", len(entries), len(base) + 7))

	// A word table_labels kept as a jump table label stays one.
	skipped := set(..base[:])
	mips.vtable_entries(r5900.RULES, img, LO, HI, runs[:], set(0x100c), &skipped)
	check(0x100c not_in skipped && 0x1014 in skipped, "skip: 100c an entry, or 1014 not")

	funcs := mips.build_module(r5900.RULES, img, LO, HI, entries, set(0x1158), {}, {}, {})
	found := false
	for f in funcs {
		check(f.entry != 0x1158 && f.entry != 0x1168, fmt.tprintf("a function at %x", f.entry))
		if f.entry == 0x1140 {
			found = true
			check(0x1158 in f.labels, "the case at 1158 not a label of J")
		}
	}
	check(found, "no function at 1140")

	mixed := make([]u8, 0x90)
	put(mixed, 0x1000, 0x3c010000, 0x24241080, 0x3c010000, 0x24251040, 0x3c010000, 0x24261050, 0x3c010000, 0x24271068) // lui $at, 0; addiu $a0..$a3, $at, ...
	put(mixed, 0x1020, 0x0c000418, NOP, JR_RA, NOP) // jal 0x1060
	put(mixed, 0x1040, 0x27bdfff0, JR_RA, 0x27bd0010)
	put(mixed, 0x1050, 0x24020001, JR_RA, NOP)
	put(mixed, 0x1060, 0x24020002, 0x24020003, 0x24020004, JR_RA, NOP)
	put(mixed, 0x1074, 0x00a41061, JR_RA, NOP) // addu $v0, $a1, $a0 with sa 1
	put(mixed, 0x1080, 0x64636261, 0x68676665)
	for flags in ([2]u32{mips.SHF_ALLOC | mips.SHF_WRITE | mips.SHF_EXEC, mips.SHF_ALLOC | mips.SHF_EXEC}) {
		code := mips.Image {
			base     = 0x1000,
			data     = mixed,
			sections = {{name = ".text", addr = 0x1000, size = u32(len(mixed)), data = mixed, flags = flags}},
		}
		labels := set(0x1040, 0x1050, 0x1068, 0x1074, 0x1080, 0x1088)
		mips.drop_data_labels(r5900.RULES, code, 0x1000, 0x1090, set(0x1000, 0x1060, 0x1080), set(0x1080), set(0x1088), &labels)
		if flags & mips.SHF_WRITE != 0 {
			check(0x1040 in labels && 0x1050 in labels && 0x1068 in labels && 0x1088 in labels, "mixed: a label on code dropped")
			check(0x1074 not_in labels && 0x1080 not_in labels, "mixed: a label on data kept")
		} else {
			check(len(labels) == 6, fmt.tprintf("code only: %d labels, want 6", len(labels)))
		}
		delete(labels)
	}

	sec := make([]u8, 0x80)
	put(sec, 0x1000, 0x24020001, JR_RA, NOP, 0x24020002, JR_RA, NOP)
	put(sec, 0x1018, 0x24020003, 0x1480fff8, NOP, j(0x1100), 0x24020004, 0x24020005, JR_RA, NOP) // bne $a0, $0, 0x1000
	put(sec, 0x1040, 0x8c820000, 0x00400008, NOP, 0x24020001, JR_RA, NOP, 0x24020002, 0x1000fff8, NOP) // b 0x1040
	secondaries := mips.Image {
		base     = 0x1000,
		data     = sec,
		sections = {{name = ".text", addr = 0x1000, size = u32(len(sec)), data = sec, flags = mips.SHF_ALLOC | mips.SHF_EXEC}},
	}
	extras := []u32{0x100c, 0x1028, 0x104c}
	c := mips.func_make(0x1000, 0x1040)
	mips.discover(r5900.RULES, secondaries, c, extras)
	check(0x100c in c.labels && 0x100c in c.insns, "container: lost its extra label 0x100c")
	mips.func_free(c)
	t := mips.func_make(0x1018, 0x1040, 0x1000)
	mips.discover(r5900.RULES, secondaries, t, extras)
	check(0x100c not_in t.labels && 0x100c not_in t.insns && 0x1010 not_in t.insns, "secondary: walked the unreached label 0x100c")
	check(0x1000 in t.labels && 0x1000 in t.insns && 0x1004 in t.insns, "secondary: lost the branch back to 0x1000")
	check(0x1028 in t.labels && 0x1028 in t.delay, "secondary: lost the delay-slot label 0x1028")
	check(0x102c in t.insns && 0x102c in t.labels && 0x1030 in t.insns, "secondary: 0x102c after the delay-slot label not walked")
	check(len(t.labels) == 4, fmt.tprintf("secondary: %d labels, want 4", len(t.labels)))
	mips.func_free(t)
	s := mips.func_make(0x1058, 0x1080, 0x1040)
	mips.discover(r5900.RULES, secondaries, s, extras)
	check(s.computed, "computed secondary: `jr $v0` not seen")
	check(0x104c in s.labels && 0x104c in s.insns && 0x1050 in s.insns, "computed secondary: lost the case 0x104c")
	mips.func_free(s)
	delete(sec)

	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok discover")
}
