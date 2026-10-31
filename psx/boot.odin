// Booting a PS1 game: the runtime set up in the order it needs and the
// executable's entry called, the PS1 counterpart of ps2.run.
package psx

import "core:fmt"

import "ps:core/disc"
import bios "bios"
import cpu "cpu"
import host "host"
import io "io"
import spu "spu"

// What run needs from the port.
Boot :: struct {
	// The path of the disc image (a .cue sheet, or a single-track .bin or
	// .iso) and the PS-X EXE's bytes; left nil, the executable SYSTEM.CNF
	// names is read from the disc.
	disc:     string,
	exe:      []u8,
	// The window's title.
	title:    cstring,
	// The generated package's executable functions (rec.EXE_FUNCS[:]) and,
	// generated only with the overlays option, rec.register_overlays.
	funcs:    []cpu.Func_Entry,
	overlays: proc(),
	// A native blob to use in place of the Odin functions ("" none;
	// load_native). With no funcs the blob is all the game's code: its
	// functions are registered from it, and the boot stops if it cannot be
	// loaded. With neither, the game is interpreted.
	native:   string,
	// The memory card images (bios.card_files); left empty, the runtime's.
	cards:    [2]string,
	// The port's own steps, each stopping the boot on false: `setup` before
	// the window opens, `hooks` once the game's functions (native ones
	// included) are registered, where the port installs its replacements
	// (cpu.hook, cpu.hook_overlay) and host hooks.
	setup:    proc() -> bool,
	hooks:    proc() -> bool,
}

// Set up the runtime for the game b describes and call the executable's
// entry. False when a step fails, with the reason printed; true when the
// entry returns.
run :: proc(b: Boot) -> bool {
	spu.cdrom_open(b.disc) or_return
	exe := b.exe
	if exe == nil {
		exe = disc_exe() or_return
	}
	pc, gp, sp, ok := cpu.load_exe(exe)
	if !ok {
		fmt.eprintln("not a PS-X EXE")
		return false
	}
	cpu.trace_init() or_return
	if b.setup != nil {b.setup() or_return}
	host.platform_init(b.title) or_return

	cpu.register_funcs(b.funcs)
	if b.overlays != nil {b.overlays()}
	// On failure load_native prints why and the Odin functions stay; a
	// standalone blob has none behind it. With neither, every function is
	// interpreted: a disc nobody has converted still runs, slowly.
	standalone := len(b.funcs) == 0
	if b.native != "" && !load_native(b.native, standalone) && standalone {
		return false
	}
	if standalone && b.native == "" {
		fmt.eprintln("psx: no native code, interpreting everything")
	}
	if b.hooks != nil {b.hooks() or_return}
	cpu.watch_code()

	io.events_init()
	spu.spu_init()
	spu.xa_init()
	io.timers_init()
	io.dma_init()
	bios.bios_init()
	if b.cards != {} {bios.card_files = b.cards}
	bios.memcard_init() or_return

	cpu.state.r[28] = gp
	cpu.state.r[29] = sp
	cpu.state.r[30] = sp
	cpu.cop0.sr = 0x40000401
	cpu.call(pc)
	return true
}

// The executable the open disc's SYSTEM.CNF names.
@(private = "file")
disc_exe :: proc() -> ([]u8, bool) {
	d := spu.disc_image()
	cnf, ok := disc.system_cnf(d, context.temp_allocator)
	if !ok || cnf.ps2 {
		fmt.eprintln("disc: no PS1 executable named in SYSTEM.CNF")
		return nil, false
	}
	exe, read_ok := disc.read_file(d, cnf.boot)
	if !read_ok {
		fmt.eprintln("disc: cannot read", cnf.boot)
	}
	return exe, read_ok
}
