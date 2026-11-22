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
//
// A start can load modules itself, through modload: LoadModuleBuffer links
// an image as a module not yet started, and StartModule runs its start as a
// thread of its own while the caller waits, as retail's modload does. Each
// start under way is a frame (Load_Frame). Only the EE's load has an undo:
// nothing else runs while it fails. A StartModule's start runs among other
// ready threads, so one that fails drops only its module: its image, its
// argument block, the blocks its start thread allocated and the threads
// running on them, and the RPC queues and servers there; its caller sees
// KE_ERROR.
package ps2_iop

import "core:fmt"
import "core:hash/xxhash"
@(require) import "core:mem/virtual" // unused on wasi
import "core:slice"
import "core:strings"
import "ps:core"
import cpu "../cpu"
import r3000 "ps:psx/cpu"

// Instructions a load's start and threads may run before they are taken
// to spin. Fixed, so a spinning start fails at the same point every run.
IOP_START_BUDGET :: 1 << 23
// Rounds of a start's loop, each a slice or an idle step to the next wake
// or interrupt due: a bound past any budget's slices, for a callback that
// stays due without the clock moving.
IOP_START_ROUNDS :: 1 << 16
#assert(IOP_START_ROUNDS > IOP_START_BUDGET * r3000.CYCLES_PER_INSN / IOP_SLICE * 4)
IOP_START_STACK :: 0x2000

KE_OK :: 0
KE_ERROR :: -1

// What a start returns in its low 2 bits.
RESIDENT_END :: 0
NO_RESIDENT_END :: 1
REMOVABLE_RESIDENT_END :: 2 // resident, and StopModule may stop it

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
	"rmman", "siftool", "reboot", "eesync", "cdvdstm", "dbcman", "sio2d",
	"ds1o_d", "ds2o", "ds2o_d", "ds2u", "ds2u_d", "mc2_d", "mc2_s1",
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
	version: u16, // a Sony one's, as the import names it
}

Iop_Module :: struct {
	id, base, size: u32,
	argv:           u32, // its argument block, 0 until its start is made
	entry, gp:      u32, // absolute
	started:        bool, // its start was made (StartModule refuses a second)
	removable:      bool, // its start returned REMOVABLE_RESIDENT_END
	stopped:        bool, // a StopModule's stop returned NO_RESIDENT_END
	hash:           u64, // its file's, for failed_key
	name:           [32]u8, // its module info's, NUL-padded, cut at 32
}

Iop_Patch :: struct {
	stub:  u32,
	words: [2]u32, // as they were
}

// The state before a load, which its failure restores (undo_restore): the
// loader's, sysmem's, the handlers sifcmd, libsd and sdrdrv hold, the
// timers, cdvdman's callback, the RPC servers and queues, the user table's
// words and which fds were open.
Load_Undo :: struct {
	libs:    [dynamic]Iop_Lib,
	pending: [dynamic]Iop_Import,
	stubs:   map[u32]Hle_Stub,
	modules: [dynamic]Iop_Module,
	next_id: u32,
	blocks:  [dynamic]Sys_Block,
	sifcmd:  Iop_Sifcmd,
	sif_tab: [dynamic]u32,
	sd:      Iop_Sd,
	sdr:     Iop_Sdr,
	timr:    Iop_Timr,
	cd:      Iop_Cd,
	vbl:     Iop_Vblank,
	rpc:     Iop_Rpc,
	open:    [dynamic]bool, // by fd
}

// A start under way: the EE's load (iop_load) or a StartModule a thread
// called. Its module and start thread, who waits for it, and whether the
// start failed.
Load_Frame :: struct {
	id:        u32, // the module
	thid:      u32, // its start's thread, 0 until made
	waiter:    u32, // StartModule's caller; 0 for the EE's load
	result_at: u32, // where StartModule puts the start's result, 0 for nowhere
	ee:        bool, // the EE's load, else a StartModule
	failed:    bool,
	gaps:      u32, // the HLE calls the start made that failed
	result:    u32, // what the start returned
}

// The most starts under way at once: an EE load, the StartModule its start
// calls, the one that start calls, and so on.
IOP_LOAD_DEPTH :: 8

// Emulated state, in the emu heap: snapshotted (sif_snap).
iop_loader: struct {
	libs:         [dynamic]Iop_Lib,
	pending:      [dynamic]Iop_Import,
	stubs:        map[u32]Hle_Stub, // by physical address
	modules:      [dynamic]Iop_Module,
	next_id:      u32,
	// The starts under way, oldest first; `loading` is the newest's module,
	// 0 when none is.
	frames:       [IOP_LOAD_DEPTH]Load_Frame,
	depth:        int,
	loading:      u32,
	// The EE load's undo, while it runs: the state before it, the threads,
	// semaphores and event flags it may make (th_mark), and the stubs patched
	// since, its StartModules' included.
	ee_undo:      Load_Undo,
	ee_mark:      Th_Mark,
	ee_patches:   [dynamic]Iop_Patch,
	// The images whose load failed, keyed by failed_key.
	failed_paths: map[string]Failed_Path,
}

// An image whose load failed: how often, whether it may run again (a library
// registered or a load succeeded since its last failure), and whether a
// refusal has said so.
Failed_Path :: struct {
	fails: u8,
	retry: bool,
	told:  bool,
}

// The most times one path's load fails: past it the path never runs again,
// whatever registers, so a game that reloads a failing module costs at most
// this many starts of it.
IOP_LOAD_FAILS :: 3

// The most HLE calls one start makes that fail: a start goes on past one,
// to find what else it lacks, but one looping on a call is stopped here.
IOP_START_GAPS :: 64

// On by default: LOADFILE runs the modules it loads. PS_IRX=0 turns it
// off (every module answered as loaded, none run). Host setting, read at init.
iop_irx: bool

// The first id of a module run here: LOADFILE has always answered 2 for a
// module it does not run.
@(private = "file")
IOP_FIRST_ID :: 3

iop_loader_init :: proc() {
	iop_irx = core.env("IRX") != "0"
	clear(&iop_loader.libs)
	clear(&iop_loader.pending)
	clear(&iop_loader.stubs)
	clear(&iop_loader.modules)
	iop_loader.next_id = IOP_FIRST_ID
	iop_loader.depth = 0
	iop_loader.loading = 0
	failed_paths_clear()
	th_init()
	iop_sifcmd = {}
	iop_sd = {}
	iop_sdr = {}
	iop_timr = {}
	iop_cd = {}
	iop_vbl = {}
	iop_rpc = {}
}

