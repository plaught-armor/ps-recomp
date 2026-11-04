// HLE sio2man at major 2 (rsio2man.h): the SIO2 transfer functions the
// pad and memory card drivers that run on the IOP CPU call.
//
// Retail's transfer is a handshake of event flags with sio2man's own thread,
// which runs the SIO2 and wakes the caller when it is done. Here a transfer
// runs to its end in the call: the init calls that open the handshake have
// nothing to do, and the transfer itself reads the request from the
// sio2_transfer_data_t and writes the reply back before it returns.
package ps2_iop

import r3000 "ps:psx/cpu"

// sio2_transfer_data_t (sio2man.h): the registers a transfer sets, the
// bytes it sends and where the reply goes. A dma_arg is {addr, size,
// count}; neither DMA path is served.
@(private = "file") TD_STAT6C :: 0x00
@(private = "file") TD_STAT70 :: 0x24
@(private = "file") TD_REGDATA :: 0x28 // 16 words, the list ends at a 0
@(private = "file") TD_STAT74 :: 0x68
@(private = "file") TD_IN_SIZE :: 0x6c
@(private = "file") TD_OUT_SIZE :: 0x70
@(private = "file") TD_IN :: 0x74
@(private = "file") TD_OUT :: 0x78
@(private = "file") TD_IN_DMA :: 0x7c
@(private = "file") TD_OUT_DMA :: 0x88
@(private = "file") TD_REGS :: 16

// The SIO2's status words after a transfer, by PCSX2's model of it
// (SioTypes.h, Sio2.cpp): stat6c, the command status, starts each transfer
// at 0. A pad frame counts the ports it opened in bits 8..11, sets
// NO_DEVICES_MISSING and, when no pad answers, its port's MISSING bits; a
// frame to any other device leaves DISCONNECTED. stat70 is PortStat and
// stat74 FifoStat, which do not change.
SIO2_DISCONNECTED :: 0x1d100
SIO2_NO_DEVICES_MISSING :: 0x1000
SIO2_PORT_1_MISSING :: 0x1d000
SIO2_PORT_2_MISSING :: 0x2d000
SIO2_ONE_PORT_OPEN :: 0x100
SIO2_TWO_PORTS_OPEN :: 0x200
SIO2_PORT_STAT :: 0xf
SIO2_FIFO_STAT :: 0

// The first byte of a frame: the device it addresses.
@(private = "file") SIO_PAD :: 0x01

// Function fno of sio2man, reading a0; v0, or false when the HLE lacks it.
// Numbers as rsio2man.h orders the major 2 table, which keeps the major 1
// numbers (sio2man.h) and repeats 4..24 at 27..47.
sio2man_fn :: proc(fno: u32) -> (v0: u32, ok: bool) {
	switch fno {
	// pad_transfer_init, mc_transfer_init, mtap_transfer_init,
	// rm_transfer_init, unknown_transfer_init, and their repeats: each
	// opens the handshake with sio2man's thread, which here does not run.
	case 23, 24, 46, 47, 48, 49, 50:
		return 0, true
	case 61, 63: // pad2_transfer_init, mc2_transfer_init: the lock, then the above
		return th_lock(), true
	case 25, 51: // transfer(td): 1, the reply in td
		td := r3000.state.r[4]
		if r32(td + TD_IN_DMA) != 0 || r32(td + TD_OUT_DMA) != 0 {return 0, false}
		sio2_transfer(td)
		return 1, true
	case 26, 52: // transfer_reset: closes the handshake
		return 0, true
	case 62: // transfer_reset3: the above, then the lock back
		th_unlock()
		return 0, true
	}
	return 0, false
}

