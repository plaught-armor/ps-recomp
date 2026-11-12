// EE kernel HLE test: a thread that ends with ExitDeleteThread frees its
// slot, so a create/start/exit-delete loop runs for longer than there are
// thread ids and keeps getting the same id back. It is freed also when it
// was the last runnable thread, and the kernel idles on its coroutine until
// an alarm wakes another. _print formats its arguments from registers. Last,
// a program patches one word of its own text and ExecPS2s into itself: every
// other thread, semaphore, handler and alarm is gone, the scratchpad is
// zeroed, the function table is off, and SetupThread hands it the arguments;
// with the word back, ExecPS2 runs the native function again. Before that,
// LOADFILE's loadelf (an IOP RPC, the EE's SifLoadElf) loads ELFs from a disc
// directory: the segments' file bytes or one section, and nothing for a bad
// ELF or one out of range. SifDmaStat reports a transfer running for its
// size's worth of cycles after SifSetDma, then done, and an older id or a
// failed set's 0 as done. LOADFILE's version handshake answers with the
// version in the LOADFILE of the IOPRP image an IOP reset loads, and "3000"
// with no image or no version in it. The EE timers fire their compare and
// overflow events at the cycle the count gets there, raising their INTC only
// when the flag was clear; a flag clears where T_MODE is written 1, and
// T_ZRET resets the count at compare. SetVTLBRefillHandler and
// SetVCommonHandler store a handler only for their own causes and return it,
// or 0 for a cause out of range. SetVSyncFlag's flag and CSR pointers are
// stored through once, by the next vblank start interrupt taken, and the CSR
// only with a flag pointer. EnableCache and DisableCache set and clear Config's
// bits 16 and 17 by their mask's low two bits, in every thread's copy.
// FlushCache of the instruction cache leaves the function table on while each
// recompiled function's first word is the boot program's and turns it off,
// until an exec, once one changed; a data-cache flush checks nothing.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import cpu "ps:ps2/cpu"
import iop "ps:ps2/iop"
import kernel "ps:ps2/kernel"
import mem "ps:ps2/mem"
import "ps:core"

ENTRY :: 0x00100000
IDLER :: ENTRY + 4 // a thread that blocks nobody but exits as the last one runnable
ALARM :: ENTRY + 8 // its alarm handler, which wakes the main thread
EXEC :: ENTRY + 12 // the program that ExecPS2s into itself
PATCH :: ENTRY + 0x80 // the word of its text it changes
PARAM :: 0x00200000
STACK :: 0x00300000
LOOPS :: 1000 // well past the 256 thread ids

ran: int
execs: int // runs of EXEC, native or interpreted
other: i64 // a thread ExecPS2 ends

sys :: proc(n: u32, a0: u32 = 0, a1: u32 = 0, a2: u32 = 0, a3: u32 = 0) -> i64 {
	cpu.state.r[3].d[0] = u64(n)
	cpu.state.r[4].d[0] = u64(a0)
	cpu.state.r[5].d[0] = u64(a1)
	cpu.state.r[6].d[0] = u64(a2)
	cpu.state.r[7].d[0] = u64(a3)
	kernel.syscall(ENTRY)
	return i64(cpu.state.r[2].d[0])
}

// The thread's entry: count the run, then ExitDeleteThread.
worker :: proc() {
	ran += 1
	sys(0x24)
	fmt.eprintln("fail: ExitDeleteThread returned")
	os.exit(1)
}

idler :: proc() {
	ran += 1
	sys(0x18, 1, ALARM) // SetAlarm: one line from now
	sys(0x24) // nothing else is ready, so the kernel idles on this thread
	fmt.eprintln("fail: ExitDeleteThread returned")
	os.exit(1)
}

alarm :: proc() {
	sys(transmute(u32)i32(-0x34), 1) // iWakeupThread(main)
}

// Native, the first run: leave a thread, a semaphore, an alarm and a handler
// behind and the scratchpad full, change a word of the text and ExecPS2 into
// itself with two arguments. The second run is native again once the word is
// back.
exec_prog :: proc() {
	execs += 1
	if execs == 3 {
		if kernel.k.exec.text_off || cpu.lookup(EXEC) == nil {fail("fail: the table is off with the text back")}
		fmt.println("ok ExecPS2")
		os.exit(0)
	}
	if execs != 1 {fail("fail: native EXEC on run %d", execs)}
	mem.wr32(PARAM + 4, ENTRY)
	mem.wr32(PARAM + 20, 100) // ready, but below the main thread
	other = sys(0x20, PARAM)
	sys(0x22, u32(other))
	mem.wr32(PARAM + 4, 1) // max_count
	if sys(0x40, PARAM) <= 0 {fail("fail: CreateSema")}
	sys(0x18, 1000, ALARM)
	sys(0x10, 2, ALARM)
	kernel.k.current.wakeups = 3
	kernel.k.current.prio = 10
	ARGV :: PARAM + 0x300
	mem.wr32(ARGV, ARGV + 0x40)
	mem.wr32(ARGV + 4, ARGV + 0x42)
	copy(mem.ram_slice(ARGV + 0x40, 5), "a\x00bc\x00")
	for &b, i in mem.spr {b = u8(i) | 1}
	mem.wr32(PATCH, 1)
	sys(7, EXEC, 0, 2, ARGV)
	fail("fail: ExecPS2 returned")
}

