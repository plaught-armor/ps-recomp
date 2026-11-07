// hle_scan: which calls into Sony code a disc's own code makes, statically,
// and which of them the HLE serves. Run it from the repository root, as it
// reads the HLE's sources to learn what they serve:
//
//   odin run tools/hle_scan -collection:ps=. -- [-bios <ROM0>] <disc> ...
//
// Each disc's files are read through, and every ELF found at a word
// boundary in them is taken: an IRX module, or an EE program. A file that
// is a ROMDIR image (an IOPRP*.IMG) is split into its modules instead.
// Archives that compress what they hold hide their modules from it.
//
// - IOP: a module is Sony's or the game's as LOADFILE judges it
//   (iop.iop_runs). Only the game's run on the R3000, so only their imports
//   of Sony libraries reach the HLE; each (library, major, function) row
//   names the discs and modules that import it, whether hle_fn serves it,
//   and whether a call to it is reached from a module's start (a call-graph
//   walk from the entry over jal, bal and j; calls through a register are
//   not followed).
// - EE: the syscall numbers the programs' code loads into v1 just before a
//   syscall, against the kernel's dispatcher.
// - PS1: the BIOS calls of each PS-X EXE (li t2, A0/B0/C0; jr t2; li t1, n)
//   against bios_a/b/c.
//
// What the HLE serves is read from its switch statements: the case labels
// of hle_fn and of the procs a case hands fno to (ps2/iop), of the kernel's
// `switch abs(n)` and of bios_a/b/c with a0_from_b0 (psx/bios). A served
// case may still refuse some arguments.
//
// -bios names a retail ROM, read for reference only: each of its modules'
// export tables gives the function count per library, the rom column.
package main

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "ps:core/disc"
import "ps:ps2/iop"
import "ps:ps2/kernel"
import pmem "ps:ps2/mem"

MAX_DISCS :: 64
CHUNK :: 8 << 20
IRX_READ :: 4 << 20
ELF_READ :: 64 << 20
ELF_MAGIC :: 0x464c457f
PSX_MAGIC :: 0x582d5350 // "PS-X"
JR_RA :: 0x03e00008

Discs :: bit_set[0 ..< MAX_DISCS; u64]

Use :: struct {
	discs: Discs,
	boot:  Discs, // the discs where a module's start reaches the call
	mods:  [dynamic]string,
}

Module :: struct {
	disc:    int,
	name:    string,
	version: u16,
	sony:    bool,
	src:     string,
}

// The rows: a library (an IOP one, or "ee", or "psx A"/"psx B"/"psx C"),
// its major version and a function number.
libs: [dynamic]string
uses: map[u64]Use
labels: [dynamic]string
seen: map[u64]bool // module and program bytes per disc
modules: [dynamic]Module
programs: [dynamic]Module // EE programs and PS-X EXEs
rom: map[u64]u32 // -bios: export count by key(lib, major, 0)
chunk: []u8

key :: proc(lib: int, major: u16, fno: u32) -> u64 {
	return u64(lib) << 32 | u64(major) << 24 | u64(fno & 0xffffff)
}

key_lib :: proc(k: u64) -> string {return libs[k >> 32]}
key_major :: proc(k: u64) -> u16 {return u16(k >> 24 & 0xff)}
key_fno :: proc(k: u64) -> u32 {return u32(k & 0xffffff)}

lib_id :: proc(name: string) -> int {
	for l, i in libs {
		if l == name {return i}
	}
	append(&libs, strings.clone(name))
	return len(libs) - 1
}

