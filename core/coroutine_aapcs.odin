#+build linux arm64, darwin arm64
// Coroutine switching on arm64 with the AAPCS64 ABI (Linux, macOS). x18 is
// left alone: macOS reserves it. tests/core runs it on the arm64 CI hosts
// (Linux, macOS); no game has run on arm64 yet.
package core

// A suspended stack holds, from its saved pointer upward: x19-x28, x29 (frame
// pointer), x30 (the return address), d8-d15, FPCR and 8 bytes of padding.
@(private, rodata)
CO_CODE := [?]u32 {
	// co_switch_stack(save: ^rawptr, sp: rawptr): suspend the running stack,
	// storing its pointer in save^, and resume the one suspended at sp.
	0xd102c3ff, // sub sp, sp, #0xb0
	0xa90053f3, // stp x19, x20, [sp]
	0xa9015bf5, // stp x21, x22, [sp, #0x10]
	0xa90263f7, // stp x23, x24, [sp, #0x20]
	0xa9036bf9, // stp x25, x26, [sp, #0x30]
	0xa90473fb, // stp x27, x28, [sp, #0x40]
	0xa9057bfd, // stp x29, x30, [sp, #0x50]
	0x6d0627e8, // stp d8, d9, [sp, #0x60]
	0x6d072fea, // stp d10, d11, [sp, #0x70]
	0x6d0837ec, // stp d12, d13, [sp, #0x80]
	0x6d093fee, // stp d14, d15, [sp, #0x90]
	0xd53b4409, // mrs x9, fpcr
	0xf90053e9, // str x9, [sp, #0xa0]
	0x910003e9, // mov x9, sp
	0xf9000009, // str x9, [x0]
	0x9100003f, // mov sp, x1
	0xf94053e9, // ldr x9, [sp, #0xa0]
	0xd51b4409, // msr fpcr, x9
	0xa94053f3, // ldp x19, x20, [sp]
	0xa9415bf5, // ldp x21, x22, [sp, #0x10]
	0xa94263f7, // ldp x23, x24, [sp, #0x20]
	0xa9436bf9, // ldp x25, x26, [sp, #0x30]
	0xa94473fb, // ldp x27, x28, [sp, #0x40]
	0xa9457bfd, // ldp x29, x30, [sp, #0x50]
	0x6d4627e8, // ldp d8, d9, [sp, #0x60]
	0x6d472fea, // ldp d10, d11, [sp, #0x70]
	0x6d4837ec, // ldp d12, d13, [sp, #0x80]
	0x6d493fee, // ldp d14, d15, [sp, #0x90]
	0x9102c3ff, // add sp, sp, #0xb0
	0xd65f03c0, // ret
	// co_trampoline: a new stack's first resume lands here with the entry
	// procedure in x20 and its argument in x19. The entry never returns.
	0xaa1303e0, // mov x0, x19
	0xd63f0280, // blr x20
	0xd4200000, // brk #0
}
@(private)
CO_TRAMPOLINE :: 0x78

// A new stack at `top`, laid out as co_switch_stack leaves a suspended one,
// returning into co_trampoline with `co` in x19 and co_body in x20.
@(private)
co_frame :: proc(co: ^Coroutine, top: uintptr) -> rawptr {
	frame := ([^]uintptr)(top - 22 * size_of(uintptr))[:22]
	// x21-x28, x29 (0 ends a frame-pointer walk), d8-d15 and FPCR (0: round
	// to nearest, no traps, no flush-to-zero) start zero.
	for &w in frame {w = 0}
	frame[0] = uintptr(co) // x19
	frame[1] = uintptr(rawptr(co_body)) // x20
	frame[11] = uintptr(co_trampoline) // x30
	return &frame[0]
}
