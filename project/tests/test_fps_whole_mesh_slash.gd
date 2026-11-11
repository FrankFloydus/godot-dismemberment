extends SceneTree
## A horizontal camera swipe cuts the posed torso and both arms at the same height.

const DEMO := "res://demo/demo.tscn"
const DEFAULT_CAP_PATH := "res://addons/godot-dismemberment/materials/slice_cap.tres"
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
	if cap < 0 or mesh.surface_get_name(cap) != "Slice Cap":
		return false
	var material := mesh.surface_get_material(cap)
	if arena.slice_cap_material != null:
		if material != arena.slice_cap_material:
			return false
	elif material == null or material.resource_path != DEFAULT_CAP_PATH:
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
	var torso_with_interiors := 0
	var torso_with_stains := 0
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
			var interiors := visual.get_children().filter(
				func(node: Node) -> bool: return node is MeshInstance3D and node.is_in_group(&"slice_interior_visual"))
			var authored_faces := 0
			var authored_indices := 0
			for layer: Dictionary in visual.get_meta(&"slice_interior_layers", []):
				for face: Dictionary in layer.get("exposed_caps", []):
					var indices: PackedInt32Array = face.arrays[Mesh.ARRAY_INDEX]
					authored_faces += 1
					authored_indices += indices.size()
			if interiors.size() == 1:
				var interior: ArrayMesh = interiors[0].mesh
				torso_with_interiors += int(authored_faces >= 2 and interior.get_surface_count() == 1
					and interior.surface_get_array_index_len(0) == authored_indices)
			var shell := visual.get_surface_override_material(0)
			torso_with_stains += int(visual.has_meta(&"plane_slice_stains") and shell != null and shell.next_pass != null)
			if (source_transform * bounds.get_center()).y > WAIST_HEIGHT:
				upper = body
		# Freeze pieces only after checking that gameplay spawned them as live bodies.
		body.freeze = true
	_expect(torso_with_interiors == 2 and torso_with_stains == 2,
		"both waist faces batch their authored interior triangles and retain a stain on the exterior")
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
	var previous_pellet_count: int = arena.pellet_count
	arena.pellet_count = 1
	arena.fire_shake_distance = 0.0
	var shot_contact: Vector3 = arena._raycast_camera().position
	var fragment_shot: Dictionary = arena._shoot()
	arena.pellet_count = previous_pellet_count
	_expect(fragment_shot.get("hit", false) and fragment_shot.get("sliced", false)
		and fragment_shot.get("detached", false) and fragment_shot.position.is_equal_approx(shot_contact),
		"the shotgun hits a sliced fragment at the actual pellet contact")
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
		and source.mesh.get_aabb().is_equal_approx(source_mesh.get_aabb())
		and get_nodes_in_group(&"slice_interior_visual").is_empty()
		and not source.has_meta(&"plane_slice_stains"),
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
	await _aim_level(actor.global_position, 0.62)
	var nested := _swipe(SWIPE)
	if _expect(nested.get("ok", false) and nested.get("loop_count", 0) == 6,
			"a horizontal leg swipe caps all six contours, including cavities: %s" % nested.get("error", "")):
		_press_reset()
		await _physics_frames()
	await _check_shot_severs_slice_limb(target)
	await _check_slash_after_shot(target, source_mesh.get_aabb().end.x)
	await _check_staged_invalidation(target)
	await _finish()

func _check_staged_invalidation(target: Dictionary) -> void:
	_press_reset()
	arena._jump_station(0)
	await _aim_level(target.actor.global_position, WAIST_HEIGHT)
	var hit: Dictionary = arena._raycast_camera()
	var plane := Plane(Vector3.UP, WAIST_HEIGHT)
	var stage: Dictionary = arena.plane_slicing.stage_whole_slash(hit, arena.targets, plane)
	if not _expect(stage.get("ok", false), "an intact subject accepts a staged slash"):
		return
	while not arena.plane_slicing.is_whole_slash_ready(stage):
		await process_frame
	var collected: Dictionary = arena.plane_slicing.collect_whole_slash(stage, arena.targets)
	if not _expect(collected.get("ok", false), "a staged slash collects its worker result"):
		arena.plane_slicing.discard_whole_slash(stage)
		return
	_press_reset()
	var rejected: Dictionary = arena.plane_slicing.prepare_whole_slash(stage, arena.targets)
	_expect(not rejected.get("ok", false) and not target.has("plane_slice")
		and get_nodes_in_group("Dismembered Limb").is_empty(),
		"reset invalidates collected geometry before fragment creation")

	await _physics_frames()
	hit = arena._raycast_camera()
	stage = arena.plane_slicing.stage_whole_slash(hit, arena.targets, plane)
	if not _expect(stage.get("ok", false), "a restored subject can stage another slash"):
		return
	while not arena.plane_slicing.is_whole_slash_ready(stage):
		await process_frame
	var prepared: Dictionary = arena.plane_slicing.prepare_whole_slash(stage, arena.targets)
	if not _expect(prepared.get("ok", false) and stage.has("fragments"), "a staged slash prepares off-tree bodies"):
		arena.plane_slicing.discard_whole_slash(stage)
		return
	var actor: Node3D = target.actor
	var origin := actor.position
	actor.position += Vector3(0.06, 0.0, 0.0)
	var pending: Array[Dictionary] = [stage]
	var result: Array = arena.plane_slicing.publish_whole_slashes(arena, pending, arena.targets)
	actor.position = origin
	_expect(not result[0].get("ok", false) and not target.has("plane_slice")
		and get_nodes_in_group("Dismembered Limb").is_empty(),
		"a changed transform discards prepared bodies without hiding the subject")

