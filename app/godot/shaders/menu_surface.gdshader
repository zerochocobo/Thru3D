shader_type spatial;
// Keep UI layer ordering, but let nearer controllers/hands occlude the surface.
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec4 surface_color : source_color = vec4(0.07, 0.08, 0.10, 0.97);
uniform vec2 surface_size = vec2(1.0);
uniform float corner_radius = 0.02;

void fragment() {
    float radius = min(corner_radius, min(surface_size.x, surface_size.y) * 0.5);
    vec2 q = abs((UV - vec2(0.5)) * surface_size) - (surface_size * 0.5 - vec2(radius));
    float distance = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    float edge = max(fwidth(distance), 0.0003);
    ALBEDO = surface_color.rgb;
    ALPHA = surface_color.a * (1.0 - smoothstep(-edge, edge, distance));
}
