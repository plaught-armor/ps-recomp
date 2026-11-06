// Mod hooks on guest functions: the chains core/mod.odin makes, installed in
// the dispatch tables. A hooked function's entry becomes its address's
// thunk (mod_thunks), which runs the function's chain each time it is
// called:
//
//   - before hooks, in load order, then
//   - the replacement, or the function itself (the original), then
//   - after hooks, in reverse load order.
//
// Before and after hooks run on the mod stack (mod_sp) and with frozen time.
// Every register, the cycle count and cop0 included, is put back when a hook
// returns, and no event or interrupt is handled while it runs (run_events
// holds them while mod_depth > 0). So a hook changes the game only through
// memory. An event or interrupt that comes due in a hook is handled as soon
// as it returns; an event a hook schedules counts its delay from the hook's
// own cycle count, so it lands that much later in game time. A before hook
// sees the function's arguments (a0-a3). An after hook sees them too, and
// the results (v0, v1). The replacement runs on the game's stack and in its
// time, as the function itself would, unless it was called from inside a
// hook: then it runs in the hook's frozen time. A hook must not switch
// threads (fatal) or wait for an event (none comes).
//
// A replacement calls the function it replaces with mod_call_original (a
// call to MOD_ORIGINAL): the original, past the thunk, so with no hooks,
// on the arguments in a0-a3 then, returning its results. It is the
// innermost running replacement's: one a replacement's call reached runs
// its own until it returns. A call to it from a before or after hook, from
// inside an original (mod_original), from guest code host code called back
// (call_callback, the BIOS's handlers), or with no replacement running, is
// fatal, the same on both builds. So is one whose function's code is no
// longer in RAM (another overlay at its slot): the message names the
// overlay.
//
// mod_install picks the entry by what runs the function now:
//
//   - executable function, recompiled: its fixed slot, through hook
//     (watch.odin keeps it across demotion and promotion);
//   - overlay function, recompiled: its signed entry's procedure;
//   - overlay function, interpreted: a signed entry of its own; the
//     original is the interpreter (call_guest);
//   - executable function, interpreted: its fixed slot; the original is
//     the interpreter.
//
// The thunk runs a chain only while the code its key names is in RAM: the
// overlay's id at its slot, and the function's first words. Otherwise it
// runs the call as if no mod were loaded.
//
// Only calls are hooked. A jump that the interpreter steps into, rather
// than taking it as a tail call, enters the function without its hooks:
// a `j` past a run's first word, or a `jr` through a register other than
// $ra to a target that is not in the fixed table (interp.goto_target). So a
// jump into an overlay function or an interpreted one is missed.
// Recompiled code turns every jump out of a function into a call.
//
// Under FLAT, a thunk a flat run's guest code called (not call, from host
// code) runs its chain as a continuation (mod_flat_step): the hooks run
// nested, as in the recursive model, and the replacement or an interpreted
// original runs on the run, where a thread switch or a wait may stop it, as
// it could with no mod loaded. A thunk called from host code (a hook's call,
// an HLE stub's) runs its chain nested, and a stop inside it is fatal. So
// does a hooked function recursing more than FLAT_HOST (4) deep: the run
// has no continuation left for it.
//
// A call costs nothing more with no mods: each hooked address has a thunk
// of its own, which knows its address, so call stores nothing.
package psx_cpu

import "core:fmt"
import "ps:core"

// Top of the stack before and after hooks run on: set before mod_install
// (mod_ram_load sets the mod region's).
// A hook called while one runs (a hook's call to a hooked function) goes
// on below that hook's stack pointer.
mod_sp: u32

// A chain as installed. original runs the function itself: the procedure
// its entry had before, or nil for the interpreter.
@(private = "file")
Mod_Run :: struct {
	chain:    core.Mod_Chain,
	original: Func_Proc,
}

@(private = "file")
mod_runs: [dynamic]Mod_Run

