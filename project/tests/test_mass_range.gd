extends SceneTree
## Runs both mass controls through the saved 30-body range and records frame gaps.
## Pass --mixed for F then RMB, --transition for RMB then F, or --cancel for R during staging.
## Pass --targets=20 to exercise a smaller fixture without changing the saved scene.
## Pass --unique-meshes for independently allocated bodies with slightly different vertices.
## Pass --full-detail to benchmark the original humanoid mesh.
## Pass --dismember-only or --slice-only to measure a fresh action in isolation.
## Pass --repeat-slices for four consecutive F presses with no reset.
## Add --settle-ms=3000 to sample the room again after an extra pause.
## Pass --physics-hz=60 to benchmark a different tick rate for this test run.

const RANGE := "res://demo/mass_range.tscn"
const RANGE_MESH := "res://demo/assets/humanoid/body_mesh_mass_range.res"
const FULL_DETAIL_MESH := "res://demo/assets/humanoid/body_mesh.res"
const PlaneSlicing := preload("res://demo/fps_plane_slicing.gd")
const AUTHORED_TARGET_COUNT := 30
const TIMEOUT_USEC := 90000000
const FRAGMENT_GROUP := &"Dismembered Limb"
const TEST_DEVICE := 15
const REPEAT_SLICE_PASSES := 4
const ROOM_SAMPLE_USEC := 500000

class InputIsolation extends Node:
	func _input(event: InputEvent) -> void:
		if event.device != TEST_DEVICE:
			get_viewport().set_input_as_handled()

