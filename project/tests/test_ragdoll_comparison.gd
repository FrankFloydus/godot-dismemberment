extends SceneTree
## Controlled actual-asset comparison. Run with a real rendering window; hidden
## OpenGL is sufficient. All cases use the same camera, lighting and floor.

const Factory = preload("res://demo/realistic_rig.gd")
const AuthoredPhysics = preload("res://demo/humanoid_physics.gd")
var camera: Camera3D
var output_directory := ProjectSettings.globalize_path("res://").path_join("../work/ragdoll-comparison").simplify_path()
var reports: Array[Dictionary] = []
var failures: Array[String] = []
var checks := 0

func require(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("RAGDOLL COMPARISON: " + message)

func _initialize() -> void:
	run.call_deferred()

func frames(count := 4) -> void:
	for _frame in count: await process_frame
	await RenderingServer.frame_post_draw

func find_type(node: Node, type_name: String) -> Node:
	if node.is_class(type_name): return node
	for child in node.get_children():
		var value := find_type(child, type_name)
		if value != null: return value
	return null

func posed(mesh: MeshInstance3D) -> PackedVector3Array:
	var baked := mesh.bake_mesh_from_current_skeleton_pose()
	var result := PackedVector3Array()
	if baked:
		for surface in baked.get_surface_count():
			for vertex in baked.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
				result.append(mesh.global_transform * vertex)
	return result

func edges(mesh: MeshInstance3D) -> PackedInt32Array:
	var result := PackedInt32Array()
	var offset := 0
	for surface in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var count := vertices.size() if indices.is_empty() else indices.size()
		for triangle in count / 3:
			var points: Array[int] = []
			for corner in 3: points.append((triangle * 3 + corner if indices.is_empty() else indices[triangle * 3 + corner]) + offset)
			for pair in [[0,1],[1,2],[2,0]]:
				result.append(points[pair[0]])
				result.append(points[pair[1]])
		offset += vertices.size()
	return result

func edge_metrics(before: PackedVector3Array, after: PackedVector3Array, pairs: PackedInt32Array) -> Dictionary:
	var maximum_before := 0.0
	var maximum_after := 0.0
	var maximum_ratio := 0.0
	var count_over_two := 0
	var count_over_five := 0
	var count_over_ten := 0
	var worst: Array[Dictionary] = []
	for pair in pairs.size() / 2:
		var a := pairs[pair * 2]
		var b := pairs[pair * 2 + 1]
		var original := before[a].distance_to(before[b])
		var current := after[a].distance_to(after[b])
		maximum_before = maxf(maximum_before, original)
		maximum_after = maxf(maximum_after, current)
		if original < 0.0001: continue
		var ratio := current / original
		maximum_ratio = maxf(maximum_ratio, ratio)
		if ratio > 2: count_over_two += 1
		if ratio > 5: count_over_five += 1
		if ratio > 10: count_over_ten += 1
		if worst.size() < 8 or current > worst[-1].current:
			worst.append({"a": a, "b": b, "rest": original, "current": current, "ratio": ratio})
			worst.sort_custom(func(one, two): return one.current > two.current)
			if worst.size() > 8: worst.resize(8)
	return {"rest_max_edge": maximum_before, "posed_max_edge": maximum_after, "max_edge_ratio": maximum_ratio,
		"edges_over_2x": count_over_two, "edges_over_5x": count_over_five, "edges_over_10x": count_over_ten, "worst_edges": worst}

func bind_bone(mesh: MeshInstance3D, skeleton: Skeleton3D, bind: int) -> int:
	var name := mesh.skin.get_bind_name(bind)
	return skeleton.find_bone(name) if name != &"" else mesh.skin.get_bind_bone(bind)

func palette_pose(mesh: MeshInstance3D, skeleton: Skeleton3D, bone: int) -> Transform3D:
	var reference := mesh.get_skin_reference()
	for bind in mesh.skin.get_bind_count():
		if bind_bone(mesh, skeleton, bind) == bone:
			return skeleton.global_transform * RenderingServer.skeleton_bone_get_transform(reference.get_skeleton(), bind) * mesh.skin.get_bind_pose(bind).affine_inverse()
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone)

