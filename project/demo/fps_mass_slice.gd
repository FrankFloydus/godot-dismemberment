extends RefCounted
## Prepares a batch of randomized slashes while the original bodies remain visible.

signal completed(result: Dictionary)

const PlaneSlicing := preload("res://demo/fps_plane_slicing.gd")
const MAX_ATTEMPTS := 3
const RAGDOLL_ATTEMPTS := 5
const EXTRA_CUT_CHANCE := 0.36
const FRAME_BUDGET_USEC := 9000

var _random := RandomNumberGenerator.new()
var _slicer: PlaneSlicing
var _owned_stages: Array[Dictionary] = []
var _generation := 0
var _running := false


func is_running() -> bool:
	return _running


func start(arena: Node3D, slicer: PlaneSlicing, targets: Array[Dictionary]) -> bool:
	if _running or targets.is_empty() or not arena.is_inside_tree():
		return false
	if not ClassDB.class_has_method(&"MeshPlaneSlice", &"capture_pose_job"):
		return false
	_slicer = slicer
	_generation += 1
	_running = true
	_run.call_deferred(arena, targets, _generation)
	return true


func cancel() -> void:
	_generation += 1
	# A captured worker owns a read-only geometry snapshot. Discard schedules
	# its reap and immediately releases any prepared, unattached fragments.
	for stage in _owned_stages:
		_slicer.discard_whole_slash(stage)
	_owned_stages.clear()
	_slicer = null
	_running = false


func _current(arena: Node3D, generation: int) -> bool:
	return _generation == generation and is_instance_valid(arena) and arena.is_inside_tree()


func _run(arena: Node3D, targets: Array[Dictionary], generation: int) -> void:
	if not _current(arena, generation):
		return
	var tree := arena.get_tree()
	var started := Time.get_ticks_usec()
	var frame_started := started
	var remaining: Array[int] = []
	for index in targets.size():
		remaining.append(index)
	var prepared: Array[Dictionary] = []
	for attempt in RAGDOLL_ATTEMPTS:
		if remaining.is_empty():
			break
		var submitted: Array[Dictionary] = []
		for index in remaining:
			var request := _make_request(targets[index], attempt)
			if request.is_empty():
				continue
			var stage := _slicer.stage_mass_slash(targets, index, request.receiver, request.point, request.plane)
			if stage.get("ok", false):
				submitted.append({"index": index, "stage": stage, "planes": []})
				_owned_stages.append(stage)
			frame_started = await _yield_if_busy(tree, frame_started)
			if not _current(arena, generation):
				return

		var retry: Array[int] = []
		for request in submitted:
			var stage: Dictionary = request.stage
			while not _slicer.is_whole_slash_ready(stage):
				await tree.process_frame
				frame_started = Time.get_ticks_usec()
				if not _current(arena, generation):
					return
			var collected := _slicer.collect_whole_slash(stage, targets)
			if collected.get("ok", false):
				frame_started = await _yield_if_busy(tree, frame_started)
				if not _current(arena, generation):
					return
				var result := _slicer.prepare_whole_slash(stage, targets)
				if result.get("ok", false):
					request.planes.append(stage.world_plane)
					prepared.append(request)
				else:
					retry.append(request.index)
			else:
				retry.append(request.index)
			frame_started = await _yield_if_busy(tree, frame_started)
			if not _current(arena, generation):
				return
		remaining = retry

	# Split selected prepared bodies again while they are still off-tree.
	var recuts: Array[Dictionary] = []
	for request in prepared:
		if _random.randf() >= EXTRA_CUT_CHANCE:
			continue
		var stage: Dictionary = request.stage
		var fragment := _largest_piece(stage.fragments)
		if fragment == null:
			continue
		var visual := fragment.get_node("Mesh") as MeshInstance3D
		var transform := fragment.transform * visual.transform
		var plane := _random_plane(visual.mesh.get_aabb(), transform, 0)
		var recut := _slicer.stage_mass_recut(stage, fragment, plane)
		if recut.get("ok", false):
			recuts.append({"request": request, "recut": recut, "plane": plane})
			_owned_stages.append(recut)
		frame_started = await _yield_if_busy(tree, frame_started)
		if not _current(arena, generation):
			return
	for request in recuts:
		var recut: Dictionary = request.recut
		while not _slicer.is_whole_slash_ready(recut):
			await tree.process_frame
			frame_started = Time.get_ticks_usec()
			if not _current(arena, generation):
				return
		if _slicer.prepare_mass_recut(request.request.stage, recut, targets):
			request.request.planes.append(request.plane)
		frame_started = await _yield_if_busy(tree, frame_started)
		if not _current(arena, generation):
			return

	var stages: Array[Dictionary] = []
	for request in prepared:
		stages.append(request.stage)
	var physics_frame := Engine.get_physics_frames()
	var publishing := Time.get_ticks_usec()
	var results := _slicer.publish_whole_slashes(arena, stages, targets)
	var publish_ms := (Time.get_ticks_usec() - publishing) / 1000.0
	var planes: Array[Plane] = []
	var sliced := 0
	var fragments := 0
	for index in results.size():
		var result: Dictionary = results[index]
		if result.get("ok", false):
			sliced += 1
			fragments += result.fragments.size()
			planes.append_array(prepared[index].planes)
	_owned_stages.clear()
	_slicer = null
	_running = false
	completed.emit({"targets": sliced, "cuts": planes.size(), "fragments": fragments,
		"skipped": targets.size() - sliced, "elapsed_ms": (Time.get_ticks_usec() - started) / 1000.0,
		"publish_ms": publish_ms, "publish_physics_frame": physics_frame, "planes": planes})


