extends SceneTree

const Fixture = preload("res://tests/rig_fixture.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("TEST FAILURE: " + message)

func near_array(actual: PackedFloat32Array, expected: Array) -> bool:
	if actual.size() != expected.size():
		return false
	for index in actual.size():
		if absf(actual[index] - float(expected[index])) > .0001:
			return false
	return true

func fixture(kind: String = "DismembermentComponent", eight_weights: bool = false) -> Dictionary:
	var value: Dictionary = Fixture.make_rig(kind, eight_weights)
	root.add_child(value.actor)
	return value

func release(value: Dictionary) -> void:
	if is_instance_valid(value.get("component")):
		value.component.clean_up_all_referenced_limbs()
	if is_instance_valid(value.get("actor")):
		value.actor.queue_free()
	await process_frame
	await process_frame

func frames(count: int = 3) -> void:
	for index in count:
		await process_frame

func _run() -> void:
	for class_name_value in ["DismembermentComponent", "DismemberedLimb", "LimbMap", "GoreComponent", "BloodPool"]:
		expect(ClassDB.class_exists(class_name_value), "native class registered: " + class_name_value)
	if not failures.is_empty():
		finish()
		return
	if "--attachment-only" in OS.get_cmdline_user_args():
		await test_attachments()
		finish()
		return
	await test_limb_map(false)
	await test_limb_map(true)
	await test_influence_edges()
	await test_severing_and_cleanup()
	await test_pose_snapshot()
	await test_authored_physics()
	await test_mass_independent_impulse()
	await test_bone_collapse()
	await test_filters()
	await test_destroy_and_reset()
	await test_attachments()
	await test_replication()
	await test_serialization()
	await test_blood()
	await test_pool_lifetime()
	finish()

func triangle_count(mesh: Mesh) -> int:
	var count := 0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		count += indices.size() / 3 if not indices.is_empty() else arrays[Mesh.ARRAY_VERTEX].size() / 3
	return count

func test_limb_map(eight_weights: bool) -> void:
	var value: Dictionary = fixture("DismembermentComponent", eight_weights)
	await frames()
	var map: Resource = ClassDB.instantiate("LimbMap")
	expect(map.initialize(value.skeleton, value.mesh), "LimbMap accepts weighted mesh with %d influences" % (8 if eight_weights else 4))
	expect(map.get_vertex_num() == 20, "LimbMap reports all surface vertices")
	expect(map.get_all_bones_of_limb(&"upper") == PackedStringArray(["upper", "lower", "hand"]), "limb query includes cut bone and descendants")
	expect(map.get_bone_index(&"missing") == -1, "invalid bone index is safe")
	expect(map.get_mapped_bone_index(0) == 3, "Skin bind index resolves shuffled skeleton bone")
	expect(map.get_bone_with_most_influence(8) == 3, "dominant influence resolves shuffled Skin bind")
	expect(map.get_weights_of_bone(&"lower")[8] > .99, "bone weight lookup uses Skin binding")
	var weights: PackedFloat32Array = map.get_weights_of_limb(&"upper")
	expect(near_array(weights, [0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0]), "subtree weights match geometry across all vertices")
	var original_colors: PackedColorArray = value.source_mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var original_bones: PackedInt32Array = value.source_mesh.surface_get_arrays(0)[Mesh.ARRAY_BONES]
	expect(map.set_limb_weights(value.mesh, &"upper", .25), "limb skin weighting succeeds")
	var painted_colors: PackedColorArray = value.mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var rewritten_bones: PackedInt32Array = value.mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_BONES]
	expect(rewritten_bones[0] == 3 and rewritten_bones[8 * (8 if eight_weights else 4)] == 0, "limb skin rewrite pins outside geometry while retaining descendant influences")
	expect(value.source_mesh.surface_get_arrays(0)[Mesh.ARRAY_BONES] == original_bones, "limb skin weighting preserves shared source mesh")
	expect(painted_colors == original_colors, "limb skin weighting preserves vertex colors")
	map.exclude = PackedStringArray(["hand"])
	expect(not map.get_all_bones_of_limb(&"upper").has("hand"), "keyword exclusion filters descendants")
	await release(value)

