#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_ARB_gpu_shader_int64 : require
#extension GL_GOOGLE_include_directive : require
// The hi-res target's queue (vk_target.odin), as gl_target.odin's DRAW_FS:
// the same hi_draw.glsl over the main picture as an input attachment read
// in place (dynamic rendering local read), walk and door as their own
// pictures, and the ghost layer and depth buffer as buffers, a pixel at
// y * w + x.
//
// With INTERLOCK (draw_lock.frag.spv, when the device has ordered pixel
// interlock), the pictures are storage images read and written inside the
// interlock, which orders overlapping primitives' pixels in queue order: a
// queue is then one level, and depths are tested and laid as the software
// target does (no pass laying them first). A discard demotes, so every
// invocation reaches the interlock's end; a helper's writes do nothing.
#ifdef INTERLOCK
#extension GL_ARB_fragment_shader_interlock : require
#extension GL_EXT_demote_to_helper_invocation : require
layout(pixel_interlock_ordered) in;
#define discard demote
#endif
#include "prim.glsl"
#define READ
#include "draw_pc.glsl"
layout(location = 0) flat in int pid;
#ifdef INTERLOCK
layout(set = 0, binding = 0, r32ui) coherent uniform uimage2D main_img;
layout(set = 0, binding = 1, r16ui) coherent uniform uimage2D walk_img;
layout(set = 0, binding = 2, r8ui) coherent uniform uimage2D door_img;
uint out_c, out_walk, out_door;
#else
layout(input_attachment_index = 0, set = 0, binding = 0) uniform usubpassInput main_in;
layout(location = 0) out uint out_c;
layout(location = 1) out uint out_walk;
layout(location = 2) out uint out_door;
#endif
// hi_draw.glsl's walk << 8 | door, split by main.
uint out_tag;

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
#ifdef INTERLOCK
	return imageLoad(main_img, p).r;
#else
	return subpassLoad(main_in).r;
#endif
}

uint z_at(ivec2 p) {
	return pc.z.v[p.y * pc.u.w + p.x];
}

void z_min(ivec2 p, uint v) {
	atomicMin(pc.z.v[p.y * pc.u.w + p.x], v);
}

// The ghost layer as hi_draw.glsl takes it: rgb | alpha << 24 and z's
// bits. A pixel's alpha shares its word with its row neighbours', so it is
// put with atomics.
uvec2 ghost_at(ivec2 p) {
	int i = p.y * pc.u.w + p.x;
	uint a = pc.ghost_a.v[i >> 2] >> ((i & 3) * 8) & 255u;
	return uvec2(pc.ghost_rgb.v[i] & 0xffffffu | a << 24, pc.ghost_z.v[i]);
}

void ghost_put(ivec2 p, uvec2 v) {
	int i = p.y * pc.u.w + p.x;
	int s = (i & 3) * 8;
	pc.ghost_rgb.v[i] = v.x & 0xffffffu;
	atomicAnd(pc.ghost_a.v[i >> 2], ~(255u << s));
	atomicOr(pc.ghost_a.v[i >> 2], (v.x >> 24) << s);
	pc.ghost_z.v[i] = v.y;
}

#define prims pc.prims.v
#define ports pc.ports.v
#include "hi_common.glsl"
#define main draw_main
#include "hi_draw.glsl"
#undef main

// queue_ghost_flush's rectangle (Gpu_Flag.Ghost_Flush, bit 31): the ghost
// layer laid over the picture and cleared, as ghost_rows and GL's pass 0.
void ghost_flush() {
	ivec2 xy = ivec2(gl_FragCoord.xy);
	uvec2 gv = ghost_at(xy);
	uint ga = gv.x >> 24;
	if (pc.zpass != 0 || ga == 0u) {
		discard;
	}
	uint m = main_at(xy);
	ghost_put(xy, uvec2(gv.x & 0xffffffu, gv.y));
	out_c = fade_mix(m, gv.x & 0xffffffu, float(ga) / 255.0) & 0xffffffu | m & HI_KEPT;
}

#ifdef INTERLOCK
void draw_lock();

void main() {
	beginInvocationInterlockARB();
	draw_lock();
	endInvocationInterlockARB();
}

// main's body, inside the interlock: the pictures written as the
// attachments would be (walk and door only with pc.tags).
void draw_lock() {
	ivec2 xy = ivec2(gl_FragCoord.xy);
	if (prims[pid].h.x < 0) {
		ghost_flush();
		imageStore(main_img, xy, uvec4(out_c));
		return;
	}
#else
void main() {
	if (prims[pid].h.x < 0) {
		ghost_flush();
		out_walk = 0u;
		out_door = 0u;
		return;
	}
#endif
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
	out_walk = out_tag >> 8 & 0xffffu;
	out_door = out_tag & 255u;
#ifdef INTERLOCK
	imageStore(main_img, xy, uvec4(out_c));
	if (pc.tags != 0) {
		imageStore(walk_img, xy, uvec4(out_walk));
		imageStore(door_img, xy, uvec4(out_door));
	}
#endif
}
