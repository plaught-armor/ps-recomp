// Disc images: an .iso of 2048-byte sectors, a raw .bin of 2352-byte ones
// (Mode 1, Mode 2 Form 1 and 2, audio) or a .cue sheet over one or more
// .bin files, read by LBA. Apart from core so the recompiler (and anything
// without a window) can read discs: it imports only the core library.
package disc

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// A raw sector: sync, header, subheader and data, or audio.
RAW :: 2352
// A sector's user data in Mode 1 and Mode 2 Form 1.
DATA :: 2048
// The two seconds before LBA 0 (MSF 00:02:00).
PREGAP :: 150
// The most sectors an image may hold, keeping every LBA sum in u32.
MAX_SECTORS :: 1 << 30

// A run of the disc's sectors kept in a host file: LBAs start ..
// start + sectors - 1, the first at byte `at` of the file, each RAW bytes
// (raw) or DATA.
Track :: struct {
	number:  int,
	file:    ^os.File,
	start:   u32,
	sectors: u32,
	at:      i64,
	raw:     bool,
	audio:   bool,
}

Disc :: struct {
	tracks:  [dynamic]Track,
	// The host files, each closed once.
	files:   [dynamic]^os.File,
	// The ISO9660 volume's size in sectors (0: no volume found), and where
	// a dual-layer DVD's second layer starts (0: one layer). Reads past the
	// first layer are not mapped yet.
	volume:  u32,
	layer1:  u32,
	// The volume's root directory.
	root:    Entry,
}

// Open a disc image by its extension: .cue, or a single-track .iso, .bin or
// .img, whose sector size its length and first sector tell. False, with the
// reason printed, when it cannot be read.
open :: proc(path: string, allocator := context.allocator) -> (d: Disc, ok: bool) {
	d.tracks = make([dynamic]Track, allocator)
	d.files = make([dynamic]^os.File, allocator)
	if strings.equal_fold(filepath.ext(path), ".cue") {
		ok = open_cue(&d, path)
	} else {
		ok = open_single(&d, path)
	}
	if !ok {
		close(&d)
		return {}, false
	}
	volume_probe(&d)
	return d, true
}

close :: proc(d: ^Disc) {
	for f in d.files {
		os.close(f)
	}
	delete(d.tracks)
	delete(d.files)
	d^ = {}
}

@(private = "file")
open_single :: proc(d: ^Disc, path: string) -> bool {
	f, err := os.open(path)
	if err != nil {
		fmt.eprintln("disc: cannot open", path)
		return false
	}
	append(&d.files, f)
	size, _ := os.file_size(f)
	raw := size % RAW == 0 && has_sync(f, 0)
	if !raw && size % DATA != 0 {
		fmt.eprintln("disc: not whole sectors:", path)
		return false
	}
	if size / (raw ? RAW : DATA) > MAX_SECTORS {
		fmt.eprintln("disc: too large:", path)
		return false
	}
	n := u32(size / (raw ? RAW : DATA))
	append(&d.tracks, Track{number = 1, file = f, sectors = n, raw = raw})
	return n > 0
}

// Whether the sector at byte at of f starts with a data sector's sync.
@(private = "file")
has_sync :: proc(f: ^os.File, at: i64) -> bool {
	sync: [12]u8
	n, err := os.read_at(f, sync[:], at)
	return err == nil && n == 12 && sync == {0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0}
}

// A cue sheet's track before layout: its file, kind and where its indexes
// fall in the file, in sectors.
@(private = "file")
Cue_Track :: struct {
	number:  int,
	file:    int,
	size:    i64, // bytes a sector
	audio:   bool,
	index0:  int, // -1 none
	index1:  int,
	pregap:  int, // -1 none
}

