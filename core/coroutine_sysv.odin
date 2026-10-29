#+build linux amd64, darwin amd64
// Coroutine switching on x86-64 with the System V ABI (Linux, macOS).
package core

// A suspended stack holds, from its saved pointer upward: MXCSR and the x87
// control word (8 bytes), r15, r14, r13, r12, rbx, rbp and the return
// address.
@(private, rodata)
CO_CODE := [?]u8 {
	// co_switch_stack(save: ^rawptr, sp: rawptr): suspend the running stack,
	// storing its pointer in save^, and resume the one suspended at sp.
	0x55,                   // push rbp
	0x53,                   // push rbx
	0x41, 0x54,             // push r12
	0x41, 0x55,             // push r13
	0x41, 0x56,             // push r14
	0x41, 0x57,             // push r15
	0x48, 0x83, 0xec, 0x08, // sub rsp, 8
	0x0f, 0xae, 0x1c, 0x24, // stmxcsr [rsp]
	0xd9, 0x7c, 0x24, 0x04, // fnstcw [rsp + 4]
	0x48, 0x89, 0x27,       // mov [rdi], rsp
	0x48, 0x89, 0xf4,       // mov rsp, rsi
	0x0f, 0xae, 0x14, 0x24, // ldmxcsr [rsp]
	0xd9, 0x6c, 0x24, 0x04, // fldcw [rsp + 4]
	0x48, 0x83, 0xc4, 0x08, // add rsp, 8
	0x41, 0x5f,             // pop r15
	0x41, 0x5e,             // pop r14
	0x41, 0x5d,             // pop r13
	0x41, 0x5c,             // pop r12
	0x5b,                   // pop rbx
	0x5d,                   // pop rbp
	0xc3,                   // ret
	// co_trampoline: a new stack's first resume lands here with the entry
	// procedure in rbx and its argument in r12. The entry never returns.
	0x4c, 0x89, 0xe7,       // mov rdi, r12
	0xff, 0xd3,             // call rbx
	0x0f, 0x0b,             // ud2
}
@(private)
CO_TRAMPOLINE :: 51

// A new stack at `top`, laid out as co_switch_stack leaves a suspended one,
// returning into co_trampoline with co_body in rbx and `co` in r12.
@(private)
co_frame :: proc(co: ^Coroutine, top: uintptr) -> rawptr {
	frame := ([^]uintptr)(top - 8 * size_of(uintptr))[:8]
	frame[0] = 0x037f << 32 | 0x1f80 // x87 control word, MXCSR: the defaults
	frame[1] = 0 // r15
	frame[2] = 0 // r14
	frame[3] = 0 // r13
	frame[4] = uintptr(co) // r12
	frame[5] = uintptr(rawptr(co_body)) // rbx
	frame[6] = 0 // rbp
	frame[7] = uintptr(co_trampoline)
	return &frame[0]
}
