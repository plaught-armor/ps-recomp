// R3000A CPU state and the call dispatcher shared by recompiled code, the
// interpreter and HLE.
//
// Recompiled functions are host procedures. A MIPS `jal` becomes a host call
// through `call`, and `jr $ra` becomes a host return, so the MIPS return
// address only matters to code that inspects it. `call` resolves a target in
// this order: hand-written override, recompiled executable function, BIOS
// vector or table entry, recompiled overlay function whose overlay is
// resident (or executable function demoted by a write to its page, whose code
// is still the same: watch.odin), interpreter.
package psx_cpu

import "core:fmt"
import "core:os"

import "ps:core"

// Handlers in the packages above this one, set by package psx at init.
bios_a, bios_b, bios_c: proc(fn: u32)
bios_syscall: proc()
// Runs a call to one of the BIOS's B0 and C0 table entries, or with run
// false only reports that addr is one; false for any other address. May be
// nil.
bios_entry: proc(addr: u32, run: bool) -> bool
irq_check: proc()
interp_run: proc(start: u32)
io_read: proc(p: u32, size: u32) -> u32
io_write: proc(p, v: u32, size: u32)
ram_keep: proc(p: u32)

Cpu :: struct {
	r:      [32]u32,
	hi, lo: u32,
	// Instructions retired; the time base for every device.
	cycles: u64,
}

state: Cpu

// Cycle count at which run_events must next be called.
next_event: u64

Func_Proc :: #type proc()

Func_Entry :: struct {
	addr: u32,
	fn:   Func_Proc,
}

// Recompiled function of one overlay: valid while `id` (the overlay's first
// word) is at `slot` in RAM and the function's first code words are `sig`.
// The signature catches a different overlay loaded over part of this one
// without touching its header.
Ovl_Entry :: struct {
	addr: u32,
	slot: u32,
	id:   u32,
	sig:  [4]u32,
	fn:   Func_Proc,
}

@(private)
ovl_resident :: #force_inline proc(e: ^Ovl_Entry) -> bool {
	if r32(e.slot) != e.id {
		return false
	}
	for w, k in e.sig {
		if r32(e.addr + u32(k) * 4) != w {
			return false
		}
	}
	return true
}

@(private)
FN_TABLE_SIZE :: RAM_SIZE / 4

dispatch: struct {
	// Executable functions and overrides, indexed by RAM word.
	fixed:     []Func_Proc,
	overlay:   map[u32][dynamic]Ovl_Entry,
	reported:  map[u32]bool,
}

fn_index :: #force_inline proc(addr: u32) -> u32 {
	return (addr & (RAM_SIZE - 1)) >> 2
}

is_ram_addr :: #force_inline proc(addr: u32) -> bool {
	return addr & 0x1fffffff < 0x800000
}

register_funcs :: proc(entries: []Func_Entry) {
	if dispatch.fixed == nil {
		dispatch.fixed = make([]Func_Proc, FN_TABLE_SIZE)
	}
	for e in entries {
		dispatch.fixed[fn_index(e.addr)] = e.fn
	}
}

register_overlay_funcs :: proc(entries: []Ovl_Entry) {
	for e in entries {
		list := dispatch.overlay[e.addr]
		append(&list, e)
		dispatch.overlay[e.addr] = list
	}
}

// Set by a game port while its own host-side camera replaces the PS1's.
// Also read by recompiled code at patch points (the recompiler's patches
// table names it as the condition): the game's patches skip culling written
// for the PS1 camera.
host_camera: bool

// Average R3000A cost per instruction including memory stalls, what the
// interpreter charges; matches the recompiler's cycles_per_insn option.
CYCLES_PER_INSN :: 2

// Frames presented (one per emulated vblank) since power-on.
presents: u64

// Emulated vblanks since power-on: the clock for anything that must advance
// with emulated time rather than with frames drawn.
vblanks :: proc() -> u64 {
	return presents
}

// Replace the executable's function at addr with a hand-written procedure,
// demoted or not (watch.odin). Returns the recompiled one so the
// replacement can fall back to it; ok is false when no function was
// recompiled at addr.
hook :: proc(addr: u32, fn: Func_Proc) -> (original: Func_Proc, ok: bool) {
	if !registered(addr) {
		return demoted_hook(addr, fn)
	}
	slot := &dispatch.fixed[fn_index(addr)]
	original, slot^ = slot^, fn
	return original, true
}

