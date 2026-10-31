// IRX images: the IOP's relocatable modules. An IRX is a 32-bit
// little-endian MIPS ELF of type 0xff80. Its PT_SCE_IOPMOD segment holds the
// module info; one PT_LOAD at address 0 holds text and data, followed in
// memory by bss. SHT_REL sections relocate the loaded image to its base.
//
// The library tables (exports, and the imports with their call stubs) have
// no section or header of their own: as retail loadcore does, they are found
// by scanning the text for their magic words, and each match must also have
// a table's structure.
package ps2_iop

import "core:encoding/endian"
import mem "../mem"

IRX_TYPE :: 0xff80
PT_SCE_IOPMOD :: 0x70000080
IRX_IMPORT_MAGIC :: 0x41e00000
IRX_EXPORT_MAGIC :: 0x41c00000

Irx :: struct {
	name:                            string, // in the image's bytes
	version:                         u16,
	entry, gp:                       u32, // relative to the image's base
	text_size, data_size, bss_size: u32,
	file_off, file_size:             u32, // the PT_LOAD bytes in the file
}

// What `irx_relocate` refused, if anything.
Irx_Error :: enum u8 {
	None,
	Bounds, // a relocation or section outside the file or the image
	Type, // a relocation type no IRX should hold, returned as the detail
	Orphan_Hi16, // an R_MIPS_HI16 with no R_MIPS_LO16 after it
}

// A library table found in a module's text, at `off` from its base.
Irx_Table :: struct {
	off:     u32,
	imports: bool, // an import table, else an export table
	version: u16,
	name:    [8]u8,
	count:   u32, // stubs of an import, function pointers of an export
}

@(private = "file")
R_MIPS_NONE :: 0
@(private = "file")
R_MIPS_32 :: 2
@(private = "file")
R_MIPS_26 :: 4
@(private = "file")
R_MIPS_HI16 :: 5
@(private = "file")
R_MIPS_LO16 :: 6
@(private = "file")
R_MIPS_GPREL16 :: 7
@(private = "file")
SHT_REL :: 9
@(private = "file")
JR_RA :: 0x03e00008

// The module info of IRX file `data`, or false when it is no IRX or a header
// lies outside it.
irx_parse :: proc(data: []u8) -> (x: Irx, ok: bool) {
	h := mem.elf_header(data) or_return
	if h.class != 1 || h.encoding != 1 || h.type != IRX_TYPE || h.machine != 8 {return}
	if h.phentsize != 32 || h.phnum < 2 || !irx_in(data, h.phoff, 64) {return}
	iopmod, load := h.phoff, h.phoff + 32
	if irx_u32(data, iopmod) != PT_SCE_IOPMOD || irx_u32(data, load) != 1 {return}
	if irx_u32(data, load + 8) != 0 {return} // PT_LOAD at address 0
	info := irx_u32(data, iopmod + 4) // p_offset
	if !irx_in(data, info, 0x1b) {return}
	x = {
		entry     = irx_u32(data, info + 4),
		gp        = irx_u32(data, info + 8),
		text_size = irx_u32(data, info + 12),
		data_size = irx_u32(data, info + 16),
		bss_size  = irx_u32(data, info + 20),
		version   = u16(data[info + 24]) | u16(data[info + 25]) << 8,
		file_off  = irx_u32(data, load + 4),
		file_size = irx_u32(data, load + 16),
	}
	n := info + 26
	end := n
	for end < u32(len(data)) && data[end] != 0 {end += 1}
	x.name = string(data[n:end])
	if !irx_in(data, x.file_off, x.file_size) {return}
	if u64(x.file_size) > u64(x.text_size) + u64(x.data_size) {return}
	return x, true
}

// The bytes the module occupies in memory: text, data and bss.
irx_mem_size :: proc(x: Irx) -> u32 {
	return x.text_size + x.data_size + x.bss_size
}

// Applies every SHT_REL section of file `data` to `img`, the module's text
// and data already copied to `base` (bss zeroed). On an error `img` may be
// partly relocated; the caller frees it.
irx_relocate :: proc(data, img: []u8, base: u32) -> (err: Irx_Error, detail: u32) {
	h, _ := mem.elf_header(data)
	if h.shnum == 0 {return}
	if h.shentsize != 40 || !irx_in(data, h.shoff, h.shnum * 40) {return .Bounds, 0}
	for s in 0 ..< h.shnum {
		sh := h.shoff + s * 40
		if irx_u32(data, sh + 4) != SHT_REL {continue}
		off, size := irx_u32(data, sh + 16), irx_u32(data, sh + 20)
		if !irx_in(data, off, size) || size % 8 != 0 {return .Bounds, 0}
		err, detail = irx_rel_section(data[off:][:size], img, base)
		if err != .None {return}
	}
	return
}

