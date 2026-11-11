extends RefCounted
## Minimal weighted mesh with deliberately shuffled Skin binds. The shared mesh
## makes accidental destructive edits visible to the integration tests.

static func make_rig(component_class: String = "DismembermentComponent", eight_weights: bool = false) -> Dictionary:
	var actor := Node3D.new()
	actor.name = "TestActor"
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	actor.add_child(skeleton)
	var bone_names := ["root", "pelvis", "upper", "lower", "hand", "other", "VB_aux"]
	var parents := [-1, 0, 1, 2, 3, 1, 1]
	var offsets := [Vector3.ZERO, Vector3(0, 1, 0), Vector3(.4, .4, 0), Vector3(.5, 0, 0), Vector3(.4, 0, 0), Vector3(-.5, .4, 0), Vector3(0, .2, 0)]
	for index in bone_names.size():
		skeleton.add_bone(bone_names[index])
		skeleton.set_bone_parent(index, parents[index])
		skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, offsets[index]))
	skeleton.reset_bone_poses()
	var bind_order := [3, 1, 5, 2, 0, 4, 6]
	var skin := Skin.new()
	for bone in bind_order:
		skin.add_bind(bone, skeleton.get_bone_global_rest(bone).affine_inverse())
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	var indices := PackedInt32Array()
	var blend_vertices := PackedVector3Array()
	var influenced_bones := [1, 2, 3, 4, 5]
	for bone in influenced_bones:
		var center: Vector3 = skeleton.get_bone_global_rest(bone).origin
		var base := vertices.size()
		for corner in [Vector3(-.11, -.11, 0), Vector3(.11, -.11, 0), Vector3(.11, .11, 0), Vector3(-.11, .11, 0)]:
			vertices.append(center + corner)
			normals.append(Vector3(0, 0, 1))
			uvs.append(Vector2(corner.x + .5, corner.y + .5))
			colors.append(Color(.2, .35, .1, .9))
			blend_vertices.append(Vector3(0, 0, .03))
			var influence_count := 8 if eight_weights else 4
			for slot in influence_count:
				bones.append(bind_order.find(bone) if slot == 0 else 0)
				weights.append(1.0 if slot == 0 else 0.0)
		for triangle_index in [0, 1, 2, 0, 2, 3]:
			indices.append(base + triangle_index)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	arrays[Mesh.ARRAY_INDEX] = indices
	var blend := []
	blend.resize(Mesh.ARRAY_MAX)
	blend[Mesh.ARRAY_VERTEX] = blend_vertices
	# Blend arrays must mirror the base surface's vertex/normal/tangent layout.
	var zero_normals := PackedVector3Array()
	zero_normals.resize(vertices.size())
	blend[Mesh.ARRAY_NORMAL] = zero_normals
	var source_mesh := ArrayMesh.new()
	source_mesh.add_blend_shape("test_morph")
	source_mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	source_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [blend], {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if eight_weights else 0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(.6, .7, .8)
	source_mesh.surface_set_material(0, material)
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = source_mesh
	mesh.skin = skin
	actor.add_child(mesh)
	mesh.skeleton = NodePath("../Skeleton")
	mesh.set_blend_shape_value(0, .4)
	var component: Node = ClassDB.instantiate(component_class)
	component.name = "Dismemberment"
	component.set("limb_rigid_fallback_enabled", true) # explicit convenience path for these synthetic fixtures
	component.set("skeleton_path", NodePath("../Skeleton"))
	component.set("mesh_path", NodePath("../Mesh"))
	component.set("pelvis_bone_name", StringName("pelvis"))
	# Most numerical extraction tests deliberately exercise the optional exact
	# triangle partition mode. The production default is BONE_COLLAPSE (0).
	component.set("geometry_mode", 1)
	actor.add_child(component)
	return {"actor": actor, "skeleton": skeleton, "mesh": mesh, "source_mesh": source_mesh, "skin": skin, "component": component}