func _check_shot_severs_slice_limb(target: Dictionary) -> void:
	arena._jump_station(0)
	await _aim_level(target.actor.global_position, WAIST_HEIGHT)
	var source: MeshInstance3D = target.mesh
	var arm: Vector3
	var thigh: Vector3
	for hitbox in target.hitboxes:
		if hitbox.bone == &"LeftArm":
			arm = source.to_local(hitbox.area.global_position)
		elif hitbox.bone == &"RightUpLeg":
			thigh = source.to_local(hitbox.area.global_position)
	var slash := _swipe(SWIPE)
	if not _expect(slash.get("ok", false), "the second waist slice prepares a rigid torso for the shotgun"):
		return
	var upper: RigidBody3D
	var lower: RigidBody3D
	var siblings: Array = []
	for body: RigidBody3D in slash.fragments:
		body.freeze = true
		var visual: MeshInstance3D = body.get_node("Mesh")
		var bounds := visual.mesh.get_aabb()
		if bounds.size.y > 0.65 and source.to_global(bounds.get_center()).y > WAIST_HEIGHT:
			upper = body
		else:
			siblings.append(body)
			if bounds.size.y > 0.65:
				lower = body
	if not _expect(upper != null and lower != null, "the waist cut retains both the upper and lower body"):
		_press_reset()
		return
	upper.global_position += Vector3(1.0, 0.25, 1.25)
	upper.rotate_y(deg_to_rad(24.0))
	upper.reset_physics_interpolation()
	await _aim_at_fragment(upper, arm, Vector3(1.7, 0.3, 2.4))
	if _expect(arena._raycast_camera().get("collider") == upper, "the shotgun ray reaches the moved, rotated upper fragment"):
		arena.pellet_count = 8
		arena.fire_shake_distance = 0.0
		arena.shot_cooldown = 0.0
		var blood_only: Dictionary = arena._shoot(true)
		_expect(blood_only.get("sliced", false) and not blood_only.get("severed", false),
			"the blood-only tool leaves the limb attached")
		arena.shot_cooldown = 0.0
		var sever: Dictionary = arena._shoot()
		if _expect(sever.get("severed", false) and sever.get("bone") == &"LeftArm" and sever.pellets_fired == 8,
				"the shotgun severs the arm from the moved fragment: %s" % str(sever)):
			var bodies: Array = target.plane_slice.fragments
			var limb_mesh: MeshInstance3D = sever.limb.get_node("Mesh")
			_expect(upper.is_queued_for_deletion() and bodies.size() == slash.fragments.size() + 1
				and sever.limb in bodies and limb_mesh.mesh.get_aabb().position.x > 0.13
				and siblings.all(func(body: RigidBody3D) -> bool: return body in bodies),
				"the hit releases only the local arm and preserves every unrelated fragment")
			await _aim_at_fragment(lower, thigh, Vector3(-1.7, 0.3, 2.4))
			_expect(not is_instance_valid(upper), "the original upper body is freed before shooting its sibling")
			if _expect(arena._raycast_camera().get("collider") == lower, "the next ray hits the surviving lower fragment"):
				arena.shot_cooldown = 0.0
				var followup: Dictionary = arena._shoot()
				if _expect(followup.get("severed", false) and followup.get("bone") == &"RightUpLeg",
						"the second shell severs a limb from the sibling fragment"):
					await _physics_frames()
					_expect(bodies.size() == slash.fragments.size() + 2 and bodies.all(func(body: RigidBody3D) -> bool:
						var peers := body.get_collision_exceptions()
						return peers.size() == bodies.size() - 1 and peers.all(func(peer: PhysicsBody3D) -> bool:
							return is_instance_valid(peer) and peer in bodies)),
						"every replacement retains only live collision exceptions")
	_press_reset()
	await _physics_frames()

func _aim_at_fragment(body: RigidBody3D, point: Vector3, offset: Vector3) -> void:
	var visual := body.get_node("Mesh") as MeshInstance3D
	var viewpoint := visual.to_global(point + offset)
	arena.player.global_position = Vector3(viewpoint.x, -0.055, viewpoint.z)
	arena.player.velocity = Vector3.ZERO
	arena.camera.position.y += viewpoint.y - arena.camera.global_position.y
	arena._look_at(visual.to_global(point))
	await _physics_frames()

func _check_slash_after_shot(target: Dictionary, original_left_extent: float) -> void:
	arena.pellet_count = 1
	arena.shot_cooldown = 0.0
	if not _expect(arena._aim_at_bone(0, &"LeftArm"), "the shotgun can aim at the restored left arm"):
		return
	await _physics_frames()
	var shot: Dictionary = arena._shoot()
	var limb: Node = target.component.get_dismembered_limb_by_name(&"LeftArm")
	if not _expect(shot.get("bone", &"") == &"LeftArm" and is_instance_valid(limb),
			"the real shotgun ray severs the left arm before the slash"):
		return
	await _aim_level(target.actor.global_position, WAIST_HEIGHT)
	var result := _swipe(SWIPE)
	if _expect(result.get("ok", false) and result.get("mode", &"") == &"whole",
			"a waist swipe slices the remaining body after a shotgun cut: %s" % result.get("error", "")):
		var largest_left_extent := -INF
		for fragment: RigidBody3D in result.fragments:
			var visual := fragment.get_node("Mesh") as MeshInstance3D
			largest_left_extent = maxf(largest_left_extent, visual.mesh.get_aabb().end.x)
		_expect(largest_left_extent < original_left_extent - 0.1 and is_instance_valid(limb)
			and target.component.get_dismembered_limb_by_name(&"LeftArm") == limb,
			"the slash keeps the existing detached arm and does not regenerate it on the body")
	_press_reset()
	await _physics_frames()
