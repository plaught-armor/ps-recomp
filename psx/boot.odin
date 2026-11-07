// Booting a PS1 game: the runtime set up in the order it needs and the
// executable's entry called, the PS1 counterpart of ps2.run.
package psx

import "core:fmt"
import "core:hash/xxhash"

import "ps:core"
import "ps:core/disc"
import bios "bios"
import cpu "cpu"
import host "host"
import io "io"
@(require) import native "native" // used only with LOADERS
import spu "spu"

// What run needs from the port.
Boot :: struct {
	// The path of the disc image (a .cue sheet, or a single-track .bin or
	// .iso) and the PS-X EXE's bytes; left nil, the executable SYSTEM.CNF
	// names is read from the disc.
	disc:          string,
	exe:           []u8,
	// The window's title.
	title:         cstring,
	// The generated package's executable functions (rec.EXE_FUNCS[:]) and,
	// generated only with the overlays option, rec.register_overlays.
	funcs:         []cpu.Func_Entry,
	overlays:      proc(),
	// A native blob to use in place of the Odin functions ("" none;
	// load_native). With no funcs the blob is all the game's code: its
	// functions are registered from it, and the boot stops if it cannot be
	// loaded. With neither, the game is interpreted.
	native:        string,
	// Called when a standalone blob cannot be loaded, before run returns
	// false; nil none.
	native_failed: proc(),
	// The blob's functions to leave to the interpreter (load_native's
	// skip), and what a wasm32 build calls with the native entries a
	// thread switch is fatal under (cpu.flat_native_fatal); play keeps
	// those (core.known_switches) and passes them here on the runs after.
	native_skip:     []u32,
	native_switched: proc(entries: []u32),
	// The port's recompiled learned functions, rec.register_learned (the
	// recompiler's learned option; nil none). Registered before the blob
	// below, they win over its functions for the same code
	// (cpu.register_learned).
	learned_funcs:  proc(),
	// A blob of learned functions ("" none; native.load_learned), and what to call
	// when it cannot be loaded (nil none); the game then runs without it.
	learned:        string,
	learned_failed: proc(),
	// The memory card images (bios.card_files); left empty, the runtime's.
	cards:         [2]string,
	// The game's mods directory ("" none; mods_load) and the disc's id,
	// which a mod's manifest may name.
	mods:          string,
	disc_id:       string,
	// A blob of the mods' functions ("" none; native.load_mods), and what to
	// call when it cannot be loaded (nil none); the mods then run
	// interpreted.
	mods_native:        string,
	mods_native_failed: proc(),
	// The port's own steps, each stopping the boot on false: `setup` before
	// the window opens, `hooks` once the game's functions (native ones
	// included) are registered, where the port installs its replacements
	// (cpu.hook, cpu.hook_overlay) and host hooks.
	setup:         proc() -> bool,
	hooks:         proc() -> bool,
	// Called at each vblank after the port's host hook (host.vblank_hook),
	// and when the host quits (host.quit_hook); nil none. A preload machine
	// (host/preload.odin) runs vblank_hook too, so a native build's
	// forked child would call it as well: play sets these only in a
	// wasm32 build, which has no fork.
	vblank:        proc(),
	quit:          proc(),
}

// Boot.vblank, and the port's vblank_hook it follows: taken once, after
// the hooks step sets it, so nothing may assign host.vblank_hook after the
// boot, or Boot.vblank is dropped.
@(private = "file")
boot_vblank, port_vblank: proc()

@(private = "file")
vblank_chain :: proc() {
	if port_vblank != nil {port_vblank()}
	boot_vblank()
}

// Whether the boot loads native and learned code: not in a native FLAT
// build (run).
@(private = "file")
LOADERS :: !core.FLAT || core.NATIVE_ARCH == core.NATIVE_ARCH_WASM32

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
	// The input record opened here carries the mod set (core/record.odin).
	// Netplay peers compare it (core/net.odin HELLO).
	if b.disc_id != "" {core.run_disc = xxhash.XXH3_64_default(transmute([]u8)b.disc_id)}
	mods := mods_identify(b.mods, b.disc_id) or_return
	host.platform_init(b.title) or_return

	// A native FLAT build runs interpreted only (core/flat.odin): a thread
	// switch inside native code would leave its host frames running on. A
	// wasm32 build runs a stored blob's native and learned code under FLAT,
	// where such a switch is fatal (cpu.flat_block).
	when core.FLAT && core.NATIVE_ARCH != core.NATIVE_ARCH_WASM32 {
		what := ""
		switch {
		case len(b.funcs) > 0: what = "recompiled functions (Boot.funcs)"
		case b.overlays != nil: what = "recompiled overlays (Boot.overlays)"
		case b.native != "": what = "native code (Boot.native)"
		case b.learned_funcs != nil: what = "recompiled learned functions (Boot.learned_funcs)"
		case b.learned != "": what = "learned code (Boot.learned)"
		case b.mods_native != "": what = "the mods' native code (Boot.mods_native)"
		}
		if what != "" {cpu.fatal("FLAT runs interpreted only: %s not installed", what)}
	}
	cpu.register_funcs(b.funcs)
	if b.overlays != nil {b.overlays()}
	// On failure load_native prints why and the Odin functions stay; a
	// standalone blob has none behind it. With neither, every function is
	// interpreted: a disc nobody has converted still runs, slowly.
	// Under a native FLAT build the loaders are not compiled in (the check
	// above refuses what they load), so it refers to no map_code.
	standalone := len(b.funcs) == 0
	when LOADERS {
		when core.FLAT {cpu.flat_native_fatal = b.native_switched}
		if b.native != "" && !load_native(b.native, standalone, b.native_skip) && standalone {
			if b.native_failed != nil {b.native_failed()}
			return false
		}
	}
	if standalone && b.native == "" {
		fmt.eprintln("psx: no native code, interpreting everything")
	}
	when LOADERS {
		if b.learned_funcs != nil {b.learned_funcs()}
		if b.learned != "" && !native.load_learned(b.learned) && b.learned_failed != nil {
			b.learned_failed()
		}
	}
	if b.hooks != nil {b.hooks() or_return}
	if b.vblank != nil {
		port_vblank, boot_vblank = host.vblank_hook, b.vblank
		host.vblank_hook = vblank_chain
	}
	host.quit_hook = b.quit
	cpu.watch_code()
	// After every other hook, so a mod wraps the port's.
	mods_load(mods, b.mods_native, b.mods_native_failed) or_return

	io.events_init()
	spu.spu_init()
	spu.xa_init()
	io.timers_init()
	io.dma_init()
	bios.bios_init()
	bios.exec_boot(exe)
	if b.cards != {} {bios.card_files = b.cards}
	bios.memcard_init() or_return

	cpu.state.r[28] = gp
	cpu.state.r[29] = sp
	cpu.state.r[30] = sp
	cpu.cop0.sr = 0x40000401
	when core.FLAT {bios.flat_main(pc)} else {cpu.call(pc)}
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
