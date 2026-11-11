extends Node3D
## First-person range for testing native skeletal cuts and posed mesh slashes.

const SHOTGUN_IMPACT := preload("res://demo/shotgun_impact.tscn")
const TRACER_SHADER := preload("res://demo/shotgun_tracer.gdshader")
const RangeAudio := preload("res://demo/fps_audio.gd")
const PlaneSlicing := preload("res://demo/fps_plane_slicing.gd")
const MuzzleFlashParticles := preload("res://demo/muzzle_flash_particles.gd")
const GOLDEN_ANGLE := 2.399963229728653
const MAX_PELLETS := 16
const MAX_IMPACT_MARKS := 96
const IMPACT_LIFETIME := 30.0
const TRACER_DURATION := 0.105
const TRACER_WIDTH := 0.012
const FLASH_LIGHT_DURATION := 0.04
const MIN_SLASH_DRAG := 24.0
const SLASH_SAMPLE_SPACING := 12.0
const MAX_SLASH_SEGMENTS := 48

@export_group("Stations")
## Station selected when this scene starts, in scene-tree order.
@export_range(0, 2) var initial_scenario := 0

@export_group("Shooting")
## Number of physics rays in one shotgun blast, including the exact center pellet.
@export_range(1, MAX_PELLETS) var pellet_count := 8
## Maximum angle from the center ray, in degrees. Blood-only and hide-only tools use the center ray.
@export_range(0.0, 12.0, 0.1, "suffix:°") var pellet_spread_degrees := 2.6
## Forward velocity change applied to a newly severed limb.
@export_range(0.0, 20.0, 0.01, "or_greater", "suffix:m/s") var dismemberment_impulse := 0.7
## Upward velocity change added to a dismemberment shot.
@export_range(0.0, 5.0, 0.01, "or_greater", "suffix:m/s") var dismemberment_upward_boost := 0.08
## Forward velocity change applied when a shot hits an already detached limb.
@export_range(0.0, 5.0, 0.01, "or_greater", "suffix:m/s") var detached_limb_hit_impulse := 0.15
## Minimum time in seconds between accepted shots.
@export_range(0.0, 2.0, 0.01, "or_greater", "suffix:s") var time_between_shots := 0.14
## Maximum distance in metres that the crosshair ray can travel.
@export_range(1.0, 200.0, 0.5, "or_greater", "suffix:m") var shot_range := 80.0
## Physics layers that shots can hit. Includes range surfaces, standing hitboxes, ragdoll bodies, and shot-only impact faces.
@export_flags_3d_physics var shot_collision_mask := 1 | 2 | 8 | 16
## Shader material for the pellet trails. Edit its Trace Color to tune the tint and intensity.
@export var tracer_material: ShaderMaterial
## Cutting any of these bones makes the remaining subject ragdoll.
@export var source_ragdoll_bones := PackedStringArray([
	"Head", "LeftUpLeg", "LeftLeg", "RightUpLeg", "RightLeg",
])

@export_group("Slash Gesture")
## Maximum distance from the camera at which a swipe can select a subject or fragment.
@export_range(0.5, 20.0, 0.1, "suffix:m") var slash_reach := 6.0
## Override for newly exposed cut surfaces. Leave empty to use the addon's textured default.
@export var slice_cap_material: Material
## Use fewer points in each slice fragment's convex collider to reduce physics cost.
@export var simplify_fragment_colliders := true

@export_group("Player Movement")
## Maximum horizontal movement speed in metres per second while walking.
@export_range(0.0, 20.0, 0.1, "or_greater", "suffix:m/s") var walk_speed := 4.5
## Maximum horizontal movement speed in metres per second while holding Shift.
@export_range(0.0, 30.0, 0.1, "or_greater", "suffix:m/s") var sprint_speed := 7.2
## How quickly horizontal velocity approaches the target speed, in metres per second squared.
@export_range(0.0, 60.0, 0.5, "or_greater", "suffix:m/s²") var acceleration := 28.0
## Downward acceleration applied to the player while airborne, in metres per second squared.
@export_range(0.0, 50.0, 0.5, "or_greater", "suffix:m/s²") var gravity := 18.0
## Initial upward speed in metres per second when jumping from the floor.
@export_range(0.0, 20.0, 0.1, "or_greater", "suffix:m/s") var jump_speed := 5.0
## Camera rotation in radians per pixel of mouse movement.
@export_range(0.0001, 0.02, 0.0001, "or_greater") var mouse_sensitivity := 0.0024

@export_group("Weapon Motion")
## Maximum weapon tilt when looking around. Set to zero to disable mouse sway.
@export_range(0.0, 5.0, 0.05, "suffix:°") var mouse_sway_degrees := 1.6
## Weapon drift and stride bob while moving, in metres. Set to zero to disable movement sway.
@export_range(0.0, 0.08, 0.001, "suffix:m") var movement_sway_distance := 0.022
## Peak displacement of the camera on firing. This visual offset leaves shot aim unchanged.
@export_range(0.0, 0.10, 0.001, "suffix:m") var fire_shake_distance := 0.032
## Time for the fire shake to settle, in seconds.
@export_range(0.02, 0.40, 0.005, "suffix:s") var fire_shake_duration := 0.16