// Whether the executable has a function at addr (register_funcs).
registered :: proc(addr: u32) -> bool {
	return dispatch.fixed != nil && is_ram_addr(addr) && addr & 3 == 0 && dispatch.fixed[fn_index(addr)] != nil
}

// Replace the recompiled function at addr of overlay `id` at `slot` with a
// hand-written procedure. Returns the recompiled one so the replacement can
// fall back to it; ok is false when no such function was recompiled.
hook_overlay :: proc(addr, slot, id: u32, fn: Func_Proc) -> (original: Func_Proc, ok: bool) {
	list := dispatch.overlay[addr] or_return
	for &e in list {
		if e.slot == slot && e.id == id {
			if e.slot == e.addr {
				return demoted_hook(addr, fn)
			}
			original, e.fn = e.fn, fn
			return original, true
		}
	}
	return nil, false
}

// Return address of the innermost host-level call.
frame_ret: u32

// Execute the MIPS function at addr and return when it returns.
call :: proc(addr: u32) {
	// A jump to the caller's return address through a register other than
	// $ra (hand-written code saves $ra elsewhere) is a return; track it.
	if .Call in core.trace.active && core.trace_pc_ok(addr) {
		core.tracef(.Call, "%08x ra=%x sp=%x a0=%x a1=%x", addr, state.r[31], state.r[29], state.r[4], state.r[5])
	}
	outer := frame_ret
	frame_ret = state.r[31]
	defer frame_ret = outer
	if is_ram_addr(addr) && addr & 3 == 0 {
		if fn := dispatch.fixed[fn_index(addr)]; fn != nil {
			fn()
			return
		}
	}
	call_slow(addr)
}

@(private)
resolve_overlay :: proc(addr: u32) -> ^Ovl_Entry {
	list, ok := dispatch.overlay[addr]
	if !ok {
		return nil
	}
	for &e, k in list {
		if ovl_resident(&e) {
			if k != 0 {
				// Keep the resident variant first for the next lookup.
				list[0], list[k] = list[k], list[0]
			}
			return &list[0]
		}
	}
	return nil
}

// Whether the cpu runs a call to addr without guest code: the A0, B0 and C0
// vectors and the table entries' stubs (bios_entry). With run, the call
// runs too. call_slow runs these; the interpreter asks without run before
// following a jump into one, as the vectors' RAM holds no code to step.
host_call :: proc(addr: u32, run: bool) -> bool {
	switch addr & 0x1fffffff {
	case 0xa0:
		if run {bios_a(state.r[9])}
		return true
	case 0xb0:
		if run {bios_b(state.r[9])}
		return true
	case 0xc0:
		if run {bios_c(state.r[9])}
		return true
	}
	return bios_entry != nil && bios_entry(addr, run)
}

@(private)
call_slow :: proc(addr: u32) {
	if host_call(addr, true) {
		return
	}
	if e := resolve_overlay(addr); e != nil {
		when FALLBACK_COUNT {
			if addr in dispatch_demoted {
				dispatch_demoted[addr] += 1
			} else {
				dispatch_overlay[addr] += 1
			}
		}
		if e.slot == e.addr {code_promote(e)}
		e.fn()
		return
	}
	report_once(addr, "interpreting")
	interpret(addr)
}

@(private)
interpret :: proc(addr: u32) {
	when FALLBACK_COUNT {fallback_interp[addr] += 1}
	when core.COMPAT_COUNT {core.compat_entry(addr)}
	interp_run(addr)
}

report_once :: proc(addr: u32, what: string) {
	if !dispatch.reported[addr] {
		dispatch.reported[addr] = true
		fmt.eprintfln("%s %#08x (ra %#08x) at present %d", what, addr, state.r[31], presents)
		// With DUMP, keep RAM as it was so the code can be identified.
		if dir := core.dump_dir(); dir != "" {
			name := fmt.tprintf("%s/ram_interp_%08x.bin", dir, addr)
			if err := os.write_entire_file(name, ram[:]); err != nil {
				fmt.eprintln(core.ENV_PREFIX + "DUMP: ram write failed:", name, err)
			}
		}
	}
}

