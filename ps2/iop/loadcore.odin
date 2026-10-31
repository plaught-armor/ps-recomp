// loadcore: loading IRX modules onto the IOP's R3000, linking their imports
// and running their start, behind PS_IRX=1.
//
// A module's imports go one of three ways:
// - to a Sony library (iop_sony): the stub stays as linked, `jr ra; addiu
//   zero, zero, fno`, and its address goes into the stub map. psx_cpu asks
//   bios_entry (iop_hle_entry) before it runs a call, so a call to the stub
//   runs the HLE function instead. The stub's words never run.
// - to a library a loaded module registered (RegisterLibraryEntries): the
//   stub becomes `j export; nop`, as retail loadcore patches it.
// - to a library nobody registered yet: pending, and in the stub map too, so
//   a call before a module registers it is a compat row, not garbage in v0.
//   RegisterLibraryEntries patches the pending stubs it satisfies.
//
// A start runs as a thread (thread.odin), synchronously, within a fixed
// budget of instructions shared with the threads that run after it returns.
// It fails when it calls an HLE function that does not exist (a compat row
// names it), uses an import nobody registered, waits with no thread ready,
// or runs out of the budget. A failed load is undone: the libraries it
// registered, the stubs it patched or mapped, the threads and semaphores it
// made and the memory it allocated, its own image included. What it wrote to
// memory stays. A path whose load failed is not run again until a library
// registers or a load succeeds, either of which may let it link.
package ps2_iop

import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "ps:core"
import cpu "../cpu"
import r3000 "ps:psx/cpu"

// Instructions a load's start and threads may run before they are taken
// to spin. Fixed, so a spinning start fails at the same point every run.
IOP_START_BUDGET :: 1 << 23
IOP_START_STACK :: 0x2000

KE_OK :: 0
KE_ERROR :: -1
KE_LIBRARY_FOUND :: -212
KE_LIBRARY_NOTFOUND :: -213

// What a start returns in its low 2 bits.
RESIDENT_END :: 0
NO_RESIDENT_END :: 1

// The Sony modules and libraries: what a LOADFILE does not run, and the
// imports the HLE serves. Module and library names only, as the PS2SDK's
// export tables (iop/*/src/exports.tab) and module sources name them.
// Matched ignoring case.
IOP_SONY := [?]string {
	"sysmem", "loadcore", "excepman", "intrman", "ssbusc", "dmacman", "timrman",
	"sysclib", "heaplib", "thbase", "thevent", "thsemap", "thmsgbx", "thfpool",
	"thvpool", "thrdman", "vblank", "stdio", "sifman", "sifcmd", "secrman",
	"loadfile", "modload", "ioman", "iomanx", "cdvdman", "cdvdfsv", "sio2man",
	"padman", "mtapman", "mcman", "mcserv", "libsd", "sdrdrv", "usbd", "dev9",
	"rmman", "siftool", "reboot", "eesync",
}

Iop_Lib :: struct {
	name:    [8]u8,
	version: u16,
	table:   u32, // the export table's address
	count:   u32, // its functions
	owner:   u32, // the module that registered it
}

Iop_Import :: struct {
	name:    [8]u8,
	version: u16,
	stub:    u32,
	fno:     u32,
}

Hle_Stub :: struct {
	name:    [8]u8,
	fno:     u32,
	pending: bool, // a library nobody registered yet, else a Sony one
}

Iop_Module :: struct {
	id, base, size: u32,
	argv:           u32, // its argument block
}

Iop_Patch :: struct {
	stub:  u32,
	words: [2]u32, // as they were
}

// Emulated state, in the emu heap: snapshotted (sif_snap).
iop_loader: struct {
	libs:    [dynamic]Iop_Lib,
	pending: [dynamic]Iop_Import,
	stubs:   map[u32]Hle_Stub, // by physical address
	modules: [dynamic]Iop_Module,
	next_id: u32,
	// During a load: its module, whether it failed, the stubs it patched,
	// and the loader's state before it, which a failure restores.
	loading: u32,
	failed:  bool,
	patches: [dynamic]Iop_Patch,
	undo:    struct {
		libs:    [dynamic]Iop_Lib,
		pending: [dynamic]Iop_Import,
		stubs:   map[u32]Hle_Stub,
		blocks:  [dynamic]Sys_Block,
	},
	// The paths whose load failed, cloned; true once a retry has said so.
	failed_paths: map[string]bool,
}

