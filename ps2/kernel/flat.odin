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
// interpreter's host frames do (ps2/interp_call.odin interp_body, `.Jr`).
Flat_Ctx :: struct {
	pc:    u32,
	depth: u32,
	// The run has not started: the checks a call makes on entry come first.
	enter: bool,
	// A switch was committed between the two events checks of a `jr` to a
	// register other than $ra: the second (a backward jump's) comes first.
	back:  bool,
	end:   Flat_End,
	// The return addresses; len is the capacity. On the emulated heap, so a
	// snapshot holds them with the rest of the machine.
	ret:   []u32,
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
}
flat: Flat

// The run the interpreter is on: the innermost nested run, else the current
// thread's.
flat_ctx :: #force_inline proc() -> ^Flat_Ctx {
	if flat.nest_depth > 0 {return &flat.nest[flat.nest_depth - 1]}
	return &flat.ee[k.current.id]
}

// Start thread t's run at entry, empty.
flat_start :: proc(t: ^Thread, entry: u32, end: Flat_End) {
	x := &flat.ee[t.id]
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

// Push a call from x to t that returns to ret, with the checks a call makes
// on entry owed (the flat interpreter's flat_reload).
flat_push :: proc(x: ^Flat_Ctx, ret, t: u32) {
	if int(x.depth) == len(x.ret) {flat_grow(x, t)}
	x.ret[x.depth] = ret
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
	if err != nil {cpu.fatal("flat: a shadow stack of %d not allocated", n)}
	copy(ret, x.ret)
	delete(x.ret, core.emu_allocator())
	x.ret = ret
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
	flat.sync = false
	from := flat.from
	if from == nil {return}
	flat.from = nil
	next := k.current
	if from == next {return}
	cycles := cpu.state.cycles
	if from == k.dead {
		k.dead = nil
		free(from)
	} else {
		from.regs = cpu.state
	}
	cpu.state = next.regs
	cpu.state.cycles = cycles
	if flat.wait[next.id] {
		flat.wait[next.id] = false
		cpu.state.r[2].d[0] = u64(i64(next.wait_result))
	}
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
