// Disc image test: one small ISO9660 volume (SYSTEM.CNF, a subdirectory, a
// file over three sectors, names in mixed case with `;1`) read as an .iso,
// as raw Mode 1 and Mode 2 Form 1 .bin files, and through cue sheets: two
// FILEs (the second two seconds on, or after its PREGAP, or its stored
// gap) and one FILE of two tracks. A Mode 2 Form 2 sector reads as false.
// Malformed images and cue sheets fail cleanly: a truncated image, a record
// past its sector or under 34 bytes, a name past its record, bytes after a
// zero length, a directory past the volume, unknown cue lines, a TRACK with
// no FILE, a missing file, overlapping tracks and a bad time. Disc ids hash
// the volume descriptor, SYSTEM.CNF and the boot file, the same for each
// image format. The IOP finds files on an opened image by the paths games
// pass it (cdrom0:\DIR\FILE.EXT;1), a second lookup from its cache.
// The images are written to a directory under the OS temp directory,
// removed at the end whether the test passes or fails.
package main

import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "ps:core/disc"
import "ps:tests/discimg"
import iop "ps:ps2/iop"

@(private = "file")
failed: int

@(private = "file")
fail :: proc(format: string, args: ..any) {
	fmt.eprint("FAIL disc: ")
	fmt.eprintfln(format, ..args)
	failed += 1
}

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if !ok {
		fail("%s (line %d)", what, loc.line)
	}
}

@(private = "file")
dir: string

@(private = "file")
write :: proc(name: string, data: []u8) -> string {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	if os.write_entire_file(path, data) != nil {
		fail("cannot write %s", path)
	}
	return path
}

@(private = "file")
write_text :: proc(name, text: string) -> string {
	return write(name, transmute([]u8)text)
}

// Everything the volume holds, read through d.
@(private = "file")
check_volume :: proc(d: ^disc.Disc, cnf: string, what: string) {
	if d.volume != discimg.VOLUME || d.layer1 != 0 {
		fail("%s: volume %d layer1 %d", what, d.volume, d.layer1)
		return
	}
	data, ok := disc.read_file(d, "cdrom0:\\SYSTEM.CNF;1", context.temp_allocator)
	check(ok && string(data) == cnf, what)
	data, ok = disc.read_file(d, "big.bin", context.temp_allocator)
	good := ok && len(data) == discimg.BIG
	for i in 0 ..< len(data) {
		good &&= data[i] == discimg.big_byte(i)
	}
	check(good, what)
	// Across a sector boundary, and short at the image's end.
	part: [100]u8
	e, found := disc.find(d, "/BIG.BIN", context.temp_allocator)
	check(found && !e.dir && e.lba == 23 && e.size == discimg.BIG && e.name == "Big.Bin", what)
	check(disc.read_at(d, 23, 2040, part[:]) == len(part) && part[0] == discimg.big_byte(2040) && part[99] == discimg.big_byte(2139), what)
	check(disc.read_at(d, discimg.VOLUME - 1, disc.DATA - 50, part[:]) == 50, what)
	data, ok = disc.read_file(d, "/data/SUB.TXT", context.temp_allocator)
	check(ok && string(data) == discimg.SUB, what)
	data, ok = disc.read_file(d, "cdrom:DATA\\sub.txt;1", context.temp_allocator)
	check(ok && string(data) == discimg.SUB, what)
	_, ok = disc.read_file(d, "DATA", context.temp_allocator)
	check(!ok, what)
	_, ok = disc.find(d, "NOPE", context.temp_allocator)
	check(!ok, what)
	_, ok = disc.find(d, "DATA/../SYSTEM.CNF", context.temp_allocator)
	check(!ok, what)
	deep := strings.repeat("DATA/", 40, context.temp_allocator)
	_, ok = disc.find(d, deep, context.temp_allocator)
	check(!ok, what)
	root, rok := disc.list(d, "\\", context.temp_allocator)
	check(rok && len(root) == 3 && root[0].name == "SYSTEM.CNF" && root[1].name == "DATA" && root[1].dir, what)
	sub, sok := disc.list(d, "data", context.temp_allocator)
	check(sok && len(sub) == 1 && sub[0].name == "Sub.Txt" && sub[0].size == len(discimg.SUB), what)
	_, ok = disc.list(d, "BIG.BIN", context.temp_allocator)
	check(!ok, what)
	buf: [disc.DATA]u8
	check(!disc.read(d, discimg.VOLUME, buf[:]), what)
}