// PS_IRX=1: LOADFILE runs the modules it loads. Host setting, read at init.
iop_irx: bool

// The first id of a module run here: LOADFILE has always answered 2 for a
// module it does not run.
@(private = "file")
IOP_FIRST_ID :: 3

iop_loader_init :: proc() {
	iop_irx = core.env("IRX") == "1"
	clear(&iop_loader.libs)
	clear(&iop_loader.pending)
	clear(&iop_loader.stubs)
	clear(&iop_loader.modules)
	iop_loader.next_id = IOP_FIRST_ID
	iop_loader.loading = 0
	iop_loader.failed = false
	failed_paths_clear()
	th_init()
	iop_sifcmd = {}
	iop_sd = {}
}

@(private = "file")
failed_paths_clear :: proc() {
	for p in iop_loader.failed_paths {delete(p)}
	clear(&iop_loader.failed_paths)
}

iop_sony :: proc(name: string) -> bool {
	for s in IOP_SONY {
		if strings.equal_fold(s, name) {return true}
	}
	return false
}

// Whether LOADFILE runs IRX file `data`: not when it is no IRX, nor a Sony
// module by its name or by a library it exports.
iop_runs :: proc(data: []u8) -> bool {
	x := irx_parse(data) or_return
	if iop_sony(x.name) {return false}
	text := data[x.file_off:][:min(x.text_size, x.file_size)]
	for &t in irx_tables(text, 0, context.temp_allocator) {
		if !t.imports && iop_sony(lib_name(&t.name)) {return false}
	}
	return true
}

// A table name: up to 8 characters, NUL-padded.
@(private = "file")
lib_name :: proc(n: ^[8]u8) -> string {
	return strings.truncate_to_byte(string(n[:]), 0)
}

@(private = "file")
phys :: #force_inline proc(a: u32) -> u32 {
	return a & 0x1fffffff
}

r32 :: proc(a: u32) -> u32 {
	return iop_u32(a & (IOP_RAM_SIZE - 1))^
}

w32 :: proc(a, v: u32) {
	iop_u32(a & (IOP_RAM_SIZE - 1))^ = v
}

