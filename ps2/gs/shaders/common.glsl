// GS local memory on the GPU: the addressing of ../mem.odin over a buffer
// holding one 4 MiB copy of local memory per subsample (scale^2 layers).
// Layer (sx, sy) is the image sampled at offset (sx, sy) / scale inside each
// GS pixel; layer 0 is the native-resolution image.
#extension GL_EXT_buffer_reference : require

// coherent: fragments of overlapping primitives may run on different compute
// units, and pixel interlock only orders them; without it a read can hit a
// stale line in the reading unit's cache.
layout(buffer_reference, std430, buffer_reference_align = 4) coherent buffer Words {
	uint w[];
};

#include "tables.glsl"

#define PSMCT32 0x00u
#define PSMCT24 0x01u
#define PSMCT16 0x02u
#define PSMCT16S 0x0au
#define PSMT8 0x13u
#define PSMT4 0x14u
#define PSMT8H 0x1bu
#define PSMT4HL 0x24u
#define PSMT4HH 0x2cu
#define PSMZ32 0x30u
#define PSMZ24 0x31u
#define PSMZ16 0x32u
#define PSMZ16S 0x3au

#define VRAM_WORDS (1u << 20)

Words VR; // local memory, all layers
uint LB;  // word offset of the current layer

bool is_z(uint psm) { return (psm & 0x30u) == 0x30u; }

uint addr32(uint psm, uint bp, uint bw, uint x, uint y) {
	uint b = block32[((y >> 3) & 3u) * 8u + ((x >> 3) & 7u)];
	if (is_z(psm)) b ^= 24u;
	uint blk = bp + ((y >> 5) * bw + (x >> 6)) * 32u + b;
	return ((blk << 6) + col32[(y & 7u) * 8u + (x & 7u)]) & (VRAM_WORDS - 1u);
}

uint addr16(uint psm, uint bp, uint bw, uint x, uint y) {
	uint i = ((y >> 3) & 7u) * 4u + ((x >> 4) & 3u);
	uint b = (psm == PSMCT16S || psm == PSMZ16S) ? block16s[i] : block16[i];
	if (is_z(psm)) b ^= 24u;
	uint blk = bp + ((y >> 6) * bw + (x >> 6)) * 32u + b;
	return ((blk << 7) + col16[(y & 7u) * 16u + (x & 15u)]) & (2u * VRAM_WORDS - 1u);
}

uint addr8(uint bp, uint bw, uint x, uint y) {
	uint blk = bp + ((y >> 6) * (bw >> 1) + (x >> 7)) * 32u + block32[((y >> 4) & 3u) * 8u + ((x >> 4) & 7u)];
	return ((blk << 8) + col8[(y & 15u) * 16u + (x & 15u)]) & (4u * VRAM_WORDS - 1u);
}

uint addr4(uint bp, uint bw, uint x, uint y) {
	uint blk = bp + ((y >> 7) * (bw >> 1) + (x >> 7)) * 32u + block16[((y >> 4) & 7u) * 4u + ((x >> 5) & 3u)];
	return ((blk << 9) + col4[(y & 15u) * 32u + (x & 31u)]) & (8u * VRAM_WORDS - 1u);
}

uint word(uint i) { return VR.w[LB + i]; }

// Where a pixel lives: bits (w >> sh) & m of word i in each layer. Layers share
// the layout, so a caller touching every layer computes this once. m is 0 for a
// format with no pixels.
struct Pixel { uint i; uint sh; uint m; };

Pixel pixel(uint psm, uint bp, uint bw, uint x, uint y) {
	switch (psm) {
	case PSMCT32: case PSMZ32: return Pixel(addr32(psm, bp, bw, x, y), 0u, 0xffffffffu);
	case PSMCT24: case PSMZ24: return Pixel(addr32(psm, bp, bw, x, y), 0u, 0xffffffu);
	case PSMCT16: case PSMCT16S: case PSMZ16: case PSMZ16S: {
		uint a = addr16(psm, bp, bw, x, y);
		return Pixel(a >> 1, (a & 1u) * 16u, 0xffffu);
	}
	case PSMT8: {
		uint a = addr8(bp, bw, x, y);
		return Pixel(a >> 2, (a & 3u) * 8u, 0xffu);
	}
	case PSMT4: {
		uint n = addr4(bp, bw, x, y);
		return Pixel(n >> 3, (n & 7u) * 4u, 15u);
	}
	case PSMT8H: return Pixel(addr32(PSMCT32, bp, bw, x, y), 24u, 0xffu);
	case PSMT4HL: return Pixel(addr32(PSMCT32, bp, bw, x, y), 24u, 15u);
	case PSMT4HH: return Pixel(addr32(PSMCT32, bp, bw, x, y), 28u, 15u);
	}
	return Pixel(0u, 0u, 0u);
}

uint load(Pixel p) { return (word(p.i) >> p.sh) & p.m; }

// Store `v` in the bits `m` of word i. Neighbouring pixels of a sub-word
// format share words, and different fragments run concurrently, so partial
// stores are atomic.
void store_bits(uint i, uint m, uint v) {
	atomicAnd(VR.w[LB + i], ~m);
	atomicOr(VR.w[LB + i], v & m);
}

void store(Pixel p, uint v) {
	if (p.m == 0xffffffffu) VR.w[LB + p.i] = v;
	else if (p.m != 0u) store_bits(p.i, p.m << p.sh, v << p.sh);
}

uint read_raw(uint psm, uint bp, uint bw, uint x, uint y) { return load(pixel(psm, bp, bw, x, y)); }

void write_raw(uint psm, uint bp, uint bw, uint x, uint y, uint v) { store(pixel(psm, bp, bw, x, y), v); }

// A 16-bit texel or CLUT entry as RGBA8888 (R in the low byte): TA0 | TA1 << 8
// supplies alpha, AEM makes black transparent.
uint texel16(uint c, uint ta, bool aem) {
	uint rgb = (c & 0x1fu) << 3 | (c & 0x3e0u) << 6 | (c & 0x7c00u) << 9;
	uint a = 0u;
	if ((c & 0x8000u) != 0u) {
		a = ta >> 8;
	} else if (!aem || (c & 0x7fffu) != 0u) {
		a = ta & 0xffu;
	}
	return rgb | a << 24;
}

// A texel of a direct-colour format, `raw` as read_raw returns it, as RGBA8888.
uint texel_direct(uint psm, uint raw, uint ta, bool aem) {
	switch (psm) {
	case PSMCT24: return raw | ((aem && raw == 0u) ? 0u : (ta & 0xffu)) << 24;
	case PSMCT16: case PSMCT16S: return texel16(raw, ta, aem);
	}
	return raw;
}