@onready var player: CharacterBody3D = $FirstPersonPlayer
@onready var range_audio: RangeAudio = $RangeAudio
@onready var camera: Camera3D = $FirstPersonPlayer/FirstPersonCamera
@onready var camera_rest_offset := Vector2(camera.h_offset, camera.v_offset)
@onready var weapon: Node3D = $FirstPersonPlayer/FirstPersonCamera/ImpulseProjector
@onready var muzzle: Marker3D = $FirstPersonPlayer/FirstPersonCamera/ImpulseProjector/Muzzle
@onready var flash: MuzzleFlashParticles = $FirstPersonPlayer/FirstPersonCamera/ImpulseProjector/Muzzle/Flash
@onready var flash_light: OmniLight3D = $FirstPersonPlayer/FirstPersonCamera/ImpulseProjector/Muzzle/FlashLight
@onready var weapon_rest_position := weapon.position
@onready var weapon_rest_rotation := weapon.rotation
@onready var reticle: Control = $HUD/Screen/Reticle
@onready var station_label: Label = $HUD/Screen/StationLabel
@onready var feedback_label: Label = $HUD/Screen/Footer/FeedbackLabel
@onready var stats_label: Label = $HUD/Screen/StatsLabel
@onready var cursor_label: Label = $HUD/Screen/CursorLabel
@onready var aim_label: Label = $HUD/Screen/AimLabel
@onready var slash_preview: Line2D = $HUD/Screen/SlashPreview

var targets: Array[Dictionary] = []
var active_station := 0
var shots_fired := 0
var successful_hits := 0
var total_cuts := 0
var pitch := 0.0
var recoil := 0.0
var flash_light_time := 0.0
var look_sway_input := Vector2.ZERO
var look_sway := Vector2.ZERO
var movement_sway := Vector2.ZERO
var stride_phase := 0.0
var fire_shake_time := 0.0
var shot_cooldown := 0.0
var feedback_time := 0.0
var elapsed := 0.0
var testing := false
var last_shot: Dictionary = {}
var shotgun_impacts: Array[Dictionary] = []
var tracer_endpoints := PackedVector3Array()
var tracer_mesh := MultiMesh.new()
var tracer_shader_material: ShaderMaterial
var tracer_age := TRACER_DURATION
var tracer_count := 0
var tracer_forward := Vector3.FORWARD
var warmed_shotgun_impact: Node
var cut_audio_contact := Vector3.INF
var plane_slicing := PlaneSlicing.new()
var slash_dragging := false
var slash_start := Vector2.ZERO
var slash_end := Vector2.ZERO
var last_slash: Dictionary = {}

func _ready() -> void:
	# Prepare the first decal before interactive shooting begins.
	warmed_shotgun_impact = SHOTGUN_IMPACT.instantiate()
	# Sway and recoil run on rendered frames. Keep the flash and its trail at the same pose.
	weapon.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_setup_pellet_traces()
	plane_slicing.simplify_fragment_colliders = simplify_fragment_colliders
	plane_slicing.cap_material = slice_cap_material
	plane_slicing.prepare()
	testing = DisplayServer.get_name() == "headless" or "--smoke" in OS.get_cmdline_user_args()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture="): testing = true
	for station in $Stations.get_children():
		_bind_station(station)
	_jump_station(mini(initial_scenario, targets.size() - 1))
	if not testing:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if "--smoke" in OS.get_cmdline_user_args():
		_run_smoke.call_deferred()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--shoot=") or argument.begins_with("--cut="):
			_autoshot.call_deferred(StringName(argument.get_slice("=", 1)))
		if argument.begins_with("--capture="):
			_capture.call_deferred(argument.trim_prefix("--capture="))

func _bind_station(station: Node3D) -> void:
	var actor: Node3D = station.get_node("Target")
	var skeleton: Skeleton3D = actor.get_node("Skeleton3D")
	var component: GoreComponent = actor.get_node("GoreComponent")
	var index := targets.size()
	var physics_bodies := {}
	for node in skeleton.find_children("*", "PhysicalBone3D", true, false):
		var body := node as PhysicalBone3D
		var bone := StringName(body.get("bone_name"))
		physics_bodies[bone] = body
		body.set_meta("target_index", index)
	# PhysicsServer collision exceptions are runtime relationships. Their
	# authored bone names are stored on each saved physical bone.
	for body: PhysicalBone3D in physics_bodies.values():
		for bone in body.get_meta("collision_exception_bones", PackedStringArray()):
			var other: PhysicalBone3D = physics_bodies.get(StringName(bone))
			if other != null:
				body.add_collision_exception_with(other)

	var hitboxes: Array[Dictionary] = []
	for child in skeleton.get_children():
		var area := child as Area3D
		if area == null or not area.has_meta("bone"):
			continue
		var bone := StringName(area.get_meta("bone"))
		var bone_index := skeleton.find_bone(bone)
		if bone_index < 0:
			push_warning("Hitbox %s names an unknown bone: %s" % [area.get_path(), bone])
			continue
		area.set_meta("target_index", index)
		var local := skeleton.get_bone_global_rest(bone_index).affine_inverse() * area.transform
		hitboxes.append({"area": area, "index": bone_index, "bone": bone,
			"local": local, "collision_layer": area.collision_layer})
	var target := {
		"actor": actor, "skeleton": skeleton, "mesh": skeleton.get_node("SkinMesh"),
		"component": component, "hitboxes": hitboxes, "physics_bodies": physics_bodies,
		"spawn": station.get_node("PlayerSpawn"), "aim": station.get_node("InitialAim"),
		"title": station.get_meta("station_title", station.name), "missing": {}, "ragdoll": false,
		"hitboxes_dirty": true, "hitboxes_suspended": false,
	}
	targets.append(target)
	skeleton.pose_updated.connect(func() -> void: target.hitboxes_dirty = true)
	if not component.initialize():
		push_error("Rig setup failed at %s: %s" % [station.name, component.get_last_error()])
		return
	component.pre_dismemberment.connect(_on_pre_dismemberment.bind(index))
	component.post_dismemberment.connect(_on_post_dismemberment.bind(index))

