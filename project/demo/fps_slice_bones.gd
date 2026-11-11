extends RefCounted
## Captures authored hit regions in the coordinates shared by a mesh and its slices.

const MAX_HIT_GAP := 0.075
const MAX_JOINT_OFFSET := 0.015
const MAX_HULL_DEPTH := 0.22
const MAX_PROXIMAL_HIT_GAP := 0.035
const LIMB_BOUNDS_MARGIN := 0.12
const THIGH_LATERAL_BIAS := 1.25

static func capture(target: Dictionary, poses: Array[Transform3D] = []) -> Dictionary:
	var skeleton: Skeleton3D = target.skeleton
	var mesh: MeshInstance3D = target.mesh
	var component: GoreComponent = target.component
	if poses.is_empty():
		poses = _capture_poses(mesh, skeleton)
	var missing: Dictionary = target.missing
	var regions: Array[Dictionary] = []
	var limb_bounds := {}
	for hitbox: Dictionary in target.hitboxes:
		var area: Area3D = hitbox.area
		var bone_index: int = hitbox.index
		if _is_missing(skeleton, bone_index, missing):
			continue
		var requested: StringName = area.get_meta(&"requested_bone", hitbox.bone)
		var bone := StringName(component.remapped_bones.get(requested, requested))
		var cut_index := skeleton.find_bone(bone)
		var can_cut := cut_index >= 0 and not component.disable_dismemberment \
			and component.check_bone_filter(bone) and not _is_missing(skeleton, cut_index, missing)
		var area_pose: Transform3D = poses[bone_index] * hitbox.local
		for child in area.get_children():
			var collider := child as CollisionShape3D
			if collider == null or collider.disabled or not collider.shape is BoxShape3D:
				continue
			var box := collider.shape as BoxShape3D
			var frame := area_pose * collider.transform
			if not frame.is_finite() or absf(frame.basis.determinant()) < 0.00000001:
				continue
			var shape_bounds := frame * AABB(-box.size * 0.5, box.size)
			var ancestor := bone_index
			while ancestor >= 0:
				var ancestor_name := skeleton.get_bone_name(ancestor)
				if limb_bounds.has(ancestor_name):
					var previous: AABB = limb_bounds[ancestor_name]
					limb_bounds[ancestor_name] = previous.merge(shape_bounds)
				else:
					limb_bounds[ancestor_name] = shape_bounds
				ancestor = skeleton.get_bone_parent(ancestor)
			var plane := Plane()
			if can_cut:
				plane = _joint_plane(poses, skeleton, cut_index, frame.origin)
			var region := {
				"bone": bone,
				"frame": frame,
				"inverse": frame.affine_inverse(),
				"half_size": box.size * 0.5,
				"plane": plane,
			}
			region.make_read_only()
			regions.append(region)
	regions.make_read_only()
	limb_bounds.make_read_only()
	var snapshot := {"regions": regions, "limb_bounds": limb_bounds}
	snapshot.make_read_only()
	return snapshot

static func resolve(snapshot: Dictionary, mesh_local_hit: Vector3,
		mesh_local_direction := Vector3.ZERO) -> Dictionary:
	if not mesh_local_hit.is_finite() or not mesh_local_direction.is_finite():
		return {}
	# A convex collider can bridge the gap between articulated limbs. Follow the
	# incoming ray through it to recover the first authored hit region.
	var project_ray := not mesh_local_direction.is_zero_approx()
	var ray_end := mesh_local_hit + mesh_local_direction.normalized() * MAX_HULL_DEPTH
	var best_score := INF
	var closest: Dictionary = {}
	var seed := mesh_local_hit
	var found_ray_contact := false
	for region: Dictionary in snapshot.get("regions", []):
		var inverse: Transform3D = region.inverse
		var frame: Transform3D = region.frame
		var half_size: Vector3 = region.half_size
		var box_hit := inverse * mesh_local_hit
		if project_ray:
			var entry = AABB(-half_size, half_size * 2.0).intersects_segment(box_hit, inverse * ray_end)
			if entry is Vector3:
				var ray_contact: Vector3 = frame * entry
				var distance := mesh_local_hit.distance_to(ray_contact)
				var ray_score := distance + ray_contact.distance_to(frame.origin) * 0.05
				if not found_ray_contact or ray_score < best_score:
					best_score = ray_score
					closest = region
					seed = ray_contact
				found_ray_contact = true
				continue
		if found_ray_contact:
			continue
		var box_contact := frame * box_hit.clamp(-half_size, half_size)
		var gap := mesh_local_hit.distance_to(box_contact)
		if gap > MAX_HIT_GAP:
			continue
		var score := gap + mesh_local_hit.distance_to(frame.origin) * 0.15
		if score < best_score:
			best_score = score
			closest = region
	if closest.is_empty():
		return {}
	var plane: Plane = closest.plane
	if plane.normal.is_zero_approx():
		return {}
	var offset := plane.distance_to(seed)
	if offset < -MAX_PROXIMAL_HIT_GAP:
		return {}
	seed += plane.normal * maxf(0.0, 0.003 - offset)
	var bounds: AABB = snapshot.limb_bounds.get(closest.bone, AABB())
	return {"bone": closest.bone, "plane": plane, "seed": seed,
		"bounds": bounds.grow(LIMB_BOUNDS_MARGIN)}

