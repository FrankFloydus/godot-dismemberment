extends SceneTree
const Factory = preload("res://demo/realistic_rig.gd")
const Physics = preload("res://demo/humanoid_physics.gd")

func _initialize() -> void:
    call_deferred("run")

func own_children(node: Node, owner_node: Node) -> void:
    for child in node.get_children():
        child.owner = owner_node
        own_children(child,owner_node)

func run() -> void:
    var names := ["humanoid_rig","articulated_rig","modular_rig"]
    DirAccess.make_dir_recursive_absolute("res://demo/rigs")
    for kind in 3:
        var rig: Dictionary = Factory.build(kind)
        if kind == 0:
            var mesh_error := ResourceSaver.save(rig.mesh.mesh,"res://demo/assets/humanoid/body_mesh.res",ResourceSaver.FLAG_CHANGE_PATH)
            if mesh_error != OK:
                push_error("Cannot save shared CC0 mesh: " + str(mesh_error))
                quit(1)
                return
        var shared_mesh: ArrayMesh = ResourceLoader.load("res://demo/assets/humanoid/body_mesh.res","ArrayMesh",ResourceLoader.CACHE_MODE_IGNORE)
        shared_mesh.take_over_path("res://demo/assets/humanoid/body_mesh.res")
        rig.mesh.mesh = shared_mesh
        root.add_child(rig.actor)
        var physics: Dictionary = Physics.attach(rig.skeleton,rig.mesh,75.0)
        for body: PhysicalBone3D in physics.bodies:
            body.add_to_group(Physics.BODY_GROUP,true)
        var component: Node = ClassDB.instantiate("GoreComponent")
        component.name = "GoreComponent"
        component.set("skeleton_path",NodePath("../Skeleton3D"))
        component.set("mesh_path",NodePath("../Skeleton3D/SkinMesh"))
        component.set("pelvis_bone_name",&"Hips")
        component.set("excluded_bones",PackedStringArray(["Hips","Spine02","Spine01","Spine"]))
        component.set("whitelist_bones",PackedStringArray(["Head","LeftArm","LeftForeArm","LeftHand","RightArm","RightForeArm","RightHand","LeftUpLeg","LeftLeg","LeftFoot","RightUpLeg","RightLeg","RightFoot"]))
        component.set("blood_paint_radius",.3)
        component.set("blood_paint_limb_radius",.18)
        component.set("blood_pool_scale",.35)
        component.set("limb_collision_layer",8)
        component.set("limb_collision_mask",9)
        component.set("support_attached_child_meshes",kind==2)
        rig.actor.add_child(component)
        own_children(rig.actor,rig.actor)
        var scene := PackedScene.new()
        var error := scene.pack(rig.actor)
        if error == OK: error = ResourceSaver.save(scene,"res://demo/rigs/"+names[kind]+".tscn")
        if error != OK:
            push_error("Failed to save real demo rig: "+str(error))
            quit(1)
            return
        print("SAVED_CC0_RIG ",names[kind])
        rig.actor.queue_free()
    quit(0)
