extends RefCounted
## Experimental pose-baked slicing. The native component still owns skeletal cuts.

const SliceBones := preload("res://demo/fps_slice_bones.gd")
const SliceInterior := preload("res://demo/fps_slice_interior.gd")
const CutStain := preload("res://demo/fps_cut_stain.gd")
const FRAGMENT_META := &"plane_slice_fragment"
const SLICE_REMAINDER_META := &"plane_slice_remainder"
const SEVERED_BONES_META := &"plane_slice_severed_bones"
const COLLISION_PEERS_META := &"plane_slice_collision_peers"
const STAGED_GENERATION := &"plane_slice_generation"
const EXTRA_SLASH_VELOCITY := &"extra_slash_velocity"
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
	var local_plane := _mesh_local_plane(mesh_transform, world_plane)
	if local_plane.normal == Vector3.ZERO:
		return _failure("The slash did not define a valid cut in mesh space.")

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

	var skeleton: Skeleton3D = null if rigid_piece else target.skeleton
	var missing_bones := PackedStringArray() if rigid_piece else _missing_roots(target)
	var fragments := _prepare_slash_fragments(positive, negative, mesh_transform, target, index, source,
		skeleton, local_plane, missing_bones)
	if fragments.is_empty():
		return _failure("A slash fragment could not make a solid collider.")

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
	_launch_slash_fragments(arena, fragments, positive.size(), normal, linear, angular, old_center, previous_siblings)
	return {"ok": true, "mode": &"fragment" if rigid_piece else &"whole", "target": index, "point": point,
		"loop_count": pieces.loop_count, "remainder": remainder, "fragment": fragments[0], "fragments": fragments}

## Capture one intact standing target on the main thread and submit its geometry.
## A staged cut owns its worker and off-tree bodies until published or discarded.
func stage_whole_slash(hit: Dictionary, targets: Array[Dictionary], world_plane: Plane) -> Dictionary:
	if not ClassDB.class_has_method(&"MeshPlaneSlice", &"capture_pose_job"):
		return _failure("Build the experimental native slicing extension.")
	var collider := hit.get("collider") as Area3D
	var index := int(collider.get_meta(&"target_index", -1)) if collider != null else -1
	if index < 0 or index >= targets.size() or not collider.has_meta(&"bone"):
		return _failure("A staged slash needs an intact standing subject.")
	var target := targets[index]
	if target.ragdoll or target.has("plane_slice") or not target.missing.is_empty():
		return _failure("A staged slash needs an intact standing subject.")
	var point: Vector3 = hit.get("position", Vector3.INF)
	if not point.is_finite() or not world_plane.normal.is_finite() or not is_finite(world_plane.d):
		return _failure("The slash needs a finite plane and contact point.")
	var source: MeshInstance3D = target.mesh
	var skeleton: Skeleton3D = target.skeleton
	var transform := source.global_transform
	var local_plane := _mesh_local_plane(transform, world_plane)
	if local_plane.normal == Vector3.ZERO:
		return _failure("The slash did not define a valid cut in mesh space.")
	var stage := _capture_slash_stage(source, skeleton, local_plane)
	if not stage.ok:
		return stage
	stage.merge({"target": index, "source": source, "mesh": source.mesh, "skeleton": skeleton,
		"pose": SliceBones._capture_poses(source, skeleton), "transform": transform, "point": point,
		"normal": world_plane.normal.normalized(), "plane": local_plane, "cap_material": cap_material,
		"generation": target.get(STAGED_GENERATION, 0)})
	return stage


