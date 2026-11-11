extends SceneTree
## Source-backed physics regressions: authored bodies, an intermediate bone
## without a body, current-pose anchors, mass properties and momentum.

const Fixture = preload("res://tests/rig_fixture.gd")
const RealisticRig = preload("res://demo/realistic_rig.gd")
const HumanoidPhysics = preload("res://demo/humanoid_physics.gd")
var failures: Array[String] = []
var checks := 0
var render_checks_skipped := 0

func _initialize() -> void:
	call_deferred("run")

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("PHYSICS FIDELITY: " + message)

func frames(count: int = 3) -> void:
	for _index in count:
		await process_frame

func release(value: Dictionary) -> void:
	value.component.clean_up_all_referenced_limbs()
	value.actor.queue_free()
	await frames()

func fixture() -> Dictionary:
	var value: Dictionary = Fixture.make_rig()
	value.component.limb_rigid_fallback_enabled = false
	value.component.limb_collision_layer = 8
	value.component.limb_collision_mask = 0
	root.add_child(value.actor)
	return value

func run() -> void:
	if "--chain-only" in OS.get_cmdline_user_args():
		await test_authored_chain()
	elif "--head-only" in OS.get_cmdline_user_args():
		if DisplayServer.get_name() == "headless":
			printerr("HEAD_RENDER_REQUIRES_REAL_RENDERER: use hidden OpenGL plus a Camera3D; dummy rendering cannot validate skinned physics.")
			quit(2)
			return
		await test_real_head_render_and_source_ragdoll()
	else:
		await test_no_physics_asset()
		await test_authored_chain()
		await test_real_head_render_and_source_ragdoll()
		await test_real_humanoid_settling()
		await test_real_humanoid_settling(&"LeftArm", 3)
	if failures.is_empty():
		print("GODOT_DISMEMBERMENT_PHYSICS_FIDELITY_PASS checks=", checks, " render_checks_skipped=", render_checks_skipped)
		quit(0)
	else:
		print("GODOT_DISMEMBERMENT_PHYSICS_FIDELITY_FAIL checks=", checks, " failures=", failures.size())
		quit(1)

func test_no_physics_asset() -> void:
	var value := fixture()
	await frames()
	value.component.initialize()
	value.component.dismember_limb(&"lower", Vector3(2, 0, 0))
	await frames()
	var limb: Node = value.component.get_dismembered_limb_by_name(&"lower")
	expect(is_instance_valid(limb), "a source without an authored PhysicsAsset still creates a detached visual")
	if is_instance_valid(limb):
		expect(not limb.is_articulated(), "missing authored bodies are reported honestly")
		expect(limb.freeze, "no authored physics does not silently become a moving convex whole-body hull")
		expect(limb.find_children("*", "CollisionShape3D", true, false).is_empty(), "no automatic collision hull is invented when the source has no physics asset")
		expect(limb.linear_velocity.is_zero_approx(), "velocity change cannot create physics for a source without authored bodies")
	await release(value)

