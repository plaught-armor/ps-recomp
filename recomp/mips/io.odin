package mips

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// Prints the message to standard error and exits with status 1.
fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

read_file :: proc(path: string) -> []u8 {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fail("%s: %v", path, err)
	}
	return data
}

write_file :: proc(path: string, data: []u8) {
	if err := os.write_entire_file(path, data); err != nil {
		fail("%s: %v", path, err)
	}
}

make_dirs :: proc(path: string) {
	if err := os.make_directory_all(path); err != nil && err != .Exist {
		fail("%s: %v", path, err)
	}
}

// Remove the packages an earlier run left in out when this one wrote only
// count: directories named prefix + digits (prefix%02d) numbered count or
// more. Only their generated file, when it starts with header, is removed,
// then the directory if that emptied it; anything else stays, and so does a
// symbolic link.
remove_stale_packages :: proc(out, prefix, file, header: string, count: int) {
	infos, err := os.read_all_directory_by_path(out, context.allocator)
	if err != nil {
		fail("%s: %v", out, err)
	}
	for fi in infos {
		digits := strings.trim_prefix(fi.name, prefix)
		if fi.type != .Directory || len(digits) < 2 || len(digits) == len(fi.name) {
			continue
		}
		numeric := true
		for c in digits {
			numeric &&= '0' <= c && c <= '9'
		}
		if !numeric || parse_int(digits) < count {
			continue
		}
		path := join(fi.fullpath, file)
		if data, read_err := os.read_entire_file(path, context.allocator); read_err == nil {
			if strings.has_prefix(string(data), header) {
				if rm_err := os.remove(path); rm_err != nil {
					fail("%s: %v", path, rm_err)
				}
			}
		}
		if os.remove(fi.fullpath) != nil {
			fmt.eprintfln("%s: kept, it holds more than a generated package", fi.fullpath)
		}
	}
}

join :: proc(parts: ..string) -> string {
	p, _ := filepath.join(parts, context.allocator)
	return p
}

concat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

parse_hex :: proc(s: string) -> u32 {
	s := s
	if strings.has_prefix(s, "0x") || strings.has_prefix(s, "0X") {
		s = s[2:]
	}
	v, ok := strconv.parse_u64_of_base(s, 16)
	if !ok || v > 0xffffffff {
		fail("not a hex number: %s", s)
	}
	return u32(v)
}

parse_int :: proc(s: string) -> int {
	v, ok := strconv.parse_int(s, 10)
	if !ok {
		fail("not a number: %s", s)
	}
	return v
}

u32le :: #force_inline proc(d: []u8, at: int) -> u32 {
	v, _ := endian.get_u32(d[at:], .Little)
	return v
}

put_u32 :: #force_inline proc(d: []u8, at: int, v: u32) {
	endian.put_u32(d[at:], .Little, v)
}

hex_string :: proc(digest: []u8) -> string {
	b := strings.builder_make()
	for x in digest {
		fmt.sbprintf(&b, "%02x", x)
	}
	return strings.to_string(b)
}

hexu :: proc(v: u32) -> string {
	return fmt.aprintf("0x%08x", v)
}

// One line of generated source.
line :: proc(b: ^strings.Builder, format: string, args: ..any) {
	if len(args) == 0 {
		strings.write_string(b, format)
	} else {
		fmt.sbprintf(b, format, ..args)
	}
	strings.write_byte(b, '\n')
}

// An import path given relative to the output directory, as seen from a
// package `depth` directories below it. Collection paths (`ps:psx`) are the
// same from everywhere.
import_path :: proc(path: string, depth: int) -> string {
	if strings.contains_rune(path, ':') {
		return path
	}
	b := strings.builder_make()
	for _ in 0 ..< depth {
		strings.write_string(&b, "../")
	}
	strings.write_string(&b, path)
	return strings.to_string(b)
}
