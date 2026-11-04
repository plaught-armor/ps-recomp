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
}

EXPORT_FILES :: [Export_File]string {
	.Readme   = "README.md",
	.Ignore   = ".gitignore",
	.Local    = "local.tsv",
	.Settings = "settings.tsv",
	.Press    = "press.txt",
	.Notes    = "docs/notes.md",
	.Thumb    = "shots/thumb.png",
}

// The .gitignore: everything ignored, then the tracked files listed.
@(private = "file")
EXPORT_IGNORE :: `# Only the files listed here are tracked. local.tsv (the paths of your disc
# image and the player's data for it) and anything not listed stay local:
# add a line to track a new file.
/*
!/.gitignore
!/README.md
!/settings.tsv
!/press.txt
!/docs/
!/shots/
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
	id, info, has_id := disc_record(path, fi)
	if !has_id {
		return 1
	}
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
	if !export_write(tmp, src, id, info) {
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
export_write :: proc(root, src, id: string, info: [Info]string) -> bool {
	files: bit_set[Export_File] = {.Readme, .Ignore, .Local, .Notes}
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
	return export_put(root, .Readme, export_readme(id, info, files))
}

// local.tsv: the image's path, the disc's directory, id and system, and the
// ps-recomp commit this player is (the one to build a port with).
@(private = "file")
export_local :: proc(src, id: string, info: [Info]string) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "key\tvalue\nimage\t%s\ndata\t%s\nid\t%s\nsystem\t%s\ncommit\t%s\n", info[.Path], src, id, info[.System], core.COMMIT)
	return b.buf[:]
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
	title := info[.Title]
	if title == "" {
		title = info[.Serial] if info[.Serial] != "" else id
	}
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
	strings.write_string(&b, "\nTo keep it in git: `git init`, then commit. `.gitignore` lists the files\nthat are tracked; add a line there to track another.\n")
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