// The failed_paths key of an image loaded as `path`, `hash` its bytes'
// (XXH3): two builds of one module under one name are two images.
@(private = "file")
failed_key :: proc(path: string, hash: u64, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s#%016x", path, hash, allocator = allocator)
}

// Whether the image of `key` is not run again: it failed IOP_LOAD_FAILS
// times, or since nothing registered or loaded. Said once; each refusal is
// an Iop_Fallback row.
@(private = "file")
failed_refused :: proc(key, name: string) -> bool {
	l := &iop_loader
	f, again := l.failed_paths[key]
	if !again || f.retry && f.fails < IOP_LOAD_FAILS {return false}
	if !f.told {
		fmt.eprintfln("iop: \"%s\" failed before, not run again", name)
		f.told = true
		l.failed_paths[key] = f
	}
	core.compat_unknown(.Iop_Fallback, core.compat_name(name))
	return true
}

// The image of `key` failed: an Iop_Fallback row, and it is not run again
// until failed_paths_retry.
@(private = "file")
failed_add :: proc(key, name: string) {
	core.compat_unknown(.Iop_Fallback, core.compat_name(name))
	paths := &iop_loader.failed_paths
	f, again := paths[key]
	f.fails += 1
	f.retry = false
	if again {paths[key] = f} else {paths[strings.clone(key)] = f}
}

@(private = "file")
failed_paths_clear :: proc() {
	for p in iop_loader.failed_paths {delete(p)}
	clear(&iop_loader.failed_paths)
}

// Lets each failed path run again, up to IOP_LOAD_FAILS: what it lacked may
// be here now.
@(private = "file")
failed_paths_retry :: proc() {
	for _, &f in iop_loader.failed_paths {f.retry = true}
}

iop_sony :: proc(name: string) -> bool {
	for s in IOP_SONY {
		if strings.equal_fold(s, name) {return true}
	}
	return false
}

