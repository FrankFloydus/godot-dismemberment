extends SceneTree

const RigFixture = preload("res://tests/rig_fixture.gd")

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func add_socket(skeleton: Skeleton3D, bone: StringName) -> BoneAttachment3D:
	var socket := BoneAttachment3D.new()
	socket.bone_name = bone
	skeleton.add_child(socket)
	return socket

func add_skinned_attachment(parent: Node3D, name: StringName, value: Dictionary) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = name
	mesh.mesh = value.source_mesh
	mesh.skin = value.skin
	parent.add_child(mesh)
	mesh.skeleton = mesh.get_path_to(value.skeleton)
	return mesh

func run() -> void:
	var value := RigFixture.make_rig()
	value.component.geometry_mode = 0
	value.component.limb_rigid_fallback_enabled = false
	value.component.support_attached_child_meshes = true
	var hand_socket := add_socket(value.skeleton, &"hand")
	var other_socket := add_socket(value.skeleton, &"other")
	add_skinned_attachment(value.actor, &"SocketlessClothing", value)
	add_skinned_attachment(hand_socket, &"CutSocketClothing", value)
	add_skinned_attachment(other_socket, &"OtherSocketClothing", value)
	var overridden := add_skinned_attachment(hand_socket, &"OverrideFilteredClothing", value)
	overridden.set_meta("override_socket", &"other")
	var prop := MeshInstance3D.new()
	prop.name = &"TransferProp"
	prop.mesh = BoxMesh.new()
	prop.transform = Transform3D(Basis(Vector3.UP, 0.6), Vector3(0.15, 0.07, -0.03))
	prop.add_to_group("Transfer Dismemberment")
	prop.add_to_group("OverrideSocket:lower")
	hand_socket.add_child(prop)
	var authored_prop_offset := prop.transform
	var filtered_prop := MeshInstance3D.new()
	filtered_prop.name = &"FilteredProp"
	filtered_prop.mesh = BoxMesh.new()
	filtered_prop.add_to_group("Transfer Dismemberment")
	filtered_prop.set_meta("override_socket", &"other")
	hand_socket.add_child(filtered_prop)
	var metadata_prop := MeshInstance3D.new()
	metadata_prop.name = &"MetadataProp"
	metadata_prop.mesh = BoxMesh.new()
	metadata_prop.add_to_group("Transfer Dismemberment")
	metadata_prop.set_meta("override_socket", &"lower")
	value.skeleton.add_child(metadata_prop)
	root.add_child(value.actor)
	await process_frame
	check(value.component.initialize(), "attachment parity fixture initializes")
	value.component.dismember_limb(&"lower", Vector3.ZERO)
	await process_frame
	var limb: DismemberedLimb = value.component.get_dismembered_limb_by_name(&"lower")
	check(is_instance_valid(limb), "attachment parity fixture creates a limb")
	if is_instance_valid(limb):
		var copied_names := PackedStringArray()
		for mesh: MeshInstance3D in limb.get_meshes():
			copied_names.append(String(mesh.name))
		check(copied_names.has("SocketlessClothing"), "socketless skinned clothing is copied")
		check(copied_names.has("CutSocketClothing"), "skinned clothing on the selected branch is copied")
		check(not copied_names.has("OtherSocketClothing"), "skinned clothing on another branch is excluded")
		check(not copied_names.has("OverrideFilteredClothing"), "override socket participates in skinned attachment filtering")
		var detached_socket := prop.get_parent() as BoneAttachment3D
		check(is_instance_valid(detached_socket) and detached_socket.get_parent() == limb.get_ragdoll_skeleton(), "original prop moves to the detached skeleton")
		check(is_instance_valid(detached_socket) and detached_socket.bone_name == &"hand", "override chooses the cut branch while transfer retains the authored hand socket")
		check(prop.transform.is_equal_approx(authored_prop_offset), "transferred prop retains its authored local transform")
		check(filtered_prop.get_parent() == hand_socket, "transfer eligibility respects an override outside the cut subtree")
		var metadata_socket := metadata_prop.get_parent() as BoneAttachment3D
		check(is_instance_valid(metadata_socket) and metadata_socket.bone_name == &"lower", "transfer with no authored socket retains the existing metadata binding")
	value.component.reset_all_limbs()
	await process_frame
	check(prop.get_parent() == hand_socket and prop.transform.is_equal_approx(authored_prop_offset), "reset restores the original socket and local transform")
	value.actor.queue_free()
	await process_frame
	print("ATTACHMENT_SOCKET_PARITY: checks=", checks, " failures=", failures)
	quit(0 if failures == 0 else 1)
