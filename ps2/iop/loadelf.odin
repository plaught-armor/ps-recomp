// LOADFILE's loadelf (function 1, the EE's SifLoadElf and SifLoadElfPart),
// verified against the SCPH-90001 retail IOP module. Section "all" loads
// every PT_LOAD segment with file bytes, those bytes only: retail does not
// zero the rest of memsz, unlike LoadExecPS2's loader (mem.load_elf). Any
// other name loads that one section. Neither may load below 0x80000, the
// EE kernel's memory. Retail checks the header strictly first.
//
// Host limits retail lacks: every segment or section must lie in main RAM
// and every header, table and byte range within the file, all checked
// before anything is written; out of range is a load error like any other.
//
// Not done: retail first asks modload whether the path's device may boot
// and replies -204 when not. That rule is not traced; only the disc is
// read here, so another device fails as a missing file.
package ps2_iop

import "core:encoding/endian"
import "core:fmt"
import "core:slice"
import "core:strings"
import "ps:core"
import mem "../mem"

// Retail refuses an address at or below 0x7ffff.
@(private = "file")
LOAD_FLOOR :: 0x00080000

@(private = "file")
PT_LOAD :: 1

// What the server replies: the entry point for "all", 0 for a section (whose
// load leaves retail's reply words unset) and on any error.
@(private)
loadelf :: proc(path, section: string) -> (entry: u32) {
	colon := strings.index_byte(path, ':')
	if colon >= 0 && !strings.has_prefix(path, "cdrom") {
		fmt.eprintfln("sif: load elf %s: not on the disc", path)
		return 0
	}
	data, found := disc_file(path, core.host_allocator)
	if !found {
		fmt.eprintfln("sif: load elf %s: no such file", path)
		return 0
	}
	defer delete(data, core.host_allocator)
	ok: bool
	if section == "all" {
		entry, ok = load_all(data)
	} else {
		ok = load_section(data, section)
	}
	if !ok {
		fmt.eprintfln("sif: load elf %s %s: not loadable", path, section)
		return 0
	}
	fmt.eprintfln("sif: load elf %s %s, entry %08x", path, section, entry)
	return entry
}

// The header checks retail makes, in its order: 32-bit little-endian
// executable for MIPS, with the standard header and table entry sizes.
@(private = "file")
header :: proc(data: []u8) -> (h: mem.Elf_Header, ok: bool) {
	h = mem.elf_header(data) or_return
	if h.class != 1 || h.encoding != 1 || h.type != 2 || h.machine != 8 {return}
	if h.ehsize != 52 || h.phentsize != 32 || (h.shnum != 0 && h.shentsize != 40) {return}
	return h, true
}

@(private = "file")
load_all :: proc(data: []u8) -> (entry: u32, ok: bool) {
	Segment :: struct {
		dst: []u8,
		off: u32,
	}
	h := header(data) or_return
	if !table_in(data, h.phoff, h.phnum, 32) {return}
	segs := make([dynamic]Segment, 0, h.phnum, context.temp_allocator)
	for i in 0 ..< h.phnum {
		p := int(h.phoff + i * 32)
		filesz := le32(data, p + 16)
		if le32(data, p) != PT_LOAD || filesz == 0 {continue}
		off, vaddr := le32(data, p + 4), le32(data, p + 8)
		if vaddr < LOAD_FLOOR || !in_file(data, off, filesz) {return}
		dst := ee_range(vaddr, filesz) or_return
		append(&segs, Segment{dst, off})
	}
	// Retail sends the segments in file order.
	slice.stable_sort_by(segs[:], proc(a, b: Segment) -> bool {return a.off < b.off})
	for s in segs {
		copy(s.dst, data[s.off:][:len(s.dst)])
	}
	return h.entry, true
}

// The first section of that name with bytes, to its address.
@(private = "file")
load_section :: proc(data: []u8, name: string) -> bool {
	h := header(data) or_return
	if !table_in(data, h.shoff, h.shnum, 40) || h.shstrndx >= h.shnum {return false}
	str := int(h.shoff + h.shstrndx * 40)
	str_off, str_size := le32(data, str + 16), le32(data, str + 20)
	if !in_file(data, str_off, str_size) {return false}
	names := data[str_off:][:str_size]
	for i in 0 ..< h.shnum {
		s := int(h.shoff + i * 40)
		at, size := le32(data, s), le32(data, s + 20)
		if at >= str_size || size == 0 {continue}
		if strings.truncate_to_byte(string(names[at:]), 0) != name {continue}
		addr, off := le32(data, s + 12), le32(data, s + 16)
		if addr < LOAD_FLOOR || !in_file(data, off, size) {return false}
		dst := ee_range(addr, size) or_return
		copy(dst, data[off:][:size])
		return true
	}
	return false
}

// n entries of size bytes at off lie within the file.
@(private = "file")
table_in :: proc(data: []u8, off, n, size: u32) -> bool {
	return u64(off) + u64(n) * u64(size) <= u64(len(data))
}

@(private = "file")
in_file :: proc(data: []u8, off, n: u32) -> bool {
	return u64(off) + u64(n) <= u64(len(data))
}

// The host bytes of EE main RAM [a, a+n), as the SIF DMA addresses it
// (physical), or false past its end or in the scratchpad.
@(private = "file")
ee_range :: proc(a, n: u32) -> ([]u8, bool) {
	p := u64(a & 0x0fffffff)
	if a >> 28 == 7 || p + u64(n) > mem.RAM_SIZE {return nil, false}
	return mem.ram[p:][:n], true
}

@(private = "file")
le32 :: proc(b: []u8, o: int) -> u32 {
	return endian.unchecked_get_u32le(b[o:])
}
