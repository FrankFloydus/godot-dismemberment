extends SceneTree
## Authored scene structure must exist before the FPS controller enters the tree.

const DEMO_PATH := "res://demo/demo.tscn"
const RANGE_PATH := "res://demo/fps_range.tscn"
const STATION_NAMES := [&"Humanoid", &"Articulated", &"Modular"]

var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("AUTHORED_DEMO: " + message)

func _finish() -> void:
	print("AUTHORED_DEMO_CHECKS=%d FAILURES=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _check_authored_station(station: Node, label: String) -> void:
	_expect(station != null, label + " exists in the saved station list")
	if station == null:
		return
	var skeleton := station.get_node_or_null("Target/Skeleton3D") as Skeleton3D
	var component := station.get_node_or_null("Target/GoreComponent")
	_expect(component != null and component.is_class("GoreComponent"),
		label + " has its native component before play")
	_expect(station.get_node_or_null("PlayerSpawn") is Marker3D
		and station.get_node_or_null("InitialAim") is Marker3D,
		label + " has editable spawn and aim markers")
	_expect(skeleton != null and skeleton.find_bone("Hips") >= 0,
		label + " has its normalized skeleton before play")
	if skeleton == null:
		return
	var skin_mesh := skeleton.get_node_or_null("SkinMesh") as MeshInstance3D
	_expect(skin_mesh != null and skin_mesh.mesh != null and skin_mesh.skin != null,
		label + " has a visible skinned mesh before play")
	var bodies := skeleton.find_children("*", "PhysicalBone3D", true, false)
	_expect(bodies.size() == 17, label + " has 17 authored physical bones")
	var fitted_shapes := true
	for body in bodies:
		var collider := body.get_node_or_null("AuthoredCollision") as CollisionShape3D
		if collider == null or collider.shape == null:
			fitted_shapes = false
	_expect(fitted_shapes, label + " has the saved ragdoll collision shapes")
	var hitbox := skeleton.get_node_or_null("Hit_LeftArm") as Area3D
	_expect(hitbox != null and hitbox.get_meta("bone", &"") == &"LeftArm"
		and hitbox.get_child_count() > 0,
		label + " has an authored bone hitbox before play")

func _check_wrapped_spawn() -> void:
	var wrapped_scene := load("res://demo/modular.tscn") as PackedScene
	_expect(wrapped_scene != null, "modular entry scene loads")
	if wrapped_scene == null:
		return
	var arena := wrapped_scene.instantiate() as Node3D
	var player := arena.get_node_or_null("FirstPersonPlayer") as CharacterBody3D
	var spawn := arena.get_node_or_null("Stations/Modular/PlayerSpawn") as Marker3D
	_expect(player != null and spawn != null,
		"modular entry scene inherits the authored player and spawn marker")
	if player == null or spawn == null:
		arena.free()
		return
	spawn.position.x += 0.3
	root.add_child(arena)
	_expect(arena.active_station == 2, "modular entry scene starts at its saved station")
	_expect(player.global_position.is_equal_approx(spawn.global_position),
		"initial spawn uses the edited marker position")
	arena.queue_free()
	await process_frame

func _check_detached_impact(arena: Node3D, component: GoreComponent, camera: Camera3D) -> void:
	for frame in 120:
		await physics_frame
	var limb := component.get_dismembered_limb_by_name(&"LeftArm") as DismemberedLimb
	_expect(is_instance_valid(limb), "the first shot creates a detached limb for the impact test")
	if not is_instance_valid(limb):
		return
	var skeleton := limb.get_ragdoll_skeleton()
	var physical_bone: PhysicalBone3D
	if skeleton != null:
		physical_bone = skeleton.get_node_or_null("Physics_LeftArm") as PhysicalBone3D
	_expect(is_instance_valid(physical_bone), "the detached limb has a physical arm collider")
	if not is_instance_valid(physical_bone):
		return
	var moved_position := physical_bone.global_position
	var original_cut: Transform3D = limb.get_bone_transform()
	_expect(moved_position.distance_to(original_cut.origin) > 0.2,
		"the detached arm has moved away from the original cut")

	# Use the source station's custom burst to identify exactly which effect was spawned.
	var burst := Node3D.new()
	burst.set_meta("detached_hit_probe", true)
	var burst_scene := PackedScene.new()
	var pack_result := burst_scene.pack(burst)
	burst.free()
	_expect(pack_result == OK, "test particle override packs")
	if pack_result != OK:
		return
	component.override_blood_particles = true
	component.fx_blood_burst = burst_scene
	component.blood_particle_scale = 1.4
	arena.active_station = 2

	var ray: Dictionary = {}
	for offset in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		arena.player.global_position += moved_position + offset * 1.25 - camera.global_position
		arena._look_at(moved_position)
		var candidate: Dictionary = arena._raycast_camera()
		var collider := candidate.get("collider") as Node
		if collider != null and (collider == limb or limb.is_ancestor_of(collider)):
			ray = candidate
			break
	_expect(not ray.is_empty(), "a camera ray hits the moved detached arm")
	if ray.is_empty():
		return

	arena.shot_cooldown = 0.0
	var audio = arena.range_audio
	var hit_voice: AudioStreamPlayer3D = audio._body_voices[audio._next_body_voice]
	var impact: Dictionary = arena._shoot()
	_expect(impact.get("detached", false), "the moved arm is handled as a detached impact")
	_expect(hit_voice.stream == audio.flesh_hits and hit_voice.global_position.distance_to(ray.position) < 0.001,
		"detached hits play the flesh sound at the actual contact")
	var effects := arena.get_children().filter(func(node: Node) -> bool:
		return node.has_meta("detached_hit_probe")
	)
	_expect(effects.size() == 1, "the burst uses the detached limb owner's settings")
	if effects.size() == 1:
		var effect := effects[0] as Node3D
		var hit_position: Vector3 = ray.position
		_expect(effect.global_position.distance_to(hit_position) < 0.001,
			"blood particles spawn at the detached collider's exact ray impact")
		_expect(effect.global_basis.get_scale().is_equal_approx(Vector3.ONE * component.blood_particle_scale),
			"the detached impact preserves the station particle scale")

	component.enable_blood_particles = false
	arena.shot_cooldown = 0.0
	var muted_impact: Dictionary = arena._shoot()
	var muted_effects := arena.get_children().filter(func(node: Node) -> bool:
		return node.has_meta("detached_hit_probe")
	)
	_expect(muted_impact.get("detached", false) and muted_effects.size() == effects.size(),
		"the source station's particle toggle also controls detached impacts")

func _run() -> void:
	var packed_scene := load(DEMO_PATH) as PackedScene
	_expect(packed_scene != null, "main FPS scene loads")
	if packed_scene == null:
		_finish()
		return
	# Opening the range's own editor tab reloads the already cached dependency.
	var reloaded_range := ResourceLoader.load(RANGE_PATH, "", ResourceLoader.CACHE_MODE_REPLACE) as PackedScene
	_expect(reloaded_range != null, "the cached range reloads as a standalone scene")
	var arena := packed_scene.instantiate() as Node3D
	var authored_range := arena.get_node_or_null("Range")
	var player := arena.get_node_or_null("FirstPersonPlayer") as CharacterBody3D
	var camera := arena.get_node_or_null("FirstPersonPlayer/FirstPersonCamera") as Camera3D
	_expect(authored_range != null and authored_range.find_child("BloodReceivingFloor", true, false) is StaticBody3D,
		"range and solid floor exist before play")
	if authored_range != null:
		var batches := authored_range.find_children("*", "MultiMeshInstance3D", true, false)
		var batches_ready := batches.size() == 12
		for batch: MultiMeshInstance3D in batches:
			var mesh := batch.multimesh
			batches_ready = (batches_ready and mesh != null and mesh.transform_format == MultiMesh.TRANSFORM_3D
				and mesh.instance_count > 0)
		_expect(batches_ready, "reloading preserves the twelve authored 3D prop batches")
	_expect(player != null and camera != null
		and camera.get_node_or_null("ImpulseProjector/Muzzle") is Marker3D,
		"player, camera, and muzzle exist before play")
	_expect(arena.get_node_or_null("HUD/Screen") is Control, "HUD exists before play")

	var editable_impulse_properties := PackedStringArray()
	for property in arena.get_property_list():
		var name := String(property.name)
		if name in ["dismemberment_impulse", "dismemberment_upward_boost"]:
			var usage: int = property.usage
			if (usage & PROPERTY_USAGE_EDITOR) != 0 and (usage & PROPERTY_USAGE_STORAGE) != 0:
				editable_impulse_properties.append(name)
	_expect(editable_impulse_properties.size() == 2,
		"both dismemberment impulse settings are editable and saveable in the Inspector")

	for station_name in STATION_NAMES:
		_check_authored_station(arena.get_node_or_null("Stations/" + String(station_name)),
			String(station_name))
	var component := arena.get_node_or_null("Stations/Humanoid/Target/GoreComponent")
	# A broken scene should fail the structural checks without attempting to
	# run a controller with missing scene dependencies.
	if failures > 0 or component == null or camera == null:
		arena.free()
		_finish()
		return

	arena.dismemberment_impulse = 2.35
	arena.dismemberment_upward_boost = 0.31
	var cut := {}
	component.connect("pre_dismemberment", func(bone: StringName, impulse: Vector3) -> void:
		cut["bone"] = bone
		cut["impulse"] = impulse
	)
	root.add_child(arena)
	current_scene = arena
	arena.testing = true
	arena.set_process_unhandled_input(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for frame in 4:
		await physics_frame
	_expect(arena._aim_at_bone(0, &"LeftArm"), "camera can aim at the saved LeftArm hitbox")
	for frame in 3:
		await physics_frame
	var expected_impulse := -camera.global_basis.z * 2.35 + Vector3.UP * 0.31
	var audio = arena.range_audio
	var voice_index: int = audio._next_body_voice
	var sever_voice: AudioStreamPlayer3D = audio._body_voices[voice_index]
	var shot: Dictionary = arena._shoot()
	_expect(shot.get("bone", &"") == &"LeftArm", "actual physics ray hits the saved LeftArm hitbox")
	_expect(sever_voice.stream == audio.sever_sounds
		and sever_voice.global_position.distance_to(shot.get("position", Vector3.INF)) < 0.001,
		"a successful cut plays the distinct sever sound at the ray contact")
	_expect(audio._next_body_voice == (voice_index + 1) % audio._body_voices.size(),
		"the shell uses one body audio voice for its severed subject")
	_expect(cut.get("bone", &"") == &"LeftArm", "the shot calls the native cut for LeftArm")
	var applied_impulse: Vector3 = cut.get("impulse", Vector3.ZERO)
	_expect(applied_impulse.is_equal_approx(expected_impulse),
		"the native cut receives the edited forward impulse and upward boost")
	await _check_detached_impact(arena, component as GoreComponent, camera)
	arena.queue_free()
	await process_frame
	await _check_wrapped_spawn()
	_finish()
