// Recompiled executable code against RAM writes. A function in the fixed
// table is the executable's bytes at boot; a game that later loads other code
// over them (an overlay into space the executable leaves for it, or a buffer
// reused for code) must not run the old function. watch_code arms every page
// that holds one; the page's first write demotes its functions to signed
// entries (Ovl_Entry) that run only while their first words are the ones they
// were recompiled from. A demoted function's call puts the page's functions
// whose words are back into the fixed table again (code_promote): a write
// of the same bytes (a RAM snapshot put back) or one undone demotes the page
// but does not slow its calls for good.
package psx_cpu

// Pages holding a function of the fixed table, still undemoted.
code_pages: [RAM_PAGES]bool

// A demoted function: its address, the code words it was recompiled from
// and its procedure (the hook, when one replaced it), as its signed entry in
// the overlay table has them. The page keeps its own copy so promoting and
// demoting it again look up no entry.
@(private = "file")
Demoted :: struct {
	addr: u32,
	sig:  [4]u32,
	fn:   Func_Proc,
}

// Each page's demoted functions from its first demotion; their signed
// entries stay in the overlay table. Kept after a promotion: the page's next
// demotion only empties their fixed slots again.
@(private = "file")
page_demoted: [RAM_PAGES][dynamic]Demoted

// The signed entry code_demote made for the function at addr.
@(private = "file")
demoted_entry :: proc(addr: u32) -> ^Ovl_Entry {
	for &e in dispatch.overlay[addr] {
		if e.slot == addr {
			return &e
		}
	}
	panic("demoted function without its entry")
}

// Watch the pages of every function in the fixed table. Called once, after
// the executable's functions, the native code and the hooks are registered
// and before the BIOS registers its own: those are not the executable's code.
watch_code :: proc() {
	if dispatch.fixed == nil {
		return
	}
	for fn, i in dispatch.fixed {
		if fn != nil {
			p := u32(i) * 4 >> RAM_PAGE_SHIFT
			code_pages[p] = true
			ram_armed[p] = true
		}
	}
}

// The slow path of ram_guard: page p's first write since it was armed, before
// the write lands. Out of line, so ram_guard stays one compare and one call
// in every store helper that inlines it.
ram_armed_write :: #force_no_inline proc(p: u32) #no_bounds_check {
	ram_armed[p] = false
	if code_pages[p] {
		code_demote(p)
	}
	if ram_keep != nil {
		ram_keep(p)
	}
}

// Move page p's functions from the fixed table to the overlay table, each
// signed with the code words it was recompiled from (still in RAM: the write
// has not landed). The entry's slot is its own address, below which no real
// overlay entry lies (an overlay's functions follow its header).
@(private = "file")
code_demote :: #force_no_inline proc(p: u32) {
	code_pages[p] = false
	when FALLBACK_COUNT {demoted_pages += 1}
	list := &page_demoted[p]
	if len(list^) != 0 {
		// Demoted before: the functions code_promote put back are signed
		// already. A hook set while one was back (its slot is not its
		// procedure) replaces its procedure and its entry's. A function
		// registered on the page since stays, as one registered after
		// watch_code does.
		for &d in list^ {
			slot := &dispatch.fixed[fn_index(d.addr)]
			if slot^ == nil {
				continue
			}
			if slot^ != d.fn {
				d.fn = slot^
				demoted_entry(d.addr).fn = d.fn
			}
			slot^ = nil
		}
		return
	}
	base := p << RAM_PAGE_SHIFT
	for i in fn_index(base) ..< fn_index(base) + RAM_PAGE / 4 {
		fn := dispatch.fixed[i]
		if fn == nil {
			continue
		}
		addr := 0x80000000 | i << 2
		e := Ovl_Entry{addr = addr, slot = addr, id = r32(addr), fn = fn}
		for &w, k in e.sig {
			w = r32(addr + u32(k) * 4)
		}
		append(list, Demoted{addr, e.sig, fn})
		register_overlay_funcs({e})
		dispatch.fixed[i] = nil
		when FALLBACK_COUNT {dispatch_demoted[addr] = 0}
	}
}

// After a call resolved to e, a demoted function (slot == addr, which
// call_slow checks: a resident overlay's never is), put its page's demoted
// functions whose signature matches back into the fixed table, e among
// them, and arm the page again, so its next write demotes them again. A
// function whose code changed does not resolve, so no call compares a page
// more than once between two of its writes: a page whose code keeps
// changing costs a pass over its functions per write, not per call. Arming
// again costs ram_keep (checkpoint.odin) no copy, since a page disarmed
// inside a pass was kept by it already; only the page's version changes.
code_promote :: #force_no_inline proc(e: ^Ovl_Entry) {
	p := fn_index(e.addr) >> (RAM_PAGE_SHIFT - 2)
	next: for &d in page_demoted[p] {
		for w, k in d.sig {
			if r32(d.addr + u32(k) * 4) != w {
				continue next
			}
		}
		dispatch.fixed[fn_index(d.addr)] = d.fn
	}
	code_pages[p] = true
	ram_armed[p] = true
	when FALLBACK_COUNT {promoted_pages += 1}
}

// hook and hook_overlay on a demoted function at addr: the hook replaces its
// procedure, its entry's, and its fixed slot's when it is back in the fixed
// table, so no promotion or demotion puts the replaced one back. ok is false
// when addr holds no demoted function.
@(private)
demoted_hook :: proc(addr: u32, fn: Func_Proc) -> (original: Func_Proc, ok: bool) {
	if !is_ram_addr(addr) || addr & 3 != 0 {
		return nil, false
	}
	i := fn_index(addr)
	for &d in page_demoted[i >> (RAM_PAGE_SHIFT - 2)] {
		if fn_index(d.addr) != i {
			continue
		}
		original = d.fn
		if slot := &dispatch.fixed[i]; slot^ != nil {
			original = slot^
			slot^ = fn
		}
		d.fn = fn
		demoted_entry(d.addr).fn = fn
		return original, true
	}
	return nil, false
}

// Whether a call to addr would run recompiled code: a fixed function, or an
// overlay or demoted one whose code is in RAM.
has_func :: proc(addr: u32) -> bool {
	return is_ram_addr(addr) && dispatch.fixed[fn_index(addr)] != nil || resolve_overlay(addr) != nil
}
