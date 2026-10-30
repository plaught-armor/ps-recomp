// The ISO9660 file system on a disc image, and SYSTEM.CNF, which names a
// PlayStation disc's executable. The image is untrusted: every length,
// extent and size it holds is checked before use, and a malformed one fails
// the call.
package disc

import "core:encoding/endian"
import "core:fmt"
import "core:strings"

// A file or directory: its name (no `;1` version), first LBA and size in
// bytes.
Entry :: struct {
	name: string,
	lba:  u32,
	size: u32,
	dir:  bool,
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
		root, ok := record(sector[156:190], min(d.volume, end(d)))
		if !ok || !root.dir {
			d.volume = 0
			return
		}
		d.root = root
		break
	}
	layer1: [DATA]u8
	if d.volume > 0 && end(d) > d.volume + 16 && read(d, d.volume + 16, layer1[:]) && string(layer1[1:6]) == "CD001" {
		d.layer1 = d.volume
		fmt.eprintfln("disc: dual layer, the second from LBA %d: only the first is read", d.layer1)
	}
}

// The directory record at the start of rec, which holds len(rec) bytes,
// its extent checked against limit. ok false when malformed; name "" for
// the `.` and `..` records. The name is a slice of rec.
@(private = "file")
record :: proc(rec: []u8, limit: u32) -> (e: Entry, ok: bool) {
	n := len(rec)
	if n < 34 || int(rec[0]) > n || rec[0] < 34 {
		return {}, false
	}
	n = int(rec[0])
	name_len := int(rec[32])
	if 33 + name_len > n {
		return {}, false
	}
	e.lba, _ = endian.get_u32(rec[2:6], .Little)
	e.size, _ = endian.get_u32(rec[10:14], .Little)
	e.dir = rec[25] & 2 != 0
	sectors := (u64(e.size) + DATA - 1) / DATA
	if u64(e.lba) + sectors > u64(limit) {
		return {}, false
	}
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
	limit := min(d.volume, end(d))
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
			e := record(sector[at:], limit) or_return
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

// Find the file or directory at a disc path, matching names
// case-insensitively; "" or `\` is the root. The name is allocated.
find :: proc(d: ^Disc, path: string, allocator := context.allocator) -> (e: Entry, ok: bool) {
	if d.volume == 0 {
		return {}, false
	}
	parts := split_path(path) or_return
	at := d.root
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
// out), whether it is a PS2 one (BOOT2), the serial its name makes
// (SLUS_123.45 is SLUS-12345, "" when it has no such form) and VMODE.
System_Cnf :: struct {
	boot:   string,
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
	c.vmode = strings.clone(vmode, allocator)
	c.serial = serial(parts[len(parts) - 1], allocator)
	return c, true
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
