extends SceneTree
## Regression uses the real crawler mesh and Godot's rendered-skin bake, rather
## than treating skeleton flags or triangle counts as proof of isolation.

const RigFactory = preload("res://demo/rig_factory.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func frames() -> void:
	await process_frame
	await process_frame
	await physics_frame
	await process_frame

func posed_world(mesh: MeshInstance3D) -> PackedVector3Array:
	var baked: ArrayMesh = mesh.bake_mesh_from_current_skeleton_pose()
	var result := PackedVector3Array()
	if baked == null:
		return result
	for surface in baked.get_surface_count():
		var vertices: PackedVector3Array = baked.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for vertex in vertices:
			result.append(mesh.global_transform * vertex)
	return result

func run() -> void:
	await run_case(false)
	await run_case(true)
	print("BODY_CUT_TESTS: ", checks, " checks, ", failures, " failures")
	quit(0 if failures == 0 else 1)

func run_case(with_override: bool) -> void:
	var rig: Dictionary = RigFactory.build(1)
	root.add_child(rig.actor)
	var sibling := MeshInstance3D.new()
	sibling.name = "SharedSkinChild"
	sibling.mesh = rig.mesh.mesh
	sibling.skin = rig.mesh.skin
	sibling.skeleton = NodePath("..")
	sibling.visible = false
	if with_override:
		sibling.add_to_group("No Dismemberment")
	rig.skeleton.add_child(sibling)
	var head_socket := BoneAttachment3D.new()
	head_socket.name = "UntransferredHeadAccessory"
	head_socket.bone_name = "head"
	rig.skeleton.add_child(head_socket)
	var badge := MeshInstance3D.new()
	badge.mesh = BoxMesh.new()
	head_socket.add_child(badge)
	var tail_socket := BoneAttachment3D.new()
	tail_socket.name = "RetainedTailAccessory"
	tail_socket.bone_name = "tail"
	rig.skeleton.add_child(tail_socket)
	var initially_hidden_socket := BoneAttachment3D.new()
	initially_hidden_socket.name = "InitiallyHiddenHeadAccessory"
	initially_hidden_socket.bone_name = "head"
	initially_hidden_socket.visible = false
	rig.skeleton.add_child(initially_hidden_socket)
	var component: Node3D = ClassDB.instantiate("DismembermentComponent")
	component.name = "Dismemberment"
	component.skeleton_path = NodePath("../Skeleton3D")
	component.mesh_path = NodePath("../Skeleton3D/SkinMesh")
	component.pelvis_bone_name = &"pelvis"
	component.excluded_bones = PackedStringArray(["root", "pelvis"])
	component.support_attached_child_meshes = with_override
	rig.actor.add_child(component)
	var camera := Camera3D.new()
	camera.position = Vector3(4, 3, 6)
	root.add_child(camera)
	camera.look_at(Vector3(0, 1, 0))
	await frames()
	check(component.initialize(), "real crawler initializes")
	var source: MeshInstance3D = rig.mesh
	var skeleton: Skeleton3D = rig.skeleton
	var arrays: Array = source.mesh.surface_get_arrays(0)
	var bone_indices: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var body_index := skeleton.find_bone("body")
	if with_override:
		# Procedural rigs and physics may supply global pose overrides. A hidden
		# source limb must stay hidden when its local scale is overridden upstream.
		var override_pose := skeleton.get_bone_global_pose(body_index)
		override_pose.origin += Vector3(.15, .1, -.2)
		override_pose.basis = Basis(Vector3.UP, .45) * override_pose.basis
		skeleton.set_bone_global_pose_override(body_index, override_pose, 1.0, true)
		await frames()
	var before := posed_world(source)
	var sibling_before := posed_world(sibling)
	check(not before.is_empty(), "Godot skin bake exposes actual posed crawler vertices")
	component.dismember_limb(&"body", Vector3.ZERO)
	await frames()
	var limb: RigidBody3D = component.get_dismembered_limb_by_name(&"body")
	check(is_instance_valid(limb), "body cut creates detached skin")
	if not is_instance_valid(limb):
		quit(1)
		return
	limb.freeze = true
	limb.gravity_scale = 0
	var detached: MeshInstance3D = limb.get_meshes()[0]
	await frames()
	var after_source := posed_world(source)
	var after_detached := posed_world(detached)
	var sibling_after := posed_world(sibling)
	check(after_source.size() == before.size() and after_detached.size() == before.size(), "both collapsed skins preserve original vertex indexing")
	var max_source_selected_distance := 0.0
	var max_source_retained_error := 0.0
	var max_detached_selected_error := 0.0
	var max_detached_complement_distance := 0.0
	var max_sibling_error := 0.0
	var cut_position: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(body_index).origin
	for vertex in mini(before.size(), mini(after_source.size(), after_detached.size())):
		var bone := bone_indices[vertex * 4]
		var cursor := bone
		var selected := false
		while cursor >= 0:
			if cursor == body_index:
				selected = true
				break
			cursor = skeleton.get_bone_parent(cursor)
		if selected:
			max_source_selected_distance = maxf(max_source_selected_distance, after_source[vertex].distance_to(cut_position))
			max_detached_selected_error = maxf(max_detached_selected_error, after_detached[vertex].distance_to(before[vertex]))
			max_sibling_error = maxf(max_sibling_error, sibling_after[vertex].distance_to(cut_position if with_override else sibling_before[vertex]))
		else:
			max_source_retained_error = maxf(max_source_retained_error, after_source[vertex].distance_to(before[vertex]))
			max_detached_complement_distance = maxf(max_detached_complement_distance, after_detached[vertex].distance_to(cut_position))
	print("CRAWLER_BODY_POSE: source_selected_radius=", max_source_selected_distance,
		" with_override=", with_override,
		" source_retained_error=", max_source_retained_error,
		" detached_selected_error=", max_detached_selected_error,
		" detached_complement_radius=", max_detached_complement_distance)
	check(max_source_selected_distance < .005, "body/head/leg source vertices actually collapse at the cut")
	check(max_source_retained_error < .005, "pelvis and tail remain on source because they are outside body subtree")
	check(max_detached_selected_error < .03, "detached body/head/legs preserve captured world-space pose")
	check(max_detached_complement_distance < .05, "detached pelvis/tail actually shrink instead of duplicating the whole crawler")
	check(max_sibling_error < .005, "supported No Dismemberment skin hides without copying; unsupported shared-skin child stays visible")
	check(limb.get_meshes().size() == 1, "No Dismemberment tag prevents detached copy and source-only mode does not copy sibling")
	check(not head_socket.visible and tail_socket.visible, "missing source socket visuals hide while unrelated tail socket remains visible")
	var delta := Vector3(4, 0, 0)
	limb.global_position += delta
	await frames()
	var moved := posed_world(detached)
	var max_motion_error := 0.0
	for vertex in mini(moved.size(), after_detached.size()):
		max_motion_error = maxf(max_motion_error, moved[vertex].distance_to(after_detached[vertex] + delta))
	check(max_motion_error < .005, "all posed detached skin moves with the native body, including skeletal render transforms")
	component.reset_all_limbs()
	await frames()
	var reset := posed_world(source)
	var max_reset_error := 0.0
	for vertex in mini(before.size(), reset.size()):
		max_reset_error = maxf(max_reset_error, before[vertex].distance_to(reset[vertex]))
	check(max_reset_error < .005, "reset restores actual rendered source vertices")
	check(head_socket.visible and not initially_hidden_socket.visible, "reset restores each attachment's original local visibility")
	component.dismember_limb(&"left_leg_1", Vector3.ZERO)
	await frames()
	component.dismember_limb(&"body", Vector3.ZERO)
	await frames()
	var later_limb: Node = component.get_dismembered_limb_by_name(&"body")
	check(is_instance_valid(later_limb), "parent cut remains possible after a child limb was removed")
	if is_instance_valid(later_limb):
		var later_mesh: MeshInstance3D = later_limb.get_meshes()[0]
		var later_skeleton: Skeleton3D = later_limb.get_ragdoll_skeleton()
		var earlier_root: int = skeleton.find_bone("left_leg_1")
		var earlier_center: Vector3 = later_skeleton.global_transform * later_skeleton.get_bone_global_pose(earlier_root).origin
		var later_vertices := posed_world(later_mesh)
		var later_source := posed_world(source)
		var max_removed_radius := 0.0
		var max_parent_source_radius := 0.0
		for vertex in mini(later_vertices.size(), before.size()):
			var cursor := bone_indices[vertex * 4]
			while cursor >= 0:
				if cursor == earlier_root:
					max_removed_radius = maxf(max_removed_radius, later_vertices[vertex].distance_to(earlier_center))
					break
				cursor = skeleton.get_bone_parent(cursor)
			cursor = bone_indices[vertex * 4]
			while cursor >= 0:
				if cursor == body_index:
					max_parent_source_radius = maxf(max_parent_source_radius, later_source[vertex].distance_to(cut_position))
					break
				cursor = skeleton.get_bone_parent(cursor)
		check(max_removed_radius < .005, "earlier removed leg does not regrow on the subsequently detached body skin")
		check(max_parent_source_radius < .005, "parent hide wins over prior child hide so the source stays fully collapsed")
	component.reset_all_limbs()
	rig.actor.queue_free()
	camera.queue_free()
	await frames()
