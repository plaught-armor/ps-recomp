// The C library half of the BIOS A table: string, memory, number, sort and
// heap functions, on guest addresses. Pointers and results are guest words.
// Behaviour follows the retail kernel (checked against v4.5), its bugs
// included where a game could see them; the comments say where something
// differs. Kept apart from psx_bios so tests can use it without the host
// (SDL) side.
package psx_libc

import cpu "../../cpu"

// Lengths above this are negative to retail, which tests them signed.
@(private = "file")
LEN_MAX :: 0x7fffffff

// A(2Ah) memcpy: nothing when dst is NULL or len is not positive; returns dst.
memcpy :: proc(dst, src, n: u32) -> u32 {
	if dst == 0 || n > LEN_MAX {
		return dst
	}
	for i in u32(0) ..< n {
		cpu.w8(dst + i, cpu.r8(src + i))
	}
	return dst
}

// A(2Bh) memset, A(28h) bzero: returns dst, or 0 when nothing was filled.
memset :: proc(dst: u32, v: u8, n: u32) -> u32 {
	if dst == 0 || n == 0 || n > LEN_MAX {
		return 0
	}
	for i in u32(0) ..< n {
		cpu.w8(dst + i, v)
	}
	return dst
}

// A(2Ch) memmove. When src < dst < src+len the ranges overlap and it copies
// backwards, with retail's bug of moving len+1 bytes, [src+len..src] to
// [dst+len..dst]; otherwise it is memcpy.
memmove :: proc(dst, src, n: u32) -> u32 {
	if dst == 0 {
		return 0
	}
	if src < dst && dst < src + n {
		for i := i32(n); i >= 0; i -= 1 {
			cpu.w8(dst + u32(i), cpu.r8(src + u32(i)))
		}
		return dst
	}
	return memcpy(dst, src, n)
}

// A(2Dh) memcmp, A(29h) bcmp, with retail's bug: on a mismatch at N it
// returns [a+N+1]-[b+N+1], the bytes after it, read unsigned. 0 when equal,
// when either is NULL, or when len is not positive.
memcmp :: proc(a, b, n: u32) -> u32 {
	if a == 0 || b == 0 || n > LEN_MAX {
		return 0
	}
	for i in u32(0) ..< n {
		if cpu.r8(a + i) != cpu.r8(b + i) {
			return u32(i32(cpu.r8(a + i + 1)) - i32(cpu.r8(b + i + 1)))
		}
	}
	return 0
}

// A(2Eh) memchr: the address of the first byte equal to c, or 0.
memchr :: proc(s: u32, c: u32, n: u32) -> u32 {
	if s == 0 || n > LEN_MAX {
		return 0
	}
	for i in u32(0) ..< n {
		if cpu.r8(s + i) == u8(c) {
			return s + i
		}
	}
	return 0
}

// A(1Bh) strlen.
strlen :: proc(s: u32) -> u32 {
	if s == 0 {
		return 0
	}
	n: u32 = 0
	for cpu.r8(s + n) != 0 {
		n += 1
	}
	return n
}

// A(17h) strcmp.
strcmp :: proc(a, b: u32) -> u32 {
	return strncmp(a, b, LEN_MAX)
}

// A(18h) strncmp: the difference of the first unequal bytes, each
// sign-extended, or 0. A NULL string gives 0 when both are NULL, else -1 for
// a NULL a and 1 for a NULL b. n is signed: a negative n compares nothing.
strncmp :: proc(a, b: u32, n: u32) -> u32 {
	if a == 0 || b == 0 {
		return u32(i32(b == 0) - i32(a == 0))
	}
	if n > LEN_MAX {
		return 0
	}
	for i in u32(0) ..< n {
		x, y := cpu.r8(a + i), cpu.r8(b + i)
		if x != y {
			return u32(i32(i8(x)) - i32(i8(y)))
		}
		if x == 0 {
			break
		}
	}
	return 0
}

