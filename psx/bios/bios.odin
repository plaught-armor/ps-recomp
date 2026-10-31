// High-level emulation of the BIOS A/B/C function tables the game calls, plus
// interrupt delivery through the HookEntryInt jump buffer.
package psx_bios

import "core:fmt"
import "core:strings"

import "ps:core"
import cpu "../cpu"
import io "../io"
import libc "libc"

bios: struct {
	// HookEntryInt jump buffer: [0]=ra [1]=sp [2]=fp [3..10]=s0-s7 [11]=gp.
	hook:      u32,
	rand_seed: u32,
	pad_buf:   [2]u32,
	// SysEnqIntRP chain heads by priority.
	chains:    [4]u32,
	// B(15h) button word destination, written every vblank.
	pad_word:  u32,
	// ChangeClearRCnt flags: timers 0-2 and vblank (3) auto-acknowledge
	// their IRQ and end the exception. On at boot, as on the retail kernel.
	rcnt_ack:  [4]bool,
	// A handler called ReturnFromException during deliver_irq.
	rfe:       bool,
	// The pad driver's vblank handler is in chain 2 (StartPAD or StartCARD
	// until StopPAD or StopCARD).
	sio0:      bool,
	// ChangeClearPad flag: that handler acknowledges vblank.
	pad_ack:   bool,
	// The pad driver reads the pads (InitPAD, until libpad stops it through
	// the pointer it takes from the driver's code).
	pad_read:  bool,
	// syscall 3 was called directly once (bios_syscall).
	tcb_warn:  bool,
	// SetConf/GetConf: event and thread control block counts, stack top.
	conf:      [3]u32,
}

// Host input and GPU, set by package psx (hooks.odin) so this package does
// not pull in the platform layer.
pad_game: proc() -> u16
// Analog stick positions, x right and y down, each in -1..1.
sticks: proc() -> (left, right: [2]f32)
pad_rumble: proc(small: bool, large: u8)
gp0_write: proc(w: u32)

// The seed of the BIOS rand() (A0:2F), where the game's random numbers come
// from.
rand_seed :: proc() -> u32 {
	return bios.rand_seed
}

set_rand_seed :: proc(seed: u32) {
	bios.rand_seed = seed
}

@(private)
arg :: #force_inline proc(n: u32) -> u32 {
	if n < 4 {
		return cpu.state.r[4 + n]
	}
	return cpu.r32(cpu.state.r[29] + 4 * n)
}

@(private)
ret :: #force_inline proc(v: u32) {
	cpu.state.r[2] = v
}

// BIOS pad driver: after InitPad, every vblank stores port 1 as a digital
// pad (status 0, id 0x41, buttons active-low in transfer order) and port 2
// as absent.
bios_pad_vblank :: proc() {
	if !bios.pad_read {
		return
	}
	if bios.pad_buf[0] != 0 {
		b := ~pad_game()
		cpu.w8(bios.pad_buf[0], 0x00)
		cpu.w8(bios.pad_buf[0] + 1, 0x41)
		cpu.w8(bios.pad_buf[0] + 2, u8(b >> 8))
		cpu.w8(bios.pad_buf[0] + 3, u8(b))
	}
	if bios.pad_buf[1] != 0 {
		cpu.w8(bios.pad_buf[1], 0xff)
	}
	if bios.pad_word != 0 {
		cpu.w32(bios.pad_word, pad_dr())
	}
}

// B(16h) button word: port 1's first button byte in bits 8-15 and its second
// in bits 0-7, active-low; port 2, absent, reads 0xffff.
@(private)
pad_dr :: proc() -> u32 {
	return 0xffff0000 | u32(~pad_game())
}