// The interpreter, which the second run of EXEC lands in with the table off.
exec_interp :: proc(addr: u32) {
	execs += 1
	if execs != 2 || addr != EXEC {fail("fail: interpreted %08x on run %d", addr, execs)}
	k := &kernel.k
	if !k.exec.text_off || cpu.lookup(EXEC) != nil {fail("fail: the table is on with the text changed")}
	if cpu.state.r[2].d[0] != EXEC {fail("fail: v0 %x, want the entry", cpu.state.r[2].d[0])}
	t := k.current
	if t != k.threads[1] || t.prio != 0 || t.wakeups != 0 {fail("fail: thread %d prio %d wakeups %d", t.id, t.prio, t.wakeups)}
	if k.threads[other] != nil || k.thread_end != 2 {fail("fail: thread %d still allocated", other)}
	for s in k.semas {if s != nil {fail("fail: semaphore %d left", s.id)}}
	if len(k.intc) != 0 || len(k.alarms) != 0 {fail("fail: %d handlers, %d alarms left", len(k.intc), len(k.alarms))}
	if k.exec.dead_co != nil {fail("fail: the old program's coroutine not freed")}
	for x, i in mem.spr {if x != 0 {fail("fail: scratchpad byte %x left %x", i, x)}}
	ARGS :: PARAM + 0x400
	sys(0x3c, 0, STACK, 0x1000, ARGS) // SetupThread
	if mem.rd32(ARGS) != 2 {fail("fail: argc %d", mem.rd32(ARGS))}
	for want, n in ([2]string{"a", "bc"}) {
		s, _ := kernel.guest_string(mem.rd32(ARGS + 4 + u32(n) * 4), 16)
		if s != want {fail("fail: argv[%d] %q, want %q", n, s, want)}
	}
	mem.wr32(PATCH, 0)
	sys(7, EXEC)
	fail("fail: ExecPS2 returned")
}

LOAD :: 0x00400000 // the test ELF's segment
LOAD_ENTRY :: LOAD + 0x40
SECT :: 0x00410000 // its section outside the segment
FILL :: 0xaa

// An ELF of one PT_LOAD segment (16 file bytes at LOAD, memsz 32) and the
// sections .text (the segment's bytes) and .extra (8 bytes at SECT).
test_elf :: proc() -> []u8 {
	e := make([]u8, 0x140 + 4 * 40)
	w32 := proc(e: []u8, o: int, v: u32) {for i in 0 ..< 4 {e[o + i] = u8(v >> (8 * uint(i)))}}
	w16 := proc(e: []u8, o: int, v: u32) {e[o], e[o + 1] = u8(v), u8(v >> 8)}
	copy(e, "\x7fELF\x01\x01\x01")
	w16(e, 16, 2) // ET_EXEC
	w16(e, 18, 8) // EM_MIPS
	w32(e, 20, 1)
	w32(e, 24, LOAD_ENTRY)
	w32(e, 28, 0x34) // phoff
	w32(e, 32, 0x140) // shoff
	w16(e, 40, 52)
	w16(e, 42, 32)
	w16(e, 44, 1)
	w16(e, 46, 40)
	w16(e, 48, 4)
	w16(e, 50, 3) // .shstrtab
	w32(e, 0x34, 1) // PT_LOAD
	w32(e, 0x38, 0x100)
	w32(e, 0x3c, LOAD)
	w32(e, 0x44, 16)
	w32(e, 0x48, 32)
	for i in 0 ..< 24 {e[0x100 + i] = u8(i + 1)}
	names := "\x00.text\x00.extra\x00.shstrtab\x00"
	copy(e[0x120:], names)
	Sh :: struct {name, addr, off, size: u32}
	for sh, n in ([3]Sh{{1, LOAD, 0x100, 16}, {7, SECT, 0x110, 8}, {14, 0, 0x120, u32(len(names))}}) {
		o := 0x140 + (n + 1) * 40
		w32(e, o, sh.name)
		w32(e, o + 12, sh.addr)
		w32(e, o + 16, sh.off)
		w32(e, o + 20, sh.size)
	}
	return e
}

// One loadelf call; the reply's 4 words, over a buffer that held others.
loadelf_call :: proc(path, section: string) -> [4]u32 {
	buf: [0x200]u8
	w := ([^]u32)(&buf[0])
	for i in 0 ..< 4 {w[i] = 0xdeadbeef}
	copy(buf[8:], path)
	copy(buf[0x104:], section)
	if !iop.sif.servers[0x80000006](1, buf[:], len(buf)) {fail("fail: loadelf unhandled")}
	return {w[0], w[1], w[2], w[3]}
}

