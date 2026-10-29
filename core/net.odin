// Rollback netplay: consoles on different hosts run the same game from the
// same boot, each simulating ahead on predicted remote input and rolling
// back (rollback.odin) when the real input turns out different.
//
// The console calls net_frame once per emulated frame (every vblank, before
// the game reads its pads) with its own frame counter, one that rewinds
// with the machine (registered with snap_add), and the local player's
// input. net_frame:
// - logs the local input for frame + delay and sends it, with the inputs
//   not yet acknowledged, to the peer;
// - takes the peer's packets, and when a frame already simulated used a
//   prediction the real input contradicts, rewinds to that frame right
//   there (snap_yield; it does not return): the console resumes at that
//   frame's vblank and calls net_frame again, which hands back the logged
//   inputs until the frame the rollback came from (net_resimulating: the
//   console skips presenting and queueing audio meanwhile);
// - waits for the peer when it is too far behind to roll back to;
// - when it runs ahead of the peer, asks the console to stretch its frame
//   (net_stretch; time sync), so the faster host does not keep running into
//   that wait;
// - asks for a commit at the next vblank (snap_op = .Commit), so the
//   console must not set snap_op itself while netplay is on.
//
// Desync check: every hash_every frames the console hashes its memory
// (net_hash_due, net_hash). A hash counts once every input before its frame
// is known; the peers exchange those and compare.
//
// Wire format, little-endian UDP datagrams, each starting with
//   u32 magic, u8 version, u8 type, u8 player
// HELLO (handshake, before the game starts):
//   u8 players, u8 delay, u8 seen (the peer's HELLO arrived), u8 hash_every,
//   u64 build
// INPUT:
//   u8 count, u32 frame (sender's), u32 ack (last frame of the receiver's
//   input the sender holds), u32 first (frame of the first input), u32 time
//   and u32 echo (ms; for ping), u32 hash frame (max = none), u64 hash,
//   i16 lead (1/16 frames; the sender's frame minus the receiver's as last
//   seen, smoothed), count * (u16 buttons, u8 lx ly rx ry)
// The build id is a hash of the executable: determinism needs the same one.
//
// The input log is one record per frame with every player's input, so a
// replay could later be the same log written out.
package core

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:net"
import "core:os"
import "core:time"

NET_VERSION :: 2

// Two inputs a frame differ in buttons or axes; axes are lx ly rx ry, 0x80
// centred, as the pad reports them (the game applies its own dead zone).
Net_Input :: struct {
	buttons: Buttons,
	axes:    [4]u8,
}

NET_NEUTRAL :: Net_Input {
	axes = {0x80, 0x80, 0x80, 0x80},
}

Net_Config :: struct {
	bind, peer: string, // host:port
	player:     int, // the local player's index
	players:    int, // in the session; 2 for now
	delay:      int, // frames of local input delay, the same on every peer
	hash_every: int, // frames between desync checks; 0 for none
	drop:       int, // testing: percent of outgoing packets dropped
	lag:        time.Duration, // testing: added one-way latency
}

Net_Status :: struct {
	ping:        time.Duration,
	ahead:       int, // local frame minus the peer's
	offset:      f32, // frames this host runs ahead, latency taken out
	slowed:      int, // frames slowed down for time sync
	rollbacks:   int,
	resimulated: int, // frames run again
	stalls:      int, // frames that waited for the peer
	hashes:      int, // hashes compared with the peer's
	desync:      int, // first frame whose hashes differ; -1 for none
}

@(private = "file")
MAGIC :: 0x504e5350 // "PSNP"
@(private = "file")
LOG :: 64 // frames of input held; the live window is under half
@(private = "file")
SEND_MAX :: 32 // inputs per packet
@(private = "file")
HASHES :: 32
@(private = "file")
HELLO :: 1
@(private = "file")
INPUT :: 2
@(private = "file")
TIMEOUT :: 10 * time.Second
@(private = "file")
RESEND :: 10 * time.Millisecond // while waiting
@(private = "file")
NO_FRAME :: max(u32)
@(private = "file")
SYNC_MIN :: 1 // frames of offset before slowing down
@(private = "file")
SYNC_SMOOTH :: 16 // samples the lead is averaged over

@(private = "file")
Log_Frame :: struct {
	frame: int, // the frame held, or -1
	input: [MAX_PLAYERS]Net_Input, // as known
	used:  [MAX_PLAYERS]Net_Input, // as simulated
}

@(private = "file")
Hash :: struct {
	frame: int, // -1 for none
	hash:  u64,
	final: bool, // every input before frame was known (local ones)
}

