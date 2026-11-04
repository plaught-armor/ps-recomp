// The launcher's library: the disc images the player added, each referenced
// where it is, never copied. <data>/library.tsv holds one `path<TAB>id` row
// per image in the order added, the path absolute with symlinks resolved
// (library_path). Each disc's disc.tsv (core/data.odin) keeps what a scan of
// its image found, one `name<TAB>value` row for each name in INFO_NAMES.
//
// Loading the library opens an image only when its path, size or mtime
// differ from its disc.tsv's (for a .cue sheet, the sheet's own: a .bin
// replaced under it is not seen), so a large library loads without reading
// its discs. An image that no longer opens as a disc is missing and keeps
// what was last known of it until it is removed. Two images of one disc
// share its disc.tsv, and loading the library scans one of them again each
// time.
package play

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "ps:core"
import "ps:core/disc"

// What disc.tsv keeps. title: the name the launcher shows, the volume label
// until the player renames the disc, kept across scans of the same disc id;
// system: ps1 or ps2.
Info :: enum {
	Path,
	Size,
	Mtime,
	Serial,
	Title,
	Label,
	System,
}

INFO_NAMES :: [Info]string {
	.Path   = "path",
	.Size   = "size",
	.Mtime  = "mtime",
	.Serial = "serial",
	.Title  = "title",
	.Label  = "label",
	.System = "system",
}

// One library row: the disc id, its disc.tsv (the path always the row's),
// whether its image no longer opens as a disc, and its compat.tsv row (all
// "" when it has none).
Library_Disc :: struct {
	id:      string,
	info:    [Info]string,
	missing: bool,
	compat:  Row,
}

// A library.tsv row.
@(private = "file")
Index_Row :: struct {
	path, id: string,
}

// The library, each image scanned again whose file changed, library.tsv
// rewritten when a changed image is another disc now. Strings live in
// `allocator`. False, after a message, without a data directory or when
// library.tsv cannot be written.
library_load :: proc(allocator := context.allocator) -> (discs: [dynamic]Library_Disc, ok: bool) {
	data := core.data_dir(context.temp_allocator) or_return
	index := library_index(data)
	rows := index_read(index)
	compat_path, _ := filepath.join({data, "compat.tsv"}, context.temp_allocator)
	compat := compat_rows(compat_path)
	discs = make([dynamic]Library_Disc, 0, len(rows), allocator)
	changed := false
	for &r in rows {
		dir := core.disc_dir(r.id, context.temp_allocator) or_continue
		d := Library_Disc {
			id   = r.id,
			info = info_load(core.disc_path(dir, .Info, context.temp_allocator)),
		}
		fi, serr := os.stat(r.path, context.temp_allocator)
		if serr != nil {
			d.missing = true
		} else if !info_current(d.info, r.path, fi) {
			if id, info, scanned := disc_record(r.path, fi); scanned {
				changed ||= id != r.id
				r.id, d.id, d.info = id, id, info
			} else {
				d.missing = true
			}
		}
		d.info[.Path] = r.path
		d.compat = compat[d.id]
		append(&discs, library_disc_clone(d, allocator))
	}
	if changed {
		index_write(index, rows[:]) or_return
	}
	return discs, true
}

