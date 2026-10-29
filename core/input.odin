// Host input: keyboard and SDL game controllers, mapped to console pads.
//
// Every keyboard key, controller button and trigger has a binding: the pad
// buttons it holds down. Bindings start empty (input_bind_standard gives the
// usual controller layout) and the game sets them from its config. Several
// sources may hold the same button.
//
// Controllers go through SDL's GameController layer, which maps any known
// pad to an Xbox-style layout. Each controller takes the lowest free player
// slot and keeps it until unplugged; the keyboard and the press script feed
// player 1 unless a press names another. With `shared` (one-player games)
// every controller feeds player 1 instead, buttons merged and the most
// deflected stick winning.
//
// Buttons are in PS pad wire order, active-high: Pad_Button bit n is bit n
// of pad data bytes 3..4 (byte 3 in the low half). A console whose software
// sees another layout converts at its boundary.
//
// The caller owns the clock: input_poll, input_tap and the press script take
// its frame count, so input replays with the game across save states.
package core

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl2"

Pad_Button :: enum u16 {
	Select, L3, R3, Start, Up, Right, Down, Left,
	L2, R2, L1, R1, Triangle, Circle, Cross, Square,
}

Buttons :: bit_set[Pad_Button; u16]

MAX_PLAYERS :: 4

// One player's pad as sampled by input_poll. Sticks are x right and y down,
// each axis in -1..1 as SDL reports it (no dead zone; see dead_zone).
Player_Input :: struct {
	connected: bool, // a controller is in this slot (player 1 always is)
	buttons:   Buttons,
	left:      [2]f32,
	right:     [2]f32,
}

// The kind of device the player last pressed something on. Button prompts
// follow it: keycaps for the keyboard and mouse, face-button symbols or
// letters for each controller family.
Input_Device :: enum u8 {
	Keyboard,
	PlayStation,
	Xbox,
	Nintendo,
}

// The controls of an SDL game controller, by their Xbox-style names; A is
// the south face button (on Nintendo pads, the button labelled A).
Pad_Control :: enum u8 {
	A,
	B,
	X,
	Y,
	Back,
	Guide,
	Start,
	Left_Stick,
	Right_Stick,
	Left_Shoulder,
	Right_Shoulder,
	Up,
	Down,
	Left,
	Right,
	Left_Trigger,
	Right_Trigger,
}

Trigger :: enum {
	Left,
	Right,
}

// A scripted press: `buttons` held on `player` for frames at ..< at + hold.
Scripted_Press :: struct {
	at:      u64,
	hold:    u64,
	buttons: Buttons,
	player:  int,
}

// Community controller mappings (SDL_GameControllerDB format).
CONTROLLER_DB_FILE :: "gamecontrollerdb.txt"

// Trigger deflection (0..1) that counts as pressed.
TRIGGER_PRESS :: 0.5

// Radial dead zone of the analog sticks (0..1); dead_zone rescales past it.
STICK_DEADZONE :: 0.2

// Controller axis deflection that counts as using the pad (of 32767).
@(private = "file")
DEVICE_AXIS_USE :: 16000

// Each rumble sent to the controllers lasts this long (real time) and is
// renewed at half of it while a motor runs, so a motor left on stops soon
// after the game stops polling.
@(private = "file")
RUMBLE_HOLD_MS :: 500

input: struct {
	keys:      [sdl.NUM_SCANCODES]Buttons,
	buttons:   [sdl.GameControllerButton.MAX]Buttons,
	triggers:  [Trigger]Buttons,
	// Every controller feeds player 1.
	shared:    bool,
	pads:      [MAX_PLAYERS]^sdl.GameController,
	pad_ids:   [MAX_PLAYERS]sdl.JoystickID,
	// Pads that refused a rumble; reported once each.
	no_rumble: [MAX_PLAYERS]bool,
	// Motor state last sent to each slot and when (SDL ticks, ms).
	rumble:    [MAX_PLAYERS]struct {
		small: bool,
		large: u8,
		sent:  u32,
	},
	// Motor strength scale 0..1, full by default; the game may set it
	// (from its settings) before input_init.
	rumble_strength: f32,
	// Frame until which each button of each player stays held by input_tap.
	tap_until: [MAX_PLAYERS][Pad_Button]u64,
	script:    [dynamic]Scripted_Press,
	// The kind of device last used, for button prompts.
	device:    Input_Device,
	// The family of the controller last used or connected; PlayStation
	// until there is one.
	pad_device: Input_Device,
	// Set from the DEVICE setting: device and pad_device stay as set.
	device_fixed: bool,
} = {
	rumble_strength = 1,
}

