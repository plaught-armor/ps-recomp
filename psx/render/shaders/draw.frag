#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_ARB_gpu_shader_int64 : require
#extension GL_GOOGLE_include_directive : require
// The hi-res target's queue (vk_target.odin), as gl_target.odin's DRAW_FS:
// the same hi_draw.glsl over the main picture as an input attachment read
// in place (dynamic rendering local read) and the ghost layer and depth
// buffer as buffers, a pixel at y * w + x.
#include "prim.glsl"
#define READ
#include "draw_pc.glsl"
layout(input_attachment_index = 0, set = 0, binding = 0) uniform usubpassInput main_in;
layout(location = 0) flat in int pid;
layout(location = 0) out uint out_c;
layout(location = 1) out uint out_tag;

// gl_submit's uniforms, as hi_draw.glsl names them (main sets them).
vec4 see0, see1, see2, see3, see4, see5, fog0;
uint fog_c;
int k, zpass;

uint vfetch(int x, int y) {
	int i = (y & 511) * 1024 + (x & 1023);
	return pc.vram.v[i >> 1] >> ((i & 1) * 16) & 0xffffu;
}

// The target's pictures as hi_draw.glsl reads them: only ever at the
// fragment's own pixel, which subpassLoad takes as given.
uint main_at(ivec2 p) {
	return subpassLoad(main_in).r;
}

uint z_at(ivec2 p) {
	return pc.z.v[p.y * pc.u.w + p.x];
}

void z_min(ivec2 p, uint v) {
	atomicMin(pc.z.v[p.y * pc.u.w + p.x], v);
}

uvec2 ghost_at(ivec2 p) {
	return pc.ghost.v[p.y * pc.u.w + p.x];
}

void ghost_put(ivec2 p, uvec2 v) {
	pc.ghost.v[p.y * pc.u.w + p.x] = v;
}

#define prims pc.prims.v
#define ports pc.ports.v
#include "hi_common.glsl"
#define main draw_main
#include "hi_draw.glsl"
#undef main

void main() {
	see0 = pc.u.see[0];
	see1 = pc.u.see[1];
	see2 = pc.u.see[2];
	see3 = pc.u.see[3];
	see4 = pc.u.see[4];
	see5 = pc.u.see[5];
	fog0 = pc.u.fog0;
	fog_c = pc.u.fog_c;
	k = pc.u.k;
	zpass = pc.zpass;
	draw_main();
}