// Add the disc image at path, or each one in the directory at path as
// play --compat finds them, to the library: a row for each new path, the
// row of a path already there made its disc's again. The number added and
// the number skipped; false, after a message, without a data directory or
// when library.tsv cannot be written. A file that is not a disc with an
// executable, or whose path holds a tab or a line break, is skipped after a
// message.
library_add :: proc(path: string) -> (added, skipped: int, ok: bool) {
	context.allocator = context.temp_allocator
	data := core.data_dir() or_return
	abs := library_path(path)
	if !os.exists(abs) {
		fmt.eprintln("play: cannot find", path)
		return
	}
	index := library_index(data)
	rows := index_read(index)
	for image in compat_images(abs) {
		if strings.contains_any(image, "\t\r\n") {
			fmt.eprintln("play: a tab or line break in its path keeps", image, "out of the library")
			skipped += 1
			continue
		}
		fi, serr := os.stat(image, context.temp_allocator)
		if serr != nil {
			fmt.eprintln("play: cannot read", image, serr)
			skipped += 1
			continue
		}
		id, _, is_disc := disc_record(image, fi)
		if !is_disc {
			skipped += 1
			continue
		}
		put := false
		for &r in rows {
			if r.path == image {
				r.id, put = id, true
			}
		}
		if !put {
			append(&rows, Index_Row{image, id})
		}
		added += 1
	}
	index_write(index, rows[:]) or_return
	return added, skipped, true
}

// Take the image at path out of the library; its disc's directory, saves
// and all, stays. False, after a message, without a data directory or when
// library.tsv cannot be written.
library_remove :: proc(path: string) -> bool {
	data := core.data_dir(context.temp_allocator) or_return
	index := library_index(data)
	rows := index_read(index)
	p := library_path(path)
	n := 0
	for r in rows {
		if r.path != p {
			rows[n] = r
			n += 1
		}
	}
	return index_write(index, rows[:n])
}

// The path as library.tsv keeps it, in temp memory: absolute with every
// symlink resolved, so one file has one spelling however it is named (a
// macOS temp directory is under the /var symlink). A file that is gone has
// its directory resolved instead, and a path whose directory is gone too
// is taken as it is, so a missing image is still found by its stored path.
@(private)
library_path :: proc(path: string) -> string {
	if abs, err := filepath.abs(path, context.temp_allocator); err == nil {
		return abs
	}
	dir, file := filepath.split(path)
	if abs, err := filepath.abs(dir, context.temp_allocator); err == nil {
		joined, _ := filepath.join({abs, file}, context.temp_allocator)
		return joined
	}
	return path
}

@(private = "file")
library_index :: proc(data: string) -> string {
	path, _ := filepath.join({data, "library.tsv"}, context.temp_allocator)
	return path
}

// library.tsv's rows, in temp memory; a row with no tab or an empty field,
// or a path already read, is skipped.
@(private = "file")
index_read :: proc(path: string) -> [dynamic]Index_Row {
	rows := make([dynamic]Index_Row, context.temp_allocator)
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return rows
	}
	rest := string(text)
	outer: for line in strings.split_lines_iterator(&rest) {
		p, tab, id := strings.partition(strings.trim_right(line, "\r"), "\t")
		if tab == "" || p == "" || id == "" {
			continue
		}
		for r in rows {
			if r.path == p {
				continue outer
			}
		}
		append(&rows, Index_Row{p, id})
	}
	return rows
}

// Write library.tsv whole (tmp + rename). False, after a message, on a
// failure.
@(private = "file")
index_write :: proc(path: string, rows: []Index_Row) -> bool {
	b := strings.builder_make(context.temp_allocator)
	for r in rows {
		fmt.sbprintf(&b, "%s\t%s\n", r.path, r.id)
	}
	if err := core.write_file_atomic(path, b.buf[:]); err != nil {
		fmt.eprintln("play: cannot write", path, err)
		return false
	}
	return true
}

