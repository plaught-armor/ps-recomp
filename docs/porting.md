# Making a port

A port turns one game into its own native program, with its own fixes and
features. It lives in its own repository. [How it works](how-it-works.md)
covers the recompiler and its options file.

A port repository holds its `recomp.tsv`, a main package driving the
runtime and any hand-written replacements; the game's files come from the
user's disc. `out` is the generated package's directory: put it inside the
main package's directory (`port/rec` for a main package in `port/`) so main
can `import "rec"`. `runtime` is the import path the generated code uses
for the runtime, as `ps:psx` or `ps:ps2` through the collection. Minimal PS1
options:

```tsv
key	value
backend	r3000
exe	SLUS_000.00
out	rec
runtime	ps:psx
code_lo	80010000
code_hi	80080000
cycles_per_insn	2
```

With `disc`, the path of the user's disc image (a `.cue` sheet, or a
single-track `.bin` or `.iso`), `exe` is read from the image: it is a path
on the disc, and left out it is the executable `SYSTEM.CNF` names.

Without `code_lo` and `code_hi`, the PS-X EXE's whole text segment is
code. Without `out` no Odin source is written; `runtime`,
`cycles_per_insn` and `package_insns` have defaults, named in the
backend's header comment.

For `r5900`, give `exe` (the ELF), `out` and `runtime` (`ps:ps2`); the
code range defaults to the ELF's `.text`, or give `code_lo` and `code_hi`,
or, for code split by data, `code_ranges`: the path of a tab-separated
file with a `lo<TAB>hi` header row and one hex range per row, in
ascending order.

## PS1

The main package imports `psx "ps:psx"`. Pass the path of the disc image
(a `.cue` sheet, or a single-track `.bin` or `.iso`) and the generated
functions to `psx.run`; it reads the EXE `SYSTEM.CNF` names, or takes the
bytes given as `exe`. It sets up the runtime in order (CD, tracing,
window, functions, native code, events, SPU and XA, timers, DMA, BIOS,
memory cards), points `gp`, `sp` and `fp` at the EXE's values and calls
its entry; it returns false when a step fails, with the reason printed,
and true when the entry returns. `overlays` (`rec.register_overlays`,
generated only with `overlays`), `native` (a blob for `psx.load_native`,
which on failure prints why and keeps the Odin functions), `cards`,
`setup` and `hooks` are optional. `setup` runs before the window opens;
`hooks` runs once the functions are registered, and is where the port
replaces guest functions (`cpu.hook`, `cpu.hook_overlay`) and sets
`host.vblank_hook`, `present_hook`, `pad_hook` or `key_hook`.
`psx/hooks.odin` is the runtime's internal wiring.

```odin
package main

import "core:os"
import psx "ps:psx"
import "rec"

main :: proc() {
	if !psx.run({disc = "game.cue", title = "Game", funcs = rec.EXE_FUNCS[:]}) {
		os.exit(1)
	}
}
```

## PS2

The main package imports `"ps:ps2"`, `cpu "ps:ps2/cpu"`,
`host "ps:ps2/host"`, `iop "ps:ps2/iop"` and `mem "ps:ps2/mem"`. Open the
disc image with `iop.disc_image_open(path)` (or set `iop.disc_dir` to a
directory of the disc's files, default `.`), `ps2.init()` (maps RAM, so it
comes before anything that writes RAM), `rec.register_all()`, optionally
`ps2.load_native(path)`. `iop.disc_boot()` names the ELF `SYSTEM.CNF`
boots and `iop.disc_file(name)` reads it. `mem.load_elf(data)` copies the
ELF's `PT_LOAD` segments into RAM and returns `entry, ok`. Set
`cpu.state.r[29].d[0] = mem.RAM_SIZE - 16` and call `ps2.run(entry)`,
which never returns. `kernel.vblank_hook`, run every vblank, is where the
port presents the picture, reads input and paces. `ps2/host` does that
for a port: `host.platform_init(title)` opens the window and audio and sets
the hook, and `host.pad_hook` lets the game remap each player's input.

```odin
package main

import "core:os"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import host "ps:ps2/host"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"
import "rec"

main :: proc() {
	if !iop.disc_image_open("game.iso") {
		os.exit(1)
	}
	ps2.init()
	if !host.platform_init("Game") {
		os.exit(1)
	}
	rec.register_all()
	boot, found := iop.disc_boot()
	if !found {
		os.exit(1)
	}
	data, read := iop.disc_file(boot)
	if !read {
		os.exit(1)
	}
	entry, ok := mem.load_elf(data)
	if !ok {
		os.exit(1)
	}
	cpu.state.r[29].d[0] = mem.RAM_SIZE - 16
	ps2.run(entry)
}
```

## Settings and memory cards

Build with `-define:ENV_PREFIX=GAME_` so settings read `GAME_*`. PS1 cards
are 128 KiB images, `slot1.mcd` and `slot2.mcd` in the working directory
(`MCD`, `MCD2`, or `bios.card_files` before `memcard_init`). PS2 cards are
directories, `memcard0/` and `memcard1/` in the working directory or in `MC`.