// Whether LOADFILE runs IRX file `data`: not when it is no IRX, nor a Sony
// module by its name (spaces around it ignored) or by a library it exports.
iop_runs :: proc(data: []u8) -> bool {
	x := irx_parse(data) or_return
	if iop_sony(strings.trim_space(x.name)) {return false}
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
// module's id and what its start returned, or KE_ERROR. A load that fails,
// or is refused as one that failed before, raises an Iop_Fallback row:
// LOADFILE answers it as it does a module it does not run, and its servers
// are left to the HLE.
iop_load :: proc(data: []u8, path: string, args: []u8) -> (id: i32, result: u32) {
	x, ok := irx_parse(data)
	if !ok {
		fmt.eprintfln("iop: \"%s\" is no IRX", path)
		return KE_ERROR, 0
	}
	// A module info can hold an empty name; its lines and rows go by the path
	if x.name == "" {x.name = path}
	core.compat_code_load()
	l := &iop_loader
	hash := xxhash.XXH3_64_default(data)
	key := failed_key(path, hash)
	if failed_refused(key, x.name) {return KE_ERROR, 0}
	if l.depth == IOP_LOAD_DEPTH {
		fmt.eprintfln("iop: load of \"%s\" refused: %d starts under way", x.name, l.depth)
		core.compat_unknown(.Iop_Fallback, core.compat_name(x.name))
		return KE_ERROR, 0
	}
	s := &iop_sched
	fail :: proc(key, name, why: string) -> (i32, u32) {
		load_ee_fail(key, name, why)
		return KE_ERROR, 0
	}
	defer iop_wake_set()
	f := frame_push(l.next_id, ee = true)
	l.next_id += 1
	m, why := module_link(data, x, f.id)
	if why != "" {return fail(key, x.name, why)}
	m.hash = hash
	f.thid = module_start(&m, path, args)
	if f.thid == 0 {return fail(key, x.name, "no memory")}
	why = ee_start_run(x.name)
	if why != "" {return fail(key, x.name, why)}
	failed_paths_retry()
	frame_pop(frame_ee())
	result = s.start_result
	m.started = true
	m.removable = result & 3 == REMOVABLE_RESIDENT_END
	if result & 3 == NO_RESIDENT_END {
		module_drop(m)
	} else {
		append(&l.modules, m)
	}
	core.gamedata_irx(strings.truncate_to_byte(string(m.name[:]), 0), m.base, m.size, m.hash)
	if cpu.debug >= 1 {fmt.eprintfln("iop: \"%s\" at %x id %d start %x", x.name, m.base, m.id, result)}
	return i32(m.id), result
}

// Runs the EE's frame, its start thread made, to the thread's return: the
// start of iop_load and the stop of iop_stop. Why it failed, "" when it did
// not. A start out of its budget, blocked, or leaving threads ready past
// the budget raises its row, by `name`, the module's.
@(private = "file")
ee_start_run :: proc(name: string) -> string {
	s := &iop_sched
	s.start_done = false
	iop_sync(cpu.state.cycles)
	// In slices, so the interrupt handlers due meanwhile run between them as
	// iop_tick runs them, by the IOP's clock, the EE's standing still over
	// the load: a start can spin on what a voice transfer's handler sets, or
	// sleep on a thread that waits for cdvdman's read callback. With no
	// thread ready, the clock moves to the next wake or interrupt due, as it
	// does between iop_ticks; the start is blocked only when none is due
	// before the budget's end. Each slice end schedules as iop_tick's does,
	// so a thread whose wake passed takes over there, not at the start's end.
	end := r3000.state.cycles + IOP_START_BUDGET * r3000.CYCLES_PER_INSN
	slices := 0
	for _ in 0 ..< IOP_START_ROUNDS {
		th_schedule(min(end, r3000.state.cycles + IOP_SLICE), idle = true)
		slices += 1
		if r3000.state.cycles >= end || (s.start_done && load_ee_failed()) {break}
		if !s.budget {
			if s.start_done {break}
			next := iop_next_ee()
			if next >= end * IOP_EE_RATIO {break}
			iop_sync(next + IOP_EE_RATIO - 1) // up to the IOP cycle it falls in
		}
		iop_intr_run(r3000.state.cycles * IOP_EE_RATIO)
	}
	if slices > 1 {fmt.eprintfln("iop: start of \"%s\" ran %d slices", name, slices)}
	if !s.start_done && s.budget {
		core.compat_unknown(.Iop_Start, core.compat_name(name))
		return "start ran out of its budget"
	}
	if !s.start_done {
		core.compat_unknown(.Iop_Blocked, core.compat_name(name))
		return "start waits with no thread ready"
	}
	if load_ee_failed() {return "start called what the HLE lacks"}
	if s.budget {
		// The start returned, so the load succeeds; the threads it left ready
		// stay so, their context saved, for a later load to run on.
		core.compat_unknown(.Iop_Threads, core.compat_name(name))
		fmt.eprintfln("iop: threads of \"%s\" ran out of the budget", name)
	}
	return ""
}

// Links IRX file `data`, module info `x`, as module `id`: its image
// allocated low, copied, relocated and its imports linked. Why it failed, ""
// when it did not; a failed link frees the image and links nothing.
@(private = "file")
module_link :: proc(data: []u8, x: Irx, id: u32) -> (m: Iop_Module, why: string) {
	size, fits := irx_mem_size(x)
	if !fits {return m, fmt.tprintf("memory size %#x", x.mem_size)}
	if cpu.debug >= 1 && size != x.text_size + x.data_size + x.bss_size {
		fmt.eprintfln("iop: \"%s\" holds %#x bytes, its module info says %#x", x.name, size, x.text_size + x.data_size + x.bss_size)
	}
	m = {
		id   = id,
		size = size,
	}
	copy(m.name[:], x.name)
	m.base = sys_alloc(.Low, m.size)
	if m.base == 0 {return m, "no memory"}
	img := iop_mem(m.base, m.size)
	copy(img, data[x.file_off:][:x.file_size])
	slice.zero(img[x.file_size:])
	if err, detail := irx_relocate(data, img, m.base); err != .None {
		if err == .Type {core.compat_unknown(.Irx_Reloc, detail)}
		sys_free(m.base)
		return m, fmt.tprintf("relocation %v %#x", err, detail)
	}
	m.entry, m.gp = m.base + x.entry, m.base + x.gp
	tables := irx_tables(img[:min(x.text_size, m.size)], m.base, context.temp_allocator)
	for &t in tables {
		if t.imports {link_imports(m.base + t.off, &t)}
	}
	return m, ""
}

// Makes module m's start thread, argv[0] `path` and then `args`, ready at
// IOP_START_PRIO. Its id, or 0 when memory ran out.
@(private = "file")
module_start :: proc(m: ^Iop_Module, path: string, args: []u8) -> u32 {
	m.argv = argv_block(path, args)
	thid := module_thread(m^, m.argv, stop = false)
	if thid == 0 {
		if m.argv != 0 {sys_free(m.argv)}
		m.argv = 0
	}
	return thid
}

// Makes a thread of module m's entry ready at IOP_START_PRIO, on argument
// block `argv` (argv_block): argc as the block holds it, negated for a
// stop, as retail's modload calls the entry to stop a module. Its id, or 0
// when `argv` is 0 or memory for its stack ran out.
@(private = "file")
module_thread :: proc(m: Iop_Module, argv: u32, stop: bool) -> u32 {
	if argv == 0 {return 0}
	stack := sys_alloc(.High, IOP_START_STACK)
	if stack == 0 {return 0}
	st := th_new(m.entry, stack, IOP_START_STACK, m.gp, IOP_START_PRIO)
	st.start, st.exit_delete = true, true
	argc := i32(r32(argv))
	st.ctx.r[4] = u32(-argc if stop else argc)
	st.ctx.r[5] = argv + 4
	th_ready(st)
	return st.id
}

@(private = "file")
module_index :: proc(id: u32) -> int {
	for m, i in iop_loader.modules {
		if m.id == id {return i}
	}
	return -1
}

// ------------------------------------------------------------- load frames

// A start begins. The EE's load saves the state its failure restores.
@(private = "file")
frame_push :: proc(id: u32, ee: bool) -> ^Load_Frame {
	l := &iop_loader
	assert(l.depth < IOP_LOAD_DEPTH, "iop: starts nested too deep")
	f := &l.frames[l.depth]
	l.depth += 1
	f^ = {
		id = id,
		ee = ee,
	}
	if ee {
		l.ee_mark = th_mark()
		clear(&l.ee_patches)
		undo_save(&l.ee_undo)
	}
	l.loading = id
	return f
}

// Frame i ends.
@(private = "file")
frame_pop :: proc(i: int) {
	l := &iop_loader
	copy(l.frames[i:l.depth - 1], l.frames[i + 1:l.depth])
	l.depth -= 1
	l.loading = l.frames[l.depth - 1].id if l.depth > 0 else 0
}

// The frame of start thread `thid`, -1 for none.
@(private = "file")
frame_of :: proc(thid: u32) -> int {
	l := &iop_loader
	for i in 0 ..< l.depth {
		if thid != 0 && l.frames[i].thid == thid {return i}
	}
	return -1
}

// The EE load's frame, -1 when none runs.
@(private = "file")
frame_ee :: proc() -> int {
	l := &iop_loader
	for i in 0 ..< l.depth {
		if l.frames[i].ee {return i}
	}
	return -1
}

// The EE's load failed: what it did is undone, the threads, semaphores and
// event flags made since it began deleted, and its image of `key` is not
// run again (failed_add; a "" key, a stop's, marks none). The StartModules
// begun since are inside the undo:
// their frames end, their callers woken with KE_ERROR if the undo keeps them.
@(private = "file")
load_ee_fail :: proc(key, name, why: string) {
	l := &iop_loader
	fmt.eprintfln("iop: load of \"%s\" failed: %s", name, why)
	i := frame_ee()
	for l.depth > i + 1 {
		f := l.frames[l.depth - 1]
		frame_pop(l.depth - 1)
		th_start_wake(f.waiter, ke(KE_ERROR))
	}
	frame_pop(i)
	th_undo(l.ee_mark)
	undo_restore()
	if key != "" {failed_add(key, name)}
}

// A start's thread `thid` ended, its v0 `v`: the EE load's start is done
// (iop_sched.start_done), a StartModule's keeps its result for
// load_start_finish.
load_start_end :: proc(thid, v: u32) {
	i := frame_of(thid)
	if i < 0 {return}
	f := &iop_loader.frames[i]
	f.result = v
	if f.ee {iop_sched.start_done, iop_sched.start_result = true, v}
}

// Whether the EE load's start called what the HLE lacks.
load_ee_failed :: proc() -> bool {
	i := frame_ee()
	return i >= 0 && iop_loader.frames[i].failed
}

// An HLE call failed in start thread `thid`, or with 0 on the loader, in
// the EE's load: its frame fails once the start returns. The calls that
// failed in that start so far.
load_gap :: proc(thid: u32) -> u32 {
	l := &iop_loader
	i := frame_of(thid) if thid != 0 else frame_ee()
	if i < 0 {return 0}
	f := &l.frames[i]
	f.failed = true
	f.gaps += 1
	return f.gaps
}

// From the scheduler: StartModule's start thread `thid` ended, dormant. Its
// result is written where StartModule was told, as retail writes whatever
// the start returned, while the caller still waits there. A start that
// called nothing the HLE lacks has its module started, or dropped when it
// returned NO_RESIDENT_END, and the caller wakes with the module's id; one
// that did fails (start_drop).
load_start_finish :: proc(thid: u32) {
	l := &iop_loader
	i := frame_of(thid)
	if i < 0 || l.frames[i].ee {return}
	f := l.frames[i]
	if f.result_at != 0 && th_start_waits(f.waiter) {w32(f.result_at, f.result)}
	if f.failed {
		start_drop(i, "start called what the HLE lacks")
		return
	}
	k := module_index(f.id)
	assert(k >= 0, "iop: a started module not loaded")
	l.modules[k].removable = f.result & 3 == REMOVABLE_RESIDENT_END
	m := l.modules[k]
	failed_paths_retry()
	frame_pop(i)
	if f.result & 3 == NO_RESIDENT_END {module_drop(m)}
	if cpu.debug >= 1 {fmt.eprintfln("iop: \"%s\" at %x id %d started %x", lib_name32(&m.name), m.base, m.id, f.result)}
	th_start_wake(f.waiter, m.id)
}

// From the scheduler: start thread `thid` stopped, or is deleted, other than
// by its return (TerminateThread, a failed load's undo). A StartModule's
// fails (start_drop); the EE load's fails once iop_load sees it.
load_start_gone :: proc(thid: u32) {
	l := &iop_loader
	i := frame_of(thid)
	if i < 0 {return}
	if !l.frames[i].ee {
		start_drop(i, "start thread stopped before it returned")
	} else if !iop_sched.start_done {
		l.frames[i].failed = true
		iop_sched.start_done, iop_sched.start_result = true, 0
	}
}

// StartModule's start of frame i failed. Other threads ran while it did, so
// nothing is undone but what is the module's: its image and argument block,
// the blocks its start thread allocated and the threads made on them (save
// the running one, whose stack stays), the RPC queues and servers in them,
// and the libraries it registered (module_drop). Its image is not run again
// (failed_add), and the caller wakes with KE_ERROR. What it wrote elsewhere
// stays, as do handlers it set pointing into its freed memory.
@(private = "file")
start_drop :: proc(i: int, why: string) {
	l := &iop_loader
	f := l.frames[i]
	frame_pop(i)
	k := module_index(f.id)
	assert(k >= 0, "iop: a started module not loaded")
	m := l.modules[k]
	name := lib_name32(&m.name)
	fmt.eprintfln("iop: start of \"%s\" failed: %s", name, why)
	cur := th_find(iop_sched.cur)
	freed := make([dynamic]Sys_Block, 0, 8, context.temp_allocator)
	for b in sys_blocks {
		mine := b.owner == f.thid || b.addr == m.base || m.argv != 0 && b.addr == m.argv
		if mine && !(cur != nil && cur.id != f.thid && sys_in({b}, cur.stack)) {append(&freed, b)}
	}
	if h, st, nl := drop_dangling(freed[:], m); h + st + nl > 0 {
		fmt.eprintfln("iop: \"%s\" dropped with %d handlers and %d stubs of other modules into its memory, kept as on retail, and %d libraries of its own, removed", name, h, st, nl)
	}
	th_kill_in(freed[:], f.thid)
	rpc_drop_in(freed[:])
	module_drop(m)
	for b in freed {
		if b.addr != m.base && b.addr != m.argv {sys_free(b.addr)}
	}
	failed_add(failed_key(name, m.hash), name)
	th_start_wake(f.waiter, ke(KE_ERROR))
}

// What a failed StartModule leaves pointing into `freed`, the blocks it
// drops, for start_drop's log: handlers of timrman, intrman, thbase's
// alarms, sifcmd, libsd, sdrdrv, vblank and cdvdman by their address, and
// stubs of modules other than `m` patched to jump there. Retail modload
// unlinks only the module's own imports (UnLinkLibraryEntries) and releases
// neither, so both stay; a later crash through one points here. `libs`
// counts the libraries `m` registered, which module_drop removes.
drop_dangling :: proc(freed: []Sys_Block, m: Iop_Module) -> (handlers, stubs, libs: int) {
	in_f :: proc(freed: []Sys_Block, a: u32) -> int {return 1 if a != 0 && sys_in(freed, a) else 0}
	for t in iop_timr.t {handlers += in_f(freed, t.handler)}
	for l in iop_timr.lines {handlers += in_f(freed, l.handler)}
	for a in iop_timr.alarms[:iop_timr.nalarm] {handlers += in_f(freed, a.handler)}
	s := &iop_sifcmd
	for h in s.sys {handlers += in_f(freed, h.handler)}
	for c in s.dma_cb[:s.n_dma_cb] {handlers += in_f(freed, c.func)}
	for i in 0 ..< min(s.user_size, IOP_RAM_SIZE / 8) {handlers += in_f(freed, r32(s.user_tab + 8 * i))}
	for h in iop_sd.trans {handlers += in_f(freed, h.func)}
	handlers += in_f(freed, iop_sd.spu2.func)
	for h in iop_sdr.user {handlers += in_f(freed, h)}
	for x in iop_vbl.h[:iop_vbl.n] {handlers += in_f(freed, x.handler)}
	handlers += in_f(freed, iop_cd.callback)
	for x in iop_loader.libs {libs += 1 if x.owner == m.id else 0}
	// A linked stub is `j export; nop` (link_stub); no module's own code
	// jumps into another's image.
	for o in iop_loader.modules {
		if o.id == m.id {continue}
		for a := o.base; a + 8 <= o.base + o.size; a += 4 {
			w := r32(a)
			if w >> 26 != 2 || r32(a + 4) != 0 {continue}
			stubs += in_f(freed, (a + 4) & 0xf0000000 | (w & 0x3ffffff) << 2)
		}
	}
	return
}

@(private = "file")
lib_name32 :: proc(n: ^[32]u8) -> string {
	return strings.truncate_to_byte(string(n[:]), 0)
}

// ------------------------------------------------------------- heaplib

// heaplib's heaps over sysmem. Retail carves a heap's blocks out of chunks
// it takes from sysmem; here each block is its own sysmem block, HEAP_LINK
// bytes longer, which starts with the next block of the heap and the heap.
// A heap is a sysmem block holding its first block, 0 for none. The chain
// is in IOP RAM, so save states and rollback carry it with the blocks.
@(private = "file")
HEAP_LINK :: 8

// heaplib's CreateHeap (4), DeleteHeap (5), AllocHeapMemory (6) and
// FreeHeapMemory (7). Numbers as heaplib's export table.
@(private = "file")
heaplib_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	switch fno {
	case 4: // CreateHeap(size, flags): the heap, 0 when sysmem is full
		heap := sys_alloc(.Low, 4)
		if heap != 0 {w32(heap, 0)}
		return heap, true
	case 5: // DeleteHeap(heap): its blocks go back to sysmem with it
		heap := phys(r[4])
		for b := r32(heap); b != 0; {
			next := r32(b)
			sys_free(b)
			b = next
		}
		return sys_free(heap) ? KE_OK : ke(KE_ERROR), true
	case 6: // AllocHeapMemory(heap, size): the block, 0 when sysmem is full
		heap := phys(r[4])
		b := sys_alloc(.Low, r[5] + HEAP_LINK)
		if b == 0 {return 0, true}
		w32(b, r32(heap))
		w32(b + 4, heap)
		w32(heap, b)
		return b + HEAP_LINK, true
	case 7: // FreeHeapMemory(heap, block)
		heap, want := phys(r[4]), phys(r[5]) - HEAP_LINK
		for at := heap; r32(at) != 0; at = r32(at) {
			if b := r32(at); b == want {
				w32(at, r32(b))
				sys_free(b)
				return KE_OK, true
			}
		}
		return ke(KE_ERROR), true
	}
	return 0, false
}

