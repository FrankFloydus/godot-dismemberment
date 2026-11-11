# Using godot-dismemberment

This is a skeletal-mesh dismemberment component. A cut selects a bone and all
its descendants. The game decides which damage events should sever a limb,
kill a character, or only paint blood.

## Character setup

1. Import a properly skinned humanoid or creature. It needs a `Skeleton3D`, a
   `MeshInstance3D` with bone/weight arrays, and a `Skin` bound to that skeleton.
2. Add authored `PhysicalBone3D` bodies, fitted collision shapes, masses, and
   constrained joints. Author the character in metre-sized coordinates; avoid
   inherited nonuniform or centimetre import scale on physical bodies. The
   downloaded demo rig is normalized before its bodies are authored.
3. Add `GoreComponent` under the character root beside the skeleton. Use
   `DismembermentComponent` when blood effects are unnecessary. The editor setup
   dock can create and link the component.
4. Assign `skeleton_path`, `mesh_path`, and the exact `pelvis_bone_name`. Godot
   bone names are case-sensitive. The downloaded CC0 humanoid uses `Hips`.
5. Configure allowed cut roots. Protect the pelvis/root and torso when a body
   hit should wound the character without removing most of its skeleton.
6. Call `initialize()` after the nodes and physics bodies exist. Check
   `get_last_error()` if it returns false.

```gdscript
@onready var gore: GoreComponent = $GoreComponent

func _ready() -> void:
    gore.skeleton_path = NodePath("../Skeleton3D")
    gore.mesh_path = NodePath("../Skeleton3D/SkinMesh")
    gore.pelvis_bone_name = &"Hips"
    gore.excluded_bones = PackedStringArray(["Hips", "Spine02", "Spine01", "Spine"])
    gore.whitelist_bones = PackedStringArray([
        "Head", "LeftArm", "LeftForeArm", "LeftHand",
        "RightArm", "RightForeArm", "RightHand",
        "LeftUpLeg", "LeftLeg", "LeftFoot",
        "RightUpLeg", "RightLeg", "RightFoot"
    ])
    if not gore.initialize():
        push_error(gore.get_last_error())
```

Replace these paths and names for another character. The source Unreal plugin
does not automatically protect a pelvis merely because it is configured. The
editor helper and FPS example add protection deliberately.

`limb_rigid_fallback_enabled` defaults to false. It explicitly enables an extra
single convex rigid-body fallback for meshes without authored limb physics.
The EnGore source uses an existing Physics Asset; the realistic demo therefore
uses authored physical-bone chains instead of that convenience fallback.

## Component Inspector

**Source Rig**, **Cut Rules**, **Cut Geometry**, **Detached Limbs**, and
**Multiplayer** group the native dismemberment settings. Assigning an explicit
mesh path hides the name-based override. The geometry mode controls which
geometry settings appear. Enable **Rigid Fallback** to see the fallback mass,
or enable networking to configure the owning peer.

**GoreComponent** adds **Blood Pools**, **Blood Particles**, and **Blood Paint**.
Enable an effect to configure it. Resource pickers appear after you enable
their override. Assigning a custom pool material hides the built-in texture
and tile-size controls. Hidden settings retain their values and remain
available to scripts.

## Shooting and effects

Give each target collider a bone-name mapping, or obtain the bone from a
`PhysicalBone3D` hit. A raycast against only a visual mesh does not identify a
skeletal bone by itself. The FPS example maps its actual target hitboxes and
physical bodies to exact bone names.

```gdscript
func apply_shot(hit: Dictionary, shot_direction: Vector3) -> void:
    var collider: Object = hit["collider"]
    var bone: StringName = collider.get_meta("bone", &"")
    if bone == &"":
        return
    if gore.check_bone_filter(bone):
        gore.dismember_limb(bone, shot_direction.normalized() * 0.7)
    else:
        gore.spawn_blood_fx(hit["position"], shot_direction, bone)
```

The vector passed to `dismember_limb` is a world-space velocity change in
metres per second, matching the source's mass-independent impulse semantics
after unit conversion. Large values throw limbs forcefully. Imported Unreal
centimetre-based sample vectors must be divided by 100 at the game boundary.

The default geometry mode retains weighted skin and closes the cut through
bone collapse. The detached mesh captures the evaluated current pose. Its
selected authored physics bodies simulate independently; excluded source
bodies must remain removed when the remaining character starts ragdolling.

The source blood defaults are broad: body paint radius 1.2 m and limb radius
0.75 m. The FPS example explicitly uses smaller wound radii. Standard Godot
PBR materials can be converted automatically while retaining their supported
maps. Custom shaders must read the selected vertex color channel (blue by
default) and the blood animation uniform themselves.