// RAM [a, a+n) all FILL: nothing was loaded there.
untouched :: proc(a, n: u32) -> bool {
	for b in mem.ram[a:][:n] {if b != FILL {return false}}
	return true
}

timer_test :: proc() {
	CUE :: mem.T_CUE
	CMPE :: mem.T_CMPE
	OVFE :: mem.T_OVFE
	ZRET :: mem.T_ZRET
	mode :: proc(n: u32) -> u32 {return mem.hw_reg(0x800 * n + 0x10)^}
	at :: proc(c: u64) {
		cpu.state.cycles = c
		mem.timer_events(c)
	}
	c0 := cpu.state.cycles
	mem.intc_stat = 0

	// Timer 0, bus clock (2 cycles a tick): compare at count 100.
	mem.timer_write(0, 0x00, 0)
	mem.timer_write(0, 0x20, 100)
	mem.timer_write(0, 0x10, CUE | CMPE)
	if mem.timer_next[0] != c0 + 200 {fail("fail: timer 0 compare at %d, want %d", mem.timer_next[0], c0 + 200)}
	if cpu.next_event > c0 + 200 {fail("fail: next_event %d past the timer's compare", cpu.next_event)}
	kernel.update_next_event()
	if cpu.next_event > c0 + 200 {fail("fail: update_next_event %d misses the timer", cpu.next_event)}
	at(c0 + 199)
	if mode(0) & mem.T_EQUF != 0 || mem.intc_stat != 0 {fail("fail: timer 0 compared a cycle early")}
	at(c0 + 200)
	if mode(0) & mem.T_EQUF == 0 {fail("fail: timer 0 compare set no flag")}
	if mem.intc_stat != 1 << 9 {fail("fail: timer 0 compare raised INTC %x", mem.intc_stat)}
	if mem.timer_count(0) != 100 {fail("fail: timer 0 count %d without ZRET, want 100", mem.timer_count(0))}
	// Written 0 the flag stays, written 1 it clears; the count carries on.
	mem.timer_write(0, 0x10, CUE | CMPE)
	if mode(0) & mem.T_EQUF == 0 {fail("fail: writing 0 cleared timer 0's flag")}
	mem.timer_write(0, 0x10, CUE | CMPE | mem.T_EQUF)
	if mode(0) & mem.T_EQUF != 0 {fail("fail: writing 1 left timer 0's flag")}
	if mem.timer_count(0) != 100 {fail("fail: a T_MODE write moved the count to %d", mem.timer_count(0))}

	// Timer 1, bus/16 (32 cycles a tick): overflow 16 ticks after 0xfff0.
	c1 := c0 + 200
	mem.intc_stat = 0
	mem.timer_write(1, 0x00, 0xfff0)
	mem.timer_write(1, 0x10, 1 | CUE | OVFE)
	if mem.timer_next[1] != c1 + 16 * 32 {fail("fail: timer 1 overflow at %d, want %d", mem.timer_next[1], c1 + 16 * 32)}
	at(c1 + 16 * 32)
	if mode(1) & mem.T_OVFF == 0 || mem.intc_stat != 1 << 10 {fail("fail: timer 1 overflow: mode %x INTC %x", mode(1), mem.intc_stat)}
	if mem.timer_count(1) != 0 {fail("fail: timer 1 count %d after overflow", mem.timer_count(1))}

	// Timer 2: ZRET at count 10 starts over from 0, and its second compare,
	// with the flag still set, raises no INTC.
	c2 := c1 + 16 * 32
	mem.intc_stat = 0
	mem.timer_write(2, 0x00, 0)
	mem.timer_write(2, 0x20, 10)
	mem.timer_write(2, 0x10, CUE | CMPE | ZRET)
	at(c2 + 20)
	if mode(2) & mem.T_EQUF == 0 || mem.intc_stat != 1 << 11 {fail("fail: timer 2 compare: mode %x INTC %x", mode(2), mem.intc_stat)}
	if mem.timer_count(2) != 0 {fail("fail: timer 2 count %d after ZRET, want 0", mem.timer_count(2))}
	if mem.timer_next[2] != c2 + 40 {fail("fail: timer 2 next compare at %d, want %d", mem.timer_next[2], c2 + 40)}
	mem.intc_stat = 0
	at(c2 + 40)
	if mem.intc_stat != 0 {fail("fail: timer 2 raised INTC with its flag set")}

	// Off again, flags cleared, for the tests after.
	for n in u32(0) ..< 3 {mem.timer_write(n, 0x10, mem.T_EQUF | mem.T_OVFF)}
	for t in mem.timer_next {if t != max(u64) {fail("fail: a stopped timer still has an event")}}
	mem.intc_stat, mem.intc_pending = 0, 0
	fmt.println("ok EE timers")
}

