package r3000

import "base:runtime"
import "core:slice"
import "../mips"
import "../native"

// Functions that may switch threads before they return: what wasm32 native
// code leaves to the interpreter. A PS1 run there cannot be suspended inside
// native code, so a thread switch under it is fatal (psx/cpu flat_block).
//
// A function switches when it may call ChangeTh or ChangeThreadSubFunction
// itself (switches_here), loops with no way out (loops_forever: an exception
// return that names another thread waits for the native code under it to
// return, so in such a loop it waits for ever), is such a loop's dispatcher
// (the loop calls it by jal and it calls through a register: the thread's
// work, which may switch; MGS1's main loop calls 0x800150c4, which calls
// each task from a list), or reaches code that does one of these: through
// jal, or a branch or jump out of its own code, each to the function holding
// the target (a jump into the middle of one passes through its rest). Other
// calls through a register are not followed: a ChangeTh past one stays
// fatal, and the fatal names the native functions it passed, for the next
// run to leave (play's known switches); a switch owed in a loop past one
// waits, and only play's exit count of stops put off shows it. Entries are
// by address across every module, so an overlay's entry that switches also
// leaves the same entry of another overlay to the interpreter; that costs
// speed, never correctness.
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
	index := make([]Func_Index, len(mods))
	defer {
		for x in index {func_index_free(x)}
		delete(index)
	}
	for funcs, k in mods {index[k] = func_index_make(funcs)}
	holders: [dynamic]u32
	defer delete(holders)
	edge :: proc(callers: ^map[u32][dynamic]u32, callee, caller: u32) {
		c := callers[callee]
		append(&c, caller)
		callers[callee] = c
	}
	looped: Set // what a loop with no way out calls by jal
	defer delete(looped)
	for funcs, k in mods {
		for f in funcs {
			loops := loops_forever(f)
			if (loops || switches_here(f)) && f.entry not_in out {
				out[f.entry] = {}
				append(&work, f.entry)
			}
			for _, i in f.insns {
				if i.kind != .Call {continue}
				if loops {looped[i.target] = {}}
				edge(&callers, i.target, f.entry)
				holding(index, k, i.target, &holders)
				for h in holders {edge(&callers, h, f.entry)}
			}
			for t in f.exits {
				holding(index, k, t, &holders)
				for h in holders {edge(&callers, h, f.entry)}
			}
		}
	}
	for funcs in mods {
		for f in funcs {
			if f.entry in looped && f.entry not_in out && calls_by_register(f) {
				out[f.entry] = {}
				append(&work, f.entry)
			}
		}
	}
	for len(work) > 0 {
		e := pop(&work)
		// A local, not callers[e] in the range: ranging over a map index
		// reads the slot through its address, nil for an entry nobody calls.
		cs := callers[e]
		for c in cs {
			if c in out {continue}
			out[c] = {}
			append(&work, c)
		}
	}
	return out
}

// A module's functions by start, with the largest end up to each, to find
// the functions holding an address.
@(private = "file")
Func_Index :: struct {
	funcs:   []^mips.Func,
	max_end: []u32,
}

@(private = "file")
func_index_make :: proc(funcs: []^mips.Func) -> Func_Index {
	x := Func_Index{slice.clone(funcs), make([]u32, len(funcs))}
	slice.sort_by(x.funcs, proc(a, b: ^mips.Func) -> bool {return a.start < b.start})
	end: u32
	for f, k in x.funcs {
		end = max(end, f.end)
		x.max_end[k] = end
	}
	return x
}

@(private = "file")
func_index_free :: proc(x: Func_Index) {
	delete(x.funcs)
	delete(x.max_end)
}

// The entries of the functions holding t into out (emptied first): those of
// module k, else of the executable (module 0), else of every module.
@(private = "file")
holding :: proc(index: []Func_Index, k: int, t: u32, out: ^[dynamic]u32) {
	clear(out)
	holding_in(index[k], t, out)
	if len(out) == 0 && k != 0 {holding_in(index[0], t, out)}
	if len(out) == 0 {
		for x in index {holding_in(x, t, out)}
	}
}

@(private = "file")
holding_in :: proc(x: Func_Index, t: u32, out: ^[dynamic]u32) {
	// The functions starting at or below t, from the last back while one
	// of them can still reach past t.
	n, _ := slice.binary_search_by(x.funcs, t, proc(f: ^mips.Func, t: u32) -> slice.Ordering {
		return .Less if f.start <= t else .Greater
	})
	for k := n - 1; k >= 0 && x.max_end[k] > t; k -= 1 {
		if f := x.funcs[k]; t < f.end {append(out, f.entry)}
	}
}

