extends SceneTree

const IMPACT_GROUP := &"Shotgun Impact"
var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("SHOTGUN_IMPACTS: " + message)

func wait_for_physics(count: int) -> void:
	for frame in count:
		await physics_frame
	await process_frame

func _run() -> void:
	var arena = load("res://demo/demo.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena
	arena.testing = true
	arena.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	await wait_for_physics(3)
	arena.pellet_count = 8
	arena.pellet_spread_degrees = 2.6
	arena.player.global_position = Vector3(0, -0.055, -3.9)
	arena.player.velocity = Vector3.ZERO
	arena._look_at(Vector3(0.72, 2.36, -10.53))
	await wait_for_physics(3)
	var burst_pool := arena.get_node_or_null(^"ShotgunImpactBursts") as Node3D
	var burst_slots := burst_pool.get_children() if burst_pool != null else []
	expect(burst_slots.size() == 32 and _emitting_bursts(burst_pool).is_empty(),
		"the surface particle pool is allocated and idle before the first shot")
	var center: Dictionary = arena._raycast_camera()
	expect(not center.is_empty() and center.collider.name == &"ShotBackboard",
		"the actual center ray reaches the visible shot-only backboard")
	var shot: Dictionary = arena._shoot()
	expect(shot.get("pellets_fired", 0) == 8, "one trigger fires eight rays")
	expect(shot.get("environment_impacts", 0) == 8, "all eight pellets strike the visible backboard")
	var firing_bursts := _emitting_bursts(burst_pool)
	expect(firing_bursts.size() == 8, "every environment contact emits one burst on the first shot")
	await process_frame
	var marks := get_nodes_in_group(IMPACT_GROUP)
	expect(marks.size() == 8, "one mark is created per physical surface hit")
	var seen := {}
	var closest := INF
	for node in marks:
		var mark := node as Node3D
		var position := mark.global_position
		seen[Vector2i(roundi(position.x * 1000), roundi(position.y * 1000))] = true
		expect(absf(position.z - -10.53) < 0.04, "mark is at the visible surface")
		expect(mark.global_basis.y.normalized().dot(Vector3.BACK) > 0.999,
			"mark is aligned to the actual wall normal")
		if not center.is_empty():
			closest = minf(closest, position.distance_to(center.position))
	expect(seen.size() == 8, "pellet impacts are distributed across the spread")
	expect(closest < 0.04, "one pellet follows the exact center ray")
	var matched := 0
	for burst in firing_bursts:
		for mark in marks:
			if burst.global_transform.is_equal_approx(mark.global_transform):
				matched += 1
				break
	expect(matched == 8, "particles originate on the exact impact positions and surface normals")

	for shot_index in 16:
		arena.shot_cooldown = 0.0
		arena._shoot()
	await process_frame
	var marks_after_firing := get_nodes_in_group(IMPACT_GROUP).size()
	expect(marks_after_firing <= 96,
		"sustained firing keeps a bounded number of impact marks")
	expect(burst_pool != null and burst_pool.get_children() == burst_slots,
		"sustained firing reuses the same bounded set of particle emitters")
	await create_timer(0.4).timeout
	expect(_emitting_bursts(burst_pool).is_empty() and get_nodes_in_group(IMPACT_GROUP).size() == marks_after_firing,
		"the one-shot emitters return to idle while the impact marks remain")
	await _check_tracers(arena, burst_pool)
	await _check_floor_impact(arena, burst_pool)
	await _check_muzzle_particles(arena)
	# Let the audio server retire the last shot's playback after the arena exits.
	arena.queue_free()
	await create_timer(0.1).timeout

	print("SHOTGUN_IMPACTS_CHECKS=%d FAILURES=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _emitting_bursts(pool: Node3D) -> Array[Node3D]:
	var active: Array[Node3D] = []
	if pool != null:
		for burst in pool.get_children():
			var sparks := burst.get_node(^"Sparks") as CPUParticles3D
			var smoke := burst.get_node(^"Smoke") as CPUParticles3D
			if sparks.emitting or smoke.emitting:
				active.append(burst)
	return active

func _check_floor_impact(arena, burst_pool: Node3D) -> void:
	await create_timer(0.4).timeout
	arena.shot_collision_mask = 1
	arena.pellet_count = 1
	arena._look_at(Vector3(1.7, -0.03, -5.8))
	arena.shot_cooldown = 0.0
	var hit: Dictionary = arena._raycast_camera()
	expect(not hit.is_empty() and hit.collider.name == &"BloodReceivingFloor"
		and hit.normal.is_equal_approx(Vector3.UP), "the downward ray hits the visible floor")
	var shot: Dictionary = arena._shoot()
	var active := _emitting_bursts(burst_pool)
	expect(shot.get("environment_impacts", 0) == 1 and active.size() == 1,
		"the floor hit reuses one burst after wall and mixed shots")
	if hit.is_empty() or active.size() != 1:
		return
	var burst := active[0]
	var sparks := burst.get_node(^"Sparks") as CPUParticles3D
	var smoke := burst.get_node(^"Smoke") as CPUParticles3D
	expect(burst.global_position.is_equal_approx(hit.position) and burst.global_basis.y.is_equal_approx(hit.normal),
		"the recycled emitter starts at the floor contact and aligns to its normal")
	expect(sparks.local_coords and smoke.local_coords and sparks.direction.y > 0.0,
		"particle emission follows the current contact and points away from the floor")
	expect(smoke.color.a > sparks.color.a, "the floor uses the dust-dominant impact profile")

func _check_tracers(arena, burst_pool: Node3D) -> void:
	var traces := arena.get_node_or_null("PelletTraces") as MultiMeshInstance3D
	expect(traces != null and traces.multimesh != null, "the demo has a shared pellet trace mesh")
	if traces == null or traces.multimesh == null:
		return

	# Freeze the camera and advance the visual timers explicitly to avoid frame-time variance.
	arena.set_physics_process(false)
	arena.set_process(false)
	var camera: Camera3D = arena.camera
	var origin := camera.global_position
	var forward := -camera.global_basis.z
	var receiver := StaticBody3D.new()
	receiver.collision_layer = 1 << 30
	receiver.collision_mask = 0
	var shape := SphereShape3D.new()
	shape.radius = 0.015
	var collider := CollisionShape3D.new()
	collider.shape = shape
	receiver.add_child(collider)
	arena.add_child(receiver)
	receiver.global_position = origin + forward * 2.5
	arena.shot_collision_mask = receiver.collision_layer
	arena.shot_range = 7.0
	await wait_for_physics(3)

	var center: Dictionary = arena._raycast_camera()
	expect(center.get("collider") == receiver, "the small receiver catches the exact center ray")
	arena._process(0.15)
	expect(is_zero_approx(arena.flash_light.light_energy) and traces.multimesh.visible_instance_count == 0,
		"the preceding shots have finished before the mixed hit-and-miss shot")
	var muzzle: Marker3D = arena.muzzle
	var muzzle_children := muzzle.get_child_count()
	var previous_shots: int = arena.shots_fired
	arena.shot_cooldown = 0.0
	var shot: Dictionary = arena._shoot()
	expect(shot.get("environment_impacts", 0) == 1, "the center ray hits and seven rays miss")
	expect(_emitting_bursts(burst_pool).size() == 1, "misses do not emit surface particles")
	expect(traces.multimesh.visible_instance_count == 8, "every pellet draws a trace, including misses")
	if DisplayServer.get_name() != "headless" and center.has("position"):
		_check_trace_endpoints(traces, muzzle.global_position, origin, center.position, arena.shot_range)

	arena._process(0.02)
	if DisplayServer.get_name() != "headless" and center.has("position"):
		_check_trace_endpoints(traces, muzzle.global_position, origin, center.position, arena.shot_range)
	expect(arena.shots_fired == previous_shots + 1 and muzzle.get_child_count() == muzzle_children
		and arena.flash_light.light_energy > 0.0,
		"the entire shell uses one authored muzzle light")
	var material := traces.material_override as ShaderMaterial
	var initial_age: Variant = material.get_shader_parameter(&"trace_age") if material else null
	arena._process(0.05)
	var faded_age: Variant = material.get_shader_parameter(&"trace_age") if material else null
	expect(is_zero_approx(arena.flash_light.light_energy),
		"the muzzle light expires while pellet traces remain visible")
	expect(traces.multimesh.visible_instance_count == 8 and typeof(initial_age) == TYPE_FLOAT
		and typeof(faded_age) == TYPE_FLOAT and faded_age > initial_age,
		"the trace fade advances while all eight traces are still active")
	arena._process(0.08)
	expect(traces.multimesh.visible_instance_count == 0, "all traces disappear after their fade")

func _check_muzzle_particles(arena) -> void:
	var flash := arena.flash as Node3D
	var emitters: Array[CPUParticles3D] = []
	if flash != null:
		for path in [^"HotCore", ^"Flame", ^"Sparks"]:
			var emitter := flash.get_node_or_null(path) as CPUParticles3D
			if emitter != null:
				emitters.append(emitter)
	expect(emitters.size() == 3, "the muzzle has three native CPU particle emitters")
	if emitters.size() != 3:
		return

	var has_3d_meshes := not flash is MeshInstance3D and flash.find_children("*", "MeshInstance3D", true, false).is_empty()
	var finished: Array[CPUParticles3D] = []
	var longest_lifetime := 0.0
	for emitter in emitters:
		has_3d_meshes = has_3d_meshes and emitter.one_shot and _particle_mesh_has_volume(emitter)
		longest_lifetime = maxf(longest_lifetime, emitter.lifetime)
		emitter.finished.connect(func() -> void: finished.append(emitter), CONNECT_ONE_SHOT)
	expect(has_3d_meshes, "one-shot muzzle emitters draw 3D meshes without surface billboards")
	expect(flash.visible and emitters.all(func(emitter: CPUParticles3D) -> bool: return emitter.emitting),
		"one accepted shot starts the core, flame, and sparks together")

	# The scene's manual recoil and light timers do not drive native particle lifetimes.
	await create_timer(longest_lifetime * 2.0 + 0.08).timeout
	expect(finished.size() == 3 and not emitters.any(func(emitter: CPUParticles3D) -> bool: return emitter.emitting),
		"all muzzle particles finish through their own one-shot cycles")
	var rejected: Dictionary = arena._shoot()
	expect(rejected.get("cooldown", false)
		and not emitters.any(func(emitter: CPUParticles3D) -> bool: return emitter.emitting),
		"a trigger rejected during cooldown does not restart the emitters")

	var previous_shots: int = arena.shots_fired
	var previous_emitters := flash.get_children()
	arena.shot_cooldown = 0.0
	arena._shoot()
	expect(arena.shots_fired == previous_shots + 1
		and flash.get_children() == previous_emitters
		and emitters.all(func(emitter: CPUParticles3D) -> bool: return emitter.emitting),
		"the next accepted shot restarts the same three emitters")
	arena._jump_station((arena.active_station + 1) % arena.targets.size())
	expect(not flash.visible and is_zero_approx(arena.flash_light.light_energy)
		and not emitters.any(func(emitter: CPUParticles3D) -> bool: return emitter.emitting),
		"switching stations clears the active muzzle particles and light")

func _particle_mesh_has_volume(emitter: CPUParticles3D) -> bool:
	if emitter.mesh == null:
		return false
	var extent := emitter.mesh.get_aabb().size
	if minf(extent.x, minf(extent.y, extent.z)) <= 0.0:
		return false
	for surface_index in emitter.mesh.get_surface_count():
		var material := emitter.material_override as BaseMaterial3D
		if material == null:
			material = emitter.mesh.surface_get_material(surface_index) as BaseMaterial3D
		if material != null and material.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED:
			return false
	return true

func _check_trace_endpoints(traces: MultiMeshInstance3D, muzzle: Vector3, origin: Vector3,
		center_impact: Vector3, shot_range: float) -> void:
	var starts_at_muzzle := true
	var hit_count := 0
	var miss_count := 0
	var endpoints := {}
	for index in traces.multimesh.visible_instance_count:
		var segment := traces.global_transform * traces.multimesh.get_instance_transform(index)
		var half_length := segment.basis.y * 0.5
		var end := segment.origin + half_length
		starts_at_muzzle = starts_at_muzzle and (segment.origin - half_length).distance_to(muzzle) < 0.002
		endpoints[Vector3i(roundi(end.x * 1000), roundi(end.y * 1000), roundi(end.z * 1000))] = true
		if end.distance_to(center_impact) < 0.002:
			hit_count += 1
		elif absf(end.distance_to(origin) - shot_range) < 0.002:
			miss_count += 1
	expect(starts_at_muzzle, "all eight traces originate at the muzzle")
	expect(hit_count == 1 and miss_count == 7, "the hit trace ends at impact and the misses end at range")
	expect(endpoints.size() == 8, "the eight traced paths have distinct endpoints")
