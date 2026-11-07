// The program switches: _ExecPS2 (syscall 7) and _LoadExecPS2 (6), verified
// against the SCPH-90001 retail kernel. Both end every other thread, the
// semaphores, the interrupt handlers and the alarms, zero the scratchpad,
// and run the new program on the current thread with the caller's registers
// (v0 = its entry); its crt0 picks up its arguments through SetupThread.
// LoadExecPS2 also clears user memory and loads the ELF from the disc, which
// retail leaves to the ROM's loader; the program gets the arguments that
// loader passes on. A new program over the recompiled code turns the function
// table off (text_check).
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

// Where LoadExecPS2's clear of user memory starts, up to the end of RAM.
// User memory starts at 0x80000, below is the kernel's; retail's restart
// leaves the first 8 KiB of it as they were.
LOAD_EXEC_CLEAR :: 0x00082000

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
	// The program in RAM, as mod keys name it (ps2/mod.odin): the low word
	// of the XXH3-64 of its ELF file. ExecPS2 starts code already in memory,
	// with no file to name it: the boot program (boot_prog) when the
	// recompiled range holds its bytes, else 0, unknown (so with no range,
	// always 0).
	prog:      u32,
	boot_prog: u32,
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

// The boot program, whose ELF file is elf, is the one in RAM.
exec_boot_program :: proc(elf: []u8) {
	k.exec.boot_prog = elf_id(elf)
	k.exec.prog = k.exec.boot_prog
}

@(private = "file")
elf_id :: proc(elf: []u8) -> u32 {
	return u32(xxhash.XXH3_64_default(elf))
}

// The boot program's arguments: argc 1, argv[0] the BOOT2 value as
// SYSTEM.CNF writes it (System_Cnf.argv: "cdrom0:\SLUS_123.45;1", device,
// backslash, case and `;1` kept), which the ROM's loader passes on as for
// any program it starts. Programs take their data device and directory from
// it.
exec_boot_args :: proc(argv0: string) {
	args_clear()
	args_put(argv0, "boot")
}

// The table on when the recompiled range holds the boot program's bytes,
// else off: the second program's code, whatever of the first it keeps, runs
// interpreted. Said each time it turns. same: the range holds them.
@(private = "file")
text_check :: proc(entry: u32) -> (same: bool) {
	e := &k.exec
	same = e.text_ok && text_hash() == e.text_hash
	if same != e.text_off {return}
	e.text_off = !same
	cpu.dispatch_set(same)
	if same {
		fmt.eprintfln("ee: exec %08x: text %08x-%08x is the recompiled program again; native", entry, cpu.text_lo, cpu.text_hi)
	} else {
		fmt.eprintfln("ee: exec %08x: text %08x-%08x differs from the recompiled program; interpreting", entry, cpu.text_lo, cpu.text_hi)
	}
	return
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
// the alarms; and it zeroes the scratchpad, all of it, as retail's restart
// does for both. Retail also sets GS, the timers and the FPU up again; the
// program's own libraries do that.
@(private = "file")
exec_reset :: proc(what: string) {
	if cpu.in_interrupt {cpu.fatal("%s from an interrupt handler", what)}
	if cpu.mod_depth > 0 {cpu.fatal("mod: %s in a mod's before or after hook", what)}
	// The new program runs inside no replacement.
	cpu.mod_inner, cpu.mod_inners = nil, {}
	// Nor inside any interpreted call.
	cpu.interp_top, cpu.interp_tops = nil, {}
	cpu.learned_top, cpu.learned_tops = nil, {}
	reap()
	cur := k.current
	cur.wakeups = 0
	cur.prio = 0
	for &t in k.threads[:k.thread_end] {
		if t == nil || t == cur {continue}
		when !core.FLAT {if t.co != nil {core.co_kill(t.co)}}
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
	mem.spr = {}
	update_next_event()
}

// The current thread runs entry on a new coroutine; the one it ran on, with
// the old program's host frames, is freed once off it (reap). Under FLAT,
// the thread's run starts over at entry, and this returns. file is the id
// of the new program's ELF file (elf_id), nil when it has none (ExecPS2).
@(private = "file")
exec_switch :: proc(entry: u32, file: Maybe(u32)) {
	t := k.current
	same := text_check(entry)
	id, named := file.?
	k.exec.prog = named ? id : same ? k.exec.boot_prog : 0
	t.entry = entry
	cpu.state.r[2].d[0] = cpu.sx32(entry)
	when core.FLAT {
		if flat.nest_depth > 0 {cpu.fatal("program switch to %08x in a nested guest call", entry)}
		flat_start(t, entry, .Exec)
	} else {
		k.exec.dead_co = t.co
		t.co = core.co_create(proc(arg: rawptr) {
			th := (^Thread)(arg)
			reap()
			cpu.thread_call(th.entry)
			cpu.fatal("program %08x started by ExecPS2 returned", th.entry)
		}, t)
		core.co_switch(t.co)
		cpu.fatal("program replaced by ExecPS2 resumed")
	}
}

// _ExecPS2(entry, gp, argc, argv): the program already in memory. gp is the
// new program's to set (crt0 does).
exec_ps2 :: proc(entry, argc, argv: u32) {
	args_clear()
	args_guest(argc, argv, "ExecPS2")
	exec_reset("ExecPS2")
	exec_switch(entry, nil)
}

// _LoadExecPS2(filename, argc, argv): the ELF from the disc (only), with
// argv[0] the filename and the arguments after it. Retail tears the program
// down before its loader looks for the file, and boots the console's browser
// when it is missing or no ELF: the game is over either way.
load_exec :: proc(filename, argc, argv: u32) {
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
	user := mem.ram[LOAD_EXEC_CLEAR:]
	intrinsics.mem_zero(raw_data(user), len(user))
	entry, loaded := mem.load_elf(data)
	prog := elf_id(data)
	delete(data, core.host_allocator)
	if !loaded {cpu.fatal("LoadExecPS2: %s is not a loadable ELF (the console would boot its browser)", name)}
	fmt.eprintfln("kernel: LoadExecPS2 %s, entry %08x", name, entry)
	exec_switch(entry, prog)
}
