package main

import "core:fmt"
import "core:os"
import "ps:core"

// core.record_open and core.replay_load: a record carries the run's mod set
// (core.run_mods) as its second line, only when there is one, and a replay
// takes only a record of the same set.
test_record_mods :: proc() {
	fails := 0
	fail :: proc(fails: ^int, what: string) {
		fmt.eprintln("FAIL record mods:", what)
		fails^ += 1
	}
	path :: "record_test.rec"
	defer {_ = os.remove(path)}
	A, B :: u64(0x0123456789abcdef), u64(0xfedcba9876543210)
	// core.mods_note notes a set's hash, 0 for a set with no mods.
	{
		mods := []core.Mod_Manifest{{id = "a"}}
		tsv, elf, order := [][]u8{{1}}, [][]u8{{2}}, []int{0}
		set := core.Mod_Set {
			mods  = mods,
			tsv   = tsv,
			elf   = elf,
			order = order,
		}
		core.mods_note(set, "test")
		if want := core.mod_set_hash(set); core.run_mods != want || want == 0 {
			fail(&fails, fmt.tprintf("mods_note: %x, want %x", core.run_mods, want))
		}
		core.mods_note({}, "test")
		if core.run_mods != 0 {fail(&fails, "mods_note of no mods")}
	}
	// Write a record made with mods (0 none) and an entry after the header.
	write :: proc(mods: u64) -> string {
		core.run_mods = mods
		if !core.record_open(path) {return ""}
		core.record_buttons(0, 5, {.Cross})
		core.record_close()
		data, _ := os.read_entire_file(path, context.temp_allocator)
		return string(data)
	}
	if got := write(0); got != "V 1\nI 5 4000\n" {
		fail(&fails, fmt.tprintf("record without mods: %q", got))
	}
	core.record = {}
	if got := write(A); got != "V 1\nX 0123456789abcdef\nI 5 4000\n" {
		fail(&fails, fmt.tprintf("record with mods: %q", got))
	}
	core.record = {}
	// Replay a record of set rec (0 none) on a run of set run.
	Case :: struct {
		rec, run: u64,
		ok:       bool,
	}
	for c in ([]Case{{0, 0, true}, {A, A, true}, {A, 0, false}, {0, A, false}, {A, B, false}}) {
		write(c.rec)
		core.record = {}
		core.run_mods = c.run
		if core.replay_load(path) != c.ok {
			fail(&fails, fmt.tprintf("replay of mods %x on mods %x: want ok %v", c.rec, c.run, c.ok))
		}
		for &b in core.replay.buttons {clear(&b)}
	}
	// A record with only its header, then a bad set and one out of place.
	core.run_mods = A
	for text, k in ([]string{"V 1\n", "V 1\nX nothex\n", "V 1\nX 0123_56789abcdef\n", "V 1\nX 123456789abcdef\n", "V 1\nI 5 4000\nX 0123456789abcdef\n"}) {
		_ = os.write_entire_file(path, transmute([]u8)text)
		if core.replay_load(path) {
			fail(&fails, fmt.tprintf("replay %d loaded on a run with mods: %q", k, text))
		}
		for &b in core.replay.buttons {clear(&b)}
	}
	core.run_mods = 0
	// Out of place, X is no known entry, and there is no extra proc.
	if core.replay_load(path) {
		fail(&fails, "a misplaced X line loaded")
	}
	for &b in core.replay.buttons {clear(&b)}
	if fails > 0 {os.exit(1)}
	fmt.println("ok record mods")
}

