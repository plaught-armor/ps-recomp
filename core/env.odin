// Runtime settings. Every one is an environment variable named ENV_PREFIX
// followed by its name (TRACE, CAPTURE, ...), so one game's settings never
// reach another's. A game build sets its prefix:
//
//   odin build ... -define:ENV_PREFIX=GAME_
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
	return os.lookup_env(env_name(name), allocator)
}

// The variable's full name, for messages.
env_name :: proc(name: string) -> string {
	return strings.concatenate({ENV_PREFIX, name}, context.temp_allocator)
}
