# Tests

From the repository root:

```sh
odin run tests/core -collection:ps=.
odin run tests/native -collection:ps=.
odin run tests/ee_native -collection:ps=.
odin run tests/ee_spin -collection:ps=.
odin run tests/fpu -collection:ps=.
odin run tests/lower -collection:ps=.
odin run tests/discover -collection:ps=.
odin run tests/vu -collection:ps=.
odin run tests/gs -collection:ps=.
odin run tests/gs_tex -collection:ps=.
odin run tests/gs_pixel -collection:ps=.
odin run tests/vu_macro -collection:ps=.
odin run tests/vu_micro -collection:ps=.
odin run tests/vu_native -collection:ps=.
odin run tests/ee_emit -collection:ps=.
odin run tests/spu -collection:ps=.
odin run tests/psx_fallback -collection:ps=.
odin run tests/psx_fallback -collection:ps=. -define:FALLBACK_COUNT=true
odin run tests/psx_codewatch -collection:ps=.
odin run tests/psx_codewatch -collection:ps=. -define:FALLBACK_COUNT=true
odin run tests/psx_learned -collection:ps=.
odin run tests/iop_learned -collection:ps=.
odin run tests/ee_learned -collection:ps=.
odin run tests/psx_unaligned -collection:ps=.
odin run tests/psx_gte -collection:ps=.
odin run tests/psx_cover -collection:ps=.
odin run tests/psx_timer -collection:ps=.
odin run tests/ps2_kernel -collection:ps=.
odin run tests/ps2_iop -collection:ps=.
odin run tests/ps2_interp -collection:ps=.
odin run tests/ps2_interp -collection:ps=. -define:FALLBACK_COUNT=true
odin run tests/psx_bios -collection:ps=.
odin run tests/psx_bios_libc -collection:ps=.
odin run tests/disc -collection:ps=.
odin run tests/host_frames -collection:ps=.
odin run tests/data -collection:ps=.
odin run tests/psx_interp -collection:ps=.
odin run tests/compat -collection:ps=.
odin run tests/learn -collection:ps=.
odin run tests/play -collection:ps=. -define:COMMIT=test
```

`.github/workflows/ci.yml` is the list CI runs; a new test goes there and
here.

## What each test covers

| Test | What |
|---|---|
| `core` | Coroutines, snapshots, rollback, file writes, PS2 ELF loading |
| `native` | The machine-code emitter |
| `ee_native` | EE instructions through the native backend against the interpreter |
| `ee_spin` | The EE spin skip on synthetic loops: on and off end the same, cycles included; a pure spin, a same-value store and an INTC_STAT poll are skipped; a counter, a GIF_STAT poll and a timer poll are not |
| `fpu` | EE FPU vectors |
| `lower` | r5900 and r3000 branch lowering |
| `discover` | Functions with no prologue that tables of methods in a writable code section point at: thunks, leaves and jumps on through a register, stubs in a row included, are entries; code after a `b` or a `j` inside a function, code that calls or uses `$sp`, data after a `jr` with stray fields or a jump in a delay slot, a jump table's cases (tables of functions next to each other in one run included) and a pair of words are not |
| `vu` | VU0 microprograms from the EE, macro flags |
| `vu_macro` | The EE recompiler's VU0 macro code against the interpreter |
| `ee_emit` | The EE recompiler's inline MMI, multiply-add and FPU code against the interpreter |
| `vu_micro` | Whole VU microprograms through the VU recompiler against the interpreter |
| `vu_native` | VU microprograms through the native backend against the interpreter |
| `spu` | SPU2 voices through the port API, sound RAM in snapshots |
| `ps2_kernel` | EE kernel threads, ExecPS2 |
| `ps2_iop` | The IOP CPU and the IOP modules run on it |
| `ps2_interp` | Whole EE functions in the interpreter |
| `psx_cover` | Which R3000 encodings each PS1 backend does inline |
| `psx_fallback` | The PS1 ways out of recompiled code and their counts |
| `psx_codewatch` | Recompiled PS1 code demoted when a write changes it, promoted again when it is back |
| `psx_learned` | Learned PS1 runs compiled, run native only while RAM holds their code |
| `iop_learned` | Learned IOP runs native only while IOP RAM holds their code, through host writes and snapshot loads |
| `ee_learned` | Learned EE runs native, where no function is registered, only while RAM holds their code, through host and DMA writes and snapshot loads, one version per code at an entry; runs stored into or too large are not compiled |
| `psx_unaligned` | Fused PS1 unaligned words |
| `psx_gte` | GTE register moves as native code |
| `psx_timer` | Root counter timing |
| `psx_bios` | BIOS events, counters and IRQs, the executable loaders |
| `psx_bios_libc` | The BIOS C library |
| `psx_interp` | The PS1 interpreter's jumps into the BIOS |
| `disc` | Disc images, cue sheets and ISO9660, malformed ones included; disc ids; the IOP's file lookups on an image |
| `host_frames` | Each host, headless, exits at FRAMES |
| `data` | The user data directory and its cached native code |
| `compat` | Each host's compat line, and stubbed calls, under COMPAT |
| `play` | `play` on small synthetic PS1 discs, converted and interpreted, and its compat mode on PS1 and PS2 discs, a second executable loaded and a PS2 program switch included; the launcher, its picture checked by point and a non-ASCII title cell by cell against the font |
| `discimg` | The small disc images `disc` and `play` use |

