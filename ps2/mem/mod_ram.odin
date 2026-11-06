// The EE's mod region: the mods' code, data and stack, at MOD_BASE, above
// the largest RAM any console has (128 MiB) and below the hardware
// registers, where the bus maps nothing. slow_addr reaches it in every RAM
// mirror (kuseg, kseg0, kseg1), so only mod code and the interpreter's
// fetch of it pay for it, and with no mods loaded (mod_ram nil) the bus is
// as before. Mod code links in the same 256 MiB as the game's, so a mod's
// `jal` reaches the game's functions.
//
// Layout, as the PS1's (psx/cpu/mod_ram.odin): the mods' images where they
// are linked, then a guard word, then MOD_STACK bytes of stack; mod_sp is
// the region's top. mod_ram_check after every hook makes an overflow of the
// stack fatal. The mods' functions (core.Mod_Image funcs) are never written:
// a store into one is fatal, so the native code play compiled for them
// (mod_funcs, ps2/mods_native.odin) always stands for what the region
// holds. DMA never reaches the region: an address in it is fatal
// (dma_addr).
package ps2_mem

import "core:fmt"
import "core:slice"
import "core:strings"
import "ps:core"
import cpu "../cpu"

MOD_BASE :: 0x0e00_0000
MOD_REGION :: 0x0100_0000
MOD_STACK :: 16 * 1024
// The address a replacement calls to run the function it replaces
// (mod_call_original): host code, below the region, so no image, guard or
// stack is at it.
MOD_ORIGINAL :: MOD_BASE - 16

@(private = "file")
MOD_GUARD :: 0x4d4f_4447

// The region, from MOD_BASE; nil with no mods.
mod_ram: []u8

// Top of the stack before and after hooks run on: the region's top.
mod_sp: u32

@(private = "file")
mod_guard: u32

// Per word of mod_ram: whether a mod function's code is in it. nil with no
// mods: the one test a store past RAM makes.
@(private = "file")
mod_code: []bool

// Each mod function's first word (offset in mod_ram) and length in words,
// sorted by offset: what native code may stand for (mod_func_words).
@(private = "file")
Mod_Span :: struct {
	at, words: u32,
}
@(private = "file")
mod_spans: []Mod_Span

// Per word of mod_ram: the native code for the mod function that starts
// there (nil none); nil with no native code. mod_native_calls counts the
// calls that ran one, mod_interp_calls the calls into the region that were
// interpreted (ps2/mod.odin mod_interp_hook): counted per call, not per
// instruction, so the interpreter's loop is the same with no mods.
mod_funcs: []cpu.Func_Proc
mod_native_calls, mod_interp_calls: u64

// Each mod's image and id, for the message of a store into its code.
@(private = "file")
Mod_Owner :: struct {
	lo, hi: u32,
	id:     string,
}
@(private = "file")
mod_owners: []Mod_Owner

// Make the region for images (their addresses physical, inside it) and set
// mod_sp to its top. An error names the two mods whose images overlap; err
// is in the temp allocator.
mod_ram_load :: proc(images: []core.Mod_Image, who: []string) -> (err: string) {
	assert(len(images) == len(who))
	if mod_ram != nil {return "mod: region loaded twice"}
	if len(images) == 0 {return ""}
	end := u32(MOD_BASE)
	for a, i in images {
		if a.lo < MOD_BASE || a.hi > MOD_BASE + MOD_REGION {
			return fmt.tprintf("mod %s: image %08x-%08x is outside the mod region", who[i], a.lo, a.hi)
		}
		for b, j in images[:i] {
			if a.lo < b.hi && b.lo < a.hi {
				return fmt.tprintf("mod %s and mod %s: images %08x-%08x and %08x-%08x overlap", who[j], who[i], b.lo, b.hi, a.lo, a.hi)
			}
		}
		end = max(end, a.hi)
	}
	guard := (end - MOD_BASE + 15) &~ 15
	size := (guard + 4 + MOD_STACK + 0xfff) &~ 0xfff
	if size > MOD_REGION {
		return fmt.tprintf("mod: images and stack need %d bytes, the region has %d", size, MOD_REGION)
	}
	mod_ram = make([]u8, size)
	mod_code = make([]bool, size / 4)
	mod_owners = make([]Mod_Owner, len(images))
	spans := make([dynamic]Mod_Span)
	for img, i in images {
		for s in img.segments {copy(mod_ram[s.addr - MOD_BASE:][:s.size], s.bytes)}
		for f in img.funcs {
			at := (f.addr & 0x1fff_ffff) - MOD_BASE
			for &c in mod_code[at / 4:][:len(f.bytes) / 4] {c = true}
			append(&spans, Mod_Span{at, u32(len(f.bytes) / 4)})
		}
		mod_owners[i] = {img.lo, img.hi, strings.clone(who[i])}
	}
	// Images do not overlap, and each image's funcs are one per address.
	slice.sort_by(spans[:], proc(a, b: Mod_Span) -> bool {return a.at < b.at})
	mod_spans = spans[:]
	mod_guard = guard
	(^u32le)(&mod_ram[guard])^ = MOD_GUARD
	mod_sp = MOD_BASE + size
	return ""
}

