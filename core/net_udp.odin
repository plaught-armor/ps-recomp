// The link to the peer for netplay (net.odin has the rest): a UDP socket
// bound to cfg.bind, taking datagrams only from cfg.peer.
package core

import "core:fmt"
import "core:hash/xxhash"
import "core:net"
import "core:os"

@(private = "file")
udp: struct {
	sock: net.UDP_Socket,
	peer: net.Endpoint,
}

// Bind and make the socket non-blocking. False after a message, with
// nothing left open.
@(private)
link_open :: proc(cfg: Net_Config) -> bool {
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
	udp.peer = peer
	sock, serr := net.make_bound_udp_socket(bind.address, bind.port)
	if serr != nil {
		fmt.eprintln("net: cannot bind", cfg.bind, serr)
		return false
	}
	udp.sock = sock
	if e := net.set_blocking(sock, false); e != nil {
		fmt.eprintln("net: cannot make the socket non-blocking", e)
		net.close(sock)
		return false
	}
	return true
}

@(private)
link_close :: proc() {
	net.close(udp.sock)
}

@(private)
link_send :: proc(d: []u8) {
	_, _ = net.send_udp(udp.sock, d, udp.peer)
}

// The size of the next datagram from the peer, copied into buf; 0 when
// none is waiting (or on an error).
@(private)
link_recv :: proc(buf: []u8) -> int {
	for {
		size, from, err := net.recv_udp(udp.sock, buf)
		if err != nil || size == 0 {return 0}
		if from == udp.peer {return size}
	}
}

@(private)
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
