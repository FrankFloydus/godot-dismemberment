extends RefCounted
## Original procedural demonstration rigs. The mesh is weighted to a real
## Skeleton3D and Skin; there are no pre-authored detached limb meshes.

static func build(kind: int) -> Dictionary:
	var actor := Node3D.new()
	actor.name = "ProceduralSubject"
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	actor.add_child(skeleton)
	var spec: Array = _humanoid() if kind != 1 else _crawler()
	var globals: Array[Vector3] = []
	for item in spec:
		var index: int = skeleton.get_bone_count()
		skeleton.add_bone(item[0])
		skeleton.set_bone_parent(index, item[1])
		var parent_position := Vector3.ZERO if item[1] < 0 else globals[item[1]]
		skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, item[2] - parent_position))
		globals.append(item[2])
	skeleton.reset_bone_poses()
	var skin := Skin.new()
	for index in spec.size():
		skin.add_bind(index, Transform3D(Basis.IDENTITY, globals[index]).affine_inverse())
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var indices := PackedInt32Array()
	for index in range(1, spec.size()):
		var item: Array = spec[index]
		var endpoint: Vector3 = item[3]
		var radius: float = item[4]
		var tint := Color(0.52, 0.72, 0.78) if kind == 0 else Color(0.80, 0.58, 0.31)
		if kind == 2:
			tint = Color(0.69, 0.59, 0.85)
		if "left" in str(item[0]):
			tint = tint.lightened(0.13)
		_add_segment(globals[index], endpoint, radius, index, tint,
			positions, normals, uvs, colors, bones, weights, indices)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = false
	material.albedo_color = Color(0.52, 0.72, 0.78) if kind == 0 else Color(0.80, 0.58, 0.31)
	if kind == 2:
		material.albedo_color = Color(0.69, 0.59, 0.85)
	material.roughness = 0.36
	material.metallic = 0.23
	mesh.surface_set_material(0, material)
	var instance := MeshInstance3D.new()
	instance.name = "SkinMesh"
	instance.mesh = mesh
	instance.skin = skin
	instance.skeleton = NodePath("..")
	instance.add_to_group("Dismemberment Source", true)
	skeleton.add_child(instance)
	if kind == 2:
		var socket := BoneAttachment3D.new()
		socket.name = "HeldBeacon"
		socket.bone_name = "hand_right"
		skeleton.add_child(socket)
		var prop := MeshInstance3D.new()
		prop.name = "TransferableBeacon"
		prop.add_to_group("Transfer Dismemberment", true)
		var prop_mesh := BoxMesh.new()
		prop_mesh.size = Vector3(0.14, 0.48, 0.14)
		prop.mesh = prop_mesh
		prop.position = Vector3(0, 0.18, 0)
		var prop_mat := StandardMaterial3D.new()
		prop_mat.albedo_color = Color(1, 0.53, 0.13)
		prop_mat.emission_enabled = true
		prop_mat.emission = Color(0.7, 0.16, 0.02)
		prop.material_override = prop_mat
		socket.add_child(prop)
	return {"actor": actor, "skeleton": skeleton, "mesh": instance, "bones": spec}

static func _add_segment(a: Vector3, b: Vector3, radius: float, bone: int, tint: Color,
		vertices: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array,
		colors: PackedColorArray, bones: PackedInt32Array, weights: PackedFloat32Array,
		indices: PackedInt32Array) -> void:
	var direction := (b - a).normalized()
	if direction.length_squared() < 0.5:
		direction = Vector3.UP
	var axis := Vector3.FORWARD if abs(direction.dot(Vector3.UP)) > 0.96 else Vector3.UP
	var side := direction.cross(axis).normalized()
	var up := direction.cross(side).normalized()
	var sides := 16
	var start := vertices.size()
	for row in 2:
		for column in sides:
			var angle: float = TAU * column / sides
			var normal := side * cos(angle) + up * sin(angle)
			vertices.append((a if row == 0 else b) + normal * radius)
			normals.append(normal)
			uvs.append(Vector2(float(column) / sides, row))
			colors.append(Color(1, 1, 0, 1))
			bones.append_array(PackedInt32Array([bone, 0, 0, 0]))
			weights.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]))
	for column in sides:
		var nxt: int = (column + 1) % sides
		indices.append_array(PackedInt32Array([start + column, start + sides + column,
			start + nxt, start + nxt, start + sides + column, start + sides + nxt]))
	# End caps are generated in the same surface and carry the same bone weights.
	for row in 2:
		var center := vertices.size()
		vertices.append(a if row == 0 else b)
		normals.append(-direction if row == 0 else direction)
		uvs.append(Vector2(0.5, 0.5))
		colors.append(Color(1, 1, 0, 1))
		bones.append_array(PackedInt32Array([bone, 0, 0, 0]))
		weights.append_array(PackedFloat32Array([1.0, 0.0, 0.0, 0.0]))
		for column in sides:
			var first: int = start + row * sides + column
			var next: int = start + row * sides + (column + 1) % sides
			indices.append_array(PackedInt32Array([center, first, next] if row == 0 else [center, next, first]))

