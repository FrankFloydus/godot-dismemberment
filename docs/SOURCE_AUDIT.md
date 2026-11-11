# EnGore source audit

Audit date: 2026-11-11. This document records the local source used as the behavioral reference for `godot-dismemberment`.

## Reference identity

- Local source root: `C:\Program Files\Epic Games\UE_5.8\Engine\Plugins\Marketplace\EnGorePrb46a3ae0fd95V10`.
- Descriptor: `DismembermentSystem.uplugin`.
- Friendly name: EnGore: Dismemberment System.
- Descriptor version: 1.3.3; descriptor engine version: 5.8.0.
- Creator: SovereignDev. Source headers identify Brock Marsh, 2021, all rights reserved.
- Runtime module: `DismembermentSystem`, loaded PreDefault, Win64 allow list.
- Editor module: `DismembermentSystemEditor`, UncookedOnly, PostEngineInit.
- Engine dependency: Niagara.
- Source version macro: `DISMEMBERMENT_VERSION=1`; its header describes future component migration/version handling.

The installed source has local IMPERIUM patches, so matching only the marketplace version number would not identify this reference. No source repository commit was available in this installed folder. The hashes below identify its inspected files.

## Template provenance

The implementation repository was cloned recursively from `https://github.com/godotengine/godot-cpp-template`.

- Template HEAD at clone: `d36f9d03e9e02dad22829f1faf4e03a347616df5`.
- godot-cpp submodule at clone: `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5`.
- The template's library name, extension descriptor, entry symbol, and registration are renamed for `godot-dismemberment` following its README.

The unrelated Unreal Prefabricator source and earlier Godot Prefabricator checkout found under `Desktop\_Prefabricator` were excluded from this implementation after the EnGore source location was confirmed.

## Local changes present in the reference

The installed `DismembermentComponent.cpp` contains these labeled patches:

1. **24 August 2026, source selection:** an explicitly tagged `Dismemberment Source` mesh wins; multiple tagged meshes produce a warning. An override name still selects a mesh by name. Character owners prefer their actual character mesh over arbitrary first-component enumeration, fixing body/eyes selection.
2. **19 September 2026, pose anchors:** after creating detached physics, joint parent anchors are recalculated from the current posed transforms. This handles scaled bones and nonphysical intermediate bones such as neck bones without applying scale twice. Shared asset templates are not modified.
3. **4 October 2026, missing physics asset:** source and detached physics rebuilding return safely when no physics asset exists.
4. Editor-only pose logging surrounds the cut, physics rebuild, anchor update, and simulation enable stages.

These are behavioral evidence, not claims that Godot has identical engine APIs. The port must capture the current pose, avoid shared-resource mutations, and handle absent collision data safely to reproduce the corresponding outcomes.

## Source inventory and SHA-256

Paths are relative to the reference root. All hashes were read from the installed files; the original files are not included in the Godot package.

| Reference file | SHA-256 |
| --- | --- |
| `Source/DismembermentSystem/DismembermentSystem.Build.cs` | `3BC18A6D9F2F27CF99C4178C7C3CC3F27AEC4BBF40A8B23B3F8A467BACF76E81` |
| `Source/DismembermentSystem/Private/DismemberedAnimInstance.cpp` | `6831C535CF2095888C45F48920553A8969C5D14C80F748E2B958FE6554501B4F` |
| `Source/DismembermentSystem/Private/DismembermentComponent.cpp` | `1AFD8E9E1D9AADED858B9D8A11676EAAB775132426874CC41780B3D1B4007778` |
| `Source/DismembermentSystem/Private/DismembermentSystem_Log.cpp` | `D01FF2ADC02ABBD1991FBD34D5B4687E847CC9C9AF7D62130226D29B8C797B54` |
| `Source/DismembermentSystem/Private/DismembermentSystem.cpp` | `6C299B612B9790BC80CF1EC4244FDC305CC2223A6D0D62C2B0EA628D4A4897D0` |
| `Source/DismembermentSystem/Private/LimbMap.cpp` | `756341BB335C129ADFD573695964E3BB3091412618770428C8A20759C1A2F017` |
| `Source/DismembermentSystem/Private/Gore/BloodPool.cpp` | `8FDF9A940EBEDE0021D530518BD2E9F97586C2E682CBA2A652C7E4FAB906F8E7` |
| `Source/DismembermentSystem/Private/Gore/GoreComponent.cpp` | `C7B8DD8833709167792DFBABA5FB4DF85A15AC6A7B8321394319A48F5860720A` |
| `Source/DismembermentSystem/Private/Version/DismembermentVersioning.cpp` | `F6E6B01B6F54F8B64C7B77D39484C442EAA8158E4C790F0E38F0C593D8CD8FEF` |
| `Source/DismembermentSystem/Public/DismemberedAnimInstance.h` | `FD992C095AB60EEAB2D556B5E25007E41C57FD0F1D477C4902D3FFC619246323` |
| `Source/DismembermentSystem/Public/DismembermentComponent.h` | `62C87C27021F1CB1B29DF1E9DB90E3757837ECFFFB5437523EE67617F0170982` |
| `Source/DismembermentSystem/Public/DismembermentSystem_Log.h` | `6D2C95DA9C91113FFFC88042EF91EA2190105486938B9F6DE3AA48DB1CFE76A5` |
| `Source/DismembermentSystem/Public/DismembermentSystem.h` | `47E0AE53949C7BF38CD5CD6426F62514098ECF5D029203B02CEFA63123F03596` |
| `Source/DismembermentSystem/Public/LimbMap.h` | `0D6285FCF3F4ECB69B62D74964BA6C57821C174C9CB09AEBE0AE518567D6332A` |
| `Source/DismembermentSystem/Public/Gore/BloodPool.h` | `A9A9AD2F755322B4BC1C5974233B2CADC55887EAEC8BFC6A12A3BE89EEBB79A1` |
| `Source/DismembermentSystem/Public/Gore/GoreComponent.h` | `CFAA4B3D8C74DC1388D27886AB3175236A245817DAB1E43C899D74A4DB3D8644` |
| `Source/DismembermentSystem/Public/Version/DismembermentVersioning.h` | `82B322D41430AF9F74DC71365495CF4DDE1EFA47B522EA4CD74C3BB831678F0D` |
| `Source/DismembermentSystemEditor/DismembermentSystemEditor.Build.cs` | `B3CC992B62974D47186DCE769DD70A8B7A7BCCCC444716093EC273E4137D9B4E` |
| `Source/DismembermentSystemEditor/Private/DismembermentSystemEditor.cpp` | `8FFAA5F4B45B61E567D54C80D4F24AE128AA908BAD9E4C945E260DB4E39D952D` |
| `Source/DismembermentSystemEditor/Public/DismembermentSystemEditor.h` | `7645A37B3637204D654853BE0E0BA0D82CDCBE707A2D0CA5E00C5086AEC1A0F4` |