// A(19h) strcpy: 0 when either is NULL.
strcpy :: proc(dst, src: u32) -> u32 {
	if dst == 0 || src == 0 {
		return 0
	}
	for i: u32 = 0; ; i += 1 {
		c := cpu.r8(src + i)
		cpu.w8(dst + i, c)
		if c == 0 {
			break
		}
	}
	return dst
}

// A(15h) strcat: 0 when either is NULL.
strcat :: proc(dst, src: u32) -> u32 {
	if dst == 0 || src == 0 {
		return 0
	}
	strcpy(dst + strlen(dst), src)
	return dst
}

// Retail's character table has entries for 00h-7Fh only; bytes from 80h up
// index past it into whatever ROM data follows, so some of them count as
// blanks or letters. These are the bytes that do, on the v4.5 kernel.
@(private = "file")
High :: bit_set[0x80 ..= 0xff;u128]
@(private = "file")
HIGH_BLANK :: High{0x92, 0x9f, 0xa3, 0xa4, 0xa7, 0xa9, 0xab, 0xac, 0xb0, 0xb4, 0xbc, 0xc0, 0xc1, 0xc5, 0xc6, 0xcb, 0xcc, 0xcf, 0xd0, 0xd3, 0xd4, 0xd8, 0xd9, 0xdd, 0xe0, 0xe2, 0xe4, 0xe6, 0xea, 0xee, 0xef, 0xf2, 0xf6, 0xfa, 0xfe}
@(private = "file")
HIGH_LOWER :: High{0x92, 0x9f, 0xa3, 0xa4, 0xaa, 0xb0, 0xb6, 0xbf, 0xc0, 0xc1, 0xc4, 0xca, 0xcb, 0xcc, 0xcf, 0xd0, 0xd2, 0xd3, 0xd4, 0xd7, 0xdd, 0xe2, 0xe6, 0xea, 0xee, 0xf2, 0xf6, 0xfa, 0xfb, 0xfe}
@(private = "file")
HIGH_UPPER :: High{0x92, 0x9f, 0xa0, 0xa4, 0xa6, 0xa8, 0xa9, 0xab, 0xad, 0xaf, 0xb3, 0xb5, 0xb6, 0xb7, 0xb9, 0xbd, 0xc0, 0xc1, 0xc5, 0xc7, 0xc9, 0xca, 0xd0, 0xd3, 0xd4, 0xd8, 0xda, 0xdc, 0xe2, 0xe6, 0xea, 0xee, 0xf2, 0xf6, 0xfa, 0xfb, 0xfd, 0xfe}

@(private = "file")
is_blank :: proc(c: u8) -> bool {
	return c >= 0x80 ? int(c) in HIGH_BLANK : c == ' ' || (c >= '\t' && c <= '\r')
}

// A(25h) toupper, A(26h) tolower: the low byte, its case changed when the
// character table calls it a letter (bytes from 80h up included), and
// sign-extended as retail returns it.
toupper :: proc(c: u32) -> u32 {
	b := u8(c)
	if b >= 0x80 ? int(b) in HIGH_LOWER : b >= 'a' && b <= 'z' {
		b -= 0x20
	}
	return u32(i32(i8(b)))
}

tolower :: proc(c: u32) -> u32 {
	b := u8(c)
	if b >= 0x80 ? int(b) in HIGH_UPPER : b >= 'A' && b <= 'Z' {
		b += 0x20
	}
	return u32(i32(i8(b)))
}

// A(0Eh) abs, A(0Fh) labs.
abs :: proc(v: u32) -> u32 {
	return i32(v) < 0 ? -v : v
}

// A(0Dh) strtol. Like retail it stores the end address through endp even
// when endp is NULL, which writes guest address 0, plain RAM on hardware.
strtol :: proc(s, endp, base: u32) -> u32 {
	if s == 0 {
		return 0
	}
	v, end := parse(s, base, true, false)
	cpu.w32(endp, end)
	return v
}

// A(0Ch) strtoul: strtol without the sign.
strtoul :: proc(s, endp, base: u32) -> u32 {
	if s == 0 {
		return 0
	}
	v, end := parse(s, base, false, false)
	cpu.w32(endp, end)
	return v
}

