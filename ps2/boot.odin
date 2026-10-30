// Booting a PS2 game from its disc image with no generated package: the
// runtime set up in the order it needs, the functions taken from a native
// blob (or none, every function interpreted), and the ELF SYSTEM.CNF names
// run. The PS2 counterpart of psx.run; ports with a generated package keep
// their own main.
package ps2

import "core:fmt"

import cpu "cpu"
import host "host"
import iop "iop"
import mem "mem"

// What boot needs.
Boot :: struct {
	// The path of the disc image (a .cue sheet, or a single-track .bin or
	// .iso).
	disc:          string,
	// The window's title.
	title:         cstring,
	// A native blob holding all the game's code ("" none: every function is
	// interpreted). The boot stops if it cannot be loaded.
	native:        string,
	// Called when the blob cannot be loaded, before boot returns false; nil
	// none.
	native_failed: proc(),
	// The directory the memory card directories go in (iop.mc_root); left
	// empty, the runtime's.
	cards:         string,
	// The port's own steps, each stopping the boot on false: `setup` before
	// the window opens, `hooks` once the game's functions are registered.
	setup:         proc() -> bool,
	hooks:         proc() -> bool,
}

// Set up the runtime for the game b describes and run the executable's
// entry. False when a step fails, with the reason printed; else it never
// returns.
boot :: proc(b: Boot) -> bool {
	iop.disc_image_open(b.disc) or_return
	name, found := iop.disc_boot()
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
	init()
	if b.setup != nil {b.setup() or_return}
	host.platform_init(b.title) or_return
	if b.native != "" {
		if !load_native(b.native) {
			if b.native_failed != nil {b.native_failed()}
			return false
		}
	} else {
		fmt.eprintln("ps2: no native code, interpreting everything")
	}
	if b.hooks != nil {b.hooks() or_return}
	entry, ok := mem.load_elf(elf)
	delete(elf)
	if !ok {
		fmt.eprintln("disc:", name, "is not a loadable ELF file")
		return false
	}
	cpu.state.r[29].d[0] = mem.RAM_SIZE - 16
	run(entry)
}
