// Input records: every pad state a game takes, by frame, written as it
// happens and played back exactly. Emulation is driven by the console's own
// frame count, so a replay of the same session (same disc, settings and
// starting saves) takes the same input on the same frames.
//
// A record has one entry per line, keyed by frame:
//
//   V 1                       format version, the first line
//   I <frame> <hex>[ <p>]     buttons held on player p (1-4, default 1) from
//                             that frame on, as the bits of core.Buttons
//   S <frame> <lx> <ly> <rx> <ry>[ <p>]
//                             sticks from that frame on, each axis as the hex
//                             bits of its f32 so replay is exact
//
// Any other entry is the game's own (camera drags, snapshots, ...): it
// writes them with record_write and reads them back through the `extra`
// proc it passes replay_load.
//
// The game owns both ends: it records the input it actually takes (after
// its own merging) with record_buttons and record_sticks, and adds
// replay_buttons and replay_sticks where it merges scripted input, so live
// input still adds on top and a replay can be taken over at its end.
package core

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

RECORD_VERSION :: 1

// Called for each entry replay_load does not know, with its kind, frame and
// remaining fields; returns false when the entry is malformed.
Replay_Extra :: proc(kind: string, at: u64, fields: []string) -> bool

Replay_Buttons :: struct {
	at:      u64,
	buttons: Buttons,
}

Replay_Sticks :: struct {
	at:          u64,
	left, right: [2]f32,
}

record: struct {
	out:     ^os.File,
	// Last state written per player, so only changes are written.
	buttons: [MAX_PLAYERS]Buttons,
	sticks:  [MAX_PLAYERS][2][2]f32,
}

replay: struct {
	// Per player, in frame order; each state holds until the next.
	buttons: [MAX_PLAYERS][dynamic]Replay_Buttons,
	sticks:  [MAX_PLAYERS][dynamic]Replay_Sticks,
	// Frame of the last button or stick entry (0 without a replay).
	end:     u64,
}

// Start writing a record to path. Returns false when it cannot be created.
record_open :: proc(path: string) -> bool {
	f, err := os.create(path)
	if err != nil {
		fmt.eprintln("record: cannot create", path, err)
		return false
	}
	record.out = f
	record_write(fmt.tprintf("V %d\n", RECORD_VERSION))
	return record.out != nil
}

record_close :: proc() {
	if record.out != nil {
		os.close(record.out)
		record.out = nil
	}
}

// Write one line as is (a game's own entry, newline included). Unbuffered,
// so a crash loses nothing written before it; a failed write stops the
// recording.
record_write :: proc(line: string) {
	if record.out == nil {
		return
	}
	if _, err := os.write_string(record.out, line); err != nil {
		fmt.eprintln("record: write failed, recording stopped:", err)
		record_close()
	}
}

// Note the buttons player takes at frame now, when they changed.
record_buttons :: proc(player: int, now: u64, b: Buttons) {
	if record.out == nil || record.buttons[player] == b {
		return
	}
	record.buttons[player] = b
	record_write(fmt.tprintf("I %d %x%s\n", now, transmute(u16)b, player_suffix(player)))
}

// Note player's stick positions at frame now, when they changed.
record_sticks :: proc(player: int, now: u64, left, right: [2]f32) {
	s := [2][2]f32{left, right}
	if record.out == nil || record.sticks[player] == s {
		return
	}
	record.sticks[player] = s
	b := transmute([4]u32)s
	record_write(fmt.tprintf("S %d %08x %08x %08x %08x%s\n", now, b[0], b[1], b[2], b[3], player_suffix(player)))
}

@(private = "file")
player_suffix :: proc(player: int) -> string {
	return player == 0 ? "" : fmt.tprintf(" %d", player + 1)
}

// Buttons the replay holds on player at frame now.
replay_buttons :: proc(player: int, now: u64) -> Buttons {
	es := replay.buttons[player][:]
	i := replay_find(es, now)
	return i < 0 ? {} : es[i].buttons
}

// Stick positions the replay holds on player at frame now.
replay_sticks :: proc(player: int, now: u64) -> (left, right: [2]f32) {
	es := replay.sticks[player][:]
	if i := replay_find(es, now); i >= 0 {
		left, right = es[i].left, es[i].right
	}
	return
}

// Index of the last entry at or before now, or -1.
@(private = "file")
replay_find :: proc(es: []$T, now: u64) -> int {
	lo, hi := 0, len(es)
	for lo < hi {
		mid := (lo + hi) / 2
		if es[mid].at <= now {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

// Load a record for replay. Returns false, with the reason on stderr, when
// it cannot be read or an entry is malformed.
replay_load :: proc(path: string, extra: Replay_Extra = nil) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintln("replay: cannot read", path, err)
		return false
	}
	presses, moves := 0, 0
	n := 0
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		n += 1
		f := strings.fields(line, context.temp_allocator)
		if n == 1 {
			if len(f) != 2 || f[0] != "V" || f[1] != fmt.tprint(RECORD_VERSION) {
				fmt.eprintf("replay: %s: not a version %d input record (first line %q)\n", path, RECORD_VERSION, line)
				return false
			}
			continue
		}
		if len(f) == 0 {
			continue
		}
		at: u64
		ok := len(f) >= 2
		if ok {
			at, ok = strconv.parse_u64(f[1], 10)
		}
		if !ok {
			fmt.eprintf("replay: %s:%d: bad entry %q\n", path, n, line)
			return false
		}
		switch f[0] {
		case "I":
			ok = replay_add_buttons(f[2:], at)
			presses += 1
		case "S":
			ok = replay_add_sticks(f[2:], at)
			moves += 1
		case:
			ok = extra != nil && extra(f[0], at, f[2:])
		}
		if !ok {
			fmt.eprintf("replay: %s:%d: bad entry %q\n", path, n, line)
			return false
		}
	}
	if n == 0 {
		fmt.eprintf("replay: %s: empty\n", path)
		return false
	}
	fmt.eprintf("replay: %d button and %d stick changes from %s\n", presses, moves, path)
	return true
}

// The player field of an entry with `want` fields before it: 1-4, default 1.
@(private = "file")
replay_player :: proc(f: []string, want: int) -> (player: int, ok: bool) {
	if len(f) == want {
		return 0, true
	}
	if len(f) != want + 1 {
		return 0, false
	}
	p := strconv.parse_u64(f[want], 10) or_return
	if p < 1 || p > MAX_PLAYERS {
		return 0, false
	}
	return int(p) - 1, true
}

@(private = "file")
replay_add_buttons :: proc(f: []string, at: u64) -> bool {
	player := replay_player(f, 1) or_return
	bits := strconv.parse_u64(f[0], 16) or_return
	if bits > 0xffff {
		return false
	}
	es := &replay.buttons[player]
	if len(es) > 0 && es[len(es) - 1].at > at {
		return false
	}
	append(es, Replay_Buttons{at = at, buttons = transmute(Buttons)u16(bits)})
	replay.end = max(replay.end, at)
	return true
}

@(private = "file")
replay_add_sticks :: proc(f: []string, at: u64) -> bool {
	player := replay_player(f, 4) or_return
	v: [4]f32
	for a, i in f[:4] {
		b := strconv.parse_u64(a, 16) or_return
		v[i] = transmute(f32)u32(b)
		if b > 0xffffffff || !(v[i] >= -1 && v[i] <= 1) {
			return false
		}
	}
	es := &replay.sticks[player]
	if len(es) > 0 && es[len(es) - 1].at > at {
		return false
	}
	append(es, Replay_Sticks{at = at, left = v.xy, right = v.zw})
	replay.end = max(replay.end, at)
	return true
}