le32 :: proc(b: []u8, o: int) -> u32 {
	if o < 0 || o + 4 > len(b) {return 0}
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

table_name :: proc(n: [8]u8) -> string {
	n := n
	return strings.clone(strings.truncate_to_byte(string(n[:]), 0), context.temp_allocator)
}

use_add :: proc(k: u64, di: int, mod: string) {
	if k not_in uses {uses[k] = {}}
	u := &uses[k]
	u.discs += {di}
	for m in u.mods {
		if m == mod {return}
	}
	append(&u.mods, strings.clone(mod))
}

// Whether bytes `b` were seen on disc `di` already; marks them seen.
seen_before :: proc(di: int, b: []u8) -> bool {
	h := xxhash.XXH3_64_default(b) ~ u64(di) * 0x9e3779b97f4a7c15
	if h in seen {return true}
	seen[h] = true
	return false
}

// ------------------------------------------------------------- IOP modules

// Module bytes `b`, named `hint` when its IRX header names none. A module
// of a ROMDIR image is Sony's: such an image holds the ROM modules that
// replace the console's own at an IOP reset, which the HLE stands in for.
module_add :: proc(di: int, b: []u8, hint, src: string, rom_image := false) {
	text := b
	name := hint
	version: u16
	entry := ~u32(0)
	sony := false
	x, irx := iop.irx_parse(b)
	if irx {
		text = b[x.file_off:][:min(x.text_size, x.file_size)]
		version, entry = x.version, x.entry
		if x.name != "" {name = x.name}
		sony = rom_image || !iop.iop_runs(b)
	}
	tables := iop.irx_tables(text, 0, context.temp_allocator)
	if !irx {
		if len(tables) == 0 {return}
		sony = rom_image || iop.iop_sony(name)
		for t in tables {
			if !t.imports && iop.iop_sony(table_name(t.name)) {sony = true}
		}
	}
	if seen_before(di, text) {return}
	append(&modules, Module{di, strings.clone(name), version, sony, strings.clone(src)})
	if sony {return} // the HLE stands in for it: its imports never run
	stubs := make(map[u32]u64, context.temp_allocator)
	for t in tables {
		lib := table_name(t.name)
		if !t.imports || !iop.iop_sony(lib) {continue}
		id := lib_id(lib)
		for i in 0 ..< t.count {
			at := t.off + 20 + 8 * i
			k := key(id, t.version >> 8, le32(text, int(at) + 4) & 0xffff)
			stubs[at] = k
			use_add(k, di, name)
		}
	}
	if entry == ~u32(0) || len(stubs) == 0 {return}
	reached := make(map[u64]bool, context.temp_allocator)
	walk(text, entry, stubs, &reached)
	for k in reached {(&uses[k]).boot += {di}}
}

// The stubs that code reached from `entry` calls or jumps to: each function
// is read from its start until a `jr ra` past every branch target in it.
walk :: proc(text: []u8, entry: u32, stubs: map[u32]u64, out: ^map[u64]bool) {
	n := u32(len(text)) &~ 3
	todo := make([dynamic]u32, context.temp_allocator)
	done := make(map[u32]bool, context.temp_allocator)
	append(&todo, entry)
	for len(todo) > 0 && len(done) < 8192 {
		f := pop(&todo)
		if f >= n || f & 3 != 0 || f in done {continue}
		done[f] = true
		limit := f
		scan: for p := f; p + 4 <= n; p += 4 {
			w := le32(text, int(p))
			op := w >> 26
			rt := w >> 16 & 31
			branch := op >= 4 && op <= 7 || op >= 0x14 && op <= 0x17 || op == 1 && rt & 0xe == 0
			switch {
			case op == 2 || op == 3: // j, jal
				t := (w & 0x3ffffff) << 2
				if k, ok := stubs[t]; ok {
					out[k] = true
				} else if op == 3 || t < f || t - p > 0x1000 {
					append(&todo, t) // a call, or a jump out: a tail call
				} else if t > limit {
					limit = t
				}
			case op == 1 && rt == 0x11: // bal
				append(&todo, p + 4 + u32(i32(i16(w & 0xffff))) << 2)
			case branch:
				t := p + 4 + u32(i32(i16(w & 0xffff))) << 2
				if t > limit && t < n {limit = t}
			case w == JR_RA:
				if p >= limit {break scan}
			}
		}
	}
}

// The files of a ROMDIR image: its directory starts with the RESET entry,
// at the start of an IOPRP image and further in a console ROM (whose RESET
// file is its boot code, from 0); each file's data follows the last one's,
// 16-byte aligned.
romdir :: proc(b: []u8, allocator := context.temp_allocator) -> (names: [dynamic]string, data: [dynamic][]u8) {
	names = make([dynamic]string, allocator)
	data = make([dynamic][]u8, allocator)
	dir := -1
	for o := 0; o + 32 <= len(b) && o < 1 << 20; o += 16 {
		if string(b[o:][:10]) == "RESET\x00\x00\x00\x00\x00" && string(b[o + 16:][:7]) == "ROMDIR\x00" {
			dir = o
			break
		}
	}
	if dir < 0 {return}
	off := 0
	for e := dir; e + 16 <= len(b); e += 16 {
		if b[e] == 0 {break}
		size := int(le32(b, e + 12))
		name := strings.truncate_to_byte(string(b[e:][:10]), 0)
		if off + size > len(b) {break}
		append(&names, name)
		append(&data, b[off:][:size])
		off += (size + 15) &~ 15
	}
	return
}

// ------------------------------------------------------------- EE and PS1

// EE program `b`: the syscall numbers its executable segments load into v1
// (addiu, ori or daddiu from zero) at most four words before a syscall.
ee_add :: proc(di: int, b: []u8, src: string) -> bool {
	h := pmem.elf_header(b) or_return
	if h.class != 1 || h.type != 2 || h.machine != 8 || h.phentsize < 32 {return false}
	id := lib_id("ee")
	segs := make([dynamic][]u8, context.temp_allocator)
	for i in 0 ..< int(h.phnum) {
		p := int(h.phoff) + i * int(h.phentsize)
		if p + 32 > len(b) {return false}
		off, size := int(le32(b, p + 4)), int(le32(b, p + 16))
		if le32(b, p) != 1 || le32(b, p + 24) & 1 == 0 {continue}
		if off + size > len(b) {return false}
		append(&segs, b[off:][:size])
	}
	if seen_before(di, b[:min(len(b), 1 << 20)]) {return true}
	append(&programs, Module{disc = di, name = strings.clone(filepath.base(src)), src = strings.clone(src)})
	for s in segs {
		for q := 0; q + 4 <= len(s); q += 4 {
			if le32(s, q) & 0xfc00003f != 0x0c {continue}
			for j in 1 ..= 4 {
				v := le32(s, q - 4 * j)
				n: i32
				switch v >> 16 {
				case 0x2403, 0x6403: n = i32(i16(v & 0xffff))
				case 0x3403: n = i32(v & 0xffff)
				case: continue
				}
				use_add(key(id, 0, u32(abs(n))), di, filepath.base(src))
				break
			}
		}
	}
	return true
}

// PS-X EXE `b`: its BIOS calls, `li t2, A0/B0/C0` at most three words
// before a `jr t2` whose delay slot holds `li t1, n`.
psx_add :: proc(di: int, b: []u8, src: string) {
	if len(b) < 0x800 || string(b[:8]) != "PS-X EXE" {return}
	text := b[0x800:][:min(len(b) - 0x800, int(le32(b, 0x1c)))]
	if seen_before(di, text) {return}
	append(&programs, Module{disc = di, name = strings.clone(filepath.base(src)), src = strings.clone(src)})
	for q := 4; q + 8 <= len(text); q += 4 {
		if le32(text, q) != 0x01400008 || le32(text, q + 4) >> 16 != 0x2409 {continue}
		fno := le32(text, q + 4) & 0xffff
		for j in 1 ..= 3 {
			table: string
			switch le32(text, q - 4 * j) {
			case 0x240a00a0: table = "psx A"
			case 0x240a00b0: table = "psx B"
			case 0x240a00c0: table = "psx C"
			case: continue
			}
			use_add(key(lib_id(table), 0, fno), di, filepath.base(src))
			break
		}
	}
}

// ------------------------------------------------------------- discs

scan_disc :: proc(di: int, d: ^disc.Disc) {
	roots := [2]disc.Entry{d.root, d.root1}
	done := make(map[u32]bool, context.temp_allocator)
	for r, layer in roots {
		if layer == 1 && d.layer1 == 0 {continue}
		scan_dir(di, d, r, "", 0, &done)
	}
}

scan_dir :: proc(di: int, d: ^disc.Disc, dir: disc.Entry, path: string, depth: int, done: ^map[u32]bool) {
	if depth > disc.MAX_DEPTH {return}
	entries, ok := disc.list_entry(d, dir)
	if !ok {return}
	defer delete(entries)
	for e in entries {
		p := strings.concatenate({path, "/", e.name})
		defer delete(p)
		if e.dir {
			scan_dir(di, d, e, p, depth + 1, done)
		} else if e.lba not_in done^ {
			done[e.lba] = true
			scan_file(di, d, e, p)
			free_all(context.temp_allocator)
		}
	}
}

read_part :: proc(d: ^disc.Disc, e: disc.Entry, at: i64, most: int) -> []u8 {
	n := int(min(i64(most), i64(e.size) - at))
	b := make([]u8, n, context.temp_allocator)
	return b[:disc.read_at(d, e.lba, at, b)]
}

scan_file :: proc(di: int, d: ^disc.Disc, e: disc.Entry, path: string) {
	if e.size < 64 {return}
	head := read_part(d, e, 0, 16)
	if len(head) == 16 && string(head[:6]) == "RESET\x00" {
		b := read_part(d, e, 0, 64 << 20)
		names, data := romdir(b)
		for f, i in data {
			switch names[i] {
			case "RESET", "ROMDIR", "EXTINFO":
			case: module_add(di, f, names[i], fmt.tprintf("%s:%s", path, names[i]), rom_image = true)
			}
		}
		return
	}
	for o: i64 = 0; o < i64(e.size); o += CHUNK {
		got := disc.read_at(d, e.lba, o, chunk[:min(CHUNK, i64(e.size) - o)])
		for p := 0; p + 8 <= got; p += 4 {
			w := le32(chunk, p)
			if w == ELF_MAGIC {
				at := o + i64(p)
				h, ok := pmem.elf_header(read_part(d, e, at, 64))
				if !ok {continue}
				if h.type == iop.IRX_TYPE {
					module_add(di, read_part(d, e, at, IRX_READ), filepath.base(path), at == 0 ? path : fmt.tprintf("%s+%x", path, at))
				} else if h.type == 2 {
					ee_add(di, read_part(d, e, at, ELF_READ), at == 0 ? path : fmt.tprintf("%s+%x", path, at))
				}
			} else if w == PSX_MAGIC && string(chunk[p + 4:p + 8]) == " EXE" {
				psx_add(di, read_part(d, e, o + i64(p), 8 << 20), path)
			}
		}
	}
}

// -bios: the export count of each library in the ROM's modules. A table is
// an export magic, no link, a major of 1..15 and a printable name, then
// function offsets up to a zero one.
bios_read :: proc(path: string) -> bool {
	b, err := os.read_entire_file(path, context.allocator)
	if err != nil {return false}
	_, data := romdir(b, context.allocator)
	for f in data {
		for o := 0; o + 24 <= len(f); o += 4 {
			if le32(f, o) != iop.IRX_EXPORT_MAGIC || le32(f, o + 4) != 0 {continue}
			major := le32(f, o + 8) >> 8 & 0xff
			if major == 0 || major > 15 {continue}
			name: [8]u8
			copy(name[:], f[o + 12:][:8])
			lib := table_name(name)
			if lib == "" || !printable(lib) {continue}
			// The first four entries are the module's own and may be zero
			// (unrelocated, its start can be at offset 0; the fourth is
			// often unused): a zero ends the table only after them.
			count: u32
			for p := o + 20; p + 4 <= len(f) && count < 512; p += 4 {
				w := le32(f, p)
				if w == 0 && count >= 4 || w & 3 != 0 || w >= u32(len(f)) {break}
				count += 1
			}
			k := key(lib_id(lib), u16(major), 0)
			rom[k] = max(rom[k], count)
		}
	}
	return true
}

printable :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if c < 0x20 || c > 0x7e {return false}
	}
	return true
}

