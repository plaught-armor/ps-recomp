#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_GOOGLE_include_directive : require
// The hi-res target's queue (vk_target.odin): each primitive its box, two triangles.
#include "prim.glsl"
#define READ readonly
#include "draw_pc.glsl"
layout(location = 0) flat out int pid;

void main() {
	int id = pc.order.v[gl_VertexIndex / 6];
	int c = int[6](0, 1, 2, 2, 1, 3)[gl_VertexIndex % 6];
	ivec4 box = pc.prims.v[id].box;
	vec2 p = vec2((c & 1) != 0 ? box.z + 1 : box.x, (c & 2) != 0 ? box.w + 1 : box.y);
	gl_Position = vec4(p / pc.u.size * 2.0 - 1.0, 0.0, 1.0);
	pid = id;
}
