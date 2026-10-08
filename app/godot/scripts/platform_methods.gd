extends RefCounted
## Android JNISingleton registers Java methods separately from Object's method list.
static func supports(platform: Object, method: String) -> bool:
	if not is_instance_valid(platform): return false
	if platform.has_method("has_java_method"):
		return bool(platform.call("has_java_method", method))
	return platform.has_method(method)
