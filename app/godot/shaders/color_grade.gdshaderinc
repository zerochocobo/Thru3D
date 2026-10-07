// Same display transform for decoder OES and inferred/packed color textures.
// Operates on decoded display RGB, after sampling; masks and model input are untouched.
uniform bool grade_enabled = false;
uniform vec3 grade_gain = vec3(1.0);
uniform vec3 grade_gamma = vec3(1.0);
uniform vec3 grade_offset = vec3(0.0);
uniform float grade_contrast = 1.0;
uniform float grade_saturation = 1.0;

vec3 color_grade(vec3 rgb) {
	if (!grade_enabled) { return rgb; }
	vec3 c = (rgb * grade_gain - vec3(0.5)) * grade_contrast + vec3(0.5) + grade_offset;
	c = pow(max(c, vec3(0.0)), grade_gamma);
	float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
	return clamp(mix(vec3(luma), c, grade_saturation), vec3(0.0), vec3(1.0));
}
