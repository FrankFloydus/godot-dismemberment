# godot-dismemberment

Native C++ procedural skeletal dismemberment for Godot. This project ports the
behavior of the locally installed **EnGore 1.3.3** Unreal plugin, including its
IMPERIUM changes.

The runtime is a GDExtension. The small GDScript editor shell adds setup,
validation, and a bone hierarchy dock; GDScript demo/test scenes exercise the
native implementation. This is separate from the Prefabricator project.

## Open the demos

Import `project/project.godot` into Godot and open `res://demo/demo.tscn`
from the FileSystem dock. Select the root **FirstPersonDismembermentRange**
node and expand **Shooting** to edit the shotgun's pellet count and spread,
**Dismemberment Impulse** (forward velocity change in m/s), **Dismemberment
Upward Boost**, shot timing, and range. **Player Movement** contains speed,
gravity, jump, and mouse settings.

The range, player, HUD, and targets are saved as editable scene instances.
Expand **Stations** to edit the spawn and aim markers, each target's
**GoreComponent**, or the skeleton's hitboxes and physical bones. Press **F5**
for the main range or **F6** to run one of these scenes:

- `res://demo/demo.tscn` — all three realistic humanoid target stations.
- `res://demo/humanoid.tscn` — starts at the CC0 humanoid station.
- `res://demo/crawler.tscn` — starts at the articulated-limb station; the filename
  is retained from the earlier creature demo.
- `res://demo/modular.tscn` — starts at the attachment and hit-remapping station.

All three stations use the downloaded, rigged
[Grab3D Man Base Mesh](https://grab3d.com/models/characters/man-base-character/),
published under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).
Its clothed skinned mesh, PBR textures, skeleton and original walk/run clips are
included. The `demo/rigs` scenes contain saved, inspectable versions of the
normalized rig. Each target uses 17 authored physical bodies and constrained
joints, with a total mass of 75 kg. Hand colliders follow the weighted hand
geometry and use lower contact friction. The demo uses **GodotPhysics3D at
240 physics ticks per second and 32 solver iterations**. Installing the addon
does not change another project's solver settings.

Left-click to fire a shotgun blast from the crosshair. Every pellet can leave
a mark on the range. A trigger pull applies at most one dismemberment hit per
target. The desktop demo uses Forward+ with SDFGI, volumetric fog, glow, and
AgX tone mapping. WASD moves, the mouse looks, Shift sprints, Space jumps,
R resets, and 1/2/3 changes station. Esc releases the mouse. F fires a blood-only
shot, X hides a hit limb, and C cleans up debris.

