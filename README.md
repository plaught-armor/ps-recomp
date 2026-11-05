# ps-recomp

Play PlayStation and PlayStation 2 games from your own discs as native
programs on your computer.

## What this is

Most emulators work out each console instruction while the game runs.
ps-recomp works differently. It converts the game's code to native code for
your computer ahead of time. This is called "static recompilation". The
converted game then runs on a built-in stand-in for the rest of the
console: graphics, sound, controllers, memory cards and the console's
system software.

**You bring the game.** This project contains no game code or data. It
also needs no console BIOS file, and it ships none. The console's system
software is rewritten as part of this project. This is known as high-level
emulation, or HLE. All you need is a disc image made from a disc you own.

There are no prebuilt downloads. You build the program yourself with the
Odin compiler. The steps are below.

<https://plaught-armor.github.io/ps-recomp/> is a disc converter that
runs in your browser, with nothing uploaded. Use what it makes with a
player built from the commit the page shows (see
[how it works](docs/how-it-works.md)).

## Project status

ps-recomp is a work in progress. Not every game runs. A game that starts
may still have bugs.

| System | Status |
|---|---|
| Linux | The only system games have been played on. Automated tests run on x86-64 and arm64. |
| Windows | Untested with games. Only the automated tests have run here. |
| macOS | Untested. The code is type-checked for macOS, but neither games nor the automated tests run there. |

## What you need

