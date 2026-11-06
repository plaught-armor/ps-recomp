// ps-recomp: static recompiler from PS1 (R3000) and PS2 (R5900) machine code
// to Odin source.
//
// Usage: recomp <options.tsv>
//        recomp [--arch <x64_sysv|x64_win|arm64|wasm32>] <disc image> [<source dir>]
//        recomp --mod-api <options.tsv> <out dir>
//
// The options file is a `key value` table; `backend` (r3000 or r5900)
// picks the console and the rest are that backend's options. Relative paths
// in it are relative to the working directory.
//
// A disc image (a .cue sheet, or a single-track .bin or .iso) alone needs no
// options: the executable SYSTEM.CNF names (PSX.EXE on a PS1 disc without
// one) is compiled to machine code for this host, or for the --arch given,
// and with a source directory to Odin source too. Code the executable loads
// from other files (PS1 overlays) is not found.
//
// --mod-api writes the options file's mod API, mod_api.h and mod.ld, into
// the out directory and compiles nothing (recomp/r3000/mod_api.odin; PS1
// only).
package recomp

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "mips"
import "native"
import "r3000"
import "r5900"

USAGE :: "usage: recomp <options.tsv> | recomp [--arch <x64_sysv|x64_win|arm64|wasm32>] <disc image> [<source dir>] | recomp --mod-api <options.tsv> <out dir>"

main :: proc() {
	args := os.args[1:]
	if len(args) >= 1 && args[0] == "--mod-api" {
		if len(args) != 3 {
			fmt.eprintln("usage: recomp --mod-api <options.tsv> <out dir>")
			os.exit(2)
		}
		o := mips.load_options(args[1])
		switch b := mips.option(o, "backend"); b {
		case "r3000":
			r3000.mod_api_write(o, args[2])
		case "r5900":
			mips.fail("%s: --mod-api: backend r5900 is not supported yet", o.path)
		case:
			mips.fail("%s: unknown backend %s", o.path, b)
		}
		return
	}
	arch := mips.HOST_ARCH
	if len(args) >= 2 && args[0] == "--arch" {
		arch = args[1]
		args = args[2:]
	}
	if len(args) < 1 || len(args) > 2 {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	o: mips.Options
	if strings.equal_fold(filepath.ext(args[0]), ".tsv") {
		if len(args) != 1 || len(os.args) != 2 {
			fmt.eprintln("usage: recomp <options.tsv>")
			os.exit(2)
		}
		o = mips.load_options(args[0])
	} else {
		// An options file names its own native_arch; the backend checks it.
		if _, ok := native.arch_of("recomp", arch); !ok {
			os.exit(2)
		}
		o = mips.disc_options(args[0], len(args) == 2 ? args[1] : "", arch)
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