// Loads IRX file `data` (none of it in the block it is loaded to), links it
// and runs its start with `args`, NUL-separated after argv[0] `path`. The
// module's id and what its start returned, or KE_ERROR.
iop_load :: proc(data: []u8, path: string, args: []u8) -> (id: i32, result: u32) {
	x, ok := irx_parse(data)
	if !ok {
		fmt.eprintfln("iop: \"%s\" is no IRX", path)
		return KE_ERROR, 0
	}
	l := &iop_loader
	if told, again := l.failed_paths[path]; again {
		if !told {
			fmt.eprintfln("iop: \"%s\" failed before, not run again", path)
			l.failed_paths[path] = true
		}
		return KE_ERROR, 0
	}
	s := &iop_sched
	mark_th, mark_sema := s.next_thid, s.next_semid
	fail :: proc(path, name, why: string, mark_th, mark_sema: u32) -> (i32, u32) {
		fmt.eprintfln("iop: load of \"%s\" failed: %s", name, why)
		th_undo(mark_th, mark_sema)
		undo_restore()
		iop_loader.failed_paths[strings.clone(path)] = false
		return KE_ERROR, 0
	}
	undo_save()
	defer iop_wake_set()
	clear(&l.patches)
	l.loading = l.next_id
	l.failed = false
	defer l.loading = 0
	m := Iop_Module {
		id   = l.next_id,
		size = irx_mem_size(x),
	}
	m.base = sys_alloc(.Low, m.size)
	if m.base == 0 {return fail(path, x.name, "no memory", mark_th, mark_sema)}
	img := iop_mem(m.base, m.size)
	copy(img, data[x.file_off:][:x.file_size])
	slice.zero(img[x.file_size:])
	if err, detail := irx_relocate(data, img, m.base); err != .None {
		if err == .Type {core.compat_unknown(.Irx_Reloc, detail)}
		return fail(path, x.name, fmt.tprintf("relocation %v %#x", err, detail), mark_th, mark_sema)
	}
	tables := irx_tables(img[:min(x.text_size, m.size)], m.base, context.temp_allocator)
	for &t in tables {
		if t.imports {link_imports(m.base + t.off, &t)}
	}
	m.argv = argv_block(path, args)
	stack := sys_alloc(.High, IOP_START_STACK)
	if m.argv == 0 || stack == 0 {return fail(path, x.name, "no memory", mark_th, mark_sema)}
	st := th_new(m.base + x.entry, stack, IOP_START_STACK, m.base + x.gp, IOP_START_PRIO)
	st.start, st.exit_delete = true, true
	st.ctx.r[4] = r32(m.argv)
	st.ctx.r[5] = m.argv + 4
	th_ready(st)
	s.start_done = false
	iop_sync(cpu.state.cycles)
	th_schedule(r3000.state.cycles + IOP_START_BUDGET * r3000.CYCLES_PER_INSN)
	if !s.start_done && s.budget {
		core.compat_unknown(.Iop_Start, core.compat_name(x.name))
		return fail(path, x.name, "start ran out of its budget", mark_th, mark_sema)
	}
	if !s.start_done {
		core.compat_unknown(.Iop_Blocked, core.compat_name(x.name))
		return fail(path, x.name, "start waits with no thread ready", mark_th, mark_sema)
	}
	if l.failed {return fail(path, x.name, "start called what the HLE lacks", mark_th, mark_sema)}
	if s.budget {
		// The start returned, so the load succeeds; the threads it left ready
		// stay so, their context saved, for a later load to run on.
		core.compat_unknown(.Iop_Threads, core.compat_name(x.name))
		fmt.eprintfln("iop: threads of \"%s\" ran out of the budget", x.name)
	}
	failed_paths_clear()
	l.next_id += 1
	result = s.start_result
	if result & 3 == NO_RESIDENT_END {
		module_drop(m)
	} else {
		append(&l.modules, m)
	}
	if cpu.debug >= 1 {fmt.eprintfln("iop: \"%s\" at %x id %d start %x", x.name, m.base, m.id, result)}
	return i32(m.id), result
}

// {argc, argv[]...} then the strings: argv[0] the path, the rest `args`.
@(private = "file")
argv_block :: proc(path: string, args: []u8) -> u32 {
	n := u32(1)
	for b in args {if b == 0 {n += 1}}
	if len(args) > 0 && args[len(args) - 1] != 0 {n += 1}
	size := 4 + 4 * (n + 1) + u32(len(path)) + 1 + u32(len(args)) + 1
	a := sys_alloc(.High, size)
	if a == 0 {return 0}
	slice.zero(iop_mem(a, size))
	w32(a, n)
	s := a + 4 + 4 * (n + 1)
	w32(a + 4, s)
	copy(iop_mem(s, u32(len(path))), path)
	s += u32(len(path)) + 1
	k := u32(1)
	start := 0
	for i in 0 ..= len(args) {
		if i < len(args) && args[i] != 0 {continue}
		if i > start {
			w32(a + 4 + 4 * k, s)
			copy(iop_mem(s, u32(i - start)), args[start:i])
			s += u32(i - start) + 1
			k += 1
		}
		start = i + 1
	}
	w32(a, k)
	return a
}

@(private = "file")
link_imports :: proc(table: u32, t: ^Irx_Table) {
	l := &iop_loader
	name := lib_name(&t.name)
	for k in 0 ..< t.count {
		stub := table + 20 + 8 * k
		fno := r32(stub + 4) & 0xffff
		if lib, ok := lib_find(name, t.version); ok {
			link_stub(stub, lib, fno)
		} else if iop_sony(name) {
			l.stubs[phys(stub)] = {t.name, fno, false}
		} else {
			append(&l.pending, Iop_Import{t.name, t.version, stub, fno})
			l.stubs[phys(stub)] = {t.name, fno, true}
		}
	}
}

@(private = "file")
lib_find :: proc(name: string, version: u16) -> (lib: Iop_Lib, ok: bool) {
	for &b in iop_loader.libs {
		if lib_name(&b.name) == name && b.version >> 8 == version >> 8 {return b, true}
	}
	return
}

