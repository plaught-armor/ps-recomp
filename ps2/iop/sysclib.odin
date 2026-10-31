// stdio and sysclib: the C library IOP modules import from the kernel.
// Numbers as the PS2SDK's export tables order them.
package ps2_iop

import "core:fmt"
import "core:strings"
import cpu "../cpu"
import r3000 "ps:psx/cpu"

// `n` bytes of IOP RAM from `a`, fewer where RAM ends.
@(private = "file")
ram :: proc(a, n: u32) -> []u8 {
	w := a & (IOP_RAM_SIZE - 1)
	return iop_ram[w:][:min(n, IOP_RAM_SIZE - w)]
}

// The NUL-terminated string at `a`, cut where RAM ends.
@(private = "file")
cstr :: proc(a: u32) -> string {
	return strings.truncate_to_byte(string(ram(a, IOP_RAM_SIZE)), 0)
}

// Function fno of stdio, reading a0..a3; v0, or false when the HLE lacks it.
// What a module prints shows under PS_DEBUG.
stdio_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	switch fno {
	case 4: // printf(format, ...)
		s := iop_format(cstr(r3000.state.r[4]))
		if cpu.debug >= 1 {fmt.eprint("iop printf: ", s, sep = "")}
		return u32(len(s)), true
	case 7: // puts(s)
		if cpu.debug >= 1 {fmt.eprintln("iop puts:", cstr(r3000.state.r[4]))}
		return 0, true
	}
	return 0, false
}

// printf's output for `format`, its arguments from a1 on: a1..a3, then the
// caller's stack past the argument registers' home. Conversions d i u x X o
// c s p and %%, with flags - 0 + and space, a width, a precision for s, and
// the size letters l h z, which 32-bit ints ignore.
iop_format :: proc(format: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	arg := 1
	next :: proc(arg: ^int) -> u32 {
		r := &r3000.state.r
		i := arg^
		arg^ += 1
		return r[4 + i] if i < 4 else r32(r[29] + 4 * u32(i))
	}
	for i := 0; i < len(format); i += 1 {
		if format[i] != '%' {
			strings.write_byte(&b, format[i])
			continue
		}
		start := i
		left, zero, plus, space := false, false, false, false
		for i += 1; i < len(format) && strings.index_byte("-0+ #", format[i]) >= 0; i += 1 {
			switch format[i] {
			case '-': left = true
			case '0': zero = true
			case '+': plus = true
			case ' ': space = true
			}
		}
		width, prec := 0, -1
		for ; i < len(format) && format[i] >= '0' && format[i] <= '9'; i += 1 {width = width * 10 + int(format[i] - '0')}
		if i < len(format) && format[i] == '.' {
			prec = 0
			for i += 1; i < len(format) && format[i] >= '0' && format[i] <= '9'; i += 1 {prec = prec * 10 + int(format[i] - '0')}
		}
		for i < len(format) && strings.index_byte("lhz", format[i]) >= 0 {i += 1}
		if i >= len(format) {break}
		body, sign: string
		switch format[i] {
		case 'd', 'i':
			v := i32(next(&arg))
			body = fmt.tprint(abs(i64(v)))
			sign = "-" if v < 0 else "+" if plus else " " if space else ""
		case 'u': body = fmt.tprint(next(&arg))
		case 'x', 'p': body = fmt.tprintf("%x", next(&arg))
		case 'X': body = fmt.tprintf("%X", next(&arg))
		case 'o': body = fmt.tprintf("%o", next(&arg))
		case 'c': body = fmt.tprint(rune(u8(next(&arg))))
		case 's':
			body = cstr(next(&arg))
			if prec >= 0 && prec < len(body) {body = body[:prec]}
			zero = false
		case '%': body = "%"
		case: body = format[start:i + 1]
		}
		pad := max(width - len(sign) - len(body), 0)
		if left {
			strings.write_string(&b, sign)
			strings.write_string(&b, body)
			for _ in 0 ..< pad {strings.write_byte(&b, ' ')}
		} else if zero {
			strings.write_string(&b, sign)
			for _ in 0 ..< pad {strings.write_byte(&b, '0')}
			strings.write_string(&b, body)
		} else {
			for _ in 0 ..< pad {strings.write_byte(&b, ' ')}
			strings.write_string(&b, sign)
			strings.write_string(&b, body)
		}
	}
	return strings.to_string(b)
}

// Function fno of sysclib, as stdio_fn.
sysclib_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	r := &r3000.state.r
	a0, a1, a2 := r[4], r[5], r[6]
	switch fno {
	case 12: // memcpy(dst, src, n)
		src := ram(a1, a2)
		copy(ram(a0, u32(len(src))), src)
		return a0, true
	case 14: // memset(dst, c, n)
		for &b in ram(a0, a2) {b = u8(a1)}
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
