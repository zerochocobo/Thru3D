uniform sampler2D bitmap_subtitle_texture : filter_linear, repeat_disable;
uniform bool bitmap_subtitle_enabled = false;
uniform vec4 bitmap_subtitle_rect = vec4(0.0, 0.0, 1.0, 1.0);

vec4 bitmap_caption(vec2 source_uv) {
	if (!bitmap_subtitle_enabled) { return vec4(0.0); }
	vec2 p = (source_uv - bitmap_subtitle_rect.xy) / bitmap_subtitle_rect.zw;
	if (any(lessThan(p, vec2(0.0))) || any(greaterThan(p, vec2(1.0)))) { return vec4(0.0); }
	return texture(bitmap_subtitle_texture, p);
}
