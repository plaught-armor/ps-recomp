// Coroutine switching on Windows x64, on stacks committed whole with
// VirtualAlloc.
//
// Besides the registers the Windows x64 ABI has a callee keep (rbx, rbp,
// rdi, rsi, r12-r15, xmm6-xmm15, MXCSR, the x87 control word), a switch
// swaps the stack bounds in the thread's TEB (StackBase at gs:[8],
// StackLimit at gs:[16]): exception dispatch and unwinding reject frames
// outside them. The stacks are committed whole, so no guard page has to
// grow them.
package core

import win "core:sys/windows"

// A suspended stack holds, from its saved pointer upward: xmm6-xmm15 (160
// bytes), MXCSR and the x87 control word (8 bytes), StackLimit, StackBase,
// r15, r14, r13, r12, rsi, rdi, rbx, rbp and the return address.
@(private, rodata)
CO_CODE := [?]u8 {
	// co_switch_stack(save: ^rawptr, sp: rawptr): suspend the running stack,
	// storing its pointer in save^, and resume the one suspended at sp.
	0x55,                                                 // push rbp
	0x53,                                                 // push rbx
	0x57,                                                 // push rdi
	0x56,                                                 // push rsi
	0x41, 0x54,                                           // push r12
	0x41, 0x55,                                           // push r13
	0x41, 0x56,                                           // push r14
	0x41, 0x57,                                           // push r15
	0x65, 0xff, 0x34, 0x25, 0x08, 0x00, 0x00, 0x00,       // push qword gs:[0x8]
	0x65, 0xff, 0x34, 0x25, 0x10, 0x00, 0x00, 0x00,       // push qword gs:[0x10]
	0x48, 0x81, 0xec, 0xa8, 0x00, 0x00, 0x00,             // sub rsp, 0xa8
	0x0f, 0x29, 0x34, 0x24,                               // movaps [rsp], xmm6
	0x0f, 0x29, 0x7c, 0x24, 0x10,                         // movaps [rsp + 0x10], xmm7
	0x44, 0x0f, 0x29, 0x44, 0x24, 0x20,                   // movaps [rsp + 0x20], xmm8
	0x44, 0x0f, 0x29, 0x4c, 0x24, 0x30,                   // movaps [rsp + 0x30], xmm9
	0x44, 0x0f, 0x29, 0x54, 0x24, 0x40,                   // movaps [rsp + 0x40], xmm10
	0x44, 0x0f, 0x29, 0x5c, 0x24, 0x50,                   // movaps [rsp + 0x50], xmm11
	0x44, 0x0f, 0x29, 0x64, 0x24, 0x60,                   // movaps [rsp + 0x60], xmm12
	0x44, 0x0f, 0x29, 0x6c, 0x24, 0x70,                   // movaps [rsp + 0x70], xmm13
	0x44, 0x0f, 0x29, 0xb4, 0x24, 0x80, 0x00, 0x00, 0x00, // movaps [rsp + 0x80], xmm14
	0x44, 0x0f, 0x29, 0xbc, 0x24, 0x90, 0x00, 0x00, 0x00, // movaps [rsp + 0x90], xmm15
	0x0f, 0xae, 0x9c, 0x24, 0xa0, 0x00, 0x00, 0x00,       // stmxcsr [rsp + 0xa0]
	0xd9, 0xbc, 0x24, 0xa4, 0x00, 0x00, 0x00,             // fnstcw [rsp + 0xa4]
	0x48, 0x89, 0x21,                                     // mov qword [rcx], rsp
	0x48, 0x89, 0xd4,                                     // mov rsp, rdx
	0x0f, 0x28, 0x34, 0x24,                               // movaps xmm6, [rsp]
	0x0f, 0x28, 0x7c, 0x24, 0x10,                         // movaps xmm7, [rsp + 0x10]
	0x44, 0x0f, 0x28, 0x44, 0x24, 0x20,                   // movaps xmm8, [rsp + 0x20]
	0x44, 0x0f, 0x28, 0x4c, 0x24, 0x30,                   // movaps xmm9, [rsp + 0x30]
	0x44, 0x0f, 0x28, 0x54, 0x24, 0x40,                   // movaps xmm10, [rsp + 0x40]
	0x44, 0x0f, 0x28, 0x5c, 0x24, 0x50,                   // movaps xmm11, [rsp + 0x50]
	0x44, 0x0f, 0x28, 0x64, 0x24, 0x60,                   // movaps xmm12, [rsp + 0x60]
	0x44, 0x0f, 0x28, 0x6c, 0x24, 0x70,                   // movaps xmm13, [rsp + 0x70]
	0x44, 0x0f, 0x28, 0xb4, 0x24, 0x80, 0x00, 0x00, 0x00, // movaps xmm14, [rsp + 0x80]
	0x44, 0x0f, 0x28, 0xbc, 0x24, 0x90, 0x00, 0x00, 0x00, // movaps xmm15, [rsp + 0x90]
	0x0f, 0xae, 0x94, 0x24, 0xa0, 0x00, 0x00, 0x00,       // ldmxcsr [rsp + 0xa0]
	0xd9, 0xac, 0x24, 0xa4, 0x00, 0x00, 0x00,             // fldcw [rsp + 0xa4]
	0x48, 0x81, 0xc4, 0xa8, 0x00, 0x00, 0x00,             // add rsp, 0xa8
	0x65, 0x8f, 0x04, 0x25, 0x10, 0x00, 0x00, 0x00,       // pop qword gs:[0x10]
	0x65, 0x8f, 0x04, 0x25, 0x08, 0x00, 0x00, 0x00,       // pop qword gs:[0x8]
	0x41, 0x5f,                                           // pop r15
	0x41, 0x5e,                                           // pop r14
	0x41, 0x5d,                                           // pop r13
	0x41, 0x5c,                                           // pop r12
	0x5e,                                                 // pop rsi
	0x5f,                                                 // pop rdi
	0x5b,                                                 // pop rbx
	0x5d,                                                 // pop rbp
	0xc3,                                                 // ret
	// co_trampoline: a new stack's first resume lands here with the entry
	// procedure in rbx and its argument in r12, 16 bytes below the top. The
	// call gets its 32 bytes of shadow space; the entry never returns.
	0x4c, 0x89, 0xe1,                                     // mov rcx, r12
	0x48, 0x83, 0xec, 0x20,                               // sub rsp, 0x20
	0xff, 0xd3,                                           // call rbx
	0x0f, 0x0b,                                           // ud2
}
@(private)
CO_TRAMPOLINE :: 0xe9

// A new stack at `top`, laid out as co_switch_stack leaves a suspended one,
// returning into co_trampoline with co_body in rbx and `co` in r12.
@(private)
co_frame :: proc(co: ^Coroutine, top: uintptr) -> rawptr {
	frame := ([^]uintptr)(top - 16 - 32 * size_of(uintptr))[:32]
	for &w in frame[:20] {w = 0} // xmm6-xmm15
	frame[20] = 0x027f << 32 | 0x1f80 // x87 control word, MXCSR: the defaults
	frame[21] = uintptr(co.ctx.stack) // StackLimit
	frame[22] = top // StackBase
	frame[23] = 0 // r15
	frame[24] = 0 // r14
	frame[25] = 0 // r13
	frame[26] = uintptr(co) // r12
	frame[27] = 0 // rsi
	frame[28] = 0 // rdi
	frame[29] = uintptr(rawptr(co_body)) // rbx
	frame[30] = 0 // rbp
	frame[31] = uintptr(co_trampoline)
	return &frame[0]
}

@(private)
co_map_stack :: proc(n: int) -> rawptr {
	stack := win.VirtualAlloc(nil, uint(n), win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
	assert(stack != nil, "coroutine stack")
	return stack
}