bios_a :: proc(fn: u32) {
	if .Bios in core.trace.active {
		core.tracef(.Bios, "A(%02xh) a0=%x a1=%x a2=%x ra=%x", fn, arg(0), arg(1), arg(2), cpu.state.r[31])
	}
	if fn < len(a0_from_b0) && a0_from_b0[fn] != 0 {
		bios_b(u32(a0_from_b0[fn]))
		return
	}
	switch fn {
	case 0x0c:
		ret(libc.strtoul(arg(0), arg(1), arg(2)))
	case 0x0d:
		ret(libc.strtol(arg(0), arg(1), arg(2)))
	case 0x0e, 0x0f:
		ret(libc.abs(arg(0)))
	case 0x0a:
		ret(libc.todigit(arg(0)))
	case 0x10, 0x11:
		ret(libc.atoi(arg(0)))
	case 0x12:
		ret(libc.atob(arg(0), arg(1)))
	case 0x13:
		bios_setjmp(arg(0))
	case 0x15:
		ret(libc.strcat(arg(0), arg(1)))
	case 0x16:
		ret(libc.strncat(arg(0), arg(1), arg(2)))
	case 0x17:
		ret(libc.strcmp(arg(0), arg(1)))
	case 0x18:
		ret(libc.strncmp(arg(0), arg(1), arg(2)))
	case 0x19:
		ret(libc.strcpy(arg(0), arg(1)))
	case 0x1a:
		ret(libc.strncpy(arg(0), arg(1), arg(2)))
	case 0x1b:
		ret(libc.strlen(arg(0)))
	case 0x1c, 0x1e:
		ret(libc.strchr(arg(0), arg(1)))
	case 0x1d, 0x1f:
		ret(libc.strrchr(arg(0), arg(1)))
	case 0x20:
		ret(libc.strpbrk(arg(0), arg(1)))
	case 0x21:
		ret(libc.strspn(arg(0), arg(1)))
	case 0x22:
		ret(libc.strcspn(arg(0), arg(1)))
	case 0x23:
		ret(libc.strtok(arg(0), arg(1)))
	case 0x24:
		ret(libc.strstr(arg(0), arg(1)))
	case 0x25:
		ret(libc.toupper(arg(0)))
	case 0x26:
		ret(libc.tolower(arg(0)))
	case 0x28:
		ret(libc.memset(arg(0), 0, arg(1)))
	case 0x29, 0x2d:
		ret(libc.memcmp(arg(0), arg(1), arg(2)))
	case 0x27:
		ret(libc.bcopy(arg(0), arg(1), arg(2)))
	case 0x2a:
		ret(libc.memcpy(arg(0), arg(1), arg(2)))
	case 0x2b:
		ret(libc.memset(arg(0), u8(arg(1)), arg(2)))
	case 0x2c:
		ret(libc.memmove(arg(0), arg(1), arg(2)))
	case 0x2e:
		ret(libc.memchr(arg(0), arg(1), arg(2)))
	case 0x2f:
		bios.rand_seed = bios.rand_seed * 0x41c64e6d + 0x3039
		ret((bios.rand_seed >> 16) & 0x7fff)
	case 0x30:
		bios.rand_seed = arg(0)
	case 0x31:
		libc.qsort(arg(0), arg(1), arg(2), arg(3))
	case 0x33:
		ret(libc.malloc(arg(0)))
	case 0x34:
		libc.free(arg(0))
	case 0x35:
		ret(libc.lsearch(arg(0), arg(1), arg(2), arg(3), arg(4)))
	case 0x36:
		ret(libc.bsearch(arg(0), arg(1), arg(2), arg(3), arg(4)))
	case 0x37:
		ret(libc.calloc(arg(0), arg(1)))
	case 0x38:
		ret(libc.realloc(arg(0), arg(1)))
	case 0x39:
		libc.init_heap(arg(0), arg(1))
	case 0x41, 0x42:
		ret(exec_load(cpu.mem_cstring(arg(0)), arg(1), fn == 0x42))
	case 0x43:
		exec(arg(0), arg(1), arg(2))
	case 0x44, 0x72:
	// FlushCache, CdRemove: nothing to do.
	case 0x3f:
		fmt.eprint("[printf] ", bios_format(cpu.mem_cstring(arg(0)), 1), sep = "")
	case 0x49:
		gp0_write(arg(0))
	case 0x51:
		load_exec(cpu.mem_cstring(arg(0)), arg(1), arg(2))
	case 0x70:
		ret(1) // _bu_init
	case 0x9c:
		// SetConf(events, threads, stack top). The retail kernel rebuilds
		// itself with tables of the new sizes; the HLE tables are fixed,
		// so this only records the values for GetConf.
		if arg(0) > MAX_EVENTS || arg(1) > MAX_THREADS {
			fmt.eprintfln(
				"bios: SetConf(%d events, %d threads) beyond the %d and %d here",
				arg(0),
				arg(1),
				MAX_EVENTS,
				MAX_THREADS,
			)
		}
		bios.conf = {arg(0), arg(1), arg(2)}
	case 0x9d:
		// GetConf(&events, &threads, &stack top), stored in the retail order.
		cpu.w32(arg(2), bios.conf[2])
		cpu.w32(arg(0), bios.conf[0])
		cpu.w32(arg(1), bios.conf[1])
	case 0xab, 0xac:
		// _card_info / _card_load: complete at once.
		card_info(arg(0))
		ret(1)
	case:
		bios_unknown("A", fn)
	}
}

