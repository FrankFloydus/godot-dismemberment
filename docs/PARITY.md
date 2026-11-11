# EnGore → Godot behavior map

Target: EnGore 1.3.3 as locally installed for Unreal Engine 5.8, including its labeled IMPERIUM patches. See `SOURCE_AUDIT.md` for the exact reference hashes and asset inspection boundary.

This is an acceptance map for the requested complete port. A source feature being listed or having a similarly named Godot method does not establish parity. Build success establishes loadability; the listed runtime, rendering, and multiplayer checks establish their respective behavior. Any unverified item remains an open parity claim.


## Current native implementation

Windows debug and release verification is recorded in `VALIDATION.md`, including native behavior, geometry, actual rendering, physics and real-ENet tests. `BONE_COLLAPSE` is the default: per-mesh RenderingServer skin-palette overrides collapse removed source regions around a pivot derived from the currently rendered parent. Local animation and IK poses are preserved. The detached full skin captures the evaluated current pose while compressing the complement to the source rig's 1% scale. `TRIANGLE_PARTITION` is an explicit alternative with independent geometry checks. Authored PhysicalBone3D limb chains preserve selected bodies and joints, matching the source's reliance on an authored Physics Asset. Bone Collapse partitions geometry only when it needs to construct fallback
collision. The additional posed convex rigid-body fallback is opt-in through `limb_rigid_fallback_enabled`, which defaults to false; missing authored physics does not silently select it. Impulses preserve the source velocity-change semantics by compensating for body mass.

Reliable authority RPCs, explicit owning-peer requests, ordered snapshots, late joins, duplicate suppression and reset were exercised in two separate ENet processes. This replaces the earlier source's unreliable-event/delayed-reconciliation transport with the same tested state outcomes. Cross-engine renderer, solver and artwork equivalence remains distinct from those passed checks.

## Runtime dismemberment

| Reference behavior | Godot counterpart / acceptance requirement |
| --- | --- |
| Actor component with Blueprint-callable methods | Native GDExtension `DismembermentComponent` with Inspector properties and GDScript-callable methods. |
| Auto source selection | Explicit source path; tagged/grouped `Dismemberment Source` candidate; deterministic skeleton/skinned mesh fallback. Verify multiple body/eyes meshes select the intended body. |
| Override source mesh name | A source mesh/skeleton NodePath replaces Unreal component-name lookup. Confirm invalid paths report configuration errors. |
| Pelvis defaults to `Pelvis`; verification before use | Validate a real Skeleton3D and configured pelvis. A Godot rig can use a different bone name explicitly. |
| Disable, excluded list, whitelist, remapped bone names | Remap first, then apply exclusion and nonempty whitelist. Filtered, unknown, virtual, and already missing bones must produce no extra limb. |
| `DismemberLimb(bone, impulse)` | Capture current pose, remove subtree from source, create detached representation, then apply physics and emit post event. |
| Pre event `(bone, impulse)` | Emit before modifying source appearance. |
| Post event `(bone, detached_mesh)` | Emit after the detached limb is initialized, preserving correct world transform and source pose. |
| One-frame deferred pose setup | Equivalent deferred initialization without a visible bind-pose flash or one-frame spatial jump. |
| Missing map includes cut bone and descendants | Cutting the same bone or an already removed descendant is idempotent. |
| Child cut followed by parent cut | The new parent limb excludes the already detached child; the first detached child stays intact. |
| `DestroyLimb` hides without spawning | Remove requested subtree without detached physics or a duplicate visible limb. |
| Reset all limbs | Restore source meshes, transforms/masks/collision state; clear missing state and remove detached objects so a new cut succeeds. |
| Cleanup one/all detached limbs | Free detached objects without implicitly restoring source geometry. |
| Get detached limb by name / all limbs | Descendant names resolve to their owning detached object; array results must not contain stale freed objects. |
| Morph targets named for copying | Copy configured Godot blend shape values into detached geometry/mesh. Verify nonzero blend shapes at cut time. |
| Copy materials and existing vertex colors | Preserve surface assignments and paint channels independently per instance. |
| Update bounds option | Recompute reduced source bounds when requested; detached bounds enclose detached geometry. |
| No physics asset patch | Skeletons without authored collision must remain safe and render their detached geometry. |
| Current scaled pose physics anchor patch | Test animated scale and intermediary bones; collision and render geometry should agree without applying scale twice. |

