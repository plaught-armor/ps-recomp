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
// (type 2) for card ports 0 and 1, which dbcman numbers ports 2 and 3,
// connected while the port has a card (mcraw.odin: port 0 always).
//
// A bound pad socket gets a 0x80-byte block every vblank, at A on even frames
// and B on odd ones: status, lengths, then the poll bytes of the mode the pad
// driver sets (pad_poll_bytes, as padman's frames and the wire pad read
// them) and 4 constant bytes after them; the frame counter at its end. The
// game loads one of two pad drivers, which differ in that mode and those 4
// bytes (Dbc_Pad_Driver); the module it loads picks the one served
// (dbcman_module).
//
// Command words of the pad driver's calls: top byte 1, a group in bits
// 16..23 and a sub command in the low 14 bits.
//
// mc2_d, the card driver, reads, writes and erases raw pages; the game's
// library keeps the filesystem. Its calls: DriverFn3 (0x131a) answers 1;
// DriverFn5 runs a command, the word itself (1..13), on a parameter block P
// at +0xc of the request: +0 first page, +4 page count, +8 page size, +0xc
// pages per block, +0x10 total pages, +0x14 and +0x18 backup blocks 1 and
// 2, +0x1c and +0x20 the source and destination blocks of a copy (+0x20 is
// also the erased block), +0x24 ECC on, +0x28 the data written. The game
// sends commands on the large server only.
//
// - One 0x80-byte status block serves both ports: +0 a sequence number,
//   +4 the driver index, +8 the result, +0xc 0x74 extra bytes. It goes to
//   the socket's A or B, a toggle shared by both ports picking which and
//   flipping each time; the EE takes the buffer with the larger number, and
//   two equal ones as a failure.
// - A port is ready from the start until command 13. On a port not ready,
//   any command but 4 and 13 sets result 0 and sends the status as it
//   stands: number, index and extra bytes from the last command, so the
//   EE reads it as failed.
// - Otherwise the command is taken: the extra bytes cleared, 0x2080
//   written at +8 of the request, result 1, the index set, the number
//   counted. With ECC on (and always for command 8) each page carries 3
//   ECC bytes per 128 data bytes after its data, 524 bytes in all.
// - Commands 1, 2, 5, 6, 8 and 11 check first page + count against the
//   total, and that each backup block lies within it (a negative one
//   passes): result 0 if not.
// - 1 reads count pages. Each page's ECC is checked and one flipped data
//   bit in each 128 bytes corrected in the copy sent, never on the card;
//   anything worse, or a failed read, sets result 0 and the rest are still
//   read. An erased page (ECC bytes all 0xff) passes. Page i's data goes
//   to A + 0x80 + i * page size, then the status to A, the toggle left as
//   it is. 8 reads one page with no check and sends the 524 bytes and the
//   rest of the driver's buffer up to 640, the same way.
// - 2 writes count pages from the data, block by block: the block erased,
//   the pages written with their ECC and read back and checked, its other
//   pages left erased. With backup block 2 not 0 and the target neither
//   backup block, the block is saved first: any interrupted write restored
//   (as 6), a marker page holding the block number written to page 0 of
//   backup block 2, the block copied to backup block 1, a second marker on
//   page 1 (the rest of each marker page whatever the driver's buffer held);
//   then the target's other pages come back from backup block 1, each
//   compared after the write (result 0 on a mismatch, 1 again on a later
//   match), and backup block 2 is erased.
// - 3 answers the card's size in the extra bytes: page size 512 (u16), 16
//   pages a block (u16), 0x4000 pages (u32).
// - 4 answers 2 for a ready card, 1 for one not ready; 12, the card's
//   authentication, the same. 13 clears ready, 1. The card is never taken
//   out, so a port stays not ready after 13.
// - 5 looks for an interrupted write in the marker pages of backup block 2:
//   1 when page 0's first word is -1 (erased); 0 when its block lies past
//   the total; 1 when page 1's is -1 or another block, backup block 2
//   erased; otherwise 2. The block number goes in the extra bytes, -1 but
//   for 2. 6 does the same and on 2 copies
//   backup block 1 back over that block and erases backup block 2.
// - 7 copies block +0x1c over block +0x20 raw (ECC bytes as they are),
//   each page read back and compared; 9 erases block +0x20; neither checks
//   the range beyond the copy's own block check.
// - 10 reads the clock (cdvdman's, all 0) into the extra bytes, 1.
// - 11 writes the first data page with its ECC to count pages from the
//   first, erasing first at each page whose low 4 bits are 0; no read back.
// - Any other command: result 1.
//
// Every write, erase and failure above ends the command at once with
// result 0, apart from what 1, 8 and 2's compare say otherwise.
package ps2_iop

