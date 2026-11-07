// The cycles an access sees (psx/cpu/interp.odin, recomp/r3000/lower.odin
// Step.seen): a load or a store off RAM, an mtc0 to SR and a syscall see the
// cycles of every instruction before them and their own, interpreted and
// learned alike, wherever they sit in their block: right after a label the
// block before falls into (a timer polled at a loop's head), in a branch's
// delay slot, as a load whose next instruction sees the old value, and as
// that instruction.
//
// A loop runs three times, through the I/O, irq_check and bios_syscall
// stubs, which log each access's address (or a tag) and cycles:
// interpreted, then as a learned function (native code from the same
// words). Both logs are the exact counts, and the cycles after the call
// match. The loop sets the syscall's a0 (7: none of the ones cpu.syscall
// does itself) in the syscall's block, which proves it no thread switch
// (recomp/r3000/switch.odin); otherwise a wasm32 blob leaves the run to the
// interpreter. Before the fix, learned code had charged the instructions before
// the label when the block fell into it, and the interpreter had not.
//
// Run it on the host, plain and FLAT, and built for wasi_wasm32 (run.mjs),
// whose learned function is wasm32 code (recomp/r3000 R3000_SIGS). The
// Odin-source emitter (recomp/r3000/emit.odin) is not run here:
// tests/psx_learned only checks the text of the learned rows it writes, and
// no test compiles them. The static code a port compiles from it runs in a
// port's own checks (the BoF4 port's tests/local/ref).
package main

import "core:fmt"
import "core:os"
import "ps:core"
import cpu "ps:psx/cpu"
import psx_native "ps:psx/native"
import "ps:recomp/native"
import "ps:recomp/r3000"

@(private = "file")
failed: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fmt.eprintfln("FAIL psx_access_cycles: %s (line %d)", what, loc.line)
		failed += 1
	}
}

@(private = "file")
LOOP :: 0x80010000

@(rodata, private = "file")
CODE := [?]u32 {
	0x3c0a1f80, // 00 lui t2, 0x1f80
	0x24090003, // 04 addiu t1, zero, 3
	0x00000000, // 08 nop
	0x954b1120, // 0c L: lhu t3, 0x1120(t2)   right after the label
	0xad491124, // 10 sw t1, 0x1124(t2)
	0x40806000, // 14 mtc0 zero, sr           irq_check
	0x24040007, // 18 addiu a0, zero, 7       proves the syscall no thread switch
	0x0000000c, // 1c syscall                 a0 = 7: bios_syscall
	0x2529ffff, // 20 addiu t1, t1, -1
	0x8d4d1120, // 24 lw t5, 0x1120(t2)
	0xad4d1128, // 28 sw t5, 0x1128(t2)       sees the old t5: a load delay
	0x1520fff7, // 2c bne t1, zero, L
	0x8d4c1128, // 30 lw t4, 0x1128(t2)       in the delay slot
	0x03e00008, // 34 jr ra
	0x00000000, // 38 nop
}

// The access log: the address and the cycles of each I/O access, or a tag
// for an SR write (irq_check) and a syscall (bios_syscall).
@(private = "file")
Access :: struct {
	addr:   u32,
	cycles: u64,
}

@(private = "file")
log: [dynamic]Access

@(private = "file")
io_read :: proc(p: u32, size: u32) -> u32 {
	append(&log, Access{p, cpu.state.cycles})
	return 0
}

@(private = "file")
io_write :: proc(p, v: u32, size: u32) {
	append(&log, Access{p, cpu.state.cycles})
}

@(private = "file")
SR_WRITE :: 0x5200000c

@(private = "file")
SYSCALL :: 0x5c000007

@(private = "file")
irq_check :: proc() {
	append(&log, Access{SR_WRITE, cpu.state.cycles})
}

@(private = "file")
bios_syscall :: proc() {
	append(&log, Access{SYSCALL, cpu.state.cycles})
}

// Call LOOP from cycles 0; its log, its cycles after, and whether a learned
// function ran it.
@(private = "file")
run :: proc() -> ([]Access, u64, bool) {
	clear(&log)
	cpu.state.r = {}
	cpu.state.cycles = 0
	cpu.state.r[29], cpu.state.r[31] = 0x801ff000, 0x80000ff0
	hits := cpu.learned_hits
	cpu.call(LOOP)
	out := make([]Access, len(log))
	copy(out, log[:])
	return out, cpu.state.cycles, cpu.learned_hits != hits
}

// The exact log: each access's instruction count from the call, times
// CYCLES_PER_INSN.
@(private = "file")
want_log :: proc() -> []Access {
	out: [dynamic]Access
	n := u64(3) // lui, addiu, nop
	for _ in 0 ..< 3 {
		append(&out, Access{0x1f801120, (n + 1) * cpu.CYCLES_PER_INSN}) // lhu
		append(&out, Access{0x1f801124, (n + 2) * cpu.CYCLES_PER_INSN}) // sw
		append(&out, Access{SR_WRITE, (n + 3) * cpu.CYCLES_PER_INSN}) // mtc0
		append(&out, Access{SYSCALL, (n + 5) * cpu.CYCLES_PER_INSN}) // syscall, after the addiu
		append(&out, Access{0x1f801120, (n + 7) * cpu.CYCLES_PER_INSN}) // lw
		append(&out, Access{0x1f801128, (n + 8) * cpu.CYCLES_PER_INSN}) // sw, the load's next
		append(&out, Access{0x1f801128, (n + 10) * cpu.CYCLES_PER_INSN}) // lw, the delay slot
		n += 10
	}
	return out[:]
}

@(private = "file")
same :: proc(a, b: []Access) -> bool {
	if len(a) != len(b) {return false}
	for x, k in a {
		if x != b[k] {return false}
	}
	return true
}

main :: proc() {
	cpu.next_event = max(u64)
	cpu.register_funcs(nil)
	cpu.interp_run = cpu.interp_loop
	cpu.io_read, cpu.io_write = io_read, io_write
	cpu.irq_check, cpu.bios_syscall = irq_check, bios_syscall
	code := CODE
	for w, k in code {
		(^u32le)(&cpu.ram[(LOOP & 0x1fffff) + u32(k) * 4])^ = u32le(w)
	}
	want := want_log()
	want_end := u64(3 + 3 * 10 + 2) * cpu.CYCLES_PER_INSN

	interp, interp_end, ran := run()
	check(!ran, "a learned function ran before any was loaded")
	check(same(interp, want), fmt.tprintf("interpreted log %v, want %v", interp, want))
	check(interp_end == want_end, fmt.tprintf("interpreted cycles %d, want %d", interp_end, want_end))

	// The blob from memory (load_learned_blob): wasi has no temp directory.
	blob := r3000.learned_blob({{LOOP, LOOP, code[:]}}, native.Arch(core.NATIVE_ARCH))
	check(psx_native.load_learned_blob(blob, "learned"), "load the blob")
	learned, learned_end, native_ran := run()
	check(native_ran, "the learned function did not run")
	check(same(learned, want), fmt.tprintf("learned log %v, want %v", learned, want))
	check(learned_end == want_end, fmt.tprintf("learned cycles %d, want %d", learned_end, want_end))
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok psx_access_cycles: an access sees the cycles up to it and its own, right after a fallthrough label, in a delay slot and a load delay's, an SR write and a syscall too, interpreted and learned alike")
}