Reset additionally restores all authored source physical bodies to a coherent pose before rebuilding their joint frames, retaining joint types, offsets and constraint properties. Actual-render tests reproduce the FPS R-key ordering, reuse the same bodies across resets, and cut additional limbs while the remaining body is already ragdolled. This covers failures that first-cut or rest-pose checks alone did not detect.

## Attached meshes and items

| Reference behavior | Godot counterpart / acceptance requirement |
| --- | --- |
| Support attached child meshes defaults false | Optional traversal of associated skinned child meshes and bone attachments. |
| `Dismembered Limb` tag | Godot group marks generated limbs and prevents them from being recaptured as character meshes. |
| `No Dismemberment` tag | Group/metadata suppresses an attached mesh's detached copy. With attached-mesh support enabled, its source still follows the source cut. |
| `Transfer Dismemberment` tag | Matching attached items move to detached limb while preserving local transform. Applies to static items such as weapons/hats too. |
| `OverrideSocket:<bone>` | Godot metadata or BoneAttachment3D bone assignment provides explicit filter bone; actual attachment transform remains preserved. |
| Child skeletal meshes use leader pose | Detached clothing/armor mesh uses the same captured pose and subtree as the detached body. A skinned mesh under a bone attachment is copied only if its effective filter socket is in that subtree. |
| Unattached modular mesh | An associated skinned mesh with no single attachment bone must still be clipped by the chosen subtree when enabled. |

## LimbMap and vertex data

`LimbMap` is marked as a legacy/deprecating helper in the reference, but its working query behavior remains part of the audit.

| Query / behavior | Reference semantics |
| --- | --- |
| Initialize limb map | Build a root-plus-descendants set per nonvirtual bone, map names to render skeleton indices, cache reference transform and vertex count. |
| Exclude keyword list | Remove matching descendant names such as IK/twist bones; a selected root itself remains part of its limb. |
| Direct child | Returns one first child, rather than every direct child. |
| Bone path to root | Includes the queried bone and walks to skeleton root. |
| Bone reference transform | Composed rest transform in skeleton/component space. |
| `get_all_immediate_bones` | Historical name means the complement of the queried subtree, not just immediate children. |
| Weights of one bone | Per-vertex normalized influence for the named bone. |
| Weights of a limb | Maximum single influence belonging to its subtree, rather than the sum of all subtree influences. |
| Bone / limb mask | One if any relevant influence is at least threshold; default threshold 0.25. |
| Immediate/complement mask | Mask of non-subtree influences, optionally including the cut bone; threshold defaults to 0.25. |
| Override limb weights | Reassign vertices meeting the complement mask threshold to the cut bone, preserve other influences. |
| Multiple render sections | Godot surfaces carry their own bone/weight arrays; verify different surface materials and bone mappings. |
| Legacy color-for-bone helper | Reference currently returns an empty array. |
| Legacy color-for-limb helper | Reference currently returns a zero-filled array because vertex reading in this path is disabled. |

The Godot geometry path retains normals, tangents, UVs, colors, materials, indices, skin influences, and configured blend shapes. The focused `tests/test_mesh_partition.gd` suite covers 4/8 influences, reordered named/indexed skin binds, translated/rotated character frame, translated mesh frame, current bone translation/nonuniform scale, normalized/relative blend mixes, compact attributes, material override, colors/UVs/normals, LOD remapping, and source immutability.

Continuous weighted geometry is also exercised on the actual CC0 humanoid: `tests/test_real_skin_geometry.gd` passes 29 actual-render checks for normalized bind mapping, mixed Head/neck and arm weights, moving source collapse, and independently moving detached skin/physics. `tests/test_ragdoll_comparison.gd` passes 13 rendered cases comparing the original walk/run clips, component-free full ragdoll, enabled uncut component, repeated R reset, and sequential cuts on an already-ragdolled body. These require a real renderer rather than the headless dummy renderer. See `REAL_MODEL_GEOMETRY_AUDIT.md` for the exact measurements and scope. Triangle partitioning and the reference Control Rig's 1%-pelvis collapse remain different techniques; boundary shape and skin blending on arbitrary topology still need direct comparison before claiming equivalence.

