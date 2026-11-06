#+build !wasi
// play --export: an opt-in repository for one disc, to study and hand-tune
// the game in. The player keeps what it needs in the disc's directory under
// DATA either way (core/data.odin). An export records the disc there as the
// library does (making the directory and writing disc.tsv for an image not
// seen before); everything else it writes goes in the new directory.
//
// What is copied is the player's own text and the last picture: the disc's
// settings.tsv and press.txt, its thumb.ppm as shots/thumb.png, and its
// compat.tsv row in docs/notes.md. The disc image and what is made from it
// (native and learned code, the learn records, which hold the game's code
// words, memory cards, saves and logs) are never copied: local.tsv, which
// the repository's .gitignore leaves out, names the image and the disc's
// directory instead. The .gitignore lists the files to track, so a file
// added later stays out until it is listed.
//
// It also holds a port to start from, each file the same for every disc of
// a system but the title: tools/recomp.tsv (the recompiler's options, the
// disc left out), setup.sh (recompiles the disc local.tsv names into
// port/src/rec and builds the port), port/build.sh, port/src/main.odin and
// port/src/local.odin (boots the disc as the player does, with the
// repository's settings.tsv, the player's memory cards for the disc and its
// learned code when the player that made it is the port's ps-recomp
// commit), and tests/run.sh (a compatibility run of the port). The README
// gives the commit: the player's own.
//
// The export is written to <dir>.ps-recomp-export and then renamed to dir,
// so a failed one leaves no half repository. dir must be missing or an
// empty directory: an export never overwrites or merges.
package play

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "ps:core"

// The directory an export is written in before it is renamed.
@(private = "file")
EXPORT_TMP :: ".ps-recomp-export"

// The files an export writes. Settings, Press and Thumb only when the disc's
// directory has the file they come from.
Export_File :: enum {
	Readme,
	Ignore,
	Local,
	Settings,
	Press,
	Notes,
	Thumb,
	Recomp,
	Setup,
	Build,
	Main,
	Port_Local,
	Run,
}

EXPORT_FILES :: [Export_File]string {
	.Readme     = "README.md",
	.Ignore     = ".gitignore",
	.Local      = "local.tsv",
	.Settings   = "settings.tsv",
	.Press      = "press.txt",
	.Notes      = "docs/notes.md",
	.Thumb      = "shots/thumb.png",
	.Recomp     = "tools/recomp.tsv",
	.Setup      = "setup.sh",
	.Build      = "port/build.sh",
	.Main       = "port/src/main.odin",
	.Port_Local = "port/src/local.odin",
	.Run        = "tests/run.sh",
}

// The .gitignore: everything ignored, then the tracked files listed.
@(private = "file")
EXPORT_IGNORE :: `# Only the files listed here are tracked. local.tsv (the paths of your disc
# image and the player's data for it) and anything not listed stay local:
# add a line to track a new file. port/src/rec is made from the disc: it is
# never tracked.
/*
!/.gitignore
!/.gitmodules
!/ps-recomp
!/README.md
!/settings.tsv
!/press.txt
!/setup.sh
!/docs/
!/shots/
!/tools/
!/tests/
!/port/
/port/*
!/port/build.sh
!/port/src/
/port/src/rec/
`

