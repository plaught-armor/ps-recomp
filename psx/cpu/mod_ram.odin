// The mod region: the mods' code, data and stack, at MOD_BASE in the
// otherwise unused expansion 1 range. load_slow and store_slow reach it, so
// only mod code pays for it, and with no mods loaded (mod_ram nil) the bus
// is as before. The interpreter fetches mod code from it the same way.
//
// Layout: the mods' images where they are linked, then a guard word, then
// MOD_STACK bytes of stack; mod_sp is the region's top. mod_call checks the
// guard after every hook, so a hook that overflowed the stack is fatal.
//
// The mods' functions (core.Mod_Image funcs) are their code, and are never
// written: a store into one is fatal, so the native code play compiled for
// them (mod_funcs) always stands for what the region holds.
package psx_cpu

import "core:fmt"
import "core:slice"
import "core:strings"
import "ps:core"

MOD_BASE :: 0x1f40_0000
// The region's largest size: up to the scratchpad at 0x1f800000.
MOD_REGION :: 0x40_0000
MOD_STACK :: 16 * 1024
// The address a replacement calls to run the function it replaces
// (mod_api.h's mod_call_original, mod.odin): host code, below the region,
// so no image, guard or stack is at it.
MOD_ORIGINAL :: MOD_BASE - 16

@(private = "file")
MOD_GUARD :: 0x4d4f_4447

// The region, from MOD_BASE; nil with no mods.
mod_ram: []u8

// Offset of the guard word in mod_ram.
@(private = "file")
mod_guard: u32

// Per word of mod_ram: whether a mod function's code is in it.
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

// Each mod's image and id, for the message of a store into its code.
@(private = "file")
Mod_Owner :: struct {
	lo, hi: u32,
	id:     string,
}
@(private = "file")
mod_owners: []Mod_Owner

// Per word of mod_ram: the native code for the mod function that starts
// there (nil none), and how many calls ran one. nil with no native code.
mod_funcs: []Func_Proc
mod_native_hits: u64

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

// Whether addr is in the mod region; never with no mods.
mod_ram_has :: #force_inline proc(addr: u32) -> bool {
	return (addr & 0x1fff_ffff) - MOD_BASE < u32(len(mod_ram))
}

// Fatal when the size bytes at offset o of the region, address addr, are
// in a mod function's code.
@(private)
mod_code_check :: #force_inline proc(o, size, addr: u32) {
	if mod_code[o >> 2] || mod_code[(o + size - 1) >> 2] {mod_code_store(addr)}
}

@(private = "file")
mod_code_store :: proc(addr: u32) {
	p := addr & 0x1fff_ffff
	for o in mod_owners {
		if p >= o.lo && p < o.hi {fatal("mod %s: store into its code at %08x (mods cannot change their code)", o.id, addr)}
	}
	fatal("mod: store into mod code at %08x", addr)
}

// The length in words of the mod function whose first word is at addr; 0
// when none starts there.
mod_func_words :: proc(addr: u32) -> u32 {
	if mod_ram == nil || addr & 3 != 0 {return 0}
	off := (addr & 0x1fff_ffff) - MOD_BASE
	k, found := slice.binary_search_by(mod_spans, off, proc(s: Mod_Span, off: u32) -> slice.Ordering {return slice.cmp(s.at, off)})
	return found ? mod_spans[k].words : 0
}

// Make the native code fn stand for the mod function at entry, which must
// be in the region (psx/native/mods.odin).
mod_native_set :: proc(entry: u32, fn: Func_Proc) {
	off := (entry & 0x1fff_ffff) - MOD_BASE
	assert(off < u32(len(mod_ram)) && entry & 3 == 0)
	if mod_funcs == nil {mod_funcs = make([]Func_Proc, len(mod_ram) / 4)}
	mod_funcs[off >> 2] = fn
}

// Run the native code for the mod function at addr; false when there is
// none (no mod function starts there, or no native code was loaded).
@(private)
mod_run :: #force_inline proc(addr: u32) -> bool {
	if mod_funcs == nil {return false}
	off := (addr & 0x1fff_ffff) - MOD_BASE
	if off >= u32(len(mod_ram)) || addr & 3 != 0 {return false}
	fn := mod_funcs[off >> 2]
	if fn == nil {return false}
	mod_native_hits += 1
	fn()
	return true
}

// Fatal when the hook at fn overflowed the mod stack (wrote its guard).
@(private)
mod_ram_check :: #force_inline proc(fn: u32) {
	if mod_ram != nil && (^u32le)(&mod_ram[mod_guard])^ != MOD_GUARD {
		fatal("mod: the hook at %08x overflowed the %d-byte mod stack", fn, MOD_STACK)
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
	mod_code, mod_spans, mod_funcs, mod_owners, mod_native_hits = nil, nil, nil, nil, 0
}
