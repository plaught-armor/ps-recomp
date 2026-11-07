// The kernel's side of FLAT (core/flat.odin): each thread's flat
// interpreter state, and the thread switch as a swap of that state and the
// registers.
//
// A switch is deferred. switch_to only records it: the host frames below it
// (the interpreter, the syscall, the handler) finish first, with cpu.state
// still the switched-from thread's, so a syscall's result lands in that
// thread's v0 as it does when the thread resumes in the coroutine model.
// The flat interpreter commits the switch (flat_commit) once it is back in
// its loop, after each syscall and each run_events.
package ps2_kernel

import "ps:core"

import cpu "../cpu"

// Shadow return stack entries a run starts with. It grows by doubling, on
// the emulated heap, up to FLAT_DEPTH_MAX: deeper guest recursion is fatal.
FLAT_DEPTH_MIN :: 64
FLAT_DEPTH_MAX :: 32768
// Guest runs the host starts inside one (a user syscall handler, an
// interrupt handler).
FLAT_NEST :: 8
FLAT_THREADS :: 256
#assert(len(k.threads) == FLAT_THREADS)

// What a `jr $ra` at depth 0 ends.
Flat_End :: enum u8 {
	Thread, // a created thread's entry: dormant until started again
	Main,   // thread 1's boot entry: fatal
	Exec,   // a program ExecPS2 started: fatal
	Call,   // a run the host started (flat_call): back to the host
}

// One guest run: where it is, and the return addresses of the calls it is
// inside, innermost last. A call returns to the address it pushed at the
// first `jr $ra` (or ERET) at its depth, whatever $ra holds then, as the
// interpreter's host frames do (ps2/interp_call.odin interp_body, `.Jr`),
// unless $ra and sp are an outer call's: a longjmp, which unwinds to it
// (ps2/interp_flat.odin flat_unwind).
Flat_Ctx :: struct {
	pc:    u32,
	depth: u32,
	// The run has not started: the checks a call makes on entry come first.
	enter: bool,
	// A switch was committed between the two events checks of a `jr` to a
	// register other than $ra: the second (a backward jump's) comes first.
	back:  bool,
	end:   Flat_End,
	// The return addresses, and the guest sp at each call (an unwind's
	// check, ps2/interp_flat.odin flat_unwind); len is the capacity. On the
	// emulated heap, so a snapshot holds them with the rest of the machine.
	ret:   []u32,
	sp:    []u32,
}

// Emulated state: a snapshot holds it with the rest of the machine.
Flat :: struct {
	ee:   [FLAT_THREADS]Flat_Ctx, // by thread id
	nest: [FLAT_NEST]Flat_Ctx,
	nest_depth: int,
	// The thread a switch is pending from (nil: none). k.current is the
	// thread switched to already.
	from: ^Thread,
	// Blocked in a syscall that returns its wait_result: set as the switch
	// away is recorded, written to v0 as the switch back commits.
	wait: [FLAT_THREADS]bool,
	// The interpreter is in a syscall, an events check or a thread's end,
	// after which it commits a switch. A switch anywhere else would leave
	// the switched-from thread running on: fatal.
	sync: bool,
	// run_events' spin flags across a snapshot operation at vblank, which
	// may load a state.
	dirty: u32,
	// Where flat_idle is, and the status it puts back as it ends.
	idle:        Flat_Idle,
	idle_status: u32,
}

Flat_Idle :: enum u8 {
	None,
	Owed, // reschedule found no thread to run, in a syscall
	On,   // flat_idle has begun: idle_status is saved
}
flat: Flat

// The run the interpreter is on: the innermost nested run, else the current
// thread's.
flat_ctx :: #force_inline proc() -> ^Flat_Ctx {
	if flat.nest_depth > 0 {return &flat.nest[flat.nest_depth - 1]}
	return &flat.ee[k.current.id]
}

// Called with the return addresses a run drops when it starts over (a
// thread's end and restart, an exec), never returned through: ps2's mods
// free the continuations their marks name. nil with no mods. Host state.
flat_drop: proc(ret: []u32)

// Start thread t's run at entry, empty.
flat_start :: proc(t: ^Thread, entry: u32, end: Flat_End) {
	x := &flat.ee[t.id]
	if flat_drop != nil {flat_drop(x.ret[:x.depth])}
	x.pc = entry
	x.depth = 0
	x.enter = true
	x.end = end
	flat.wait[t.id] = false
}

// Push a nested run at entry for the host (flat_call); pop it after.
flat_nest_push :: proc(entry: u32) -> ^Flat_Ctx {
	if flat.nest_depth == FLAT_NEST {cpu.fatal("guest calls from the host nested %d deep at %08x", FLAT_NEST, entry)}
	flat.nest_depth += 1
	x := &flat.nest[flat.nest_depth - 1]
	x.pc = entry
	x.depth = 0
	x.enter = true
	x.end = .Call
	return x
}

flat_nest_pop :: proc() {
	flat.nest_depth -= 1
}

