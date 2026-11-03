// Saved settings: the runtime settings (env.odin) a player keeps for one disc
// in its directory's settings.tsv (data.odin) and for every disc in
// <data>/settings.tsv, one `NAME<TAB>value` row each. Only the names in
// SETTING_NAMES are read; any other row, or one with no tab, is skipped.
//
// A setting's value comes from, first to last: the environment (set there at
// all, even to "", it wins), the disc's file, the global file; else it is
// unset and the runtime's default holds. With neither file a run is exactly
// as the environment alone makes it.
package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Setting :: enum {
	Gpu, // PS1 renderer: vk or sw
	Sw, // PS2: 1 for the software GS
	Scale, // PS2 Vulkan GS resolution, 1..8 times native
	Irx, // PS2: 0 to HLE the IOP modules instead of running them
	Native, // 0 runs the game interpreted
}

SETTING_NAMES :: [Setting]string {
	.Gpu    = "GPU",
	.Sw     = "SW",
	.Scale  = "SCALE",
	.Irx    = "IRX",
	.Native = "NATIVE",
}

// The longest value a row keeps, in bytes; a longer row is skipped.
SETTING_MAX :: 64

// The settings one file holds: a value for each setting in `set`.
Settings :: struct {
	value: [Setting]string,
	set:   bit_set[Setting],
}

// Where a setting's value comes from.
Setting_Source :: enum {
	Default, // unset: the runtime's default
	Global, // <data>/settings.tsv
	Disc, // the disc's settings.tsv
	Env, // the environment
}

// The settings in a settings.tsv's text. Values live in `allocator`.
settings_parse :: proc(text: string, allocator := context.allocator) -> (s: Settings) {
	names := SETTING_NAMES
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		name, tab, value := strings.partition(strings.trim_right(line, "\r"), "\t")
		if tab == "" || len(value) > SETTING_MAX || strings.contains_any(value, "\t\x00") {
			continue
		}
		for n, k in names {
			if n == name {
				s.value[k] = strings.clone(value, allocator)
				s.set += {k}
			}
		}
	}
	return
}

// The settings in the file at path, none when it is missing or unreadable.
settings_load :: proc(path: string, allocator := context.allocator) -> Settings {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}
	}
	return settings_parse(string(text), allocator)
}

// Write s to path whole (tmp + rename), its rows in SETTING_NAMES order; with
// nothing set the file is removed. False, after a message, on a failure.
settings_save :: proc(path: string, s: Settings) -> bool {
	if s.set == {} {
		if err := os.remove(path); err != nil && os.exists(path) {
			fmt.eprintln("cannot remove", path, err)
			return false
		}
		return true
	}
	names := SETTING_NAMES
	b := strings.builder_make(context.temp_allocator)
	for k in s.set {
		fmt.sbprintf(&b, "%s\t%s\n", names[k], s.value[k])
	}
	if err := write_file_atomic(path, transmute([]u8)strings.to_string(b)); err != nil {
		fmt.eprintln("cannot write", path, err)
		return false
	}
	return true
}

// Each setting's value and where it comes from, given the disc's and the
// global settings and the environment. Values live in the temp allocator
// or in the Settings passed.
settings_resolve :: proc(disc, global: Settings) -> (value: [Setting]string, from: [Setting]Setting_Source) {
	names := SETTING_NAMES
	for k in Setting {
		if v, ok := env_lookup(names[k]); ok {
			value[k], from[k] = v, .Env
		} else if k in disc.set {
			value[k], from[k] = disc.value[k], .Disc
		} else if k in global.set {
			value[k], from[k] = global.value[k], .Global
		}
	}
	return
}

// The global settings file, <data>/settings.tsv.
settings_global_path :: proc(allocator := context.allocator) -> (path: string, ok: bool) {
	data := data_dir(context.temp_allocator) or_return
	path, _ = filepath.join({data, "settings.tsv"}, allocator)
	return path, true
}

// Put the saved settings of the disc whose directory is dir into this
// process's environment, each one the environment does not already set, so
// the runtime reads them as it reads any setting. False, after a message,
// when one cannot be set.
settings_apply :: proc(dir: string) -> bool {
	global: Settings
	if path, ok := settings_global_path(context.temp_allocator); ok {
		global = settings_load(path, context.temp_allocator)
	}
	disc := settings_load(disc_path(dir, .Settings, context.temp_allocator), context.temp_allocator)
	value, from := settings_resolve(disc, global)
	names := SETTING_NAMES
	for k in Setting {
		if from[k] != .Disc && from[k] != .Global {
			continue
		}
		if err := os.set_env(env_name(names[k]), value[k]); err != nil {
			fmt.eprintln("cannot set", env_name(names[k]), err)
			return false
		}
	}
	return true
}