loadelf_test :: proc() {
	core.host_allocator = context.allocator // no snap_init here; the loader reads the file with it
	iop.sif_init()
	dir, err := os.make_directory_temp("", "ps_loadelf_test_*", context.allocator)
	if err != nil {fail("fail: temp dir: %v", err)}
	defer if os.remove_all(dir) != nil {fmt.eprintln("loadelf: temp dir left:", dir)}
	iop.disc_dir = dir
	put :: proc(dir, name: string, e: []u8) {
		if os.write_entire_file(fmt.tprintf("%s/%s", dir, name), e) != nil {fail("fail: write %s", name)}
	}
	le32_put :: proc(e: []u8, o: int, v: u32) {for i in 0 ..< 4 {e[o + i] = u8(v >> (8 * uint(i)))}}
	good := test_elf()
	put(dir, "GOOD.ELF", good)
	// Each bad one is the good one with a field changed.
	Bad :: struct {name: string, at: int, v: u32}
	bads := [?]Bad {
		{"NOELF.ELF", 0, 0}, // no magic
		{"MACHINE.ELF", 18, 3}, // e_machine EM_386
		{"LOW.ELF", 0x3c, 0x1000}, // below the kernel's 0x80000
		{"PASTRAM.ELF", 0x3c, mem.RAM_SIZE - 8}, // ends past main RAM
		{"PHOFF.ELF", 28, 0x10000}, // program headers past the file
	}
	for b in bads {
		e := make([]u8, len(good), context.temp_allocator)
		copy(e, good)
		le32_put(e, b.at, b.v)
		put(dir, b.name, e)
	}

	ram_fill :: proc() {
		for a in ([?]u32{0x1000, LOAD, SECT, mem.RAM_SIZE - 32}) {for &b in mem.ram[a:][:32] {b = FILL}}
	}
	ram_fill()
	r := loadelf_call("cdrom0:\\GOOD.ELF;1", "all")
	if r != ([4]u32{LOAD_ENTRY, 0, 0, 0}) {fail("fail: loadelf all replied %x", r)}
	for i in 0 ..< 16 {if mem.ram[LOAD + u32(i)] != u8(i + 1) {fail("fail: loadelf all: byte %d", i)}}
	if !untouched(LOAD + 16, 16) {fail("fail: loadelf all zeroed the memsz tail")}
	if !untouched(SECT, 32) {fail("fail: loadelf all loaded a section outside its segments")}

	ram_fill()
	r = loadelf_call("cdrom0:\\GOOD.ELF;1", ".extra")
	if r != ([4]u32{}) {fail("fail: loadelf .extra replied %x", r)}
	for i in 0 ..< 8 {if mem.ram[SECT + u32(i)] != u8(0x11 + i) {fail("fail: loadelf .extra: byte %d", i)}}
	if !untouched(SECT + 8, 24) || !untouched(LOAD, 32) {fail("fail: loadelf .extra loaded more than its section")}

	ram_fill()
	for b in bads {
		r = loadelf_call(fmt.tprintf("cdrom0:\\%s;1", b.name), "all")
		if r != ([4]u32{}) {fail("fail: loadelf %s replied %x", b.name, r)}
	}
	for c in ([?][2]string{{"cdrom0:\\NONE.ELF;1", "all"}, {"host:GOOD.ELF", "all"}, {"cdrom0:\\GOOD.ELF;1", ".nope"}}) {
		r = loadelf_call(c[0], c[1])
		if r != ([4]u32{}) {fail("fail: loadelf %s %s replied %x", c[0], c[1], r)}
	}
	if !untouched(0x1000, 32) || !untouched(LOAD, 32) || !untouched(SECT, 32) || !untouched(mem.RAM_SIZE - 32, 32) {
		fail("fail: a failed loadelf wrote RAM")
	}
	fmt.println("ok loadelf")
}

// SetupThread as retail: the program's sp 0x2a0 below the top, with only
// gp, sp, fp and ra written into the context frame there, and a stack of -1
// topping out 4 KiB below the end of memory; a negative heap size ends the
// heap at the stack.
setup_test :: proc() {
	FRAME :: 0x2a0
	GP :: 0x00123450
	ROOT :: 0x00100040
	SIZE :: 0x1000
	for top in ([2]u32{STACK + SIZE, mem.RAM_SIZE - 0x1000}) {
		stack: u32 = top == STACK + SIZE ? STACK : 0xffffffff
		frame := top - FRAME
		for &b in mem.ram[frame:][:FRAME] {b = FILL}
		cpu.state.r[8].d[0] = ROOT
		if sp := u32(sys(0x3c, GP, stack, SIZE, 0)); sp != frame {fail("fail: SetupThread(%x) sp %x, want %x", stack, sp, frame)}
		want := [4]u32{GP, top - 0x20, top - 0x20, ROOT}
		for o in u32(0) ..< FRAME / 16 {
			at := frame + o * 16
			if o < 28 || o >= 32 {
				if !untouched(at, 16) {fail("fail: frame slot %d written", o)}
				continue
			}
			if got := mem.rd32(at); got != want[o - 28] {fail("fail: frame slot %d %x, want %x", o, got, want[o - 28])}
			if !untouched(at + 4, 12) {fail("fail: frame slot %d past its low word written", o)}
		}
		if end := u32(sys(0x3d, 0x00500000, 0xffffffff)); end != top - SIZE || u32(sys(0x3e)) != end {fail("fail: heap end %x, want the stack %x", end, top - SIZE)}
	}
	fmt.println("ok SetupThread")
}

