// Runtime settings. Every one is an environment variable named ENV_PREFIX
// followed by its name (TRACE, CAPTURE, ...), so one game's settings never
// reach another's. A game build sets its prefix:
//
//   odin build ... -define:ENV_PREFIX=GAME_
//
// TTY is an internal hint, not a setting: the launcher sets TTY=1 for a run
// it starts only when its own stderr is a terminal, since it copies the
// run's stderr there through a pipe; output written for a terminal (the
// conversion's progress line) is then written as it would be without the
// launcher. Unset, only whether stderr is a terminal counts.
package core

import "core:os"
import "core:strings"

ENV_PREFIX :: #config(ENV_PREFIX, "PS_")

// The setting `name`, or "" when unset. The string lives in `allocator`.
env :: proc(name: string, allocator := context.temp_allocator) -> string {
	return os.get_env(env_name(name), allocator)
}

// The setting `name`, and whether it is set at all (set to "" counts).
env_lookup :: proc(name: string, allocator := context.temp_allocator) -> (value: string, ok: bool) {
	key := env_name(name)
	// On wasi, os.lookup_env finds the value but never reports it found
	// (core/os/env_wasi.odin); the environment's list does. A name set twice
	// is listed once there, with one of its values, where getenv takes the
	// first.
	when ODIN_OS == .WASI {
		vars, err := os.environ(context.temp_allocator)
		if err != nil {return}
		for v in vars {
			// An entry without "=" is not a variable, as for getenv.
			k, sep, val := strings.partition(v, "=")
			if sep != "" && k == key {return strings.clone(val, allocator), true}
		}
		return
	} else {
		return os.lookup_env(key, allocator)
	}
}

// The variable's full name, for messages.
env_name :: proc(name: string) -> string {
	return strings.concatenate({ENV_PREFIX, name}, context.temp_allocator)
}