## Prepare a batch cut against the current body or a registered slice fragment.
func stage_mass_slash(targets: Array[Dictionary], index: int, receiver: Node3D,
		point: Vector3, world_plane: Plane) -> Dictionary:
	if not ClassDB.class_has_method(&"MeshPlaneSlice", &"capture_pose_job"):
		return _failure("Build the experimental native slicing extension.")
	var target := targets[index]
	var source: MeshInstance3D = target.mesh
	var skeleton: Skeleton3D = target.skeleton
	var old_body := receiver as RigidBody3D
	var old_remainder: MeshInstance3D
	if target.has("plane_slice"):
		var slice: Dictionary = target.plane_slice
		if slice.fragments.size() >= MAX_FRAGMENTS:
			return _failure("Fragment limit reached.")
		if old_body != null and slice.fragments.has(old_body):
			source = old_body.get_node("Mesh") as MeshInstance3D
		elif is_instance_valid(slice.remainder) and receiver == slice.remainder:
			old_remainder = receiver as MeshInstance3D
			source = old_remainder
		else:
			return _failure("The fragment has already been cleared.")
		skeleton = null
	elif receiver != null:
		return _failure("The fragment has already been cleared.")

	if not is_instance_valid(source) or not source.is_inside_tree() or source.is_queued_for_deletion():
		return _failure("The target is no longer available.")
	var transform := source.global_transform
	var local_plane := _mesh_local_plane(transform, world_plane)
	if local_plane.normal == Vector3.ZERO:
		return _failure("The slash did not define a valid cut in mesh space.")
	var capture := source
	if skeleton == null:
		# Surface overrides contain per-fragment stains. Capture the actual
		# mesh materials so the recut can transfer its seam data independently.
		capture = MeshInstance3D.new()
		capture.mesh = source.mesh
	var fit_to_pose: bool = skeleton != null and (target.ragdoll or not target.missing.is_empty())
	var collapsed_roots := PackedStringArray()
	if fit_to_pose and target.component.geometry_mode == DismembermentComponent.BONE_COLLAPSE:
		collapsed_roots = _missing_roots(target)
	var stage := _capture_slash_stage(capture, skeleton, local_plane, collapsed_roots, fit_to_pose)
	if capture != source:
		capture.free()
	if not stage.ok:
		return stage
	var motion_body := old_body as PhysicsBody3D
	if target.ragdoll and skeleton != null:
		motion_body = target.physics_bodies.get(&"Hips") as PhysicalBone3D
	stage.merge({"target": index, "source": source, "mesh": source.mesh, "skeleton": skeleton,
		"transform": transform, "point": point, "normal": world_plane.normal.normalized(),
		"plane": local_plane, "world_plane": world_plane, "cap_material": cap_material, "mass": true,
		"fit_to_pose": fit_to_pose, "ragdoll": target.ragdoll,
		"old_body": old_body, "old_remainder": old_remainder, "motion_body": motion_body,
		"motion_transform": motion_body.global_transform if is_instance_valid(motion_body) else Transform3D.IDENTITY,
		"generation": target.get(STAGED_GENERATION, 0)})
	if skeleton != null:
		stage["pose"] = SliceBones._capture_poses(source, skeleton)
	return stage


func _capture_slash_stage(source: MeshInstance3D, skeleton: Skeleton3D, local_plane: Plane,
		collapsed_roots := PackedStringArray(), fit_to_pose := false) -> Dictionary:
	var job := ClassDB.class_call_static(&"MeshPlaneSlice", &"capture_pose_job", source, skeleton,
		local_plane, EPSILON, simplify_fragment_colliders, collapsed_roots, fit_to_pose) as RefCounted
	if job == null:
		return _failure("The posed mesh could not be captured.")
	var task := WorkerThreadPool.add_task(Callable(job, &"compute"), false, "Prepare whole-body slash")
	return {"ok": true, "task": task, "job": job}

func is_whole_slash_ready(stage: Dictionary) -> bool:
	var task := int(stage.get("task", -1))
	return task < 0 or WorkerThreadPool.is_task_completed(task)