// A recompiled function jumped to pc, which is not one of its block labels.
jump_unknown :: proc(func, pc: u32) {
	if pc == frame_ret {
		when FALLBACK_COUNT {fallback_jump[{func, pc, .Return}] += 1}
		return
	}
	if pc < func || !is_ram_addr(pc) {
		when FALLBACK_COUNT {fallback_jump[{func, pc, .Call}] += 1}
		call(pc)
		return
	}
	if has_func(pc) {
		when FALLBACK_COUNT {fallback_jump[{func, pc, .Call}] += 1}
		call(pc)
		return
	}
	when FALLBACK_COUNT {fallback_jump[{func, pc, .Interp}] += 1}
	report_once(pc, "unlabelled jump target, interpreting")
	interpret(pc)
}

mult :: #force_inline proc(a, b: u32) {
	p := i64(i32(a)) * i64(i32(b))
	state.lo = u32(p)
	state.hi = u32(u64(p) >> 32)
}

multu :: #force_inline proc(a, b: u32) {
	p := u64(a) * u64(b)
	state.lo = u32(p)
	state.hi = u32(p >> 32)
}

div :: #force_inline proc(a, b: u32) {
	n, d := i32(a), i32(b)
	switch {
	case d == 0:
		state.hi = a
		state.lo = n >= 0 ? 0xffffffff : 1
	case a == 0x80000000 && d == -1:
		state.lo = 0x80000000
		state.hi = 0
	case:
		state.lo = u32(n / d)
		state.hi = u32(n % d)
	}
}

divu :: #force_inline proc(a, b: u32) {
	if b == 0 {
		state.lo = 0xffffffff
		state.hi = a
		return
	}
	state.lo = a / b
	state.hi = a % b
}

brk :: proc(pc, code: u32) {
	fmt.eprintfln("break %#x at %#08x", code, pc)
}

bad_insn :: proc(pc, w: u32) {
	fatal("reserved instruction %#08x at %#08x", w, pc)
}

// Stop the game on an error it cannot get past: say so, then save RAM
// (RAMDUMP) and print the compat line (COMPAT).
fatal :: proc(format: string, args: ..any) -> ! {
	msg := fmt.tprintf(format, ..args)
	fmt.eprintln("fatal:", msg)
	ram_dump_env()
	core.compat_report(msg)
	os.exit(1)
}

// Debug aid: RAMDUMP=<file> saves main RAM for post-mortem, and a
// FALLBACK_COUNT build reports its counters; called where the port exits
// on purpose.
ram_dump_env :: proc() {
	when FALLBACK_COUNT {fallback_dump()}
	if path := core.env("RAMDUMP"); path != "" {
		if err := os.write_entire_file(path, ram[:]); err != nil {
			fmt.eprintln(core.ENV_PREFIX + "RAMDUMP: write failed:", path, err)
		}
	}
}

// ---------------------------------------------------------------- COP0

COP0_SR :: 12
COP0_CAUSE :: 13
COP0_EPC :: 14

cop0: struct {
	sr:    u32,
	cause: u32,
	epc:   u32,
}

// COP0 register r. Recompiled code calls it with a constant r, and the
// switch folds away.
mfc0 :: #force_inline proc(r: u32) -> u32 {
	switch r {
	case COP0_SR:
		return cop0.sr
	case COP0_CAUSE:
		return cop0.cause
	case COP0_EPC:
		return cop0.epc
	case 15:
		return 2 // PRId
	}
	return 0
}

mtc0 :: proc(r, v: u32) {
	switch r {
	case COP0_SR:
		cop0.sr = v
		irq_check()
	case COP0_CAUSE:
		cop0.cause = (cop0.cause & ~u32(0x300)) | (v & 0x300)
	}
}

rfe :: proc() {
	cop0.sr = (cop0.sr & ~u32(0xf)) | ((cop0.sr >> 2) & 0xf)
}

// ExitCriticalSection: interrupts on, and any pending one taken.
exit_critical :: #force_inline proc() {
	cop0.sr |= 0x401
	irq_check()
}

// `syscall`: EnterCriticalSection (a0=1) and ExitCriticalSection (a0=2),
// which the BIOS implements by editing SR, are done here; the BIOS does
// the rest.
syscall :: proc(pc: u32) {
	switch state.r[4] {
	// The BIOS edits the SR saved on exception entry (bits 0x404), which rfe
	// turns into the live IEc/IM2 bits 0x401; edit those directly.
	case 1:
		state.r[2] = (cop0.sr & 0x401) == 0x401 ? 1 : 0
		cop0.sr &= ~u32(0x401)
	case 2:
		exit_critical()
	case 0:
		// NoFunction
	case:
		bios_syscall()
	}
}
