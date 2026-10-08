uniform sampler2D subtitle_texture : source_color, filter_linear, repeat_disable;
uniform bool subtitle_enabled = false;
uniform mat3 subtitle_anchor_inverse = mat3(1.0);
uniform float subtitle_parallax = 0.0;
uniform float subtitle_patch_half_extent = 0.35;

vec4 projected_caption(vec3 direction, int physical_eye) {
	if (!subtitle_enabled) { return vec4(0.0); }
	vec3 d = normalize(direction);
	// tool_subembed offsets the already-projected right patch in longitude.
	// Apply the inverse offset while sampling, including fisheye and 360 source projections.
	float longitude = atan(d.x, -d.z) + (physical_eye == 1 ? subtitle_parallax : 0.0);
	float radial = sqrt(max(0.0, 1.0 - d.y * d.y));
	d = vec3(radial * sin(longitude), d.y, -radial * cos(longitude));
	vec3 patch = subtitle_anchor_inverse * d;
	if (patch.z >= -0.0001) { return vec4(0.0); }
	vec2 p = vec2(0.5) + vec2(patch.x, -patch.y) / (-patch.z * 2.0 * subtitle_patch_half_extent);
	if (any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)))) { return vec4(0.0); }
	return texture(subtitle_texture, p);
}

vec4 caption_composite(vec3 video_rgb, float video_alpha, vec4 caption) {
	// A transparent canvas viewport contains premultiplied RGB; convert back for blend_mix.
	float a = caption.a + video_alpha * (1.0 - caption.a);
	vec3 rgb = caption.rgb + video_rgb * video_alpha * (1.0 - caption.a);
	return vec4(a > 0.0001 ? rgb / a : vec3(0.0), a);
}
