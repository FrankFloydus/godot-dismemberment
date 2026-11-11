# Source re-audit: setup, material preservation, and wound paint

This audit was requested after the first demo review. It compares the installed
EnGore 1.3.3 C++ source and exported Control Rig/material graphs against the Godot
implementation. It records concrete corrections and remaining review work; it
does not establish complete engine equivalence.

## Expected source setup

1. Select the intended main skeletal mesh. The local source patch supports a
   `Dismemberment Source` component tag to distinguish the body from eyes or
   modular parts. Explicit source overrides take a component name in Unreal;
   Godot uses the configured mesh and skeleton NodePaths.
2. Set `PelvisBoneName` to a real bone. Unreal's `FName` comparison is insensitive
   to case; Godot bone lookup is sensitive to case. Imported names such as
   `Hips`, `mixamorig:Hips`, and `pelvis` must be configured exactly in Godot.
3. Assign a matching dismemberment animation instance in Unreal. The exported
   asset-action graph duplicates the template and sets its target skeleton.
   Godot's native pose skeleton replaces this asset-specific setup.
4. Enable CPU access on the Unreal skeletal meshes for blood vertex painting.
   Godot needs readable mesh surface position/bone/weight arrays and a correct
   Skin binding. Bone indices in mesh arrays are Skin bind indices, not
   necessarily Skeleton3D bone indices.
5. Use authored physics bodies for articulated detached ragdolls. A render mesh
   and animation rig alone do not contain the collision shapes and constraints
   of the Unreal physics asset.
6. Wrap the original Unreal material attributes with `MF_DIS_ApplyBlood` and
   match its selected vertex channel to the Gore component. Blue is the default.
   The source function changes base color, roughness, and wound normals while
   preserving the other incoming material attributes.
7. Enable attached child mesh support when using modular skinned clothing.
   Source groups/tags distinguish generated limbs, no-copy meshes, transferred
   props, overridden attachment bones, and meshes that ignore blood.

The source defaults for excluded bones, whitelist bones, and remapped bones are
empty. Requiring a pelvis does not automatically protect it from cutting.
Godot's editor setup and demo protect the root/pelvis explicitly as a convenience.
An FPS demo should whitelist intended limbs rather than treating every central
body or helper bone as a suitable cut point. A residual pelvis/tail outside a
chosen body subtree can be a correct hierarchy result.

## Findings and corrections

| Finding | Source evidence | Correction |
| --- | --- | --- |
| Detached limbs inherited the body's wider new blood radius. | `UGoreComponent::PreDismemberment` spawns effects only. `PostDismemberment` clones/copies earlier vertex colors before painting body and detached limb separately. | Removed new sphere painting from the pre hook. The post hook applies the main and limb radii independently, preserving earlier wounds. |
| Full skinned detached meshes were painted in the wrong coordinate space. | `ApplyBloodToMesh` compares reference-pose bone location with reference-position vertex buffers. | Skinned detached/collapse/articulated meshes now use the inverse Skin bind to locate the cut bone in mesh rest coordinates. Only pose-baked/static geometry uses a world hit transformed into its local frame. |
| Several deferred cuts could use the last cut's world location. | Source detached post callbacks retain each bone's identity and use its reference bone location. | Baked/static post paint now reads the individual limb's cached bone transform instead of a shared last-cut location. |
| A global material override could hide newly installed surface blood materials. | A Godot global `material_override` takes precedence over surface overrides. | The global slot itself is converted when present. Per-surface conversion is used only when there is no global override. |
| Basic material conversion discarded normal maps and most PBR inputs. | Exported `MF_DIS_ApplyBlood` reads incoming attributes and passes them through; its output changes only the wound attributes. | Conversion now carries normal scale/map, metallic/specular factors, packed texture channels, roughness, AO, ORM, UV1/UV2 transforms, repeat, culling, emission, and common alpha modes. |
| Source and detached objects could share blood animation uniforms through a global shader material. | Source custom primitive data is per component, even when a material asset is shared. | Native-generated blood materials carry an owning mesh ID and are duplicated before a copied mesh changes its uniforms. |
| Normal detail was lost outside wounds. | The material function interpolates the incoming tangent normal toward flat +Z only inside its blood mask. | The Godot shader retains the incoming normal texture and flattens it according to the wound mask. |
| The blood color parameter could be interpreted as an sRGB UI color. | The source vector default `(0.005,0,0)` is a linear material value. | The shader keeps this blood parameter linear; ordinary base/albedo color inputs retain Godot's normal color handling. |
| Reset could retain a completed animation uniform. | Clean blue-channel initialization must produce no blood. | Initialization/reset now set the blood animation uniform to zero as well as clearing the selected paint channel. |

## Why alpha masking was not enabled as a guessed fix

The installed `DismembermentComponent.cpp` defines `InitVertexColors`,
`GetDismemberAlphas`, and `ApplyMaskedVertexColors`, but contains no calls to
those helpers. Searches across the runtime source found no active callers.
`DismemberedVertices` is initialized for the legacy helper but is not part of
the active bone-hide/Control Rig cut sequence. Consequently, wiring the vertex
alpha channel into opacity would introduce behavior absent from the inspected
active source path.

The active blood material uses the configured blue/default paint channel. Its
final noise/contrast mask is multiplied by the painted channel, so a zero
paint channel must produce exactly zero blood regardless of cloud-noise pixels.
The main source paint radius is 120 cm, converted to 1.2 metres, and is genuinely
broad on a human body. A smaller explicit demo radius can be an art direction
choice without silently changing the plugin's reference default.

## Validation and remaining limits

`tests/test_gore_audit.gd` passed **21 checks with zero failures** on Godot 4.7
using a fresh isolated project import. It exercises clean initialization, preservation of other
vertex channels, active global material conversion, PBR texture/channel/UV
preservation, an animated full-skinned cut, independent main/limb paint radii,
independent material animation, rest-space paint after translating a detached
limb, and reset. A separate OpenGL Compatibility run on the imported textured
CC0 humanoid compiled the PBR/blood shaders and captured both clean and directly
severed states with exit code 0. These captures establish real renderer execution;
they do not validate the FPS raycast/hitbox path, which is tested separately.

The automatic material converter handles common StandardMaterial3D PBR inputs.
Custom ShaderMaterial graphs remain user-authored. Advanced triplanar, detail,
refraction, subsurface, alternate lighting models, and vertex colors that also
encode the original albedo require an explicit shader integration; the paint
channel cannot simultaneously retain unrelated source albedo data. Cross-engine
renderer output and physics still need visual comparison on the final imported
model. Test success on synthetic geometry does not establish identical output
for every imported rig or original Unreal asset.
