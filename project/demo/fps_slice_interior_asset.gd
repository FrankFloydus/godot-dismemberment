extends RefCounted
## Editable hidden volumes authored against the rest pose of the CC0 demo rig.

const INTERIOR := preload("res://demo/rigs/humanoid_slice_interior.tscn")
const BODY_MESH_PATH := "res://demo/assets/humanoid/body_mesh.res"
const SliceBones := preload("res://demo/fps_slice_bones.gd")

static var _layers: Array[Dictionary] = []

static func prepare() -> void:
	if not _layers.is_empty():
		return
	var interior := INTERIOR.instantiate()
	for part: MeshInstance3D in interior.get_children():
		var rest_frame := part.transform
		var scale := rest_frame.basis.get_scale()
		if not part.visible or scale.x < 0.0001 or scale.y < 0.0001 or scale.z < 0.0001:
			continue
		rest_frame.basis = rest_frame.basis.orthonormalized()
		var arrays := part.mesh.surface_get_arrays(0)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		for vertex in positions.size():
			positions[vertex] *= scale
			normals[vertex] = (normals[vertex] / scale).normalized()
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = normals
		# Authored dimensions are baked once so the native cap's UVs remain in metres.
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_name(0, String(part.name))
		mesh.surface_set_material(0, part.material_override)
		_layers.append({
			"name": part.name,
			"bone": part.get_meta(&"bone"),
			"relief": part.get_meta(&"relief"),
			"profile": part.get_meta(&"profile", &"soft"),
			"mesh": mesh,
			"cap_material": part.material_override,
			"rest_frame": rest_frame,
		})
	interior.free()

static func posed_layers(source: MeshInstance3D, skeleton: Skeleton3D) -> Array[Dictionary]:
	var posed: Array[Dictionary] = []
	if source == null or skeleton == null or source.mesh == null:
		return posed
	if not bool(source.get_meta(&"slice_interior_rig", false)) and source.mesh.resource_path != BODY_MESH_PATH:
		return posed
	prepare()
	var poses := SliceBones._capture_poses(source, skeleton)
	var delta_by_bone: Dictionary = {}
	for layer: Dictionary in _layers:
		var bone: StringName = layer.bone
		if not delta_by_bone.has(bone):
			var index := skeleton.find_bone(bone)
			if index < 0:
				continue
			var rest := skeleton.get_bone_global_rest(index)
			delta_by_bone[bone] = poses[index] * rest.affine_inverse()
		var transform: Transform3D = delta_by_bone[bone] * layer.rest_frame
		if not transform.is_finite() or absf(transform.basis.determinant()) < 0.000001:
			continue
		posed.append({
			"name": layer.name,
			"bone": bone,
			"relief": layer.relief,
			"profile": layer.profile,
			"mesh": layer.mesh,
			"cap_material": layer.cap_material,
			"transform": transform,
		})
	return posed
