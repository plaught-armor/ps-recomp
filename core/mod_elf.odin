// A mod's code, as data: the ELF a mod is built as (mod.elf), read into
// the segments that go into the console's mod region and the hooks its
// .mod_hooks section lists.
//
// The ELF is 32-bit little-endian MIPS, an executable linked inside the mod
// region. A .mod_hooks record is nine words: the kind (0 before, 1 after,
// 2 replace), the hooked function's key (slot, id, addr, sig[4]) and the
// mod function's address, which must be in one of the ELF's segments.
package core

import "core:fmt"

// One loadable segment: bytes at addr, then zeros up to size.
Mod_Segment :: struct {
	addr, size: u32,
	bytes:      []u8,
}

// A mod's code. lo and hi bound its segments, physical addresses (the low
// 29 bits); segments and hooks are in the read's allocator, and bytes slice
// the ELF.
Mod_Image :: struct {
	lo, hi:   u32,
	segments: []Mod_Segment,
	hooks:    []Mod_Hook,
}

MOD_HOOK_WORDS :: 9

@(private = "file")
ELF_LOAD :: 1

// The image in elf, which must lie in [lo, hi) (physical). Each hook's mod
// is `mod`. err is in the temp allocator.
mod_elf_read :: proc(elf: []u8, lo, hi: u32, mod: int, allocator := context.allocator) -> (img: Mod_Image, err: string) {
	u16_at :: proc(b: []u8, at: u32) -> u32 {return u32(b[at]) | u32(b[at + 1]) << 8}
	u32_at :: proc(b: []u8, at: u32) -> u32 {return u16_at(b, at) | u16_at(b, at + 2) << 16}
	n := u32(len(elf))
	if n < 52 || string(elf[:4]) != "\x7fELF" || elf[4] != 1 || elf[5] != 1 {
		return {}, "not a 32-bit little-endian ELF"
	}
	if u16_at(elf, 16) != 2 || u16_at(elf, 18) != 8 {
		return {}, "not a MIPS executable"
	}
	phoff, shoff := u32_at(elf, 28), u32_at(elf, 32)
	phsize, phnum := u16_at(elf, 42), u16_at(elf, 44)
	shsize, shnum, shstr := u16_at(elf, 46), u16_at(elf, 48), u16_at(elf, 50)
	if phnum == 0 || phsize < 32 || u64(phoff) + u64(phsize) * u64(phnum) > u64(n) {
		return {}, "bad program headers"
	}
	if shnum != 0 && (shsize < 40 || shstr >= shnum || u64(shoff) + u64(shsize) * u64(shnum) > u64(n)) {
		return {}, "bad section headers"
	}

	segs := make([dynamic]Mod_Segment, allocator)
	img.lo, img.hi = max(u32), 0
	for k in 0 ..< phnum {
		ph := phoff + k * phsize
		if u32_at(elf, ph) != ELF_LOAD {continue}
		off, addr, file, mem := u32_at(elf, ph + 4), u32_at(elf, ph + 8), u32_at(elf, ph + 16), u32_at(elf, ph + 20)
		p := addr & 0x1fff_ffff
		if file > mem || u64(off) + u64(file) > u64(n) {
			delete(segs)
			return {}, fmt.tprintf("bad segment at %08x", addr)
		}
		if mem == 0 {continue}
		if p < lo || u64(p) + u64(mem) > u64(hi) {
			delete(segs)
			return {}, fmt.tprintf("segment %08x-%08x is outside the mod region %08x-%08x", p, u64(p) + u64(mem), lo, hi)
		}
		append(&segs, Mod_Segment{p, mem, elf[off:][:file]})
		img.lo, img.hi = min(img.lo, p), max(img.hi, p + mem)
	}
	if len(segs) == 0 {
		delete(segs)
		return {}, "no segment to load"
	}
	img.segments = segs[:]

	// .mod_hooks, found by name.
	hooks: []u8
	if shnum != 0 {
		names_at := shoff + shstr * shsize
		names_off, names_size := u32_at(elf, names_at + 16), u32_at(elf, names_at + 20)
		if u64(names_off) + u64(names_size) > u64(n) {
			mod_image_delete(img, allocator)
			return {}, "bad section names"
		}
		names := elf[names_off:][:names_size]
		for k in 0 ..< shnum {
			sh := shoff + k * shsize
			name := u32_at(elf, sh)
			if u64(name) + len(".mod_hooks") >= u64(names_size) || string(names[name:][:len(".mod_hooks") + 1]) != ".mod_hooks\x00" {
				continue
			}
			off, size := u32_at(elf, sh + 16), u32_at(elf, sh + 20)
			if u64(off) + u64(size) > u64(n) || size % (MOD_HOOK_WORDS * 4) != 0 {
				mod_image_delete(img, allocator)
				return {}, "bad .mod_hooks section"
			}
			hooks = elf[off:][:size]
			break
		}
	}
	out := make([]Mod_Hook, len(hooks) / (MOD_HOOK_WORDS * 4), allocator)
	img.hooks = out
	for &h, k in out {
		r := u32(k) * MOD_HOOK_WORDS * 4
		kind := u32_at(hooks, r)
		if kind > u32(Mod_Hook_Kind.Replace) {
			mod_image_delete(img, allocator)
			return {}, fmt.tprintf("hook %d: kind %d", k, kind)
		}
		h = {
			key = {slot = u32_at(hooks, r + 4), id = u32_at(hooks, r + 8), addr = u32_at(hooks, r + 12)},
			kind = Mod_Hook_Kind(kind),
			mod = mod,
			fn = u32_at(hooks, r + 32),
		}
		for &w, i in h.key.sig {w = u32_at(hooks, r + 16 + u32(i) * 4)}
		if !mod_image_has(img, h.fn) {
			e := fmt.tprintf("hook %d on %08x: mod function %08x is not in the image", k, h.key.addr, h.fn)
			mod_image_delete(img, allocator)
			return {}, e
		}
	}
	return img, ""
}

// Whether addr is in a segment of img.
mod_image_has :: proc(img: Mod_Image, addr: u32) -> bool {
	p := addr & 0x1fff_ffff
	for s in img.segments {
		if p >= s.addr && p - s.addr < s.size {return true}
	}
	return false
}

mod_image_delete :: proc(img: Mod_Image, allocator := context.allocator) {
	delete(img.segments, allocator)
	delete(img.hooks, allocator)
}