// ------------------------------------------------------------- modload

// The id LOADFILE and LoadModuleBuffer answer for a module not run here.
// Every such module shares it, as one record nowhere: StartModule of it is
// a resident start that runs nothing, whichever module the caller meant,
// and a second is not KE_ALREADY_STARTED. Retail gives each its own id.
@(private = "file")
IOP_SONY_ID :: 2

KE_ILLEGAL_OBJECT :: -201
KE_UNKNOWN_MODULE :: -202
KE_ALREADY_STARTED :: -206
KE_NOT_STARTED :: -207
KE_ALREADY_STOPPED :: -208
KE_CAN_NOT_STOP :: -209
KE_NOT_STOPPED :: -210
KE_NOT_REMOVABLE :: -211

// LOADFILE's StopModule of module `id`, from the EE, as retail's modload
// stops one: a started module its start left removable has its entry run
// again, argc negated, argv[0] "other" and then `args`, and `modres` is
// what that returns. Its low 2 bits NO_RESIDENT_END stop the module, the
// reply its id; any other leaves it running, KE_CAN_NOT_STOP. A module not
// run here (IOP_SONY_ID) is answered as stopped. The stop runs as an EE
// load's start does; one that fails is undone as a failed load is and
// answered KE_ERROR, its image left free to load again.
@(private)
iop_stop :: proc(id: u32, args: []u8) -> (v0, modres: u32) {
	if id == IOP_SONY_ID {return id, NO_RESIDENT_END}
	l := &iop_loader
	k := module_index(id)
	if k < 0 {return ke(KE_UNKNOWN_MODULE), 0}
	m := l.modules[k]
	name := lib_name32(&m.name)
	switch {
	case !m.started:
		return ke(KE_NOT_STARTED), 0
	case m.stopped:
		return ke(KE_ALREADY_STOPPED), 0
	case !m.removable:
		return ke(KE_NOT_REMOVABLE), 0
	}
	if l.depth == IOP_LOAD_DEPTH {
		fmt.eprintfln("iop: stop of \"%s\" refused: %d starts under way", name, l.depth)
		return ke(KE_ERROR), 0
	}
	defer iop_wake_set()
	f := frame_push(id, ee = true)
	argv := argv_block("other", args)
	f.thid = module_thread(m, argv, stop = true)
	why := "no memory" if f.thid == 0 else ee_start_run(name)
	if why != "" {
		// The undo frees the block with the rest of sysmem's.
		load_ee_fail("", name, why)
		return ke(KE_ERROR), 0
	}
	frame_pop(frame_ee())
	sys_free(argv)
	modres = iop_sched.start_result
	if cpu.debug >= 1 {fmt.eprintfln("iop: \"%s\" id %d stop %x", name, id, modres)}
	if modres & 3 != NO_RESIDENT_END {return ke(KE_CAN_NOT_STOP), modres}
	// The stop can have loaded modules, so its index moved.
	if k = module_index(id); k >= 0 {l.modules[k].stopped = true}
	return id, modres
}

