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
//
// Then mips.discover on a branch into a later jump's delay slot, on a fourth
// image (code only), function 0x1000:
//
//   0x1000  beqz $a0, 0x1014; nop
//   0x1008  li $v0, 1; li $v0, 2
//   0x1010  j 0x1024                        its delay slot, 0x1014, is
//   0x1014  li $v0, 3                         also the branch's target
//   0x1018  li $v0, 4; jr $ra; nop          reached only by walking on
//   0x1024  jr $ra; nop                       from 0x1014
//
// The fall-through decodes 0x1014 as a delay slot first; the branch to it
// still walks on to 0x1018.
//
// Then the same on a fifth image (code only), first for a secondary's probe,
// function 0x100c in range 0x1000, extra label 0x1020:
//
//   0x100c  beqz $a0, 0x101c; nop
//   0x1014  li $v0, 2
//   0x1018  j 0x1100                        out; its delay slot, 0x101c, is
//   0x101c  li $v0, 3                         also the branch's target
//   0x1020  li $v0, 4; jr $ra; nop          E, an extra label reached only
//                                             by walking on from 0x101c
//
// The probe walks on from 0x101c, so it keeps E. Then for the computed
// sweep, function 0x1040, no extra labels:
//
//   0x1040  beqz $a0, 0x1054; nop
//   0x1048  lw $v0, 0($a0); nop
//   0x1050  j 0x1100                        its delay slot, 0x1054, is
//   0x1054  li $v0, 3                         also the branch's target
//   0x1058  jr $v0                          reached only from 0x1054
//   0x105c  b 0x1068                          its delay slot, no start
//   0x1060  li $v0, 4; nop...                 swept as code
//
// Walking on from 0x1054 meets `jr $v0`, so the sweep runs. It starts no
// walk at the delay slot 0x105c, so 0x1060 is no slot of that `b`.
package main