func _sync_hitboxes(only_dirty := false) -> void:
	for target in targets:
		var suspend_hitboxes: bool = target.ragdoll or target.has("plane_slice")
		if only_dirty and target.hitboxes_suspended == suspend_hitboxes \
				and (suspend_hitboxes or not target.hitboxes_dirty):
			continue
		target.hitboxes_dirty = false
		target.hitboxes_suspended = suspend_hitboxes
		var skeleton: Skeleton3D = target.skeleton
		for hitbox in target.hitboxes:
			var area: Area3D = hitbox.area
			var missing: bool = target.missing.has(hitbox.bone)
			area.collision_layer = 0 if missing or suspend_hitboxes else hitbox.collision_layer
			if not missing and not suspend_hitboxes:
				area.transform = skeleton.get_bone_global_pose(hitbox.index) * hitbox.local

func _physics_process(delta: float) -> void:
	if player == null:
		return
	_sync_hitboxes(true)
	_update_aim_label()
	shot_cooldown = maxf(0, shot_cooldown - delta)
	if not player.is_on_floor():
		player.velocity.y -= gravity * delta
	var input := Vector2.ZERO
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not testing:
		input.x = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		input.y = float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	input = input.normalized()
	var speed := sprint_speed if Input.is_physical_key_pressed(KEY_SHIFT) else walk_speed
	var direction := player.basis * Vector3(input.x, 0, input.y)
	player.velocity.x = move_toward(player.velocity.x, direction.x * speed, delta * acceleration)
	player.velocity.z = move_toward(player.velocity.z, direction.z * speed, delta * acceleration)
	player.move_and_slide()
	range_audio.advance_steps(player.get_position_delta(), player.is_on_floor())

func _process(delta: float) -> void:
	elapsed += delta
	while not shotgun_impacts.is_empty() and elapsed >= shotgun_impacts.front().expires_at:
		_remove_oldest_impact()
	if weapon != null:
		_advance_weapon_motion(delta)
	if tracer_count > 0:
		tracer_age += delta
		tracer_shader_material.set_shader_parameter("trace_age", tracer_age)
		if tracer_age < TRACER_DURATION:
			_update_pellet_ribbons()
		else:
			_clear_pellet_traces()
	feedback_time = maxf(0, feedback_time - delta)
	if feedback_label != null:
		feedback_label.modulate.a = minf(1, feedback_time * 2)
		cursor_label.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not testing
		_update_stats()

func _advance_weapon_motion(delta: float) -> void:
	recoil = move_toward(recoil, 0.0, delta * 5.0)
	flash_light_time = maxf(0.0, flash_light_time - delta)
	look_sway = look_sway.lerp(look_sway_input, 1.0 - exp(-24.0 * delta))
	look_sway_input *= exp(-20.0 * delta)
	var local_velocity := Vector2(player.basis.x.dot(player.velocity), player.basis.z.dot(player.velocity))
	var speed_scale := maxf(0.01, maxf(walk_speed, sprint_speed))
	var move_input := (local_velocity / speed_scale).limit_length()
	movement_sway = movement_sway.lerp(move_input, 1.0 - exp(-12.0 * delta))
	stride_phase = fposmod(stride_phase + movement_sway.length() * 12.0 * delta, TAU)
	if fire_shake_time > 0.0:
		fire_shake_time = maxf(0.0, fire_shake_time - delta)
		_update_camera_shake()
	_update_weapon_pose()

func _update_weapon_pose() -> void:
	var look_tilt := look_sway * deg_to_rad(mouse_sway_degrees)
	var step_weight := movement_sway.length()
	var drift := Vector3(-movement_sway.x + sin(stride_phase) * step_weight * 0.24,
		cos(stride_phase * 2.0) * step_weight * 0.32, -movement_sway.y * 0.65) * movement_sway_distance
	var idle_bob := sin(elapsed * 2.0) * 0.002 * (1.0 - step_weight)
	weapon.position = weapon_rest_position + drift + Vector3(-look_tilt.x * 0.22,
		idle_bob + look_tilt.y * 0.22, recoil * 0.075)
	weapon.rotation = weapon_rest_rotation + Vector3(recoil * 0.08 + look_tilt.y,
		look_tilt.x, -look_tilt.x * 0.35)
	if flash_light_time > 0.0:
		var phase := 1.0 - flash_light_time / FLASH_LIGHT_DURATION
		var light_fade := 1.0 - smoothstep(0.0, 0.65, phase)
		flash_light.light_energy = 1.6 * light_fade * light_fade
	else:
		flash_light.light_energy = 0.0

