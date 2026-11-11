extends SceneTree
## The public simulator API starts every descendant of a requested ancestor.
## Removed source bodies must be unbound, rather than merely collision-disabled.
const Fixture = preload("res://tests/rig_fixture.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func frames() -> void:
	await physics_frame
	await physics_frame
	await process_frame

func run() -> void:
	var value: Dictionary = Fixture.make_rig()
	var simulator: Node3D = ClassDB.instantiate("PhysicalBoneSimulator3D")
	simulator.name = "AuthoredSimulator"
	value.skeleton.add_child(simulator)
	var bodies: Dictionary = {}
	for bone_name in [&"pelvis", &"upper", &"lower", &"hand", &"other"]:
		var body := PhysicalBone3D.new()
		body.name = "Physical_" + String(bone_name)
		body.set("bone_name", bone_name)
		body.gravity_scale = 0
		body.collision_layer = 2
		body.collision_mask = 0
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = .035
		capsule.height = .12
		shape.shape = capsule
		body.add_child(shape)
		simulator.add_child(body)
		bodies[bone_name] = body
	root.add_child(value.actor)
	await frames()
	check(value.component.initialize(), "component resolves an explicitly authored PhysicalBoneSimulator3D")
	simulator.call("physical_bones_start_simulation", [&"pelvis"])
	await frames()
	check(bodies.lower.is_simulating_physics() and bodies.hand.is_simulating_physics(), "ancestor start activates descendant bodies before the cut")
	bodies.upper.linear_velocity = Vector3(.5, 0, 0)
	var lower_index: int = bodies.lower.get_index()
	var hand_index: int = bodies.hand.get_index()
	value.component.dismember_limb(&"lower", Vector3.ZERO)
	await frames()
	check(not bodies.lower.is_simulating_physics() and not bodies.hand.is_simulating_physics(), "removed source bodies leave their original simulator")
	check(bodies.lower.get_bone_id() == -1 and bodies.hand.get_bone_id() == -1, "source cut bodies unbind from skeleton indices")
	check(bodies.lower.get_parent() != simulator and bodies.hand.get_parent() != simulator, "missing bodies are outside the source simulator traversal")
	check(bodies.lower.collision_layer == 0 and bodies.hand.collision_layer == 0, "quarantined source bodies cannot collide")
	check(bodies.upper.is_simulating_physics() and bodies.other.is_simulating_physics(), "retained source bodies keep simulating")
	check(absf(bodies.upper.linear_velocity.x - .5) < .02, "source simulator restart preserves retained body velocity")
	simulator.call("physical_bones_start_simulation", [&"pelvis"])
	await frames()
	check(not bodies.lower.is_simulating_physics() and not bodies.hand.is_simulating_physics(), "gameplay restarting a parent ragdoll cannot reactivate missing source bodies")
	check(PhysicsServer3D.body_get_mode(bodies.lower.get_rid()) == PhysicsServer3D.BODY_MODE_STATIC, "quarantined bodies stay physically inactive")
	value.component.reset_all_limbs()
	await frames()
	check(bodies.lower.get_parent() == simulator and bodies.hand.get_parent() == simulator, "reset restores original simulator parents")
	check(bodies.lower.get_index() == lower_index and bodies.hand.get_index() == hand_index, "reset restores authored child ordering")
	check(bodies.lower.get_bone_id() == 3 and bodies.hand.get_bone_id() == 4, "reset rebinds original skeleton bone indices")
	check(bodies.lower.collision_layer == 2 and bodies.hand.collision_layer == 2, "reset restores authored collision layers")
	check(bodies.lower.is_simulating_physics() and bodies.hand.is_simulating_physics(), "reset restores pre-cut source simulation state")
	value.actor.queue_free()
	await frames()
	print("SOURCE_PHYSICS_TESTS: ", checks, " checks, ", failures, " failures")
	quit(0 if failures == 0 else 1)
