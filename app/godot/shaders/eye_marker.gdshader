shader_type spatial;
render_mode unshaded, cull_disabled;

varying flat float eye;

void vertex() {
	eye = float(VIEW_INDEX);
}

void fragment() {
	// Different patterns and colors expose swapped eyes in a real multiview run.
	float stripe = step(0.5, fract(UV.x * (eye < 0.5 ? 4.0 : 8.0)));
	vec3 eye_color = eye < 0.5 ? vec3(1.0, 0.12, 0.12) : vec3(0.1, 0.4, 1.0);
	ALBEDO = mix(eye_color * 0.25, eye_color, stripe);
}

