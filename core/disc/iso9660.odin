// The ISO9660 file system on a disc image, and SYSTEM.CNF, which names a
// PlayStation disc's executable. The image is untrusted: every length,
// extent and size it holds is checked before use, and a malformed one fails
// the call.
package disc

import "core:encoding/endian"
import "core:strings"

// A file or directory: its name (no `;1` version), first LBA and size in
// bytes, the layer whose volume holds it, and its record's recording date
// {years since 1900, month, day, hour, minute, second, GMT offset}.
Entry :: struct {
	name:  string,
	lba:   u32,
	size:  u32,
	dir:   bool,
	layer: u8,
	date:  [7]u8,
}

// The most components a path may have.
MAX_DEPTH :: 32
// The most sectors one directory may span.
MAX_DIR_SECTORS :: 4096
// The largest file read_file reads, and the largest SYSTEM.CNF.
MAX_FILE :: 1 << 30
@(private = "file")
MAX_CNF :: 64 * 1024

// The first sector past the image.
end :: proc(d: ^Disc) -> u32 {
	n: u32
	for t in d.tracks {
		n = max(n, t.start + t.sectors)
	}
	return n
}

// Find the primary volume descriptor and, on a DVD, a second layer's.
@(private)
volume_probe :: proc(d: ^Disc) {
	sector: [DATA]u8
	for lba in u32(16) ..< 32 {
		if !read(d, lba, sector[:]) || string(sector[1:6]) != "CD001" || sector[0] == 255 {
			return
		}
		if sector[0] != 1 {
			continue
		}
		d.volume, _ = endian.get_u32(sector[80:84], .Little)
		root, ok := record(sector[156:190], 0, min(d.volume, end(d)))
		if !ok || !root.dir {
			d.volume = 0
			return
		}
		d.root = root
		break
	}
	// A dual-layer DVD's second layer holds a volume of its own, its
	// descriptor 16 sectors into the layer, which starts at the first
	// volume's end or 16 sectors before it (images of both are seen). Its
	// records count sectors from the layer's start. Taken only when the
	// descriptor is a primary one whose volume ends inside the image and
	// whose root directory starts with its `.` record.
	if d.volume == 0 {
		return
	}
	for pvd in ([2]u32{d.volume, d.volume + 16}) {
		if pvd < 32 || !read(d, pvd, sector[:]) || sector[0] != 1 || string(sector[1:6]) != "CD001" {
			continue
		}
		start := pvd - 16
		size, _ := endian.get_u32(sector[80:84], .Little)
		if size == 0 || u64(start) + u64(size) > u64(end(d)) {
			continue
		}
		root, ok := record(sector[156:190], start, start + size)
		if !ok || !root.dir || !self_record(d, root, start, start + size) {
			continue
		}
		root.layer = 1
		d.layer1, d.volume1, d.root1 = start, size, root
		return
	}
}

// The most sectors a CD holds: 99 minutes at 75 a second.
CD_MAX_SECTORS :: 99 * 60 * 75

// Whether the disc is a DVD. The drive tells CD from DVD by the medium
// itself, which an image does not record, so this judges from the image's
// contents, in order:
//  - raw sectors (a .bin or .cue of 2352-byte ones): a CD, as a DVD has no
//    CD sectors to dump raw;
//  - a UDF NSR02 or NSR03 descriptor in the volume recognition sequence
//    after the ISO9660 descriptors: a DVD. DVD-ROMs are mastered as UDF
//    bridge discs, and every PS2 DVD image seen carries BEA01, NSR02 and
//    TEA01 there; PS2 CDs are plain ISO9660;
//  - more sectors than a CD holds: a DVD;
//  - otherwise a CD only when PCSX2's test also says CD (InputIsoFile.cpp
//    tryIsoType: the root directory record's data length is 2048, as CD
//    mastering writes it; Sony's DVD mastering writes the directory's exact
//    length). That test alone misreads a CD whose root spans more than one
//    sector, so here it only confirms.
// Anything not shown to be a CD is a DVD: most PS2 discs are DVDs, a DVD
// game told it is on a CD may refuse the disc, and that is the worse error.
@(private)
dvd_probe :: proc(d: ^Disc) -> bool {
	for t in d.tracks {
		if t.raw {
			return false
		}
	}
	sector: [DATA]u8
	for lba in u32(16) ..< 32 {
		if !read(d, lba, sector[:]) {
			break
		}
		id := string(sector[1:6])
		if id == "NSR02" || id == "NSR03" {
			return true
		}
	}
	return end(d) > CD_MAX_SECTORS || d.root.size != DATA
}