// Bit 0 of a return address on the shadow stack: the call was made by host
// code that has nothing left to do after it (FLAT_HOST_TAIL). Its return is
// not counted against $ra, which the host did not set.
FLAT_HOST_TAIL :: u32(1)

// Push a call from x to t that returns to ret, with the checks a call makes
// on entry owed (the flat interpreter's flat_reload).
flat_push :: proc(x: ^Flat_Ctx, ret, t: u32) {
	if int(x.depth) == len(x.ret) {flat_grow(x, t)}
	x.ret[x.depth] = ret
	x.sp[x.depth] = u32(cpu.state.r[29].d[0])
	x.depth += 1
	cpu.flat_max_depth = max(cpu.flat_max_depth, x.depth)
	x.pc = t
	x.enter = true
}

@(private = "file")
flat_grow :: proc(x: ^Flat_Ctx, t: u32) {
	n := max(2 * len(x.ret), FLAT_DEPTH_MIN)
	if n > FLAT_DEPTH_MAX {cpu.fatal("guest calls nested %d deep at %08x", FLAT_DEPTH_MAX, t)}
	ret, err := make([]u32, n, core.emu_allocator())
	sp, err_sp := make([]u32, n, core.emu_allocator())
	if err != nil || err_sp != nil {cpu.fatal("flat: a shadow stack of %d not allocated", n)}
	copy(ret, x.ret)
	copy(sp, x.sp)
	delete(x.ret, core.emu_allocator())
	delete(x.sp, core.emu_allocator())
	x.ret, x.sp = ret, sp
}

// A syscall the program installed (SetSyscall) at pc runs its handler fn,
// as cpu.call. Under FLAT that call is not run nested: syscall has nothing
// left to do after it, so it is pushed on the running run, a host-tail
// record returning to the instruction after the syscall, and the handler
// runs at that run's depth. A thread switch or a wait inside it then parks
// the thread as anywhere else, and its `jr $ra` pops the record.
@(private)
flat_syscall :: proc(pc, fn: u32) {
	flat_push(flat_ctx(), (pc + 4) | FLAT_HOST_TAIL, fn)
}

// Record the switch to next (switch_to under FLAT).
@(private)
flat_switch :: proc(next: ^Thread) {
	if flat.nest_depth > 0 {cpu.fatal("thread switch to %d in a nested guest call", next.id)}
	if !flat.sync {cpu.fatal("thread switch to %d outside a syscall or events check", next.id)}
	cur := k.current
	if cur.status == .Run {cur.status = .Ready}
	if flat.from == nil {flat.from = cur}
	k.current = next
	next.status = .Run
}

// The interpreter enters a syscall, an events check or a thread's end. A
// nested run is inside its host caller's window already, and commits
// nothing: its host caller does.
flat_sync :: #force_inline proc() {
	if flat.nest_depth == 0 {flat.sync = true}
}

// Leave that: carry out the pending switch, if any. Save the registers of
// the thread it is from (or free that thread, deleted) and load the current
// one's, with the cycle count carried as switch_to does.
flat_commit :: proc() {
	if flat.nest_depth > 0 {return}
	if flat.idle != .None {flat_idle()}
	flat.sync = false
	from := flat.from
	flat.from = nil
	next := k.current
	if from != nil && from != next {
		cycles := cpu.state.cycles
		if from == k.dead {
			k.dead = nil
			free(from)
		} else {
			from.regs = cpu.state
		}
		cpu.state = next.regs
		cpu.state.cycles = cycles
	}
	// Set only for a thread switched away, or one blocked as an idle was
	// owed, which may run on with no switch.
	if flat.wait[next.id] {
		flat.wait[next.id] = false
		cpu.state.r[2].d[0] = u64(i64(next.wait_result))
	}
}

// reschedule's idle, done after the syscall that owed it: skip to the next
// event and run it, until a thread is ready. The state it keeps across
// run_events is in flat, not in host locals, so a snapshot saved here
// loads at any other events check (and one saved there loads here) and
// goes on alike: the first commit after it finishes the idle.
@(private = "file")
flat_idle :: proc() {
	if flat.idle == .Owed {
		flat.idle = .On
		flat.idle_status = cpu.state.cop0[12]
	}
	for flat.idle != .None {
		if next := pick_thread(); next != nil {
			if next != k.current {flat_switch(next)}
			break
		}
		idle_skip()
		// As idle does: interrupts enabled, whatever the thread's status.
		cpu.state.cop0[12] = STATUS_USER
		run_events()
	}
	if flat.idle == .None {return}
	cpu.state.cop0[12] = flat.idle_status
	flat.idle = .None
}

flat_snap :: proc() {
	when core.FLAT {core.snap_add(&flat)}
}

// A created thread's entry returned: dormant until started again, as
// thread_main parks it.
flat_thread_end :: proc() {
	k.current.status = .Dormant
	flat_sync()
	reschedule()
	flat_commit()
}
