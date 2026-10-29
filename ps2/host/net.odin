package ps2_host

import "core:fmt"
import "core:strconv"
import "core:time"
import "ps:core"

// NET_PEER=host:port: rollback netplay (core net.odin) with that peer,
// listening on NET_BIND (default 0.0.0.0:7000) as session player
// NET_PLAYER (1 or 2), with NET_DELAY frames of input delay (default
// 2) and a desync check every NET_HASH vblanks (default 60). Testing:
// NET_DROP=<percent> drops outgoing packets, NET_LAG=<ms> delays them.
// Both hosts must run the same build from the same boot and memory card.
@(private)
NET_PLAYERS :: 2
@(private)
net_on: bool
@(private)
NET_LINGER :: 60
@(private)
quit_at: int // host side: the vblank a headless netplay run exits at

// False when a session was asked for and cannot start.
@(private)
net_init :: proc() -> bool {
	peer, ok := core.env_lookup("NET_PEER")
	if !ok {return true}
	num :: proc(name: string, def: int) -> int {
		return strconv.parse_int(core.env(name)) or_else def
	}
	cfg := core.Net_Config {
		bind       = core.env("NET_BIND"),
		peer       = peer,
		player     = num("NET_PLAYER", 1) - 1,
		players    = NET_PLAYERS,
		delay      = num("NET_DELAY", 2),
		hash_every = num("NET_HASH", 60),
		drop       = num("NET_DROP", 0),
		lag        = time.Duration(num("NET_LAG", 0)) * time.Millisecond,
	}
	if cfg.bind == "" {cfg.bind = "0.0.0.0:7000"}
	if !core.net_start(cfg) {return false}
	net_on = true
	return true
}

@(private)
print_net :: proc() {
	st := core.net_status()
	fmt.eprintfln("net: vblank %d, ping %.1f ms, ahead %d, offset %.1f, %d rollbacks (%d frames rerun), %d stalls, %d slowed, %d hashes compared, desync %d",
		vblank, time.duration_milliseconds(st.ping), st.ahead, st.offset, st.rollbacks, st.resimulated, st.stalls,
		st.slowed, st.hashes, st.desync)
}
