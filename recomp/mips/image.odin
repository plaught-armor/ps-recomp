package mips

import "core:fmt"
import "core:strings"
import "ps:core/disc"

Section :: struct {
	name:  string,
	addr:  u32,
	size:  u32,
	data:  []u8, // nil for NOBITS
	flags: u32,
}

SHF_ALLOC :: 2
SHF_EXEC :: 4
SHT_NOBITS :: 8

// Code and data as loaded: data[0] sits at base.
Image :: struct {
	base:     u32,
	data:     []u8,
	entry:    u32,
	// The executable's name in messages: its path, or on a disc image
	// `image:path`; "" for an overlay.
	name:     string,
	// ELF sections; none for a PS-X EXE or an overlay, which do not tell
	// code from data.
	sections: []Section,
}

word :: proc(img: Image, addr: u32) -> (u32, bool) {
	o := i64(addr) - i64(img.base)
	if o < 0 || o + 4 > i64(len(img.data)) || addr & 3 != 0 {
		return 0, false
	}
	return u32le(img.data, int(o)), true
}

// The options for a disc image alone: the backend SYSTEM.CNF's executable
// needs, machine code for this host into <serial>.<arch>.bin (the executable's
// name when it has no serial) and, given source, Odin source there; the
// backends default the rest.
disc_options :: proc(image, source: string) -> Options {
	d, ok := disc.open(image)
	if !ok {
		fail("%s: not a disc image", image)
	}
	defer disc.close(&d)
	cnf, found := disc.system_cnf(&d)
	if !found {
		fail("%s: no SYSTEM.CNF naming the executable", image)
	}
	o := Options {
		path = image,
	}
	o.values["backend"] = cnf.ps2 ? "r5900" : "r3000"
	o.values["disc"] = image
	o.values["quiet"] = "true"
	o.values["native_arch"] = HOST_ARCH
	name := cnf.serial
	if name == "" {
		name = cnf.boot[strings.last_index_byte(cnf.boot, '/') + 1:]
	}
	o.values["native_out"] = fmt.aprintf("%s.%s.bin", name, HOST_ARCH)
	if source != "" {
		o.values["out"] = source
	}
	return o
}

// The native_arch of the machine recomp runs on.
HOST_ARCH :: "arm64" when ODIN_ARCH == .arm64 else "x64_win" when ODIN_OS == .Windows else "x64_sysv"

// The executable's bytes and its name: option `exe`, a file; or, with
// option `disc` (a .cue sheet, or a single-track .bin or .iso), the file at
// disc path `exe` on that image, by default the one SYSTEM.CNF names.
@(private = "file")
read_exe :: proc(o: Options) -> (raw: []u8, name: string) {
	image := option_or(o, "disc", "")
	if image == "" {
		name = option(o, "exe")
		return read_file(name), name
	}
	d, ok := disc.open(image)
	if !ok {
		fail("%s: not a disc image", image)
	}
	defer disc.close(&d)
	path := option_or(o, "exe", "")
	if path == "" {
		cnf, found := disc.system_cnf(&d)
		if !found {
			fail("%s: no SYSTEM.CNF naming the executable", image)
		}
		path = cnf.boot
	}
	name = fmt.aprintf("%s:%s", image, path)
	raw, ok = disc.read_file(&d, path)
	if !ok {
		fail("%s: not found", name)
	}
	return raw, name
}

// A PS-X EXE: the text segment, loaded at its address.
load_psx_exe :: proc(o: Options) -> Image {
	raw, name := read_exe(o)
	if len(raw) < 0x800 || string(raw[:8]) != "PS-X EXE" {
		fail("%s: not a PS-X EXE", name)
	}
	text, size := u32le(raw, 0x18), int(u32le(raw, 0x1c))
	return {base = text, data = raw[0x800:min(0x800 + size, len(raw))], entry = u32le(raw, 0x10), name = name}
}

// A 32-bit little-endian MIPS ELF: every allocated section in one flat view,
// NOBITS reading as zero. Sections at 0x01000000 and up (the EE's .vudata,
// in VU memory) stay out of it.
load_elf :: proc(o: Options) -> Image {
	raw, name := read_exe(o)
	if len(raw) < 52 || string(raw[:4]) != "\x7fELF" {
		fail("%s: not an ELF file", name)
	}
	u16le :: proc(b: []u8, o: int) -> u32 {return u32(b[o]) | u32(b[o + 1]) << 8}
	img: Image
	img.entry = u32le(raw, 24)
	img.name = name
	shoff := int(u32le(raw, 32))
	shentsize := int(u16le(raw, 46))
	shnum := int(u16le(raw, 48))
	shstrndx := int(u16le(raw, 50))
	str_off := int(u32le(raw, shoff + shstrndx * shentsize + 16))
	sections: [dynamic]Section
	lo, hi := u32(0xffffffff), u32(0)
	for i in 0 ..< shnum {
		h := shoff + i * shentsize
		name_off := int(u32le(raw, h))
		typ := u32le(raw, h + 4)
		flags := u32le(raw, h + 8)
		addr := u32le(raw, h + 12)
		off := int(u32le(raw, h + 16))
		size := u32le(raw, h + 20)
		if flags & SHF_ALLOC == 0 || size == 0 {
			continue
		}
		s := Section {
			name  = strings.clone_from_cstring(cstring(&raw[str_off + name_off])),
			addr  = addr,
			size  = size,
			flags = flags,
		}
		if typ != SHT_NOBITS {
			s.data = raw[off:off + int(size)]
		}
		append(&sections, s)
		if addr < 0x01000000 {
			lo = min(lo, addr)
			hi = max(hi, addr + size)
		}
	}
	img.base = lo
	img.data = make([]u8, hi - lo)
	for s in sections {
		if s.data != nil && s.addr < 0x01000000 {
			copy(img.data[s.addr - lo:], s.data)
		}
	}
	img.sections = sections[:]
	return img
}

find_section :: proc(img: Image, name: string) -> ^Section {
	for &s in img.sections {
		if s.name == name {
			return &s
		}
	}
	return nil
}
