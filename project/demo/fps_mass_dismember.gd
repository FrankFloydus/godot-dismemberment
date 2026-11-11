extends RefCounted
## Prepare native skeletal cuts across frames, then launch the range in one physics tick.

const CHAINS := [
	[&"Head"],
	[&"LeftArm", &"LeftForeArm", &"LeftHand"],
	[&"RightArm", &"RightForeArm", &"RightHand"],
	[&"LeftUpLeg", &"LeftLeg", &"LeftFoot"],
	[&"RightUpLeg", &"RightLeg", &"RightFoot"],
]
const MAX_CUTS_PER_TARGET := 4
const MIN_CUTS_PER_FRAME := 3
const MAX_CUTS_PER_FRAME := 8
const FRAME_BUDGET_USEC := 16000
const BODY_CENTER_HEIGHT := 1.03

var running := false
var _cancelled := false
var _random := RandomNumberGenerator.new()
var _prepared_bursts: Array[Node3D] = []


func cancel() -> void:
	_cancelled = true
	_discard_unattached_bursts()


func run(arena: Node3D, targets: Array[Dictionary], impulse: float, upward_boost: float) -> Dictionary:
	if running:
		return {"busy": true}

	var tree := arena.get_tree()
	var report := {
		"targets": 0,
		"cuts": 0,
		"already_sliced": 0,
		"cancelled": false,
		"frames": 0,
		"cut_counts": [],
		"severed_bones": [],
		"staging_ms": 0.0,
		"release_ms": 0.0,
		"release_physics_frame": -1,
		"publish_physics_frame": -1,
		"launched_limbs": 0,
		"blasted_fragments": 0,
	}
	if tree == null or not ClassDB.class_has_method(&"DismembermentComponent", &"stage_dismember_limb"):
		return report

	running = true
	_cancelled = false

	var started := Time.get_ticks_usec()
	var frame_started := started
	var frame_cuts := 0
	var staged: Array[Dictionary] = []
	var cut_counts: Array = report.cut_counts
	var severed_bones: Array = report.severed_bones
	cut_counts.resize(targets.size())
	cut_counts.fill(0)
	severed_bones.resize(targets.size())
	var order := range(targets.size())
	for end in range(order.size() - 1, 0, -1):
		var other := _random.randi_range(0, end)
		var index: int = order[end]
		order[end] = order[other]
		order[other] = index

	for index: int in order:
		var severed: Array[StringName] = []
		severed_bones[index] = severed
		if _cancelled or not is_instance_valid(arena):
			break

		var target := targets[index]
		var actor: Node3D = target.actor
		if not is_instance_valid(actor):
			continue
		var center := actor.to_global(Vector3.UP * BODY_CENTER_HEIGHT)
		if target.has("plane_slice"):
			staged.append({"fragments": target.plane_slice.fragments, "center": center})
			continue

		var component: GoreComponent = target.component
		if not is_instance_valid(component) or component.disable_dismemberment:
			continue
		var bones := _choose_bones(target, component)
		if bones.is_empty():
			continue
		var snapshot := _snapshot_pose(arena, target.mesh)
		if snapshot == null:
			continue
		var prepared := {
			"target": target,
			"actor_visible": actor.visible,
			"snapshot": snapshot,
			"limbs": [],
		}
		actor.hide()
		staged.append(prepared)
		for bone in bones:
			if _cancelled or not is_instance_valid(arena) or not is_instance_valid(component) \
					or target.has("plane_slice"):
				break
			var mapped := StringName(component.remapped_bones.get(bone, bone))
			if target.missing.has(mapped):
				continue
			var velocity := _limb_velocity(target, mapped, center, impulse, upward_boost)
			var cut := _stage_cut(component, bone, velocity)
			if not cut.is_empty():
				if prepared.limbs.is_empty() and component.enable_blood_particles \
						and not component.override_blood_particles:
					var burst := component.spawn_blood_particles(cut.limb.get_bone_transform().origin,
						velocity.normalized(), false) as Node3D
					if burst != null:
						cut["burst"] = burst
						_prepared_bursts.append(burst)
				prepared.limbs.append(cut)
				severed.append(mapped)
				report.cuts += 1
			frame_cuts += 1
			if frame_cuts >= MAX_CUTS_PER_FRAME or (frame_cuts >= MIN_CUTS_PER_FRAME \
					and Time.get_ticks_usec() - frame_started >= FRAME_BUDGET_USEC):
				report.frames += 1
				await tree.process_frame
				frame_started = Time.get_ticks_usec()
				frame_cuts = 0
		cut_counts[index] = severed.size()
		if not severed.is_empty():
			report.targets += 1

	# The old posed meshes cover all intermediate cuts. Reveal the prepared
	# bodies before the same physics step without pausing the range.
	await tree.physics_frame
	var release_started := Time.get_ticks_usec()
	report.staging_ms = (release_started - started) / 1000.0
	report.cancelled = _cancelled or not is_instance_valid(arena)
	if not report.cancelled:
		report.release_physics_frame = Engine.get_physics_frames()
		report.publish_physics_frame = report.release_physics_frame
	_release_staged(staged, report, impulse, upward_boost)
	_discard_unattached_bursts()
	report.release_ms = (Time.get_ticks_usec() - release_started) / 1000.0
	running = false
	return report