// setup.sh.
@(private = "file")
PORT_SETUP :: `#!/bin/sh
# Recompile the game on your disc and build the port.
#
#   sh setup.sh        recompile, then build port/game
#   sh setup.sh rec    recompile only, and print the size of port/src/rec
#                      (the build's memory peak grows with it: ps-recomp's
#                      docs/porting.md)
#
# build/recomp.tsv is tools/recomp.tsv with the disc image local.tsv names,
# the VU capture files it names that are still there and, for a PS1 disc,
# the code the player learned (learn/psx.bin in the player's directory for
# the disc, recorded with PS_LEARN=1) when there is any; recomp writes the
# game's code to port/src/rec from it, then port/build.sh builds
# port/game. Both stay out of git. PS_RECOMP overrides the ps-recomp
# checkout (default: the ps-recomp submodule).
set -e
case "$1" in
"" | rec) ;;
*)
	echo "usage: sh setup.sh [rec]" >&2
	exit 2
	;;
esac
cd "$(dirname "$0")"
PS_RECOMP=$(cd "${PS_RECOMP:-ps-recomp}" && pwd)
export PS_RECOMP
image=$(awk -F '	' '$1 == "image" { print $2 }' local.tsv)
if [ -z "$image" ]; then
	echo "setup.sh: local.tsv names no disc image" >&2
	exit 1
fi
mkdir -p build
{
	cat tools/recomp.tsv
	printf 'disc	%s
' "$image"
	for vu in vu0 vu1; do
		cap=$(awk -F '	' -v k="${vu}_capture" '$1 == k { print $2 }' local.tsv)
		if [ -n "$cap" ] && [ -f "$cap" ]; then
			printf '%s_capture	%s
' "$vu" "$cap"
		fi
	done
	data=$(awk -F '	' '$1 == "data" { print $2 }' local.tsv)
	system=$(awk -F '	' '$1 == "system" { print $2 }' local.tsv)
	if [ "$system" = ps1 ] && [ -f "$data/learn/psx.bin" ]; then
		printf 'learned	%s
' "$data/learn/psx.bin"
	fi
} >build/recomp.tsv
odin build "$PS_RECOMP/recomp" -collection:ps="$PS_RECOMP" -o:speed -out:build/recomp
build/recomp build/recomp.tsv
if [ "$1" = rec ]; then
	du -sh port/src/rec
	exit 0
fi
sh port/build.sh
`

// port/build.sh.
@(private = "file")
PORT_BUILD :: `#!/bin/sh
# Build the port: port/game, from port/src and the generated port/src/rec
# (setup.sh makes it).
#
# PS_RECOMP overrides the ps-recomp checkout (default: the ps-recomp
# submodule). The build is named for its commit, so the port takes the
# player's learned code for the disc only when the player is that commit.
set -e
cd "$(dirname "$0")"
PS_RECOMP=${PS_RECOMP:-../ps-recomp}
COMMIT=$(git -C "$PS_RECOMP" rev-parse HEAD)
odin build src -collection:ps="$PS_RECOMP" -define:COMMIT="$COMMIT" -use-separate-modules -o:speed -out:game
echo "built port/game"
`

// port/src/local.odin, the same for every port.
@(private = "file")
PORT_LOCAL :: `// What the port takes from local.tsv, which play --export wrote and git
// ignores: the disc image, and the player's directory for the disc, which
// has its memory cards and the code the player learned.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "ps:core"

Local :: struct {
	// The repository's root (above port/, the binary's directory), the
	// disc image and the player's directory for the disc.
	root, image, data: string,
}

// local.tsv. Exits after a message when it cannot be read or names no disc.
local_read :: proc() -> (l: Local) {
	dir, err := os.get_executable_directory(context.allocator)
	if err != nil {
		fmt.eprintln("cannot find the port's directory:", err)
		os.exit(1)
	}
	l.root = filepath.dir(dir)
	path, _ := filepath.join({l.root, "local.tsv"})
	text, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		fmt.eprintln("cannot read", path, rerr)
		os.exit(1)
	}
	rest := string(text)
	for line in strings.split_lines_iterator(&rest) {
		key, _, value := strings.partition(strings.trim_right(line, "\r"), "\t")
		switch key {
		case "image":
			l.image = value
		case "data":
			l.data = value
		}
	}
	if l.image == "" || l.data == "" {
		fmt.eprintln(path, "names no disc image or player directory")
		os.exit(1)
	}
	return
}

// The repository's settings.tsv, then the player's settings for every disc,
// into the environment; not for a COMPAT run, as in the player. Exits after
// a message on a failure.
settings :: proc(l: Local) {
	if core.env("COMPAT") != "1" && !core.settings_apply(l.root) {
		os.exit(1)
	}
}

// The player's blob of learned code for the disc, when it was made by the
// ps-recomp commit the port is built from; else "" (that code is
// interpreted).
learned :: proc(l: Local, kind: core.Blob_Kind, blob, key: core.Disc_File) -> string {
	text, err := os.read_entire_file(core.disc_path(l.data, key, context.temp_allocator), context.temp_allocator)
	if err != nil {
		return ""
	}
	fields := strings.fields(string(text), context.temp_allocator)
	if len(fields) != 3 || !core.blob_cached(l.data, core.COMMIT, kind, fields[2]) {
		fmt.eprintln("the player's learned code is from another ps-recomp commit: interpreting it")
		return ""
	}
	return core.disc_path(l.data, blob)
}

// The player's memory card directory for the disc, made if missing. Exits
// after a message when it cannot be made.
cards :: proc(l: Local) -> string {
	dir := core.disc_path(l.data, .Cards)
	if err := os.make_directory_all(dir); err != nil && !(err == .Exist && os.is_dir(dir)) {
		fmt.eprintln("cannot make", dir, err)
		os.exit(1)
	}
	return dir
}
`

