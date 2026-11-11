extends SceneTree
## End-to-end real mesh test: camera ray, left click, ragdoll, R key, repeat.
var checks := 0
var failures := 0

func expect(ok: bool, label: String) -> void:
    checks += 1
    if not ok:
        failures += 1
        push_error("FPS_RESET_FAIL: " + label)

func _initialize() -> void:
    call_deferred("run")

func wait_physics(count: int) -> void:
    for i in count: await physics_frame
    await process_frame
    await RenderingServer.frame_post_draw

func edge_maximum(mesh: Mesh) -> float:
    var maximum := 0.0
    for surface in mesh.get_surface_count():
        var arrays := mesh.surface_get_arrays(surface)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
        for i in range(0, indices.size(), 3):
            var a := vertices[indices[i]]
            var b := vertices[indices[i+1]]
            var c := vertices[indices[i+2]]
            maximum = maxf(maximum, maxf(a.distance_squared_to(b), maxf(b.distance_squared_to(c),c.distance_squared_to(a))))
    return sqrt(maximum)

func run() -> void:
    if DisplayServer.get_name() == "headless":
        push_error("FPS reset skin test requires the actual renderer; run without --headless.")
        quit(1)
        return
    var arena: Node3D = load("res://demo/demo.tscn").instantiate()
    root.add_child(arena)
    current_scene = arena
    arena.testing = true
    # Drive the input handler explicitly below without live desktop input.
    arena.set_process_unhandled_input(false)
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    await wait_physics(4)
    var target: Dictionary = arena.targets[0]
    var rest: PackedVector3Array = target.mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
    for bone: StringName in [&"Head", &"LeftLeg", &"Head", &"LeftArm"]:
        expect(arena._aim_at_bone(0,bone), "camera can aim at " + String(bone))
        await wait_physics(3)
        arena.shot_cooldown = 0.0
        var click := InputEventMouseButton.new()
        click.button_index = MOUSE_BUTTON_LEFT
        click.pressed = true
        arena._unhandled_input(click)
        expect(arena.last_shot.get("bone", &"") == bone and arena.last_shot.get("target", -1) == 0,
            "actual camera ray hits " + String(bone) + " on the intended station")
        await wait_physics(int(Engine.physics_ticks_per_second * 1.7))
        expect(target.component.get_all_dismembered_limbs().size() == 1, "one independent limb after " + String(bone))
        var source_baked: Mesh = target.mesh.bake_mesh_from_current_skeleton_pose()
        var source_edge := edge_maximum(source_baked)
        expect(source_edge < .2, "remaining source has no long triangles after " + String(bone))
        var detached_edge := 0.0
        for limb in target.component.get_all_dismembered_limbs():
            for mesh: MeshInstance3D in limb.get_meshes():
                detached_edge = maxf(detached_edge,edge_maximum(mesh.bake_mesh_from_current_skeleton_pose()))
        expect(detached_edge < .2, "detached geometry has no long triangles after " + String(bone))
        var reset := InputEventKey.new()
        reset.keycode = KEY_R
        reset.physical_keycode = KEY_R
        reset.pressed = true
        arena._unhandled_input(reset)
        await wait_physics(4)
        expect(target.component.get_all_dismembered_limbs().is_empty(), "R removes detached limbs")
        expect(target.missing.is_empty(), "R restores hit eligibility")
        var restored: PackedVector3Array = target.mesh.bake_mesh_from_current_skeleton_pose().surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
        var error := 0.0
        for v in mini(restored.size(),rest.size()): error = maxf(error,restored[v].distance_to(rest[v]))
        expect(restored.size() == rest.size() and error < .001, "R restores the rendered mesh before the next shot")
        print("FPS_RESET_EVIDENCE bone=",bone," source_edge_m=",source_edge," detached_edge_m=",detached_edge," reset_vertex_error_m=",error)
    # The same camera ray on a protected core hit must wound without severing.
    expect(arena._aim_at_bone(0,&"Hips"),"camera can aim at the core body")
    await wait_physics(3)
    arena.shot_cooldown = 0.0
    var core_hit: Dictionary = arena._shoot()
    expect(core_hit.get("bone",&"") == &"Hips", "body shot resolves the actual pelvis bone")
    expect(target.component.get_all_dismembered_limbs().is_empty(), "protected body shot does not detach the whole character")
    print("GODOT_DISMEMBERMENT_FPS_RESET_", "PASS" if failures == 0 else "FAIL", " checks=",checks," failures=",failures)
    quit(0 if failures == 0 else 1)