// Lay out a cue sheet's tracks. In one FILE, a track's sectors run from its
// INDEX 01 to the next track's first index. A later FILE starts after the
// earlier ones plus its first track's PREGAP, or plus two seconds when its
// gap is not in the file either (no INDEX 00, INDEX 01 at its start), as a
// disc's tracks are spaced.
@(private = "file")
open_cue :: proc(d: ^Disc, cue_path: string) -> bool {
	text, err := os.read_entire_file(cue_path, context.temp_allocator)
	if err != nil {
		fmt.eprintln("disc: cannot read", cue_path)
		return false
	}
	dir := filepath.dir(cue_path)
	cue := make([dynamic]Cue_Track, context.temp_allocator)
	s := string(text)
	for line in strings.split_lines_iterator(&s) {
		l := strings.trim_space(line)
		word, _, rest := strings.partition(l, " ")
		word = strings.to_upper(word, context.temp_allocator)
		rest = strings.trim_space(rest)
		switch word {
		case "", "REM", "CATALOG", "CDTEXTFILE", "TITLE", "PERFORMER", "SONGWRITER", "ISRC", "FLAGS", "POSTGAP":
		case "FILE":
			q1 := strings.index_byte(rest, '"')
			q2 := strings.last_index_byte(rest, '"')
			name := q1 >= 0 && q2 > q1 ? rest[q1 + 1:q2] : rest[:max(strings.last_index_byte(rest, ' '), 0)]
			path, _ := filepath.join({dir, name}, context.temp_allocator)
			f, ferr := os.open(path)
			if ferr != nil {
				fmt.eprintln("disc: cannot open", path)
				return false
			}
			append(&d.files, f)
		case "TRACK":
			if len(d.files) == 0 {
				fmt.eprintln("disc: TRACK before FILE in", cue_path)
				return false
			}
			num, _, kind := strings.partition(rest, " ")
			kind = strings.to_upper(strings.trim_space(kind), context.temp_allocator)
			t := Cue_Track{file = len(d.files) - 1, index0 = -1, index1 = -1, pregap = -1}
			n, num_ok := strconv.parse_int(num)
			if !num_ok || n < 1 || n > 99 {
				fmt.eprintln("disc: bad track number in", l)
				return false
			}
			t.number = n
			switch kind {
			case "AUDIO", "MODE1/2352", "MODE2/2352", "CDI/2352": t.size = RAW
			case "MODE1/2048", "MODE2/2048": t.size = DATA
			case "MODE2/2336", "CDI/2336": t.size = 2336
			case:
				fmt.eprintln("disc: unknown track kind", kind)
				return false
			}
			t.audio = kind == "AUDIO"
			append(&cue, t)
		case "INDEX", "PREGAP":
			if len(cue) == 0 {
				fmt.eprintln("disc:", word, "before TRACK in", cue_path)
				return false
			}
			t := &cue[len(cue) - 1]
			num, _, at := strings.partition(rest, " ")
			if word == "PREGAP" {
				at = num
			}
			frames, ok := msf_parse(strings.trim_space(at))
			if !ok {
				fmt.eprintln("disc: bad time in", l)
				return false
			}
			switch {
			case word == "PREGAP": t.pregap = frames
			case num == "00" || num == "0": t.index0 = frames
			case num == "01" || num == "1": t.index1 = frames
			}
		case:
			fmt.eprintln("disc: unknown cue line:", l)
			return false
		}
	}
	lba: u32
	for t, i in cue {
		if t.index1 < 0 {
			fmt.eprintln("disc: track", t.number, "has no INDEX 01")
			return false
		}
		f := d.files[t.file]
		size, _ := os.file_size(f)
		file_sectors := int(size / t.size)
		first := i == 0 || cue[i - 1].file != t.file
		if first {
			base := lba
			if i > 0 {
				stored := t.index0 >= 0 || t.index1 > 0
				base += u32(t.pregap >= 0 ? t.pregap : stored ? 0 : int(PREGAP))
			}
			lba = base // LBA of the file's first sector
		}
		end := file_sectors
		if i + 1 < len(cue) && cue[i + 1].file == t.file {
			n := cue[i + 1]
			end = n.index0 >= 0 ? n.index0 : n.index1
			if n.size != t.size {
				fmt.eprintln("disc: tracks", t.number, "and", n.number, "share a file with different sector sizes")
				return false
			}
		}
		if t.index1 >= end || t.index0 > t.index1 || end > file_sectors || lba > MAX_SECTORS - u32(file_sectors) {
			fmt.eprintln("disc: track", t.number, "overlaps another or lies past its file")
			return false
		}
		if t.size != RAW && t.size != DATA {
			fmt.eprintln("disc: track", t.number, "has", t.size, "byte sectors, not read")
		} else {
			append(&d.tracks, Track{
				number = t.number,
				file = f,
				start = lba + u32(t.index1),
				sectors = u32(end - t.index1),
				at = i64(t.index1) * t.size,
				raw = t.size == RAW,
				audio = t.audio,
			})
		}
		if i + 1 == len(cue) || cue[i + 1].file != t.file {
			lba += u32(file_sectors)
		}
	}
	return len(d.tracks) > 0
}

