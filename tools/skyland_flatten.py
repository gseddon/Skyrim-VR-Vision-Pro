#!/usr/bin/env python3 -I
"""Flatten a chosen subset of the Skyland AIO FOMOD into a loose-file Data tree (private, git-ignored).

  python3 -I tools/skyland_flatten.py --src "<extracted Skyland AIO folder>" --out build/private/mods/skyland-aio-1k \
      [--select PREFIX ...]      default: the Landscapes and Whiterun options

The download is untrusted data: this reads fomod/ModuleConfig.xml as XML (never executes anything from it), only takes the
<folder source=... destination=...> entries whose source starts with a --select prefix (so every copied folder is one the
FOMOD itself lists), refuses symlinks and paths that leave the source, copies with APFS clones (cp -c: no extra disk on the
same volume), merges names case-insensitively (APFS), and copies no .esp/.esm/.esl/.bsa. Writes OUT/Data/... and OUT/manifest.json.
"""
import argparse, hashlib, json, os, subprocess, sys
import xml.etree.ElementTree as ET
from pathlib import Path

DEFAULT = ['30_Skyland - A Landscape Texture Overhaul\\Data\\', '110_Skyland Whiterun\\']
BAD = ('.esp', '.esm', '.esl', '.bsa', '.dll', '.exe', '.pex', '.bat', '.cmd', '.sh', '.py')

ap = argparse.ArgumentParser()
ap.add_argument('--src', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--select', action='append', help="source prefix as written in ModuleConfig.xml (backslashes), repeatable")
a = ap.parse_args()
src = Path(a.src).resolve(strict=True); out = Path(a.out).resolve()
sel = [s.lower() for s in (a.select or DEFAULT)]
text = (src / 'fomod/ModuleConfig.xml').read_bytes().decode('utf-16')
root = ET.fromstring(text.split('?>', 1)[1] if text.lstrip().startswith('<?xml') else text)
folders = []
for el in root.iter('folder'):
    s = (el.get('source') or ''); d = (el.get('destination') or '')
    if any(s.lower().startswith(p) for p in sel) and (s, d, el.get('priority')) not in folders:
        folders.append((s, d, el.get('priority')))
if not folders:
    sys.exit('no FOMOD folder entry matches the selection')
folders.sort(key=lambda f: int(f[2] or 0))      # low priority first, later wins on a clash
if out.exists() and any(out.iterdir()):
    sys.exit(f'{out} is not empty; remove it first (it is private and rebuildable)')
(out / 'Data').mkdir(parents=True, exist_ok=True)
done = []
for s, d, pr in folders:
    sp = src.joinpath(*s.split('\\'))
    # case-insensitive volume: resolve and require it stays inside src
    sp = sp.resolve(strict=True)
    if not sp.is_relative_to(src) or not sp.is_dir():
        sys.exit(f'refusing {s}')
    for dp, dn, fn in os.walk(sp):
        for n in dn + fn:
            p = Path(dp) / n
            if p.is_symlink():
                sys.exit(f'refusing symlink {p}')
        for n in fn:
            if n.lower().endswith(BAD):
                sys.exit(f'refusing {Path(dp)/n}: not a texture/mesh file')
    dst = out / 'Data' / Path(*d.split('\\')) if d else out / 'Data'
    dst.mkdir(parents=True, exist_ok=True)
    subprocess.run(['cp', '-cR', str(sp) + '/.', str(dst)], check=True)
    done.append(dict(source=s, destination=d, priority=pr))
for p in list((out / 'Data').rglob('*')):      # keep only what the game reads (drops the author's tool logs)
    if p.is_file() and p.suffix.lower() not in ('.dds', '.nif'):
        p.unlink()
files = sorted(p for p in (out / 'Data').rglob('*') if p.is_file())
h = hashlib.sha256()
for p in files:
    h.update(str(p.relative_to(out)).lower().encode()); h.update(str(p.stat().st_size).encode())
exts = {}
for p in files:
    exts[p.suffix.lower()] = exts.get(p.suffix.lower(), 0) + 1
man = dict(source_folders=done, file_count=len(files), bytes=sum(p.stat().st_size for p in files), extensions=exts,
           tree_digest_names_sizes=h.hexdigest(), note='private mod data; do not commit or redistribute')
(out / 'manifest.json').write_text(json.dumps(man, indent=1))
print(json.dumps(man, indent=1))
