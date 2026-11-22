// SIO0 (0x1f801040-0x1f80104f): the pad on controller port 1 and the
// memory cards in both slots. The first byte of a transaction picks the
// device: 0x01 the pad (port 2 has none), 0x81 the card in the port the
// control register selects.
//
// The pad is a digital pad (ID 0x41), or a DualShock when rumble is enabled
// (pad_set_rumble). The DualShock follows the SCPH-1200 protocol: it answers
// the 0x42 poll like a digital pad until the game switches it to analog mode
// (ID 0x73, sticks after the buttons), and accepts the config-mode commands
// 0x43..0x4f (ID 0xf3) libpad sends to identify it and to map the motors.
// Each transaction is: 0x01 address, command (reply = ID), 0x00 (reply 0x5a),
// then argument bytes, each answered by one data byte. The controller state
// lives outside `sio` because an SIO reset does not reset the pad.
package psx_bios

import "ps:core"
import cpu "../cpu"
import io "../io"

@(private)
SIO_ACK_DELAY :: 400
// Data bytes after the 0x5a byte: digital pad, analog mode and config mode.
@(private)
PAD_DATA_DIGITAL :: 2
@(private)
PAD_DATA_FULL :: 6
// Motor map entries (command 0x4d): which motor a poll argument byte drives.
@(private)
MOTOR_SMALL :: 0x00
@(private)
MOTOR_LARGE :: 0x01
@(private)
MOTOR_NONE :: 0xff

@(private)
sio: struct {
	ctrl:   u32,
	mode:   u32,
	baud:   u32,
	rx:     u8,
	rx_full: bool,
	// Byte position within the current transaction; -1 when no device
	// answers.
	step:   int,
	// The device answering the current transaction, picked by its first
	// byte.
	dev:    Sio_Device,
	ack:    bool,
	irq:    bool,
}

@(private)
Sio_Device :: enum u8 {
	None,
	Pad,
	Card,
}

@(private)
pad: struct {
	dualshock: bool,
	analog:    bool,
	config:    bool,
	// Command byte of the current transaction and its reply data.
	cmd:       u8,
	data:      [PAD_DATA_FULL]u8,
	size:      int,
	motor_map: [PAD_DATA_FULL]u8,
	small:     bool,
	large:     u8,
}

// Enable or disable the DualShock with its motors; strength 0 keeps the plain
// digital pad. Call before the game starts.
pad_set_rumble :: proc(strength: f64) {
	pad.dualshock = strength > 0
	pad.motor_map = MOTOR_NONE
	core.input.rumble_strength = f32(clamp(strength, 0, 1))
}

@(private)
pad_id :: proc() -> u8 {
	switch {
	case pad.config:
		return 0xf3
	case pad.analog:
		return 0x73
	}
	return 0x41
}

@(private)
pad_response :: proc(tx: u8) -> (u8, bool) {
	switch sio.step {
	case 0:
		if tx != 0x01 {
			sio.step = -1
			return 0xff, false
		}
		return 0xff, true
	case 1:
		return pad_command(tx)
	case 2:
		return 0x5a, true
	}
	k := sio.step - 3
	if k >= pad.size {
		return 0xff, false
	}
	rx := pad.data[k]
	pad_argument(k, tx)
	return rx, k + 1 < pad.size
}

// The command byte: pick the reply data. Returns the ID byte.
@(private)
pad_command :: proc(cmd: u8) -> (u8, bool) {
	pad.cmd = cmd
	pad.data = {}
	pad.size = PAD_DATA_FULL
	id := pad_id()
	if pad.config {
		return id, pad_config_reply(cmd)
	}
	if cmd != 0x42 && !(cmd == 0x43 && pad.dualshock) {
		return id, false
	}
	b := ~pad_game()
	pad.data[0] = u8(b >> 8)
	pad.data[1] = u8(b)
	if !pad.analog {
		pad.size = PAD_DATA_DIGITAL
		return id, true
	}
	left, right := sticks()
	pad.data[2] = stick_byte(right.x)
	pad.data[3] = stick_byte(right.y)
	pad.data[4] = stick_byte(left.x)
	pad.data[5] = stick_byte(left.y)
	return id, true
}

// Stick axis -1..1 as the pad's 0x00..0xff with 0x80 at rest.
@(private)
stick_byte :: proc(v: f32) -> u8 {
	return u8(clamp(128 + v * 128, 0, 255))
}