func physical_palette_errors(mesh: MeshInstance3D, skeleton: Skeleton3D, bodies: Array) -> Array[Dictionary]:
	var physical: Dictionary = {}
	for body in bodies:
		if body.get_bone_id() >= 0: physical[body.get_bone_id()] = body
	var result: Array[Dictionary] = []
	for bone in skeleton.get_bone_count():
		var body_index := bone
		var chain: Array[int] = []
		while body_index >= 0 and not physical.has(body_index):
			chain.push_front(body_index)
			body_index = skeleton.get_bone_parent(body_index)
		if body_index < 0: continue
		var body: PhysicalBone3D = physical[body_index]
		var expected := body.global_transform * body.body_offset.affine_inverse()
		for child in chain: expected *= skeleton.get_bone_pose(child)
		var actual := palette_pose(mesh, skeleton, bone)
		var basis_error := maxf(maxf(actual.basis.x.distance_to(expected.basis.x), actual.basis.y.distance_to(expected.basis.y)), actual.basis.z.distance_to(expected.basis.z))
		result.append({"bone": skeleton.get_bone_name(bone), "physical": physical.has(bone), "ancestor": skeleton.get_bone_name(body_index),
			"position_error": actual.origin.distance_to(expected.origin), "basis_error": basis_error,
			"actual": str(actual.origin), "expected": str(expected.origin)})
	result.sort_custom(func(one, two): return one.position_error + one.basis_error > two.position_error + two.basis_error)
	return result

func vertex_influences(mesh: MeshInstance3D, skeleton: Skeleton3D, target: int) -> Dictionary:
	var offset := 0
	for surface in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if target >= offset + vertices.size():
			offset += vertices.size()
			continue
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var count := bones.size() / vertices.size()
		var result := {}
		for influence in count:
			var index := (target - offset) * count + influence
			if weights[index] > 0.00001:
				var bone := bind_bone(mesh, skeleton, bones[index])
				result[skeleton.get_bone_name(bone)] = weights[index]
		return result
	return {}

func setup_environment() -> Node3D:
	var scene := Node3D.new()
	root.add_child(scene)
	current_scene = scene
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.light_energy = 1.1
	light.shadow_enabled = true
	scene.add_child(light)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.12, 0.14, 0.17)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color.WHITE
	settings.ambient_light_energy = 0.5
	environment.environment = settings
	scene.add_child(environment)
	var floor := StaticBody3D.new()
	floor.collision_layer = 1
	scene.add_child(floor)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 0.2, 20)
	collision.shape = box
	collision.position.y = -0.1
	floor.add_child(collision)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	floor_mesh.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.32, 0.35)
	material.roughness = 0.85
	floor_mesh.material_override = material
	scene.add_child(floor_mesh)
	camera = Camera3D.new()
	camera.position = Vector3(2.8, 2.0, 3.8)
	camera.fov = 48
	scene.add_child(camera)
	camera.look_at(Vector3(0, 0.85, 0))
	return scene

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Ragdoll comparison requires actual rendered skin; run hidden OpenGL, not dummy headless.")
		quit(2)
		return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="): output_directory = argument.trim_prefix("--output=")
	output_directory = ProjectSettings.globalize_path(output_directory).simplify_path()
	var directory_error := DirAccess.make_dir_recursive_absolute(output_directory)
	if directory_error != OK:
		push_error("Cannot create comparison output directory: " + output_directory)
		quit(1)
		return
	var probe: Node3D = Factory.MODEL.instantiate()
	var player: AnimationPlayer = find_type(probe, "AnimationPlayer")
	var clips := PackedStringArray()
	if player:
		print("RAGDOLL_ORIGINAL_ANIMATIONS ", player.get_animation_list())
		for clip in player.get_animation_list():
			if "walk" in clip.to_lower() or "run" in clip.to_lower(): clips.append(clip)
	probe.free()
	if clips.is_empty(): clips.append("")
	for clip in clips: await run_case("A_original_" + (clip if not clip.is_empty() else "rest"), true, false, clip)
	await run_case("B_physics_no_component", false, false)
	await run_case("C_physics_component_no_cut", false, true)
	await run_reset_cycles()
	var report_file := FileAccess.open(output_directory.path_join("comparison.json"), FileAccess.WRITE)
	if report_file == null:
		push_error("Cannot write comparison report: " + output_directory)
		quit(1)
		return
	report_file.store_string(JSON.stringify(reports, "  "))
	print("RAGDOLL_COMPARISON_DONE cases=", reports.size(), " output=", output_directory)
	require(reports.size() == clips.size() + 11, "all controlled animation/physics/reset/sequential cases completed")
	print("RAGDOLL_COMPARISON_CHECKS=", checks, " FAILURES=", failures.size())
	quit(0 if failures.is_empty() else 1)

