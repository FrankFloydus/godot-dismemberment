extends RefCounted
## Experimental pose-baked slicing. The native component still owns skeletal cuts.

const SliceBones := preload("res://demo/fps_slice_bones.gd")
const SliceInterior := preload("res://demo/fps_slice_interior.gd")
const CutStain := preload("res://demo/fps_cut_stain.gd")
const FRAGMENT_META := &"plane_slice_fragment"
const SLICE_REMAINDER_META := &"plane_slice_remainder"
const SEVERED_BONES_META := &"plane_slice_severed_bones"
const COLLISION_PEERS_META := &"plane_slice_collision_peers"
const REMAINDER_COLLISION_LAYER := 1 << 1
const MAX_FRAGMENTS := 12
const HULL_POINT_BUDGET := 98
const TILT_STEP := 5.0
const MAX_TILT := 5.0
const EPSILON := 0.000001

var tilt_degrees := 0.0
var cap_material: Material
var simplify_fragment_colliders := true
var cut_stain := CutStain.new()

func prepare() -> void:
	SliceInterior.prepare()

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
	if not (collider is Area3D or collider is PhysicalBone3D) or bone not in [&"LeftForeArm", &"RightForeArm"] or target.missing.has(bone):
		return _failure("The standing prototype accepts forearm hits.")
	if target.ragdoll:
		return _failure("Use a middle-mouse swipe to slice a ragdolled subject.")
	if target.has("plane_slice"):
		return _failure("Swipe across the remaining piece to slice it again.")
	return _slice_standing(arena, target, index, bone, point)

