// HLE dbcman (module version 0x310) and the device drivers behind it: a pad
// driver (ds1o_d or ds2u) and the memory card driver mc2_d, so none of these
// modules, nor sio2d under them, runs on the IOP.
//
// dbcman binds EE sockets to IOP drivers. The EE creates a socket with a
// filter (driver type, port and slot, sub id, name: the match flags pick
// which must be equal) and two EE addresses, A and B. A socket is bound while
// a connected driver matches it, one socket per driver. Commands on a bound
// socket go to its driver; the driver writes its data to A or B. dbcman keeps
// a link flag per socket, 1 while it is bound, and writes the 16 of them to
// the EE's flag buffer on each create and delete and when a binding changes.
//
// The drivers, as the modules register them: a pad driver (type 1) for pad
// ports 0 and 1, connected while the port has a pad, and a card driver
// (type 2) for card ports 0 and 1, which dbcman numbers ports 2 and 3. The
// card drivers are never connected, so the game sees both card slots empty.
//
// A bound pad socket gets a 0x80-byte block every vblank, at A on even frames
// and B on odd ones: status, lengths, then the poll bytes of the mode the pad
// driver sets (pad_poll_bytes, as padman's frames and the wire pad read
// them) and 4 constant bytes after them; the frame counter at its end. The
// game loads one of two pad drivers, which differ in that mode and those 4
// bytes (Dbc_Pad_Driver); the module it loads picks the one served
// (dbcman_module).
//
// Command words of the driver calls: top byte 1, a group in bits 16..23 and
// a sub command in the low 14 bits.
package ps2_iop

import "core:fmt"
import "core:strings"
import "ps:core"
import mem "../mem"

DBC_SID :: 0x80001300
DBC_SID_BIG :: 0x8000131c // driver calls of up to 0x2090 bytes
DBC_SID_FAST0 :: 0x8000131e // driver calls of up to 0x90 bytes
DBC_SID_FAST1 :: 0x8000131f
DBC_VERSION :: 0x310

DBC_SOCKETS :: 16
DBC_PAD :: 1 // driver types
DBC_CARD :: 2

// Match flags: which fields of a socket's filter must equal the driver's.
DBC_MATCH_TYPE :: 1
DBC_MATCH_PORT :: 2 // port and slot
DBC_MATCH_SUB :: 4
DBC_MATCH_NAME :: 8

// Results.
DBC_NO_DRIVER :: -0x0c
DBC_NO_SOCKET :: -0x15 // CreateSocket: none free
DBC_BAD_SOCKET :: -0x16
DBC_UNBOUND :: -0x17
DBC_BAD_CMD :: -1 // a command word whose top byte is not 1
DBC_BAD_GROUP :: -2
DBC_BAD_SUB :: -3

// Pad commands, as the game sends them (bits 14..15 are ignored).
DBC_PAD_MODE :: 0x01_02 // group 1: the pad's id
DBC_PAD_STATUS :: 0x01_0c // connection status
DBC_PAD_FILL :: 0x02_02 // group 2: the 4 bytes after the poll bytes
DBC_PAD_ACT_INFO :: 0x03_02 // group 3: whether the pad has motors
DBC_PAD_ACT :: 0x03_0b // set the motors

DBC_PAD_ACTS :: 3 // ACT_INFO for a pad with motors

// A pad driver, as it sets the pad up: the pad's id, whose low nibble is
// the halfwords of poll bytes it sends, and the 4 bytes after them.
Dbc_Pad_Driver :: struct {
	id:     u8,
	filler: [4]u8,
}

// ds1o_d leaves a DualShock in analog mode: 6 poll bytes. ds2u puts it in
// DualShock 2 mode: 18, the pressures too. Neither module checks the
// pressures against the buttons in a way pad_poll_bytes' could fail (ds2u
// sets a pressure of 0 for a held button to 1, and of a released one to 0).
DBC_DS1O_D :: Dbc_Pad_Driver{0x73, {0xff, 0xff, 0x0f, 0x00}}
DBC_DS2U :: Dbc_Pad_Driver{0x79, {0xff, 0xff, 0xff, 0xff}}

// The drivers: index, type and port, slot 0, sub id 0 and an empty name.
@(private = "file")
DBC_DRIVERS := [4]struct {
	type, port: u32,
}{{DBC_PAD, 0}, {DBC_PAD, 1}, {DBC_CARD, 2}, {DBC_CARD, 3}}

Dbc_Socket :: struct {
	used:              bool,
	flags, type:       u32,
	port, slot, sub:   u32,
	name:              [16]u8,
	addr:              [2]u32, // A, B
	driver:            i32, // bound to, or -1
}

@(private = "file")
dbc: struct {
	sockets: [DBC_SOCKETS]Dbc_Socket,
	flag_buf: u32, // EE address of the 16 link flags; 0 = none
	// The pad driver's frame counter per driver: it counts the vblanks a
	// pad has been connected, bound to a socket or not, as the drivers
	// keep it in their port state and clear it when the pad goes.
	frame:    [len(DBC_DRIVERS)]u32,
	pad:      Dbc_Pad_Driver,
}

