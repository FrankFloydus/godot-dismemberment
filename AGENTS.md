# godot-dismemberment

This is a Godot C++ GDExtension port of EnGore procedural dismemberment.
The separate Prefabricator project remains under its existing checkout.

Work only in this repository and its parent `dist` for releases. The installed
Unreal plugin is a read-only behavior reference:
`C:\Program Files\Epic Games\UE_5.8\Engine\Plugins\Marketplace\EnGorePrb46a3ae0fd95V10`.
Do not modify that installation or package its original assets/source.

Follow `README.md`, `docs/PARITY.md`, and `docs/VALIDATION.md`. Build both Windows
targets with `tools/build.ps1`; run `tools/run_tests.ps1` with the installed
Godot 4.7 console executable. Preserve the native runtime and real skinned-mesh
demo coverage. Update the parity document when behavior or verification changes.
Package with `python tools/package.py` into the sibling `dist` directory.
Do not claim 100% parity from build success or marketing descriptions alone.