func test_influence_edges() -> void:
	for eight_weights in [false, true]:
		var value: Dictionary = fixture("DismembermentComponent", eight_weights)
		await frames()
		var arrays: Array = value.source_mesh.surface_get_arrays(0)
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		if eight_weights:
			bones[0] = 2 # Bind 2 -> the unrelated 'other' skeleton bone.
			weights[0] = .4
			bones[6] = 0 # Bind 0 -> lower; deliberately beyond the first 4 slots.
			weights[6] = .6
		else:
			bones[0] = 3 # upper
			weights[0] = .4
			bones[1] = 0 # lower
			weights[1] = .3
			bones[2] = 2 # other
			weights[2] = .3
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
		var mixed_mesh := ArrayMesh.new()
		mixed_mesh.add_blend_shape("test_morph")
		mixed_mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
		mixed_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, value.source_mesh.surface_get_blend_shape_arrays(0), {}, Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS if eight_weights else 0)
		value.mesh.mesh = mixed_mesh
		var map: Resource = ClassDB.instantiate("LimbMap")
		map.initialize(value.skeleton, value.mesh)
		var expected_weight := .6 if eight_weights else .4
		expect(is_equal_approx(map.get_weights_of_limb(&"upper")[0], expected_weight), "limb mask uses maximum individual influence, including 8-weight high slots")
		var named_skin: Skin = value.skin.duplicate()
		named_skin.set_bind_bone(0, -1)
		named_skin.set_bind_name(0, &"hand")
		value.mesh.skin = named_skin
		expect(map.get_mapped_bone_index(0) == 4, "named Skin binds resolve by skeleton bone name")
		await release(value)

func test_severing_and_cleanup() -> void:
	var value: Dictionary = fixture()
	await frames()
	var component: Node = value.component
	expect(component.initialize(), "component initializes valid mesh")
	var source_arrays: Array = value.source_mesh.surface_get_arrays(0)
	component.dismember_limb(&"lower", Vector3(.2, .1, 0))
	await frames()
	var child_limb: Node = component.get_dismembered_limb_by_name(&"lower")
	expect(is_instance_valid(child_limb), "severing creates native physics limb")
	expect(component.get_dismembered_limb_by_name(&"hand") == child_limb, "descendant missing-bone lookup points at same limb")
	expect(component.get_all_dismembered_limbs().size() == 1, "descendants do not duplicate detached-limb count")
	component.dismember_limb(&"hand", Vector3.ZERO)
	await frames()
	expect(component.get_all_dismembered_limbs().size() == 1, "already missing descendant cannot sever twice")
	component.dismember_limb(&"upper", Vector3.ZERO)
	await frames()
	expect(component.get_all_dismembered_limbs().size() == 2, "severing parent retains previously detached child")
	var parent_limb: Node = component.get_dismembered_limb_by_name(&"upper")
	if is_instance_valid(parent_limb):
		var triangles := 0
		for limb_mesh in parent_limb.get_meshes():
			triangles += triangle_count(limb_mesh.mesh)
		expect(triangles == 2, "parent detached geometry excludes an earlier severed child")
	expect(value.source_mesh.surface_get_arrays(0) == source_arrays, "runtime cutting leaves original mesh data unchanged")
	component.clean_up_all_referenced_limbs()
	await frames()
	expect(component.get_all_dismembered_limbs().is_empty(), "cleanup deletes detached physics objects")
	component.dismember_limb(&"upper", Vector3.ZERO)
	await frames()
	expect(component.get_all_dismembered_limbs().is_empty(), "cleanup preserves missing-bone state until reset")
	component.reset_all_limbs()
	component.dismember_limb(&"upper", Vector3.ZERO)
	await frames()
	expect(component.get_all_dismembered_limbs().size() == 1, "reset restores cut eligibility")
	await release(value)