## Experimental slicing API

On `experiment/plane-slicing`, `MeshPlaneSlice.slice_pose(mesh_instance,
skeleton, local_plane, cap_material)` cuts the current pose of a skinned
mesh. `MeshPlaneSlice.slice_mesh_pieces(array_mesh, local_plane, cap_material)`
cuts an already rigid fragment. On success, both return `positive_pieces`,
`negative_pieces`, and `loop_count`. Each piece is a closed `ArrayMesh` in
the input mesh's local coordinates. On refusal, the dictionary contains
`error` and the source is untouched.

For an animated sword, use the weapon sweep to find the contacted mesh and
choose a plane through three points on the swept blade. Convert the point
on that plane to mesh space with `mesh_instance.to_local(point)`. Convert
its world normal with `(mesh_instance.global_basis.transposed() * normal).normalized()`.
Build a local `Plane` from the resulting normal and point. The demo calls
the same geometry API from its camera swipe, builds convex rigid bodies from
the pieces, and publishes the swap after all colliders succeed.

`MeshPlaneSlice.sever_connected_piece(array_mesh, local_plane, limb_seed,
cap_material)` uses a mesh-local point on the limb side of the plane to
detach one connected region. It returns `detached_mesh` and `retained_mesh`.
Only the chosen region receives a new cut boundary. The demo keeps its
authored bone hit regions in the same local frame so the shotgun can find
the joint on a piece that has already moved or rotated.

`MeshPlaneSlice.reduce_collision_hull(points)` samples body-local convex
hull points in 98 directions, keeping the exact extents along the body
axes. The demo enables it by default for fragment simulation. The display
and subsequent cuts use the complete sliced mesh.

Use closed, consistently wound triangle meshes. Valid closed contours can
include holes. Cuts that overlap a face or form touching or crossing
contours can be refused. Returned pieces are
pose-baked, so games decide their physics, lifetime, animation, and
replication. Time the operation on your own assets before using it for
frequent combat.

## Gameplay and reset

`pre_dismemberment(bone, velocity_change)` runs before the cut.
`post_dismemberment(bone, limb)` runs after the detached limb is initialized.
Use these signals for damage, sound, death, or remaining-character ragdoll
logic. The FPS example ragdolls its remaining character after a head or major
leg cut. That death/balance rule belongs to the example game.

- `reset_all_limbs()` restores source geometry, cut state and attachments,
  and removes the referenced detached limb objects.
- `clean_up_all_referenced_limbs()` removes detached objects while leaving
  the character's missing limbs missing.
- `destroy_limb(bone)` hides the subtree without creating a detached limb.
- `get_dismembered_limb_by_name(bone)` resolves descendants to their detached
  limb; `get_all_dismembered_limbs()` lists live detached objects.

The component restores its cut state and physics ownership. Your game restores
its own alive/dead state, animation controller, hit eligibility, and desired
standing pose. For the demo's direct Skeleton3D physics owner, R performs:

```gdscript
gore.reset_all_limbs()
skeleton.physical_bones_stop_simulation()
skeleton.clear_bones_global_pose_override()
skeleton.reset_bone_poses()
# Then clear the game's ragdoll/missing flags and rebuild its hitboxes.
```

With an explicit PhysicalBoneSimulator3D, stop that owning simulator through its
API. Do not reset a ragdoll by changing only node transforms or raw PhysicsServer
body modes; the joints and simulation callbacks must agree with the new pose.

Enable `support_attached_child_meshes` for modular clothing sharing the same
skeleton. `No Dismemberment` suppresses an attached mesh's detached copy while
its source follows the cut. `Transfer Dismemberment` moves an attached prop to
the detached limb. Mark the main source mesh `Dismemberment Source` when a
character has several candidate meshes.

For network play, enable `network_enabled` and configure authority consistently.
Only the explicit `owning_peer_id` may request a client-originated cut. Server
combat logic can call the component directly for NPC damage. Retained state
supports late join and duplicate suppression.

## FPS demo

Open `res://demo/demo.tscn` and select **FirstPersonDismembermentRange** in the
Scene dock. **Shooting → Dismemberment Impulse** sets the forward velocity
change in m/s. **Dismemberment Upward Boost** adds upward velocity. Set
movement and mouse settings in **Player Movement**. The **Stations** branch
holds the spawn and aim markers and each editable target's **GoreComponent**,
hitboxes, and physical bones.

WASD moves, mouse looks, Shift sprints, Space jumps, and left-click fires the
crosshair ray. R resets the selected target; 1/2/3 changes station. F applies
blood-only shots, X hides the hit limb, C clears detached objects, and Esc
releases or captures the mouse. Restart an open editor after rebuilding its
native DLL, then run the main scene with F5.
