// HLE padman (new libpad, sid 0x80000100) and mtapman (libmtap, sid
// 0x80000900). Open hands over a 256-byte DMA area in EE RAM: two 128-byte
// pad_data frames, of which libpad reads the one with the higher frame
// counter. pad_update rewrites both every vblank.
//
// Command numbers, arguments and result words follow the padman the discs
// load (module version 0x0422): its RPC handler switches on the command word.
// A socket's button mask is the wire 0x4f mask its pad would get, so it sets
// the mode the same way as the wire pad's (ds2_mask_mode): pressures only
// once a game asks for them, as on a DualShock 2.
//
// Player 1 is port 0 slot 0. With more than one player a multitap sits in
// port 0 and players 2..4 are its slots 1..3, which the game sees once it
// has opened the tap (mtap port 2).
package ps2_iop

import "core:fmt"
import "ps:core"
import cpu "../cpu"
import mem "../mem"

// Host input in PS2 wire order: buttons are the active-high form of pad
// data bytes 2..3 (byte 2 in the low half), axes are rx, ry, lx, ly.
Pad_Button :: core.Pad_Button

MAX_PLAYERS :: 4

Pad :: struct {
	connected: bool, // set by the host; player 1 always is
	buttons:   bit_set[Pad_Button; u16],
	axes:      [4]u8,
	// Motor levels the game asked for (SetActDirect): small is on/off,
	// large an 8-bit speed. The host drives rumble from these.
	small:     u8,
	large:     u8,
}

pads: [MAX_PLAYERS]Pad

@(private = "file")
pad_area: [2][4]u32 // per port and slot; 0 = closed

// Per port and slot: the 0x4f mask of poll bytes (SetButtonMask), reset to
// the analog set on Open.
@(private = "file")
btn_mask: [2][4]u32

// Actuator align per player (SetActAlign): which actuator each byte of a
// SetActDirect drives, 0xff for none.
@(private = "file")
act_align: [MAX_PLAYERS][6]u8

@(private = "file")
mtap: struct {
	status: u32, // EE address of the 128-byte connection table (fno 6)
	open:   [4]bool, // libmtap ports; 2 and 3 are the taps in pad ports 0 and 1
}

PAD_STATE_STABLE :: 6

// pad_data field offsets, as read by libpad (its frame pick, GetState and
// InfoMode).
@(private = "file") PD_DATA :: 0x00
@(private = "file") PD_ACT_DATA :: 0x30 // 4 bytes per actuator: func, sub, size, current
@(private = "file") PD_MODE_TABLE :: 0x50
@(private = "file") PD_FRAME :: 0x58
@(private = "file") PD_LENGTH :: 0x60
@(private = "file") PD_MODE_CONFIG :: 0x64
@(private = "file") PD_MODE_CUR_ID :: 0x65
@(private = "file") PD_MODEL :: 0x66
@(private = "file") PD_READY :: 0x67
@(private = "file") PD_NR_MODES :: 0x68
@(private = "file") PD_MODE_CUR_OFFS :: 0x69
@(private = "file") PD_NR_ACTS :: 0x6a // the game keeps room for 6
@(private = "file") PD_NR_ACT_COMB :: 0x6b
@(private = "file") PD_STATE :: 0x70 // u8
@(private = "file") PD_REQ_STATE :: 0x71 // u8, 2 = busy
@(private = "file") PD_OK :: 0x72 // u8, 1 once mode info is valid

// Pressure bytes 8..19 in order: right, left, up, down, triangle, circle,
// cross, square, L1, R1, L2, R2.
@(private)
PRESSURE := [12]Pad_Button{.Right, .Left, .Up, .Down, .Triangle, .Circle, .Cross, .Square, .L1, .R1, .L2, .R2}

@(private = "file")
pad_frame: u32

pad_init :: proc() {
	for &p in pads {p.axes = {0x80, 0x80, 0x80, 0x80}}
	pads[0].connected = true
	for &a in act_align {a = 0xff}
	for &m in btn_mask {m = DS2_RESPONSE_ANALOG}
	ds2_reset()
}

// The multitap is plugged in while more than one player is.
@(private = "file")
tap_present :: proc() -> bool {
	for p in pads[1:] {if p.connected {return true}}
	return false
}

