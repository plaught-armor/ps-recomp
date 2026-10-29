// Symmetric coroutines standing in for console threads (BIOS OpenTh/ChangeTh,
// EE kernel threads).
//
// Recompiled code keeps MIPS call frames on the host stack, so each console
// thread needs its own host stack. The coroutines all run on the host main
// thread: the whole machine lives in one OS thread, so a fork() copy of the
// process carries every console thread with it.
//
// The switch is hand-written, not the OS's: glibc's swapcontext also saves
// the signal mask with a syscall and the whole FP environment on every
// switch, and a Windows fiber's stack cannot be copied for a snapshot. Odin
// can only assemble foreign code with nasm, so each switch ships as machine
// code (the listing beside CO_CODE) copied into an executable page on first
// use. Each ABI's file (coroutine_sysv.odin, coroutine_aapcs.odin,
// coroutine_windows_amd64.odin) supplies CO_CODE, CO_TRAMPOLINE and co_frame
// (a new stack laid out as a suspended one); each OS's (coroutine_<os>.odin,
// with Windows in its ABI file) supplies co_map_stack, and code_<os>.odin
// map_code.
package core

import "base:runtime"
import "core:mem"

when !(ODIN_ARCH == .amd64 && (ODIN_OS == .Linux || ODIN_OS == .Windows || ODIN_OS == .Darwin)) &&
     !(ODIN_ARCH == .arm64 && (ODIN_OS == .Linux || ODIN_OS == .Darwin)) {
	#panic("core: no coroutine switch for this target yet")
}

// Host stack of a coroutine, reserved whole and committed as it is used.
CO_STACK :: 8 << 20

Co_Context :: struct {
	sp:    rawptr, // saved stack pointer while suspended
	stack: rawptr, // lowest address; the stack is CO_STACK bytes
}

Coroutine :: struct {
	ctx:     Co_Context, // the target's switch state and stack
	entry:   proc(arg: rawptr),
	arg:     rawptr,
	started: bool,
}

// The coroutine for the host main thread's own stack.
co_main_thread: Coroutine

co_current: ^Coroutine = &co_main_thread

// The allocator coroutine bodies start with (the default context's when
// nil). A console with save states sets its emulated heap here, so what
// console threads allocate is saved with the machine.
co_allocator: runtime.Allocator

// The context every coroutine but the main thread's starts with.
@(private)
co_context :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	if co_allocator.procedure != nil {
		c.allocator = co_allocator
	}
	return c
}

// The body of every coroutine but the main thread's, on its own stack.
@(private)
co_run :: proc(co: ^Coroutine) -> ! {
	co.entry(co.arg)
	panic("coroutine returned from its entry")
}

// The Coroutine itself comes from `allocator`, never a core-global one: a
// console with save states passes its emulated heap so the struct lives in
// the snapshot, and restored co_stack_owner entries point at it.
co_create :: proc(entry: proc(arg: rawptr), arg: rawptr, allocator := context.allocator) -> ^Coroutine {
	co := new(Coroutine, allocator)
	co.entry = entry
	co.arg = arg
	return co
}

// Transfer control from the running coroutine to `to`; returns when some
// coroutine transfers back to the caller.
co_switch :: proc(to: ^Coroutine) {
	from := co_current
	if to == from {
		return
	}
	if !to.started && to != &co_main_thread {
		to.started = true
		co_start(to)
	}
	co_current = to
	co_swap(from, to)
}

// Discard a coroutine that is not running, with its stack.
co_kill :: proc(co: ^Coroutine, allocator := context.allocator) {
	assert(co != co_current, "co_kill on the running coroutine")
	co_free(co)
	free(co, allocator)
}

@(private)
co_switch_stack: proc "c" (save: ^rawptr, sp: rawptr)
@(private)
co_trampoline: rawptr

@(private)
co_body :: proc "c" (co: ^Coroutine) {
	context = co_context()
	co_run(co)
}

// Stacks are mapped on first use and never unmapped, so a snapshot's stack
// pointers stay valid. co_stack_owner says which are in use: a console with
// save states saves it as emulated state, with each live stack from its
// saved pointer (ctx.sp) to its top (ctx.stack + CO_STACK).
CO_POOL :: 64
@(private)
co_stacks: [CO_POOL]rawptr
co_stack_owner: [CO_POOL]^Coroutine

// Give `co` a stack from the pool, laid out by co_frame.
@(private)
co_start :: proc(co: ^Coroutine) {
	if co_switch_stack == nil {
		page := map_code(mem.slice_to_bytes(CO_CODE[:]))
		co_switch_stack = auto_cast page
		co_trampoline = rawptr(uintptr(page) + CO_TRAMPOLINE)
	}
	slot := -1
	for o, i in co_stack_owner {
		if o == nil {slot = i; break}
	}
	assert(slot >= 0, "coroutine stacks exhausted")
	if co_stacks[slot] == nil {
		co_stacks[slot] = co_map_stack(CO_STACK)
	}
	co_stack_owner[slot] = co
	co.ctx.stack = co_stacks[slot]
	co.ctx.sp = co_frame(co, uintptr(co.ctx.stack) + CO_STACK)
}

@(private)
co_swap :: proc(from, to: ^Coroutine) {
	co_switch_stack(&from.ctx.sp, to.ctx.sp)
}

// Only releases the slot; the stack stays mapped (see co_stack_owner) so a
// restored snapshot finds its stack bytes at the same addresses.
@(private)
co_free :: proc(co: ^Coroutine) {
	for &o in co_stack_owner {
		if o == co {o = nil}
	}
}

// Snapshots (snap.odin): the live stacks, from the saved pointer to the top.
@(private)
co_stacks_put :: proc(d: ^[dynamic]u8) {
	for co in co_stack_owner {
		if co == nil {continue}
		top := uintptr(co.ctx.stack) + CO_STACK
		append(d, ..([^]u8)(co.ctx.sp)[:top - uintptr(co.ctx.sp)])
	}
}

// After the regions are taken: co_stack_owner is one, so these are the
// saved owners.
@(private)
co_stacks_take :: proc(d: []u8, pos: ^int) {
	for co in co_stack_owner {
		if co == nil {continue}
		n := int(uintptr(co.ctx.stack) + CO_STACK - uintptr(co.ctx.sp))
		copy(([^]u8)(co.ctx.sp)[:n], take(d, pos, n))
	}
}
