// Mods, as data: a mod's manifest (mod.tsv), the order mods load in, and
// the hook chains their hooks make. Nothing here touches a running game;
// the consoles install the chains (psx, ps2) and run them.
//
// A hook names a guest function by Mod_Key and runs a mod function before
// it, after it, or in its place. Before hooks run in load order and after
// hooks in reverse load order, so the first mod loaded wraps the others. A
// function has at most one replacement: a second is a load error.
package core

import "core:fmt"
import "core:slice"
import "core:strings"

// The mod API this runtime has; a manifest's `api` must equal it.
MOD_API :: 1

// Longest mod id, and the most mods one game loads.
MOD_ID_MAX :: 64
MOD_MAX :: 256

// major.minor.patch
Mod_Version :: [3]u32

// A dependency: a mod with this id, at least version min.
Mod_Dep :: struct {
	id:  string,
	min: Mod_Version,
}

// A mod.tsv. `before` and `after` name mods this one loads before or after
// when they are loaded too; a dependency always loads first.
Mod_Manifest :: struct {
	id, name, game, disc, files: string,
	version:                     Mod_Version,
	api:                         u32,
	deps:                        []Mod_Dep,
	before, after:               []string,
}

// A guest function. PS1: the overlay at `slot` whose first word is `id`,
// or slot = id = 0 for the executable. EE: slot 0 and id the program's.
Mod_Key :: struct {
	slot, id, addr: u32,
}

Mod_Hook_Kind :: enum u8 {
	Before,
	After,
	Replace,
}

// One hook from a mod: mod indexes the manifests, fn is the mod function's
// guest address.
Mod_Hook :: struct {
	key:  Mod_Key,
	kind: Mod_Hook_Kind,
	mod:  int,
	fn:   u32,
}

Mod_Fn :: struct {
	mod: int,
	fn:  u32,
}

// Everything that hooks one function, in the order it runs.
Mod_Chain :: struct {
	key:           Mod_Key,
	before, after: []Mod_Fn,
	replace:       Maybe(Mod_Fn),
}

@(private = "file")
MOD_KEYS :: [?]string{"id", "version", "api", "name", "game", "disc", "deps", "before", "after", "files"}

// The manifest in a mod.tsv's text: one `key<tab>value` per line, blank
// lines and lines starting with # skipped. id, version and api are
// required; an unknown or repeated key is an error. Strings live in
// `allocator`; err is in the temp allocator.
mod_manifest_parse :: proc(text: string, allocator := context.allocator) -> (m: Mod_Manifest, err: string) {
	keys := MOD_KEYS
	seen: bit_set[0 ..< len(MOD_KEYS)]
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_right(line, "\r")
		if l == "" || l[0] == '#' {continue}
		key, tab, value := strings.partition(l, "\t")
		k, found := slice.linear_search(keys[:], key)
		if tab == "" || !found {return m, fmt.tprintf("mod.tsv: bad line %q", l)}
		if k in seen {return m, fmt.tprintf("mod.tsv: %s twice", key)}
		seen += {k}
		if e := mod_manifest_set(&m, key, value, allocator); e != "" {return m, e}
	}
	for need in ([]string{"id", "version", "api"}) {
		k, _ := slice.linear_search(keys[:], need)
		if k not_in seen {return m, fmt.tprintf("mod.tsv: no %s", need)}
	}
	return m, ""
}

@(private = "file")
mod_manifest_set :: proc(m: ^Mod_Manifest, key, value: string, allocator := context.allocator) -> (err: string) {
	ok := true
	switch key {
	case "id":
		m.id = strings.clone(value, allocator)
		ok = mod_id_ok(value)
	case "version":
		m.version, ok = mod_version_parse(value)
	case "api":
		v: Mod_Version
		v, ok = mod_version_parse(value, 1)
		m.api = v[0]
	case "name":
		m.name = strings.clone(value, allocator)
	case "game":
		m.game = strings.clone(value, allocator)
	case "disc":
		m.disc = strings.clone(value, allocator)
	case "files":
		m.files = strings.clone(value, allocator)
	case "deps":
		m.deps, ok = mod_deps_parse(value, allocator)
	case "before":
		m.before, ok = mod_ids_parse(value, allocator)
	case "after":
		m.after, ok = mod_ids_parse(value, allocator)
	}
	if !ok {return fmt.tprintf("mod.tsv: bad %s %q", key, value)}
	return ""
}

// A mod id: 1 to MOD_ID_MAX of a-z, 0-9, '_', '-', '.', not starting
// with '.'.
mod_id_ok :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > MOD_ID_MAX || id[0] == '.' {return false}
	for c in transmute([]u8)id {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c == '.') {return false}
	}
	return true
}