func _discard_unattached_bursts() -> void:
	for burst in _prepared_bursts:
		if is_instance_valid(burst) and not burst.is_inside_tree():
			burst.free()
	_prepared_bursts.clear()


func _snapshot_pose(arena: Node3D, source: MeshInstance3D) -> MeshInstance3D:
	if not is_instance_valid(source) or source.mesh == null:
		return null
	var snapshot := MeshInstance3D.new()
	snapshot.name = "MassDismemberPose"
	snapshot.add_to_group(&"mass_dismember_pose")
	snapshot.mesh = source.mesh
	snapshot.visible = source.is_visible_in_tree()
	snapshot.skeleton = NodePath()
	snapshot.layers = source.layers
	snapshot.cast_shadow = source.cast_shadow
	snapshot.gi_mode = source.gi_mode
	snapshot.custom_aabb = source.custom_aabb
	snapshot.material_override = source.material_override
	snapshot.material_overlay = source.material_overlay
	for surface in source.get_surface_override_material_count():
		snapshot.set_surface_override_material(surface, source.get_surface_override_material(surface))
	for blend in source.get_blend_shape_count():
		snapshot.set_blend_shape_value(blend, source.get_blend_shape_value(blend))
	arena.add_child(snapshot)
	snapshot.global_transform = source.global_transform
	snapshot.reset_physics_interpolation()
	var skin_reference := source.get_skin_reference()
	if skin_reference != null:
		var source_palette := skin_reference.get_skeleton()
		if source_palette.is_valid():
			var count := RenderingServer.skeleton_get_bone_count(source_palette)
			var palette := RenderingServer.skeleton_create()
			RenderingServer.skeleton_allocate_data(palette, count)
			for bone in count:
				RenderingServer.skeleton_bone_set_transform(palette, bone,
					RenderingServer.skeleton_bone_get_transform(source_palette, bone))
			RenderingServer.instance_attach_skeleton(snapshot.get_instance(), palette)
			snapshot.tree_exiting.connect(_free_palette.bind(snapshot.get_instance(), palette), CONNECT_ONE_SHOT)
	return snapshot


static func _free_palette(instance: RID, palette: RID) -> void:
	RenderingServer.instance_attach_skeleton(instance, RID())
	RenderingServer.free_rid(palette)


func _stage_cut(component: GoreComponent, bone: StringName, velocity: Vector3) -> Dictionary:
	# Stage the native limb without emitting effects while the snapshot is visible.
	var particles := component.enable_blood_particles
	var pool := component.enable_blood_pool_decal
	var painting := component.enable_blood_skin_painting
	component.enable_blood_particles = false
	component.enable_blood_pool_decal = false
	component.enable_blood_skin_painting = false
	var limb := component.call(&"stage_dismember_limb", bone) as DismemberedLimb
	component.enable_blood_particles = particles
	component.enable_blood_pool_decal = pool
	component.enable_blood_skin_painting = painting
	if not is_instance_valid(limb):
		return {}
	return {"limb": limb, "velocity": velocity}


func _release_staged(staged: Array[Dictionary], report: Dictionary, impulse: float, upward_boost: float) -> void:
	for entry in staged:
		if entry.has("fragments"):
			if not report.cancelled:
				var launched := _launch_fragments(entry.fragments, entry.center, impulse, upward_boost)
				if launched > 0:
					report.targets += 1
					report.already_sliced += 1
					report.blasted_fragments += launched
			continue

		var snapshot: MeshInstance3D = entry.snapshot
		if is_instance_valid(snapshot):
			snapshot.hide()
			snapshot.queue_free()
		var target: Dictionary = entry.target
		var actor: Node3D = target.actor
		if is_instance_valid(actor):
			actor.visible = entry.actor_visible
		if not report.cancelled and is_instance_valid(actor) and not entry.limbs.is_empty():
			var component: GoreComponent = target.component
			# Mass cuts keep their release burst and decal without rebuilding
			# the entire source and detached mesh for every wound.
			var painting := component.enable_blood_skin_painting
			component.enable_blood_skin_painting = false
			for cut: Dictionary in entry.limbs:
				if is_instance_valid(cut.limb) and not cut.limb.is_queued_for_deletion() \
						and component.call(&"release_staged_limb", cut.limb, cut.velocity):
					report.launched_limbs += 1
			component.enable_blood_skin_painting = painting
			_launch_source(target, impulse, upward_boost)
			_spawn_release_fx(component, entry.limbs[0])


