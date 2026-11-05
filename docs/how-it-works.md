# How it works

`recomp` translates a game's MIPS machine code (R3000A for PS1, R5900 for
PS2) into Odin source, one procedure per guest function (a function in the
game's code). The game is then built as a native program against the
runtime packages here, which emulate the rest of the console: memory, DMA,
the GPU or GS (the PS2's graphics chip), sound, controllers, memory cards
and the BIOS or kernel calls the game makes. `recomp` can also emit x86-64
(SysV or Win64) or arm64 machine code alongside the Odin source
(`native_arch`, `native_out`).

`play` uses the machine-code route, so it needs no Odin source and no port.
A port lives in its own repository: it supplies the game's executable (from
a disc the user owns), a `recomp` options file, and any per-game code. See
[Making a port](porting.md).

## Layout

| Path | What |
|---|---|
| `recomp/` | The recompiler: `mips/` (shared decoding and function discovery), `r3000/`, `r5900/`, `vu/` backends, `native/` machine-code emitter |
| `play/` | `play`: runs a game from its disc image, converting it to native code on its first run |
| `core/` | Console-independent runtime: coroutines, save states and rollback, netplay, input and rebinding, audio, recording and replay, Vulkan device, capture; `disc` (disc images, ISO9660 and disc ids); the user data directory; compatibility counters and the COMPAT line |
| `psx/` | PS1 runtime: `cpu`, `gte`, `gpu` and `render`, `spu`, `mdec`, `bios`, `io`, `native` (the names native code imports), `host` (SDL2 window, pacing, input), and the interpreter, checkpoints and hooks |
| `ps2/` | PS2 runtime: `cpu`, `mem`, `dma`, `gif`, `gs` (Vulkan), `vu`, `ipu`, `iop` (HLE IOP modules, memory cards), `kernel`, `r5900` (EE instruction decoder), `host` (SDL2 window, audio, input, net), and the interpreter and bus |
| `tests/` | The tests; see [Tests](testing.md) |
| `docs/` | These pages |

## Settings in the code

Settings are environment variables, read with `core.env`. The full list is
wherever each setting is read; see `core/env.odin` for how names are built.
`play` reads them with the `PS_` prefix. A port chooses its own prefix when
it is built (`-define:ENV_PREFIX=GAME_` makes settings read `GAME_*`).
Debug aids such as scripted input (`INPUT`, `STICK`), replays and memory
pokes are described where they are read.

## The play program

`play <disc image>` converts the disc's executable to native code for the
host on its first run, in a child process (`play --convert`), and keeps it
in the disc's folder under the user data directory. A build made without
`-define:COMMIT=<hash>` is a development build and converts every time.
When the conversion fails, the game runs in the interpreter.

`play --compat` runs each disc in a child of the same executable as `play`
would run it, headless, unpaced and as a COMPAT run (`core/compat`), and
keeps one row per disc id in `compat.tsv`. `play/compat.odin` describes
each column.

## Using the recompiler

```sh
odin build recomp -collection:ps=. -out:recomp-bin
./recomp-bin path/to/recomp.tsv
./recomp-bin [--arch <x64_sysv|x64_win|arm64>] path/to/game.cue [source dir]
```

Given a disc image (a `.cue` sheet, or a single-track `.bin` or `.iso`) in
place of an options file, recomp needs no options: it compiles the
executable `SYSTEM.CNF` names (`PSX.EXE` on a PS1 disc without one) to
machine code for the host (or for the `--arch` given), into
`<serial>.<arch>.bin` in the working directory, and to Odin source too when given a source directory. Code the
executable loads from other files (PS1 overlays) is not found; an ELF
without `.text` has its executable sections compiled whole, data in them
included.

recomp also builds for `wasi_wasm32`, where it reads only what WASI
preopens. `tests/wasi/run.mjs` runs that build under Node 24 or newer (a
development harness, no npm packages); its blob for an arch is the host
build's byte for byte:

```sh
odin build recomp -target:wasi_wasm32 -collection:ps=. -o:speed -out:recomp.wasm
node tests/wasi/run.mjs recomp.wasm <out dir> --arch arm64 path/to/game.cue
```

The options file is tab-separated: a `key<TAB>value` header row, then one
option per row; lines starting with `#` are comments. `backend` (`r3000` or
`r5900`) picks the console; the backend's header comment lists the rest of
its options (`exe`, `disc`, `out`, `runtime`, `code_lo`/`code_hi`,
`cycles_per_insn`, `native_arch`/`native_out`, ...). Numbers are hex where
the header says so. File and directory paths in it are opened as given, so
relative ones are relative to the directory recomp runs in.

A port imports the runtime through the `ps` collection, for example
`odin build port -collection:ps=<path to ps-recomp> -use-separate-modules
-o:speed`. `-use-separate-modules` lets a generated program of many packages
build in parallel (a few minutes for a PS2 game of about 20 packages, much
longer without it). Generated code is not vetted: check it without `-vet`.

`glslc` is needed only to rebuild the shaders
(`ps2/gs/shaders/build.sh`, `psx/render/shaders/build.sh`); the compiled
`.spv` files are committed.
