extends SceneTree
## Real asset regression: a sibling cut after ragdoll, and R followed by another
## cut in the same frame. Assertions inspect rendered vertices and solver state.
const Rig = preload("res://demo/realistic_rig.gd")
const Physics = preload("res://demo/humanoid_physics.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("SEQUENTIAL SKIN: " + message)

func frames(count: int) -> void:
	for _frame in count:
		await physics_frame
		await RenderingServer.frame_post_draw

func descendant(skeleton: Skeleton3D, bone: int, root_index: int) -> bool:
	while bone >= 0:
		if bone == root_index: return true
		bone = skeleton.get_bone_parent(bone)
	return false

func mapped_bone(mesh: MeshInstance3D, skeleton: Skeleton3D, bind: int) -> int:
	var name := mesh.skin.get_bind_name(bind)
	return skeleton.find_bone(name) if name != &"" else mesh.skin.get_bind_bone(bind)

func rendered_pose(mesh: MeshInstance3D, skeleton: Skeleton3D, bone: int) -> Transform3D:
	var sr := mesh.get_skin_reference()
	for bind in mesh.skin.get_bind_count():
		if mapped_bone(mesh,skeleton,bind) == bone:
			return RenderingServer.skeleton_bone_get_transform(sr.get_skeleton(),bind) * mesh.skin.get_bind_pose(bind).affine_inverse()
	return skeleton.get_bone_global_pose(bone)

func max_edge(mesh: ArrayMesh) -> float:
	var result := 0.0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in range(0,indices.size(),3):
			var a := v[indices[i]]; var b := v[indices[i+1]]; var c := v[indices[i+2]]
			result=maxf(result,maxf(a.distance_to(b),maxf(b.distance_to(c),c.distance_to(a))))
	return result

func outside_radius(limb: Node, root_name: StringName) -> float:
	var skeleton: Skeleton3D = limb.get_ragdoll_skeleton()
	var mesh: MeshInstance3D = limb.get_meshes()[0]
	var root_index := skeleton.find_bone(root_name)
	var center: Vector3 = skeleton.global_transform * rendered_pose(mesh,skeleton,root_index).origin
	var baked := mesh.bake_mesh_from_current_skeleton_pose()
	var result := 0.0
	for surface in mesh.mesh.get_surface_count():
		var arrays := mesh.mesh.surface_get_arrays(surface)
		var original: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var vertices: PackedVector3Array = baked.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		var stride := bones.size()/original.size()
		for vertex in original.size():
			var selected := 0.0
			for slot in stride:
				var offset: int = vertex*stride+slot
				if descendant(skeleton,mapped_bone(mesh,skeleton,bones[offset]),root_index): selected+=weights[offset]
			if selected < .001: result=maxf(result,(mesh.global_transform*vertices[vertex]).distance_to(center))
	return result

func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Sequential skin requires a real renderer; a hidden OpenGL window is sufficient.")
		quit(2)
		return
	var camera := Camera3D.new()
	camera.position=Vector3(0,3,6)
	root.add_child(camera)
	camera.look_at(Vector3(0,1,0))
	var floor := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size=Vector3(30,.2,30)
	collider.shape=floor_shape
	floor.position.y=-.1
	floor.add_child(collider)
	root.add_child(floor)
	var value: Dictionary=Rig.build(0)
	value.actor.transform=Transform3D(Basis(Vector3.UP,.35),Vector3(-4.2,0,-7))
	root.add_child(value.actor)
	var authored: Dictionary=Physics.attach(value.skeleton,value.mesh)
	var component: Node3D=ClassDB.instantiate("DismembermentComponent")
	component.skeleton_path=NodePath("../Skeleton3D")
	component.mesh_path=NodePath("../Skeleton3D/SkinMesh")
	component.pelvis_bone_name=&"Hips"
	value.actor.add_child(component)
	await frames(3)
	check(component.initialize(),"real rig initializes away from the world origin")
	component.dismember_limb(&"Head",Vector3.ZERO)
	await frames(2)
	value.skeleton.physical_bones_start_simulation([&"Hips"])
	await frames(90)
	component.dismember_limb(&"LeftArm",Vector3(2,0,0))
	await frames(60)
	var arm: Node=component.get_dismembered_limb_by_name(&"LeftArm")
	check(is_instance_valid(arm),"an already-ragdolled source supports the second sibling cut")
	if is_instance_valid(arm):
		var radius := outside_radius(arm,&"LeftArm")
		var arm_mesh: MeshInstance3D=arm.get_meshes()[0]
		var edge := max_edge(arm_mesh.bake_mesh_from_current_skeleton_pose())
		print("SEQUENTIAL_ARM: outside_radius=",radius," max_edge=",edge)
		check(radius<.04,"previously removed head stays inside the compressed arm complement")
		check(edge<.2,"a second cut does not create long triangles to a prior sibling's old location")
	component.reset_all_limbs()
	# Deliberately do not wait for rendering or a physics frame here.
	var max_palette_error := 0.0
	for bone in value.skeleton.get_bone_count():
		max_palette_error=maxf(max_palette_error,rendered_pose(value.mesh,value.skeleton,bone).origin.distance_to(value.skeleton.get_bone_global_pose(bone).origin))
	check(max_palette_error<.001,"reset immediately publishes the clean source palette without waiting for a draw")
	var inconsistent_modes := 0
	for body: PhysicalBone3D in authored.bodies:
		if not body.is_simulating_physics() and PhysicsServer3D.body_get_mode(body.get_rid())==PhysicsServer3D.BODY_MODE_RIGID: inconsistent_modes+=1
	check(inconsistent_modes==0,"reset leaves no ghost rigid bodies with inactive simulation callbacks")
	var next_bone: int=value.skeleton.find_bone("RightUpLeg")
	var expected: Vector3=value.skeleton.global_transform*value.skeleton.get_bone_global_pose(next_bone).origin
	component.dismember_limb(&"RightUpLeg",Vector3.ZERO)
	var leg: Node=component.get_dismembered_limb_by_name(&"RightUpLeg")
	check(is_instance_valid(leg) and leg.get_bone_transform().origin.distance_to(expected)<.001,"R followed by an immediate cut captures the reset pose")
	await frames(2)
	value.skeleton.physical_bones_start_simulation([&"Hips"])
	await frames(120)
	var source_edge := max_edge(value.mesh.bake_mesh_from_current_skeleton_pose())
	print("SEQUENTIAL_RESET: palette_error=",max_palette_error," ghost_modes=",inconsistent_modes," source_max_edge=",source_edge)
	check(source_edge<.2,"the post-reset ragdoll retains coherent joints and unstretched skin")
	component.reset_all_limbs()
	value.actor.queue_free()
	await process_frame
	print("SEQUENTIAL_SKIN: checks=",checks," failures=",failures)
	quit(0 if failures==0 else 1)
