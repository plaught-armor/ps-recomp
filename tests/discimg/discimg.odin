// Small ISO9660 images for the tests that read discs (tests/disc,
// tests/play): one volume of SYSTEM.CNF, a subdirectory and a file over three
// sectors, names in mixed case with `;1`, as an .iso or as raw sectors, and
// an audio track.
package discimg

import "core:encoding/endian"
import "ps:core/disc"

// The volume: PVD at 16, its terminator at 17, the root at 20, DATA at 21,
// SYSTEM.CNF at 22, Big.Bin at 23 .. 25, DATA/Sub.Txt at 26; 27 and 28 are
// left out of every file, and 27 is Form 2 in the Mode 2 image. A sub file
// (make_iso's sub) over one sector runs on into 27 and 28. A second file in
// DATA (make_iso's sub2) starts at VOLUME and makes the volume longer.
VOLUME :: 29
BIG :: 5000
SUB :: "sub file!\n"
FORM2 :: 27
AUDIO :: 160

CNF_PS2 :: "BOOT2 = cdrom0:\\SLUS_123.45;1\r\nVER = 1.00\r\nVMODE = NTSC\r\n"
CNF_PS1 :: "BOOT = cdrom:\\DATA\\Sub.Txt;1\nTCB = 4\n"

sector :: proc(img: []u8, lba: int) -> []u8 {
	return img[lba * disc.DATA:][:disc.DATA]
}

put32 :: proc(b: []u8, v: int) {
	endian.put_u32(b[:4], .Little, u32(v))
}

// A directory record at b; its length.
record :: proc(b: []u8, lba, size: int, dir: bool, name: string) -> int {
	n := 33 + len(name)
	n += n & 1
	b[0] = u8(n)
	put32(b[2:], lba)
	put32(b[10:], size)
	b[25] = dir ? 2 : 0
	b[32] = u8(len(name))
	copy(b[33:], name)
	return n
}

make_iso :: proc(
	cnf: string,
	cnf_name := "SYSTEM.CNF;1",
	sub_name := "Sub.Txt;1",
	sub := SUB,
	sub2_name := "",
	sub2 := "",
) -> []u8 {
	assert(len(sub) <= (VOLUME - 26) * disc.DATA)
	volume := VOLUME + (len(sub2) + disc.DATA - 1) / disc.DATA
	img := make([]u8, volume * disc.DATA)
	pvd := sector(img, 16)
	pvd[0], pvd[6] = 1, 1
	copy(pvd[1:6], "CD001")
	put32(pvd[80:], volume)
	record(pvd[156:190], 20, disc.DATA, true, "\x00")
	term := sector(img, 17)
	term[0] = 255
	copy(term[1:6], "CD001")
	root := sector(img, 20)
	at := record(root, 20, disc.DATA, true, "\x00")
	at += record(root[at:], 20, disc.DATA, true, "\x01")
	at += record(root[at:], 22, len(cnf), false, cnf_name)
	at += record(root[at:], 21, disc.DATA, true, "DATA")
	record(root[at:], 23, BIG, false, "Big.Bin;1")
	sub_dir := sector(img, 21)
	at = record(sub_dir, 21, disc.DATA, true, "\x00")
	at += record(sub_dir[at:], 20, disc.DATA, true, "\x01")
	at += record(sub_dir[at:], 26, len(sub), false, sub_name)
	if sub2_name != "" {
		record(sub_dir[at:], VOLUME, len(sub2), false, sub2_name)
		copy(img[VOLUME * disc.DATA:], sub2)
	}
	copy(sector(img, 22), cnf)
	for i in 0 ..< BIG {
		img[23 * disc.DATA + i] = big_byte(i)
	}
	copy(img[26 * disc.DATA:], sub)
	return img
}

big_byte :: proc(i: int) -> u8 {
	return u8(i * 7 + 3)
}

// The ISO as raw sectors of mode 1 or 2 (Form 1, but FORM2 Form 2).
make_raw :: proc(iso: []u8, mode: u8) -> []u8 {
	n := len(iso) / disc.DATA
	out := make([]u8, n * disc.RAW)
	for lba in 0 ..< n {
		r := out[lba * disc.RAW:][:disc.RAW]
		for &b in r[1:11] {
			b = 0xff
		}
		r[12], r[13], r[14] = disc.msf(u32(lba))
		r[15] = mode
		if mode == 1 {
			copy(r[16:], sector(iso, lba))
			continue
		}
		form: u8 = lba == FORM2 ? 0x28 : 0x08
		r[18], r[22] = form, form
		copy(r[24:], sector(iso, lba))
	}
	return out
}

make_audio :: proc(sectors: int) -> []u8 {
	out := make([]u8, sectors * disc.RAW)
	for &b, i in out {
		b = u8(i * 13 + 1)
	}
	return out
}
