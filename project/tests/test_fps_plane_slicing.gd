extends SceneTree
## Real camera rays drive the experimental cut, re-cut, and reset keys.

const DEMO := "res://demo/demo.tscn"

var checks := 0
var failures := 0
var arena: Node3D

func _initialize() -> void:
	_run.call_deferred()

func _expect(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		push_error("FPS_PLANE_SLICE: " + message)
	return condition

func _press_key(key: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = true
	arena._unhandled_input(event)

func _physics_frames() -> void:
	for frame in 4:
		await physics_frame
	await process_frame

func _finish() -> void:
	if is_instance_valid(arena):
		# Let both short cut cues finish before exercising scene teardown.
		await create_timer(0.5).timeout
		arena.queue_free()
		await process_frame
		await create_timer(0.12).timeout
	print("FPS_PLANE_SLICE_CHECKS=%d FAILURES=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _run() -> void:
	arena = load(DEMO).instantiate()
	root.add_child(arena)
	arena.testing = true
	arena.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await _physics_frames()
	var target: Dictionary = arena.targets[0]
	var source: MeshInstance3D = target.mesh
	var source_bounds := source.mesh.get_aabb()
	var source_surface_count := source.mesh.get_surface_count()
	var body_layers := {}
	for body: PhysicalBone3D in target.physics_bodies.values():
		body_layers[body] = body.collision_layer

	if not _expect(arena._aim_at_bone(0, &"Hips"), "camera can aim at an invalid standing cut"):
		await _finish()
		return
	await _physics_frames()
	var refused: Dictionary = arena._slice_camera()
	_expect(not refused.ok and not target.has("plane_slice") and source.is_visible_in_tree(),
		"an invalid standing cut leaves the original subject unchanged")

	if not _expect(arena._aim_at_bone(0, &"LeftForeArm"), "camera can aim at the standing forearm"):
		await _finish()
		return
	await _physics_frames()
	var hit: Dictionary = arena._raycast_camera()
	var collider: Node3D = hit.get("collider")
	if not _expect(collider != null and collider.get_meta(&"bone", &"") == &"LeftForeArm",
			"the actual camera ray reaches the standing forearm"):
		await _finish()
		return
	_press_key(KEY_E)
	_expect(is_equal_approx(arena.plane_slicing.tilt_degrees, 5.0), "E tilts the cutting plane by five degrees")
	_press_key(KEY_V)
	if not _expect(target.has("plane_slice"), "V cuts the oblique forearm through the actual camera ray"):
		await _finish()
		return
	var slice: Dictionary = target.plane_slice
	var remainder: MeshInstance3D = slice.remainder
	_expect(not source.is_visible_in_tree() and remainder.is_visible_in_tree()
		and remainder.global_transform.is_equal_approx(source.global_transform),
		"the pose-captured remainder replaces the source in place")
	_expect(remainder.layers == source.layers and remainder.cast_shadow == source.cast_shadow
		and remainder.gi_mode == source.gi_mode, "the remainder retains the source's render flags")
	var muted := true
	for hitbox in target.hitboxes:
		muted = muted and hitbox.area.collision_layer == 0
	for body: PhysicalBone3D in body_layers:
		muted = muted and body.collision_layer == 0
	_expect(muted, "source hitboxes and original physical bodies are suppressed")

	var fragment: RigidBody3D = slice.fragments[0]
	_expect(fragment.is_in_group("Dismembered Limb") and fragment.collision_layer != 0
		and fragment.get_node("CollisionShape3D").shape is ConvexPolygonShape3D
		and fragment.linear_velocity.length() > 0.0,
		"the detached piece has a live convex collider and launch velocity")

	_press_key(KEY_Q)
	_expect(is_zero_approx(arena.plane_slicing.tilt_degrees), "Q tilts the plane back to zero")
	if not _expect(await _reslice_fragment(fragment), "V re-cuts a fragment targeted by a real camera ray"):
		await _finish()
		return
	_expect(slice.fragments.size() == 2 and fragment.is_queued_for_deletion(),
		"the re-cut replaces the old rigid fragment with two bodies")

	_press_key(KEY_R)
	await _physics_frames()
	_expect(not target.has("plane_slice") and source.is_visible_in_tree()
		and source.mesh.get_surface_count() == source_surface_count
		and source.mesh.get_aabb().is_equal_approx(source_bounds),
		"R restores the original subject geometry and visibility")
	var restored := true
	for hitbox in target.hitboxes:
		restored = restored and hitbox.area.collision_layer == hitbox.collision_layer
	for body: PhysicalBone3D in body_layers:
		restored = restored and body.collision_layer == body_layers[body]
	_expect(restored and get_nodes_in_group("Dismembered Limb").is_empty(),
		"R restores source collision layers and removes every experimental fragment")
	await _finish()

func _reslice_fragment(fragment: RigidBody3D) -> bool:
	# Place the live fragment clear of the subject for a deterministic second ray.
	fragment.freeze = true
	fragment.global_position += Vector3(0.0, 0.18, 1.7)
	fragment.reset_physics_interpolation()
	await _physics_frames()
	var visual := fragment.get_node("Mesh") as MeshInstance3D
	var bounds := visual.mesh.get_aabb()
	for offset in [Vector3(0.48, 0.45, 0.5), Vector3(0.4, 0.33, 0.5), Vector3(0.6, 0.56, 0.5)]:
		var point := visual.to_global(bounds.position + bounds.size * offset)
		arena.player.global_position = Vector3(point.x, -0.055, point.z + 1.4)
		arena.player.velocity = Vector3.ZERO
		arena._look_at(point)
		await _physics_frames()
		if arena._raycast_camera().get("collider") == fragment:
			_press_key(KEY_V)
			if fragment.is_queued_for_deletion():
				return true
	return false
