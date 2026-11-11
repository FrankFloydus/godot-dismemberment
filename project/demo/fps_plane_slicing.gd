extends RefCounted
## Experimental pose-baked slicing. The native component still owns skeletal cuts.

const FRAGMENT_META := &"plane_slice_fragment"
const MAX_FRAGMENTS := 12
const TILT_STEP := 5.0
const MAX_TILT := 5.0
const EPSILON := 0.000001

var tilt_degrees := 0.0
var cap_material := StandardMaterial3D.new()

func _init() -> void:
	cap_material.albedo_color = Color(0.28, 0.045, 0.038)
	cap_material.roughness = 0.84

func adjust_tilt(step: float) -> void:
	tilt_degrees = clampf(tilt_degrees + step, -MAX_TILT, MAX_TILT)

func slice_hit(arena: Node3D, hit: Dictionary, targets: Array[Dictionary]) -> Dictionary:
	if not ClassDB.class_has_method(&"MeshPartition", &"snapshot_pose") or not ClassDB.class_exists(&"MeshPlaneSlice"):
		return _failure("Build the experimental native slicing extension.")
	var collider := hit.get("collider") as Node3D
	if collider == null:
		return _failure("Aim at an intact forearm or a sliced fragment.")
	var index := int(collider.get_meta(&"target_index", -1))
	if index < 0 or index >= targets.size():
		return _failure("Aim at an intact forearm or a sliced fragment.")
	var target := targets[index]
	var point: Vector3 = hit.position
	if collider is RigidBody3D and collider.has_meta(FRAGMENT_META):
		return _slice_fragment(arena, target, index, collider, point)
	var bone: StringName = collider.get_meta(&"bone", &"")
	if not (collider is Area3D or collider is PhysicalBone3D) or bone not in [&"LeftForeArm", &"RightForeArm"]:
		return _failure("The standing prototype accepts forearm hits.")
	if target.ragdoll or not target.missing.is_empty() or target.has("plane_slice"):
		return _failure("Press R to restore this subject before slicing.")
	return _slice_standing(arena, target, index, bone, point)

func _slice_standing(arena: Node3D, target: Dictionary, index: int, bone: StringName, point: Vector3) -> Dictionary:
	var source: MeshInstance3D = target.mesh
	var skeleton: Skeleton3D = target.skeleton
	var baked := ClassDB.class_call_static(&"MeshPartition", &"snapshot_pose", source, skeleton) as ArrayMesh
	if baked == null:
		return _failure("The current skinned pose could not be captured.")
	var mesh_transform := source.global_transform
	var local_normal := _local_normal()
	var halves := _cut(baked, Plane(local_normal, source.to_local(point)))
	if not halves.ok:
		return halves

	# The normalized CC0 rig's left hand is on +X and right hand on -X.
	var positive_distal := bone == &"LeftForeArm"
	var piece: ArrayMesh = halves.positive_mesh if positive_distal else halves.negative_mesh
	var keep: ArrayMesh = halves.negative_mesh if positive_distal else halves.positive_mesh
	if piece.get_aabb().size.length() >= keep.get_aabb().size.length():
		return _failure("That plane does not isolate the outer forearm. Adjust the aim or tilt.")
	var fragment := _make_fragment(piece, mesh_transform, target.component, index, source)
	if fragment == null:
		return _failure("The cut fragment could not make a solid collider.")

	var remainder := MeshInstance3D.new()
	remainder.name = "PlaneSliceRemainder"
	remainder.mesh = keep
	remainder.layers = source.layers
	remainder.cast_shadow = source.cast_shadow
	remainder.gi_mode = source.gi_mode
	target.actor.add_child(remainder)
	remainder.global_transform = mesh_transform
	remainder.reset_physics_interpolation()
	var physics_layers := {}
	for body: PhysicalBone3D in target.physics_bodies.values():
		physics_layers[body] = body.collision_layer
		body.collision_layer = 0
	target["plane_slice"] = {
		"remainder": remainder,
		"fragments": [fragment],
		"skeleton_visible": skeleton.visible,
		"physics_layers": physics_layers,
	}
	skeleton.hide()
	_attach_fragment(arena, fragment)
	var outward := _world_normal(mesh_transform, local_normal)
	if not positive_distal:
		outward = -outward
	fragment.linear_velocity = outward * 0.35 + Vector3.UP * 0.08
	return {"ok": true, "mode": &"standing", "target": index, "point": point,
		"loop_count": halves.loop_count, "remainder": remainder, "fragment": fragment, "fragments": [fragment]}

