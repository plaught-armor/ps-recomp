// Function discovery for code without symbols.
//
// A module (an executable's text, an overlay) is split into functions at
// entries: `jal` targets, the first instruction after each `jr $ra` and its
// delay slot, listed entries, and referenced code addresses that begin with
// a stack-frame prologue. Each function's reachable code is walked from its
// entry and its labels; branches out of it become tail calls.
package mips

import "core:crypto/legacy/sha1"
import "core:fmt"
import "core:slice"
import "core:strings"

// Where the two consoles' recompilers had grown different rules, the one a
// module uses.
Rules :: struct {
	decode:        Decode,
	// Words allowed before a referenced address's prologue for it to begin a
	// function.
	lead:          Lead,
	// A jump or call ends the run lui values are followed through, after its
	// delay slot.
	lui_reset:     bool,
	// Secondary functions also label the entries dropped as mid-function.
	label_dropped: bool,
	// Where code can run, [lo, hi): a guessed function (module_entries) that
	// jumps or calls outside it is data. Zero: anywhere.
	ram:           [2]u32,
}

Lead :: enum u8 {
	// lui and loads based on those lui registers (a global loaded and tested
	// first).
	Global_Loads,
	// Any lui, lw, ld, addiu or daddu.
	Loose,
}

Set :: map[u32]struct{}

Func :: struct {
	entry:    u32,
	start:    u32, // range start
	end:      u32, // exclusive range end
	insns:    map[u32]Insn, // reachable
	labels:   Set,
	delay:    Set, // delay-slot pcs
	exits:    Set, // branch/jump targets outside [start, end)
	computed: bool, // a walked jr through a register other than $ra
	warnings: [dynamic]string,
}

func_make :: proc(entry, end: u32, start: Maybe(u32) = nil) -> ^Func {
	f := new(Func)
	f.entry, f.end = entry, end
	f.start = start.? or_else entry
	f.labels[entry] = {}
	return f
}

inside :: #force_inline proc(f: ^Func, a: u32) -> bool {
	return f.start <= a && a < f.end
}

sorted_keys :: proc(s: Set) -> []u32 {
	out := make([]u32, len(s))
	n := 0
	for k in s {
		out[n] = k
		n += 1
	}
	slice.sort(out)
	return out
}

sorted_pcs :: proc(f: ^Func) -> []u32 {
	out := make([]u32, len(f.insns))
	n := 0
	for pc in f.insns {
		out[n] = pc
		n += 1
	}
	slice.sort(out)
	return out
}

// The part of a sorted address list inside [lo, hi).
@(private = "file")
sorted_range :: proc(s: []u32, lo, hi: u32) -> []u32 {
	a, _ := slice.binary_search(s, lo)
	b, _ := slice.binary_search(s, hi)
	for a > 0 && s[a - 1] >= lo {
		a -= 1
	}
	for b > 0 && s[b - 1] >= hi {
		b -= 1
	}
	return s[a:max(a, b)]
}

// Walk reachable code of f inside [start, end). A computed `jr` (not `$ra`)
// with no code pointers into the function can land on any instruction, as
// in a Duff's device, so then every word in the range is walked and
// labelled. extra_labels is sorted.
discover :: proc(r: Rules, img: Image, f: ^Func, extra_labels: []u32) {
	extra := sorted_range(extra_labels, f.start, f.end)
	work: [dynamic]u32
	append(&work, f.entry)
	append(&work, ..extra)
	for a in extra {
		f.labels[a] = {}
	}
	seen: Set
	defer delete(seen)
	walk(r, img, f, &work, &seen)
	if f.computed && len(extra) == 0 {
		clear(&work)
		for a := f.start; a < f.end; a += 4 {
			if a not_in seen {
				append(&work, a)
			}
		}
		walk(r, img, f, &work, &seen)
		for a in f.insns {
			if a not_in f.delay {
				f.labels[a] = {}
			}
		}
	}
	delete(work)
	// A delay slot that is also a label needs its successor labelled too.
	// Ascending, so a chain of delay slots (data decoded as branches) is
	// labelled the same way on every run.
	for d in sorted_keys(f.delay) {
		if d in f.labels {
			f.labels[d + 4] = {}
		}
	}
}

