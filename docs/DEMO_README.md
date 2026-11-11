# godot-dismemberment demo project

Import the **project.godot file beside this README** into Godot 4.7 for the
verified local environment, then press F5. Windows x86_64 debug and release
native libraries are included. The extension targets the Godot 4.3 API.

The main scene is a first-person sci-fi range with three humanoid stations
named **CC0 Humanoid**, **Articulated Limbs**, and **Modular / Attachments**.
The desktop project uses Forward+ with SDFGI, volumetric fog, glow, and AgX
tone mapping. The range and its lighting are editable in `demo/fps_range.tscn`.
All three use the downloaded rigged
[Grab3D Man Base Mesh](https://grab3d.com/models/characters/man-base-character/),
published under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/),
with its clothed skinned mesh and PBR textures. Left-click to fire the shotgun.
The default blast casts eight rays, with one through the center of the crosshair.
Each ray can mark the environment and each target receives up to one hit per
blast. Impacts on detached limbs emit blood at the contact point. Missing limbs
lose their original hitboxes, and the remaining body ragdolls after a head or
major-leg cut.

Metal surfaces give a short contact glint and amber sparks. Floor impacts
favor dust. The effects start at the pellet contacts and fade while the marks
stay on the surface.

The shotgun viewmodel is editable in `demo/fps_player.tscn`. Its base mesh is
the CC0 [Bullpup Shotgun, Fitted by 3DAssets.dev](https://3dassets.dev/assets/mega-weapon-pack-bullpup-shotgun-loadout-0f97efcb).
The muzzle follows the model's barrel socket. The **Flash** node holds editable
one-shot 3D particle emitters for the hot core, flame, and sparks. Each pellet's
short tracer starts at the barrel and ends at its own ray impact or maximum
range.

Each normalized rig has 17 authored physical bodies, fitted collision shapes,
constrained joints and 75 kg total mass. The project uses **GodotPhysics3D at
240 physics ticks per second and 32 solver iterations**. The fitted hand
colliders use lower friction to reduce sticking during floor contact. The
third station adds a transferable hand accessory and a remapped hit proxy.
The demo's filters protect the pelvis and torso, so a central-body shot can
wound without severing.

- **WASD:** move; **mouse:** look; **Shift:** sprint; **Space:** jump.
- **Left mouse:** fire the shotgun.
- **R:** reset the current target; **1 / 2 / 3:** move to a target station.
- **F:** blood-only shot; **X:** hide-only shot; **C:** clean up detached limbs.
- **Esc:** release/capture the mouse.

## 30-target Mass Range

Open `demo/mass_range.tscn` and press **F6** to run the authored 30-humanoid
scene. It starts at an overview of the range. The targets are saved scene
instances, so their placement can be edited in Godot. They use a closed,
19,990-triangle version of the same skinned character for crowd gameplay.
The standard FPS range uses the original 262,348-triangle body.

- **RMB** runs Mass Murder. It picks one to four eligible skeletal roots
  per target across different limb chains. The prepared limbs and remaining
  ragdolls appear and launch together. The range physics and player movement
  keep running during preparation. Targets already cut into rigid pieces
  receive an impulse on those pieces. The batch uses the native blood effects
  without rebuilding the skinned mesh for vertex painting on every sever.
- **F** prepares a mass slice with randomized planes. Some targets receive
  a second cut. The completed cuts are published together after preparation.
- **R** cancels any pending mass action and restores all 30 targets.
- **B** fires the blood-only shot. **LMB**, **MMB**, **V**, and **Q / E** keep
  their usual controls in this scene.

Run the mass range integration test with the Godot 4.7 console executable
in `$Godot`. Append `-- --mixed --transition --cancel` to verify both
action orders and reset during preparation. Use `-- --unique-meshes
--dismember-only` or `-- --unique-meshes --slice-only` for a fresh action
with independently allocated body geometry. `--targets=20` limits the
runtime test fixture to 20 of the 30 authored stations. `--full-detail`
runs the same fixture with the original body mesh.

```powershell
& $Godot --audio-driver Dummy --disable-vsync --resolution 1600x900 --path project --script res://tests/test_mass_range.gd
```

## Slice surfaces

On the experimental slicing branch, aim at the subject, hold **middle mouse**,
drag in the direction of the slash, and release. The line starts at the
crosshair. The first subject or fragment hit by the swipe within reach is cut
along its plane. Try a horizontal swipe through the middle of the torso or
a diagonal swipe across the upper body. Each closed piece can fall and be cut
again. **R** restores the subject. The original **V** forearm cut and
**Q / E** tilt are also available. Select **Slash Gesture** on the range root
to edit the reach. The demo humanoid has authored torso and forearm volumes
in `demo/rigs/humanoid_slice_interior.tscn`. The slicer cuts them with the
outer mesh and exposes their cross-sections as each fragment moves.
The exposed volumes and their surrounding cap share the same continuous
SkinGore texture projection. A textured stain extends from the seam onto
the skin and clothing. Edit the interior scene to adjust the volumes,
or use the cap material override to change their surface finish.

Leave **Slice Cap Material** empty to use the bundled materials, or assign
a Godot material to override the exposed outer and inner cut surfaces.
**Simplify Fragment Colliders** builds convex shapes from a bounded set of
support points. The interior geometry is visual and adds no colliders.
Regular shotgun shots can sever a limb from a sliced body or fragment using
the saved bone hit regions. A hit on a protected region gives the usual
impact feedback. A swipe can also cut the remaining body after a shotgun sever.

To reproduce the rendered 20-character stress test, run this from the
repository root with the Godot 4.7 console executable in `$Godot`.

```powershell
& $Godot --audio-driver Dummy --disable-vsync --resolution 1600x900 --path project --script res://tests/test_twenty_humanoid_stress.gd -- --verify-interiors
```

The test applies a torso slash, a shotgun limb sever, and a radial blast to
each subject in one process frame. It reports burst CPU time and subsequent
frame times separately, then checks that reset removes the fragments.

Add `--staged` after `--verify-interiors` to exercise the batch path.
It captures each standing pose on the main thread, computes the geometry
on workers, and builds render resources and bodies across frames. The
prepared slashes appear together. The test then stages the shotgun
severs and releases all the blast impulses in one physics step.
The original benchmark measures the fully synchronous path.

Open `demo/demo.tscn` in the Godot editor to edit the range before play. Select
**FirstPersonDismembermentRange** and open **Shooting** for pellet count, spread,
forward and upward dismemberment impulse, detached-limb impulse, shot timing,
and range.
**Player Movement** contains the movement and mouse settings. Under
**Stations**, each **Target** contains its editable **GoreComponent**, skinned
mesh, hitboxes, and physical bones. Move a station's **PlayerSpawn** and
**InitialAim** markers to change where the player starts and looks.

**Weapon Motion** controls the mouse sway, movement sway, and firing shake.
The **RangeAudio** scene contains the editable shotgun, footsteps, and room-tone
players, along with separate positional recordings for flesh hits and cuts.
Footsteps follow the distance walked on the ground. The **Range Shotgun** bus
adds short indoor reflections and can be adjusted in the editor's Audio panel.
The **Range Body** bus controls the flesh and sever cues. It briefly reduces
the shotgun layer when a body cue plays.
Optional WAVs in `user://range_audio` replace the corresponding bundled takes.
The supported stems are `shotgun_01` through `shotgun_04`, `step_01` through
`step_04`, `flesh_hit_01` through `flesh_hit_03`, and `sever_01` through `sever_03`.

`demo/humanoid.tscn`, `demo/crawler.tscn`, and `demo/modular.tscn` inherit this range
and start at stations 1, 2, and 3. The original imported walk/run clips remain in
`demo/assets/humanoid/humanoid.glb` and are used as controls in regression tests.

To install the plugin in another project, copy `addons/godot-dismemberment/` to its
`addons` directory, restart the editor and enable the plugin under Project
Settings > Plugins. Select a Skeleton3D and use its setup dock.

For another character, author its physical-bone chain and configure exact source
paths, pelvis name and allowed cut roots before initialization. The single convex
rigid-body fallback is an optional convenience; `limb_rigid_fallback_enabled`
defaults to false. The addon does not change another project's physics solver or
timestep. `docs/USAGE.md` describes the setup and gameplay hooks.

The default source-hide path operates on renderer skin matrices while preserving
animation/IK poses. Actual-render tests cover the reported floating-head defect,
R reset followed by new cuts, and additional cuts while already ragdolled. The
reset correction restores coherent body poses and rebuilds joint frames with
their authored settings. Original animation and component-free ragdoll controls
confirm this downloaded mesh is usable; detailed evidence and limits are in
`docs/REAL_MODEL_GEOMETRY_AUDIT.md`.

This demo ZIP contains the runnable project. Use the separate source ZIP for
the C++ source, build scripts and pinned godot-cpp dependency. `docs/VALIDATION.md`
records completed checks; `docs/PARITY.md` records cross-engine mappings and
remaining equivalence checks. The bundled blood masks and cloud noise tile were
generated procedurally for this port. Asset provenance is in
`THIRD_PARTY_NOTICES.md`.