// The boot program's arguments as SetupThread hands them over: argc 1 and
// argv[0] the BOOT2 value unchanged, device, backslash and `;1` kept.
boot_args_test :: proc() {
	ARGS :: PARAM + 0x400
	RAW :: "cdrom0:\\SLUS_123.45;1"
	kernel.exec_boot_args(RAW)
	sys(0x3c, 0, STACK, 0x1000, ARGS) // SetupThread
	if argc := mem.rd32(ARGS); argc != 1 {fail("fail: boot argc %d, want 1", argc)}
	if s, _ := kernel.guest_string(mem.rd32(ARGS + 4), 64); s != RAW {fail("fail: boot argv[0] %q, want %q", s, RAW)}
	fmt.println("ok boot arguments")
}

// SifSetDma (0x77) of one 0x1000-byte transfer, then SifDmaStat (0x76).
dma_stat_test :: proc() {
	LIST :: PARAM + 0x300
	for v, n in ([4]u32{PARAM, 0x40000, 0x1000, 0}) {mem.wr32(LIST + u32(n) * 4, v)}
	first := sys(0x77, LIST, 1)
	id := sys(0x77, LIST, 1)
	if id <= 0 || first <= 0 {fail("fail: SifSetDma returned %d, %d", first, id)}
	if st := sys(0x76, u32(id)); st < 0 {fail("fail: SifDmaStat %d right after the set, want >= 0", st)}
	if st := sys(0x76, u32(first)); st != -1 {fail("fail: SifDmaStat of an older id %d, want -1", st)}
	if st := sys(0x76, 0); st != -1 {fail("fail: SifDmaStat of id 0 %d, want -1", st)}
	cpu.state.cycles += 2 * 0x1000 * iop.SIF_DMA_CYCLES_PER_BYTE
	if st := sys(0x76, u32(id)); st != -1 {fail("fail: SifDmaStat %d after the transfer's cycles, want -1", st)}
	fmt.println("ok SifDmaStat")
}

// SetVSyncFlag (0x73): the next vblank start interrupt taken stores 1 through
// the flag pointer and the GS CSR through the other, once.
vsync_flag_test :: proc() {
	FLAG :: PARAM + 0x400
	CSR :: PARAM + 0x408
	MARK :: 0x1122334455667788
	vblank :: proc() {
		mem.intc_raise(mem.INTC_VBLANK_START)
		kernel.deliver_interrupts()
	}
	mark :: proc() {
		mem.wr64(FLAG, MARK)
		mem.wr64(CSR, MARK)
	}
	status, mask, csr := cpu.state.cop0[12], mem.intc_mask, mem.gs_csr
	mem.intc_pending = 0
	mem.gs_csr = 0x2008
	want := u64(0x551b2008)
	mark()
	sys(0x73, FLAG, CSR)
	if kernel.k.vsync_flag != FLAG || kernel.k.vsync_csr != CSR {fail("fail: SetVSyncFlag kept %x, %x", kernel.k.vsync_flag, kernel.k.vsync_csr)}

	// Not taken: masked in INTC_MASK, then interrupts off.
	cpu.state.cop0[12] |= 0x10001
	mem.intc_mask = 0
	vblank()
	mem.intc_mask = 1 << mem.INTC_VBLANK_START
	cpu.state.cop0[12] &~= 1
	vblank()
	if mem.rd64(FLAG) != MARK || mem.rd64(CSR) != MARK {fail("fail: a vblank not taken stored %x, %x", mem.rd64(FLAG), mem.rd64(CSR))}
	if kernel.k.vsync_flag != FLAG || kernel.k.vsync_csr != CSR {fail("fail: a vblank not taken cleared the pointers")}

	// The pointers are kernel state a snapshot holds: they come back with it.
	saved := kernel.k
	sys(0x73, 0, 0)
	kernel.k = saved

	// Taken: 32 bits of 1, 64 bits of CSR, both pointers cleared.
	cpu.state.cop0[12] |= 1
	mem.intc_pending = 0
	vblank()
	if got := mem.rd64(FLAG); got != MARK &~ 0xffffffff | 1 {fail("fail: the flag reads %x, want 32 bits of 1", got)}
	if got := mem.rd64(CSR); got != want {fail("fail: CSR stored as %x, want %x", got, want)}
	if kernel.k.vsync_flag != 0 || kernel.k.vsync_csr != 0 {fail("fail: pointers %x, %x after the vblank, want 0", kernel.k.vsync_flag, kernel.k.vsync_csr)}

	// A second vblank stores nothing.
	mark()
	vblank()
	if mem.rd64(FLAG) != MARK || mem.rd64(CSR) != MARK {fail("fail: the second vblank stored %x, %x", mem.rd64(FLAG), mem.rd64(CSR))}

	// No flag pointer: CSR is not stored.
	sys(0x73, 0, CSR)
	low := mem.rd64(0)
	vblank()
	if mem.rd64(CSR) != MARK {fail("fail: CSR stored with no flag pointer: %x", mem.rd64(CSR))}
	if mem.rd64(0) != low {fail("fail: a store through a null flag pointer")}

	// No CSR pointer: only the flag.
	sys(0x73, FLAG, 0)
	vblank()
	if mem.rd32(FLAG) != 1 || mem.rd64(CSR) != MARK || mem.rd64(0) != low {fail("fail: flag %x, CSR %x with no CSR pointer", mem.rd32(FLAG), mem.rd64(CSR))}
	if kernel.k.vsync_flag != 0 {fail("fail: flag pointer kept with no CSR pointer")}

	sys(0x73, 0, 0)
	mem.intc_pending = 0
	cpu.state.cop0[12], mem.intc_mask, mem.gs_csr = status, mask, csr
	fmt.println("ok SetVSyncFlag")
}

