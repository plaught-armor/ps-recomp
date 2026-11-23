// A native function that calls a routine in its own code, then loops
// through it by a branch into its body (psx/cpu return_link, recomp/r3000
// local_links): the routine's `jr $ra` then goes on in the function at the
// link of the first call, not to the function's caller. Driver 2's MDEC VLC
// decoder (0x80117980, learned as one run with its routine at 0x80117ac0)
// returned at its second `jr $ra` there, with its frame still pushed.
//
// D counts down t0 from 3: it calls R once, then branches back into R's
// body at LINK, the link of that call, until t0 is 0. R adds 1 to CNT. Right:
// CNT 3, sp back where it was, and $ra the caller's. R is also a function of its own, compiled apart, as jal targets are.
// The R3000 code waits out each load's delay slot.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import cpu "ps:psx/cpu"
import psx_native "ps:psx/native"
import "ps:recomp/mips"
import "ps:recomp/native"
import "ps:recomp/r3000"

D :: u32(0x80020000)
LINK :: D + 0x18 // the return address of D's jal R
OUT :: D + 0x28
R :: D + 0x38
R_BODY :: D + 0x3c // where D's loop branches into R
D_END :: D + 0x58
DATA :: u32(0x80010000)
CNT :: DATA + 0x10
STACK :: DATA + 0x2000
RET :: u32(0x80000080) // the caller's return address: frame_ret of the call of D

ZERO, T0, T1, T7, SP, RA :: u32(0), u32(8), u32(9), u32(15), u32(29), u32(31)
NOP :: u32(0)
JR_RA :: u32(0x03e00008)

lui :: proc(rt, imm: u32) -> u32 {return 0x0f << 26 | rt << 16 | imm & 0xffff}
lw :: proc(rt, off, base: u32) -> u32 {return 0x23 << 26 | base << 21 | rt << 16 | off & 0xffff}
sw :: proc(rt, off, base: u32) -> u32 {return 0x2b << 26 | base << 21 | rt << 16 | off & 0xffff}
addiu :: proc(rt, rs, imm: u32) -> u32 {return 0x09 << 26 | rs << 21 | rt << 16 | imm & 0xffff}
jal :: proc(t: u32) -> u32 {return 0x03 << 26 | t >> 2 & 0x03ffffff}
beq :: proc(pc, rs, rt, t: u32) -> u32 {return 0x04 << 26 | rs << 21 | rt << 16 | (t - pc - 4) >> 2 & 0xffff}

d_words :: proc() -> [22]u32 {
	return {
		addiu(SP, SP, 0xfff0), sw(RA, 0, SP), addiu(T0, ZERO, 3), lui(T7, DATA >> 16),
		jal(R), NOP,
		// LINK
		beq(LINK, T0, ZERO, OUT), NOP,
		beq(LINK + 8, ZERO, ZERO, R_BODY), NOP,
		// OUT
		lw(RA, 0, SP), NOP, JR_RA, addiu(SP, SP, 16),
		// R
		lui(T7, DATA >> 16),
		// R_BODY
		lw(T1, CNT - DATA, T7), NOP, addiu(T1, T1, 1), sw(T1, CNT - DATA, T7),
		addiu(T0, T0, 0xffff), JR_RA, NOP,
	}
}

put :: proc(at: u32, words: []u32) {
	for w, k in words {(^u32le)(&cpu.ram[(at & 0x1fffff) + u32(k) * 4])^ = u32le(w)}
}

rd :: proc(at: u32) -> u32 {return u32((^u32le)(&cpu.ram[at & 0x1fffff])^)}

fail :: proc(what: string) -> ! {
	fmt.eprintln("FAIL psx_local_link:", what)
	os.exit(1)
}

// One function from the words at at, entered at entry, to end.
compile :: proc(na: ^native.Asm, entry, at, end: u32, words: []u32) -> native.Blob_Func {
	f := mips.func_make(entry, end, at)
	defer mips.func_free(f)
	mips.discover(r3000.RULES, {base = at, data = ([^]u8)(raw_data(words))[:4 * len(words)], entry = entry}, f, nil)
	if entry == D && (R_BODY not_in f.labels || LINK in f.labels) {
		fail("D's labels are not R_BODY without LINK before lowering")
	}
	defer free_all(context.temp_allocator)
	return {entry, r3000.native_func(na, f, nil, 1)}
}

main :: proc() {
	cpu.register_funcs(nil)
	cpu.interp_run = cpu.interp_loop
	cpu.next_event = max(u64)
	dw := d_words()
	assert(D + 4 * u32(len(dw)) == D_END)
	put(D, dw[:])
	na := native.make_asm(native.Arch(core.NATIVE_ARCH), r3000.native_ram(), r3000.NATIVE_CACHED[:])
	funcs := [2]native.Blob_Func{compile(&na, D, D, D_END, dw[:]), compile(&na, R, R, D_END, dw[(R - D) / 4:])}
	code, err := core.native_load(native.make_blob(&na, funcs[:], {}), psx_native.imports())
	if err != "" {fail(fmt.tprint("native_load:", err))}
	for e, k in funcs {
		cpu.register_funcs({{e.addr,cast(cpu.Func_Proc)rawptr(code.base + uintptr(code.funcs[k].off))}})
	}
	cpu.state.r[29], cpu.state.r[31] = STACK, RET
	cpu.call(D)
	got := [3]u32{rd(CNT), cpu.state.r[29], cpu.state.r[31]}
	want := [3]u32{3, STACK, RET}
	fmt.printfln("cnt sp ra %x, want %x", got, want)
	if got != want {fail("D returned at its routine's jr $ra to the link it set")}
	fmt.println("ok")
}