// A(10h) atoi, A(11h) atol: base 10, a "0x" or "0b" prefix, and any other
// leading 0 means octal.
atoi :: proc(s: u32) -> u32 {
	if s == 0 {
		return 0
	}
	v, _ := parse(s, 10, true, true)
	return v
}

// Retail's number parser: blanks (09h-0Dh, 20h and some bytes from 80h up),
// then when signed any run of
// "-", each one flipping the sign (no "+"). A "0" is skipped, and a "b" or
// "x" after it (either case) picks base 2 or 16 whatever the base was, so
// base 16 reads "0b11" as binary; atoi takes base 8 after any other "0", the
// strto* functions take it after a leading "o". Then digits while below the
// base, with no overflow check. A base outside 2..36 means 10. Returns the
// value and the address where parsing stopped.
@(private = "file")
parse :: proc(s, base: u32, signed, atoi: bool) -> (u32, u32) {
	base := base if base >= 2 && base <= 36 else 10
	p := s
	for is_blank(cpu.r8(p)) {
		p += 1
	}
	neg := false
	for signed && cpu.r8(p) == '-' {
		neg = !neg
		p += 1
	}
	switch c := cpu.r8(p); {
	case c == '0':
		p += 1
		switch cpu.r8(p) | 0x20 {
		case 'b':
			base = 2
			p += 1
		case 'x':
			base = 16
			p += 1
		case:
			if atoi {
				base = 8
			}
		}
	case !atoi && c | 0x20 == 'o':
		base = 8
		p += 1
	}
	v: u32 = 0
	for d := digit(cpu.r8(p)); d < base; d = digit(cpu.r8(p)) {
		v = v * base + d
		p += 1
	}
	return neg ? -v : v, p
}

@(private = "file")
digit :: proc(c: u8) -> u32 {
	switch c {
	case '0' ..= '9':
		return u32(c - '0')
	case 'a' ..= 'z':
		return u32(c - 'a') + 10
	case 'A' ..= 'Z':
		return u32(c - 'A') + 10
	}
	return 99
}

// Call the guest comparison function cmp(a, b) and return its result,
// leaving the caller's registers as they were.
@(private = "file")
guest_cmp :: proc(cmp, a, b: u32) -> i32 {
	saved := cpu.state
	cpu.state.r[4] = a
	cpu.state.r[5] = b
	cpu.call(cmp)
	v := i32(cpu.state.r[2])
	cycles := cpu.state.cycles
	cpu.state = saved
	cpu.state.cycles = cycles
	return v
}

// A(31h) qsort: retail's quicksort, so equal elements end in the same order
// as on hardware. It swaps through a temporary of one element taken with
// malloc, and sorts nothing when that fails. Each range moves its middle
// element to the end as the pivot, partitions with cmp(element, pivot), puts
// the pivot in place, sorts the left part and then the right.
qsort :: proc(base, n, size, cmp: u32) {
	tmp := malloc(size)
	if failed(tmp) {
		return
	}
	qsort_range(base, size, cmp, tmp, 0, i32(n) - 1)
	free(tmp)
}

@(private = "file")
qsort_range :: proc(base, size, cmp, tmp: u32, lo, hi: i32) {
	at :: proc(base, size: u32, i: i32) -> u32 {return base + u32(i) * size}
	swap :: proc(a, b, size, tmp: u32) {
		memcpy(tmp, a, size)
		memcpy(a, b, size)
		memcpy(b, tmp, size)
	}
	lo := lo
	for lo < hi {
		pivot := at(base, size, hi)
		swap(at(base, size, (lo + hi) / 2), pivot, size, tmp)
		i, j := lo - 1, hi
		for i < j {
			for {
				i += 1
				if guest_cmp(cmp, at(base, size, i), pivot) >= 0 || i >= j {
					break
				}
			}
			for {
				j -= 1
				if i >= j || guest_cmp(cmp, at(base, size, j), pivot) <= 0 {
					break
				}
			}
			if i < j {
				swap(at(base, size, i), at(base, size, j), size, tmp)
			}
		}
		swap(pivot, at(base, size, i), size, tmp)
		qsort_range(base, size, cmp, tmp, lo, i - 1)
		lo = i + 1
	}
}

