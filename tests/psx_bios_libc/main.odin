// psx_libc, the BIOS A table's C library, on hand cases in guest RAM that
// pin the retail kernel's behaviour, bugs included: NULL arguments, n = 0 and
// negative lengths, memmove and memcmp, bytes at and above 0x80, strtol's
// prefixes, signs and end pointer, qsort's order of equal elements and
// bsearch's misses through a guest comparison function (a host proc in the
// dispatch table at CMP) that must leave the caller's registers alone, and
// the InitHeap heap's headers, next fit, growth and realloc in place.
package main

import "core:fmt"
import "core:os"
import cpu "ps:psx/cpu"
import libc "ps:psx/bios/libc"

@(private = "file")
fail :: proc(what: string, got, want: u32) -> ! {
	fmt.eprintfln("FAIL psx_bios_libc: %s = %#x, want %#x", what, got, want)
	os.exit(1)
}

@(private = "file")
check :: proc(what: string, got, want: u32) {
	if got != want {
		fail(what, got, want)
	}
}

@(private = "file")
put :: proc(addr: u32, s: string) -> u32 {
	for i in 0 ..< len(s) {
		cpu.w8(addr + u32(i), s[i])
	}
	cpu.w8(addr + u32(len(s)), 0)
	return addr
}

@(private = "file")
get :: proc(addr: u32) -> string {
	return cpu.mem_cstring(addr)
}

@(private = "file")
check_str :: proc(what: string, addr: u32, want: string) {
	if s := get(addr); s != want {
		fmt.eprintfln("FAIL psx_bios_libc: %s = %q, want %q", what, s, want)
		os.exit(1)
	}
}

CMP :: 0x80001000
A :: 0x80010000
B :: 0x80011000
HEAP :: 0x80100000

@(private = "file")
cmp_calls: int

// Signed word comparison; clobbers the argument registers as real code may.
@(private = "file")
cmp_words :: proc() {
	x, y := i32(cpu.r32(cpu.state.r[4])), i32(cpu.r32(cpu.state.r[5]))
	cpu.state.r[2] = u32(i32(x > y) - i32(x < y))
	cpu.state.r[4], cpu.state.r[5] = 0, 0
	cmp_calls += 1
}

NEG :: max(u32) // -1

// -v as the u32 the guest sees.
@(private = "file")
neg :: proc(v: u32) -> u32 {
	return -v
}

