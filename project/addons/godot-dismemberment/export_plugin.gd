@tool
extends EditorExportPlugin
## The runtime manifest is an autoload scene, so Godot's standard dependency
## scanner includes the native descriptor, matching library, shaders and imports.
## Do not replace extension_list.cfg: Godot merges all included extensions itself.

const MANIFEST_PATH := "res://addons/godot-dismemberment/runtime_manifest.tscn"

func _get_name() -> String:
	return "godot-dismemberment runtime manifest"

func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var manifest_registered := false
	for property in ProjectSettings.get_property_list():
		var setting: String = property.name
		if not setting.begins_with("autoload/"):
			continue
		var autoload_path := str(ProjectSettings.get_setting(setting)).trim_prefix("*")
		if autoload_path == MANIFEST_PATH:
			manifest_registered = true
			break
	if not manifest_registered:
		push_error("godot-dismemberment export: enable the editor plugin before exporting so its runtime manifest is registered.")
