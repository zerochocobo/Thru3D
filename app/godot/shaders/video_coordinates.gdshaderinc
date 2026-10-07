uniform mat4 surface_transform = mat4(1.0);
uniform bool stereo_sbs = false; // two views: side by side, or above each other with top_bottom
uniform bool top_bottom = false;
// Lens field of view of fisheye sources (180, 190, 200, 220...).
uniform float fisheye_fov = 180.0;
uniform bool swap_eyes = false;
uniform int rotation_degrees = 0;
// 0 flat, 1 half-equirect 180, 2 equidistant fisheye 180.
uniform int video_geometry = 0;
uniform vec2 source_size = vec2(1920.0, 1080.0);
uniform vec2 packed_size = vec2(768.0, 432.0);
uniform bool packed_color = false;
varying flat int eye_index;
varying vec3 media_direction;

// One view's size in source pixels.
vec2 view_size() {
	return vec2(source_size.x * (stereo_sbs && !top_bottom ? 0.5 : 1.0), source_size.y * (stereo_sbs && top_bottom ? 0.5 : 1.0));
}

// Fisheye directions beyond the lens circle have no picture.
bool outside_lens(vec3 direction) {
	return video_geometry == 2 && acos(clamp(-normalize(direction).z, -1.0, 1.0)) > radians(fisheye_fov * 0.5);
}

vec2 eye_uv(vec2 planar_uv, vec3 direction) {
	if (video_geometry == 0) { return planar_uv; }
	vec3 d = normalize(direction);
	if (video_geometry == 3) {
		// Full equirectangular 360: longitude 0 (looking along -Z) is the centre column.
		return vec2(atan(d.x, -d.z) / (2.0 * PI) + 0.5, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI);
	}
	if (video_geometry == 1) {
		return vec2(atan(d.x, -d.z) / PI + 0.5, 0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI);
	}
	float transverse = length(d.xy);
	float radial = acos(clamp(-d.z, -1.0, 1.0)) / radians(fisheye_fov * 0.5);
	vec2 axis = transverse > 0.000001 ? vec2(d.x, -d.y) / transverse : vec2(0.0);
	vec2 eye_size = view_size();
	return vec2(0.5) + 0.5 * radial * axis * min(eye_size.x, eye_size.y) / eye_size;
}

vec2 color_uv(vec2 per_eye_uv) {
	vec2 eye_size = view_size();
	vec2 uv = clamp(per_eye_uv, vec2(0.5) / eye_size, vec2(1.0) - vec2(0.5) / eye_size);
	if (stereo_sbs) {
		int eye = swap_eyes ? 1 - eye_index : eye_index;
		if (top_bottom) { uv.y = uv.y * 0.5 + float(eye) * 0.5; }
		else { uv.x = uv.x * 0.5 + float(eye) * 0.5; }
	}
	if (rotation_degrees == 90) { uv = vec2(uv.y, 1.0 - uv.x); }
	else if (rotation_degrees == 180) { uv = vec2(1.0) - uv; }
	else if (rotation_degrees == 270) { uv = vec2(1.0 - uv.y, uv.x); }
	return uv;
}

vec2 oes_uv(vec2 top_left_uv) {
	return (surface_transform * vec4(top_left_uv.x, 1.0 - top_left_uv.y, 0.0, 1.0)).xy;
}

bool reserved_color(vec2 full_uv) {
	vec2 p = full_uv * source_size;
	float half_w = packed_size.x * 0.5;
	float quarter_w = packed_size.x * 0.25;
	float half_h = packed_size.y * 0.5;
	bool edge_row = p.y < half_h || p.y >= source_size.y - half_h;
	float center_x = source_size.x * 0.5 - half_w * 0.5;
	bool edge_column = p.x < quarter_w || p.x >= source_size.x - quarter_w || (p.x >= center_x && p.x < center_x + half_w);
	return edge_row && edge_column;
}