- [Odin](https://odin-lang.org), version `dev-2026-10`.
- SDL2. It provides the window, input and sound.
- Vulkan 1.3, for graphics. Both consoles can also draw in software
  instead; see [Settings](#settings).
- A PS1 or PS2 disc image made from your own disc. This can be a `.cue`
  sheet, or a single-track `.bin` or `.iso` file.

You do not need a BIOS file.

## Install

Get this repository, then run this from its top folder:

```sh
odin build play -collection:ps=. -o:speed -out:play-bin
```

This builds a program called `play-bin`.

A build made this way counts as a development build. It converts the game
again every time you start it. To keep the converted code between runs,
add `-define:COMMIT=<hash>` with the current commit hash:

```sh
odin build play -collection:ps=. -o:speed -define:COMMIT=$(git rev-parse HEAD) -out:play-bin
```

## Play a game

```sh
./play-bin path/to/game.cue
```

The first time you run a disc, `play` converts the game to native code.
It shows its progress while it works. The result is saved, so later runs of
the same build start at once.

If the conversion fails, the game still runs, but slowly. It then runs
through an interpreter, which works out each instruction as it goes.

## The launcher

Run `play-bin` with no disc to open the launcher:

```sh
./play-bin
```

It shows your library of discs. To add one, drag a disc image (`.cue`,
`.iso` or `.bin`) onto the window, or a folder to add every image in it.
The launcher remembers where each image is. It never copies or moves the
file. If you move or delete an image, its disc shows as missing in red;
you can then take it off the list. Its saves are kept.

The selected disc shows its picture from the last time you quit it, and
its result from [the compatibility check](#check-which-of-your-games-run).
Start a disc and the launcher hides until the game ends. If the game
fails, the launcher shows the last line it printed. Everything it printed
is also kept in `play.log` (see [Where your files go](#where-your-files-go)).

Export makes a new git-ready folder for the selected disc, to study the
game in and tune it by hand. It goes in `ps-recomp-ports` in your home
folder, named after the disc (with ` 2`, ` 3` and so on added when the
name is taken), and the launcher says where. The folder holds notes, the
disc's settings, its last picture and a port of the game to build (see
[Start from an export](docs/porting.md#start-from-an-export)). The disc
image stays where it is and is never copied. `./play-bin --export <disc
image> <folder>` does the same into a folder you name, which must be
missing or empty.

The settings screen changes [settings](#settings) for the selected disc
or, after a switch, for all discs. A change is saved at once. Each row
says where its value comes from:

| Shown | Where the value comes from |
|---|---|
| `(set by PS_...)` | An environment variable. It wins over everything, and the launcher cannot change it. |
| `(this disc)` | This disc's own setting. It wins over all discs. |
| `(all discs)` | The setting for all discs. |
| nothing | The default. |

Clearing a row removes the setting from the screen you are on, so the
next one down holds.

| Action | Keyboard | Controller | Mouse |
|---|---|---|---|
| Move up or down | Up / Down | D-pad or left stick | Wheel |
| Move a page | Page Up / Page Down | L1 / R1 (LB / RB) | |
| Play the disc (list) | Return | A | Double-click |
| Play the disc (either screen) | | Start | |
| Open the settings (list) | Tab | X | |
| Switch this disc / all discs (settings) | Tab | X | |
| Change a setting | Left / Right, or Return for the next choice | D-pad or left stick left / right, or A | Double-click the row |
| Clear a setting (settings) | Delete | Y | |
| Export the disc (list) | X | Y | |
| Take a missing disc off the list | Delete | Y | |
| Back to the list | Esc or Backspace | B | |

The controller column is read from the code. It has not been tried with a
controller. Dropping a folder has been tested only by the automated tests.
The launcher has only been run on Linux. On Windows and macOS it is
untested, and so is an export and the port it holds.

## Controls

A game controller works with the usual layout. The buttons map by
position:

- A is Cross, B is Circle, X is Square and Y is Triangle.
- The triggers are L2 and R2.
- Clicking the sticks gives L3 and R3 on PS2.
- Back is Select.

The keyboard defaults differ by console:

| PlayStation button | PS1 | PS2 |
|---|---|---|
| D-pad | Arrow keys or W A S D | Arrow keys |
| Cross | E | Z |
| Circle | Esc or left Shift | X |
| Square | Tab | A |
| Triangle | Space | S |
| L1 / R1 | Mouse wheel | Q / W |
| L2 / R2 | Q / R | 1 / 2 |
| Start | Return | Return |
| Select | Backspace | Right Shift |

On PS1, the left and right mouse buttons are also Cross and Circle.

## Settings

Settings are environment variables. Each name starts with `PS_`. Put the
setting before the command, like this:

```sh
PS_GPU=sw ./play-bin path/to/game.cue
```

| Setting | What it does |
|---|---|
| `PS_DATA` | The folder where your files go. See [Where your files go](#where-your-files-go). |
| `PS_GPU` | PS1 only. `vk` draws with Vulkan (the default). `sw` draws in software. |
| `PS_SW` | PS2 only. `1` draws in software. Otherwise PS2 games draw with Vulkan. |
| `PS_SCALE` | PS2 only. The window size, as a multiple of the console's resolution. 1 to 8. The default is 3. |
| `PS_IRX` | PS2 only. By default, a game's own sound and input/output modules run on an emulated copy of the console's I/O processor. `0` turns that off: each module is answered as loaded, without running it. |
| `PS_NATIVE` | `0` runs the game through the interpreter instead of as native code. Slower; for checking a bug. |
| `PS_LEARN` | By default, a PS2 game's I/O processor code (its own modules, loaded from the disc) is recorded in the disc's folder as it runs, and later runs use native code compiled from it. `1` records the code every processor interprets. `0` records nothing and uses no learned code. |
| `PS_VU_CAPTURE` | PS2 only. `1` records the game's vector unit microcode in the disc's folder as it runs, for a [port](docs/porting.md#vu-microcode) to compile. Off by default: the vector units then run through the interpreter, so the game is slower. Each run adds to the record. Later runs without it run the recorded microcode as native code. |

`PS_GPU`, `PS_SW`, `PS_SCALE`, `PS_IRX` and `PS_NATIVE` can also be set
in the [launcher](#the-launcher). It keeps them in `settings.tsv` files:
one for all discs in the data folder, and one in each disc's folder. An
environment variable always wins over both.

Other settings exist, mostly for debugging. They are described in the code
where each one is read. See [docs/how-it-works.md](docs/how-it-works.md#settings-in-the-code).
`PS_TTY` is not a setting: the launcher sets it for the games it starts.

### Where your files go

Saves, memory cards and converted code are kept for each disc in a user
data folder, under `discs/<disc id>/`. So are the disc's launcher
settings (`settings.tsv`), its picture (`thumb.ppm`) and the output of
its last launcher run (`play.log`). The launcher's list of discs is
`library.tsv`, and the settings for all discs are `settings.tsv`, both in
the data folder itself.

| System | Default location |
|---|---|
| Linux | `~/.local/share/ps-recomp` |
| macOS | `~/Library/Application Support/ps-recomp` |
| Windows | `%APPDATA%\ps-recomp` |

Set `PS_DATA` to use a different folder.

## Check which of your games run

`play` has a compatibility mode. It runs games without a window and
reports how far each one got:

```sh
./play-bin --compat path/to/discs [frames]
```

You can give it one disc image, or a folder. For a folder, it runs every
`.cue`, `.iso` and `.bin` file in it.

Each game runs in its own process, with no window and no speed limit. It
runs for a set number of vblanks. A vblank is the console's signal that
comes once per screen refresh. The count is the `frames` argument. Without
it, the count is `PS_FRAMES`, or else 3600.

In this mode, unknown BIOS calls and system calls are skipped, so that a
run can keep going.

Each game gets one row in `compat.tsv`, in the user data folder. The row
holds the game's latest run. It says how the run ended, how much of it
went through the interpreter, and which calls were skipped. The result is
one of these:

| Result | Meaning |
|---|---|
| `ok` | Reached the vblank count. |
| `stalled` | Reached the count, but showed no picture, or main memory stopped changing over the second half. |
| `fallback` | Reached the count and made progress, but a module on the emulated I/O processor failed to load, and the built-in stand-in took over. |
| `exit` | The game ended. |
| `fatal` | The program stopped on a fatal error. |
| `crash` | The run crashed. It ended without writing its result. |
| `hang` | Stopped because no new vblank came for `PS_COMPAT_WAIT` seconds (default 120), or for 5 times that before the first vblank. A slow game that keeps going is never stopped. |
| `spawn` | The game's process could not be started. |

Each game's output goes to `compat.log`, in its `discs/<disc id>/` folder.
If a `press.txt` file is in that folder, it is used as the game's scripted
button presses (`PS_PRESS`).
`PS_SHOT=<vblank>,...` saves the picture at those vblanks on a PS2 disc;
on a PS1 disc, `PS_DUMP=<dir>` saves frames. docs/testing.md has the
details.

Each game starts on blank memory cards, so a save left by an earlier run
does not change what the game does. They are kept in `compat-cards` in the
disc's folder and emptied before each run; the disc's own `cards` are not
touched. Set `PS_COMPAT_CARDS=keep` to run on the disc's own cards
instead, as a normal run does, for example to check that a save loads.
The `cards` column says which: `fresh`, `kept`, or `kept-empty` (kept, but
the disc's cards held no files). Run one compatibility run of a disc at a
time: two at once in the same data folder share its `compat-cards`.

A PS2 run also checks whether the game still answers its controller.
Once it has been quiet for a minute (no new module loaded, and no code
run through the interpreter for the first time), it saves its state and
tries a few buttons from it, one at a time: Start, Cross, Circle, Up and
Down, each against pressing nothing. It then loads the state back and
goes on as if nothing happened. If no button changed more than 64 bytes
of main memory, the game ignored it. Two such checks in a row are listed
as a `stuck` stretch in the game's compat line. `PS_COMPAT_PROBE` sets
the vblanks of quiet before each check (default 3600, a minute); `0`
turns the check off. A run of a game that already has learned code for everything
it runs is quiet whenever it loads nothing.

A press script is a comma-separated list of `<name>@<frame>` entries, for
example `Start@600,Cross@900+10,LUp&LRight@1200+300:2`:

- `<name>` is a button (`Cross`, `Circle`, `Square`, `Triangle`, `Start`,
  `Select`, `Up`, `Down`, `Left`, `Right`, `L1`, `L2`, `L3`, `R1`, `R2`,
  `R3`) or a stick pushed fully one way (`LUp`, `LDown`, `LLeft`, `LRight`
  for the left stick, `RUp`, `RDown`, `RLeft`, `RRight` for the right), in
  any case. `&` joins several names into one entry, so `LUp&LRight` is a
  diagonal and `Cross&LRight` presses a button while moving. Entries that
  overlap in time combine too.
- `+<n>` after the frame holds the entry for `n` frames instead of a short
  tap.
- `:<n>` at the end presses on player `n` instead of player 1.

## Report a problem

Open an issue on the project's GitHub page. Please include:

- Your system (Linux, Windows or macOS) and its CPU type.
- The ps-recomp commit you built from (`git rev-parse HEAD`).
- The command you ran, with any `PS_` settings.
- What you expected, and what happened instead.
- The text `play` printed in the terminal.
- If you can, a compatibility run of the game: its row from `compat.tsv`
  and its `compat.log`. See [Check which of your games run](#check-which-of-your-games-run).

Do not attach disc images or game files.

## For developers

These pages cover the internals:

- [How it works](docs/how-it-works.md): the recompiler, the runtime, the
  repository layout, and how to use `recomp` directly.
- [Making a port](docs/porting.md): turning one game into its own native
  program, with its own fixes and features.
- [Tests](docs/testing.md): the test list, what CI runs, and how to check a
  change before sending it.

## License

GPL-3.0; see [LICENSE](LICENSE).