func _update_camera_shake() -> void:
	var duration := maxf(fire_shake_duration, 0.001)
	var life := clampf(fire_shake_time / duration, 0.0, 1.0)
	var age := duration * (1.0 - life)
	var sideways := sin(age * TAU * 13.0 + 0.5) * 0.56
	var upwards := cos(age * TAU * 9.0)
	var offset := Vector2(sideways, upwards) * (fire_shake_distance * life * life)
	# Offsets move the rendered camera while global_position and global_basis still define the shot.
	camera.h_offset = camera_rest_offset.x + offset.x
	camera.v_offset = camera_rest_offset.y + offset.y

func _clear_weapon_motion() -> void:
	recoil = 0.0
	flash_light_time = 0.0
	flash.clear()
	look_sway_input = Vector2.ZERO
	look_sway = Vector2.ZERO
	movement_sway = Vector2.ZERO
	stride_phase = 0.0
	fire_shake_time = 0.0
	_update_camera_shake()
	_update_weapon_pose()
	_clear_pellet_traces()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed and (testing or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED):
			_begin_slash()
		elif not event.pressed and slash_dragging:
			var start := slash_start
			var end := slash_end
			_cancel_slash()
			last_slash = _slash_view(start, end)
		return
	if slash_dragging and event is InputEventMouseMotion:
		var viewport := get_viewport().get_visible_rect()
		slash_end = (slash_end + event.relative).clamp(viewport.position, viewport.end - Vector2.ONE)
		slash_preview.set_point_position(1, slash_end)
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var look_delta: Vector2 = event.relative * mouse_sensitivity
		player.rotate_y(-look_delta.x)
		pitch = clampf(pitch - look_delta.y, -1.35, 1.35)
		camera.rotation.x = pitch
		look_sway_input = (look_sway_input + look_delta * 6.0).limit_length()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not testing:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		last_shot = _shoot()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode if event.physical_keycode != 0 else event.keycode:
			KEY_ESCAPE:
				_cancel_slash()
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
			KEY_R: _reset_target(active_station)
			KEY_1: _jump_station(0)
			KEY_2: _jump_station(1)
			KEY_3: _jump_station(2)
			KEY_F: last_shot = _shoot(true)
			KEY_X: last_shot = _shoot(false, true)
			KEY_V: _slice_camera()
			KEY_Q: _tilt_slice(-PlaneSlicing.TILT_STEP)
			KEY_E: _tilt_slice(PlaneSlicing.TILT_STEP)
			KEY_C:
				for target in targets:
					if target.component != null:
						target.component.call("clean_up_all_referenced_limbs")
					plane_slicing.clear_fragments(target)
				_feedback("Detached bodies cleared. R restores the selected subject.")
			KEY_SPACE:
				if player.is_on_floor(): player.velocity.y = jump_speed

func _tilt_slice(step: float) -> void:
	plane_slicing.adjust_tilt(step)
	_feedback("SLICE PLANE %+d° · V cuts an aimed forearm or fragment" % plane_slicing.tilt_degrees)

func _slice_camera() -> Dictionary:
	var result := plane_slicing.slice_hit(self, _raycast_camera(), targets)
	return _report_slice(result, "PLANE CUT %+d° · V cuts fragments · R restores" % plane_slicing.tilt_degrees)

func _begin_slash() -> void:
	slash_dragging = true
	slash_start = get_viewport().get_visible_rect().get_center()
	slash_end = slash_start
	slash_preview.points = PackedVector2Array([slash_start, slash_end])
	slash_preview.show()

func _cancel_slash() -> void:
	if slash_dragging:
		slash_dragging = false
		slash_preview.hide()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_cancel_slash()

func _slash_view(start: Vector2, end: Vector2) -> Dictionary:
	var distance := start.distance_to(end)
	if distance < MIN_SLASH_DRAG:
		return _report_slice({"ok": false, "error": "Drag across the subject before releasing."}, "")
	var origin := camera.project_ray_origin(start)
	var start_ray := camera.project_ray_normal(start)
	var end_on_ray := camera.project_ray_origin(end) + camera.project_ray_normal(end)
	var normal := start_ray.cross(end_on_ray - origin).normalized()
	if normal.is_zero_approx():
		return _report_slice({"ok": false, "error": "The swipe did not define a plane."}, "")

	var segments := clampi(ceili(distance / SLASH_SAMPLE_SPACING), 1, MAX_SLASH_SEGMENTS)
	var space := get_world_3d().direct_space_state
	var query := _make_hit_query(origin, start_ray, slash_reach)
	for segment in range(segments + 1):
		var screen_point := start.lerp(end, float(segment) / segments)
		query.from = camera.project_ray_origin(screen_point)
		query.to = query.from + camera.project_ray_normal(screen_point) * slash_reach
		var hit := space.intersect_ray(query)
		if hit.is_empty() or not hit.collider.has_meta(&"target_index"):
			continue
		var result := plane_slicing.slash_hit(self, hit, targets, Plane(normal, origin))
		return _report_slice(result, "SLASH COMPLETE · R restores the subject")
	return _report_slice({"ok": false, "error": "Swipe across a subject or fragment within reach."}, "")