`MeshPartition.isolate_limb` returns vertices in the source mesh's local frame. Detached instances must retain the source mesh global transform, or use the equivalent local transform under their cut-bone body. Its remaining output preserves skin and live blend shapes; baked detached output captures the current blend/pose and removes skin channels. LOD indices are partitioned/remapped through guarded ArrayMesh `_surfaces` storage access because Godot 4.3's public RenderingServer dictionary has malformed LOD entries. Surface arrays are compacted over vertices referenced by the base and retained LODs. Nontriangle surfaces are reported through `unsupported_surface_count`; this utility does not generate cut caps.

## Gore and blood

Unreal uses centimeters. Godot defaults use meters. Distances below therefore include the corresponding conversion; normalized quantities and seconds retain their numeric values.

| Reference setting / method | Reference behavior and expected Godot mapping |
| --- | --- |
| Enable decals / particles / skin paint | All default true; control automatic cut hooks. Direct effect method calls in the source bypass these hook flags. |
| `ApplyBlood(bone,radius,hardness)` | Default radius 75 cm → 0.75 m, hardness 0.2; paint associated meshes unless marked `Ignore Blood`. |
| `ApplyBloodToMesh` | Paint skinned mesh vertices around reference bone position, preserving unrelated color channels. |
| Main / limb cut radius | 120 cm → 1.2 m and 75 cm → 0.75 m. |
| Sphere paint mask | Clamp `(1 - distance / radius) / max(1 - hardness, 0.00001)` to [0,1], max-blend selected channel. |
| Vertex channel | Blue by default; selectable R/G/B/A. Existing paint accumulates by max. |
| All LODs | The reference writes all available LOD color buffers. Godot imported LOD behavior must be checked separately. |
| `SpawnBoolDecal` | Reference public method has this spelling; creates a surface-oriented blood pool with optional attachment and splatter direction. |
| `SpawnBloodParticles` | Spawns configured particle effect at position/orientation; particle scale defaults 1. |
| `SpawnBloodFX` | Burst plus surface trace in supplied direction with downward Z override -0.7, trace length 2000 cm → 20 m. Godot uses Y-up. |
| Static mesh paint/remove | Independent per-instance colors/mesh data; remove must restore original appearance. |
| Pool scale / lifetime | Scale 1, lifetime 60 seconds. |
| Override material / texture / particles | Optional Godot resource replacements. No Unreal `.uasset` is runtime-loadable by Godot. |
| Blood material tile size | 750 cm → 7.5 m, world-space tiling defaults true. |
| Blood paint scale | Default 1; declared in source but not used in inspected implementation. |
| Paint animation | Custom primitive slot 0 animates 0→1 over 1 second on the main body only. Painted clothing and detached meshes start fully painted. Godot keeps the corresponding uniform independent on each mesh, including opt-in custom shaders. |

`BloodPool` has start delay 0, lifetime 60 seconds, decal size 100 cm per axis, rotation offset, interpolation time 0.3 seconds, material override, and an overlap box. The Godot decal and Compatibility plane keep the authored projection size fixed. They fade in over 0.3 seconds, vary yaw by ±10 degrees and start fade-out after lifetime/5 with a lifetime-length fade. They take the minimum of the two fade values when the intervals overlap. A zero lifetime keeps the decal visible after its fade-in. Unreal destroys the decal component at the end of a finite fade and retains the overlap actor. Godot frees the finite pool node. Projection and material differences remain open.

## Replication and state

| Reference behavior | Acceptance requirement |
| --- | --- |
| Local cut then unreliable server request/multicast | Godot transport can use different APIs, but authority, remote observation, and duplicate suppression must be demonstrated with two peers. |
| Replicated cut-bone list | Serializable state must let a late joiner recreate cuts already applied. |
| One-second delayed replicated reconciliation | Apply only unseen cuts after event/state races; do not create duplicate limbs. |
| Dedicated server skips render vertex data | Server-side state handling must not require a visible renderer or mesh readback. |
| Reset and replication | Reset must also clear the serialized cut state. The reference fails to clear its replicated list in reset; reproducing that bug is not an acceptance goal. |

A state export/import helper alone would demonstrate serialization. The packaged implementation has additionally passed the two-process ENet checks in `VALIDATION.md`; additional production network topologies and adverse network conditions have not been exercised.

## Editor, content, and engine replacements

