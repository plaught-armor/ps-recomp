// ps-recomp: static recompiler from PS1 (R3000) and PS2 (R5900) machine code
// to Odin source.
//
// Usage: recomp <options.tsv>
//
// The options file is a `key value` table; `backend` (r3000 or r5900)
// picks the console and the rest are that backend's options. Relative paths
// in it are relative to the working directory.
package recomp

import "core:fmt"
import "core:os"
import "mips"
import "r3000"
import "r5900"

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: recomp <options.tsv>")
		os.exit(2)
	}
	o := mips.load_options(os.args[1])
	switch b := mips.option(o, "backend"); b {
	case "r3000":
		r3000.generate(o)
	case "r5900":
		r5900.generate(o)
	case:
		mips.fail("%s: unknown backend %s", o.path, b)
	}
}
