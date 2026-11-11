extends RefCounted
## Authored SI ragdoll for the CC0 humanoid. It is built from the actual imported
## rest pose and weighted mesh volume; it does not generate a whole-character
## convex collider. Body masses total 75 kg by default. Call after adding the
## normalized model to the scene tree, before enabling any simulation.

const BODY_GROUP := "Humanoid Authored Physics"
# bone, segment end, mass fraction, collision type, nominal radius, joint
const SPEC := [
	["Hips", "Spine02", 12.0, "torso", .135, "root"],
	["Spine02", "Spine01", 7.0, "torso", .125, "spine"],
	["Spine01", "Spine", 7.0, "torso", .135, "spine"],
	["Spine", "neck", 13.0, "chest", .155, "spine"],
	["Head", "head_end", 5.0, "head", .085, "head"],
	["LeftArm", "LeftForeArm", 2.5, "capsule", .047, "shoulder"],
	["LeftForeArm", "LeftHand", 1.5, "capsule", .037, "elbow"],
	["LeftHand", "", .55, "hand", .038, "hand"],
	["RightArm", "RightForeArm", 2.5, "capsule", .047, "shoulder"],
	["RightForeArm", "RightHand", 1.5, "capsule", .037, "elbow"],
	["RightHand", "", .55, "hand", .038, "hand"],
	["LeftUpLeg", "LeftLeg", 8.0, "capsule", .072, "hip"],
	["LeftLeg", "LeftFoot", 3.5, "capsule", .05, "knee"],
	["LeftFoot", "LeftToeBase", 1.3, "foot", .05, "foot"],
	["RightUpLeg", "RightLeg", 8.0, "capsule", .072, "hip"],
	["RightLeg", "RightFoot", 3.5, "capsule", .05, "knee"],
	["RightFoot", "RightToeBase", 1.3, "foot", .05, "foot"]
]

