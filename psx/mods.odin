// Loading a game's mods: each subdirectory of the mods directory that has
// a mod.tsv is a mod, its code in mod.elf beside it. An optional mods.tsv
// in the mods directory lists mod ids, one a line, in the order the user
// wants them (core.mod_order keeps it where dependencies allow).
package psx

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "ps:core"
import cpu "cpu"

// Load the mods in dir into the mod region and install their hooks, after
// every other hook. disc is the running disc's id; a mod whose `disc` is
// neither it nor its serial (the id up to the first `.`) gets a warning
// and loads anyway. A missing dir is no mods. False, after a message, on
// any error; then no mod is loaded.
mods_load :: proc(dir, disc: string) -> bool {
	if dir == "" || !os.is_dir(dir) {return true}
	err := mods_load_dir(dir, disc)
	if err != "" {
		fmt.eprintln(err)
		cpu.mod_ram_free()
		return false
	}
	return true
}

@(private = "file")
mods_load_dir :: proc(dir, disc: string) -> (err: string) {
	entries, derr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if derr != nil {return fmt.tprintf("mod: cannot read %s: %v", dir, derr)}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

	// Manifests and chains outlive the machine: the default allocator.
	mods := make([dynamic]core.Mod_Manifest)
	where_ := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.type != .Directory {continue}
		path, _ := filepath.join({e.fullpath, "mod.tsv"}, context.temp_allocator)
		text, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr == .Not_Exist {continue}
		if rerr != nil {return fmt.tprintf("mod: cannot read %s: %v", path, rerr)}
		m, merr := core.mod_manifest_parse(string(text))
		if merr != "" {return fmt.tprintf("%s: %s", path, merr)}
		if m.disc != "" && m.disc != disc && m.disc != strings.split_n(disc, ".", 2, context.temp_allocator)[0] {
			fmt.eprintfln("mod %s: made for disc %s, this is %s", m.id, m.disc, disc)
		}
		append(&mods, m)
		append(&where_, e.fullpath)
	}
	if len(mods) == 0 {return ""}

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
		return fmt.tprintf("mod: cannot read %s: %v", list, rerr)
	}
	order, oerr := core.mod_order(mods[:], user)
	if oerr != "" {return oerr}

	images := make([]core.Mod_Image, len(mods), context.temp_allocator)
	who := make([]string, len(mods), context.temp_allocator)
	hooks := make([dynamic]core.Mod_Hook, context.temp_allocator)
	for m, k in mods {
		path, _ := filepath.join({where_[k], "mod.elf"}, context.temp_allocator)
		elf, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil {return fmt.tprintf("mod %s: cannot read %s: %v", m.id, path, rerr)}
		img, ierr := core.mod_elf_read(elf, cpu.MOD_BASE, cpu.MOD_BASE + cpu.MOD_REGION, k, context.temp_allocator)
		if ierr != "" {return fmt.tprintf("mod %s: %s: %s", m.id, path, ierr)}
		images[k], who[k] = img, m.id
		append(&hooks, ..img.hooks)
	}
	if e := cpu.mod_ram_load(images, who); e != "" {return e}
	chains, cerr := core.mod_chains(mods[:], order, hooks[:])
	if cerr != "" {return cerr}
	return cpu.mod_install(mods[:], chains)
}