// Runs the frames td's register list names, each sending its bytes from
// td.in in turn and putting its reply bytes in td.out in turn. A frame's
// register: port in bits 0..1, bytes sent in 8..16, bytes back in 18..26.
@(private = "file")
sio2_transfer :: proc(td: u32) {
	in_buf, out_buf := iop_ram_at(r32(td + TD_IN), r32(td + TD_IN_SIZE)), iop_ram_at(r32(td + TD_OUT), r32(td + TD_OUT_SIZE))
	stat: u32
	for i in u32(0) ..< TD_REGS {
		reg := r32(td + TD_REGDATA + 4 * i)
		if reg == 0 {break}
		n_in, n_out := int(reg >> 8 & 0x1ff), int(reg >> 18 & 0x1ff)
		send := in_buf[:min(n_in, len(in_buf))]
		reply := out_buf[:min(n_out, len(out_buf))]
		stat = sio2_frame(reg & 3, send, reply, stat)
		in_buf, out_buf = in_buf[len(send):], out_buf[len(reply):]
	}
	w32(td + TD_STAT6C, stat)
	w32(td + TD_STAT70, SIO2_PORT_STAT)
	w32(td + TD_STAT74, SIO2_FIFO_STAT)
}

// One frame to port `port`: its reply bytes, and stat6c after it. Player
// 1's pad, when connected, answers a pad frame on port 0; no device answers
// anything else, and the reply is all 0xff.
@(private = "file")
sio2_frame :: proc(port: u32, send, reply: []u8, stat: u32) -> u32 {
	for &b in reply {b = 0xff}
	if len(send) == 0 || send[0] != SIO_PAD {return SIO2_DISCONNECTED}
	stat := stat
	if stat & SIO2_ONE_PORT_OPEN != 0 {
		stat = stat &~ SIO2_ONE_PORT_OPEN | SIO2_TWO_PORTS_OPEN
	} else {
		stat |= SIO2_ONE_PORT_OPEN
	}
	stat |= SIO2_NO_DEVICES_MISSING
	if port != 0 || !pads[0].connected {
		return stat | (SIO2_PORT_1_MISSING if port == 0 else SIO2_PORT_2_MISSING)
	}
	for tx, i in send[1:] {
		rx := ds2_byte(i + 1, tx)
		if i + 1 < len(reply) {reply[i + 1] = rx}
	}
	return stat
}

// ------------------------------------------------------------- the pad

// A DualShock 2 on the wire, after PCSX2's PadDualshock2.cpp: byte 0 of a
// frame addresses the pad (answered 0xff by the SIO2), byte 1 is the
// command, answered by the mode's id, byte 2 is answered 0x5a, and each
// later byte by the command's data. The pad starts digital; 0x44 and 0x4f
// change its mode, 0x43 enters and leaves config mode (id 0xf3). One
// divergence: PCSX2 answers 0x43 outside config mode with 0x00 from byte 3
// on; here it answers with the poll bytes (see 0x43 in ds2_byte).
DS2_DIGITAL :: 0x41
DS2_ANALOG :: 0x73
DS2_DUALSHOCK2 :: 0x79
DS2_CONFIG :: 0xf3
// 0x4f's mask of the poll bytes the pad sends (PadTypes.h ResponseBytes):
// the analog set, the DualShock 2 set with pressures; any other is digital
// (ds2_mask_mode).
DS2_RESPONSE_ANALOG :: 0x3f
DS2_RESPONSE_DUALSHOCK2 :: 0x3ffff
// Motor map entries (0x4d): which motor a poll argument byte drives.
@(private = "file") DS2_MOTOR_SMALL :: 0x00
@(private = "file") DS2_MOTOR_LARGE :: 0x01

// Player 1's pad's protocol state. Emulated state: snapshotted (pad_snap).
ds2: struct {
	mode:          u8, // DS2_DIGITAL, DS2_ANALOG or DS2_DUALSHOCK2
	config:        bool,
	analog_light:  u8, // 0x44's first argument
	analog_locked: bool,
	stage:         bool, // 0x46's and 0x4c's selector
	cmd:           u8, // the current frame's command
	cmd_config:    bool, // whether it came in config mode
	response:      u32, // 0x4f's mask
	motor_map:     [6]u8,
}

// The mode a 0x4f mask of poll bytes sets, after PCSX2. The HLE padman's
// SetButtonMask (pad.odin) sends its mask through here as well, so the two
// pads agree.
ds2_mask_mode :: proc(mask: u32) -> u8 {
	switch mask {
	case DS2_RESPONSE_ANALOG: return DS2_ANALOG
	case DS2_RESPONSE_DUALSHOCK2: return DS2_DUALSHOCK2
	}
	return DS2_DIGITAL
}