// LOADFILE's UnloadModule of module `id`, as retail's modload unloads one:
// a module stopped, or loaded and never started, is dropped, the reply its
// id; a started one is KE_NOT_REMOVABLE when its start left it resident,
// else KE_NOT_STOPPED. A module not run here is answered as unloaded.
@(private)
iop_unload :: proc(id: u32) -> u32 {
	if id == IOP_SONY_ID {return id}
	k := module_index(id)
	if k < 0 {return ke(KE_UNKNOWN_MODULE)}
	m := iop_loader.modules[k]
	if m.started && !m.removable {return ke(KE_NOT_REMOVABLE)}
	if m.started && !m.stopped {return ke(KE_NOT_STOPPED)}
	if cpu.debug >= 1 {fmt.eprintfln("iop: \"%s\" id %d unloaded", lib_name32(&m.name), id)}
	module_drop(m)
	return id
}

// modload's LoadModuleBuffer (10) and StartModule (8), as a start that loads
// modules itself calls them (PLD.IRX), the module id lists (16, 18) and
// SearchModuleByName (22). Numbers as modload's export table. A Sony module
// has no record, so a search for one finds nothing.
@(private = "file")
modload_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	if iop_sched.intr {return ke(KE_ILLEGAL_CONTEXT), true}
	switch fno {
	case 8: // StartModule(modid, name, arglen, args, int *result)
		return module_start_call(r[4], r[5], r[6], r[7], r32(r[29] + 16))
	case 10: // LoadModuleBuffer(buffer)
		return module_buffer_load(r[4]), true
	case 16: // GetModuleIdList(int *list, int max, int *count)
		return module_id_list("", false, r[4], r[5], r[6]), true
	case 18: // GetModuleIdListByName(name, int *list, int max, int *count)
		return module_id_list(r[4] != 0 ? cstr(r[4]) : "", r[4] != 0, r[5], r[6], r[7]), true
	case 22: // SearchModuleByName(name): the newest such module's id, or KE_UNKNOWN_MODULE
		if r[4] == 0 {return ke(KE_UNKNOWN_MODULE), true}
		name := cstr(r[4])
		// A Sony module's name is never found (none is loaded), so a module
		// that looks for one to gate its own start takes its "not found"
		// path: the name shows which.
		if cpu.debug >= 1 {fmt.eprintfln("iop: SearchModuleByName(%q) ra %08x", name, r[31])}
		#reverse for m in iop_loader.modules {
			m := m
			if strings.truncate_to_byte(string(m.name[:]), 0) == name {return m.id, true}
		}
		return ke(KE_UNKNOWN_MODULE), true
	}
	return 0, false
}

