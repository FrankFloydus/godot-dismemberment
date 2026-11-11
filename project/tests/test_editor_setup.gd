@tool
extends EditorPlugin
## Enable this test as a second EditorPlugin only in an isolated project copy.

const RigFixture = preload("res://tests/rig_fixture.gd")
const PLUGIN_PATH := "res://addons/godot-dismemberment/plugin.gd"
const FIXTURE_PATH := "res://.godot/godot_dismemberment_editor_setup_fixture.tscn"

var checks := 0
var failures := 0

func _enter_tree() -> void:
	_run.call_deferred()

func _run() -> void:
	var plugin: EditorPlugin
	for _frame in 300:
		await get_tree().process_frame
		plugin = _find_plugin()
		if plugin != null and not EditorInterface.get_resource_filesystem().is_scanning():
			break
	_check(plugin != null, "setup dock loaded in the editor")
	if plugin == null or not _write_fixture():
		_finish()
		return
	EditorInterface.open_scene_from_path(FIXTURE_PATH)
	var scene: Node
	for _frame in 300:
		await get_tree().process_frame
		scene = EditorInterface.get_edited_scene_root()
		if scene != null and scene.scene_file_path == FIXTURE_PATH:
			break
	_check(scene != null and scene.scene_file_path == FIXTURE_PATH, "editor opened the setup fixture")
	if scene == null or scene.scene_file_path != FIXTURE_PATH:
		_finish()
		return
	var button := _find_setup_button(plugin)
	_check(button != null, "setup action is available from the dock")
	if button == null:
		_finish()
		return
	var selection := EditorInterface.get_selection()
	var selected_paths := ["RigA", "RigB", "RigC", "EyesC", "InvalidRig"]
	_select(scene, selection, selected_paths)
	button.pressed.emit()
	_check(_components(scene).size() == 3, "batch creates only the two missing components")
	_check(_check_component(scene, "RigA", "BodyA") == scene.get_node("Existing"), "existing rig retains its component")
	var second := _check_component(scene, "RigB", "BodyB")
	var third := _check_component(scene, "RigC", "EyesC")
	if second != null and third != null:
		_check(second.owner == scene and third.owner == scene, "both new components have scene ownership")
		_check(PackedStringArray(second.get("excluded_bones")).has("pelvis") and
			PackedStringArray(third.get("excluded_bones")).has("root"), "setup preserves protected bone defaults")

	_select(scene, selection, selected_paths)
	button.pressed.emit()
	_check(_components(scene).size() == 3, "repeating setup is idempotent")
	var undo := plugin.get_undo_redo()
	var history := undo.get_history_undo_redo(undo.get_object_history_id(scene))
	_check(history != null and history.has_undo(), "batch belongs to the edited scene's undo history")
	if history != null and history.has_undo():
		history.undo()
		_check(_components(scene).size() == 1, "one undo removes both newly created components")
		history.redo()
		_check(_components(scene).size() == 3, "one redo restores both components")
		_check_component(scene, "RigB", "BodyB")
		_check_component(scene, "RigC", "EyesC")
		var packed := PackedScene.new()
		_check(packed.pack(scene) == OK, "batch scene can be packed")
		var reloaded := packed.instantiate()
		_check(reloaded != null and _components(reloaded).size() == 3, "packed scene retains the three components")
		if reloaded != null:
			reloaded.free()
	_finish()

func _find_plugin() -> EditorPlugin:
	for node in get_tree().root.find_children("*", "EditorPlugin", true, false):
		var script: Script = node.get_script()
		if script != null and script.resource_path == PLUGIN_PATH:
			return node as EditorPlugin
	return null

func _find_setup_button(plugin: EditorPlugin) -> Button:
	var dock: Control = plugin.get("dock")
	for node in dock.find_children("*", "Button", true, false):
		var button := node as Button
		if button.text.begins_with("Set up selected skeleton"):
			return button
	return null

func _write_fixture() -> bool:
	var scene := Node3D.new()
	scene.name = "BatchSetupFixture"
	for suffix in ["A", "B", "C"]:
		var rig := RigFixture.make_rig()
		var actor: Node = rig.actor
		var skeleton: Skeleton3D = rig.skeleton
		var body: MeshInstance3D = rig.mesh
		actor.remove_child(skeleton)
		actor.remove_child(body)
		actor.free()
		skeleton.name = "Rig" + suffix
		body.name = "Body" + suffix
		body.skeleton = NodePath("../" + str(skeleton.name))
		body.add_to_group(&"Dismemberment Source", true)
		var eyes := MeshInstance3D.new()
		eyes.name = "Eyes" + suffix
		eyes.mesh = body.mesh
		eyes.skin = body.skin
		eyes.skeleton = body.skeleton
		for node in [skeleton, eyes, body]:
			scene.add_child(node)
			node.owner = scene
	var existing: Node = ClassDB.instantiate("DismembermentComponent")
	existing.name = "Existing"
	existing.set("skeleton_path", NodePath("../RigA"))
	existing.set("mesh_path", NodePath("../BodyA"))
	scene.add_child(existing)
	existing.owner = scene
	var invalid := Skeleton3D.new()
	invalid.name = "InvalidRig"
	scene.add_child(invalid)
	invalid.owner = scene
	var packed := PackedScene.new()
	var ok := packed.pack(scene) == OK and ResourceSaver.save(packed, FIXTURE_PATH) == OK
	scene.free()
	_check(ok, "editor fixture saved")
	return ok

func _select(scene: Node, selection: EditorSelection, paths: Array) -> void:
	selection.clear()
	for path in paths:
		selection.add_node(scene.get_node(path))

func _components(scene: Node) -> Array[Node]:
	return scene.find_children("*", "DismembermentComponent", true, false)

func _check_component(scene: Node, rig_name: String, mesh_name: String) -> Node:
	for component in _components(scene):
		var skeleton_path: NodePath = component.get("skeleton_path")
		if component.get_node_or_null(skeleton_path) == scene.get_node(rig_name):
			var mesh_path: NodePath = component.get("mesh_path")
			_check(component.get_node_or_null(mesh_path) == scene.get_node(mesh_name),
				"%s has the expected %s source" % [rig_name, mesh_name])
			return component
	_check(false, "%s has a bound component" % rig_name)
	return null

func _check(ok: bool, description: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("EDITOR_SETUP_FAIL: " + description)

func _finish() -> void:
	print("EDITOR_SETUP_CHECKS=", checks, " FAILURES=", failures)
	get_tree().quit(0 if failures == 0 else 1)