strings_test :: proc() {
	check("strlen", libc.strlen(put(A, "hello")), 5)
	check("strlen empty", libc.strlen(put(A, "")), 0)
	check("strlen NULL", libc.strlen(0), 0)

	check("strcmp equal", libc.strcmp(put(A, "abc"), put(B, "abc")), 0)
	check("strcmp less", libc.strcmp(put(A, "abc"), put(B, "abd")), NEG)
	check("strcmp more", libc.strcmp(put(A, "abd"), put(B, "abc")), 1)
	check("strcmp prefix", libc.strcmp(put(A, "ab"), put(B, "abc")), neg('c'))
	check("strcmp signed", libc.strcmp(put(A, "\x80"), put(B, "a")), neg(128 + 'a'))
	check("strcmp NULL NULL", libc.strcmp(0, 0), 0)
	check("strcmp NULL s", libc.strcmp(0, put(B, "a")), NEG)
	check("strcmp s NULL", libc.strcmp(put(A, "a"), 0), 1)
	check("strncmp n=0", libc.strncmp(put(A, "a"), put(B, "b"), 0), 0)
	check("strncmp n=2", libc.strncmp(put(A, "abc"), put(B, "abd"), 2), 0)
	check("strncmp n=3", libc.strncmp(put(A, "abc"), put(B, "abd"), 3), NEG)
	check("strncmp n<0", libc.strncmp(put(A, "a"), put(B, "b"), 0x80000000), 0)
	check("strncmp n<0 NULL", libc.strncmp(0, put(B, "b"), 0x80000000), NEG)

	put(A, "xxxxxxxx")
	check("strcpy ret", libc.strcpy(A, put(B, "hi")), A)
	check_str("strcpy", A, "hi")
	check("strcpy past NUL", u32(cpu.r8(A + 3)), 'x')
	check("strcpy NULL", libc.strcpy(A, 0), 0)
	check_str("strcpy NULL leaves dst", A, "hi")
	check("strcat ret", libc.strcat(put(A, "ab"), put(B, "cd")), A)
	check_str("strcat", A, "abcd")
	check("strcat NULL", libc.strcat(0, B), 0)

	check("toupper a", libc.toupper('a'), 'A')
	check("toupper {", libc.toupper('{'), '{')
	check("toupper 0xe1", libc.toupper(0xe1), 0xffffffe1)
	check("toupper 0x161", libc.toupper(0x161), 'A')
	check("tolower Z", libc.tolower('Z'), 'z')
	check("tolower @", libc.tolower('@'), '@')
	check("toupper 0xe2", libc.toupper(0xe2), 0xffffffc2)
	check("tolower 0xc1", libc.tolower(0xc1), 0xffffffe1)
	check("tolower 0xc2", libc.tolower(0xc2), 0xffffffc2)
	check("abs -5", libc.abs(neg(5)), 5)
	check("abs 7", libc.abs(7), 7)
	check("abs min", libc.abs(0x80000000), 0x80000000)

	E :: B + 0x100
	check("strtol -42", libc.strtol(put(A, " \t-42x"), E, 10), neg(42))
	check("strtol end", cpu.r32(E), A + 5)
	check("strtol 0x1F", libc.strtol(put(A, "0x1F"), E, 0), 31)
	check("strtol 0x1F end", cpu.r32(E), A + 4)
	check("strtol 017", libc.strtol(put(A, "017"), 0, 0), 17)
	check("strtol O17", libc.strtol(put(A, "O17"), 0, 10), 15)
	check("strtol 0b11 base 16", libc.strtol(put(A, "0b11"), 0, 16), 3)
	check("strtol 0x no digit", libc.strtol(put(A, "0xg"), E, 16), 0)
	check("strtol 0x no digit end", cpu.r32(E), A + 2)
	check("strtol zz", libc.strtol(put(A, "zz"), 0, 36), 35 * 36 + 35)
	check("strtol base 99", libc.strtol(put(A, "19a"), 0, 99), 19)
	check("strtol none", libc.strtol(put(A, "abc"), E, 10), 0)
	check("strtol none end", cpu.r32(E), A)
	check("strtol +7", libc.strtol(put(A, "+7"), E, 10), 0)
	check("strtol +7 end", cpu.r32(E), A)
	cpu.w32(E, 0x1234)
	check("strtol NULL", libc.strtol(0, E, 10), 0)
	check("strtol NULL end", cpu.r32(E), 0x1234)
	check("strtol high blanks", libc.strtol(put(A, "\x92\xfe7"), E, 10), 7)
	check("strtol high blanks end", cpu.r32(E), A + 3)
	check("strtol 0x80 not blank", libc.strtol(put(A, "\x807"), E, 10), 0)
	check("strtol 0x80 not blank end", cpu.r32(E), A)
	check("strtol --5", libc.strtol(put(A, "--5"), E, 10), 5)
	check("strtol ---5", libc.strtol(put(A, "---5"), E, 10), neg(5))
	cpu.w32(0, 0x5555)
	check("strtol endp NULL", libc.strtol(put(A, "12"), 0, 10), 12)
	check("strtol endp NULL writes 0", cpu.r32(0), A + 2)
	check("strtoul -5", libc.strtoul(put(A, "-5"), E, 10), 0)
	check("strtoul -5 end", cpu.r32(E), A)
	check("atoi", libc.atoi(put(A, "123 4")), 123)
	check("atoi 017", libc.atoi(put(A, "-017")), neg(15))
	check("atoi high blank", libc.atoi(put(A, "\xa3-7")), neg(7))
	check("atoi 0x1F", libc.atoi(put(A, "0x1F")), 31)
	check("atoi 0B101", libc.atoi(put(A, "0B101")), 5)
	check("atoi o17", libc.atoi(put(A, "o17")), 0)
	check("atoi --08", libc.atoi(put(A, "--08")), 0)
	check("atoi wraps", libc.atoi(put(A, "4294967297")), 1)
	check("atoi NULL", libc.atoi(0), 0)
}

memory_test :: proc() {
	put(A, "0123456789")
	check("memcpy n=0", libc.memcpy(A, B, 0), A)
	check_str("memcpy n=0 leaves dst", A, "0123456789")
	check("memcpy NULL", libc.memcpy(0, B, 4), 0)
	check("memmove up overlapping", libc.memmove(A + 2, A, 5), A + 2)
	check_str("memmove up overlapping copies len+1", A, "0101234589")
	put(A, "0123456789")
	check("memmove up apart", libc.memmove(A + 5, A, 3), A + 5)
	check_str("memmove up apart", A, "0123401289")
	put(A, "0123456789")
	check("memmove NULL", libc.memmove(0, A, 3), 0)
	check("memmove n=0", libc.memmove(A + 1, A, 0), A + 1)
	check_str("memmove n=0 leaves dst", A, "0123456789")
	put(A, "0123456789")
	check("memmove down", libc.memmove(A, A + 2, 5), A)
	check_str("memmove down", A, "2345656789")
	check("memset", libc.memset(A, '-', 3), A)
	check_str("memset", A, "---5656789")
	check("memset n=0", libc.memset(A, '-', 0), 0)
	check("memset NULL", libc.memset(0, '-', 3), 0)
	check("memset too long", libc.memset(A, '-', 0x80000000), 0)
	check_str("memset refusals leave dst", A, "---5656789")

	put(A, "\x01\x80\x05")
	put(B, "\x01\x7f\x03")
	check("memcmp the byte after", libc.memcmp(A, B, 2), 2)
	check("memcmp less", libc.memcmp(B, A, 2), neg(2))
	check("memcmp n=1", libc.memcmp(A, B, 1), 0)
	check("memcmp n=0", libc.memcmp(A, B, 0), 0)
	check("memcmp NULL", libc.memcmp(0, B, 2), 0)
	check("memcmp n<0", libc.memcmp(A, B, 0x80000000), 0)
	put(A, "a\x01\x90")
	put(B, "a\x02\x10")
	check("memcmp unsigned", libc.memcmp(A, B, 3), 0x80)

	put(A, "ab\x80cd")
	check("memchr", libc.memchr(A, 'c', 5), A + 3)
	check("memchr 0x80 as int 0x180", libc.memchr(A, 0x180, 5), A + 2)
	check("memchr past n", libc.memchr(A, 'd', 4), 0)
	check("memchr n=0", libc.memchr(A, 'a', 0), 0)
	check("memchr NULL", libc.memchr(0, 'a', 5), 0)
}