func _report_slice(result: Dictionary, success_text: String) -> Dictionary:
	if not result.ok:
		_feedback("SLICE REFUSED · " + result.error, true)
		return result
	active_station = result.target
	station_label.text = "%02d / %s" % [active_station + 1, targets[active_station].title]
	_sync_hitboxes()
	range_audio.play_body_impact(result.point, true)
	_feedback(success_text)
	return result

func _shoot(blood_only := false, hide_only := false) -> Dictionary:
	if shot_cooldown > 0:
		return {"hit": false, "cooldown": true}
	shot_cooldown = time_between_shots
	shots_fired += 1
	var is_shell := not blood_only and not hide_only
	recoil = 1
	flash_light_time = FLASH_LIGHT_DURATION
	if is_shell:
		range_audio.play_shot()
		fire_shake_time = maxf(0.0, fire_shake_duration)
		_update_camera_shake()
	# Use the same muzzle pose for the flash and the start of every trace.
	_update_weapon_pose()
	flash.fire()
	var count := clampi(pellet_count, 1, MAX_PELLETS) if is_shell else 1
	var cone_radius := tan(deg_to_rad(clampf(pellet_spread_degrees, 0.0, 12.0)))
	var origin := camera.global_position
	var basis := camera.global_basis
	var forward := -basis.z
	var query := _make_hit_query(origin, forward, shot_range)
	var space := get_world_3d().direct_space_state
	var hits: Array[Dictionary] = []
	# Trace the whole shell before a native cut can change any colliders.
	for pellet in count:
		var direction := forward
		if pellet > 0:
			var radius := cone_radius * sqrt((float(pellet) - 0.5) / float(count - 1))
			var angle := float(shots_fired + pellet) * GOLDEN_ANGLE
			var offset := basis.x * cos(angle) + basis.y * sin(angle)
			direction = (forward + offset * radius).normalized()
		query.to = origin + direction * shot_range
		var hit := space.intersect_ray(query)
		tracer_endpoints[pellet] = hit.get("position", query.to)
		if not hit.is_empty():
			hit["direction"] = direction
			hits.append(hit)
	_show_pellet_traces(forward, count)

	var handled_stations := {}
	var handled_detached := {}
	var first_subject := {}
	var first_surface := {}
	var impact_count := 0
	for hit in hits:
		var outcome := _apply_pellet_hit(hit, blood_only, hide_only, handled_stations, handled_detached)
		if outcome.get("hit", false):
			if first_subject.is_empty():
				first_subject = outcome
		elif outcome.get("surface", false):
			if first_surface.is_empty():
				first_surface = outcome
			var receiver := hit.collider as Node3D
			if is_shell and is_instance_valid(receiver) and not receiver is Area3D:
				_spawn_shotgun_impact(hit.position, hit.normal, hit.direction, receiver)
				impact_count += 1
	var result := first_subject if not first_subject.is_empty() else first_surface
	if result.is_empty():
		result = {"hit": false}
	_show_shot_result(result, blood_only, hide_only)
	result["pellets_fired"] = count
	result["environment_impacts"] = impact_count
	return result

func _apply_pellet_hit(hit: Dictionary, blood_only: bool, hide_only: bool,
		handled_stations: Dictionary, handled_detached: Dictionary) -> Dictionary:
	var collider: Object = hit.collider
	if not is_instance_valid(collider):
		return {}
	var endpoint: Vector3 = hit.position
	var direction: Vector3 = hit.direction
	var sliced_fragment := collider.has_meta(PlaneSlicing.FRAGMENT_META)
	var sliced_remainder := collider.has_meta(PlaneSlicing.SLICE_REMAINDER_META)
	var limb := collider as Node
	while limb != null and not limb.is_in_group("Dismembered Limb"):
		limb = limb.get_parent()
	if limb != null or sliced_remainder:
		var part: Object = limb if limb != null else collider
		var index: int = part.get_meta("target_index", -1)
		if handled_detached.has(part) or handled_stations.has(index):
			return {}
		handled_detached[part] = true
		var sever := {}
		if index >= 0 and index < targets.size():
			handled_stations[index] = true
			if (sliced_fragment or sliced_remainder) and not blood_only and not hide_only:
				var impulse := direction * dismemberment_impulse + Vector3.UP * dismemberment_upward_boost
				sever = plane_slicing.sever_shot(self, hit, targets[index], index, impulse)
			var gore: GoreComponent = targets[index].component
			if is_instance_valid(gore) and gore.enable_blood_particles:
				gore.spawn_blood_particles(endpoint, direction)
		if sever.is_empty() and (collider is PhysicalBone3D or (collider is RigidBody3D and sliced_fragment)):
			collider.apply_central_impulse(direction * collider.mass * detached_limb_hit_impulse)
		if not hide_only:
			range_audio.play_body_impact(endpoint, not sever.is_empty())
		if not sever.is_empty():
			total_cuts += 1
			return {"hit": true, "detached": limb != null, "sliced": true, "severed": true,
				"target": index, "position": endpoint, "bone": sever.bone, "limb": sever.limb}
		return {"hit": true, "detached": limb != null, "sliced": sliced_fragment or sliced_remainder,
			"target": index, "position": endpoint}

	if not collider.has_meta("target_index") or not collider.has_meta("bone"):
		return {"hit": false, "surface": true, "position": endpoint}
	var index: int = collider.get_meta("target_index")
	if index < 0 or index >= targets.size() or handled_stations.has(index):
		return {}
	handled_stations[index] = true
	var bone: StringName = collider.get_meta("bone")
	var requested: StringName = collider.get_meta("requested_bone", bone)
	var component: GoreComponent = targets[index].component
	var allowed := component.check_bone_filter(bone)
	if blood_only or not allowed:
		component.spawn_blood_fx(endpoint, direction, bone)
		if not hide_only:
			range_audio.play_body_impact(endpoint)
	elif hide_only:
		component.destroy_limb(requested)
		_mark_missing(index, bone)
	else:
		cut_audio_contact = endpoint
		component.dismember_limb(requested, direction * dismemberment_impulse + Vector3.UP * dismemberment_upward_boost)
		if cut_audio_contact.is_finite():
			range_audio.play_body_impact(endpoint)
			cut_audio_contact = Vector3.INF
	return {"hit": true, "bone": bone, "requested_bone": requested, "target": index,
		"position": endpoint, "allowed": allowed}