func test_replication() -> void:
	var server: Dictionary = fixture()
	var client: Dictionary = fixture()
	await frames()
	server.component.initialize()
	client.component.initialize()
	server.component.dismember_limb(&"lower", Vector3(.1, 0, 0))
	await frames()
	var state: Dictionary = server.component.get_replication_state()
	expect(client.component.apply_replication_state(state), "late-join state applies a valid cut")
	await frames()
	expect(client.component.get_dismembered_bones().has("lower"), "late-join client receives missing limb state")
	expect(client.component.get_all_dismembered_limbs().size() == 1, "state replay creates one limb")
	expect(client.component.apply_replication_state(state), "state replay is idempotent")
	await frames()
	expect(client.component.get_all_dismembered_limbs().size() == 1, "duplicate snapshot cannot duplicate limb")
	var bad_state: Dictionary = state.duplicate(true)
	bad_state.version = 999
	expect(not client.component.apply_replication_state(bad_state), "unsupported replication version is rejected")
	bad_state = state.duplicate(true)
	bad_state.revision = state.revision + 1
	bad_state.dismembered_bones = PackedStringArray(["missing"])
	expect(not client.component.apply_replication_state(bad_state), "invalid replication bone is rejected")
	server.component.reset_all_limbs()
	var reset_state: Dictionary = server.component.get_replication_state()
	expect(client.component.apply_replication_state(reset_state), "reset state can be replicated")
	await frames()
	expect(client.component.get_all_dismembered_limbs().is_empty() and client.component.get_dismembered_bones().is_empty(), "replicated reset clears missing state and detached objects")
	server.component.dismember_limb(&"upper", Vector3(INF, 0, 0))
	await frames()
	expect(server.component.get_all_dismembered_limbs().is_empty(), "non-finite impulses cannot enter physics")
	await release(server)
	await release(client)

func test_filters() -> void:
	var value: Dictionary = fixture()
	await frames()
	var component: Node = value.component
	component.initialize()
	component.excluded_bones = PackedStringArray(["lower"])
	for bone in [&"missing", &"VB_aux", &"lower"]:
		component.dismember_limb(bone, Vector3.ZERO)
	await frames()
	expect(component.get_all_dismembered_limbs().is_empty(), "invalid, virtual and excluded bones produce no limbs")
	component.whitelist_bones = PackedStringArray(["other"])
	component.dismember_limb(&"upper", Vector3.ZERO)
	await frames()
	expect(component.get_all_dismembered_limbs().is_empty(), "whitelist rejects unlisted bone")
	component.remapped_bones = {&"pelvis": &"other"}
	component.dismember_limb(&"pelvis", Vector3.ZERO)
	await frames()
	expect(is_instance_valid(component.get_dismembered_limb_by_name(&"other")), "remapping happens before bone filtering")
	component.reset_all_limbs()
	component.disable_dismemberment = true
	component.dismember_limb(&"other", Vector3.ZERO)
	await frames()
	expect(component.get_all_dismembered_limbs().is_empty(), "disable flag gates public dismember API")
	await release(value)

func test_mass_independent_impulse() -> void:
	var light: Dictionary = fixture()
	var heavy: Dictionary = fixture()
	light.actor.position.x = -10
	heavy.actor.position.x = 10
	light.component.limb_mass = .5
	heavy.component.limb_mass = 5.0
	await frames()
	for value in [light, heavy]:
		value.component.initialize()
		value.component.dismember_limb(&"lower", Vector3(2, 0, 0))
		var body: RigidBody3D = value.component.get_dismembered_limb_by_name(&"lower")
		body.gravity_scale = 0
		body.linear_damp = 0
		body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	await physics_frame
	await physics_frame
	var light_limb: RigidBody3D = light.component.get_dismembered_limb_by_name(&"lower")
	var heavy_limb: RigidBody3D = heavy.component.get_dismembered_limb_by_name(&"lower")
	expect(absf(light_limb.linear_velocity.x - 2.0) < .02, "light limb receives requested delta velocity")
	expect(absf(heavy_limb.linear_velocity.x - 2.0) < .02, "heavy limb receives requested delta velocity")
	expect(absf(light_limb.linear_velocity.x - heavy_limb.linear_velocity.x) < .01, "dismember impulse preserves source mass-independent velocity semantics")
	await release(light)
	await release(heavy)