// mm:ss:ff in frames (75 a second).
@(private = "file")
msf_parse :: proc(s: string) -> (frames: int, ok: bool) {
	parts := strings.split(s, ":", context.temp_allocator)
	if len(parts) != 3 {
		return 0, false
	}
	v: [3]int
	for p, i in parts {
		if len(p) == 0 || len(p) > 3 {
			return 0, false
		}
		for c in p {
			if c < '0' || c > '9' {
				return 0, false
			}
		}
		v[i], _ = strconv.parse_int(p)
	}
	if v[1] >= 60 || v[2] >= 75 {
		return 0, false
	}
	return (v[0] * 60 + v[1]) * 75 + v[2], true
}

// The track holding lba, or nil.
track_of :: proc(d: ^Disc, lba: u32) -> ^Track {
	for &t in d.tracks {
		if lba >= t.start && lba - t.start < t.sectors {
			return &t
		}
	}
	return nil
}

// MSF of lba, in BCD as a sector header holds it. Minutes past 99, on a
// DVD-sized image, do not fit; only CD images need raw sectors.
msf :: proc(lba: u32) -> (m, s, f: u8) {
	bcd :: proc(v: u32) -> u8 {return u8((v / 10) << 4 | (v % 10))}
	a := lba + PREGAP
	return bcd(a / (75 * 60)), bcd(a / 75 % 60), bcd(a % 75)
}

// Read the raw sector at lba into buf (RAW bytes). A 2048-byte sector comes
// back as the Mode 2 Form 1 sector holding it.
read_raw :: proc(d: ^Disc, lba: u32, buf: []u8) -> bool {
	assert(len(buf) >= RAW, "disc: raw read under a sector")
	t := track_of(d, lba)
	if t == nil {
		return false
	}
	if t.raw {
		n, err := os.read_at(t.file, buf[:RAW], t.at + i64(lba - t.start) * RAW)
		return err == nil && n == RAW
	}
	for &b in buf[1:11] {
		b = 0xff
	}
	buf[0], buf[11] = 0, 0
	buf[12], buf[13], buf[14] = msf(lba)
	buf[15] = 2
	copy(buf[16:24], []u8{0, 0, 0x08, 0, 0, 0, 0x08, 0})
	n, err := os.read_at(t.file, buf[24:24 + DATA], t.at + i64(lba - t.start) * DATA)
	for &b in buf[24 + DATA:RAW] {
		b = 0
	}
	return err == nil && n == DATA
}

// Read the user data of whole sectors from lba on into buf, a multiple of
// DATA long: a Mode 2 Form 1 sector's from byte 24, a Mode 1 one's from
// byte 16. False past the image, or on an audio, Mode 0 or Mode 2 Form 2
// sector, which hold no 2048 bytes of data.
read :: proc(d: ^Disc, lba: u32, buf: []u8) -> bool {
	assert(len(buf) % DATA == 0, "disc: read not in whole sectors")
	raw: [RAW]u8
	for i := 0; i < len(buf) / DATA; {
		at := lba + u32(i)
		t := track_of(d, at)
		if t == nil || t.audio {
			return false
		}
		if !t.raw { // as many sectors as the track holds in one read
			k := min(len(buf) / DATA - i, int(t.start + t.sectors - at))
			n, err := os.read_at(t.file, buf[i * DATA:(i + k) * DATA], t.at + i64(at - t.start) * DATA)
			if err != nil || n != k * DATA {
				return false
			}
			i += k
			continue
		}
		if !read_raw(d, at, raw[:]) {
			return false
		}
		from: int
		switch {
		case raw[15] == 1: from = 16
		case raw[15] == 2 && raw[18] & 0x20 == 0: from = 24
		case: return false
		}
		copy(buf[i * DATA:(i + 1) * DATA], raw[from:from + DATA])
		i += 1
	}
	return true
}

// Read len(buf) bytes of user data starting `offset` bytes into the sectors
// from lba on; the count read, short past the image.
read_at :: proc(d: ^Disc, lba: u32, offset: i64, buf: []u8) -> int {
	sector: [DATA]u8
	done := 0
	for done < len(buf) {
		pos := offset + i64(done)
		if pos < 0 || i64(lba) + pos / DATA >= MAX_SECTORS {
			break
		}
		at := lba + u32(pos / DATA)
		in_sector := int(pos % DATA)
		if in_sector == 0 && len(buf) - done >= DATA {
			k := (len(buf) - done) / DATA
			if read(d, at, buf[done:done + k * DATA]) {
				done += k * DATA
				continue
			}
		}
		if !read(d, at, sector[:]) {
			break
		}
		done += copy(buf[done:], sector[in_sector:])
	}
	return done
}