func slash_hit(arena: Node3D, hit: Dictionary, targets: Array[Dictionary], world_plane: Plane) -> Dictionary:
	var collider := hit.get("collider") as Node3D
	var index := int(collider.get_meta(&"target_index", -1)) if collider != null else -1
	if index < 0 or index >= targets.size():
		return _failure("Swipe across a subject or a sliced fragment.")
	var point: Vector3 = hit.get("position", Vector3.INF)
	if not point.is_finite() or not world_plane.normal.is_finite() or not is_finite(world_plane.d):
		return _failure("The slash needs a finite plane and contact point.")

	var target := targets[index]
	var old_body := collider as RigidBody3D if collider.has_meta(FRAGMENT_META) else null
	var hits_remainder := collider is StaticBody3D and collider.has_meta(SLICE_REMAINDER_META)
	var source: MeshInstance3D = target.mesh
	var remainder: MeshInstance3D = null
	var active_fragments: Array = []
	if old_body != null or hits_remainder:
		if not target.has("plane_slice") or collider.is_queued_for_deletion():
			return _failure("The fragment has already been cleared.")
		var state: Dictionary = target.plane_slice
		active_fragments = state.fragments
		remainder = state.remainder
		if hits_remainder:
			if not is_instance_valid(remainder) or remainder.is_queued_for_deletion() or collider.get_parent() != remainder:
				return _failure("The remainder has already been cleared.")
			source = remainder
		else:
			if not active_fragments.has(old_body):
				return _failure("The fragment has already been cleared.")
			source = old_body.get_node("Mesh") as MeshInstance3D
		if active_fragments.size() >= MAX_FRAGMENTS:
			return _failure("Fragment limit reached. Press R to restore the subject.")
	else:
		if not (collider is Area3D or collider is PhysicalBone3D) or not collider.has_meta(&"bone"):
			return _failure("Swipe across a subject or a sliced fragment.")
		if target.has("plane_slice") or target.missing.has(collider.get_meta(&"bone")):
			return _failure("Swipe across the remaining pieces to slice them again.")

	var mesh_transform := source.global_transform
	var local_normal := mesh_transform.basis.transposed() * world_plane.normal
	var normal_length := local_normal.length()
	if not mesh_transform.is_finite() or mesh_transform.basis.determinant() == 0.0 \
			or not is_finite(normal_length) or normal_length == 0.0:
		return _failure("The slash did not define a valid cut in mesh space.")
	var local_plane := Plane(local_normal / normal_length,
		(world_plane.d - world_plane.normal.dot(mesh_transform.origin)) / normal_length)

	var rigid_piece := old_body != null or hits_remainder
	var needs_baked_pose: bool = not rigid_piece and not target.missing.is_empty()
	var method := &"slice_mesh_pieces" if rigid_piece or needs_baked_pose else &"slice_pose"
	if not ClassDB.class_has_method(&"MeshPlaneSlice", method):
		return _failure("Build the experimental native slicing extension.")
	var pieces: Dictionary
	if rigid_piece:
		pieces = ClassDB.class_call_static(&"MeshPlaneSlice", method, source.mesh, local_plane, cap_material, EPSILON)
	elif needs_baked_pose:
		var baked := _snapshot_source(target)
		if baked == null:
			return _failure("The current skinned pose could not be captured.")
		pieces = ClassDB.class_call_static(&"MeshPlaneSlice", method, baked, local_plane, cap_material, EPSILON)
	else:
		pieces = ClassDB.class_call_static(&"MeshPlaneSlice", method, source, target.skeleton, local_plane, cap_material, EPSILON)
	var positive: Array = pieces.get("positive_pieces", [])
	var negative: Array = pieces.get("negative_pieces", [])
	if positive.is_empty() or negative.is_empty():
		return _failure(str(pieces.get("error", "The slash did not produce a closed cut.")))
	var remaining_count := active_fragments.size() - int(old_body != null)
	if remaining_count + positive.size() + negative.size() > MAX_FRAGMENTS:
		return _failure("Fragment limit reached. Press R to restore the subject.")

	var fragments: Array[RigidBody3D] = []
	var positive_visuals: Array[MeshInstance3D] = []
	var negative_visuals: Array[MeshInstance3D] = []
	for piece: ArrayMesh in positive + negative:
		var fragment := _make_fragment(piece, mesh_transform, target.component, index, source)
		if fragment == null:
			for prepared in fragments:
				prepared.free()
			return _failure("A slash fragment could not make a solid collider.")
		var visuals := positive_visuals if fragments.size() < positive.size() else negative_visuals
		visuals.append(fragment.get_node("Mesh") as MeshInstance3D)
		fragments.append(fragment)
	var skeleton: Skeleton3D = null if rigid_piece else target.skeleton
	var missing_bones := PackedStringArray() if rigid_piece else _missing_roots(target)
	_decorate_cut(source, skeleton, local_plane, positive_visuals, negative_visuals, missing_bones)

	# Do not replace the visible mesh or its collision until every body is ready.
	var normal := world_plane.normal.normalized()
	var linear := Vector3.ZERO
	var angular := Vector3.ZERO
	var old_center := mesh_transform.origin
	var previous_siblings: Array[RigidBody3D] = []
	if not rigid_piece:
		if target.ragdoll and collider is PhysicalBone3D:
			linear = collider.linear_velocity
			angular = collider.angular_velocity
			old_center = collider.global_position
		_suspend_source(target, null, fragments.duplicate())
	elif hits_remainder:
		for sibling: RigidBody3D in active_fragments:
			previous_siblings.append(sibling)
		collider.collision_layer = 0
		remainder.hide()
		remainder.queue_free()
		remainder = null
		target.plane_slice.remainder = null
		active_fragments.append_array(fragments)
	else:
		linear = old_body.linear_velocity
		angular = old_body.angular_velocity
		old_center = old_body.global_position
		previous_siblings = _remove_fragment(old_body)
		active_fragments.erase(old_body)
		active_fragments.append_array(fragments)
	for i in fragments.size():
		var fragment := fragments[i]
		_attach_fragment(arena, fragment)
		# Pieces start with coincident cap faces. Keep sibling contacts out of the solver.
		for j in i:
			_add_fragment_exception(fragment, fragments[j])
		# Recut pieces can still touch an earlier cap while the debris separates.
		_inherit_fragment_exceptions(fragment, previous_siblings)
		var separation := normal if i < positive.size() else -normal
		fragment.linear_velocity = linear + angular.cross(fragment.global_position - old_center) + separation * 0.35
		fragment.angular_velocity = angular
	return {"ok": true, "mode": &"fragment" if rigid_piece else &"whole", "target": index, "point": point,
		"loop_count": pieces.loop_count, "remainder": remainder, "fragment": fragments[0], "fragments": fragments}

