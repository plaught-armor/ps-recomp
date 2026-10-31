// The program switches: _ExecPS2 (syscall 7) and _LoadExecPS2 (6), verified
// against the SCPH-90001 retail kernel. Both end every other thread, the
// semaphores, the interrupt handlers and the alarms, and run the new program
// on the current thread with the caller's registers (v0 = its entry); its
// crt0 picks up its arguments through SetupThread. LoadExecPS2 also clears
// user memory and loads the ELF from the disc, which retail leaves to the
// ROM's loader; the program gets the arguments that loader passes on. A new
// program over the recompiled code turns the function table off (text_check).
package ps2_kernel

import "base:intrinsics"
import "core:fmt"
import "core:hash/xxhash"
import "core:strings"
import "ps:core"
import cpu "../cpu"
import iop "../iop"
import mem "../mem"

// The arguments SetupThread hands a program: crt0's struct holds 16
// pointers and 256 bytes of strings. Retail checks neither bound.
ARGV_MAX :: 16
ARGV_BYTES :: 256

// User memory, which LoadExecPS2 clears: the kernel owns what is below.
USER_MEMORY :: 0x00080000

Exec_State :: struct {
	// The arguments, NUL-terminated strings packed.
	argc:      u32,
	args_len:  u32,
	args:      [ARGV_BYTES]u8,
	// The recompiled range's hash once the boot program is in RAM, and
	// whether it is one (text_ok false: no range, or one outside RAM).
	text_hash: u64,
	text_ok:   bool,
	// An exec found other code over the range: the table is off.
	text_off:  bool,
	// The coroutine the program ran on before an exec, freed by reap.
	dead_co:   ^core.Coroutine,
}

// Once the boot program is in RAM, before it runs (ps2 run): what text_check
// compares against. A range it cannot hash is said here, since every exec
// then interprets. A standalone blob's range ends at the first word of its
// last function (ps2 load_native), so a change past that is not seen.
exec_boot :: proc() {
	e := &k.exec
	lo, hi := cpu.text_lo, cpu.text_hi
	e.text_ok = lo < hi && hi <= mem.RAM_SIZE
	if !e.text_ok {
		fmt.eprintfln("ee: recompiled text %08x-%08x is not in RAM; a program started by ExecPS2 runs interpreted", lo, hi)
		return
	}
	e.text_hash = text_hash()
}

@(private = "file")
text_hash :: proc() -> u64 {
	return xxhash.XXH3_64_default(mem.ram[cpu.text_lo:cpu.text_hi])
}

// The boot program's arguments: argv[0] the path SYSTEM.CNF names, which
// the ROM's loader passes on as for any program it starts.
exec_boot_args :: proc(path: string) {
	args_clear()
	args_put(path, "boot")
}

// The table on when the recompiled range holds the boot program's bytes,
// else off: the second program's code, whatever of the first it keeps, runs
// interpreted. Said each time it turns.
@(private = "file")
text_check :: proc(entry: u32) {
	e := &k.exec
	same := e.text_ok && text_hash() == e.text_hash
	if same != e.text_off {return}
	e.text_off = !same
	cpu.dispatch_set(same)
	if same {
		fmt.eprintfln("ee: exec %08x: text %08x-%08x is the recompiled program again; native", entry, cpu.text_lo, cpu.text_hi)
	} else {
		fmt.eprintfln("ee: exec %08x: text %08x-%08x differs from the recompiled program; interpreting", entry, cpu.text_lo, cpu.text_hi)
	}
}

// Start the argument list over.
@(private = "file")
args_clear :: proc() {
	k.exec.argc, k.exec.args_len = 0, 0
}

@(private = "file")
args_put :: proc(s: string, what: string) {
	e := &k.exec
	if e.argc == ARGV_MAX || int(e.args_len) + len(s) + 1 > ARGV_BYTES {
		cpu.fatal("%s: arguments past %d strings or %d bytes", what, ARGV_MAX, ARGV_BYTES)
	}
	copy(e.args[e.args_len:], s)
	e.args[int(e.args_len) + len(s)] = 0
	e.args_len += u32(len(s)) + 1
	e.argc += 1
}

// The guest's argv[0..argc-1], each string read before anything is cleared.
@(private = "file")
args_guest :: proc(argc, argv: u32, what: string) {
	if argc > ARGV_MAX {cpu.fatal("%s: %d arguments, past %d", what, argc, ARGV_MAX)}
	for n in 0 ..< argc {
		s, ok := guest_string(mem.rd32(argv + n * 4), ARGV_BYTES)
		if !ok {cpu.fatal("%s: argument %d is not in RAM", what, n)}
		args_put(s, what)
	}
}