// Patches `stub` to jump to function fno of `lib`; a function the library
// lacks leaves it pending.
@(private = "file")
link_stub :: proc(stub: u32, lib: Iop_Lib, fno: u32) -> bool {
	l := &iop_loader
	if fno >= lib.count {
		l.stubs[phys(stub)] = {lib.name, fno, true}
		return false
	}
	f := r32(lib.table + 20 + 4 * fno)
	append(&l.patches, Iop_Patch{stub, {r32(stub), r32(stub + 4)}})
	w32(stub, 0x08000000 | (f >> 2) & 0x3ffffff)
	w32(stub + 4, 0)
	delete_key(&l.stubs, phys(stub))
	return true
}

// Forgets a module whose start returned NO_RESIDENT_END: its memory, the
// stubs in it and the libraries it registered. Stubs of other modules
// patched to those stay patched, as on retail.
@(private = "file")
module_drop :: proc(m: Iop_Module) {
	l := &iop_loader
	in_m :: proc(a: u32, m: Iop_Module) -> bool {return phys(a) >= m.base && phys(a) - m.base < m.size}
	for i := len(l.pending) - 1; i >= 0; i -= 1 {
		if in_m(l.pending[i].stub, m) {ordered_remove(&l.pending, i)}
	}
	for i := len(l.libs) - 1; i >= 0; i -= 1 {
		if l.libs[i].owner == m.id {ordered_remove(&l.libs, i)}
	}
	drop: [dynamic]u32
	drop.allocator = context.temp_allocator
	for a in l.stubs {
		if in_m(a, m) {append(&drop, a)}
	}
	for a in drop {delete_key(&l.stubs, a)}
	sys_free(m.base)
	sys_free(m.argv)
}

@(private = "file")
undo_save :: proc() {
	u := &iop_loader.undo
	clear(&u.libs)
	append(&u.libs, ..iop_loader.libs[:])
	clear(&u.pending)
	append(&u.pending, ..iop_loader.pending[:])
	clear(&u.blocks)
	append(&u.blocks, ..sys_blocks[:])
	clear(&u.stubs)
	for a, s in iop_loader.stubs {u.stubs[a] = s}
}

@(private = "file")
undo_restore :: proc() {
	l := &iop_loader
	#reverse for p in l.patches {
		w32(p.stub, p.words[0])
		w32(p.stub + 4, p.words[1])
	}
	clear(&l.patches)
	clear(&l.libs)
	append(&l.libs, ..l.undo.libs[:])
	clear(&l.pending)
	append(&l.pending, ..l.undo.pending[:])
	clear(&sys_blocks)
	append(&sys_blocks, ..l.undo.blocks[:])
	clear(&l.stubs)
	for a, s in l.undo.stubs {l.stubs[a] = s}
}

// ------------------------------------------------------------- the HLE

// psx_cpu's bios_entry: whether `addr` is a stub the HLE serves, and with
// `run` the call.
iop_hle_entry :: proc(addr: u32, run: bool) -> bool {
	s, ok := iop_loader.stubs[phys(addr)]
	if !ok {return false}
	if run {hle_call(addr, s)}
	return true
}

@(private = "file")
hle_call :: proc(addr: u32, s: Hle_Stub) {
	s := s
	r := &r3000.state.r
	name := lib_name(&s.name)
	if s.pending {
		core.compat_unknown(.Iop_Import, core.compat_name(name), pc = addr, ra = r[31])
		fmt.eprintfln("iop: call to %s fno %d, which no module registered", name, s.fno)
	} else if v, ok := hle_fn(name, s.fno); ok {
		r[2] = v
		if iop_sched.resched {th_preempt()}
		return
	} else {
		core.compat_unknown(.Iop_Call, core.compat_name(name), s.fno, pc = addr, ra = r[31])
		fmt.eprintfln("iop: %s fno %d not implemented", name, s.fno)
	}
	r[2] = ke(KE_ERROR)
	th_call_failed()
}

// An error code as v0 holds it.
ke :: proc(e: i32) -> u32 {
	return u32(e)
}