// SetVTLBRefillHandler (0x0d) takes causes 1-3, SetVCommonHandler (0x0e)
// causes 4-13; each returns the handler it stored, or 0 and stores nothing.
exc_handler_test :: proc() {
	FN :: 0x00140000
	for n in u32(0) ..= 15 {
		for sc in ([2]u32{0x0d, 0x0e}) {
			fn := FN + n * 0x10 + sc
			before := n <= kernel.EXC_LAST ? kernel.k.exc_handlers[n] : 0
			want: u32 = 0
			if sc == 0x0d && n >= 1 && n <= 3 || sc == 0x0e && n >= 4 && n <= 13 {want = fn}
			if got := sys(sc, n, fn); got != i64(want) {fail("fail: syscall %x cause %d returned %x, want %x", sc, n, got, want)}
			if n > kernel.EXC_LAST {continue}
			after := kernel.k.exc_handlers[n]
			if want != 0 && after != fn {fail("fail: syscall %x cause %d stored %x, want %x", sc, n, after, fn)}
			if want == 0 && after != before {fail("fail: syscall %x cause %d changed the table to %x", sc, n, after)}
		}
	}
	// A second call replaces the first, still returning the new handler.
	if got := sys(0x0e, 9, FN); got != FN || kernel.k.exc_handlers[9] != FN {fail("fail: replacing cause 9 returned %x", got)}
	fmt.println("ok exception handlers")
}

// EnableCache (0x61) sets Config's bits 16 and 17 by the mask's bits 0 and 1,
// DisableCache (0x62) clears them; the rest of Config and of the mask is left
// alone, and a thread not running reads the same Config when it next runs.
cache_test :: proc() {
	CONFIG :: 16
	ICE_DCE :: 3 << 16
	c := &cpu.state.cop0[CONFIG]
	c^ = 0x0440 // some other bits, which stay
	mem.wr32(PARAM + 4, ENTRY)
	mem.wr32(PARAM + 20, 100) // below the main thread: it does not run here
	parked := kernel.k.threads[sys(0x20, PARAM)]
	sys(0x22, u32(parked.id))
	sys(0x61, 0xfffffffe)
	if c^ != 0x0440 | 2 << 16 {fail("fail: EnableCache(2) left Config %x", c^)}
	sys(0x61, 1)
	if c^ != 0x0440 | ICE_DCE || sys(0x63, CONFIG) != i64(c^) {fail("fail: EnableCache(1) left Config %x", c^)}
	if parked.regs.cop0[CONFIG] != c^ {fail("fail: a parked thread's Config is %x, want %x", parked.regs.cop0[CONFIG], c^)}
	sys(0x62, 0xfffffffd)
	if c^ != 0x0440 | 2 << 16 {fail("fail: DisableCache(1) left Config %x", c^)}
	sys(0x62, 3)
	if c^ != 0x0440 || parked.regs.cop0[CONFIG] != c^ {fail("fail: DisableCache(3) left Config %x", c^)}
	sys(0x25, u32(parked.id))
	sys(0x21, u32(parked.id))
	c^ = 0
	fmt.println("ok EnableCache, DisableCache")
}

