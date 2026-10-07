extends SceneTree

const Naming := preload("res://scripts/media_naming.gd")
const G := preload("res://scripts/video_geometry.gd")

var checks := 0
var failures: Array[String] = []

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)

func _initialize() -> void:
	var flat := G.Geometry.FLAT
	var half := G.Geometry.HALF_EQUIRECT
	var fisheye := G.Geometry.FISHEYE
	var full := G.Geometry.EQUIRECT_360
	# PTMediaServer outputs.
	check(Naming.from_name("clip_LR_180_FISHEYE_F180_alpha.mp4") == {"geometry": fisheye, "fisheye_fov": 180, "stereo": true, "alpha": true, "packed": true},
		"Alpha-packed fisheye output decodes its own mask")
	check(Naming.from_name("clip_LR_180_SBS_passthrough_live.mp4") == {"geometry": half, "stereo": true, "alpha": true, "packed": false},
		"Green passthrough asks for live Alpha")
	check(Naming.from_name("clip_3D_LR_Screen.mp4") == {"geometry": flat, "stereo": true}, "2D->3D output is a flat SBS screen")
	check(Naming.from_name("clip_alpha.mp4") == {"alpha": true, "packed": false}, "Bare alpha marker: live Alpha")
	# Player conventions, any case and order.
	check(Naming.from_name("Movie.VR180.SBS.mkv") == {"geometry": half, "stereo": true}, "Dots separate markers")
	check(Naming.from_name("scene_fisheye190_LR.mp4") == {"geometry": fisheye, "fisheye_fov": 190, "stereo": true}, "DeoVR fisheye190")
	check(Naming.from_name("scene-MKX200-3dh.mp4") == {"geometry": fisheye, "fisheye_fov": 200, "stereo": true}, "Lens and half-SBS markers")
	check(Naming.from_name("a_VRCA220_LR.mp4").fisheye_fov == 220 and Naming.from_name("a_RF52_LR.mp4").fisheye_fov == 190
		and Naming.from_name("a_fisheye210_LR.mp4").fisheye_fov == 200 and Naming.from_name("a_fisheye_LR.mp4").fisheye_fov == 180,
		"Lens markers give their field of view, snapped to the offered ones")
	check(Naming.from_name("trip_360_2D.mp4") == {"geometry": full, "stereo": false}, "Mono 360")
	check(Naming.from_name("show_RL_180.mp4") == {"geometry": half, "stereo": true, "swap": true}, "RL swaps the eyes")
	check(Naming.from_name("film [Side-By-Side].mkv") == {"stereo": true}, "Spelled-out SBS in brackets")
	# Words that only contain a marker are not markers.
	check(Naming.from_name("4k2.com@sivr00434_8k_part1.mp4").is_empty(), "No marker in a plain name")
	check(Naming.from_name("trailer2d1080.mp4").is_empty() and Naming.from_name("alphabet_180mm.mp4").is_empty(), "Markers need separators")
	check(Naming.from_name("clip_TB_180.mp4") == {"geometry": half, "stereo": true, "top_bottom": true}, "Top-bottom 180")
	check(Naming.from_name("trip_360_BT.mp4") == {"geometry": full, "stereo": true, "top_bottom": true, "swap": true}, "Bottom-top swaps")
	check(Naming.from_name("film.Over-Under.3D.mkv") == {"stereo": true, "top_bottom": true}, "Over-under wins over a bare 3D")
	check(Naming.complete({"stereo": true, "top_bottom": true}, 4096, 4096) == {"geometry": full, "stereo": true, "top_bottom": true, "swap": false},
		"Stated top-bottom square is 360")
	check(Naming.complete({}, 5760, 5760) == {"geometry": full, "stereo": true, "top_bottom": true, "swap": false}, "Large unmarked square is 360 top-bottom")
	check(Naming.complete({}, 1080, 1080) == {"geometry": flat, "stereo": false, "top_bottom": false, "swap": false}, "Small square stays flat 2D")
	# Frame shape fills the rest.
	check(Naming.complete({}, 8192, 4096) == {"geometry": half, "stereo": true, "top_bottom": false, "swap": false}, "Unmarked 2:1 is VR180 SBS")
	check(Naming.complete({}, 3840, 1080) == {"geometry": flat, "stereo": true, "top_bottom": false, "swap": false}, "32:9 is a flat full-SBS film")
	check(Naming.complete({}, 1920, 1080) == {"geometry": flat, "stereo": false, "top_bottom": false, "swap": false}, "16:9 is flat 2D")
	check(Naming.complete({"stereo": false}, 7680, 3840) == {"geometry": full, "stereo": false, "top_bottom": false, "swap": false}, "Mono 2:1 is 360")
	check(Naming.complete({"stereo": true, "swap": true}, 3840, 1920) == {"geometry": half, "stereo": true, "top_bottom": false, "swap": true}, "RL at 2:1")
	check(Naming.complete({"geometry": full}, 4096, 2048) == {"geometry": full, "stereo": false, "top_bottom": false, "swap": false}, "360 defaults mono")
	check(Naming.complete({"geometry": fisheye}, 4000, 2000).stereo, "Fisheye defaults SBS")
	print("media naming checks=%d failures=%d" % [checks, failures.size()])
	for failure in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)
