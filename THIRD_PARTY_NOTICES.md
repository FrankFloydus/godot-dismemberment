# Source provenance

The repository began with `godotengine/godot-cpp-template`. Its original
`LICENSE.md` is retained and applies to the upstream template. The original
template instructions are retained in `docs/TEMPLATE.md`.

The pinned `godot-cpp` submodule is Godot Engine's C++ binding library, under
its included MIT license. The source archive includes the pinned binding
sources so it can be built without a separate download.

The behavior reference is the user's installed EnGore: Procedural Dismemberment
1.3.3 plugin by Brock Marsh / SovereignDev, including local IMPERIUM changes.
Its source headers state all rights reserved. The upstream template license
does not relicense EnGore. No Unreal Engine source files, binaries, `.uasset`
or `.umap` files are included in these packages. The three blood splatter masks
and seamless cloud noise tile in `project/addons/godot-dismemberment/textures`
were generated procedurally for this port from independent geometry and noise.
Reference-product texture exports remain private development artifacts. The
Godot shaders, editor shell, demonstration environment and physical-body
configuration are authored for this port. The realistic humanoid mesh has the
separate provenance below.

The FPS demo's clothed humanoid is the rigged **Man Base Mesh** from
[Grab3D](https://grab3d.com/models/characters/man-base-character/). Grab3D publishes
the asset, its textures and supplied walk/run animations under
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/). The
download's [LICENSE.txt](https://grab3d.com/dl/man-base-character/LICENSE.txt),
manifest and local provenance record are retained in
`project/demo/assets/humanoid/` as `LICENSE.txt`, `manifest.json` and `ORIGIN.json`.
The origin disclosure identifies AI-assisted mesh/texture generation using Meshy
followed by cleanup, scaling, texturing and checks in Blender.

The downloaded rigged GLB is retained as `humanoid.glb`. The Godot demo derives
metre-sized bone rests and inverse binds while preserving the original Skin bind
slot mapping; it also includes imported PBR textures, a saved Godot body mesh and
17 authored physical bodies with a default combined mass of 75 kg. These Godot
setup changes do not alter the asset's stated CC0 provenance. The original
download SHA-256 is recorded in `ORIGIN.json`.

The range HUD uses Barlow Semi Condensed and IBM Plex Mono under the SIL Open
Font License 1.1. The license files accompany the fonts in
`project/demo/assets/hud_fonts/`.

The first-person shotgun derives from [Bullpup Shotgun, Fitted by 3DAssets.dev](https://3dassets.dev/assets/mega-weapon-pack-bullpup-shotgun-loadout-0f97efcb),
which the publisher identifies as AI-assisted and releases under
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/).
The demo fits it to the camera and applies Godot materials for first-person use.

The bundled shotgun recordings, hiking boot footsteps, room tone, and body
impact Foley are CC0 1.0. The recordings, creator links, and processing notes
are listed in `project/demo/assets/audio/PROVENANCE.md`.

Godot-specific implementations and engine adaptations are documented in
`docs/PARITY.md`; this package does not grant rights to the original EnGore
product or its content.
