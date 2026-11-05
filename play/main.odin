// play: run a game from its disc image.
//
// Usage: play
//        play <disc image>
//        play --compat <disc image | directory> [frames]
//        play --export <disc image> <directory>
//
// The disc image (a .cue sheet, or a single-track .bin or .iso) is all it
// needs. The first run of a disc compiles the executable SYSTEM.CNF names to
// a native blob for this host, in a child process (`play --convert <disc
// image> <out>`), and keeps it in the disc's directory under the user data
// directory (DATA) with the memory cards; later runs of the same build
// use it. A dev build (no COMMIT) converts every time. When the conversion
// fails the game runs interpreted; a stored blob that will not load is
// converted again on the next run.
//
// LEARN=1 records the code a game interprets in the disc's directory, a PS1
// game's in learn/psx.bin and a PS2 game's in learn/ps2.bin (core/learn.odin;
// a path records there instead). Without LEARN a PS2 game's IOP code is
// recorded there all the same; LEARN=0 records nothing and runs no learned
// code. While that file has records of the PS1, or
// of the PS2's IOP, each run compacts it and runs native code for them:
// compiled in a child (`play --learned <psx | iop> <records> <out>`) when the
// stored learned blob is not for these records, this build and blob
// format (always, for a dev build), and loaded beside the native blob.
// Code that is not in RAM as it was recorded is interpreted, and learned.
//
// With no disc image it opens the launcher (launcher_window.odin), a window
// listing the library's discs to run.
//
// --compat runs each disc headless to a vblank count as a compatibility
// run and keeps a row per disc in compat.tsv under DATA (compat.odin).
//
// --export writes a new repository for the disc, to study and hand-tune the
// game in, into a directory that is missing or empty (export.odin).
package play

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
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
	case len(args) == 1:
		return launcher(args[0])
	case len(args) == 4 && args[1] == "--convert":
		return convert(args[2], args[3])
	case len(args) == 5 && args[1] == "--learned" && (args[2] == "psx" || args[2] == "iop" || args[2] == "ee"):
		return compile_learned(.Psx if args[2] == "psx" else .Iop if args[2] == "iop" else .Ee, args[3], args[4])
	case (len(args) == 3 || len(args) == 4) && args[1] == "--compat":
		return compat_mode(args[2], args[3] if len(args) == 4 else "")
	case len(args) == 4 && args[1] == "--export":
		return export(args[2], args[3])
	case len(args) == 2 && !strings.has_prefix(args[1], "--"):
		if compat_child() {
			parent_watch()
		}
		return play(args[1])
	}
	fmt.eprintln("usage: play")
	fmt.eprintln("       play <disc image>")
	fmt.eprintln("       play --compat <disc image | directory> [frames]")
	fmt.eprintln("       play --export <disc image> <directory>")
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

// The same for the learned blob.
@(private = "file")
learned_key: string

@(private = "file")
learned_failed :: proc() {
	os.remove(learned_key)
	fmt.eprintln("play: the stored learned code would not load; it is compiled again next run")
}

// The same for a PS2 game's EE learned blob.
@(private = "file")
learned_ee_key: string

@(private = "file")
learned_ee_failed :: proc() {
	os.remove(learned_ee_key)
	fmt.eprintln("play: the stored learned EE code would not load; it is compiled again next run")
}

// Where the learned code of cpu is kept: its blob, the blob's file and key,
// the file its LEARN records are in, and its name on the learned child's
// command line. A PS2 game's IOP and EE keep their records in one file.
@(private)
Learned_Files :: struct {
	kind:          core.Blob_Kind,
	blob, key:     core.Disc_File,
	records, name: string,
}

@(private)
learned_files :: proc(cpu: core.Learn_Cpu) -> Learned_Files {
	switch cpu {
	case .Psx: return {.Learned, .Learned, .Learned_Key, "psx.bin", "psx"}
	case .Iop: return {.Learned_Iop, .Learned_Iop, .Learned_Iop_Key, "ps2.bin", "iop"}
	case .Ee: return {.Learned_Ee, .Learned_Ee, .Learned_Ee_Key, "ps2.bin", "ee"}
	}
	unreachable()
}

