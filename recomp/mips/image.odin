package mips

import "core:strings"

Section :: struct {
	name:  string,
	addr:  u32,
	size:  u32,
	data:  []u8, // nil for NOBITS
	flags: u32,
}

SHF_ALLOC :: 2
SHF_EXEC :: 4
SHT_NOBITS :: 8

// Code and data as loaded: data[0] sits at base.
Image :: struct {
	base:     u32,
	data:     []u8,
	entry:    u32,
	// ELF sections; none for a PS-X EXE or an overlay, which do not tell
	// code from data.
	sections: []Section,
}

word :: proc(img: Image, addr: u32) -> (u32, bool) {
	o := i64(addr) - i64(img.base)
	if o < 0 || o + 4 > i64(len(img.data)) || addr & 3 != 0 {
		return 0, false
	}
	return u32le(img.data, int(o)), true
}

// A PS-X EXE: the text segment, loaded at its address.
load_psx_exe :: proc(path: string) -> Image {
	raw := read_file(path)
	if len(raw) < 0x800 || string(raw[:8]) != "PS-X EXE" {
		fail("%s: not a PS-X EXE", path)
	}
	text, size := u32le(raw, 0x18), int(u32le(raw, 0x1c))
	return {base = text, data = raw[0x800:min(0x800 + size, len(raw))], entry = u32le(raw, 0x10)}
}

// A 32-bit little-endian MIPS ELF: every allocated section in one flat view,
// NOBITS reading as zero. Sections at 0x01000000 and up (the EE's .vudata,
// in VU memory) stay out of it.
load_elf :: proc(path: string) -> Image {
	raw := read_file(path)
	if len(raw) < 52 || string(raw[:4]) != "\x7fELF" {
		fail("%s: not an ELF file", path)
	}
	u16le :: proc(b: []u8, o: int) -> u32 {return u32(b[o]) | u32(b[o + 1]) << 8}
	img: Image
	img.entry = u32le(raw, 24)
	shoff := int(u32le(raw, 32))
	shentsize := int(u16le(raw, 46))
	shnum := int(u16le(raw, 48))
	shstrndx := int(u16le(raw, 50))
	str_off := int(u32le(raw, shoff + shstrndx * shentsize + 16))
	sections: [dynamic]Section
	lo, hi := u32(0xffffffff), u32(0)
	for i in 0 ..< shnum {
		h := shoff + i * shentsize
		name_off := int(u32le(raw, h))
		typ := u32le(raw, h + 4)
		flags := u32le(raw, h + 8)
		addr := u32le(raw, h + 12)
		off := int(u32le(raw, h + 16))
		size := u32le(raw, h + 20)
		if flags & SHF_ALLOC == 0 || size == 0 {
			continue
		}
		s := Section {
			name  = strings.clone_from_cstring(cstring(&raw[str_off + name_off])),
			addr  = addr,
			size  = size,
			flags = flags,
		}
		if typ != SHT_NOBITS {
			s.data = raw[off:off + int(size)]
		}
		append(&sections, s)
		if addr < 0x01000000 {
			lo = min(lo, addr)
			hi = max(hi, addr + size)
		}
	}
	img.base = lo
	img.data = make([]u8, hi - lo)
	for s in sections {
		if s.data != nil && s.addr < 0x01000000 {
			copy(img.data[s.addr - lo:], s.data)
		}
	}
	img.sections = sections[:]
	return img
}

find_section :: proc(img: Image, name: string) -> ^Section {
	for &s in img.sections {
		if s.name == name {
			return &s
		}
	}
	return nil
}
