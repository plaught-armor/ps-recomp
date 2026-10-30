// Shared by the Vulkan target's shaders (vk_target.odin): the hi-res pixel
// format.
const uint HI_MASK = 0x80000000u, HI_GLOW = 0x01000000u, HI_DEPTH = 0x7e000000u;
// The bits a pixel laid over another takes from it (pixel_kept).
const uint HI_KEPT = HI_MASK | HI_DEPTH;

// View depth z (0 unknown) as HI_DEPTH bits (depth_bits).
uint depth_bits(float z) {
	if (z <= 0.0) {
		return 0u;
	}
	return uint(clamp(int(min(z, 65536.0)) >> 6, 1, 63)) << 25;
}

// VRAM pixel c as a target pixel (hi_pixel).
uint hi(uint c) {
	return (c & 31u) << 19 | (c >> 5 & 31u) << 11 | (c >> 10 & 31u) << 3 | (c & 0x8000u) << 16;
}

uint fade_mix(uint back, uint front, float a) {
	uint o = front & HI_MASK;
	for (int s = 0; s < 24; s += 8) {
		precise float b = float((back >> s) & 255u);
		precise float f = float((front >> s) & 255u);
		precise float v = b + (f - b) * a + 0.5;
		o |= uint(v) << s;
	}
	return o;
}
