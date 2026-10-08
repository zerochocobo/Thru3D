shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;
uniform sampler2D photo_texture : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_texture : filter_linear, repeat_disable;
#include "res://shaders/video_coordinates.gdshaderinc"
#include "res://shaders/sharpness.gdshaderinc"
uniform vec2 crop_center = vec2(0.5);
uniform float content_zoom = 1.0;
uniform vec4 pano_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform bool detail_projection = false;
uniform vec3 detail_forward = vec3(0.0, 0.0, -1.0);
uniform vec3 detail_right = vec3(1.0, 0.0, 0.0);
uniform vec3 detail_up = vec3(0.0, 1.0, 0.0);
uniform bool photo_depth = false;
uniform float depth_strength = 1.0;
uniform vec4 depth_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform int test_eye = -1;

void vertex() { eye_index = test_eye >= 0 ? test_eye : int(VIEW_INDEX); media_direction = VERTEX; }
void fragment() {
	vec3 direction = media_direction;
	if (detail_projection) {
		// Match the 0.8 x 0.5 m window at 1.4 m: 1x shows its natural angular coverage.
		vec2 p = (UV - vec2(0.5)) * vec2(0.8, -0.5) / (1.4 * content_zoom);
		direction = normalize(detail_forward + detail_right * p.x + detail_up * p.y);
	}
	vec2 shown = eye_uv(UV, direction);
	if (video_geometry == 0) { shown = crop_center + (shown - vec2(0.5)) / content_zoom; }
	if (photo_depth && !stereo_sbs && video_geometry == 0) {
		vec2 fixed_uv = shown;
		for (int i = 0; i < 4; i++) {
			float near_value = texture(depth_texture, clamp(depth_rect.xy + shown * depth_rect.zw, depth_rect.xy, depth_rect.xy + depth_rect.zw)).r;
			shown.x = fixed_uv.x - (eye_index == 0 ? 1.0 : -1.0) * (near_value - 0.35) * 0.0175 * depth_strength;
		}
	}
	if (video_geometry == 3 && !stereo_sbs) { shown = (shown - pano_rect.xy) / pano_rect.zw; }
	bool outside = any(lessThan(shown, vec2(0.0))) || any(greaterThan(shown, vec2(1.0))) || outside_lens(direction);
	vec4 color = texture(photo_texture, color_uv(shown));
	if (sharpness > 0.0) {
		vec2 step_uv = max(vec2(1.0) / view_size(), fwidth(shown));
		color.rgb = sharpen_rgb(color.rgb,
			texture(photo_texture, color_uv(shown + vec2(0.0, step_uv.y))).rgb,
			texture(photo_texture, color_uv(shown - vec2(0.0, step_uv.y))).rgb,
			texture(photo_texture, color_uv(shown + vec2(step_uv.x, 0.0))).rgb,
			texture(photo_texture, color_uv(shown - vec2(step_uv.x, 0.0))).rgb);
	}
	ALBEDO = outside ? vec3(0.0) : color.rgb;
	ALPHA = outside ? 1.0 : color.a;
}