// Decode reachable instructions from the pcs in work.
@(private = "file")
walk :: proc(r: Rules, img: Image, f: ^Func, work: ^[dynamic]u32, seen: ^Set) {
	for len(work) > 0 {
		pc := pop(work)
		step: for {
			if !inside(f, pc) || pc in seen^ {
				break
			}
			w, ok := word(img, pc)
			if !ok {
				break
			}
			seen[pc] = {}
			i := r.decode(pc, w)
			f.insns[pc] = i
			if i.kind == .Bad {
				break
			}
			if has_delay(i) {
				d := pc + 4
				if inside(f, d) && d not_in f.insns {
					if dw, d_ok := word(img, d); d_ok {
						f.insns[d] = r.decode(d, dw)
						seen[d] = {}
					}
				}
				f.delay[d] = {}
				#partial switch i.kind {
				case .Branch, .Jump:
					if inside(f, i.target) {
						f.labels[i.target] = {}
						append(work, i.target)
					} else {
						f.exits[i.target] = {}
					}
					if i.kind == .Jump {
						break step
					}
					pc += 8
					continue step
				case .Call, .Jalr:
					pc += 8
					continue step
				case .Jr:
					f.computed ||= i.rs != 31
				}
				break step
			}
			if i.halt {
				break
			}
			pc += 4
		}
		if pc == f.end {
			f.exits[pc] = {} // falls through into the next function
		}
	}
}

// ---------------------------------------------------------------- entries

// Aligned data words in img that point into [lo, hi): from every section
// that is not code, or from the whole image when it has no sections. With
// pairs, each two such words in a row also go there, for table_labels.
data_pointers :: proc(img: Image, lo, hi: u32, out: ^Set, pairs: ^[dynamic][2]u32 = nil) {
	scan :: proc(data: []u8, lo, hi: u32, out: ^Set, pairs: ^[dynamic][2]u32) {
		prev: Maybe(u32)
		for o := 0; o + 4 <= len(data); o += 4 {
			v := u32le(data, o)
			if !(lo <= v && v < hi && v & 3 == 0) {
				prev = nil
				continue
			}
			out[v] = {}
			if p, ok := prev.?; ok && pairs != nil {append(pairs, [2]u32{p, v})}
			prev = v
		}
	}
	if img.sections == nil {
		scan(img.data, lo, hi, out, pairs)
		return
	}
	for s in img.sections {
		if s.data != nil && s.addr < 0x01000000 && s.flags & SHF_EXEC == 0 {
			scan(s.data, lo, hi, out, pairs)
		}
	}
}

// e follows a `jr $ra`, a `j` or a `b` back to a loop (with its delay slot
// and any nop padding), or five or more nops of padding: where a function
// without a prologue can start. Unlike terminator_before, not after a `b`
// forward (past an else) or a `jr` through a table, which end blocks inside a
// function.
@(private = "file")
after_exit :: proc(r: Rules, img: Image, e: u32) -> bool {
	p := e - 4
	for n in 0 ..< 16 {
		if w, ok := word(img, p); !ok || w != 0 {
			break
		}
		if n == 4 {
			return true // padding, not a delay slot or a load delay
		}
		p -= 4
	}
	for q in ([2]u32{p, p - 4}) {
		if q > e - 8 {
			continue // e would be this instruction's delay slot
		}
		w, ok := word(img, q)
		if !ok {
			return true
		}
		i := r.decode(q, w)
		if i.kind == .Jr && i.rs == 31 || i.kind == .Jump || w >> 16 == 0x1000 && w & 0x8000 != 0 {
			return true
		}
	}
	return false
}

