// tests/ee_jump_miss for the PS1 (psx/cpu jump_unknown): a native
// function's computed jump to a target in itself that is no label must run
// on to the function's own return, once. G calls F and then tail-jumps to
// T; F calls H, then jumps through a word in DATA to CASE_B, in F but no
// label. Right: G's continuation and T run once each, and sp is back where
// it was. The R3000 code waits out each load's delay slot.
//
// And a loop through a routine whose link is no label (Tarzan's MDEC
// decoder, 8002fbc4): P calls R, and after the call branches back to R with
// the call's link still in $ra. R's return misses P's labels and is
// interpreted from the link, and the interpreted branch to R must come back
// there as often as the loop asks, not end P ahead of its epilogue.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import cpu "ps:psx/cpu"
import psx_native "ps:psx/native"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"

G :: u32(0x80020000)
F :: u32(0x80020100)
T :: u32(0x80020200)
H :: u32(0x80020300)
P :: u32(0x80020400)
R :: u32(0x80020500)
P_LINK :: P + 4 * 4 // no label
P_OUT :: P + 14 * 4
ROUNDS :: 4
DATA :: u32(0x80010000)
TGT :: DATA + 0x00
CNT :: DATA + 0x10
CNT2 :: DATA + 0x14
MARK :: DATA + 0x18
STACK :: DATA + 0x2000
RET :: u32(0x80000080) // the caller's return address: frame_ret of the call of G

ZERO, T1, T2, T7, SP, RA :: u32(0), u32(9), u32(10), u32(15), u32(29), u32(31)
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

g_words :: proc() -> [13]u32 {
	return {
		addiu(SP, SP, 0xfff0), sw(RA, 0, SP), jal(F), NOP,
		lui(T7, DATA >> 16), lw(T1, CNT - DATA, T7), NOP, addiu(T1, T1, 1), sw(T1, CNT - DATA, T7),
		lw(RA, 0, SP), NOP, j(T), addiu(SP, SP, 16),
	}
}
CASE_A :: F + 9 * 4 // a label, so discover's computed-jr sweep does not run
CASE_B :: F + 12 * 4 // the target: no label
F_OUT :: F + 14 * 4
f_words :: proc() -> [18]u32 {
	return {
		addiu(SP, SP, 0xfff0), sw(RA, 0, SP), jal(H), NOP,
		lui(T7, DATA >> 16), lw(T1, TGT - DATA, T7), NOP, jr(T1), NOP,
		addiu(2, ZERO, 1), beq(CASE_A + 4, ZERO, ZERO, F_OUT), NOP,
		addiu(T2, ZERO, 2), sw(T2, MARK - DATA, T7),
		lw(RA, 0, SP), NOP, JR_RA, addiu(SP, SP, 16),
	}
}
t_words :: proc() -> [6]u32 {
	return {lui(T7, DATA >> 16), lw(T1, CNT2 - DATA, T7), NOP, addiu(T1, T1, 1), JR_RA, sw(T1, CNT2 - DATA, T7)}
}
H_W :: [2]u32{JR_RA, NOP}
p_words :: proc() -> [18]u32 {
	return {
		addiu(SP, SP, 0xfff0), sw(RA, 0, SP), jal(R), NOP,
		lui(T7, DATA >> 16), lw(T1, CNT - DATA, T7), NOP, addiu(T1, T1, 1),
		sw(T1, CNT - DATA, T7), addiu(T2, ZERO, ROUNDS), beq(P + 10 * 4, T1, T2, P_OUT), NOP,
		beq(P + 12 * 4, ZERO, ZERO, R), NOP,
		lw(RA, 0, SP), NOP, JR_RA, addiu(SP, SP, 16),
	}
}

Prog :: struct {
	at:    u32,
	words: []u32,
	extra: []u32,
}

put :: proc(at: u32, words: []u32) {
	for w, k in words {(^u32le)(&cpu.ram[(at & 0x1fffff) + u32(k) * 4])^ = u32le(w)}
}

rd :: proc(at: u32) -> u32 {return u32((^u32le)(&cpu.ram[at & 0x1fffff])^)}

fail :: proc(what: string) -> ! {
	fmt.eprintln("FAIL psx_jump_miss:", what)
	os.exit(1)
}

main :: proc() {
	cpu.register_funcs(nil)
	cpu.interp_run = cpu.interp_loop
	cpu.next_event = max(u64)
	gw, fw, tw, hw := g_words(), f_words(), t_words(), H_W
	pw, rw := p_words(), t_words()
	case_a := [?]u32{CASE_A}
	progs := [?]Prog{{G, gw[:], nil}, {F, fw[:], case_a[:]}, {T, tw[:], nil}, {H, hw[:], nil}, {P, pw[:], nil}, {R, rw[:], nil}}
	na := native.make_asm(native.Arch(core.NATIVE_ARCH), r3000.native_ram(), r3000.NATIVE_CACHED[:])
	funcs: [len(progs)]native.Blob_Func
	for p, k in progs {
		put(p.at, p.words)
		f := mips.func_make(p.at, p.at + 4 * u32(len(p.words)))
		mips.discover(r3000.RULES, {base = p.at, data = ([^]u8)(raw_data(p.words))[:4 * len(p.words)]}, f, p.extra)
		if p.at == F && (CASE_B in f.labels || CASE_A not_in f.labels) {fail("F's labels are not CASE_A without CASE_B")}
		if p.at == P && P_LINK in f.labels {fail("P's link is a label")}
		funcs[k] = {p.at, r3000.native_func(&na, f, nil, 1)}
		free_all(context.temp_allocator)
	}
	code, err := core.native_load(native.make_blob(&na, funcs[:], {}), psx_native.imports())
	if err != "" {fail(fmt.tprint("native_load:", err))}
	for p, k in progs {
		cpu.register_funcs({{p.at, cast(cpu.Func_Proc)rawptr(code.base + uintptr(code.funcs[k].off))}})
	}
	(^u32le)(&cpu.ram[TGT & 0x1fffff])^ = u32le(CASE_B)
	cpu.state.r[29], cpu.state.r[31] = STACK, RET
	cpu.call(G)
	got := [4]u32{rd(CNT), rd(CNT2), rd(MARK), cpu.state.r[29]}
	want := [4]u32{1, 1, 2, STACK}
	fmt.printfln("cnt cnt2 mark sp %x, want %x", got, want)
	if got != want {fail("F's miss ran on past its return")}
	for at in ([?]u32{CNT, CNT2}) {(^u32le)(&cpu.ram[at & 0x1fffff])^ = 0}
	cpu.state.r[29], cpu.state.r[31] = STACK, RET
	cpu.call(P)
	loop := [3]u32{rd(CNT), rd(CNT2), cpu.state.r[29]}
	loop_want := [3]u32{ROUNDS, ROUNDS, STACK}
	fmt.printfln("loop cnt cnt2 sp %x, want %x", loop, loop_want)
	if loop != loop_want {fail("the loop through R ended P early")}
	fmt.println("ok")
}