// Console button names as used in config files and press scripts.
PAD_NAMES := [Pad_Button]string {
	.Select   = "select",
	.L3       = "l3",
	.R3       = "r3",
	.Start    = "start",
	.Up       = "up",
	.Right    = "right",
	.Down     = "down",
	.Left     = "left",
	.L2       = "l2",
	.R2       = "r2",
	.L1       = "l1",
	.R1       = "r1",
	.Triangle = "triangle",
	.Circle   = "circle",
	.Cross    = "cross",
	.Square   = "square",
}

// `shared`: one-player game, every controller feeds player 1. Reads the
// DEVICE setting (keyboard, ps, xbox, switch), which fixes the prompt family
// for tests. Call after SDL_Init: it loads CONTROLLER_DB_FILE from the
// working directory when there is one, so pads SDL does not know get a
// mapping too.
input_init :: proc(shared: bool) {
	input.shared = shared
	if os.exists(CONTROLLER_DB_FILE) {
		if n := sdl.GameControllerAddMappingsFromFile(CONTROLLER_DB_FILE); n < 0 {
			fmt.eprintln("gamepad: cannot read", CONTROLLER_DB_FILE, "-", sdl.GetError())
		}
	}
	input.device_fixed = true
	switch env("DEVICE") {
	case "keyboard":
		input.device = .Keyboard
	case "ps":
		input.device = .PlayStation
	case "xbox":
		input.device = .Xbox
	case "switch":
		input.device = .Nintendo
	case:
		input.device_fixed = false
	}
	input.pad_device = input.device
}

// The usual controller layout: face buttons by position, shoulders, sticks
// clicked for L3/R3, triggers for L2/R2. Keys are left as they are.
input_bind_standard :: proc() {
	C :: sdl.GameControllerButton
	b := &input.buttons
	b^ = {}
	b[C.A] = {.Cross}
	b[C.B] = {.Circle}
	b[C.X] = {.Square}
	b[C.Y] = {.Triangle}
	b[C.LEFTSHOULDER] = {.L1}
	b[C.RIGHTSHOULDER] = {.R1}
	b[C.LEFTSTICK] = {.L3}
	b[C.RIGHTSTICK] = {.R3}
	b[C.BACK] = {.Select}
	b[C.START] = {.Start}
	b[C.DPAD_UP] = {.Up}
	b[C.DPAD_DOWN] = {.Down}
	b[C.DPAD_LEFT] = {.Left}
	b[C.DPAD_RIGHT] = {.Right}
	input.triggers = {.Left = {.L2}, .Right = {.R2}}
}

// The usual emulator keyboard layout: arrows for the d-pad, Z X A S for
// Cross Circle Square Triangle, Q W for L1 R1, 1 2 for L2 R2, Return for
// Start, right Shift for Select. Controllers are left as they are.
input_bind_keys_standard :: proc() {
	K :: sdl.Scancode
	k := &input.keys
	k^ = {}
	k[K.UP] = {.Up}
	k[K.DOWN] = {.Down}
	k[K.LEFT] = {.Left}
	k[K.RIGHT] = {.Right}
	k[K.Z] = {.Cross}
	k[K.X] = {.Circle}
	k[K.A] = {.Square}
	k[K.S] = {.Triangle}
	k[K.Q] = {.L1}
	k[K.W] = {.R1}
	k[K.NUM1] = {.L2}
	k[K.NUM2] = {.R2}
	k[K.RETURN] = {.Start}
	k[K.RSHIFT] = {.Select}
}

// The button for a config name such as "cross" or "l1".
pad_button_from_name :: proc(name: string) -> (b: Pad_Button, ok: bool) {
	for n, p in PAD_NAMES {
		if strings.equal_fold(n, name) {
			return p, true
		}
	}
	return {}, false
}

// The kind of device last used.
input_device :: proc() -> Input_Device {
	return input.device
}

// The family of the controller last used or connected (PlayStation when
// none has been): what controller buttons are called.
input_pad_device :: proc() -> Input_Device {
	return input.pad_device == .Keyboard ? .PlayStation : input.pad_device
}