// Whether addr is in the mod region (any RAM mirror); never with no mods.
mod_ram_has :: #force_inline proc(addr: u32) -> bool {
	switch addr >> 28 {
	case 0x0, 0x2, 0x3, 0x8, 0xa:
		return (addr & 0x0fff_ffff) - MOD_BASE < u32(len(mod_ram))
	}
	return false
}

// The offset in mod_ram of addr (any RAM mirror); false outside the region.
@(private = "file")
mod_off :: #force_inline proc(addr: u32) -> (off: u32, ok: bool) {
	switch addr >> 28 {
	case 0x0, 0x2, 0x3, 0x8, 0xa:
		off = (addr & 0x0fff_ffff) - MOD_BASE
		return off, off < u32(len(mod_ram))
	}
	return 0, false
}

// The length in words of the mod function whose first word is at addr; 0
// when none starts there.
mod_func_words :: proc(addr: u32) -> u32 {
	off, ok := mod_off(addr)
	if !ok || addr & 3 != 0 {return 0}
	k, found := slice.binary_search_by(mod_spans, off, proc(s: Mod_Span, off: u32) -> slice.Ordering {return slice.cmp(s.at, off)})
	return found ? mod_spans[k].words : 0
}

// Make the native code fn stand for the mod function at entry, which must
// be in the region (ps2/mods_native.odin).
mod_native_set :: proc(entry: u32, fn: cpu.Func_Proc) {
	off, ok := mod_off(entry)
	assert(ok && entry & 3 == 0)
	if mod_funcs == nil {mod_funcs = make([]cpu.Func_Proc, len(mod_ram) / 4)}
	mod_funcs[off >> 2] = fn
}

// The native code for the mod function at addr; nil when there is none
// (no mod function starts there, or no native code was loaded).
mod_func_at :: #force_inline proc(addr: u32) -> cpu.Func_Proc {
	if mod_funcs == nil || addr & 3 != 0 {return nil}
	off, ok := mod_off(addr)
	if !ok {return nil}
	return mod_funcs[off >> 2]
}

// mod_func_at, counted as a call when there is code.
mod_native :: #force_inline proc(addr: u32) -> cpu.Func_Proc {
	fn := mod_func_at(addr)
	if fn != nil {mod_native_calls += 1}
	return fn
}

// One line on stderr, with mods.
mod_print :: proc() {
	if mod_ram == nil {return}
	fmt.eprintfln("mod: %d interpreted calls into the region, %d native calls", mod_interp_calls, mod_native_calls)
}

// For the message of a host view of guest memory (a kernel string, a SIF
// transfer, ram_slice) that refuses addr: why, when it is in the mod
// region, which only the mods' own loads and stores reach; else "".
mod_region_note :: proc(addr: u32) -> string {
	return mod_ram_has(addr) ? " (in the mod region: only mods' own loads and stores reach it; pass the game a buffer in its RAM)" : ""
}

// slow_addr for a store of n bytes at a: fatal when they are in a mod
// function's code.
@(private)
slow_store_addr :: #force_inline proc(a: u32, n: u32) -> rawptr {
	p := slow_addr(a)
	if mod_code != nil && p != nil && mod_ram_has(a) {mod_code_check(a, n)}
	return p
}

@(private = "file")
mod_code_check :: proc(a, n: u32) {
	o := (a & 0x0fff_ffff) - MOD_BASE
	last := min(o + n - 1, u32(len(mod_ram)) - 1)
	hit := false
	for w in o >> 2 ..= last >> 2 {hit ||= mod_code[w]}
	if !hit {return}
	p := a & 0x0fff_ffff
	for w in mod_owners {
		if p >= w.lo && p < w.hi {cpu.fatal("mod %s: store into its code at %08x (mods cannot change their code)", w.id, a)}
	}
	cpu.fatal("mod: store into mod code at %08x", a)
}

// A DMA address in the mod region: fatal (mod code and data are no DMA
// source or target).
@(private)
mod_dma_check :: proc(a: u32) {
	if (a & 0x0fff_ffff) - MOD_BASE < u32(len(mod_ram)) {
		cpu.fatal("mod: DMA at %08x, in the mod region", a)
	}
}

// Fatal when the hook at fn overflowed the mod stack (wrote its guard).
mod_ram_check :: #force_inline proc(fn: u32) {
	if mod_ram != nil && (^u32le)(&mod_ram[mod_guard])^ != MOD_GUARD {
		cpu.fatal("mod: the hook at %08x overflowed the %d-byte mod stack", fn, MOD_STACK)
	}
}

// Free the region (tests).
mod_ram_free :: proc() {
	delete(mod_ram)
	delete(mod_code)
	delete(mod_spans)
	delete(mod_funcs)
	for o in mod_owners {delete(o.id)}
	delete(mod_owners)
	mod_ram, mod_guard, mod_sp = nil, 0, 0
	mod_code, mod_spans, mod_funcs, mod_owners = nil, nil, nil, nil
	mod_native_calls, mod_interp_calls = 0, 0
}
