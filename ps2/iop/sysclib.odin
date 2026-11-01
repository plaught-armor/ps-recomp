// stdio and sysclib: the C library IOP modules import from the kernel.
// Numbers as the PS2SDK's export tables order them.
package ps2_iop

import "core:fmt"
import "core:strings"
import "ps:core"
import cpu "../cpu"
import r3000 "ps:psx/cpu"

// `n` bytes of IOP RAM from `a`, fewer where RAM ends.
@(private = "file")
ram :: proc(a, n: u32) -> []u8 {
	w := a & (IOP_RAM_SIZE - 1)
	return iop_ram[w:][:min(n, IOP_RAM_SIZE - w)]
}

// The NUL-terminated string at `a`, cut where RAM ends.
@(private)
cstr :: proc(a: u32) -> string {
	return strings.truncate_to_byte(string(ram(a, IOP_RAM_SIZE)), 0)
}

// Function fno of stdio, reading a0..a3; v0, or false when the HLE lacks it.
// What a module prints shows under PS_DEBUG.
stdio_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	switch fno {
	case 4: // printf(format, ...)
		s, n := iop_format(cstr(r3000.state.r[4]))
		if cpu.debug >= 1 {fmt.eprint("iop printf: ", s, sep = "")}
		return n, true
	case 7: // puts(s)
		if cpu.debug >= 1 {fmt.eprintln("iop puts:", cstr(r3000.state.r[4]))}
		return 0, true
	}
	return 0, false
}

// printf's output for `format`, its arguments from register a<first> on:
// up to a3, then the caller's stack past the argument registers' home. As
// the formatter of sysclib 1.4, which discs carry in their IOPRP:
// conversions d i u o x X p c s n, D O U as ld lo lu, flags # 0 - + and
// space, a width and a precision, each a number or * (an argument), and the
// size letters h l L, which it ignores. Precision zeros count the sign and
// 0x prefix as digits; 0 pads %s and %c too; %p has no prefix, # or not. Any
// other character after the flags is printed as itself, %% so too.
// Widths and precisions are 32-bit as the kernel's: a run of digits wraps,
// a negative precision is none, a negative width from digits pads nothing.
// Output past IOP_RAM_SIZE characters, more than any buffer in IOP RAM
// holds, is counted and not kept: `n` is the count the kernel returns, its
// 32 bits wrapping as its counter does. `out` holds until the next call.
iop_format :: proc(format: string, first := 1) -> (out: string, n: u32) {
	o := Fmt_Out{b = strings.builder_from_bytes(fmt_buf[:])}
	arg := first
	next :: proc(arg: ^int) -> u32 {
		r := &r3000.state.r
		i := arg^
		arg^ += 1
		return r[4 + i] if i < 4 else r32(r[29] + 4 * u32(i))
	}
	for i := 0; i < len(format); i += 1 {
		if format[i] != '%' {
			fmt_put(&o, format[i])
			continue
		}
		left, zero, alt: bool
		sign: u8
		width, prec: i32 = 0, -1
		i += 1
		flags: for ; i < len(format); i += 1 {
			switch format[i] {
			case '-': left = true
			case '0': zero = true
			case '+': sign = '+'
			case ' ': if sign == 0 {sign = ' '}
			case '#': alt = true
			case 'h', 'l', 'L':
			case '*':
				width = i32(next(&arg))
				if width < 0 {width, left = -width, true}
			case '1' ..= '9':
				width = 0
				for ; i < len(format) && format[i] >= '0' && format[i] <= '9'; i += 1 {width = width * 10 + i32(format[i] - '0')}
				i -= 1
			case '.':
				i += 1
				if i < len(format) && format[i] == '*' {
					prec = max(i32(next(&arg)), -1)
					continue
				}
				prec = 0
				for ; i < len(format) && format[i] >= '0' && format[i] <= '9'; i += 1 {prec = prec * 10 + i32(format[i] - '0')}
				prec = max(prec, -1)
				i -= 1
			case: break flags
			}
		}
		if i >= len(format) {break}
		body: string
		prefix := ""
		dprec := -1 // a number's precision
		switch c := format[i]; c {
		case 'd', 'i', 'D', 'u', 'U', 'o', 'O', 'x', 'X', 'p':
			v := next(&arg)
			base: u32 = 16
			switch c {
			case 'd', 'i', 'D':
				base = 10
				if i32(v) < 0 {v, sign = -v, '-'}
			case 'u', 'U': base, sign = 10, 0
			case 'o', 'O': base, sign = 8, 0
			case: sign = 0
			}
			if prec >= 0 {dprec, zero = int(prec), false}
			digits := "0123456789ABCDEF" if c == 'X' else "0123456789abcdef"
			buf: [12]u8
			n := len(buf)
			for x := v; x != 0 || (n == len(buf) && dprec != 0); x /= base {
				n -= 1
				buf[n] = digits[x % base]
			}
			if alt && base == 8 && n < len(buf) && buf[n] != '0' {
				n -= 1
				buf[n] = '0'
			}
			if alt && (c == 'x' || c == 'X') && v != 0 {prefix = "0x" if c == 'x' else "0X"}
			body = strings.clone(string(buf[n:]), context.temp_allocator)
		case 'c':
			sign = 0
			body = strings.clone(string([]u8{u8(next(&arg))}), context.temp_allocator)
		case 's':
			sign = 0
			p := next(&arg)
			body = "(null)" if p == 0 else cstr(p)
			if prec >= 0 && int(prec) < len(body) {body = body[:prec]}
		case 'n':
			w := o.n
			copy(ram(next(&arg), 4), ([^]u8)(&w)[:4])
			continue
		case:
			fmt_put(&o, c)
			continue
		}
		size := len(body) + len(prefix) + (sign != 0 ? 1 : 0)
		real := max(size, dprec)
		if !left && !zero {fmt_put(&o, ' ', int(width) - real)}
		if sign != 0 {fmt_put(&o, sign)}
		fmt_str(&o, prefix)
		if !left && zero {fmt_put(&o, '0', int(width) - real)}
		fmt_put(&o, '0', dprec - size)
		fmt_str(&o, body)
		if left {fmt_put(&o, ' ', int(width) - real)}
	}
	return strings.to_string(o.b), o.n
}

