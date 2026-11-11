#!/usr/bin/env python3
"""Mac-side mod pack tool for the Skyrim VR runtime: prepared mod folders + a mods list -> one pack.

  python3 -I tools/mods.py build  --list mods-list.json --out PACK [--force]
  python3 -I tools/mods.py show   PACK
  python3 -I tools/mods.py deploy PACK --bundle BUNDLE_ID [--device ID] [--yes]     (prints the devicectl commands; runs them only with --yes)

mods-list.json (written by hand or by a later UI):
  { "profile": "default",
    "mods": [ { "id": "skyland", "name": "Skyland AIO 1k", "kind": "files", "enabled": true, "priority": 10,
                "source": "build/private/mods/skyland-aio-1k-full",        # a prepared tree with Data/ (tools/fomod_auto.py), relative to the list
                "plugins": ["Lit Road Signs.esp"], "memory_hint_mb": 250, "note": "" },
              { "id": "higgs", "name": "HIGGS 1.10.10", "kind": "skse", "enabled": true, "priority": 40, "size_bytes": 5128085 } ] }
kind: files (loose assets), plugin (assets plus ESP/ESM/ESL; listed in plugins), skse (needs SKSE VR; listed, never applied).

PACK/ gets
  mods.json         the same list with what was done (active, size_bytes, files, path); read by tools/vxrt_native_startup.py --mods-config,
                    by the visionOS app (xros/app, read-only launcher section) and by the runtime's start-up log
  Plugins.txt       "*Name" lines (SE-style) for the active plugins in priority order; also at merged/Plugins.txt
  mods/<id>/Data/   each applied mod's own folder (APFS clone of its source)
  merged/Data/      all applied mods flattened in PRIORITY ORDER (higher priority wins a clash): the single overlay the runtime reads.
                    The runtime keeps its one overlay layer (files.c); priority is resolved here, on the Mac, by this flatten.
No toggling at run time: to change the set, edit the list and build again. Sources are only read; nothing from a download is executed.
"""
import argparse, json, os, re, shlex, struct, subprocess, sys
from pathlib import Path

OFFICIAL = {'skyrim.esm', 'update.esm', 'dawnguard.esm', 'hearthfires.esm', 'dragonborn.esm', 'skyrimvr.esm'}
REFUSE = ('.dll', '.exe', '.bat', '.cmd', '.sh', '.py', '.ps1', '.dylib', '.command')
KINDS = ('files', 'plugin', 'skse')
SKSE_NOTE = 'SKSE: configure on the Mac. Needs SKSE VR, which this runtime cannot load yet, so it is not applied.'


def masters(path):
    d = Path(path).read_bytes()[:4000]
    if d[:4] != b'TES4': raise ValueError(f'{path}: not a plugin (no TES4 record)')
    sz = struct.unpack('<I', d[4:8])[0]; i = 24; out = []
    while i < min(24 + sz, len(d)) - 6:
        t = d[i:i + 4]; s = struct.unpack('<H', d[i + 4:i + 6])[0]
        if t == b'MAST': out.append(d[i + 6:i + 6 + s].split(b'\0')[0].decode('latin1'))
        i += 6 + s
    return out


def tree_stats(root):
    n = size = 0
    for dp, dn, fn in os.walk(root):
        for x in dn + fn:
            if (Path(dp) / x).is_symlink(): raise ValueError(f'symlink in a mod source: {Path(dp) / x}')
        for f in fn:
            if f.lower().endswith(REFUSE): raise ValueError(f'refused file type in a mod source: {Path(dp) / f}')
            n += 1; size += (Path(dp) / f).stat().st_size
    return n, size


def clone(src, dst):
    dst.mkdir(parents=True, exist_ok=True)
    subprocess.run(['cp', '-cR', str(src) + '/.', str(dst)], check=True)


