# Tests

From the repository root:

```sh
odin run tests/core -collection:ps=.
odin run tests/native -collection:ps=.
odin run tests/blob_arch -collection:ps=.
odin run tests/ee_native -collection:ps=.
odin run tests/wasm_sigs -collection:ps=.
odin run tests/ee_spin -collection:ps=.
odin run tests/fpu -collection:ps=.
odin run tests/lower -collection:ps=.
odin run tests/discover -collection:ps=.
odin run tests/vu -collection:ps=.
odin run tests/gs -collection:ps=.
odin run tests/gs_tex -collection:ps=.
odin run tests/gs_pixel -collection:ps=.
odin run tests/gs_scanout -collection:ps=.
odin run tests/gs_hw -collection:ps=.
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
odin run tests/psx_flat_learn -collection:ps=. -define:PS_FLAT=true
odin run tests/iop_learned -collection:ps=.
odin run tests/ee_learned -collection:ps=.
odin run tests/psx_unaligned -collection:ps=.
odin run tests/psx_gte -collection:ps=.
odin run tests/psx_cover -collection:ps=.
odin run tests/psx_timer -collection:ps=.
odin run tests/psx_access_cycles -collection:ps=.
odin run tests/psx_access_cycles -collection:ps=. -define:PS_FLAT=true
odin build tests/psx_access_cycles -collection:ps=. -target:wasi_wasm32 -extra-linker-flags:"--export-table --growable-table" -out:psx_access_cycles.wasm
node tests/psx_access_cycles/run.mjs psx_access_cycles.wasm
odin run tests/psx_gpu_upload -collection:ps=.
odin run tests/ps2_kernel -collection:ps=.
odin run tests/ps2_iop -collection:ps=.
odin run tests/iop_thread_grow -collection:ps=.
odin run tests/iop_thread_grow -collection:ps=. -define:PS_FLAT=true
odin run tests/rollback -collection:ps=. -define:PS_FLAT=true
odin run tests/ps2_interp -collection:ps=.
odin run tests/ps2_interp -collection:ps=. -define:FALLBACK_COUNT=true
odin run tests/ee_syscall_handler -collection:ps=.
odin run tests/ee_syscall_handler -collection:ps=. -define:PS_FLAT=true
odin run tests/psx_bios -collection:ps=.
odin run tests/psx_bios_libc -collection:ps=.
odin run tests/disc -collection:ps=.
odin run tests/host_frames -collection:ps=.
odin run tests/data -collection:ps=.
odin run tests/mod -collection:ps=.
odin run tests/psx_mod -collection:ps=.
odin run tests/psx_mod -collection:ps=. -define:PS_FLAT=true
odin run tests/psx_mod_region -collection:ps=.
odin run tests/psx_mod_region -collection:ps=. -define:PS_FLAT=true
odin run tests/psx_mod_native -collection:ps=.
odin run tests/psx_mod_native -collection:ps=. -define:PS_FLAT=true
odin run tests/ps2_mod -collection:ps=.
odin run tests/ps2_mod -collection:ps=. -define:PS_FLAT=true
odin build tests/ps2_mod -collection:ps=. -target:wasi_wasm32 -extra-linker-flags:"--export-table --growable-table" -out:ps2_mod.wasm
node tests/ps2_mod/run.mjs ps2_mod.wasm
odin run tests/ps2_mod_elf -collection:ps=.
odin run tests/ps2_mod_elf -collection:ps=. -- interp
odin run tests/ps2_mod_elf -collection:ps=. -- native
odin run tests/ps2_mod_elf -collection:ps=. -define:PS_FLAT=true
odin run tests/mod_api -collection:ps=.
odin run tests/read_dir -collection:ps=.
odin build tests/read_dir -collection:ps=. -target:wasi_wasm32 -out:read_dir.wasm
node tests/read_dir/run.mjs read_dir.wasm
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
| `core` | Coroutines, snapshots, rollback, file writes, PS2 ELF loading, the mod set in input records and replays, netplay HELLO checks, a full emulated heap ending the process (a child run) |
| `native` | The machine-code emitter |
| `ee_native` | EE instructions through the native backend against the interpreter |
| `wasm_sigs` | Every runtime procedure native code imports (`ps2.native_imports`, `psx_native.imports`) has a signature in `r5900.EE_SIGS` or `r3000.R3000_SIGS`, the signatures wasm32 code calls them with, each agrees with its procedure (Odin convention, argument count, a result or none, every argument and result fits one i32), and no signature lacks an import |
| `ee_spin` | The EE spin skip on synthetic loops: on and off end the same, cycles included; a pure spin, a same-value store, an INTC_STAT poll and two threads at one priority handing the EE back and forth with RotateThreadReadyQueue are skipped, and end the same when the other thread rotates at two sites in turn; a counter, a GIF_STAT poll and a timer poll are not |
| `fpu` | EE FPU vectors |
| `lower` | r5900 and r3000 branch lowering |
| `discover` | Functions with no prologue that tables of methods in a writable code section point at: thunks, leaves and jumps on through a register, stubs in a row included, are entries; code after a `b` or a `j` inside a function, code that calls or uses `$sp`, data after a `jr` with stray fields or a jump in a delay slot, a jump table's cases (tables of functions next to each other in one run included) and a pair of words are not |
| `gs_hw` | The Vulkan GS against the software GS, bit for bit, at scales 1 to 3, run twice each: sprites that sample the buffers they draw: the frame as CT32 (decoded, and too big to decode at scale 3), as PSMT8 through a CLUT, in region repeat, on the top pages wrapping to page 0, sampled past its buffer's width, and the depth buffer as a texture; and a decoded texture sampled again after PSMT8 rows uploaded over it at an odd width, and after one page of it uploaded again; and two sprites on one state, the second sampling what the first drew. Without a Vulkan device it prints `gs_hw: skip, no Vulkan device` and exits 0, which is a skip, not a pass |
| `vu` | VU0 microprograms from the EE, macro flags |
| `vu_macro` | The EE recompiler's VU0 macro code against the interpreter |
| `ee_emit` | The EE recompiler's inline MMI, multiply-add and FPU code against the interpreter |
| `vu_micro` | Whole VU microprograms through the VU recompiler against the interpreter |
| `vu_native` | VU microprograms through the native backend against the interpreter |
| `spu` | SPU2 voices through the port API, sound RAM in snapshots |
| `ps2_kernel` | EE kernel threads, ExecPS2 |
| `blob_arch` | A native code header is valid only with this build's arch: arch 0 and wasm32's (4) are refused on a native build, every machine-code arch on a wasm build, and native_load refuses another arch before it maps anything |
| `ps2_iop` | The IOP CPU and the IOP modules run on it, and the raw memory card image behind the HLE card driver |
| `rollback` | Under FLAT (the build only runs that way): a rewind to a commit gives the save state taken at it, byte for byte, after the emulated heap's top block is freed and its bytes written over, and with a block made in heap pages no scan had read, over a freed one's bytes |
| `iop_thread_grow` | An IOP start that grows the thread array while it runs is removed once it returns, in the coroutine model and under FLAT: the same thread count |
| `ps2_interp` | Whole EE functions in the interpreter |
| `ee_syscall_handler` | A SetSyscall handler switched away from (an alarm wakes a thread of higher priority) and sleeping, in the coroutine model and under FLAT: the same log and cycles |
| `psx_cover` | Which R3000 encodings each PS1 backend does inline |
| `psx_fallback` | The PS1 ways out of recompiled code and their counts |
| `psx_codewatch` | Recompiled PS1 code demoted when a write changes it, promoted again when it is back |
| `psx_learned` | Learned PS1 runs compiled, run native only while RAM holds their code |
| `psx_flat_learn` | LEARN under FLAT (FLAT builds only): a run on the shadow stack when its flat run stops stays open across the stop and is written once when it returns, covering the words fetched on both sides, a store another thread made into it meanwhile marking it `.Smc`; a run from code a standalone blob left to the interpreter (an entry, or inside a range) not written; a run that never returns is written `.Open` at the report |
| `iop_learned` | Learned IOP runs native only while IOP RAM holds their code, through host writes and snapshot loads |
| `ee_learned` | Learned EE runs native, where no function is registered, only while RAM holds their code, through host and DMA writes and snapshot loads, one version per code at an entry; runs stored into or too large are not compiled |
| `psx_unaligned` | Fused PS1 unaligned words |
| `psx_gte` | GTE register moves as native code |
| `psx_timer` | Root counter timing |
| `psx_access_cycles` | The cycles a PS1 load or store off RAM, an mtc0 to SR and a syscall see, interpreted and learned alike, in the coroutine model, under FLAT and built for `wasi_wasm32` (`run.mjs`, Node 24 or newer, the learned function as wasm32 code): every instruction before it and its own, right after a label the block before falls into, in a delay slot, and as a load and the instruction after it |
| `psx_gpu_upload` | VRAM uploads a run at a time, as a pixel at a time: row wrap, a dropped half word, mask bits |
| `psx_bios` | BIOS events, counters and IRQs, the executable loaders |
| `psx_bios_libc` | The BIOS C library |
| `psx_interp` | The PS1 interpreter's jumps into the BIOS |
| `disc` | Disc images, cue sheets and ISO9660, malformed ones included; disc ids; the IOP's file lookups on an image |
| `host_frames` | Each host, headless, exits at FRAMES |
| `data` | The user data directory and its cached native code |
| `mod` | Mod manifests (mod.tsv), the order mods load in, and hook chains: before hooks in load order, after hooks in reverse, at most one replace; the hooked set's hash, the same in the runtime and the recompiler, pinned |
| `psx_mod` | Mod hook chains installed in the PS1 dispatch tables: executable and overlay functions, recompiled and interpreted, nested hooks, frozen time, install errors; `mod_call_original` runs the innermost replacement's original without hooks, each thread's own across a BIOS thread switch, and is fatal from a hook or with no replacement; under FLAT, a stop inside the original, the replacement, or an original the replacement called resumes into the after hooks |
| `psx_mod_region` | The PS1 mod region and loader: mod ELF and overlap errors, a mod loaded from `mods/` running its hook from the region on its stack, RAM untouched, the region put back by a checkpoint pass, not learned, and a stack overflow fatal; the mod set noted before the input record opens, as its second line |
| `psx_mod_native` | PS1 mod functions as native code: `.symtab` functions, the mod set hash, a mod function's calls run native from a blob with the interpreted result, through a checkpoint pass, a stale blob refused and interpreted, a store into mod code fatal; under FLAT, interpreted |
| `ps2_mod` | EE mod hooks on a guest program, in the recursive model and under FLAT: before and after hooks on the mod stack with every register put back, the after hooks seeing the entry arguments; a replacement calling its original; the chain reached by a call, a tail `j` and `jr`, recompiled code's call table, and host code, but not by a function's jump to its own entry; no chain with the kernel's `text_off` or other code at the key; key refusals (slot, program, address, code), a second load and a hooked set the recompiled code was not built for refused; `mod_call_original` fatal with no replacement, from a before hook and from inside an original; built for `wasi_wasm32` (`run.mjs`, Node 24 or newer), the unhooked functions as a wasm32 blob whose tail jumps reach the chain |
| `ps2_mod_elf` | An EE mod built from C by `mods/build.sh` (n32), read from its directory (`mods_read`) and loaded on a hand-assembled game, recursive (with and without a recompiled original) and under FLAT: the committed API is `--mod-api`'s for the game and, with clang and lld of the major version `clang.txt` names, the committed `mod.elf` is `mod.c`'s build; hooks and a replacement seeing, passing on and returning 64-bit values; a replacement calling its original with 8 arguments and a game function with 9 (the ninth on the stack); a before hook and a replacement changing all 128 bits of `s0` and clobbering `$f21` and `$f31`, which the game sees as it left them after; `mod_f2i` truncating a negative float |
| `read_dir` | `core.read_dir`, the listing code that runs on the web uses, on the host and built for `wasi_wasm32` (`run.mjs`, Node 24 or newer): every entry once with its type, no `.` or `..`, past `fd_readdir`'s first buffer, an empty and a missing directory; on wasi the toolchain's own listing asserts on the first entry |
| `mod_api` | The PS1 mod API (`recomp --mod-api`) against committed `mod_api.h` and `mod.ld`, in any row order: names, aliases and left-out rows, error rows and a short overlay, the region constants and `mod_call_original`'s address; with clang, ld.lld, llvm-nm and sh, `mods/build.sh` builds a mod whose hooks read back with the right keys and a replacement that calls `mod_call_original` at its address, with no `jal` or `j` out of the image except in controls built without `long_call`, and refuses overlapping images by name; builds fail for a mod defining a game function's name or `mod_call_original`, an unplaced section, an image past the region, and a bad `--origin`. The EE's on a hand-made ELF against committed `ee/mod_api.h` and `ee/mod.ld`: the functions recomp finds, plain calls, keyed by the id the kernel gives the same ELF, unchanged by a `words` patch, a native blob built with `mod_hooks` naming its hooked set by import slot, and the region constants; with llvm-objdump too, `build.sh` builds an EE mod whose hooks read back with those keys and whose calls into the game and `mod_call_original` are plain `jal`, and fails a mod with a 64-bit multiply, a double or `(int)f`; with llvm-mc, `build.sh`'s float operations are exactly the decoder's |
| `compat` | Each host's compat line, and stubbed calls, under COMPAT; the mod set in the build column |
| `play` | `play` on small synthetic PS1 discs, converted and interpreted, and its compat mode on PS1 and PS2 discs, a second executable loaded and a PS2 program switch included; the launcher, its picture checked by point and a non-ASCII title cell by cell against the font |
| `discimg` | The small disc images `disc` and `play` use |

## Compatibility runs

`play --compat` runs each disc once. A run records the code it
interpreted (`learn/psx.bin` in the disc's folder for a PS1 disc; for a
PS2 disc its I/O processor code and its EE code, `learn/ps2.bin`), as
every run does by default; a later run, compat or not, compiles those
records and runs that code natively, a PS1 game's and the EE's only while
memory holds the code it was compiled from. The `learned` column
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
each of Start, Cross, Circle, Up, Down and the left stick pushed up held
for 60, loads the state back after each, and counts the bytes of EE RAM
each input left different. Every input at 64 or fewer is a deaf probe;
two in a row are a `stuck` stretch in the compat line, from the first
to the last.
The branches count nothing, note no learn records, write no card or
progress file, and push no sound, so the run after a probe is the run
without one (`PS_DUMP_HASH` is the same with `PS_COMPAT_PROBE=0`). A
warm run has no new entry pcs, so it is quiet whenever it loads no IRX.

### Timing a run

Time a run warm: run it once cold first, so it records the code it
interprets, then time a second run, which compiles those records and runs
them natively. A cold run spends its time in the interpreter on code the
next run will not interpret, so a speed compared from cold runs measures
how much each side interprets, not its code. Learned code and the
interpreter see the same cycles at every access (psx/cpu/interp.odin), so
a warm run and a cold one of a PS1 disc play the same. The one exception
is a fused lwl/lwr or swl/swr pair, which learned code charges at its
first word for both halves: it shows only off RAM, on ROM (constant) or
I/O (no game reads a timer unaligned).

### Press scripts with conditions

A `PS_PRESS` entry (core/input.odin input_script_load; the README has the
plain form) can wait on main RAM. `?<cond>~<n>` after the timing makes it
conditional, where `<cond>` is `u8`, `u16` or `u32`, a hex address in
brackets, `==` or `!=`, and a value (decimal or `0x` hex). Values are
little-endian, a `u16` or `u32` address must be aligned, and an address is
taken `& 0x1fffffff`, so `801f2a40` (PS1) and `00123450` (PS2) both name
main RAM; one outside it is a bad entry.

- `Cross@900?u8[801f2a40]==3~600`: from frame 900, press Cross at the first
  frame the byte is 3.
- `LUp@900*20?u8[801f2a40]==0~400`: at frames 900, 920, 940, ... press LUp
  while the byte is not 0; at the first of those frames it is 0, end
  without a press. `*<n>` must be more than the hold.
- `@900?u8[801e0010]!=0~3000`: no names, only wait.

The condition is checked once a frame, as the frame is counted (PS2:
presented frames, PS1: presents), with RAM as it stands then, so a run
replays exactly and snapshots and rollback keep the script's state.

When a conditional entry ends at frame t, every entry after it in the text
moves t - (its frame) frames later. That is every later entry in text
order, whatever its frame, not only the ones timed after it: write a
route in the order it is played. A conditional entry also holds back the
entries after it in the text until it ends. A script with no condition
runs as it always did.

The `~<n>` window is inclusive: from frame 900, a wait with `~600` reads
the condition at frames 900 to 1500, 601 checks. A repeat reads it at each step and also
at the last frame, step or not, so `LUp@900*20?...~30` ends at 930 if the
condition holds there. Numbers are decimal or `0x` hex,
without `_` separators.

Conditions are a test tool: with netplay on, a script with one does not
load.

A condition not met by the last frame of its window ends the run at once
with status 1 and prints `PRESS: <entry> timed out at frame <f>
(<width>[<address>]=<value read>)`. A compat run's row has result `watch`
and that message in `fatal`.

To find the address, dump RAM around a few presses that move what the
script must watch: on PS1 `PS_DUMP=<dir> PS_DUMP_RAM=1` (with
`PS_DUMP_FROM` near the presses, as every present is 2 MB), on PS2
`PS_DUMP=<dir>` (32 MB a frame). Then `play --ramdiff <dir> <frame>
<frame> ...` prints each byte that changed between every two frames named
in a row, with its value at each, as a condition writes the address; a
frame written `=<frame>` wants the byte unchanged since the one before. A dump must be PS1 (2 MB) or PS2 (32 MB) main RAM.
For a cursor moved at frames 1000 and 1100:
`play --ramdiff dump 990 =999 1010 1110`.

### Pictures and dumps

`PS_SHOT=<vblank>,<vblank>,...` (PS2 only, read in ps2/host/platform.odin)
writes `shot_<vblank>.ppm` into the working directory at each listed
vblank, in ascending order. Shots count vblanks, as `PS_FRAMES` does, so a
shot at the last frame is the picture the compat `lit` column counts. With
the display off at that vblank no file is written and the run prints
`shot: vblank <n>, display off, none written`. A headless run without
`PS_FRAMES` exits after its last shot; with `PS_FRAMES` it runs on to that
count. The PS1 host does not read `PS_SHOT`.

A change to the Vulkan GS gets a run of a game's `PS_SHOT` set twice on
Vulkan, each in a directory of its own, then `cmp` of each pair: the GPU
is meant to give the same picture every run, so a pair that differs is a
race (the software GS differs from it by rounding, so it is no reference here).

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

`PS_DUMP` also writes `ram_interp_<addr>.bin`, the processor's whole 2 MB
RAM, for every address the R3000 interpreter first enters (the PS1 CPU, or
the IOP on PS2; psx/cpu/cpu.odin report_once), with `PS_DUMP_HASH=1` too.
A run that interprets many functions writes many: about 545 MB in a
3600-frame PS2 run.

## What a disc calls that the HLE lacks

`tools/hle_scan` reads discs, without running them, for the calls their
own code makes into Sony code, and checks each one against what the HLE
serves. Run it from the repository root, since it reads the HLE's
sources:

```
odin run tools/hle_scan -collection:ps=. -- [-bios <ROM0>] <disc> ...
```

It looks at every ELF that starts on a word boundary in a disc's files,
and at each module of a ROMDIR image (an `IOPRP*.IMG`). A module is
Sony's or the game's as LOADFILE judges it (`iop.iop_runs`); an IOPRP
image's modules are Sony's, as the HLE stands in for them at an IOP
reset. Only the
game's modules run on the R3000, so the IOP rows are their imports of
Sony libraries: one row per library, major version and function number,
with the discs and modules that import it, `hle` (`y`, `n`, or `major`
when only another major is served), and `start`, the discs where a call
graph walk from a module's entry reaches the call. That walk follows
`jal`, `bal` and `j`, but not calls through a register, so a call it
does not reach may still run at start. The EE rows are the syscall
numbers loaded into v1 just before a `syscall`: the kernel library's
wrappers, which a program links whether or not it calls them. The PS1 rows are the
A0/B0/C0 calls of each PS-X EXE. Missing rows sort first, and then by
how many discs need them.

What is served is read from the switch statements: `hle_fn` and the
procs its cases hand `fno` to, the kernel's `switch abs(n)`, and
`bios_a`/`bios_b`/`bios_c` with `a0_from_b0`. A served case may still
refuse some arguments. Modules inside compressed archives are not seen.
`-bios` takes a retail ROM for reference only (never commit it): the
`rom` column says whether the ROM's module exports the function, and
the per-library summary gives its export count.

## Netplay on one machine

Two headless players on loopback test rollback netplay (core/net.odin)
in either build. Each peer is one process: `PS_NET_BIND` is its own
address, `PS_NET_PEER` the other's, `PS_NET_PLAYER` its slot (1 or 2).
`PS_NET_DELAY` is the input delay in frames (default 2, at most 8),
`PS_NET_HASH` the frames between desync checks (default 60). For tests,
`PS_NET_LAG` adds one-way latency in ms, `PS_NET_DROP` drops that
percent of outgoing packets and `PS_NET_ANY_BUILD=1` takes a peer that
runs another build (both peers print `net: build check off (testing)`);
`PS_PACE=<hz>` paces a headless run, and a different rate on each peer
stands in for clock drift. Give each peer
its own press script (`PS_PRESS`, without conditions) so the peers'
inputs differ and change.

A run with an input delay longer than the latency never predicts, so it
never rolls back: it is the reference. A run with the same delay and
scripts but more latency than the delay (or drops) predicts, rolls back
and reruns, and must reach the same machine at every frame:

```sh
net() { # <out dir> <player> <bind port> <peer port> <press> [VAR=value ...]
	out=$1 p=$2 bind=$3 peer=$4 press=$5; shift 5
	mkdir -p $out
	env PS_SW=1 PS_HEADLESS=1 PS_FRAMES=3600 PS_DUMP=$out PS_DUMP_HASH=1 \
		PS_DUMP_EVERY=60 PS_DATA=$out/data PS_NET_PLAYER=$p \
		PS_NET_BIND=127.0.0.1:$bind PS_NET_PEER=127.0.0.1:$peer \
		PS_PRESS=$press "$@" ./play path/to/game.iso 2>$out/log &
}
A=Start@300,Cross@400,Cross@430,LUp@900+60,Cross@1000,Cross@1030
B=Cross@350,Circle@700,LLeft@900+40,Cross@990,Circle@1020
net ref1 1 7000 7001 "$A" PS_NET_DELAY=8
net ref2 2 7001 7000 "$B" PS_NET_DELAY=8
wait
net rb1 1 7000 7001 "$A" PS_NET_DELAY=8 PS_NET_LAG=200 PS_PACE=60
net rb2 2 7001 7000 "$B" PS_NET_DELAY=8 PS_NET_LAG=200 PS_PACE=57
wait
grep 'net:' ref1/log rb1/log # rollbacks, frames rerun, max back, desync
last() { awk -F'\t' '{h[$1"\t"$2]=$3} END {for (k in h) print k"\t"h[k]}' $1/hashes.tsv | sort; }
for p in 1 2; do cmp <(last ref$p) <(last rb$p); done
```

The reference must report 0 rollbacks, the rollback run some rollbacks
and frames rerun, both `desync -1` with hashes compared. A rerun frame
is dumped again, so only the last line per kind and frame is compared.
`max back` is the deepest rollback in frames rewound, 1 being the
current frame's start; `RB_FRAMES` (core/rollback.odin) is the whole
ring, back to `RB_FRAMES - 1` frames before the current one. Delay 8
with `PS_NET_LAG=250` reaches it. Build `play` with
`-define:PS_FLAT=true` for the FLAT run; the reference is the same pair
in the same build.

### Netplay on wasm

play.wasm has no sockets: core/net_wasi.odin hands its datagrams to the
host's `system:ps_net` imports (`web/net.js`), through SharedArrayBuffer rings
served by a thread that is not the module's. Its build id is the first 8
bytes of the module's SHA-256.

Under Node, `tests/wasi/play.mjs` with `PS_NET_PEER` set serves the rings
with a UDP socket (`tests/wasi/netlink.mjs`), with the same `PS_NET_*`
settings as a native peer (IPv4 addresses, not names). So a wasm peer
plays a native FLAT one: run the `net` pair above with one side as
`node tests/wasi/play.mjs <page dir>/play.wasm $out path/to/game.iso 3600`
and `PS_NET_ANY_BUILD=1` on both sides. Its hashes must be those of the
native FLAT pair with the same scripts and settings.
`node tests/wasi/ring.mjs` checks the rings themselves: full, empty,
oversized and empty datagrams, order, and the counts' wrap.

In the browser, two play pages are the peers, over a WebRTC data channel
(host candidates only). `serve.py --play play.wasm <disc> --net <room>`
prints the two pages' URLs; the pages find each other through its
`/signal` endpoint, which is for development only, not a server to
expose. Each page writes `p<N>/hashes.tsv` beside the result and
`<result>.p<N>.json`. Headless Chrome and Brave hide host addresses
behind mDNS names, which two pages on one machine may fail to resolve:
run them with `--disable-features=WebRtcHideLocalIpsWithMdns`
(Firefox: `media.peerconnection.ice.obfuscate_host_addresses` false).

## The wasm C maths functions

The `wasi_wasm32` build has no C library, so `core/libm_wasi.odin` supplies
the maths functions the tree calls (`sinf`, `cosf`, `expf`, `sin`, `pow`,
`exp2`, `fmax`, `fmin`), so that results match the Linux x86-64 build bit
for bit. `sinf`, `cosf`, `expf`, `pow` and `exp2` are ported from glibc and
match it on every input; `sin` is fdlibm's and matches glibc only on the
inputs the tree passes it. `tests/libm_wasi` checks them: build it for the
host and for `wasi_wasm32`, and `tests/libm_wasi/run.mjs` runs both, the
wasm under Node on `web/wasi.js`, and compares. Run it after any change to
`core/libm_wasi.odin`; it needs Node 24 or newer.

The reference is a glibc compiled for x86-64-v3 or later (FMA), such as
CachyOS's v3 and v4 packages: the ports fuse the multiply-adds that build
fuses. A stock x86-64 glibc picks FMA variants at run time for some of
these functions only, so on it the test can report differences, in `exp2`
for one, that are not bugs in the ports. `run.mjs` refuses a host build that
does not link glibc's `libm.so.6`.

Two differences remain by design. `fmax` and `fmin` follow C on a tie of
`+0` and `-0` (`fmax` gives `+0`, `fmin` gives `-0`), where the host's
`maxpd` and `minpd` pick by operand order. Their one caller,
`texels_read` in `psx/render/gpu.odin`, converts the result to `i32`, so
the sign of a zero never reaches its output; the test leaves the pair out. And a NaN result's sign and payload are
not matched: x86 makes `0/0` negative and wasm leaves NaN signs unspecified,
so the test compares every NaN as one value.

```sh
odin build tests/libm_wasi -collection:ps=. -o:speed -out:libm_host
odin build tests/libm_wasi -collection:ps=. -o:speed -target:wasi_wasm32 -out:libm_wasi.wasm
node tests/libm_wasi/run.mjs libm_host libm_wasi.wasm
```

It covers every `f32` input of `sinf`, `cosf` and `expf` (3 x 2^32
calls, 2 to 3 minutes on 8 cores), `sin` and `pow(2, y)` on the inputs the
tree passes them, `fmax` and `fmin` as `texels_read` calls them
(`simd.reduce_max` and `simd.reduce_min` on `f64` lanes) on every pair of 16 edge values
(NaNs, signed zeros, infinities, extremes, values around integers), and `pow` and `exp2` on 1310720 random inputs. It prints
each input whose result differs (the first 10000) and their count, and
exits 1 if any does; `--only s|c|e|domain` runs one part.

## The browser player

`tests/wasi/host` is the play page's gate program: built for
`wasi_wasm32` into the page's out dir, it runs in `play.html` in place of
`play.wasm` with the same SDL imports, so it needs no disc. It draws a
fixed pattern every frame (exact in 8-bit arithmetic, so the captured
frame is the same bytes in every browser), queues a 440 Hz square wave,
prints each controller and key event, and exits after 6 seconds.
`tests/wasi/serve.py --play` serves the page in its test mode, which
presses A on a fake gamepad and the Z key once the first frame is drawn,
and writes the page's report to the result file:

```sh
web/build.sh <out dir>
odin build tests/wasi/host -target:wasi_wasm32 -o:speed -out:<out dir>/host.wasm
python3 tests/wasi/serve.py <out dir> result.json --play host.wasm
python3 tests/wasi/serve.py <out dir> result.json --play host.wasm --no-isolate --port 8766
python3 tests/wasi/serve.py <out dir> result.json --play play.wasm path/to/game.iso --seconds 30
```

The test URL's `disc` parameter may name a disc on another origin only if
that server sends CORS headers and answers the preflight for the page's
`Range` requests: an isolated page (COEP `require-corp`, from the server
or `web/sw.js`) loads nothing cross-origin without them. Open each printed
URL in the browser under test. A headless browser needs
autoplay allowed for the audio to run (Chromium:
`--autoplay-policy=no-user-gesture-required`). WebKitGTK withholds
`SharedArrayBuffer` even from an isolated page unless it runs with
`JSC_useSharedArrayBuffer=1` in the environment; without it the report has
`isolated` true and nothing else, and the page says why. For host.wasm the report
should have `isolated` true, `done.code` 0, `capture` 320x240 with the same
`sha256` in every browser, `audio.frames` over zero with `audio.rms` near
0.25, the log lines `host: pad added`, `host: button 0 down` and `up`,
`host: key Z down` and `up`, and no `errors`. The `--no-isolate` run checks
the service worker path: `controlled` true and `isolated` true after the
page's one reload. `sabUpload` says whether `texSubImage2D` took a view of
the `SharedArrayBuffer` itself (false: the page copies each texture
first). play.wasm runs a game: it is a FLAT build that interprets guest
code (wasm cannot load generated code) and starts none of the
emulator's own host threads (`core.THREADS`), so it is slower than a
desktop build but computes the same frames. Its run should have
`firstPresentMs` set and no `errors`, and, with `--env PS_FRAMES=<n>`,
`done.code` 0 once it stops at that vblank; the gate run below checks
what it computes.

For a gate run, the test mode takes the module's input from the URL and
sends its output back. Every disc file after the module is served (a
`.cue` with its track files: the module opens the `.cue`); each `--env K=V` is
set in the module's environment, so the `PS_*` settings of a native run
apply; `--no-input` leaves out the fake presses, which would change the
emulation. When the module exits, the page posts each file it wrote and
`ring.pcm` (every sample it queued for the audio device, 16-bit stereo,
before the ring drops what does not fit) to the server, which writes them
beside the result file. The report adds `done.compileMs` (the module's
compile), `done.runMs` (from the module's start to its exit),
`firstPresentMs` (from the Worker's start to the first frame the page
sees), `frames` and `files` (each file's name and size). The page copies
the served disc into the browser's storage (OPFS) first and the module
reads it from there, as with a disc picked on the page; `store` in the
report says how it was read: `kind` `opfs` with `copyMs` (the copy), or,
when the copy fails (no OPFS, a full quota), `kind` `url` with the
`error` and the browser's storage `estimate`. `--store url` skips the
copy and reads the disc by URL (`kind` `url`). With
`PS_DUMP=. PS_DUMP_HASH=1`, `hashes.tsv` lands beside the result file,
and with `PS_AUDIO_DUMP=audio.wav` the mixed audio. Both must be
byte-identical to a native FLAT run with the same settings (its
command is under "The wasm player under Node" below); `ring.pcm` is not compared, since what the ring keeps
depends on the browser's audio clock:

```sh
python3 tests/wasi/serve.py <out dir> run/result.json --play play.wasm game.cue game.bin \
	--env PS_SW=1 --env PS_FRAMES=600 --env PS_DUMP=. --env PS_DUMP_HASH=1 --env PS_DUMP_EVERY=60 \
	--env PS_AUDIO_DUMP=audio.wav --no-input --seconds 600