// The code left to the interpreter: entries, and the bytes [lo, hi) of
// functions and runs held there (a zero-length one holds its entry only).
Interp_Set :: struct {
	entries: Set,
	ranges:  [dynamic][2]u32,
}

interp_set_make :: proc(interp: []native.Blob_Interp) -> Interp_Set {
	s: Interp_Set
	for v in interp {interp_set_add(&s, v.entry, v.lo, v.hi)}
	return s
}

interp_set_add :: proc(s: ^Interp_Set, entry, lo, hi: u32) {
	s.entries[entry] = {}
	if lo < hi {append(&s.ranges, [2]u32{lo, hi})}
}

interp_set_free :: proc(s: Interp_Set) {
	delete(s.entries)
	delete(s.ranges)
}

// Whether code at t is left to the interpreter: an entry, or inside a range.
interp_holds :: proc(s: Interp_Set, t: u32) -> bool {
	if t in s.entries {return true}
	for r in s.ranges {
		if t >= r[0] && t < r[1] {return true}
	}
	return false
}

// Whether [lo, hi) shares bytes with a range of s.
interp_overlaps :: proc(s: Interp_Set, lo, hi: u32) -> bool {
	for r in s.ranges {
		if lo < r[1] && r[0] < hi {return true}
	}
	return false
}

// Whether f, a learned run's code, may switch threads: as thread_switches
// counts a function, with s the code that may (thread_switches' functions
// and the runs found to switch so far): a run calls, or branches or jumps
// out of its words, into code of s.
run_switches :: proc(f: ^mips.Func, s: Interp_Set) -> bool {
	if switches_here(f) || loops_forever(f) {return true}
	for _, i in f.insns {
		if i.kind == .Call && interp_holds(s, i.target) {return true}
	}
	for t in f.exits {
		if interp_holds(s, t) {return true}
	}
	return false
}

// Whether f loops with no way out: its reachable code has a backward branch
// or jump, and no jr, halt or exit from its range. MGS1's idle thread
// (0x8008e514) is one, and its other threads run only when an exception
// return takes the CPU from it. A program's start also has a loop (it
// clears the bss) and no jr, but ends in a halt (break 1) after main. A
// jump to itself is not counted: it is a halt too (MGS1's fault handler,
// 0x8008e64c), and its callers would all be left to the interpreter.
@(private = "file")
loops_forever :: proc(f: ^mips.Func) -> bool {
	if len(f.exits) > 0 {return false}
	loops := false
	for pc, i in f.insns {
		if i.halt {return false}
		#partial switch i.kind {
		case .Jr:
			return false
		case .Branch, .Jump:
			if i.target < pc && mips.inside(f, i.target) {loops = true}
		}
	}
	return loops
}

// Whether f has a jalr.
@(private = "file")
calls_by_register :: proc(f: ^mips.Func) -> bool {
	for _, i in f.insns {
		if i.kind == .Jalr {return true}
	}
	return false
}

// Whether f itself may switch threads: call ChangeTh (B 10h),
// ChangeThreadSubFunction (syscall with a0 of 3), or Exec or LoadExec
// (A 43h, A 51h: the program they run is not seen here and may call
// ChangeTh under f). A syscall, or a jal, j, jr or jalr to the A or B
// table (0xa0, 0xb0 in any segment), counts unless its function number
// (a0, t1) is proven another: set by an addiu or ori from $zero in the
// same block, the delay slot of the jump included, as in the PSY-Q stub
// `li t2, 0xb0; jr t2; li t1, n`. A jr or jalr through a register that is
// not proven but that f loads anywhere with 0xa0 or 0xb0 counts too.
@(private = "file")
switches_here :: proc(f: ^mips.Func) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	A0 :: 4
	tables: bit_set[0 ..< 32] // registers f loads with 0xa0 or 0xb0
	starts := make(map[u32]struct{}, context.temp_allocator) // the pcs blocks start at
	starts[f.entry] = {}
	for _, i in f.insns {
		if v, ok := li_value(i.w); ok && (v == 0xa0 || v == 0xb0) {tables += {int((i.w >> 16) & 31)}}
		if i.kind == .Branch || i.kind == .Jump {starts[i.target] = {}}
	}
	for pc, i in f.insns {
		switch {
		case i.w & 0xfc00003f == 0x0000000c: // syscall
			if a0, ok := proven(f, starts, pc, false, A0); !ok || a0 == 3 {return true}
		case i.kind == .Call || i.kind == .Jump:
			if table_switches(f, starts, pc, i.target) {return true}
		case i.kind == .Jr || i.kind == .Jalr:
			if t, ok := proven(f, starts, pc, false, int(i.rs)); ok {
				if table_switches(f, starts, pc, t) {return true}
			} else if int(i.rs) in tables {
				return true
			}
		}
	}
	return false
}

