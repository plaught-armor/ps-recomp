package psx_cpu

import "core:fmt"

import "ps:core"

// A game's own task switch: a routine that saves the running task's $ra,
// $sp and callee-saved registers in that task's memory, loads another's and
// ends with `jr $ra` (Racing Lagoon 0x8006cf24). On the console that jr
// enters the other task; a native call to the routine returns to its caller
// on the host with the other task's registers. call_back and interp_call
// see that (task_returned: the host callee came back on another $sp) and
// switch host coroutines instead, as the BIOS ChangeTh HLE does for BIOS threads. A task
// is known only by where it goes on: the $sp and $ra the routine loaded,
// which are the $sp and link of the call into the routine the task made
// when it switched away. One that matches no suspended task starts a new
// coroutine running the guest code at that $ra.
//
// FLAT has no host coroutines: a task's open calls are its flat run's
// records (Flat_Ctx.frames), and a switch swaps them (Task_Run), as a BIOS
// thread's run has records of its own. flat_task_switch makes it when a
// native callee of the run's guest code came back in another task. One in
// native code (a wasm32 build's blob calling the routine natively) holds the
// run there (flat_hold), host frames and all, as a BIOS preempt in native
// code does, and runs the other tasks on the same records swap inside it
// until one switches back; it then goes on in the native code. Meanwhile
// the others run interpreted (task_holding): their switch back is guest
// code's, which stops the run inside the hold, where native code's would be
// held above the held task's host frames. The native code is named for the
// runs after to leave to the interpreter (flat_native_switched), as a held
// task may never go on. One in a guest call native code made (the
// interpreter's run nested in it) holds the run there too, the others on
// the thread's own run. One in a guest call other host code made cannot
// switch (task_switch counts and warns once), as the host frames below it
// would run on.
//
// The registers are the guest's: the routine saved and loaded them in its
// own memory, so a switch moves none.
//
// What reaps a task that never goes on: the table full, a stale task's
// coroutine is discarded, the one suspended longest. A task is stale once a
// new task starts on the $sp it started on (the game made a task over in
// that slot, at the same entry or another, as Racing Lagoon does with its
// 0x30-byte task slots); it stays until a slot is wanted, as it may be
// suspended on another stack and still go on. No stale task: the one made
// here suspended longest is, with a warning. Both count in tasks_reaped. A
// discarded task the game switches back to cannot go on (its host frames
// are gone): that starts a coroutine at its resume point, and counts in
// tasks_lost. Only coroutines made here are
// discarded: a BIOS thread's or the main one may be suspended in the table
// too (a task switch made in a thread), and stays.
// The pool's coroutines (core CO_POOL, 64) are shared with the BIOS threads
// (MAX_THREADS 16, the main thread's taking none): MAX_TASKS leaves them
// theirs. PS1 has no save states, so the table, like the BIOS threads', is
// not in one.
MAX_TASKS :: 48

// Game-level task switches made, suspended tasks discarded, and switches
// back to a discarded task (of the last LOST_RING discarded).
task_switches, tasks_reaped, tasks_lost: u64

// Suspended tasks dropped as another made here suspended at their $sp and
// link (task_switch): their frames on the guest stack are gone.
tasks_replaced: u64

LOST_RING :: 64

// FLAT: the records a task made here may hold (20 bytes each, Flat_Frame),
// so its stack is at most 20 KB and the table's at most MAX_TASKS times
// that, 960 KB. Deeper is fatal, as FLAT_DEPTH_MAX is for a run's own.
TASK_DEPTH_MAX :: 1024

// The host callee of a call with $sp sp and link came back (call_back,
// interp_call, flat_task_switch). On another $sp, it entered another task
// (task_switch) when task_leaves.
task_returned :: #force_inline proc(sp, link: u32) {
	if task_leaves(sp, link) {task_switch(sp, link)}
}

// Whether the host callee of a call with $sp sp and link that came back
// entered another task: on another $sp, when its $ra is not the link, or is
// and a task suspended there goes on at that $sp and $ra. Tasks waiting in
// one routine go on at one return address (Racing Lagoon 0x8006c988, after
// the switch call in its wait-frames loop), and only $sp tells them apart.
// Back at the link with no such task, the callee moved the stack and
// returned (a SetSp, as Driver 2's f_00090300 is): the call goes on.
task_leaves :: #force_inline proc(sp, link: u32) -> bool {
	to_sp, to_ra := state.r[29], state.r[31]
	if to_sp == sp {return false}
	return to_ra != link || task_waits(to_sp, to_ra)
}