// Functions hooked at most: one thunk each.
MOD_SITES :: 512

// A hooked address: its chains, indexes into mod_runs, one per overlay
// and code the address has.
@(private = "file")
Mod_Site :: struct {
	addr: u32,
	runs: [dynamic]int,
}

@(private = "file")
mod_sites: [dynamic]Mod_Site

// Index into mod_sites of each hooked address.
@(private = "file")
mod_at: map[u32]int

// Thunk k runs mod_sites[k]: a procedure per address, made at compile time.
@(private = "file")
mod_thunks: [MOD_SITES]Func_Proc

@(private = "file")
mod_thunk :: proc($K: int) -> Func_Proc {
	return proc() {mod_enter(K)}
}

@(private = "file")
mod_thunks_fill :: proc($LO, $HI: int) {
	when HI - LO == 1 {
		mod_thunks[LO] = mod_thunk(LO)
	} else {
		mod_thunks_fill(LO, (LO + HI) / 2)
		mod_thunks_fill((LO + HI) / 2, HI)
	}
}

// The replacements running in the recursive model (mod_enter's call),
// innermost first, on the host stack: what mod_call_original calls. depth
// is mod_depth when it was called, so a hook it reached does not get its
// original. run -1 is a marker, where code runs that is not inside the
// replacement below it: an original (mod_original) or a callback of host
// code (call_callback). flat is the flat run then running (FLAT; nil none):
// a continuation pushed on another run is inside it. Each thread has its
// own (psx/bios change_thread); Exec and LoadExec start the new program
// with none (psx/bios exec).
//
// mod_inner, mod_depth and mod_held are not in a save state: when PS1
// snapshots land they become snap_add state (docs/porting.md, Mods).
Mod_Inner :: struct {
	run, depth: int,
	prev:       ^Mod_Inner,
	flat:       ^Flat_Ctx,
}
mod_inner: ^Mod_Inner

// A Mod_Inner for run on top of mod_inner, for the caller to link in.
@(private = "file")
mod_inner_at :: proc(run: int) -> Mod_Inner {
	when core.FLAT {
		return {run, mod_depth, mod_inner, flat_cur}
	} else {
		return {run, mod_depth, mod_inner, nil}
	}
}

// Call the guest code at addr for host code, as call does: an interrupt
// handler, a callback, a compare function. Under a marker: the code it runs
// is not inside the replacement that may be running, so a mod_call_original
// it makes outside a replacement of its own is fatal, as it is under FLAT,
// where such code runs nested, on a run of its own.
call_callback :: proc(addr: u32) {
	mark := mod_inner_at(-1)
	mod_inner = &mark
	call(addr)
	mod_inner = mark.prev
}

// Hooks now running, nested. While it is above 0, run_events handles
// nothing and sets mod_held instead.
mod_depth: int

// An event or interrupt came due in the running hook: mod_call has it
// handled as soon as the hook returns.
mod_held: bool

