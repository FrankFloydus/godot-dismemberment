extends SceneTree

const Fixture = preload("res://tests/rig_fixture.gd")

var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("BLOOD POOL: " + message)

func visual_opacity(visual: Node3D) -> float:
	if visual is Decal:
		return visual.modulate.a
	var material := (visual as MeshInstance3D).material_override as ShaderMaterial
	return material.get_shader_parameter("opacity")

func wait_to_age(pool: BloodPool, age: float) -> void:
	while is_instance_valid(pool) and pool.get_age() < age:
		await process_frame

func _run() -> void:
	var fixture: Dictionary = Fixture.make_rig("GoreComponent")
	root.add_child(fixture.actor)
	var component: GoreComponent = fixture.component
	component.blood_decal_lifetime = 1.5
	var receiver := Node3D.new()
	receiver.rotation = Vector3(0.65, 0.44, -0.34)
	receiver.position = Vector3(4.0, 5.0, 6.0)
	receiver.scale = Vector3(1.5, 0.9, 1.1)
	root.add_child(receiver)
	var impact := Vector3(1.0, 2.0, 3.0)
	var normal := Vector3(1.0, 2.0, 0.0).normalized()
	var pool := component.spawn_blood_decal(impact, normal, receiver, Vector3.FORWARD)
	check(pool != null, "public spawn creates a pool")
	if pool == null:
		finish()
		return
	var visual := pool.get_child(0) as Node3D
	var arguments := OS.get_cmdline_user_args()
	if "--expect-decal" in arguments:
		check(visual is Decal, "Forward+ uses the projected Decal node")
	elif "--expect-fallback" in arguments:
		check(visual is MeshInstance3D, "Compatibility uses the plane fallback")
	pool.interp_time = 9.0
	check(pool.get_parent() == receiver and pool.global_position.is_equal_approx(impact), "attachment keeps the world impact point")
	check(pool.global_basis.y.is_equal_approx(normal), "world normal aligns on a rotated and scaled receiver")
	check(visual.global_basis.y.is_equal_approx(normal) and absf(visual.rotation.y) <= deg_to_rad(10.0) + 0.0001, "visual yaw stays around the receiving normal and within ten degrees")
	check(is_zero_approx(visual_opacity(visual)), "delayed splatter begins invisible")
	var receiver_movement := Vector3(2.0, -1.0, 0.3)
	receiver.position += receiver_movement
	check(pool.global_position.is_equal_approx(impact + receiver_movement), "pool follows later receiver movement")

	var persistent := BloodPool.new()
	persistent.max_lifetime = 0.0
	persistent.decal_rotation = Vector3(0, 0.45, 0)
	root.add_child(persistent)
	var persistent_visual := persistent.get_child(0) as Node3D
	check(absf(persistent_visual.rotation.y - 0.45) <= deg_to_rad(10.0) + 0.0001, "random yaw offsets the authored decal rotation")

	await wait_to_age(pool, 0.38)
	if not is_instance_valid(pool):
		check(false, "pool remains alive during fade-in")
		finish()
		return
	var fade_in := (pool.get_age() - 0.25) / 0.3
	check(absf(visual_opacity(visual) - fade_in) < 0.001, "opacity fades in over 0.3 seconds independently of interpolation metadata")
	check(visual.scale.is_equal_approx(Vector3.ONE), "projection retains full size during fade-in")

	await wait_to_age(pool, 0.65)
	if not is_instance_valid(pool):
		check(false, "pool remains alive during fade-out")
		finish()
		return
	var fade_out := 1.0 - (pool.get_age() - 0.3) / 1.5
	check(absf(visual_opacity(visual) - fade_out) < 0.001, "fade-out starts one fifth of a lifetime after spawn, independent of fade-in delay")
	check(visual.scale.is_equal_approx(Vector3.ONE), "projection retains full size during fade-out")
	check(is_instance_valid(persistent) and is_equal_approx(visual_opacity(persistent_visual), 1.0), "zero lifetime leaves the fully faded-in decal visible")

	await wait_to_age(pool, 1.85)
	check(not is_instance_valid(pool), "Godot removes the finite pool at the fade-out endpoint")
	check(is_instance_valid(persistent), "zero-lifetime decal survives past finite pool cleanup")
	finish()

func finish() -> void:
	print("Blood pool parity checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