@(private = "file")
Delayed :: struct {
	due:  time.Tick,
	data: [dynamic]u8,
}

@(private = "file")
net_state: struct {
	on:          bool,
	cfg:         Net_Config,
	alloc:       runtime.Allocator, // for delayed packets
	open:        bool, // the socket
	peer_player: int,
	sock:        net.UDP_Socket,
	peer:        net.Endpoint,
	build:       u64,
	epoch:       time.Tick,
	log:         [LOG]Log_Frame,
	upto:        [MAX_PLAYERS]int, // each player's input is known up to here
	peer_ack:    int, // our input the peer holds, up to here
	live:        int, // the newest frame run; -1 before the first
	cur:         int, // the frame being run
	rewind:      int, // earliest frame whose input proved wrong
	peer_frame:  int,
	lead:        f32, // live - peer_frame, smoothed: offset plus latency
	stretch:     f32, // share of a frame to add to the live one
	peer_lead:   f32, // the peer's own lead
	peer_time:   u32, // newest time stamp from the peer, echoed back
	last_send:   time.Tick,
	hashes:      [HASHES]Hash,
	peer_hashes: [HASHES]Hash,
	sent_hash:   int, // newest final local hash frame
	delayed:     [dynamic]Delayed,
	rng:         u64,
	status:      Net_Status,
}

// Bind, find the peer and handshake (blocking, up to TIMEOUT while the peer
// is not there yet). False after a message.
net_start :: proc(cfg: Net_Config) -> (ok: bool) {
	n := &net_state
	net_stop()
	defer if !ok {release()}
	// One peer for now; the log and wire format already take MAX_PLAYERS.
	if cfg.players != 2 ||
	   cfg.player < 0 ||
	   cfg.player >= cfg.players ||
	   cfg.delay < 0 ||
	   cfg.delay > 8 ||
	   cfg.hash_every < 0 ||
	   cfg.hash_every > 255 {
		fmt.eprintln("net: bad config", cfg)
		return false
	}
	n^ = {}
	n.cfg = cfg
	n.alloc = context.allocator
	n.delayed = make([dynamic]Delayed, n.alloc)
	n.live, n.cur, n.sent_hash = -1, -1, -1
	n.status.desync = -1
	n.rng = 0x9e3779b97f4a7c15
	for &l in n.log {l.frame = -1}
	for &h in n.hashes {h.frame = -1}
	for &h in n.peer_hashes {h.frame = -1}
	n.build = build_id()
	n.epoch = time.tick_now()

	bind, bok := net.parse_endpoint(cfg.bind)
	if !bok {
		fmt.eprintln("net: bad bind address", cfg.bind)
		return false
	}
	peer, err := net.resolve_ip4(cfg.peer)
	if err != nil {
		fmt.eprintln("net: cannot resolve", cfg.peer, err)
		return false
	}
	n.peer = peer
	sock, serr := net.make_bound_udp_socket(bind.address, bind.port)
	if serr != nil {
		fmt.eprintln("net: cannot bind", cfg.bind, serr)
		return false
	}
	n.sock, n.open = sock, true
	if e := net.set_blocking(sock, false); e != nil {
		fmt.eprintln("net: cannot make the socket non-blocking", e)
		return false
	}

	got, seen := false, false
	start := time.tick_now()
	sent: time.Tick
	for !(got && seen) {
		if time.tick_since(start) > TIMEOUT * 6 {
			fmt.eprintln("net: no answer from", cfg.peer)
			return false
		}
		if time.tick_since(sent) > 50 * time.Millisecond {
			send_hello(got)
			sent = time.tick_now()
		}
		flush_delayed()
		buf: [1500]u8
		for {
			size, from, rerr := net.recv_udp(sock, buf[:])
			if rerr != nil || size == 0 {break}
			if from != n.peer {continue}
			d := buf[:size]
			player, kind, valid := header(d)
			if !valid {continue}
			switch kind {
			case HELLO:
				if len(d) < 19 {continue}
				players, delay, every := int(d[7]), int(d[8]), int(d[10])
				build := get_u64(d[11:])
				msg := ""
				switch {
				case build != n.build:
					msg = "a different build"
				case players != cfg.players:
					msg = "a different player count"
				case delay != cfg.delay:
					msg = "a different input delay"
				case every != cfg.hash_every:
					msg = "a different hash interval"
				case player == cfg.player || player >= cfg.players:
					msg = "the same player slot"
				}
				if msg != "" {
					fmt.eprintln("net: peer refused:", msg)
					return false
				}
				got = true
				n.peer_player = player
				seen ||= d[9] != 0
			case INPUT:
				seen = got // the peer is past its handshake
			}
		}
		time.sleep(time.Millisecond)
	}
	send_hello(true)
	n.on = true
	fmt.eprintfln(
		"net: connected to %s as player %d of %d, delay %d",
		cfg.peer,
		cfg.player + 1,
		cfg.players,
		cfg.delay,
	)
	return true
}