// ------------------------------------------------------------- HLE sources

Case :: struct {
	line:   int,
	labels: [dynamic]u32,
	strs:   [dynamic]string,
	note:   string, // the comment on the case line
	body:   string, // the code after the colon, else the next line's
}

Source :: struct {
	path:  string,
	lines: []string,
}

sources: [dynamic]Source

source_load :: proc(dir: string) -> bool {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {return false}
	for fi in infos {
		if !strings.has_suffix(fi.name, ".odin") {continue}
		b, rerr := os.read_entire_file(fi.fullpath, context.allocator)
		if rerr != nil {return false}
		append(&sources, Source{fi.fullpath, strings.split_lines(string(b))})
	}
	return true
}

indent :: proc(l: string) -> int {
	n := 0
	for n < len(l) && l[n] == '\t' {n += 1}
	return n
}

strip_comment :: proc(s: string) -> (code, note: string) {
	if i := strings.index(s, "//"); i >= 0 {
		return strings.trim_space(s[:i]), strings.trim_space(s[i + 2:])
	}
	return strings.trim_space(s), ""
}

// The cases of the first `switch <head> {` in lines from..<until, at that
// switch's own indentation; the default case left out.
switch_cases :: proc(lines: []string, from, until: int, head: string) -> (cases: [dynamic]Case, end: int, ok: bool) {
	want := strings.concatenate({"switch ", head, " {"}, context.temp_allocator)
	for i in from ..< min(until, len(lines)) {
		if strings.trim_space(lines[i]) != want {continue}
		k := indent(lines[i])
		for j in i + 1 ..< len(lines) {
			if indent(lines[j]) != k {continue}
			t := strings.trim_space(lines[j])
			if t == "}" {return cases, j, true}
			if !strings.has_prefix(t, "case ") {continue}
			colon := strings.index_byte(t, ':')
			if colon < 5 {continue}
			c := Case{line = j}
			c.body, c.note = strip_comment(t[colon + 1:])
			if c.body == "" && j + 1 < len(lines) {
				c.body, _ = strip_comment(lines[j + 1])
			}
			for part in strings.split(t[5:colon], ",", context.temp_allocator) {
				p := strings.trim_space(part)
				if strings.has_prefix(p, "\"") {
					append(&c.strs, strings.trim(p, "\""))
					continue
				}
				lo_s, hi_s, incl := p, p, true
				if r := strings.index(p, "..="); r >= 0 {
					lo_s, hi_s = p[:r], p[r + 3:]
				} else if x := strings.index(p, "..<"); x >= 0 {
					lo_s, hi_s, incl = p[:x], p[x + 3:], false
				}
				lo, ok1 := strconv.parse_i64_maybe_prefixed(strings.trim_space(lo_s))
				hi, ok2 := strconv.parse_i64_maybe_prefixed(strings.trim_space(hi_s))
				if !ok1 || !ok2 {continue}
				if !incl {hi -= 1}
				for v in lo ..= hi {append(&c.labels, u32(v))}
			}
			append(&cases, c)
		}
		return
	}
	return
}