// Whether directory dir's first record is its `.`, pointing back at dir.
@(private = "file")
self_record :: proc(d: ^Disc, dir: Entry, base, limit: u32) -> bool {
	sector: [DATA]u8
	if !read(d, dir.lba, sector[:]) {
		return false
	}
	e, ok := record(sector[:], base, limit)
	return ok && e.name == "" && e.dir && e.lba == dir.lba
}

// The sectors a layer's volume spans: its first and the first past it.
@(private = "file")
layer_span :: proc(d: ^Disc, layer: u8) -> (base, limit: u32) {
	if layer == 0 {
		return 0, min(d.volume, end(d))
	}
	return d.layer1, d.layer1 + d.volume1
}

// The directory record at the start of rec, which holds len(rec) bytes, its
// LBA counted from base and its extent checked against limit. ok false when
// malformed; name "" for the `.` and `..` records. The name is a slice of
// rec.
@(private = "file")
record :: proc(rec: []u8, base, limit: u32) -> (e: Entry, ok: bool) {
	n := len(rec)
	if n < 34 || int(rec[0]) > n || rec[0] < 34 {
		return {}, false
	}
	n = int(rec[0])
	name_len := int(rec[32])
	if 33 + name_len > n {
		return {}, false
	}
	rel, _ := endian.get_u32(rec[2:6], .Little)
	e.size, _ = endian.get_u32(rec[10:14], .Little)
	e.dir = rec[25] & 2 != 0
	copy(e.date[:], rec[18:25])
	sectors := (u64(e.size) + DATA - 1) / DATA
	if u64(base) + u64(rel) + sectors > u64(limit) {
		return {}, false
	}
	e.lba = base + rel
	name := string(rec[33:33 + name_len])
	if name_len == 1 && (name[0] == 0 || name[0] == 1) {
		return e, true
	}
	if i := strings.index_byte(name, ';'); i >= 0 {
		name = name[:i]
	}
	name = strings.trim_right(name, ".")
	if name == "" {
		return {}, false
	}
	e.name = name
	return e, true
}

// The entries of directory dir, `.` and `..` left out, names allocated.
list_entry :: proc(d: ^Disc, dir: Entry, allocator := context.allocator) -> (entries: []Entry, ok: bool) {
	if d.volume == 0 || !dir.dir {
		return nil, false
	}
	sectors := (dir.size + DATA - 1) / DATA
	base, limit := layer_span(d, dir.layer)
	if sectors > MAX_DIR_SECTORS || u64(dir.lba) + u64(sectors) > u64(limit) {
		return nil, false
	}
	out := make([dynamic]Entry, allocator)
	defer if !ok {
		for e in out {
			delete(e.name, allocator)
		}
		delete(out)
	}
	sector: [DATA]u8
	for i in 0 ..< sectors {
		if !read(d, dir.lba + i, sector[:]) {
			return nil, false
		}
		at := 0
		for at < DATA {
			if sector[at] == 0 { // padding to the sector's end, nothing else
				for b in sector[at:] {
					if b != 0 {
						return nil, false
					}
				}
				break
			}
			e := record(sector[at:], base, limit) or_return
			e.layer = dir.layer
			at += int(sector[at])
			if e.name != "" {
				e.name = strings.clone(e.name, allocator)
				append(&out, e)
			}
		}
	}
	return out[:], true
}

// The components of a disc path: a device prefix (`cdrom0:`) and `;N`
// versions left out, `\` or `/` between components. ok false for `..` or
// too deep a path.
@(private = "file")
split_path :: proc(path: string) -> (parts: [dynamic]string, ok: bool) {
	rest := path
	if i := strings.index_byte(rest, ':'); i >= 0 {
		rest = rest[i + 1:]
	}
	parts = make([dynamic]string, context.temp_allocator)
	for len(rest) > 0 {
		i := strings.index_any(rest, "\\/")
		part := i < 0 ? rest : rest[:i]
		rest = i < 0 ? "" : rest[i + 1:]
		if j := strings.index_byte(part, ';'); j >= 0 {
			part = part[:j]
		}
		part = strings.trim_right(part, ".")
		switch {
		case part == "": continue
		case part == "..": return nil, false
		}
		append(&parts, part)
	}
	return parts, len(parts) <= MAX_DEPTH
}

// Find the file or directory at a disc path in a layer's volume (1: a
// dual-layer DVD's second), matching names case-insensitively; "" or `\` is
// the root. The name is allocated.
find :: proc(d: ^Disc, path: string, allocator := context.allocator, layer: u8 = 0) -> (e: Entry, ok: bool) {
	if d.volume == 0 || layer > 1 || (layer == 1 && d.layer1 == 0) {
		return {}, false
	}
	parts := split_path(path) or_return
	at := layer == 0 ? d.root : d.root1
	for part in parts {
		entries := list_entry(d, at, context.temp_allocator) or_return
		found := false
		for c in entries {
			if strings.equal_fold(c.name, part) {
				at, found = c, true
				break
			}
		}
		if !found {
			return {}, false
		}
	}
	at.name = strings.clone(len(parts) > 0 ? at.name : "", allocator)
	return at, true
}