bios_b :: proc(fn: u32) {
	if .Bios in core.trace.active {
		core.tracef(.Bios, "B(%02xh) a0=%x a1=%x a2=%x ra=%x", fn, arg(0), arg(1), arg(2), cpu.state.r[31])
	}
	switch fn {
	case 0x07:
		deliver_event(arg(0), arg(1))
		ret(1)
	case 0x08:
		ret(open_event(arg(0), arg(1), arg(2), arg(3)))
	case 0x09:
		close_event(arg(0))
		ret(1)
	case 0x0a:
		ret(wait_event(arg(0)))
	case 0x0b:
		ret(test_event(arg(0)))
	case 0x0c:
		set_event_status(arg(0), EV_ENABLED)
		ret(1)
	case 0x0d:
		set_event_status(arg(0), EV_DISABLED)
		ret(1)
	case 0x0e:
		ret(open_thread(arg(0), arg(1), arg(2)))
	case 0x0f:
		ret(close_thread(arg(0)))
	case 0x10:
		change_thread(arg(0))
	case 0x12:
		bios.pad_buf = {arg(0), arg(2)}
		bios.pad_read = true
		ret(1)
	case 0x13:
		sio0_start(true)
		ret(1)
	case 0x14:
		sio0_stop()
		ret(1)
	case 0x15:
		// InitPAD2(type, button word): only the two 6-button types start
		// the driver; anything else is refused.
		if arg(0) == 0x20000000 || arg(0) == 0x20000001 {
			bios.pad_word = arg(1)
			bios.pad_read = true
			sio0_start(true)
			ret(2)
		} else {
			ret(0)
		}
	case 0x16:
		// PAD_dr, also stored where B(15h) asked.
		v := pad_dr()
		if bios.pad_word != 0 {
			cpu.w32(bios.pad_word, v)
		}
		ret(v)
	case 0x17:
		// ReturnFromException. The handler still returns normally here;
		// deliver_irq then skips the rest of the chains and the hook.
		if io.irq_regs.in_handler {
			bios.rfe = true
		}
	case 0x18:
		// SetDefaultExitFromException: the retail default exit buffer
		// returns through ReturnFromException, which is what no hook
		// does here.
		bios.hook = 0
	case 0x19:
		bios.hook = arg(0)
	case 0x20:
		undeliver_event(arg(0), arg(1))
	case 0x32:
		ret(card_open(cpu.mem_cstring(arg(0)), arg(1)))
	case 0x33:
		ret(card_seek(arg(0), arg(1), arg(2)))
	case 0x34:
		ret(card_rw(arg(0), arg(1), arg(2), false))
	case 0x35:
		ret(card_rw(arg(0), arg(1), arg(2), true))
	case 0x36:
		ret(card_close(arg(0)))
	case 0x3f:
		fmt.eprintln("[puts]", cpu.mem_cstring(arg(0)))
	case 0x42:
		ret(card_nextfile(arg(1), true, cpu.mem_cstring(arg(0))))
	case 0x43:
		ret(card_nextfile(arg(0), false))
	case 0x45:
		ret(card_erase(cpu.mem_cstring(arg(0))))
	case 0x4a, 0x50:
		ret(1) // InitCARD, allow_new_card
	case 0x4b:
		sio0_start(false)
		ret(1)
	case 0x4c:
		sio0_stop()
		ret(1)
	case 0x4e, 0x4f:
		ret(card_sector(arg(0), arg(1), arg(2), fn == 0x4e))
	case 0x5c, 0x5d:
		ret(1) // _card_status, _card_wait: idle, every operation is done
	case 0x56:
		ret(C0_TABLE)
	case 0x57:
		ret(B0_TABLE)
	case 0x5b:
		// ChangeClearPad(flag): returns the old flag.
		ret(u32(bios.pad_ack))
		bios.pad_ack = arg(0) != 0
	case:
		bios_unknown("B", fn)
	}
}

bios_c :: proc(fn: u32) {
	if .Bios in core.trace.active {
		core.tracef(.Bios, "C(%02xh) a0=%x a1=%x a2=%x ra=%x", fn, arg(0), arg(1), arg(2), cpu.state.r[31])
	}
	switch fn {
	case 0x02:
		int_chain_enqueue(arg(0), arg(1))
		ret(0)
	case 0x03:
		ret(int_chain_dequeue(arg(0), arg(1)))
	case 0x0a:
		// ChangeClearRCnt(t, flag): returns the old flag.
		if t := arg(0); t < len(bios.rcnt_ack) {
			ret(u32(bios.rcnt_ack[t]))
			bios.rcnt_ack[t] = arg(1) != 0
		} else {
			ret(0)
		}
	case:
		bios_unknown("C", fn)
	}
}

// A call to a table entry's stub (TABLE_STUBS): the function it names, with
// t1 set as the stub sets it.
bios_entry :: proc(addr: u32) -> bool {
	off := (addr & 0x1fffffff) - TABLE_STUBS
	if off >= 8 * (B0_ENTRIES + C0_ENTRIES) || off & 7 != 0 {
		return false
	}
	n := off / 8
	if n < B0_ENTRIES {
		cpu.state.r[9] = n
		bios_b(n)
	} else {
		cpu.state.r[9] = n - B0_ENTRIES
		bios_c(n - B0_ENTRIES)
	}
	return true
}

// syscall with a0 of 3 or more, as the retail kernel's handler does it.
// 3 is ChangeThreadSubFunction(tcb), the thread switch under ChangeTh
// (B 10h); the HLE threads have no control blocks to switch by, so a
// direct call returns 1 and stays on the running thread. Anything higher
// delivers class 0xf0000010 spec 0x4000.
bios_syscall :: proc() {
	if arg(0) == 3 {
		if !bios.tcb_warn {
			fmt.eprintfln("bios: syscall 3 (switch to TCB %#x) not done; ChangeTh is", arg(1))
			bios.tcb_warn = true
		}
		ret(1)
		return
	}
	deliver_event(0xf0000010, 0x4000)
}

// The A functions the retail kernel's C(1Ch) AdjustA0Table points at B
// functions during boot: A 00-09 (open to putc) are B 32-3B, A 3B-3E
// (getchar to puts) are B 3C-3F. 0 = not redirected.
@(private, rodata)
a0_from_b0 := [0x3f]u8 {
	0x00 = 0x32,
	0x01 = 0x33,
	0x02 = 0x34,
	0x03 = 0x35,
	0x04 = 0x36,
	0x05 = 0x37,
	0x06 = 0x38,
	0x07 = 0x39,
	0x08 = 0x3a,
	0x09 = 0x3b,
	0x3b = 0x3c,
	0x3c = 0x3d,
	0x3d = 0x3e,
	0x3e = 0x3f,
}