// An IOP reset to `path`, a packet SifSetDma (0x77) sends to the IOP's
// command buffer, then LOADFILE's version handshake (fno 255).
// An instruction-cache FlushCache (modes 2 and 3) with the functions' first
// words as booted keeps the table, whatever else in the range changed: a
// word past a function's first, a word no function holds. With a first
// word changed (code loaded over the program, no exec) it turns the table
// off, and a later flush with the word back does not turn it on. A
// data-cache flush (modes 0 and 1) checks nothing. The state is the
// kernel's, so a copy of it brings the table back as it was.
flush_text_test :: proc() {
	e := &kernel.k.exec
	saved := kernel.k
	sys(0x64, 2)
	sys(0x68, 3)
	if e.text_off || cpu.lookup(EXEC) == nil {fail("fail: FlushCache turned the table off with the text unchanged")}
	mem.wr32(PATCH, 1)
	mem.wr32(ENTRY + 0xfc, 1)
	sys(0x64, 2)
	sys(0x68, 3)
	if e.text_off || cpu.lookup(EXEC) == nil {fail("fail: FlushCache turned the table off for a word that starts no function")}
	mem.wr32(PATCH, 0)
	mem.wr32(ENTRY + 0xfc, 0)
	was := mem.rd32(EXEC)
	mem.wr32(EXEC, was + 1)
	sys(0x64, 0)
	sys(0x68, 1)
	if e.text_off || cpu.lookup(EXEC) == nil {fail("fail: a data-cache FlushCache turned the table off")}
	sys(0x64, 2)
	if !e.text_off {fail("fail: FlushCache did not mark the text changed")}
	if cpu.lookup(EXEC) != nil {fail("fail: FlushCache left the table on with the text changed")}
	off := kernel.k
	mem.wr32(EXEC, was)
	sys(0x68, 3)
	if !e.text_off || cpu.lookup(EXEC) != nil {fail("fail: a later FlushCache turned the table back on")}
	// As a snapshot's load does (kernel_snap): the table follows text_off.
	kernel.k = saved
	cpu.dispatch_set(!e.text_off)
	if e.text_off || cpu.lookup(EXEC) == nil {fail("fail: the state from before the flush left the table off")}
	kernel.k = off
	cpu.dispatch_set(!e.text_off)
	if !e.text_off || cpu.lookup(EXEC) != nil {fail("fail: the state from after the flush left the table on")}
	kernel.k = saved
	cpu.dispatch_set(!e.text_off)
	fmt.println("ok FlushCache text check")
}
reset_version :: proc(path: string) -> string {
	LIST :: PARAM + 0x300
	PKT :: PARAM + 0x400
	for &b in mem.ram_slice(PKT, 0x100) {b = 0}
	mem.wr32(PKT + 8, iop.SIF_CMD_RESET)
	copy(mem.ram_slice(PKT + 24, 0x100 - 24), path)
	for v, n in ([4]u32{PKT, iop.IOP_CMDBUF, 0x100, 0}) {mem.wr32(LIST + u32(n) * 4, v)}
	if sys(0x77, LIST, 1) <= 0 {fail("fail: SifSetDma of the reset failed")}
	buf: [16]u8
	if !iop.sif.servers[0x80000006](255, buf[:], 4) {fail("fail: loadfile fno 255 unhandled")}
	return strings.clone(string(buf[:4]), context.temp_allocator)
}

