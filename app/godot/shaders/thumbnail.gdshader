shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

// Library picture of a played video: a crop of the left eye of the displayed frame.
uniform sampler2D color_texture : filter_linear, repeat_disable;
uniform vec2 color_uv_scale = vec2(1.0);
uniform bool stereo_sbs = false;
uniform bool top_bottom = false; // stereo views above each other: the top one is the left eye
uniform vec4 crop = vec4(0.0, 0.0, 1.0, 1.0); // eye UV, row 0 on top

void fragment() {
	vec2 p = crop.xy + UV * crop.zw;
	if (stereo_sbs && top_bottom) { p.y *= 0.5; }
	else if (stereo_sbs) { p.x *= 0.5; }
	ALBEDO = texture(color_texture, p * color_uv_scale).rgb;
}