// Table entries that never return on the retail kernel: each is a stub that
// loads its own number and jumps to its table's vector, which dispatches
// straight back to the stub. Listed by the PS1 BIOS index (v4.5 retail
// kernel):
//   awk -F'\t' '$12 ~ /hangs:/ {print $1, $2}' bios-index/ps1/index.tsv
@(private)
A0_HANGS :: bit_set[0x3a ..= 0xa1; u128]{0x3a, 0x40, 0x4f, 0x50, 0x52, 0x53, 0x9a, 0x9b, 0xa1}
@(private)
B0_HANGS :: bit_set[0x1a ..= 0x5a; u128] {
	0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x21, 0x22, 0x23, 0x2a, 0x2b, 0x52, 0x5a,
}
@(private)
C0_HANGS :: bit_set[0x0b ..= 0x0b; u128]{0x0b}

// Whether table(fn) is one of those stubs. fn comes from the guest and can
// lie outside a set's range, where `in` alone is not defined; the range is
// tested first.
hangs_on_retail :: proc(table: string, fn: u32) -> bool {
	switch table {
	case "A":
		return fn >= 0x3a && fn <= 0xa1 && int(fn) in A0_HANGS
	case "B":
		return fn >= 0x1a && fn <= 0x5a && int(fn) in B0_HANGS
	case "C":
		return fn == 0x0b && int(fn) in C0_HANGS
	}
	return false
}

// Table entries the retail kernel points at a bare `jr ra; move v0, zero`
// (A: 0xbfc06fdc, C: 0x35a4): they return 0 and touch nothing else. Listed
// by the PS1 BIOS index (v4.5 retail kernel):
//   awk -F'\t' '$5 == "0xbfc06fdc" || $5 == "0x000035a4" {print $1, $2}' bios-index/ps1/index.tsv
@(private)
A0_RETURN_0 :: bit_set[0x57 ..= 0xb3; u128] {
	0x57, 0x58, 0x59, 0x5a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x79, 0x7a, 0x7b,
	0x7d, 0x7f, 0x80, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a,
	0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0xb0, 0xb1, 0xb3,
}
@(private)
C0_RETURN_0 :: bit_set[0x0e ..= 0x14; u128]{0x0e, 0x0f, 0x10, 0x11, 0x14}

// Whether table(fn) is one of those stubs. fn comes from the guest and can
// lie outside a set's range, where `in` alone is not defined; the range is
// tested first.
returns_0_on_retail :: proc(table: string, fn: u32) -> bool {
	switch table {
	case "A":
		return fn >= 0x57 && fn <= 0xb3 && int(fn) in A0_RETURN_0
	case "C":
		return fn >= 0x0e && fn <= 0x14 && int(fn) in C0_RETURN_0
	}
	return false
}

// A call the HLE BIOS does not handle stops the game, except under COMPAT,
// where it returns 0. One the retail kernel sends to a return-0 stub returns
// 0 silently, as retail does, and is not counted. One that hangs on the
// retail kernel says so: the game was never meant to get there.
@(private)
bios_unknown :: proc(table: string, fn: u32) {
	if returns_0_on_retail(table, fn) {
		ret(0)
		return
	}
	kind := core.Compat_Call.Bios_A
	switch table {
	case "B": kind = .Bios_B
	case "C": kind = .Bios_C
	}
	// ra is the game's call: the library stub that jumps here leaves it.
	if core.compat_unknown(kind, fn, ra = cpu.state.r[31]) {
		ret(0)
		return
	}
	if hangs_on_retail(table, fn) {
		cpu.fatal("BIOS %s(%02xh) hangs on retail (ra %#08x)", table, fn, cpu.state.r[31])
	}
	if table == "A" {
		switch fn {
		case 0x0b, 0x32:
			cpu.fatal("unimplemented BIOS A(%02xh): it uses the FPU the console lacks, so it faults on retail too (ra %#08x)", fn, cpu.state.r[31])
		case 0x14:
			cpu.fatal("unimplemented BIOS A(14h) longjmp: a jump back across host frames is not supported (ra %#08x)", cpu.state.r[31])
		}
	}
	cpu.fatal("unimplemented BIOS %s(%02xh) (ra %#08x)", table, fn, cpu.state.r[31])
}

@(private)
bios_setjmp :: proc(buf: u32) {
	cpu.w32(buf, cpu.state.r[31])
	cpu.w32(buf + 4, cpu.state.r[29])
	cpu.w32(buf + 8, cpu.state.r[30])
	for i in u32(0) ..< 8 {
		cpu.w32(buf + 12 + i * 4, cpu.state.r[16 + i])
	}
	cpu.w32(buf + 44, cpu.state.r[28])
	ret(0)
}

// Minimal printf for debug output; `first` is the index of the first vararg.
@(private)
bios_format :: proc(f: string, first: u32) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := first
	i := 0
	for i < len(f) {
		ch := f[i]
		i += 1
		if ch != '%' || i >= len(f) {
			strings.write_byte(&b, ch)
			continue
		}
		for i < len(f) && strings.index_byte("0123456789-+ #.lh", f[i]) >= 0 {
			i += 1
		}
		if i >= len(f) {
			break
		}
		conv := f[i]
		i += 1
		switch conv {
		case 'd', 'i':
			fmt.sbprint(&b, i32(arg(n)))
		case 'u':
			fmt.sbprint(&b, arg(n))
		case 'x', 'X', 'p':
			fmt.sbprintf(&b, "%x", arg(n))
		case 'c':
			strings.write_byte(&b, u8(arg(n)))
		case 's':
			strings.write_string(&b, cpu.mem_cstring(arg(n)))
		case '%':
			strings.write_byte(&b, '%')
			continue
		}
		n += 1
	}
	return strings.to_string(b)
}