// iop_format's output: what it keeps, in fmt_buf, and the count of all it
// wrote.
@(private = "file")
Fmt_Out :: struct {
	b: strings.Builder,
	n: u32,
}

@(private = "file")
fmt_buf: [IOP_RAM_SIZE]u8

// `k` of char `c` to `o` (none for k <= 0), kept while fmt_buf has room.
@(private = "file")
fmt_put :: proc(o: ^Fmt_Out, c: u8, k := 1) {
	if k <= 0 {return}
	o.n += u32(k)
	keep := min(k, IOP_RAM_SIZE - len(o.b.buf))
	for _ in 0 ..< keep {strings.write_byte(&o.b, c)}
}

@(private = "file")
fmt_str :: proc(o: ^Fmt_Out, s: string) {
	o.n += u32(len(s))
	strings.write_string(&o.b, s[:min(len(s), IOP_RAM_SIZE - len(o.b.buf))])
}

// Function fno of sysclib, as stdio_fn.
sysclib_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2 := r[4], r[5], r[6]
	switch fno {
	case 8: // look_ctype_table(c): its class bits
		// Past -1..158 the kernel reads its own code and data: a row, and 0.
		c := i32(a0)
		if c < -1 || c > 158 {core.compat_unknown(.Iop_Call, core.compat_name("sysclib"), fno, pc = r[31])}
		return u32(ctype(c)), true
	case 11: // memcmp(a, b, n): -1, 0 or 1 by the first unequal byte; n <= 0 compares none
		n := u32(max(i32(a2), 0))
		x, y := ram(a0, n), ram(a1, n)
		for i in 0 ..< min(len(x), len(y)) {
			if x[i] != y[i] {return x[i] < y[i] ? ke(-1) : 1, true}
		}
		return 0, true
	case 12: // memcpy(dst, src, n)
		src := ram(a1, a2)
		copy(ram(a0, u32(len(src))), src)
		return a0, true
	case 14: // memset(dst, c, n)
		for &b in ram(a0, a2) {b = u8(a1)}
		return a0, true
	case 17: // bzero(p, n)
		for &b in ram(a0, u32(max(i32(a1), 0))) {b = 0}
		return 0, true
	case 19: // sprintf(buf, format, ...): the characters it wrote, not counting the NUL
		if a1 == 0 {return 0, true}
		out, count := iop_format(cstr(a1), 2)
		dst := ram(a0, u32(len(out)) + 1)
		n := copy(dst, out)
		if n < len(dst) {dst[n] = 0}
		return count, true
	case 20: // strcat(dst, src): dst; 0 when either is null or both end at one address
		if a0 == 0 || a1 == 0 {return 0, true}
		end, src := a0 + u32(len(cstr(a0))), cstr(a1)
		if end == a1 + u32(len(src)) {return 0, true}
		str_put(end, src)
		return a0, true
	case 22: // strcmp(a, b)
		return str_cmp(a0, a1, max(int)), true
	case 23: // strcpy(dst, src): dst, 0 when either is null
		if a0 == 0 || a1 == 0 {return 0, true}
		str_put(a0, cstr(a1))
		return a0, true
	case 27: // strlen(s): 0 for null
		return a0 == 0 ? 0 : u32(len(cstr(a0))), true
	case 29: // strncmp(a, b, n)
		return str_cmp(a0, a1, int(i32(a2))), true
	case 30: // strncpy(dst, src, n): dst, 0 when either is null; NUL-pads to n
		if a0 == 0 || a1 == 0 {return 0, true}
		src := cstr(a1)
		dst := ram(a0, u32(max(i32(a2), 0)))
		k := copy(dst, src)
		for &b in dst[k:] {b = 0}
		return a0, true
	case 36: // strtol(s, char **end, base)
		v, end := iop_strtol(a0, a2)
		if a1 != 0 {w32(a1, end)}
		return u32(v), true
	}
	return 0, false
}

