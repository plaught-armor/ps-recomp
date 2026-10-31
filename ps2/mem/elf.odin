// The game's ELF into RAM: each PT_LOAD segment copied to its address, the
// part past its file bytes zeroed (the BSS). Only program headers count:
// some games' ELFs have no named sections. Every header field is checked
// against the file and against RAM (or the scratchpad) before anything is
// written, so a bad ELF leaves memory untouched and returns false.
package ps2_mem

@(private = "file")
ELF_MAGIC :: 0x464c457f // "\x7fELF"

@(private = "file")
PT_LOAD :: 1

// The ELF header fields the loaders read (this one and the IOP's loadelf).
Elf_Header :: struct {
	class, encoding:            u8, // e_ident: 1 = 32-bit, 1 = little-endian
	type, machine:              u32,
	entry, phoff, shoff:        u32,
	ehsize, phentsize, phnum:   u32,
	shentsize, shnum, shstrndx: u32,
}

// The header of `data`, or false when it is shorter than one or no ELF.
// Nothing else is checked: each loader checks what it relies on.
elf_header :: proc(data: []u8) -> (h: Elf_Header, ok: bool) {
	if len(data) < 52 || le32(data, 0) != ELF_MAGIC {return}
	h = {
		class     = data[4],
		encoding  = data[5],
		type      = le16(data, 16),
		machine   = le16(data, 18),
		entry     = le32(data, 24),
		phoff     = le32(data, 28),
		shoff     = le32(data, 32),
		ehsize    = le16(data, 40),
		phentsize = le16(data, 42),
		phnum     = le16(data, 44),
		shentsize = le16(data, 46),
		shnum     = le16(data, 48),
		shstrndx  = le16(data, 50),
	}
	return h, true
}

// Load `data` into RAM; mem_init must have run. Returns the entry point.
load_elf :: proc(data: []u8) -> (entry: u32, ok: bool) {
	Segment :: struct {
		dst:          []u8,
		off, filesz: u32,
	}
	h := elf_header(data) or_return
	phoff, phentsize, phnum := u64(h.phoff), u64(h.phentsize), u64(h.phnum)
	if phnum > 0 && (phentsize < 24 || phoff + phnum * phentsize > u64(len(data))) {return}
	segs := make([dynamic]Segment, 0, phnum, context.temp_allocator)
	for i in 0 ..< phnum {
		p := int(phoff + i * phentsize)
		if le32(data, p) != PT_LOAD {continue}
		off, vaddr := le32(data, p + 4), le32(data, p + 8)
		filesz, memsz := le32(data, p + 16), le32(data, p + 20)
		if filesz > memsz || u64(off) + u64(filesz) > u64(len(data)) {
			// An empty segment (filesz 0) copies nothing; its offset is moot.
			if filesz != 0 {return}
			off = 0
		}
		dst := guest_range(vaddr, memsz) or_return
		append(&segs, Segment{dst, off, filesz})
	}
	for s in segs {
		copy(s.dst, data[s.off:][:s.filesz])
		for &b in s.dst[s.filesz:] {b = 0}
	}
	return h.entry, true
}

// The host bytes of guest [a, a+n) in RAM or the scratchpad, as ram_slice
// maps them, or false when the range runs off the end.
@(private = "file")
guest_range :: proc(a, n: u32) -> ([]u8, bool) {
	if a >> 28 == 7 {
		if a - SPR_BASE >= SPR_SIZE || u64(a - SPR_BASE) + u64(n) > SPR_SIZE {return nil, false}
		return spr[a - SPR_BASE:][:n], true
	}
	p := a & 0x0fffffff
	if u64(p) + u64(n) > RAM_SIZE {return nil, false}
	return ram[p:][:n], true
}

@(private = "file")
le32 :: proc(b: []u8, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

@(private = "file")
le16 :: proc(b: []u8, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8
}