func run_case(label: String, original: bool, component_enabled: bool, animation := "") -> void:
	var scene := setup_environment()
	var actor: Node3D
	var skeleton: Skeleton3D
	var mesh: MeshInstance3D
	var bodies: Array = []
	if original:
		actor = Factory.MODEL.instantiate()
		scene.add_child(actor)
		skeleton = find_type(actor, "Skeleton3D")
		mesh = find_type(actor, "MeshInstance3D")
	else:
		var value: Dictionary = Factory.build(0)
		actor = value.actor
		skeleton = value.skeleton
		mesh = value.mesh
		scene.add_child(actor)
		actor.position.y = 0.06
		bodies = AuthoredPhysics.attach(skeleton, mesh).bodies
		if component_enabled:
			var component: Node3D = ClassDB.instantiate("GoreComponent")
			component.skeleton_path = NodePath("../Skeleton3D")
			component.mesh_path = NodePath("../Skeleton3D/SkinMesh")
			component.pelvis_bone_name = &"Hips"
			actor.add_child(component)
	await frames()
	var before := posed(mesh)
	var pairs := edges(mesh)
	if original and not animation.is_empty():
		var player: AnimationPlayer = find_type(actor, "AnimationPlayer")
		player.play(animation)
	else:
		if not original: skeleton.physical_bones_start_simulation()
	for _tick in Engine.physics_ticks_per_second * 3: await physics_frame
	await frames()
	var after := posed(mesh)
	var metrics := edge_metrics(before, after, pairs)
	require(metrics.posed_max_edge < 0.2, label + " keeps actual skin edges below 20 cm")
	for edge in metrics.worst_edges:
		edge["weights_a"] = vertex_influences(mesh, skeleton, edge.a)
		edge["weights_b"] = vertex_influences(mesh, skeleton, edge.b)
	var bone_errors: Array = physical_palette_errors(mesh, skeleton, bodies) if not original else []
	var screenshot := output_directory.path_join(label.validate_filename() + ".png")
	var error := root.get_texture().get_image().save_png(screenshot)
	if error != OK:
		failures.append("Cannot save comparison image: " + screenshot)
		push_error(failures[-1])
	var report := {"case": label, "animation": animation, "vertices": before.size(), "metrics": metrics, "bone_palette_errors": bone_errors,
		"screenshot": screenshot, "screenshot_error": error}
	reports.append(report)
	print("RAGDOLL_CASE ", JSON.stringify(report))
	scene.queue_free()
	await frames()

func start_remaining(skeleton: Skeleton3D, bodies: Array, component: Node) -> void:
	var names: Array[StringName] = []
	var removed: PackedStringArray = component.get_dismembered_bones()
	for body in bodies:
		if not is_instance_valid(body): continue
		var name: StringName = body.bone_name
		var bone := skeleton.find_bone(name)
		if bone < 0: continue
		var missing := false
		for removed_name in removed:
			var ancestor := bone
			while ancestor >= 0:
				if skeleton.get_bone_name(ancestor) == removed_name:
					missing = true
					break
				ancestor = skeleton.get_bone_parent(ancestor)
		if not missing: names.append(name)
	skeleton.physical_bones_start_simulation(names)

func record_state(label: String, mesh: MeshInstance3D, skeleton: Skeleton3D, bodies: Array,
		baseline: PackedVector3Array, pairs: PackedInt32Array, component: Node) -> void:
	await frames()
	var current := posed(mesh)
	var metrics := edge_metrics(baseline, current, pairs)
	var maximum_rest_error := 0.0
	for vertex in mini(current.size(), baseline.size()): maximum_rest_error = maxf(maximum_rest_error, current[vertex].distance_to(baseline[vertex]))
	var limb_metrics: Array[Dictionary] = []
	for limb in component.get_all_dismembered_limbs():
		for piece in limb.get_meshes():
			var vertices := posed(piece)
			if vertices.size() == baseline.size():
				limb_metrics.append({"bone": String(limb.bone_name), "metrics": edge_metrics(baseline, vertices, pairs)})
	var screenshot := output_directory.path_join(label + ".png")
	var error := root.get_texture().get_image().save_png(screenshot)
	if error != OK:
		failures.append("Cannot save comparison image: " + screenshot)
		push_error(failures[-1])
	var head := skeleton.find_bone("Head")
	var neck := skeleton.find_bone("neck")
	var expected_head := palette_pose(mesh, skeleton, neck) * skeleton.get_bone_pose(head)
	var head_anchor_error := palette_pose(mesh, skeleton, head).origin.distance_to(expected_head.origin)
	require(metrics.posed_max_edge < 0.2, label + " keeps cut/reset skin edges below 20 cm")
	require(head_anchor_error < 0.1, label + " keeps restored head joint attached to its rendered neck")
	if "reset_pose" in label: require(maximum_rest_error < 0.002, label + " restores actual rendered rest positions")
	var report := {"case": label, "vertices": current.size(), "metrics": metrics,
		"bone_palette_errors": physical_palette_errors(mesh, skeleton, bodies), "rest_position_error": maximum_rest_error if "reset_pose" in label else null,
		"max_displacement_from_rest": maximum_rest_error,
		"head_anchor_error": head_anchor_error, "detached": limb_metrics, "screenshot": screenshot, "screenshot_error": error}
	reports.append(report)
	print("RAGDOLL_CASE ", JSON.stringify(report))