// Player on a port and slot, or -1 for an empty socket.
@(private = "file")
pad_player :: proc(port, slot: u32) -> int {
	if port != 0 {return -1}
	if slot == 0 {return 0}
	if !tap_present() || !mtap.open[2] || !pads[slot].connected {return -1}
	return int(slot)
}

// Player on an open port and slot, or -1.
@(private = "file")
pad_open :: proc(port, slot: u32) -> int {
	if port >= 2 || slot >= 4 || pad_area[port][slot] == 0 {return -1}
	return pad_player(port, slot)
}

// Writes the current host input into every open pad area, and the
// multitap connection table.
pad_update :: proc() {
	pad_frame += 1
	for port in u32(0) ..< 2 {
		for slot in u32(0) ..< 4 {
			addr := pad_area[port][slot]
			if addr == 0 {continue}
			player := pad_player(port, slot)
			for half in u32(0) ..< 2 {
				pad_fill(mem.ram_slice(addr + half * 128, 128), pad_frame * 2 + half, player, btn_mask[port][slot])
			}
		}
	}
	if mtap.status != 0 {
		t := ([^]u32)(raw_data(mem.ram_slice(mtap.status, 128)))
		t[0] = 1 // table valid
		t[6] = 1 if tap_present() else 0 // tap in pad port 0
		t[7] = 0 // pad port 1
	}
}

// An empty socket keeps its frame counter running with state 0
// (disconnected), so a pad pulled out mid-game reads as gone. The mode the
// mask sets decides the data: the buttons, then the sticks unless digital,
// then the pressures only in DualShock 2 mode; the length is the mode's
// halfwords and the 2 bytes before them.
@(private = "file")
pad_fill :: proc(p: []u8, frame: u32, player: int, mask: u32) {
	w32 :: proc(p: []u8, o: int, v: u32) {(^u32)(&p[o])^ = v}
	w16 :: proc(p: []u8, o: int, v: u16) {(^u16)(&p[o])^ = v}
	if player < 0 {
		for &b in p {b = 0}
		w32(p, PD_FRAME, frame)
		return
	}
	pad := &pads[player]
	mode := ds2_mask_mode(mask)
	analog := mode != DS2_DIGITAL
	d := p[PD_DATA:][:32]
	d[0] = 0
	d[1] = mode
	w16(d, 2, ~transmute(u16)pad.buttons)
	copy(d[4:8], pad.axes[:] if analog else []u8{0, 0, 0, 0})
	for b, i in PRESSURE {d[8 + i] = 0xff if mode == DS2_DUALSHOCK2 && b in pad.buttons else 0}
	// DualShock 2 motors: small (on/off) and large (8-bit speed).
	copy(p[PD_ACT_DATA:][:8], []u8{1, 0, 0, 1, 1, 1, 1, 10})
	w16(p, PD_MODE_TABLE + 0, 4)
	w16(p, PD_MODE_TABLE + 2, 7)
	w32(p, PD_FRAME, frame)
	w32(p, PD_LENGTH, 2 + 2 * u32(mode & 0xf))
	p[PD_MODE_CONFIG] = 2 // 1 = no mode info yet, 2+ = modes and actuators known
	p[PD_MODE_CUR_ID] = mode
	p[PD_MODEL] = 3 // DualShock 2
	p[PD_READY] = 1
	p[PD_NR_MODES] = 2
	p[PD_MODE_CUR_OFFS] = 1 if analog else 0 // in the mode table
	p[PD_NR_ACTS] = 2
	p[PD_NR_ACT_COMB] = 0
	p[PD_STATE] = PAD_STATE_STABLE
	p[PD_REQ_STATE] = 0
	p[PD_OK] = 1
}

// padman: the command is the first word of the request; the result word
// depends on the command, the fourth for most. It serves two sids alike,
// and the row of a command it does not handle carries the sid called.
PADMAN_SID :: 0x80000100
PADMAN_SID_101 :: 0x80000101

@(private)
padman_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {return padman(PADMAN_SID, buf)}

@(private)
padman_server_101 :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {return padman(PADMAN_SID_101, buf)}