// Reply data of a config-mode command; false when the pad ignores it.
@(private)
pad_config_reply :: proc(cmd: u8) -> bool {
	switch cmd {
	case 0x42, 0x43, 0x44, 0x4f:
	case 0x45:
		pad.data = {0x03, 0x02, u8(pad.analog), 0x02, 0x01, 0x00}
	case 0x47:
		pad.data = {0x00, 0x00, 0x02, 0x00, 0x01, 0x00}
	case 0x4d:
		pad.data = pad.motor_map
	case 0x46, 0x4c:
		// Filled once the selector argument arrives (pad_argument).
	case 0x40, 0x41, 0x48, 0x49, 0x4a, 0x4b, 0x4e:
	case:
		return false
	}
	return true
}

// One argument byte, sent while data byte k goes back.
@(private)
pad_argument :: proc(k: int, tx: u8) {
	switch {
	case pad.cmd == 0x42 && !pad.config && pad.dualshock:
		pad_motor_byte(k, tx)
	case pad.cmd == 0x43 && k == 0:
		pad.config = tx == 0x01
	case !pad.config:
	case pad.cmd == 0x44 && k == 0:
		pad.analog = tx == 0x01
	case pad.cmd == 0x46 && k == 0:
		pad.data[2] = 0x01
		if tx == 0 {
			pad.data[3], pad.data[4], pad.data[5] = 0x02, 0x00, 0x0a
		} else {
			pad.data[3], pad.data[4], pad.data[5] = 0x01, 0x01, 0x14
		}
	case pad.cmd == 0x4c && k == 0:
		pad.data[3] = tx == 0 ? 0x04 : 0x07
	case pad.cmd == 0x4d:
		pad.motor_map[k] = tx
	}
}

// A poll argument byte drives the motor the map gives it: the small motor
// is on or off (bit 0), the large one takes a speed 0..255.
@(private)
pad_motor_byte :: proc(k: int, tx: u8) {
	small, large := pad.small, pad.large
	switch pad.motor_map[k] {
	case MOTOR_SMALL:
		pad.small = tx & 1 != 0
	case MOTOR_LARGE:
		pad.large = tx
	case:
		return
	}
	if .Sio in core.trace.active && (small != pad.small || large != pad.large) {
		core.tracef(.Sio, "motor small %v large %d", pad.small, pad.large)
	}
	pad_rumble(pad.small, pad.large)
}

@(private)
sio_transfer :: proc(tx: u8) {
	if .Sio in core.trace.active {
		core.tracef(.Sio, "tx %02x step %d ctrl %x ra=%x", tx, sio.step, sio.ctrl, cpu.state.r[31])
	}
	sio.rx_full = true
	selected := sio.ctrl & 0x2 != 0
	if !selected || sio.step < 0 {
		sio.rx = 0xff
		return
	}
	if sio.step == 0 {
		port2 := sio.ctrl & 0x2000 != 0
		switch {
		case tx == 0x01 && !port2:
			sio.dev = .Pad
		case tx == 0x81:
			sio.dev = .Card
			mcd.slot = port2 ? CARD_SLOT_2 : CARD_SLOT_1
		case:
			sio.dev = .None
		}
	}
	rx: u8 = 0xff
	ack := false
	switch sio.dev {
	case .Pad:
		rx, ack = pad_response(tx)
	case .Card:
		rx, ack = mcd_response(tx)
	case .None:
		sio.step = -1
	}
	if .Sio in core.trace.active {
		core.tracef(.Sio, "rx %02x ack %v", rx, ack)
	}
	sio.rx = rx
	if sio.step >= 0 {
		sio.step += 1
	}
	if ack {
		io.schedule(.Sio, SIO_ACK_DELAY)
	}
}

sio_event :: proc() {
	if .Sio in core.trace.active {
		core.tracef(.Sio, "ack ctrl %x", sio.ctrl)
	}
	sio.ack = true
	if sio.ctrl & 0x1000 != 0 {
		sio.irq = true
		io.irq_raise(.Sio0)
	}
}

sio0_read :: proc(reg, size: u32) -> u32 {
	switch reg {
	case 0:
		v := sio.rx
		sio.rx = 0xff
		sio.rx_full = false
		return u32(v)
	case 4:
		s: u32 = 0x5 // TX ready, TX finished
		if sio.rx_full {
			s |= 0x2
		}
		if sio.ack {
			s |= 0x80
			sio.ack = false
		}
		if sio.irq {
			s |= 0x200
		}
		return s
	case 8:
		return sio.mode
	case 0xa:
		return sio.ctrl
	case 0xe:
		return sio.baud
	}
	return 0
}

sio0_write :: proc(reg, v, size: u32) {
	switch reg {
	case 0:
		sio_transfer(u8(v))
	case 8:
		sio.mode = v & 0xffff
	case 0xa:
		if v & 0x40 != 0 {
			sio = {}
			return
		}
		if v & 0x10 != 0 {
			sio.irq = false
		}
		if v & 0x2 == 0 || (v ~ sio.ctrl) & 0x2000 != 0 {
			sio.step = 0
		}
		sio.ctrl = v & ~u32(0x50)
	case 0xe:
		sio.baud = v & 0xffff
	}
}