// port/src/main.odin of a PS1 disc; {title} is the title as an Odin string.
@(private = "file")
PORT_MAIN_PS1 :: `// The port's main package: psx.run boots the disc with the functions
// setup.sh generated into port/src/rec. This file is yours: psx.Boot's
// setup and hooks are where a port changes the game (ps-recomp's
// docs/porting.md).
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "ps:core/disc"
import psx "ps:psx"
import "rec"

TITLE :: {title}

main :: proc() {
	l := local_read()
	settings(l)
	b := psx.Boot {
		disc          = l.image,
		exe           = psx_exe(l.image),
		title         = TITLE,
		funcs         = rec.EXE_FUNCS[:],
		learned       = learned(l, .Learned, .Learned, .Learned_Key),
		learned_funcs = rec.register_learned,
	}
	dir := cards(l)
	for &c, i in b.cards {
		c, _ = filepath.join({dir, fmt.tprintf("slot%d.mcd", i + 1)})
	}
	if !psx.run(b) {
		os.exit(1)
	}
}

// PSX.EXE, on a disc with no SYSTEM.CNF (psx.run does not look for it); nil
// on one with.
psx_exe :: proc(image: string) -> []u8 {
	d, ok := disc.open(image)
	if !ok {
		return nil
	}
	defer disc.close(&d)
	if _, has_cnf := disc.system_cnf(&d, context.temp_allocator); has_cnf {
		return nil
	}
	exe, _ := disc.read_file(&d, "PSX.EXE")
	return exe
}
`

// port/src/main.odin of a PS2 disc; {title} is the title as an Odin string.
@(private = "file")
PORT_MAIN_PS2 :: `// The port's main package: ps2.boot boots the disc with the functions
// setup.sh generated into port/src/rec. This file is yours: ps2.Boot's
// setup and hooks are where a port changes the game (ps-recomp's
// docs/porting.md).
package main

import "core:os"
import "ps:ps2"
import "rec"

TITLE :: {title}

main :: proc() {
	l := local_read()
	settings(l)
	// ps2.boot returns only on a failure.
	ps2.boot(
		{
			disc = l.image,
			title = TITLE,
			learned = learned(l, .Learned_Iop, .Learned_Iop, .Learned_Iop_Key),
			learned_ee = learned(l, .Learned_Ee, .Learned_Ee, .Learned_Ee_Key),
			cards = cards(l),
			hooks = hooks,
		},
	)
	os.exit(1)
}

// Once the runtime is set up: the generated functions in place of the
// interpreter. A port replaces game functions here too.
hooks :: proc() -> bool {
	rec.register_all()
	return true
}
`

// tests/run.sh.
@(private = "file")
PORT_RUN :: `#!/bin/sh
# A compatibility run of the port, as play --compat makes one: no window,
# FRAMES vblanks (the first argument, default 3600), press.txt as the PRESS
# script when there is one, and the compat line on stderr at the end, to
# compare with the player's (docs/notes.md).
set -e
cd "$(dirname "$0")/.."
PS_PRESS=
if [ -f press.txt ]; then
	PS_PRESS=$(cat press.txt)
fi
export PS_PRESS
PS_HEADLESS=1 PS_COMPAT=1 PS_FRAMES=${1:-3600} exec port/game
`