func sever_shot(arena: Node3D, hit: Dictionary, target: Dictionary, index: int, impulse: Vector3) -> Dictionary:
	if not target.has("plane_slice") or not ClassDB.class_has_method(&"MeshPlaneSlice", &"sever_connected_piece"):
		return {}
	var state: Dictionary = target.plane_slice
	var fragments: Array = state.fragments
	if fragments.size() >= MAX_FRAGMENTS:
		return {}
	var collider := hit.collider as PhysicsBody3D
	if collider == null or collider.is_queued_for_deletion():
		return {}
	var old_fragment := collider as RigidBody3D
	var source: MeshInstance3D
	if old_fragment != null:
		if not fragments.has(old_fragment):
			return {}
		source = old_fragment.get_node("Mesh") as MeshInstance3D
	else:
		source = state.remainder
		if not is_instance_valid(source) or collider.get_parent() != source:
			return {}

	var region := SliceBones.resolve(state.bones, source.to_local(hit.position),
		source.global_basis.inverse() * hit.direction)
	if region.is_empty():
		return {}
	var bone: StringName = region.bone
	var component: GoreComponent = target.component
	var severed: PackedStringArray = source.get_meta(SEVERED_BONES_META, PackedStringArray())
	if String(bone) in severed or component.disable_dismemberment or not component.check_bone_filter(bone):
		return {}
	var local_plane: Plane = region.plane
	var split: Dictionary = ClassDB.class_call_static(&"MeshPlaneSlice", &"sever_connected_piece",
		source.mesh, local_plane, region.seed, cap_material, EPSILON)
	var detached_mesh := split.get("detached_mesh") as ArrayMesh
	var retained_mesh := split.get("retained_mesh") as ArrayMesh
	if detached_mesh == null or retained_mesh == null:
		return {}
	var limb_bounds: AABB = region.bounds
	if not limb_bounds.encloses(detached_mesh.get_aabb()):
		return {}

	var mesh_transform := source.global_transform
	var detached := _make_fragment(detached_mesh, mesh_transform, component, index, source)
	if detached == null:
		return {}
	severed = severed.duplicate()
	severed.append(String(bone))
	var detached_visual := detached.get_node("Mesh") as MeshInstance3D
	detached_visual.set_meta(SEVERED_BONES_META, severed)
	var linear := Vector3.ZERO
	var angular := Vector3.ZERO
	var center := mesh_transform.origin
	if old_fragment != null:
		var retained := _make_fragment(retained_mesh, mesh_transform, component, index, source)
		if retained == null:
			detached.free()
			return {}
		var retained_visual := retained.get_node("Mesh") as MeshInstance3D
		retained_visual.set_meta(SEVERED_BONES_META, severed)
		_decorate_cut(source, null, local_plane, [detached_visual], [retained_visual], PackedStringArray(), true)
		linear = old_fragment.linear_velocity
		angular = old_fragment.angular_velocity
		center = old_fragment.global_position
		var siblings := _remove_fragment(old_fragment)
		fragments.erase(old_fragment)
		_attach_fragment(arena, retained)
		_attach_fragment(arena, detached)
		_add_fragment_exception(retained, detached)
		_inherit_fragment_exceptions(retained, siblings)
		_inherit_fragment_exceptions(detached, siblings)
		retained.linear_velocity = linear + angular.cross(retained.global_position - center)
		retained.angular_velocity = angular
		fragments.append(retained)
	else:
		var retained := _make_remainder(retained_mesh, index, source)
		if retained == null:
			detached.free()
			return {}
		retained.set_meta(SEVERED_BONES_META, severed)
		_decorate_cut(source, null, local_plane, [detached_visual], [retained], PackedStringArray(), true)
		collider.collision_layer = 0
		source.hide()
		source.queue_free()
		target.actor.add_child(retained)
		retained.global_transform = mesh_transform
		retained.reset_physics_interpolation()
		state.remainder = retained
		_attach_fragment(arena, detached)
	detached.linear_velocity = linear + angular.cross(detached.global_position - center) + impulse
	detached.angular_velocity = angular
	fragments.append(detached)
	return {"bone": bone, "limb": detached}

