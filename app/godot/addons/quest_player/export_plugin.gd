@tool
extends EditorPlugin

var android_export: QuestPlayerExport

func _enter_tree() -> void:
	android_export = QuestPlayerExport.new()
	add_export_plugin(android_export)

func _exit_tree() -> void:
	remove_export_plugin(android_export)
	android_export = null

class QuestPlayerExport extends EditorExportPlugin:
	func _get_name() -> String:
		return "QuestPlayer"

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_libraries(_platform: EditorExportPlatform, debug: bool) -> PackedStringArray:
		return PackedStringArray(["res://addons/quest_player/bin/player-plugin-%s.aar" % ("debug" if debug else "release")])

	func _get_android_dependencies(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
		# AAR library dependencies are resolved by the exported Godot Gradle app.
		return PackedStringArray(["androidx.media3:media3-exoplayer:1.10.1", "eu.agno3.jcifs:jcifs-ng:2.1.10"])
