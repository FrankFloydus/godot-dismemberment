"""Build local addon, demo and self-contained source archives without caches or UE assets."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'.git', '.godot', '__pycache__', '.scons-cache', 'work', 'gen', '.vscode'}
SKIP_SUFFIXES = {'.obj', '.o', '.os', '.lib', '.exp', '.pdb', '.pyc', '.dblite', '.log'}

def files(folder: Path, binaries: bool = True):
    for path in sorted(folder.rglob('*')):
        if not path.is_file():
            continue
        rel = path.relative_to(folder)
        if (ROOT / 'project/demo/assets/mannequin') in path.parents:
            continue
        if any(p in SKIP_DIRS for p in rel.parts) or path.suffix in SKIP_SUFFIXES:
            continue
        if path.name.startswith(('.sconsign', '~')) or path.suffix in {'.uasset', '.umap', '.dmp', '.tmp'}:
            continue
        if not binaries and (path.suffix in {'.dll', '.so', '.dylib', '.a'} or 'bin' in rel.parts):
            continue
        yield path

def archive(target: Path, entries):
    with ZipFile(target, 'w', ZIP_DEFLATED, compresslevel=6) as out:
        for path, name in entries:
            out.write(path, name)
    with ZipFile(target) as out:
        bad = out.testzip()
        if bad:
            raise RuntimeError(f'Corrupt ZIP member: {bad}')
        members = out.namelist()
        if any('/.godot/' in name or '.uasset' in name or '.umap' in name for name in members):
            raise RuntimeError('Excluded data in archive')
    return {'file': target.name, 'bytes': target.stat().st_size,
            'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'members': len(members)}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT.parent / 'dist')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    addon = ROOT / 'project/addons/godot-dismemberment'
    for mode in ('debug', 'release'):
        dll = addon / f'bin/windows/godot-dismemberment.windows.template_{mode}.x86_64.dll'
        if not dll.is_file():
            raise SystemExit(f'Build both targets first. Missing {dll}')
    docs = [p for p in (ROOT/'docs').rglob('*') if p.is_file() and p.suffix in {'.md', '.json'}]
    notices = [p for p in (ROOT/'LICENSE.md', ROOT/'THIRD_PARTY_NOTICES.md') if p.is_file()]
    records = []
    records.append(archive(output/'godot-dismemberment-windows-x86_64.zip',
        [(p, p.relative_to(ROOT/'project').as_posix()) for p in files(addon)] +
        [(p, p.name) for p in notices] + [(ROOT/'docs/ADDON_README.md', 'README.md')] +
        [(p, 'docs/'+p.relative_to(ROOT/'docs').as_posix()) for p in docs]))
    records.append(archive(output/'godot-dismemberment-demo.zip',
        [(p, 'godot-dismemberment-demo/'+p.relative_to(ROOT/'project').as_posix()) for p in files(ROOT/'project')] +
        [(p, 'godot-dismemberment-demo/'+p.name) for p in notices] +
        [(ROOT/'docs/DEMO_README.md', 'godot-dismemberment-demo/README.md')] +
        [(p, 'godot-dismemberment-demo/docs/'+p.relative_to(ROOT/'docs').as_posix()) for p in docs]))
    entries = []
    for p in files(ROOT, binaries=False):
        entries.append((p, 'godot-dismemberment/'+p.relative_to(ROOT).as_posix()))
    records.append(archive(output/'godot-dismemberment-source.zip', entries))
    manifest = {'name':'godot-dismemberment', 'version':'0.1.0',
                'platform':'Windows x86_64', 'godot_api':'4.3',
                'tested_engine':'4.7.stable.official.5b4e0cb0f',
                'native_variants_verified':['template_debug','template_release'],
                'validation_report':'docs/VALIDATION.md',
                'demo_engine':'Godot 4.7 Forward+; GodotPhysics3D at 240 Hz and 32 solver iterations',
                'demo':'Editable sci-fi range, CC0 skinned humanoids, shotgun pellet impacts and articulated limb severing',
                'parity_status':'See docs/PARITY.md for engine adaptations and remaining equivalence checks.',
                'archives':records}
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