// GetC0Table/GetB0Table, at the retail kernel's addresses. PsyQ libraries
// patch kernel code reached through two entries, at fixed offsets: the
// exception handler (C0 06h) and the pad and card driver (B0 5Bh,
// ChangeClearPad), up to 0x198c bytes past it. Both point at kernel RAM
// kept free for those patches; the HLE BIOS never executes that code.
// Every other entry the retail kernel sets points at a stub of its own
// (TABLE_STUBS); the ones it leaves 0 (B0_UNSET) stay 0.
@(private)
C0_TABLE :: 0x674
@(private)
B0_TABLE :: 0x874
@(private)
B0_ENTRIES :: 0x60
@(private)
C0_ENTRIES :: 0x1e
// The B0 entries the retail kernel leaves 0. Every C0 entry is set.
@(private)
B0_UNSET :: bit_set[0 ..< B0_ENTRIES; u128] {
	0x11, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x5e, 0x5f,
}
@(private)
EXC_HANDLER :: 0xc80
@(private)
PAD_DRIVER :: 0x4000

// Offsets into the pad driver that libpad takes. It calls the first three
// through pointers: setPadOutputData(buf1, n1, buf2, n2), and the start and
// stop of pad reading. _remove_ChgclrPAD zeroes 9 words at the last, the
// handler's vblank acknowledge; a nonzero word stands in for that code.
@(private)
PAD_SET_OUTPUT :: 0x7a0
@(private)
PAD_READ_START :: 0x884
@(private)
PAD_READ_STOP :: 0x894
@(private)
PAD_ACK_CODE :: 0x62c

// The retail exception vector: lui k0, 0; addiu k0, k0, EXC_HANDLER; jr k0;
// nop. Games copy it until the nop, and test the halfword at 0x86. The
// retail kernel writes it at 0x00 as well.
@(private)
EXC_VECTOR :: [4]u32{0x3c1a0000, 0x275a0000 | EXC_HANDLER, 0x03400008, 0}

// Device control block table (pointer at 0x150, byte size at 0x154). PsyQ's
// firstfile() looks up the "bu" device here and patches its handler; the
// HLE file functions never call through it, so one named entry is enough.
@(private)
FAKE_DCB_TABLE :: 0x3000

@(private)
DCB_SIZE :: 0x50

// The stack top GetConf reports until SetConf: the retail default.
@(private)
STACK_TOP :: 0x801fff00

// The B0 entries' stubs, then the C0 entries', 8 bytes each: j 0xb0 (or
// 0xc0) with t1 = the function number in the delay slot, so a call through
// the table reaches the same function as a call to the vector. bios_entry
// runs such a call without interpreting the stub.
@(private)
TABLE_STUBS :: FAKE_DCB_TABLE + 0x100

// Kernel RAM the HLE BIOS fixes, from 0x3000: the DCB table and the stubs
// to 0x34f0, KERNEL_EXEC (exec.odin) at 0x3800, PAD_DRIVER at 0x4000 to
// about 0x48a0, and strtok's buffer and pointer (libc) at 0x9030-0x9133.

bios_init :: proc() {
	vector := EXC_VECTOR
	for w, k in vector {
		cpu.w32(0x00 + 4 * u32(k), w)
		cpu.w32(0x80 + 4 * u32(k), w)
	}
	for n in u32(0) ..< B0_ENTRIES + C0_ENTRIES {
		stub := TABLE_STUBS + 8 * n
		if n < B0_ENTRIES {
			if int(n) in B0_UNSET {
				cpu.w32(B0_TABLE + 4 * n, 0)
				continue
			}
			cpu.w32(B0_TABLE + 4 * n, stub)
			cpu.w32(stub, 0x0800002c) // j 0xb0
			cpu.w32(stub + 4, 0x24090000 | n) // addiu t1, zero, n
		} else {
			cpu.w32(C0_TABLE + 4 * (n - B0_ENTRIES), stub)
			cpu.w32(stub, 0x08000030) // j 0xc0
			cpu.w32(stub + 4, 0x24090000 | (n - B0_ENTRIES))
		}
	}
	cpu.w32(C0_TABLE + 0x06 * 4, EXC_HANDLER)
	cpu.w32(B0_TABLE + 0x5b * 4, PAD_DRIVER)
	cpu.w32(PAD_DRIVER + PAD_ACK_CODE, 0x3c011f80) // lui at, 0x1f80
	cpu.register_funcs(
		{
			{PAD_DRIVER + PAD_SET_OUTPUT, proc() {}},
			{PAD_DRIVER + PAD_READ_START, proc() {bios.pad_read = true}},
			{PAD_DRIVER + PAD_READ_STOP, proc() {bios.pad_read = false}},
		},
	)
	libc.memset(FAKE_DCB_TABLE, 0, DCB_SIZE + 4)
	copy(cpu.mem_slice(FAKE_DCB_TABLE + DCB_SIZE, 3), "bu\x00")
	cpu.w32(FAKE_DCB_TABLE, FAKE_DCB_TABLE + DCB_SIZE)
	cpu.w32(0x150, FAKE_DCB_TABLE)
	cpu.w32(0x154, DCB_SIZE)
	bios.rcnt_ack = {0 ..< len(bios.rcnt_ack) = true}
	bios.conf = {MAX_EVENTS, MAX_THREADS, STACK_TOP}
	threads_init()
}