when core.FLAT {
	// A suspended task's records under FLAT: its run's open calls, with the
	// state of the run that goes with them, as a coroutine's host frames are.
	@(private = "file")
	Task_Run :: struct {
		// The run (a BIOS thread's) the records are on.
		ctx:        ^Flat_Ctx,
		frames:     []Flat_Frame,
		depth:      u32,
		start:      u32,
		frame_ret:  u32,
		tail_depth: int,
		// Made here (Flat_Ctx.task).
		task:       bool,
		inner:      ^Mod_Inner,
		// Held in native code (task_go): its level, 1 the first held; 0 not.
		// Its records stay its run's, and it is never discarded.
		held:       int,
	}
} else {
	@(private = "file")
	Task_Run :: ^core.Coroutine
}

@(private = "file")
Guest_Task :: struct {
	// Where it goes on: the $sp and link of its call into the switch.
	sp, ra:      u32,
	// The guest pc and $sp it started at (0, 0: not made here).
	entry, sp0:  u32,
	run:         Task_Run,
	// Order of suspension, for the full table.
	stamp:       u64,
	// A task started since on the $sp it started on.
	stale:       bool,
	// Not a free entry.
	live:        bool,
}

// The suspended tasks.
@(private = "file")
tasks: [MAX_TASKS]Guest_Task

// The running task's start, for its entry when it switches away.
@(private = "file")
task_entry, task_sp0: u32

@(private = "file")
task_stamp: u64

@(private = "file")
task_full_warned: bool

// Where the last LOST_RING discarded tasks would have gone on ($sp, $ra;
// 0, 0: none), for tasks_lost.
@(private = "file")
lost: [LOST_RING][2]u32

@(private = "file")
lost_next: int

// Whether a suspended task goes on at sp and ra. One discarded there
// (a SetSp cannot be told from it) counts in tasks_lost.
@(private = "file")
task_waits :: proc(sp, ra: u32) -> bool {
	for t in tasks {
		if t.live && t.sp == sp && t.ra == ra {return true}
	}
	for &l in lost {
		if l == {sp, ra} {
			tasks_lost += 1
			l = {}
			break
		}
	}
	return false
}

// Discard suspended task t, remembering where it would have gone on.
@(private = "file")
task_reap :: proc(t: ^Guest_Task) {
	task_drop(t.run)
	lost[lost_next] = {t.sp, t.ra}
	lost_next = (lost_next + 1) % LOST_RING
	t^ = {}
	tasks_reaped += 1
}

// The host callee of a call with $sp sp and link came back with another
// task's $sp and $ra. Natively, returns when some task switches back to
// this one, with its registers loaded: $sp sp and $ra link. Under FLAT it
// returns at once, the run's records the other task's (task_go).
task_switch :: proc(sp, link: u32) {
	to_sp, to_ra := state.r[29], state.r[31]
	if !task_can_switch(sp, link) {return}
	if mod_depth > 0 {
		fatal("game task switch to %#08x inside a mod hook: hooks run in frozen time and cannot switch tasks (sp %#08x)", to_ra, to_sp)
	}
	if .Call in core.trace.active && core.trace_pc_ok(to_ra) {
		core.tracef(.Call, "task %08x sp=%x -> %08x sp=%x", link, sp, to_ra, to_sp)
	}
	to: Task_Run
	found := false
	to_entry, to_sp0 := to_ra, to_sp
	for &t in tasks {
		if t.live && t.sp == to_sp && t.ra == to_ra {
			to, to_entry, to_sp0, found = t.run, t.entry, t.sp0, true
			t = {}
			break
		}
	}
	if !found {
		for &l in lost {
			if l == {to_sp, to_ra} {
				tasks_lost += 1
				l = {}
				break
			}
		}
		// The game made a task over on a stack: the one that started
		// there before most likely never goes on. It is discarded first
		// when a slot is wanted, not now: it may be suspended on another
		// stack still and be switched back to (Racing Lagoon 0x8007ebc0).
		for &t in tasks {
			if t.live && t.entry != 0 && t.sp0 == to_sp {
				t.stale = true
			}
		}
	}
	// A free entry, else the stale task suspended longest, else the task
	// made here suspended longest; never one held in native code (FLAT).
	slot := -1
	for t, i in tasks {
		if !t.live {slot = i; break}
		if t.entry == 0 || task_held(t.run) {continue}
		if slot < 0 {slot = i; continue}
		s := &tasks[slot]
		if t.stale != s.stale ? t.stale : t.stamp < s.stamp {slot = i}
	}
	if slot < 0 {
		fatal("game task switch to %#08x: %d tasks suspended, none made by a switch to discard", to_ra, MAX_TASKS)
	}
	if t := &tasks[slot]; t.live {
		if !t.stale && !task_full_warned {
			fmt.eprintfln("cpu: %d game tasks suspended; discarding the one at %#08x (sp %#08x), suspended longest", MAX_TASKS, t.ra, t.sp)
			task_full_warned = true
		}
		task_reap(t)
	}
	// A task made here suspended at this $sp and link already: its frames
	// were on this stack, which this task's overwrote (the game made a task
	// over on it, and the new one waits at the same depth in the same
	// routine), so it never goes on. A switch back here could find it
	// first and run its host frames on this task's registers: Racing
	// Lagoon's slot remade from 0x800b6fd4 to 0x800b6e48, both waiting in
	// 0x8006c910 under a 0x78-byte frame.
	for &t in tasks {
		if t.live && t.entry != 0 && t.sp == sp && t.ra == link && !task_held(t.run) {
			task_drop(t.run)
			t = {}
			tasks_replaced += 1
		}
	}
	task_stamp += 1
	tasks[slot] = {sp, link, task_entry, task_sp0, task_suspend(), task_stamp, false, true}
	task_entry, task_sp0 = to_entry, to_sp0
	task_switches += 1
	task_go(to, found, to_ra)
}