// The compat.tsv columns docs/notes.md shows, in order.
@(private = "file")
NOTES_COLUMNS :: [?]Column {
	.Result,
	.Frames,
	.Frames_Wanted,
	.Shown,
	.Lit,
	.Native,
	.Interp_Share,
	.Idle_Share,
	.Entries,
	.Unimplemented,
	.Stretches,
	.Fatal,
	.Build,
	.When,
}

// Export the disc image to the directory dir. The exit status: 0 when the
// repository is written, 1 (after a message) when it is not.
export :: proc(image, dir: string) -> int {
	path := library_path(image)
	fi, serr := os.stat(path, context.temp_allocator)
	if serr != nil {
		fmt.eprintln("play: cannot read", path, serr)
		return 1
	}
	if strings.contains_any(path, "\t\r\n") {
		fmt.eprintln("play: a tab or line break in its path keeps", path, "out of local.tsv: not exporting")
		return 1
	}
	id, info, has_id := disc_record(path, fi)
	if !has_id {
		return 1
	}
	// A PS1 disc with no SYSTEM.CNF boots PSX.EXE, which recomp is told.
	_, _, psx_exe, _ := identify(path)
	src, has_src := core.disc_dir(id, context.temp_allocator)
	if !has_src {
		return 1
	}
	out := library_path(dir)
	if os.exists(out) {
		if !os.is_dir(out) {
			fmt.eprintln("play: not exporting to", out, "(not a directory)")
			return 1
		}
		first, err := os.read_directory_by_path(out, 1, context.temp_allocator)
		if err != nil || len(first) != 0 {
			fmt.eprintln("play: not exporting to", out, "(not empty)")
			return 1
		}
	}
	tmp := strings.concatenate({out, EXPORT_TMP}, context.temp_allocator)
	if os.exists(tmp) {
		fmt.eprintln("play: not exporting:", tmp, "is in the way (left by an export that stopped? remove it)")
		return 1
	}
	if !export_write(tmp, src, id, info, psx_exe != nil) {
		_ = os.remove_all(tmp)
		return 1
	}
	if os.exists(out) {
		_ = os.remove(out)
	}
	if err := os.rename(tmp, out); err != nil {
		fmt.eprintln("play: cannot rename", tmp, "to", out, err)
		_ = os.remove_all(tmp)
		return 1
	}
	fmt.println("play: exported to", out)
	return 0
}

// Write the repository for the disc id, whose directory is src and disc.tsv
// info, into the new directory root. False, after a message, on a failure.
@(private = "file")
export_write :: proc(root, src, id: string, info: [Info]string, psx_exe: bool) -> bool {
	files: bit_set[Export_File] = {.Readme, .Ignore, .Local, .Notes, .Recomp, .Setup, .Build, .Main, .Port_Local, .Run}
	copied := [?]struct {
		file: Export_File,
		from: core.Disc_File,
	}{{.Settings, .Settings}, {.Press, .Press}}
	for c in copied {
		data, err := os.read_entire_file(core.disc_path(src, c.from, context.temp_allocator), context.temp_allocator)
		if err == nil {
			export_put(root, c.file, data) or_return
			files += {c.file}
		}
	}
	if thumb, err := os.read_entire_file(core.disc_path(src, .Thumb, context.temp_allocator), context.temp_allocator); err == nil {
		w, h, rgb, ok := core.ppm_parse(thumb)
		if ok {
			export_dir(root, .Thumb) or_return
			png := export_path(root, .Thumb)
			if !core.png_write(png, rgb, w, h, 3) {
				fmt.eprintln("play: cannot write", png)
				return false
			}
			files += {.Thumb}
		}
	}
	export_put(root, .Ignore, transmute([]u8)string(EXPORT_IGNORE)) or_return
	export_put(root, .Local, export_local(src, id, info)) or_return
	export_put(root, .Notes, export_notes(id)) or_return
	export_put(root, .Recomp, export_recomp(info, psx_exe)) or_return
	export_put(root, .Setup, transmute([]u8)string(PORT_SETUP)) or_return
	export_put(root, .Build, transmute([]u8)string(PORT_BUILD)) or_return
	export_put(root, .Port_Local, transmute([]u8)string(PORT_LOCAL)) or_return
	main_odin := PORT_MAIN_PS2 if info[.System] == "ps2" else PORT_MAIN_PS1
	main_odin, _ = strings.replace(main_odin, "{title}", fmt.tprintf("%q", export_title(id, info)), 1, context.temp_allocator)
	export_put(root, .Main, transmute([]u8)main_odin) or_return
	export_put(root, .Run, transmute([]u8)string(PORT_RUN)) or_return
	return export_put(root, .Readme, export_readme(id, info, files))
}