## Compatibility runs

`play --compat` runs each disc once. A PS2 disc's run records its I/O
processor code and the EE code it interpreted (`learn/ps2.bin` in the
disc's folder), as every PS2 run does by default; a later run, compat or
not, compiles those records and runs that code natively, the EE's only
while memory holds the code it was compiled from. The `learned` column
says whether a run had learned code, so a cold run (no records yet) and a
warm one are told apart. Set `PS_LEARN=0` for a run with no learned code that records
nothing.

Each child plays on blank cards: the parent empties the disc's
`compat-cards` folder before it starts, so a save from an earlier run (a
cold run's, say) cannot send a warm run down another route.
`PS_COMPAT_CARDS=keep` runs on the disc's `cards` as play does, for a
save and reload check; the `cards` column says `fresh`, `kept` or
`kept-empty`. One run of a disc at a time is assumed: a parent runs its
discs in turn, but two parents in one `PS_DATA` share `compat-cards`.

A PS2 child probes input while quiet (core/compat.odin,
ps2/host/probe.odin): every `PS_COMPAT_PROBE` vblanks of samples with no
IRX load and no interpreter entry pc first seen (default 3600; `0` is
off), it saves state, runs 90 vblanks with nothing pressed and then with
each of Start, Cross, Circle, Up and Down held for 10, loads the state
back after each, and counts the bytes of EE RAM each button left
different. Every button at 64 or fewer is a deaf probe; two in a row
are a `stuck` stretch in the compat line, from the first to the last.
The branches count nothing, note no learn records, write no card or
progress file, and push no sound, so the run after a probe is the run
without one (`PS_DUMP_HASH` is the same with `PS_COMPAT_PROBE=0`). A
warm run has no new entry pcs, so it is quiet whenever it loads no IRX.

### Pictures and dumps

`PS_SHOT=<vblank>,<vblank>,...` (PS2 only, read in ps2/host/platform.odin)
writes `shot_<vblank>.ppm` into the working directory at each listed
vblank, in ascending order. Shots count vblanks, as `PS_FRAMES` does, so a
shot at the last frame is the picture the compat `lit` column counts. With
the display off at that vblank no file is written and the run prints
`shot: vblank <n>, display off, none written`. A headless run without
`PS_FRAMES` exits after its last shot; with `PS_FRAMES` it runs on to that
count. The PS1 host does not read `PS_SHOT`.

Both consoles also save the disc's thumbnail, `thumb.ppm` in the disc's
folder, from the picture on screen when the run ends without an error,
unless the display is off then.

On PS1, pictures come from `PS_DUMP=<dir>` (core/dump.odin): from present
`PS_DUMP_FROM` (default 1), every `PS_DUMP_EVERY` presents (default 1), the
displayed area is written as `frame_<n>.ppm` and main RAM as
`ram_<n>.bin`, plus all of VRAM as `vram_<n>.ppm` on every 150th present.
On PS2, `PS_DUMP` writes the guest clock, EE RAM and IOP memory per
presented frame (`cyc`, `ram`, `iop`, `iophle`), no pictures.
`PS_DUMP_HASH=1` turns every dump into a line `<kind>\t<frame>\t<XXH3>`
in `<dir>/hashes.tsv` instead of a file, so two runs can be diffed for the
first frame they diverge; a PS1 run with it writes no pictures.

## CI

CI type-checks every package on Linux and macOS (amd64 and arm64) and on
Windows, and runs the tests on Linux (x86-64, arm64) and Windows. No CI job
runs the tests on macOS.

Before sending a change, check what it touches as CI does, with vet and
strict style:

```sh
odin check psx -no-entry-point -collection:ps=. -vet -strict-style
odin check recomp -collection:ps=. -vet -strict-style
odin check tests/core -collection:ps=. -vet -strict-style
```

The runtime packages (`core`, `core/disc`, `psx`, `ps2`, `ps2/host`) and
`tests/discimg` take `-no-entry-point`; `recomp`, `play` and the tests do
not. Add `-target:` to check another platform, as CI does for
`linux_arm64`, `darwin_amd64` and `darwin_arm64`.
