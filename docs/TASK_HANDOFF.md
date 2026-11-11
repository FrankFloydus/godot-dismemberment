# godot-dismemberment Codex task

The user's objective is to port everything in the installed Unreal **EnGore**
plugin to a native Godot C++ plugin named **godot-dismemberment**. The repository was cloned recursively from
`godotengine/godot-cpp-template`. Follow `AGENTS.md` and the template-derived
build workflow. The unrelated Prefabricator project is not this source.

The source reference is read-only:
`C:\Program Files\Epic Games\UE_5.8\Engine\Plugins\Marketplace\EnGorePrb46a3ae0fd95V10`.
It is EnGore 1.3.3 with local IMPERIUM patches. Exact hashes and graph inspection
are in `SOURCE_AUDIT.md`. Development-only Unreal graph/image exports are in
`work/unreal_asset_audit`; do not package those exports or `.uasset`/`.umap`.
The four packaged addon PNG textures are procedural replacements authored for the Godot port.

The user's demo requirements are essential: **an FPS with a downloaded, realistic
CC0 humanoid**. The main range now has three stations using the rigged
[Grab3D Man Base Mesh](https://grab3d.com/models/characters/man-base-character/)
under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/): humanoid cuts,
articulated limbs, and attachments/hit remapping. The user moves in first person,
aims a centered crosshair and shoots to sever the hit limb. Preserve actual
physics raycast hit-to-bone mapping and native dismemberment. The older
`crawler.tscn` filename now opens the humanoid articulated-limb station.

Multiple agents implemented the core, hierarchy/mesh utilities, blood effects,
editor setup/export integration, demos and regression tests. The runtime classes
are registered native GDExtension classes. The editor shell, demos and tests use
GDScript. Default `BONE_COLLAPSE` mirrors the source rig's weighted boundary
approach through per-mesh renderer skin-palette collapse, retaining local
animation/IK poses and deriving source cut pivots from the evaluated rendered
parent. `TRIANGLE_PARTITION` remains an optional geometry mode. Authored
PhysicalBone3D chains supply limb simulation. The additional single convex
rigid-body fallback requires `limb_rigid_fallback_enabled`, default false.

The realistic demo uses 17 authored physical bodies, fitted shapes and constrained
joints per target, with 75 kg combined mass. Its final hand boxes fit weighted
geometry in hand rest axes and use 0.35 contact friction. The example uses
the engine's default physics settings. The addon uses the host project's
physics settings. Preserve the demo's protected pelvis/torso filters
and explicit 0.3 m body / 0.18 m detached wound radii.

Both Windows x86_64 debug and release libraries have been verified on Godot 4.7,
targeting API 4.3. See `VALIDATION.md` for exact completed evidence and the final
suite totals. The toolkit includes actual two-process ENet tests. Use isolated project copies
when an interactive editor holds Godot's temporary DLL open. Preserve user
editor state; restart is needed to load a changed native library.

The user subsequently identified two real-model failures: floating cut geometry,
then severely stretched ragdolls after pressing R and cutting again. Both were
reproduced and corrected in native code. First-cut source hide now follows the
actual renderer palette rather than restored animation getters. Reset now
restores all source bodies coherently before rebuilding their joint frames while
retaining authored types, offsets and constraint settings. Rendered tests cover
repeated R cycles followed by sequential Head/LeftArm/LeftLeg cuts while already
ragdolled. The original model's walk/run animations and component-free ragdoll
controls are healthy; the mesh is usable, and these failures were plugin state
handling defects. Keep `tests/test_real_skin_geometry.gd`,
`tests/test_ragdoll_comparison.gd` and `tests/test_physics_joint_integrity.gd` as coverage.
`REAL_MODEL_GEOMETRY_AUDIT.md` separates the rendered Head/neck anchor error from
the independent physics constraint-gap metric. Real-render tests need an active
viewport; headless dummy rendering does not exercise the same palette behavior.

The goal is **full behavior fidelity**, and a passing suite is not proof of
100% equivalence. `PARITY.md` and `GORE_MAPPING.md` document adaptations and
remaining side-by-side work, especially Niagara simulation, exact decal
projection/material output, complex standard/custom material attributes,
arbitrary rig boundaries, and physics solver differences. Evaluate the actual
reference graphs and behavior before claiming completion; do not merely rename
features or hide open differences.

The release directory is `../dist`. `python tools/package.py` creates addon,
FPS demo and self-contained source ZIPs plus a SHA-256 manifest. Rebuild, run
relevant checks, validate a fresh extracted project, and regenerate these
archives after further changes. Preserve the playable FPS demo as acceptance
coverage when continuing fidelity work.
