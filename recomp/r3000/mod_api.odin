// The mod API of a PS1 program: `recomp --mod-api <options.tsv> <out dir>`
// writes <out dir>/mod_api.h and <out dir>/mod.ld, what a mod's C is built
// against (mods/build.sh). It reads the options' exe, overlays and funcs and
// compiles nothing.
//
// Each funcs.tsv function gets a name, a prototype and a key: the
// .mod_hooks record fields (core.Mod_Key) that name it to the runtime. The
// name is `<space>_<entry>` (ram_80012345, ov_xxx_80123456); the row's
// `name`, when it is a usable C name, is an alias for it.
package r3000

import "core:fmt"
import "core:slice"
import "core:strings"
import "../mips"

// The mod region as the console has it (psx/cpu/mod_ram.odin; tests/mod_api
// checks they agree): mods link at MOD_BASE, and an image ends at
// MOD_IMAGE_END at most, leaving the guard word and MOD_STACK.
// MOD_ORIGINAL, below the region, is mod_call_original's address.
MOD_API :: 1
MOD_BASE :: 0x1f40_0000
MOD_REGION :: 0x40_0000
MOD_STACK :: 16 * 1024
MOD_IMAGE_END :: MOD_BASE + ((MOD_REGION - MOD_STACK - 4) &~ 15)
MOD_ORIGINAL :: MOD_BASE - 16

// Where game code may be: the executable (slot = id = 0) or an overlay
// file, loaded at slot, whose first word is its id.
Mod_Api_Space :: struct {
	name:     string,
	img:      mips.Image,
	slot, id: u32,
}

// A funcs.tsv row; name "" for none.
Mod_Api_Row :: struct {
	space: string,
	entry: u32,
	name:  string,
}

// What mod_api left out: rows whose entry is not in its image with its
// four signature words, and names not made aliases.
Mod_Api_Skips :: struct {
	outside, names: int,
}

// The spaces and rows the options name: `ram` the executable, and each
// overlays/manifest.tsv file its name without `.bin`. An overlay too
// short for its id word is an error; err is in the temp allocator.
mod_api_load :: proc(o: mips.Options) -> (spaces: []Mod_Api_Space, rows: []Mod_Api_Row, err: string) {
	exe := mips.load_psx_exe(o)
	ovls := load_overlays(o)
	s := make([]Mod_Api_Space, 1 + len(ovls))
	s[0] = {"ram", exe, 0, 0}
	for ov, k in ovls {
		id, ok := mips.word(ov.img, ov.img.base)
		if !ok {
			return nil, nil, fmt.tprintf("overlay %s: %d bytes, no id word", ov.name, len(ov.img.data))
		}
		s[1 + k] = {ov.name, ov.img, ov.img.base, id}
	}
	t := mips.load_table(mips.option(o, "funcs"), "space", "entry")
	r := make([]Mod_Api_Row, len(t.rows))
	for row, k in t.rows {
		r[k] = {mips.cell(t, row, "space"), mips.parse_hex(mips.cell(t, row, "entry")), mips.cell(t, row, "name")}
	}
	return s, r, ""
}

// Write the API of the program o names into out.
mod_api_write :: proc(o: mips.Options, out: string) {
	spaces, rows, lerr := mod_api_load(o)
	if lerr != "" {
		mips.fail("%s: %s", o.path, lerr)
	}
	header, script, skips, err := mod_api(spaces, rows)
	if err != "" {
		mips.fail("%s: %s", mips.option(o, "funcs"), err)
	}
	mips.make_dirs(out)
	mips.write_file(mips.join(out, "mod_api.h"), transmute([]u8)header)
	mips.write_file(mips.join(out, "mod.ld"), transmute([]u8)script)
	fmt.printfln("mod api: %d rows, %d not in their image, %d names not aliases", len(rows), skips.outside, skips.names)
}