@(private = "file")
check_cnf :: proc(d: ^disc.Disc, boot: string, ps2: bool, serial, vmode, what: string) {
	c, ok := disc.system_cnf(d, context.temp_allocator)
	if !ok || c.boot != boot || c.ps2 != ps2 || c.serial != serial || c.vmode != vmode {
		fail("%s: system_cnf %v %v", what, c, ok)
	}
}

@(private = "file")
open :: proc(path: string, what: string) -> (d: disc.Disc, ok: bool) {
	d, ok = disc.open(path)
	if !ok {
		fail("%s: open", what)
	}
	return
}

@(private = "file")
track_is :: proc(d: ^disc.Disc, i: int, start, sectors: u32, what: string, loc := #caller_location) {
	if i >= len(d.tracks) || d.tracks[i].start != start || d.tracks[i].sectors != sectors {
		fail("%s: track %d not at %d for %d (line %d): %v", what, i, start, sectors, loc.line, d.tracks[:])
	}
}

@(private = "file")
test_formats :: proc(iso, mode1, mode2, audio: []u8) {
	iso_path := write("v.iso", iso)
	mode1_path := write("m1.bin", mode1)
	mode2_path := write("m2.bin", mode2)
	write("a.bin", audio)
	raw: [disc.RAW]u8
	buf: [disc.DATA]u8
	if d, ok := open(iso_path, "iso"); ok {
		check_volume(&d, discimg.CNF_PS2, "iso")
		check_cnf(&d, "SLUS_123.45", true, "SLUS-12345", "NTSC", "iso")
		// A 2048-byte sector as the Mode 2 Form 1 sector holding it.
		check(disc.read_raw(&d, 16, raw[:]) && raw[12] == 0 && raw[13] == 2 && raw[14] == 0x16 && raw[15] == 2, "iso raw header")
		check(string(raw[25:30]) == "CD001", "iso raw data")
		disc.close(&d)
	}
	if d, ok := open(mode1_path, "mode 1"); ok {
		check_volume(&d, discimg.CNF_PS1, "mode 1")
		check_cnf(&d, "DATA/Sub.Txt", false, "", "", "mode 1")
		disc.close(&d)
	}
	if d, ok := open(mode2_path, "mode 2"); ok {
		check_volume(&d, discimg.CNF_PS2, "mode 2")
		check(!disc.read(&d, discimg.FORM2, buf[:]), "form 2 read")
		check(disc.read_raw(&d, discimg.FORM2, raw[:]) && raw[18] == 0x28, "form 2 raw read")
		check(disc.read(&d, discimg.FORM2 - 1, buf[:]) && string(buf[:len(discimg.SUB)]) == discimg.SUB, "form 1 read")
		disc.close(&d)
	}
	// Two FILEs: the second two seconds on, after its PREGAP, or with its gap
	// stored in it, which puts its INDEX 01 at the same LBA.
	two := []struct {
		cue:     string,
		start:   u32,
		sectors: u32,
	} {
		{"FILE \"m2.bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\nFILE \"a.bin\" BINARY\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n", discimg.VOLUME + 150, discimg.AUDIO},
		{"FILE \"m2.bin\" BINARY\r\nTRACK 01 MODE2/2352\r\nINDEX 01 00:00:00\r\nFILE \"a.bin\" BINARY\r\nTRACK 02 AUDIO\r\nPREGAP 00:01:00\r\nINDEX 01 00:00:00\r\n", discimg.VOLUME + 75, discimg.AUDIO},
		{"REM a comment\nFILE m2.bin BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\nFILE a.bin BINARY\nTRACK 02 AUDIO\nINDEX 00 00:00:00\nINDEX 01 00:02:00\n", discimg.VOLUME + 150, discimg.AUDIO - 150},
	}
	for c, i in two {
		what := fmt.tprintf("two-file cue %d", i)
		path := write_text("two.cue", c.cue)
		d, ok := open(path, what)
		if !ok {
			continue
		}
		track_is(&d, 0, 0, discimg.VOLUME, what)
		track_is(&d, 1, c.start, c.sectors, what)
		check_volume(&d, discimg.CNF_PS2, what)
		check(!disc.read(&d, c.start, buf[:]), what)
		check(disc.read_raw(&d, c.start, raw[:]) && raw[0] == audio[(discimg.AUDIO - c.sectors) * disc.RAW], what)
		disc.close(&d)
	}
	// One FILE of two tracks: data, two gap sectors (INDEX 00), then audio.
	one := make([]u8, len(mode2) + 7 * disc.RAW, context.temp_allocator)
	copy(one, mode2)
	copy(one[len(mode2):], audio[:7 * disc.RAW])
	write("one.bin", one)
	one_cue := "FILE \"one.bin\" BINARY\n TRACK 01 MODE2/2352\n  INDEX 01 00:00:00\n TRACK 02 AUDIO\n  INDEX 00 00:00:%d\n  INDEX 01 00:00:%d\n"
	path := write_text("one.cue", fmt.tprintf(one_cue, discimg.VOLUME, discimg.VOLUME + 2))
	if d, ok := open(path, "one-file cue"); ok {
		track_is(&d, 0, 0, discimg.VOLUME, "one-file cue")
		track_is(&d, 1, discimg.VOLUME + 2, 5, "one-file cue")
		check_volume(&d, discimg.CNF_PS2, "one-file cue")
		check(disc.read_raw(&d, discimg.VOLUME + 2, raw[:]) && raw[0] == audio[2 * disc.RAW], "one-file cue audio")
		check(!disc.read_raw(&d, discimg.VOLUME, raw[:]), "one-file cue gap")
		disc.close(&d)
	}
}

