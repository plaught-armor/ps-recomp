// Mod hooks on the EE's guest functions: the chains core/mod.odin makes,
// run each time a hooked function is called, as the PS1's
// (psx/cpu/mod.odin):
//
//   - before hooks, in load order, then
//   - the replacement, or the function itself (the original), then
//   - after hooks, in reverse load order.
//
// Before and after hooks run on the mod stack (mem.mod_sp) and with frozen
// time. Every register, 128 bits each, HI/LO, the FPU, cop0 and the cycle
// count included, is put back when a hook returns, and no event or
// interrupt is handled while it runs (run_events holds them while
// cpu.mod_depth > 0). So a hook changes the game only through memory. An
// event or interrupt that comes due in a hook is handled as soon as it
// returns. A before hook sees the function's arguments (a0-a7, $4-$11,
// and the game's stack); an after hook sees those registers too, and the
// results (v0, v1). The replacement runs on the game's stack and in
// its time, as the function would. A hook must not switch threads, start
// another program, or wait (fatal).
//
// Mods are n32 code, which keeps only the low 64 bits of the registers it
// must save ($16-$23, $28, $30: sd and ld), while the game keeps all 128
// (lq and sq), and keeps only the even FPU registers of $f20-$f31, while
// the game keeps all twelve. So the upper 64 bits of those integer
// registers and all of $f20-$f31 are put back when a replacement returns,
// as a hook's are: a mod's MMI or float code may change them. An
// original that returns a value in one of them, as no compiled code does,
// returns it to the replacement only, not to the game.
//
// A replacement calls the function it replaces with mod_call_original (a
// call to mem.MOD_ORIGINAL): the original, with no hooks, on the arguments
// in a0-a7 and on the stack then, reached by a call (jal, jalr) only: a tail jump to it is
// not supported. It is the innermost running replacement's. A call to it
// from a before or after hook, from inside an original, from an interrupt
// handler, or with no replacement running, is fatal, the same on both
// models; so is one whose function's code is no longer in RAM.
//
// Keys name the boot program: slot 0 and id the low word of the XXH3-64 of
// its ELF file. A chain runs only while that program is the one in RAM
// (kernel k.exec.prog: LoadExecPS2 names it by its file; ExecPS2, which has
// none, by the recompiled range holding its bytes, so with no range a chain
// stays off after it), and the function's first words are its key's.
// Otherwise the call runs as if no mod were loaded. An exec back to the
// boot program turns its chains on again.
//
// Mod-region addresses (the mod stack, a mod's data) are for the mods' own
// loads and stores only: the kernel's string arguments (guest_string), SIF
// transfers (sceSifGetOtherData) and host views of RAM (mem.ram_slice) do
// not reach the region, and refuse such an address with a message naming
// it. A hook passes the game a buffer in game RAM.
//
// Every way into a hooked function that leaves the caller's own function
// reaches its chain: recompiled code calls it through the call table (the
// recomp option mod_hooks, which the hooked set must match: mods_check),
// where its thunk is; the interpreter's calls, and its jumps to another
// function's entry, test mod_at. A jump inside a function to its own entry
// (a loop) is no call. The interpreter takes the function it is in to be
// the one its call entered (FLAT: the one whose mark is on top), so under
// mutual tail jumps, hooked A jumping to B and B back to A, an interpreted
// B's jump is A's loop and runs no chain, while a recompiled B's is a call
// and runs it. Code that needs either must not rely on such a jump.
//
// Recursive model: the thunk (mod_enter) runs the chain on the host stack.
// FLAT: the chain runs on the flat run, as data. A call's entry
// (flat_reload) to a hooked function runs the before hooks nested and
// marks the return address the call pushed: the replacement or the
// original then runs on the run, where a thread switch or a wait may stop
// it as with no mod. Its return finds the mark and runs the after hooks
// (mod_flat_return). The continuations the marks name are host state: a
// snapshot saved while one is pushed does not hold it.
package ps2

import "core:fmt"

import "ps:core"

import cpu "cpu"
import kernel "kernel"
import mem "mem"

// Functions hooked at most: one thunk each.
MOD_SITES :: 512