func test_real_head_render_and_source_ragdoll() -> void:
	var actual_renderer := DisplayServer.get_name() != "headless"
	var camera: Camera3D
	if actual_renderer:
		camera = Camera3D.new()
		root.add_child(camera)
		camera.global_position = Vector3(0, 1.2, 4)
		camera.look_at(Vector3(0, 1, 0))
		camera.current = true
	var value: Dictionary = RealisticRig.build(0)
	root.add_child(value.actor)
	var authored := HumanoidPhysics.attach(value.skeleton, value.mesh)
	var source_head: PhysicalBone3D
	for body in authored.bodies:
		if body.get("bone_name") == &"Head": source_head = body
	var component: Node3D = ClassDB.instantiate("DismembermentComponent")
	component.name = "Dismemberment"
	component.skeleton_path = NodePath("../Skeleton3D")
	component.mesh_path = NodePath("../Skeleton3D/SkinMesh")
	component.pelvis_bone_name = &"Hips"
	component.limb_collision_layer = 8
	component.limb_collision_mask = 0
	value.actor.add_child(component)
	value.component = component
	await frames()
	component.initialize()
	component.dismember_limb(&"Head", Vector3(.6, .1, 0))
	await frames()
	var limb: Node = component.get_dismembered_limb_by_name(&"Head")
	expect(is_instance_valid(limb) and limb.is_articulated(), "real Head cut creates its authored physics body")
	if not is_instance_valid(limb) or not limb.is_articulated():
		await release(value)
		return
	var detached_skeleton: Skeleton3D = limb.get_ragdoll_skeleton()
	var bodies := detached_skeleton.find_children("*", "PhysicalBone3D", true, false)
	expect(bodies.size() == 1, "severed Head physics contains only its authored head body")
	var head_body: PhysicalBone3D = bodies[0]
	var piece: MeshInstance3D = limb.get_meshes()[0]
	var head_index := detached_skeleton.find_bone("Head")
	var head_bind := -1
	for slot in piece.skin.get_bind_count():
		var name := piece.skin.get_bind_name(slot)
		var index := detached_skeleton.find_bone(name) if not name.is_empty() else piece.skin.get_bind_bone(slot)
		if index == head_index: head_bind = slot
	expect(head_bind >= 0, "detached rendered skin retains the Head bind slot")
	var initial_body_origin: Vector3 = (head_body.global_transform * head_body.body_offset.affine_inverse()).origin
	# This deliberately supplies an ancestor root. The engine activates roots AND
	# descendants; a severed source body must have been removed from its simulator
	# rather than merely assigned a zero collision mask.
	value.skeleton.physical_bones_start_simulation(PackedStringArray(["Hips"]))
	for _step in 24:
		await physics_frame
		await process_frame
		if actual_renderer:
			await RenderingServer.frame_post_draw
	expect(source_head.get_bone_id() < 0 or not source_head.is_simulating_physics(), "starting remaining-body ragdoll cannot reactivate the severed source Head")
	var expected: Vector3 = (head_body.global_transform * head_body.body_offset.affine_inverse()).origin
	expect(expected.distance_to(initial_body_origin) > .03, "detached Head body actually moves under gravity and impulse")
	if actual_renderer:
		var skin_rid: RID = piece.get_skin_reference().get_skeleton()
		var head_palette := RenderingServer.skeleton_bone_get_transform(skin_rid, head_bind)
		var rendered_origin: Vector3 = (piece.global_transform * head_palette * piece.skin.get_bind_pose(head_bind).affine_inverse()).origin
		print("HEAD_RENDER_PHYSICS_EVIDENCE body=", expected, " rendered_skin=", rendered_origin, " error_m=", expected.distance_to(rendered_origin))
		expect(rendered_origin.distance_to(expected) < .06, "actual RenderingServer Head skin follows the detached physics body instead of floating at its original position")
	else:
		render_checks_skipped += 1
	var source_bind := -1
	var source_head_index: int = value.skeleton.find_bone("Head")
	for slot in value.mesh.skin.get_bind_count():
		if value.mesh.skin.get_bind_bone(slot) == source_head_index: source_bind = slot
	if source_bind >= 0 and actual_renderer:
		var source_rid: RID = value.mesh.get_skin_reference().get_skeleton()
		var source_palette := RenderingServer.skeleton_bone_get_transform(source_rid, source_bind)
		expect(maxf(source_palette.basis.x.length(), maxf(source_palette.basis.y.length(), source_palette.basis.z.length())) < .02, "source Head remains collapsed while the remaining body simulates")
	elif not actual_renderer:
		render_checks_skipped += 1
	value.skeleton.physical_bones_stop_simulation()
	component.reset_all_limbs()
	await frames()
	expect(source_head.get_bone_id() == source_head_index and source_head.collision_layer == 8, "reset rebinds and restores the authored source Head physics body")
	await release(value)
	if camera != null: camera.queue_free()