net_stop :: proc() {
	if net_state.on {release()}
}

// Close the socket and free what net_start took, from any point in it.
@(private = "file")
release :: proc() {
	n := &net_state
	if n.open {net.close(n.sock)}
	for d in n.delayed {delete(d.data)}
	delete(n.delayed)
	n.delayed = nil
	n.open, n.on = false, false
}

net_active :: proc() -> bool {
	return net_state.on
}

// The inputs every player gives on `frame` (see the top of the file); ok is
// false once the peer is gone, and netplay stops.
net_frame :: proc(frame: int, local: Net_Input) -> (inputs: [MAX_PLAYERS]Net_Input, ok: bool) {
	n := &net_state
	if !n.on {return}
	if n.live < 0 {first_frame(frame)}
	n.cur = frame
	if frame > n.live {
		n.live = frame
		f := frame + n.cfg.delay
		if f > n.upto[n.cfg.player] {
			slot(f).input[n.cfg.player] = local
			n.upto[n.cfg.player] = f
		}
	}
	if frame == n.live {
		n.rewind = max(int)
		receive()
		if behind() {
			n.status.stalls += 1
			start := time.tick_now()
			for behind() {
				if time.tick_since(start) > TIMEOUT {
					fmt.eprintln("net: peer timed out")
					net_stop()
					return
				}
				if time.tick_since(n.last_send) > RESEND {send_input()}
				time.sleep(time.Millisecond)
				receive()
			}
		}
		send_input()
		sync()
		if n.rewind < frame {
			back := frame - n.rewind + 1
			assert(back <= rb_frames(), "net: rollback past the held frames")
			n.status.rollbacks += 1
			n.status.resimulated += frame - n.rewind
			snap_op, rb_back = .Rewind, back
			snap_yield()
			unreachable()
		}
		finalize_hashes()
	}
	l := slot(frame)
	for p in 0 ..< n.cfg.players {
		in_ := frame <= n.upto[p] ? l.input[p] : slot(n.upto[p]).input[p]
		l.used[p] = in_
		inputs[p] = in_
	}
	snap_op = .Commit
	return inputs, true
}

// The frame being run is a rerun after a rollback: nothing of it is shown.
net_resimulating :: proc() -> bool {
	return net_state.on && net_state.cur < net_state.live
}

// The share of a frame the console should add to this one's time, to let
// the peer catch up; 0 when unpaced (headless) is fine too.
net_stretch :: proc() -> f32 {
	n := &net_state
	return n.on && n.cur == n.live ? n.stretch : 0
}

// The console should hash its memory for this frame (net_hash).
net_hash_due :: proc() -> bool {
	n := &net_state
	return n.on && n.cfg.hash_every > 0 && n.cur % n.cfg.hash_every == 0
}

net_hash :: proc(h: u64) {
	n := &net_state
	n.hashes[(n.cur / n.cfg.hash_every) % HASHES] = {n.cur, h, false}
}

net_status :: proc() -> Net_Status {
	return net_state.status
}

@(private = "file")
first_frame :: proc(frame: int) {
	n := &net_state
	// Nothing before the first frame can be rolled back to, so the inputs
	// up to the delay (and the first frame's, with no delay) are neutral.
	known := frame + max(n.cfg.delay, 1) - 1
	for f in frame ..= known {
		l := slot(f)
		for p in 0 ..< MAX_PLAYERS {l.input[p] = NET_NEUTRAL}
	}
	for p in 0 ..< MAX_PLAYERS {n.upto[p] = known}
	n.peer_ack = known
	n.live = frame - 1
}

@(private = "file")
slot :: proc(frame: int) -> ^Log_Frame {
	l := &net_state.log[frame % LOG]
	if l.frame != frame {l^ = {
			frame = frame,
		}}
	return l
}

// The peer's input is too old to roll back to from the next frame.
@(private = "file")
behind :: proc() -> bool {
	n := &net_state
	for p in 0 ..< n.cfg.players {
		if n.upto[p] < n.live - (RB_FRAMES - 1) {return true}
	}
	return false
}

