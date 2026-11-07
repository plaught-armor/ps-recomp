// Emotion Engine CPU state and the call dispatcher shared by recompiled code.
//
// Recompiled functions are Odin procs that read and write `state` directly.
// MIPS calls become host calls; `call` finds the proc for an address
// through a table indexed by word offset into .text.
package ps2_cpu

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

// What the interpreter charges an instruction; matches the recompiler's
// cycles_per_insn option.
CYCLES_PER_INSN :: 1

EE_CLOCK :: 294_912_000
CYCLES_PER_FRAME :: EE_CLOCK * 1001 / 60000 // NTSC 59.94 Hz

// Set while the kernel runs interrupt handlers; a raised interrupt then
// waits for them to return instead of ending the current block.
in_interrupt: bool

// What ran since the spin skip (ps2/spin.odin) armed its probe that a loop
// at a fixed point must not do: SPIN_SIDE for an effect the snapshot of EE
// state and RAM cannot show (a register read, a syscall, the interpreter, a
// read of COP0 Count), SPIN_EVENT for run_events and all its handlers did,
// SPIN_ROTATE for a RotateThreadReadyQueue, whose effects on the threads the
// probe compares itself (kernel/spin.odin). Nonzero but for SPIN_ROTATE, the
// probe does not skip.
spin_dirty: u32
SPIN_SIDE :: 1
SPIN_EVENT :: 2
SPIN_ROTATE :: 4
// The bytes of a Cpu the spin probe compares: all but cycles (and the
// padding before it).
STATE_BYTES :: int(offset_of(Cpu, cop0)) + size_of(Cpu{}.cop0)
// The cycles the spin skip added, for STATS.
spin_cycles: u64

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
	fn_table = make([]Func_Proc, (hi - lo) / 4, core.long_allocator())
}

register :: proc(addr: u32, fn: Func_Proc) {
	t := fn_held != nil ? fn_held : fn_table
	t[(addr - text_lo) >> 2] = fn
}

// The table while dispatch_set has it off, nil while it is on.
@(private)
fn_held: []Func_Proc

// Turn the whole table on or off: off, lookup finds no function, so every
// call is interpreted. The kernel turns it off when a program switch
// (ExecPS2) leaves other code over the recompiled range: a native function
// calls the others it knew directly, so only the whole table can go.
dispatch_set :: proc(on: bool) {
	if on && fn_held != nil {
		fn_table, fn_held = fn_held, nil
	} else if !on && fn_held == nil {
		fn_table, fn_held = nil, fn_table
	}
}

// Unchecked: the slot is tested against len(fn_table) first.
lookup :: proc(addr: u32) -> Func_Proc #no_bounds_check {
	i := (addr - text_lo) >> 2
	if addr < text_lo || addr & 3 != 0 || i >= u32(len(fn_table)) {
		return nil
	}
	return fn_table[i]
}

// Runs the guest code at an address no function is registered at, as a
// call that returns at its `jr $ra`: ps2 sets the EE interpreter here. Nil
// makes such a call fatal.
interp_hook: proc(addr: u32)

call :: proc(addr: u32) {
	spin_dirty |= SPIN_SIDE
	// FLAT runs no recompiled code: every call goes to the interpreter.
	when !core.FLAT {
		if fn := lookup(addr); fn != nil {
			fn()
			return
		}
	}
	if interp_hook != nil {
		interp_hook(addr)
		return
	}
	fatal("call to unknown function %08x (ra %08x)", addr, u32(state.r[31].d[0]))
}

// A jump inside a function to an address that is no label of it. Discovery
// splits a function after a mid-body `jr $ra`, so switch cases past it land
// in what was recompiled as another function: continue there as a tail call
// (the guest stack frame is shared, and its `jr $ra` returns for us).
jump_unknown :: proc(fn, pc: u32) {
	spin_dirty |= SPIN_SIDE
	// Only x64 and arm64 code calls it, which FLAT never runs; a FLAT
	// build's table holds wasm32 code, which is no Func_Proc.
	when !core.FLAT {
		if f := lookup(pc); f != nil {
			f()
			return
		}
	}
	if interp_hook != nil {
		interp_hook(pc)
		return
	}
	fatal("function %08x: jump to %08x which is not a label", fn, pc)
}

// ---------------------------------------------------------------- mods

// EE mod hooks (ps2/mod.odin) keep here what the kernel and recompiled
// code see. Host state, not in snapshots.
//
// mod_on: mods are loaded. mod_depth: before and after hooks now running,
// nested; while it is above 0, run_events handles nothing and sets
// mod_held instead, and a thread switch or a program switch is fatal.
mod_on: bool
mod_depth: int
mod_held: bool

