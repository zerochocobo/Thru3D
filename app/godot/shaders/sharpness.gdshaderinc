// Local contrast, bounded to the sampled range to avoid ringing/bright halos.
// Default is neutral for offscreen probes; the player applies its global setting.
uniform float sharpness : hint_range(0.0, 0.6) = 0.0;

vec3 sharpen_rgb(vec3 center, vec3 north, vec3 south, vec3 east, vec3 west) {
	vec3 low = min(center, min(min(north, south), min(east, west)));
	vec3 high = max(center, max(max(north, south), max(east, west)));
	vec3 detail = center - (north + south + east + west) * 0.25;
	return clamp(center + clamp(detail * sharpness, vec3(-0.04), vec3(0.04)), low, high);
}
