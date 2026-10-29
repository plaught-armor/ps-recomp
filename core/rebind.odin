// Keyboard rebinding from a game's menus: the keys bound to console
// buttons, catching the next press, and moving a key to a button.
//
// Keys are named as in config files, by SDL scancode name ("E", "Left
// Shift"). A game with sources of its own (a mouse) binds those itself
// and offers their presses to the same catch with bind_catch_offer.
//
// While a catch is armed the next press is taken by it and should reach
// nothing else: the game skips its own handling of any press the catch
// takes, and hides what is held when the catch ends from the console so the
// caught press does not also act.
package core

import "core:hash/xxhash"
import "core:mem"
import "core:strings"
import sdl "vendor:sdl2"

bind_catch: struct {
	armed: bool,
	// The caught source's name; "" until one is caught.
	name:  string,
}

// Arm the catch: the next press is taken by bind_catch_take.
bind_catch_start :: proc() {
	bind_catch = {armed = true}
}

// The caught source's name, once one has been caught; the catch is then
// over.
bind_catch_take :: proc() -> (name: string, ok: bool) {
	if !bind_catch.armed || bind_catch.name == "" {
		return "", false
	}
	name = bind_catch.name
	bind_catch = {}
	return name, true
}

// Offer a press named `name` to an armed catch; false when none is armed.
// The first press offered is caught, the rest are swallowed until the
// catch is taken. `name` must live as long as the program (a constant or
// SDL's own name), as the catch keeps it.
bind_catch_offer :: proc(name: string) -> bool {
	if !bind_catch.armed {
		return false
	}
	if bind_catch.name == "" {
		bind_catch.name = name
	}
	return true
}

// Offer a key press to an armed catch (key repeats are swallowed, not
// caught); false when none is armed.
bind_catch_key :: proc(k: sdl.KeyboardEvent) -> bool {
	if !bind_catch.armed {
		return false
	}
	if k.repeat == 0 {
		bind_catch_offer(string(sdl.GetScancodeName(k.keysym.scancode)))
	}
	return true
}

// The names of the keys that hold any of `b`, as many as fit in `out`;
// returns how many there are in all.
key_sources :: proc(b: Buttons, out: []string) -> (n: int) {
	for k, code in input.keys {
		if k & b != {} {
			if n < len(out) {
				out[n] = string(sdl.GetScancodeName(sdl.Scancode(code)))
			}
			n += 1
		}
	}
	return n
}

// Make the named key hold `b` and nothing else; false when no key has that
// name.
key_bind_move :: proc(name: string, b: Buttons) -> bool {
	code := sdl.GetScancodeFromName(strings.clone_to_cstring(name, context.temp_allocator))
	if code == .UNKNOWN {
		return false
	}
	input.keys[code] = b
	return true
}

// Unbind every key from `b`.
key_bind_clear :: proc(b: Buttons) {
	for &k in input.keys {
		k -= b
	}
}

// A hash of every binding (keys, controller buttons and triggers) and the
// device in use, chained from `seed`: button prompts drawn from them stay
// current while it is unchanged. A game folds its own sources in with the
// result as their seed.
binds_hash :: proc(seed: u64 = 0) -> u64 {
	h := xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&input.keys), seed ~ u64(input.device))
	h = xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&input.buttons), h)
	return xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&input.triggers), h)
}