// core.hello_mismatch on what core.hello_encode writes: a peer's HELLO
// joins only with the same build, mods, disc, player count, input delay
// and hash interval, from the other player slot.
test_hello :: proc() {
	fails := 0
	me := core.Net_Config {
		player     = 0,
		players    = 2,
		delay      = 2,
		hash_every = 60,
		mods       = 0x1111,
		disc       = 0x2222,
	}
	BUILD :: 0x3333
	peer := me
	peer.player = 1
	Case :: struct {
		what:  string,
		build: u64,
		edit:  proc(c: ^core.Net_Config),
		want:  string,
	}
	cases := []Case {
		{"same", BUILD, nil, ""},
		{"build", BUILD + 1, nil, "a different build"},
		{"mods", BUILD, proc(c: ^core.Net_Config) {c.mods = 0}, "a different mod set"},
		{"disc", BUILD, proc(c: ^core.Net_Config) {c.disc += 1}, "a different disc"},
		{"players", BUILD, proc(c: ^core.Net_Config) {c.players = 3}, "a different player count"},
		{"delay", BUILD, proc(c: ^core.Net_Config) {c.delay = 3}, "a different input delay"},
		{"hash", BUILD, proc(c: ^core.Net_Config) {c.hash_every = 30}, "a different hash interval"},
		{"slot", BUILD, proc(c: ^core.Net_Config) {c.player = 0}, "the same player slot"},
		{"slot past", BUILD, proc(c: ^core.Net_Config) {c.player = 2}, "a player slot past the player count"},
	}
	for c in cases {
		p := peer
		if c.edit != nil {c.edit(&p)}
		d := core.hello_encode(p, c.build, true)
		if got := core.hello_mismatch(d[:], me, BUILD); got != c.want {
			fmt.eprintfln("FAIL hello %s: %q, want %q", c.what, got, c.want)
			fails += 1
		}
	}
	// Another protocol version is refused before any other field is read;
	// anything not of ours is no refusal.
	other := core.hello_encode(peer, BUILD, true)
	other[4] = core.NET_VERSION - 1
	if got, want := core.version_mismatch(other[:]), fmt.tprintf("protocol v%d, this build v%d", core.NET_VERSION - 1, core.NET_VERSION); got != want {
		fmt.eprintfln("FAIL hello version: %q, want %q", got, want)
		fails += 1
	}
	same := core.hello_encode(peer, BUILD, true)
	if got := core.version_mismatch(same[:]); got != "" {
		fmt.eprintfln("FAIL hello version: same version refused: %q", got)
		fails += 1
	}
	other[0] ~= 1
	if got := core.version_mismatch(other[:]); got != "" {
		fmt.eprintfln("FAIL hello version: other magic refused: %q", got)
		fails += 1
	}
	d := core.hello_encode(peer, BUILD, true)
	if len(d) != core.HELLO_SIZE || d[4] != core.NET_VERSION || d[9] != 1 {
		fmt.eprintln("FAIL hello: size, version or seen", len(d), d[4], d[9])
		fails += 1
	}
	if fails > 0 {os.exit(1)}
	fmt.println("ok hello")
}

// core.peer_hash: the peer's hash for a frame is taken once, however many
// INPUT packets carry it. A repeat leaves the slot as compare_hash left it
// (final cleared once counted), so the hash is not counted again; the next
// frame's hash replaces it.
test_peer_hash :: proc() {
	fails := 0
	h := core.Hash{frame = -1}
	if !core.peer_hash(&h, 60, 0xaa) || h != {60, 0xaa, true} {
		fmt.eprintln("FAIL peer_hash: the first hash for 60 not taken:", h)
		fails += 1
	}
	h.final = false // counted (compare_hash)
	for _ in 0 ..< 3 {
		if core.peer_hash(&h, 60, 0xaa) || h != {60, 0xaa, false} {
			fmt.eprintln("FAIL peer_hash: a repeat of 60 taken again:", h)
			fails += 1
		}
	}
	if !core.peer_hash(&h, 120, 0xbb) || h != {120, 0xbb, true} {
		fmt.eprintln("FAIL peer_hash: the hash for 120 not taken:", h)
		fails += 1
	}
	if fails > 0 {os.exit(1)}
	fmt.println("ok peer_hash")
}