| Reference feature | Godot replacement / inspection boundary |
| --- | --- |
| Blueprint-callable nodes | Registered GDExtension methods, properties, signals and GDScript integration. |
| Animation Blueprint / Control Rig | Text exports establish attached-parent pose copy, pelvis global transform at 1% scale, limb global scale 1 and identity rotation, all propagating to descendants. Native Godot pose/geometry processing replaces RigVM; rendered boundary comparison remains required. |
| Physics assets and constraints | Authored Godot PhysicalBone3D chains, collision shapes and joints replace the Physics Asset. Articulated multi-body detachment, remaining-body ragdoll and repeated-reset constraint integrity are tested separately from the opt-in single rigid-body fallback. The supplied FPS uses GodotPhysics3D at 240 Hz; this does not certify another solver or timestep. |
| Niagara burst and emitter graphs | Original Godot particle scene/effect; verify lifetime, orientation and scale, then compare visuals separately. |
| Blood materials/functions/textures | Godot shader/material resources mapped from exported source graphs; blood masks and cloud noise are independently authored procedural assets. See `GORE_MAPPING.md`. Cross-renderer pixel matching remains unverified. |
| Create Dismemberment Rig asset action | Source text export shows selected-asset enumeration, template duplication and target-skeleton assignment. Godot editor setup/validation replaces those Unreal-specific assets and APIs. |
| Editor module | The reference C++ only ensures its content directory is always cooked. Godot resource references/export inclusion replace this behavior. |
| Demo level, pawn, UI, test Blueprints | The source pawn export shows click-hit dismemberment, reset, cleanup and cursor/UI setup. The editable Godot range exposes those operations. Its pellet spread, surface effects, sound, weapon sway, and firing shake are demo-specific. |
| UE mannequin, skeleton, textures and physics | The FPS uses the downloaded [Grab3D Man Base Mesh](https://grab3d.com/models/characters/man-base-character/) under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/), with normalized Godot binds and authored physical bodies. It does not redistribute the Unreal mannequin. Three stations demonstrate humanoid cuts, articulated limbs, and attachment/hit remapping on this realistic model. Source asset comparisons remain separate from these examples. |

## Reported real-model failures and corrections

The first floating-head/skin-bridge defect came from reading restored Skeleton3D animation poses while the rendered physical body had already moved. Source collapse now uses the evaluated renderer palette, and detached pose capture permits its selected physical bodies to drive the visible skin. Mixed-influence Head/neck vertices therefore follow the current source cut pivot rather than a stale rest position. Unreal's installed SkeletalRender.cpp sets a hidden non-root bone's matrix to the parent origin at zero scale. The current Godot palette uses the cut-bone origin evaluated from the visible parent, so exact weighted-boundary equivalence remains open.

The later R-triggered stretching was a separate plugin reset defect. In the rendered comparison, a restored Head joint separated from its neck by approximately 1.55 m after repeated resets; coherent body restoration and joint-frame rebuild reduced that head/neck anchor error to 0.000123 m. The independent physics-integrity test measured a different quantity: maximum constraint-anchor gap across five cycles, improving from 3.945 m to 0.048697 m. These measurements must not be conflated. The demo's 240 Hz GodotPhysics3D configuration was checked in three repeated 46-check physics runs.

The original downloaded walk/run clips and the component-free ragdoll controls remain proportionate. The evidence identifies plugin pose/reset defects and establishes that this imported mesh is usable in the corrected demo; it does not establish identical behavior for every rig or physics solver.

## Release evidence

The build/package process records concrete validation results separately. Required evidence for a full parity claim includes:

1. Native debug/release library compilation and Godot extension load.
2. Runtime smoke tests for cut/remap/filter/idempotence/parent-after-child/reset and state round-trip.
3. Pose and geometry checks on continuous weighted meshes, multiple surfaces, named morphs, attached modular meshes, scaled animation and missing physics.
4. Rendered demo review for source and detached geometry, paint, particles, pool lifetime and UI interactions.
5. Actual two-peer tests, including late join, event/state race, and reset.
6. Side-by-side Unreal/Godot comparison of the exported Control Rig, material, asset-action, Niagara and showcase behavior before claiming exact visual or workflow equivalence.

Passing a subset does not establish 100% parity. The package can be useful and runnable while remaining explicit about these remaining comparisons.
