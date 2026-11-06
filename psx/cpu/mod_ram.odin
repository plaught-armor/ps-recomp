// The mod region: the mods' code, data and stack, at MOD_BASE in the
// otherwise unused expansion 1 range. load_slow and store_slow reach it, so
// only mod code pays for it, and with no mods loaded (mod_ram nil) the bus
// is as before. The interpreter fetches mod code from it the same way.
//
// Layout: the mods' images where they are linked, then a guard word, then
// MOD_STACK bytes of stack; mod_sp is the region's top. mod_call checks the
// guard after every hook, so a hook that overflowed the stack is fatal.
package psx_cpu

import "core:fmt"
import "ps:core"

MOD_BASE :: 0x1f40_0000
// The region's largest size: up to the scratchpad at 0x1f800000.
MOD_REGION :: 0x40_0000
MOD_STACK :: 16 * 1024

@(private = "file")
MOD_GUARD :: 0x4d4f_4447

// The region, from MOD_BASE; nil with no mods.
mod_ram: []u8

// Offset of the guard word in mod_ram.
@(private = "file")
mod_guard: u32

// Make the region for images (their addresses physical, inside it) and set
// mod_sp to its top. An error names the two mods whose images overlap; err
// is in the temp allocator.
mod_ram_load :: proc(images: []core.Mod_Image, who: []string) -> (err: string) {
	assert(len(images) == len(who))
	if mod_ram != nil {return "mod: region loaded twice"}
	if len(images) == 0 {return ""}
	end := u32(MOD_BASE)
	for a, i in images {
		if a.lo < MOD_BASE || a.hi > MOD_BASE + MOD_REGION {
			return fmt.tprintf("mod %s: image %08x-%08x is outside the mod region", who[i], a.lo, a.hi)
		}
		for b, j in images[:i] {
			if a.lo < b.hi && b.lo < a.hi {
				return fmt.tprintf("mod %s and mod %s: images %08x-%08x and %08x-%08x overlap", who[j], who[i], b.lo, b.hi, a.lo, a.hi)
			}
		}
		end = max(end, a.hi)
	}
	guard := (end - MOD_BASE + 15) &~ 15
	size := (guard + 4 + MOD_STACK + 0xfff) &~ 0xfff
	if size > MOD_REGION {
		return fmt.tprintf("mod: images and stack need %d bytes, the region has %d", size, MOD_REGION)
	}
	mod_ram = make([]u8, size)
	for img in images {
		for s in img.segments {copy(mod_ram[s.addr - MOD_BASE:][:s.size], s.bytes)}
	}
	mod_guard = guard
	(^u32le)(&mod_ram[guard])^ = MOD_GUARD
	mod_sp = MOD_BASE + size
	return ""
}

// Whether addr is in the mod region; never with no mods.
mod_ram_has :: #force_inline proc(addr: u32) -> bool {
	return (addr & 0x1fff_ffff) - MOD_BASE < u32(len(mod_ram))
}

// Fatal when the hook at fn overflowed the mod stack (wrote its guard).
@(private)
mod_ram_check :: #force_inline proc(fn: u32) {
	if mod_ram != nil && (^u32le)(&mod_ram[mod_guard])^ != MOD_GUARD {
		fatal("mod: the hook at %08x overflowed the %d-byte mod stack", fn, MOD_STACK)
	}
}

// Free the region (tests).
mod_ram_free :: proc() {
	delete(mod_ram)
	mod_ram, mod_guard, mod_sp = nil, 0, 0
}