// Install chains (core.mod_chains), once, after every other hook. mods are
// the manifests the chains index, for errors; err is in the temp
// allocator, and on an error nothing is installed. The chains must outlive
// the machine.
mod_install :: proc(mods: []core.Mod_Manifest, chains: []core.Mod_Chain) -> (err: string) {
	if len(chains) == 0 {return ""}
	if len(mod_runs) != 0 {return "mod: hooks installed twice"}
	if mod_sp == 0 {return "mod: no mod stack"}
	addrs := make(map[u32]bool, context.temp_allocator)
	for c in chains {
		if e := mod_check(mods[mod_chain_mod(c)].id, c.key); e != "" {return e}
		addrs[c.key.addr] = true
	}
	if len(addrs) > MOD_SITES {
		return fmt.tprintf("mod: %d functions hooked, at most %d", len(addrs), MOD_SITES)
	}
	if mod_thunks[0] == nil {mod_thunks_fill(0, MOD_SITES)}
	if dispatch.fixed == nil {
		dispatch.fixed = make([]Func_Proc, FN_TABLE_SIZE)
	}
	for c in chains {
		k := c.key
		run := Mod_Run {
			chain = c,
		}
		site, seen := mod_at[k.addr]
		if !seen {
			site = len(mod_sites)
			mod_at[k.addr] = site
			append(&mod_sites, Mod_Site{addr = k.addr})
		}
		thunk := mod_thunks[site]
		if k.slot == 0 {
			// One executable chain at an address: mod_check found its code.
			ok: bool
			run.original, ok = hook(k.addr, thunk)
			if !ok {dispatch.fixed[fn_index(k.addr)] = thunk}
		} else {
			found := false
			list := dispatch.overlay[k.addr] // a copy of the header: the entries are shared
			for &e in list {
				if e.slot == k.slot && e.id == k.id && e.sig == k.sig {
					run.original, e.fn, found = e.fn, thunk, true
					break
				}
			}
			if !found {
				register_overlay_funcs({{addr = k.addr, slot = k.slot, id = k.id, sig = k.sig, fn = thunk}})
			}
		}
		// Overlay chains first: with its overlay in, a function's overlay key
		// is the more specific one.
		if k.slot != 0 {
			inject_at(&mod_sites[site].runs, 0, len(mod_runs))
		} else {
			append(&mod_sites[site].runs, len(mod_runs))
		}
		append(&mod_runs, run)
	}
	return ""
}

// Why mod `who` cannot hook the function k names, or "". An executable
// function's code must be in RAM now, as the mod was built for it.
@(private = "file")
mod_check :: proc(who: string, k: core.Mod_Key) -> string {
	if !is_ram_addr(k.addr) || k.addr & 3 != 0 {
		return fmt.tprintf("mod %s: a hook on %08x, which is not a function in RAM", who, k.addr)
	}
	if k.slot != 0 {
		if !is_ram_addr(k.slot) || k.slot & 3 != 0 || k.slot >= k.addr {
			return fmt.tprintf("mod %s: a hook on %08x in an overlay at %08x", who, k.addr, k.slot)
		}
		return ""
	}
	if k.id != 0 {
		return fmt.tprintf("mod %s: a hook on %08x with id %08x and no slot", who, k.addr, k.id)
	}
	if !mod_resident(k) {
		return fmt.tprintf("mod %s: the code at %08x is not the code it was built for", who, k.addr)
	}
	return ""
}

// A mod of the chain, for errors.
@(private = "file")
mod_chain_mod :: proc(c: core.Mod_Chain) -> int {
	if r, ok := c.replace.?; ok {return r.mod}
	if len(c.before) != 0 {return c.before[0].mod}
	return c.after[0].mod
}

// What thunk k runs: the chain of the hooked code in RAM at its address,
// or, with none, the call as call_slow would.
@(private = "file")
mod_enter :: proc(site: int) {
	when core.FLAT {
		if !flat_host_call && flat_cur != nil && flat_cur.hosts < FLAT_HOST {
			m := (^Mod_Cont)(&flat_push_cont(FLAT_MOD).w)
			m^ = {site = i32(site), depth = i32(mod_depth)}
			for &a, i in m.entry {a = state.r[4 + i]}
			return
		}
	}
	addr := mod_sites[site].addr
	run := mod_pick(site)
	if run < 0 {
		call_slow(addr)
		return
	}
	c := &mod_runs[run].chain
	entry := mod_args()
	mod_before(c)
	if r, ok := c.replace.?; ok {
		inner := mod_inner_at(run)
		mod_inner = &inner
		call(r.fn)
		mod_inner = inner.prev
	} else {
		mod_original(run)
	}
	mod_after(c, entry)
}

