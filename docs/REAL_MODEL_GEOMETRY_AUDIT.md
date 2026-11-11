# Actual CC0 rig: floating head and stretched skin regression

The reported failure was reproduced on the actual imported CC0 humanoid rather
than a procedural stand-in. `tests/test_real_skin_geometry.gd` reads Godot's
rendered skin through `bake_mesh_from_current_skeleton_pose` and the skin palette
from RenderingServer. It requires a real renderer and an active Camera3D; the
headless dummy renderer does not provide equivalent modifier/palette behavior.

## Import and weights

The mesh contains 143,901 rendered surface vertices and 24 Skin bind slots. All
weighted indices are valid, every vertex has nonzero normalized weights, and
the factory preserves the imported slot-to-bone mapping. The original GLB uses
a 0.01 Armature scale and inverse bind bases near 100. The normalized factory
uses metre-scale bone translations and unit-scale inverse bind bases.

The original Armature has a constant translation of approximately
`(0.000096, 0, -0.024723)` metres. Accounting explicitly for that origin change,
the original and normalized rendered rest positions and rotated Head/LeftArm
poses differ by less than 0.000073 metres. The normalization was therefore not
the cause of the detached head or long skin bridge.

The actual Head subtree has 14,173 fully selected vertices and 8,124 vertices
with mixed Head/neck influences. The LeftArm subtree has 15,722 fully selected
vertices and 6,742 mixed vertices. These transition vertices expose errors that
one-bone boxes and unanimated rest-pose checks cannot detect.

## Failure mechanism

Godot's SkeletonModifier3D processing can restore the base animation pose after
applying a physical-bone modifier to the renderer. Reading
`Skeleton3D.get_bone_global_pose()` outside that modifier evaluation can return
the original animation/rest position even while the rendered body is falling.

The previous source-hide palette override used that stale pose as the zero-scale
cut pivot. The source body's retained neck moved with physics, but removed Head
vertices stayed collapsed around the original head position. The mixed-weight
triangles consequently stretched between those two positions.

The actual-render regression measured a 1.678-metre Head pivot error and a
1.318-metre LeftArm pivot error after 60 physics frames. A test whose expected
position also came from the stale Skeleton3D getter would have falsely passed.

The correction derives the removed root's pivot from an actual retained parent's
RenderingServer skin matrix, removes that parent's inverse-bind transform, and
composes the local chain to the cut root. The collapsed source region therefore
follows the currently rendered parent, including physical simulation.

Two related corrections are covered by the same model-level evidence: removed
source physical bodies are quarantined so starting a remaining ancestor cannot
reactivate them, and detached pose capture leaves selected bones available for
their physical-bone modifier rather than freezing their visible geometry behind
persistent global pose overrides.

## Verification after correction

The actual-render test passed **29 checks with zero failures** on Godot 4.7,
OpenGL Compatibility, RTX 4090. It verifies bind normalization, weight validity,
posed original/normalized geometry, initial source collapse, moving source
pivots, detached physical-body/visible-skin agreement, collapsed detached
complements, and visible independent movement.

Representative measured results after 60 physics frames:

| Measurement | Head | LeftArm |
| --- | ---: | ---: |
| Source cut-region error from moving rendered parent pivot | 0.000169 m | 0.000291 m |
| Detached visible root error from its actual physical body | 0.000117 m | 0.000045 m |
| Detached collapsed-complement radius | 0.0155 m | 0.0147 m |
| Visible detached root movement from original cut position | 1.726 m | 1.774 m |

A separate three-second FPS capture used an actual aimed left-click ray, hit
`Head`, and showed the body settled on the floor without a head suspended at its
former position or a long connecting skin triangle. The camera reticle remained
centered in the 1440×900 viewport.

The native collapse mode follows the source's bone/skin approach; it does not
generate a new polygonal cut cap. These results address the reported moving
skin/physics failure on this real model. They are not a claim of identical
rendering for every rig, material, animation system, or original Unreal asset.

## Subsequent reset-cycle finding

The initial 29 checks above address a first cut and its moving skin. They did
not exercise reusing the same source physics bodies after the FPS reset key.
The later `tests/test_ragdoll_comparison.gd` adds those controls and reset cycles.

On the original downloaded model, the supplied `run` and `walk` clips produced
maximum triangle edges of approximately 0.059 m and 0.052 m. The normalized
model with authored full-body ragdoll and no component produced 0.074 m; adding
an enabled component without cutting produced 0.078 m. All 24 rendered bone
palettes, including nonphysical shoulder/neck/toe helpers, matched their
physical-body or parent-derived transforms within approximately 0.000001 m.

The failure was then reproduced after two Head-cut/reset cycles followed by a
LeftArm cut and full-body ragdoll. Each reset first returned the rendered mesh
exactly to its original rest positions, but the subsequent simulation placed the
restored Head physical body approximately 1.55 m away from its neck. The visible
skin followed that physical body correctly; its largest triangle edge stretched
to 0.521 m. This distinguishes the later failure from the earlier renderer-pivot
bug and from malformed asset weights.

The comparison script now fails if these cut/reset cases produce skin edges
over 0.2 m or head/neck anchor separation over 0.1 m. Physics restoration and its
constraint-frame rebuild were subsequently corrected: all source bodies are put
back into a coherent pose before their joints are rebuilt, retaining the authored
joint types, offsets, limits, and other constraint settings.

The rebuilt version passed **13 rendered cases and 26 checks with zero failures**:
original run, original walk, component-free ragdoll, enabled uncut component
ragdoll, three cut/reset cycles, and sequential Head, LeftArm, and LeftLeg cuts
on the same already-ragdolled body after those resets. The formerly failing third-cycle LeftArm
case improved from a 0.521 m maximum skin edge to 0.0695 m. Its restored head/neck
anchor separation improved from approximately 1.55 m to 0.000123 m. Every reset
snapshot returned exactly to the baseline rendered rest positions.

After the final sequential leg cut, the remaining body's maximum triangle edge
was 0.068472 m. The detached Head, LeftArm, and LeftLeg had maximum edges of
0.032714 m, 0.045035 m, and 0.044614 m respectively. The removed Head's collapsed
source pivot remained within 0.000000205 m of its currently rendered parent-derived
position. These detached-piece measurements are recorded in the report in addition
to the asserted source-body and restored-head thresholds. The final rendered
capture also showed no long connecting skin strip.

The complete per-case geometry, bind-palette measurements, screenshots, and
assertion summary are saved under `work/ragdoll-comparison-reset-fix/` and
`work/ragdoll-comparison-reset-fix.log`. These outputs were captured with an actual
OpenGL viewport rather than the headless dummy renderer.

The controlled comparison therefore identifies a plugin physics-state restoration
defect; it does not support declaring the downloaded mesh unusable. These tests
cover this imported asset and sequence. Passing earlier first-cut tests alone
would not have established reset-cycle recovery.