// A dual-layer image: a second volume descriptor at the first's end + 16.
@(private = "file")
test_dual_layer :: proc(iso: []u8) {
	img := make([]u8, (discimg.VOLUME + 20) * disc.DATA, context.temp_allocator)
	copy(img, iso)
	copy(discimg.sector(img, discimg.VOLUME + 16), discimg.sector(iso, 16))
	if d, ok := open(write("dl.iso", img), "dual layer"); ok {
		check(d.volume == discimg.VOLUME && d.layer1 == discimg.VOLUME, "dual layer")
		disc.close(&d)
	}
}

// The disc id of an image written as name; "" when id fails.
@(private = "file")
id_of :: proc(name: string, img: []u8) -> string {
	d, ok := disc.open(write(name, img))
	if !ok {
		fail("%s does not open", name)
		return ""
	}
	defer disc.close(&d)
	id, _ := disc.id(&d, context.temp_allocator)
	return id
}

// XXH3-64 of the volume descriptor, then each part after its length.
@(private = "file")
id_hash :: proc(img: []u8, parts: ..[]u8) -> string {
	input: [dynamic]u8
	defer delete(input)
	append(&input, ..discimg.sector(img, 16))
	for p in parts {
		n: [4]u8
		discimg.put32(n[:], len(p))
		append(&input, ..n[:])
		append(&input, ..p)
	}
	return fmt.tprintf("%016x", xxhash.XXH3_64_default(input[:]))
}