// Scan the image at path (fi its file info) and write its disc's disc.tsv,
// keeping the title there. The disc id and the info, in temp memory; false,
// after a message, when it is not a disc with an executable or its
// directory cannot be made. A disc.tsv that cannot be written is only
// reported: the next load scans the image again.
@(private)
disc_record :: proc(path: string, fi: os.File_Info) -> (id: string, info: [Info]string, ok: bool) {
	d, opened := disc.open(path, context.temp_allocator)
	if !opened {
		fmt.eprintln("play:", path, "is not a disc image")
		return
	}
	defer disc.close(&d)
	if id, ok = disc.id(&d, context.temp_allocator); !ok {
		fmt.eprintln("play:", path, "has no executable to run")
		return
	}
	cnf, _ := disc.system_cnf(&d, context.temp_allocator)
	info[.Path] = path
	info[.Size] = fmt.tprint(fi.size)
	info[.Mtime] = fmt.tprint(time.to_unix_nanoseconds(fi.modification_time))
	info[.Serial] = cnf.serial
	info[.Label] = disc.volume_label(&d, context.temp_allocator)
	info[.System] = "ps2" if cnf.ps2 else "ps1"
	dir := core.disc_dir(id, context.temp_allocator) or_return
	file := core.disc_path(dir, .Info, context.temp_allocator)
	info[.Title] = info_load(file)[.Title]
	if info[.Title] == "" {
		info[.Title] = info[.Label]
	}
	info_save(file, info)
	return id, info, true
}

// Whether info was scanned from the image at path as fi finds it.
@(private = "file")
info_current :: proc(info: [Info]string, path: string, fi: os.File_Info) -> bool {
	return(
		info[.Path] == path &&
		info[.Size] == fmt.tprint(fi.size) &&
		info[.Mtime] == fmt.tprint(time.to_unix_nanoseconds(fi.modification_time)) \
	)
}

// The disc.tsv at path, in temp memory; all "" when it is missing. Rows of
// other names are skipped, and of two rows with one name the first counts.
@(private = "file")
info_load :: proc(path: string) -> (info: [Info]string) {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	names := INFO_NAMES
	got: bit_set[Info]
	rest := string(text)
	for line in strings.split_lines_iterator(&rest) {
		name, tab, value := strings.partition(strings.trim_right(line, "\r"), "\t")
		if tab == "" {
			continue
		}
		for n, k in names {
			if n == name && k not_in got {
				info[k] = value
				got += {k}
			}
		}
	}
	return
}

// Write a disc.tsv whole (tmp + rename), tabs and line breaks in its values
// made spaces. Only reported on a failure.
@(private = "file")
info_save :: proc(path: string, info: [Info]string) {
	names := INFO_NAMES
	b := strings.builder_make(context.temp_allocator)
	for v, k in info {
		strings.write_string(&b, names[k])
		strings.write_byte(&b, '\t')
		for r in v {
			strings.write_rune(&b, ' ' if r == '\t' || r == '\n' || r == '\r' else r)
		}
		strings.write_byte(&b, '\n')
	}
	if err := core.write_file_atomic(path, b.buf[:]); err != nil {
		fmt.eprintln("play: cannot write", path, err)
	}
}

// compat.tsv's rows by disc id, in temp memory, each column found by its
// header name: a file from before columns were added reads with them "".
// None when it is missing.
@(private)
compat_rows :: proc(path: string) -> map[string]Row {
	rows := make(map[string]Row, context.temp_allocator)
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return rows
	}
	rest := string(text)
	first, _ := strings.split_lines_iterator(&rest)
	header := strings.split(first, "\t", context.temp_allocator)
	cols := make([]Maybe(Column), len(header), context.temp_allocator)
	names := COLUMNS
	for h, i in header {
		for n, c in names {
			if n == h {
				cols[i] = c
			}
		}
	}
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) != len(header) {
			continue
		}
		row: Row
		for f, i in fields {
			if c, named := cols[i].?; named {
				row[c] = f
			}
		}
		if row[.Id] != "" {
			rows[row[.Id]] = row
		}
	}
	return rows
}

@(private = "file")
library_disc_clone :: proc(d: Library_Disc, allocator := context.allocator) -> (c: Library_Disc) {
	c.id = strings.clone(d.id, allocator)
	c.missing = d.missing
	for v, k in d.info {
		c.info[k] = strings.clone(v, allocator)
	}
	for v, k in d.compat {
		c.compat[k] = strings.clone(v, allocator)
	}
	return
}