// GetModuleIdList(ByName): the ids of the modules run here (those named
// `name` when by_name), up to max of them, into list; count gets how many
// there are, and the call returns how many it wrote. A Sony module has no
// record of its own.
@(private = "file")
module_id_list :: proc(name: string, by_name: bool, list, max_n, count: u32) -> u32 {
	n, wrote: u32
	for m in iop_loader.modules {
		m := m
		if by_name && strings.truncate_to_byte(string(m.name[:]), 0) != name {continue}
		if i32(wrote) < i32(max_n) {
			w32(list + wrote * 4, m.id)
			wrote += 1
		}
		n += 1
	}
	if count != 0 {w32(count, n)}
	return wrote
}

// LoadModuleBuffer: links the IRX image at `buf`, which the caller may free
// once it returns, as a module not yet started; its id. A Sony module is not
// run (iop_runs): IOP_SONY_ID. A pad driver's name picks the one dbcman
// serves (dbcman_module). An image that failed before is refused
// (failed_refused); one whose link fails is a failed path.
@(private = "file")
module_buffer_load :: proc(buf: u32) -> u32 {
	l := &iop_loader
	// Only read: the file ends where the furthest of its headers, segments
	// and sections does (irx_extent), and what follows is not the file's.
	data := iop_view(buf, IOP_RAM_SIZE)
	x, ok := irx_parse(data)
	if !ok {return ke(KE_ILLEGAL_OBJECT)}
	data = data[:irx_extent(data, x)]
	dbcman_module(strings.trim_space(x.name), data)
	if !iop_runs(data) {return IOP_SONY_ID}
	if x.name == "" {x.name = fmt.tprintf("irx@%x", buf)}
	core.compat_code_load()
	// The file's bytes up to its image's end, and its name as its module
	// record holds it, cut at 32, which the failure of its start keys by.
	hash := xxhash.XXH3_64_default(data[:x.file_off + x.file_size])
	name := x.name[:min(len(x.name), len(Iop_Module{}.name))]
	key := failed_key(name, hash)
	if failed_refused(key, name) {return ke(KE_ERROR)}
	m, why := module_link(data, x, l.next_id)
	if why != "" {
		fmt.eprintfln("iop: load of \"%s\" failed: %s", name, why)
		failed_add(key, name)
		return ke(KE_ERROR)
	}
	m.hash = hash
	l.next_id += 1
	append(&l.modules, m)
	core.gamedata_irx(strings.truncate_to_byte(string(m.name[:]), 0), m.base, m.size, m.hash)
	if cpu.debug >= 1 {fmt.eprintfln("iop: \"%s\" at %x id %d loaded", x.name, m.base, m.id)}
	return m.id
}

// StartModule: runs module id's start as a thread of its own, argv[0]
// `name_at`'s string (the module's name when 0) and then the arglen bytes
// at `args_at`, while the caller waits for it to return (load_start_finish),
// as retail's modload runs it on its loader thread. One start at a time
// besides the EE load's: a StartModule from another thread while one runs
// is a gap, as is one past IOP_LOAD_DEPTH. Memory for the start running out
// is KE_NO_MEMORY, the module kept, not started.
@(private = "file")
module_start_call :: proc(id, name_at, arglen, args_at, result_at: u32) -> (v0: u32, ok: bool) {
	l := &iop_loader
	s := &iop_sched
	if s.cur == 0 {return ke(KE_ILLEGAL_CONTEXT), true}
	if id == IOP_SONY_ID {
		if result_at != 0 {w32(result_at, RESIDENT_END)}
		return id, true
	}
	k := module_index(id)
	if k < 0 {return ke(KE_UNKNOWN_MODULE), true}
	if l.modules[k].started {return ke(KE_ALREADY_STARTED), true}
	if l.depth > 0 && !l.frames[l.depth - 1].ee && l.frames[l.depth - 1].thid != s.cur {
		fmt.eprintfln("iop: StartModule of %d from thread %d while another start runs", id, s.cur)
		return 0, false
	}
	if l.depth == IOP_LOAD_DEPTH {
		fmt.eprintfln("iop: StartModule of %d: %d starts under way", id, l.depth)
		return 0, false
	}
	m := &l.modules[k]
	name := lib_name32(&m.name)
	path := cstr(name_at) if name_at != 0 else name
	args := iop_view(args_at, arglen) if arglen > 0 else nil
	thid := module_start(m, path, args)
	if thid == 0 {
		fmt.eprintfln("iop: StartModule of \"%s\": no memory", name)
		return ke(KE_NO_MEMORY), true
	}
	m.started = true
	f := frame_push(id, ee = false)
	f.thid, f.waiter, f.result_at = thid, s.cur, result_at
	return th_start_wait(), true
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
			l.stubs[phys(stub)] = {t.name, fno, false, t.version}
		} else {
			append(&l.pending, Iop_Import{t.name, t.version, stub, fno})
			l.stubs[phys(stub)] = {t.name, fno, true, 0}
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
		l.stubs[phys(stub)] = {lib.name, fno, true, 0}
		return false
	}
	f := r32(lib.table + 20 + 4 * fno)
	if frame_ee() >= 0 {append(&l.ee_patches, Iop_Patch{stub, {r32(stub), r32(stub + 4)}})}
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
	if k := module_index(m.id); k >= 0 {ordered_remove(&l.modules, k)}
	// A failed start's restore may have freed them already.
	sys_free(m.base)
	if m.argv != 0 {sys_free(m.argv)}
}

