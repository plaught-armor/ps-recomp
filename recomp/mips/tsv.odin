package mips

import "core:strings"

// A tab-separated table: a header row naming the columns, then one row per
// line. Blank lines and lines starting with `#` are skipped.
Table :: struct {
	path:    string,
	columns: []string,
	rows:    [][]string,
}

load_table :: proc(path: string, required: ..string) -> Table {
	t := Table {
		path = path,
	}
	rows: [dynamic][]string
	for l, n in strings.split_lines(string(read_file(path))) {
		if l == "" || l[0] == '#' {
			continue
		}
		cells := strings.split(strings.trim_right(l, "\r"), "\t")
		if t.columns == nil {
			t.columns = cells
			continue
		}
		if len(cells) != len(t.columns) {
			fail("%s:%d: %d columns, the header has %d", path, n + 1, len(cells), len(t.columns))
		}
		append(&rows, cells)
	}
	t.rows = rows[:]
	for c in required {
		if column(t, c) < 0 {
			fail("%s: no %s column", path, c)
		}
	}
	return t
}

// The index of a column, or -1.
column :: proc(t: Table, name: string) -> int {
	for c, i in t.columns {
		if c == name {
			return i
		}
	}
	return -1
}

// The cell of a row in a named column, "" when the table has none.
cell :: proc(t: Table, row: []string, name: string) -> string {
	i := column(t, name)
	return i < 0 ? "" : row[i]
}

// A recompiler options file: a `key value` table.
Options :: struct {
	path:   string,
	values: map[string]string,
}

load_options :: proc(path: string) -> Options {
	t := load_table(path, "key", "value")
	o := Options {
		path = path,
	}
	for r in t.rows {
		o.values[cell(t, r, "key")] = cell(t, r, "value")
	}
	return o
}

// A required option.
option :: proc(o: Options, key: string) -> string {
	v, ok := o.values[key]
	if !ok {
		fail("%s: no %s option", o.path, key)
	}
	return v
}

option_or :: proc(o: Options, key, default: string) -> string {
	return o.values[key] or_else default
}
