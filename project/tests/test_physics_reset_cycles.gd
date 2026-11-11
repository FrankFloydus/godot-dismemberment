extends SceneTree
## Exact FPS reset ordering, repeated on the same imported rig. Alternate head
## and leg cuts so a body restored by one reset remains active in the next run.

const Rig = preload("res://demo/realistic_rig.gd")
const Authored = preload("res://demo/humanoid_physics.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void: call_deferred("run")

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("RESET PHYSICS: " + message)

func frames(count: int = 3) -> void:
	for _index in count: await process_frame

func run() -> void:
	var value: Dictionary = Rig.build(0)
	value.actor.position = Vector3(2.5, .45, -3)
	value.actor.rotation.y = .35
	root.add_child(value.actor)
	var authored := Authored.attach(value.skeleton, value.mesh)
	var skeleton: Skeleton3D = value.skeleton
	var component: Node3D = ClassDB.instantiate("DismembermentComponent")
	component.name = "Dismemberment"
	component.skeleton_path = NodePath("../Skeleton3D")
	component.mesh_path = NodePath("../Skeleton3D/SkinMesh")
	component.pelvis_bone_name = &"Hips"
	component.limb_collision_layer = 8
	component.limb_collision_mask = 1 | 8
	value.actor.add_child(component)
	var floor := StaticBody3D.new()
	var floor_collision := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(30, .2, 30)
	floor_collision.shape = floor_shape
	floor_collision.position.y = -.1
	floor.add_child(floor_collision)
	root.add_child(floor)
	await frames()
	component.initialize()
	var initial: Dictionary = {}
	for body: PhysicalBone3D in authored.bodies:
		initial[skeleton.get_bone_name(body.get_bone_id())] = {"body": body, "parent": body.get_parent(), "index": body.get_bone_id(),
			"joint_type": body.joint_type, "body_offset": body.body_offset, "joint_offset": body.joint_offset, "local": body.transform}
	var constraints: Array[Dictionary] = []
	for child_name: String in initial:
		var child: PhysicalBone3D = initial[child_name].body
		var parent_index := skeleton.get_bone_parent(child.get_bone_id())
		while parent_index >= 0 and not initial.has(skeleton.get_bone_name(parent_index)):
			parent_index = skeleton.get_bone_parent(parent_index)
		if parent_index < 0: continue
		var parent_name := skeleton.get_bone_name(parent_index)
		var parent: PhysicalBone3D = initial[parent_name].body
		constraints.append({"child": child_name, "parent": parent_name, "child_frame": child.joint_offset,
			"parent_frame": parent.global_transform.affine_inverse() * child.global_transform * child.joint_offset})
	var cuts: Array[StringName] = [&"Head", &"LeftUpLeg", &"Head", &"RightUpLeg", &"Head"]
	if "--one-cycle" in OS.get_cmdline_user_args(): cuts.resize(1)
	for cycle in cuts.size():
		var cut := cuts[cycle]
		component.dismember_limb(cut, Vector3(.7, .1, 0))
		await frames()
		skeleton.physical_bones_start_simulation(PackedStringArray(["Hips"]))
		var maximum_gap := 0.0
		var maximum_span := 0.0
		var worst_joint := ""
		for _step in Engine.physics_ticks_per_second * 2:
			await physics_frame
			if _step == Engine.physics_ticks_per_second:
				# The second sever happens while the source is already simulating,
				# so its PhysicalBone nodes are top-level/world-space at capture.
				component.dismember_limb(&"LeftArm" if cycle % 2 == 0 else &"RightArm", Vector3(.4, .1, 0))
			var bounds := AABB()
			var started := false
			for state: Dictionary in initial.values():
				var body: PhysicalBone3D = state.body
				if body.get_bone_id() < 0: continue
				bounds = bounds.expand(body.global_position) if started else AABB(body.global_position, Vector3.ZERO)
				started = true
			maximum_span = maxf(maximum_span, bounds.size.length())
			for constraint in constraints:
				var child: PhysicalBone3D = initial[constraint.child].body
				var parent: PhysicalBone3D = initial[constraint.parent].body
				if child.get_bone_id() < 0 or parent.get_bone_id() < 0: continue
				var gap: float = (child.global_transform * constraint.child_frame).origin.distance_to((parent.global_transform * constraint.parent_frame).origin)
				if gap > maximum_gap:
					maximum_gap = gap
					worst_joint = constraint.parent + " -> " + constraint.child
		# Exact current FPS _reset_target order, intentionally without replacing
		# the actor or rebuilding its authored physics bodies.
		component.reset_all_limbs()
		skeleton.physical_bones_stop_simulation()
		skeleton.clear_bones_global_pose_override()
		skeleton.reset_bone_poses()
		await frames()
		var parents_restored := true
		var bindings_restored := true
		var templates_restored := true
		var maximum_reset_pose_error := 0.0
		var body_modes_consistent := true
		var maximum_solver_node_error := 0.0
		for name: String in initial:
			var state: Dictionary = initial[name]
			var body: PhysicalBone3D = state.body
			parents_restored = parents_restored and body.get_parent() == state.parent
			bindings_restored = bindings_restored and body.get_bone_id() == state.index and not body.is_simulating_physics()
			templates_restored = templates_restored and body.joint_type == state.joint_type and body.body_offset.is_equal_approx(state.body_offset) and body.joint_offset.is_equal_approx(state.joint_offset)
			maximum_reset_pose_error = maxf(maximum_reset_pose_error, body.transform.origin.distance_to(state.local.origin))
			var mode := PhysicsServer3D.body_get_mode(body.get_rid())
			body_modes_consistent = body_modes_consistent and not (mode == PhysicsServer3D.BODY_MODE_RIGID and not body.is_simulating_physics())
			var solver_pose: Transform3D = PhysicsServer3D.body_get_state(body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
			maximum_solver_node_error = maxf(maximum_solver_node_error, solver_pose.origin.distance_to(body.global_position))
		print("RESET_PHYSICS_EVIDENCE cycle=", cycle + 1, " cut=", cut, " max_anchor_gap_m=", maximum_gap, " max_body_diagonal_m=", maximum_span,
			" worst_joint=", worst_joint, " max_reset_body_pose_error_m=", maximum_reset_pose_error,
			" parents_restored=", parents_restored, " bindings_restored=", bindings_restored, " templates_restored=", templates_restored,
			" modes_consistent=", body_modes_consistent, " max_solver_node_error_m=", maximum_solver_node_error)
		expect(maximum_gap < .08, "cycle %d keeps authored joint anchors connected after shooting again" % (cycle + 1))
		expect(maximum_span < 3.0, "cycle %d keeps the source physical body human-sized" % (cycle + 1))
		expect(parents_restored and bindings_restored, "cycle %d restores original physics parents and bone bindings" % (cycle + 1))
		expect(templates_restored, "cycle %d preserves authored joint types and body/joint offsets" % (cycle + 1))
		expect(maximum_reset_pose_error < .003, "cycle %d returns all physical bodies to the reset pose" % (cycle + 1))
		expect(body_modes_consistent, "cycle %d cannot leave unmanaged rigid bodies while simulation flags are stopped" % (cycle + 1))
		expect(maximum_solver_node_error < .003, "cycle %d keeps PhysicsServer body transforms aligned with their restored nodes" % (cycle + 1))
	component.clean_up_all_referenced_limbs()
	value.actor.queue_free()
	floor.queue_free()
	await frames()
	if failures.is_empty():
		print("GODOT_DISMEMBERMENT_RESET_PHYSICS_PASS checks=", checks)
		quit(0)
	else:
		print("GODOT_DISMEMBERMENT_RESET_PHYSICS_FAIL checks=", checks, " failures=", failures.size())
		quit(1)