On `experiment/plane-slicing`, hold **middle mouse**, drag from the crosshair
across an intact subject, and release to slash through the posed mesh. The swipe
sets the angle. Each closed fragment gets its own rigid body and can be slashed
again. **R** restores the rig. **V** remains the quick forearm cut, with
**Q / E** to tilt that cut by up to 5°. See the [slicing API](docs/USAGE.md#experimental-slicing-api)
to drive the same operation from a game animation.

The supplied binaries target **Windows x86_64**, standard single-precision Godot.
They use the Godot **4.3** extension API; local verification uses **4.7 stable**.
Other platform entries in the descriptor require a corresponding local build.

## Install in another Godot project

1. Extract `godot-dismemberment-windows-x86_64.zip` into the project root. This creates
   `addons/godot-dismemberment/` with its descriptor and debug/release DLLs.
2. Restart Godot so it loads the native classes.
3. Enable **Project > Project Settings > Plugins > godot-dismemberment** for the setup dock.
4. Select a `Skeleton3D` or a skinned `MeshInstance3D`, and press
   **Set up selected skeletons** in the dock. Save the scene.
5. Author physical bones, fitted collision shapes and constrained joints for the
   source character, as with the reference plugin's Physics Asset. Configure the
   component's source paths, pelvis bone, allowed cut roots, filters, effects,
   collision layers and multiplayer settings in the Inspector. See `docs/USAGE.md`.

Enabling the editor plugin also registers a small runtime manifest autoload.
Its explicit dependencies let Godot include the native extension, blood shaders
and imported textures when exporting selected scenes. Existing autoloads and
other extensions are preserved. Disabling the plugin removes only its own
manifest registration.

If upgrading an installation of the addon under its former `godot-prefabs`
name, disable the old plugin before removing its addon folder, then install and
enable `godot-dismemberment`. Update any direct resource paths in your project
that point into the old addon folder. Existing native component class names
and authored physics metadata remain compatible.

A source mesh must have triangle surfaces with valid bone and weight arrays.
Godot `Skin` bind names/indices are resolved to skeleton bones; 4- and 8-weight
formats are supported. Shared imported mesh resources are preserved: changes
are made on the affected instance. Bone filtering and remapping use exact names.

`BONE_COLLAPSE` is the default geometry mode. Removed source regions collapse
through per-mesh renderer skin-palette overrides that follow the currently
rendered parent pose; animation and IK bone poses remain available. A detached
full skin retains the selected pose and compresses its complement to 1% scale.
Authored physical-bone chains supply limb simulation. The extra single-body
convex fallback is opt-in through `limb_rigid_fallback_enabled`, which defaults
to false. `TRIANGLE_PARTITION` is an explicit alternative geometry mode.

```gdscript
@onready var gore: GoreComponent = $GoreComponent

func _ready() -> void:
    if not gore.initialize():
        push_error(gore.get_last_error())

func hit_bone(bone: StringName, impulse: Vector3) -> void:
    gore.dismember_limb(bone, impulse)

func restore_character() -> void:
    gore.reset_all_limbs()
```

Native classes are `DismembermentComponent`, `GoreComponent`, `LimbMap`,
`MeshPartition`, `DismemberedLimb`, `DismemberedAnimInstance`, and `BloodPool`.
Pre/post dismemberment signals support game logic. Cleanup removes detached
objects; reset restores the source geometry and permits new cuts.

Godot groups `Dismemberment Source`, `No Dismemberment`, `Transfer Dismemberment`,
and `Ignore Blood` carry the corresponding source plugin tags. Configure attached
mesh support on the component when using clothing or transferable objects.
Distances use meters (100 Unreal centimeters = 1 Godot unit); time uses seconds.

## Build from the template

The repository was cloned recursively from
[godotengine/godot-cpp-template](https://github.com/godotengine/godot-cpp-template).
Its original README is retained in `docs/TEMPLATE.md`. The library name,
`.gdextension` descriptor, exported entry symbol, CMake target and release workflow
have been renamed as instructed there.

Prerequisites: Python 3, SCons, a C++17 compiler and the initialized `godot-cpp`
submodule. If cloning this repository normally, initialize dependencies with:

```powershell
git submodule update --init --recursive
```

The self-contained source ZIP already includes the pinned binding sources.
Build both local Windows targets:

```powershell
./tools/build.ps1
# Equivalent individual commands:
scons platform=windows arch=x86_64 target=template_debug -j12
scons platform=windows arch=x86_64 target=template_release -j12
```

SCons installs libraries directly into `project/addons/godot-dismemberment/bin/windows`.
The descriptor uses `godot_dismemberment_library_init`. `build_profile.json` limits
binding generation to runtime classes and their dependencies. Generate an IDE
compilation database with `scons compiledb=yes compile_commands.json`.

CMake is also configured with the same API/profile and source discovery; the
local release verification is performed with SCons.

## Test and package

```powershell
./tools/run_tests.ps1 -Godot 'C:/path/to/Godot_console.exe'
./tools/test_network.ps1 -GodotPath 'C:/path/to/Godot_console.exe'
python tools/package.py
```

The package command creates addon, runnable demo, and self-contained source ZIPs,
plus a SHA-256 manifest, in the sibling `dist` directory. It excludes editor
caches, build intermediates and the Unreal reference exports.

Read `docs/VALIDATION.md` for the actual completed checks, `docs/PARITY.md` for
behavior mapping and remaining equivalence checks, and `docs/SOURCE_AUDIT.md`
for the exact local reference and hashes. A passing build alone does not establish
100% visual, physics or workflow equivalence between different engines.

Actual-render regression tests also cover the reported floating-head and
R-reset stretching failures on the downloaded humanoid. Source skin collapse
now follows evaluated physics, and reset restores coherent body poses before
rebuilding joints and preserving their authored settings. Repeated resets and
sequential cuts on an already-ragdolled body pass the focused checks. The original
walk/run clips and component-free ragdoll controls establish that this mesh is
usable; details and measurement boundaries are in
`docs/REAL_MODEL_GEOMETRY_AUDIT.md`.

Attribution and reference-content provenance are in `THIRD_PARTY_NOTICES.md`.
