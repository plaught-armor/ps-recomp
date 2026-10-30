// EE whole-function interpreter test: cpu.call to an address with no
// registered function runs the guest code there (ps2 interp_call) until its
// `jr $ra`: a counted loop, a call to a registered function, likely branches
// taken and not, a jalr to another unregistered function, and a jump to a
// registered function as a tail call.
package main

import "core:fmt"
import "core:os"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import mem "ps:ps2/mem"

BASE :: 0x00100000
FN_A :: BASE // the program under test
FN_B :: BASE + 0x100 // registered: a0 += 100
FN_C :: BASE + 0x200 // unregistered: a0 += 20000, then a tail jump to B

ZERO :: 0
V0 :: 2
A0 :: 4
T0 :: 8
T9 :: 25
RA :: 31

b_calls: int

fn_b :: proc() {
	b_calls += 1
	cpu.state.r[A0].d[0] += 100
}

i_type :: proc(op, rs, rt: u32, imm: i32) -> u32 {return op << 26 | rs << 21 | rt << 16 | (u32(imm) & 0xffff)}
r_type :: proc(rs, rt, rd, fn: u32) -> u32 {return rs << 21 | rt << 16 | rd << 11 | fn}
j_type :: proc(op, target: u32) -> u32 {return op << 26 | (target >> 2) & 0x3ffffff}
addiu :: proc(rt, rs: u32, imm: i32) -> u32 {return i_type(9, rs, rt, imm)}

NOP :: 0

put :: proc(at: ^u32, w: u32) {
	mem.wr32(at^, w)
	at^ += 4
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

main :: proc() {
	mem.mem_init()
	cpu.next_event = max(u64)
	cpu.text_range(BASE, BASE + 0x400)
	cpu.register(FN_B, fn_b)
	cpu.interp_hook = ps2.interp_call

	pc := u32(FN_A)
	put(&pc, addiu(A0, ZERO, 0))
	loop := pc
	put(&pc, addiu(A0, A0, 1))
	put(&pc, i_type(10, A0, T0, 10)) // slti t0, a0, 10
	put(&pc, i_type(5, T0, ZERO, i32(loop - (pc + 4)) / 4)) // bne t0, zero, loop
	put(&pc, NOP)
	put(&pc, j_type(3, FN_B)) // jal B
	put(&pc, NOP)
	put(&pc, i_type(20, ZERO, ZERO, 2)) // beql zero, zero, past the next: taken
	put(&pc, addiu(A0, A0, 1000)) // its delay slot runs
	put(&pc, addiu(A0, A0, 5)) // skipped
	put(&pc, i_type(21, ZERO, ZERO, 2)) // bnel zero, zero: not taken
	put(&pc, addiu(A0, A0, 7)) // its delay slot does not run
	put(&pc, i_type(15, ZERO, T9, i32(FN_C >> 16))) // lui t9, C
	put(&pc, i_type(13, T9, T9, i32(FN_C & 0xffff))) // ori t9, t9, C
	put(&pc, r_type(T9, 0, RA, 9)) // jalr t9
	put(&pc, NOP)
	put(&pc, r_type(RA, 0, 0, 8)) // jr ra
	put(&pc, addiu(V0, A0, 0)) // its delay slot runs

	pc = FN_C
	put(&pc, addiu(A0, A0, 20000))
	put(&pc, j_type(2, FN_B)) // j B: a tail call
	put(&pc, NOP)
	put(&pc, NOP) // a fall through to here would hang on garbage

	cpu.state.r[RA].d[0] = 0xdead0000
	cpu.call(FN_A)
	want := u64(10 + 100 + 1000 + 20000 + 100)
	if got := cpu.state.r[V0].d[0]; got != want {fail("fail: v0 %d, want %d", got, want)}
	if b_calls != 2 {fail("fail: B called %d times, want 2", b_calls)}
	if ra := cpu.state.r[RA].d[0]; ra != u64(FN_A + 4 * 16) {fail("fail: ra %08x after jalr", ra)}
	when cpu.FALLBACK_COUNT {
		a, c := cpu.fallback_ee_calls[FN_A], cpu.fallback_ee_calls[FN_C]
		if a != 1 || c != 1 || len(cpu.fallback_ee_calls) != 2 {fail("fail: interpreted calls A %d, C %d, of %d addresses", a, c, len(cpu.fallback_ee_calls))}
	}
	fmt.println("ps2_interp: ok")
}
