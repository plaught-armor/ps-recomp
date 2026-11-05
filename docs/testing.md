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
odin run tests/ee_syscall_handler -collection:ps=.
odin run tests/ee_syscall_handler -collection:ps=. -define:PS_FLAT=true
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
| `ee_spin` | The EE spin skip on synthetic loops: on and off end the same, cycles included; a pure spin, a same-value store, an INTC_STAT poll and two threads at one priority handing the EE back and forth with RotateThreadReadyQueue are skipped, and end the same when the other thread rotates at two sites in turn; a counter, a GIF_STAT poll and a timer poll are not |
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
| `ee_syscall_handler` | A SetSyscall handler switched away from (an alarm wakes a thread of higher priority) and sleeping, in the coroutine model and under FLAT: the same log and cycles |
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
each of Start, Cross, Circle, Up, Down and the left stick pushed up held
for 60, loads the state back after each, and counts the bytes of EE RAM
each input left different. Every input at 64 or fewer is a deaf probe;
two in a row are a `stuck` stretch in the compat line, from the first
to the last.
The branches count nothing, note no learn records, write no card or
progress file, and push no sound, so the run after a probe is the run
without one (`PS_DUMP_HASH` is the same with `PS_COMPAT_PROBE=0`). A
warm run has no new entry pcs, so it is quiet whenever it loads no IRX.

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
first). play.wasm cannot run a game yet: guest code has no way to run on
wasm (`core/code_wasi.odin`), so console start-up stops at a runtime
assertion. Its run checks that the page loads the module and reads the
disc, and that the assertion reaches the report's `errors` with
`done.code` -1.

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
`web/*.js` and `tests/wasi/run.mjs` after editing them.