func _show_shot_result(result: Dictionary, blood_only: bool, hide_only: bool) -> void:
	if result.get("detached", false) or result.get("sliced", false):
		var index: int = result.get("target", -1)
		if index >= 0 and index < targets.size():
			active_station = index
			station_label.text = "%02d / %s" % [active_station + 1, targets[index].title]
		successful_hits += 1
		var severed: bool = result.get("severed", false)
		reticle.call("register_hit", severed)
		if severed:
			_feedback("SEVERED · " + String(result.bone))
		elif result.get("sliced", false):
			_feedback("SLICE FRAGMENT HIT" if result.detached else "SLICED SUBJECT HIT")
		else:
			_feedback("DETACHED LIMB HIT")
	elif result.get("hit", false):
		var index: int = result.target
		var bone := String(result.bone)
		var allowed: bool = result.allowed
		active_station = index
		station_label.text = "%02d / %s" % [index + 1, targets[index].title]
		successful_hits += 1
		reticle.call("register_hit", allowed)
		if blood_only or not allowed:
			_feedback(("BLOOD FX" if blood_only else "PROTECTED BONE") + " · " + bone, not allowed)
		elif hide_only:
			_feedback("HIDDEN · " + bone)
		else:
			_feedback("HIT · " + bone)
	elif result.get("surface", false):
		_feedback("SURFACE HIT · aim at a skeletal subject")
	else:
		_feedback("MISS · aim at a subject's visible limb")

func _exit_tree() -> void:
	if warmed_shotgun_impact != null:
		warmed_shotgun_impact.free()
		warmed_shotgun_impact = null

func _spawn_shotgun_impact(position: Vector3, normal: Vector3, direction: Vector3, receiver: Node3D) -> void:
	if shotgun_impacts.size() >= MAX_IMPACT_MARKS:
		_remove_oldest_impact()
	var impact = warmed_shotgun_impact if warmed_shotgun_impact != null else SHOTGUN_IMPACT.instantiate()
	warmed_shotgun_impact = null
	receiver.add_child(impact)
	impact.place(position, normal, direction)
	$ShotgunImpactBursts.emit_at(impact.global_transform, direction,
		bool(receiver.get_meta(&"dusty_impact", false)))
	impact.add_to_group("Shotgun Impact")
	shotgun_impacts.append({"node": impact, "expires_at": elapsed + IMPACT_LIFETIME})

func _remove_oldest_impact() -> void:
	var entry: Dictionary = shotgun_impacts.pop_front()
	var impact = entry.node
	if is_instance_valid(impact):
		var receiver: Node = impact.get_parent()
		if receiver != null:
			receiver.remove_child(impact)
		impact.queue_free()

func _make_hit_query(origin: Vector3, direction: Vector3, distance: float) -> PhysicsRayQueryParameters3D:
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * distance, shot_collision_mask)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	query.exclude = [player.get_rid()]
	return query

func _raycast_camera() -> Dictionary:
	var query := _make_hit_query(camera.global_position, -camera.global_basis.z, shot_range)
	return get_world_3d().direct_space_state.intersect_ray(query)

func _update_aim_label() -> void:
	if aim_label == null: return
	var result := _raycast_camera()
	if not result.is_empty() and result.collider.has_meta(PlaneSlicing.FRAGMENT_META):
		aim_label.text = "FRAGMENT · V SLICE %+d°" % plane_slicing.tilt_degrees
	elif not result.is_empty() and result.collider.has_meta(PlaneSlicing.SLICE_REMAINDER_META):
		aim_label.text = "SLICED SUBJECT"
	elif not result.is_empty() and result.collider.has_meta("bone"):
		var bone: StringName = result.collider.get_meta("bone")
		aim_label.text = str(bone).to_upper()
		var index := int(result.collider.get_meta("target_index", -1))
		if index >= 0 and index < targets.size() and bone in [&"LeftForeArm", &"RightForeArm"]:
			var target := targets[index]
			if not target.ragdoll and target.missing.is_empty() and not target.has("plane_slice"):
				aim_label.text += " · V SLICE %+d°" % plane_slicing.tilt_degrees
	else:
		aim_label.text = ""