static func attach(skeleton: Skeleton3D, mesh: MeshInstance3D, total_mass_kg: float = 75.0) -> Dictionary:
	if skeleton == null or mesh == null or not skeleton.is_inside_tree():
		push_error("Humanoid physics requires a normalized skeleton and mesh inside the scene tree.")
		return {"bodies": [], "mass": 0.0, "names": PackedStringArray()}
	clear(skeleton)
	var points := _weighted_world_points(skeleton, mesh)
	var scale_factor := _height(skeleton) / 1.8
	var mass_units := 0.0
	for spec in SPEC:
		if skeleton.find_bone(spec[0]) >= 0:
			mass_units += float(spec[2])
	var bodies: Array[PhysicalBone3D] = []
	var by_bone: Dictionary = {}
	var records: Array[Dictionary] = []
	var names := PackedStringArray()
	for spec in SPEC:
		var index := skeleton.find_bone(spec[0])
		if index < 0:
			continue
		var bone_world := skeleton.global_transform * skeleton.get_bone_global_rest(index)
		var start := bone_world.origin
		var end_index := skeleton.find_bone(spec[1]) if not String(spec[1]).is_empty() else -1
		var endpoint: Vector3
		if end_index >= 0:
			endpoint = (skeleton.global_transform * skeleton.get_bone_global_rest(end_index)).origin
		else:
			var parent := skeleton.get_bone_parent(index)
			var direction := bone_world.basis.y.normalized()
			if parent >= 0 and spec[3] != "hand":
				var parent_origin := (skeleton.global_transform * skeleton.get_bone_global_rest(parent)).origin
				direction = (start - parent_origin).normalized()
			endpoint = start + direction * .11 * scale_factor
		var delta := endpoint - start
		if delta.length() < .005 * scale_factor:
			delta = bone_world.basis.y.normalized() * .1 * scale_factor
			endpoint = start + delta
		var length := delta.length()
		var body_basis := bone_world.basis.orthonormalized() if spec[3] == "hand" else Basis(Quaternion(Vector3.UP, delta.normalized())).orthonormalized()
		var center := start.lerp(endpoint, .5)
		var radius := float(spec[4]) * scale_factor
		var point_bounds := _oriented_bounds(points.get(index, []), center, body_basis)
		if point_bounds.has_surface():
			if spec[3] == "hand":
				# Fit weighted hand vertices in the hand's rest axes and world metres.
				# The box center and body offset must move together to preserve the wrist pivot.
				center += body_basis * point_bounds.get_center()
			else:
				# Fit cross-section to this bone's weighted geometry, while preventing a
				# handful of blended seam vertices from creating oversized colliders.
				var fitted_radius := maxf(point_bounds.size.x, point_bounds.size.z) * .5
				radius = clampf(fitted_radius * .88, radius * .75, radius * 1.3)
				var transverse := point_bounds.get_center()
				transverse.y = 0
				transverse.x = clampf(transverse.x, -radius * .35, radius * .35)
				transverse.z = clampf(transverse.z, -radius * .35, radius * .35)
				center += body_basis * transverse
		var body := PhysicalBone3D.new()
		body.name = "Physics_" + String(spec[0])
		body.set("bone_name", StringName(spec[0]))
		body.add_to_group(BODY_GROUP)
		body.mass = total_mass_kg * float(spec[2]) / mass_units
		# Let palms slide on the floor during a fall instead of catching at the wrist.
		body.friction = .35 if spec[3] == "hand" else .7
		body.bounce = .015
		body.linear_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
		body.angular_damp_mode = PhysicalBone3D.DAMP_MODE_REPLACE
		body.linear_damp = .04
		body.angular_damp = .3
		body.collision_layer = 8
		body.collision_mask = 1 | 8
		# Shape sizes are world metres, including any uniform import scale. The
		# body offset positions the mass centre in bone space; its basis is pure
		# rotation so PhysicsServer receives an unscaled rigid body transform.
		var bone_basis := bone_world.basis.orthonormalized()
		body.body_offset = Transform3D(bone_basis.inverse() * body_basis, bone_world.affine_inverse() * center)
		var collision := CollisionShape3D.new()
		collision.name = "AuthoredCollision"
		var kind: String = spec[3]
		if kind in ["torso", "chest", "hand", "foot"]:
			var box := BoxShape3D.new()
			match kind:
				"torso": box.size = Vector3(radius * 1.85, maxf(length * .88, .065 * scale_factor), radius * 1.3)
				"chest": box.size = Vector3(radius * 1.9, maxf(length * 1.05, .09 * scale_factor), radius * 1.35)
				"hand": box.size = point_bounds.size if point_bounds.has_surface() else Vector3(.075, .11, .045) * scale_factor
				"foot": box.size = Vector3(.09, maxf(length * 1.3, .18 * scale_factor), .065 * scale_factor)
			collision.shape = box
		else:
			var capsule := CapsuleShape3D.new()
			capsule.radius = radius
			capsule.height = maxf(radius * 2.05, length * (.94 if kind == "head" else .91))
			collision.shape = capsule
		body.add_child(collision)
		skeleton.add_child(body)
		body.set_meta("authored_mass_kg", body.mass)
		body.set_meta("authored_joint_kind", spec[5])
		body.set_meta("source_units", "metres_kilograms_seconds")
		bodies.append(body)
		by_bone[index] = body
		names.append(String(spec[0]))
		records.append({"body": body, "index": index, "kind": spec[5], "direction": delta.normalized(), "basis": body_basis})
	# Deliberately configure joints after all bodies exist. The engine then
	# computes both constraint frames from this exact pose, including skipped
	# nonphysical neck/clavicle bones, rather than using stale parent anchors.
	for record in records:
		var body: PhysicalBone3D = record.body
		var parent_index := _physical_parent(skeleton, record.index, by_bone)
		if parent_index < 0:
			body.joint_type = PhysicalBone3D.JOINT_TYPE_NONE
			continue
		_configure_joint(body, record.kind, record.direction, record.basis, skeleton)
		var parent_body: PhysicalBone3D = by_bone[parent_index]
		body.add_collision_exception_with(parent_body)
		parent_body.add_collision_exception_with(body)
		# Thorax segments and the head can overlap a grandparent collider slightly
		# at a shared joint. Match a physics asset collision-disable table for these
		# neighbouring bodies while retaining nonadjacent limb/body collisions.
		var grandparent_index := _physical_parent(skeleton, parent_index, by_bone)
		if grandparent_index >= 0 and record.kind in ["spine", "head", "shoulder"]:
			var grandparent: PhysicalBone3D = by_bone[grandparent_index]
			body.add_collision_exception_with(grandparent)
			grandparent.add_collision_exception_with(body)
	return {"bodies": bodies, "mass": total_mass_kg, "names": names, "height_m": _height(skeleton), "scale": scale_factor}

static func clear(skeleton: Skeleton3D) -> void:
	for node in skeleton.find_children("*", "PhysicalBone3D", true, false):
		if node.is_in_group(BODY_GROUP):
			node.free()

static func _physical_parent(skeleton: Skeleton3D, index: int, by_bone: Dictionary) -> int:
	var parent := skeleton.get_bone_parent(index)
	while parent >= 0:
		if by_bone.has(parent):
			return parent
		parent = skeleton.get_bone_parent(parent)
	return -1

static func _height(skeleton: Skeleton3D) -> float:
	var minimum := INF
	var maximum := -INF
	for index in skeleton.get_bone_count():
		var position := (skeleton.global_transform * skeleton.get_bone_global_rest(index)).origin
		minimum = minf(minimum, position.y)
		maximum = maxf(maximum, position.y)
	return maxf(maximum - minimum, .1)

