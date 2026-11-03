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
package psx_cpu

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
// (learned_span_ok); words must outlive it.
register_learned :: proc(entry, lo: u32, words: []u32, fn: Func_Proc) {
	assert(learned_span_ok(lo, len(words)))
	list := learned[entry]
	append(&list, Learned_Entry{lo = lo, words = words, fn = fn})
	learned[entry] = list
	learned_loaded = true
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
		return e.resident
	}
	e.resident = string(ram[o:][:4 * len(e.words)]) == string(([^]u8)(raw_data(e.words))[:4 * len(e.words)])
	for p in first ..= last {
		ram_armed[p] = true
	}
	e.gen, e.epoch = gen, learned_epoch
	return e.resident
}