// The header and linker script for rows, in (space, entry) order whatever
// the rows' order. err (temp allocated) names a row of an unknown space,
// an unaligned entry, or a space that is not a C name.
mod_api :: proc(spaces: []Mod_Api_Space, rows: []Mod_Api_Row) -> (header, script: string, skips: Mod_Api_Skips, err: string) {
	Fn :: struct {
		space: int,
		entry: u32,
		sig:   [4]u32,
	}
	for s in spaces {
		if !c_name(s.name) {return "", "", {}, fmt.tprintf("space %s is not a C name", s.name)}
	}
	sorted := slice.clone(rows, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Mod_Api_Row) -> bool {
		if a.space != b.space {return a.space < b.space}
		if a.entry != b.entry {return a.entry < b.entry}
		return a.name < b.name
	})

	fns := make([dynamic]Fn, context.temp_allocator)
	// Per sorted row: its function's index in fns, -1 none.
	of := make([]int, len(sorted), context.temp_allocator)
	for r, k in sorted {
		of[k] = -1
		sp := -1
		for s, i in spaces {
			if s.name == r.space {sp = i}
		}
		if sp < 0 {return "", "", {}, fmt.tprintf("%s %08x: unknown space %s", r.space, r.entry, r.space)}
		if r.entry & 3 != 0 {return "", "", {}, fmt.tprintf("%s %08x: entry not word aligned", r.space, r.entry)}
		if n := len(fns); n > 0 && fns[n - 1].space == sp && fns[n - 1].entry == r.entry {
			of[k] = n - 1
			continue
		}
		f := Fn{sp, r.entry, {}}
		ok := true
		for &w, i in f.sig {
			w, ok = mips.word(spaces[sp].img, r.entry + u32(i) * 4)
			if !ok {break}
		}
		if !ok {
			skips.outside += 1
			continue
		}
		of[k] = len(fns)
		append(&fns, f)
	}

	// A name is an alias when it is a C name of its own (no keyword, no
	// reserved name, not shaped like a canonical one) used by one function.
	users := make(map[string]int, context.temp_allocator)
	for r, k in sorted {
		if r.name == "" || of[k] < 0 {continue}
		if u, seen := users[r.name]; seen && u != of[k] {
			users[r.name] = -1
		} else if !seen {
			users[r.name] = of[k]
		}
	}
	aliases := make([][]string, len(fns), context.temp_allocator)
	for r, k in sorted {
		if r.name == "" || of[k] < 0 {continue}
		f := fns[of[k]]
		own := fmt.tprintf("%s_%08x", spaces[f.space].name, f.entry)
		if r.name == own {continue}
		if users[r.name] != of[k] || !c_name(r.name) || reserved(r.name) || canonical_shaped(spaces, r.name) {
			skips.names += 1
			continue
		}
		list := slice.clone_to_dynamic(aliases[of[k]], context.temp_allocator)
		if !slice.contains(list[:], r.name) {append(&list, r.name)}
		aliases[of[k]] = list[:]
	}

	h, ld: strings.Builder
	strings.builder_init(&h)
	strings.builder_init(&ld)
	fmt.sbprint(&h, HEADER_TOP)
	fmt.sbprintf(&h, "#define MOD_API %d\n#define MOD_BASE 0x%08x\n", MOD_API, MOD_BASE)
	fmt.sbprint(&h, HEADER_HOOKS)
	fmt.sbprint(&ld, SCRIPT_TOP)
	fmt.sbprintf(&ld, "mod_call_original = 0x%08x;\n", MOD_ORIGINAL)
	for f, i in fns {
		s := spaces[f.space]
		own := fmt.tprintf("%s_%08x", s.name, f.entry)
		key := fmt.tprintf("0x%08x, 0x%08x, 0x%08x, {{0x%08x, 0x%08x, 0x%08x, 0x%08x}}", s.slot, s.id, f.entry, f.sig[0], f.sig[1], f.sig[2], f.sig[3])
		fmt.sbprintf(&h, "\n")
		names := make([dynamic]string, context.temp_allocator)
		append(&names, own)
		append(&names, ..aliases[i])
		for n in names {
			fmt.sbprintf(&h, "unsigned %s() __attribute__((long_call));\n#define MOD_KEY_%s %s\n", n, n, key)
			fmt.sbprintf(&ld, "%s = 0x%08x;\n", n, f.entry)
		}
	}
	fmt.sbprint(&h, "\n#endif\n")
	fmt.sbprintf(&ld, SCRIPT_SECTIONS, MOD_BASE, MOD_BASE, MOD_IMAGE_END, MOD_IMAGE_END)
	return strings.to_string(h), strings.to_string(ld), skips, ""
}

@(private = "file")
HEADER_TOP :: `// A game's functions, for mods: generated by recomp --mod-api; do not edit.
//
// Build a mod against it with mods/build.sh. Each function is declared by
// name (<space>_<entry>, and the funcs table's name when it is a usable C
// name) with unspecified arguments: cast it to the prototype you call it
// through. MOD_BEFORE, MOD_AFTER and MOD_REPLACE hook a function by that
// name.
//
// A mod runs from the mod region at MOD_BASE, and a jal reaches only its
// own 256 MiB segment, which the game's code is not in: so every game
// function is long_call (lui, ori, jalr). ld.lld does not report a jal out
// of reach, it links a wrong target; the mod's own functions stay plain
// calls.
#ifndef MOD_API_H
#define MOD_API_H

`