// ---------------------------------------------------------------- events

@(private)
EV_DISABLED :: 0x1000
@(private)
EV_ENABLED :: 0x2000
@(private)
EV_READY :: 0x4000
@(private)
EV_MODE_CALLBACK :: 0x1000
@(private)
EV_MODE_READY :: 0x2000

@(private)
Bios_Event :: struct {
	class, spec, mode, status, func: u32,
}

@(private)
MAX_EVENTS :: 32

@(private)
events_tab: [MAX_EVENTS]Bios_Event

@(private)
event_slot :: proc(h: u32) -> ^Bios_Event {
	i := h & 0xffff
	if h & 0xffff0000 != 0xf1000000 || i >= MAX_EVENTS || events_tab[i].status == 0 {
		return nil
	}
	return &events_tab[i]
}

@(private)
open_event :: proc(class, spec, mode, func: u32) -> u32 {
	for &e, i in events_tab {
		if e.status == 0 {
			e = {class, spec, mode, EV_DISABLED, func}
			return 0xf1000000 | u32(i)
		}
	}
	fmt.eprintfln("bios: event table full (class %#x spec %#x)", class, spec)
	return 0xffffffff
}

@(private)
// CloseEvent, EnableEvent and DisableEvent return 1 whatever the handle,
// as on the retail kernel.
close_event :: proc(h: u32) {
	if e := event_slot(h); e != nil {
		e^ = {}
	}
}

@(private)
set_event_status :: proc(h, status: u32) {
	if e := event_slot(h); e != nil {
		e.status = status
	}
}

@(private)
test_event :: proc(h: u32) -> u32 {
	e := event_slot(h)
	if e == nil || e.status != EV_READY {
		return 0
	}
	e.status = EV_ENABLED
	return 1
}

// WaitEvent: 0 for a disabled event, else run time forward (and with it the
// interrupts that deliver events) until it is ready, then take it back to
// enabled. A callback event never becomes ready, so waiting on one hangs, as
// on hardware. The wait gives up with 0 when the event stops being enabled
// or time cannot advance (frozen for a checkpoint pass). With interrupts
// blocked (SR IE off, or inside a handler) hardware also hangs on an event
// only an IRQ readies; here that would freeze the window, so after
// WAIT_BLOCKED_CYCLES of device events alone it gives up with 0.
@(private)
wait_event :: proc(h: u32) -> u32 {
	e := event_slot(h)
	if e == nil {
		return 0
	}
	blocked_since := cpu.state.cycles
	for e.status == EV_ENABLED {
		if cpu.next_event == io.EVENT_OFF {
			return 0
		}
		if cpu.cop0.sr & 0x401 == 0x401 && !io.irq_regs.in_handler {
			blocked_since = cpu.state.cycles
		} else if cpu.state.cycles - blocked_since >= WAIT_BLOCKED_CYCLES {
			fmt.eprintfln("bios: WaitEvent(%#x) with interrupts blocked never became ready", h)
			return 0
		}
		cpu.state.cycles = max(cpu.state.cycles, cpu.next_event)
		io.run_events()
	}
	if e.status != EV_READY {
		return 0
	}
	e.status = EV_ENABLED
	return 1
}

// One second: device events (memory card, CD) still ready events while
// interrupts are blocked, and finish well within it.
@(private)
WAIT_BLOCKED_CYCLES :: io.CPU_HZ

// An enabled event whose class and spec both equal the delivered ones fires:
// mode 0x2000 marks it ready, mode 0x1000 calls its function if it has one.
deliver_event :: proc(class, spec: u32) {
	for &e in events_tab {
		if e.status != EV_ENABLED || e.class != class || e.spec != spec {
			continue
		}
		switch e.mode {
		case EV_MODE_READY:
			e.status = EV_READY
		case EV_MODE_CALLBACK:
			if e.func != 0 {
				hle_call(e.func)
			}
		}
	}
}

// UnDeliverEvent: a ready mode 0x2000 event of this class and spec goes
// back to enabled. v0 is left as it was; the retail kernel leaves a
// pointer into its event table there.
@(private)
undeliver_event :: proc(class, spec: u32) {
	for &e in events_tab {
		if e.status == EV_READY && e.mode == EV_MODE_READY && e.class == class && e.spec == spec {
			e.status = EV_ENABLED
		}
	}
}

// Call guest code from HLE without disturbing the caller's registers.
@(private)
hle_call :: proc(addr: u32) {
	saved := cpu.state
	cpu.call(addr)
	cycles := cpu.state.cycles
	cpu.state = saved
	cpu.state.cycles = cycles
}

// ---------------------------------------------------------------- interrupts

