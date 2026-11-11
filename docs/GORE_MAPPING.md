# EnGore gore and blood mapping

This document describes the native Godot implementation in `GoreComponent` and
`BloodPool`. The reference is the user's installed EnGore 2021 source and its
UE 5.8 content, read locally from the `EnGorePrb46a3ae0fd95V10` Marketplace
directory. The Godot package name requested for this port is `godot-dismemberment`.

## Reference inspection

The port was checked against `Public/Gore/GoreComponent.h`,
`Private/Gore/GoreComponent.cpp`, `BloodPool.h/.cpp`, the exported material
graphs `MF_DIS_ApplyBlood`, `MF_DIS_BloodMask`, `M_Decal_BloodPool`,
`M_Decal_BloodPool_Custom`, and `M_DIS_Sprite`. The Niagara graph exports were
available for reference. The port implements native Godot effects rather than
embedding Unreal objects or running Niagara.

The Unreal animation instance contains only `Limb` and `PelvisBoneName` fields;
its pose copying and control rig are stored in content assets, rather than its
C++ implementation. See the general parity documentation for the Godot
pose-baking and physics approach.

## Units and coordinates

Godot positions and radii use metres with Y up. Unreal source values use
centimetres with Z up. The defaults below include that conversion. Impulses and
directions are vectors in Godot world coordinates, and the caller supplies them
in Godot's units.

| Unreal setting | Godot property | Default |
| --- | --- | --- |
| Enable blood pools | `enable_blood_pool_decal` | `true` |
| Enable particles | `enable_blood_particles` | `true` |
| Enable skin painting | `enable_blood_skin_painting` | `true` |
| Pool scale | `blood_pool_scale` | `1.0` |
| Decal lifetime | `blood_decal_lifetime` | `60.0` seconds |
| Decal override | `override_blood_decal`, `blood_decal` | `false`, empty |
| Texture override | `override_blood_decal_texture`, `blood_decal_texture` | `false`, empty |
| Texture tile size | `blood_decal_tile_size` | `7.5` metres, from 750 cm |
| World space tiling | `use_world_space_tiling` | `true` |
| Allowed surface object types | `allowed_surface_types_for_blood_decals` | collision layer mask `1` |
| Particle override | `override_blood_particles`, `fx_blood_burst` | `false`, empty |
| Particle scale | `blood_particle_scale` | `1.0` |
| Paint scale | `blood_paint_scale` | `1.0`; reserved, unused by the upstream implementation |
| Character paint radius | `blood_paint_radius` | `1.2` metres, from 120 cm |
| Detached paint radius | `blood_paint_limb_radius` | `0.75` metres, from 75 cm |
| Paint falloff | `blood_paint_falloff` | `0.2` |
| Vertex color channel | `blood_vertex_channel` | `2`, blue; 0–3 means RGBA |
| Animation primitive index | `blood_animation_primitive_index` | `0`; compatibility metadata, see below |
| Blood animation time | `blood_animation_time` | `1.0` second |
| Automatic standard material conversion | `auto_apply_blood_material` | `true`; Godot convenience |

The surface type setting is a Godot physics collision layer mask, since Unreal
object query enums have no cross-engine meaning. Put receiving surfaces on the
allowed layers and give them collision shapes. The pool ray starts at the cut,
uses the impulse direction with its downward Y component replaced by `-0.7`,
and extends 20 metres, matching the source's 2,000 cm trace.

The Inspector groups the three automatic effects separately and shows their
controls when enabled. Assigning an active pool material override hides the
built-in texture controls. Tile size appears for built-in materials with
world-space tiling. The world-space toggle stays visible because it also affects
the pool footprint. The two compatibility-only paint settings remain available
through scripts and scene storage.

## Callable API

All methods are bound to GDScript. The misspelling `spawn_bool_decal` from the
original public API is retained as an alias of `spawn_blood_decal`.

```gdscript
gore.apply_blood(&"upperarm_l", 0.75, 0.2)
gore.apply_blood_to_mesh(mesh, &"upperarm_l", 0.75, 0.2)
gore.apply_blood_to_static_mesh(weapon, world_hit, 0.75, 0.2)
gore.remove_blood_from_static_mesh(weapon)

var pool: BloodPool = gore.spawn_blood_decal(world_hit, normal, surface, direction)
var original_alias: BloodPool = gore.spawn_bool_decal(world_hit, normal)
var particles: Node3D = gore.spawn_blood_particles(world_hit, direction)
gore.spawn_blood_fx(world_hit, direction, &"upperarm_l")
```

`spawn_blood_particles` takes a direction vector. The Unreal function's rotator
was used only to orient the emitted effect. A custom `PackedScene` can replace
the native burst; its root must derive from `Node3D`. It is placed at the world
location, scaled by `blood_particle_scale`, and removed after 2.5 seconds.

The three enable flags control effects triggered by dismemberment. As in the
reference, calling `spawn_blood_fx` explicitly spawns its effects directly,
independent of those flags. It paints only when a hit bone is supplied.

