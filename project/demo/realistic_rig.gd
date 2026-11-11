extends RefCounted
## Real CC0 skinned humanoid, normalized to metre-sized bones and physics.

const MODEL = preload("res://demo/assets/humanoid/humanoid.glb")

static func find_type(node: Node, type: String) -> Node:
	if node.is_class(type): return node
	for child in node.get_children():
		var result := find_type(child, type)
		if result: return result
	return null

static func build(kind: int) -> Dictionary:
	var imported: Node3D = MODEL.instantiate()
	var old_skeleton: Skeleton3D = find_type(imported,"Skeleton3D")
	var old_mesh: MeshInstance3D = find_type(imported,"MeshInstance3D")
	var actor := Node3D.new()
	actor.name = "CC0Humanoid"
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	actor.add_child(skeleton)
	# This published GLB has centimetre bones under a 0.01 Armature but metre
	# vertex coordinates. Rebinding the same geometry removes inherited body
	# scale from physics without changing its visible rest shape.
	var hips := old_skeleton.find_bone("Hips")
	var unit_scale := 0.01 if old_skeleton.get_bone_global_rest(hips).origin.y > 10.0 else 1.0
	for i in old_skeleton.get_bone_count():
		skeleton.add_bone(old_skeleton.get_bone_name(i))
		skeleton.set_bone_parent(i,old_skeleton.get_bone_parent(i))
		var rest := old_skeleton.get_bone_rest(i)
		rest.origin *= unit_scale
		skeleton.set_bone_rest(i,rest)
	skeleton.reset_bone_poses()
	var skin := Skin.new()
	for i in skeleton.get_bone_count():
		skin.add_bind(i,skeleton.get_bone_global_rest(i).affine_inverse())
	# Imported surface indices refer to Skin bind slots, which may differ from
	# skeleton order. Re-create binds in that original slot order.
	if old_mesh.skin:
		skin = Skin.new()
		for slot in old_mesh.skin.get_bind_count():
			var name: StringName = old_mesh.skin.get_bind_name(slot)
			var bone: int = old_skeleton.find_bone(name) if name != &"" else old_mesh.skin.get_bind_bone(slot)
			skin.add_bind(bone,skeleton.get_bone_global_rest(bone).affine_inverse())
	var mesh := MeshInstance3D.new()
	mesh.name = "SkinMesh"
	mesh.mesh = old_mesh.mesh
	mesh.skin = skin
	mesh.skeleton = NodePath("..")
	mesh.add_to_group("Dismemberment Source",true)
	skeleton.add_child(mesh)
	var specs: Array = []
	var endpoints := {"Hips":"Spine02","Spine02":"Spine01","Spine01":"Spine","Spine":"neck",
		"LeftShoulder":"LeftArm","LeftArm":"LeftForeArm","LeftForeArm":"LeftHand",
		"RightShoulder":"RightArm","RightArm":"RightForeArm","RightForeArm":"RightHand",
		"LeftUpLeg":"LeftLeg","LeftLeg":"LeftFoot","LeftFoot":"LeftToeBase",
		"RightUpLeg":"RightLeg","RightLeg":"RightFoot","RightFoot":"RightToeBase",
		"neck":"Head","Head":"head_end"}
	for i in skeleton.get_bone_count():
		var name := skeleton.get_bone_name(i)
		var start := skeleton.get_bone_global_rest(i).origin
		var end := start
		var radius := 0.05
		if endpoints.has(name):
			end = skeleton.get_bone_global_rest(skeleton.find_bone(endpoints[name])).origin
		elif "Hand" in name:
			var parent := skeleton.get_bone_parent(i)
			end = start + (start-skeleton.get_bone_global_rest(parent).origin).normalized()*0.085
			radius = 0.037
		elif "Toe" in name:
			end = start + Vector3(0,0,0.06)
			radius = 0.035
		else:
			radius = 0.0
		if name == "Head": radius = 0.095
		elif name == "Hips": radius = 0.14
		elif name.begins_with("Spine"): radius = 0.155
		elif name.ends_with("UpLeg"): radius = 0.075
		elif name.ends_with("Leg"): radius = 0.055
		elif name.ends_with("Arm"): radius = 0.052 if "Fore" not in name else 0.043
		elif name.ends_with("Shoulder"): radius = 0.055
		elif name == "neck": radius = 0.045
		specs.append([name,skeleton.get_bone_parent(i),start,end,radius])
	if kind == 2:
		var socket := BoneAttachment3D.new()
		socket.name = "HandAccessory"
		socket.bone_name = "RightHand"
		skeleton.add_child(socket)
		var prop := MeshInstance3D.new()
		prop.name = "TransferableAccessory"
		prop.add_to_group("Transfer Dismemberment",true)
		var shape := BoxMesh.new()
		shape.size = Vector3(.04,.14,.04)
		prop.mesh = shape
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(.2,.22,.24)
		material.metallic = .8
		prop.material_override = material
		socket.add_child(prop)
	imported.free()
	return {"actor":actor,"skeleton":skeleton,"mesh":mesh,"bones":specs}