@(private)
padman :: proc(sid: u32, buf: []u8) -> bool {
	w := ([^]u32)(raw_data(buf))
	cmd := w[0]
	switch cmd {
	case 0x00000001, 0x80000100: // Open {cmd, port, slot, ?, pad data}
		if cpu.debug >= 1 {fmt.eprintfln("pad: open port %d slot %d data %08x", w[1], w[2], w[4])}
		if w[1] < 2 && w[2] < 4 {
			pad_area[w[1]][w[2]] = w[4]
			btn_mask[w[1]][w[2]] = DS2_RESPONSE_ANALOG
			pad_update()
		}
		w[3] = 1
	case 0x0e, 0x8000010d: // Close {cmd, port, slot}
		if w[1] < 2 && w[2] < 4 {pad_area[w[1]][w[2]] = 0}
		w[3] = 1
	case 0x80000105, 0x10: // SetMainMode (old protocol), Init
		w[3] = 1
	// SetMainMode {cmd, port, slot, mode, lock}: the pad stays a DualShock in
	// analog mode either way. libpad marks the request busy until the next
	// pad_update clears reqState.
	case 0x06: w[5] = 1
	case 0x07, 0x08: // SetActDirect, SetActAlign {cmd, port, slot, u8[6]}
		w[5] = 1
		player := pad_player(w[1], w[2]) if w[1] < 2 && w[2] < 4 else -1
		if player < 0 {break}
		b := buf[12:18]
		if cmd == 0x08 {
			copy(act_align[player][:], b)
			break
		}
		pad := &pads[player]
		pad.small, pad.large = 0, 0
		for a, i in act_align[player] {
			switch a {
			case 0: pad.small = b[i]
			case 1: pad.large = b[i]
			}
		}
	// GetButtonMask {cmd, port, slot}: what the pad answered wire 0x41 at
	// open, which a DualShock 2 in analog mode answers with every byte.
	case 0x09: w[3] = DS2_RESPONSE_DUALSHOCK2 if pad_open(w[1], w[2]) >= 0 else 0
	case 0x0a: // SetButtonMask {cmd, port, slot, mask}: a mask of the 12 pressures, sent as 0x4f's after the 6 bytes before them
		ok := pad_open(w[1], w[2]) >= 0
		if ok {btn_mask[w[1]][w[2]] = w[3] << 6 | DS2_RESPONSE_ANALOG}
		w[4] = 1 if ok else 0
	// SetVref {cmd, port, slot, u8[12]}: the pressure levels, which change
	// nothing here, where a pressure is 0 or 0xff.
	case 0x0b: w[7] = 1 if pad_open(w[1], w[2]) >= 0 else 0
	case 0x0c: w[3] = 2 // GetPortMax
	case 0x0d: // GetSlotMax {cmd, port}: the multitap's 4 once libmtap opened it
		w[3] = 4 if w[1] == 0 && tap_present() && mtap.open[2] else 1
	case 0x12: w[3] = 0x400 // GetModuleVersion
	case:
		// The command word is padman's function: the row's function number.
		if !core.compat_unknown(.Sif_Rpc, sid, sub = cmd) {fmt.eprintfln("pad: unhandled command %08x", cmd)}
		w[3] = 0
	}
	return true
}

// mtapman: arguments and results are words of the 128-byte buffer.
@(private)
mtap_server :: proc(fno: u32, buf: []u8, send_size: u32) -> bool {
	w := ([^]u32)(raw_data(buf))
	switch fno {
	case 1, 2: // PortOpen, PortClose {port} -> w[1]
		if w[0] < 4 {mtap.open[w[0]] = fno == 1}
		w[1] = 1
	case 5: w[0] = 0x310 // version; libmtap wants 0x31x
	case 6: // connection table address {_, addr}
		mtap.status = w[1]
		pad_update()
		w[0] = 1
	case:
		fmt.eprintfln("mtap: unhandled fno %d", fno)
		w[0] = 0
	}
	return true
}

// Emulated state, saved and restored by snapshots (snap.odin).
pad_snap :: proc() {
	core.snap_add(&pad_area)
	core.snap_add(&btn_mask)
	core.snap_add(&act_align)
	core.snap_add(&mtap)
	core.snap_add(&pad_frame)
	core.snap_add(&ds2)
}