// A case's name for label number i of its labels: the comment's names
// (split by ", " when there is one per label) up to a parenthesis or
// colon, else the proc its code calls.
case_name :: proc(c: Case, i: int) -> string {
	n := c.note
	if n != "" {
		if k := strings.index_any(n, "(:"); k >= 0 {n = n[:k]}
		parts := strings.split(n, ", ", context.temp_allocator)
		if len(parts) == len(c.labels) {return strings.trim_space(parts[i])}
		return strings.trim_space(n)
	}
	b := c.body
	if k := strings.index(b, "= "); k >= 0 {b = b[k + 2:]}
	if k := strings.index_byte(b, '('); k > 0 {return b[:k]}
	return ""
}

// The proc a case hands fno to (`return name(fno)`), or "".
delegate :: proc(c: Case) -> string {
	if strings.has_prefix(c.body, "return ") && strings.has_suffix(c.body, "(fno)") {
		return c.body[7:len(c.body) - 5]
	}
	return ""
}

find_proc :: proc(name: string) -> (lines: []string, at: int, ok: bool) {
	want := fmt.tprintf("%s :: proc", name)
	for s in sources {
		for l, i in s.lines {
			if strings.has_prefix(l, want) {return s.lines, i, true}
		}
	}
	return
}

proc_end :: proc(lines: []string, at: int) -> int {
	for i in at + 1 ..< len(lines) {
		if lines[i] == "}" {return i}
	}
	return len(lines)
}