@(private = "file")
undo_save :: proc(u: ^Load_Undo) {
	clear(&u.libs)
	append(&u.libs, ..iop_loader.libs[:])
	clear(&u.pending)
	append(&u.pending, ..iop_loader.pending[:])
	clear(&u.blocks)
	append(&u.blocks, ..sys_blocks[:])
	clear(&u.stubs)
	for a, s in iop_loader.stubs {u.stubs[a] = s}
	clear(&u.modules)
	append(&u.modules, ..iop_loader.modules[:])
	u.next_id = iop_loader.next_id
	u.sifcmd, u.sd, u.sdr, u.timr, u.cd, u.rpc = iop_sifcmd, iop_sd, iop_sdr, iop_timr, iop_cd, iop_rpc
	u.vbl = iop_vbl
	clear(&u.sif_tab)
	for i in 0 ..< 2 * min(iop_sifcmd.user_size, IOP_RAM_SIZE / 8) {
		append(&u.sif_tab, r32(iop_sifcmd.user_tab + 4 * i))
	}
	clear(&u.open)
	for f in fileio.files {append(&u.open, f.f != nil)}
}

@(private = "file")
undo_restore :: proc() {
	l := &iop_loader
	u := &l.ee_undo
	#reverse for p in l.ee_patches {
		w32(p.stub, p.words[0])
		w32(p.stub + 4, p.words[1])
	}
	clear(&l.ee_patches)
	clear(&l.libs)
	append(&l.libs, ..u.libs[:])
	clear(&l.pending)
	append(&l.pending, ..u.pending[:])
	clear(&l.modules)
	append(&l.modules, ..u.modules[:])
	l.next_id = u.next_id
	// What the load allocated, which is freed below: no handler is left
	// pointing there (cdvdman's callback included), the timers it allocated
	// are as they were, the RPC servers and queues it removed are back
	// (rpc_undo), and the fds it opened are closed. What else it did
	// is kept: bytes it wrote to memory that stays, what it sent the EE, the
	// SPU2 registers and voices it set, threads it did not make that it
	// started or woke, and fds open before it that it closed or moved.
	freed := make([dynamic]Sys_Block, 0, len(sys_blocks), context.temp_allocator)
	for b in sys_blocks {
		if !slice.contains(u.blocks[:], b) && b.addr != iop_sifcmd.rpc_pool {append(&freed, b)}
	}
	sifcmd_undo(u.sifcmd, u.sif_tab[:], freed[:])
	sd_undo(u.sd, freed[:])
	sdr_undo(u.sdr, freed[:])
	tim_undo(u.timr, freed[:])
	cd_undo(u.cd, freed[:])
	vbl_undo(u.vbl, freed[:])
	rpc_undo(u.rpc, freed[:])
	for &f, i in fileio.files {
		if f.f != nil && (i >= len(u.open) || !u.open[i]) {f = {}}
	}
	clear(&sys_blocks)
	append(&sys_blocks, ..u.blocks[:])
	// The RPC client's pool stays where it is, however late it was allocated.
	if p := iop_sifcmd.rpc_pool; p != 0 && !sys_in(sys_blocks[:], p) {sys_alloc(.Addr, RPC_PKTS * RPC_PKT_SIZE, p)}
	clear(&l.stubs)
	for a, s in u.stubs {l.stubs[a] = s}
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
	} else if u32(s.version >> 8) != hle_major(name) {
		core.compat_unknown(.Iop_Import, core.compat_name(name), u32(s.version), pc = addr, ra = r[31])
		fmt.eprintfln("iop: call to %s version %x fno %d, a major version the HLE does not serve", name, s.version, s.fno)
	} else if v, ok := hle_fn(name, s.fno); ok {
		when core.FLAT {
			// It stopped the thread: its return is owed to the resume. It
			// went on as a continuation: that returns (hle_return).
			if r3000.flat_stop {
				th_flat_stopped(v)
				return
			}
			if r3000.flat_deferred() {return}
		}
		hle_return(v)
		return
	} else {
		core.compat_unknown(.Iop_Call, core.compat_name(name), s.fno, pc = addr, ra = r[31])
		fmt.eprintfln("iop: %s fno %d not implemented", name, s.fno)
	}
	r[2] = ke(KE_ERROR)
	th_call_failed()
}

// An HLE function returns v to its guest caller, which yields first when
// it readied a thread of better priority.
hle_return :: proc(v: u32) {
	r3000.state.r[2] = v
	if iop_sched.resched {th_preempt()}
}

// Maps a call to IOP address `addr` to function fno of the HLE's library
// `name`, as an import's stub of a version 1 table: a function the HLE
// itself hands to guest code, as a thread's entry or a server's function.
hle_host_stub :: proc(addr: u32, name: string, fno: u32) {
	s := Hle_Stub{fno = fno, version = u16(hle_major(name) << 8 | 1)}
	copy(s.name[:], name)
	iop_loader.stubs[phys(addr)] = s
}

