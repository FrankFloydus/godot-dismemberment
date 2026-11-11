@tool
extends EditorPlugin
## Editor shell; runtime geometry, physics, hierarchy and effects live in C++.

const RuntimeExportPlugin = preload("res://addons/godot-dismemberment/export_plugin.gd")
const RUNTIME_MANIFEST_PATH := "res://addons/godot-dismemberment/runtime_manifest.tscn"
const RUNTIME_AUTOLOAD_BASE := "GodotDismembermentRuntime"
const SETUP_MENU := "godot-dismemberment: set up selected skeletons"
const SOURCE_GROUP := &"Dismemberment Source"

var runtime_export_plugin: EditorExportPlugin
var dock: VBoxContainer
var explanation: Label
var bones: ItemList
var selected_component: Node
var runtime_autoload_name := ""

func _enter_tree() -> void:
	_ensure_runtime_manifest()
	runtime_export_plugin = RuntimeExportPlugin.new()
	add_export_plugin(runtime_export_plugin)
	dock = VBoxContainer.new()
	dock.name = "godot-dismemberment"
	dock.custom_minimum_size.x = 240
	var title := Label.new()
	title.text = "PROCEDURAL DISMEMBERMENT"
	title.add_theme_font_size_override("font_size", 13)
	dock.add_child(title)
	explanation = Label.new()
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	explanation.custom_minimum_size = Vector2(240, 70)
	dock.add_child(explanation)
	var setup := Button.new()
	setup.text = "Set up selected skeletons"
	setup.pressed.connect(_setup_selected)
	dock.add_child(setup)
	var validate := Button.new()
	validate.text = "Validate component"
	validate.pressed.connect(_validate_selected)
	dock.add_child(validate)
	var bone_label := Label.new()
	bone_label.text = "BONE HIERARCHY"
	dock.add_child(bone_label)
	bones = ItemList.new()
	bones.custom_minimum_size.y = 220
	bones.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dock.add_child(bones)
	var note := Label.new()
	note.text = "Configure filters, effects and networking in the native component inspector. Meshes need a Skin and bone/weight arrays."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 240
	dock.add_child(note)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)
	add_tool_menu_item(SETUP_MENU, _setup_selected)
	get_editor_interface().get_selection().selection_changed.connect(_refresh_selection)
	_refresh_selection()

func _enable_plugin() -> void:
	_ensure_runtime_manifest()

func _disable_plugin() -> void:
	# Only remove the exact name and resource installed by this plugin. An
	# unrelated autoload with the same preferred name is left untouched.
	if runtime_autoload_name.is_empty():
		runtime_autoload_name = _find_manifest_autoload_name()
	if not runtime_autoload_name.is_empty():
		var setting := "autoload/" + runtime_autoload_name
		if str(ProjectSettings.get_setting(setting, "")).trim_prefix("*") == RUNTIME_MANIFEST_PATH:
			remove_autoload_singleton(runtime_autoload_name)
		runtime_autoload_name = ""

func _find_manifest_autoload_name() -> String:
	for property in ProjectSettings.get_property_list():
		var setting: String = property.name
		if setting.begins_with("autoload/" + RUNTIME_AUTOLOAD_BASE):
			if str(ProjectSettings.get_setting(setting)).trim_prefix("*") == RUNTIME_MANIFEST_PATH:
				return setting.trim_prefix("autoload/")
	return ""

func _ensure_runtime_manifest() -> void:
	runtime_autoload_name = _find_manifest_autoload_name()
	if not runtime_autoload_name.is_empty():
		return
	var candidate := RUNTIME_AUTOLOAD_BASE
	var suffix := 2
	while ProjectSettings.has_setting("autoload/" + candidate):
		candidate = RUNTIME_AUTOLOAD_BASE + str(suffix)
		suffix += 1
	add_autoload_singleton(candidate, RUNTIME_MANIFEST_PATH)
	runtime_autoload_name = candidate