// The data pointers in [lo, hi) that are labels in the functions starting
// at entries: those at an entry or after a return or jump (code that may
// start a function without a prologue), and those in two data words in a row
// that point into the same function (a jump table) or of which one points at
// an entry (a table of methods). A lone data word into the middle of a
// function is data that looks like an address.
table_labels :: proc(r: Rules, img: Image, lo, hi: u32, ptrs: Set, pairs: [][2]u32, entries: Set, out: ^Set) {
	starts := sorted_keys(entries)
	defer delete(starts)
	for v in ptrs {
		if lo <= v && v < hi && (v in entries || after_exit(r, img, v)) {out[v] = {}}
	}
	for p in pairs {
		in_range := lo <= p[0] && p[0] < hi && lo <= p[1] && p[1] < hi
		same := bisect_right(starts, p[0]) == bisect_right(starts, p[1])
		if in_range && (same || p[0] in entries || p[1] in entries) {
			out[p[0]] = {}
			out[p[1]] = {}
		}
	}
}

// Addresses in [lo, hi) built in the code in [from, to) by `lui` +
// `addiu`/`daddiu`/`ori` pairs, such as callbacks passed as arguments.
address_constants :: proc(r: Rules, img: Image, from, to, lo, hi: u32, out: ^Set) {
	upper: [32]Maybe(u32)
	reset := false // a jump's delay slot is next; it still sees lui values
	for a := from; a < to; a += 4 {
		w, ok := word(img, a)
		if !ok {
			continue
		}
		clear := reset
		reset = false
		op, rs, rt := w >> 26, w >> 21 & 31, w >> 16 & 31
		if op == 0x0f {
			upper[rt] = (w & 0xffff) << 16
		} else if h, known := upper[rs].?; known && (op == 0x09 || op == 0x0d || op == 0x19) {
			v := h + (op == 0x0d ? w & 0xffff : u32(sx16(w)))
			if lo <= v && v < hi && v & 3 == 0 {
				out[v] = {}
			}
		}
		if clear {
			upper = {}
		}
		if r.lui_reset && (op == 2 || op == 3 || op == 0 && (w & 63 == 8 || w & 63 == 9)) {
			reset = true
		}
	}
}

// Every image's whole range.
image_range :: proc(img: Image) -> (lo, hi: u32) {
	return img.base, img.base + u32(len(img.data))
}

call_targets :: proc(img: Image, lo, hi: u32) -> Set {
	out: Set
	for a := lo; a < hi; a += 4 {
		if w, ok := word(img, a); ok && w >> 26 == 3 {
			out[(a + 4) & 0xf0000000 | (w & 0x3ffffff) << 2] = {}
		}
	}
	return out
}

// True when the code before e (skipping up to four nop padding words) ends
// with an unconditional jump (jr, j, b) and its delay slot.
terminator_before :: proc(r: Rules, img: Image, e: u32) -> bool {
	p := e - 4
	for _ in 0 ..< 4 {
		if w, ok := word(img, p); !ok || w != 0 {
			break
		}
		p -= 4
	}
	for q in ([2]u32{p, p - 4}) {
		if q > e - 8 {
			continue // e would be this instruction's delay slot
		}
		w, ok := word(img, q)
		if !ok {
			return true
		}
		i := r.decode(q, w)
		if i.kind == .Jr || i.kind == .Jump || w >> 16 == 0x1000 {
			return true
		}
	}
	return false
}

// Words a function may run before its `addiu $sp, $sp, -n` prologue: game
// code often loads a global first (`lui` + load) and tests it after.
MAX_PRE_PROLOGUE :: 3

// addiu (or daddiu) $sp, $sp, -n
is_prologue :: proc(img: Image, a: u32) -> bool {
	w, ok := word(img, a)
	return ok && (w >> 16 == 0x27bd || w >> 16 == 0x67bd) && w & 0x8000 != 0
}