func _snapshot_source(target: Dictionary) -> ArrayMesh:
	if target.missing.is_empty() or target.component.geometry_mode != DismembermentComponent.BONE_COLLAPSE:
		return ClassDB.class_call_static(&"MeshPartition", &"snapshot_pose", target.mesh, target.skeleton) as ArrayMesh
	return ClassDB.class_call_static(&"MeshPartition", &"snapshot_pose",
		target.mesh, target.skeleton, _missing_roots(target)) as ArrayMesh

func _missing_roots(target: Dictionary) -> PackedStringArray:
	var roots := target.component.get_dismembered_bones() as PackedStringArray
	roots.append_array(PackedStringArray(target.missing.keys()))
	return roots

func _decorate_cut(source: MeshInstance3D, skeleton: Skeleton3D, local_plane: Plane,
		positive: Array, negative: Array, missing_bones := PackedStringArray(), retain_unmatched := false) -> void:
	SliceInterior.apply(source, skeleton, local_plane, positive, negative, cap_material, missing_bones, retain_unmatched)
	for visual: MeshInstance3D in positive:
		cut_stain.apply(visual, source, local_plane)
	for visual: MeshInstance3D in negative:
		cut_stain.apply(visual, source, local_plane)

func _slice_standing(arena: Node3D, target: Dictionary, index: int, bone: StringName, point: Vector3) -> Dictionary:
	var source: MeshInstance3D = target.mesh
	var baked := _snapshot_source(target)
	if baked == null:
		return _failure("The current skinned pose could not be captured.")
	var mesh_transform := source.global_transform
	var local_normal := _local_normal()
	var local_plane := Plane(local_normal, source.to_local(point))
	var halves := _cut(baked, local_plane)
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
	var remainder := _make_remainder(keep, index, source)
	if remainder == null:
		fragment.free()
		return _failure("The remaining piece could not make a hit surface.")
	var detached_visual := fragment.get_node("Mesh") as MeshInstance3D
	var positive := detached_visual if positive_distal else remainder
	var negative := remainder if positive_distal else detached_visual
	_decorate_cut(source, target.skeleton, local_plane, [positive], [negative], _missing_roots(target))

	target.actor.add_child(remainder)
	remainder.global_transform = mesh_transform
	remainder.reset_physics_interpolation()
	_suspend_source(target, remainder, [fragment])
	_attach_fragment(arena, fragment)
	var outward := _world_normal(mesh_transform, local_normal)
	if not positive_distal:
		outward = -outward
	fragment.linear_velocity = outward * 0.35 + Vector3.UP * 0.08
	return {"ok": true, "mode": &"standing", "target": index, "point": point,
		"loop_count": halves.loop_count, "remainder": remainder, "fragment": fragment, "fragments": [fragment]}

