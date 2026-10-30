// play: run a game from its disc image.
//
// Usage: play <disc image>
//
// The disc image (a .cue sheet, or a single-track .bin or .iso) is all it
// needs. The first run of a disc compiles the executable SYSTEM.CNF names to
// a native blob for this host, in a child process (`play --convert <disc
// image> <out>`), and keeps it in the disc's directory under the user data
// directory (DATA) with the memory cards; later runs of the same build
// use it. A dev build (no COMMIT) converts every time. When the conversion
// fails the game runs interpreted; a stored blob that will not load is
// converted again on the next run.
package play

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "ps:core"
import "ps:core/disc"
import "ps:ps2"
import "ps:psx"

main :: proc() {
	os.exit(run(os.args))
}

// Run play with the command line args (args[0] the executable). The exit
// status: 0 when the game ends, 1 on a failure, 2 on a usage error.
run :: proc(args: []string) -> int {
	switch {
	case len(args) == 4 && args[1] == "--convert":
		return convert(args[2], args[3])
	case len(args) == 2 && !strings.has_prefix(args[1], "--"):
		return play(args[1])
	}
	fmt.eprintln("usage: play <disc image>")
	return 2
}

// The key of the blob the game runs, removed when the blob will not load so
// the next run converts again: a blob a crash or a bad disk truncated is
// not used twice.
@(private = "file")
native_key: string

@(private = "file")
native_failed :: proc() {
	os.remove(native_key)
	fmt.eprintln("play: the stored native code would not load; it is converted again next run")
}

// Run the game on the disc image.
@(private = "file")
play :: proc(image: string) -> int {
	d, opened := disc.open(image)
	if !opened {
		fmt.eprintln("play:", image, "is not a disc image")
		return 1
	}
	id, has_id := disc.id(&d)
	cnf, has_cnf := disc.system_cnf(&d)
	// With no SYSTEM.CNF a PS1 disc boots PSX.EXE, which psx.run does not
	// look for.
	exe: []u8
	if has_id && !has_cnf {
		exe, has_id = disc.read_file(&d, "PSX.EXE")
	}
	disc.close(&d)
	if !has_id {
		fmt.eprintln("play:", image, "has no executable to run")
		return 1
	}
	dir, has_dir := core.disc_dir(id)
	if !has_dir {
		return 1
	}
	// NATIVE=0 runs the game interpreted.
	native := core.disc_path(dir, .Native)
	if core.env("NATIVE") == "0" || (!core.blob_cached(dir) && !convert_store(image, dir)) {
		native = ""
	}
	native_key = core.disc_path(dir, .Native_Key)
	cards := core.disc_path(dir, .Cards)
	if err := os.make_directory_all(cards); err != nil && !(err == .Exist && os.is_dir(cards)) {
		fmt.eprintln("play: cannot make", cards, err)
		return 1
	}
	title := strings.clone_to_cstring(cnf.serial if cnf.serial != "" else id)
	if cnf.ps2 {
		// ps2.boot returns only on a failure.
		ps2.boot({disc = image, title = title, native = native, native_failed = native_failed, cards = cards})
		return 1
	}
	b := psx.Boot {
		disc          = image,
		exe           = exe,
		title         = title,
		native        = native,
		native_failed = native_failed,
	}
	for &c, i in b.cards {
		c, _ = filepath.join({cards, fmt.tprintf("slot%d.mcd", i + 1)})
	}
	return 0 if psx.run(b) else 1
}