func test_bone_collapse() -> void:
	var defaults: Node = ClassDB.instantiate("DismembermentComponent")
	expect(defaults.geometry_mode == 0, "native component defaults to source-compatible bone collapse")
	defaults.free()
	var value: Dictionary = fixture()
	value.component.geometry_mode = 0
	# Smoothly weighted cut-boundary vertices share upper/lower influences. This
	# guards the original continuous-skin workflow against triangle deletion.
	var arrays: Array = value.source_mesh.surface_get_arrays(0)
	var mixed_bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var mixed_weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	for vertex in range(8, 12):
		mixed_bones[vertex * 4] = 0 # lower bind
		mixed_weights[vertex * 4] = .6
		mixed_bones[vertex * 4 + 1] = 3 # upper bind
		mixed_weights[vertex * 4 + 1] = .4
	arrays[Mesh.ARRAY_BONES] = mixed_bones
	arrays[Mesh.ARRAY_WEIGHTS] = mixed_weights
	var continuous_mesh := ArrayMesh.new()
	continuous_mesh.add_blend_shape("test_morph")
	continuous_mesh.set_blend_shape_mode(Mesh.BLEND_SHAPE_MODE_RELATIVE)
	continuous_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, value.source_mesh.surface_get_blend_shape_arrays(0))
	value.mesh.mesh = continuous_mesh
	await frames()
	value.component.initialize()
	var source_triangles := triangle_count(value.mesh.mesh)
	var original_scale: Vector3 = value.skeleton.get_bone_pose_scale(3)
	value.component.dismember_limb(&"lower", Vector3.ZERO)
	await frames()
	expect(value.skeleton.get_bone_pose_scale(3).is_equal_approx(original_scale), "source hiding preserves animation pose; rendered palette hiding is verified separately")
	expect(triangle_count(value.mesh.mesh) == source_triangles, "collapse mode retains source topology for cut closure")
	var limb: Node = value.component.get_dismembered_limb_by_name(&"lower")
	expect(is_instance_valid(limb), "collapse mode creates a detached native limb")
	if is_instance_valid(limb):
		expect(is_instance_valid(limb.get_ragdoll_skeleton()), "collapse mode preserves a cloned skinned skeleton")
		var cloned_skeleton: Skeleton3D = limb.get_ragdoll_skeleton()
		expect(cloned_skeleton.get_bone_global_pose(5).basis.get_scale().is_equal_approx(Vector3.ONE), "detached physics poses remain uncollapsed; final palette isolation is verified by rendered tests")
		var detached_triangles := 0
		for mesh in limb.get_meshes():
			detached_triangles += triangle_count(mesh.mesh)
			var detached_arrays: Array = mesh.mesh.surface_get_arrays(0)
			expect(detached_arrays[Mesh.ARRAY_BONES] == mixed_bones and detached_arrays[Mesh.ARRAY_WEIGHTS] == mixed_weights, "collapse clone retains smooth mixed skin weights")
		expect(detached_triangles == source_triangles, "collapsed detached skin retains original topology")
		var hull: ConvexPolygonShape3D
		for child in limb.get_children():
			if child is CollisionShape3D and child.shape is ConvexPolygonShape3D:
				hull = child.shape
				break
		var hull_reaches_source_core := false
		if hull != null:
			for point in hull.points:
				hull_reaches_source_core = hull_reaches_source_core or point.x < -0.2
		expect(hull != null and hull.points.size() >= 4 and not hull_reaches_source_core,
			"collapse rigid fallback collider contains the cut subtree instead of the full skin")
	value.component.reset_all_limbs()
	await frames()
	expect(value.skeleton.get_bone_pose_scale(3).is_equal_approx(original_scale), "collapse reset restores original source bone pose scale")
	await release(value)