func run_reset_cycles() -> void:
	var scene := setup_environment()
	var value: Dictionary = Factory.build(0)
	scene.add_child(value.actor)
	value.actor.position.y = 0.06
	var bodies: Array = AuthoredPhysics.attach(value.skeleton, value.mesh).bodies
	var component: Node3D = ClassDB.instantiate("GoreComponent")
	component.skeleton_path = NodePath("../Skeleton3D")
	component.mesh_path = NodePath("../Skeleton3D/SkinMesh")
	component.pelvis_bone_name = &"Hips"
	component.enable_blood_particles = false
	component.enable_blood_pool_decal = false
	value.actor.add_child(component)
	await frames()
	var baseline := posed(value.mesh)
	var pairs := edges(value.mesh)
	for cycle in 3:
		var cut: StringName = [&"Head", &"Head", &"LeftArm"][cycle]
		component.dismember_limb(cut, Vector3(0.4, 0.2, 0))
		await frames()
		start_remaining(value.skeleton, bodies, component)
		for _tick in Engine.physics_ticks_per_second * 3: await physics_frame
		await record_state("R%d_%s_ragdoll" % [cycle + 1, cut], value.mesh, value.skeleton, bodies, baseline, pairs, component)
		# This is the exact R-key ordering in the FPS demo, deliberately reusing
		# the same Skeleton, PhysicalBone nodes, meshes, Skin and native component.
		component.reset_all_limbs()
		value.skeleton.physical_bones_stop_simulation()
		value.skeleton.clear_bones_global_pose_override()
		value.skeleton.reset_bone_poses()
		await record_state("R%d_reset_pose" % [cycle + 1], value.mesh, value.skeleton, bodies, baseline, pairs, component)
	# Additional shots while the same remaining body is already ragdolled must
	# not convert an earlier zero-scale missing-bone palette into singular poses.
	# Use a marker-only particle override to inspect a burst's world transform.
	var marker := Node3D.new()
	var burst_scene := PackedScene.new()
	var pack_result := burst_scene.pack(marker)
	marker.free()
	require(pack_result == OK, "moving-source burst test scene packs")
	component.override_blood_particles = true
	component.fx_blood_burst = burst_scene
	for step in 3:
		var cut: StringName = [&"Head", &"LeftArm", &"LeftLeg"][step]
		var visible_cut_position: Vector3
		component.enable_blood_particles = step == 1
		if step == 1:
			var bone_index: int = value.skeleton.find_bone(cut)
			var stale_position: Vector3 = value.skeleton.global_transform * value.skeleton.get_bone_global_pose(bone_index).origin
			visible_cut_position = palette_pose(value.mesh, value.skeleton, bone_index).origin
			require(visible_cut_position.distance_to(stale_position) > 0.1,
				"the moving source test has distinct rendered and animation cut positions")
		component.dismember_limb(cut, Vector3(0.2, 0.1, 0))
		if step == 1:
			var burst := scene.get_node_or_null("BloodBurst") as Node3D
			require(burst != null and burst.global_position.distance_to(visible_cut_position) < 0.001,
				"a cut on the moving source spawns blood at the rendered bone pose")
		await frames()
		if step == 0: start_remaining(value.skeleton, bodies, component)
		for _tick in Engine.physics_ticks_per_second: await physics_frame
		await record_state("S%d_%s_already_ragdolled" % [step + 1, cut], value.mesh, value.skeleton, bodies, baseline, pairs, component)
	component.clean_up_all_referenced_limbs()
	scene.queue_free()
	await frames()
