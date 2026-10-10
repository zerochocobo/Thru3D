shader_type spatial;
#include "res://shaders/color_grade.gdshaderinc"
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix;

// Both textures belong to one immutable source ticket. Canonical row 0 is top.
// Variant of video_rvm_pair.gdshader for decoder images (external OES color).
// The decoder's own image (MPV direct mode): sampled as RGB by the GPU's YUV conversion.
uniform samplerExternalOES color_texture;
// Visible frame inside a possibly padded decoder buffer.
uniform vec2 color_uv_scale = vec2(1.0);
uniform sampler2D alpha_texture : filter_linear, repeat_disable;
uniform bool alpha_enabled = true;
uniform vec2 model_size = vec2(256.0, 144.0);
uniform vec4 model_content_rect = vec4(0.0, 0.0, 1.0, 1.0);
// 2D->3D (mono sources): alpha_texture carries a near map (1 = nearest) instead of Alpha.
// Each eye samples the color shifted by its half of the parallax; depth_shift is the eye-width
// fraction between nearest and farthest, depth_convergence the near value left on the screen plane.
uniform bool depth_enabled = false;
uniform float depth_shift = 0.035;
uniform float depth_convergence = 0.35;
// Alpha-packed fisheye files (DeoVR six-block layout, PTMediaServer "_FISHEYE_F180_alpha"): the
// mask is part of the color image itself; no model runs. packed_size is in the include.
uniform bool packed_alpha = false;
#include "res://shaders/video_coordinates.gdshaderinc"
#include "res://shaders/sharpness.gdshaderinc"
#include "res://shaders/projected_subtitles.gdshaderinc"
#include "res://shaders/bitmap_subtitles.gdshaderinc"
uniform bool separate_subtitles = false;

vec3 clarity_sample(vec2 p, vec2 lo, vec2 hi, vec3 center) {
	vec2 q = clamp(p, lo, hi);
	if (packed_alpha && reserved_color(q)) { return center; }
	return texture(color_texture, q * color_uv_scale).rgb;
}

vec2 raw_eye_uv(vec2 displayed_uv) {
	vec2 p = displayed_uv;
	if (rotation_degrees == 90) { p = vec2(p.y, 1.0 - p.x); }
	else if (rotation_degrees == 180) { p = vec2(1.0) - p; }
	else if (rotation_degrees == 270) { p = vec2(1.0 - p.y, p.x); }
	return p;
}

float near_at(vec2 uv) {
	vec2 p = clamp(model_content_rect.xy + uv * model_content_rect.zw, vec2(0.5) / model_size, vec2(1.0) - vec2(0.5) / model_size);
	return texture(alpha_texture, vec2(p.x * 0.5, p.y)).r;
}

// Inverse warp: find the source point whose own parallax lands here (fixed point, three steps),
// so near edges move with their object instead of with whatever lies beside them.
vec2 depth_parallax(vec2 shown, int view) {
	float side = view == 0 ? 1.0 : -1.0; // left eye: near content moves right, in front of the screen
	vec2 p = shown;
	for (int i = 0; i < 3; i++) {
		p.x = shown.x - side * (near_at(raw_eye_uv(p)) - depth_convergence) * depth_shift * 0.5;
	}
	return p;
}

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
	return texture(color_texture, packed_texel(mask_pixel) * color_uv_scale).r;
}

// Four taps stay inside their own tiles and this eye's half (as video_alpha_oes.gdshader).
float packed_mask(vec2 full_uv, int eye) {
	vec2 p = clamp(full_uv * packed_size - vec2(0.5), vec2(0.0), packed_size - vec2(1.0));
	if (stereo_sbs) {
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
	vec2 shown_uv = eye_uv(UV, media_direction);
	if (depth_enabled && !stereo_sbs) { shown_uv = depth_parallax(shown_uv, eye_index); }
	vec2 local_uv = raw_eye_uv(shown_uv);
	int eye = stereo_sbs ? (swap_eyes ? 1 - eye_index : eye_index) : 0;
	vec2 eye_size = view_size();
	vec2 color_p = clamp(local_uv, vec2(0.5) / eye_size, vec2(1.0) - vec2(0.5) / eye_size);
	if (stereo_sbs && top_bottom) { color_p.y = (color_p.y + float(eye)) * 0.5; }
	else if (stereo_sbs) { color_p.x = (color_p.x + float(eye)) * 0.5; }
	vec3 rgb = texture(color_texture, color_p * color_uv_scale).rgb;
	if (sharpness > 0.0) {
		vec2 lo = vec2(0.5) / source_size;
		vec2 hi = vec2(1.0) - lo;
		if (stereo_sbs && top_bottom) { lo.y += float(eye) * 0.5; hi.y -= float(1 - eye) * 0.5; }
		else if (stereo_sbs) { lo.x += float(eye) * 0.5; hi.x -= float(1 - eye) * 0.5; }
		vec2 step_uv = max(vec2(1.0) / source_size, fwidth(color_p));
		rgb = sharpen_rgb(rgb, clarity_sample(color_p + vec2(0.0, step_uv.y), lo, hi, rgb),
			clarity_sample(color_p - vec2(0.0, step_uv.y), lo, hi, rgb),
			clarity_sample(color_p + vec2(step_uv.x, 0.0), lo, hi, rgb),
			clarity_sample(color_p - vec2(step_uv.x, 0.0), lo, hi, rgb));
	}
	// The model input contains letterbox padding. Read only centers inside content,
	// then clamp within this eye before packing; never interpolate across the seam.
	vec2 first_center = (ceil(model_content_rect.xy * model_size - vec2(0.5)) + vec2(0.5)) / model_size;
	vec2 last_center = (floor((model_content_rect.xy + model_content_rect.zw) * model_size - vec2(0.5)) + vec2(0.5)) / model_size;
	// An ROI window covers the whole model; keep sampling on this eye's own centers.
	first_center = max(first_center, vec2(0.5) / model_size);
	last_center = min(last_center, vec2(1.0) - vec2(0.5) / model_size);
	vec2 model_p = model_content_rect.xy + local_uv * model_content_rect.zw;
	// Outside the ROI window nothing was inferred: show passthrough, never an edge smear.
	bool outside = any(lessThan(model_p, vec2(0.0))) || any(greaterThan(model_p, vec2(1.0)));
	vec2 alpha_p = clamp(model_p, first_center, last_center);
	alpha_p.x = (alpha_p.x + float(eye)) * 0.5;
	ALBEDO = outside_lens(media_direction) ? vec3(0.0) : color_grade(rgb);
	if (packed_alpha && stereo_sbs && !top_bottom) {
		// Pixels that carry the mask had their color overwritten by the packer.
		// (No early return: Godot writes the outputs after this function body.)
		ALPHA = reserved_color(color_p) ? 0.0 : clamp(packed_mask(color_p, eye), 0.0, 1.0);
	} else {
		ALPHA = alpha_enabled && !depth_enabled ? (outside ? 0.0 : clamp(texture(alpha_texture, alpha_p).r, 0.0, 1.0)) : 1.0;
	}
	if (!separate_subtitles) {
	vec4 composed = caption_composite(ALBEDO, ALPHA, projected_caption(media_direction, eye_index));
	composed = caption_composite(composed.rgb, composed.a, bitmap_caption(raw_eye_uv(eye_uv(UV, media_direction))));
	ALBEDO = composed.rgb;
	ALPHA = composed.a;
	}
}