func _exit_tree() -> void:
	if runtime_export_plugin != null:
		remove_export_plugin(runtime_export_plugin)
		runtime_export_plugin = null
	remove_tool_menu_item(SETUP_MENU)
	if is_instance_valid(dock):
		remove_control_from_docks(dock)
		dock.queue_free()

func _refresh_selection() -> void:
	selected_component = null
	bones.clear()
	var selection := get_editor_interface().get_selection().get_selected_nodes()
	var targets := _selection_targets(selection)
	if targets.is_empty():
		for node in selection:
			if node.is_class("DismembermentComponent"):
				selected_component = node
				break
		explanation.text = "Select one or more Skeleton3D nodes, skinned meshes, or native components."
		return
	var skeleton: Skeleton3D = targets.keys()[0]
	var selected_node: Node = targets[skeleton]
	var mesh := _mesh_for_target(skeleton, selected_node)
	selected_component = _component_for_target(skeleton, selected_node)
	for index in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(index)
		bones.add_item("%02d  %s%s" % [index, "↳ " if parent >= 0 else "", skeleton.get_bone_name(index)])
	explanation.text = "%s · %d bones\n%s" % [skeleton.name, skeleton.get_bone_count(),
		"Skinned mesh ready" if mesh != null else "No skinned mesh bound to this skeleton"]
	if targets.size() > 1:
		explanation.text += "\n%d skeletons selected for setup" % targets.size()

func _selection_targets(selection: Array[Node]) -> Dictionary:
	var targets := {}
	for node in selection:
		var skeleton := _skeleton_for_target(node)
		if skeleton == null:
			continue
		# Prefer an explicit mesh over a skeleton-only selection for the same rig.
		# An explicitly selected component takes precedence over both.
		if not targets.has(skeleton) or targets[skeleton] is Skeleton3D or node.is_class("DismembermentComponent"):
			targets[skeleton] = node
	return targets

