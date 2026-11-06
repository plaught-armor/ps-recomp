// Booting a PS2 game from its disc image with no generated package: the
// runtime set up in the order it needs, the functions taken from a native
// blob (or none, every function interpreted), and the ELF SYSTEM.CNF names
// run. The PS2 counterpart of psx.run; ports with a generated package keep
// their own main.
package ps2

import "core:fmt"

import "ps:core"
import cpu "cpu"
import host "host"
import iop "iop"
import kernel "kernel"
import mem "mem"
@(require) import psx_native "ps:psx/native" // used only without FLAT

// What boot needs.
Boot :: struct {
	// The path of the disc image (a .cue sheet, or a single-track .bin or
	// .iso).
	disc:           string,
	// The window's title.
	title:          cstring,
	// A native blob holding all the game's code ("" none: the functions
	// hooks registers run, every other one is interpreted). The boot stops
	// if it cannot be loaded.
	native:         string,
	// Called when the blob cannot be loaded, before boot returns false; nil
	// none.
	native_failed:  proc(),
	// A blob of the IOP's learned functions ("" none;
	// psx_native.load_learned), and what to call when it cannot be loaded
	// (nil none); the IOP then interprets them, and the boot goes on.
	learned:        string,
	learned_failed: proc(),
	// The same for the EE's learned functions (load_learned), which run where
	// no function is registered while RAM holds their code.
	learned_ee:        string,
	learned_ee_failed: proc(),
	// The directory the memory card directories go in (iop.mc_root); left
	// empty, the runtime's.
	cards:          string,
	// The port's own steps, each stopping the boot on false: `setup` before
	// the window opens, `hooks` once the game's functions are registered.
	setup:          proc() -> bool,
	hooks:          proc() -> bool,
	// The directory of the EE mods to load (ps2/mod.odin; "" or a missing
	// one none), and the disc's id, which a mod made for another disc is
	// warned of (core.mods_read). Code built for another hooked set than
	// the mods' (the recomp option mod_hooks) stops the boot.
	mods:           string,
	disc_id:        string,
	// Called at each vblank after the host's frame (kernel.vblank_hook), on
	// the EE thread where no microprogram runs; and when the host quits.
	// nil none.
	vblank:         proc(),
	quit:           proc(),
}

// Boot.vblank, and the host's vblank_hook it follows: taken once, after
// platform_init sets it, so nothing may assign kernel.vblank_hook after the
// boot, or Boot.vblank is dropped.
@(private = "file")
boot_vblank, host_vblank: proc()

@(private = "file")
vblank_chain :: proc() {
	host_vblank()
	boot_vblank()
}

// Set up the runtime for the game b describes and run the executable's
// entry. False when a step fails, with the reason printed; else it never
// returns.
boot :: proc(b: Boot) -> bool {
	iop.disc_image_open(b.disc) or_return
	name, argv0, found := iop.disc_boot()
	if !found {
		fmt.eprintln("disc: no PS2 executable named in SYSTEM.CNF")
		return false
	}
	elf, read := iop.disc_file(name)
	if !read {
		fmt.eprintln("disc: cannot read", name)
		return false
	}
	if b.cards != "" {iop.mc_root = b.cards}
	set, hooked, merr := mods_read(b.mods, b.disc_id)
	if merr != "" {
		fmt.eprintln(merr)
		return false
	}
	init()
	if b.setup != nil {b.setup() or_return}
	host.platform_init(b.title) or_return
	if b.vblank != nil {
		host_vblank, boot_vblank = kernel.vblank_hook, b.vblank
		kernel.vblank_hook = vblank_chain
	}
	host.quit_hook = b.quit
	// FLAT runs interpreted only (core/flat.odin): a thread switch inside
	// native code would leave its host frames running on.
	when core.FLAT {
		what := ""
		switch {
		case b.native != "": what = "native code (Boot.native)"
		case b.learned != "": what = "the IOP's learned code (Boot.learned)"
		case b.learned_ee != "": what = "the EE's learned code (Boot.learned_ee)"
		}
		if what != "" {cpu.fatal("FLAT runs interpreted only: %s not installed", what)}
	}
	// Under FLAT the loaders are not compiled in (the check above refuses
	// what they load), so a FLAT build refers to no map_code.
	when !core.FLAT {
		if b.native != "" {
			if !load_native(b.native, hooked) {
				if b.native_failed != nil {b.native_failed()}
				return false
			}
		}
		// After init, which makes the R3000 the IOP (iop.iop_cpu_init).
		if b.learned != "" && !psx_native.load_learned(b.learned) && b.learned_failed != nil {
			b.learned_failed()
		}
		if b.learned_ee != "" && !load_learned(b.learned_ee) && b.learned_ee_failed != nil {
			b.learned_ee_failed()
		}
	}
	if b.hooks != nil {b.hooks() or_return}
	// A blob's hooked set is checked as it loads; the registered Odin
	// functions' here. FLAT calls none of them.
	if !core.FLAT && b.native == "" {
		if e := mods_check(hooked); e != "" {
			fmt.eprintln(e)
			return false
		}
	}
	// Without a blob, a port's hooks register its recompiled functions
	// (text_range sizes their table); with neither, nothing is.
	if b.native == "" {
		if cpu.text_hi == 0 {
			fmt.eprintln("ps2: no native code, interpreting everything")
		} else {
			fmt.eprintln("ps2: no native blob, running the registered functions")
		}
	}
	entry, ok := mem.load_elf(elf)
	if !ok {
		delete(elf)
		fmt.eprintln("disc:", name, "is not a loadable ELF file")
		return false
	}
	// The hooks name the boot program by its ELF file, and its code in RAM.
	kernel.exec_boot_program(elf)
	merr = mods_load(set)
	delete(elf)
	if merr != "" {
		fmt.eprintln(merr)
		return false
	}
	cpu.state.r[29].d[0] = mem.RAM_SIZE - 16
	kernel.exec_boot_args(argv0)
	run(entry)
}