// The first controller control (in Pad_Control order) that holds any of
// `b`.
pad_source :: proc(b: Buttons) -> (c: Pad_Control, ok: bool) {
	#assert(int(Pad_Control.Right) == int(sdl.GameControllerButton.DPAD_RIGHT))
	for pc in Pad_Control.A ..= Pad_Control.Right {
		if input.buttons[sdl.GameControllerButton(pc)] & b != {} {
			return pc, true
		}
	}
	if input.triggers[.Left] & b != {} {
		return .Left_Trigger, true
	}
	if input.triggers[.Right] & b != {} {
		return .Right_Trigger, true
	}
	return {}, false
}

// Make exactly the named keys (SDL scancode names, e.g. "Z", "Space", "Left
// Shift") hold `b`. All names are checked before anything changes.
bind_keys :: proc(b: Buttons, names: []string) -> bool {
	codes := make([]sdl.Scancode, len(names), context.temp_allocator)
	for name, i in names {
		codes[i] = sdl.GetScancodeFromName(strings.clone_to_cstring(name, context.temp_allocator))
		if codes[i] == .UNKNOWN {
			fmt.eprintln("input: unknown key", name)
			return false
		}
	}
	for &k in input.keys {
		k -= b
	}
	for c in codes {
		input.keys[c] += b
	}
	return true
}

// Make exactly the named controller buttons (SDL names: a, b, x, y, back,
// start, leftshoulder, rightshoulder, leftstick, rightstick, dpup, dpdown,
// dpleft, dpright, plus lefttrigger and righttrigger) hold `b`.
bind_buttons :: proc(b: Buttons, names: []string) -> bool {
	Source :: union {
		sdl.GameControllerButton,
		Trigger,
	}
	sources := make([]Source, len(names), context.temp_allocator)
	for name, i in names {
		switch name {
		case "lefttrigger":
			sources[i] = Trigger.Left
		case "righttrigger":
			sources[i] = Trigger.Right
		case:
			c := sdl.GameControllerGetButtonFromString(strings.clone_to_cstring(name, context.temp_allocator))
			if c == .INVALID {
				fmt.eprintln("input: unknown controller button", name)
				return false
			}
			sources[i] = c
		}
	}
	for &c in input.buttons {
		c -= b
	}
	for &t in input.triggers {
		t -= b
	}
	for s in sources {
		switch v in s {
		case sdl.GameControllerButton:
			input.buttons[v] += b
		case Trigger:
			input.triggers[v] += b
		}
	}
	return true
}

// Take the controller events (hotplug, and presses for the prompt family)
// and keyboard presses; the caller still handles them as it likes.
input_event :: proc(e: sdl.Event) {
	#partial switch e.type {
	case .CONTROLLERDEVICEADDED:
		gamepad_added(e.cdevice.which)
	case .CONTROLLERDEVICEREMOVED:
		gamepad_removed(sdl.JoystickID(e.cdevice.which))
	case .KEYDOWN:
		if e.key.repeat == 0 {
			device_used(.Keyboard)
		}
	case .CONTROLLERBUTTONDOWN:
		device_pad_used(e.cbutton.which)
	case .CONTROLLERAXISMOTION:
		if abs(i32(e.caxis.value)) > DEVICE_AXIS_USE {
			device_pad_used(e.caxis.which)
		}
	}
}

// Note a press on a device of kind `d` (the mouse counts as the keyboard).
device_used :: proc(d: Input_Device) {
	if input.device_fixed {
		return
	}
	input.device = d
	if d != .Keyboard {
		input.pad_device = d
	}
}

// Note a press on the controller with joystick instance id `id`.
@(private = "file")
device_pad_used :: proc(id: sdl.JoystickID) {
	if pad := sdl.GameControllerFromInstanceID(id); pad != nil {
		device_used(device_of_pad(pad))
	}
}

// The prompt family of an open controller. Unknown pads use Xbox prompts,
// since SDL lays every pad out like one.
@(private = "file")
device_of_pad :: proc(pad: ^sdl.GameController) -> Input_Device {
	#partial switch sdl.GameControllerGetType(pad) {
	case .PS3, .PS4, .PS5:
		return .PlayStation
	case .NINTENDO_SWITCH_PRO:
		return .Nintendo
	}
	// Joy-Con types (left, right, pair) postdate the binding's enum.
	if t := int(sdl.GameControllerGetType(pad)); t >= 11 && t <= 13 {
		return .Nintendo
	}
	return .Xbox
}