// Fills A with 8-byte elements, a key the comparison reads and a tag saying
// where the element started.
@(private = "file")
put_keyed :: proc(keys: []i32) {
	for k, i in keys {
		cpu.w32(A + u32(i) * 8, u32(k))
		cpu.w32(A + u32(i) * 8 + 4, u32(i))
	}
}

@(private = "file")
check_tags :: proc(what: string, want: []u32) {
	for w, i in want {
		check(fmt.tprintf("%s tag[%d]", what, i), cpu.r32(A + u32(i) * 8 + 4), w)
	}
}

sort_test :: proc() {
	cpu.register_funcs({{addr = CMP, fn = cmp_words}})
	vals := [?]i32{5, -3, 9, 0, 5, -3, 2147483647, -2147483648, 1}
	put_keyed(vals[:])
	check("malloc before InitHeap", libc.malloc(4), 0)
	libc.qsort(A, len(vals), 8, CMP) // no temporary, no sort
	check("qsort before InitHeap calls", u32(cmp_calls), 0)
	check("qsort before InitHeap sorts nothing", cpu.r32(A), 5)

	libc.init_heap(HEAP, 0x100)
	cpu.state.r[4], cpu.state.r[29], cpu.state.r[31] = 0x1234, 0x801fff00, 0x80005678
	libc.qsort(A, len(vals), 8, CMP)
	check("qsort keeps a0", cpu.state.r[4], 0x1234)
	check("qsort keeps sp", cpu.state.r[29], 0x801fff00)
	check("qsort keeps ra", cpu.state.r[31], 0x80005678)
	check("qsort calls", u32(cmp_calls), 19)
	want := [?]i32{-2147483648, -3, -3, 0, 1, 5, 5, 9, 2147483647}
	for w, i in want {
		check(fmt.tprintf("qsort[%d]", i), cpu.r32(A + u32(i) * 8), u32(w))
	}
	check_tags("qsort", {7, 5, 1, 3, 8, 4, 0, 2, 6}) // equal keys swap places
	check("qsort frees its temporary", cpu.r32(HEAP) & 1, 1)
	cmp_calls = 0
	libc.qsort(A, 1, 8, CMP)
	libc.qsort(A, 0, 8, CMP)
	check("qsort n<2 calls", u32(cmp_calls), 0)

	// The sorted keys again; bsearch narrows on the element at lo, so it
	// finds only keys it reaches by halving from the top.
	K :: B + 0x200
	found := [?]struct {
		key:  i32,
		elem: u32,
	}{{-2147483648, 0}, {5, 5}, {2147483647, 8}}
	for f in found {
		cpu.w32(K, u32(f.key))
		check(fmt.tprintf("bsearch %d", f.key), libc.bsearch(K, A, len(want), 8, CMP), A + f.elem * 8)
	}
	misses := [?]i32{-3, 0, 1, 9, 4}
	for k in misses {
		cpu.w32(K, u32(k))
		check(fmt.tprintf("bsearch misses %d", k), libc.bsearch(K, A, len(want), 8, CMP), 0)
	}
	cpu.w32(K, 5)
	check("bsearch n=0", libc.bsearch(K, A, 0, 8, CMP), 0)
	cpu.w32(K, 0x80000000)
	check("bsearch n=0 still compares", libc.bsearch(K, A, 0, 8, CMP), A)

	put_keyed({1, 1, 0, 1, 0, 1})
	libc.qsort(A, 6, 8, CMP)
	check_tags("qsort ties", {4, 2, 0, 3, 5, 1})
}