dbcman_init :: proc() {
	dbc = {pad = DBC_DS1O_D}
	for &s in dbc.sockets {s.driver = -1}
}

// A module load: the pad driver it names, by file or module name (ds1o_d,
// or ds2u or ds2u_d, ignoring case and any directory, extension or
// version), is the one served from then on, its frame counters at 0 as its
// start leaves them. Other names change nothing.
dbcman_module :: proc(path: string) {
	name := path[strings.last_index_any(path, `\/:`) + 1:]
	name, _, _ = strings.partition(name, ".")
	switch {
	case strings.equal_fold(name, "ds1o_d"): dbc.pad = DBC_DS1O_D
	case strings.equal_fold(name, "ds2u") || strings.equal_fold(name, "ds2u_d"): dbc.pad = DBC_DS2U
	case: return
	}
	dbc.frame = {}
}

dbcman_snap :: proc() {core.snap_add(&dbc)}

// Whether driver `d` is connected: a pad driver while its port has a pad,
// a card driver never.
@(private = "file")
dbc_connected :: proc(d: int) -> bool {
	drv := DBC_DRIVERS[d]
	return drv.type == DBC_PAD && pad_player(drv.port, 0) >= 0
}

@(private = "file")
dbc_matches :: proc(s: ^Dbc_Socket, d: int) -> bool {
	drv := DBC_DRIVERS[d]
	if s.flags & DBC_MATCH_TYPE != 0 && s.type != drv.type {return false}
	if s.flags & DBC_MATCH_PORT != 0 && (s.port != drv.port || s.slot != 0) {return false}
	if s.flags & DBC_MATCH_SUB != 0 && s.sub != 0 {return false}
	if s.flags & DBC_MATCH_NAME != 0 && s.name[0] != 0 {return false}
	return true
}

// Binds each created socket, in index order, to the first connected driver
// that matches it and no earlier socket holds. Reports whether a binding
// changed.
@(private = "file")
dbc_bind :: proc() -> (changed: bool) {
	held: [len(DBC_DRIVERS)]bool
	for &s in dbc.sockets {
		driver := i32(-1)
		if s.used {
			for d in 0 ..< len(DBC_DRIVERS) {
				if !held[d] && dbc_connected(d) && dbc_matches(&s, d) {
					driver = i32(d)
					held[d] = true
					break
				}
			}
		}
		if driver != s.driver {changed = true}
		s.driver = driver
	}
	return
}

// Writes the link flags to the EE's flag buffer.
@(private = "file")
dbc_flags_push :: proc() {
	if dbc.flag_buf == 0 {return}
	f := ([^]u32)(raw_data(mem.ram_slice(dbc.flag_buf, DBC_SOCKETS * 4)))
	for s, i in dbc.sockets {f[i] = 1 if s.driver >= 0 else 0}
}

// Writes every bound pad socket's block, and the flags when a pad came or
// went; then counts the frame of each connected pad. Runs every vblank.
//
// Timing: the block holds this vblank's input. Retail's driver polls the
// pad in a thread woken at vblank start and SIF-DMAs the block when the
// poll is done, so the EE sees it up to about a frame later.
dbcman_vblank :: proc() {
	if dbc_bind() {dbc_flags_push()}
	for s in dbc.sockets {
		if s.driver < 0 || DBC_DRIVERS[s.driver].type != DBC_PAD {continue}
		n := dbc.frame[s.driver]
		if addr := s.addr[n & 1]; addr != 0 {
			dbc_pad_block(mem.ram_slice(addr, 0x80), pad_player(DBC_DRIVERS[s.driver].port, 0), n)
		}
	}
	for &n, d in dbc.frame {n = n + 1 if dbc_connected(d) else 0}
}

// A pad block: status 1, the data length and that plus 4, 4, then a word
// that is 1 when the last SIO2 transfer came back clean (both drivers set
// it from the transfer status, and the EE side reads 0 as no pad), the
// data from 0x1c and the frame number at 0x7c. Only connected pads get a
// block, so the word is always 1 here.
@(private = "file")
dbc_pad_block :: proc(p: []u8, player: int, frame: u32) {
	for &b in p {b = 0}
	n := 2 * int(dbc.pad.id & 0xf)
	p[0] = 1
	p[1] = u8(n) + 4
	p[2] = u8(n)
	p[3] = 4
	p[4] = 1
	poll := pad_poll_bytes(player)
	copy(p[0x1c:], poll[:n])
	copy(p[0x1c + n:], dbc.pad.filler[:])
	(^u32)(&p[0x7c])^ = frame
}