def build(a):
    lst = Path(a.list).resolve(strict=True); out = Path(a.out).resolve()
    cfg = json.loads(lst.read_text())
    if out.exists() and any(out.iterdir()):
        if not a.force: sys.exit(f'{out} is not empty (use --force to rebuild; it is private and rebuildable)')
        subprocess.run(['rm', '-rf', str(out)], check=True)
    mods = cfg['mods']; seen = set()
    for m in mods:
        if not re.fullmatch(r'[a-z0-9][a-z0-9._-]*', m.get('id', '')): sys.exit(f"bad id {m.get('id')!r}")
        if m['id'] in seen: sys.exit(f"duplicate id {m['id']}")
        seen.add(m['id'])
        if m.get('kind') not in KINDS: sys.exit(f"{m['id']}: kind must be one of {KINDS}")
        if not isinstance(m.get('priority'), int): sys.exit(f"{m['id']}: priority must be an integer")
    (out / 'merged' / 'Data').mkdir(parents=True)
    res = []; plugins = []
    for m in sorted(mods, key=lambda m: (m['priority'], m['id'])):
        r = dict(id=m['id'], name=m.get('name', m['id']), kind=m['kind'], enabled=bool(m.get('enabled', True)), priority=m['priority'],
                 plugins=list(m.get('plugins', [])), memory_hint_mb=m.get('memory_hint_mb'), size_bytes=m.get('size_bytes'), files=None,
                 active=False, path=None, note=m.get('note', ''))
        if m['kind'] == 'skse':
            r['note'] = r['note'] or SKSE_NOTE
        elif r['enabled']:
            if not m.get('source'): sys.exit(f"{m['id']}: kind {m['kind']} needs a source")
            src = (lst.parent / m['source']).resolve(strict=True)
            if not (src / 'Data').is_dir(): sys.exit(f"{m['id']}: {src} has no Data/")
            n, size = tree_stats(src / 'Data')
            clone(src / 'Data', out / 'mods' / m['id'] / 'Data')
            clone(src / 'Data', out / 'merged' / 'Data')          # in priority order, so a higher priority overwrites
            r.update(active=True, path=f"mods/{m['id']}", files=n, size_bytes=size)
            for p in r['plugins']:
                f = out / 'merged' / 'Data' / p
                if not f.is_file(): sys.exit(f"{m['id']}: plugin {p} is not at the top of its Data/")
                bad = [x for x in masters(f) if x.lower() not in OFFICIAL and x not in plugins]
                if bad: sys.exit(f'{m["id"]}: {p} needs masters that are not official or earlier in the load order: {bad}')
                if p not in plugins: plugins.append(p)
        else:
            r['note'] = r['note'] or 'disabled in the list'
        res.append(r)
    ptxt = ''.join(f'*{p}\r\n' for p in plugins)
    (out / 'Plugins.txt').write_text(ptxt, newline=''); (out / 'merged' / 'Plugins.txt').write_text(ptxt, newline='')
    act = [r for r in res if r['active']]
    doc = dict(version=1, profile=cfg.get('profile', 'default'), merged='merged', plugins_txt='Plugins.txt', plugins=plugins, mods=res,
               totals=dict(active_mods=len(act), active_files=sum(r['files'] for r in act), active_size_bytes=sum(r['size_bytes'] for r in act),
                           active_memory_hint_mb=sum(r['memory_hint_mb'] or 0 for r in act)))
    (out / 'mods.json').write_text(json.dumps(doc, indent=1))
    show(out)


def show(pack):
    d = json.loads((Path(pack) / 'mods.json').read_text())
    print(f"pack {pack}  profile {d['profile']}  version {d['version']}")
    for m in d['mods']:
        sz = f"{m['size_bytes'] / 1e6:.0f} MB" if m['size_bytes'] else '-'
        print(f"  {m['priority']:>4}  {m['id']:<14} {m['kind']:<7} enabled={str(m['enabled']):<5} active={str(m['active']):<5} {sz:>8}  {m['name']}" + (f"  [{m['note']}]" if m['note'] else ''))
    print('  plugins:', ', '.join(d['plugins']) or '(none)'); print('  totals:', d['totals'])


def deploy(a):
    pack = Path(a.pack).resolve(strict=True); d = json.loads((pack / 'mods.json').read_text())
    dev = ['--device', a.device] if a.device else ['--device', '<DEVICE>']
    base = ['xcrun', 'devicectl', 'device', 'copy', 'to', *dev, '--domain-type', 'appDataContainer', '--domain-identifier', a.bundle]
    root = 'Documents/root'
    steps = [(str(pack / 'mods.json'), f'{root}/mods.json'),
             (str(pack / 'Plugins.txt'), f'{root}/drive_c/users/vxrt/AppData/Local/Skyrim VR/Plugins.txt')]
    for e in sorted((pack / 'merged' / 'Data').iterdir()):
        steps.append((str(e), f'{root}/overlay_skyrimvr/Data/{e.name}'))
    cmds = [base + ['--source', s, '--destination', t] for s, t in steps]
    for c in cmds: print(' '.join(shlex.quote(x) for x in c))
    if not a.yes:
        print('(dry run: nothing copied; add --yes only with the user\'s authorization for the physical device)'); return
    if not a.device: sys.exit('--device is required with --yes')
    for c in cmds: subprocess.run(c, check=True)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build'); b.add_argument('--list', required=True); b.add_argument('--out', required=True); b.add_argument('--force', action='store_true')
    s = sub.add_parser('show'); s.add_argument('pack')
    p = sub.add_parser('deploy'); p.add_argument('pack'); p.add_argument('--bundle', required=True); p.add_argument('--device'); p.add_argument('--yes', action='store_true')
    a = ap.parse_args()
    {'build': build, 'show': lambda a: show(a.pack), 'deploy': deploy}[a.cmd](a)