// C's strtol over the string at `a`: the value, clamped to an i32, and the
// address of the first character it did not use (`a` when it used none).
iop_strtol :: proc(a, base: u32) -> (v: i32, end: u32) {
	end = a
	p := a
	ch :: proc(p: u32) -> u8 {return ram(p, 1)[0]}
	for ch(p) == ' ' || ch(p) >= '\t' && ch(p) <= '\r' {p += 1}
	neg := false
	if ch(p) == '-' || ch(p) == '+' {
		neg = ch(p) == '-'
		p += 1
	}
	base := base
	hex := ch(p) == '0' && ch(p + 1) | 0x20 == 'x'
	if (base == 0 || base == 16) && hex && digit(ch(p + 2)) < 16 {
		p += 2
		base = 16
	} else if base == 0 {
		base = 8 if ch(p) == '0' else 10
	}
	if base < 2 || base > 36 {return 0, a}
	n: i64
	any := false
	for d := digit(ch(p)); d < base; d = digit(ch(p)) {
		n = min(n * i64(base) + i64(d), i64(max(i32)) + 1)
		any = true
		p += 1
	}
	if !any {return 0, a}
	if neg {n = -n}
	return i32(clamp(n, i64(min(i32)), i64(max(i32)))), p
}

@(private = "file")
digit :: proc(c: u8) -> u32 {
	switch c {
	case '0' ..= '9': return u32(c - '0')
	case 'a' ..= 'z': return u32(c - 'a') + 10
	case 'A' ..= 'Z': return u32(c - 'A') + 10
	}
	return 99
}

// Writes `src` and its NUL at `a`, as far as RAM goes, a byte at a time
// from the front as the kernel's loop does. Its length is fixed first: where
// `a` lies inside src, the kernel's loop would run on over what it wrote,
// this stops at that length.
@(private = "file")
str_put :: proc(a: u32, src: string) {
	dst := ram(a, u32(len(src)) + 1)
	for i in 0 ..< len(dst) {dst[i] = i < len(src) ? src[i] : 0}
}

// strncmp over the strings at `a` and `b`: 0 for the same address, else -1
// when `a` is null, 1 when `b` is; else the signed difference of the first
// unequal chars within `n` (n <= 0 compares none), 0 when they end together.
@(private = "file")
str_cmp :: proc(a, b: u32, n: int) -> u32 {
	if a == 0 || b == 0 {
		return 0 if a == b else ke(-1) if a == 0 else 1
	}
	x, y := ram(a, IOP_RAM_SIZE), ram(b, IOP_RAM_SIZE)
	for i in 0 ..< min(n, len(x), len(y)) {
		if x[i] != y[i] {return u32(i32(i8(x[i])) - i32(i8(y[i])))}
		if x[i] == 0 {break}
	}
	return 0
}

// The kernel's class bits of char `c`: its table covers -1 (EOF) to 127,
// and 0 bytes follow it up to 158.
@(private = "file")
ctype :: proc(c: i32) -> u8 {
	if c >= 'A' && c <= 'Z' {return CT_UPPER | (c <= 'F' ? CT_HEX : 0)}
	if c >= 'a' && c <= 'z' {return CT_LOWER | (c <= 'f' ? CT_HEX : 0)}
	if c >= '0' && c <= '9' {return CT_DIGIT}
	if c >= '\t' && c <= '\r' {return CT_SPACE}
	if c == ' ' {return CT_SPACE | CT_PUNCT}
	if c >= 0 && c < ' ' || c == 127 {return CT_CTRL}
	if c > ' ' && c < 127 {return CT_PUNCT}
	return 0
}

CT_UPPER :: 0x01
CT_LOWER :: 0x02
CT_DIGIT :: 0x04
CT_SPACE :: 0x08
CT_PUNCT :: 0x10
CT_CTRL :: 0x20
CT_HEX :: 0x40
