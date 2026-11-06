# Making a port

A port turns one game into its own native program, with its own fixes and
features. It lives in its own repository. [How it works](how-it-works.md)
covers the recompiler and its options file.

The quickest start is an export (below), which writes a working port
for one disc. A port repository holds its `recomp.tsv`, a main package driving the
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
generated only with `overlays`), `learned_funcs` (`rec.register_learned`,
always generated; see [PS1 overlays](#ps1-overlays)), `native` (a blob for `psx.load_native`,
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

## Mods

Mods hook guest functions without changing the port. `core/mod.odin`
reads each mod's manifest (`mod.tsv`), orders the mods (dependencies,
then `before` and `after`), and builds one chain per hooked function:
before hooks in load order, at most one replacement, after hooks in
reverse load order. A hook is keyed by the function's address, the
overlay slot and id for overlay code, and the function's first four code
words, as the mod was built against.

On PS1, `cpu.mod_install` puts the chains in the dispatch tables, after
the port's own hooks (`hooks`), with `cpu.mod_sp` set to the top of the
mods' stack. Recompiled executable functions are wrapped through
`cpu.hook`, so a port hook still runs inside the mods'. Recompiled
overlay functions have their entry replaced, and interpreted functions
get an entry whose original is the interpreter. A chain runs only while
its code is in RAM: the overlay's id at its slot and the function's
first words; otherwise the call runs as if no mod were loaded.

Before and after hooks run on the mods' stack with time frozen: every
register, the cycle count and cop0 included, is put back when a hook
returns, so a hook changes the game only through memory. No event or
interrupt is handled inside a hook; one that comes due there is handled
as soon as the hook returns. An event a hook schedules counts its delay
from the hook's own cycle count, so it lands later in game time by the
hook's length. After hooks see the arguments (a0-a3) and the results
(v0, v1). The replacement runs on the game's stack and in game time,
except when it is called from inside a hook: then it runs in that hook's
frozen time.
An install error leaves nothing installed.

Limits:

- Only calls are hooked. A jump the interpreter steps into enters the
  function without its hooks: a `j` past a run's first word, or a `jr`
  through a register other than `$ra` to a target not in the fixed table.
  Recompiled code turns every jump out of a function into a call.
- A hook must not switch threads (`ChangeTh` inside one is fatal) or
  wait for an event (none comes while time is frozen).
- `FLAT` builds install mods too, but the hooks, the replacement and an
  interpreted original run nested, as recompiled functions do there: a
  thread switch or a wait inside them is fatal.
- IOP hooks are untested.

## Settings and memory cards

Build with `-define:ENV_PREFIX=GAME_` so settings read `GAME_*`. PS1 cards
are 128 KiB images, `slot1.mcd` and `slot2.mcd` in the working directory
(`MCD`, `MCD2`, or `bios.card_files` before `memcard_init`). PS2 cards are
directories, `memcard0/` and `memcard1/` in the working directory or in `MC`.

## Start from an export

`play --export <disc image> <dir>`, or Export in the launcher, writes a
repository for the disc into a missing or empty directory. Next to the
notes, settings and picture it holds a port that builds as it is:

| File | What it is |
|---|---|
| `tools/recomp.tsv` | The recompiler's options, `out` set to `port/src/rec`; `setup.sh` adds the disc row. |
| `setup.sh` | Builds `recomp` from the `ps-recomp` submodule, recompiles the disc `local.tsv` names, then runs `port/build.sh`; `sh setup.sh rec` stops after the recompile and prints the size of `port/src/rec`. |
| `port/build.sh` | Builds `port/game` with `COMMIT` set to the submodule's commit. |
| `port/src/main.odin` | Boots the disc with the generated code, as the player does. Change the game here. |
| `port/src/local.odin` | Reads `local.tsv`: the disc image, the player's data for the disc, its settings, memory cards and learned code. |
| `tests/run.sh` | A headless compatibility run of `port/game`, `press.txt` as its input, to a frame count (3600 by default). |
| `local.tsv` | Where the disc image and the player's data are. Git ignores it. |

The README gives the commands: add ps-recomp as a submodule at the
commit of the player that wrote the export, then `sh setup.sh`. The
learned code the player compiled for the disc is used only while the
submodule is at that commit; at another, the port interprets what it
did not recompile. The generated `port/src/rec` is ignored by git, so a
fresh clone runs `setup.sh` again. The scripts need a POSIX shell and have
only been run on Linux; Windows and macOS are untested.

### Memory for the build

`port/build.sh` needs much more memory than the generated source is large.
The Odin front end parses and checks every package of `port/src/rec` and
holds all of their syntax trees at once, so the peak grows with the size of
the generated source. The number of packages, `-thread-count` and `-o:none`
do not change it. Measured peaks:

| Generated source | Build peak |
|---|---|
| 2.6 MB (a PS1 executable, no overlays) | 1.14 GB (12.6 s) |
| 29 MB | 6.7 GB |
| 30.7 MB | 6.82 GB |
| 53 MB | over 9.0 GB (stopped there, not a full peak) |
| 145 MB | over 10.2 GB (stopped there, not a full peak) |

Run the build with no other large jobs on the machine. On a system with
less memory than the peak, it is stopped by the out-of-memory killer.

`sh setup.sh rec` recompiles without building: it writes
`port/src/rec` and prints its size, so the peak can be judged before
`sh setup.sh` (or `sh port/build.sh`) builds.

### PS1 overlays

The recompiler compiles the PS-X EXE. Code the game loads from other files
at run time (overlays) is interpreted unless the options give it, in one of
two ways.

`overlays` names a directory holding the overlay files and a
`manifest.tsv` with a `file<TAB>slot` header row: each file's name in that
directory, and the hex address it loads at. The files are read from the
directory, never from the disc, so the port has to extract them itself
(how a game packs its overlays is its own). Each overlay is recompiled into
`ovl_NN` packages that `rec.register_overlays` registers; a function runs
while its overlay's first word (its id) is at its slot and its first words
match. In `funcs`, an overlay's space is its file name less `.bin`.

`learned` names a LEARN file: the code the player interpreted, recorded
with `PS_LEARN=1` in the disc's directory as `learn/psx.bin`
(core/learn.odin). Each run in it that never stored into its own code is
recompiled into `lrn_NN` packages that `rec.register_learned` registers.
A learned function runs only while RAM holds the words it was recompiled
from, so it needs no knowledge of how the game loads its code, and code
the player never ran stays interpreted. Recording covers what the run
played: run the player with `PS_LEARN=1` through the parts of the game to
cover, then recompile. The file holds the game's code, so keep it out of
git. `learned.odin` is written with or without the option, registering
nothing without it. When the player's learned blob is also loaded (psx.Boot
`learned`), a function for the same code that the port recompiled wins.