// True when [a, end) is `lui`s and loads based on registers those `lui`s
// set, starting with a `lui`: a load of a global. Data such as pointers into
// overlay space decodes as loads, but not based this way.
@(private = "file")
global_loads :: proc(img: Image, a, end: u32) -> bool {
	upper: bit_set[0 ..< 32;u32]
	for q := a; q < end; q += 4 {
		w, ok := word(img, q)
		if !ok {
			return false
		}
		op, rs, rt := w >> 26, w >> 21 & 31, w >> 16 & 31
		if op == 0x0f {
			upper += {int(rt)}
		} else if !(op == 0x20 || op == 0x21 || op == 0x23 || op == 0x24 || op == 0x25) || int(rs) not_in upper {
			return false
		}
	}
	return upper != {}
}

// Start of the function whose prologue is at p: p, or the global loads of
// up to MAX_PRE_PROLOGUE words just before it.
function_start :: proc(img: Image, p, lo: u32) -> u32 {
	for k := u32(MAX_PRE_PROLOGUE); k > 0; k -= 1 {
		a := p - 4 * k
		if a >= lo && global_loads(img, a, p) {
			return a
		}
	}
	return p
}

// Referenced code addresses that begin a function: a prologue, or a lead
// before one (Rules.lead). Jump table targets do not, and splitting at one
// would turn a loop through it into recursion. Functions after a `jr $ra`
// are covered by return_boundaries.
@(private = "file")
pointer_entries :: proc(r: Rules, img: Image, ptrs: []u32, lo: u32, out: ^Set) {
	for p in ptrs {
		for k in u32(0) ..= MAX_PRE_PROLOGUE {
			q := p + 4 * k
			if is_prologue(img, q) {
				if k == 0 || r.lead == .Loose || function_start(img, q, lo) == p {
					out[p] = {}
				}
				break
			}
			if r.lead == .Loose {
				w, ok := word(img, q)
				op := w >> 26
				if !ok || !(op == 0x0f || op == 0x23 || op == 0x37 || op == 0x09 || op == 0 && w & 63 == 0x2d) {
					break
				}
			}
		}
	}
}