// The entries of the directory at a disc path, names allocated.
list :: proc(d: ^Disc, path: string, allocator := context.allocator) -> (entries: []Entry, ok: bool) {
	dir := find(d, path, context.temp_allocator) or_return
	return list_entry(d, dir, allocator)
}

// The bytes of the file at a disc path.
read_file :: proc(d: ^Disc, path: string, allocator := context.allocator) -> (data: []u8, ok: bool) {
	e := find(d, path, context.temp_allocator) or_return
	if e.dir || e.size > MAX_FILE {
		return nil, false
	}
	data = make([]u8, e.size, allocator)
	if read_at(d, e.lba, 0, data) != len(data) {
		delete(data, allocator)
		return nil, false
	}
	return data, true
}

// What SYSTEM.CNF says: the executable's disc path (device and `;1` left
// out), the same line's value as written (`argv`), whether it is a PS2 one
// (BOOT2), the serial its name makes (SLUS_123.45 is SLUS-12345, "" when it
// has no such form) and VMODE.
System_Cnf :: struct {
	boot:   string,
	// The value as the ROM's loader passes it on as the program's argv[0]:
	// from its first printable byte up to the next space or control byte,
	// device, backslashes, case and `;1` kept ("cdrom0:\SLUS_123.45;1").
	argv:   string,
	ps2:    bool,
	serial: string,
	vmode:  string,
}

// Read SYSTEM.CNF from the root. Strings allocated.
system_cnf :: proc(d: ^Disc, allocator := context.allocator) -> (c: System_Cnf, ok: bool) {
	e := find(d, "SYSTEM.CNF", context.temp_allocator) or_return
	if e.dir || e.size > MAX_CNF {
		return {}, false
	}
	data := make([]u8, e.size, context.temp_allocator)
	if read_at(d, e.lba, 0, data) != len(data) {
		return {}, false
	}
	boot, vmode: string
	s := string(data)
	for line in strings.split_lines_iterator(&s) {
		key, _, value := strings.partition(line, "=")
		key = strings.trim_space(key)
		value = strings.trim_space(value)
		switch {
		case strings.equal_fold(key, "BOOT2"): boot, c.ps2 = value, true
		case strings.equal_fold(key, "BOOT") && !c.ps2: boot = value
		case strings.equal_fold(key, "VMODE"): vmode = value
		}
	}
	parts := split_path(boot) or_return
	if len(parts) == 0 {
		return {}, false
	}
	c.boot = strings.join(parts[:], "/", allocator)
	end := 0
	for end < len(boot) && boot[end] > ' ' && boot[end] < 0x7f {end += 1}
	c.argv = strings.clone(boot[:end], allocator)
	c.vmode = strings.clone(vmode, allocator)
	c.serial = serial(parts[len(parts) - 1], allocator)
	return c, true
}

// The volume identifier of the primary volume descriptor in sector 16
// (bytes 40-71), trimmed, each byte other than printable ASCII a space; ""
// when sector 16 holds no primary volume descriptor. Allocated.
volume_label :: proc(d: ^Disc, allocator := context.allocator) -> string {
	sector: [DATA]u8
	if !read(d, 16, sector[:]) || sector[0] != 1 || string(sector[1:6]) != "CD001" {
		return ""
	}
	b: [32]u8
	for c, i in sector[40:72] {
		b[i] = c > ' ' && c < 0x7f ? c : ' '
	}
	return strings.clone(strings.trim_space(string(b[:])), allocator)
}

// SLUS_123.45 as SLUS-12345: four letters, `_`, then digits with one `.`.
@(private = "file")
serial :: proc(name: string, allocator := context.allocator) -> string {
	if len(name) != 11 || name[4] != '_' || name[8] != '.' {
		return ""
	}
	b: [10]u8
	for i in 0 ..< 4 {
		c := name[i] &~ 0x20
		if c < 'A' || c > 'Z' {
			return ""
		}
		b[i] = c
	}
	b[4] = '-'
	k := 5
	for i in 5 ..< 11 {
		if i == 8 {
			continue
		}
		if name[i] < '0' || name[i] > '9' {
			return ""
		}
		b[k] = name[i]
		k += 1
	}
	return strings.clone(string(b[:]), allocator)
}
