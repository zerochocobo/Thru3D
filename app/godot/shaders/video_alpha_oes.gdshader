shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

uniform samplerExternalOES video_texture;
// Numeric mask: no source_color hint or color transfer.
uniform sampler2D alpha_texture : filter_linear, repeat_disable;
// 1 independent mask in displayed per-eye SBS layout, 2 legacy six-block red.
uniform int alpha_encoding = 1;
#include "res://shaders/video_coordinates.gdshaderinc"

vec2 packed_texel(vec2 mask_pixel) {
	float half_w = packed_size.x * 0.5;
	float quarter_w = packed_size.x * 0.25;
	float half_h = packed_size.y * 0.5;
	float y = mask_pixel.y < half_h ? source_size.y - half_h + mask_pixel.y : mask_pixel.y - half_h;
	float x;
	if (mask_pixel.x < half_w) { x = source_size.x * 0.5 - half_w * 0.5 + mask_pixel.x; }
	else if (mask_pixel.x < half_w + quarter_w) { x = source_size.x - quarter_w + mask_pixel.x - half_w; }
	else { x = mask_pixel.x - half_w - quarter_w; }
	return (vec2(x, y) + vec2(0.5)) / source_size;
}

float packed_sample(vec2 mask_pixel) {
	return texture(video_texture, oes_uv(packed_texel(mask_pixel))).r;
}

float legacy_alpha(vec2 full_uv) {
	// Four taps stay inside their own tiles, including the six-block seams.
	vec2 p = clamp(full_uv * packed_size - vec2(0.5), vec2(0.0), packed_size - vec2(1.0));
	if (stereo_sbs) {
		int eye = swap_eyes ? 1 - eye_index : eye_index;
		float eye_start = float(eye) * packed_size.x * 0.5;
		p.x = clamp(p.x, eye_start, eye_start + packed_size.x * 0.5 - 1.0);
	}
	vec2 a = floor(p);
	vec2 b = min(a + vec2(1.0), packed_size - vec2(1.0));
	vec2 f = fract(p);
	return mix(mix(packed_sample(a), packed_sample(vec2(b.x, a.y)), f.x),
		mix(packed_sample(vec2(a.x, b.y)), packed_sample(b), f.x), f.y);
}

void vertex() {
	eye_index = int(VIEW_INDEX);
	media_direction = VERTEX;
}

void fragment() {
	vec2 local_uv = eye_uv(UV, media_direction);
	vec2 source_uv = color_uv(local_uv);
	vec3 rgb = texture(video_texture, oes_uv(source_uv)).rgb;
	float alpha = alpha_encoding == 2 ? legacy_alpha(source_uv) : texture(alpha_texture, source_uv).r;
	// These pixels carry metadata; their original RGB has been overwritten by the packer.
	if (alpha_encoding == 2 && reserved_color(source_uv)) { alpha = 0.0; }
	ALBEDO = rgb;
	ALPHA = clamp(alpha, 0.0, 1.0);
}