// The hooked set (recomp option mod_hooks) the registered recompiled code
// was built for: its register procedure sets it, 0 for none. Loaded mods
// must hook exactly that set (ps2 mods_check).
mod_hooks_hash: u64

// The replacements running in the recursive model, innermost first, on the
// host stack: what mod_call_original calls. depth is mod_depth when it was
// called. site -1 is a marker: code inside it is not inside the
// replacement below (an original, an interrupt handler). Each thread has
// its own (mod_inners by thread id, swapped by the kernel's thread switch);
// an exec starts with none. Unused under FLAT, whose runs keep the chain as
// data (ps2/mod.odin).
Mod_Inner :: struct {
	site, depth: int,
	prev:        ^Mod_Inner,
}
mod_inner: ^Mod_Inner
mod_inners: [256]^Mod_Inner

// ---------------------------------------------------------------- unwind

// The calls the EE interpreter's runs are inside (ps2 interp_body),
// innermost first, on the host stack: the address each returns to and the
// guest sp at the call, so a `jr $ra` to an outer call's return address
// with that call's sp (a longjmp) returns there instead of to its own
// caller. target is the address called; direct: the run that made the call
// was itself called by the record below, with no host code between. Each
// thread has its own (interp_tops by thread id, swapped by the kernel's
// thread switch); an exec starts with none. Emulated: the records are on
// the coroutines' stacks, which snapshots hold. Unused under FLAT, whose
// runs keep the chain as data (kernel.Flat_Ctx).
Interp_Frame :: struct {
	ret, sp, target: u32,
	direct:          bool,
	prev:            ^Interp_Frame,
}
interp_top: ^Interp_Frame
interp_tops: [256]^Interp_Frame

// The most calls an unwind looks through, both interpreters: past it a
// `jr $ra` returns as before.
UNWIND_MAX :: 64

bad_insn :: proc(pc, w: u32) {
	fatal("invalid instruction %08x at %08x", w, pc)
}

brk :: proc(pc, w: u32) {
	fatal("break %d at %08x", (w >> 6) & 0xfffff, pc)
}

// For tests only: with trap_hook set, a trap calls it in place of fatal and
// the guest carries on past the trap.
trap_hook: proc(pc: u32)

trap :: proc(pc: u32) {
	if trap_hook != nil {
		spin_dirty |= SPIN_SIDE
		trap_hook(pc)
		return
	}
	fatal("trap at %08x", pc)
}

// Stop the game on an error it cannot get past: say so with the registers,
// then print the compat line (COMPAT).
fatal :: proc(format: string, args: ..any) -> ! {
	core.fatal_cleanup_run()
	msg := fmt.tprintf(format, ..args)
	fmt.eprintln("ee:", msg)
	dump_regs()
	unmapped_print()
	learned_print()
	flat_print()
	core.learn_report()
	core.compat_report(msg)
	os.exit(1)
}

// The distinct addresses logged per kind of unmapped access (read, write);
// past them a game sweeping unmapped memory is counted, not logged.
UNMAPPED_LOG :: 64

// Unmapped accesses: the addresses logged (a snap region, ps2 snap.odin),
// and per kind how many were logged and how many there were. The counts
// are diagnostics, not in snapshots.
unmapped_seen: map[u32]bool
@(private = "file")
unmapped_logged: [2]int
@(private = "file")
unmapped_count: [2]u64

// An access to an unmapped address (from the bus), said once per address
// up to UNMAPPED_LOG per kind.
unmapped :: proc(a: u32, write: bool) {
	k := int(write)
	what := write ? "write" : "read"
	unmapped_count[k] += 1
	if unmapped_logged[k] == UNMAPPED_LOG || a in unmapped_seen {return}
	unmapped_seen[a] = true
	unmapped_logged[k] += 1
	fmt.eprintfln("ee: unmapped %s at %08x", what, a)
	if unmapped_logged[k] == UNMAPPED_LOG {
		fmt.eprintfln("ee: unmapped %ss: %d addresses logged, more only counted", what, UNMAPPED_LOG)
	}
}

// Where a run ends: the counts, when any access went unlogged.
unmapped_print :: proc() {
	logged := unmapped_logged[0] + unmapped_logged[1]
	if unmapped_count[0] + unmapped_count[1] == u64(logged) {return}
	fmt.eprintfln("ee: unmapped accesses: %d reads, %d writes, %d logged", unmapped_count[0], unmapped_count[1], logged)
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
	when !core.FLAT {
		core.snap_add(&interp_top)
		core.snap_add(&interp_tops)
	}
}
