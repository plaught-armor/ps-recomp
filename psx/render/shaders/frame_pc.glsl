// The push constants of frame.comp and bloom.comp (vk_target.odin's
// Vk_Frame_Push): the target's picture (rgb, a row of t.w pixels each, as
// the software target keeps it), a blur stage's source and destination,
// the glow and the depth of field's blur, the converted pixels, the
// conversion's lit flag and the uniforms; all but rgb and the uniforms are
// rows of their area's width.
layout(buffer_reference, std430, buffer_reference_align = 4) buffer Buf { uint v[]; };
// vk_frame's uniforms: the area (target pixels, wrapping), the target's
// size and shift, the effects (post_pixel) and the grade's columns 0..2,
// then its offset.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Uni {
	ivec4 area;
	ivec4 size_k;
	ivec4 fx;
	ivec4 dof;
	ivec4 vig;
	ivec4 grade[4];
};
layout(push_constant) uniform Push {
	Buf rgb;
	Buf src;
	Buf dst;
	Buf glow;
	Buf blur;
	Buf px;
	Buf bright;
	Uni u;
	// bloom.comp's stage, and whether it averages every pixel.
	int stage;
	int every;
} pc;

ivec3 lanes(uint c) {
	return ivec3(c >> 16 & 255u, c >> 8 & 255u, c & 255u);
}

uint pack(ivec3 v) {
	return uint(v.x) << 16 | uint(v.y) << 8 | uint(v.z);
}

// The target's pixel at p (wrapping).
uint rgb_at(ivec2 p) {
	ivec2 s = pc.u.size_k.xy;
	p &= s - 1;
	return pc.rgb.v[p.y * s.x + p.x];
}
