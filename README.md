# ps-recomp

A static recompilation framework for PlayStation (PS1) and PlayStation 2
games, written in [Odin](https://odin-lang.org).

`recomp` translates a game's MIPS machine code (R3000A for PS1, R5900 for
PS2) into Odin source, one procedure per guest function. The game is then
built as a native program against the runtime packages here, which emulate
the rest of the console: memory, DMA, the GPU or GS, sound, controllers,
memory cards and the BIOS or kernel calls the game makes. `recomp` can
also emit x86-64 (SysV or Win64) or arm64 machine code alongside the Odin
source (`native_arch`, `native_out`).

This repository holds no game code or data. A port lives in its own
repository: it supplies the game's executable (from a disc the user owns),
a `recomp` options file, and any per-game code.

## Layout

| Path | What |
|---|---|
| `recomp/` | The recompiler: `mips/` (shared decoding and function discovery), `r3000/`, `r5900/`, `vu/` backends, `native/` machine-code emitter |
| `core/` | Console-independent runtime: coroutines, save states and rollback, netplay, input and rebinding, audio, recording and replay, Vulkan device, capture; `disc` (disc images, ISO9660 and disc ids); the user data directory |
| `psx/` | PS1 runtime: `cpu`, `gte`, `gpu` and `render`, `spu`, `mdec`, `bios`, `io`, `native` (the names native code imports), `host` (SDL2 window, pacing, input), and the interpreter, checkpoints and hooks |
| `ps2/` | PS2 runtime: `cpu`, `mem`, `dma`, `gif`, `gs` (Vulkan), `vu`, `ipu`, `iop` (HLE IOP modules, memory cards), `kernel`, `r5900` (EE instruction decoder), `host` (SDL2 window, audio, input, net), and the interpreter and bus |
| `tests/` | `core` (coroutines, snapshots, rollback, file writes, PS2 ELF loading), `native` (machine-code emitter), `ee_native` (EE instructions through the native backend against the interpreter), `fpu` (EE FPU vectors), `lower` (r5900 and r3000 branch lowering), `vu` (VU0 microprograms from the EE, macro flags), `vu_macro` (the EE recompiler's VU0 macro code against the interpreter), `ee_emit` (the EE recompiler's inline MMI, multiply-add and FPU code against the interpreter), `vu_micro` (whole VU microprograms through the VU recompiler against the interpreter), `spu` (SPU2 voices through the port API, sound RAM in snapshots), `ps2_kernel` (EE kernel threads), `ps2_interp` (whole EE functions in the interpreter), `psx_cover` (which R3000 encodings each PS1 backend does inline), `psx_fallback` (the PS1 ways out of recompiled code and their counts), `psx_unaligned` (fused PS1 unaligned words), `psx_gte` (GTE register moves as native code), `psx_timer` (root counter timing), `psx_bios` (BIOS events, counters and IRQs), `psx_bios_libc` (the BIOS C library), `disc` (disc images, cue sheets and ISO9660, malformed ones included; disc ids), `host_frames` (each host, headless, exits at FRAMES), `data` (the user data directory and its cached native code) |

## Requirements

- Odin `dev-2026-10`
- SDL2 (window, input, audio), Vulkan 1.3 (PS1 renderer, `GPU=sw` draws in
  software; PS2 GS)
- `glslc` only to rebuild the shaders (`ps2/gs/shaders/build.sh`,
  `psx/render/shaders/build.sh`); the compiled `.spv` files are committed

## Building the recompiler

```sh
odin build recomp -collection:ps=. -out:recomp-bin
./recomp-bin path/to/recomp.tsv
```

The options file is tab-separated: a `key<TAB>value` header row, then one
option per row; lines starting with `#` are comments. `backend` (`r3000` or
`r5900`) picks the console; the backend's header comment lists the rest of
its options (`exe`, `out`, `runtime`, `code_lo`/`code_hi`,
`cycles_per_insn`, `native_arch`/`native_out`, ...). Numbers are hex where
the header says so. File and directory paths in it are opened as given, so
relative ones are relative to the directory recomp runs in.

A port imports the runtime through the `ps` collection, for example
`odin build port -collection:ps=<path to ps-recomp> -use-separate-modules
-o:speed`. `-use-separate-modules` lets a generated program of many packages
build in parallel (a few minutes for a PS2 game of about 20 packages,
much longer without it). Generated code is not vetted: check it without
`-vet`.

## Tests

From the repository root:

```sh
odin run tests/core -collection:ps=.
odin run tests/native -collection:ps=.
odin run tests/ee_native -collection:ps=.
odin run tests/fpu -collection:ps=.
odin run tests/lower -collection:ps=.
odin run tests/vu -collection:ps=.
odin run tests/vu_macro -collection:ps=.
odin run tests/vu_micro -collection:ps=.
odin run tests/ee_emit -collection:ps=.
odin run tests/spu -collection:ps=.
odin run tests/psx_fallback -collection:ps=.
odin run tests/psx_fallback -collection:ps=. -define:FALLBACK_COUNT=true
odin run tests/psx_unaligned -collection:ps=.
odin run tests/psx_gte -collection:ps=.
odin run tests/psx_cover -collection:ps=.
odin run tests/psx_timer -collection:ps=.
odin run tests/ps2_kernel -collection:ps=.
odin run tests/ps2_interp -collection:ps=.
odin run tests/ps2_interp -collection:ps=. -define:FALLBACK_COUNT=true
odin run tests/psx_bios -collection:ps=.
odin run tests/psx_bios_libc -collection:ps=.
odin run tests/disc -collection:ps=.
odin run tests/host_frames -collection:ps=.
odin run tests/data -collection:ps=.
```

