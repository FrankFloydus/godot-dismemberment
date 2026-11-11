extends SceneTree

var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func near(actual: Vector3, expected: Vector3, message: String) -> void:
	check(actual.distance_to(expected) < 0.003, "%s: actual=%s expected=%s" % [message, actual, expected])

func make_mesh(eight_weights: bool, relative: bool) -> ArrayMesh:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var indices := PackedInt32Array()
	for triangle in 4:
		for corner in 3:
			var index := triangle * 3 + corner
			positions.append(Vector3(0.1 + triangle * 0.4 + (0.1 if corner == 1 else 0.0), 0.1 if corner == 2 else 0.0, 0.0))
			normals.append(Vector3.BACK)
			tangents.append_array(PackedFloat32Array([1, 0, 0, 1]))
			colors.append(Color(float(index) / 12.0, 0.2, 0.3, 1.0))
			uvs.append(Vector2(index / 12.0, 0.4))
			indices.append(index)
			# Skin bind 0 is Arm, bind 1 is Pelvis: intentionally reversed
			# from Skeleton3D indices. Eight-weight vertices split their full
			# weight across slots 0 and 4 to exercise the second four slots.
			var bind := 1 if triangle < 2 else 0
			for influence in (8 if eight_weights else 4):
				bones.append(bind)
				weights.append((0.4 if influence == 0 else (0.6 if influence == 4 else 0.0)) if eight_weights else (1.0 if influence == 0 else 0.0))
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices
	var shape: Array = []
	shape.resize(Mesh.ARRAY_MAX)
	var shape_positions := PackedVector3Array()
	var shape_normals := PackedVector3Array()
	var shape_tangents := PackedFloat32Array()
	for index in positions.size():
		shape_positions.append(Vector3(0, 0, 0.4) if relative else positions[index] + Vector3(0, 0, 0.4))
		shape_normals.append(Vector3.ZERO if relative else normals[index])
		shape_tangents.append_array(PackedFloat32Array([0, 0, 0, 1]) if relative else PackedFloat32Array([1, 0, 0, 1]))
	shape[Mesh.ARRAY_VERTEX] = shape_positions
	shape[Mesh.ARRAY_NORMAL] = shape_normals
	shape[Mesh.ARRAY_TANGENT] = shape_tangents
	var mesh := ArrayMesh.new()
	mesh.add_blend_shape("Inflate")
	mesh.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE if relative else Mesh.BLEND_SHAPE_MODE_NORMALIZED
	var blend_arrays: Array[Array] = [shape]
	var flags := Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if eight_weights else 0
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, blend_arrays, {5.0: PackedInt32Array([0, 1, 2, 6, 7, 8])}, flags)
	return mesh

