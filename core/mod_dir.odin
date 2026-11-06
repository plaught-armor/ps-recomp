// A game's mods directory, read: each subdirectory of it that has a
// mod.tsv is a mod, its code in mod.elf beside it. An optional mods.tsv in
// the mods directory lists mod ids, one a line, in the order the user wants
// them (mod_order keeps it where dependencies allow). The console loads the
// set (psx/mods.odin); play compiles its functions and keys the blob by
// mod_set_hash.
package core

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The mods of a directory, k indexing each in directory order: the
// manifests (in the default allocator, as they outlive the machine), the
// load order (indices into mods), and each mod's mod.tsv and mod.elf bytes
// and image, temp allocated. hooks holds every image's, the mod of each
// its k.
Mod_Set :: struct {
	mods:      []Mod_Manifest,
	order:     []int,
	tsv, elf:  [][]u8,
	images:    []Mod_Image,
	hooks:     []Mod_Hook,
}

// The mods in dir, each image inside [lo, hi) (physical). disc is the
// running disc's id: a mod whose `disc` is neither it nor its serial (the
// id up to the first `.`) gets a warning, and is read all the same; ""
// warns of none. A missing dir is no mods. err is in the temp allocator.
mods_read :: proc(dir, disc: string, lo, hi: u32) -> (set: Mod_Set, err: string) {
	if dir == "" || !os.is_dir(dir) {return}
	entries, derr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if derr != nil {return {}, fmt.tprintf("mod: cannot read %s: %v", dir, derr)}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

	mods := make([dynamic]Mod_Manifest)
	// Freed here until set holds them.
	defer if set.mods == nil {
		for m in mods {mod_manifest_delete(m)}
		delete(mods)
	}
	tsv := make([dynamic][]u8, context.temp_allocator)
	where_ := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.type != .Directory {continue}
		path, _ := filepath.join({e.fullpath, "mod.tsv"}, context.temp_allocator)
		text, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr == .Not_Exist {continue}
		if rerr != nil {return {}, fmt.tprintf("mod: cannot read %s: %v", path, rerr)}
		m, merr := mod_manifest_parse(string(text))
		if merr != "" {return {}, fmt.tprintf("%s: %s", path, merr)}
		if disc != "" && m.disc != "" && m.disc != disc && m.disc != strings.split_n(disc, ".", 2, context.temp_allocator)[0] {
			fmt.eprintfln("mod %s: made for disc %s, this is %s", m.id, m.disc, disc)
		}
		append(&mods, m)
		append(&tsv, text)
		append(&where_, e.fullpath)
	}
	if len(mods) == 0 {return}
	set.mods, set.tsv = mods[:], tsv[:]

	user: []string
	list, _ := filepath.join({dir, "mods.tsv"}, context.temp_allocator)
	if text, rerr := os.read_entire_file(list, context.temp_allocator); rerr == nil {
		ids := make([dynamic]string, context.temp_allocator)
		rest := string(text)
		for line in strings.split_lines_iterator(&rest) {
			l := strings.trim_space(line)
			if l != "" && l[0] != '#' {append(&ids, l)}
		}
		user = ids[:]
	} else if rerr != .Not_Exist {
		return set, fmt.tprintf("mod: cannot read %s: %v", list, rerr)
	}
	oerr: string
	set.order, oerr = mod_order(set.mods, user, context.temp_allocator)
	if oerr != "" {return set, oerr}

	set.elf = make([][]u8, len(mods), context.temp_allocator)
	set.images = make([]Mod_Image, len(mods), context.temp_allocator)
	hooks := make([dynamic]Mod_Hook, context.temp_allocator)
	for m, k in set.mods {
		path, _ := filepath.join({where_[k], "mod.elf"}, context.temp_allocator)
		elf, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil {return set, fmt.tprintf("mod %s: cannot read %s: %v", m.id, path, rerr)}
		img, ierr := mod_elf_read(elf, lo, hi, k, context.temp_allocator)
		if ierr != "" {return set, fmt.tprintf("mod %s: %s: %s", m.id, path, ierr)}
		set.elf[k], set.images[k] = elf, img
		append(&hooks, ..img.hooks)
	}
	set.hooks = hooks[:]
	return set, ""
}

// The mod set's hash: XXH3-64 over MOD_API, then for each mod in load
// order its id, mod.tsv and mod.elf, each length-prefixed. The mods blob's
// key names it, so any edit, an added or removed mod, or another order
// compiles the blob again.
mod_set_hash :: proc(set: Mod_Set) -> u64 {
	state: xxhash.XXH3_state
	xxhash.XXH3_init_state(&state)
	_ = xxhash.XXH3_64_reset(&state)
	put :: proc(state: ^xxhash.XXH3_state, b: []u8) {
		n := u32le(len(b))
		_ = xxhash.XXH3_64_update(state, ([^]u8)(&n)[:4])
		if len(b) > 0 {_ = xxhash.XXH3_64_update(state, b)}
	}
	api := u32le(MOD_API)
	_ = xxhash.XXH3_64_update(&state, ([^]u8)(&api)[:4])
	for k in set.order {
		put(&state, transmute([]u8)set.mods[k].id)
		put(&state, set.tsv[k])
		put(&state, set.elf[k])
	}
	return xxhash.XXH3_64_digest(&state)
}

// The hooked set's hash: XXH3-64 over the sorted unique addresses the hooks
// name, as u32 little endian; 0 for none. Recompiled EE code built for a
// hooked set (recomp option mod_hooks) carries the same hash
// (recomp/mips/mod_hooks.odin: tests/mod pins both), and the runtime
// refuses code built for another set.
mod_hooks_hash :: proc(hooks: []Mod_Hook) -> u64 {
	addrs := make([]u32, len(hooks), context.temp_allocator)
	for h, k in hooks {addrs[k] = h.key.addr}
	slice.sort(addrs)
	n := len(slice.unique(addrs))
	if n == 0 {return 0}
	b := make([]u8, 4 * n, context.temp_allocator)
	for a, k in addrs[:n] {
		for i in 0 ..< 4 {b[4 * k + i] = u8(a >> (8 * uint(i)))}
	}
	return xxhash.XXH3_64_default(b)
}

// Free what mods_read gave set in the default allocator (its manifests),
// for a set not loaded.
mod_set_delete :: proc(set: Mod_Set) {
	for m in set.mods {mod_manifest_delete(m)}
	delete(set.mods)
}