// Function fno of Sony library `name`, reading a0..a3; v0, or false when the
// HLE lacks it. Numbers as the PS2SDK's export tables order them.
@(private = "file")
hle_fn :: proc(name: string, fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2 := r[4], r[5], r[6]
	switch name {
	case "sysmem":
		switch fno {
		case 4: // AllocSysMemory(type, size, addr)
			if a0 > u32(Sys_Alloc.Addr) {return 0, true}
			return sys_alloc(Sys_Alloc(a0), a1, phys(a2)), true
		case 5: // FreeSysMemory(addr)
			return sys_free(phys(a0)) ? KE_OK : ke(KE_ERROR), true
		case 6: // QueryMemSize
			return IOP_RAM_SIZE, true
		case 7: // QueryMaxFreeMemSize
			largest, _ := sys_free_sizes()
			return largest, true
		case 8: // QueryTotalFreeMemSize
			_, total := sys_free_sizes()
			return total, true
		case 14: // Kprintf: the IOP's debug console, which nothing shows
			return 0, true
		}
	case "loadcore":
		switch fno {
		case 4, 5: // FlushIcache, FlushDcache: no caches here
			return 0, true
		case 6: // RegisterLibraryEntries(table)
			return lib_register(a0), true
		case 7: // ReleaseLibraryEntries(table)
			l := &iop_loader
			for b, i in l.libs {
				if phys(b.table) == phys(a0) {
					ordered_remove(&l.libs, i)
					return KE_OK, true
				}
			}
			return ke(KE_LIBRARY_NOTFOUND), true
		case 12: // QueryBootMode(mode): no boot-mode records
			return 0, true
		case 27: // SetRebootTimeLibraryHandlingMode
			return KE_OK, true
		}
	case "intrman":
		switch fno {
		case 17: // CpuSuspendIntr(int *state): no interrupts to hold off
			if a0 != 0 {w32(a0, 0)}
			return KE_OK, true
		case 18: // CpuResumeIntr(state)
			return KE_OK, true
		}
	case "thbase":
		return th_base(fno)
	case "thsemap":
		return th_semap(fno)
	case "stdio":
		return stdio_fn(fno)
	case "sysclib":
		return sysclib_fn(fno)
	case "sifcmd":
		return sifcmd_fn(fno)
	case "sifman":
		return sifman_fn(fno)
	case "libsd":
		return libsd_fn(fno)
	case "cdvdman":
		return cdvdman_fn(fno)
	case "ioman":
		return ioman_fn(fno)
	}
	return 0, false
}

// Registers the export table at `a` and patches the pending stubs it
// satisfies; KE_LIBRARY_FOUND when a library of that name and major version
// is registered.
@(private = "file")
lib_register :: proc(a: u32) -> u32 {
	l := &iop_loader
	b := Iop_Lib {
		version = u16(r32(a + 8)),
		table   = a,
		owner   = l.loading,
	}
	(^[2]u32)(&b.name)^ = {r32(a + 12), r32(a + 16)}
	name := lib_name(&b.name)
	if _, dup := lib_find(name, b.version); dup {return ke(KE_LIBRARY_FOUND)}
	for b.count < 256 && r32(a + 20 + 4 * b.count) != 0 {b.count += 1}
	append(&l.libs, b)
	failed_paths_clear()
	for i := 0; i < len(l.pending); {
		p := l.pending[i]
		pn := p.name
		if lib_name(&pn) == name && p.version >> 8 == b.version >> 8 && link_stub(p.stub, b, p.fno) {
			ordered_remove(&l.pending, i)
		} else {
			i += 1
		}
	}
	return KE_OK
}

// ------------------------------------------------------------- dispatch

// psx_cpu indexes its table of recompiled functions on every call, and the
// IOP has none: an all-nil table, mapped read-only so that no path can make
// it emulated state by writing it (a write faults).
@(private = "file")
iop_fixed: []r3000.Func_Proc

iop_dispatch_init :: proc() {
	if iop_fixed == nil {
		size := uint(r3000.RAM_SIZE / 4 * size_of(r3000.Func_Proc))
		data, err := virtual.reserve_and_commit(size)
		assert(err == nil, "iop: dispatch table not mapped")
		ok := virtual.protect(raw_data(data), size, {.Read})
		assert(ok, "iop: dispatch table not made read-only")
		iop_fixed = slice.reinterpret([]r3000.Func_Proc, data)
	}
	assert(r3000.dispatch.fixed == nil || raw_data(r3000.dispatch.fixed) == raw_data(iop_fixed), "iop: PS1 functions registered")
	r3000.dispatch.fixed = iop_fixed
}