// A(36h) bsearch, with retail's bugs: it calls cmp(element, key), the
// reverse of C, and narrows on the element at lo instead of the middle one,
// so it misses most keys past the first element. It ends by comparing the
// element at lo, even when n is 0: its address on a match, else 0.
bsearch :: proc(key, base, n, size, cmp: u32) -> u32 {
	lo, hi := i32(0), i32(n)
	for lo < hi {
		mid := (lo + hi) / 2
		if guest_cmp(cmp, base + u32(lo) * size, key) >= 0 {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	e := base + u32(lo) * size
	return e if guest_cmp(cmp, e, key) == 0 else 0
}

// ---------------------------------------------------------------- heap

// The user heap of A(39h) InitHeap, in guest RAM, laid out as retail lays
// it: blocks one after another, each a header word holding its data size (a
// multiple of 4) with bit 0 set while free, and an end marker word of
// END_MARK after the last. The heap starts empty and grows from cursor as
// malloc needs room. malloc is next fit: it goes on from the block it last
// stopped at (rover), joins free neighbours as it walks, splits off the rest
// of a block that is too big, and goes round from the first block once more
// before it grows the heap. The state below is the kernel's, kept host side.
@(private = "file")
END_MARK :: 0xfffffffe

@(private = "file")
heap: struct {
	cursor, size, end: u32, // the next end marker goes at cursor-4
	first, rover:      u32,
	ready:             bool, // the first malloc lays out the first block
}

// malloc's two failure results: 0, and -1 when growing fails at the end of
// its second round (retail's bug).
@(private = "file")
failed :: proc(p: u32) -> bool {
	return p == 0 || p == max(u32)
}

// Retail rounds some offsets by signed division, toward zero.
@(private = "file")
words :: proc(v: u32) -> u32 {
	return u32(i32(v) / 4 * 4)
}

// A(39h) InitHeap: no alignment; writes 0 at addr. Again, it frees every
// block.
init_heap :: proc(addr, size: u32) {
	cpu.w32(addr, 0)
	heap.cursor = addr
	heap.end = addr + size &~ 3 + 4
	heap.size = size
	heap.ready = false
}

// Turn the end marker into a free block of n bytes and put a new marker after
// it. Retail takes the larger of n and the InitHeap size when that fits, else
// the smaller, so in practice n.
@(private = "file")
grow :: proc(n: u32) -> bool {
	t: u32 = 0
	if n == 0 {
		if heap.cursor >= heap.end {
			return false
		}
	} else {
		room := (heap.end - heap.cursor) &~ 3 - 4
		switch {
		case room >= max(n, heap.size):
			t = max(n, heap.size)
		case room >= min(n, heap.size):
			t = min(n, heap.size)
		case:
			return false
		}
	}
	cpu.w32(heap.cursor + words(t), END_MARK)
	cpu.w32(heap.cursor - 4, t | 1)
	heap.cursor += words(t + 4)
	return true
}

// A(33h) malloc: size rounded up to 4. 0 when the heap is full, or -1 when it
// fills on growing after the second round. Retail spins forever on a heap
// whose headers the game overwrote into a loop; this stops as fatal after
// as many steps as RAM has words, as no sound heap takes that many.
malloc :: proc(size: u32) -> u32 {
	n := (size + 3) &~ 3
	if !heap.ready {
		if heap.cursor >= heap.end {
			return 0
		}
		cpu.w32(heap.cursor, END_MARK)
		heap.rover = heap.cursor
		heap.cursor += 4
		if !grow(n) {
			return 0
		}
		heap.first = heap.rover
		heap.ready = true
	}
	rounds := 2
	for _ in 0 ..< cpu.RAM_SIZE / 4 {
		p := heap.rover
		h := cpu.r32(p)
		next := p + h &~ 3 + 4
		if h & 1 == 0 {
			if h != END_MARK {
				heap.rover = next
				continue
			}
			rounds -= 1
			if rounds > 0 {
				heap.rover = heap.first
			} else if !grow(n) {
				return max(u32)
			}
			continue
		}
		switch {
		case h == n | 1:
			cpu.w32(p, n)
			return p + 4
		case h > n | 1:
			cpu.w32(p + words(n) + 4, h - n - 4)
			cpu.w32(p, n)
			return p + 4
		}
		switch nh := cpu.r32(next); {
		case nh == END_MARK:
			rounds -= 1
			if rounds > 0 {
				heap.rover = heap.first
			} else if !grow(n) {
				return 0
			}
		case nh & 1 != 0:
			cpu.w32(p, h + nh &~ 1 + 4)
		case:
			heap.rover = next
		}
	}
	cpu.fatal("BIOS heap at %#08x is corrupt, malloc found no end marker (ra %#08x)", heap.first, cpu.state.r[31])
}

// A(34h) free: sets bit 0 of the word before ptr, for any ptr. Retail does
// that for NULL too, at FFFFFFFCh; this ignores ptr below 4 rather than wrap
// the write into the top of RAM.
free :: proc(ptr: u32) {
	if ptr >= 4 {
		cpu.w32(ptr - 4, cpu.r32(ptr - 4) | 1)
	}
}

// A(37h) calloc: malloc(n*size), the product wrapping at 32 bits as on
// retail, zero-filled. Retail also fills at malloc's -1; this returns it.
calloc :: proc(n, size: u32) -> u32 {
	p := malloc(n * size)
	if !failed(p) {
		memset(p, 0, n * size)
	}
	return p
}

// A(38h) realloc: malloc when ptr is NULL, free when size is 0 (retail then
// returns a stale stack word; this returns 0). Otherwise it resizes the block
// in place when it can; if not, it takes a new block, copies size bytes
// whatever the old size was and frees the old one. When malloc fails the old
// block stays; at malloc's -1 retail still copies and frees, this returns -1.
realloc :: proc(ptr, size: u32) -> u32 {
	if ptr == 0 {
		return malloc(size)
	}
	if size == 0 {
		free(ptr)
		return 0
	}
	if p := resize(ptr, size); p != 0 {
		return p
	}
	p := malloc(size)
	if failed(p) {
		return p
	}
	memcpy(p, ptr, size)
	free(ptr)
	return p
}

// realloc's in-place step, with retail's bugs: to grow a block it joins the
// free blocks after it but adds only their data sizes, dropping 4 bytes per
// header; at the end marker it carves the missing bytes from the room left,
// checking that room in words against bytes, writing the new marker over the
// last data word and leaving the heap cursor where it was. A block with room
// to spare is split. Returns ptr, or 0 when the block is still too small.
@(private = "file")
resize :: proc(ptr, size: u32) -> u32 {
	n := (size + 3) &~ 3
	hdr := ptr - 4
	h := cpu.r32(hdr)
	if h == END_MARK {
		return 0
	}
	have := h &~ 1
	for q := hdr; have < n; {
		q += cpu.r32(q) &~ 3 + 4
		qh := cpu.r32(q)
		if qh == END_MARK {
			more := n - have
			if u32(i32(heap.end - q) >> 2) - 4 < more {
				break
			}
			cpu.w32(q + more &~ 3, END_MARK)
			qh = more | 1
			cpu.w32(q, qh)
		} else if qh & 1 == 0 {
			break
		}
		cpu.w32(hdr, cpu.r32(hdr) + qh &~ 1)
		have += qh &~ 1
	}
	h = cpu.r32(hdr)
	if n < h &~ 3 {
		cpu.w32(hdr + words(n) + 4, (h &~ 1 - n - 4) | 1)
		cpu.w32(hdr, n | h & 1)
		return ptr
	}
	return 0 if h &~ 1 < n else ptr
}