func test_authored_physics() -> void:
	var value: Dictionary = fixture()
	var authored_bodies: Array[PhysicalBone3D] = []
	for bone_name in ["lower", "hand"]:
		var body := PhysicalBone3D.new()
		body.name = "Physical_" + bone_name
		body.set("bone_name", bone_name)
		body.joint_type = PhysicalBone3D.JOINT_TYPE_PIN
		var collision := CollisionShape3D.new()
		var shape := CapsuleShape3D.new()
		shape.radius = .08
		shape.height = .24
		collision.shape = shape
		body.add_child(collision)
		value.skeleton.add_child(body)
		authored_bodies.append(body)
	await frames()
	value.component.initialize()
	value.component.dismember_limb(&"lower", Vector3(.1, 0, 0))
	await physics_frame
	await physics_frame
	var limb: Node = value.component.get_dismembered_limb_by_name(&"lower")
	expect(is_instance_valid(limb) and limb.is_articulated(), "authored physical bone chain creates articulated detached limb")
	if is_instance_valid(limb) and limb.is_articulated():
		var ragdoll: Skeleton3D = limb.get_ragdoll_skeleton()
		var physical_bones := ragdoll.find_children("*", "PhysicalBone3D", true, false)
		expect(physical_bones.size() == 2, "detached physics contains only authored cut-subtree bodies")
		var bound_and_simulating := true
		for body in physical_bones:
			bound_and_simulating = bound_and_simulating and body.get_bone_id() >= 0 and body.is_simulating_physics()
		expect(bound_and_simulating, "detached authored physics binds to cloned skeleton and starts simulation")
	expect(authored_bodies[0].collision_layer == 0 and authored_bodies[1].collision_layer == 0, "source missing-limb physics bodies stop colliding")
	value.component.reset_all_limbs()
	await frames()
	expect(authored_bodies[0].collision_layer == 1 and authored_bodies[1].collision_layer == 1, "reset restores source physical bone collision layers")
	await release(value)

func test_pose_snapshot() -> void:
	var value: Dictionary = fixture()
	value.actor.transform = Transform3D(Basis(Vector3.UP, .2).scaled(Vector3(1.4, .8, 1.2)), Vector3(3, .5, 2))
	value.skeleton.set_bone_pose_rotation(3, Quaternion(Vector3.FORWARD, .4))
	value.skeleton.set_bone_pose_scale(3, Vector3(1.15, .9, 1.0))
	value.component.morph_targets_to_copy = PackedStringArray(["test_morph"])
	await frames()
	value.component.initialize()
	var original_vertices: PackedVector3Array = value.source_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var deformed_vertex: Vector3 = original_vertices[8] + Vector3(0, 0, .03) * .4
	var expected_world: Vector3 = value.skeleton.global_transform * value.skeleton.get_bone_global_pose(3) * value.skeleton.get_bone_global_rest(3).affine_inverse() * deformed_vertex
	value.component.dismember_limb(&"lower", Vector3.ZERO)
	# The deferred post hook can run before the next physics step, preserving the
	# captured pose exactly while the actual rigid body has already been created.
	await process_frame
	var limb: Node = value.component.get_dismembered_limb_by_name(&"lower")
	var nearest := INF
	if is_instance_valid(limb):
		for piece in limb.get_meshes():
			for surface in piece.mesh.get_surface_count():
				var vertices: PackedVector3Array = piece.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
				for vertex in vertices:
					nearest = minf(nearest, (piece.global_transform * vertex).distance_to(expected_world))
	expect(nearest < .005, "detached mesh captures current rotated/scaled pose, actor transform and selected morph")
	await release(value)

