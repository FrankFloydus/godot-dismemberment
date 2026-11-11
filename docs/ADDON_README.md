# godot-dismemberment Windows addon

Extract this ZIP into an existing Godot project so it contains
`addons/godot-dismemberment/`. Restart Godot, then enable **godot-dismemberment** under
Project Settings > Plugins. Windows x86_64 debug and release DLLs are included;
the local validation engine is Godot 4.7 stable and the extension API is 4.3.

Select a Skeleton3D with a skinned MeshInstance3D beneath it and use **Set up
selected skeleton** in the plugin dock. Save the scene. Configure the source
paths, pelvis name, filters, attachments, blood settings and collision layers
on the native GoreComponent. Call `dismember_limb(bone_name, impulse)` from game
code; `reset_all_limbs()` restores the character.

The separate demo ZIP contains three runnable scenarios. The separate source
ZIP contains the complete C++ project, pinned bindings and build scripts.
See `docs/VALIDATION.md`, `docs/PARITY.md` and `THIRD_PARTY_NOTICES.md` for tested
behavior, engine adaptations and source-content attribution.
