// A queued primitive and portal (prim_queue.odin's Gpu_Prim, Gpu_Portal).
struct Prim { ivec4 box, h, t, m, a, b, c, w; vec4 z, e; };
struct Port { vec4 corner[4]; vec4 info; };