func test_destroy_and_reset() -> void:
	var value: Dictionary = fixture()
	await frames()
	var component: Node = value.component
	component.initialize()
	component.destroy_limb(&"lower")
	await frames()
	expect(component.get_all_dismembered_limbs().is_empty(), "destroy hides a limb without spawning physics")
	component.dismember_limb(&"hand", Vector3.ZERO)
	await frames()
	expect(component.get_all_dismembered_limbs().is_empty(), "destroyed subtree cannot spawn detached descendant")
	component.reset_all_limbs()
	component.dismember_limb(&"hand", Vector3.ZERO)
	await frames()
	expect(component.get_all_dismembered_limbs().size() == 1, "reset also restores destroy-only cuts")
	await release(value)

func test_serialization() -> void:
	var value: Dictionary = fixture()
	await frames()
	for child in value.actor.get_children():
		child.owner = value.actor
	var scene := PackedScene.new()
	expect(scene.pack(value.actor) == OK, "native rig and component serialize as PackedScene")
	var loaded: Node = scene.instantiate()
	root.add_child(loaded)
	await frames()
	var component: Node = loaded.get_node("Dismemberment")
	expect(component.initialize(), "native component resolves paths after PackedScene round trip")
	component.dismember_limb(&"hand", Vector3.ZERO)
	await frames()
	expect(component.get_all_dismembered_limbs().size() == 1, "serialized native component remains functional")
	loaded.queue_free()
	await release(value)

func test_attachments() -> void:
	var value: Dictionary = fixture()
	# Use an actual two-body detached chain: a root-only parent assertion would
	# let a held prop drift away from its articulated hand.
	for bone_name in [&"lower", &"hand"]:
		var body := PhysicalBone3D.new()
		body.name = "AttachmentPhysics_" + String(bone_name)
		body.set("bone_name", bone_name)
		body.gravity_scale = 0
		body.collision_layer = 0
		body.collision_mask = 0
		body.joint_type = PhysicalBone3D.JOINT_TYPE_PIN
		var collision := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = .05
		capsule.height = .14
		collision.shape = capsule
		body.add_child(collision)
		value.skeleton.add_child(body)
	var socket := BoneAttachment3D.new()
	socket.name = "HandSocket"
	socket.bone_name = "hand"
	value.skeleton.add_child(socket)
	var item := MeshInstance3D.new()
	item.name = "TransferItem"
	item.mesh = BoxMesh.new()
	item.add_to_group("Transfer Dismemberment")
	socket.add_child(item)
	item.position = Vector3(.1, .02, 0)
	var ignored := MeshInstance3D.new()
	ignored.name = "IgnoredItem"
	ignored.mesh = BoxMesh.new()
	ignored.add_to_group("Transfer Dismemberment")
	ignored.add_to_group("No Dismemberment")
	socket.add_child(ignored)
	value.component.support_attached_child_meshes = true
	await frames()
	value.component.initialize()
	var initial_transform := item.transform
	var original_item_id := item.get_instance_id()
	var initial_world := item.global_transform
	value.component.dismember_limb(&"lower", Vector3(.75, 0, 0))
	await frames()
	var limb: Node = value.component.get_dismembered_limb_by_name(&"lower")
	expect(is_instance_valid(limb) and limb.is_articulated(), "attachment test detaches an authored articulated chain")
	var transferred_socket := item.get_parent() as BoneAttachment3D
	expect(is_instance_valid(transferred_socket), "transfer group moves the original item into a cloned bone socket")
	if is_instance_valid(transferred_socket) and is_instance_valid(limb):
		var clone: Skeleton3D = limb.get_ragdoll_skeleton()
		expect(transferred_socket.get_parent() == clone and transferred_socket.bone_name == "hand", "transferred item uses the hand socket on the detached skeleton")
		expect(item.get_instance_id() == original_item_id and item.transform.is_equal_approx(initial_transform), "transfer preserves the original item and its local hand offset")
		if DisplayServer.get_name() != "headless":
			for _frame in 30:
				await physics_frame
			await RenderingServer.frame_post_draw
			var hand_body: PhysicalBone3D
			for body: PhysicalBone3D in clone.find_children("*", "PhysicalBone3D", true, false):
				if body.get_bone_id() == clone.find_bone("hand"):
					hand_body = body
			expect(is_instance_valid(hand_body) and hand_body.is_simulating_physics(), "the detached hand is driven by live authored physics")
			if is_instance_valid(hand_body):
				var expected_world := hand_body.global_transform * hand_body.body_offset.affine_inverse() * initial_transform
				expect(item.global_position.distance_to(initial_world.origin) > .02, "transferred item moves with the detached physical chain")
				expect(item.global_position.distance_to(expected_world.origin) < .015, "transferred item follows the articulated hand rather than the frozen limb root")
		else:
			print("ATTACHMENT_MOTION_SKIPPED: dummy renderer does not evaluate final skeleton modifiers; run --attachment-only with rendering")
	expect(ignored.get_parent() == socket, "No Dismemberment group prevents attachment transfer")
	expect(not ignored.is_visible_in_tree(), "ignored attachment remains hidden on the missing source socket")
	value.component.reset_all_limbs()
	await frames()
	expect(is_instance_valid(item) and item.get_parent() == socket and item.transform.is_equal_approx(initial_transform), "reset restores original attachment parent and local pose")
	expect(ignored.get_parent() == socket and ignored.is_visible_in_tree(), "reset restores visibility of the original ignored attachment")
	await release(value)