// Disc ids: the hash of the volume descriptor, SYSTEM.CNF and the boot
// file, whatever the image format; the serial before it when the boot name
// makes one; PSX.EXE with no SYSTEM.CNF; no id for a SYSTEM.CNF that does
// not parse or a boot file that is missing.
@(private = "file")
test_id :: proc() {
	iso := discimg.make_iso(discimg.CNF_PS1)
	want := id_hash(iso, transmute([]u8)string(discimg.CNF_PS1), transmute([]u8)string(discimg.SUB))
	check(id_of("id.iso", iso) == want, "id")
	check(id_of("id.bin", discimg.make_raw(iso, 1)) == want, "id of a raw image")
	other := discimg.make_iso(discimg.CNF_PS1)
	other[23 * disc.DATA] ~= 1
	check(id_of("id.iso", other) == want, "id with another file changed")
	other = discimg.make_iso(discimg.CNF_PS1)
	other[26 * disc.DATA] ~= 1
	check(id_of("id.iso", other) != want, "id with the boot file changed")
	cnf := "BOOT = cdrom:\\DATA\\SLUS_123.45;1\n"
	iso = discimg.make_iso(cnf, sub_name = "SLUS_123.45;1")
	want = id_hash(iso, transmute([]u8)cnf, transmute([]u8)string(discimg.SUB))
	check(id_of("id.iso", iso) == fmt.tprintf("SLUS-12345.%s", want), "id with a serial")
	exe := "an exe"
	iso = discimg.make_iso(exe, cnf_name = "PSX.EXE;1")
	check(id_of("id.iso", iso) == id_hash(iso, nil, transmute([]u8)exe), "id with no SYSTEM.CNF")
	check(id_of("id.iso", discimg.make_iso("VER = 1.00\n")) == "", "id with no BOOT line")
	check(id_of("id.iso", discimg.make_iso(discimg.CNF_PS2)) == "", "id with no boot file")
}

// Malformed images: open fails, or the file system calls do.
@(private = "file")
test_corrupt :: proc(iso: []u8) {
	_, ok := disc.open(write("short.iso", iso[:len(iso) - 100]))
	check(!ok, "partial sector image opens")
	_, ok = disc.open(write("empty.iso", nil))
	check(!ok, "empty image opens")
	missing, _ := filepath.join({dir, "missing.iso"}, context.temp_allocator)
	_, ok = disc.open(missing)
	check(!ok, "missing image opens")
	// The volume's end cut off: the root is gone.
	if d, dok := open(write("cut.iso", iso[:21 * disc.DATA]), "cut"); dok {
		_, ok = disc.read_file(&d, "SYSTEM.CNF", context.temp_allocator)
		check(!ok, "cut image reads a file")
		disc.close(&d)
	}
	// Changes to the root (sector 20) or DATA (21) at a byte offset.
	Patch :: struct {
		what:   string,
		lba:    int,
		at:     int,
		bytes:  []u8,
		path:   string,
	}
	root_end := 34 + 34 + 46 + 38 + 42 // after Big.Bin's record
	// Records of 254 bytes from there to 76 before the sector's end, then
	// one of 100.
	chain := make([]u8, disc.DATA - root_end, context.temp_allocator)
	at := 0
	for at + 254 <= disc.DATA - root_end - 76 {
		chain[at], chain[at + 32], chain[at + 33] = 254, 1, 'X'
		at += 254
	}
	chain[at] = 100
	patches := []Patch {
		{"record past its sector", 20, root_end, chain, "SYSTEM.CNF"},
		{"record under 34 bytes", 20, root_end, {5}, "SYSTEM.CNF"},
		{"bytes after a zero length", 20, disc.DATA - 1, {7}, "SYSTEM.CNF"},
		{"name past its record", 20, 68 + 32, {200}, "SYSTEM.CNF"},
		{"directory past the volume", 20, 114 + 2, {0xe8, 0x03}, "DATA/Sub.Txt"},
		{"file past the volume", 21, 68 + 2, {0x10, 0x27}, "DATA/Sub.Txt"},
		{"file size past the volume", 20, 152 + 12, {0x01}, "BIG.BIN"},
		{"no volume descriptor", 16, 1, {'X'}, "SYSTEM.CNF"},
	}
	for p in patches {
		img := make([]u8, len(iso), context.temp_allocator)
		copy(img, iso)
		copy(img[p.lba * disc.DATA + p.at:], p.bytes)
		d, dok := open(write("bad.iso", img), p.what)
		if !dok {
			continue
		}
		_, ok = disc.read_file(&d, p.path, context.temp_allocator)
		check(!ok, p.what)
		disc.close(&d)
	}
	bad_cues := []string {
		"FILE \"m2.bin\" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\nGARBAGE here\n",
		"TRACK 01 MODE2/2352\nINDEX 01 00:00:00\n",
		"FILE \"nope.bin\" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\n",
		"FILE \"m2.bin\" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 01 00:00:10\nTRACK 03 AUDIO\nINDEX 01 00:00:05\n",
		"FILE \"m2.bin\" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:60:00\n",
		"FILE \"m2.bin\" BINARY\nTRACK 01 MODE2/2352\nINDEX 01 00:00:40\n",
		"FILE \"m2.bin\" BINARY\nTRACK 01 MODE2/2352\n",
		"FILE \"m2.bin\" BINARY\nINDEX 01 00:00:00\n",
		"FILE \"m2.bin\" BINARY\nTRACK 01 MODE7/2352\nINDEX 01 00:00:00\n",
		"FILE \"m2.bin\" BINARY\nTRACK 100 MODE2/2352\nINDEX 01 00:00:00\n",
	}
	for c, i in bad_cues {
		_, ok = disc.open(write_text("bad.cue", c))
		if ok {
			fail("bad cue %d opens", i)
		}
	}
}

