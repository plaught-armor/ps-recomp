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

// One frame to port `port`: its reply bytes, and stat6c after it. No device
// answers: the reply is all 0xff.
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
	stat |= SIO2_PORT_1_MISSING if port & 1 == 0 else SIO2_PORT_2_MISSING
	return stat
}
