// The push constants of draw.vert and draw.frag (vk_target.odin's
// Vk_Draw_Push): the queue, VRAM, the target's ghost layer (rgb, alpha and
// z's bits) and depth buffer, a row of the target's pixels each as the
// software target keeps them, and the uniforms. READ is readonly in the
// vertex shader, which only reads.
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Prims { Prim v[]; };
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer Ports { Port v[]; };
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer Order { int v[]; };
layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer Vram { uint v[]; };
// A plane of the target; the ghost layer's alpha has four pixels a word.
layout(buffer_reference, std430, buffer_reference_align = 4) READ coherent buffer Plane { uint v[]; };
// vk_target_submit's uniforms; w is the target's width.
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
	Plane ghost_rgb;
	Plane ghost_a;
	Plane ghost_z;
	Plane z;
	Uni u;
	// 1 while a level lays down its depths (vk_target_submit).
	int zpass;
#ifdef INTERLOCK
	// 1 when the level writes walk and door (its depth_on).
	int tags;
#endif
} pc;