import "core:fmt"
import "core:os"
import mem "ps:ps2/mem"
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

	slot := make([]u8, 0x30)
	put(slot, 0x1000, 0x10800004, NOP, 0x24020001, 0x24020002, j(0x1024), 0x24020003) // beq $a0, $0, 0x1014
	put(slot, 0x1018, 0x24020004, JR_RA, NOP, JR_RA, NOP)
	slots := mips.Image {
		base     = 0x1000,
		data     = slot,
		sections = {{name = ".text", addr = 0x1000, size = u32(len(slot)), data = slot, flags = mips.SHF_ALLOC | mips.SHF_EXEC}},
	}
	b := mips.func_make(0x1000, 0x1030)
	mips.discover(r5900.RULES, slots, b, {})
	check(0x1014 in b.labels && 0x1014 in b.delay, "delay-slot target: 0x1014 not a label in a delay slot")
	check(0x1018 in b.insns && 0x101c in b.insns && 0x1020 in b.insns, "delay-slot target: 0x1018 after it not walked")
	mips.func_free(b)
	delete(slot)

	five := make([]u8, 0x70)
	put(five, 0x100c, 0x10800003, NOP, 0x24020002, j(0x1100), 0x24020003, 0x24020004, JR_RA, NOP) // beq $a0, $0, 0x101c
	put(five, 0x1040, 0x10800004, NOP, 0x8c820000, NOP, j(0x1100), 0x24020003) // beq $a0, $0, 0x1054
	put(five, 0x1058, 0x00400008, 0x10000002, 0x24020004) // jr $v0; b 0x1068
	fives := mips.Image {
		base     = 0x1000,
		data     = five,
		sections = {{name = ".text", addr = 0x1000, size = u32(len(five)), data = five, flags = mips.SHF_ALLOC | mips.SHF_EXEC}},
	}
	p := mips.func_make(0x100c, 0x102c, 0x1000)
	mips.discover(r5900.RULES, fives, p, {0x1020})
	check(0x101c in p.labels && 0x101c in p.delay, "probe: 0x101c not a label in a delay slot")
	check(0x1020 in p.labels && 0x1020 in p.insns && 0x1024 in p.insns, "probe: dropped the extra label 0x1020 after the delay-slot target")
	mips.func_free(p)
	k := mips.func_make(0x1040, 0x1070)
	mips.discover(r5900.RULES, fives, k, {})
	check(0x1054 in k.labels && 0x1054 in k.delay && 0x1058 in k.insns, "sweep: 0x1058 after the delay-slot target not walked")
	check(k.computed, "sweep: `jr $v0` after the delay-slot target not seen")
	check(0x1060 in k.labels && 0x1060 not_in k.delay, "sweep: walked from the delay slot 0x105c")
	mips.func_free(k)
	delete(five)

	// A data word holding a delay slot's address (FFX 0x3304a0 = 0x24fffc,
	// the `addiu $sp, $sp, 0x20` slot right before a prologue) is no
	// entry; a Loose lead took it, and the function before lost its slot.
	ptr := make([]u8, 0x18)
	put(ptr, 0x1000, JR_RA, 0x27bd0020, 0x27bdffe0, JR_RA, 0x27bd0020) // addiu $sp, $sp, +-0x20
	ptrs := mips.Image {
		base     = 0x1000,
		data     = ptr,
		sections = {{name = ".text", addr = 0x1000, size = u32(len(ptr)), data = ptr, flags = mips.SHF_ALLOC | mips.SHF_EXEC}},
	}
	pe, pc, pg := mips.module_entries(r5900.RULES, ptrs, 0x1000, 0x1018, nil, set(0x1004, 0x1008), {})
	check(0x1004 not_in pe, "pointer to a delay slot: 0x1004 an entry")
	check(0x1008 in pe, "pointer to a prologue: 0x1008 not an entry")
	delete(pe)
	delete(pc)
	delete(pg)
	delete(ptr)

	// A prologue right after a jump is an entry (Okami 0x4632f8 holds
	// 0x401280, a prologue after the `jr $ra` at 0x40127c).
	ok_ptr := make([]u8, 0x10)
	put(ok_ptr, 0x1000, JR_RA, 0x27bdffc0, JR_RA, 0x27bd0040) // addiu $sp, $sp, -+0x40
	ok_img := mips.Image {
		base     = 0x1000,
		data     = ok_ptr,
		sections = {{name = ".text", addr = 0x1000, size = u32(len(ok_ptr)), data = ok_ptr, flags = mips.SHF_ALLOC | mips.SHF_EXEC}},
	}
	oe, oc, og := mips.module_entries(r5900.RULES, ok_img, 0x1000, 0x1010, nil, set(0x1004), {})
	check(0x1004 in oe, "pointer to a prologue after a jr: 0x1004 not an entry")
	delete(oe)
	delete(oc)
	delete(og)

	// A data word that decodes as a jal to a delay slot calls nothing
	// (Burnout 3's byte table word 0x0c0c0f01 at 0x48c9b4, `jal 0x303c04`,
	// the slot of the `jr $ra` that ends 0x303a40, which lost its
	// `addiu $sp, $sp, 0x230`); a jal to a prologue still does.
	jal_ds := make([]u8, 0x18)
	put(jal_ds, 0x1000, 0x27bdfdd0, JR_RA, 0x27bd0230, 0x0c000402, 0x0c000400, 0) // addiu $sp, $sp, -+0x230; jal 0x1008; jal 0x1000
	jal_img := mips.Image {
		base     = 0x1000,
		data     = jal_ds,
		sections = {{name = ".text", addr = 0x1000, size = u32(len(jal_ds)), data = jal_ds, flags = mips.SHF_ALLOC | mips.SHF_EXEC}},
	}
	je, jc, jg := mips.module_entries(r5900.RULES, jal_img, 0x1000, 0x1018, nil, {}, {})
	check(0x1008 not_in jc && 0x1008 not_in je, "jal to a delay slot: 0x1008 a call target or entry")
	check(0x1000 in jc && 0x1000 in je, "jal to a prologue: 0x1000 not a call target")
	delete(je)
	delete(jc)
	delete(jg)
	delete(jal_ds)
	delete(ok_ptr)

	test_unpacked()
	test_unpack_agree()
	test_jump_tables()
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok discover")
}

