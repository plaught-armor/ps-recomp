// The R3000 interpreter of a FLAT build (core/flat.odin), for the PS1's CPU
// and the IOP. It does what interp_loop and call do, with the same
// execution, charges, events checks, dispatch order and counts, but keeps
// the call chain as data (Flat_Ctx) instead of in host frames: a call pushes
// a record and goes on at its target, and the end of a run pops it.
//
// A record is one call that has not returned, as one host frame of call is
// in the recursive model:
//   - a guest run's (kind Base, Call, Tail or Jump), whose code runs at
//     Flat_Ctx.pc while it is on top;
//   - a host callee's (host set): a fixed or overlay function, a BIOS vector
//     or an HLE stub. It returns when the loop gets control back with the
//     record on top;
//   - a continuation's (kind Cont): host code that called guest code and
//     goes on after it returns, kept as plain data (Flat_Host) and run in
//     steps by flat_step. A host callee that would call guest code and then
//     wait pushes one instead (the IOP's rpc_loop, the PS1's mod thunks).
//
// The owner of a set of runs (the PS1's BIOS threads, the IOP's scheduler)
// runs one with flat_run until it ends or something stops it (flat_block:
// a thread switch, a wait), then picks the next. A guest call the host makes
// itself (call, from host code) runs nested: to its end, and a stop inside
// it is fatal.
package psx_cpu

@(require) import "core:fmt" // used only under FLAT

@(require) import "core:strings" // used only under FLAT

@(require) import "base:runtime" // used only under FLAT

import "ps:core"

// Shadow stack records a run starts with; it grows by doubling up to
// FLAT_DEPTH_MAX, past which guest recursion is fatal.
FLAT_DEPTH_MIN :: 64
FLAT_DEPTH_MAX :: 32768
// Continuations one run can hold at once.
FLAT_HOST :: 4
// Words of a continuation's state.
FLAT_HOST_WORDS :: 48
// Guest calls from host code nested inside one another.
FLAT_NEST :: 8

Flat_Kind :: enum u8 {
	Base, // the run's first call (flat_start): its return ends the run
	Call, // jal, jalr, a linking regimm branch: the caller goes on at ret
	Tail, // goto_target's tail call: its return ends the caller's run too
	Jump, // jump's tail call at a run's first word, counted in tail_depth
	Cont, // a continuation, x.host[slot]
}

// Where flat_enter looks for a callee: every table, as call does; all but
// the fixed table, as call_slow does; or none, as call_guest does (learned
// code, else the interpreter).
Flat_Lookup :: enum u8 {
	All,
	Slow,
	Guest,
}

Flat_Frame :: struct {
	ret:   u32, // where the caller goes on (Call)
	start: u32, // the caller run's first word
	outer: u32, // frame_ret before the call, put back as it returns
	kind:  Flat_Kind,
	host:  bool, // the callee is host code
	slot:  u8,   // Cont: its index in Flat_Ctx.host
}

// A continuation: what host code needs to go on after the guest code it
// called returns. tag and the words mean what its owner (flat_step) says.
Flat_Host :: struct {
	tag: u32,
	w:   [FLAT_HOST_WORDS]u32,
}

Flat_Ctx :: struct {
	pc:      u32,
	// The running run's first word.
	start:   u32,
	// Instructions run since the last charge.
	pending: u64,
	depth:   u32,
	// The run's first call (to pc) is owed: flat_start set it up.
	enter:   bool,
	// goto_target(pc) is owed: the events check before it stopped the run.
	goto_owed: bool,
	ended:   bool,
	hosts:   u32,
	host:    [FLAT_HOST]Flat_Host,
	// Records, innermost last; len is the capacity, emu heap.
	frames:  []Flat_Frame,
}

