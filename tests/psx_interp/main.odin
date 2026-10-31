// The PS1 interpreter's jumps into the BIOS: interpreted code that tail
// calls a vector through a register other than $ra (addiu t2,zero,0xa0;
// jr t2; addiu t1,zero,fn, the libapi stub shape) runs the A, B or C
// function and returns to the caller's $ra, as a call from native code
// does. Each vector's RAM holds a reserved instruction, so stepping into it
// stops the test with a fatal error instead of running on.
// An interpreted syscall 3 to a TCB switches threads as ChangeTh does, and
// the interpreted code goes on past it with v0 1 when the main thread is
// switched back to.
package main

import "core:fmt"
import "core:os"
import _ "ps:psx"
import bios "ps:psx/bios"
import cpu "ps:psx/cpu"

@(private = "file")
failed: int

@(private = "file")
check :: proc(what: string, got, want: u32) {
	if got != want {
		fmt.eprintfln("FAIL psx_interp: %s = %#x, want %#x", what, got, want)
		failed += 1
	}
}

// Where the stubs sit, and the return address their caller leaves in $ra.
@(private = "file")
STUB :: 0x80001000
@(private = "file")
RA :: 0x80000ff0

// addiu a0, zero, 3; syscall; jr ra; nop, with a1 the TCB.
@(private = "file")
SYSCALL_3 :: 0x80001100

// A thread that counts its turns and switches back to the main thread
// through the B(10h) stub.
@(private = "file")
FN_THREAD :: 0x80001200

@(private = "file")
turns: int

// Interpret the stub for vector vec and function fn with a0 and a1; v0.
@(private = "file")
stub :: proc(vec, fn: u32, a0: u32 = 0, a1: u32 = 0) -> u32 {
	cpu.w32(STUB, 0x240a0000 | vec) // addiu t2, zero, vec
	cpu.w32(STUB + 4, 0x01400008) // jr t2
	cpu.w32(STUB + 8, 0x24090000 | fn) // addiu t1, zero, fn
	r := &cpu.state.r
	r[2] = 0xdead
	r[4], r[5] = a0, a1
	r[31] = RA
	cpu.call(STUB)
	check(fmt.tprintf("$ra after the %xh stub", vec), r[31], RA)
	check(fmt.tprintf("t1 after the %xh stub", vec), r[9], fn)
	return r[2]
}

main :: proc() {
	cpu.register_funcs({{FN_THREAD, proc() {
				for {
					turns += 1
					stub(0xb0, 0x10, 0xff000000)
				}
			}}})
	bios.bios_init()
	for vec in ([?]u32{0xa0, 0xb0, 0xc0}) {
		cpu.w32(vec, 0xffffffff)
	}

	check("A(0Eh) abs(-5)", stub(0xa0, 0x0e, transmute(u32)i32(-5)), 5)
	check("B(0Ch) EnableEvent", stub(0xb0, 0x0c, 0xf1000000), 1)
	// ChangeClearRCnt returns the flag the call before set.
	stub(0xc0, 0x0a, 0, 1)
	check("C(0Ah) ChangeClearRCnt", stub(0xc0, 0x0a, 0, 0), 1)

	h := stub(0xb0, 0x0e, FN_THREAD, 0x801f0000)
	check("B(0Eh) OpenTh", h, 0xff000001)
	for w, k in ([?]u32{0x24040003, 0x0000000c, 0x03e00008, 0}) {
		cpu.w32(SYSCALL_3 + 4 * u32(k), w)
	}
	r := &cpu.state.r
	for want in 1 ..= 2 {
		r[2], r[5], r[16], r[31] = 0xdead, cpu.r32(0x110) + 0xc0, 0x5555, RA
		cpu.call(SYSCALL_3)
		check("syscall 3 to a TCB", r[2], 1)
		check("main thread s0 after syscall 3", r[16], 0x5555)
		check("thread turns after syscall 3", u32(turns), u32(want))
	}

	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok psx_interp: jr to the A0, B0 and C0 vectors runs the function and returns to $ra; syscall 3 switches threads")
}
