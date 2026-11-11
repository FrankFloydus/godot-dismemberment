extends SceneTree
## Numerical regression on the actual CC0 asset, including its original bind
## space and smoothly blended cut-boundary vertices. No primitive stand-in.

const Factory = preload("res://demo/realistic_rig.gd")
const Physics = preload("res://demo/humanoid_physics.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("REAL SKIN: " + message)

func frames(count := 4) -> void:
	for _frame in count:
		await process_frame
	await RenderingServer.frame_post_draw

func world_vertices(mesh: MeshInstance3D) -> PackedVector3Array:
	var baked := mesh.bake_mesh_from_current_skeleton_pose()
	var result := PackedVector3Array()
	if baked == null:
		return result
	for surface in baked.get_surface_count():
		for vertex in baked.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			result.append(mesh.global_transform * vertex)
	return result

func max_error(one: PackedVector3Array, two: PackedVector3Array, origin_offset := Vector3.ZERO) -> float:
	if one.size() != two.size() or one.is_empty(): return INF
	var error := 0.0
	for index in one.size(): error = maxf(error, (one[index] - origin_offset).distance_to(two[index]))
	return error

func subtree(skeleton: Skeleton3D, index: int, root_index: int) -> bool:
	while index >= 0:
		if index == root_index: return true
		index = skeleton.get_bone_parent(index)
	return false

func bind_bone(mesh: MeshInstance3D, skeleton: Skeleton3D, bind: int) -> int:
	if mesh.skin == null: return bind
	if bind < 0 or bind >= mesh.skin.get_bind_count(): return -1
	var name := mesh.skin.get_bind_name(bind)
	return skeleton.find_bone(name) if name != &"" else mesh.skin.get_bind_bone(bind)

func rendered_bone_pose(mesh: MeshInstance3D, skeleton: Skeleton3D, bone: int) -> Transform3D:
	var reference := mesh.get_skin_reference()
	for bind in mesh.skin.get_bind_count():
		if bind_bone(mesh, skeleton, bind) == bone:
			return RenderingServer.skeleton_bone_get_transform(reference.get_skeleton(), bind) * mesh.skin.get_bind_pose(bind).affine_inverse()
	return skeleton.get_bone_global_pose(bone)

func vertex_weights(mesh: MeshInstance3D, skeleton: Skeleton3D, root_name: StringName, include_children := true) -> PackedFloat32Array:
	var selected := PackedFloat32Array()
	var root_index := skeleton.find_bone(root_name)
	for surface in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var count := bones.size() / vertices.size()
		for vertex in vertices.size():
			var amount := 0.0
			for influence in count:
				var element := vertex * count + influence
				var index := bind_bone(mesh, skeleton, bones[element])
				if (include_children and subtree(skeleton, index, root_index)) or (not include_children and index == root_index): amount += weights[element]
			selected.append(amount)
	return selected

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Real skin geometry requires a rendered window (can be hidden), not the headless dummy renderer.")
		quit(2)
		return
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.2, 4)
	root.add_child(camera)
	camera.look_at(Vector3(0, 1, 0))
	await test_import_normalization()
	await test_cut_geometry(&"Head")
	await test_cut_geometry(&"LeftArm")
	print("REAL_SKIN_GEOMETRY: checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)

func test_import_normalization() -> void:
	var original: Node3D = Factory.MODEL.instantiate()
	root.add_child(original)
	var original_skeleton: Skeleton3D = Factory.find_type(original, "Skeleton3D")
	var original_mesh: MeshInstance3D = Factory.find_type(original, "MeshInstance3D")
	var normalized: Dictionary = Factory.build(0)
	root.add_child(normalized.actor)
	await frames()
	print("REAL_SKIN_FRAMES original_mesh=", original_mesh.global_transform, " original_skeleton=", original_skeleton.global_transform)
	check(original_skeleton.get_bone_count() == normalized.skeleton.get_bone_count(), "normalization retains bone count")
	check(original_mesh.skin.get_bind_count() == normalized.mesh.skin.get_bind_count(), "normalization retains original Skin slot count")
	var invalid_binds := 0
	var invalid_indices := 0
	var bad_sums := 0
	var zero_weights := 0
	for bind in original_mesh.skin.get_bind_count():
		var old_bone := bind_bone(original_mesh, original_skeleton, bind)
		var new_bone := bind_bone(normalized.mesh, normalized.skeleton, bind)
		if old_bone != new_bone or old_bone < 0: invalid_binds += 1
		if original_skeleton.get_bone_name(old_bone) in [&"Head", &"neck", &"LeftArm", &"Hips"]:
			print("REAL_SKIN_BIND slot=", bind, " name=", original_skeleton.get_bone_name(old_bone), " original=", original_mesh.skin.get_bind_pose(bind), " normalized=", normalized.mesh.skin.get_bind_pose(bind))
	for surface in normalized.mesh.mesh.get_surface_count():
		var arrays: Array = normalized.mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var count := bones.size() / vertices.size()
		for vertex in vertices.size():
			var total := 0.0
			for influence in count:
				var element := vertex * count + influence
				total += weights[element]
				if weights[element] > 0 and (bones[element] < 0 or bones[element] >= normalized.mesh.skin.get_bind_count()): invalid_indices += 1
			if absf(total - 1.0) > 0.001: bad_sums += 1
			if total <= 0.00001: zero_weights += 1
	check(invalid_binds == 0, "normalization preserves all imported bind-to-bone mappings")
	check(invalid_indices == 0 and bad_sums == 0 and zero_weights == 0, "real mesh has valid bind indices and normalized nonzero weights")
	var original_rest := world_vertices(original_mesh)
	var normalized_rest := world_vertices(normalized.mesh)
	# The factory deliberately re-centers the Armature; compare skin deformation
	# after accounting for that one constant origin shift, not by ignoring it.
	var origin_offset: Vector3 = original_mesh.global_position - normalized.mesh.global_position
	var rest_error := max_error(original_rest, normalized_rest, origin_offset)
	print("REAL_SKIN_NORMALIZATION rest_error=", rest_error, " origin_offset=", origin_offset, " vertices=", original_rest.size(), " bad_sums=", bad_sums)
	check(rest_error < 0.002, "original and normalized mesh match in actual rendered rest positions")
	for bone_name in [&"Head", &"LeftArm"]:
		var old_index := original_skeleton.find_bone(bone_name)
		var new_index: int = normalized.skeleton.find_bone(bone_name)
		var old_rotation := original_skeleton.get_bone_pose_rotation(old_index)
		var new_rotation: Quaternion = normalized.skeleton.get_bone_pose_rotation(new_index)
		var rotation := Quaternion(Vector3.FORWARD, 0.5)
		original_skeleton.set_bone_pose_rotation(old_index, old_rotation * rotation)
		normalized.skeleton.set_bone_pose_rotation(new_index, new_rotation * rotation)
		await frames()
		var pose_error := max_error(world_vertices(original_mesh), world_vertices(normalized.mesh), origin_offset)
		print("REAL_SKIN_NORMALIZATION posed_bone=", bone_name, " max_error=", pose_error)
		check(pose_error < 0.003, "normalized real mesh preserves imported animated pose: " + String(bone_name))
		original_skeleton.reset_bone_poses()
		normalized.skeleton.reset_bone_poses()
		await frames()
	original.queue_free()
	normalized.actor.queue_free()
	await frames()

func test_cut_geometry(cut_bone: StringName) -> void:
	var value: Dictionary = Factory.build(0)
	root.add_child(value.actor)
	var authored: Dictionary = Physics.attach(value.skeleton, value.mesh)
	var component: DismembermentComponent = ClassDB.instantiate("DismembermentComponent")
	component.skeleton_path = NodePath("../Skeleton3D")
	component.mesh_path = NodePath("../Skeleton3D/SkinMesh")
	component.pelvis_bone_name = &"Hips"
	component.limb_collision_layer = 8
	component.limb_collision_mask = 0
	value.actor.add_child(component)
	await frames()
	var before := world_vertices(value.mesh)
	check(not before.is_empty(), "rendered actual asset vertex buffer is available: " + String(cut_bone))
	if before.is_empty():
		value.actor.queue_free()
		await frames()
		return
	var selected := vertex_weights(value.mesh, value.skeleton, cut_bone)
	var root_weights := vertex_weights(value.mesh, value.skeleton, cut_bone, false)
	var pure_count := 0
	var mixed_count := 0
	for amount in selected:
		if amount > 0.999: pure_count += 1
		elif amount > 0.001: mixed_count += 1
	print("REAL_SKIN_CUT_COUNTS bone=", cut_bone, " pure=", pure_count, " mixed=", mixed_count)
	check(pure_count > 0, "real asset has fully weighted vertices for " + String(cut_bone))
	component.dismember_limb(cut_bone, Vector3.ZERO)
	await frames()
	var limb: DismemberedLimb = component.get_dismembered_limb_by_name(cut_bone)
	check(is_instance_valid(limb), "real cut creates independent detached limb: " + String(cut_bone))
	if not is_instance_valid(limb):
		value.actor.queue_free()
		await frames()
		return
	var detached: MeshInstance3D = limb.get_meshes()[0]
	var after := world_vertices(value.mesh)
	check(after.size() == before.size(), "real source skin retains expected vertex count after cut")
	var cut_index: int = value.skeleton.find_bone(cut_bone)
	var cut_center: Vector3 = value.skeleton.global_transform * value.skeleton.get_bone_global_pose(cut_index).origin
	var source_pure_radius := 0.0
	for vertex in mini(after.size(), selected.size()):
		if selected[vertex] > 0.999: source_pure_radius = maxf(source_pure_radius, after[vertex].distance_to(cut_center))
	print("REAL_SKIN_SOURCE_AFTER_CUT bone=", cut_bone, " pure_radius=", source_pure_radius)
	check(source_pure_radius < 0.003, "real source fully weighted removed vertices collapse: " + String(cut_bone))
	# Match the FPS path: start the remaining source body ragdoll after cutting.
	# Including Hips is deliberate: this detects recursive simulation APIs that
	# silently restart a supposedly removed physical child.
	var remaining := PackedStringArray()
	for body in authored.bodies:
		if not subtree(value.skeleton, body.get_bone_id(), cut_index): remaining.append(body.bone_name)
	value.skeleton.physical_bones_start_simulation(remaining)
	for body in authored.bodies:
		if body.bone_name in [&"Hips", cut_bone]:
			print("REAL_SKIN_PHYSICS_START bone=", body.bone_name, " sim=", body.is_simulating_physics(), " world=", body.global_position, " velocity=", body.linear_velocity)
	for _step in 60:
		await physics_frame
	await frames()
	for body in authored.bodies:
		if body.bone_name in [&"Hips", cut_bone]:
			print("REAL_SKIN_PHYSICS_AFTER bone=", body.bone_name, " sim=", body.is_simulating_physics(), " world=", body.global_position, " velocity=", body.linear_velocity)
	var moved_source := world_vertices(value.mesh)
	check(moved_source.size() == before.size(), "real source skin remains readable during body ragdoll")
	var source_neck: int = value.skeleton.get_bone_parent(cut_index)
	# SkeletonModifier3D restores the animation pose after applying the ragdoll.
	# The public pose getter can therefore still return rest while the renderer
	# displays a falling body. Derive the pivot from a retained rendered parent.
	var rendered_parent := rendered_bone_pose(value.mesh, value.skeleton, source_neck)
	var expected_cut: Transform3D = rendered_parent * value.skeleton.get_bone_pose(cut_index)
	var expected_center: Vector3 = value.skeleton.global_transform * expected_cut.origin
	var moved_radius := 0.0
	var stale_radius := 0.0
	for vertex in mini(moved_source.size(), selected.size()):
		if selected[vertex] > 0.999:
			moved_radius = maxf(moved_radius, moved_source[vertex].distance_to(expected_center))
			stale_radius = maxf(stale_radius, moved_source[vertex].distance_to(cut_center))
	print("REAL_SKIN_SOURCE_RAGDOLL bone=", cut_bone, " dynamic_pivot_radius=", moved_radius, " original_cut_radius=", stale_radius, " dynamic_cut=", expected_center, " source_cut_pose=", value.skeleton.get_bone_global_pose(cut_index).origin)
	check(moved_radius < 0.01, "removed source vertices follow the moving parent pivot during ragdoll: " + String(cut_bone))
	# Separately prove the rendered detached root follows its actual physical
	# body, rather than floating at the cut while an invisible body falls away.
	var detached_skeleton: Skeleton3D = limb.get_ragdoll_skeleton()
	var physical_root: PhysicalBone3D
	for body in detached_skeleton.find_children("*", "PhysicalBone3D", true, false):
		if body.bone_name == cut_bone:
			physical_root = body
			break
	check(physical_root != null, "detached actual rig has its authored root body: " + String(cut_bone))
	if physical_root != null:
		var physical_bone_world := physical_root.global_transform * physical_root.body_offset.affine_inverse()
		var captured_inverse := limb.get_bone_transform().affine_inverse()
		var detached_vertices := world_vertices(detached)
		var root_vertex_count := 0
		var max_physics_pose_error := 0.0
		var max_complement_radius := 0.0
		var maximum_root_motion := 0.0
		for vertex in mini(detached_vertices.size(), before.size()):
			if root_weights[vertex] > 0.999:
				root_vertex_count += 1
				var expected: Vector3 = physical_bone_world * captured_inverse * before[vertex]
				max_physics_pose_error = maxf(max_physics_pose_error, detached_vertices[vertex].distance_to(expected))
				maximum_root_motion = maxf(maximum_root_motion, detached_vertices[vertex].distance_to(before[vertex]))
			elif selected[vertex] < 0.001:
				max_complement_radius = maxf(max_complement_radius, detached_vertices[vertex].distance_to(physical_bone_world.origin))
		print("REAL_SKIN_DETACHED_RAGDOLL bone=", cut_bone, " root_vertices=", root_vertex_count, " physics_skin_error=", max_physics_pose_error, " complement_radius=", max_complement_radius, " visible_motion=", maximum_root_motion)
		check(root_vertex_count > 0 and max_physics_pose_error < 0.02, "rendered detached root follows the actual physical body: " + String(cut_bone))
		check(max_complement_radius < 0.08, "rendered detached complement stays collapsed around its moving root: " + String(cut_bone))
		check(maximum_root_motion > 0.2, "visible detached root moves independently from its original cut position: " + String(cut_bone))
	component.clean_up_all_referenced_limbs()
	value.actor.queue_free()
	await frames()
