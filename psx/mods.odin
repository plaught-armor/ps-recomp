// Loading a game's mods (core/mod_dir.odin) into the mod region, with
// their hooks, and the native code play compiled for their functions.
package psx

import "core:fmt"
import "core:mem"
import "ps:core"
import cpu "cpu"
@(require) import native "native" // used only without FLAT

// The mods in dir (core.mods_read), read for this console's mod region.
mods_read :: proc(dir, disc: string) -> (set: core.Mod_Set, err: string) {
	return core.mods_read(dir, disc, cpu.MOD_BASE, cpu.MOD_BASE + cpu.MOD_REGION)
}

// Where the set mods_identify read keeps its temporary parts (its images,
// hooks and order) until mods_load has installed it.
@(private = "file")
mods_arena: mem.Dynamic_Arena
@(private = "file")
mods_held: bool

// Read the mods in dir, note them as this run's set (core.run_mods), print
// it and return it for mods_load to install: the directory is read once.
// disc is the running disc's id (core.mods_read). psx.run calls it before
// host.platform_init opens the input record, which carries the set. A
// missing dir is no mods. False, after a message, when the directory does
// not read.
mods_identify :: proc(dir, disc: string) -> (set: core.Mod_Set, ok: bool) {
	mods_free()
	mem.dynamic_arena_init(&mods_arena)
	mods_held = true
	err: string
	{
		context.temp_allocator = mem.dynamic_arena_allocator(&mods_arena)
		set, err = mods_read(dir, disc)
	}
	if err != "" {
		fmt.eprintln(err)
		core.mod_set_delete(set)
		mods_free()
		return {}, false
	}
	core.mods_note(set, "psx")
	return set, true
}

// Load the set mods_identify read into the mod region and install their
// hooks, after every other hook. False, after a message, on any error; then
// no mod is loaded. blob is the mods' native code ("" none;
// native.load_mods): when it cannot be used, failed is called (nil none),
// and the mods are interpreted.
mods_load :: proc(set: core.Mod_Set, blob := "", failed: proc() = nil) -> bool {
	defer mods_free()
	if err := mods_install(set); err != "" {
		fmt.eprintln(err)
		core.mod_set_delete(set)
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
mods_install :: proc(set: core.Mod_Set) -> (err: string) {
	if len(set.mods) == 0 {return}
	who := make([]string, len(set.mods), context.temp_allocator)
	for m, k in set.mods {who[k] = m.id}
	if err = cpu.mod_ram_load(set.images, who); err != "" {return}
	chains: []core.Mod_Chain
	if chains, err = core.mod_chains(set.mods, set.order, set.hooks); err != "" {return}
	return cpu.mod_install(set.mods, chains)
}

// Free what mods_identify keeps for mods_load.
@(private = "file")
mods_free :: proc() {
	if mods_held {mem.dynamic_arena_destroy(&mods_arena)}
	mods_held = false
}
