// Learned functions: native code compiled from runs the interpreter learned
// (core/learn.odin, psx/native/learned.odin), each valid while RAM
// holds the words it was compiled from. interpret runs one in place of the
// interpreter when RAM holds all its words.
//
// A function's words are compared with RAM on its first resolve and again
// only after one of its pages was written since: the compare arms those
// pages, and ram_armed_write bumps a written page's generation. RAM put
// back behind the guard (checkpoint_restore) bumps learned_epoch instead.
// The result of the last compare is kept, so code that is not resident is
// not compared again until its pages change.
//
// With none loaded (learned_loaded false), interpret does no lookup.
//
// -define:LEARNED_CHECK=true compares again on every resolve the last
// compare's result stands for, and prints each entry whose RAM changed
// without its pages' generations or the epoch: a write that missed the
// guard.
package psx_cpu

@(require) import "core:fmt"
import "core:slice"

LEARNED_CHECK :: #config(LEARNED_CHECK, false)

Learned_Entry :: struct {
	lo:       u32, // the first word's address
	words:    []u32,
	fn:       Func_Proc,
	// The generation sum of its pages and learned_epoch at the last
	// compare, and whether RAM held its words then. Epoch 0: never compared.
	gen:      u32,
	epoch:    u32,
	resident: bool,
}

// Whether any learned function is registered.
learned_loaded: bool

// The learned functions by entry, the resident one first once found.
learned: map[u32][dynamic]Learned_Entry

// Per RAM page, the writes since it was last armed for a learned compare.
learned_gen: [RAM_PAGES]u32

learned_epoch: u32 = 1

// Calls run by a learned function.
learned_hits: u64

// Whether the span of n words from lo can be a learned function's: all in
// RAM, without wrapping.
learned_span_ok :: proc(lo: u32, n: int) -> bool {
	return is_ram_addr(lo) && lo % 4 == 0 && n > 0 && int(lo & (RAM_SIZE - 1)) + 4 * n <= RAM_SIZE
}

// Register a learned function entered at entry, compiled from words at lo
// (learned_span_ok); words must outlive it. The first function registered
// for an entry, lo and words wins: a later one for the same code (the
// player's learned blob after a port's recompiled learned functions,
// psx.Boot) is dropped.
register_learned :: proc(entry, lo: u32, words: []u32, fn: Func_Proc) {
	assert(learned_span_ok(lo, len(words)))
	list := learned[entry]
	for e in list {
		if e.lo == lo && slice.equal(e.words, words) {
			return
		}
	}
	append(&list, Learned_Entry{lo = lo, words = words, fn = fn})
	learned[entry] = list
	learned_loaded = true
}

// A recompiled learned function (recomp/r3000 learned option): entered at
// entry, compiled from the n words at index at of its package's WORDS,
// whose first is at lo.
Learned_Func :: struct {
	entry, lo: u32,
	at, n:     u32,
	fn:        Func_Proc,
}

// Register a package's recompiled learned functions (register_learned),
// their words in words.
register_learned_funcs :: proc(funcs: []Learned_Func, words: []u32) {
	for f in funcs {
		register_learned(f.entry, f.lo, words[f.at:][:f.n], f.fn)
	}
}

// The learned function for a call to addr whose words RAM holds; nil none.
@(private)
learned_resolve :: proc(addr: u32) -> Func_Proc {
	list, ok := learned[addr]
	if !ok {
		return nil
	}
	for &e, k in list {
		if learned_resident(&e) {
			if k != 0 {
				// Keep the resident variant first for the next lookup.
				list[0], list[k] = list[k], list[0]
			}
			return list[0].fn
		}
	}
	return nil
}

@(private = "file")
learned_resident :: proc(e: ^Learned_Entry) -> bool #no_bounds_check {
	o := e.lo & (RAM_SIZE - 1)
	first := o >> RAM_PAGE_SHIFT
	last := (o + 4 * u32(len(e.words)) - 1) >> RAM_PAGE_SHIFT
	gen: u32
	for p in first ..= last {
		gen += learned_gen[p]
	}
	// Generations only grow, so an unchanged sum is unchanged pages.
	if e.epoch == learned_epoch && e.gen == gen {
		when LEARNED_CHECK {
			if learned_same(e, o) != e.resident {
				fmt.eprintfln("learned check: %08x changed behind the guard (resident %v)", e.lo, e.resident)
			}
		}
		return e.resident
	}
	e.resident = learned_same(e, o)
	for p in first ..= last {
		ram_armed[p] = true
	}
	e.gen, e.epoch = gen, learned_epoch
	return e.resident
}

// Whether RAM at offset o holds e's words.
@(private = "file")
learned_same :: #force_inline proc(e: ^Learned_Entry, o: u32) -> bool #no_bounds_check {
	return string(ram[o:][:4 * len(e.words)]) == string(([^]u8)(raw_data(e.words))[:4 * len(e.words)])
}