@(private = "file")
irx_rel_section :: proc(rel, img: []u8, base: u32) -> (err: Irx_Error, detail: u32) {
	MAX_HI :: 64
	his: [MAX_HI]u32 // R_MIPS_HI16 offsets waiting for their R_MIPS_LO16
	nhi := 0
	for r := u32(0); r < u32(len(rel)); r += 8 {
		at, t := irx_u32(rel, r), irx_u32(rel, r + 4) & 0xff
		if t == R_MIPS_NONE || t == R_MIPS_GPREL16 {continue} // gp moves with the module
		if at % 4 != 0 || !irx_in(img, at, 4) {return .Bounds, at}
		w := irx_u32(img, at)
		switch t {
		case R_MIPS_32:
			w += base
		case R_MIPS_26:
			w = w & 0xfc000000 | ((w & 0x3ffffff) << 2 + base) >> 2 & 0x3ffffff
		case R_MIPS_HI16:
			if nhi == MAX_HI {return .Bounds, at}
			his[nhi] = at
			nhi += 1
			continue
		case R_MIPS_LO16:
			lo := u32(i32(i16(w & 0xffff)))
			for hi in his[:nhi] {
				hw := irx_u32(img, hi)
				ahl := (hw << 16) + lo + base
				endian.put_u32(img[hi:], .Little, hw & 0xffff0000 | (ahl + 0x8000) >> 16 & 0xffff)
			}
			nhi = 0
			w = w & 0xffff0000 | (lo + base) & 0xffff
		case:
			return .Type, t
		}
		endian.put_u32(img[at:], .Little, w)
	}
	if nhi != 0 {return .Orphan_Hi16, his[0]}
	return
}

// The library tables in `text`, the module's relocated text at `base`, in
// address order, allocated with `allocator`. A magic word counts only at a
// word boundary and with a table's structure, all inside the text: no next
// link (loadcore fills it), a major version of 1..15, a name of printable
// characters padded with NULs, and then for an import `jr ra; addiu zero,
// zero, fno` stub pairs ending in a zero pair, for an export pointers into
// the text ending in 0.
irx_tables :: proc(text: []u8, base: u32, allocator := context.allocator) -> [dynamic]Irx_Table {
	out := make([dynamic]Irx_Table, allocator)
	n := u32(len(text)) &~ 3
	for o := u32(0); o + 20 <= n; o += 4 {
		magic := irx_u32(text, o)
		if magic != IRX_IMPORT_MAGIC && magic != IRX_EXPORT_MAGIC {continue}
		t := Irx_Table{off = o, imports = magic == IRX_IMPORT_MAGIC}
		t.version = u16(irx_u32(text, o + 8))
		copy(t.name[:], text[o + 12:][:8])
		if irx_u32(text, o + 4) != 0 || t.version >> 8 == 0 || t.version >> 8 > 15 {continue}
		if !irx_name_ok(t.name) {continue}
		count, ok := irx_entries(text, base, o + 20, t.imports)
		if !ok {continue}
		t.count = count
		append(&out, t)
	}
	return out
}

@(private = "file")
irx_name_ok :: proc(name: [8]u8) -> bool {
	if name[0] == 0 {return false}
	nul := false
	for c in name {
		if c == 0 {nul = true; continue}
		if nul || c < 0x20 || c > 0x7e {return false}
	}
	return true
}

@(private = "file")
irx_entries :: proc(text: []u8, base: u32, o: u32, imports: bool) -> (count: u32, ok: bool) {
	n := u32(len(text)) &~ 3
	if imports {
		for p := o; p + 8 <= n; p += 8 {
			a, b := irx_u32(text, p), irx_u32(text, p + 4)
			if a == 0 && b == 0 {return count, true}
			if a != JR_RA || b >> 16 != 0x2400 {return}
			count += 1
		}
		return
	}
	for p := o; p + 4 <= n; p += 4 {
		f := irx_u32(text, p)
		if f == 0 {return count, true}
		if f < base || f - base >= u32(len(text)) {return}
		count += 1
	}
	return
}

@(private = "file")
irx_u32 :: proc(b: []u8, o: u32) -> u32 {
	v, _ := endian.get_u32(b[o:], .Little)
	return v
}

@(private = "file")
irx_in :: proc(b: []u8, off, n: u32) -> bool {
	return u64(off) + u64(n) <= u64(len(b))
}
