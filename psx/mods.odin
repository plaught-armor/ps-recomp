// Loading a game's mods (core/mod_dir.odin) into the mod region, with
// their hooks, and the native code play compiled for their functions.
package psx

import "core:fmt"
import "ps:core"
import cpu "cpu"
@(require) import native "native" // used only without FLAT

// The mods in dir (core.mods_read), read for this console's mod region.
mods_read :: proc(dir, disc: string) -> (set: core.Mod_Set, err: string) {
	return core.mods_read(dir, disc, cpu.MOD_BASE, cpu.MOD_BASE + cpu.MOD_REGION)
}

// Load the mods in dir into the mod region and install their hooks, after
// every other hook. disc is the running disc's id (core.mods_read). A
// missing dir is no mods. False, after a message, on any error; then no mod
// is loaded. blob is the mods' native code ("" none; native.load_mods):
// when it cannot be used, failed is called (nil none), and the mods are
// interpreted.
mods_load :: proc(dir, disc: string, blob := "", failed: proc() = nil) -> bool {
	err := mods_load_dir(dir, disc)
	if err != "" {
		fmt.eprintln(err)
		cpu.mod_ram_free()
		return false
	}
	// Under FLAT there is no native code (Boot's check refuses a blob).
	when !core.FLAT {
		if blob != "" && cpu.mod_ram != nil && !native.load_mods(blob) && failed != nil {
			failed()
		}
	}
	return true
}

@(private = "file")
mods_load_dir :: proc(dir, disc: string) -> (err: string) {
	set: core.Mod_Set
	// On an error no mod is loaded, and the manifests are freed here.
	defer if err != "" {core.mod_set_delete(set)}
	if set, err = mods_read(dir, disc); err != "" || len(set.mods) == 0 {return}
	who := make([]string, len(set.mods), context.temp_allocator)
	for m, k in set.mods {who[k] = m.id}
	if err = cpu.mod_ram_load(set.images, who); err != "" {return}
	chains: []core.Mod_Chain
	if chains, err = core.mod_chains(set.mods, set.order, set.hooks); err != "" {return}
	return cpu.mod_install(set.mods, chains)
}
