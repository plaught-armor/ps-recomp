// ps2_mem.load_elf on hand-built ELFs: a good one (a segment with BSS, a
// non-load header, an empty PT_LOAD whose offset is past the file), then bad
// ones, each of which must return false and leave RAM as it was.
package main

import "core:fmt"
import "core:os"
import mem "ps:ps2/mem"

@(private = "file")
Phdr :: struct {
	type, off, vaddr, filesz, memsz: u32,
}

@(private = "file")
FILL :: 0xaa

@(private = "file")
put32 :: proc(b: []u8, o: int, v: u32) {
	b[o], b[o + 1], b[o + 2], b[o + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)
}

// An ELF header, its program headers at 52, then `payload`.
@(private = "file")
build_elf :: proc(entry: u32, phdrs: []Phdr, payload: []u8) -> []u8 {
	b := make([]u8, 52 + 32 * len(phdrs) + len(payload), context.temp_allocator)
	put32(b, 0, 0x464c457f)
	put32(b, 24, entry)
	put32(b, 28, 52)
	b[42] = 32
	b[44] = u8(len(phdrs))
	for ph, i in phdrs {
		p := 52 + 32 * i
		put32(b, p, ph.type)
		put32(b, p + 4, ph.off)
		put32(b, p + 8, ph.vaddr)
		put32(b, p + 16, ph.filesz)
		put32(b, p + 20, ph.memsz)
	}
	copy(b[52 + 32 * len(phdrs):], payload)
	return b
}

@(private = "file")
fail :: proc(what: string) -> ! {
	fmt.eprintln("FAIL load_elf:", what)
	os.exit(1)
}

test_load_elf :: proc() {
	mem.ram = make([]u8, mem.RAM_SIZE)
	defer delete(mem.ram)
	for &b in mem.ram[0x100000:][:32] {b = FILL}
	payload := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	off := u32(52 + 32 * 3)
	good := build_elf(0x00100008, {
		{1, off, 0x80100000, 8, 16}, // kseg0 alias of 0x100000, 8 bytes of BSS
		{4, 0, 0, 0, 0}, // PT_NOTE: skipped
		{1, 0xffffff, 0x3aa480, 0, 0}, // empty PT_LOAD
	}, payload)
	entry, ok := mem.load_elf(good)
	if !ok || entry != 0x00100008 {fail("good ELF")}
	got := mem.ram[0x100000:][:17]
	for i in 0 ..< 8 {if got[i] != payload[i] {fail("segment bytes")}}
	for i in 8 ..< 16 {if got[i] != 0 {fail("BSS not zeroed")}}
	if got[16] != FILL {fail("wrote past memsz")}

	for &b in mem.ram[0x100000:][:32] {b = FILL}
	// Two program headers put the payload at 116; the first segment is good,
	// so only the second can be the reason for a rejection.
	off = 52 + 32 * 2
	not_elf := build_elf(0, {{1, off, 0x100000, 8, 8}, {4, 0, 0, 0, 0}}, payload)
	not_elf[3] = 'G'
	bad := [?]struct {
		what: string,
		elf:  []u8,
	} {
		{"short file", good[:40]},
		{"bad magic", not_elf},
		{"phdrs past file", build_elf(0, {{4, 0, 0, 0, 0}, {1, off, 0x100000, 8, 8}}, payload)[:100]},
		{"segment past RAM", build_elf(0, {{1, off, 0x100000, 8, 8}, {1, off, mem.RAM_SIZE - 8, 0, 16}}, payload)},
		{"filesz > memsz", build_elf(0, {{1, off, 0x100000, 8, 8}, {1, off, 0x200000, 8, 4}}, payload)},
		{"data past file", build_elf(0, {{1, off, 0x100000, 8, 8}, {1, off, 0x200000, 16, 16}}, payload)},
		{"scratchpad overrun", build_elf(0, {{1, off, 0x100000, 8, 8}, {1, off, mem.SPR_BASE + mem.SPR_SIZE - 4, 8, 8}}, payload)},
	}
	for c in bad {
		if _, loaded := mem.load_elf(c.elf); loaded {fail(c.what)}
		for b in mem.ram[0x100000:][:32] {if b != FILL {fail(fmt.tprint(c.what, "wrote RAM"))}}
	}
	fmt.println("ok load_elf", len(bad), "bad ELFs rejected")
}