import "core:encoding/endian"
import "core:fmt"
import "core:slice"
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
	mc2 = {ready = true}
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

dbcman_snap :: proc() {
	core.snap_add(&dbc)
	core.snap_add(&mc2)
}

// Whether driver `d` is connected: a pad driver while its port has a pad,
// a card driver while its port has a card.
@(private = "file")
dbc_connected :: proc(d: int) -> bool {
	drv := DBC_DRIVERS[d]
	if drv.type == DBC_CARD {return mcraw_present(int(drv.port) - 2)}
	return pad_player(drv.port, 0) >= 0
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
		r[0x8c / 4] = dbc_call(w[0], w[1], buf, ping = fno & 0xffff == 0x131a)
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

// A driver call on socket `i` (DriverFn5, or DriverFn3 for a ping): the
// size word at +8, the parameters from +0xc. The pad driver serves both
// alike.
@(private = "file")
dbc_call :: proc(i, cmd: u32, buf: []u8, ping := false) -> i32 {
	s := dbc_socket(i)
	if s == nil {return DBC_BAD_SOCKET}
	if s.driver < 0 {return DBC_UNBOUND}
	if DBC_DRIVERS[s.driver].type == DBC_CARD {return 1 if ping else mc2_exec(int(s.driver), cmd, buf)}
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

// mc2_d's buffers and the parameters of the command running.
MC2_BUF :: 0x420

Mc2_Status :: struct {
	seq:    i32,
	driver: u32,
	result: i32,
	extra:  [0x74]u8,
}

Mc2_Params :: struct {
	start, count, size, ppb, total, bk1, bk2, src, dst, ecc: i32,
}

@(private = "file")
mc2: struct {
	status:        Mc2_Status,
	toggle:        u32, // 0: the next status goes to A
	ready:         [MCRAW_PORTS]bool,
	page, verify:  [MC2_BUF]u8, // the page buffer and the read-back one
	port:          int,
	p:             Mc2_Params,
	eccsize, xfer: i32,
}

// The card's size, as command 3 answers it.
@(private = "file")
MC2_SPEC := [8]u8{0x00, 0x02, 0x10, 0x00, 0x00, 0x40, 0x00, 0x00}

// SignalData: `data` to the EE at the bound socket's A or B, plus `off`.
@(private = "file")
mc2_signal :: proc(d: int, which, off: u32, data: []u8) {
	for s in dbc.sockets {
		if !s.used || s.driver != i32(d) {continue}
		if a := s.addr[which]; a != 0 {copy(mem.ram_slice(a + off, u32(len(data))), data)}
		return
	}
}

@(private = "file")
mc2_status_bytes :: proc() -> []u8 {return ([^]u8)(&mc2.status)[:size_of(Mc2_Status)]}

// The status to A or B by the toggle, which flips.
@(private = "file")
mc2_push :: proc(d: int) {
	mc2_signal(d, mc2.toggle, 0, mc2_status_bytes())
	mc2.toggle ~= 1
}

// A mc2_d command on driver `d`: the result.
@(private = "file")
mc2_exec :: proc(d: int, cmd: u32, buf: []u8) -> i32 {
	st := &mc2.status
	port := int(DBC_DRIVERS[d].port) - 2
	if !mc2.ready[port] && cmd != 4 && cmd != 13 {
		st.result = 0
		mc2_push(d)
		return 0
	}
	st.extra = {}
	endian.unchecked_put_u32le(buf[8:], 0x2080)
	st.result = 1
	st.driver = u32(d)
	st.seq += 1
	pb := buf[0xc:]
	word :: proc(b: []u8, off: int) -> i32 {return i32(endian.unchecked_get_u32le(b[off:])) if off + 4 <= len(b) else 0}
	mc2.p = {
		start = word(pb, 0),
		count = word(pb, 4),
		size  = word(pb, 8),
		ppb   = word(pb, 0xc),
		total = word(pb, 0x10),
		bk1   = word(pb, 0x14),
		bk2   = word(pb, 0x18),
		src   = word(pb, 0x1c),
		dst   = word(pb, 0x20),
		ecc   = word(pb, 0x24),
	}
	p := &mc2.p
	data := pb[min(0x28, len(pb)):]
	mc2.port = port
	mc2.eccsize = p.size / 128 * 3 if p.ecc != 0 || cmd == 8 else 0
	mc2.xfer = p.size + mc2.eccsize
	defer mcraw_flush(port)
	switch cmd {
	case 1, 2, 5, 6, 8, 11:
		if p.start + p.count > p.total || (p.bk1 + 1) * p.ppb > p.total || (p.bk2 + 1) * p.ppb > p.total {
			st.result = 0
			mc2_push(d)
			return 0
		}
	}
	n := int(clamp(p.size, 0, MC2_BUF))
	switch cmd {
	case 1:
		for i in 0 ..< p.count {
			ok := mc2_read(p.start + i, mc2.page[:])
			if ok {ok = mc2_ecc_check(mc2.page[:])}
			if !ok {st.result = 0}
			mc2_signal(d, 0, 0x80 + u32(i * p.size), mc2.page[:n])
		}
		mc2_signal(d, 0, 0, mc2_status_bytes())
		return st.result
	case 8:
		if !mc2_read(p.start, mc2.page[:]) {st.result = 0}
		mc2_signal(d, 0, 0x80, mc2.page[:clamp(int((mc2.xfer >> 7) + 1) * 128, 0, MC2_BUF)])
		mc2_signal(d, 0, 0, mc2_status_bytes())
		return st.result
	case 2: st.result = mc2_write_blocks(data)
	case 3: copy(st.extra[:], MC2_SPEC[:])
	case 4, 12: st.result = 2 if mc2.ready[port] else 1
	case 5:
		r, blk := mc2_backup_check()
		st.result = r
		endian.unchecked_put_u32le(st.extra[:], u32(blk))
	case 6: st.result = mc2_backup_restore()
	case 7: st.result = i32(mc2_copy(p.dst, p.src))
	case 9: st.result = i32(mc2_erase(p.dst))
	case 10: // the clock, all 0: the extra bytes as cleared
	case 11:
		for i in 0 ..< p.count {
			page := p.start + i
			if page & 0xf == 0 && !mcraw_erase(port, u32(page)) {
				st.result = 0
				break
			}
			if !mc2_fill(data, 0) || !mc2_write(page, mc2.page[:]) {
				st.result = 0
				break
			}
		}
	case 13:
		mc2.ready[port] = false
	case:
		// Logged once per command: the row's first hit.
		if !core.compat_unknown(.Sif_Rpc, DBC_SID, sub = cmd) && core.compat.calls[{.Sif_Rpc, DBC_SID, cmd}].n <= 1 {fmt.eprintfln("mc2: unknown command %d", cmd)}
	}
	mc2_push(d)
	return st.result
}

// Read xfer bytes of a page into buf.
@(private = "file")
mc2_read :: proc(page: i32, buf: []u8) -> bool {
	if mc2.xfer < 0 || int(mc2.xfer) > len(buf) {return false}
	return mcraw_read(mc2.port, u32(page), buf[:mc2.xfer])
}

@(private = "file")
mc2_write :: proc(page: i32, buf: []u8) -> bool {
	if mc2.xfer < 0 || int(mc2.xfer) > len(buf) {return false}
	return mcraw_write(mc2.port, u32(page), buf[:mc2.xfer])
}

// Erase block `blk`, at its first page.
@(private = "file")
mc2_erase :: proc(blk: i32) -> bool {return mcraw_erase(mc2.port, u32(blk * mc2.p.ppb))}

// The page buffer from the data at `off`, its ECC computed.
@(private = "file")
mc2_fill :: proc(data: []u8, off: int) -> bool {
	size := int(mc2.p.size)
	if size < 0 || size > MC2_BUF || off + size > len(data) {return false}
	copy(mc2.page[:size], data[off:][:size])
	mc2_ecc_set(mc2.page[:])
	return true
}

// Whether a block lies on the card the parameters describe.
@(private = "file")
mc2_block_ok :: proc(blk: i32) -> bool {return blk >= 0 && (blk + 1) * mc2.p.ppb <= mc2.p.total}

// Copy block src over block dst raw, each page read back and compared.
@(private = "file")
mc2_copy :: proc(dst, src: i32) -> bool {
	p := &mc2.p
	if !mc2_block_ok(dst) || !mc2_block_ok(src) || !mc2_erase(dst) {return false}
	for j in 0 ..< p.ppb {
		if !mc2_read(src * p.ppb + j, mc2.page[:]) || !mc2_write(dst * p.ppb + j, mc2.page[:]) || !mc2_read(dst * p.ppb + j, mc2.verify[:]) {return false}
		if !slice.equal(mc2.page[:mc2.xfer], mc2.verify[:mc2.xfer]) {return false}
	}
	return true
}

// Command 5: 0, 1, or 2 and the block an interrupted write left.
@(private = "file")
mc2_backup_check :: proc() -> (r: i32, blk: i32) {
	p := &mc2.p
	first :: proc() -> i32 {return i32(endian.unchecked_get_u32le(mc2.page[:]))}
	if !mc2_read(p.bk2 * p.ppb, mc2.page[:]) {return 0, -1}
	w0 := first()
	if w0 == -1 {return 1, -1}
	if (w0 + 1) * p.ppb > p.total {return 0, -1}
	if !mc2_read(p.bk2 * p.ppb + 1, mc2.page[:]) {return 0, -1}
	if w1 := first(); w1 == -1 || w1 != w0 {
		mc2_erase(p.bk2)
		return 1, -1
	}
	return 2, w0
}

// Command 6: command 5, and on 2 the block back from backup block 1.
@(private = "file")
mc2_backup_restore :: proc() -> i32 {
	r, blk := mc2_backup_check()
	if r != 2 {return r}
	if !mc2_copy(blk, mc2.p.bk1) || !mc2_erase(mc2.p.bk2) {return 0}
	return 2
}

// A marker page of backup block 2: the block number over the page buffer.
@(private = "file")
mc2_marker :: proc(page, blk: i32) -> bool {
	endian.unchecked_put_u32le(mc2.page[:], u32(blk))
	mc2_ecc_set(mc2.page[:])
	return mc2_write(mc2.p.bk2 * mc2.p.ppb + page, mc2.page[:])
}

// Command 2.
@(private = "file")
mc2_write_blocks :: proc(data: []u8) -> (result: i32) {
	p := &mc2.p
	if p.ppb <= 0 {return 0}
	result = 1
	cur, off := p.start, 0
	for cur < p.start + p.count {
		blkstart := cur - cur % p.ppb
		blk := blkstart / p.ppb
		backup := blkstart != p.bk1 * p.ppb && blkstart != p.bk2 * p.ppb && p.bk2 != 0
		if backup {
			result = mc2_backup_restore()
			if result == 0 {return}
			if !mc2_marker(0, blk) || !mc2_copy(p.bk1, blk) || !mc2_marker(1, blk) {return 0}
		}
		if !mc2_erase(blk) {return 0}
		result = 1
		for j in 0 ..< p.ppb {
			switch {
			case j == cur % p.ppb && cur < p.start + p.count:
				ok := mc2_fill(data, off) && mc2_write(blkstart + j, mc2.page[:]) && mc2_read(blkstart + j, mc2.page[:]) && mc2_ecc_check(mc2.page[:])
				cur += 1
				off += int(p.size)
				if !ok {return 0}
			case backup:
				if !mc2_read(p.bk1 * p.ppb + j, mc2.page[:]) || !mc2_write(blkstart + j, mc2.page[:]) || !mc2_read(blkstart + j, mc2.verify[:]) {return 0}
				result = i32(slice.equal(mc2.page[:mc2.xfer], mc2.verify[:mc2.xfer]))
			}
		}
		if backup && !mc2_erase(p.bk2) {return 0}
	}
	return
}

// The ECC of a byte: bit 7 the parity of all 8 bits; bit 4 + j the parity
// of the bits whose index has bit j set, bit j of those whose index has it
// clear.
@(private = "file")
mc2_ecc_byte :: proc(b: u8) -> (t: u8) {
	for k in u8(0) ..< 8 {
		if b >> k & 1 == 0 {continue}
		t ~= 0x80
		for j in u8(0) ..< 3 {t ~= 1 << (j + 4) if k >> j & 1 != 0 else 1 << j}
	}
	return
}

// The 3 ECC bytes of 128 data bytes: column parity, then two line
// parities over the indexes of the bytes of odd parity.
@(private = "file")
mc2_ecc_chunk :: proc(c: []u8) -> [3]u8 {
	col, la, lb: u8
	for b, i in c[:128] {
		t := mc2_ecc_byte(b)
		col ~= t
		if t & 0x80 != 0 {
			la ~= ~u8(i)
			lb ~= u8(i)
		}
	}
	return {~col & 0x77, ~la & 0x7f, ~lb & 0x7f}
}

// The page buffer's ECC after its data, when ECC is on.
@(private = "file")
mc2_ecc_set :: proc(buf: []u8) {
	size := int(mc2.p.size)
	for c in 0 ..< int(mc2.eccsize) / 3 {
		e := mc2_ecc_chunk(buf[c * 128:])
		copy(buf[size + 3 * c:], e[:])
	}
}

// Check a page read into buf against its ECC, correcting one flipped data
// bit per 128 bytes in buf; buf's ECC bytes end up recomputed. True with
// ECC off, and for an erased page.
@(private = "file")
mc2_ecc_check :: proc(buf: []u8) -> bool {
	size, n := int(mc2.p.size), int(mc2.eccsize)
	if n == 0 {return true}
	stored: [MC2_BUF]u8
	copy(stored[:n], buf[size:][:n])
	if slice.all_of(stored[:n], 0xff) {return true}
	mc2_ecc_set(buf)
	for c in 0 ..< n / 3 {
		d0, d1, d2 := stored[3 * c] ~ buf[size + 3 * c], stored[3 * c + 1] ~ buf[size + 3 * c + 1], stored[3 * c + 2] ~ buf[size + 3 * c + 2]
		switch {
		case d0 == 0 && d1 == 0 && d2 == 0:
		case d1 ~ d2 == 0x7f && (d0 & 0xf) ~ (d0 >> 4) == 7: buf[c * 128 + int(d2)] ~= 1 << (d0 >> 4)
		case: return false
		}
	}
	return true
}