func _run() -> void:
	check(ClassDB.class_exists("MeshPartition"), "MeshPartition is registered")
	if failures:
		quit(1)
		return
	for eight_weights in [false, true]:
		for relative in [false, true]:
			for named_binds in [false, true]:
				await run_case(eight_weights, relative, named_binds)
	print("MeshPartition checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)

func run_case(eight_weights: bool, relative: bool, named_binds: bool) -> void:
	var label := "%s weights / %s blend / %s binds" % [8 if eight_weights else 4, "relative" if relative else "normalized", "named" if named_binds else "indexed"]
	var container := Node3D.new()
	root.add_child(container)
	container.position = Vector3(4, 2, -3)
	container.rotate_y(0.3)
	var skeleton := Skeleton3D.new()
	container.add_child(skeleton)
	skeleton.add_bone("Pelvis")
	skeleton.add_bone("Arm")
	skeleton.add_bone("Hand")
	skeleton.set_bone_parent(1, 0)
	skeleton.set_bone_parent(2, 1)
	skeleton.set_bone_rest(0, Transform3D.IDENTITY)
	skeleton.set_bone_rest(1, Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)))
	skeleton.set_bone_rest(2, Transform3D(Basis.IDENTITY, Vector3(0.5, 0, 0)))
	skeleton.reset_bone_poses()
	var instance := MeshInstance3D.new()
	container.add_child(instance)
	instance.position = Vector3(0.3, 0.1, 0.2)
	instance.mesh = make_mesh(eight_weights, relative)
	instance.skeleton = instance.get_path_to(skeleton)
	var skin := Skin.new()
	skin.set_bind_count(2)
	if named_binds:
		skin.set_bind_name(0, "Arm")
	else:
		skin.set_bind_bone(0, 1)
	skin.set_bind_pose(0, Transform3D(Basis.IDENTITY, Vector3(-0.7, 0.1, 0.2)))
	if named_binds:
		skin.set_bind_name(1, "Pelvis")
	else:
		skin.set_bind_bone(1, 0)
	skin.set_bind_pose(1, instance.transform)
	instance.skin = skin
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.8, 0.1, 0.2)
	instance.set_surface_override_material(0, material)
	instance.set_blend_shape_value(0, 0.5)
	skeleton.set_bone_pose_position(1, Vector3(1, 1, 0))
	skeleton.set_bone_pose_scale(1, Vector3(2, 1, 1))
	await process_frame
	var source: ArrayMesh = instance.mesh
	var original_arrays := source.surface_get_arrays(0)
	var original_positions: PackedVector3Array = original_arrays[Mesh.ARRAY_VERTEX]
	var cut: Dictionary = MeshPartition.isolate_limb(instance, skeleton, "Arm", 0.5, true)
	check(not cut.has("error"), label + " partitions successfully")
	check(cut.detached_triangle_count == 2 and cut.remaining_triangle_count == 2, label + " partitions each triangle exactly once")
	var remaining: ArrayMesh = cut.remaining_mesh
	var detached: ArrayMesh = cut.detached_mesh
	check(remaining.get_surface_count() == 1 and detached.get_surface_count() == 1, label + " retains surfaces")
	if remaining.get_surface_count() != 1 or detached.get_surface_count() != 1:
		container.queue_free()
		await process_frame
		return
	var detached_arrays := detached.surface_get_arrays(0)
	var remaining_arrays := remaining.surface_get_arrays(0)
	var detached_positions: PackedVector3Array = detached_arrays[Mesh.ARRAY_VERTEX]
	check(detached_positions.size() == 6, label + " removes unused vertices from detached bounds")
	check((remaining_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() == 6, label + " removes unused vertices from remaining bounds")
	check(detached_arrays[Mesh.ARRAY_BONES] == null and detached_arrays[Mesh.ARRAY_WEIGHTS] == null, label + " baked detached mesh has no skin")
	check(remaining.get_blend_shape_count() == 1 and detached.get_blend_shape_count() == 0, label + " remaining blend shape remains live; detached blend is baked")
	check(remaining.surface_get_material(0) == material and detached.surface_get_material(0) == material, label + " uses active material override")
	for index in detached_positions.size():
		var original := original_positions[index + 6]
		# Reversed named bind, translated mesh, arm X scale 2, arm Y
		# translation 1, and half-weight 0.4 m Z morph, calculated explicitly.
		var expected := Vector3(2 * original.x - 0.7, original.y + 1, original.z + 0.2)
		near(detached_positions[index], expected, label + " baked posed/morphed vertex %d" % index)
	var detached_colors: PackedColorArray = detached_arrays[Mesh.ARRAY_COLOR]
	var detached_uvs: PackedVector2Array = detached_arrays[Mesh.ARRAY_TEX_UV]
	check(absf(detached_colors[0].r - 0.5) < 0.01, label + " colors follow compact vertex mapping")
	check(detached_uvs[0].distance_to(Vector2(0.5, 0.4)) < 0.002, label + " UVs follow compact vertex mapping")
	var normals: PackedVector3Array = detached_arrays[Mesh.ARRAY_NORMAL]
	near(normals[0], Vector3.BACK, label + " inverse transpose normals")
	var detached_lods := MeshPartition.get_surface_lods(detached, 0)
	var remaining_lods := MeshPartition.get_surface_lods(remaining, 0)
	check(detached_lods.size() == 1 and remaining_lods.size() == 1, label + " preserves LOD levels")
	if detached_lods.size() == 1:
		check((detached_lods.values()[0] as PackedInt32Array) == PackedInt32Array([0, 1, 2]), label + " remaps LOD indices")
	check(source.surface_get_array_len(0) == 12, label + " shared source mesh remains unchanged")
	var unbaked: Dictionary = MeshPartition.isolate_limb(instance, skeleton, "Arm", 0.5, false)
	check(unbaked.detached_mesh.get_blend_shape_count() == 1, label + " optional unbaked output retains blends")
	container.queue_free()
	await process_frame