## Publish the geometry worker's render resources for one ready stage.
## The caller can yield before building collision bodies for these meshes.
func collect_whole_slash(stage: Dictionary, targets: Array[Dictionary]) -> Dictionary:
	if not stage.get("ok", false) or stage.has("pieces") or stage.has("fragments"):
		return stage
	if not is_whole_slash_ready(stage):
		return _failure("The staged slash is still preparing.")
	var task := int(stage.get("task", -1))
	if task < 0:
		return _failure("The staged slash has already been consumed.")
	WorkerThreadPool.wait_for_task_completion(task)
	stage.erase("task")
	var job: RefCounted = stage.job
	stage.erase("job")
	if not _staged_target_matches(stage, targets):
		return _reject_staged_slash(stage, "The subject changed while the slash was preparing.")
	if stage.get("fit_to_pose", false):
		var local_plane: Plane = job.call(&"get_cut_plane")
		var transform: Transform3D = stage.transform
		var normal := _world_normal(transform, local_plane.normal)
		var world_plane := Plane(normal, transform * (local_plane.normal * local_plane.d))
		stage["plane"] = local_plane
		stage["world_plane"] = world_plane
		stage["normal"] = normal
		stage["point"] = world_plane.project(stage.point)
	var pieces: Dictionary = job.call(&"finish", stage.cap_material)
	var positive: Array = pieces.get("positive_pieces", [])
	var negative: Array = pieces.get("negative_pieces", [])
	if positive.is_empty() or negative.is_empty():
		return _reject_staged_slash(stage, str(pieces.get("error", "The slash did not produce a closed cut.")))
	if _staged_fragment_count(stage, targets) + positive.size() + negative.size() > MAX_FRAGMENTS:
		return _reject_staged_slash(stage, "Fragment limit reached. Press R to restore the subject.")
	stage["pieces"] = pieces
	return stage


## Build one stage's off-tree collision bodies and visuals. The original
## subject remains active until publication.
func prepare_whole_slash(stage: Dictionary, targets: Array[Dictionary]) -> Dictionary:
	if not stage.get("ok", false) or stage.has("fragments"):
		return stage
	if stage.has("pieces"):
		if not _staged_target_matches(stage, targets):
			return _reject_staged_slash(stage, "The subject changed while the slash was preparing.")
	else:
		var collected := collect_whole_slash(stage, targets)
		if not collected.get("ok", false):
			return collected
	var pieces: Dictionary = stage.pieces
	stage.erase("pieces")
	var positive: Array = pieces.positive_pieces
	var negative: Array = pieces.negative_pieces
	var target := targets[int(stage.target)]
	var missing_bones := _missing_roots(target) if stage.skeleton != null else PackedStringArray()
	var poses: Array[Transform3D] = []
	if stage.skeleton != null:
		poses = stage.pose
	var fragments := _prepare_slash_fragments(positive, negative, stage.transform, target, stage.target,
		stage.source, stage.skeleton, stage.plane, missing_bones, pieces, poses)
	if fragments.is_empty():
		return _reject_staged_slash(stage, "A slash fragment could not make a solid collider.")
	if stage.skeleton != null:
		stage["bones"] = SliceBones.capture(target, poses)
	stage["fragments"] = fragments
	stage["positive_count"] = positive.size()
	stage["loop_count"] = pieces.loop_count
	return stage


## Submit a recut of a prepared off-tree fragment. Both cuts publish together.
func stage_mass_recut(stage: Dictionary, body: RigidBody3D, world_plane: Plane) -> Dictionary:
	var source := body.get_node("Mesh") as MeshInstance3D
	var transform := body.transform * source.transform
	var local_plane := _mesh_local_plane(transform, world_plane)
	if local_plane.normal == Vector3.ZERO:
		return _failure("The recut did not define a valid cut in mesh space.")
	var capture := MeshInstance3D.new()
	capture.mesh = source.mesh
	var recut := _capture_slash_stage(capture, null, local_plane)
	capture.free()
	if not recut.ok:
		return recut
	recut.merge({"source": source, "body": body, "transform": transform, "plane": local_plane,
		"cap_material": stage.cap_material, "normal": world_plane.normal.normalized()})
	return recut