@(private = "file")
receive :: proc() {
	n := &net_state
	flush_delayed()
	buf: [1500]u8
	for n.on {
		size, from, err := net.recv_udp(n.sock, buf[:])
		if err != nil || size == 0 {return}
		if from != n.peer {continue}
		d := buf[:size]
		player, kind, ok := header(d)
		if !ok {continue}
		switch kind {
		case HELLO:
			send_hello(true) // our last HELLO may have been lost
		case INPUT:
			take_input(player, d)
		}
	}
}

@(private = "file")
INPUT_HEAD :: 42

// Each lead is the true offset plus the one-way latency, measured from
// opposite ends, so half their difference is the offset alone. The host
// that is ahead gives up a quarter frame per frame until it is not.
@(private = "file")
sync :: proc() {
	n := &net_state
	n.status.offset = (n.lead - n.peer_lead) / 2
	n.stretch = 0
	if n.status.offset < SYNC_MIN {return}
	n.stretch = 0.25
	n.status.slowed += 1
}

@(private = "file")
take_input :: proc(player: int, d: []u8) {
	n := &net_state
	if len(d) < INPUT_HEAD || player != n.peer_player {return}
	count := int(d[7])
	if len(d) < INPUT_HEAD + count * 6 {return}
	if pf := int(get_u32(d[8:])); pf >= n.peer_frame {
		n.peer_frame = pf
		n.lead += (f32(n.live - pf) - n.lead) / SYNC_SMOOTH
		n.peer_lead = f32(i16(get_u16(d[40:]))) / 16
	}
	n.status.ahead = n.live - n.peer_frame
	n.peer_ack = max(n.peer_ack, int(get_u32(d[12:])))
	first := int(get_u32(d[16:]))
	t, echo := get_u32(d[20:]), get_u32(d[24:])
	n.peer_time = t
	if echo !=
	   0 {n.status.ping = time.tick_since(n.epoch) - time.Duration(echo) * time.Millisecond}
	if hf := get_u32(d[28:]); hf != NO_FRAME && n.cfg.hash_every > 0 {
		h := &n.peer_hashes[(int(hf) / n.cfg.hash_every) % HASHES]
		h^ = {int(hf), get_u64(d[32:]), true}
		compare_hash(int(hf))
	}
	for i in 0 ..< count {
		f := first + i
		if f <= n.upto[player] {continue}
		if f != n.upto[player] + 1 || f > n.live + LOG / 2 {break}
		e := d[INPUT_HEAD + i * 6:]
		in_ := Net_Input{transmute(Buttons)get_u16(e), {e[2], e[3], e[4], e[5]}}
		l := slot(f)
		l.input[player] = in_
		n.upto[player] = f
		if f < n.live && l.used[player] != in_ {n.rewind = min(n.rewind, f)}
	}
}

@(private = "file")
send_input :: proc() {
	n := &net_state
	me := n.cfg.player
	first := n.peer_ack + 1
	count := clamp(n.upto[me] - n.peer_ack, 0, SEND_MAX)
	buf: [INPUT_HEAD + SEND_MAX * 6]u8
	put_header(buf[:], INPUT)
	buf[7] = u8(count)
	put_u32(buf[8:], u32(n.live))
	put_u32(buf[12:], u32(n.upto[n.peer_player]))
	put_u32(buf[16:], u32(first))
	put_u32(buf[20:], max(u32(time.duration_milliseconds(time.tick_since(n.epoch))), 1))
	put_u32(buf[24:], n.peer_time)
	put_u32(buf[28:], NO_FRAME)
	put_u16(buf[40:], u16(i16(clamp(n.lead * 16, -32768, 32767))))
	if n.sent_hash >= 0 {
		h := n.hashes[(n.sent_hash / n.cfg.hash_every) % HASHES]
		put_u32(buf[28:], u32(h.frame))
		put_u64(buf[32:], h.hash)
	}
	for i in 0 ..< count {
		in_ := slot(first + i).input[me]
		e := buf[INPUT_HEAD + i * 6:]
		put_u16(e, transmute(u16)in_.buttons)
		copy(e[2:6], in_.axes[:])
	}
	send(buf[:INPUT_HEAD + count * 6])
	n.last_send = time.tick_now()
}

@(private = "file")
send_hello :: proc(seen: bool) {
	n := &net_state
	buf: [19]u8
	put_header(buf[:], HELLO)
	buf[7] = u8(n.cfg.players)
	buf[8] = u8(n.cfg.delay)
	buf[9] = u8(seen)
	buf[10] = u8(n.cfg.hash_every)
	put_u64(buf[11:], n.build)
	send(buf[:])
}