## Vertex paint and material mapping

The native sphere mask is:

```text
clamp((1 - distance(center, vertex) / radius) / max(1 - hardness, 0.00001), 0, 1)
```

Painting max-blends this mask into the selected color channel and preserves the
other channels. Character paint uses reference/rest bone positions, matching the
source. Detached skinned geometry also uses rest space, derived from inverse Skin
binds so subsequent world movement does not move the wound. Pose-baked/static
detached geometry uses its individual cut's world position transformed into its
local frame. The body and detached limb receive their separate radii after the
clone is created; the limb inherits only earlier wounds. Meshes
in the `Ignore Blood` or `ignore_blood` groups are skipped by `apply_blood`.

Mesh color data is duplicated per instance to avoid modifying shared source
assets. Surface materials, blend shape arrays, live blend shape values, and LOD
index dictionaries are preserved while replacing that mesh. The selected channel
is cleared on initialization and after `reset_all_limbs` restores the original
mesh.

`blood_skin.gdshader` recreates the inspected material graph operations:

1. The animation factor is `clamp((a + 0.9) * ceil(a), 0, 1)`.
2. The blue/default selected vertex channel is multiplied by that factor.
3. Cloud noise is sampled with UV divided by `0.5`.
4. The mask input adds `pow(painted, 50) * 10` to the noise and applies the
   source's contrast setting of `10`, then multiplies by `painted`.
5. The material blends toward blood color `(0.005, 0, 0)` multiplied by
   `Dismember Emissive` (default `5`) and `2`.
6. Roughness blends toward `0.2 * (1 - mask)`.

The first paint animates from zero to one over `blood_animation_time` on the
main mesh. Painted clothing and detached meshes use one immediately. Godot
isolates the animated value per mesh, including custom ShaderMaterial resources
that declare a float `blood_animation` uniform. The original shader and other
uniforms are retained. `blood_animation_primitive_index` records the Unreal API
mapping.

With automatic conversion enabled, standard materials retain their albedo,
normal maps/strength, metallic/specular, roughness, ambient occlusion, packed
texture channels, ORM inputs, UV transforms, culling, emission, and common alpha
modes in the blood shader. A global material override is converted in its own
slot. Generated blood materials are separated per mesh before animation uniforms
are changed, including detached global overrides. To make a custom shader show blood, consume the chosen `COLOR` component and
declare the float `blood_animation` uniform. Complex source
material graphs, triplanar/detail/refraction/subsurface networks, alternate
lighting models, and engine-specific material attributes are not automatically
translated by this conversion. The original normal detail is retained outside a
wound and blended toward flat tangent-space +Z inside it, matching the exported
material function. See `RE_AUDIT_GORE_SETUP.md` for the source-backed corrections
and expected rig setup.

## Blood pool rendering

BloodPool starts at full projection size and aligns to the world-space receiving
normal. GoreComponent starts the 0.3-second fade-in after a 0.25-second delay.
The fade-out starts independently at one fifth of the configured lifetime and
lasts that lifetime. Opacity is the lesser of the two fades, clamped to [0, 1].
A zero lifetime leaves the decal visible after fade-in. The native pool frees
its node at the end of a finite fade, while Unreal retains its overlap actor.
Pools follow an explicit receiver or one found by the physics ray.

On Vulkan, Direct3D, and Metal renderers, pools use native Godot `Decal` nodes.
On Compatibility and headless renderers, pools use an alpha-blended plane just
above the receiving surface. Both paths retain visible pools without requiring
Godot's decal support. The fallback shader adds world-space/local noise tiling
and a wet-to-dry roughness animation. An explicit material override also uses
the plane path, because Godot `Decal` does not accept an arbitrary `Material`.

The default puddle silhouette is generated in native code. This is a visual
recreation, rather than an identical reproduction of Unreal deferred decal
projection, scene-normal rejection, or its exact material/lifetime integration.
Custom texture overrides replace that silhouette on both render paths. An
arbitrary custom material controls its own shader opacity; its uniforms are not
rewritten to enforce the default fade shader.

## Particle effects and procedural textures

The default burst is a native `CPUParticles3D` droplet system and a second sprite
spray using the procedural `blood_01.png` mask. It works with Compatibility as
well as Forward+. This reproduces the feature and its public controls, while
Godot's particle simulation differs from Niagara. The exact Niagara emitters,
module stack, collision responses, random streams, and pixel output are not
claimed identical. Use `fx_blood_burst` for an art-directed Godot effect.

The four bundled PNGs were generated independently for the Godot port.
`blood_01.png`, `blood_02.png` and `blood_03.png` are grayscale splatter masks
with opaque alpha. The burst shader samples red for erosion. The seamless
grayscale `cloud_noise.png` supplies red-channel variation to the pool and skin
shaders. Reference texture and graph exports remain private development
artifacts.

The retained graph exports in `work/unreal_asset_audit` are development
references only. They must remain outside the distributable addon ZIP.