func prepare_mass_recut(stage: Dictionary, recut: Dictionary, targets: Array[Dictionary]) -> bool:
	if not recut.get("ok", false) or not is_whole_slash_ready(recut):
		return false
	WorkerThreadPool.wait_for_task_completion(int(recut.task))
	recut.erase("task")
	var job: RefCounted = recut.job
	recut.erase("job")
	if not _staged_target_matches(stage, targets):
		return false
	var pieces: Dictionary = job.call(&"finish", recut.cap_material)
	var positive: Array = pieces.get("positive_pieces", [])
	var negative: Array = pieces.get("negative_pieces", [])
	var fragments: Array[RigidBody3D] = stage.fragments
	if positive.is_empty() or negative.is_empty() or (_staged_fragment_count(stage, targets) +
			fragments.size() - 1 + positive.size() + negative.size() > MAX_FRAGMENTS):
		return false
	var target := targets[int(stage.target)]
	var replacements := _prepare_slash_fragments(positive, negative, recut.transform, target,
		stage.target, recut.source, null, recut.plane, PackedStringArray(), pieces)
	if replacements.is_empty():
		return false
	var old_body: RigidBody3D = recut.body
	var position := fragments.find(old_body)
	fragments.remove_at(position)
	old_body.free()
	for i in replacements.size():
		var body := replacements[i]
		var direction: Vector3 = recut.normal if i < positive.size() else -recut.normal
		body.set_meta(EXTRA_SLASH_VELOCITY, direction * 0.45)
		fragments.insert(position + i, body)
	if position < int(stage.positive_count):
		stage.positive_count += replacements.size() - 1
	stage.loop_count += pieces.loop_count
	return true


func _staged_fragment_count(stage: Dictionary, targets: Array[Dictionary]) -> int:
	var target := targets[int(stage.target)]
	if not target.has("plane_slice"):
		return 0
	return target.plane_slice.fragments.size() - int(is_instance_valid(stage.get("old_body")))


## Publish all prepared subjects in this callback, without yielding a frame or
## physics step between them. Each result matches slash_hit's whole-cut shape.
func publish_whole_slashes(arena: Node3D, stages: Array,
		targets: Array[Dictionary]) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for stage: Dictionary in stages:
		if not stage.get("ok", false):
			results.append(stage)
			continue
		if not stage.has("fragments") or not _staged_target_matches(stage, targets):
			results.append(_reject_staged_slash(stage, "The staged subject or its prepared cut is unavailable."))
			continue
		if _staged_fragment_count(stage, targets) + stage.fragments.size() > MAX_FRAGMENTS:
			results.append(_reject_staged_slash(stage, "Fragment limit reached."))
			continue
		results.append(_publish_staged_slash(arena, stage, targets[int(stage.target)]))
		stage.clear()
	return results


func _publish_staged_slash(arena: Node3D, stage: Dictionary, target: Dictionary) -> Dictionary:
	var fragments: Array[RigidBody3D] = stage.fragments
	var normal: Vector3 = stage.normal
	var point: Vector3 = stage.point
	var linear := Vector3.ZERO
	var angular := Vector3.ZERO
	var center: Vector3 = stage.transform.origin
	var siblings: Array[RigidBody3D] = []
	var old_body := stage.get("old_body") as RigidBody3D
	var remainder := stage.get("old_remainder") as MeshInstance3D
	var motion_body := stage.get("motion_body") as PhysicsBody3D
	var delta := Transform3D.IDENTITY
	if stage.skeleton == null:
		var source: MeshInstance3D = stage.source
		delta = source.global_transform * stage.transform.affine_inverse()
	elif is_instance_valid(motion_body):
		var original: Transform3D = stage.motion_transform
		delta = motion_body.global_transform * original.affine_inverse()
	if not delta.is_equal_approx(Transform3D.IDENTITY):
		for fragment in fragments:
			fragment.transform = delta * fragment.transform
			if fragment.has_meta(EXTRA_SLASH_VELOCITY):
				fragment.set_meta(EXTRA_SLASH_VELOCITY, delta.basis * fragment.get_meta(EXTRA_SLASH_VELOCITY))
		normal = (delta.basis.inverse().transposed() * normal).normalized()
		point = delta * point
	if is_instance_valid(motion_body):
		center = motion_body.global_position
		linear = motion_body.get("linear_velocity")
		angular = motion_body.get("angular_velocity")

	var mode := &"whole"
	if old_body != null or remainder != null:
		mode = &"fragment"
		var state: Dictionary = target.plane_slice
		if old_body != null:
			siblings = _remove_fragment(old_body)
			state.fragments.erase(old_body)
		else:
			siblings.assign(state.fragments)
			var hit_surface := remainder.get_node_or_null("HitSurface") as StaticBody3D
			if hit_surface != null:
				hit_surface.collision_layer = 0
			remainder.hide()
			remainder.queue_free()
			state.remainder = null
		state.fragments.append_array(fragments)
	else:
		_suspend_source(target, null, fragments.duplicate(), stage.bones)
	_launch_slash_fragments(arena, fragments, stage.positive_count, normal, linear, angular, center, siblings)
	return {"ok": true, "mode": mode, "target": stage.target, "point": point,
		"loop_count": stage.loop_count, "remainder": target.plane_slice.remainder,
		"fragment": fragments[0], "fragments": fragments}