ds2_reset :: proc() {
	ds2 = {mode = DS2_DIGITAL, motor_map = 0xff}
}

// The pad's answer to byte i of a frame, `tx`.
@(private = "file")
ds2_byte :: proc(i: int, tx: u8) -> u8 {
	d := &ds2
	switch i {
	case 1:
		d.cmd, d.cmd_config = tx, d.config
		return DS2_CONFIG if d.config else d.mode
	case 2:
		return 0x5a
	}
	switch d.cmd {
	case 0x40:
		switch i {
		case 5: return 0x02
		case 8: return 0x5a
		}
	case 0x41: // the poll bytes it sends, of a pad not digital
		if d.mode == DS2_DIGITAL {return 0}
		switch i {
		case 3, 4: return 0xff
		case 5: return 0x03
		case 8: return 0x5a
		}
	case 0x42:
		return ds2_poll(i, tx)
	case 0x43: // config mode: outside it, a poll as well, as the PS1 pad's (psx/bios/sio.odin); PCSX2 answers 0x00
		if i == 3 {d.config = tx != 0}
		if !d.cmd_config {return ds2_poll(i, tx, motors = false)}
	case 0x44: // mode switch: analog light, then 3 to lock the mode
		switch i {
		case 3:
			d.analog_light = tx
			d.mode = DS2_ANALOG if tx != 0 else DS2_DIGITAL
		case 4:
			d.analog_locked = tx == 3
		}
	case 0x45: // status: a standard pad, the analog light
		switch i {
		case 3: return 0x03
		case 4, 6: return 0x02
		case 5: return d.analog_light
		case 7: return 0x01
		}
	case 0x46:
		switch i {
		case 3: d.stage = tx != 0
		case 5: return 0x01
		case 6: return 0x01 if d.stage else 0x02
		case 7: return 0x01 if d.stage else 0x00
		case 8: return 0x14 if d.stage else 0x0a
		}
	case 0x47:
		switch i {
		case 5: return 0x02
		case 7: return 0x01
		}
	case 0x4c:
		switch i {
		case 3: d.stage = tx != 0
		case 6: return 0x07 if d.stage else 0x04
		}
	case 0x4d: // motor map: each byte answered by the entry it replaces
		if i < 3 || i >= 3 + len(d.motor_map) {return 0xff}
		old := d.motor_map[i - 3]
		d.motor_map[i - 3] = tx
		return old
	case 0x4f: // the poll bytes to send, which set the mode
		switch i {
		case 3, 4:
			d.response = d.response &~ (0xff << (8 * u32(i - 3))) | u32(tx) << (8 * u32(i - 3))
		case 5:
			d.response = d.response & 0xffff | u32(tx) << 16
			d.mode = ds2_mask_mode(d.response)
			d.analog_light = 0 if d.mode == DS2_DIGITAL else 1
		case 8:
			return 0x5a
		}
	}
	return 0
}

// Poll byte i: the buttons, active low, then the sticks rx, ry, lx, ly, then
// the pressures in PRESSURE's order, 0xff for a button held. With
// `motors`, argument byte k drives the motor the map gives it: the small one
// on or off (bit 0), the large one a speed.
@(private = "file")
ds2_poll :: proc(i: int, tx: u8, motors := true) -> u8 {
	p := &pads[0]
	if k := i - 3; motors && k >= 0 && k < len(ds2.motor_map) {
		switch ds2.motor_map[k] {
		case DS2_MOTOR_SMALL: p.small = tx & 1
		case DS2_MOTOR_LARGE: p.large = tx
		}
	}
	b := ~transmute(u16)p.buttons
	switch i {
	case 3: return u8(b)
	case 4: return u8(b >> 8)
	case 5 ..= 8: return p.axes[i - 5]
	case 9 ..< 9 + len(PRESSURE): return 0xff if PRESSURE[i - 9] in p.buttons else 0
	}
	return 0
}