heap_test :: proc() {
	cpu.w32(HEAP, 0xaaaaaaaa)
	libc.init_heap(HEAP, 0x102)
	check("InitHeap clears the first header", cpu.r32(HEAP), 0)

	a := libc.malloc(10)
	check("malloc a", a, HEAP + 4)
	check("a header", cpu.r32(HEAP), 12)
	check("end marker after a", cpu.r32(HEAP + 16), 0xfffffffe)
	b := libc.malloc(1)
	check("malloc b", b, HEAP + 20)
	check("b header", cpu.r32(HEAP + 16), 4)
	c := libc.malloc(0)
	check("malloc c (0 bytes)", c, HEAP + 28)
	check("c header", cpu.r32(HEAP + 24), 0)
	check("malloc too big", libc.malloc(0x100), NEG)

	libc.free(a)
	check("free sets bit 0", cpu.r32(HEAP), 12 | 1)
	libc.free(0)
	d := libc.malloc(8) // splits a, leaving an empty free block
	check("malloc reuses a", d, a)
	check("split header", cpu.r32(HEAP), 8)
	check("empty free block", cpu.r32(HEAP + 12), 1)

	libc.free(d)
	libc.free(b)
	e := libc.malloc(16) // joins d, the empty block and b
	check("malloc joins", e, a)
	check("joined header", cpu.r32(HEAP), 16)
	check("joined rest", cpu.r32(HEAP + 20), 1)

	for i in u32(0) ..< 8 {
		cpu.w8(HEAP + 32 + i, 0xff) // where calloc's block lands
	}
	f := libc.calloc(2, 4)
	check("calloc", f, HEAP + 32)
	check("calloc header", cpu.r32(HEAP + 28), 8)
	check("calloc end marker", cpu.r32(HEAP + 40), 0xfffffffe)
	check("calloc zero lo", cpu.r32(f), 0)
	check("calloc zero hi", cpu.r32(f + 4), 0)
	check("calloc overflow", libc.calloc(0x10000, 0x10001), NEG)

	check("realloc same size", libc.realloc(f, 8), f)
	check("realloc shrinks in place", libc.realloc(f, 4), f)
	check("realloc shrunk header", cpu.r32(HEAP + 28), 4)
	check("realloc split", cpu.r32(HEAP + 36), 1)
	g := libc.realloc(0, 4)
	check("realloc NULL", g, HEAP + 40)
	check("realloc NULL header", cpu.r32(HEAP + 36), 4)
	check("realloc NULL rest", cpu.r32(HEAP + 44), 1)
	check("realloc NULL end marker", cpu.r32(HEAP + 48), 0xfffffffe)
	check("realloc 0", libc.realloc(g, 0), 0)
	check("realloc 0 frees", cpu.r32(HEAP + 36), 4 | 1)

	// Growing into a free block adds its size but not its header's.
	libc.init_heap(HEAP, 0x100)
	p1 := libc.malloc(4)
	p2 := libc.malloc(8)
	check("join p1", p1, HEAP + 4)
	check("join p2", p2, HEAP + 12)
	check("join p3", libc.malloc(4), HEAP + 24)
	libc.free(p2)
	check("realloc joins", libc.realloc(p1, 12), p1)
	check("realloc join loses a header", cpu.r32(HEAP), 12)

	// Growing at the end marker moves the marker but not malloc's cursor,
	// so the next new block's header lands in the grown block.
	libc.init_heap(HEAP, 0x100)
	q1 := libc.malloc(4)
	check("grow q1", q1, HEAP + 4)
	check("realloc grows at the end", libc.realloc(q1, 12), q1)
	check("grown header", cpu.r32(HEAP), 12)
	check("moved end marker", cpu.r32(HEAP + 16), 0xfffffffe)
	cpu.w32(HEAP + 8, 0x5a5a5a5a)
	check("malloc after grow", libc.malloc(4), HEAP + 20)
	check("stale cursor overwrites q1", cpu.r32(HEAP + 8), 4 | 1)

	// The room at the end is counted in words against a size in bytes.
	libc.init_heap(HEAP, 0x40)
	r1 := libc.malloc(4)
	check("room r1", r1, HEAP + 4)
	r2 := libc.realloc(r1, 0x20)
	check("realloc moves", r2, HEAP + 12)
	check("realloc frees old", cpu.r32(HEAP), 4 | 1)
	check("realloc too big", libc.realloc(r2, 0x100), NEG)
	check("realloc too big keeps old", cpu.r32(HEAP + 8), 0x20)

	libc.init_heap(HEAP + 1, 0x10)
	check("unaligned malloc", libc.malloc(4), HEAP + 5)
}

main :: proc() {
	strings_test()
	memory_test()
	sort_test()
	heap_test()
	fmt.println("ok psx_bios_libc: strings, memory, strtol, qsort/bsearch through guest calls, heap")
}
