#+build wasi
// The link to the peer for netplay on wasm (net.odin has the rest): the
// host's "system:ps_net" imports (web/net.js), which carry the datagrams over
// whatever the host has (UDP under Node, a WebRTC data channel in a page)
// and only ever from the one peer. cfg.bind and cfg.peer go to the host
// as given; the host decides what they mean.
package core

import "core:fmt"

foreign import ps_net "system:ps_net"

@(default_calling_convention = "contextless")
foreign ps_net {
	// 0 once the link is up; blocks until then or a timeout (-1).
	@(link_name = "open")
	host_open :: proc(bind: [^]u8, bind_len: i32, peer: [^]u8, peer_len: i32) -> i32 ---
	@(link_name = "close")
	host_close :: proc() ---
	// Never blocks: a datagram the host cannot take is dropped.
	@(link_name = "send")
	host_send :: proc(data: [^]u8, size: i32) ---
	// The next datagram's size, copied to buf; 0 when none is waiting, -1
	// when it was over size (dropped).
	@(link_name = "recv")
	host_recv :: proc(buf: [^]u8, size: i32) -> i32 ---
	// The first 8 bytes of the module's SHA-256; 0 from a host with no
	// netplay.
	@(link_name = "build")
	host_build :: proc() -> u64 ---
}

@(private)
link_open :: proc(cfg: Net_Config) -> bool {
	if host_open(raw_data(cfg.bind), i32(len(cfg.bind)), raw_data(cfg.peer), i32(len(cfg.peer))) != 0 {
		fmt.eprintln("net: no link to", cfg.peer)
		return false
	}
	return true
}

@(private)
link_close :: proc() {
	host_close()
}

@(private)
link_send :: proc(d: []u8) {
	host_send(raw_data(d), i32(len(d)))
}

// The size of the next datagram from the peer, copied into buf; 0 when
// none is waiting.
@(private)
link_recv :: proc(buf: []u8) -> int {
	for {
		size := host_recv(raw_data(buf), i32(len(buf)))
		if size >= 0 {return int(size)}
	}
}

@(private)
build_id :: proc() -> u64 {
	id := host_build()
	if id == 0 {fatal("net: the host gives no build id")}
	return id
}