// `parts` decimal numbers joined by '.', each below 2^32.
mod_version_parse :: proc(s: string, parts := 3) -> (v: Mod_Version, ok: bool) {
	assert(parts >= 1 && parts <= 3)
	rest := s
	for k in 0 ..< parts {
		field: string
		if k == parts - 1 {
			field, rest = rest, ""
		} else {
			dot := strings.index_byte(rest, '.')
			if dot < 0 {return v, false}
			field, rest = rest[:dot], rest[dot + 1:]
		}
		if len(field) == 0 || len(field) > 10 {return v, false}
		n: u64
		for c in transmute([]u8)field {
			if c < '0' || c > '9' {return v, false}
			n = n * 10 + u64(c - '0')
		}
		if n > u64(max(u32)) {return v, false}
		v[k] = u32(n)
	}
	return v, true
}

mod_version_less :: proc(a, b: Mod_Version) -> bool {
	for k in 0 ..< 3 {
		if a[k] != b[k] {return a[k] < b[k]}
	}
	return false
}

// "id" or "id>=1.2.3", comma separated.
@(private = "file")
mod_deps_parse :: proc(s: string, allocator := context.allocator) -> (deps: []Mod_Dep, ok: bool) {
	parts := strings.split(s, ",", context.temp_allocator)
	deps = make([]Mod_Dep, len(parts), allocator)
	for p, k in parts {
		id, op, ver := strings.partition(strings.trim_space(p), ">=")
		if !mod_id_ok(id) {return deps, false}
		deps[k].id = strings.clone(id, allocator)
		if op != "" {deps[k].min = mod_version_parse(ver) or_return}
	}
	return deps, true
}

@(private = "file")
mod_ids_parse :: proc(s: string, allocator := context.allocator) -> (ids: []string, ok: bool) {
	parts := strings.split(s, ",", context.temp_allocator)
	ids = make([]string, len(parts), allocator)
	for p, k in parts {
		id := strings.trim_space(p)
		if !mod_id_ok(id) {return ids, false}
		ids[k] = strings.clone(id, allocator)
	}
	return ids, true
}

// The order mods load in, as indexes into mods: every dependency before the
// mods needing it, before/after hints kept, and otherwise the user's order
// (ids in `user`), then the rest by id. An error names what is wrong: two
// mods with one id, a wrong api, a dependency missing or too old, or a
// cycle. order is in `allocator`, err in the temp allocator.
mod_order :: proc(mods: []Mod_Manifest, user: []string, allocator := context.allocator) -> (order: []int, err: string) {
	if len(mods) > MOD_MAX {return nil, fmt.tprintf("mod: %d mods, at most %d load", len(mods), MOD_MAX)}
	index := make(map[string]int, len(mods), context.temp_allocator)
	for m, k in mods {
		if m.id in index {return nil, fmt.tprintf("mod: two mods are %s", m.id)}
		if m.api != MOD_API {return nil, fmt.tprintf("mod %s: api %d, this runtime has %d", m.id, m.api, MOD_API)}
		index[m.id] = k
	}
	edges, e := mod_edges(mods, index)
	if e != "" {return nil, e}
	return mod_sort(mods, user, edges, allocator)
}

// Each edge [a, b]: mods[a] loads before mods[b].
@(private = "file")
mod_edges :: proc(mods: []Mod_Manifest, index: map[string]int) -> (edges: [dynamic][2]int, err: string) {
	edges = make([dynamic][2]int, context.temp_allocator)
	for m, k in mods {
		for d in m.deps {
			j, ok := index[d.id]
			if !ok {return edges, fmt.tprintf("mod %s needs %s, which is not loaded", m.id, d.id)}
			if mod_version_less(mods[j].version, d.min) {
				v := mods[j].version
				return edges, fmt.tprintf("mod %s needs %s %d.%d.%d, loaded is %d.%d.%d", m.id, d.id, d.min[0], d.min[1], d.min[2], v[0], v[1], v[2])
			}
			append(&edges, [2]int{j, k})
		}
		for id in m.after {
			if j, ok := index[id]; ok {append(&edges, [2]int{j, k})}
		}
		for id in m.before {
			if j, ok := index[id]; ok {append(&edges, [2]int{k, j})}
		}
	}
	return edges, ""
}

