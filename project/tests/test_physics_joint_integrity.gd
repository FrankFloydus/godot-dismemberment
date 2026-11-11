extends SceneTree
## Compare an authored ragdoll with no plugin component against native cuts.
## These checks measure constraint separation directly; low velocity or finite
## transforms alone cannot prove that a physical chain remains connected.

const Rig = preload("res://demo/realistic_rig.gd")
const Authored = preload("res://demo/humanoid_physics.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("run")

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("JOINT INTEGRITY: " + message)

func frames(count: int = 3) -> void:
	for _index in count: await process_frame

func body_map(skeleton: Skeleton3D) -> Dictionary:
	var result := {}
	for body in skeleton.find_children("*", "PhysicalBone3D", true, false):
		if body.get_bone_id() >= 0:
			result[skeleton.get_bone_name(body.get_bone_id())] = body
	return result

func capture_constraints(skeleton: Skeleton3D, bodies: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for name: String in bodies:
		var child: PhysicalBone3D = bodies[name]
		var parent_index := skeleton.get_bone_parent(child.get_bone_id())
		while parent_index >= 0 and not bodies.has(skeleton.get_bone_name(parent_index)):
			parent_index = skeleton.get_bone_parent(parent_index)
		if parent_index < 0: continue
		var parent_name := skeleton.get_bone_name(parent_index)
		var parent: PhysicalBone3D = bodies[parent_name]
		var child_frame := child.joint_offset
		var joint_world := child.global_transform * child_frame
		var parent_frame := parent.global_transform.affine_inverse() * joint_world
		result.append({"child": name, "parent": parent_name, "child_frame": child_frame, "parent_frame": parent_frame,
			"max_center_span": parent_frame.origin.length() + child_frame.origin.length()})
	return result

func run() -> void:
	await compare_case("BASELINE_NO_PLUGIN")
	await compare_case("NATIVE_FULL_CUT")
	await compare_case("NATIVE_HEAD_CUT_SOURCE_RAGDOLL")
	await compare_case("NATIVE_SEQUENTIAL_ARM_CUT_SOURCE")
	await compare_case("NATIVE_SEQUENTIAL_ARM_CUT_DETACHED")
	if failures.is_empty():
		print("GODOT_DISMEMBERMENT_JOINT_INTEGRITY_PASS checks=", checks)
		quit(0)
	else:
		print("GODOT_DISMEMBERMENT_JOINT_INTEGRITY_FAIL checks=", checks, " failures=", failures.size())
		quit(1)

func compare_case(kind: String) -> void:
	var value: Dictionary = Rig.build(0)
	value.actor.position = Vector3(0, .45, 0)
	root.add_child(value.actor)
	var authored := Authored.attach(value.skeleton, value.mesh)
	var original_bodies := body_map(value.skeleton)
	var constraints := capture_constraints(value.skeleton, original_bodies)
	var floor := StaticBody3D.new()
	floor.collision_layer = 1
	var floor_collision := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(20, .2, 20)
	floor_collision.shape = floor_shape
	floor_collision.position.y = -.1
	floor.add_child(floor_collision)
	root.add_child(floor)
	await frames()
	var bodies: Dictionary
	var component: Node3D
	if kind == "BASELINE_NO_PLUGIN":
		bodies = original_bodies
		value.skeleton.physical_bones_start_simulation()
		var hips: PhysicalBone3D = bodies["Hips"]
		hips.apply_central_impulse(Vector3(1, .15, 0) * hips.mass)
	else:
		component = ClassDB.instantiate("DismembermentComponent")
		component.name = "Dismemberment"
		component.skeleton_path = NodePath("../Skeleton3D")
		component.mesh_path = NodePath("../Skeleton3D/SkinMesh")
		component.pelvis_bone_name = &"Hips"
		component.limb_collision_layer = 8
		component.limb_collision_mask = 1 | 8
		value.actor.add_child(component)
		component.initialize()
		var cut_bone: StringName = &"Hips" if kind == "NATIVE_FULL_CUT" else &"Head"
		component.dismember_limb(cut_bone, Vector3(1, .15, 0))
		await frames()
		if kind == "NATIVE_FULL_CUT":
			var detached: Node = component.get_dismembered_limb_by_name(cut_bone)
			bodies = body_map(detached.get_ragdoll_skeleton())
		else:
			value.skeleton.physical_bones_start_simulation(PackedStringArray(["Hips"]))
			bodies = body_map(value.skeleton)
			if kind.begins_with("NATIVE_SEQUENTIAL_ARM_CUT"):
				for _step in Engine.physics_ticks_per_second:
					await physics_frame
				component.dismember_limb(&"LeftArm", Vector3(.7, .1, 0))
				await frames()
				if kind.ends_with("DETACHED"):
					var detached_arm: Node = component.get_dismembered_limb_by_name(&"LeftArm")
					bodies = body_map(detached_arm.get_ragdoll_skeleton())
				else:
					bodies = body_map(value.skeleton)
	var maximum_gap := 0.0
	var maximum_excess := 0.0
	var maximum_span := 0.0
	var worst_joint := ""
	var measured_joints := 0
	var finite := true
	for _step in Engine.physics_ticks_per_second * 5:
		await physics_frame
		var bounds := AABB()
		var bounds_started := false
		for body: PhysicalBone3D in bodies.values():
			if not bounds_started:
				bounds = AABB(body.global_position, Vector3.ZERO)
				bounds_started = true
			else:
				bounds = bounds.expand(body.global_position)
		maximum_span = maxf(maximum_span, bounds.size.length())
		for constraint in constraints:
			if not bodies.has(constraint.child) or not bodies.has(constraint.parent): continue
			var child: PhysicalBone3D = bodies[constraint.child]
			var parent: PhysicalBone3D = bodies[constraint.parent]
			var child_anchor: Vector3 = (child.global_transform * constraint.child_frame).origin
			var parent_anchor: Vector3 = (parent.global_transform * constraint.parent_frame).origin
			var gap := child_anchor.distance_to(parent_anchor)
			finite = finite and is_finite(gap)
			if gap > maximum_gap:
				maximum_gap = gap
				worst_joint = constraint.parent + " -> " + constraint.child
			var excess: float = parent.global_position.distance_to(child.global_position) - constraint.max_center_span
			maximum_excess = maxf(maximum_excess, excess)
			measured_joints += 1
	print("JOINT_INTEGRITY_EVIDENCE case=", kind, " bodies=", bodies.size(), " physics_hz=", Engine.physics_ticks_per_second,
		" simulated_seconds=5 max_anchor_gap_m=", maximum_gap, " max_center_span_excess_m=", maximum_excess,
		" max_whole_body_diagonal_m=", maximum_span, " worst_joint=", worst_joint)
	expect(finite and measured_joints > 0, kind + " measures finite authored joints each frame")
	expect(maximum_gap < .08, kind + " joint anchors stay connected within eight centimetres under floor impact")
	expect(maximum_excess < .08, kind + " adjacent bodies cannot stretch beyond their authored joint offsets")
	expect(maximum_span < 3.0, kind + " normalized 1.8m body does not stretch into multi-metre strips")
	if component != null: component.clean_up_all_referenced_limbs()
	value.actor.queue_free()
	floor.queue_free()
	await frames()