// The IOP's file lookups on an opened image, without the rest of the PS2.
@(private = "file")
test_iop :: proc(iso: []u8) {
	if !iop.disc_image_open(write("iop.iso", iso)) {
		fail("iop: image does not open")
		return
	}
	defer iop.disc_image_close() // before the directory is removed
	boot, ok := iop.disc_boot(context.temp_allocator)
	check(ok && boot == "SLUS_123.45", "iop boot")
	for _ in 0 ..< 2 { // the second time from the cache
		data, read := iop.disc_file("cdrom0:\\DATA\\SUB.TXT;1", context.temp_allocator)
		check(read && string(data) == discimg.SUB, "iop file")
	}
	data, read := iop.disc_file("cdrom0:\\data\\Sub.Txt", context.temp_allocator)
	check(read && string(data) == discimg.SUB, "iop file case")
	data, read = iop.disc_file("cdrom0:\\BIG.BIN;1", context.temp_allocator)
	good := read && len(data) == discimg.BIG
	for i in 0 ..< len(data) {
		good &&= data[i] == discimg.big_byte(i)
	}
	check(good, "iop big")
	for bad in ([]string{"cdrom0:\\DATA", "cdrom0:\\NOPE.BIN;1", "cdrom0:\\DATA\\..\\SYSTEM.CNF;1"}) {
		_, read = iop.disc_file(bad, context.temp_allocator)
		check(!read, bad)
	}
}

main :: proc() {
	err: os.Error
	dir, err = os.make_directory_temp("", "ps_disc_test_*", context.allocator)
	if err != nil {
		fmt.eprintln("FAIL disc: no temp directory:", err)
		os.exit(1)
	}
	iso := discimg.make_iso(discimg.CNF_PS2)
	test_formats(iso, discimg.make_raw(discimg.make_iso(discimg.CNF_PS1), 1), discimg.make_raw(iso, 2), discimg.make_audio(discimg.AUDIO))
	test_dual_layer(iso)
	test_corrupt(iso)
	test_id()
	test_iop(iso)
	if os.remove_all(dir) != nil {
		fail("cannot remove %s", dir)
	}
	if failed != 0 {
		os.exit(1)
	}
	fmt.println("ok disc")
}