// Run the game's interrupt handler the way the BIOS would: switch to the
// registers saved by setjmp in the HookEntryInt buffer and enter the code that
// follows that setjmp's "returned nonzero" branch. libetc places a call to its
// dispatcher (trapIntr) there; on hardware that dispatcher ends in
// ReturnFromException, which only flags the end here, so it simply returns.
// The hook is skipped when a chain handler ended the exception first.
deliver_irq :: proc() {
	target: u32 = 0
	if bios.hook != 0 {
		target = hook_target(cpu.r32(bios.hook))
	}
	if .Irq in core.trace.active {
		core.tracef(.Irq, "deliver stat=%x mask=%x hook=%x", io.irq_regs.stat, io.irq_regs.mask, target)
	}
	saved_cpu := cpu.state
	saved_sr := cpu.cop0.sr
	// Exception entry: push the interrupt-enable stack, disabling interrupts.
	cpu.cop0.sr = (cpu.cop0.sr & ~u32(0x3f)) | ((cpu.cop0.sr << 2) & 0x3c)
	io.irq_regs.in_handler = true
	bios.rfe = false
	run_int_chains()
	if target != 0 && !bios.rfe {
		buf := bios.hook
		cpu.state.r[29] = cpu.r32(buf + 4)
		cpu.state.r[30] = cpu.r32(buf + 8)
		for i in u32(0) ..< 8 {
			cpu.state.r[16 + i] = cpu.r32(buf + 12 + i * 4)
		}
		cpu.state.r[28] = cpu.r32(buf + 44)
		cpu.state.r[2] = 1
		cpu.call(target)
	}
	io.irq_regs.in_handler = false
	bios.rfe = false
	cycles := cpu.state.cycles
	cpu.state = saved_cpu
	cpu.state.cycles = cycles
	cpu.cop0.sr = saved_sr
}

// SysEnqIntRP chains, highest priority (0) first. Each element is
// {next, second, first, unused}: first() runs on every interrupt and, when it
// returns nonzero, second(result) runs. libpad polls the pad from one. The
// kernel's own handlers, enqueued at boot, sit at the tails: the root counter
// ones in chain 1, the IRQ event one in chain 3. ReturnFromException in any
// handler ends the walk.
@(private)
run_int_chains :: proc() {
	for head, pri in bios.chains {
		e := head
		for guard := 0; e != 0 && guard < 64; guard += 1 {
			first := cpu.r32(e + 8)
			second := cpu.r32(e + 4)
			next := cpu.r32(e)
			if first != 0 {
				cpu.call(first)
				if v := cpu.state.r[2]; v != 0 && second != 0 && !bios.rfe {
					cpu.state.r[4] = v
					cpu.call(second)
				}
				if bios.rfe {
					return
				}
			}
			e = next
		}
		switch pri {
		case 1:
			rcnt_irqs()
		case 2:
			sio0_irq()
		case 3:
			irq_events()
		}
		if bios.rfe {
			return
		}
	}
}

// IRQ bits of root counters 0-2 and vblank (counter 3).
@(private)
RCNT_IRQS :: [4]u32{4, 5, 6, 0}

// The kernel's root counter handlers, vblank first, then timers 2, 1, 0:
// each pending one delivers event 0xf2000000+n spec 2 and, with
// ChangeClearRCnt's flag set, acknowledges the IRQ and ends the exception.
@(private)
rcnt_irqs :: proc() {
	irqs := RCNT_IRQS
	for n := 3; n >= 0; n -= 1 {
		bit := u32(1) << irqs[n]
		if io.irq_regs.stat & io.irq_regs.mask & bit == 0 {
			continue
		}
		deliver_event(0xf2000000 + u32(n), 2)
		if bios.rcnt_ack[n] {
			io.irq_regs.stat &~= bit
			bios.rfe = true
			return
		}
	}
}

// StartPAD and StartCARD enqueue the pad driver's vblank handler in chain 2
// and hand the vblank acknowledge from the root counter handler to it;
// StartPAD also acknowledges a pending vblank. StopPAD and StopCARD undo
// both. The handler sits at the tail of chain 2 here, behind any element
// the game enqueued before it.
@(private)
sio0_start :: proc(ack_vblank: bool) {
	if ack_vblank {
		io.irq_regs.stat &~= 1
	}
	io.irq_regs.mask |= 1
	bios.sio0 = true
	bios.pad_ack = true
	bios.rcnt_ack[3] = false
}

@(private)
sio0_stop :: proc() {
	bios.sio0 = false
	bios.rcnt_ack[3] = true
}

// The pad driver's vblank handler: the pads themselves are read by the
// host every vblank (bios_pad_vblank), so only the acknowledge is left,
// unless ChangeClearPad or _remove_ChgclrPAD turned it off.
@(private)
sio0_irq :: proc() {
	if !bios.sio0 || io.irq_regs.stat & io.irq_regs.mask & 1 == 0 {
		return
	}
	if bios.pad_ack && cpu.r32(PAD_DRIVER + PAD_ACK_CODE) != 0 {
		io.irq_regs.stat &~= 1
	}
}