func test_real_humanoid_settling(cut_bone: StringName = &"Hips", expected_bodies: int = 17) -> void:
	var value: Dictionary = RealisticRig.build(0)
	value.actor.position = Vector3(0, .45, 0)
	root.add_child(value.actor)
	var authored := HumanoidPhysics.attach(value.skeleton, value.mesh)
	var component: Node3D = ClassDB.instantiate("DismembermentComponent")
	component.name = "Dismemberment"
	component.skeleton_path = NodePath("../Skeleton3D")
	component.mesh_path = NodePath("../Skeleton3D/SkinMesh")
	component.pelvis_bone_name = &"Hips"
	component.limb_collision_layer = 8
	component.limb_collision_mask = 1 | 8
	value.actor.add_child(component)
	value.component = component
	var floor := StaticBody3D.new()
	floor.name = "FidelityTestFloor"
	floor.collision_layer = 1
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, .2, 20)
	collision.shape = box
	collision.position.y = -.1
	floor.add_child(collision)
	root.add_child(floor)
	await frames()
	expect(authored.bodies.size() == 17, "real CC0 model has seventeen authored anatomical physics bodies")
	var total_mass := 0.0
	for body in authored.bodies:
		total_mass += body.mass
	expect(absf(total_mass - 75.0) < .001, "real model mass distribution totals 75 kilograms")
	expect(component.initialize(), "real normalized CC0 model initializes native dismemberment")
	component.dismember_limb(cut_bone, Vector3(1.0, .15, 0))
	await frames()
	var limb: Node = component.get_dismembered_limb_by_name(cut_bone)
	expect(is_instance_valid(limb) and limb.is_articulated(), "real model uses an articulated physics asset instead of a full-mesh rigid collider")
	if not is_instance_valid(limb) or not limb.is_articulated():
		await release(value)
		floor.queue_free()
		return
	var detached_skeleton: Skeleton3D = limb.get_ragdoll_skeleton()
	var bodies := detached_skeleton.find_children("*", "PhysicalBone3D", true, false)
	expect(bodies.size() == expected_bodies, "real cut retains exactly its authored physics subtree: " + String(cut_bone))
	var maximum_angular_speed := 0.0
	var minimum_body_height := INF
	var finite := true
	var terminal_speed_sum := 0.0
	var terminal_samples := 0
	var high_spin_seconds := 0.0
	var physics_hz := Engine.physics_ticks_per_second
	for step in physics_hz * 5:
		await physics_frame
		var frame_max_angular_speed := 0.0
		for body in bodies:
			finite = finite and body.global_transform.is_finite() and body.linear_velocity.is_finite() and body.angular_velocity.is_finite()
			maximum_angular_speed = maxf(maximum_angular_speed, body.angular_velocity.length())
			frame_max_angular_speed = maxf(frame_max_angular_speed, body.angular_velocity.length())
			minimum_body_height = minf(minimum_body_height, body.global_position.y)
			if step >= physics_hz * 4:
				terminal_speed_sum += body.linear_velocity.length()
				terminal_samples += 1
		if frame_max_angular_speed > 50.0:
			high_spin_seconds += 1.0 / physics_hz
	var mean_terminal_speed := terminal_speed_sum / maxf(terminal_samples, 1)
	print("HUMANOID_PHYSICS_EVIDENCE cut=", cut_bone, " bodies=", bodies.size(), " source_mass_kg=", total_mass, " physics_hz=", physics_hz, " simulated_seconds=5 max_angular_rad_s=", maximum_angular_speed, " seconds_over_50_rad_s=", high_spin_seconds, " min_body_y_m=", minimum_body_height, " final_second_mean_speed_m_s=", mean_terminal_speed)
	expect(finite, "real ragdoll remains finite for five seconds of contact simulation")
	# A small hand can have a one-step contact transient. Require it to remain
	# bounded and brief, rather than conflating it with sustained solver explosion.
	expect(maximum_angular_speed < 100.0 and high_spin_seconds < .05, "real ragdoll avoids unbounded or sustained explosive joint velocities")
	expect(minimum_body_height > -.12, "authored body collision prevents deep penetration through the floor")
	expect(mean_terminal_speed < .45, "real ragdoll settles instead of continuing to drift or vibrate after five seconds")
	await release(value)
	floor.queue_free()
	await frames()

func add_body(value: Dictionary, bone: StringName, mass_kg: float, offset: Vector3) -> PhysicalBone3D:
	var body := PhysicalBone3D.new()
	body.name = "Authored_" + String(bone)
	body.set("bone_name", bone)
	body.mass = mass_kg
	body.gravity_scale = 0.0
	body.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	body.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.angular_damp = .15
	body.body_offset = Transform3D(Basis.IDENTITY, offset)
	body.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
	body.set("joint_constraints/swing_span", 27.0)
	body.set("joint_constraints/twist_span", 12.0)
	var collision := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = .06
	shape.height = .32
	collision.shape = shape
	collision.rotation.z = PI * .5
	body.add_child(collision)
	value.skeleton.add_child(body)
	body.linear_velocity = Vector3(.4, 0, 0)
	PhysicsServer3D.body_set_param(body.get_rid(), PhysicsServer3D.BODY_PARAM_CENTER_OF_MASS, Vector3(.015, 0, 0))
	PhysicsServer3D.body_set_param(body.get_rid(), PhysicsServer3D.BODY_PARAM_INERTIA, Vector3(.012, .02, .025))
	# Godot Physics reports zero for an inactive body's inertia, so importers
	# retain the authored tensor explicitly for exact cloning before simulation.
	body.set_meta("godot_dismemberment_inertia", Vector3(.012, .02, .025))
	return body