func _mark_missing(index: int, root_bone: StringName) -> void:
	var target: Dictionary = targets[index]
	var skeleton: Skeleton3D = target.skeleton
	var root_index := skeleton.find_bone(root_bone)
	for hitbox in target.hitboxes:
		var current: int = hitbox.index
		while current >= 0:
			if current == root_index:
				target.missing[hitbox.bone] = true
				(hitbox.area as Area3D).collision_layer = 0
				break
			current = skeleton.get_bone_parent(current)

func _on_pre_dismemberment(bone: StringName, _impulse: Vector3, index: int) -> void:
	_mark_missing(index, bone)
	if cut_audio_contact.is_finite():
		range_audio.play_body_impact(cut_audio_contact, true)
		cut_audio_contact = Vector3.INF

func _on_post_dismemberment(bone: StringName, limb: Node, index: int) -> void:
	if is_instance_valid(limb):
		limb.set_meta("target_index", index)
	var target: Dictionary = targets[index]
	if not target.ragdoll and _should_ragdoll_on_sever(bone):
		var remaining: Array[StringName] = []
		for name: StringName in target.physics_bodies:
			if not target.missing.has(name):
				remaining.append(name)
		if not remaining.is_empty():
			target.skeleton.physical_bones_start_simulation(remaining)
			target.ragdoll = true
	total_cuts += 1
	_report_skeletal_sever(bone, target.title)

func _should_ragdoll_on_sever(bone: StringName) -> bool:
	return source_ragdoll_bones.has(String(bone))

func _report_skeletal_sever(bone: StringName, title: String) -> void:
	_feedback("SEVERED · " + str(bone) + "  /  " + title)
	_update_stats()

func _reset_target(index: int, update_ui := true) -> void:
	if index < 0 or index >= targets.size(): return
	_cancel_slash()
	var target: Dictionary = targets[index]
	plane_slicing.restore(target)
	if target.component != null:
		target.component.call("reset_all_limbs")
	target.skeleton.physical_bones_stop_simulation()
	target.skeleton.clear_bones_global_pose_override()
	target.skeleton.reset_bone_poses()
	target.ragdoll = false
	target.missing.clear()
	if update_ui:
		_sync_hitboxes()
		_feedback("SUBJECT %02d RESTORED · aim and fire" % (index + 1))

func _jump_station(index: int) -> void:
	if index < 0 or index >= targets.size():
		return
	_cancel_slash()
	active_station = index
	var target: Dictionary = targets[index]
	player.global_position = target.spawn.global_position
	player.velocity = Vector3.ZERO
	range_audio.reset_footsteps()
	_look_at(target.aim.global_position)
	_clear_weapon_motion()
	station_label.text = "%02d / %s" % [index + 1, target.title]
	_feedback("HOLD MMB AND DRAG TO SLASH · left mouse fires")

func _look_at(position: Vector3) -> void:
	var direction := (position - camera.global_position).normalized()
	player.rotation.y = atan2(-direction.x, -direction.z)
	pitch = asin(clampf(direction.y, -1, 1))
	camera.rotation.x = pitch

func _aim_at_bone(index: int, bone: StringName) -> bool:
	if index < 0 or index >= targets.size(): return false
	var target: Dictionary = targets[index]
	var aliases := {&"hit_proxy": &"RightHand", &"upper_arm_left": &"LeftArm", &"hand_right": &"RightHand", &"left_leg_1": &"LeftLeg"}
	var requested_bone: StringName = aliases.get(bone, bone)
	var focus := Vector3.ZERO
	var found := false
	if bool(target.get("ragdoll", false)):
		var body: PhysicalBone3D = target.physics_bodies.get(requested_bone)
		if body != null and body.get_bone_id() >= 0:
			focus = body.global_position
			found = true
	else:
		_sync_hitboxes()
		for hitbox in target.hitboxes:
			if hitbox.bone == requested_bone:
				focus = (hitbox.area as Area3D).global_position
				found = true
				break
	if not found: return false
	var flank := 2.0 if focus.x >= target.actor.global_position.x else -2.0
	player.global_position = target.actor.global_position + Vector3(flank, -0.055, 2.8)
	player.velocity = Vector3.ZERO
	_look_at(focus)
	_clear_weapon_motion()
	active_station = index
	station_label.text = "%02d / %s" % [index + 1, target.title]
	return true

func _setup_pellet_traces() -> void:
	tracer_endpoints.resize(MAX_PELLETS)
	tracer_mesh.transform_format = MultiMesh.TRANSFORM_3D
	tracer_mesh.use_custom_data = true
	tracer_mesh.mesh = QuadMesh.new()
	tracer_mesh.instance_count = MAX_PELLETS
	tracer_mesh.visible_instance_count = 0
	if tracer_material != null:
		tracer_shader_material = tracer_material.duplicate()
	else:
		tracer_shader_material = ShaderMaterial.new()
		tracer_shader_material.shader = TRACER_SHADER
	tracer_shader_material.set_shader_parameter("trace_duration", TRACER_DURATION)

	var batch := MultiMeshInstance3D.new()
	batch.name = "PelletTraces"
	batch.multimesh = tracer_mesh
	batch.material_override = tracer_shader_material
	batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	batch.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	batch.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	batch.top_level = true
	add_child(batch)
	batch.global_transform = Transform3D.IDENTITY