func _make_remainder(mesh: ArrayMesh, index: int, source: MeshInstance3D) -> MeshInstance3D:
	var shape := mesh.create_trimesh_shape()
	if shape == null:
		return null
	var remainder := MeshInstance3D.new()
	remainder.name = "PlaneSliceRemainder"
	remainder.mesh = mesh
	remainder.layers = source.layers
	remainder.cast_shadow = source.cast_shadow
	remainder.gi_mode = source.gi_mode
	if source.has_meta(SEVERED_BONES_META):
		remainder.set_meta(SEVERED_BONES_META, source.get_meta(SEVERED_BONES_META))

	# This pose-baked surface is only for hit queries, like the standing hitboxes.
	var body := StaticBody3D.new()
	body.name = "HitSurface"
	body.collision_layer = REMAINDER_COLLISION_LAYER
	body.collision_mask = 0
	body.set_meta(&"target_index", index)
	body.set_meta(SLICE_REMAINDER_META, true)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	remainder.add_child(body)
	return remainder

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
	var local_plane := Plane(local_normal, visual.to_local(point))
	var halves := _cut(visual.mesh, local_plane)
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
	_decorate_cut(visual, null, local_plane, [positive.get_node("Mesh")], [negative.get_node("Mesh")])

	var world_normal := _world_normal(mesh_transform, local_normal)
	var linear := body.linear_velocity
	var angular := body.angular_velocity
	var old_center := body.global_position
	var siblings := _remove_fragment(body)
	fragments.erase(body)
	_attach_fragment(arena, positive)
	_attach_fragment(arena, negative)
	# Siblings share the cap at spawn. Keep those coincident faces out of the solver.
	_add_fragment_exception(positive, negative)
	_inherit_fragment_exceptions(positive, siblings)
	_inherit_fragment_exceptions(negative, siblings)
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
	# Use a unit-scale rigid frame, while retaining the source visual transform.
	var center := mesh.get_aabb().get_center()
	var body_basis := mesh_transform.basis.orthonormalized()
	if body_basis.determinant() < 0.0:
		body_basis.x = -body_basis.x
	var body_transform := Transform3D(body_basis, mesh_transform * center)
	var local_visual := body_transform.affine_inverse() * mesh_transform
	var shape := _build_fragment_shape(mesh, local_visual)
	if shape == null:
		return null

	var body := RigidBody3D.new()
	body.name = "PlaneSliceFragment"
	body.transform = body_transform
	body.mass = clampf(mesh.get_aabb().get_volume() * 220.0, 0.12, 1.6)
	body.collision_layer = component.limb_collision_layer
	body.collision_mask = component.limb_collision_mask
	body.add_to_group("Dismembered Limb")
	body.set_meta(&"target_index", index)
	body.set_meta(FRAGMENT_META, true)
	var collision_peers: Array[int] = []
	body.set_meta(COLLISION_PEERS_META, collision_peers)

	var visual := MeshInstance3D.new()
	visual.name = "Mesh"
	visual.mesh = mesh
	visual.transform = local_visual
	visual.layers = source.layers
	visual.cast_shadow = source.cast_shadow
	visual.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	if source.has_meta(SEVERED_BONES_META):
		visual.set_meta(SEVERED_BONES_META, source.get_meta(SEVERED_BONES_META))
	body.add_child(visual)
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	collision.shape = shape
	body.add_child(collision)
	return body

func _build_fragment_shape(mesh: ArrayMesh, local_visual: Transform3D) -> ConvexPolygonShape3D:
	var can_simplify := simplify_fragment_colliders and ClassDB.class_has_method(&"MeshPlaneSlice", &"reduce_collision_hull")
	if can_simplify:
		var points := PackedVector3Array()
		for surface in mesh.get_surface_count():
			points.append_array(mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX])
		if points.size() > HULL_POINT_BUDGET:
			# Directional extrema are already present in the mesh vertices.
			# Sample those before asking the physics server to build the hull.
			var sampled := ClassDB.class_call_static(&"MeshPlaneSlice", &"reduce_collision_hull",
				local_visual * points) as PackedVector3Array
			if sampled.size() >= 4 and sampled.size() <= HULL_POINT_BUDGET:
				var reduced_shape := ConvexPolygonShape3D.new()
				reduced_shape.points = sampled
				return reduced_shape
	var shape := mesh.create_convex_shape(true, false)
	if shape == null or shape.points.size() < 4:
		return null
	var hull := local_visual * shape.points
	if can_simplify:
		hull = ClassDB.class_call_static(&"MeshPlaneSlice", &"reduce_collision_hull", hull)
	shape.points = hull
	return shape

