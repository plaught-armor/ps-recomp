// Emotion Engine CPU state and the call dispatcher shared by recompiled code.
//
// Recompiled functions are Odin procs that read and write `state` directly.
// MIPS calls become host calls; `call` finds the proc for an address
// through a table indexed by word offset into .text.
package ps2_cpu

import "base:runtime"
import "core:fmt"
import "core:os"
import "ps:core"

// A general-purpose register: 128 bits on the R5900. Non-MMI instructions
// only touch the low doubleword.
Gpr :: struct #raw_union {
	q:  u128,
	d:  [2]u64,
	sd: [2]i64,
	w:  [4]u32,
	sw: [4]i32,
	h:  [8]u16,
	sh: [8]i16,
	b:  [16]u8,
	sb: [16]i8,
	// SIMD views for MMI instructions the recompiler emits inline
	vw: #simd[4]u32,
	vsw: #simd[4]i32,
	vh: #simd[8]i16,
	vuh: #simd[8]u16,
	vb: #simd[16]u8,
	vsb: #simd[16]i8,
}

Fpr :: struct #raw_union {
	f: f32,
	u: u32,
	i: i32,
}

Cpu :: struct {
	r:      [32]Gpr,
	hi, lo: Gpr, // d[1] are HI1/LO1 of the second multiply pipe
	sa:     u32, // shift amount for QFSRV, in bits
	f:      [32]Fpr,
	acc:    Fpr,
	fcr31:  u32,
	cop0:   [32]u32,
	cycles: u64,
}

state: Cpu
next_event: u64

EE_CLOCK :: 294_912_000
CYCLES_PER_FRAME :: EE_CLOCK * 1001 / 60000 // NTSC 59.94 Hz

// Set while the kernel runs interrupt handlers; a raised interrupt then
// waits for them to return instead of ending the current block.
in_interrupt: bool

// DEBUG=1: dump threads every two seconds; 2: also trace syscalls; 3: trace
// GS register writes. Set by the kernel at init.
debug: int

FCR31_C :: 0x800000

sx32 :: #force_inline proc "contextless" (v: u32) -> u64 {
	return u64(i64(i32(v)))
}

// ---------------------------------------------------------------- dispatch

Func_Proc :: #type proc()

// The program's code range, from the recompiler's text_range call.
text_lo, text_hi: u32

@(private)
fn_table: []Func_Proc

@(private)
reported: map[u32]bool

// Host state, outside the emulated heap: snapshots never need it.
text_range :: proc(lo, hi: u32) {
	text_lo, text_hi = lo, hi
	fn_table = make([]Func_Proc, (hi - lo) / 4, runtime.heap_allocator())
}

register :: proc(addr: u32, fn: Func_Proc) {
	fn_table[(addr - text_lo) >> 2] = fn
}

// Unchecked: the slot is tested against len(fn_table) first.
lookup :: proc(addr: u32) -> Func_Proc #no_bounds_check {
	i := (addr - text_lo) >> 2
	if addr < text_lo || addr & 3 != 0 || i >= u32(len(fn_table)) {
		return nil
	}
	return fn_table[i]
}

call :: proc(addr: u32) {
	if fn := lookup(addr); fn != nil {
		fn()
		return
	}
	fatal("call to unknown function %08x (ra %08x)", addr, u32(state.r[31].d[0]))
}

// A jump inside a function to an address that is no label of it. Discovery
// splits a function after a mid-body `jr $ra`, so switch cases past it land
// in what was recompiled as another function: continue there as a tail call
// (the guest stack frame is shared, and its `jr $ra` returns for us).
jump_unknown :: proc(fn, pc: u32) {
	if f := lookup(pc); f != nil {
		f()
		return
	}
	fatal("function %08x: jump to %08x which is not a label", fn, pc)
}

bad_insn :: proc(pc, w: u32) {
	fatal("invalid instruction %08x at %08x", w, pc)
}

brk :: proc(pc, w: u32) {
	fatal("break %d at %08x", (w >> 6) & 0xfffff, pc)
}

fatal :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("ee: ")
	fmt.eprintfln(format, ..args)
	dump_regs()
	os.exit(1)
}

GPR_NAMES := [32]string {
	"zero", "at", "v0", "v1", "a0", "a1", "a2", "a3", "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7",
	"s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "t8", "t9", "k0", "k1", "gp", "sp", "fp", "ra",
}

dump_regs :: proc() {
	for n in 0 ..< 32 {
		fmt.eprintf("%4s %016x%s", GPR_NAMES[n], state.r[n].d[0], n % 4 == 3 ? "\n" : "  ")
	}
	fmt.eprintfln("  hi %016x    lo %016x  cycles %d", state.hi.d[0], state.lo.d[0], state.cycles)
}

// Emulated state, saved and restored by snapshots (snap.odin).
cpu_snap :: proc() {
	core.snap_add(&state)
	core.snap_add(&next_event)
	core.snap_add(&in_interrupt)
	core.snap_add(&reported)
}
