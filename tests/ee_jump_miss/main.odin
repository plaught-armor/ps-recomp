// A disc-blob function's computed jump to a target in itself that is no
// label (a jump-table case discover did not find) must run on to the
// function's own return, once. ENTRY, interpreted, calls G; G (blob) calls
// F and then tail-jumps to T; F (blob) calls H, then jumps through a word
// in DATA to CASE_B, which is in F but no label. CASE_B marks DATA, and F's
// jr $ra returns to G. Right: G's continuation and T run once each and
// ENTRY's sp is back where it was. A miss that interprets on past F's
// return while F's and G's host frames are open runs G's continuation
// twice and pops G's frame twice.
//
// x64 and arm64 run it as is; for wasm32, a FLAT build, run.mjs.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import "ps:ps2/mem"
import "ps:recomp/mips"
import "ps:recomp/native"
import r5900 "ps:recomp/r5900"

ENTRY :: u32(0x00100000) // interpreted: outside the blob
G :: u32(0x00200000)
F :: u32(0x00200100)
T :: u32(0x00200200)
H :: u32(0x00200300)
DATA :: u32(0x00180000)
TGT :: DATA + 0x00 // F's jump target
CNT :: DATA + 0x10 // G's continuation runs
CNT2 :: DATA + 0x14 // T runs
MARK :: DATA + 0x18 // CASE_B ran
SP_OUT :: DATA + 0x1c // ENTRY's sp after G
DONE :: DATA + 0x20
STACK :: DATA + 0x2000
BLOB :: "jump_miss.bin"

ZERO, V0, T1, T2, T7, SP, RA :: u32(0), u32(2), u32(9), u32(10), u32(15), u32(29), u32(31)
NOP :: u32(0)
JR_RA :: u32(0x03e00008)

lui :: proc(rt, imm: u32) -> u32 {return 0x0f << 26 | rt << 16 | imm & 0xffff}
lw :: proc(rt, off, base: u32) -> u32 {return 0x23 << 26 | base << 21 | rt << 16 | off & 0xffff}
sw :: proc(rt, off, base: u32) -> u32 {return 0x2b << 26 | base << 21 | rt << 16 | off & 0xffff}
addiu :: proc(rt, rs, imm: u32) -> u32 {return 0x09 << 26 | rs << 21 | rt << 16 | imm & 0xffff}
jal :: proc(t: u32) -> u32 {return 0x03 << 26 | t >> 2 & 0x03ffffff}
j :: proc(t: u32) -> u32 {return 0x02 << 26 | t >> 2 & 0x03ffffff}
jr :: proc(rs: u32) -> u32 {return rs << 21 | 0x08}
beq :: proc(pc, rs, rt, t: u32) -> u32 {return 0x04 << 26 | rs << 21 | rt << 16 | (t - pc - 4) >> 2 & 0xffff}

// The blob's functions; F's two cases follow its jump.
g_words :: proc() -> [11]u32 {
	return {
		addiu(SP, SP, 0xfff0), sw(RA, 0, SP), jal(F), NOP,
		lui(T7, DATA >> 16), lw(T1, CNT - DATA, T7), addiu(T1, T1, 1), sw(T1, CNT - DATA, T7),
		lw(RA, 0, SP), j(T), addiu(SP, SP, 16),
	}
}
CASE_A :: F + 9 * 4 // a label, so discover's computed-jr sweep does not run
CASE_B :: F + 12 * 4 // the target: no label
F_OUT :: F + 14 * 4
f_words :: proc() -> [17]u32 {
	return {
		addiu(SP, SP, 0xfff0), sw(RA, 0, SP), jal(H), NOP,
		lui(T7, DATA >> 16), lw(T1, TGT - DATA, T7), NOP, jr(T1), NOP,
		addiu(V0, ZERO, 1), beq(CASE_A + 4, ZERO, ZERO, F_OUT), NOP,
		addiu(T2, ZERO, 2), sw(T2, MARK - DATA, T7),
		lw(RA, 0, SP), JR_RA, addiu(SP, SP, 16),
	}
}
t_words :: proc() -> [5]u32 {
	return {lui(T7, DATA >> 16), lw(T1, CNT2 - DATA, T7), addiu(T1, T1, 1), JR_RA, sw(T1, CNT2 - DATA, T7)}
}
H_W :: [2]u32{JR_RA, NOP}

