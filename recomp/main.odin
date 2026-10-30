// ps-recomp: static recompiler from PS1 (R3000) and PS2 (R5900) machine code
// to Odin source.
//
// Usage: recomp <options.tsv>
//        recomp <disc image> [<source dir>]
//
// The options file is a `key value` table; `backend` (r3000 or r5900)
// picks the console and the rest are that backend's options. Relative paths
// in it are relative to the working directory.
//
// A disc image (a .cue sheet, or a single-track .bin or .iso) alone needs no
// options: the executable SYSTEM.CNF names is compiled to machine code for
// this host, and with a source directory to Odin source too. Code the
// executable loads from other files (PS1 overlays) is not found.
package recomp

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mips"
import "r3000"
import "r5900"

main :: proc() {
	if len(os.args) < 2 || len(os.args) > 3 {
		fmt.eprintln("usage: recomp <options.tsv> | recomp <disc image> [<source dir>]")
		os.exit(2)
	}
	o: mips.Options
	if strings.equal_fold(filepath.ext(os.args[1]), ".tsv") {
		if len(os.args) != 2 {
			fmt.eprintln("usage: recomp <options.tsv>")
			os.exit(2)
		}
		o = mips.load_options(os.args[1])
	} else {
		o = mips.disc_options(os.args[1], len(os.args) == 3 ? os.args[2] : "")
	}
	switch b := mips.option(o, "backend"); b {
	case "r3000":
		r3000.generate(o)
	case "r5900":
		r5900.generate(o)
	case:
		mips.fail("%s: unknown backend %s", o.path, b)
	}
}