// The learned blob for cpu's records in the disc directory dir's learn
// directory, after the file is compacted (core.learn_compact); compiled when
// the stored one is not for them. Its key names those records alone, so
// another processor's in the same file do not compile it again. Without
// compile a blob not stored is not compiled either; a compile still running
// after deadline (0: none) is stopped. "" when there are none, or no blob.
@(private)
learned_blob :: proc(dir: string, cpu: core.Learn_Cpu, compile: bool, deadline: time.Duration) -> string {
	l := learned_files(cpu)
	records := learn_records(dir, l.records)
	if !os.exists(records) {
		return ""
	}
	data, err := os.read_entire_file(records, context.temp_allocator)
	if err != nil {
		fmt.eprintln("play: cannot read", records, err)
		return ""
	}
	// A file of an earlier stream version compacts to nothing and is
	// emptied, so the runs after record anew rather than append behind
	// records no reader gets past.
	compact, n := core.learn_compact(data)
	defer delete(compact)
	if string(compact) != string(data) {
		if werr := core.write_file_atomic(records, compact); werr != nil {
			fmt.eprintln("play: cannot write", records, werr)
			return ""
		}
	}
	if n == 0 {
		return ""
	}
	// Each record by its code's hash; compacted, they are in one order.
	Key :: struct #packed {
		flags:        core.Learn_Flags,
		entry, lo, n: u32,
		hash:         u64,
	}
	recs, _ := core.learn_read(compact, context.temp_allocator)
	keys := make([dynamic]Key, context.temp_allocator)
	for r in recs {
		if r.cpu == cpu {append(&keys, Key{r.flags, r.entry, r.lo, u32(len(r.words)), r.hash})}
	}
	if len(keys) == 0 {
		return ""
	}
	set := fmt.tprintf("%016x", xxhash.XXH3_64_default(([^]u8)(raw_data(keys))[:len(keys) * size_of(Key)]))
	if !core.blob_cached(dir, core.COMMIT, l.kind, set) {
		if !compile {
			fmt.eprintln("play: no learned code (not compiled in the compat run)")
			return ""
		}
		if !learned_store(cpu, records, dir, set, deadline) {
			return ""
		}
	}
	return core.disc_path(dir, l.blob)
}

// The path of the file name in the disc directory dir's learn directory,
// temp allocated.
@(private = "file")
learn_records :: proc(dir, name: string) -> string {
	path, _ := filepath.join({core.disc_path(dir, .Learn, context.temp_allocator), name}, context.temp_allocator)
	return path
}

// The disc image's id and SYSTEM.CNF, and its PSX.EXE when it has no
// SYSTEM.CNF. False, after a message, when it is not a disc image or has no
// executable to run.
@(private)
identify :: proc(image: string) -> (id: string, cnf: disc.System_Cnf, exe: []u8, ok: bool) {
	d, opened := disc.open(image)
	if !opened {
		fmt.eprintln("play:", image, "is not a disc image")
		return
	}
	defer disc.close(&d)
	id, ok = disc.id(&d)
	has_cnf: bool
	cnf, has_cnf = disc.system_cnf(&d)
	// With no SYSTEM.CNF a PS1 disc boots PSX.EXE, which psx.run does not
	// look for.
	if ok && !has_cnf {
		exe, ok = disc.read_file(&d, "PSX.EXE")
	}
	if !ok {
		fmt.eprintln("play:", image, "has no executable to run")
	}
	return
}