var arena: Node3D
var target_count := AUTHORED_TARGET_COUNT
var unique_meshes := false
var full_detail := false
var checks := 0
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _expect(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		failures += 1
		push_error("MASS_RANGE: " + message)
	return condition


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.device = TEST_DEVICE
	event.pressed = true
	event.physical_keycode = code
	root.push_input(event, true)


func _mouse(button: MouseButton) -> void:
	var event := InputEventMouseButton.new()
	event.device = TEST_DEVICE
	event.pressed = true
	event.button_index = button
	event.position = Vector2(root.size) * 0.5
	event.global_position = event.position
	root.push_input(event, true)


func _replace_body_meshes(stations: Node) -> bool:
	var first := stations.get_child(0).get_node("Target/Skeleton3D/SkinMesh") as MeshInstance3D
	var source := first.mesh as ArrayMesh
	if not _expect(source != null and source.get_surface_count() == 1
			and source.get_blend_shape_count() == 0 and source.surface_get_array_len(0) > 0,
			"the unique-mesh fixture has the expected humanoid source layout"):
		return false
	var surface_data: Array = source.get("_surfaces")
	var raw_lods: Array = surface_data[0].get("lods", [])
	var uses_16_bit_indices := source.surface_get_array_len(0) <= 65536
	var lods := {}
	for lod in range(0, raw_lods.size(), 2):
		var indices: PackedByteArray = raw_lods[lod + 1]
		if uses_16_bit_indices:
			var expanded := PackedInt32Array()
			expanded.resize(indices.size() >> 1)
			for index in expanded.size():
				expanded[index] = indices.decode_u16(index * 2)
			lods[raw_lods[lod]] = expanded
		else:
			lods[raw_lods[lod]] = indices.to_int32_array()
	var source_arrays := source.surface_get_arrays(0)
	var positions: PackedVector3Array = source_arrays[Mesh.ARRAY_VERTEX]
	# Vary the head height while leaving the rest of the skinned geometry intact.
	var head_vertices := PackedInt32Array()
	var height_weights := PackedFloat32Array()
	for index in positions.size():
		if positions[index].y > 1.64:
			head_vertices.append(index)
			height_weights.append(smoothstep(1.64, 1.80, positions[index].y))
	var flags := source.surface_get_format(0) & (Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
		| Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE | (0xfff << Mesh.ARRAY_FORMAT_CUSTOM_BASE))
	var resources := {}
	var bounds := {}
	for index in target_count:
		var body := stations.get_child(index).get_node("Target/Skeleton3D/SkinMesh") as MeshInstance3D
		var height_offset := lerpf(-0.012, 0.012, float(index) / (target_count - 1))
		var variant_positions := positions.duplicate()
		for head_vertex in head_vertices.size():
			var vertex := head_vertices[head_vertex]
			variant_positions[vertex] += Vector3.UP * height_offset * height_weights[head_vertex]
		var arrays := source_arrays.duplicate()
		arrays[Mesh.ARRAY_VERTEX] = variant_positions
		var variant_mesh := ArrayMesh.new()
		variant_mesh.add_surface_from_arrays(source.surface_get_primitive_type(0), arrays, [], lods, flags)
		variant_mesh.surface_set_name(0, source.surface_get_name(0))
		variant_mesh.surface_set_material(0, source.surface_get_material(0))
		body.mesh = variant_mesh
		resources[variant_mesh.get_rid()] = true
		bounds[variant_mesh.get_aabb().size] = true
	return _expect(resources.size() == target_count and bounds.size() == target_count,
		"each humanoid has a different mesh RID and different vertex bounds")


func _prepare_range() -> bool:
	var packed := load(RANGE) as PackedScene
	if not _expect(packed != null, "the saved 30-body range scene loads"):
		return false
	arena = packed.instantiate() as Node3D
	if not _expect(arena != null and arena.has_signal("mass_action_finished"),
			"the range has its mass-action controller"):
		return false
	var stations := arena.get_node_or_null("Stations")
	if not _expect(stations != null and stations.get_child_count() == AUTHORED_TARGET_COUNT,
			"all 30 stations are authored in the scene before play"):
		return false
	var names := {}
	for station in stations.get_children():
		var mesh := station.get_node_or_null("Target/Skeleton3D/SkinMesh") as MeshInstance3D
		names[station.name] = true
		if not _expect(mesh != null and mesh.mesh != null and mesh.skin != null
				and mesh.mesh.resource_path == RANGE_MESH
				and station.get_node_or_null("Target/GoreComponent") is GoreComponent
				and station.get_node_or_null("PlayerSpawn") is Marker3D
				and station.get_node_or_null("InitialAim") is Marker3D,
				"%s includes its reduced skinned target, component and authored station markers" % station.name):
			return false
	_expect(names.size() == AUTHORED_TARGET_COUNT, "the authored station names are distinct")
	for index in range(stations.get_child_count() - 1, target_count - 1, -1):
		stations.get_child(index).free()
	if full_detail:
		var source := load(FULL_DETAIL_MESH) as ArrayMesh
		if not _expect(source != null, "the original full-detail humanoid mesh loads"):
			return false
		for station in stations.get_children():
			var body := station.get_node("Target/Skeleton3D/SkinMesh") as MeshInstance3D
			body.mesh = source
	if unique_meshes and not _replace_body_meshes(stations):
		return false
	root.add_child(arena)
	arena.add_child(InputIsolation.new())
	current_scene = arena
	arena.testing = true
	# Reuse the same choices when comparing shared and unique geometry.
	arena.mass_dismember._random.seed = 763203
	arena.mass_slice._random.seed = 57403
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	return _expect(arena.targets.size() == target_count, "the controller bound every actor")


func _slice_count() -> int:
	var count := 0
	for target: Dictionary in arena.targets:
		count += int(target.has("plane_slice"))
	return count


func _limb_root_body(limb: DismemberedLimb) -> PhysicalBone3D:
	var skeleton := limb.get_ragdoll_skeleton()
	if skeleton == null:
		return null
	return skeleton.get_node_or_null("Physics_" + String(limb.get_bone_name())) as PhysicalBone3D


func _dismembered_target_counts() -> Vector3i:
	var counts := Vector3i.ZERO
	for target: Dictionary in arena.targets:
		var component: GoreComponent = target.component
		var revealed := false
		for limb: DismemberedLimb in component.get_all_dismembered_limbs():
			if limb.is_visible_in_tree():
				revealed = true
			else:
				counts.y += 1
				var bone := _limb_root_body(limb)
				if bone == null or bone.is_simulating_physics() \
						or bone.collision_layer != 0 or bone.collision_mask != 0:
					counts.z += 1
		counts.x += int(revealed)
	return counts


func _summarize(values: Array[float], unit_suffix := "_ms") -> Dictionary:
	if values.is_empty():
		return {}
	values.sort()
	var total := 0.0
	for value in values:
		total += value
	return {
		"samples": values.size(),
		"mean" + unit_suffix: total / values.size(),
		"p95" + unit_suffix: values[ceili(values.size() * 0.95) - 1],
		"max" + unit_suffix: values.back(),
	}


func _fragment_ids() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for target: Dictionary in arena.targets:
		var ids := {}
		for body: RigidBody3D in target.get("plane_slice", {}).get("fragments", []):
			if is_instance_valid(body) and body.is_inside_tree() and not body.is_queued_for_deletion():
				ids[body.get_instance_id()] = true
		result.append(ids)
	return result


func _source_colliders_in_world() -> Dictionary:
	var attached := {}
	var space := arena.get_world_3d().space
	for target: Dictionary in arena.targets:
		for bone: PhysicalBone3D in target.physics_bodies.values():
			var body := bone.get_rid()
			if PhysicsServer3D.body_get_space(body) == space:
				attached[body] = true
		for hitbox: Dictionary in target.hitboxes:
			var area: Area3D = hitbox.area
			var hitbox_rid := area.get_rid()
			if PhysicsServer3D.area_get_space(hitbox_rid) == space:
				attached[hitbox_rid] = true
	return attached


func _sample_room(pass_number: int, settled: bool = false) -> void:
	var frame_gaps: Array[float] = []
	var physics_ticks: Array[float] = []
	var collision_pairs: Array[float] = []
	var active_objects: Array[float] = []
	var draw_calls: Array[float] = []
	var started := Time.get_ticks_usec()
	var previous := started
	var previous_physics_frame := Engine.get_physics_frames()
	while previous - started < ROOM_SAMPLE_USEC:
		await process_frame
		var now := Time.get_ticks_usec()
		var physics_frame_number := Engine.get_physics_frames()
		frame_gaps.append((now - previous) * 0.001)
		physics_ticks.append(physics_frame_number - previous_physics_frame)
		collision_pairs.append(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
		active_objects.append(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
		draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		previous = now
		previous_physics_frame = physics_frame_number

	var fragments := 0
	var sleeping := 0
	var frozen := 0
	for node in get_nodes_in_group(FRAGMENT_GROUP):
		var body := node as RigidBody3D
		if body != null and not body.is_queued_for_deletion():
			fragments += 1
			frozen += int(body.freeze)
			sleeping += int(body.sleeping and not body.freeze)
	var max_target_fragments := 0
	for ids in _fragment_ids():
		max_target_fragments = maxi(max_target_fragments, ids.size())
	print("MASS_RANGE_ROOM=", JSON.stringify({
		"after_pass": pass_number,
		"settled": settled,
		"frame_gaps": _summarize(frame_gaps),
		# Godot reports the peaks from its last one-second monitor interval.
		"engine_monitor_process_peak_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"engine_monitor_physics_peak_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"physics_ticks_per_frame": _summarize(physics_ticks, ""),
		"physics_active_objects": _summarize(active_objects, ""),
		"physics_collision_pairs": _summarize(collision_pairs, ""),
		"draw_calls": _summarize(draw_calls, ""),
		"fragment_nodes": fragments,
		"sleeping_fragments": sleeping,
		"frozen_fragments": frozen,
		"max_target_fragments": max_target_fragments,
	}))


func _run_repeated_slices(settle_ms: int) -> void:
	await _sample_room(0)
	var original_colliders := _source_colliders_in_world()
	var suspended_colliders := -1
	_expect(not original_colliders.is_empty(), "the original rigs have colliders in the world before F")
	var previous := _fragment_ids()
	var largest_recut_growth := 2
	for pass_number in range(1, REPEAT_SLICE_PASSES + 1):
		var result := await _run_action(&"slice", _key.bind(KEY_F))
		if result.is_empty():
			return
		var current := _fragment_ids()
		var changed := 0
		var created := 0
		var replaced := 0
		var skipped_previous_counts: Array[int] = []
		for index in current.size():
			var added := 0
			var removed := 0
			for id in current[index]:
				if not previous[index].has(id):
					added += 1
			for id in previous[index]:
				if not current[index].has(id):
					removed += 1
			if added == 0:
				skipped_previous_counts.append(previous[index].size())
				_expect(removed == 0, "F pass %d preserves all pieces of skipped target %d" % [pass_number, index])
			else:
				changed += 1
				created += added
				replaced += removed
				var expected_replacements := int(pass_number > 1)
				_expect(added >= 2 and removed == expected_replacements
						and current[index].size() <= PlaneSlicing.MAX_FRAGMENTS,
						"F pass %d replaces only the cut piece of target %d within the fragment cap" % [pass_number, index])
				if pass_number > 1:
					largest_recut_growth = maxi(largest_recut_growth, added - removed)
		_expect(changed == int(result.get("targets", -1)) and created == int(result.get("fragments", -1))
				and target_count - changed == int(result.get("skipped", -1))
				and int(result.get("cuts", 0)) >= changed and created > replaced,
				"F pass %d accounts for each new fragment, recut and skipped target" % pass_number)
		if pass_number < REPEAT_SLICE_PASSES:
			_expect(changed == target_count, "F pass %d cuts every target" % pass_number)
		else:
			# One recut can replace its input with several disconnected pieces.
			_expect(skipped_previous_counts.all(func(count: int) -> bool:
				return PlaneSlicing.MAX_FRAGMENTS - count < largest_recut_growth),
				"F pass %d skips only targets near the fragment cap (prior counts %s)"
				% [pass_number, skipped_previous_counts])
		print("MASS_RANGE_REPEAT_PASS=", JSON.stringify({
			"pass": pass_number,
			"changed_targets": changed,
			"created_fragments": created,
			"replaced_fragments": replaced,
			"skipped_previous_counts": skipped_previous_counts,
			"largest_recut_growth": largest_recut_growth,
		}))
		if pass_number == 1:
			_verify_slice(result)
		await _sample_room(pass_number)
		if pass_number == 1:
			suspended_colliders = _source_colliders_in_world().size()
			_expect(suspended_colliders == 0, "F removes hidden rig colliders from the world (%d remain)"
				% suspended_colliders)
		_expect(_fragment_ids() == current, "F pass %d keeps all published pieces between inputs" % pass_number)
		previous = current
	if settle_ms > 0:
		await create_timer(settle_ms / 1000.0).timeout
		await _sample_room(REPEAT_SLICE_PASSES, true)
		_expect(_fragment_ids() == previous, "all published pieces persist while the room settles")
	if not (await _run_action(&"reset", _key.bind(KEY_R))).is_empty():
		await physics_frame
		_verify_reset()
		var restored_colliders := _source_colliders_in_world()
		_expect(restored_colliders == original_colliders,
			"R restores every original physical bone and hitbox to the world")
		print("MASS_RANGE_SOURCE_COLLIDERS=", JSON.stringify({
			"before_f": original_colliders.size(),
			"after_f": suspended_colliders,
			"after_r": restored_colliders.size(),
		}))


func _run_action(action: StringName, send: Callable) -> Dictionary:
	var observe_reveal := action == &"dismember" and _slice_count() == 0
	var reveal_counts: Array[int] = []
	var observed_staged_limbs := false
	var observed_invalid_staged_limbs := false
	var physics_active := true
	if observe_reveal:
		reveal_counts.append(_dismembered_target_counts().x)
	var start := Time.get_ticks_usec()
	send.call()
	var input_ms := (Time.get_ticks_usec() - start) * 0.001
	var previous := start
	var frame_gaps: Array[float] = []
	var slice_counts: Array[int] = []
	if action == &"slice":
		slice_counts.append(_slice_count())
	while arena.mass_action_active or arena.last_mass_action.get("action", &"") != action:
		if Time.get_ticks_usec() - start > TIMEOUT_USEC:
			_expect(false, "%s did not finish within the test deadline" % action)
			return {}
		await process_frame
		var now := Time.get_ticks_usec()
		frame_gaps.append((now - previous) * 0.001)
		previous = now
		if action == &"slice":
			var count := _slice_count()
			if slice_counts.back() != count:
				slice_counts.append(count)
		if observe_reveal:
			var counts := _dismembered_target_counts()
			observed_staged_limbs = observed_staged_limbs or counts.y > 0
			observed_invalid_staged_limbs = observed_invalid_staged_limbs or counts.z > 0
			physics_active = physics_active and PhysicsServer3D.space_is_active(arena.get_world_3d().space)
			if reveal_counts.back() != counts.x:
				reveal_counts.append(counts.x)
	var result: Dictionary = arena.last_mass_action.duplicate()
	print("MASS_RANGE_ACTION=", JSON.stringify({
		"action": action,
		"input_ms": input_ms,
		"wall_ms": (Time.get_ticks_usec() - start) * 0.001,
		"frame_gaps": _summarize(frame_gaps),
		"targets": result.get("targets", -1),
		"cuts": result.get("cuts", -1),
		"fragments": result.get("fragments", -1),
		"skipped": result.get("skipped", 0),
		"publish_ms": result.get("publish_ms", 0.0),
		"publish_physics_frame": result.get("publish_physics_frame", -1),
		"staging_ms": result.get("staging_ms", 0.0),
		"release_ms": result.get("release_ms", 0.0),
		"release_physics_frame": result.get("release_physics_frame", -1),
		"launched_limbs": result.get("launched_limbs", 0),
		"blasted_fragments": result.get("blasted_fragments", 0),
		"slice_count_changes": slice_counts,
		"visible_dismembered_target_counts": reveal_counts,
	}))
	if action == &"slice":
		_expect(slice_counts.has(target_count)
			and slice_counts.all(func(count: int) -> bool: return count == 0 or count == target_count),
			"no partially published target count is visible between process frames")
	if observe_reveal:
		_expect(reveal_counts == [0, target_count],
			"all fresh rigs reveal native detached limbs on one visible frame")
		_expect(observed_staged_limbs and not observed_invalid_staged_limbs,
			"native limbs stay hidden, noncolliding and out of physics while staged")
		_expect(physics_active, "the world physics space stays active throughout RMB")
	return result


func _verify_dismember(result: Dictionary) -> void:
	_expect(int(result.get("targets", 0)) == target_count and not result.get("cancelled", false),
		"RMB affects every fresh rig")
	_expect(PhysicsServer3D.space_is_active(arena.get_world_3d().space),
		"the range physics space is active after the native limb release")
	var root_sets := {}
	var count_variants := {}
	var source_rids := {}
	var cuts := 0
	for index in arena.targets.size():
		var target: Dictionary = arena.targets[index]
		var component: GoreComponent = target.component
		var severed: PackedStringArray = component.get_dismembered_bones()
		var limbs: Array = component.get_all_dismembered_limbs()
		var source: ArrayMesh = target.mesh.mesh
		source_rids[source.get_rid()] = true
		_expect(not target.has("plane_slice") and not severed.is_empty() and limbs.size() == severed.size(),
			"target %d has native detached limbs without plane fragments" % index)
		for limb: DismemberedLimb in limbs:
			var bone := _limb_root_body(limb)
			_expect(limb.is_visible_in_tree() and limb.get_meta("target_index", -1) == index
					and bone != null and bone.is_simulating_physics() and bone.linear_velocity.is_finite()
					and bone.collision_layer == component.limb_collision_layer
					and bone.collision_mask == component.limb_collision_mask,
				"each released native limb is visible and simulates with its owner's collision settings")
			if unique_meshes:
				var pieces := limb.get_meshes()
				_expect(not pieces.is_empty() and pieces.all(func(piece: MeshInstance3D) -> bool:
					return piece.mesh != null and piece.mesh.get_rid() == source.get_rid()),
					"each detached piece shares only the geometry of its own unique source")
		severed.sort()
		root_sets[",".join(severed)] = true
		count_variants[severed.size()] = true
		cuts += severed.size()
	_expect(root_sets.size() > 1 and count_variants.size() > 1,
		"RMB randomizes the severed bone selections and their counts")
	_expect(int(result.get("cuts", -1)) == cuts, "the RMB result counts the recorded skeletal sever roots")
	_expect(int(result.get("launched_limbs", -1)) == cuts
			and int(result.get("release_physics_frame", -1)) >= 0,
		"the common physics release applies an impulse to every native limb")
	if unique_meshes:
		_expect(source_rids.size() == target_count,
			"all source mesh RIDs remain distinct after releasing the limbs")


func _verify_reset() -> void:
	_expect(PhysicsServer3D.space_is_active(arena.get_world_3d().space),
		"R leaves the range physics space active")
	_expect(_slice_count() == 0 and get_nodes_in_group(FRAGMENT_GROUP).is_empty(),
		"R clears the plane fragment state and detached scene bodies")
	for index in arena.targets.size():
		var target: Dictionary = arena.targets[index]
		var component: GoreComponent = target.component
		_expect(not target.ragdoll and target.missing.is_empty()
				and component.get_dismembered_bones().is_empty()
				and component.get_all_dismembered_limbs().is_empty(),
				"R restores native limb and ragdoll state for target %d" % index)


func _verify_slice(result: Dictionary) -> void:
	_expect(int(result.get("targets", 0)) == target_count and int(result.get("cuts", 0)) > target_count
			and int(result.get("skipped", 0)) == 0,
		"F cuts all targets and performs additional random cuts")
	var unique_angles := {}
	for plane: Plane in result.get("planes", []):
		if plane.is_finite() and not plane.normal.is_zero_approx():
			var normal := plane.normal if plane.normal.y >= 0.0 else -plane.normal
			unique_angles[normal.snapped(Vector3.ONE * 0.05)] = true
	_expect(unique_angles.size() > 1, "F picks distinct finite cut angles")
	var fragment_counts := {}
	var fragments := 0
	var sample: ArrayMesh
	for index in arena.targets.size():
		var target: Dictionary = arena.targets[index]
		var component: GoreComponent = target.component
		var bodies: Array = target.get("plane_slice", {}).get("fragments", [])
		_expect(component.get_dismembered_bones().is_empty() and bodies.size() >= 2,
			"F creates plane fragments and leaves native skeletal state clear for target %d" % index)
		fragment_counts[bodies.size()] = true
		fragments += bodies.size()
		for body: RigidBody3D in bodies:
			var visual := body.get_node_or_null("Mesh") as MeshInstance3D
			var collision := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
			var mesh := visual.mesh as ArrayMesh if visual != null else null
			var has_cap := false
			if mesh != null:
				for surface in mesh.get_surface_count():
					if mesh.surface_get_name(surface) == "Slice Cap":
						has_cap = true
						break
			_expect(body.is_inside_tree() and not body.freeze and body.get_meta("target_index", -1) == index
					and collision != null and collision.shape != null and has_cap,
					"each plane fragment is a live owned collider with a capped mesh")
			if has_cap and (sample == null or mesh.get_aabb().get_volume() < sample.get_aabb().get_volume()):
				sample = mesh
	_expect(fragment_counts.size() > 1, "F produces different fragment counts across the range")
	_expect(fragments == int(result.get("fragments", -1)) and fragments >= 2 * target_count,
		"the result reports the complete set of published bodies")
	_expect(sample != null and _is_closed(sample), "a sampled cut mesh has paired, oppositely wound edges")


func _is_closed(mesh: ArrayMesh) -> bool:
	var welded := {}
	var edges := {}
	for surface in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			return false
		var arrays := mesh.surface_get_arrays(surface)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var count := positions.size() if indices.is_empty() else indices.size()
		if count == 0 or count % 3 != 0:
			return false
		var ids := PackedInt32Array()
		ids.resize(positions.size())
		for vertex in positions.size():
			var point := positions[vertex]
			if not point.is_finite():
				return false
			if not welded.has(point):
				welded[point] = welded.size()
			ids[vertex] = welded[point]
		for start in range(0, count, 3):
			for corner in 3:
				var a_index := start + corner
				var b_index := start + (corner + 1) % 3
				var a := ids[a_index if indices.is_empty() else indices[a_index]]
				var b := ids[b_index if indices.is_empty() else indices[b_index]]
				if a == b:
					return false
				var edge := Vector2i(mini(a, b), maxi(a, b))
				var state: Vector2i = edges.get(edge, Vector2i.ZERO)
				edges[edge] = state + Vector2i(1, 1 if a < b else -1)
	return not edges.is_empty() and edges.values().all(func(state: Vector2i) -> bool:
		return state == Vector2i(2, 0))


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	unique_meshes = "--unique-meshes" in args
	full_detail = "--full-detail" in args
	if "--targets=20" in args:
		target_count = 20
	var settle_ms := 0
	for argument in args:
		if argument.begins_with("--physics-hz="):
			var rate := argument.trim_prefix("--physics-hz=")
			if not _expect(rate.is_valid_int() and rate.to_int() > 0, "the test tick rate is a positive integer"):
				await _finish()
				return
			Engine.physics_ticks_per_second = rate.to_int()
		elif argument.begins_with("--settle-ms="):
			settle_ms = maxi(0, argument.trim_prefix("--settle-ms=").to_int())
	if not _prepare_range():
		await _finish()
		return
	await create_timer(0.4).timeout
	var body: ArrayMesh = arena.targets[0].mesh.mesh
	print("MASS_RANGE_ENVIRONMENT=", JSON.stringify({
		"engine": Engine.get_version_info().string,
		"display": DisplayServer.get_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"cpu": OS.get_processor_name(),
		"window": str(root.size),
		"physics_backend": ProjectSettings.get_setting("physics/3d/physics_engine"),
		"physics_ticks": Engine.physics_ticks_per_second,
		"target_count": target_count,
		"unique_meshes": unique_meshes,
		"full_detail": full_detail,
		"body_triangles": body.surface_get_array_index_len(0) / 3,
	}))
	if "--repeat-slices" in args:
		await _run_repeated_slices(settle_ms)
		await _finish()
		return
	if "--slice-only" in args:
		var fresh_slice := await _run_action(&"slice", _key.bind(KEY_F))
		if not fresh_slice.is_empty():
			_verify_slice(fresh_slice)
		await _finish()
		return
	_print_memory("before_rmb")
	var sever := await _run_action(&"dismember", _mouse.bind(MOUSE_BUTTON_RIGHT))
	if sever.is_empty():
		await _finish()
		return
	_verify_dismember(sever)
	_print_memory("after_rmb")
	if "--dismember-only" in args:
		await _finish()
		return
	if "--transition" in args:
		var after_dismember := await _run_action(&"slice", _key.bind(KEY_F))
		_expect(int(after_dismember.get("targets", 0)) == target_count and _slice_count() == target_count,
			"F after RMB slices all dismembered targets")
	if (await _run_action(&"reset", _key.bind(KEY_R))).is_empty():
		await _finish()
		return
	await process_frame
	_verify_reset()
	var slice := await _run_action(&"slice", _key.bind(KEY_F))
	if slice.is_empty():
		await _finish()
		return
	_verify_slice(slice)
	if "--mixed" in args:
		var blast := await _run_action(&"dismember", _mouse.bind(MOUSE_BUTTON_RIGHT))
		_expect(int(blast.get("already_sliced", 0)) == target_count and int(blast.get("cuts", -1)) == 0
				and _slice_count() == target_count,
			"RMB launches existing plane fragments on already sliced rigs")
	if not (await _run_action(&"reset", _key.bind(KEY_R))).is_empty():
		await process_frame
		_verify_reset()
	if "--cancel" in args:
		_key(KEY_F)
		for frame in 3:
			await process_frame
		_expect(arena.mass_action_active and arena.mass_slice.is_running() and _slice_count() == 0,
			"F has started preparing when R cancels it")
		await _run_action(&"reset", _key.bind(KEY_R))
		await create_timer(0.25).timeout
		_expect(not arena.mass_slice.is_running() and arena.last_mass_action.get("action") == &"reset",
			"the cancelled worker batch cannot publish after R")
		_verify_reset()
		_mouse(MOUSE_BUTTON_RIGHT)
		for frame in 3:
			await process_frame
		var staged := _dismembered_target_counts()
		_expect(arena.mass_action_active and arena.mass_dismember.running and staged.x == 0 and staged.y > 0,
			"RMB has started staging hidden limbs when R cancels it")
		await _run_action(&"reset", _key.bind(KEY_R))
		await create_timer(0.25).timeout
		_expect(not arena.mass_dismember.running and arena.last_mass_action.get("action") == &"reset",
			"the cancelled native batch cannot release limbs after R")
		_verify_reset()
	await _finish()


func _print_memory(stage: String) -> void:
	print("MASS_RANGE_MEMORY=", JSON.stringify({
		"stage": stage,
		"godot_static_bytes": OS.get_static_memory_usage(),
		"render_buffer_bytes": Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED),
		"render_video_bytes": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
	}))


func _finish() -> void:
	if is_instance_valid(arena):
		if arena.is_inside_tree():
			arena.queue_free()
			await process_frame
		else:
			arena.free()
	await process_frame
	if DisplayServer.get_name() != "headless":
		await create_timer(0.25).timeout
	print("MASS_RANGE_CHECKS=%d FAILURES=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
