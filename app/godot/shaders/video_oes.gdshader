shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform samplerExternalOES video_texture;
#include "res://shaders/video_coordinates.gdshaderinc"

void vertex() {
	eye_index = int(VIEW_INDEX);
	media_direction = VERTEX;
}

void fragment() {
	vec2 source_uv = color_uv(eye_uv(UV, media_direction));
	vec3 rgb = texture(video_texture, oes_uv(source_uv)).rgb;
	if (packed_color && reserved_color(source_uv)) { rgb = vec3(0.0); }
	// The OES sampler yields SDR encoded RGB. Compatibility's lighting space is sRGB.
	ALBEDO = rgb;
}