// Run the game on the disc image.
@(private = "file")
play :: proc(image: string) -> int {
	id, cnf, exe, has_id := identify(image)
	if !has_id {
		return 1
	}
	dir, has_dir := core.disc_dir(id)
	if !has_dir {
		return 1
	}
	// The player's saved settings for this disc, then for every disc; not
	// for a COMPAT run, whose result comes from the environment alone.
	if core.env("COMPAT") != "1" && !core.settings_apply(dir) {
		return 1
	}
	// VU_CAPTURE=1 records a PS2 game's VU microcode in its directory, where
	// an export's port is compiled from (docs/porting.md). Only from the
	// environment: settings.tsv goes into the export. VU0_CAPTURE or
	// VU1_CAPTURE set already names that VU's file.
	if cnf.ps2 && core.env("VU_CAPTURE") == "1" {
		for f, unit in ([2]core.Disc_File{.Vu0_Capture, .Vu1_Capture}) {
			name := fmt.tprintf("VU%d_CAPTURE", unit)
			if _, set := core.env_lookup(name); set {continue}
			if err := os.set_env(core.env_name(name), core.disc_path(dir, f, context.temp_allocator)); err != nil {
				fmt.eprintln("play: cannot set", core.env_name(name), err)
				return 1
			}
		}
	}
	// NATIVE=0 runs the game interpreted.
	native := core.disc_path(dir, .Native)
	if core.env("NATIVE") == "0" || (!core.blob_cached(dir) && !convert_store(image, dir, 0)) {
		native = ""
	}
	native_key = core.disc_path(dir, .Native_Key)
	// Learned code runs on a PS1 game, and on a PS2 game's IOP and EE,
	// unless NATIVE=0 or LEARN=0; found before LEARN opens the records,
	// which compacting rewrites. A compat child's parent compiled it already
	// (compat_disc): one that failed there is not tried again here.
	learn_cpu := core.Learn_Cpu.Iop if cnf.ps2 else .Psx
	learn_env := core.env("LEARN")
	learned, learned_ee: string
	if core.env("NATIVE") != "0" && learn_env != "0" {
		learned = learned_blob(dir, learn_cpu, !compat_child(), 0)
		if cnf.ps2 {learned_ee = learned_blob(dir, .Ee, !compat_child(), 0)}
	}
	learned_key = core.disc_path(dir, learned_files(learn_cpu).key)
	learned_ee_key = core.disc_path(dir, learned_files(.Ee).key)
	// LEARN=1 records every processor's runs; unset, a PS2 game's IOP,
	// whose modules no recompiled code covers, and its EE, whose code the
	// recompiler never saw (loaded at run time, or missed). A default that
	// cannot open its records runs without them.
	if learn_env == "1" || (learn_env == "" && cnf.ps2) {
		cpus := ~core.Learn_Cpus{} if learn_env == "1" else {.Iop, .Ee}
		learn := core.disc_path(dir, .Learn)
		opened := false
		if err := os.make_directory_all(learn); err != nil && !(err == .Exist && os.is_dir(learn)) {
			fmt.eprintln("play: cannot make", learn, err)
		} else {
			opened = core.learn_open_path(learn_records(dir, learned_files(learn_cpu).records), cpus)
		}
		if !opened && learn_env == "1" {
			return 1
		}
	}
	// The picture a run ends on (a quit, a COMPAT run's last vblank), for
	// the launcher.
	core.thumb_path = core.disc_path(dir, .Thumb)
	// A compat child plays on the cards its parent emptied, unless
	// COMPAT_CARDS=keep (compat_disc).
	cards := core.disc_path(dir, .Compat_Cards if compat_child() && core.env("COMPAT_CARDS") != "keep" else .Cards)
	if err := os.make_directory_all(cards); err != nil && !(err == .Exist && os.is_dir(cards)) {
		fmt.eprintln("play: cannot make", cards, err)
		return 1
	}
	title := strings.clone_to_cstring(cnf.serial if cnf.serial != "" else id)
	if cnf.ps2 {
		// ps2.boot returns only on a failure.
		ps2.boot(
			{
				disc = image,
				title = title,
				native = native,
				native_failed = native_failed,
				learned = learned,
				learned_failed = learned_failed,
				learned_ee = learned_ee,
				learned_ee_failed = learned_ee_failed,
				cards = cards,
			},
		)
		return 1
	}
	b := psx.Boot {
		disc           = image,
		exe            = exe,
		title          = title,
		native         = native,
		native_failed  = native_failed,
		learned        = learned,
		learned_failed = learned_failed,
	}
	for &c, i in b.cards {
		c, _ = filepath.join({cards, fmt.tprintf("slot%d.mcd", i + 1)})
	}
	return 0 if psx.run(b) else 1
}
