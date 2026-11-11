#!/usr/bin/env python3
"""Apply a FOMOD installer's choices automatically into a private loose-file Data tree (APFS clones).

  python3 -I tools/fomod_auto.py --src "<extracted mod folder>" --out build/private/mods/<name> \
      [--choose "Group name=Option name" ...] [--skip-option "Group name=Option name" ...] \
      [--allow-plugin "File.esp" ...] [--keep-le-nifs]

Rules (the installer's own defaults, everything else on):
  * SelectAll and SelectAny groups: every option is installed (minus --skip-option).
  * SelectExactlyOne / SelectAtMostOne groups: the option given by --choose, else the one with a Recommended/Required type,
    else the FIRST option (the one a FOMOD wizard preselects).
  * Plugins (.esp/.esm/.esl/.bsa) are copied only when named with --allow-plugin AND the ESP's TES4 masters are all official
    Skyrim masters; anything else is refused.  .dll/.exe/scripts are always refused.
  * Skyrim LE-format meshes (NIF user version 2 = 83) are removed unless --keep-le-nifs; they are listed in manifest.json.
The download is untrusted data: this only parses fomod/ModuleConfig.xml as XML and copies files named by it (no symlinks, no
paths leaving --src); nothing from the download is executed.  Writes OUT/Data/... and OUT/manifest.json.
"""
import argparse, json, os, struct, subprocess, sys, hashlib
import xml.etree.ElementTree as ET
from pathlib import Path

OFFICIAL = {'skyrim.esm', 'update.esm', 'dawnguard.esm', 'hearthfires.esm', 'dragonborn.esm', 'skyrimvr.esm'}
REFUSE = ('.dll', '.exe', '.pex', '.bat', '.cmd', '.sh', '.py', '.ps1', '.psc')
ap = argparse.ArgumentParser()
ap.add_argument('--src', required=True); ap.add_argument('--out', required=True)
ap.add_argument('--choose', action='append', default=[]); ap.add_argument('--skip-option', action='append', default=[])
ap.add_argument('--allow-plugin', action='append', default=[]); ap.add_argument('--keep-le-nifs', action='store_true')
a = ap.parse_args()
src = Path(a.src).resolve(strict=True); out = Path(a.out).resolve()
if out.exists() and any(out.iterdir()):
    sys.exit(f'{out} is not empty; remove it first (private and rebuildable)')
text = (src / 'fomod/ModuleConfig.xml').read_bytes().decode('utf-16')
root = ET.fromstring(text.split('?>', 1)[1] if text.lstrip().startswith('<?xml') else text)
choose = dict(s.split('=', 1) for s in a.choose); skip = set(a.skip_option); allow = {p.lower() for p in a.allow_plugin}

def masters(path):
    d = path.read_bytes()[:4000]; sz = struct.unpack('<I', d[4:8])[0]; i = 24; m = []
    while i < min(24 + sz, len(d)) - 6:
        t = d[i:i + 4]; s = struct.unpack('<H', d[i + 4:i + 6])[0]
        if t == b'MAST': m.append(d[i + 6:i + 6 + s].split(b'\0')[0].decode('latin1').lower())
        i += 6 + s
    return m

selected = []   # (group, option, [entries])
for step in root.iter('installStep'):
    for g in step.iter('group'):
        gname, gtype = g.get('name'), g.get('type')
        plugs = list(g.iter('plugin'))
        if gtype in ('SelectAll', 'SelectAny'):
            pick = [p for p in plugs if f"{gname}={p.get('name')}" not in skip]
        else:
            want = choose.get(gname)
            pick = [p for p in plugs if p.get('name') == want] if want else []
            if not pick:
                rec = [p for p in plugs if (p.find('typeDescriptor/type') is not None and p.find('typeDescriptor/type').get('name') in ('Recommended', 'Required'))]
                pick = (rec or plugs)[:1]
            pick = [p for p in pick if f"{gname}={p.get('name')}" not in skip]
        for p in pick:
            selected.append((gname, p.get('name'), list(p.findall('files/*'))))

def cp(sp, dp):
    dp.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['cp', '-c', str(sp), str(dp)], check=True)

(out / 'Data').mkdir(parents=True)
log = []; refused = []; plugins = []
for gname, oname, entries in selected:
    for e in entries:
        s, d = e.get('source') or '', e.get('destination') or ''
        sp = src.joinpath(*s.split('\\')).resolve(strict=True)
        if not sp.is_relative_to(src): sys.exit(f'refusing {s}')
        if sp.is_symlink(): sys.exit(f'refusing symlink {sp}')
        dest = out / 'Data' / Path(*[x for x in d.split('\\') if x]) if d else out / 'Data'
        if e.tag == 'file':
            if not sp.is_file(): sys.exit(f'not a file: {s}')
            if not d: dest = out / 'Data' / sp.name
            files = [(sp, dest)]
        else:
            files = []
            for dp, dn, fn in os.walk(sp):
                for n in dn + fn:
                    if (Path(dp) / n).is_symlink(): sys.exit(f'refusing symlink {Path(dp)/n}')
                for n in fn:
                    files.append((Path(dp) / n, dest / Path(dp).relative_to(sp) / n))
        for f, t in files:
            low = f.name.lower()
            if low.endswith(REFUSE): refused.append((str(f.relative_to(src)), 'refused type')); continue
            if low.endswith(('.esp', '.esm', '.esl', '.bsa')):
                if low not in allow: refused.append((str(f.relative_to(src)), 'plugin not allowed')); continue
                if low.endswith(('.esp', '.esm', '.esl')) and not set(masters(f)) <= OFFICIAL:
                    refused.append((str(f.relative_to(src)), 'masters not all official: ' + ','.join(masters(f)))); continue
                plugins.append(t.name)
            elif not low.endswith(('.dds', '.nif', '.tri', '.png')):
                refused.append((str(f.relative_to(src)), 'not a game asset')); continue
            cp(f, t)
        log.append(dict(group=gname, option=oname, source=s, destination=d, files=len(files)))

le = []
if not a.keep_le_nifs:
    for p in sorted((out / 'Data').rglob('*')):
        if p.is_file() and p.suffix.lower() == '.nif':
            h = p.read_bytes()[:120]; i = h.index(b'\n') + 1
            if struct.unpack('<I', h[i + 13:i + 17])[0] == 83:
                le.append(str(p.relative_to(out / 'Data'))); p.unlink()
files = sorted(p for p in (out / 'Data').rglob('*') if p.is_file())
dig = hashlib.sha256()
for p in files: dig.update(str(p.relative_to(out)).lower().encode()); dig.update(str(p.stat().st_size).encode())
ext = {}
for p in files: ext[p.suffix.lower()] = ext.get(p.suffix.lower(), 0) + 1
man = dict(choices=[(g, o) for g, o, _ in selected], applied=log, plugins=plugins, le_nifs_removed=le, refused=refused,
           file_count=len(files), bytes=sum(p.stat().st_size for p in files), extensions=ext, tree_digest_names_sizes=dig.hexdigest(),
           note='private mod data; do not commit or redistribute')
(out / 'manifest.json').write_text(json.dumps(man, indent=1))
print(json.dumps({k: man[k] for k in ('plugins', 'file_count', 'bytes', 'extensions')}, indent=1)); print('LE nifs removed:', len(le)); print('refused:', len(refused))
for r in refused[:12]: print('  ', r)
