// The cycles an access sees (psx/cpu/interp.odin, recomp/r3000/lower.odin
// Step.seen): a load or a store off RAM sees the cycles of every instruction
// before it and its own, interpreted and learned alike, wherever it sits in
// its block: right after a label the block before falls into (a timer polled
// at a loop's head), in a branch's delay slot, as a load whose next
// instruction sees the old value, and as that instruction.
//
// A loop runs three times, through the I/O stubs, which log each access's
// address and cycles: interpreted, then as a learned function (native code
// from the same words). Both logs are the exact counts, and the cycles after
// the call match. Before the fix, learned code had charged the instructions
// before the label when the block fell into it, and the interpreter had not.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
	0x2529ffff, // 14 addiu t1, t1, -1
	0x8d4d1120, // 18 lw t5, 0x1120(t2)
	0xad4d1128, // 1c sw t5, 0x1128(t2)       sees the old t5: a load delay
	0x1520fffa, // 20 bne t1, zero, L
	0x8d4c1128, // 24 lw t4, 0x1128(t2)       in the delay slot
	0x03e00008, // 28 jr ra
	0x00000000, // 2c nop
}

// The access log: the address and the cycles of each I/O access.
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
		append(&out, Access{0x1f801120, (n + 4) * cpu.CYCLES_PER_INSN}) // lw
		append(&out, Access{0x1f801128, (n + 5) * cpu.CYCLES_PER_INSN}) // sw, the load's next
		append(&out, Access{0x1f801128, (n + 7) * cpu.CYCLES_PER_INSN}) // lw, the delay slot
		n += 7
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
	code := CODE
	for w, k in code {
		(^u32le)(&cpu.ram[(LOOP & 0x1fffff) + u32(k) * 4])^ = u32le(w)
	}
	want := want_log()
	want_end := u64(3 + 3 * 7 + 2) * cpu.CYCLES_PER_INSN

	interp, interp_end, ran := run()
	check(!ran, "a learned function ran before any was loaded")
	check(same(interp, want), fmt.tprintf("interpreted log %v, want %v", interp, want))
	check(interp_end == want_end, fmt.tprintf("interpreted cycles %d, want %d", interp_end, want_end))

	tmp, err := os.make_directory_temp("", "ps_access_cycles_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL psx_access_cycles: no temp directory:", err)
		os.exit(1)
	}
	path, _ := filepath.join({tmp, "learned.bin"}, context.allocator)
	blob := r3000.learned_blob({{LOOP, LOOP, code[:]}}, native.Arch(core.NATIVE_ARCH))
	check(os.write_entire_file(path, blob) == nil, "write the blob")
	check(psx_native.load_learned(path), "load the blob")
	learned, learned_end, native_ran := run()
	check(native_ran, "the learned function did not run")
	check(same(learned, want), fmt.tprintf("learned log %v, want %v", learned, want))
	check(learned_end == want_end, fmt.tprintf("learned cycles %d, want %d", learned_end, want_end))

	if os.remove_all(tmp) != nil {
		check(false, fmt.tprintf("cannot remove %s", tmp))
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok psx_access_cycles: an access sees the cycles up to it and its own, right after a fallthrough label, in a delay slot and a load delay's, interpreted and learned alike")
}