@(private = "file")
HEADER_HOOKS :: `
typedef unsigned u32;

// A .mod_hooks record (core/mod_elf.odin): the kind (0 before, 1 after, 2
// replace), the hooked function's key (slot, id, addr, its first four
// words) and the mod's function.
struct mod_hook {
	u32 kind, slot, id, addr, sig[4];
	void (*fn)();
};

#define MOD_CAT_(a, b) a##b
#define MOD_CAT(a, b) MOD_CAT_(a, b)
#define MOD_HOOK_(kind, target, fn) \
	__attribute__((section(".mod_hooks"), used, aligned(4))) \
	static const struct mod_hook MOD_CAT(mod_hook_, __COUNTER__) = {kind, MOD_KEY_##target, (void (*)())(fn)}

// Run fn before, after or in place of the game function target.
#define MOD_BEFORE(target, fn) MOD_HOOK_(0, target, fn)
#define MOD_AFTER(target, fn) MOD_HOOK_(1, target, fn)
#define MOD_REPLACE(target, fn) MOD_HOOK_(2, target, fn)

// From a replacement: run the function it replaces, without its hooks, on
// the arguments now in a0-a3, and return its results. Cast it to the
// function's prototype, as a game function. It is the innermost running
// replacement's; a call from a before or after hook, or with no
// replacement running, is fatal.
unsigned mod_call_original() __attribute__((long_call));
`

@(private = "file")
SCRIPT_TOP :: `/* A mod's link: generated by recomp --mod-api; do not edit.
 *
 * The image goes at MOD_ORIGIN (mods/build.sh --origin; the mod region's
 * base by default) and must end before the region's guard word and stack.
 * .mod_hooks is not loaded: the runtime reads it from the ELF. Each game
 * function is a symbol at its address, and mod_call_original is the
 * runtime's. */

ENTRY(mod_entry_none)
mod_entry_none = 0;

`

// A format: braces doubled.
@(private = "file")
SCRIPT_SECTIONS :: `
mod_origin = DEFINED(MOD_ORIGIN) ? MOD_ORIGIN : 0x%08x;

SECTIONS {{
	. = mod_origin;
	.text : {{ *(.text .text.*) }}
	.rodata : {{ *(.rodata .rodata.*) }}
	.data : {{ *(.data .data.* .sdata .sdata.*) }}
	.got : {{ *(.got) }}
	.bss : {{ *(.bss .bss.* .sbss .sbss.* COMMON) }}
	mod_end = .;
	.mod_hooks 0 (INFO) : {{ KEEP(*(.mod_hooks)) }}
	.symtab 0 : {{ *(.symtab) }}
	.strtab 0 : {{ *(.strtab) }}
	.shstrtab 0 : {{ *(.shstrtab) }}
	/DISCARD/ : {{ *(.eh_frame*) *(.MIPS.*) *(.reginfo) *(.pdr) *(.comment) *(.gnu.attributes) *(.mdebug.*) }}
}}

/* build.sh links with --orphan-handling=error: every loaded section is one
 * of the above, so mod_end is the image's end. */
ASSERT(mod_origin >= 0x%08x && mod_origin < 0x%08x, "mod: the origin is outside the mod region")
ASSERT(mod_origin %% 16 == 0, "mod: the origin is not 16-byte aligned")
ASSERT(mod_end <= 0x%08x, "mod: the image runs past the mod region (its stack and guard)")
`

// Whether s starts as a canonical name does, with a space's name and `_`.
@(private = "file")
canonical_shaped :: proc(spaces: []Mod_Api_Space, s: string) -> bool {
	for sp in spaces {
		if len(s) > len(sp.name) && strings.has_prefix(s, sp.name) && s[len(sp.name)] == '_' {return true}
	}
	return false
}

// Whether s is a C identifier.
@(private = "file")
c_name :: proc(s: string) -> bool {
	if s == "" || (s[0] >= '0' && s[0] <= '9') {return false}
	for c in transmute([]u8)s {
		if !(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {return false}
	}
	return true
}

// A name no alias may take: a C keyword, a name the header or a mod's own
// code needs, or one C reserves (a leading underscore).
@(private = "file")
reserved :: proc(s: string) -> bool {
	@(static, rodata)
	words := [?]string {
		"auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
		"float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed",
		"sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
		"alignas", "alignof", "bool", "constexpr", "false", "nullptr", "static_assert", "thread_local", "true",
		"typeof", "typeof_unqual", "asm", "u32", "main", "memcpy", "memset", "memmove", "memcmp",
		// Macros clang predefines for the target outside C's reserved names
		// (-std=gnu17 does; build.sh's -std=c17 does not).
		"mips", "MIPSEL",
	}
	if s[0] == '_' || strings.has_prefix(s, "mod_") || strings.has_prefix(s, "MOD_") {return true}
	return slice.contains(words[:], s)
}