// A hooked function: its chain, and what runs it with no hooks: the
// procedure its call table slot had (nil: the interpreter). before, after
// and replace: the native code of the chain's hooks, each at its index
// (nil: none, interpreted; mod_native_resolve), so a hook call is one
// indirect call.
@(private = "file")
Mod_Site :: struct {
	chain:         core.Mod_Chain,
	original:      cpu.Func_Proc,
	before, after: []cpu.Func_Proc,
	replace:       cpu.Func_Proc,
}

@(private = "file")
mod_sites: [dynamic]Mod_Site

// Index into mod_sites of each hooked address.
@(private = "file")
mod_at: map[u32]int

// The boot program's id the chains were installed for: they run while it
// is the program in RAM (kernel k.exec.prog), so an exec away turns them
// off and an exec back on.
@(private = "file")
mod_prog: u32

// Thunk k runs mod_sites[k]: a procedure per address, made at compile
// time, so a call through the table stores nothing.
@(private = "file")
mod_thunks: [MOD_SITES]cpu.Func_Proc

@(private = "file")
mod_thunk :: proc($K: int) -> cpu.Func_Proc {
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

// The mods in dir (core.mods_read), read for the EE's mod region: what
// play compiles their native code from (ps2/mods_native.odin).
mods_read_set :: proc(dir, disc: string) -> (set: core.Mod_Set, err: string) {
	return core.mods_read(dir, disc, mem.MOD_BASE, mem.MOD_BASE + mem.MOD_REGION)
}

// The mods in dir (core.mods_read), read for the EE's mod region and noted
// as this run's set (core.mods_note), and the hash of the set they hook
// (core.mod_hooks_hash). ps2.boot calls it before host.platform_init opens
// the input record, which carries the set.
mods_read :: proc(dir, disc: string) -> (set: core.Mod_Set, hash: u64, err: string) {
	set, err = mods_read_set(dir, disc)
	if err != "" {return}
	core.mods_note(set, "ps2")
	return set, core.mod_hooks_hash(set.hooks), ""
}

// Why the recompiled functions registered cannot run with mods hooking the
// set with hash, or "": built for another set (cpu.mod_hooks_hash), they
// call hooked functions past their thunks, or call through the table what
// is not hooked. A native blob is checked as it loads (load_native).
mods_check :: proc(hash: u64) -> string {
	if cpu.text_hi == 0 || cpu.mod_hooks_hash == hash {return ""}
	return fmt.tprintf("mod: the recompiled functions were built for hooked set %016x, the mods hook %016x: build them again with the recomp option mod_hooks set to the mods' hooked addresses", cpu.mod_hooks_hash, hash)
}

// Load set's images into the mod region and install its hooks, once the
// boot program is in RAM and the kernel has its id (exec_boot_program). On an error, which is in
// the temp allocator, no mod is loaded and set's manifests are freed; the
// chains of a loaded set outlive the machine.
mods_load :: proc(set: core.Mod_Set) -> (err: string) {
	// A second load leaves the first's region and hooks alone.
	if mem.mod_ram != nil || cpu.mod_on {
		core.mod_set_delete(set)
		return "mod: mods loaded twice"
	}
	defer if err != "" {
		core.mod_set_delete(set)
		mem.mod_ram_free()
	}
	if len(set.mods) == 0 {return ""}
	who := make([]string, len(set.mods), context.temp_allocator)
	for m, k in set.mods {who[k] = m.id}
	if err = mem.mod_ram_load(set.images, who); err != "" {return}
	chains: []core.Mod_Chain
	if chains, err = core.mod_chains(set.mods, set.order, set.hooks, core.long_allocator()); err != "" {return}
	return mod_install(set.mods, chains, kernel.k.exec.boot_prog)
}

// Install chains for the boot program with id prog. Nothing is installed
// on an error.
@(private = "file")
mod_install :: proc(mods: []core.Mod_Manifest, chains: []core.Mod_Chain, prog: u32) -> (err: string) {
	if len(chains) == 0 {return ""}
	if len(mod_sites) != 0 {return "mod: hooks installed twice"}
	if mem.mod_sp == 0 {return "mod: no mod stack"}
	if len(chains) > MOD_SITES {
		return fmt.tprintf("mod: %d functions hooked, at most %d", len(chains), MOD_SITES)
	}
	seen := make(map[u32]bool, context.temp_allocator)
	for c in chains {
		if e := mod_check(mods[mod_chain_mod(c)].id, c.key, prog); e != "" {return e}
		if c.key.addr in seen {
			return fmt.tprintf("mod %s: a second chain on %08x", mods[mod_chain_mod(c)].id, c.key.addr)
		}
		seen[c.key.addr] = true
	}
	when !core.FLAT {if mod_thunks[0] == nil {mod_thunks_fill(0, MOD_SITES)}}
	mod_sites = make([dynamic]Mod_Site, 0, len(chains), core.long_allocator())
	mod_at = make(map[u32]int, len(chains), core.long_allocator())
	for c in chains {
		a := c.key.addr
		site := Mod_Site{chain = c}
		// A hooked function in the call table gets its thunk there, for
		// recompiled code's calls; register writes the held table while
		// dispatch is off. FLAT's runner reaches the chain itself
		// (mod_flat_enter), and on wasm32 calls what the table holds as
		// native code, which a thunk is not.
		when !core.FLAT {
			if cpu.text_hi != 0 && a >= cpu.text_lo && a < cpu.text_hi {
				site.original = cpu.lookup(a)
				cpu.register(a, mod_thunks[len(mod_sites)])
			}
		}
		mod_at[a] = len(mod_sites)
		append(&mod_sites, site)
	}
	mod_prog = prog
	cpu.mod_on = true
	when core.FLAT {
		kernel.flat_drop = mod_flat_drop
	} else {
		cpu.interp_hook = mod_interp_hook
	}
	return ""
}

// Each site's hooks' native code (mem.mod_func_at), once load_mods has
// loaded it. Mod code cannot change after (mem.mod_ram_check), so it stays.
mod_native_resolve :: proc() {
	for &s in mod_sites {
		c := &s.chain
		s.before = make([]cpu.Func_Proc, len(c.before), core.long_allocator())
		s.after = make([]cpu.Func_Proc, len(c.after), core.long_allocator())
		for f, k in c.before {s.before[k] = mem.mod_func_at(f.fn)}
		for f, k in c.after {s.after[k] = mem.mod_func_at(f.fn)}
		if r, ok := c.replace.?; ok {s.replace = mem.mod_func_at(r.fn)}
	}
}

// Why mod `who` cannot hook the function k names in the boot program with
// id prog, or "": its code must be in RAM now, as the mod was built for it.
@(private = "file")
mod_check :: proc(who: string, k: core.Mod_Key, prog: u32) -> string {
	if k.slot != 0 {
		return fmt.tprintf("mod %s: a hook on %08x in slot %08x: EE hooks name the boot program, slot 0", who, k.addr, k.slot)
	}
	if k.id != prog {
		return fmt.tprintf("mod %s: a hook on %08x in program %08x; the boot program is %08x (EE hooks name only it)", who, k.addr, k.id, prog)
	}
	if k.addr >= mem.RAM_SIZE - 16 || k.addr & 3 != 0 {
		return fmt.tprintf("mod %s: a hook on %08x, which is not a function in RAM", who, k.addr)
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

// The site of a hooked address (mod_at).
@(private)
mod_hooked :: #force_inline proc(addr: u32) -> (site: int, ok: bool) {
	return mod_at[addr]
}

// Whether k's code is in RAM: its first words (mod_check has the address
// in RAM).
@(private = "file")
mod_resident :: proc(k: core.Mod_Key) -> bool {
	for w, i in k.sig {
		if u32((^u32le)(&mem.ram[k.addr + u32(i) * 4])^) != w {return false}
	}
	return true
}

// Whether site's chain runs: the boot program is the one in RAM, and its
// code at the site is still what the mod was built for.
@(private = "file")
mod_live :: proc(site: int) -> bool {
	return kernel.k.exec.prog == mod_prog && mod_resident(mod_sites[site].chain.key)
}

// cpu.interp_hook with mods, recursive model: a mod function with native
// code (ps2/mods_native.odin) runs it; a call to MOD_ORIGINAL or to a
// hooked function no table slot holds (outside the recompiled range, or
// while dispatch is off) runs the chain.
@(private = "file")
mod_interp_hook :: proc(addr: u32) {
	if fn := mem.mod_native(addr); fn != nil {
		fn()
		return
	}
	if addr == mem.MOD_ORIGINAL {
		mod_call_original()
		return
	}
	if site, ok := mod_at[addr]; ok {
		mod_enter(site)
		return
	}
	if mem.mod_ram_has(addr) {mem.mod_interp_calls += 1}
	interp_call(addr)
}

// What a call to hooked site runs, recursive model: its chain when live,
// else the function as with no mods.
@(private)
mod_enter :: proc(site: int) {
	s := &mod_sites[site]
	if !mod_live(site) {
		if s.original != nil && !kernel.k.exec.text_off {
			s.original()
		} else {
			interp_call(s.chain.key.addr)
		}
		return
	}
	c := &s.chain
	entry := mod_args()
	mod_before(s)
	if r, ok := c.replace.?; ok {
		inner := cpu.Mod_Inner{site, cpu.mod_depth, cpu.mod_inner}
		cpu.mod_inner = &inner
		kept := mod_kept()
		mod_run(r.fn, s.replace)
		mod_kept_set(kept)
		cpu.mod_inner = inner.prev
	} else {
		mod_original(site)
	}
	mod_after(s, entry)
}

// Run the mod function at fn: its native code p, else through cpu.call.
@(private = "file")
mod_run :: #force_inline proc(fn: u32, p: cpu.Func_Proc) {
	if p != nil {
		mem.mod_native_calls += 1
		p()
	} else {
		cpu.call(fn)
	}
}

// Run site's function past its thunk, recursive model, under a marker:
// guest code inside it is not inside the replacement that called it.
@(private = "file")
mod_original :: proc(site: int) {
	mark := cpu.Mod_Inner{-1, cpu.mod_depth, cpu.mod_inner}
	cpu.mod_inner = &mark
	defer cpu.mod_inner = mark.prev
	if o := mod_sites[site].original; o != nil {
		o()
	} else {
		interp_call(mod_sites[site].chain.key.addr)
	}
}

// A call to MOD_ORIGINAL, recursive model: the original of the innermost
// running replacement. A mod's native code calls it direct
// (ps2.mod_call_original in native_imports).
@(private)
mod_call_original :: proc() {
	i := cpu.mod_inner
	if i == nil || i.site < 0 || i.depth != cpu.mod_depth {mod_original_fatal()}
	mod_original_resident(i.site)
	mod_original(i.site)
}

// Fatal unless site's code is in RAM, as when its replacement was called.
@(private = "file")
mod_original_resident :: proc(site: int) {
	if !mod_live(site) {
		cpu.fatal("mod: mod_call_original for %08x: that code is no longer in RAM", mod_sites[site].chain.key.addr)
	}
}

@(private = "file")
mod_original_fatal :: proc() -> ! {
	cpu.fatal("mod: a call to mod_call_original (%08x) outside a replacement (ra %08x)", u32(mem.MOD_ORIGINAL), u32(cpu.state.r[31].d[0]))
}

// The argument registers, a0-a7.
@(private = "file")
Mod_Args :: [8]cpu.Gpr

@(private = "file")
mod_args :: proc() -> Mod_Args {
	a: Mod_Args
	copy(a[:], cpu.state.r[4:12])
	return a
}

@(private = "file")
mod_args_set :: proc(a: Mod_Args) {
	a := a
	copy(cpu.state.r[4:12], a[:])
}

// The registers a callee saves, $16-$23, $28 and $30: their upper 64 bits,
// which a replacement does not keep (n32).
@(private = "file")
MOD_SAVED :: [10]int{16, 17, 18, 19, 20, 21, 22, 23, 28, 30}

// What a replacement's return puts back: the upper 64 bits of MOD_SAVED's
// registers and the FPU registers a callee saves, $f20-$f31 (n32 keeps
// only the even ones).
@(private = "file")
Mod_Kept :: struct {
	upper: [len(MOD_SAVED)]u64,
	f:     [12]cpu.Fpr,
}

@(private = "file")
mod_kept :: proc() -> (m: Mod_Kept) {
	for r, k in MOD_SAVED {m.upper[k] = cpu.state.r[r].d[1]}
	copy(m.f[:], cpu.state.f[20:])
	return
}

@(private = "file")
mod_kept_set :: proc(m: Mod_Kept) {
	for r, k in MOD_SAVED {cpu.state.r[r].d[1] = m.upper[k]}
	for &x, k in cpu.state.f[20:] {x = m.f[k]}
}

@(private = "file")
mod_before :: proc(s: ^Mod_Site) {
	for f, k in s.chain.before {mod_call(f.fn, s.before[k] if s.before != nil else nil)}
}

// The after hooks, each with the arguments the function had (entry) and its
// results; then a0-a7 as the function left them.
@(private = "file")
mod_after :: proc(s: ^Mod_Site, entry: Mod_Args) {
	if len(s.chain.after) == 0 {return}
	done := mod_args()
	for f, k in s.chain.after {
		mod_args_set(entry)
		mod_call(f.fn, s.after[k] if s.after != nil else nil)
	}
	mod_args_set(done)
}

// The bytes of a Cpu a hook's return puts back: every register but cop0
// (cycles, after it, apart). A hook's own C code cannot write cop0; game
// code the hook calls can (EI, DI, Status), and that is real execution,
// so it stays. One copy costs about 30% less than the whole Cpu.
@(private = "file")
MOD_REGS :: int(offset_of(cpu.Cpu, cop0))
#assert(offset_of(cpu.Cpu, fcr31) < offset_of(cpu.Cpu, cop0) && offset_of(cpu.Cpu, cop0) < offset_of(cpu.Cpu, cycles))

// Call the before or after hook at fn (native code p, nil none) on the
// mod stack, in frozen time, and put every register but cop0 back after.
// Under FLAT, cpu.call runs it nested.
@(private = "file")
mod_call :: proc(fn: u32, p: cpu.Func_Proc) {
	regs := (^[MOD_REGS]u8)(&cpu.state)^
	cycles, next, held := cpu.state.cycles, cpu.next_event, cpu.mod_held
	if cpu.mod_depth == 0 {cpu.state.r[29].q = u128(mem.mod_sp)}
	cpu.next_event, cpu.mod_held = max(u64), false
	cpu.mod_depth += 1
	mod_run(fn, p)
	cpu.mod_depth -= 1
	mem.mod_ram_check(fn)
	// An event the hook scheduled or an interrupt it raised lowered
	// next_event, or came due and was held: run_events then runs as the game
	// goes on, and handles what is due.
	due := cpu.next_event != max(u64) || cpu.mod_held
	(^[MOD_REGS]u8)(&cpu.state)^ = regs
	cpu.state.cycles, cpu.mod_held = cycles, held
	cpu.next_event = due ? min(next, cycles) : next
}

// ---------------------------------------------------------------- FLAT

// Bit 1 of a return address on a flat run's shadow stack: a mark, whose
// bits 2 up index mod_conts. Return addresses are word aligned; bit 0 is
// kernel.FLAT_HOST_TAIL's.
FLAT_MOD_MARK :: u32(2)

// A hooked call's continuation on a flat run: the return address its mark
// replaced, the site, mod_depth at the call, and the arguments for the
// after hooks. replaced: the replacement runs (mod_call_original's to
// make), and kept is what its return puts back (mod_kept). orig:
// mod_call_original's own, which runs no after hooks. again: the mark was
// pushed below the run's first frame (a call at depth 0), and its return
// ends the run.
@(private = "file")
Mod_Cont :: struct {
	ret:      u32,
	site:     int,
	depth:    int,
	entry:    Mod_Args,
	kept:     Mod_Kept,
	replaced: bool,
	orig:     bool,
	again:    bool,
}

@(private = "file")
mod_conts: [dynamic]Mod_Cont

// Free indices into mod_conts.
@(private = "file")
mod_conts_free: [dynamic]int

@(private = "file")
mod_cont_new :: proc(c: Mod_Cont) -> u32 {
	if mod_conts == nil {
		mod_conts = make([dynamic]Mod_Cont, core.long_allocator())
		mod_conts_free = make([dynamic]int, core.long_allocator())
	}
	if n, ok := pop_safe(&mod_conts_free); ok {
		mod_conts[n] = c
		return u32(n) << 2 | FLAT_MOD_MARK
	}
	append(&mod_conts, c)
	return u32(len(mod_conts) - 1) << 2 | FLAT_MOD_MARK
}

// The entry of a call on x, at x.pc, whose checks flat_reload owes: a
// hooked function's runs its before hooks and marks its return, and the run
// goes on at the replacement, if any (x.pc). A call to MOD_ORIGINAL goes on
// at the original.
@(private)
mod_flat_enter :: proc(x: ^kernel.Flat_Ctx) {
	t := x.pc
	if t == mem.MOD_ORIGINAL {
		mod_flat_original(x)
		return
	}
	site, ok := mod_at[t]
	if !ok || !mod_live(site) {return}
	m := Mod_Cont{site = site, depth = cpu.mod_depth, entry = mod_args()}
	if x.depth > 0 {
		m.ret = x.ret[x.depth - 1]
		x.ret[x.depth - 1] = mod_cont_new(m)
	} else {
		m.again = true
		kernel.flat_push(x, mod_cont_new(m), t)
		x.enter = false
	}
	mark := x.ret[x.depth - 1]
	c := &mod_sites[site].chain
	mod_before(&mod_sites[site])
	if r, rok := c.replace.?; rok {
		mod_conts[mark >> 2].replaced = true
		mod_conts[mark >> 2].kept = mod_kept()
		x.pc = r.fn
	}
}

// A call to MOD_ORIGINAL on x: the innermost mark on x must be a running
// replacement's, at this mod_depth, else fatal as in the recursive model.
// The original then runs on the run, its return marked so that it runs no
// hook.
@(private = "file")
mod_flat_original :: proc(x: ^kernel.Flat_Ctx) {
	for k := int(x.depth) - 1; k >= 0; k -= 1 {
		r := x.ret[k]
		if r & FLAT_MOD_MARK == 0 {continue}
		m := mod_conts[r >> 2]
		if !m.replaced || m.depth != cpu.mod_depth {break}
		mod_original_resident(m.site)
		top := &x.ret[x.depth - 1]
		top^ = mod_cont_new({ret = top^, site = m.site, depth = m.depth, orig = true})
		x.pc = mod_sites[m.site].chain.key.addr
		return
	}
	mod_original_fatal()
}

// kernel.flat_drop: free the continuations of the marks in ret, and of the
// marks they replaced, without running their hooks.
@(private = "file")
mod_flat_drop :: proc(ret: []u32) {
	for r in ret {
		for m := r; m & FLAT_MOD_MARK != 0; m = mod_conts[m >> 2].ret {
			append(&mod_conts_free, int(m >> 2))
		}
	}
}

// The return through mark: the after hooks of its call, unless it was
// mod_call_original's; then the address the mark replaced, and whether the
// return ends the run instead (again).
@(private)
mod_flat_return :: proc(mark: u32) -> (ret: u32, again: bool) {
	n := int(mark >> 2)
	m := mod_conts[n]
	append(&mod_conts_free, n)
	if m.replaced {mod_kept_set(m.kept)}
	if !m.orig {mod_after(&mod_sites[m.site], m.entry)}
	return m.ret, m.again
}

// Whether a jump on x to t enters hooked function t, as a tail call:
// t is hooked, its chain is live, and the code on top of x is not t's
// original looping to its own entry.
@(private)
mod_flat_tail :: proc(x: ^kernel.Flat_Ctx, t: u32) -> bool {
	site, ok := mod_at[t]
	if !ok || !mod_live(site) {return false}
	if x.depth > 0 {
		if top := x.ret[x.depth - 1]; top & FLAT_MOD_MARK != 0 {
			m := &mod_conts[top >> 2]
			if !m.replaced && m.site == site {return false}
		}
	}
	return true
}