func _spawn_release_fx(component: GoreComponent, cut: Dictionary) -> void:
	if not is_instance_valid(component) or not is_instance_valid(cut.limb):
		return
	var location: Vector3 = cut.limb.get_bone_transform().origin
	var direction: Vector3 = cut.velocity.normalized()
	if component.enable_blood_particles:
		var burst: Node3D = cut.get("burst")
		if is_instance_valid(burst) and not component.override_blood_particles:
			var parent := component.get_tree().current_scene
			if parent == null:
				parent = component.get_parent()
			parent.add_child(burst)
		else:
			component.spawn_blood_particles(location, direction)
	if component.enable_blood_pool_decal:
		var trace := Vector3(direction.x, -0.7, direction.z)
		var query := PhysicsRayQueryParameters3D.create(location, location + trace * 20.0,
			component.allowed_surface_types_for_blood_decals)
		var hit := component.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			component.spawn_blood_decal(hit.position, hit.normal, hit.collider as Node3D, direction)


func _choose_bones(target: Dictionary, component: GoreComponent) -> Array[StringName]:
	var skeleton: Skeleton3D = target.skeleton
	var choices: Array[StringName] = []
	for chain: Array in CHAINS:
		var eligible: Array[StringName] = []
		for bone: StringName in chain:
			var mapped := StringName(component.remapped_bones.get(bone, bone))
			if skeleton.find_bone(mapped) >= 0 and not target.missing.has(mapped) \
					and component.check_bone_filter(mapped):
				eligible.append(bone)
		if not eligible.is_empty():
			choices.append(eligible[_random.randi_range(0, eligible.size() - 1)])

	var selected: Array[StringName] = []
	if not choices.is_empty():
		for cut in _random.randi_range(1, mini(MAX_CUTS_PER_TARGET, choices.size())):
			selected.append(choices.pop_at(_random.randi_range(0, choices.size() - 1)))
	return selected


func _limb_velocity(target: Dictionary, mapped: StringName, center: Vector3,
		impulse: float, upward_boost: float) -> Vector3:
	var skeleton: Skeleton3D = target.skeleton
	var physical: PhysicalBone3D = target.physics_bodies.get(mapped)
	var limb_position := physical.global_position if is_instance_valid(physical) and physical.is_simulating_physics() \
		else skeleton.to_global(skeleton.get_bone_global_pose(skeleton.find_bone(mapped)).origin)
	var hip: PhysicalBone3D = target.physics_bodies.get(&"Hips")
	if is_instance_valid(hip) and hip.is_simulating_physics():
		center = hip.global_position
	return _blast_velocity(limb_position - center, impulse, upward_boost)


func _launch_source(target: Dictionary, impulse: float, upward_boost: float) -> void:
	var skeleton: Skeleton3D = target.skeleton
	if not is_instance_valid(skeleton):
		return
	if not target.ragdoll:
		var remaining: Array[StringName] = []
		for bone: StringName in target.physics_bodies:
			if not target.missing.has(bone):
				remaining.append(bone)
		if remaining.is_empty():
			return
		skeleton.physical_bones_start_simulation(remaining)
		target.ragdoll = true
	var hip: PhysicalBone3D = target.physics_bodies.get(&"Hips")
	if is_instance_valid(hip) and hip.is_simulating_physics():
		var velocity := _blast_velocity(Vector3.ZERO, impulse * 0.44, upward_boost * 0.66)
		hip.apply_central_impulse(velocity * hip.mass)


func _launch_fragments(fragments: Array, center: Vector3, impulse: float, upward_boost: float) -> int:
	var launched := 0
	for fragment: RigidBody3D in fragments:
		if not is_instance_valid(fragment) or fragment.is_queued_for_deletion() or fragment.freeze:
			continue
		var velocity := _blast_velocity(fragment.global_position - center, impulse, upward_boost)
		fragment.apply_central_impulse(velocity * fragment.mass)
		launched += 1
	return launched


func _blast_velocity(offset: Vector3, impulse: float, upward_boost: float) -> Vector3:
	var horizontal := Vector3(offset.x, 0.0, offset.z)
	var angle := _random.randf_range(-PI, PI)
	var scatter := Vector3(cos(angle), 0.0, sin(angle))
	var outward := (horizontal.normalized() + scatter * 0.38).normalized()
	var speed := maxf(impulse, 2.8) * _random.randf_range(0.85, 1.28)
	var lift := maxf(upward_boost, 1.2) * _random.randf_range(0.75, 1.22)
	return outward * speed + Vector3.UP * lift
