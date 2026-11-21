# ps-recomp

Play PlayStation and PlayStation 2 games from your own discs as native
programs on your computer.

## What this is

Most emulators work out each console instruction while the game runs.
ps-recomp converts the game's code to native code for your computer ahead
of time ("static recompilation"). The converted game runs on a built-in
stand-in for the rest of the console: graphics, sound, controllers, memory
cards and system software.

- **You bring the game.** This project contains no game code or data.
- **No BIOS needed.** The console's system software is rewritten as part
  of the project (high-level emulation, or HLE). None is shipped, and none
  is needed.
- **No prebuilt downloads.** You build it yourself with the Odin compiler,
  or play in the browser.

## Quick start

You need Odin `dev-2026-10`, SDL2, Vulkan 1.3, and a disc image (`.cue`,
`.iso` or `.bin`) made from a disc you own.

```sh
odin build play -collection:ps=. -o:speed -out:play-bin
./play-bin path/to/game.cue    # play a disc
./play-bin                     # or open the launcher
```

No build: <https://plaught-armor.github.io/ps-recomp/play.html> plays a
disc in a browser tab.

## Project status

A work in progress. Not every game runs, and a game that starts may still
have bugs.

| System | Status |
|---|---|
| Linux | Games have been played here. The automated tests run here. |
| Windows | A port runs here natively with Vulkan: [SDF_Macross](https://github.com/Tzeentchnet/SDF_Macross). |
| macOS | Untested. The code is type-checked for macOS, but neither games nor the automated tests run there. |

## Guides

| Guide | Covers |
|---|---|
| [Build and play](docs/install.md) | What you need, building `play-bin`, the first run of a disc |
| [Play in your browser](docs/browser.md) | The web pages, what they keep, reports and game data |
| [The launcher](docs/launcher.md) | Your disc library, per-disc settings, exporting a disc |
| [Controls](docs/controls.md) | Controller and keyboard layouts, window keys |
| [Settings](docs/settings.md) | Graphics, learned code, network play, where your files go |
| [Check which of your games run](docs/compat.md) | Compatibility runs, results, press scripts |
| [Report a problem](docs/reporting.md) | What to put in an issue |

## For developers

| Page | Covers |
|---|---|
| [How it works](docs/how-it-works.md) | The recompiler, the runtime, the repository layout, using `recomp` directly |
| [Making a port](docs/porting.md) | Turning one game into its own native program, with its own fixes and features |
| [Tests](docs/testing.md) | The test list and how to check a change before sending it |

## License

GPL-3.0; see [LICENSE](LICENSE).