// The memory card answering a transaction that began with 0x81, per the
// public nocash PSX specification: commands 'R' (0x52) read a 128-byte
// frame, 'W' (0x57) write one and 'S' (0x53) the card's ID. The bytes are
// the slot's image in card.images, the one the BIOS card functions use; a
// written frame is saved at once, as _card_write saves it.
@(private)
mcd: struct {
	slot:    int,
	cmd:     u8,
	sector:  u32,
	chk:     u8,
	// The byte sent before the current one: a card echoes it while a frame
	// is written to it.
	prev:    u8,
	// A write's end status: 'G' (0x47) good, 'N' (0x4e) a bad checksum,
	// 0xff a bad sector.
	status:  u8,
	frame:   [FRAME_SIZE]u8,
	// FLAG bit 3 is set from power-on until the card's first write.
	written: [CARD_SLOTS]bool,
}

// The reply to byte sio.step of a card transaction, and whether the card
// acknowledges it (asks for the next byte).
@(private)
mcd_response :: proc(tx: u8) -> (u8, bool) {
	prev := mcd.prev
	mcd.prev = tx
	switch sio.step {
	case 0:
		return 0xff, true
	case 1:
		mcd.cmd = tx
		flag: u8 = mcd.written[mcd.slot] ? 0x00 : 0x08
		return flag, tx == 'R' || tx == 'W' || tx == 'S'
	case 2:
		return 0x5a, true
	case 3:
		return 0x5d, true
	}
	switch mcd.cmd {
	case 'R':
		return mcd_read(sio.step, tx, prev)
	case 'W':
		return mcd_write(sio.step, tx, prev)
	case 'S':
		id := [?]u8{0x5c, 0x5d, 0x04, 0x00, 0x00, 0x80}
		k := sio.step - 4
		if k < len(id) {
			return id[k], k + 1 < len(id)
		}
	}
	return 0xff, false
}

// 'R': sector MSB and LSB in, ACK1 ACK2, the confirmed sector, 128 data
// bytes, the checksum (XOR of the sector bytes and the data) and 'G'.
@(private)
mcd_read :: proc(step: int, tx, prev: u8) -> (u8, bool) {
	switch step {
	case 4:
		mcd.sector = u32(tx) << 8
		return 0x00, true
	case 5:
		mcd.sector |= u32(tx)
		return prev, true
	case 6:
		return 0x5c, true
	case 7:
		return 0x5d, true
	case 8, 9:
		if mcd.sector >= CARD_SIZE / FRAME_SIZE {
			return 0xff, step == 8
		}
		mcd.chk = u8(mcd.sector >> 8) ~ u8(mcd.sector)
		return step == 8 ? u8(mcd.sector >> 8) : u8(mcd.sector), true
	}
	k := step - 10
	switch {
	case k < FRAME_SIZE:
		b := frame_ptr(&card.images[mcd.slot], int(mcd.sector))[k]
		mcd.chk ~= b
		return b, true
	case k == FRAME_SIZE:
		return mcd.chk, true
	case k == FRAME_SIZE + 1:
		return 'G', false
	}
	return 0xff, false
}

// 'W': sector MSB and LSB, 128 data bytes and the checksum in, each
// answered by the byte before it; then ACK1, ACK2 and the end status. A
// good frame lands on the card with the end status.
@(private)
mcd_write :: proc(step: int, tx, prev: u8) -> (u8, bool) {
	switch step {
	case 4:
		mcd.sector = u32(tx) << 8
		mcd.chk = tx
		return 0x00, true
	case 5:
		mcd.sector |= u32(tx)
		mcd.chk ~= tx
		return prev, true
	}
	k := step - 6
	switch {
	case k < FRAME_SIZE:
		mcd.frame[k] = tx
		mcd.chk ~= tx
		return prev, true
	case k == FRAME_SIZE:
		switch {
		case mcd.sector >= CARD_SIZE / FRAME_SIZE:
			mcd.status = 0xff
		case tx != mcd.chk:
			mcd.status = 'N'
		case:
			mcd.status = 'G'
		}
		return prev, true
	case k == FRAME_SIZE + 1:
		return 0x5c, true
	case k == FRAME_SIZE + 2:
		return 0x5d, true
	case k == FRAME_SIZE + 3:
		if mcd.status == 'G' {
			img := &card.images[mcd.slot]
			copy(frame_ptr(img, int(mcd.sector)), mcd.frame[:])
			card_save(img)
			mcd.written[mcd.slot] = true
		}
		return mcd.status, false
	}
	return 0xff, false
}