// The interpreter: under FLAT only, so a default build carries none of it.
when core.FLAT {
	// Set by flat_block: the run on top stops at the next point it can.
	flat_stop: bool
	// The run the loop is on, nil outside one.
	flat_cur: ^Flat_Ctx
	// Steps the continuation h on top of x (the owner's: the IOP's, the PS1's mod_flat_step).
	flat_step: proc(x: ^Flat_Ctx, h: ^Flat_Host)
	// Calls returned by `jr`, those whose target was not the call's return
	// address (the run went on at the call's, as the recursive model does),
	// and the deepest shadow stack.
	flat_returns, flat_mismatch: u64
	flat_max_depth: u32
	// Stops put off until native code or a nested run returned (the IOP's
	// budget, th_budget), each counted once (flat_put_off).
	flat_late: u64
	@(private = "file")
	flat_late_owed: bool // the running run has one put off, counted

	@(private = "file")
	flat_nest: [FLAT_NEST]Flat_Ctx
	@(private = "file")
	flat_nest_depth: int
	// Fixed, overlay or learned functions running: native code, whose host
	// frames a stop would leave running on.
	@(private = "file")
	flat_native: int
	// The entries of the native functions flat_enter and flat_call_native
	// run now, outermost first (the first FLAT_NAMED of flat_native; 0 for
	// one flat_call_native names none), which flat_block's fatal names.
	// Native code's own calls to native code do not pass here.
	@(private = "file")
	flat_native_at: [FLAT_NAMED]u32
	@(private = "file")
	flat_dummy: Interp
	// Set while call runs a callee for host code, so a mod thunk it reaches
	// runs its chain nested; clear when flat_enter reached the thunk from a
	// flat run's guest code (mod_enter). Exec and LoadExec run the new
	// executable through call, so all of it runs with this set: its hooks
	// all run nested, and a stop inside one is fatal.
	flat_host_call: bool

	// Set up x to run the guest function at entry from the start, as call does
	// (the call itself is made once x runs). Its shadow stack is kept.
	flat_start :: proc(x: ^Flat_Ctx, entry: u32) {
		x.pc = entry
		x.start = 0
		x.pending = 0
		x.depth = 0
		x.hosts = 0
		x.enter = true
		x.goto_owed = false
		x.ended = false
	}

	// Let go of x's shadow stack.
	flat_free :: proc(x: ^Flat_Ctx) {
		delete(x.frames, flat_allocator())
		x.frames = nil
	}

	// Run x until it ends (true) or stops (false). Not inside another run.
	flat_run :: proc(x: ^Flat_Ctx) -> bool {
		if flat_cur != nil {fatal("a flat run started inside another")}
		flat_cur = x
		flat_loop(x)
		flat_cur = nil
		flat_stop = false
		flat_late_owed = false
		return x.ended
	}

	// A stop the running run cannot take now (flat_can_stop) is put off: the
	// clock stays past it, so each events check until it lands asks again.
	// Counted once a run.
	flat_put_off :: proc() {
		if flat_late_owed {return}
		flat_late_owed = true
		flat_late += 1
	}

	// interp_run under FLAT: call ran its checks and dispatch, and the code at
	// addr is interpreted. Run it to its end on a run of its own.
	flat_nested :: proc(addr: u32) {
		if flat_cur == nil {fatal("guest code at %08x interpreted outside a flat run", addr)}
		if flat_nest_depth == FLAT_NEST {fatal("guest calls from the host nested %d deep at %08x", FLAT_NEST, addr)}
		outer := flat_cur
		x := &flat_nest[flat_nest_depth]
		flat_nest_depth += 1
		flat_cur = x
		x.pending, x.depth, x.hosts = 0, 0, 0
		x.enter, x.goto_owed, x.ended = false, false, false
		flat_push(x, .Base, 0)
		x.pc, x.start = addr, addr
		events_due()
		flat_loop(x)
		if !x.ended {fatal("guest code at %08x the host called stopped", addr)}
		flat_nest_depth -= 1
		flat_cur = outer
	}

	// What a wait or a thread switch calls before it lets the run stop: only
	// the guest code a run is on can stop, not host code it called. Inside a
	// guest call the host made itself (nested), or native code, the host frames
	// below would run on as if it had returned: fatal.
	flat_block :: proc(what: string) {
		if flat_cur == nil {fatal("%s outside a flat run", what)}
		if flat_nest_depth > 0 {fatal("%s inside a guest call made by host code (FLAT runs those nested)", what)}
		if flat_native > 0 {
			b := strings.builder_make(context.temp_allocator)
			for e, k in flat_native_at[:min(flat_native, FLAT_NAMED)] {
				fmt.sbprintf(&b, "%s%08x", " > " if k > 0 else "", e)
			}
			fatal("%s inside native code (FLAT), entered at %s, ra %08x", what, strings.to_string(b), state.r[31])
		}
		flat_stop = true
	}

	@(private = "file")
	FLAT_NAMED :: 16

	// Count native code entered at addr in, for flat_block.
	@(private = "file")
	flat_native_in :: #force_inline proc(addr: u32) {
		if flat_native < FLAT_NAMED {flat_native_at[flat_native] = addr}
		flat_native += 1
	}

	// Whether flat_block may stop the running run now: on its own guest code,
	// not inside a nested run or native code.
	flat_can_stop :: proc() -> bool {
		return flat_cur != nil && flat_nest_depth == 0 && flat_native == 0
	}

	// Push a continuation on the running run, for host code to go on in steps
	// (flat_step) instead of returning.
	flat_push_cont :: proc(tag: u32) -> ^Flat_Host {
		x := flat_cur
		if x.hosts == FLAT_HOST {fatal("continuations nested %d deep", FLAT_HOST)}
		slot := x.hosts
		x.hosts += 1
		f := flat_push(x, .Cont, 0)
		f.slot = u8(slot)
		h := &x.host[slot]
		h^ = {tag = tag}
		return h
	}

	// The continuation on top is done: its host code returns.
	flat_pop_cont :: proc() {
		x := flat_cur
		if x.depth == 0 || x.frames[x.depth - 1].kind != .Cont {fatal("no continuation to pop")}
		x.depth -= 1
		x.hosts -= 1
	}

	// From a continuation's step: call the guest function at addr, as call
	// does; the step after it returns is the continuation's next.
	// lookup is where the callee is looked for: a mod's continuation calls the
	// code its thunk stands in for, past the thunk.
	flat_call :: proc(addr: u32, lookup := Flat_Lookup.All) {
		x := flat_cur
		if x.depth == 0 || x.frames[x.depth - 1].kind != .Cont {fatal("a flat call to %08x not from a continuation", addr)}
		flat_enter(x, addr, 0, .Call, lookup)
	}

	// From a continuation's step: run the native function fn now, counted as
	// native code (a stop inside it is put off or fatal).
	flat_call_native :: proc(fn: Func_Proc) {
		flat_native_in(0)
		fn()
		flat_native -= 1
	}

	// True when the host callee on top of the running run did not return yet:
	// it pushed a continuation, or stopped the run.
	flat_deferred :: proc() -> bool {
		x := flat_cur
		if flat_stop {return true}
		return x != nil && x.depth > 0 && !x.frames[x.depth - 1].host
	}

	flat_print :: proc() {
		when core.FLAT {
			who := learn_cpu == .Iop ? "iop" : "psx"
			fmt.eprintfln("%s flat: %d returns, %d with the target not the call's return address, %d deep at most, %d stops put off past native code or a nested run", who, flat_returns, flat_mismatch, flat_max_depth, flat_late)
		}
	}

	// Push a record on x with its caller's state, growing the stack.
	@(private = "file")
	flat_push :: proc(x: ^Flat_Ctx, kind: Flat_Kind, ret: u32) -> ^Flat_Frame {
		if int(x.depth) == len(x.frames) {flat_grow(x)}
		f := &x.frames[x.depth]
		f^ = {ret = ret, start = x.start, outer = frame_ret, kind = kind}
		x.depth += 1
		if x.depth > flat_max_depth {flat_max_depth = x.depth}
		return f
	}

	// The shadow stacks' allocator. The IOP means snapshotted: its runs are
	// emulated state, on the emulated heap (core.snap_init) a snapshot holds.
	// The PS1 has none: no emulated heap, so long-lived host memory.
	@(private = "file")
	flat_allocator :: proc() -> runtime.Allocator {
		return learn_cpu == .Iop ? core.emu_allocator() : core.long_allocator()
	}

	@(private = "file")
	flat_grow :: proc(x: ^Flat_Ctx) {
		n := max(2 * len(x.frames), FLAT_DEPTH_MIN)
		if n > FLAT_DEPTH_MAX {fatal("guest calls nested %d deep at %08x", FLAT_DEPTH_MAX, x.pc)}
		frames, err := make([]Flat_Frame, n, flat_allocator())
		if err != nil {fatal("flat: shadow stack of %d not allocated", n)}
		copy(frames, x.frames)
		flat_free(x)
		x.frames = frames
	}

	// call(addr) from x: the record, then the dispatch call and call_slow make.
	// Host code runs now; an interpreted callee goes on at x.pc after the
	// checks it makes on entry.
	@(private = "file")
	flat_enter :: proc(x: ^Flat_Ctx, addr, ret: u32, kind: Flat_Kind, lookup := Flat_Lookup.All) {
		if .Call in core.trace.active && core.trace_pc_ok(addr) {
			core.tracef(.Call, "%08x ra=%x sp=%x a0=%x a1=%x", addr, state.r[31], state.r[29], state.r[4], state.r[5])
		}
		f := flat_push(x, kind, ret)
		frame_ret = state.r[31]
		if kind == .Jump {tail_depth += 1}
		if lookup == .All && is_ram_addr(addr) && addr & 3 == 0 {
			if fn := dispatch.fixed[fn_index(addr)]; fn != nil {
				f.host = true
				flat_native_in(addr)
				fn()
				flat_native -= 1
				return
			}
		}
		if lookup != .Guest && host_call(addr, false) {
			f.host = true
			host_call(addr, true)
			return
		}
		if e := lookup != .Guest ? resolve_overlay(addr) : nil; e != nil {
			when FALLBACK_COUNT {
				if addr in dispatch_demoted {
					dispatch_demoted[addr] += 1
				} else {
					dispatch_overlay[addr] += 1
				}
			}
			if e.slot == e.addr {code_promote(e)}
			f.host = true
			flat_native_in(addr)
			e.fn()
			flat_native -= 1
			return
		}
		if learned_loaded {
			f.host = true
			flat_native_in(addr)
			ok := run_learned(addr)
			flat_native -= 1
			if ok {return}
			f.host = false
		}
		report_once(addr, "interpreting")
		when FALLBACK_COUNT {fallback_interp[addr] += 1}
		when core.COMPAT_COUNT {core.compat_entry(addr)}
		x.pc, x.start = addr, addr
		events_due()
	}

	// The innermost call returns: pop its record, and as a tail call's return
	// ends its caller's run too, that one's. The run goes on where the last
	// popped record's caller does, or has ended.
	@(private = "file")
	flat_pop :: proc(x: ^Flat_Ctx) {
		for {
			if x.depth == 0 {fatal("flat: return with no call")}
			x.depth -= 1
			f := x.frames[x.depth]
			frame_ret = f.outer
			x.pc, x.start = f.ret, f.start
			switch f.kind {
			case .Base:
				x.ended = true
				return
			case .Call:
				return
			case .Tail:
			case .Jump:
				tail_depth -= 1
			case .Cont:
				fatal("flat: a return into a continuation's record")
			}
		}
	}

	// Whether goto_target makes a jump to target a tail call.
	@(private = "file")
	flat_fn_target :: #force_inline proc(target: u32) -> bool {
		return is_ram_addr(target) && dispatch.fixed[fn_index(target)] != nil || host_call(target, false)
	}

	// Do what x owes before its guest code runs on: start it, return from host
	// callees, step continuations, follow an owed jump. False when x stopped or
	// ended.
	@(private = "file")
	flat_settle :: proc(x: ^Flat_Ctx) -> bool {
		for {
			if flat_stop || x.ended {return false}
			if x.enter {
				x.enter = false
				flat_enter(x, x.pc, 0, .Base)
				continue
			}
			if x.depth > 0 {
				f := &x.frames[x.depth - 1]
				if f.host {
					flat_pop(x)
					continue
				}
				if f.kind == .Cont {
					depth := x.depth
					flat_step(x, &x.host[f.slot])
					if !flat_stop && x.depth == depth && x.frames[depth - 1].kind == .Cont {
						fatal("flat: continuation %d made no progress", x.host[x.frames[depth - 1].slot].tag)
					}
					continue
				}
			}
			if x.goto_owed {
				x.goto_owed = false
				if flat_fn_target(x.pc) {flat_enter(x, x.pc, 0, .Tail)}
				continue
			}
			return true
		}
	}

	// The delay slot of the branch at pc, then the block's charge (branch).
	@(private = "file")
	flat_slot :: #force_inline proc(x: ^Flat_Ctx, pc: u32) {
		slot := pc + 4
		w := lw(slot)
		x.pc = slot + 4
		x.pending += 1
		if .Interp in core.trace.active && core.trace_pc_ok(slot) {
			core.tracef(.Interp, "%08x %08x (delay)", slot, w)
		}
		switch w >> 26 {
		case 0x01 ..= 0x07:
			fatal("flat: control transfer %08x in the delay slot at %08x", w, slot)
		case 0x00:
			switch w & 0x3f {
			case 0x08, 0x09, 0x0c, 0x0d:
				fatal("flat: control transfer %08x in the delay slot at %08x", w, slot)
			}
		}
		interp_exec(&flat_dummy, slot, w, x.pending)
		state.r[0] = 0
		state.cycles += x.pending * CYCLES_PER_INSN
		x.pending = 0
	}

	// A taken jump from pc to target that is not a call (branch's, after the
	// slot): events first when it goes back (or always, check), then
	// goto_target. False when x then has something to settle.
	@(private = "file")
	flat_goto :: #force_inline proc(x: ^Flat_Ctx, pc, target: u32, check: bool) -> bool {
		x.pc = target
		if (check || target <= pc) && state.cycles >= next_event {
			x.goto_owed = true
			run_events()
			return false
		}
		if flat_fn_target(target) {
			x.goto_owed = true
			return false
		}
		return true
	}

	// `jr` to t ended the run on top: return.
	@(private = "file")
	flat_return :: #force_inline proc(x: ^Flat_Ctx, t: u32) {
		flat_returns += 1
		flat_pop(x)
		if !x.ended && t != x.pc && (x.depth == 0 || x.frames[x.depth - 1].kind != .Cont) {flat_mismatch += 1}
	}

	@(private = "file")
	flat_loop :: proc(x: ^Flat_Ctx) {
		r := &state.r
		if !flat_settle(x) {return}
		for {
			pc := x.pc
			w := lw(pc)
			x.pc = pc + 4
			x.pending += 1
			if .Interp in core.trace.active && core.trace_pc_ok(pc) {
				core.tracef(.Interp, "%08x %08x", pc, w)
			}
			settle := false
			switch w >> 26 {
			case 0x00:
				rs := (w >> 21) & 31
				switch w & 0x3f {
				case 0x08:
					t := r[rs]
					flat_slot(x, pc)
					if rs == 31 || t == frame_ret {
						flat_return(x, t)
						settle = true
					} else {
						settle = !flat_goto(x, pc, t, true)
					}
				case 0x09:
					t := r[rs]
					r[(w >> 11) & 31] = pc + 8
					r[0] = 0
					flat_slot(x, pc)
					flat_enter(x, t, pc + 8, .Call)
					settle = true
				case 0x0c, 0x0d:
					interp_exec(&flat_dummy, pc, w, x.pending)
					r[0] = 0
					settle = flat_stop
				case:
					interp_exec(&flat_dummy, pc, w, x.pending)
					r[0] = 0
				}
			case 0x01:
				rt := (w >> 16) & 31
				target := pc + 4 + (signed_imm(w) << 2)
				taken := (rt & 1 != 0) == (i32(r[(w >> 21) & 31]) >= 0)
				if rt & 0x1e == 0x10 {
					r[31] = pc + 8
					flat_slot(x, pc)
					if taken {
						flat_enter(x, target, pc + 8, .Call)
						settle = true
					}
				} else {
					flat_slot(x, pc)
					if taken {settle = !flat_goto(x, pc, target, false)}
				}
			case 0x02:
				target := (pc & 0xf0000000) | ((w & 0x3ffffff) << 2)
				flat_slot(x, pc)
				if pc != x.start || tail_depth >= TAIL_DEPTH_MAX {
					settle = !flat_goto(x, pc, target, false)
				} else {
					flat_enter(x, target, 0, .Jump)
					settle = true
				}
			case 0x03:
				r[31] = pc + 8
				flat_slot(x, pc)
				flat_enter(x, (pc & 0xf0000000) | ((w & 0x3ffffff) << 2), pc + 8, .Call)
				settle = true
			case 0x04 ..= 0x07:
				rs, rt := r[(w >> 21) & 31], r[(w >> 16) & 31]
				taken: bool
				switch w >> 26 {
				case 0x04: taken = rs == rt
				case 0x05: taken = rs != rt
				case 0x06: taken = i32(rs) <= 0
				case: taken = i32(rs) > 0
				}
				target := pc + 4 + (signed_imm(w) << 2)
				flat_slot(x, pc)
				if taken {settle = !flat_goto(x, pc, target, false)}
			case 0x10:
				interp_exec(&flat_dummy, pc, w, x.pending)
				r[0] = 0
				settle = flat_stop
			case:
				interp_exec(&flat_dummy, pc, w, x.pending)
				r[0] = 0
			}
			if settle && !flat_settle(x) {return}
		}
	}

	#assert(size_of(Flat_Frame) == 16)
}
