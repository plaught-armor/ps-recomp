package r3000

import "../mips"

// Functions that may switch threads before they return: what wasm32 native
// code leaves to the interpreter. A PS1 run there cannot be suspended inside
// native code, so a thread switch under it is fatal (psx/cpu flat_block).
//
// A function switches when it calls ChangeTh (B 10h: a jump to 0xb0 with
// t1 of 0x10) or ChangeThreadSubFunction (syscall with a0 of 3) itself, or
// reaches one that does through jal or j. Calls through a register are not
// followed: a path through one stays fatal, and the fatal names the native
// functions it passed. Entries are by address across every module, so an
// overlay's entry that switches also leaves the same entry of another
// overlay to the interpreter; that costs speed, never correctness.
//
// mods holds each module's functions; the result is in context.allocator.
thread_switches :: proc(mods: [][]^mips.Func) -> Set {
	out: Set
	callers: map[u32][dynamic]u32 // callee entry -> caller entries
	defer {
		for _, c in callers {delete(c)}
		delete(callers)
	}
	work: [dynamic]u32
	defer delete(work)
	for funcs in mods {
		for f in funcs {
			if switches_here(f) && f.entry not_in out {
				out[f.entry] = {}
				append(&work, f.entry)
			}
			for _, i in f.insns {
				if i.kind != .Call && i.kind != .Jump {continue}
				c := callers[i.target]
				append(&c, f.entry)
				callers[i.target] = c
			}
		}
	}
	for len(work) > 0 {
		e := pop(&work)
		for c in callers[e] {
			if c in out {continue}
			out[c] = {}
			append(&work, c)
		}
	}
	return out
}

// Whether f, a learned run's code, may switch threads: as thread_switches
// counts a function of a program whose switching entries are set.
run_switches :: proc(f: ^mips.Func, set: Set) -> bool {
	if switches_here(f) {return true}
	for _, i in f.insns {
		if (i.kind == .Call || i.kind == .Jump) && i.target in set {return true}
	}
	return false
}

// Instructions before a call that load its arguments: the delay slot and
// up to this many before the jump.
@(private = "file")
SWITCH_WINDOW :: 4

// Whether f itself calls ChangeTh or ChangeThreadSubFunction: a jr or jalr
// through a register loaded with 0xb0, t1 loaded with 0x10, or a syscall
// with a0 loaded with 3, each loaded within SWITCH_WINDOW before (or in the
// delay slot).
@(private = "file")
switches_here :: proc(f: ^mips.Func) -> bool {
	T1 :: 9
	A0 :: 4
	for pc, i in f.insns {
		switch {
		case i.kind == .Jr || i.kind == .Jalr:
			if loads(f, pc, u32(i.rs), 0xb0, false) && loads(f, pc, T1, 0x10, true) {return true}
		case i.w & 0xfc00003f == 0x0000000c: // syscall
			if loads(f, pc, A0, 3, false) {return true}
		}
	}
	return false
}

// Whether an instruction of f within SWITCH_WINDOW before pc (and with
// delay, at pc + 4) loads reg with v: addiu or ori from $zero.
@(private = "file")
loads :: proc(f: ^mips.Func, pc, reg, v: u32, delay: bool) -> bool {
	lo := pc - 4 * SWITCH_WINDOW
	hi := pc + 4 if delay else pc - 4
	for a := lo; a <= hi; a += 4 {
		i, ok := f.insns[a]
		if !ok {continue}
		op, rs, rt, imm := i.w >> 26, (i.w >> 21) & 31, (i.w >> 16) & 31, i.w & 0xffff
		if (op == 0x09 || op == 0x0d) && rs == 0 && rt == reg && imm == v {return true}
	}
	return false
}