// IOPRP images built here: a ROMDIR table of RESET, ROMDIR, a placeholder
// module and LOADFILE, whose bytes are placeholders around the version.
loadfile_version_test :: proc() {
	dir, err := os.make_directory_temp("", "ps_ioprp_test_*", context.allocator)
	if err != nil {fail("fail: temp dir: %v", err)}
	defer if os.remove_all(dir) != nil {fmt.eprintln("ioprp: temp dir left:", dir)}
	iop.disc_dir = dir
	image :: proc(dir, name: string, loadfile: []u8) {
		Entry :: struct {name: string, size: int}
		entries := [?]Entry{{"RESET", 0}, {"ROMDIR", 5 * 16}, {"OTHER", 0x23}, {"LOADFILE", len(loadfile)}}
		img: [dynamic]u8
		defer delete(img)
		for e in entries {
			row: [16]u8
			copy(row[:10], e.name)
			(^u32)(&row[12])^ = u32(e.size)
			append(&img, ..row[:])
		}
		append(&img, ..make([]u8, 16, context.temp_allocator)) // the zero name ending the table
		other := make([]u8, 0x30, context.temp_allocator) // 0x23 bytes, aligned
		for &b in other[:0x23] {b = 0xee}
		append(&img, ..other)
		append(&img, ..loadfile)
		if os.write_entire_file(fmt.tprintf("%s/%s", dir, name), img[:]) != nil {fail("fail: write %s", name)}
	}
	with: [dynamic]u8
	defer delete(with)
	append(&with, ..make([]u8, 0x40, context.temp_allocator))
	append(&with, "PsIIloadfile3210")
	append(&with, ..make([]u8, 0x10, context.temp_allocator))
	image(dir, "NEW.IMG", with[:])
	without := make([]u8, 0x50, context.temp_allocator)
	copy(without[0x40:], "PsIIloadfileXY")
	image(dir, "OLD.IMG", without)

	Case :: struct {path, want: string}
	cases := [?]Case {
		{"rom0:UDNL cdrom0:\\NEW.IMG;1", "3210"},
		{"", "3000"}, // no image: rom0's modules again
		{"rom0:UDNL cdrom0:\\NEW.IMG;1", "3210"},
		{"rom0:UDNL cdrom0:\\OLD.IMG;1", "3000"}, // no version after the marker
		{"rom0:UDNL cdrom0:\\NONE.IMG;1", "3000"},
	}
	for c in cases {
		if got := reset_version(c.path); got != c.want {fail("fail: version after reset %q is %q, want %q", c.path, got, c.want)}
	}
	fmt.println("ok LOADFILE version")
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

main :: proc() {
	mem.mem_init()
	kernel.kernel_init()
	main_t := kernel.k.threads[1]
	main_t.co = &core.co_main_thread
	main_t.prio = 64
	cpu.text_range(ENTRY, ENTRY + 0x100)
	cpu.register(ENTRY, worker)
	cpu.register(IDLER, idler)
	cpu.register(ALARM, alarm)
	cpu.register(EXEC, exec_prog)
	cpu.interp_hook = exec_interp
	kernel.exec_boot()

	mem.wr32(PARAM + 4, ENTRY)
	mem.wr32(PARAM + 8, STACK)
	mem.wr32(PARAM + 12, 0x1000)
	mem.wr32(PARAM + 20, 1) // runs ahead of the main thread
	first: i64 = -1
	for i in 0 ..< LOOPS {
		id := sys(0x20, PARAM) // CreateThread
		if id <= 0 {fail("fail: CreateThread returned %d on loop %d", id, i)}
		if first < 0 {first = id}
		if id != first {fail("fail: loop %d got id %d, want %d", i, id, first)}
		sys(0x22, u32(id)) // StartThread: the worker runs and deletes itself
		if kernel.k.threads[id] != nil {fail("fail: thread %d still allocated", id)}
	}
	if ran != LOOPS {fail("fail: worker ran %d times, want %d", ran, LOOPS)}
	if kernel.k.dead != nil {fail("fail: deleted thread not freed")}
	fmt.println("ok exit-delete", LOOPS, "threads, id", first)

	// The main thread sleeps, leaving the idler as the only thread, and the
	// slot it frees is reused at once.
	mem.wr32(PARAM + 4, IDLER)
	mem.wr32(PARAM + 20, 100) // runs only once the main thread sleeps
	ran = 0
	for i in 0 ..< 3 {
		id := sys(0x20, PARAM)
		if id != first {fail("fail: idle loop %d got id %d, want %d", i, id, first)}
		sys(0x22, u32(id))
		if ran != i {fail("fail: idler ran before the main thread slept")}
		sys(0x32) // SleepThread: the alarm wakes us
		if ran != i + 1 {fail("fail: idler ran %d times, want %d", ran, i + 1)}
		if kernel.k.threads[id] != nil {fail("fail: idler %d still allocated", id)}
		if kernel.k.dead != nil {fail("fail: idler not freed after the main thread resumed")}
	}
	fmt.println("ok exit-delete while idle")

	// _print: the format in a0, then a1-a3 and t0-t3.
	FMT :: PARAM + 0x100
	STR :: PARAM + 0x200
	f := "%s %d %u %08x %-3c| %lx %% %X %d\n"
	copy(mem.ram_slice(FMT, u32(len(f)) + 1), f)
	copy(mem.ram_slice(STR, 4), "ab\x00\x00")
	args := [7]u64{STR, u64(transmute(u32)i32(-5)), 0xffffffff, 0xbeef, 'z', 0x123456789, 0xabc}
	for v, n in args {cpu.state.r[5 + n].d[0] = v}
	want := "ab -5 4294967295 0000beef z  | 123456789 % ABC ?\n"
	if got := kernel.print_format(f, 5); got != want {fail("fail: _print gave %q, want %q", got, want)}
	// The guest controls the format: widths clamp, %n and unknown
	// conversions are copied out, and a pointer past RAM prints `?`.
	f = "%99999d|%s|%.1s|%n|%q"
	args = {7, 0x0f000000, STR, 0, 0, 0, 0}
	for v, n in args {cpu.state.r[5 + n].d[0] = v}
	want = fmt.tprintf("%64d|?|a|%%n|%%q", 7)
	if got := kernel.print_format(f, 5); got != want {fail("fail: _print gave %q, want %q", got, want)}
	sys(0x75, FMT) // must print, not stop the run
	sys(0x75, 0x0f000000) // a format past RAM prints `?`
	fmt.println("ok _print")

	timer_test()
	loadelf_test()
	setup_test()
	boot_args_test()
	dma_stat_test()
	exc_handler_test()
	cache_test()
	flush_text_test()
	vsync_flag_test()
	loadfile_version_test()

	// ExecPS2 frees the coroutine the program ran on, so it is not the host's.
	main_t.co = core.co_create(proc(_: rawptr) {exec_prog()}, nil)
	core.co_switch(main_t.co)
	fail("fail: the program's coroutine returned")
}