// The function numbers `cases` serve, each with its name, following
// delegations.
case_set :: proc(cases: []Case, out: ^map[u32]string, depth := 0) {
	for c in cases {
		if d := delegate(c); d != "" && depth < 4 {
			sub := make(map[u32]string, context.temp_allocator)
			proc_set(d, &sub, depth + 1)
			for v in c.labels {
				if name, ok := sub[v]; ok {out[v] = name}
			}
			continue
		}
		for v, i in c.labels {out[v] = case_name(c, i)}
	}
}

proc_set :: proc(name: string, out: ^map[u32]string, depth := 0, head := "fno") {
	lines, at, ok := find_proc(name)
	if !ok {
		fmt.eprintfln("hle_scan: no proc %s in the sources", name)
		return
	}
	cases, _, found := switch_cases(lines, at, proc_end(lines, at), head)
	if found {case_set(cases[:], out, depth)}
}

// hle: what the HLE serves, by key(lib, major, fno), with names.
hle: map[u64]string

hle_read :: proc() -> bool {
	for dir in ([]string{"ps2/iop", "ps2/kernel", "psx/bios"}) {
		if !source_load(dir) {
			fmt.eprintfln("hle_scan: cannot read %s", dir)
			return false
		}
	}
	// IOP: hle_fn's `switch name`, each library's own `switch fno` or a
	// proc it hands fno to.
	lines, at, found := find_proc("hle_fn")
	end := proc_end(lines, at)
	libcases, swend, sok := switch_cases(lines, at, end, "name")
	if !found || !sok {
		fmt.eprintln("hle_scan: no `switch name` in hle_fn")
		return false
	}
	for c, i in libcases {
		next := i + 1 < len(libcases) ? libcases[i + 1].line : swend
		set := make(map[u32]string, context.temp_allocator)
		if delegate(c) != "" {
			case_set([]Case{c}[:], &set)
			// A lone delegation names no labels: take all its proc serves.
			proc_set(delegate(c), &set)
		} else if sub, _, inner := switch_cases(lines, c.line + 1, next, "fno"); inner {
			case_set(sub[:], &set)
		}
		for lib in c.strs {
			major := u16(iop.hle_major(lib))
			for v, name in set {hle[key(lib_id(lib), major, v)] = strings.clone(name)}
		}
	}
	// EE: the kernel's `switch abs(n)`.
	{
		klines, kat, kfound := find_proc("syscall")
		cases, _, kok := switch_cases(klines, kat, proc_end(klines, kat), "abs(n)")
		if !kfound || !kok {
			fmt.eprintln("hle_scan: no `switch abs(n)` in the kernel's syscall")
			return false
		}
		set := make(map[u32]string, context.temp_allocator)
		case_set(cases[:], &set)
		for v, name in set {hle[key(lib_id("ee"), 0, v)] = strings.clone(name)}
	}
	// PS1: bios_a/b/c, and the A calls a0_from_b0 sends to B.
	b := make(map[u32]string, context.temp_allocator)
	for t in ([]string{"A", "B", "C"}) {
		set := make(map[u32]string, context.temp_allocator)
		proc_set(fmt.tprintf("bios_%s", strings.to_lower(t, context.temp_allocator)), &set, head = "fn")
		for v, name in set {hle[key(lib_id(fmt.tprintf("psx %s", t)), 0, v)] = strings.clone(name)}
		if t == "B" {b = set}
	}
	for s in sources {
		in_table := false
		for l in s.lines {
			if strings.has_prefix(l, "a0_from_b0 := ") {in_table = true; continue}
			if !in_table {continue}
			if l == "}" {break}
			code, _ := strip_comment(l)
			eq := strings.index(code, " = ")
			if eq < 0 {continue}
			a, ok1 := strconv.parse_i64_maybe_prefixed(code[:eq])
			bb, ok2 := strconv.parse_i64_maybe_prefixed(strings.trim_right(code[eq + 3:], ","))
			if !ok1 || !ok2 {continue}
			if name, ok := b[u32(bb)]; ok {
				hle[key(lib_id("psx A"), 0, u32(a))] = fmt.aprintf("B(%02x) %s", bb, name)
			}
		}
	}
	return true
}