func discard_whole_slash(stage: Dictionary) -> void:
	var task := int(stage.get("task", -1))
	if task >= 0:
		_reap_discarded_slash(task, stage.job)
	for fragment in stage.get("fragments", []):
		if is_instance_valid(fragment):
			fragment.free()
	stage.clear()


func _reap_discarded_slash(task: int, _job: RefCounted) -> void:
	# Keep the job alive while its callable may still be running. Cancellation
	# must not block the scene on a worker.
	var tree := Engine.get_main_loop() as SceneTree
	while tree != null and not WorkerThreadPool.is_task_completed(task):
		await tree.process_frame
	WorkerThreadPool.wait_for_task_completion(task)


func _reject_staged_slash(stage: Dictionary, error: String) -> Dictionary:
	discard_whole_slash(stage)
	stage.merge(_failure(error))
	return stage


func _staged_target_matches(stage: Dictionary, targets: Array[Dictionary]) -> bool:
	var index := int(stage.target)
	if index < 0 or index >= targets.size() or not is_instance_valid(stage.source) or stage.cap_material != cap_material:
		return false
	var target := targets[index]
	var source: MeshInstance3D = stage.source
	if target.get(STAGED_GENERATION, 0) != stage.generation or not source.is_inside_tree() \
			or source.is_queued_for_deletion() or source.mesh != stage.mesh:
		return false
	var old_body := stage.get("old_body") as RigidBody3D
	var remainder := stage.get("old_remainder") as MeshInstance3D
	if stage.skeleton == null:
		if not target.has("plane_slice"):
			return false
		if old_body != null:
			return not old_body.is_queued_for_deletion() and target.plane_slice.fragments.has(old_body)
		return remainder == source and target.plane_slice.remainder == source
	if not is_instance_valid(stage.skeleton) or target.mesh != source or target.skeleton != stage.skeleton \
			or target.has("plane_slice") or not source.global_transform.is_equal_approx(stage.transform):
		return false
	if not stage.get("mass", false) and (target.ragdoll or not target.missing.is_empty()):
		return false
	if target.ragdoll or stage.get("ragdoll", false):
		return target.ragdoll == stage.get("ragdoll", false)
	var poses := SliceBones._capture_poses(source, stage.skeleton)
	var previous: Array[Transform3D] = stage.pose
	if poses.size() != previous.size():
		return false
	for bone in poses.size():
		if not poses[bone].is_equal_approx(previous[bone]):
			return false
	return true


func _mesh_local_plane(transform: Transform3D, world_plane: Plane) -> Plane:
	var local_normal := transform.basis.transposed() * world_plane.normal
	var length := local_normal.length()
	if not transform.is_finite() or transform.basis.determinant() == 0.0 \
			or not is_finite(length) or length == 0.0:
		return Plane()
	return Plane(local_normal / length, (world_plane.d - world_plane.normal.dot(transform.origin)) / length)


func _piece_data(pieces: Dictionary, positive_key: StringName, negative_key: StringName) -> Array:
	if pieces.is_empty():
		return []
	var positive: Array = pieces.get(positive_key, [])
	var negative: Array = pieces.get(negative_key, [])
	if positive.size() != pieces.positive_pieces.size() or negative.size() != pieces.negative_pieces.size():
		return []
	return positive + negative


