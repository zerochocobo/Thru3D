extends RefCounted
## Playback mode from the file name, then from the frame's shape. Markers follow
## PTMediaServer utils/vr_naming.py (DeoVR / SKYBOX / HereSphere conventions): any case, any
## order, separated by _ - space . or brackets. EAC cubemaps are not supported by this player,
## so their markers are ignored rather than shown wrongly.

const Geometry := preload("res://scripts/video_geometry.gd")
const _EDGE := "(?:^|[_\\-\\s.\\[\\]()])"
const _END := "(?=$|[_\\-\\s.\\[\\]()])"
const _SBS := "lrf?|sbsf?|hsbs|3dhf?|3d|half[-_ ]?sbs|left[-_ ]*(?:by[-_ ]*)?right|(?:half[-_ ]*)?side[-_ ]*by[-_ ]*side"
const _RL := "rlf?"
const _TB := "tbf?|ouf?|3dvf?|hou|top[-_ ]*(?:by[-_ ]*)?bottom|(?:half[-_ ]*)?over[-_ ]*under|half[-_ ]?ou"
const _BT := "btf?"
const _MONO := "2d|mono"
const _HALF := "180|vr180|180x180"
const _FULL := "360|vr360"
const _FISHEYE := "fisheye(?:\\d{3})?|f180|180f|rf52|mkx200|mkx220|mkx22|vrca220"
## Lens field of view each marker stands for (PTMediaServer _FISHEYE_FOV_BY_MARKER); the frame
## cannot tell 180, 190 and 200 degree circles apart.
const _LENS := {"rf52": 190, "mkx200": 200, "mkx220": 220, "mkx22": 220, "vrca220": 220}
const FOVS := [180, 190, 200, 220]
const _ALPHA := "alpha|passthrough"
const _FLAT := "flat|screen"
static var _patterns := {}

static func _has(name: String, alternatives: String) -> bool:
	if not _patterns.has(alternatives):
		_patterns[alternatives] = RegEx.create_from_string("(?i)" + _EDGE + "(?:" + alternatives + ")" + _END)
	return _patterns[alternatives].search(name) != null

## What the name states. Keys appear only when stated: geometry, stereo, top_bottom, swap,
## fisheye_fov, alpha, packed.
## packed: an alpha-packed fisheye output (mask in the frame's corners, PTMediaServer
## "_LR_180_FISHEYE_F180_alpha"); other alpha names ask for live matting.
static func from_name(file_name: String) -> Dictionary:
	var name := file_name.get_file()
	if name.get_extension().length() in range(2, 5):
		name = name.get_basename()
	var result := {}
	if _has(name, _FISHEYE):
		result.geometry = Geometry.Geometry.FISHEYE
		result.fisheye_fov = _lens_fov(name)
	elif _has(name, _FULL):
		result.geometry = Geometry.Geometry.EQUIRECT_360
	elif _has(name, _HALF):
		result.geometry = Geometry.Geometry.HALF_EQUIRECT
	elif _has(name, _FLAT):
		result.geometry = Geometry.Geometry.FLAT
	if _has(name, _TB) or _has(name, _BT):
		result.stereo = true
		result.top_bottom = true
		if _has(name, _BT):
			result.swap = true
	elif _has(name, _RL):
		result.stereo = true
		result.swap = true
	elif _has(name, _SBS):
		result.stereo = true
	elif _has(name, _MONO):
		result.stereo = false
	if _has(name, _ALPHA):
		result.alpha = true
		result.packed = result.get("geometry", -1) == Geometry.Geometry.FISHEYE and result.get("stereo", true) \
			and not result.get("top_bottom", false)
	return result

## The marker's lens, snapped to the choices the player offers.
static func _lens_fov(name: String) -> int:
	var found := RegEx.create_from_string("(?i)" + _EDGE + "(fisheye(\\d{3})?|f180|180f|rf52|mkx200|mkx220|mkx22|vrca220)" + _END).search(name)
	if not found:
		return 180
	var fov := int(found.get_string(2)) if not found.get_string(2).is_empty() else int(_LENS.get(found.get_string(1).to_lower(), 180))
	var best := 180
	for choice in FOVS:
		if absi(choice - fov) < absi(best - fov):
			best = choice
	return best

## Fills what the name left open from the frame size: 2:1 is VR180 side by side (as PTMediaServer
## exposes unmarked 2:1 sources), 2:1 stated mono is 360, 3.2:1 and wider is a flat full-SBS film,
## a large square frame (2880 px and up) is 360 top-bottom; stated top-bottom: square is 360.
static func complete(stated: Dictionary, width: int, height: int) -> Dictionary:
	var aspect := float(width) / maxf(1.0, float(height))
	var half := absf(aspect - 2.0) <= 0.04
	var square := absf(aspect - 1.0) <= 0.04
	var geometry := int(stated.get("geometry", -1))
	var stacked := bool(stated.get("top_bottom", false)) or (not stated.has("stereo") and square and width >= 2880 		and geometry != Geometry.Geometry.FISHEYE)
	if geometry < 0:
		if stacked and square:
			geometry = Geometry.Geometry.EQUIRECT_360
		elif stacked:
			geometry = Geometry.Geometry.FLAT
		elif half and stated.get("stereo", true):
			geometry = Geometry.Geometry.HALF_EQUIRECT
		elif half:
			geometry = Geometry.Geometry.EQUIRECT_360
		else:
			geometry = Geometry.Geometry.FLAT
	var stereo: bool
	if stacked:
		stereo = true
	elif stated.has("stereo"):
		stereo = stated.stereo
	elif geometry == Geometry.Geometry.FLAT:
		stereo = aspect >= 3.2
	else:
		stereo = geometry != Geometry.Geometry.EQUIRECT_360
	return {"geometry": geometry, "stereo": stereo, "top_bottom": stacked, "swap": bool(stated.get("swap", false)) and stereo}