// CONTROLLERDEVICEADDED: `index` is a device index. Pads present at startup
// arrive through this event too, sometimes twice.
@(private = "file")
gamepad_added :: proc(index: i32) {
	id := sdl.JoystickGetDeviceInstanceID(index)
	for p, k in input.pads {
		if p != nil && input.pad_ids[k] == id {
			return
		}
	}
	for p, k in input.pads {
		if p != nil {
			continue
		}
		pad := sdl.GameControllerOpen(index)
		if pad == nil {
			fmt.eprintln("gamepad: cannot open device", index, sdl.GetError())
			return
		}
		input.pads[k] = pad
		input.no_rumble[k] = false
		input.rumble[k] = {}
		input.pad_ids[k] = sdl.JoystickInstanceID(sdl.GameControllerGetJoystick(pad))
		if !input.shared {
			sdl.GameControllerSetPlayerIndex(pad, i32(k)) // player LEDs where the pad has them
		}
		device_used(device_of_pad(pad))
		fmt.eprintfln("gamepad: player %d: %s", input.shared ? 1 : k + 1, sdl.GameControllerName(pad))
		return
	}
	fmt.eprintln("gamepad: ignoring device", index, "- all", MAX_PLAYERS, "slots in use")
}

// CONTROLLERDEVICEREMOVED: `id` is a joystick instance id.
@(private = "file")
gamepad_removed :: proc(id: sdl.JoystickID) {
	for &p, k in input.pads {
		if p != nil && input.pad_ids[k] == id {
			sdl.GameControllerClose(p)
			p = nil
			fmt.eprintfln("gamepad: player %d unplugged", input.shared ? 1 : k + 1)
		}
	}
}

// The taps' state, which advances with the game's frames: a game with save
// states or rollback that uses input_tap saves and restores these bytes with
// its own.
input_tap_state :: proc() -> []u8 {
	return mem.ptr_to_bytes(&input.tap_until)
}

// Hold `b` on `player` until frame `until`, on top of whatever is held; a
// later call extends a tap still running.
input_tap :: proc(player: int, b: Buttons, until: u64) {
	for p in b {
		input.tap_until[player][p] = max(input.tap_until[player][p], until)
	}
}

// Sample every player at frame `now`: keys, controllers, the press script and
// taps. Reads SDL's state as of the last event pump, so it may be called
// more than once a frame.
input_poll :: proc(now: u64) -> (ps: [MAX_PLAYERS]Player_Input) {
	ps[0].connected = true
	for down, code in sdl.GetKeyboardStateAsSlice() {
		if down != 0 && code < len(input.keys) {
			ps[0].buttons += input.keys[code]
		}
	}
	for pad, k in input.pads {
		if pad == nil {
			continue
		}
		p := &ps[input.shared ? 0 : k]
		p.connected = true
		p.buttons += gamepad_held(pad)
		p.left = stronger(p.left, {axis(pad, .LEFTX), axis(pad, .LEFTY)})
		p.right = stronger(p.right, {axis(pad, .RIGHTX), axis(pad, .RIGHTY)})
	}
	for s in input.script {
		if now >= s.at && now < s.at + s.hold {
			ps[s.player].buttons += s.buttons
		}
	}
	for &taps, k in input.tap_until {
		for until, b in taps {
			if now < until {
				ps[k].buttons += {b}
			}
		}
	}
	return
}

@(private = "file")
gamepad_held :: proc(p: ^sdl.GameController) -> (held: Buttons) {
	for b, c in input.buttons {
		if b != {} && sdl.GameControllerGetButton(p, sdl.GameControllerButton(c)) != 0 {
			held += b
		}
	}
	if axis(p, .TRIGGERLEFT) >= TRIGGER_PRESS {
		held += input.triggers[.Left]
	}
	if axis(p, .TRIGGERRIGHT) >= TRIGGER_PRESS {
		held += input.triggers[.Right]
	}
	return
}

@(private = "file")
axis :: proc(p: ^sdl.GameController, a: sdl.GameControllerAxis) -> f32 {
	return max(f32(sdl.GameControllerGetAxis(p, a)) / 32767, -1)
}