// local.tsv: the image's path, the disc's directory, id and system, the
// ps-recomp commit this player is (the one to build a port with), and the
// VU capture files the player has written for the disc (VU_CAPTURE).
@(private = "file")
export_local :: proc(src, id: string, info: [Info]string) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "key\tvalue\nimage\t%s\ndata\t%s\nid\t%s\nsystem\t%s\ncommit\t%s\n", info[.Path], src, id, info[.System], core.COMMIT)
	for f, unit in ([2]core.Disc_File{.Vu0_Capture, .Vu1_Capture}) {
		path := core.disc_path(src, f, context.temp_allocator)
		if os.is_file(path) {fmt.sbprintf(&b, "vu%d_capture\t%s\n", unit, path)}
	}
	return b.buf[:]
}

// tools/recomp.tsv: the backend and runtime for the disc's system, the
// generated code in port/src/rec. The disc is setup.sh's to add.
@(private = "file")
export_recomp :: proc(info: [Info]string, psx_exe: bool) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "key\tvalue\n")
	if info[.System] == "ps2" {
		strings.write_string(&b, "backend\tr5900\nruntime\tps:ps2\n")
	} else {
		strings.write_string(&b, "backend\tr3000\nruntime\tps:psx\n")
		if psx_exe {
			strings.write_string(&b, "exe\tPSX.EXE\n")
		}
	}
	strings.write_string(&b, "out\tport/src/rec\nquiet\ttrue\n")
	return b.buf[:]
}

// The disc's name: its title, else its serial, else its id.
@(private)
export_title :: proc(id: string, info: [Info]string) -> string {
	if info[.Title] != "" {
		return info[.Title]
	}
	return info[.Serial] if info[.Serial] != "" else id
}

// docs/notes.md: headings to fill in, then the disc's compat.tsv row.
@(private = "file")
export_notes :: proc(id: string) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# Notes\n\n## Address map\n\n## Overlays and modules\n\n## Findings\n\n## Compatibility\n\n")
	data, _ := core.data_dir(context.temp_allocator)
	tsv, _ := filepath.join({data, "compat.tsv"}, context.temp_allocator)
	row, has_row := compat_rows(tsv)[id]
	if !has_row {
		strings.write_string(&b, "No compatibility run yet: `play --compat <disc image>` makes one.\n")
		return b.buf[:]
	}
	strings.write_string(&b, "The player's last compatibility run (`play --compat`), from compat.tsv:\n\n| column | value |\n|---|---|\n")
	names := COLUMNS
	for c in NOTES_COLUMNS {
		fmt.sbprintf(&b, "| %s | ", names[c])
		for r in row[c] {
			if r == '|' {
				strings.write_byte(&b, '\\')
			}
			strings.write_rune(&b, r)
		}
		strings.write_string(&b, " |\n")
	}
	return b.buf[:]
}