// r5900.discover on one writable executable section, code and jump tables
// together (Burnout 3's one section: its printf's `%s` case 0x129c10 was no
// label, so the native jump to it missed and ran in the interpreter):
//
//   0x1000  lui; addiu $a1 = 0x1030             F, a built label stops the
//   0x1008  sll; lui $v1, 0; addu; lw 0x1100($v1); jr $v1; nop   sweep
//   0x1020  li $v0, 1; jr $ra; nop             case A
//   0x102c  li $v0, 2                           case B, past a return: guessed
//   0x1030  jr $ra; nop
//   0x1040  lui $s5, 0; lui; addiu $a1 = 0x1078 G, the table's lui hoisted
//   0x104c  beqz $a0, 0x1078; sll                 before a branch
//   0x1054  addiu $v1, $s5, 0x1110; addu; lw 0($v0); jr $a0; nop
//   0x1068  li $v0, 3; b 0x1078; nop            case C
//   0x1074  li $v0, 4                           case D
//   0x1078  jr $ra; nop
//   0x1080  lui; addiu $a1 = 0x1098             N, a jump through a loaded
//   0x1088  lw $v1, 0($a0); jr $v1; nop           pointer, no table
//   0x1094  li $v0, 5; jr $ra; nop
//   0x1100  F's table A, B, A; G's C, D; a run of three words into N
//
// A to D are labels (B a guessed entry that must not end F's table); 0x1094 is no label.
@(private = "file")
test_jump_tables :: proc() {
	data := make([]u8, 0x140)
	defer delete(data)
	put(data, 0x1000, 0x3c050000, 0x24a51030, 0x00041080, 0x3c030000, 0x00621821, 0x8c631100, 0x00600008, NOP)
	put(data, 0x1020, 0x24020001, JR_RA, NOP, 0x24020002, JR_RA, NOP)
	put(data, 0x1040, 0x3c150000, 0x3c050000, 0x24a51078, 0x1080000a, 0x00041080)
	put(data, 0x1054, 0x26a31110, 0x00431021, 0x8c440000, 0x00800008, NOP)
	put(data, 0x1068, 0x24020003, 0x10000002, NOP, 0x24020004, JR_RA, NOP)
	put(data, 0x1080, 0x3c050000, 0x24a51098, 0x8c830000, 0x00600008, NOP, 0x24020005, JR_RA, NOP)
	X :: 0xffffffff
	put(data, 0x1100, 0x1020, 0x102c, 0x1020, X, 0x1068, 0x1074, X, X, 0x1094, 0x1094, 0x1098, X)
	img := mips.Image {
		name     = "jump tables",
		base     = 0x1000,
		entry    = 0x1000,
		data     = data,
		sections = {{name = ".text", addr = 0x1000, size = u32(len(data)), data = data, flags = mips.SHF_ALLOC | mips.SHF_WRITE | mips.SHF_EXEC}},
	}
	funcs, labels, _, _ := r5900.discover({path = "jump tables"}, img)
	defer delete(labels)
	// Each case and the function it is a label of.
	want := [?][2]u32{{0x1020, 0x1000}, {0x102c, 0x1000}, {0x1068, 0x1040}, {0x1074, 0x1040}}
	for ce in want {
		c, e := ce[0], ce[1]
		ok := false
		for f in funcs {
			if f.start == e {ok = ok || c in f.labels}
		}
		check(ok || c in labels, fmt.tprintf("jump table: case %x no label of %x", c, e))
	}
	check(0x1094 not_in labels, "jump table: 0x1094, in a run with no table jump, a label")
	for f in funcs {mips.func_free(f)}
	delete(funcs)
}

// mips.unpacked on a stub section that starts [u32 size][zlib stream][u32
// dest][u32 entry]: the stream inflates to 64 bytes, 0..31 twice.
@(private = "file")
ZLIB := [?]u8 {
	0x78, 0xda, 0x63, 0x60, 0x64, 0x62, 0x66, 0x61, 0x65, 0x63, 0xe7, 0xe0, 0xe4, 0xe2, 0xe6, 0xe1, 0xe5, 0xe3, 0x17, 0x10, 0x14, 0x12,
	0x16, 0x11, 0x15, 0x13, 0x97, 0x90, 0x94, 0x92, 0x96, 0x91, 0x95, 0x93, 0x67, 0x20, 0x20, 0x0f, 0x00, 0x68, 0xe0, 0x03, 0xe1,
}