## Content inventory and inspection boundary

The installed content contains the following asset groups:

- `UE4_Dismemberment_ControlRig` and `UE4_Mannequin_Dismemberment_AnimBP`: actual Unreal pose-copy and bone-scaling graph behavior. The C++ animation base only declares `Limb` and `PelvisBoneName`.
- `AssetAction_CreateDismembermentRig`: Blueprint editor automation for rig setup.
- Niagara `NS_DIS_BloodBurst`, `NE_DIS_BloodParticle`, and `NE_DIS_BloodBurst`.
- Blood materials/functions `M_DIS_Blood`, `M_DIS_Sprite`, `M_Decal_BloodPool`, `M_Decal_BloodPool_Custom`, `MF_DIS_BloodMask`, `MF_DIS_ApplyBlood`, their instances, three blood textures, and cloud noise.
- UE4 mannequin skeletal mesh, skeleton, physics assets, body/logo materials, and textures.
- Showcase level and Blueprint actor, pawn, game-mode, and controls display assets.

The Unreal editor was subsequently used to inventory **33 assets**, export **17 text graph/asset descriptions**, and export **7 texture images** into local scratch evidence under `work/unreal_asset_audit`. These scratch exports are excluded from the release package. The inventory distinguishes assets whose class/name was read from those with successful text/image export.

The inspected animation graph copies pose from its attached parent, feeds the Control Rig with `Limb` and `PelvisBoneName`, and outputs the resulting pose. The Control Rig imports the skeleton at construction, then in its forward solve sets the pelvis transform to 1% scale, sets the selected limb global scale to 1, and sets its global rotation to identity. All three operations propagate to children. Its pelvis transform also has a mannequin-specific quaternion and zero translation. The Godot implementation uses native skeleton/geometry processing in place of RigVM execution; a current-pose comparison on identical continuous meshes remains necessary to establish the same boundary appearance.

The asset action graph enumerates selected assets, duplicates its template asset through AssetTools, and calls the native target-skeleton setter. The demo pawn graph exposes click-hit dismemberment, reset, cleanup, and cursor/UI setup. Material graphs and Niagara descriptions were available to the effect implementation; see `GORE_MAPPING.md` for the corresponding shader/effect mapping.

The addon includes independently generated procedural blood masks (`blood_01.png`, `blood_02.png`, `blood_03.png`) and a tileable cloud noise texture (`cloud_noise.png`). Texture exports from the reference remain private development artifacts. Mannequin/example geometry in the Godot demo is newly generated. No reference `.uasset` or `.umap` is redistributed. Exact rendered equivalence still needs side-by-side engine comparison because renderer, physics solver, particles, and projection differ.

## Attribution and scope

No permissive license file was found in the installed EnGore directory. Its source and content remain separately licensed, including private texture exports. The template has its own license in the repository. This audit records behavior and provenance; it does not relicense EnGore or imply endorsement by its creator. Source, engine compatibility, visual asset equivalence, and multiplayer behavior should be assessed separately using `PARITY.md`.