// ------------------------------------------------------------- report

Row :: struct {
	k:       u64,
	u:       ^Use,
	served:  bool,
	other:   bool, // served at another major only
	n:       int,
}

row_less :: proc(a, b: Row) -> bool {
	if a.served != b.served {return !a.served}
	if a.n != b.n {return a.n > b.n}
	ab, bb := a.u.boot != {}, b.u.boot != {}
	if ab != bb {return ab}
	if key_lib(a.k) != key_lib(b.k) {return key_lib(a.k) < key_lib(b.k)}
	return a.k < b.k
}

disc_list :: proc(s: Discs) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(labels) {
		if i not_in s {continue}
		if strings.builder_len(b) > 0 {strings.write_byte(&b, ',')}
		strings.write_string(&b, labels[i])
	}
	return strings.to_string(b)
}

mod_list :: proc(m: []string) -> string {
	s := slice.clone(m, context.temp_allocator)
	slice.sort(s)
	if len(s) > 4 {
		return fmt.tprintf("%s,+%d", strings.join(s[:4], ",", context.temp_allocator), len(s) - 4)
	}
	return strings.join(s, ",", context.temp_allocator)
}

report :: proc(have_rom: bool) {
	fmt.println("# discs")
	for l, i in labels {
		game, sony, progs := 0, 0, 0
		for m in modules {
			if m.disc == i {if m.sony {sony += 1} else {game += 1}}
		}
		for p in programs {if p.disc == i {progs += 1}}
		fmt.printfln("%-12s  game IRX %-3d  Sony IRX %-3d  programs %d", l, game, sony, progs)
	}
	fmt.println("\n# modules (kind, disc, name, version, where)")
	for m in modules {
		fmt.printfln("%s  %-12s %-10s %x.%02x  %s", m.sony ? "sony" : "game", labels[m.disc], m.name, m.version >> 8, m.version & 0xff, m.src)
	}
	sections := [?]string{"IOP: game modules' imports of Sony libraries", "EE syscalls", "PS1 BIOS calls"}
	for title, si in sections {
		rows := make([dynamic]Row, context.temp_allocator)
		for k, &u in uses {
			lib := key_lib(k)
			s := 0 if lib != "ee" && !strings.has_prefix(lib, "psx ") else (1 if lib == "ee" else 2)
			if s != si {continue}
			r := Row{k = k, u = &u, n = card(u.discs)}
			_, r.served = hle[k]
			if !r.served && si == 0 {
				for m in u16(1) ..= 15 {
					if _, ok := hle[key(int(k >> 32), m, key_fno(k))]; ok {r.other = true}
				}
			}
			append(&rows, r)
		}
		if len(rows) == 0 {continue}
		slice.sort_by(rows[:], row_less)
		missing := 0
		for r in rows {if !r.served {missing += 1}}
		fmt.printfln("\n# %s: %d calls, %d not served", title, len(rows), missing)
		if si == 0 {
			fmt.printfln("%-9s %-3s %-4s %-6s %-4s %-5s %-24s %-24s %s", "lib", "maj", "fno", "hle", "rom", "discs", "start", "name", "on discs / modules")
		} else {
			fmt.printfln("%-9s %-4s %-6s %-5s %-24s %s", "table", "no", "hle", "discs", "name", "on discs / programs")
		}
		for r in rows {
			name := hle[r.k]
			hl := r.served ? "y" : (r.other ? "major" : "n")
			if si == 0 {
				romc := "-"
				if have_rom {
					c, in_rom := rom[key(int(r.k >> 32), key_major(r.k), 0)]
					romc = !in_rom ? "?" : (key_fno(r.k) < c ? "y" : "n")
				}
				fmt.printfln("%-9s %-3d %-4d %-6s %-4s %-5d %-24s %-24s %s / %s", key_lib(r.k), key_major(r.k), key_fno(r.k), hl, romc, r.n,
					r.u.boot == {} ? "-" : disc_list(r.u.boot), name, disc_list(r.u.discs), mod_list(r.u.mods[:]))
			} else {
				if si == 1 && name == "" {
					f := key_fno(r.k)
					if int(f) < len(kernel.ROM_ONLY_SYSCALLS) {name = kernel.ROM_ONLY_SYSCALLS[f]}
				}
				fmt.printfln("%-9s %-4x %-6s %-5d %-24s %s / %s", key_lib(r.k), key_fno(r.k), hl, r.n, name, disc_list(r.u.discs), mod_list(r.u.mods[:]))
			}
		}
		if si != 0 {continue}
		// Per library: the functions imported, served, and in the ROM.
		fmt.printfln("\n# IOP libraries: imported, not served, HLE serves, ROM exports")
		Lib :: struct {
			k:                u64,
			imported, gaps:   int,
			served, exported: int,
		}
		per := make(map[u64]Lib, context.temp_allocator)
		for r in rows {
			lk := r.k &~ 0xffffff
			l := per[lk]
			l.k = lk
			l.imported += 1
			if !r.served {l.gaps += 1}
			per[lk] = l
		}
		for k in hle {
			lk := k &~ 0xffffff
			if l, ok := per[lk]; ok {l.served += 1; per[lk] = l}
		}
		list := make([dynamic]Lib, context.temp_allocator)
		for _, l in per {
			l := l
			l.exported = int(rom[l.k]) if l.k in rom else -1
			append(&list, l)
		}
		slice.sort_by(list[:], proc(a, b: Lib) -> bool {
			if a.gaps != b.gaps {return a.gaps > b.gaps}
			return key_lib(a.k) < key_lib(b.k)
		})
		fmt.printfln("%-9s %-3s %-8s %-10s %-10s %s", "lib", "maj", "imported", "not served", "HLE serves", "ROM exports")
		for l in list {
			fmt.printfln("%-9s %-3d %-8d %-10d %-10d %s", key_lib(l.k), key_major(l.k), l.imported, l.gaps, l.served, l.exported < 0 ? "-" : fmt.tprint(l.exported))
		}
	}
}

main :: proc() {
	args := os.args[1:]
	bios := ""
	if len(args) >= 2 && args[0] == "-bios" {
		bios, args = args[1], args[2:]
	}
	if len(args) == 0 || len(args) > MAX_DISCS {
		fmt.eprintln("usage: hle_scan [-bios <ROM0>] <disc image> ...  (from the repository root)")
		os.exit(2)
	}
	if !hle_read() {
		fmt.eprintln("hle_scan: cannot read the HLE sources: run it from the repository root")
		os.exit(1)
	}
	if bios != "" && !bios_read(bios) {
		fmt.eprintfln("hle_scan: cannot read %s", bios)
		os.exit(1)
	}
	chunk = make([]u8, CHUNK)
	for path in args {
		d, ok := disc.open(path)
		if !ok {
			fmt.eprintfln("hle_scan: cannot open %s", path)
			os.exit(1)
		}
		label := filepath.stem(path)
		if cnf, cok := disc.system_cnf(&d); cok && cnf.serial != "" {label = cnf.serial}
		append(&labels, strings.clone(label))
		scan_disc(len(labels) - 1, &d)
		disc.close(&d)
	}
	report(bios != "")
}