func _show_pellet_traces(forward: Vector3, count: int) -> void:
	tracer_count = count
	tracer_forward = forward
	tracer_age = 0.0
	tracer_shader_material.set_shader_parameter("trace_age", tracer_age)
	_update_pellet_ribbons()

func _update_pellet_ribbons() -> void:
	var start := muzzle.global_position
	var view := camera.get_camera_transform()
	var active := 0
	var bounds := AABB(start, Vector3.ZERO)
	for pellet in tracer_count:
		var end := tracer_endpoints[pellet]
		var path := end - start
		# A close hit may be between the camera and muzzle. The flash covers it.
		if path.dot(tracer_forward) <= 0.002:
			continue
		var midpoint := start + path * 0.5
		var across := path.cross(view.origin - midpoint).normalized()
		if across.is_zero_approx():
			across = view.basis.x
		var normal := across.cross(path).normalized()
		var ribbon := Basis(across * TRACER_WIDTH, path, normal)
		tracer_mesh.set_instance_transform(active, Transform3D(ribbon, midpoint))
		tracer_mesh.set_instance_custom_data(active, Color(path.length(), 0.0, 0.0, 0.0))
		bounds = bounds.expand(end)
		active += 1
	tracer_mesh.custom_aabb = bounds.grow(TRACER_WIDTH)
	tracer_mesh.visible_instance_count = active

func _clear_pellet_traces() -> void:
	tracer_count = 0
	tracer_age = TRACER_DURATION
	tracer_mesh.visible_instance_count = 0

func _feedback(text: String, warning := false) -> void:
	if feedback_label == null: return
	feedback_label.text = text
	feedback_label.add_theme_color_override("font_color", Color(1, 0.68, 0.29) if warning else Color(0.39, 0.94, 0.96))
	feedback_time = 3

func _update_stats() -> void:
	var detached := 0
	for target in targets:
		if is_instance_valid(target.component):
			detached += target.component.call("get_all_dismembered_limbs").size()
		if target.has("plane_slice"):
			detached += target.plane_slice.fragments.size()
	stats_label.text = "SHOTGUN\nSHOTS %02d   HITS %02d   LIMBS %02d" % [shots_fired, successful_hits, detached]

func _autoshot(bone: StringName) -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not _aim_at_bone(initial_scenario, bone):
		push_error("FPS_SHOT_FAILED: unknown bone " + str(bone))
		return
	await get_tree().physics_frame
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	# The deterministic capture uses the same input handler as a real click.
	var previous := testing
	testing = true
	_unhandled_input(event)
	testing = previous
	print("FPS_AUTOSHOT: ", last_shot)

func _run_smoke() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if targets.size() != 3 or targets[0].component == null:
		push_error("FPS_SMOKE_FAILED: native component missing")
		get_tree().quit(1)
		return
	var requested := [&"LeftArm", &"LeftLeg", &"RightHand", &"Head"]
	for iteration in requested.size():
		var index: int = iteration % 3
		_reset_target(index)
		_aim_at_bone(index, requested[iteration])
		await get_tree().physics_frame
		shot_cooldown = 0
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		_unhandled_input(click)
		await get_tree().physics_frame
		await get_tree().process_frame
		if not last_shot.get("hit", false) or last_shot.get("bone", &"") != requested[iteration] or targets[index].component.call("get_all_dismembered_limbs").is_empty():
			push_error("FPS_SMOKE_FAILED: aimed click did not sever expected bone at station %d result=%s" % [index, last_shot])
			get_tree().quit(1)
			return
		for hitbox in targets[index].hitboxes:
			if targets[index].missing.has(hitbox.bone) and (hitbox.area as Area3D).collision_layer != 0:
				push_error("FPS_SMOKE_FAILED: missing limb hitbox still active")
				get_tree().quit(1)
				return
		_reset_target(index)
		await get_tree().physics_frame
	# A real camera ray above every subject must not sever anything.
	player.global_position = Vector3(0, 0.04, 1)
	_look_at(Vector3(0, 20, -8))
	shot_cooldown = 0
	var miss := _shoot()
	if miss.get("hit", false):
		push_error("FPS_SMOKE_FAILED: miss counted as a bone hit")
		get_tree().quit(1)
		return
	print("FPS_SMOKE_OK: first-person camera; 4 aimed left-click physics hits including head; native sever; descendant hitbox removal; reset; miss")
	# Give the mixer time to retire the active one-shots after the scene frees its players.
	var tree := get_tree()
	tree.create_timer(0.12).timeout.connect(tree.quit.bind(0))
	queue_free()

func _capture(path: String) -> void:
	await get_tree().create_timer(1.35).timeout
	await RenderingServer.frame_post_draw
	var error := get_viewport().get_texture().get_image().save_png(path)
	print("FPS_RETICLE: rect=", reticle.get_global_rect(), " center=", reticle.get_global_rect().get_center(), " viewport_center=", get_viewport().get_visible_rect().get_center())
	print("FPS_CAPTURE: ", path, " error=", error)
	get_tree().quit(0 if error == OK else 1)