func _skeleton_for_target(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	if node is MeshInstance3D:
		if node.mesh != null and node.skin != null:
			return node.get_node_or_null(node.skeleton) as Skeleton3D
		return null
	if not node.is_class("DismembermentComponent"):
		return null
	var skeleton_path: NodePath = node.get("skeleton_path")
	if not skeleton_path.is_empty():
		return node.get_node_or_null(skeleton_path) as Skeleton3D
	var mesh_path: NodePath = node.get("mesh_path")
	if not mesh_path.is_empty():
		var mesh := node.get_node_or_null(mesh_path) as MeshInstance3D
		return mesh.get_node_or_null(mesh.skeleton) as Skeleton3D if mesh != null else null
	var initialized_skeleton := node.call("get_skeleton") as Skeleton3D
	if initialized_skeleton != null:
		return initialized_skeleton
	var parent := node.get_parent()
	if parent is Skeleton3D:
		return parent
	if parent != null:
		var skeletons := parent.find_children("*", "Skeleton3D", true, false)
		if skeletons.size() == 1:
			return skeletons[0] as Skeleton3D
	return null

func _mesh_for_target(skeleton: Skeleton3D, node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	if node.is_class("DismembermentComponent"):
		var mesh_path: NodePath = node.get("mesh_path")
		if not mesh_path.is_empty():
			return node.get_node_or_null(mesh_path) as MeshInstance3D
	var parent := skeleton.get_parent()
	if parent == null:
		return null
	var fallback: MeshInstance3D
	for child in parent.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		if mesh.mesh == null or mesh.skin == null or mesh.get_node_or_null(mesh.skeleton) != skeleton:
			continue
		if mesh.is_in_group(SOURCE_GROUP):
			return mesh
		if fallback == null or (skeleton.is_ancestor_of(mesh) and not skeleton.is_ancestor_of(fallback)):
			fallback = mesh
	return fallback

func _component_for_target(skeleton: Skeleton3D, node: Node) -> Node:
	if node.is_class("DismembermentComponent"):
		return node
	var parent := skeleton.get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling.is_class("DismembermentComponent") and _skeleton_for_target(sibling) == skeleton:
				return sibling
	return null

func _setup_selected() -> void:
	var editor := get_editor_interface()
	var selection := editor.get_selection()
	var targets := _selection_targets(selection.get_selected_nodes())
	if targets.is_empty():
		explanation.text = "Setup requires a selected Skeleton3D or a skinned mesh bound to it."
		return
	if not ClassDB.class_exists("GoreComponent"):
		explanation.text = "Native library missing. Build godot-dismemberment, then restart the editor."
		return
	var scene_root := editor.get_edited_scene_root()
	if scene_root == null:
		explanation.text = "Open the scene containing the selected skeletons before setup."
		return
	var created: Array[Node] = []
	var existing: Node
	var skipped := 0
	var undo := get_undo_redo()
	for target in targets:
		var skeleton := target as Skeleton3D
		var node: Node = targets[skeleton]
		var component := _component_for_target(skeleton, node)
		if component != null:
			if existing == null:
				existing = component
			continue
		var mesh := _mesh_for_target(skeleton, node)
		if not scene_root.is_ancestor_of(skeleton) or mesh == null or skeleton.get_bone_count() == 0:
			skipped += 1
			continue
		if created.is_empty():
			undo.create_action("Set up godot-dismemberment", UndoRedo.MERGE_DISABLE, scene_root)
		var parent := skeleton.get_parent()
		component = _make_component(skeleton, mesh)
		undo.add_do_method(parent, "add_child", component, true)
		undo.add_do_property(component, "owner", scene_root)
		undo.add_undo_method(parent, "remove_child", component)
		undo.add_do_reference(component)
		created.append(component)
	if not created.is_empty():
		undo.commit_action()
		selection.clear()
		for component in created:
			selection.add_node(component)
		if created.size() == 1:
			editor.edit_node(created[0])
		explanation.text = "Created %d new GoreComponent nodes. Save the scene." % created.size()
	elif existing != null:
		editor.edit_node(existing)
		explanation.text = "Existing component selected. Adjust the native settings in the Inspector."
	else:
		explanation.text = "Setup requires a skeleton with bones and a bound skinned mesh below the scene root."
		return
	if skipped > 0:
		explanation.text += " Skipped %d without bones or a bound mesh below the scene root." % skipped

func _make_component(skeleton: Skeleton3D, mesh: MeshInstance3D) -> Node:
	var component: Node = ClassDB.instantiate("GoreComponent")
	component.name = "GoreComponent"
	# The paths are relative to the future sibling component.
	var parent := skeleton.get_parent()
	component.set("skeleton_path", NodePath("../" + str(parent.get_path_to(skeleton))))
	component.set("mesh_path", NodePath("../" + str(parent.get_path_to(mesh))))
	var pelvis := "pelvis"
	for index in skeleton.get_bone_count():
		var name := skeleton.get_bone_name(index)
		if name.to_lower() in ["pelvis", "hips"]:
			pelvis = name
			break
	component.set("pelvis_bone_name", StringName(pelvis))
	var protected_bones := PackedStringArray([pelvis])
	for index in skeleton.get_bone_count():
		if skeleton.get_bone_parent(index) == -1:
			protected_bones.append(skeleton.get_bone_name(index))
	component.set("excluded_bones", protected_bones)
	return component

func _validate_selected() -> void:
	_refresh_selection()
	if selected_component == null:
		explanation.text = "Select a native component or set up the selected skeleton first."
		return
	var ok: bool = selected_component.call("initialize")
	if ok:
		var skeleton := selected_component.call("get_skeleton") as Skeleton3D
		var physics_bodies := skeleton.find_children("*", "PhysicalBone3D", true, false)
		if physics_bodies.is_empty() and not bool(selected_component.get("limb_rigid_fallback_enabled")):
			explanation.text = "Mesh and skeleton validated. Add authored PhysicalBone3D collision bodies and joints for detached ragdoll simulation. Rigid fallback is an explicit optional mode."
		else:
			explanation.text = "Validated: skeleton, mesh, Skin and physics configuration are ready."
	else:
		explanation.text = "Validation failed: " + str(selected_component.call("get_last_error"))