// Send now, or after cfg.lag, unless cfg.drop loses it.
@(private = "file")
send :: proc(d: []u8) {
	n := &net_state
	if n.cfg.drop > 0 {
		n.rng ~= n.rng << 13
		n.rng ~= n.rng >> 7
		n.rng ~= n.rng << 17
		if int(n.rng % 100) < n.cfg.drop {return}
	}
	if n.cfg.lag > 0 {
		data := make([dynamic]u8, 0, len(d), n.alloc)
		append(&data, ..d)
		append(&n.delayed, Delayed{time.tick_add(time.tick_now(), n.cfg.lag), data})
		return
	}
	_, _ = net.send_udp(n.sock, d, n.peer)
}

@(private = "file")
flush_delayed :: proc() {
	n := &net_state
	now := time.tick_now()
	i := 0
	for i < len(n.delayed) {
		if time.tick_diff(n.delayed[i].due, now) < 0 {break}
		_, _ = net.send_udp(n.sock, n.delayed[i].data[:], n.peer)
		delete(n.delayed[i].data)
		i += 1
	}
	remove_range(&n.delayed, 0, i)
}

// Local hashes become final once every input before their frame is known:
// a wrong prediction before then has already been rolled back and rerun.
@(private = "file")
finalize_hashes :: proc() {
	n := &net_state
	if n.cfg.hash_every <= 0 {return}
	known := max(int)
	for p in 0 ..< n.cfg.players {known = min(known, n.upto[p])}
	for &h in n.hashes {
		if h.frame < 0 || h.final || h.frame - 1 > known || h.frame >= n.live {continue}
		h.final = true
		n.sent_hash = max(n.sent_hash, h.frame)
		compare_hash(h.frame)
	}
}

@(private = "file")
compare_hash :: proc(frame: int) {
	n := &net_state
	i := (frame / n.cfg.hash_every) % HASHES
	a, b := n.hashes[i], n.peer_hashes[i]
	if a.frame != frame || b.frame != frame || !a.final || !b.final {return}
	n.status.hashes += 1
	n.peer_hashes[i].final = false // counted
	if a.hash != b.hash && n.status.desync < 0 {
		n.status.desync = frame
		fmt.eprintfln(
			"net: desync at frame %d (%016x here, %016x on the peer)",
			frame,
			a.hash,
			b.hash,
		)
	}
}

@(private = "file")
build_id :: proc() -> u64 {
	path := "/proc/self/exe" when ODIN_OS == .Linux else os.args[0]
	f, err := os.open(path)
	if err != nil {return 0}
	defer os.close(f)
	state: xxhash.XXH3_state
	xxhash.XXH3_init_state(&state)
	_ = xxhash.XXH3_64_reset(&state)
	buf: [1 << 16]u8
	for {
		size, rerr := os.read(f, buf[:])
		if size > 0 {_ = xxhash.XXH3_64_update(&state, buf[:size])}
		if rerr != nil || size == 0 {break}
	}
	return xxhash.XXH3_64_digest(&state)
}

@(private = "file")
header :: proc(d: []u8) -> (player, kind: int, ok: bool) {
	if len(d) < 7 || get_u32(d) != MAGIC || d[4] != NET_VERSION {return}
	return int(d[6]), int(d[5]), true
}

@(private = "file")
put_header :: proc(d: []u8, kind: u8) {
	put_u32(d, MAGIC)
	d[4] = NET_VERSION
	d[5] = kind
	d[6] = u8(net_state.cfg.player)
}

@(private = "file")
put_u16 :: proc(d: []u8, v: u16) {
	d[0], d[1] = u8(v), u8(v >> 8)
}

@(private = "file")
put_u32 :: proc(d: []u8, v: u32) {
	for i in 0 ..< 4 {d[i] = u8(v >> uint(8 * i))}
}

@(private = "file")
put_u64 :: proc(d: []u8, v: u64) {
	for i in 0 ..< 8 {d[i] = u8(v >> uint(8 * i))}
}

@(private = "file")
get_u16 :: proc(d: []u8) -> u16 {
	return u16(d[0]) | u16(d[1]) << 8
}

@(private = "file")
get_u32 :: proc(d: []u8) -> (v: u32) {
	for i in 0 ..< 4 {v |= u32(d[i]) << uint(8 * i)}
	return
}

@(private = "file")
get_u64 :: proc(d: []u8) -> (v: u64) {
	for i in 0 ..< 8 {v |= u64(d[i]) << uint(8 * i)}
	return
}
