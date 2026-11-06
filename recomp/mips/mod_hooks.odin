package mips

import "core:hash/xxhash"
import "core:slice"
import "core:strings"

// The hooked set: the addresses of the functions a mod set hooks, which
// recompiled code must call through the call table (where the runtime puts
// a hook's thunk) instead of directly. Read from the file the recomp option
// mod_hooks names: one hex address per line, blank lines and text after a #
// ignored. No option: empty, hash 0. The hash is mod_hooks_hash of the set;
// the runtime computes the same for the mods it loads (core/mod.odin) and
// refuses code built for another set.
read_mod_hooks :: proc(o: Options) -> (set: Set, hash: u64) {
	path := option_or(o, "mod_hooks", "")
	if path == "" {return}
	addrs: [dynamic]u32
	text := string(read_file(path))
	for line in strings.split_lines_iterator(&text) {
		s := line
		if k := strings.index_byte(s, '#'); k >= 0 {s = s[:k]}
		s = strings.trim_space(s)
		if s == "" {continue}
		a := parse_hex(s)
		if a % 4 != 0 {fail("%s: hooked address %08x is not word aligned", path, a)}
		append(&addrs, a)
		set[a] = {}
	}
	return set, mod_hooks_hash(addrs[:])
}

// XXH3-64 over the sorted unique addresses as u32 little endian; 0 for
// none. Sorts addrs. core/mod.odin holds the same; tests/mod pins both.
mod_hooks_hash :: proc(addrs: []u32) -> u64 {
	slice.sort(addrs)
	n := len(slice.unique(addrs))
	if n == 0 {return 0}
	b := make([]u8, 4 * n, context.temp_allocator)
	for a, k in addrs[:n] {
		for i in 0 ..< 4 {b[4 * k + i] = u8(a >> (8 * uint(i)))}
	}
	return xxhash.XXH3_64_default(b)
}