func _slice_fragment(arena: Node3D, target: Dictionary, index: int, body: RigidBody3D, point: Vector3) -> Dictionary:
	if not target.has("plane_slice"):
		return _failure("The fragment has already been cleared.")
	var state: Dictionary = target.plane_slice
	var fragments: Array = state.fragments
	if not fragments.has(body) or body.is_queued_for_deletion():
		return _failure("The fragment has already been cleared.")
	if fragments.size() >= MAX_FRAGMENTS:
		return _failure("Fragment limit reached. Press R to restore the subject.")
	var visual := body.get_node("Mesh") as MeshInstance3D
	var mesh_transform := visual.global_transform
	var local_normal := _local_normal()
	var halves := _cut(visual.mesh, Plane(local_normal, visual.to_local(point)))
	if not halves.ok:
		return halves
	var positive := _make_fragment(halves.positive_mesh, mesh_transform, target.component, index, visual)
	var negative := _make_fragment(halves.negative_mesh, mesh_transform, target.component, index, visual)
	if positive == null or negative == null:
		if positive != null:
			positive.free()
		if negative != null:
			negative.free()
		return _failure("That fragment cut did not create two solid colliders.")

	var world_normal := _world_normal(mesh_transform, local_normal)
	var linear := body.linear_velocity
	var angular := body.angular_velocity
	var old_center := body.global_position
	body.collision_layer = 0
	body.hide()
	body.queue_free()
	fragments.erase(body)
	_attach_fragment(arena, positive)
	_attach_fragment(arena, negative)
	# Siblings share the cap at spawn. Keep those coincident faces out of the solver.
	positive.add_collision_exception_with(negative)
	negative.add_collision_exception_with(positive)
	positive.linear_velocity = linear + angular.cross(positive.global_position - old_center) + world_normal * 0.2
	negative.linear_velocity = linear + angular.cross(negative.global_position - old_center) - world_normal * 0.2
	positive.angular_velocity = angular
	negative.angular_velocity = angular
	fragments.append_array([positive, negative])
	return {"ok": true, "mode": &"fragment", "target": index, "point": point,
		"loop_count": halves.loop_count, "remainder": state.remainder, "fragment": positive, "fragments": [positive, negative]}

func _cut(mesh: Mesh, local_plane: Plane) -> Dictionary:
	var result: Dictionary = ClassDB.class_call_static(&"MeshPlaneSlice", &"slice_mesh",
		mesh, local_plane, cap_material, EPSILON)
	var positive := result.get("positive_mesh") as ArrayMesh
	var negative := result.get("negative_mesh") as ArrayMesh
	if positive == null or negative == null:
		return _failure(str(result.get("error", "The plane did not produce a closed cut.")))
	if result.get("loop_count", 0) != 1:
		return _failure("This prototype accepts one closed cut loop. Adjust the aim or tilt.")
	return {"ok": true, "positive_mesh": positive, "negative_mesh": negative, "loop_count": 1}

func _make_fragment(mesh: ArrayMesh, mesh_transform: Transform3D, component: GoreComponent,
		index: int, source: MeshInstance3D) -> RigidBody3D:
	var shape := mesh.create_convex_shape(true, false)
	if shape == null or shape.points.size() < 4:
		return null
	# Use a unit-scale rigid frame, while retaining the source visual transform.
	var center := mesh.get_aabb().get_center()
	var body_transform := Transform3D(mesh_transform.basis.orthonormalized(), mesh_transform * center)
	var local_visual := body_transform.affine_inverse() * mesh_transform
	var points := shape.points
	for i in points.size():
		points[i] = local_visual * points[i]
	shape.points = points

	var body := RigidBody3D.new()
	body.name = "PlaneSliceFragment"
	body.transform = body_transform
	body.mass = clampf(mesh.get_aabb().get_volume() * 220.0, 0.12, 1.6)
	body.collision_layer = component.limb_collision_layer
	body.collision_mask = component.limb_collision_mask
	body.add_to_group("Dismembered Limb")
	body.set_meta(&"target_index", index)
	body.set_meta(FRAGMENT_META, true)

	var visual := MeshInstance3D.new()
	visual.name = "Mesh"
	visual.mesh = mesh
	visual.transform = local_visual
	visual.layers = source.layers
	visual.cast_shadow = source.cast_shadow
	visual.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	body.add_child(visual)
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = shape
	body.add_child(collision)
	return body

func _attach_fragment(arena: Node3D, fragment: RigidBody3D) -> void:
	var world_transform := fragment.transform
	arena.add_child(fragment, true)
	fragment.global_transform = world_transform
	fragment.reset_physics_interpolation()

func clear_fragments(target: Dictionary) -> void:
	if not target.has("plane_slice"):
		return
	var fragments: Array = target.plane_slice.fragments
	for fragment: RigidBody3D in fragments:
		if is_instance_valid(fragment):
			fragment.collision_layer = 0
			fragment.hide()
			fragment.queue_free()
	fragments.clear()

func restore(target: Dictionary) -> void:
	if not target.has("plane_slice"):
		return
	clear_fragments(target)
	var state: Dictionary = target.plane_slice
	var remainder: MeshInstance3D = state.remainder
	if is_instance_valid(remainder):
		remainder.hide()
		remainder.queue_free()
	for body: PhysicalBone3D in state.physics_layers:
		if is_instance_valid(body):
			body.collision_layer = state.physics_layers[body]
	target.skeleton.visible = state.skeleton_visible
	target.erase("plane_slice")

func _local_normal() -> Vector3:
	return Vector3.RIGHT.rotated(Vector3.BACK, deg_to_rad(tilt_degrees))

func _world_normal(mesh_transform: Transform3D, local_normal: Vector3) -> Vector3:
	return (mesh_transform.basis.inverse().transposed() * local_normal).normalized()

func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
