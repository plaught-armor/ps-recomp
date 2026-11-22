// A jump to a call that never returns on the console, interpreted
// (psx/cpu/interp.odin) and under FLAT (psx/cpu/interp_flat.odin).
//
// An interrupt handler calls work, then jumps to B(17h) ReturnFromException.
// $ra still holds the link of that call, a pc of the handler's own run. The
// HLE BIOS only flags the end and returns, so the run must end there: going
// on at the link calls B(17h) again and again.
//   - A `jr` to the B0 vector, whatever the host code there does.
//   - The same with the real B(17h).
//   - A `j` to a function that makes the call, as recompiled code does.
//   - A `j` to a function that jumps to the vector, as a recompiled stub's
//     `jr` does (cpu.jump_unknown).
//   - A `j` to a function whose callee, interpreted, jumps to the vector.
// Runs on both builds: natively, and with -define:PS_FLAT=true.
package main

import "core:fmt"
import "core:os"
import "ps:core"
import _ "ps:psx" // the PS1 hooks: interp_run and bios_b among them
import cpu "ps:psx/cpu"
import io "ps:psx/io"

// jal WORK; nop; addiu t2, zero, 0xb0; jr t2; addiu t1, zero, 0x17.
@(private = "file")
DIRECT :: 0x80002000

// jal WORK; nop; j the case's function; nop.
@(private = "file")
BY_FUNC :: 0x80002100

// addiu t2, zero, 0xb0; jr t2; addiu t1, zero, 0x17.
@(private = "file")
GUEST_STUB :: 0x80002200

// Host code.
@(private = "file")
WORK :: 0x80003000
@(private = "file")
FUNC :: 0x80003100
@(private = "file")
JR_FUNC :: 0x80003200
@(private = "file")
NESTED_FUNC :: 0x80003300

@(private = "file")
BACK :: 0x80001000

// A handler that loops is stopped at this many B(17h)s: the loop is from the
// link, past the call of WORK, so only they repeat.
@(private = "file")
ENDS_MAX :: 4

@(private = "file")
works: u32
@(private = "file")
ends: u32
@(private = "file")
real_b: proc(fn: u32) // the HLE B table, nil for the case without it
@(private = "file")
failed: int
@(private = "file")
running: string

@(private = "file")
put :: proc(at: u32, words: []u32) {
	for w, k in words {
		cpu.w32(at + u32(k) * 4, w)
	}
}

@(private = "file")
work :: proc() {
	works += 1
}

@(private = "file")
count_b :: proc(fn: u32) {
	if fn == 0x17 {
		ends += 1
		if ends >= ENDS_MAX {
			fmt.eprintfln("FAIL psx_rfe: %s: B(17h) is called again and again", running)
			os.exit(1)
		}
	}
	if real_b != nil {real_b(fn)}
}

@(private = "file")
handler :: proc(what: string, entry: u32) {
	running, works, ends = what, 0, 0
	io.irq_regs.in_handler = true
	cpu.state.r[29], cpu.state.r[31] = 0x801ff000, BACK
	when core.FLAT {
		x: cpu.Flat_Ctx
		cpu.flat_start(&x, entry)
		if !cpu.flat_run(&x) {
			fmt.eprintfln("FAIL psx_rfe: %s: the flat run stopped", what)
			failed += 1
		}
		cpu.flat_free(&x)
	} else {
		cpu.call_callback(entry)
	}
	io.irq_regs.in_handler = false
	if works != 1 || ends != 1 {
		fmt.eprintfln("FAIL psx_rfe: %s: %d passes and %d B(17h)s, want 1 and 1", what, works, ends)
		failed += 1
	}
}

main :: proc() {
	cpu.register_funcs({
		{WORK, work},
		{FUNC, proc() {cpu.bios_b(0x17)}},
		{JR_FUNC, proc() {
				cpu.state.r[9] = 0x17
				cpu.jump_unknown(JR_FUNC, 0xb0)
			}},
		{NESTED_FUNC, proc() {cpu.call(GUEST_STUB)}},
	})
	cpu.next_event = max(u64)
	jal_work :: 0x0c000000 | (WORK >> 2) & 0x3ffffff
	put(DIRECT, {jal_work, 0, 0x240a00b0, 0x01400008, 0x24090017})
	put(GUEST_STUB, {0x240a00b0, 0x01400008, 0x24090017})

	hle := cpu.bios_b
	cpu.bios_b = count_b
	handler("a jr to a vector", DIRECT)
	real_b = hle
	handler("a jr to B(17h)", DIRECT)

	Case :: struct {
		target: u32,
		what:   string,
	}
	cases := [?]Case {
		{FUNC, "a j to a function that calls B(17h)"},
		{JR_FUNC, "a j to a function that jumps to B(17h)"},
		{NESTED_FUNC, "a j to a function whose callee jumps to B(17h)"},
	}
	for c in cases {
		put(BY_FUNC, {jal_work, 0, 0x08000000 | (c.target >> 2) & 0x3ffffff, 0})
		handler(c.what, BY_FUNC)
	}

	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok psx_rfe: a handler's jump to ReturnFromException ends it, at the vector and through a function that makes the call, whatever link $ra holds")
}