// Kahn's sort: each round loads the ready mod (nothing left to load before
// it) that comes first by user position, then id.
@(private = "file")
mod_sort :: proc(mods: []Mod_Manifest, user: []string, edges: [dynamic][2]int, allocator := context.allocator) -> (order: []int, err: string) {
	n := len(mods)
	pos := make([]int, n, context.temp_allocator)
	for m, k in mods {
		p, found := slice.linear_search(user, m.id)
		pos[k] = found ? p : len(user)
	}
	waits := make([]int, n, context.temp_allocator)
	for e in edges {waits[e[1]] += 1}
	done := make([]bool, n, context.temp_allocator)
	order = make([]int, n, allocator)
	for round in 0 ..< n {
		pick := -1
		for k in 0 ..< n {
			if done[k] || waits[k] != 0 {continue}
			if pick < 0 || pos[k] < pos[pick] || (pos[k] == pos[pick] && mods[k].id < mods[pick].id) {pick = k}
		}
		if pick < 0 {
			delete(order, allocator)
			return nil, mod_cycle(mods, done)
		}
		order[round], done[pick] = pick, true
		for e in edges {
			if e[0] == pick {waits[e[1]] -= 1}
		}
	}
	return order, ""
}

@(private = "file")
mod_cycle :: proc(mods: []Mod_Manifest, done: []bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	for m, k in mods {
		if done[k] {continue}
		if strings.builder_len(b) != 0 {strings.write_string(&b, ", ")}
		strings.write_string(&b, m.id)
	}
	return fmt.tprintf("mod: %s wait on each other (dependency or before/after cycle)", strings.to_string(b))
}

// The chain of each hooked function, ordered by key, from the hooks of the
// mods in `order` (mod_order). An error names the two mods replacing one
// function, or a hook whose mod is not in the order. Chains and their
// slices are in `allocator` (mod_chains_delete), err in the temp allocator.
mod_chains :: proc(mods: []Mod_Manifest, order: []int, hooks: []Mod_Hook, allocator := context.allocator) -> (chains: []Mod_Chain, err: string) {
	rank := make([]int, len(mods), context.temp_allocator)
	slice.fill(rank, -1)
	for m, k in order {rank[m] = k}
	for h in hooks {
		if h.mod < 0 || h.mod >= len(mods) || rank[h.mod] < 0 {
			return nil, fmt.tprintf("mod: a hook on %08x is from no loaded mod", h.key.addr)
		}
	}
	Ranked :: struct {
		hook: Mod_Hook,
		rank: int,
	}
	sorted := make([]Ranked, len(hooks), context.temp_allocator)
	for h, k in hooks {sorted[k] = {h, rank[h.mod]}}
	slice.stable_sort_by(sorted, proc(a, b: Ranked) -> bool {
		if a.hook.key != b.hook.key {return mod_key_less(a.hook.key, b.hook.key)}
		return a.rank < b.rank
	})
	out := make([dynamic]Mod_Chain, allocator)
	for start := 0; start < len(sorted); {
		end := start + 1
		for end < len(sorted) && sorted[end].hook.key == sorted[start].hook.key {end += 1}
		group := make([]Mod_Hook, end - start, context.temp_allocator)
		for r, k in sorted[start:end] {group[k] = r.hook}
		c, e := mod_chain(mods, group, allocator)
		append(&out, c)
		if e != "" {
			chains = out[:]
			mod_chains_delete(chains, allocator)
			return nil, e
		}
		start = end
	}
	return out[:], ""
}

// One function's chain from its hooks, in load order.
@(private = "file")
mod_chain :: proc(mods: []Mod_Manifest, group: []Mod_Hook, allocator := context.allocator) -> (c: Mod_Chain, err: string) {
	n: [Mod_Hook_Kind]int
	for h in group {n[h.kind] += 1}
	c.key = group[0].key
	c.before = make([]Mod_Fn, n[.Before], allocator)
	c.after = make([]Mod_Fn, n[.After], allocator)
	b, a := 0, n[.After]
	for h in group {
		f := Mod_Fn{h.mod, h.fn}
		switch h.kind {
		case .Before:
			c.before[b] = f
			b += 1
		case .After:
			a -= 1
			c.after[a] = f
		case .Replace:
			if r, ok := c.replace.?; ok {
				return c, fmt.tprintf("mod: %s (%08x) and %s (%08x) both replace %08x (slot %08x id %08x)", mods[r.mod].id, r.fn, mods[h.mod].id, h.fn, c.key.addr, c.key.slot, c.key.id)
			}
			c.replace = f
		}
	}
	return c, ""
}

mod_key_less :: proc(a, b: Mod_Key) -> bool {
	if a.slot != b.slot {return a.slot < b.slot}
	if a.id != b.id {return a.id < b.id}
	return a.addr < b.addr
}

// Free what mod_chains returned.
mod_chains_delete :: proc(chains: []Mod_Chain, allocator := context.allocator) {
	for c in chains {
		delete(c.before, allocator)
		delete(c.after, allocator)
	}
	delete(chains, allocator)
}