@(private = "file")
le :: proc(b: []u8, o: int, v: u32) {
	b[o], b[o + 1], b[o + 2], b[o + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
}

// The stub's section: the header words, then 16 bytes of its code.
@(private = "file")
stub :: proc(size, dest, entry: u32) -> []u8 {
	t := make([]u8, 4 + len(ZLIB) + 8 + 16)
	le(t, 0, size)
	copy(t[4:], ZLIB[:])
	le(t, 4 + len(ZLIB), dest)
	le(t, 8 + len(ZLIB), entry)
	return t
}

@(private = "file")
stub_sections :: proc(t: []u8) -> []mips.Section {
	out := make([]mips.Section, 2)
	out[0] = {name = ".text", addr = 0x00800000, size = u32(len(t)), data = t, flags = mips.SHF_ALLOC | mips.SHF_EXEC}
	out[1] = {name = ".bss", addr = 0x00900000, size = 0x1000, flags = mips.SHF_ALLOC | mips.SHF_WRITE}
	return out
}

@(private = "file")
test_unpacked :: proc() {
	u, entry, ok := mips.unpacked(stub_sections(stub(64, 0x00100000, 0x00100024)), 0x00800010)
	check(ok && entry == 0x00100024 && u.name == ".unpacked" && u.addr == 0x00100000 && u.size == 64, "unpacked: the stub not found")
	check(u.flags == mips.SHF_ALLOC | mips.SHF_EXEC | mips.SHF_WRITE, "unpacked: not writable executable code")
	check(len(u.data) == 64, fmt.tprintf("unpacked: %d bytes, want 64", len(u.data)))
	for k in 0 ..< len(u.data) {
		check(u.data[k] == u8(k & 31), fmt.tprintf("unpacked: byte %d is %x", k, u.data[k]))
	}
	Bad :: struct {
		size, dest, entry, elf_entry: u32,
		what:                         string,
	}
	bads := [?]Bad {
		{63, 0x00100000, 0x00100024, 0x00800010, "a size the stream does not inflate to"},
		{64, 0x00100002, 0x00100024, 0x00800010, "dest not aligned"},
		{64, 0x00100000, 0x00100040, 0x00800010, "entry past the code"},
		{64, 0x00100000, 0x000ffffc, 0x00800010, "entry before the code"},
		{64, 0x008fffe0, 0x008fffe0, 0x00800010, "the code over .bss"},
		{64, 0x00800000, 0x00800000, 0x00800010, "the code over the stub"},
		{64, 0x00ffffe0, 0x00ffffe0, 0x00800010, "the code past the entry's 16 MB"},
		{64, 0x00100000, 0x00100024, 0x01000010, "an ELF entry in another 16 MB"},
	}
	for c in bads {
		_, _, bad := mips.unpacked(stub_sections(stub(c.size, c.dest, c.entry)), c.elf_entry)
		check(!bad, fmt.tprintf("unpacked: took %s", c.what))
	}
	plain := stub(64, 0x00100000, 0x00100024)
	plain[4] = 0x27 // no zlib header: an ordinary .text
	_, _, bad := mips.unpacked(stub_sections(plain), 0x00800010)
	check(!bad, "unpacked: took a section without a zlib header")
}

// An ELF with the program headers of stub_sections: the stub's segment
// (executable) at 0x00800000 and 0x1000 bytes of BSS at 0x00900000.
@(private = "file")
stub_elf :: proc(t: []u8, elf_entry: u32) -> []u8 {
	PH :: 52
	DATA :: PH + 2 * 32
	f := make([]u8, DATA + len(t))
	le(f, 0, 0x464c457f)
	f[4], f[5] = 1, 1
	le(f, 24, elf_entry)
	le(f, 28, PH)
	f[42], f[44] = 32, 2
	// type, offset, vaddr, paddr, filesz, memsz, flags
	ph := [2][7]u32{{1, DATA, 0x00800000, 0x00800000, u32(len(t)), u32(len(t)), 5}, {1, 0, 0x00900000, 0x00900000, 0, 0x1000, 6}}
	for h, i in ph {
		for x, k in h {le(f, PH + i * 32 + k * 4, x)}
	}
	copy(f[DATA:], t)
	return f
}

// recomp/mips unpacked and ps2/mem load_elf's unpack keep the same checks:
// on the same stub, both find the same code at the same address or both
// refuse it. If they ever part, the runtime's text check keeps other words
// than the blob was compiled from, and the run interprets.
@(private = "file")
test_unpack_agree :: proc() {
	mem.mem_init()
	Case :: struct {
		size, dest, entry, elf_entry: u32,
		header:                       u8,
		what:                         string,
	}
	cases := [?]Case {
		{64, 0x00100000, 0x00100024, 0x00800010, 0x78, "a good stream"},
		{64, 0x00100000, 0x00100024, 0x00800010, 0x27, "no zlib header"},
		{65, 0x00100000, 0x00100024, 0x00800010, 0x78, "a short inflate"},
		{64, 0x00100002, 0x00100024, 0x00800010, 0x78, "dest unaligned"},
		{64, 0x00100000, 0x00100040, 0x00800010, 0x78, "entry past the code"},
		{64, 0x008fffe0, 0x008fffe0, 0x00800010, 0x78, "the code over the BSS"},
		{64, 0x00100000, 0x00100024, 0x01000010, 0x78, "an ELF entry in another 16 MB"},
		{64, 0x80100000, 0x80100024, 0x80800010, 0x78, "a kseg0 dest"},
	}
	for c in cases {
		t := stub(c.size, c.dest, c.entry)
		t[4] = c.header
		u, _, ok := mips.unpacked(stub_sections(t), c.elf_entry)
		f := stub_elf(t, c.elf_entry)
		_, loaded := mem.load_elf(f)
		check(loaded, fmt.tprintf("unpack agree: %s: the ELF did not load", c.what))
		rt := mem.unpacked_code != nil
		check(ok == rt, fmt.tprintf("unpack agree: %s: recomp %v, runtime %v", c.what, ok, rt))
		if ok && rt {
			check(u.addr == mem.unpacked_at, fmt.tprintf("unpack agree: %s: at %08x and %08x", c.what, u.addr, mem.unpacked_at))
			check(string(u.data) == string(mem.unpacked_code), fmt.tprintf("unpack agree: %s: the code differs", c.what))
		}
		delete(f)
		delete(t)
	}
}