func _yield_if_busy(tree: SceneTree, frame_started: int) -> int:
	if Time.get_ticks_usec() - frame_started < FRAME_BUDGET_USEC:
		return frame_started
	await tree.process_frame
	return Time.get_ticks_usec()


func _make_request(target: Dictionary, attempt: int) -> Dictionary:
	if attempt >= MAX_ATTEMPTS and (not target.ragdoll or target.has("plane_slice")):
		return {}
	var source: MeshInstance3D = target.mesh
	var receiver: Node3D
	if target.has("plane_slice"):
		var slice: Dictionary = target.plane_slice
		if slice.fragments.size() >= PlaneSlicing.MAX_FRAGMENTS:
			return {}
		var largest := _largest_piece(slice.fragments)
		var remainder := slice.remainder as MeshInstance3D
		if is_instance_valid(remainder) and (largest == null or remainder.mesh.get_aabb().get_volume() >
				(largest.get_node("Mesh") as MeshInstance3D).mesh.get_aabb().get_volume()):
			source = remainder
			receiver = remainder
		elif largest != null:
			source = largest.get_node("Mesh") as MeshInstance3D
			receiver = largest
		else:
			return {}
	if not is_instance_valid(source) or source.mesh == null:
		return {}
	if target.ragdoll and receiver == null:
		var hips := target.physics_bodies.get(&"Hips") as PhysicalBone3D
		var chest := target.physics_bodies.get(&"Spine") as PhysicalBone3D
		if is_instance_valid(hips) and is_instance_valid(chest):
			var axis := (chest.global_position - hips.global_position).normalized()
			if axis.length_squared() > 0.01:
				var point := hips.global_position.lerp(chest.global_position, 0.25 + 0.15 * mini(attempt, 2))
				var normal := _ragdoll_normal(axis, attempt)
				return {"receiver": receiver, "point": point, "plane": Plane(normal, point)}
	var bounds := source.mesh.get_aabb()
	var transform := source.global_transform
	var plane := _random_plane(bounds, transform, attempt)
	return {"receiver": receiver, "point": plane.project(transform * bounds.get_center()), "plane": plane}


func _ragdoll_normal(axis: Vector3, attempt: int) -> Vector3:
	if attempt < 2:
		return (axis + Vector3(_random.randf_range(-0.18, 0.18), 0,
			_random.randf_range(-0.18, 0.18))).normalized()
	# Folded limbs can form intersecting contours across nearby parallel cuts.
	# Retry with wider oblique angles against the captured pose.
	var reference := Vector3.UP if absf(axis.y) < 0.9 else Vector3.RIGHT
	var tangent := axis.cross(reference).normalized()
	var bitangent := axis.cross(tangent)
	var azimuth := _random.randf_range(-0.2, 0.2) + (attempt - 2) * TAU / 3.0
	var offset := tangent * cos(azimuth) + bitangent * sin(azimuth)
	return (axis * 0.6 + offset).normalized()


func _largest_piece(fragments: Array) -> RigidBody3D:
	var best: RigidBody3D
	var volume := 0.0
	for body: RigidBody3D in fragments:
		if not is_instance_valid(body) or body.is_queued_for_deletion():
			continue
		var visual := body.get_node("Mesh") as MeshInstance3D
		var size := visual.mesh.get_aabb().get_volume()
		if size > volume:
			best = body
			volume = size
	return best


func _random_plane(bounds: AABB, transform: Transform3D, attempt: int) -> Plane:
	var center := bounds.get_center()
	var height := _random.randf_range(0.47, 0.66)
	var tilt := _random.randf_range(0.13, 0.48)
	if attempt == 1:
		height = 0.58
		tilt = 0.08
	elif attempt >= 2:
		height = 0.61
		tilt = 0.0
	center.y = bounds.position.y + bounds.size.y * height
	var azimuth := _random.randf_range(0.0, TAU)
	var normal := Vector3(cos(azimuth) * tilt, 1.0, sin(azimuth) * tilt)
	var basis := transform.basis.inverse().transposed()
	return Plane((basis * normal).normalized(), transform * center)