func _attach_fragment(arena: Node3D, fragment: RigidBody3D) -> void:
	var world_transform := fragment.transform
	fragment.tree_exiting.connect(_unlink_fragment_exceptions.bind(fragment), CONNECT_ONE_SHOT)
	arena.add_child(fragment, true)
	fragment.global_transform = world_transform
	fragment.reset_physics_interpolation()

func _suspend_source(target: Dictionary, remainder: MeshInstance3D, fragments: Array) -> void:
	var skeleton: Skeleton3D = target.skeleton
	var bones := SliceBones.capture(target)
	if target.ragdoll:
		skeleton.physical_bones_stop_simulation()
	var physics_layers := {}
	for body: PhysicalBone3D in target.physics_bodies.values():
		physics_layers[body] = body.collision_layer
		body.collision_layer = 0
	target["plane_slice"] = {
		"remainder": remainder,
		"fragments": fragments,
		"skeleton_visible": skeleton.visible,
		"physics_layers": physics_layers,
		"bones": bones,
	}
	skeleton.hide()

func _add_fragment_exception(first: RigidBody3D, second: RigidBody3D) -> void:
	var first_peers: Array[int] = first.get_meta(COLLISION_PEERS_META)
	var second_id := second.get_instance_id()
	if second_id in first_peers:
		return
	var second_peers: Array[int] = second.get_meta(COLLISION_PEERS_META)
	first_peers.append(second_id)
	second_peers.append(first.get_instance_id())
	first.add_collision_exception_with(second)
	second.add_collision_exception_with(first)

func _inherit_fragment_exceptions(fragment: RigidBody3D, peers: Array[RigidBody3D]) -> void:
	for peer in peers:
		if is_instance_valid(peer) and not peer.is_queued_for_deletion():
			_add_fragment_exception(fragment, peer)

func _unlink_fragment_exceptions(fragment: RigidBody3D) -> Array[RigidBody3D]:
	# Remove both directions while the physics bodies still exist.
	var live_peers: Array[RigidBody3D] = []
	var peer_ids: Array[int] = fragment.get_meta(COLLISION_PEERS_META)
	var fragment_id := fragment.get_instance_id()
	for peer_id in peer_ids:
		var peer := instance_from_id(peer_id) as RigidBody3D
		if peer == null:
			continue
		var reciprocal: Array[int] = peer.get_meta(COLLISION_PEERS_META)
		reciprocal.erase(fragment_id)
		peer.remove_collision_exception_with(fragment)
		fragment.remove_collision_exception_with(peer)
		if not peer.is_queued_for_deletion():
			live_peers.append(peer)
	peer_ids.clear()
	return live_peers

func _remove_fragment(fragment: RigidBody3D) -> Array[RigidBody3D]:
	var peers := _unlink_fragment_exceptions(fragment)
	fragment.collision_layer = 0
	fragment.hide()
	fragment.queue_free()
	return peers

func clear_fragments(target: Dictionary) -> void:
	if not target.has("plane_slice"):
		return
	var fragments: Array = target.plane_slice.fragments
	for fragment: RigidBody3D in fragments:
		if is_instance_valid(fragment):
			_remove_fragment(fragment)
	fragments.clear()

func restore(target: Dictionary) -> void:
	if not target.has("plane_slice"):
		return
	clear_fragments(target)
	var state: Dictionary = target.plane_slice
	var remainder: MeshInstance3D = state.remainder
	if is_instance_valid(remainder):
		var hit_surface := remainder.get_node_or_null("HitSurface") as StaticBody3D
		if hit_surface != null:
			hit_surface.collision_layer = 0
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
