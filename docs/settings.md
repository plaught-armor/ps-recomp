# Settings

Settings are environment variables whose names start with `PS_`. Put one
before the command:

```sh
PS_GPU=sw ./play-bin path/to/game.cue
```

The most used ones can also be set in the [launcher](launcher.md#settings-screen)
(marked **L** below). It keeps them in `settings.tsv` files: one for all
discs in the data folder, and one in each disc's folder. An environment
variable always wins over both.

## Graphics

| Setting | Console | What it does |
|---|---|---|
| `PS_GPU` **L** | PS1 | `vk` draws with Vulkan (the default). `sw` draws in software. |
| `PS_SW` **L** | PS2 | `1` draws in software. Otherwise Vulkan, except the wasm build, which always draws in software. |
| `PS_BANDS` | PS2 | Software drawing only. The number of threads that draw, each a band of rows, 1 to 16. The default, 1, draws on the emulator's own thread. The play page's default is one fewer than the CPUs, at most 8. |
| `PS_SCALE` **L** | PS2 | Window size as a multiple of the console's resolution, 1 to 8. Default 3. |
| `PS_UPSCALER` | PS2 | Vulkan only. `fsr1` uses AMD FidelityFX Super Resolution 1 EASU and RCAS when the window is larger than the internal picture. Otherwise output uses linear scaling. |

## How the game runs

| Setting | Console | What it does |
|---|---|---|
| `PS_NATIVE` **L** | Both | `0` runs the game through the interpreter instead of as native code. Slower; for checking a bug. |
| `PS_IRX` **L** | PS2 | A game's own sound and I/O modules run on an emulated copy of the console's I/O processor. `0` turns that off: each module is answered as loaded, without running. |
| `PS_LEARN` | Both | See [Learned code](#learned-code). |
| `PS_VU_CAPTURE` | PS2 | See [Learned code](#learned-code). |

## Learned code

The converter cannot see all of a game's code ahead of time. Some is only
loaded as the game runs. ps-recomp records that code in the disc's folder
and compiles it to native code for later runs.

- **`PS_LEARN`** covers code run through the interpreter: a PS1 game's
  overlays, and a PS2 game's I/O processor modules and interpreted main
  CPU code. This is on by default. `1` records the code every processor
  interprets. `0` records nothing and uses no learned code.
- **`PS_VU_CAPTURE`** covers a PS2 game's vector unit microcode that has no
  native code yet. It runs as native code later in the same run (once the
  recording has been quiet for a while) and in later runs, and a
  [port](porting.md#vu-microcode) compiles it too. Each run adds to the
  record. `1` records all of it, with the vector units run through the
  interpreter, so the game is slower. `0` records nothing.

## Play over the network (PS2)

Two players can play a PS2 game together over the network, with rollback
netplay. Both computers must run the same build and mods on the same disc,
from the same boot and memory card.

| Setting | What it does |
|---|---|
| `PS_NET_PEER` | `host:port` of the other player. Setting it starts netplay. |
| `PS_NET_BIND` | The address to listen on. Default `0.0.0.0:7000`. |
| `PS_NET_PLAYER` | Your player number, `1` or `2`. Default `1`. |
| `PS_NET_DELAY` | Frames of input delay. Default `2`. |
| `PS_NET_HASH` | Check that both games still agree every this many vblanks. Default `60`. |

For example, on each computer, with the other's address:

```sh
PS_NET_PEER=192.168.1.20:7000 PS_NET_PLAYER=1 ./play-bin game.cue   # computer A
PS_NET_PEER=192.168.1.10:7000 PS_NET_PLAYER=2 ./play-bin game.cue   # computer B
```

Netplay has only been run on Linux, like the rest of the project.

## Where your files go

All your files live in one user data folder:

| System | Default location |
|---|---|
| Linux | `~/.local/share/ps-recomp` |
| macOS | `~/Library/Application Support/ps-recomp` |
| Windows | `%APPDATA%\ps-recomp` |

Set `PS_DATA` to use a different folder.

| File | What it is |
|---|---|
| `library.tsv` | The launcher's list of discs. |
| `settings.tsv` | Settings for all discs. |
| `compat.tsv` | [Compatibility](compat.md) results, one row per disc. |
| `discs/<disc id>/` | One folder per disc: saves, memory cards, converted and learned code. |
| `discs/<disc id>/settings.tsv` | The disc's own launcher settings. |
| `discs/<disc id>/thumb.ppm` | The disc's picture from the last time you quit. |
| `discs/<disc id>/play.log` | What the disc's last launcher run printed. |

## Other settings

More settings exist, mostly for debugging. Each is described in the code
where it is read; see [how it works](how-it-works.md#settings-in-the-code).
`PS_TTY` is not a setting: the launcher sets it for the games it starts.