when !core.FLAT {
	@(private = "file")
	task_can_switch :: #force_inline proc(sp, link: u32) -> bool {return true}

	@(private = "file")
	task_suspend :: #force_inline proc() -> Task_Run {return core.co_current}

	@(private = "file")
	task_drop :: proc(run: Task_Run) {core.co_kill(run)}

	@(private = "file")
	task_held :: #force_inline proc(run: Task_Run) -> bool {return false}

	// Switch to the coroutine of the task found, or a new one at ra; back
	// when some task switches back to this one.
	@(private = "file")
	task_go :: proc(to: Task_Run, found: bool, ra: u32) {
		to := to
		if !found {to = core.co_create(task_run, rawptr(uintptr(ra)))}
		// A mod's replacement may switch tasks, as the function it stands in
		// for may: the replacements running are this task's. So are the
		// interpreted calls open (interp_top) and the tail calls in progress
		// on this coroutine's stack, as an IOP thread's are its own.
		inner, top, tails, fr := mod_inner, interp_top, tail_depth, frame_ret
		core.co_switch(to)
		// Resumed: the task that switched back set task_entry and task_sp0.
		mod_inner, interp_top, tail_depth, frame_ret = inner, top, tails, fr
	}

	// The body of a task's coroutine: the guest code at its entry, which
	// never returns.
	@(private = "file")
	task_run :: proc(arg: rawptr) {
		pc := u32(uintptr(arg))
		// No replacement runs in a new task (mod_call_original), and no
		// call of it is open yet.
		mod_inner, interp_top, tail_depth = nil, nil, 0
		// A task whose $ra is its own entry starts over when it returns, as
		// its `jr $ra` does on the console (Racing Lagoon 0x8007e5f8, made
		// with its entry as $ra).
		for {
			call(pc)
			if state.r[31] != pc {
				break
			}
		}
		fatal("game task started at %#08x returned (ra %#08x)", pc, state.r[31])
	}
} else {
	@(private = "file")
	task_warned: bool

	// Tasks held in native code now (task_go), the last held on top.
	@(private = "file")
	task_holds: int

	// A task is held in native code: flat_enter runs no native code, so the
	// other tasks' switch back to it is made by guest code (flat_task_jr),
	// which can stop the run inside the hold. Native code of theirs that
	// switched would be held above it, and the held task's host frames could
	// not go on until that one's had.
	task_holding :: #force_inline proc() -> bool {return task_holds > 0}

	// The run inside a hold stopped to go back to the task held on top.
	@(private = "file")
	task_back: bool

	// The BIOS's: the running thread's slot, and, when the run inside a hold
	// stopped for a thread switch instead, what runs the other threads until
	// that one's turn again (bios.flat_others). Nil, none: the stop is fatal.
	flat_thread: proc() -> int
	flat_others: proc(home: int)

	// A run's own guest code can switch (flat_can_stop), and code under
	// native code it called: task_go holds the run there, in the native code
	// or in a guest call it made (a function the runs before left to the
	// interpreter, which native code calls), host frames and all. In a guest
	// call other host code made the host frames below would run on: it goes
	// on with the other task's registers, as before, counted and warned.
	@(private = "file")
	task_can_switch :: proc(sp, link: u32) -> bool {
		if flat_can_stop() || flat_under_native() {return true}
		task_switches += 1
		if !task_warned {
			fmt.eprintfln("cpu: game task switch from %#08x (sp %#08x) to %#08x (sp %#08x) in native code or a guest call the host made, under FLAT: not supported, goes on", link, sp, state.r[31], state.r[29])
			task_warned = true
		}
		return false
	}

	// The running task's records, now the table's. A continuation open (a
	// mod's replacement chain) is the run's, not the task's: fatal.
	@(private = "file")
	task_suspend :: proc() -> Task_Run {
		if flat_cur.hosts > 0 {
			fatal("game task switch to %#08x with %d continuations open (a mod's replacement) under FLAT: not supported", state.r[31], flat_cur.hosts)
		}
		// The thread's run, under any nested run of a task held (task_go).
		x := flat_own
		held := task_holds + 1 if flat_under_native() else 0
		return {x, x.frames, x.depth, x.start, frame_ret, tail_depth, x.task, mod_inner, held}
	}

	@(private = "file")
	task_drop :: proc(run: Task_Run) {
		x := Flat_Ctx{start = run.start, depth = run.depth, frames = run.frames}
		flat_free(&x)
	}

	@(private = "file")
	task_held :: #force_inline proc(run: Task_Run) -> bool {return run.held != 0}

	// The run goes on in the task found, at ra, or in a new one there. From
	// guest code, at once: the run's records become the task's, and a task
	// held in native code (the one on top) is gone back to by stopping the run
	// inside its hold. From native code, the run is held there and the other
	// tasks run on it until one switches back to this one: then the native
	// code goes on. So from a guest call native code made: the nested run
	// held as well, the others run on the thread's run (flat_own) under it.
	@(private = "file")
	task_go :: proc(to: Task_Run, found: bool, ra: u32) {
		x := flat_own
		if found && to.ctx != x {
			fatal("game task switch to %#08x (sp %#08x): suspended on another BIOS thread's flat run", ra, state.r[29])
		}
		if !flat_under_native() {
			if found && to.held != 0 {
				if to.held != task_holds {
					fatal("game task switch to %#08x (sp %#08x): held in native code below another task's hold (FLAT)", ra, state.r[29])
				}
				task_back = true
				flat_stop = true
				return
			}
			frame_ret, tail_depth, mod_inner = task_load(x, to, found, ra)
			return
		}
		// Its host frames are below this native code's.
		if found && to.held != 0 {flat_block("a game task switch back to a task held in native code")}
		// A task held may never go on (Racing Lagoon makes its slot's task
		// over), and all code runs interpreted while one is: the runs after
		// leave this native code to the interpreter, which switches unheld.
		flat_native_named()
		saved, inner := x^, mod_inner
		h: Flat_Hold
		if !flat_hold(&h) {
			fatal("game task switch to %#08x in native code: %d flat runs held already (FLAT)", ra, FLAT_HOLDS)
		}
		task_holds += 1
		x.frame_ret, x.tail_depth, mod_inner = task_load(x, to, found, ra)
		x.pc, x.goto_owed = ra, false
		home := flat_thread() if flat_thread != nil else 0
		for {
			if flat_run(x) {fatal("a game task's run ended inside a task held in native code (FLAT)")}
			if task_back {break}
			// A BIOS thread switch: the other threads run, then this one's goes on.
			if flat_others == nil {
				fatal("a run stopped inside a game task held in native code (FLAT), with no BIOS to switch threads (ra %#08x)", state.r[31])
			}
			flat_others(home)
		}
		task_back = false
		task_holds -= 1
		x^ = saved
		mod_inner = inner
		flat_resume(&h)
	}

	// Put the records of task to (found), or none yet for a new task at ra,
	// its first call (.Task) owed (flat_settle), on run x; the run's state that
	// goes with them is returned.
	@(private = "file")
	task_load :: proc(x: ^Flat_Ctx, to: Task_Run, found: bool, ra: u32) -> (u32, int, ^Mod_Inner) {
		if !found {
			x.frames, x.depth, x.start, x.task = nil, 0, ra, true
			x.enter = true
			return ra, 0, nil
		}
		x.frames, x.depth, x.start, x.task = to.frames, to.depth, to.start, to.task
		return to.frame_ret, to.tail_depth, to.inner
	}
}
