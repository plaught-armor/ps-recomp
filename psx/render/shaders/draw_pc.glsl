// The push constants of draw.vert and draw.frag (vk_target.odin's
// Vk_Draw_Push): the queue, VRAM, the target's ghost layer and depth
// buffer, a row of the target's pixels each, and the uniforms. READ is
// readonly in the vertex shader, which only reads.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Prims { Prim v[]; };
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Ports { Port v[]; };
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer Order { int v[]; };
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer Vram { uint v[]; };
layout(buffer_reference, std430, buffer_reference_align = 8) READ coherent buffer Ghost { uvec2 v[]; };
layout(buffer_reference, std430, buffer_reference_align = 4) READ coherent buffer Zbuf { uint v[]; };
// gl_submit's uniforms; w is the target's width.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Uni {
	vec4 see[6];
	vec4 fog0;
	uint fog_c;
	int k;
	vec2 size;
	int w;
};
layout(push_constant) uniform Push {
	Prims prims;
	Ports ports;
	Order order;
	Vram vram;
	Ghost ghost;
	Zbuf z;
	Uni u;
	// 1 while a level lays down its depths (vk_target_submit).
	int zpass;
} pc;