// README.md: what the repository is, and what it holds of files.
@(private = "file")
export_readme :: proc(id: string, info: [Info]string, files: bit_set[Export_File]) -> []u8 {
	title := export_title(id, info)
	system := "PS2" if info[.System] == "ps2" else "PS1"
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# %s\n\n%s disc", title, system)
	if info[.Serial] != "" {
		fmt.sbprintf(&b, " %s", info[.Serial])
	}
	fmt.sbprintf(&b, ", id `%s`, exported by the ps-recomp player (build %s).\n\n", id, core.COMMIT)
	strings.write_string(
		&b,
		"Notes, settings and pictures for studying and tuning one game. This\n" +
		"repository holds no game code or data: `local.tsv`, which git ignores,\n" +
		"names your disc image and the player's data for it (compiled and learned\n" +
		"code, memory cards, logs), which stay where they are.\n\n",
	)
	strings.write_string(&b, "- `docs/notes.md`: your notes, and the player's last compatibility run\n")
	if .Settings in files {
		strings.write_string(&b, "- `settings.tsv`: the player's settings for this disc, `NAME<TAB>value` rows\n")
	}
	if .Press in files {
		strings.write_string(&b, "- `press.txt`: the PRESS script compatibility runs use\n")
	}
	if .Thumb in files {
		strings.write_string(&b, "- `shots/thumb.png`: the picture the game last showed\n")
	}
	strings.write_string(
		&b,
		"- `setup.sh`, `tools/recomp.tsv`, `port/`: a port of the game, built from\n" +
		"  your disc (below)\n" +
		"- `tests/run.sh`: a compatibility run of the port, as `play --compat` makes\n" +
		"  one\n\n" +
		"`.gitignore` lists the files that are tracked; add a line there to track\n" +
		"another.\n\n## Build the port\n\n" +
		"With git and Odin, in this directory (the submodule add downloads\n" +
		"ps-recomp: it needs the network):\n\n```sh\ngit init\n" +
		"git submodule add https://github.com/plaught-armor/ps-recomp ps-recomp\n",
	)
	if core.COMMIT == "dev" {
		strings.write_string(&b, "git -C ps-recomp checkout <the commit your player was built from>\n")
	} else {
		fmt.sbprintf(&b, "git -C ps-recomp checkout %s\n", core.COMMIT)
	}
	strings.write_string(
		&b,
		"git add .\ngit commit -m \"The export, ps-recomp pinned\"\nsh setup.sh\n```\n\n" +
		"The commit records the exported files and the ps-recomp commit, so\n" +
		"`git status` shows only what changes after it.\n\n" +
		"`setup.sh` recompiles the game on your disc into `port/src/rec` and builds\n" +
		"`port/game`, which runs it as the player does: with ",
	)
	if .Settings in files {
		strings.write_string(&b, "`settings.tsv`, ")
	}
	strings.write_string(
		&b,
		"the player's memory cards for the disc and, at the player's ps-recomp\n" +
		"commit, the code the player learned. `sh tests/run.sh [frames]` makes a\n" +
		"compatibility run of it. `port/src/main.odin` is where the port changes\n" +
		"the game: see ps-recomp's `docs/porting.md`. `sh setup.sh rec` only\n" +
		"recompiles, and prints the size of `port/src/rec`: the build needs\n" +
		"memory in step with it. Only tried on Linux: the\n" +
		"scripts need a POSIX shell.\n",
	)
	if system == "PS1" {
		strings.write_string(
			&b,
			"\n## Recompile the code the game loads\n\n" +
			"The recompiler sees the disc's executable; code the game loads from\n" +
			"other files as it runs stays interpreted. Play that code with the player\n" +
			"recording what it interprets, then recompile:\n\n```sh\n" +
			"PS_LEARN=1 play <your disc image>\nsh setup.sh\n```\n\n" +
			"`PS_LEARN=1` records each run of code the player interprets in its\n" +
			"directory for the disc, as `learn/psx.bin`; `setup.sh` gives that file to\n" +
			"the recompiler, which adds it to `port/src/rec`. Only what was played is\n" +
			"recorded: play through the parts of the game to cover. The file holds\n" +
			"the game's code and stays out of git.\n",
		)
	}
	return b.buf[:]
}

// The path of f under root, temp allocated.
@(private = "file")
export_path :: proc(root: string, f: Export_File) -> string {
	names := EXPORT_FILES
	path, _ := filepath.join({root, names[f]}, context.temp_allocator)
	return path
}

// Make the directory f goes in. False, after a message, on a failure.
@(private = "file")
export_dir :: proc(root: string, f: Export_File) -> bool {
	dir := filepath.dir(export_path(root, f))
	if err := os.make_directory_all(dir); err != nil && !(err == .Exist && os.is_dir(dir)) {
		fmt.eprintln("play: cannot make", dir, err)
		return false
	}
	return true
}

// Write f under root. False, after a message, on a failure.
@(private = "file")
export_put :: proc(root: string, f: Export_File, data: []u8) -> bool {
	export_dir(root, f) or_return
	path := export_path(root, f)
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintln("play: cannot write", path, err)
		return false
	}
	return true
}