static func _configure_joint(body: PhysicalBone3D, kind: String, direction: Vector3, body_basis: Basis, skeleton: Skeleton3D) -> void:
	if kind in ["elbow", "knee"]:
		var forward := _forward(skeleton)
		var axis := direction.cross(forward).normalized()
		if axis.length_squared() < .5:
			axis = skeleton.global_basis.orthonormalized().x
		if kind == "knee": axis = -axis
		var x_axis := direction.normalized()
		var y_axis := axis.cross(x_axis).normalized()
		x_axis = y_axis.cross(axis).normalized()
		var joint := body.joint_offset
		joint.basis = body_basis.inverse() * Basis(x_axis, y_axis, axis)
		body.joint_offset = joint
		body.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
		body.set("joint_constraints/angular_limit_enabled", true)
		# PhysicalBone3D's dynamic joint properties use degrees (the native
		# PhysicsServer API uses radians internally).
		body.set("joint_constraints/angular_limit_lower", -4.0)
		body.set("joint_constraints/angular_limit_upper", 145.0 if kind == "knee" else 150.0)
		body.set("joint_constraints/angular_limit_bias", .2)
		body.set("joint_constraints/angular_limit_softness", .85)
		body.set("joint_constraints/angular_limit_relaxation", 1.0)
	else:
		# The swing/twist joint frame uses X along the limb, whereas CapsuleShape3D's long
		# axis is Y. Align the joint frame with the anatomical segment explicitly.
		var x_axis := direction.normalized()
		var reference := _forward(skeleton)
		if absf(x_axis.dot(reference)) > .9:
			reference = skeleton.global_basis.orthonormalized().x
		var z_axis := x_axis.cross(reference).normalized()
		var y_axis := z_axis.cross(x_axis).normalized()
		var joint := body.joint_offset
		joint.basis = body_basis.inverse() * Basis(x_axis, y_axis, z_axis)
		body.joint_offset = joint
		body.joint_type = PhysicalBone3D.JOINT_TYPE_6DOF
		var swing := 20.0
		var twist := 15.0
		match kind:
			"head": swing = 35.0; twist = 40.0
			"shoulder": swing = 75.0; twist = 50.0
			"hip": swing = 55.0; twist = 25.0
			"hand": swing = 35.0; twist = 35.0
			"foot": swing = 25.0; twist = 15.0
		for axis in ["x", "y", "z"]:
			var prefix: String = "joint_constraints/" + String(axis) + "/"
			body.set(prefix + "linear_limit_enabled", true)
			body.set(prefix + "linear_limit_lower", 0.0)
			body.set(prefix + "linear_limit_upper", 0.0)
			body.set(prefix + "angular_limit_enabled", true)
			var limit := twist if axis == "x" else swing
			body.set(prefix + "angular_limit_lower", -limit)
			body.set(prefix + "angular_limit_upper", limit)
			body.set(prefix + "angular_limit_softness", .5)
			body.set(prefix + "angular_damping", 1.0)
			body.set(prefix + "erp", .25)

static func _forward(skeleton: Skeleton3D) -> Vector3:
	# This published character faces +Z, unlike a Godot camera's -Z. Use the
	# actual anatomical face marker so elbow and knee flexion are not reversed.
	var head := skeleton.find_bone("Head")
	var front := skeleton.find_bone("headfront")
	if head >= 0 and front >= 0:
		var direction := skeleton.global_basis * (skeleton.get_bone_global_rest(front).origin - skeleton.get_bone_global_rest(head).origin)
		direction.y = 0
		if direction.length_squared() > .0001: return direction.normalized()
	return skeleton.global_basis.orthonormalized().z

static func _weighted_world_points(skeleton: Skeleton3D, mesh: MeshInstance3D) -> Dictionary:
	var result: Dictionary = {}
	if mesh.mesh == null:
		return result
	var skin := mesh.skin
	var remap: Array[int] = []
	if skin != null:
		for bind in skin.get_bind_count():
			var name := skin.get_bind_name(bind)
			remap.append(skeleton.find_bone(name) if not name.is_empty() else skin.get_bind_bone(bind))
	for surface in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if vertices.is_empty() or bones.size() != weights.size():
			continue
		var stride := bones.size() / vertices.size()
		if stride not in [4, 8]:
			continue
		for vertex in vertices.size():
			var best := -1
			var best_weight := 0.0
			for slot in stride:
				var offset: int = vertex * stride + slot
				if weights[offset] > best_weight:
					best_weight = weights[offset]
					best = bones[offset]
			if skin != null:
				best = remap[best] if best >= 0 and best < remap.size() else -1
			if best < 0:
				continue
			if not result.has(best): result[best] = []
			result[best].append(mesh.global_transform * vertices[vertex])
	return result

static func _oriented_bounds(points: Array, center: Vector3, basis: Basis) -> AABB:
	if points.is_empty():
		return AABB()
	var inverse := basis.inverse()
	var first: Vector3 = inverse * (points[0] - center)
	var bounds := AABB(first, Vector3.ZERO)
	for point: Vector3 in points:
		bounds = bounds.expand(inverse * (point - center))
	return bounds