@(private)
dbcman_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	r := ([^]i32)(raw_data(buf)) // result words
	switch fno & 0xffff {
	case 0x1301: // CreateSocket {flags, type, port, slot, sub, name[16], _, A, B} -> +0x24
		i := 0
		for i < DBC_SOCKETS && dbc.sockets[i].used {i += 1}
		if i == DBC_SOCKETS {
			r[9] = DBC_NO_SOCKET
			break
		}
		s := &dbc.sockets[i]
		s^ = {
			used   = true,
			flags  = w[0],
			type   = w[1],
			port   = w[2],
			slot   = w[3],
			sub    = w[4],
			addr   = {w[10], w[11]},
			driver = -1,
		}
		copy(s.name[:], buf[0x14:][:16])
		dbc_bind()
		dbc_flags_push()
		w[9] = u32(i)
	case 0x1302: // DeleteSocket {socket} -> +4
		s := dbc_socket(w[0])
		if s == nil {
			r[1] = DBC_BAD_SOCKET
			break
		}
		s^ = {driver = -1}
		dbc_bind()
		dbc_flags_push()
		w[1] = 1
	case 0x1303: // GetBoundDriver {socket} -> +4
		s := dbc_socket(w[0])
		r[1] = DBC_BAD_SOCKET if s == nil else DBC_NO_DRIVER if s.driver < 0 else s.driver
	case 0x1304: // SetFlagBuffer {version, EE address} -> +0: the flags go there at once
		dbc.flag_buf = w[1]
		dbc_flags_push()
		w[0] = 1
	case 0x1317: w[1] = 0 // Status: unsupported, always 0
	case 0x1319, 0x131a: // DriverFn5, DriverFn3 {socket, cmd, size, param...} -> +0x8c
		r[0x8c / 4] = dbc_call(w[0], w[1], buf)
	case 0x131d: // FindSocketByDevice {_, _, _, _, port, slot} -> +4
		r[1] = DBC_NO_DRIVER
		for drv, d in DBC_DRIVERS {
			if drv.port != w[4] || w[5] != 0 || !dbc_connected(d) {continue}
			r[1] = DBC_BAD_SOCKET
			for s, i in dbc.sockets {if s.driver == i32(d) {r[1] = i32(i)}}
		}
	case 0x1363: w[0] = DBC_VERSION
	case:
		// DriverFn0, DriverFn1, DriverFn4 (0x1315, 0x1316, 0x1318): what the
		// pad driver does for them is not known.
		if !core.compat_unknown(.Sif_Rpc, DBC_SID, sub = fno) {fmt.eprintfln("dbcman: unhandled fno %08x", fno)}
		w[1] = 0
	}
	return true
}

// The driver-call servers: a DriverFn5 request, its result at the end of the
// buffer. A request larger than the buffer is not served.
@(private)
dbcman_fast_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	if send_size <= 0x90 {
		w := ([^]u32)(raw_data(buf))
		r := ([^]i32)(raw_data(buf))
		r[0x8c / 4] = dbc_call(w[0], w[1], buf)
	}
	return true
}

@(private)
dbcman_big_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	if send_size <= 0x2090 {
		w := ([^]u32)(raw_data(buf))
		r := ([^]i32)(raw_data(buf))
		r[0x208c / 4] = dbc_call(w[0], w[1], buf)
	}
	return true
}

@(private = "file")
dbc_socket :: proc(i: u32) -> ^Dbc_Socket {
	return &dbc.sockets[i] if i < DBC_SOCKETS && dbc.sockets[i].used else nil
}

// A driver call on socket `i`: the size word at +8, the parameters from
// +0xc. Only pad drivers are ever bound.
@(private = "file")
dbc_call :: proc(i, cmd: u32, buf: []u8) -> i32 {
	s := dbc_socket(i)
	if s == nil {return DBC_BAD_SOCKET}
	if s.driver < 0 {return DBC_UNBOUND}
	size := (^u32)(&buf[8])
	p := buf[0xc:]
	if cmd >> 24 != 1 {return DBC_BAD_CMD}
	group := cmd >> 16 & 0xff
	if group < 1 || group > 3 {return DBC_BAD_GROUP}
	switch group << 8 | cmd & 0x3fff {
	case DBC_PAD_MODE:
		size^ = 4
		(^u32)(&p[0])^ = u32(dbc.pad.id)
	case DBC_PAD_STATUS:
		size^ = 1
		p[0] = 1 // stable
	case DBC_PAD_FILL:
		size^ = 4
		copy(p, dbc.pad.filler[:])
	case DBC_PAD_ACT_INFO:
		size^ = 1
		p[0] = DBC_PAD_ACTS
	case DBC_PAD_ACT:
		// {_, offset, data[0], data[1], ...}: the selector at data + offset
		// picks the motors. Only port 0 has a player.
		pad := &pads[pad_player(DBC_DRIVERS[s.driver].port, 0)]
		d := p[8:]
		off := (^u32)(&p[4])^
		if off >= u32(len(d)) {return DBC_BAD_CMD}
		switch d[off] {
		case 1: pad.small = d[0] & 1
		case 2: pad.large = d[0]
		case 3: pad.small, pad.large = d[0] & 1, d[0] >> 1 | d[1] << 7
		case: return DBC_BAD_CMD
		}
	case:
		if !core.compat_unknown(.Sif_Rpc, DBC_SID, sub = cmd) {fmt.eprintfln("dbcman: unhandled pad command %08x", cmd)}
		return DBC_BAD_SUB
	}
	return 1
}
