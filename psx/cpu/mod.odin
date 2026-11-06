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

// Top of the stack before and after hooks run on: set before mod_install.
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
			m^ = {site = i32(site)}
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
		call(r.fn)
	} else if mod_runs[run].original != nil {
		mod_runs[run].original()
	} else {
		call_guest(addr)
	}
	mod_after(c, entry)
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
	// for none resident: the call as call_slow makes it). The chain is picked
	// at that step, not at the push: a run can stop between the two, and
	// another thread may swap the overlay in the meantime. site and run index
	// this install's tables, so a save state that holds a Mod_Cont is only
	// good for the same mods.
	@(private = "file")
	Mod_Cont :: struct {
		site, run: i32,
		entry:     [4]u32,
		called:    bool,
	}
	#assert(size_of(Mod_Cont) <= FLAT_HOST_WORDS * 4)

	// flat_step for the PS1: the step of a mod thunk's chain. The first runs
	// the before hooks and calls the replacement or the original on the run;
	// the next, once it returned, runs the after hooks.
	mod_flat_step :: proc(x: ^Flat_Ctx, h: ^Flat_Host) {
		if h.tag != FLAT_MOD {fatal("psx: flat continuation %d", h.tag)}
		m := (^Mod_Cont)(&h.w)
		if m.called {
			if m.run >= 0 {mod_after(&mod_runs[m.run].chain, m.entry)}
			flat_pop_cont()
			return
		}
		m.called = true
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
	// An event the hook scheduled or an interrupt it raised (a device it
	// wrote) lowered next_event, or came due and was held: run_events
	// then runs as the game goes on, and handles what is due.
	due := next_event != max(u64) || mod_held
	state, cop0, mod_held = saved, saved_cop0, held
	next_event = due ? min(next, saved.cycles) : next
}