### VU microcode

The recompiler compiles the VU programs in the ELF's `.vutext` section.
Microcode the game builds in data and uploads at run time (VIF MPG
packets) is not in the ELF; it is found only by running the game with a
capture, and without one it runs in the interpreter.

To capture, run the player with `PS_VU_CAPTURE=1` through the parts of the
game to cover. It records both VUs' microcode in the disc's directory
(`vu0-capture.bin`, `vu1-capture.bin`; ps2/vu/capture.odin). Capturing is
off by default and is never a saved setting: a captured VU runs only in
the interpreter, so the run is slower. Each run appends what it saw, so
the files grow with every run and cover every part played. A run stopped
mid-write leaves its last record cut short; readers stop there and keep
the rest.

The player uses the captures too. Its next run converts the disc again
with them, so the VU programs (the captured ones and those of
`.vutext`) run as native code in the player as well. It converts again
only when a capture gains a program entry it did not have; runs that
repeat what is already recorded keep the stored code.

Then export the disc again (`play --export`): `local.tsv` names the
capture files that exist, and `setup.sh` adds each one still there to
`build/recomp.tsv`, so the recompiler compiles that microcode too. The
files hold the game's code, so they stay in the player's data, out of the
repository. Without them, a fresh clone builds the same as before, and
that microcode runs in the interpreter.

`PS_VU0_CAPTURE=<file>` and `PS_VU1_CAPTURE=<file>` capture one VU into a
file of your own (each wins over `PS_VU_CAPTURE` for its VU); name such a
file in `tools/recomp.tsv` by hand:

```
vu1_capture	build/vu1.cap
vu0_capture	build/vu0.cap
```

A capture file that is missing is a warning. The options are listed at
the top of recomp/r5900/gen.odin.