```

Save states made by the wasm build (FLAT) do not load on a desktop build,
nor the other way round: a snapshot records which model saved it, and a
mismatched load is fatal.

## The wasm player under Node

`tests/wasi/play.mjs` runs play.wasm headless under Node 24 or newer, on
the page's shim and SDL imports (`web/wasi.js`, `web/sdl.js`), with the
software renderer, the only one a wasm build has (no `PS_SW=1` needed). It stops at a vblank (600 by default) and writes a
hash line every 60 frames to `<out dir>/hashes.tsv`. A wasi build is
always FLAT, so its reference is a native FLAT run with the same settings:

```sh
web/build.sh <page dir>
node tests/wasi/play.mjs <page dir>/play.wasm out-wasm path/to/game.iso 600
odin build play -collection:ps=. -o:speed -define:PS_FLAT=true -out:play-flat
mkdir -p out-native
PS_NATIVE=0 PS_SW=1 PS_HEADLESS=1 PS_FRAMES=600 PS_DUMP=out-native \
	PS_DUMP_HASH=1 PS_DUMP_EVERY=60 PS_DATA=out-native/data ./play-flat path/to/game.iso
cmp out-wasm/hashes.tsv out-native/hashes.tsv
```

Both runs start from an empty data directory. A `PS_*` variable set for
play.mjs is passed on to the module.

A wasm PS1 run that records its code and runs learned code compiles its
new records mid-run (play/midload_learned.odin): once they have stopped
growing for 300 frames, the records no loaded blob covers, at most 480
per compile, go to another instance of the module (`play --learned psx`),
in a Worker on the page (web/learn.js) and in a worker_thread under
play.mjs (`tests/wasi/learnlink.mjs`), and the run loads the blob it hands
back. Nothing is stored; the next run compiles its own set as before.
`node tests/wasi/learn.mjs` checks the handoff: a late blob, from a
compile before the one in flight or from the run before, is dropped, and
an empty, failed or oversized one fails. A run
with `PS_DUMP` waits for each compile, so its hashes match a run with
`PS_MIDLOAD=0`. Netplay and rollback runs never load mid-run. With
`COMMIT=test`, `PS_MIDLEARN_CHECK=1` compiles each set in the run too and
logs whether the worker's blob is the same, and `PS_MIDLEARN_STALE=1`
makes each blob stale, so it is dropped. A `COMMIT=test` build finds only
a native blob whose key names `test`.

A native PS1 run compiles the same sets in a child of the player
(`play --learned-midload`, docs/porting.md). tests/play checks it on the
built-in disc (`midlearn`): one compile, waited for, loads its record and
leaves no temporary file; with `PS_MIDLOAD_FAIL=1` the child exits 1, the
run counts the failure and goes on.

A headless PS2 game never presents, so its present count stays 0. To count
presents, run it with `PS_HEADLESS=0 node tests/wasi/play.mjs ...`: slower,
and the hashes are the same.

`tests/blob_arch` is pure, so it also runs as a wasi module, where it checks
the wasm32 arch:

```sh
odin build tests/blob_arch -collection:ps=. -target:wasi_wasm32 -out:blob_arch.wasm
node tests/wasi/run.mjs blob_arch.wasm out-test path/to/any/file
```

`tests/rollback` is pure too. As a wasi module it tests the wasm write
tracking (core/rollback_wasi.odin), which compares pages with their shadows:

```sh
odin build tests/rollback -collection:ps=. -target:wasi_wasm32 -out:rollback.wasm
node tests/wasi/run.mjs rollback.wasm out-test path/to/any/file
```

## CI

CI type-checks every package on Linux and macOS (amd64 and arm64) and on
Windows, and runs the tests on Linux (x86-64, arm64) and Windows. No CI job
runs the tests on macOS.

Before sending a change, check what it touches as CI does, with vet and
strict style:

```sh
odin check psx -no-entry-point -collection:ps=. -vet -strict-style
odin check recomp -collection:ps=. -vet -strict-style
odin check recomp -collection:ps=. -target:wasi_wasm32 -vet -strict-style
odin check tests/core -collection:ps=. -vet -strict-style
```

The runtime packages (`core`, `core/disc`, `core/learnfile`, `psx`, `ps2`,
`ps2/host`) and `tests/discimg` take `-no-entry-point`; `recomp`, `play`
and the tests do not. Add `-target:` to check another platform, as CI does
for `linux_arm64`, `darwin_amd64` and `darwin_arm64`. recomp is also
checked for `wasi_wasm32`, the target of the web converter: a recomp
import of a package that needs the host (such as `core`) fails there.
The web page's scripts have no build step; `node --check` each of
`web/*.js` and `tests/wasi/*.mjs` after editing them.