// A stick position with the radial dead zone removed and the rest rescaled
// to 0..1.
dead_zone :: proc(v: [2]f32) -> [2]f32 {
	m := math.sqrt(v.x * v.x + v.y * v.y)
	if m <= STICK_DEADZONE {
		return {}
	}
	scaled := min((m - STICK_DEADZONE) / (1 - STICK_DEADZONE), 1)
	return v * (scaled / m)
}

// The more deflected of two stick positions (a on a tie).
stronger :: proc(a, b: [2]f32) -> [2]f32 {
	return a.x * a.x + a.y * a.y >= b.x * b.x + b.y * b.y ? a : b
}

// Clockwise angle of a stick from up, in degrees (-180..180).
stick_angle :: proc(v: [2]f32) -> f64 {
	return math.to_degrees(math.atan2(f64(v.x), f64(-v.y)))
}

// D-pad buttons of the eight 45 degree sectors around a stick, clockwise
// from up.
STICK_SECTORS := [8]Buttons{{.Up}, {.Up, .Right}, {.Right}, {.Right, .Down}, {.Down}, {.Down, .Left}, {.Left}, {.Left, .Up}}

// The d-pad buttons of the sector a stick points into.
stick_dpad :: proc(v: [2]f32) -> Buttons {
	return STICK_SECTORS[int(math.round(stick_angle(v) / 45)) & 7]
}

// Drive a player's controller motors from the emulated pad's: the large
// (low frequency) motor takes a speed, the small (high frequency) one is on
// or off. With `shared` every controller takes player 1's.
input_rumble :: proc(player: int, small: bool, large: u8) {
	if input.shared {
		assert(player == 0, "input: shared pads have one player")
		for _, k in input.pads {
			rumble_slot(k, small, large)
		}
	} else {
		rumble_slot(player, small, large)
	}
}

// Stop every motor (pause); the next input_rumble that runs one starts it
// again.
input_rumble_stop :: proc() {
	for _, k in input.pads {
		input.rumble[k] = {}
		rumble_send(k, 0, 0, 0)
	}
}

@(private = "file")
rumble_slot :: proc(k: int, small: bool, large: u8) {
	r := &input.rumble[k]
	now := sdl.GetTicks()
	running := small || large != 0
	if small == r.small && large == r.large {
		if !running || now - r.sent < RUMBLE_HOLD_MS / 2 {
			return
		}
	}
	r^ = {small, large, now}
	lo := u16(f32(large) / 255 * input.rumble_strength * 0xffff)
	hi := small ? u16(input.rumble_strength * 0xffff) : 0
	rumble_send(k, lo, hi, running ? RUMBLE_HOLD_MS : 0)
}

@(private = "file")
rumble_send :: proc(k: int, lo, hi: u16, ms: u32) {
	p := input.pads[k]
	if p == nil || input.no_rumble[k] {
		return
	}
	if sdl.GameControllerRumble(p, lo, hi, ms) != 0 {
		input.no_rumble[k] = true
		fmt.eprintln("gamepad: no rumble on", sdl.GameControllerName(p), "-", sdl.GetError())
	}
}

// Add the PRESS setting's script: comma-separated "<button>@<frame>", each
// held `hold` frames; "+<n>" after the frame holds n frames instead
// (Left@900+120), ":<n>" at the end presses on player n (Start@900:2).
// Button names are PAD_NAMES, any case. Returns false on a bad entry.
input_script_load :: proc(hold: u64) -> bool {
	spec := env("PRESS")
	if spec == "" {
		return true
	}
	ok := true
	for item in strings.split(spec, ",", context.temp_allocator) {
		name, _, rest := strings.partition(item, "@")
		timing, colon, who := strings.partition(rest, ":")
		at_s, plus, dur := strings.partition(timing, "+")
		b, bok := pad_button_from_name(name)
		at, aok := strconv.parse_u64(at_s)
		player, pok := 1, true
		if colon != "" {
			player, pok = strconv.parse_int(who)
		}
		n, hok := hold, true
		if plus != "" {
			n, hok = strconv.parse_u64(dur)
		}
		if !bok || !aok || !pok || !hok || n < 1 || player < 1 || player > MAX_PLAYERS {
			fmt.eprintfln(ENV_PREFIX + "PRESS: bad entry \"%s\"", item)
			ok = false
			continue
		}
		append(&input.script, Scripted_Press{at = at, hold = n, buttons = {b}, player = player - 1})
	}
	return ok
}