`.github/workflows/ci.yml` is the list CI runs; a new test goes there and
here.

CI type-checks every package on linux and darwin (amd64 and arm64) and on
Windows, and runs the tests on Linux (x86-64, arm64), macOS (arm64; a
subset as x86-64 under Rosetta) and Windows. Games have only been played on
Linux.

Before sending a change, check what it touches as CI does, with vet and
strict style:

```sh
odin check psx -no-entry-point -collection:ps=. -vet -strict-style
odin check recomp -collection:ps=. -vet -strict-style
odin check tests/core -collection:ps=. -vet -strict-style
```

The runtime packages (`core`, `psx`, `ps2`, `ps2/host`) take
`-no-entry-point`; `recomp` and the tests do not. Add `-target:` to check
another platform, as CI does for `linux_arm64`, `darwin_amd64` and
`darwin_arm64`.

## Making a port

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

For `r5900`, give `exe` (the ELF), `out`, `runtime` (`ps:ps2`),
`cycles_per_insn` and `package_insns`; the code range defaults to the
ELF's `.text`, or give `code_lo` and `code_hi`, or, for code split by data,
`code_ranges`: the path of a tab-separated file with a `lo<TAB>hi` header
row and one hex range per row, in ascending order. `overlays` (PS1) also
needs `package_insns`.

PS1 (imports `psx "ps:psx"`): read the EXE and pass its bytes, with the
disc's CUE sheet and the generated functions, to `psx.run`. It sets up the
runtime in order (CD, tracing, window, functions, native code, events, SPU
and XA, timers, DMA, BIOS, memory cards), points `gp`, `sp` and `fp` at the
EXE's values and calls its entry; it returns false when a step fails, with
the reason printed, and true when the entry returns. `overlays`
(`rec.register_overlays`, generated only with `overlays`), `native` (a blob
for `psx.load_native`, which on failure prints why and keeps the Odin
functions), `cards`, `setup` and `hooks` are optional. `setup` runs before
the window opens; `hooks` runs once the functions are registered, and is
where the port replaces guest functions (`cpu.hook`, `cpu.hook_overlay`)
and sets `host.vblank_hook`, `present_hook`, `pad_hook` or `key_hook`.
`psx/hooks.odin` is the runtime's internal wiring.

```odin
package main

import "core:os"
import psx "ps:psx"
import "rec"

main :: proc() {
	exe, err := os.read_entire_file("disc/SLUS_000.00", context.allocator)
	if err != nil {
		os.exit(1)
	}
	if !psx.run({exe = exe, cue = "game.cue", title = "Game", funcs = rec.EXE_FUNCS[:]}) {
		os.exit(1)
	}
}
```

PS2 (imports `"ps:ps2"`, `cpu "ps:ps2/cpu"`, `host "ps:ps2/host"`,
`iop "ps:ps2/iop"`, `mem "ps:ps2/mem"`): set `iop.disc_dir` to the
directory of the disc's files (default `.`), `ps2.init()` (maps RAM, so it
comes before anything that writes RAM), `rec.register_all()`, optionally
`ps2.load_native(path)`. `mem.load_elf(data)` copies the ELF's `PT_LOAD`
segments into RAM and returns `entry, ok`. Set
`cpu.state.r[29].d[0] = mem.RAM_SIZE - 16` and call `ps2.run(entry)`,
which never returns. `kernel.vblank_hook`, run every vblank, is where the
port presents the picture, reads input and paces. `ps2/host` does that
for a port: `host.platform_init(title)` opens the window and audio and sets
the hook, and `host.pad_hook` lets the game remap each player's input.

```odin
package main

import "core:os"
import "core:path/filepath"
import "ps:ps2"
import cpu "ps:ps2/cpu"
import host "ps:ps2/host"
import iop "ps:ps2/iop"
import mem "ps:ps2/mem"
import "rec"

main :: proc() {
	path := "disc/SLUS_000.00"
	iop.disc_dir = filepath.dir(path)
	ps2.init()
	if !host.platform_init("Game") {
		os.exit(1)
	}
	rec.register_all()
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
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

Build with `-define:ENV_PREFIX=GAME_` so settings read `GAME_*`. PS1 cards
are 128 KiB images, `slot1.mcd` and `slot2.mcd` in the working directory
(`MCD`, `MCD2`, or `bios.card_files` before `memcard_init`). PS2 cards are
directories, `memcard0/` and `memcard1/` in the working directory or in `MC`.

## Configuration

Runtime options come from environment variables, prefixed per port
(`-define:ENV_PREFIX=GAME_`); see `core/env.odin`. Debug aids such as
scripted input (`INPUT`, `STICK`), replays and memory pokes are described
where they are read.

## License

GPL-3.0; see `LICENSE`.