// Run the function run's chain hooks, past its thunk: the procedure its
// entry had (counted as native code under FLAT), or the interpreter. Under
// a marker: guest code inside it is not inside the replacement that called
// it.
@(private = "file")
mod_original :: proc(run: int) {
	mark := mod_inner_at(-1)
	mod_inner = &mark
	defer mod_inner = mark.prev
	if o := mod_runs[run].original; o == nil {
		call_guest(mod_runs[run].chain.key.addr)
	} else {
		when core.FLAT {flat_call_native(o)} else {o()}
	}
}

// A call to MOD_ORIGINAL (host_call): the original of the innermost running
// replacement. Under FLAT, that is the innermost mod continuation of the
// running flat run, when it has one pushed since mod_inner (mod_inner's
// flat is another run: a run's frames do not grow while host code it called
// runs, and the runs nested since are newer). An interpreted original whose
// replacement guest code on the run called runs as a continuation, where a
// stop may come, as it does under mod_flat_step; one from host code (native
// code's call) runs nested.
mod_call_original :: proc() {
	i := mod_inner
	when core.FLAT {
		x := flat_cur
		if x != nil && (i == nil || i.flat != x) {
			if site, run, depth, ok := mod_flat_replacing(x); ok {
				if run < 0 || int(depth) != mod_depth {mod_original_fatal()}
				mod_original_resident(run)
				if mod_runs[run].original == nil && !flat_host_call && x.hosts < FLAT_HOST {
					m := (^Mod_Cont)(&flat_push_cont(FLAT_MOD).w)
					m^ = {site = site, run = i32(run), depth = depth, orig = true}
				} else {
					mod_original(run)
				}
				return
			}
		}
	}
	if i == nil || i.run < 0 || i.depth != mod_depth {mod_original_fatal()}
	mod_original_resident(i.run)
	mod_original(i.run)
}

// Fatal unless run's code is in RAM, as when its replacement was called: an
// overlay loaded over it meanwhile is named.
@(private = "file")
mod_original_resident :: proc(run: int) {
	k := mod_runs[run].chain.key
	if mod_resident(k) {return}
	if k.slot != 0 {
		fatal("mod: mod_call_original for %08x, in overlay %08x at %08x: that code is no longer in RAM (overlay %08x there)", k.addr, k.id, k.slot, r32(k.slot))
	}
	fatal("mod: mod_call_original for %08x: that code is no longer in RAM", k.addr)
}

@(private = "file")
mod_original_fatal :: proc() -> ! {
	fatal("mod: a call to mod_call_original (%08x) outside a replacement (ra %08x)", u32(MOD_ORIGINAL), state.r[31])
}

// The run of site's chain whose hooked code is in RAM now, or -1.
@(private = "file")
mod_pick :: proc(site: int) -> int {
	for k in mod_sites[site].runs {
		if mod_resident(mod_runs[k].chain.key) {return k}
	}
	return -1
}

@(private = "file")
mod_args :: proc() -> [4]u32 {
	return {state.r[4], state.r[5], state.r[6], state.r[7]}
}

@(private = "file")
mod_before :: proc(c: ^core.Mod_Chain) {
	for f in c.before {mod_call(f.fn)}
}

// The after hooks, each with the arguments the function had (entry) and its
// results; then a0-a3 as the function left them.
@(private = "file")
mod_after :: proc(c: ^core.Mod_Chain, entry: [4]u32) {
	if len(c.after) == 0 {return}
	done := mod_args()
	for f in c.after {
		state.r[4], state.r[5], state.r[6], state.r[7] = entry[0], entry[1], entry[2], entry[3]
		mod_call(f.fn)
	}
	state.r[4], state.r[5], state.r[6], state.r[7] = done[0], done[1], done[2], done[3]
}

