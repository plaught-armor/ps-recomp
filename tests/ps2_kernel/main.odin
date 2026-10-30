// EE kernel HLE test: a thread that ends with ExitDeleteThread frees its
// slot, so a create/start/exit-delete loop runs for longer than there are
// thread ids and keeps getting the same id back. It is freed also when it
// was the last runnable thread, and the kernel idles on its coroutine until
// an alarm wakes another. Last, _print formats its arguments from registers.
package main

import "core:fmt"
import "core:os"
import cpu "ps:ps2/cpu"
import kernel "ps:ps2/kernel"
import mem "ps:ps2/mem"
import "ps:core"

ENTRY :: 0x00100000
IDLER :: ENTRY + 4 // a thread that blocks nobody but exits as the last one runnable
ALARM :: ENTRY + 8 // its alarm handler, which wakes the main thread
PARAM :: 0x00200000
STACK :: 0x00300000
LOOPS :: 1000 // well past the 256 thread ids

ran: int

sys :: proc(n: u32, a0: u32 = 0, a1: u32 = 0) -> i64 {
	cpu.state.r[3].d[0] = u64(n)
	cpu.state.r[4].d[0] = u64(a0)
	cpu.state.r[5].d[0] = u64(a1)
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
}
