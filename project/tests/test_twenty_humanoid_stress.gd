extends SceneTree
## Same-frame slash, shotgun sever, and radial blast on 20 authored rigs.
## Run this scene-tree script with the renderer, Dummy audio and VSync disabled.

const DEMO := "res://demo/demo.tscn"
const TARGET_COUNT := 20
const WAIST_HEIGHT := 1.04
const BLAST_SPEED := 3.2
const BLAST_LIFT := 0.85
const FRAGMENT_GROUP := &"Dismembered Limb"
const INTERIOR_GROUP := &"slice_interior_visual"
const STAINS_META := &"plane_slice_stains"

var arena: Node3D
var checks := 0
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _expect(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		push_error("TWENTY_HUMANOID_STRESS: " + message)
	return condition


func _prepare_range() -> void:
	arena = load(DEMO).instantiate()
	var stations := arena.get_node("Stations") as Node3D
	var original := stations.get_node("Humanoid") as Node3D
	for station in stations.get_children():
		if station != original:
			station.free()
	for index in TARGET_COUNT:
		var station := original if index == 0 else original.duplicate() as Node3D
		if index != 0:
			station.name = "Humanoid%02d" % (index + 1)
			stations.add_child(station)
		var row := floori(index / 5.0)
		var stagger := -0.36 if row % 2 == 0 else 0.36
		station.position = Vector3((index % 5 - 2) * 2.15 + stagger, 0.0, -6.8 + row * 2.0)

	root.add_child(arena)
	current_scene = arena
	arena.testing = true
	arena.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	arena.get_node("HUD").hide()
	arena.weapon.hide()
	var camera := Camera3D.new()
	camera.fov = 76.0
	arena.add_child(camera)
	camera.position = Vector3(0.0, 3.95, 4.75)
	camera.look_at(Vector3(0.0, 0.8, -4.3))
	camera.make_current()
	camera.reset_physics_interpolation()


func _hitbox(target: Dictionary, name: StringName) -> Area3D:
	for hitbox: Dictionary in target.hitboxes:
		if hitbox.bone == name:
			return hitbox.area as Area3D
	return null


func _upper_fragment(result: Dictionary, original: Transform3D, waist: float) -> RigidBody3D:
	for body: RigidBody3D in result.fragments:
		var visual := body.get_node("Mesh") as MeshInstance3D
		var bounds := visual.mesh.get_aabb()
		if bounds.size.y > 0.65 and (original * bounds.get_center()).y > waist:
			return body
	return null


func _blast(fragments: Array, center: Vector3) -> int:
	var launched := 0
	for body: RigidBody3D in fragments:
		var offset := body.global_position - center
		var impulse := (offset.normalized() * BLAST_SPEED + Vector3.UP * BLAST_LIFT) * body.mass
		body.apply_central_impulse(impulse)
		launched += 1
	return launched


func _has_visible_interior(visual: MeshInstance3D) -> bool:
	for child in visual.get_children():
		if child is MeshInstance3D and child.is_in_group(INTERIOR_GROUP) \
				and child.mesh != null and child.is_visible_in_tree():
			return true
	return false


func _validate_interiors(severed_limbs: Array[RigidBody3D]) -> Dictionary:
	var interior_halves := 0
	var stained_halves := 0
	for index in TARGET_COUNT:
		var target: Dictionary = arena.targets[index]
		var torso_halves := 0
		var target_interiors := 0
		var target_stains := 0
		for body: RigidBody3D in target.get("plane_slice", {}).get("fragments", []):
			var visual := body.get_node("Mesh") as MeshInstance3D
			if visual.mesh.get_aabb().size.y <= 0.65:
				continue
			torso_halves += 1
			target_interiors += int(_has_visible_interior(visual))
			var stains: Variant = visual.get_meta(STAINS_META, [])
			if not stains.is_empty():
				target_stains += 1
		_expect(torso_halves == 2 and target_interiors == 2 and target_stains == 2,
			"Target %d must retain both torso interiors and stains after the shotgun contact." % index)
		interior_halves += target_interiors
		stained_halves += target_stains
	var arms_with_interior := 0
	for limb in severed_limbs:
		var visual := limb.get_node("Mesh") as MeshInstance3D
		arms_with_interior += int(_has_visible_interior(visual))
	_expect(arms_with_interior == TARGET_COUNT,
		"All severed arms must retain their previously exposed forearm interiors.")
	return {
		"interior_torso_halves": interior_halves,
		"stained_torso_halves": stained_halves,
		"interior_severed_arms": arms_with_interior,
	}


func _summarize(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {}
	var sorted := samples.duplicate()
	sorted.sort()
	var average := 0.0
	for sample in sorted:
		average += sample
	average /= sorted.size()
	return {
		"samples": sorted.size(),
		"avg_ms": average,
		"p50_ms": sorted[ceili(sorted.size() * 0.50) - 1],
		"p95_ms": sorted[ceili(sorted.size() * 0.95) - 1],
		"max_ms": sorted.back(),
	}


func _measure_frames(seconds: float) -> Dictionary:
	var samples: Array[float] = []
	var previous := Time.get_ticks_usec()
	var deadline := previous + int(seconds * 1000000.0)
	while previous < deadline:
		await process_frame
		var now := Time.get_ticks_usec()
		samples.append((now - previous) * 0.001)
		previous = now
	var result := _summarize(samples)
	result["mean_fps"] = 1000.0 / result.avg_ms
	result["physics_active"] = PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ACTIVE_OBJECTS)
	result["visible_draw_calls"] = RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	return result


func _run() -> void:
	_prepare_range()
	var elapsed := create_timer(1.25)
	await elapsed.timeout
	if not _expect(arena.targets.size() == TARGET_COUNT, "Expected 20 authored humanoid rigs."):
		await _finish()
		return

	var idle := await _measure_frames(0.75)
	var started_frame := Engine.get_process_frames()
	var started_physics_frame := Engine.get_physics_frames()
	var slice_durations: Array[float] = []
	var sever_durations: Array[float] = []
	var sliced := 0
	var severed := 0
	var severed_limbs: Array[RigidBody3D] = []
	var blasted := 0
	var blasted_bodies := 0
	var expected_fragments := 0
	var event_started := Time.get_ticks_usec()
	for index in TARGET_COUNT:
		var target: Dictionary = arena.targets[index]
		var source := target.mesh as MeshInstance3D
		var hips := _hitbox(target, &"Hips")
		var left_arm := _hitbox(target, &"LeftArm")
		if not _expect(hips != null and left_arm != null and source != null,
				"Target %d is missing its real rig and hit regions." % index):
			continue
		var waist := source.to_global(Vector3(0.0, WAIST_HEIGHT, 0.0)).y
		var original := source.global_transform
		var arm_contact := source.to_local(left_arm.global_position)
		var started := Time.get_ticks_usec()
		var slash: Dictionary = arena.plane_slicing.slash_hit(arena, {
			"collider": hips,
			"position": Vector3(hips.global_position.x, waist, hips.global_position.z),
		}, arena.targets, Plane(Vector3.UP, waist))
		slice_durations.append((Time.get_ticks_usec() - started) * 0.001)
		if not _expect(slash.get("ok", false) and slash.get("mode") == &"whole",
				"Target %d failed to slice. %s" % [index, slash.get("error", "")]):
			continue
		sliced += 1
		expected_fragments += slash.fragments.size()
		var upper := _upper_fragment(slash, original, waist)
		if not _expect(upper != null, "Target %d has no cut upper torso." % index):
			continue
		var visual := upper.get_node("Mesh") as MeshInstance3D
		started = Time.get_ticks_usec()
		# Deliver the registered limb contact directly. Bodies just created in this
		# same frame have not all entered the physics query broadphase yet.
		var shot: Dictionary = arena._apply_pellet_hit({
			"collider": upper,
			"position": visual.to_global(arm_contact),
			"direction": -visual.global_basis.z.normalized(),
		}, false, false, {}, {})
		sever_durations.append((Time.get_ticks_usec() - started) * 0.001)
		if not _expect(shot.get("severed", false) and shot.get("bone") == &"LeftArm",
				"Target %d did not sever at the intended pellet contact. %s" % [index, shot]):
			continue
		var limb := shot.get("limb") as RigidBody3D
		if _expect(limb != null and limb.linear_velocity.length() >= arena.dismemberment_impulse,
				"Target %d did not launch its detached limb." % index):
			severed_limbs.append(limb)
		severed += 1
		expected_fragments += 1
		blasted_bodies += _blast(target.plane_slice.fragments,
			source.to_global(Vector3(0.0, WAIST_HEIGHT, 0.0)))
		blasted += 1

	var event_cpu_ms := (Time.get_ticks_usec() - event_started) * 0.001
	var same_frame := started_frame == Engine.get_process_frames() \
		and started_physics_frame == Engine.get_physics_frames()
	_expect(same_frame, "All cuts and blasts must finish in one frame before any physics step.")
	_expect(sliced == TARGET_COUNT and severed == TARGET_COUNT,
		"All 20 humanoids must slice and dismember.")
	_expect(blasted == TARGET_COUNT and blasted_bodies == expected_fragments,
		"Each humanoid's resulting rigid fragments must receive a radial blast impulse.")
	await process_frame
	var event_to_next_frame_ms := (Time.get_ticks_usec() - event_started) * 0.001
	var fragments := get_nodes_in_group(FRAGMENT_GROUP)
	var live_fragments := 0
	for body in fragments:
		if body is RigidBody3D and not body.is_queued_for_deletion() and not body.freeze:
			live_fragments += 1
	_expect(live_fragments == expected_fragments,
		"Expected %d live rigid fragments, found %d." % [expected_fragments, live_fragments])
	var aftermath := await _measure_frames(0.75)
	await create_timer(0.25).timeout
	var settle := await _measure_frames(0.75)
	var verify_interiors := "--verify-interiors" in OS.get_cmdline_user_args()
	var interior_result := _validate_interiors(severed_limbs) if verify_interiors else {}
	print("TWENTY_HUMANOID_STRESS_RESULT=", JSON.stringify({
		"targets": TARGET_COUNT, "sliced": sliced, "severed": severed, "same_frame": same_frame,
		"live_fragments": live_fragments, "blasted": blasted, "blasted_bodies": blasted_bodies,
		"interior_verification": interior_result,
		"event_cpu_ms": event_cpu_ms, "event_to_next_frame_ms": event_to_next_frame_ms,
		"first_slice_ms": slice_durations.front() if not slice_durations.is_empty() else 0.0,
		"first_sever_ms": sever_durations.front() if not sever_durations.is_empty() else 0.0,
		"slice": _summarize(slice_durations), "sever": _summarize(sever_durations),
		"idle": idle, "aftermath": aftermath, "settle": settle,
		"display": DisplayServer.get_name(), "gpu": RenderingServer.get_video_adapter_name(),
		"cpu": OS.get_processor_name(), "window": str(root.size),
		"physics_ticks": Engine.physics_ticks_per_second,
	}))
	for index in TARGET_COUNT:
		arena._reset_target(index)
	await process_frame
	_expect(get_nodes_in_group(FRAGMENT_GROUP).is_empty(), "Reset must free every stress fragment.")
	if verify_interiors:
		_expect(get_nodes_in_group(INTERIOR_GROUP).is_empty(), "Reset must free every attached interior.")
		for target: Dictionary in arena.targets:
			_expect(not target.mesh.has_meta(STAINS_META), "Reset must leave the restored exterior unstained.")
	await _finish()


func _finish() -> void:
	await create_timer(0.25).timeout
	arena.queue_free()
	await process_frame
	await create_timer(0.15).timeout
	print("TWENTY_HUMANOID_STRESS_CHECKS=%d FAILURES=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