func test_blood() -> void:
	for eight_weights in [false, true]:
		var value: Dictionary = fixture("GoreComponent", eight_weights)
		await frames()
		value.component.initialize()
		var original_arrays: Array = value.source_mesh.surface_get_arrays(0)
		var original_colors: PackedColorArray = original_arrays[Mesh.ARRAY_COLOR]
		value.component.apply_blood_to_mesh(value.mesh, &"lower", .4, .2)
		expect(value.mesh.mesh.get_surface_count() == 1, "blood mesh clone retains its surface with %d influences" % (8 if eight_weights else 4))
		if value.mesh.mesh.get_surface_count() == 0:
			await release(value)
			continue
		var arrays: Array = value.mesh.mesh.surface_get_arrays(0)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		expect(colors.size() == 20, "blood paint retains complete vertex array")
		if colors.size() != 20:
			await release(value)
			continue
		expect(colors[8].b > original_colors[8].b, "native blood paint reaches cut region")
		expect(is_equal_approx(colors[8].r, original_colors[8].r) and is_equal_approx(colors[8].g, original_colors[8].g) and is_equal_approx(colors[8].a, original_colors[8].a), "blood paint preserves other color channels")
		expect(arrays[Mesh.ARRAY_BONES] == original_arrays[Mesh.ARRAY_BONES] and arrays[Mesh.ARRAY_WEIGHTS] == original_arrays[Mesh.ARRAY_WEIGHTS], "blood clone preserves all 4/8 skin influence slots")
		expect(value.mesh.mesh.get_blend_shape_count() == 1, "blood clone retains blend shape definition")
		expect(value.source_mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR] == original_colors, "blood painting preserves shared source mesh")
		await release(value)

func test_pool_lifetime() -> void:
	var pool: Node3D = ClassDB.instantiate("BloodPool")
	pool.start_delay = .05
	pool.max_lifetime = .05
	pool.interp_time = .01
	root.add_child(pool)
	pool.configure(Vector3.UP, Vector3.FORWARD)
	await create_timer(.025).timeout
	expect(is_instance_valid(pool) and pool.get_age() >= 0.0, "pool remains alive during its configured splatter delay")
	await create_timer(.2).timeout
	expect(not is_instance_valid(pool), "native blood pool frees itself after fade lifetime")

func finish() -> void:
	if failures.is_empty():
		print("GODOT_DISMEMBERMENT_TESTS_PASS checks=", checks)
		quit(0)
	else:
		print("GODOT_DISMEMBERMENT_TESTS_FAIL checks=", checks, " failures=", failures.size())
		for message in failures:
			print("  - ", message)
		quit(1)