when core.FLAT {
	// The continuation tag of a mod thunk's chain.
	FLAT_MOD :: 1

	// A mod thunk's continuation, in Flat_Host.w: the thunk's site, the
	// arguments it was called with, whether the replacement or the original
	// was called, and from then the chain run (an index into mod_runs, or -1
	// for none resident: the call as call_slow makes it). With orig, it is
	// mod_call_original's instead: it calls the run's interpreted original,
	// and no hook. The chain is picked
	// at that step, not at the push: a run can stop between the two, and
	// another thread may swap the overlay in the meantime. site and run index
	// this install's tables, so a save state that holds a Mod_Cont is only
	// good for the same mods.
	@(private = "file")
	Mod_Cont :: struct {
		site, run: i32,
		depth:     i32, // mod_depth at the push
		entry:     [4]u32,
		called:    bool,
		orig:      bool,
	}
	#assert(size_of(Mod_Cont) <= FLAT_HOST_WORDS * 4)

	// flat_step for the PS1: the step of a mod thunk's chain. The first runs
	// the before hooks and calls the replacement or the original on the run;
	// the next, once it returned, runs the after hooks.
	mod_flat_step :: proc(x: ^Flat_Ctx, h: ^Flat_Host) {
		if h.tag != FLAT_MOD {fatal("psx: flat continuation %d", h.tag)}
		m := (^Mod_Cont)(&h.w)
		if m.called {
			if m.run >= 0 && !m.orig {mod_after(&mod_runs[m.run].chain, m.entry)}
			flat_pop_cont()
			return
		}
		m.called = true
		if m.orig {
			flat_call(mod_sites[m.site].addr, .Guest)
			return
		}
		m.run = i32(mod_pick(int(m.site)))
		if m.run < 0 {
			flat_call(mod_sites[m.site].addr, .Slow)
			return
		}
		run := &mod_runs[m.run]
		mod_before(&run.chain)
		if r, ok := run.chain.replace.?; ok {
			flat_call(r.fn)
		} else if run.original != nil {
			flat_call_native(run.original)
			mod_after(&run.chain, m.entry)
			flat_pop_cont()
		} else {
			flat_call(mod_sites[m.site].addr, .Guest)
		}
	}

	// The site, run and depth of x's innermost mod continuation, when it
	// called a replacement that is running: the guest code on top of x is
	// inside it. Run -1 when the code is inside an original, or in a hook or
	// a chain with no replacement; ok false when x has no mod continuation.
	@(private = "file")
	mod_flat_replacing :: proc(x: ^Flat_Ctx) -> (site: i32, run: int, depth: i32, ok: bool) {
		for k := int(x.depth) - 1; k >= 0; k -= 1 {
			f := x.frames[k]
			if f.kind != .Cont || x.host[f.slot].tag != FLAT_MOD {continue}
			m := (^Mod_Cont)(&x.host[f.slot].w)
			if !m.called || m.orig || m.run < 0 {return 0, -1, 0, true}
			if _, r := mod_runs[m.run].chain.replace.?; !r {return 0, -1, 0, true}
			return m.site, int(m.run), m.depth, true
		}
		return 0, -1, 0, false
	}
}

@(private = "file")
mod_resident :: proc(k: core.Mod_Key) -> bool {
	if k.slot != 0 && r32(k.slot) != k.id {return false}
	for w, i in k.sig {
		if r32(k.addr + u32(i) * 4) != w {return false}
	}
	return true
}

// Call the before or after hook at fn on the mod stack, in frozen time,
// and put every register back after.
@(private = "file")
mod_call :: proc(fn: u32) {
	saved, saved_cop0, next, held := state, cop0, next_event, mod_held
	if mod_depth == 0 {state.r[29] = mod_sp}
	next_event, mod_held = max(u64), false
	mod_depth += 1
	call(fn)
	mod_depth -= 1
	mod_ram_check(fn)
	// An event the hook scheduled or an interrupt it raised (a device it
	// wrote) lowered next_event, or came due and was held: run_events
	// then runs as the game goes on, and handles what is due.
	due := next_event != max(u64) || mod_held
	state, cop0, mod_held = saved, saved_cop0, held
	next_event = due ? min(next, saved.cycles) : next
}