// IRQ number and event class of the kernel's IRQ event handler, in its
// order. Timer 2 delivers timer 1's class, as on the retail kernel.
@(private)
IRQ_EVENTS :: [11][2]u32 {
	{2, 0xf0000003},
	{9, 0xf0000009},
	{1, 0xf0000002},
	{10, 0xf000000a},
	{8, 0xf000000b},
	{0, 0xf0000001},
	{4, 0xf0000005},
	{5, 0xf0000006},
	{6, 0xf0000006},
	{7, 0xf0000008},
	{3, 0xf0000004},
}

// Each pending IRQ delivers its class with spec 0x1000. The game
// acknowledges them; the walk goes on to the hook.
@(private)
irq_events :: proc() {
	events := IRQ_EVENTS
	for ev in events {
		if io.irq_regs.stat & io.irq_regs.mask & (u32(1) << ev[0]) != 0 {
			deliver_event(ev[1], 0x1000)
		}
	}
}

// SysEnqIntRP pushes at the head. An element already in the chain moves to
// the head instead of being linked twice; the retail kernel would link the
// head to itself and loop.
@(private)
int_chain_enqueue :: proc(pri, elem: u32) {
	if pri >= len(bios.chains) {
		return
	}
	int_chain_dequeue(pri, elem)
	cpu.w32(elem, bios.chains[pri])
	bios.chains[pri] = elem
}

// SysDeqIntRP: the element unlinked, or 0 when it is not in the chain.
@(private)
int_chain_dequeue :: proc(pri, elem: u32) -> u32 {
	if pri >= len(bios.chains) {
		return 0
	}
	if bios.chains[pri] == elem {
		bios.chains[pri] = cpu.r32(elem)
		return elem
	}
	e := bios.chains[pri]
	for guard := 0; e != 0 && guard < 64; guard += 1 {
		if cpu.r32(e) == elem {
			cpu.w32(e, cpu.r32(elem))
			return elem
		}
		e = cpu.r32(e)
	}
	return 0
}

// The setjmp return site is `beqz v0, X; nop; jal T`: the handler is T.
@(private)
hook_target :: proc(ra: u32) -> u32 {
	for k in u32(0) ..< 4 {
		w := cpu.r32(ra + k * 4)
		if w >> 26 == 0x03 {
			return ((ra + k * 4) & 0xf0000000) | ((w & 0x3ffffff) << 2)
		}
	}
	fmt.eprintfln("bios: HookEntryInt return site %#08x has no handler call", ra)
	return 0
}

// ---------------------------------------------------------------- threads

@(private)
MAX_THREADS :: 16

@(private)
Bios_Thread :: struct {
	used:  bool,
	regs:  cpu.Cpu,
	sr:    u32,
	entry: u32,
	co:    ^core.Coroutine,
}

@(private)
threads: [MAX_THREADS]Bios_Thread

// Index of the running thread; 0 is the main thread (handle 0xff000000).
@(private)
cur_thread: int

// Coroutine of a thread that closed itself. It keeps running until it
// switches away; the next thread to run then discards it.
@(private)
zombie: ^core.Coroutine

@(private)
reap_zombie :: proc() {
	if zombie != nil {
		core.co_kill(zombie)
		zombie = nil
	}
}

@(private)
threads_init :: proc() {
	threads[0] = {
		used = true,
		co   = &core.co_main_thread,
	}
	cur_thread = 0
}

@(private)
open_thread :: proc(pc, sp, gp: u32) -> u32 {
	for &t, i in threads {
		if t.used {
			continue
		}
		t = {
			used  = true,
			entry = pc,
			// The BIOS stores 0x40000404 and enters the thread with rfe;
			// threads[].sr holds the live value after that rfe.
			sr    = 0x40000401,
		}
		t.regs.r[29] = sp
		t.regs.r[30] = sp
		t.regs.r[28] = gp
		t.co = core.co_create(thread_entry, rawptr(uintptr(i)))
		return 0xff000000 | u32(i)
	}
	fmt.eprintln("bios: thread table full")
	return 0xffffffff
}

@(private)
thread_entry :: proc(arg: rawptr) {
	i := int(uintptr(arg))
	reap_zombie()
	cpu.call(threads[i].entry)
	cpu.fatal("thread %d returned from its entry %#08x", i, threads[i].entry)
}

@(private)
close_thread :: proc(h: u32) -> u32 {
	i := int(h & 0xffff)
	if i == 0 || i >= MAX_THREADS || !threads[i].used {
		return 0
	}
	if i == cur_thread {
		zombie = threads[i].co
	} else {
		core.co_kill(threads[i].co)
	}
	threads[i] = {}
	return 1
}

@(private)
change_thread :: proc(h: u32) {
	i := int(h & 0xffff)
	if i >= MAX_THREADS || !threads[i].used {
		fmt.eprintfln("bios: ChangeTh to bad handle %#x", h)
		ret(0)
		return
	}
	if i == cur_thread {
		ret(1)
		return
	}
	from := &threads[cur_thread]
	to := &threads[i]
	ret(1)
	// A thread that closed itself has no slot to save into; OpenTh may even
	// have reused it. Any other zombie was reaped when this thread resumed.
	if zombie == nil {
		from.regs = cpu.state
		from.sr = cpu.cop0.sr
	}
	cycles := cpu.state.cycles
	cpu.state = to.regs
	cpu.state.cycles = cycles
	cpu.cop0.sr = to.sr
	cur_thread = i
	core.co_switch(to.co)
	// Resumed: whoever switched back already loaded our registers.
	reap_zombie()
}