func _prepare_slash_fragments(positive: Array, negative: Array, mesh_transform: Transform3D,
		target: Dictionary, index: int, source: MeshInstance3D, skeleton: Skeleton3D, plane: Plane,
		missing_bones: PackedStringArray, pieces: Dictionary = {},
		poses: Array[Transform3D] = []) -> Array[RigidBody3D]:
	var fragments: Array[RigidBody3D] = []
	var positive_visuals: Array[MeshInstance3D] = []
	var negative_visuals: Array[MeshInstance3D] = []
	var hulls := _piece_data(pieces, &"positive_hulls", &"negative_hulls")
	var caps := _piece_data(pieces, &"positive_cap_arrays", &"negative_cap_arrays")
	var cap_arrays := {}
	for piece: ArrayMesh in positive + negative:
		var hull: PackedVector3Array = hulls[fragments.size()] if not hulls.is_empty() else PackedVector3Array()
		var fragment := _make_fragment(piece, mesh_transform, target.component, index, source, hull)
		if fragment == null:
			for prepared in fragments:
				prepared.free()
			return []
		var visuals := positive_visuals if fragments.size() < positive.size() else negative_visuals
		var visual := fragment.get_node("Mesh") as MeshInstance3D
		if not caps.is_empty():
			cap_arrays[visual] = caps[fragments.size()]
		visuals.append(visual)
		fragments.append(fragment)
	_decorate_cut(source, skeleton, plane, positive_visuals, negative_visuals, missing_bones, false,
		cap_arrays, poses)
	return fragments


func _launch_slash_fragments(arena: Node3D, fragments: Array[RigidBody3D], positive_count: int,
		normal: Vector3, linear := Vector3.ZERO, angular := Vector3.ZERO, old_center := Vector3.ZERO,
		previous_siblings: Array[RigidBody3D] = []) -> void:
	for i in fragments.size():
		var fragment := fragments[i]
		_attach_fragment(arena, fragment)
		# Pieces start with coincident cap faces. Keep sibling contacts out of the solver.
		for j in i:
			_add_fragment_exception(fragment, fragments[j])
		# Recut pieces can still touch an earlier cap while the debris separates.
		_inherit_fragment_exceptions(fragment, previous_siblings)
		var separation := normal if i < positive_count else -normal
		fragment.linear_velocity = linear + angular.cross(fragment.global_position - old_center) + separation * 0.35
		fragment.angular_velocity = angular
		if fragment.has_meta(EXTRA_SLASH_VELOCITY):
			fragment.linear_velocity += fragment.get_meta(EXTRA_SLASH_VELOCITY)
			fragment.remove_meta(EXTRA_SLASH_VELOCITY)


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
		positive: Array, negative: Array, missing_bones := PackedStringArray(), retain_unmatched := false,
		cap_arrays: Dictionary = {}, poses: Array[Transform3D] = []) -> void:
	SliceInterior.apply(source, skeleton, local_plane, positive, negative, cap_material, missing_bones,
		retain_unmatched, cap_arrays, poses)
	for visual: MeshInstance3D in positive + negative:
		cut_stain.apply(visual, source, local_plane, cap_arrays.get(visual, {}))

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
		index: int, source: MeshInstance3D, hull := PackedVector3Array()) -> RigidBody3D:
	# Use a unit-scale rigid frame, while retaining the source visual transform.
	var center := mesh.get_aabb().get_center()
	var body_basis := mesh_transform.basis.orthonormalized()
	if body_basis.determinant() < 0.0:
		body_basis.x = -body_basis.x
	var body_transform := Transform3D(body_basis, mesh_transform * center)
	var local_visual := body_transform.affine_inverse() * mesh_transform
	var shape := _build_fragment_shape(mesh, local_visual, hull)
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

func _build_fragment_shape(mesh: ArrayMesh, local_visual: Transform3D,
		prepared_hull: PackedVector3Array) -> ConvexPolygonShape3D:
	if simplify_fragment_colliders and prepared_hull.size() >= 4 and prepared_hull.size() <= HULL_POINT_BUDGET \
			and local_visual.basis.is_equal_approx(Basis.IDENTITY):
		var prepared_shape := ConvexPolygonShape3D.new()
		prepared_shape.points = local_visual * prepared_hull
		return prepared_shape
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

func _suspend_source(target: Dictionary, remainder: MeshInstance3D, fragments: Array,
		prepared_bones: Dictionary = {}) -> void:
	var skeleton: Skeleton3D = target.skeleton
	var bones := SliceBones.capture(target) if prepared_bones.is_empty() else prepared_bones
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
	target[STAGED_GENERATION] = int(target.get(STAGED_GENERATION, 0)) + 1
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