static func _humanoid() -> Array:
	return [
		["root", -1, Vector3.ZERO, Vector3.ZERO, 0.0],
		["pelvis", 0, Vector3(0, 1.35, 0), Vector3(0, 1.57, 0), 0.27],
		["spine", 1, Vector3(0, 1.57, 0), Vector3(0, 1.93, 0), 0.27],
		["chest", 2, Vector3(0, 1.93, 0), Vector3(0, 2.18, 0), 0.35],
		["neck", 3, Vector3(0, 2.18, 0), Vector3(0, 2.35, 0), 0.12],
		["head", 4, Vector3(0, 2.35, 0), Vector3(0, 2.72, 0), 0.23],
		["upper_arm_left", 3, Vector3(-0.39, 2.06, 0), Vector3(-0.91, 1.91, 0), 0.14],
		["lower_arm_left", 6, Vector3(-0.91, 1.91, 0), Vector3(-1.35, 1.7, 0), 0.115],
		["hand_left", 7, Vector3(-1.35, 1.7, 0), Vector3(-1.57, 1.62, 0), 0.14],
		["upper_arm_right", 3, Vector3(0.39, 2.06, 0), Vector3(0.91, 1.91, 0), 0.14],
		["lower_arm_right", 9, Vector3(0.91, 1.91, 0), Vector3(1.35, 1.7, 0), 0.115],
		["hand_right", 10, Vector3(1.35, 1.7, 0), Vector3(1.57, 1.62, 0), 0.14],
		["thigh_left", 1, Vector3(-0.2, 1.3, 0), Vector3(-0.25, 0.72, 0), 0.18],
		["shin_left", 12, Vector3(-0.25, 0.72, 0), Vector3(-0.25, 0.16, 0), 0.135],
		["foot_left", 13, Vector3(-0.25, 0.16, 0), Vector3(-0.25, 0.13, 0.3), 0.16],
		["thigh_right", 1, Vector3(0.2, 1.3, 0), Vector3(0.25, 0.72, 0), 0.18],
		["shin_right", 15, Vector3(0.25, 0.72, 0), Vector3(0.25, 0.16, 0), 0.135],
		["foot_right", 16, Vector3(0.25, 0.16, 0), Vector3(0.25, 0.13, 0.3), 0.16]]

static func _crawler() -> Array:
	var result: Array = [
		["root", -1, Vector3.ZERO, Vector3.ZERO, 0.0],
		["pelvis", 0, Vector3(0, 1.0, -0.45), Vector3(0, 1.0, 0.0), 0.4],
		["body", 1, Vector3(0, 1.0, 0), Vector3(0, 1.0, 0.7), 0.45],
		["head", 2, Vector3(0, 1.0, 0.7), Vector3(0, 1.0, 1.1), 0.28],
		["tail", 1, Vector3(0, 1.0, -0.45), Vector3(0, 1.1, -1.2), 0.17]]
	for side in [-1, 1]:
		for leg in 3:
			var z: float = -0.45 + leg * 0.48
			var prefix := "left" if side < 0 else "right"
			var parent: int = result.size()
			var hip := Vector3(side * 0.32, 1.0, z)
			var knee := Vector3(side * 0.95, 0.65, z)
			var toe := Vector3(side * 1.3, 0.08, z + 0.15)
			result.append(["%s_leg_%d" % [prefix, leg + 1], 2, hip, knee, 0.105])
			result.append(["%s_tip_%d" % [prefix, leg + 1], parent, knee, toe, 0.075])
	return result