static func _capture_poses(mesh: MeshInstance3D, skeleton: Skeleton3D) -> Array[Transform3D]:
	var evaluated := {}
	var skin_ref := mesh.get_skin_reference()
	if skin_ref != null and skin_ref.get_skeleton().is_valid():
		var skin := skin_ref.get_skin()
		var palette := skin_ref.get_skeleton()
		if skin != null and RenderingServer.skeleton_get_bone_count(palette) == skin.get_bind_count():
			for bind in skin.get_bind_count():
				var name := skin.get_bind_name(bind)
				var bone := skin.get_bind_bone(bind) if name == &"" else skeleton.find_bone(name)
				var inverse_rest := skin.get_bind_pose(bind)
				if bone < 0 or absf(inverse_rest.basis.determinant()) < 0.00000001:
					continue
				var pose := RenderingServer.skeleton_bone_get_transform(palette, bind) * inverse_rest.affine_inverse()
				if pose.is_finite() and absf(pose.basis.determinant()) >= 0.00000001:
					evaluated[bone] = pose

	var poses: Array[Transform3D] = []
	for bone in skeleton.get_bone_count():
		var pose := skeleton.get_bone_global_pose(bone)
		var local_chain := Transform3D.IDENTITY
		var cursor := bone
		while cursor >= 0 and not evaluated.is_empty():
			if evaluated.has(cursor):
				pose = evaluated[cursor] * local_chain
				break
			local_chain = skeleton.get_bone_pose(cursor) * local_chain
			cursor = skeleton.get_bone_parent(cursor)
		poses.append(pose)
	return poses

static func _joint_plane(poses: Array[Transform3D], skeleton: Skeleton3D, bone: int, center: Vector3) -> Plane:
	var joint := poses[bone].origin
	var outward := center - joint
	var parent := skeleton.get_bone_parent(bone)
	var name := skeleton.get_bone_name(bone)
	var upper_arm := name in [&"LeftArm", &"RightArm"]
	var thigh := name in [&"LeftUpLeg", &"RightUpLeg"]
	if parent >= 0 and (upper_arm or thigh):
		var lateral := joint - poses[parent].origin
		var spine := skeleton.find_bone(&"Spine")
		var lower_spine := skeleton.find_bone(&"Spine01")
		if spine >= 0 and lower_spine >= 0:
			var torso_up := (poses[spine].origin - poses[lower_spine].origin).normalized()
			if not torso_up.is_zero_approx():
				lateral = lateral.slide(torso_up)
		if lateral.length_squared() >= 0.000001:
			# A downward arm plane can cross the chest. An oblique thigh
			# plane crosses the middle of the pelvis below the crotch.
			if upper_arm:
				outward = lateral
			else:
				outward += lateral.normalized() * outward.length() * THIGH_LATERAL_BIAS
	if outward.length_squared() < 0.000001:
		if parent < 0:
			return Plane()
		outward = joint - poses[parent].origin
	if outward.length_squared() < 0.000001:
		return Plane()
	var normal := outward.normalized()
	var offset := minf(MAX_JOINT_OFFSET, outward.length() * 0.12)
	return Plane(normal, joint + normal * offset)

static func _is_missing(skeleton: Skeleton3D, bone: int, missing: Dictionary) -> bool:
	var ancestor := bone
	while ancestor >= 0:
		if missing.has(skeleton.get_bone_name(ancestor)):
			return true
		ancestor = skeleton.get_bone_parent(ancestor)
	return false