// Whether a jump at pc to t, a table call with t1 as f's block sets it,
// may switch threads.
@(private = "file")
table_switches :: proc(f: ^mips.Func, starts: map[u32]struct{}, pc, t: u32) -> bool {
	T1 :: 9
	switch t & 0x1fffffff {
	case 0xa0:
		n, ok := proven(f, starts, pc, true, T1)
		return !ok || n == 0x43 || n == 0x51
	case 0xb0:
		n, ok := proven(f, starts, pc, true, T1)
		return !ok || n == 0x10
	}
	return false
}

// The value register r holds at the instruction at pc (after its delay
// slot when delay), when its block sets it with an addiu or ori from $zero:
// the last write to r before pc, from the block's start; a write of any
// other kind, or none in the block, is not proven.
@(private = "file")
proven :: proc(f: ^mips.Func, starts: map[u32]struct{}, pc: u32, delay: bool, r: int) -> (u32, bool) {
	if r == 0 {return 0, true}
	if delay {
		if d, ok := f.insns[pc + 4]; ok && writes(d.w, r) {return li_value(d.w)}
	}
	for p := pc; (p not_in starts); {
		// p starts a block when the word before it is a delay slot.
		if before, ok := f.insns[p - 8]; ok && before.kind != .Alu && before.kind != .Sys {return 0, false}
		p -= 4
		i, ok := f.insns[p]
		if !ok || i.kind != .Alu {return 0, false}
		if writes(i.w, r) {return li_value(i.w)}
	}
	return 0, false
}

// The value an addiu or ori from $zero loads, else not one.
@(private = "file")
li_value :: proc(w: u32) -> (u32, bool) {
	op, rs, imm := w >> 26, (w >> 21) & 31, w & 0xffff
	if rs != 0 {return 0, false}
	switch op {
	case 0x09:
		return u32(i32(i16(u16(imm)))), true
	case 0x0d:
		return imm, true
	}
	return 0, false
}

// Whether w may write register r (r != 0): over-counted, as a write that is
// not a load of a constant only leaves r unproven.
@(private = "file")
writes :: proc(w: u32, r: int) -> bool {
	op, rt, rd := w >> 26, int((w >> 16) & 31), int((w >> 11) & 31)
	switch op {
	case 0x00:
		return rd == r
	case 0x01, 0x02, 0x04 ..= 0x07, 0x28 ..= 0x2e, 0x38 ..= 0x3e:
		return false // branches, j, stores
	case 0x03:
		return r == 31
	}
	return rt == r
}

// Mark, in each function's back, the calls (jal) to a function that may
// return somewhere other than the caller's jal+8; returns how many. Native
// code goes on at jal+8 whatever the callee jumps to; at a marked call it
// checks (cpu.call_back) and, when the callee came back to this function's
// own return address, returns too, as the interpreter's jr $ra unwinds to
// that frame (psx/cpu interp_unwind_find). FF8's LZS decompressor
// (0x8003947c) yields through 0x800394d0, which loads $ra from a global and
// returns to the decompressor's caller; run on at jal+8, the decompressor
// went on past its buffer and wrote over the program.
//
// A callee counts when it loads $ra other than from its stack frame
// (returns_elsewhere_here). One that saves $ra in a global and restores it
// to return to its own caller counts too (Crash, FF7): its calls only cost
// the check. mods holds each module's functions.
//
// With outside, a call to the entry of no function in mods counts too:
// nothing here shows how that callee returns. Learned runs need it, since
// their callees are mostly in the main blob or interpreted. FF8 discs 2-4
// learned the decompressor's resume at 0x800395b8 as a run whose jal to
// the yield went on at jal+8 and wrote past the buffer again.
returns_elsewhere :: proc(mods: [][]^mips.Func, outside := false) -> int {
	here, known: Set
	defer delete(here)
	defer delete(known)
	for funcs in mods {
		for f in funcs {
			known[f.entry] = {}
			if returns_elsewhere_here(f) {here[f.entry] = {}}
		}
	}
	n := 0
	for funcs in mods {
		for f in funcs {
			for _, i in f.insns {
				if i.kind == .Call && (i.target in here || outside && i.target not_in known) {
					f.back[i.target] = {}
					n += 1
				}
			}
		}
	}
	return n
}

// Whether f loads $ra (lw $31) through a base other than $sp or $fp.
returns_elsewhere_here :: proc(f: ^mips.Func) -> bool {
	LW :: 0x23
	for _, i in f.insns {
		if i.w >> 26 != LW || (i.w >> 16) & 31 != 31 {continue}
		if base := (i.w >> 21) & 31; base != 29 && base != 30 {return true}
	}
	return false
}