// SetupThread's half: argc at args, its pointers after, the strings at +68.
args_write :: proc(args: u32) {
	e := &k.exec
	STRINGS :: 4 + 4 * ARGV_MAX
	mem.wr32(args, e.argc)
	at: u32 = 0
	for n in 0 ..< e.argc {
		mem.wr32(args + 4 + n * 4, args + STRINGS + at)
		for e.args[at] != 0 {at += 1}
		at += 1
	}
	copy(mem.ram_slice(args + STRINGS, e.args_len), e.args[:e.args_len])
}

// What both switches end: every thread but the current one, which drops to
// priority 0 with no wakeups, the semaphores, the INTC and DMAC handlers and
// the alarms. Retail also sets GS, the timers and the scratchpad up again;
// the program's own libraries set GS and the timers, and whether the
// scratchpad is cleared is not traced, so it is left.
@(private = "file")
exec_reset :: proc(what: string) {
	if cpu.in_interrupt {cpu.fatal("%s from an interrupt handler", what)}
	reap()
	cur := k.current
	cur.wakeups = 0
	cur.prio = 0
	for &t in k.threads[:k.thread_end] {
		if t == nil || t == cur {continue}
		if t.co != nil {core.co_kill(t.co)}
		free(t)
		t = nil
	}
	k.thread_end = max(2, int(cur.id) + 1)
	for &s in k.semas {
		free(s)
		s = nil
	}
	clear(&k.intc)
	clear(&k.dmac)
	clear(&k.alarms)
	k.next_handler = 1
	k.next_alarm = 1
	k.heap_end = 0
	update_next_event()
}

// The current thread runs entry on a new coroutine; the one it ran on, with
// the old program's host frames, is freed once off it (reap).
@(private = "file")
exec_switch :: proc(entry: u32) -> ! {
	t := k.current
	text_check(entry)
	t.entry = entry
	cpu.state.r[2].d[0] = cpu.sx32(entry)
	k.exec.dead_co = t.co
	t.co = core.co_create(proc(arg: rawptr) {
		th := (^Thread)(arg)
		reap()
		cpu.call(th.entry)
		cpu.fatal("program %08x started by ExecPS2 returned", th.entry)
	}, t)
	core.co_switch(t.co)
	cpu.fatal("program replaced by ExecPS2 resumed")
}

// _ExecPS2(entry, gp, argc, argv): the program already in memory. gp is the
// new program's to set (crt0 does).
exec_ps2 :: proc(entry, argc, argv: u32) -> ! {
	args_clear()
	args_guest(argc, argv, "ExecPS2")
	exec_reset("ExecPS2")
	exec_switch(entry)
}

// _LoadExecPS2(filename, argc, argv): the ELF from the disc (only), with
// argv[0] the filename and the arguments after it. Retail tears the program
// down before its loader looks for the file, and boots the console's browser
// when it is missing or no ELF: the game is over either way.
load_exec :: proc(filename, argc, argv: u32) -> ! {
	args_clear()
	name_in, ok := guest_string(filename, ARGV_BYTES)
	if !ok {cpu.fatal("LoadExecPS2: the filename is not in RAM")}
	args_put(name_in, "LoadExecPS2")
	args_guest(argc, argv, "LoadExecPS2")
	name := strings.clone(string(k.exec.args[:len(name_in)]), context.temp_allocator)
	exec_reset("LoadExecPS2")
	iop.fileio_reset()
	colon := strings.index_byte(name, ':')
	data: []u8
	found := colon < 0 || strings.has_prefix(name, "cdrom")
	if found {data, found = iop.disc_file(name, core.host_allocator)}
	if !found {cpu.fatal("LoadExecPS2: no ELF %s (the console would boot its browser)", name)}
	user := mem.ram[USER_MEMORY:]
	intrinsics.mem_zero(raw_data(user), len(user))
	entry, loaded := mem.load_elf(data)
	delete(data, core.host_allocator)
	if !loaded {cpu.fatal("LoadExecPS2: %s is not a loadable ELF (the console would boot its browser)", name)}
	fmt.eprintfln("kernel: LoadExecPS2 %s, entry %08x", name, entry)
	exec_switch(entry)
}
