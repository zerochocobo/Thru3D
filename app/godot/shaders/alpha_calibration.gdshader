shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform vec4 foreground_color : source_color = vec4(0.1, 0.85, 0.4, 1.0);
uniform float alpha_value : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	ALBEDO = foreground_color.rgb;
	ALPHA = alpha_value;
}

