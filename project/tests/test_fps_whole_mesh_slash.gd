extends SceneTree
## A horizontal camera swipe cuts the posed torso and both arms at the same height.

const DEMO := "res://demo/demo.tscn"
const WAIST_HEIGHT := 1.04
const UPPER_BODY_HEIGHT := 1.35
const SWIPE := Vector2(136.0, 0.0)
const DIAGONAL_SWIPE := Vector2(136.0, -58.0)

var checks := 0
var failures := 0
var arena: Node3D

func _initialize() -> void:
	_run.call_deferred()

func _expect(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		push_error("FPS_WHOLE_MESH_SLASH: " + message)
	return condition

func _physics_frames() -> void:
	for frame in 4:
		await physics_frame
	await process_frame

func _finish() -> void:
	# Let the sever cues and room playback retire after scene teardown.
	await create_timer(0.5).timeout
	arena.queue_free()
	await process_frame
	await create_timer(0.12).timeout
	print("FPS_WHOLE_MESH_SLASH_CHECKS=%d FAILURES=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _swipe(relative: Vector2) -> Dictionary:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_MIDDLE
	press.pressed = true
	arena._unhandled_input(press)
	var motion := InputEventMouseMotion.new()
	motion.relative = relative
	arena._unhandled_input(motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_MIDDLE
	release.pressed = false
	arena._unhandled_input(release)
	return arena.last_slash

func _aim_level(point: Vector3, height: float) -> void:
	var camera: Camera3D = arena.camera
	camera.position.y += height - camera.global_position.y
	arena._look_at(Vector3(point.x, height, point.z))
	arena.player.reset_physics_interpolation()
	await _physics_frames()

func _press_reset() -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_R
	event.pressed = true
	arena._unhandled_input(event)

func _cap_is_on_plane(mesh: ArrayMesh, source_transform: Transform3D, plane: Plane) -> bool:
	var cap := mesh.get_surface_count() - 1
	if cap < 0 or mesh.surface_get_name(cap) != "Slice Cap" or mesh.surface_get_material(cap) != arena.slice_cap_material:
		return false
	var positions: PackedVector3Array = mesh.surface_get_arrays(cap)[Mesh.ARRAY_VERTEX]
	for position in positions:
		if absf(plane.distance_to(source_transform * position)) > 0.001:
			return false
	return positions.size() >= 3

func _run() -> void:
	arena = load(DEMO).instantiate()
	root.add_child(arena)
	arena.testing = true
	arena.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	arena._jump_station(0)
	await _physics_frames()

	var target: Dictionary = arena.targets[0]
	var actor: Node3D = target.actor
	var source: MeshInstance3D = target.mesh
	var source_mesh := source.mesh
	var source_transform := source.global_transform
	var physics_layers := {}
	for body: PhysicalBone3D in target.physics_bodies.values():
		physics_layers[body] = body.collision_layer

	await _aim_level(actor.global_position, WAIST_HEIGHT)
	var hit: Dictionary = arena._raycast_camera()
	var collider := hit.get("collider") as CollisionObject3D
	if not _expect(collider != null and collider.get_meta(&"bone", &"") == &"Hips",
			"the level camera ray reaches the center of the posed humanoid"):
		await _finish()
		return

	var short_drag := _swipe(Vector2(8.0, 0.0))
	_expect(not short_drag.get("ok", false) and short_drag.has("error") and not target.has("plane_slice"),
		"a short drag is refused without cutting the subject")
	var previous_reach: float = arena.slash_reach
	arena.slash_reach = 1.0
	var out_of_reach := _swipe(SWIPE)
	arena.slash_reach = previous_reach
	_expect(not out_of_reach.get("ok", false) and out_of_reach.has("error") and source.is_visible_in_tree()
		and source.mesh == source_mesh and get_nodes_in_group("Dismembered Limb").is_empty(),
		"a full swipe outside reach leaves source geometry and bodies untouched")

	var first := _swipe(SWIPE)
	if not _expect(first.get("ok", false) and first.get("mode", &"") == &"whole"
			and first.get("target", -1) == 0 and target.has("plane_slice"),
			"middle-mouse release cuts the whole mesh: %s" % first.get("error", "")):
		await _finish()
		return
	var fragments: Array = first.fragments.duplicate()
	_expect(first.loop_count == 3 and fragments.size() >= 4,
		"the horizontal cut through the torso and arms produces three contours and at least four independent bodies")
	_expect(not source.is_visible_in_tree() and source.mesh == source_mesh,
		"the live rig hides once the complete pose-baked result is ready")
	var muted := true
	for hitbox in target.hitboxes:
		muted = muted and hitbox.area.collision_layer == 0
	for body: PhysicalBone3D in physics_layers:
		muted = muted and body.collision_layer == 0
	_expect(muted, "the hidden rig no longer receives rays on its original colliders")

	var upper: RigidBody3D
	var torso_sections := 0
	var capped_pieces := 0
	var live_colliders := true
	var bounded_colliders := true
	var waist_plane := Plane(Vector3.UP, WAIST_HEIGHT)
	for body: RigidBody3D in fragments:
		var visual := body.get_node("Mesh") as MeshInstance3D
		var mesh := visual.mesh as ArrayMesh
		var shape := body.get_node("CollisionShape3D") as CollisionShape3D
		live_colliders = (live_colliders and not body.freeze and body.collision_layer != 0
			and body.is_in_group("Dismembered Limb") and shape.shape is ConvexPolygonShape3D)
		var convex := shape.shape as ConvexPolygonShape3D
		bounded_colliders = bounded_colliders and convex != null and convex.points.size() <= 98
		capped_pieces += int(_cap_is_on_plane(mesh, source_transform, waist_plane))
		var bounds := mesh.get_aabb()
		if bounds.size.y > 0.65:
			torso_sections += 1
			if (source_transform * bounds.get_center()).y > WAIST_HEIGHT:
				upper = body
		# Freeze pieces only after checking that gameplay spawned them as live bodies.
		body.freeze = true
	_expect(live_colliders, "all output sections are live rigid bodies with convex collision")
	_expect(bounded_colliders, "whole-mesh fragments use bounded convex collision point counts")
	_expect(capped_pieces >= 4, "both torso sections and the detached arms expose the authored cap material on the swipe plane")
	if not _expect(torso_sections == 2 and upper != null, "the whole-body swipe creates upper and lower torso-scale pieces"):
		await _finish()
		return

	await _physics_frames()
	await _aim_level(actor.global_position, UPPER_BODY_HEIGHT)
	if not _expect(arena._raycast_camera().get("collider") == upper,
			"the second level ray targets the upper rigid fragment"):
		await _finish()
		return
	var upper_visual := upper.get_node("Mesh") as MeshInstance3D
	var upper_transform := upper_visual.global_transform
	var second := _swipe(SWIPE)
	if _expect(second.get("ok", false) and second.get("mode", &"") == &"fragment",
			"another swipe cuts the upper fragment: %s" % second.get("error", "")):
		var current: Array = target.plane_slice.fragments
		_expect(second.fragments.size() >= 2 and upper.is_queued_for_deletion() and not current.has(upper)
			and current.size() == fragments.size() - 1 + second.fragments.size(),
			"the second swipe replaces the selected fragment with independent bodies")
		var new_caps := 0
		var upper_plane := Plane(Vector3.UP, UPPER_BODY_HEIGHT)
		for body: RigidBody3D in second.fragments:
			var visual := body.get_node("Mesh") as MeshInstance3D
			new_caps += int(_cap_is_on_plane(visual.mesh, upper_transform, upper_plane))
		_expect(new_caps >= 2, "the second swipe caps both new sides at the new plane")
		var siblings_remain := true
		for body: RigidBody3D in fragments:
			if body != upper:
				siblings_remain = siblings_remain and current.has(body) and not body.is_queued_for_deletion()
		_expect(siblings_remain, "re-cutting one body preserves the other fragments")

	_press_reset()
	await _physics_frames()
	_expect(not target.has("plane_slice") and source.is_visible_in_tree()
		and source.mesh.get_surface_count() == source_mesh.get_surface_count()
		and source.mesh.get_aabb().is_equal_approx(source_mesh.get_aabb()),
		"R restores the original source geometry and clears experimental cut state")
	var restored := true
	for hitbox in target.hitboxes:
		restored = restored and hitbox.area.collision_layer == hitbox.collision_layer
	for body: PhysicalBone3D in physics_layers:
		restored = restored and body.collision_layer == physics_layers[body]
	_expect(restored and get_nodes_in_group("Dismembered Limb").is_empty(),
		"R restores the source collision layers and removes all created fragments")

	await _aim_level(actor.global_position, 1.20)
	var camera: Camera3D = arena.camera
	var slash_normal := (camera.global_basis.y + camera.global_basis.x * (DIAGONAL_SWIPE.y / DIAGONAL_SWIPE.x)).normalized()
	var diagonal_plane := Plane(slash_normal, camera.global_position)
	var diagonal := _swipe(DIAGONAL_SWIPE)
	if _expect(diagonal.get("ok", false) and diagonal.get("mode", &"") == &"whole",
			"a diagonal swipe can slice the restored subject: %s" % diagonal.get("error", "")):
		var diagonal_caps := 0
		for body: RigidBody3D in diagonal.fragments:
			var visual := body.get_node("Mesh") as MeshInstance3D
			diagonal_caps += int(_cap_is_on_plane(visual.mesh, source.global_transform, diagonal_plane))
		_expect(diagonal.loop_count == 2 and diagonal_caps >= 3,
			"the gesture changes the cut angle and caps both diagonal contours")
		_press_reset()
		await _physics_frames()
		_expect(source.is_visible_in_tree() and get_nodes_in_group("Dismembered Limb").is_empty(),
			"the subject can reset again after a second whole-body swipe")
	await _finish()
