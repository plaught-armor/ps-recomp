package psx_cpu

@(require) import "core:fmt" // used only without FLAT

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

LOST_RING :: 64

// The host callee of a call with $sp sp and link came back (call_back,
// interp_call). On another $sp, it entered another task (task_switch) when
// its $ra is not the link, or is and a task suspended there goes on at that
// $sp and $ra: tasks waiting in one routine go on at one return address
// (Racing Lagoon 0x8006c988, after the switch call in its wait-frames loop),
// and only $sp tells them apart. Back at the link with no such task, the
// callee moved the stack and returned (a SetSp, as Driver 2's f_00090300
// is): the call goes on.
task_returned :: #force_inline proc(sp, link: u32) {
	to_sp, to_ra := state.r[29], state.r[31]
	if to_sp == sp {return}
	if to_ra == link && !task_waits(to_sp, to_ra) {return}
	task_switch(sp, link)
}

when !core.FLAT {
	// Whether a suspended task goes on at sp and ra. One discarded there
	// (a SetSp cannot be told from it) counts in tasks_lost.
	@(private = "file")
	task_waits :: proc(sp, ra: u32) -> bool {
		for t in tasks {
			if t.co != nil && t.sp == sp && t.ra == ra {return true}
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

	@(private = "file")
	Guest_Task :: struct {
		// Where it goes on: the $sp and link of its call into the switch.
		sp, ra:      u32,
		// The guest pc and $sp its coroutine started at (0, 0: not made here).
		entry, sp0:  u32,
		co:          ^core.Coroutine,
		// Order of suspension, for the full table.
		stamp:       u64,
		// A task started since on the $sp it started on.
		stale:       bool,
	}

	// The suspended tasks; co nil is a free entry.
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

	// Discard suspended task t, remembering where it would have gone on.
	@(private = "file")
	task_reap :: proc(t: ^Guest_Task) {
		core.co_kill(t.co)
		lost[lost_next] = {t.sp, t.ra}
		lost_next = (lost_next + 1) % LOST_RING
		t^ = {}
		tasks_reaped += 1
	}

	// The host callee of a call with $sp sp and link came back with another
	// task's $sp and $ra. Returns when some task switches back to this one,
	// with its registers loaded: $sp sp and $ra link.
	task_switch :: proc(sp, link: u32) {
		to_sp, to_ra := state.r[29], state.r[31]
		if mod_depth > 0 {
			fatal("game task switch to %#08x inside a mod hook: hooks run in frozen time and cannot switch tasks (sp %#08x)", to_ra, to_sp)
		}
		if .Call in core.trace.active && core.trace_pc_ok(to_ra) {
			core.tracef(.Call, "task %08x sp=%x -> %08x sp=%x", link, sp, to_ra, to_sp)
		}
		to: ^core.Coroutine
		to_entry, to_sp0 := to_ra, to_sp
		for &t in tasks {
			if t.co != nil && t.sp == to_sp && t.ra == to_ra {
				to, to_entry, to_sp0 = t.co, t.entry, t.sp0
				t = {}
				break
			}
		}
		if to == nil {
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
				if t.co != nil && t.entry != 0 && t.sp0 == to_sp {
					t.stale = true
				}
			}
			to = core.co_create(task_run, rawptr(uintptr(to_ra)))
		}
		// A free entry, else the stale task suspended longest, else the task
		// made here suspended longest.
		slot := -1
		for t, i in tasks {
			if t.co == nil {slot = i; break}
			if t.entry == 0 {continue}
			if slot < 0 {slot = i; continue}
			s := &tasks[slot]
			if t.stale != s.stale ? t.stale : t.stamp < s.stamp {slot = i}
		}
		if slot < 0 {
			fatal("game task switch to %#08x: %d tasks suspended, none made by a switch to discard", to_ra, MAX_TASKS)
		}
		if t := &tasks[slot]; t.co != nil {
			if !t.stale && !task_full_warned {
				fmt.eprintfln("cpu: %d game tasks suspended; discarding the one at %#08x (sp %#08x), suspended longest", MAX_TASKS, t.ra, t.sp)
				task_full_warned = true
			}
			task_reap(t)
		}
		task_stamp += 1
		tasks[slot] = {sp, link, task_entry, task_sp0, core.co_current, task_stamp, false}
		task_entry, task_sp0 = to_entry, to_sp0
		task_switches += 1
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

	// FLAT keeps no suspended tasks.
	@(private = "file")
	task_waits :: proc(sp, ra: u32) -> bool {return false}

	// FLAT has no host coroutines to hold a task's native frames on, so the
	// call goes on at its link with the other task's registers, as before:
	// counted and warned.
	task_switch :: proc(sp, link: u32) {
		task_switches += 1
		if !task_warned {
			fmt.eprintfln("cpu: game task switch from %#08x (sp %#08x) to %#08x (sp %#08x) under FLAT: not supported, goes on at the link", link, sp, state.r[31], state.r[29])
			task_warned = true
		}
	}
}