// The index of the first entry above t.
@(private = "file")
bisect_right :: proc(s: []u32, t: u32) -> int {
	lo, hi := 0, len(s)
	for lo < hi {
		mid := (lo + hi) / 2
		if t < s[mid] {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo
}

@(private = "file")
any_call_or_stack :: proc(f: ^Func) -> (returns, calls: bool) {
	for _, i in f.insns {
		returns ||= i.kind == .Jr && i.rs == 31
		calls ||= i.kind == .Call || i.kind == .Jalr || i.sp
	}
	return
}

// Functions for referenced code addresses without a prologue, which
// pointer_entries leaves to the preceding function: after an unconditional
// jump, code that returns through `jr $ra`, never leaves itself and never
// touches the stack or makes a call: a leaf function. A jump-table case can
// look the same, but such leaves are also called through function-pointer
// tables (`jalr`), so each gets a function of just its own code, overlapping
// its container, where it stays a label. Cases that end in their function's
// epilogue restore $sp, so they are left out.
@(private = "file")
pointer_leaves :: proc(r: Rules, img: Image, ptrs: []u32, entries: []u32, hi: u32, out: ^[dynamic]^Func) {
	for p in ptrs {
		if !terminator_before(r, img, p) {
			continue
		}
		n := bisect_right(entries, p)
		f := func_make(p, n < len(entries) ? entries[n] : hi)
		discover(r, img, f, nil)
		returns, calls := any_call_or_stack(f)
		if len(f.exits) == 0 && returns && !calls {
			append(out, f)
		}
	}
}

// First non-nop word after each `jr $ra` and its delay slot: where the next
// function usually starts.
@(private = "file")
return_boundaries :: proc(img: Image, lo, hi: u32, out: ^Set) {
	for q := lo; q + 8 < hi; q += 4 {
		if w, _ := word(img, q); w != 0x03e00008 {
			continue
		}
		a := q + 8
		for a < hi {
			if w, ok := word(img, a); !ok || w != 0 {
				break
			}
			a += 4
		}
		// Past the end of the image there is no code to start.
		if _, ok := word(img, a); ok && a < hi {
			out[a] = {}
		}
	}
}

@(private = "file")
union_sorted :: proc(a: []u32, b: Set) -> []u32 {
	s: Set
	defer delete(s)
	for k in a {
		s[k] = {}
	}
	for k in b {
		s[k] = {}
	}
	return sorted_keys(s)
}

// Entries of the code in [lo, hi), the jal targets among them, and the
// entries only return_boundaries gave (guessed: data after a return looks
// the same). Entries in known are certain and skip the plausibility check;
// listed entries that ordinary code falls through into are dropped (Ghidra
// places some mid-function), but `jal` targets are always kept.
module_entries :: proc(r: Rules, img: Image, lo, hi: u32, listed: []u32, refs: Set, known: Set) -> (entries, calls, guessed: Set) {
	calls = call_targets(img, lo, hi)
	for e in listed {
		if e in calls || terminator_before(r, img, e) {
			entries[e] = {}
		}
	}
	for e in known {
		entries[e] = {}
	}
	inside: [dynamic]u32
	for a in refs {
		if lo <= a && a < hi {
			append(&inside, a)
		}
	}
	pointer_entries(r, img, inside[:], lo, &entries)
	for e in calls {
		entries[e] = {}
	}
	after: Set
	defer delete(after)
	return_boundaries(img, lo, hi, &after)
	for e in after {
		if e not_in entries {
			guessed[e] = {}
			entries[e] = {}
		}
	}
	return
}

@(private = "file")
split_module :: proc(r: Rules, img: Image, hi: u32, entries: []u32, extra_labels: []u32) -> [dynamic]^Func {
	funcs: [dynamic]^Func
	for e, n in entries {
		f := func_make(e, n + 1 < len(entries) ? entries[n + 1] : hi)
		discover(r, img, f, extra_labels)
		append(&funcs, f)
	}
	return funcs
}

// Split [lo, hi) at the entries. An entry the preceding function branches
// past is mid-function and is dropped, unless it is in fixed (`jal`
// targets); it stays a label and gets a secondary function. A branch that
// still leaves its function for a non-entry address (code shared between
// functions) becomes a tail call, so each such target also gets a secondary
// function entered there and covering its container's whole range, so loops
// back across the target stay inside it. Secondary functions overlap their
// container instead of splitting it. Addresses in leaf_ptrs that
// pointer_leaves accepts get one too. A guessed entry (module_entries) whose
// code is data after a return, such as a table or strings (data_func), gets
// no function, and neither do the secondary functions only its branches
// made, unless code that keeps its function branches there.
build_module :: proc(r: Rules, img: Image, lo, hi: u32, all_entries: Set, extra_labels: Set, fixed: Set, leaf_ptrs: Set, guessed: Set) -> []^Func {
	entries: [dynamic]u32
	for e in sorted_keys(all_entries) {
		if lo <= e && e < hi {
			append(&entries, e)
		}
	}
	extra := sorted_keys(extra_labels)
	dropped: Set
	funcs: [dynamic]^Func
	for {
		funcs = split_module(r, img, hi, entries[:], r.label_dropped ? union_sorted(extra, dropped) : extra)
		inner: Set
		for n in 0 ..< len(funcs) - 1 {
			nxt := funcs[n + 1]
			if nxt.entry in fixed {
				continue
			}
			for t in funcs[n].exits {
				if nxt.entry < t && t < nxt.end {
					inner[nxt.entry] = {}
					break
				}
			}
		}
		if len(inner) == 0 {
			break
		}
		for e in inner {
			dropped[e] = {}
		}
		kept: [dynamic]u32
		for e in entries {
			if e not_in inner {
				append(&kept, e)
			}
		}
		entries = kept
	}
	labels := r.label_dropped ? union_sorted(extra, dropped) : extra
	known: Set
	for e in entries {
		known[e] = {}
	}
	work: [dynamic]u32
	for e in dropped {
		append(&work, e)
	}
	for f in funcs {
		for t in f.exits {
			append(&work, t)
		}
	}
	split := len(funcs)
	for len(work) > 0 {
		t := pop(&work)
		if t in known || !(lo <= t && t < hi) || t & 3 != 0 {
			continue
		}
		known[t] = {}
		n := bisect_right(entries[:], t)
		g := func_make(t, n < len(entries) ? entries[n] : hi, n > 0 ? entries[n - 1] : lo)
		discover(r, img, g, labels)
		append(&funcs, g)
		for x in g.exits {
			append(&work, x)
		}
	}
	funcs = drop_data(r, funcs, split, hi, dropped, guessed)
	leaves: [dynamic]u32
	for p in leaf_ptrs {
		if lo <= p && p < hi && p not_in known {
			append(&leaves, p)
		}
	}
	pointer_leaves(r, img, leaves[:], entries[:], hi, &funcs)
	slice.stable_sort_by(funcs[:], proc(a, b: ^Func) -> bool {return a.entry < b.entry})
	return funcs[:]
}

// The functions of build_module that are not data after a return: the
// first `split` came from splitting at the entries, the rest from the
// branches of others or from mid-function entries (dropped).
@(private = "file")
drop_data :: proc(r: Rules, funcs: [dynamic]^Func, split: int, hi: u32, dropped, guessed: Set) -> [dynamic]^Func {
	data: Set
	defer delete(data)
	for f in funcs[:split] {
		if f.entry in guessed && data_func(r, f, hi) {
			data[f.entry] = {}
		}
	}
	if len(data) == 0 {
		return funcs
	}
	at: map[u32]^Func
	defer delete(at)
	work: [dynamic]u32
	defer delete(work)
	for f, k in funcs {
		at[f.entry] = f
		if k < split ? f.entry not_in data : f.entry in dropped {
			append(&work, f.entry)
		}
	}
	live: Set
	defer delete(live)
	for len(work) > 0 {
		e := pop(&work)
		f, ok := at[e]
		if !ok || e in live {
			continue
		}
		live[e] = {}
		for t in f.exits {
			append(&work, t)
		}
	}
	kept: [dynamic]^Func
	for f in funcs {
		if f.entry in live {
			append(&kept, f)
		}
	}
	return kept
}

// True when f's code, in a module ending at hi, is data: a word that does
// not decode, a jump through $zero, a jump or call outside r.ram, or running
// off the module's end. A computed jump walks every word of the range, so
// its function is left alone.
@(private = "file")
data_func :: proc(r: Rules, f: ^Func, hi: u32) -> bool {
	if f.computed {
		return false
	}
	if f.end == hi && hi in f.exits {
		return true
	}
	for _, i in f.insns {
		if i.kind == .Bad || (i.kind == .Jr || i.kind == .Jalr) && i.rs == 0 {
			return true
		}
		if r.ram != {} && (i.kind == .Jump || i.kind == .Call) && !(r.ram[0] <= i.target && i.target < r.ram[1]) {
			return true
		}
	}
	return false
}

// Identity of a function's code: overlays often share identical copies.
func_key :: proc(f: ^Func) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	for pc in sorted_pcs(f) {
		pair: [8]u8
		put_u32(pair[:], 0, pc)
		put_u32(pair[:], 4, f.insns[pc].w)
		sha1.update(&ctx, pair[:])
	}
	// The Python tool's repr((start, end, sorted(labels))).
	b := strings.builder_make()
	fmt.sbprintf(&b, "(%d, %d, [", f.start, f.end)
	for l, k in sorted_keys(f.labels) {
		fmt.sbprintf(&b, k == 0 ? "%d" : ", %d", l)
	}
	strings.write_string(&b, "])")
	sha1.update(&ctx, b.buf[:])
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	return fmt.aprintf("f_%08x_%s", f.entry, hex_string(digest[:])[:8])
}