// The major version of Sony library `name` that hle_fn serves: its numbers
// are those of that major's export table. An import of another major names
// other functions by the same numbers, so a call to it is not served.
// sio2man is served at 2, whose table adds the locked transfer functions
// (rsio2man.h); every other library at 1.
hle_major :: proc(name: string) -> u32 {
	return 2 if name == "sio2man" else 1
}

// An error code as v0 holds it.
ke :: proc(e: i32) -> u32 {
	return u32(e)
}

// Function fno of Sony library `name`, reading a0..a3; v0, or false when the
// HLE lacks it. Numbers as the PS2SDK's export tables order them.
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
	case "modload":
		return modload_fn(fno)
	case "heaplib":
		return heaplib_fn(fno)
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
			return ke(KE_ERROR), true // retail's -1 for a table not registered
		case 12: // QueryBootMode(mode): no boot-mode records
			return 0, true
		case 27: // SetRebootTimeLibraryHandlingMode
			return KE_OK, true
		}
	case "intrman":
		switch fno {
		case 8: // CpuDisableIntr: KE_CPUDI when they were off already
			off := th_intr_off()
			th_intr_set(true)
			return off ? ke(KE_CPUDI) : KE_OK, true
		case 9: // CpuEnableIntr
			th_intr_set(false)
			return KE_OK, true
		case 4: // RegisterIntrHandler(irq, mode, handler, arg)
			return intr_register(a0, a2, r[7]), true
		case 5: // ReleaseIntrHandler(irq)
			return intr_release(a0), true
		case 6: // EnableIntr(irq): every line counts as enabled, as above;
			// a timer's line lets its handler run (intr_enable)
			intr_enable(a0, true)
			return KE_OK, true
		case 7: // DisableIntr(irq, int *res): the old state, which counts as
			// enabled, so res gets irq as retail gives an enabled line's; a
			// timer's line stops its handler running
			intr_enable(a0 & 0xff, false)
			if a1 != 0 {w32(a1, a0)}
			return KE_OK, true
		case 17: // CpuSuspendIntr(int *state): the old state stored whether
			// or not they were on; KE_CPUDI when they were off already
			off := th_intr_off()
			if a0 != 0 {w32(a0, off ? 0 : INTR_ON_STATE)}
			th_intr_set(true)
			return off ? ke(KE_CPUDI) : KE_OK, true
		case 18: // CpuResumeIntr(state): back to what state says, its bit 0
			// as the register takes it, whatever the caller built
			th_intr_set(a0 & INTR_ON_STATE == 0)
			return KE_OK, true
		case 23: // QueryIntrContext
			return iop_query_intr_context(), true
		}
	case "usbd":
		// A class driver registering or dropping its LDD: no USB device ever
		// attaches here, so its connect and probe are never called and it
		// never reaches usbd's other calls, which stay gaps.
		switch fno {
		case 4, 5: // sceUsbdRegisterLdd(ops), sceUsbdUnregisterLdd(ops)
			return 0, true
		}
	case "secrman":
		// A memory card's authentication over SIO2, which no card answers here
		// (sio2_frame): the HLE's cards are mcserv's alone, over its RPC.
		switch fno {
		case 4, 5: // SecrSetMcCommandHandler(func), SecrSetMcDevIDHandler(func): kept for 6 to talk to the card through
			return 0, true
		case 6: // SecrAuthCard(port, slot, cnum): 0, the handshake failed, as retail's when no card answers
			return 0, true
		}
	case "thbase":
		return th_base(fno)
	case "thsemap":
		return th_semap(fno)
	case "thmsgbx":
		return th_msgbx(fno)
	case "thfpool":
		return th_fpool(fno)
	case "sio2man":
		return sio2man_fn(fno)
	case "thevent":
		return th_event(fno)
	case "vblank":
		return vblank_fn(fno)
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
	case "sdrdrv":
		return sdrdrv_fn(fno)
	case "timrman":
		return timrman_fn(fno)
	case "cdvdman":
		return cdvdman_fn(fno)
	case "ioman":
		return ioman_fn(fno)
	}
	return 0, false
}

// Registers the export table at `a` and patches the pending stubs it
// satisfies. As retail, -1 for a null table or one without the export
// magic, and -1 when a library of that name and major version is
// registered. Retail lets a newer minor take the older one's importers
// over; that is not done here, and it is -1 too.
@(private = "file")
lib_register :: proc(a: u32) -> u32 {
	l := &iop_loader
	if a == 0 || r32(a) != IRX_EXPORT_MAGIC {return ke(KE_ERROR)}
	b := Iop_Lib {
		version = u16(r32(a + 8)),
		table   = a,
		owner   = l.loading,
	}
	(^[2]u32)(&b.name)^ = {r32(a + 12), r32(a + 16)}
	name := lib_name(&b.name)
	if _, dup := lib_find(name, b.version); dup {return ke(KE_ERROR)}
	for b.count < 256 && r32(a + 20 + 4 * b.count) != 0 {b.count += 1}
	append(&l.libs, b)
	failed_paths_retry()
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
//
// On wasi it comes from the heap and is writable: wasm memory has no page
// protection, and core:mem/virtual maps nothing there. Nothing is lost. The
// only writers are the installs of recompiled code (register_funcs, hook),
// which a wasi build, always FLAT, refuses; a native FLAT build runs the
// same paths on the read-only mapping, so a stray write still faults there.
@(private = "file")
iop_fixed: []r3000.Func_Proc

iop_dispatch_init :: proc() {
	if iop_fixed == nil {
		size := uint(r3000.RAM_SIZE / 4 * size_of(r3000.Func_Proc))
		data: []u8
		err: virtual.Allocator_Error
		when ODIN_OS == .WASI {
			// Host memory, as the mapping is natively: init runs on
			// the emulated heap.
			data, err = make([]u8, size, core.long_allocator())
			assert(err == nil, "iop: dispatch table not allocated")
		} else {
			data, err = virtual.reserve_and_commit(size)
			assert(err == nil, "iop: dispatch table not mapped")
			ok := virtual.protect(raw_data(data), size, {.Read})
			assert(ok, "iop: dispatch table not made read-only")
		}
		iop_fixed = slice.reinterpret([]r3000.Func_Proc, data)
	}
	assert(r3000.dispatch.fixed == nil || raw_data(r3000.dispatch.fixed) == raw_data(iop_fixed), "iop: PS1 functions registered")
	r3000.dispatch.fixed = iop_fixed
}