func test_authored_chain() -> void:
	var value := fixture()
	# 'lower' is deliberately a nonphysical intermediate bone. The source
	# PhysicsAsset links upper -> hand across it, just as neck_01 may sit between
	# a spine body and a head body in a humanoid.
	var source_upper := add_body(value, &"upper", 3.0, Vector3(.15, 0, 0))
	var source_hand := add_body(value, &"hand", 1.0, Vector3(.1, 0, 0))
	source_upper.add_collision_exception_with(source_hand)
	source_hand.add_collision_exception_with(source_upper)
	value.skeleton.set_bone_pose_rotation(2, Quaternion(Vector3.FORWARD, .35))
	value.skeleton.set_bone_pose_rotation(3, Quaternion(Vector3.FORWARD, -.18))
	await frames()
	value.component.initialize()
	# Inherit real moving-source momentum rather than assigning velocity to a
	# static body, which different physics backends intentionally handle differently.
	value.skeleton.physical_bones_start_simulation(PackedStringArray(["upper"]))
	source_upper.linear_velocity = Vector3(.4, 0, 0)
	source_hand.linear_velocity = Vector3(.4, 0, 0)
	var original_mass: float = source_upper.mass
	var source_offset: Transform3D = source_hand.body_offset
	value.component.dismember_limb(&"upper", Vector3(1, 0, 0))
	await frames()
	var limb: Node = value.component.get_dismembered_limb_by_name(&"upper")
	expect(is_instance_valid(limb) and limb.is_articulated(), "authored two-body chain remains articulated after severing")
	if not is_instance_valid(limb) or not limb.is_articulated():
		await release(value)
		return
	var skeleton: Skeleton3D = limb.get_ragdoll_skeleton()
	var bodies := skeleton.find_children("*", "PhysicalBone3D", true, false)
	expect(bodies.size() == 2, "only the authored subtree bodies are cloned")
	var upper: PhysicalBone3D
	var hand: PhysicalBone3D
	for body in bodies:
		if skeleton.get_bone_name(body.get_bone_id()) == "upper": upper = body
		if skeleton.get_bone_name(body.get_bone_id()) == "hand": hand = body
	expect(upper != null and hand != null, "cloned bodies bind to their original skeleton bone names")
	if upper == null or hand == null:
		await release(value)
		return
	expect(upper.joint_type == PhysicalBone3D.JOINT_TYPE_NONE, "the severed root has no constraint to a removed parent")
	expect(hand.joint_type == PhysicalBone3D.JOINT_TYPE_CONE, "a joint across a nonphysical intermediate bone is preserved")
	expect(is_equal_approx(hand.get("joint_constraints/swing_span"), 27.0), "authored cone swing limit survives runtime joint rebuilding")
	expect(is_equal_approx(hand.get("joint_constraints/twist_span"), 12.0), "authored cone twist limit survives runtime joint rebuilding")
	expect(is_equal_approx(upper.mass, 3.0) and is_equal_approx(hand.mass, 1.0), "authored mass distribution is preserved instead of replacing every body with one limb mass")
	expect(hand.body_offset.is_equal_approx(source_offset), "authored body center offset is preserved")
	expect(is_equal_approx(hand.angular_damp, .15), "authored angular damping survives cloning")
	expect(upper.get_collision_exceptions().has(hand) and hand.get_collision_exceptions().has(upper), "authored collision-disable pairs remap to cloned bodies")
	var cloned_com: Vector3 = PhysicsServer3D.body_get_param(upper.get_rid(), PhysicsServer3D.BODY_PARAM_CENTER_OF_MASS)
	var cloned_inertia: Vector3 = PhysicsServer3D.body_get_param(upper.get_rid(), PhysicsServer3D.BODY_PARAM_INERTIA)
	expect(cloned_com.is_equal_approx(Vector3(.015, 0, 0)), "direct-server center-of-mass customization survives cloning")
	expect(cloned_inertia.is_equal_approx(Vector3(.012, .02, .025)), "authored inertia metadata survives cloning before simulation")
	expect(limb.freeze and limb.collision_layer == 0 and limb.collision_mask == 0, "articulated container never adds a duplicate rigid whole-body collider")
	# With no gravity, collisions or linear damping, internal joint forces must
	# conserve total momentum: inherited .4m/s * 4kg + requested 1m/s * root 3kg.
	await physics_frame
	await process_frame
	var momentum := upper.mass * upper.linear_velocity + hand.mass * hand.linear_velocity
	print("CHAIN_MOMENTUM_EVIDENCE actual=", momentum, " expected_x=4.6")
	expect(absf(momentum.x - 4.6) < .12 and absf(momentum.y) < .12 and absf(momentum.z) < .12, "inherited velocity and source mass-independent delta velocity conserve chain momentum in SI units")
	var finite_and_bounded := true
	var max_angular_speed := 0.0
	for _step in 90:
		await physics_frame
		for body in [upper, hand]:
			finite_and_bounded = finite_and_bounded and body.global_transform.is_finite() and body.linear_velocity.is_finite() and body.angular_velocity.is_finite()
			max_angular_speed = maxf(max_angular_speed, body.angular_velocity.length())
	expect(finite_and_bounded and max_angular_speed < 30.0, "current-pose joint anchors settle without nonfinite transforms or explosive angular velocity")
	expect(is_equal_approx(source_upper.mass, original_mass) and source_hand.body_offset.is_equal_approx(source_offset), "runtime physics edits preserve source body templates")
	await release(value)