put :: proc(at: u32, words: []u32) {
	for w, i in words {mem.wr32(at + 4 * u32(i), w)}
}

// The four functions as a disc blob, F with CASE_A as its only extra label.
Prog :: struct {
	at:    u32,
	words: []u32,
	extra: []u32,
}

build_blob :: proc(progs: []Prog) -> bool {
	assert(len(progs) == 4)
	a := r5900.native_asm(native.Arch(core.NATIVE_ARCH))
	labels := make(map[u32]native.Label)
	defer delete(labels)
	for p in progs {labels[p.at] = native.new_label(&a)}
	funcs: [4]native.Blob_Func
	slow: map[string]int
	defer delete(slow)
	for p, k in progs {
		data := make([]u8, 4 * len(p.words))
		defer delete(data)
		for w, n in p.words {
			data[4 * n], data[4 * n + 1], data[4 * n + 2], data[4 * n + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
		}
		f := mips.func_make(p.at, p.at + u32(len(data)))
		mips.discover(r5900.RULES, {base = p.at, data = data}, f, p.extra)
		if p.at == F && (CASE_B in f.labels || CASE_A not_in f.labels) {
			fmt.eprintln("fail: F's labels are not CASE_A without CASE_B")
			return false
		}
		funcs[k] = {p.at, r5900.native_func(&a, f, {}, 1, &slow, labels)[0].off}
		free_all(context.temp_allocator)
	}
	_, ok := native.write_blob(BLOB, &a, funcs[:], nil)
	return ok && ps2.load_native(BLOB)
}

check :: proc() {
	if mem.rd32(DONE) != 1 {return}
	got := [4]u32{mem.rd32(CNT), mem.rd32(CNT2), mem.rd32(MARK), mem.rd32(SP_OUT)}
	want := [4]u32{1, 1, 2, STACK}
	fmt.printfln("cnt cnt2 mark sp %x, want %x; %d jumps", got, want, cpu.interp_jumps)
	if got != want {
		fmt.eprintln("FAIL: F's miss ran on past its return")
		os.exit(1)
	}
	fmt.println("ok")
	os.exit(0)
}

vblank :: proc() {
	check()
	if kernel.k.frame >= 4 {
		fmt.eprintln("fail: ENTRY did not finish")
		os.exit(1)
	}
}

main :: proc() {
	ps2.init()
	// ENTRY: sp = STACK, call G, store sp and DONE, hang.
	put(ENTRY, {
		lui(SP, STACK >> 16), addiu(SP, SP, STACK & 0xffff), jal(G), NOP,
		lui(T7, DATA >> 16), sw(SP, SP_OUT - DATA, T7), addiu(T1, ZERO, 1), sw(T1, DONE - DATA, T7),
		beq(ENTRY + 32, ZERO, ZERO, ENTRY + 32), NOP,
	})
	gw, fw, tw, hw := g_words(), f_words(), t_words(), H_W
	case_a := [?]u32{CASE_A}
	progs := [?]Prog{{G, gw[:], nil}, {F, fw[:], case_a[:]}, {T, tw[:], nil}, {H, hw[:], nil}}
	for p in progs {put(p.at, p.words)}
	mem.wr32(TGT, CASE_B)
	if !build_blob(progs[:]) {
		fmt.eprintln("fail: blob")
		os.exit(1)
	}
	kernel.vblank_hook = vblank
	ps2.run(ENTRY)
}
