#!/usr/bin/env python3
"""Mac-side mod pack tool for the Skyrim VR runtime: prepared mod folders + a mods list -> one pack.

  python3 -I tools/mods.py build  [--list mods-list.json] --out PACK [--force]
  python3 -I tools/mods.py fetch  [--list mods-list.json] [--nxm nxm://...] [--force]     (Nexus entries only; a NEXUS_API_KEY is optional)
  Without --list: <VXRT_PRIVATE_ROOT>/mods-list.json if it exists, else the tracked default mods/default.json (names, versions, Nexus ids, md5s,
  load order, the SkyUI jit.off recipe; no mod files). Copy it to change the set.
  python3 -I tools/mods.py show   PACK
  python3 -I tools/mods.py deploy PACK --bundle BUNDLE_ID [--device ID] [--yes]     (prints the devicectl commands; runs them only with --yes)

mods-list.json (written by hand or by a later UI):
  { "profile": "default",
    "mods": [ { "id": "skyland", "name": "Skyland AIO 1k", "kind": "files", "enabled": true, "priority": 10,
                "source": "build/private/mods/skyland-aio-1k-full",        # a prepared tree with Data/ (tools/fomod_auto.py), relative to the list
                "plugins": ["Lit Road Signs.esp"], "memory_hint_mb": 250, "note": "" },
              { "id": "higgs", "name": "HIGGS 1.10.10", "kind": "skse", "enabled": true, "priority": 40, "size_bytes": 5128085 } ] }
A mod may instead name a Nexus Mods file: "nexus": {"game": "skyrimspecialedition", "mod_id": 43930, "file_id": 12345, "md5": "<pinned>"}
(no "source"). `mods.py fetch --list L [--nxm nxm://...]` downloads it through tools/nexus.py (with NEXUS_API_KEY; without a key, from the browser's Downloads folder), pins its md5 in the list, and unpacks it to <VXRT_PRIVATE_ROOT>/mods-src/<id>/ (a tree with Data/), which build then uses.
Other keys of an entry: "nexus.file_id" may be null when "nexus.md5" is pinned (the Downloads-folder fetch matches by md5); "install": {"data_root":
"Folder" (the archive's Data content is inside it), "exclude": [fnmatch patterns on Data-relative paths, e.g. "*.pdb"]}; "external": {url, file_name, md5,
extract: glob under the archive's top folder} for a mod that is not on Nexus (put the archive in <VXRT_PRIVATE_ROOT>/downloads or ~/Downloads; checked by md5);
"recipe": {"kind": "fomod_auto", "allow_plugins": [...]} (unpack a FOMOD by its own defaults) or {"kind": "skyui_nojit", "from": "<skyui mod id>"} (the LuaJIT-off overlay).
kind: files (loose assets), plugin (assets plus ESP/ESM/ESL; listed in plugins), skse (SKSE plugins: DLLs, ini, lua under Data/SKSE/Plugins, plus any ESP/scripts),
runtime (with "provides": "skse_core" and an "external" archive: the SKSE VR core DLL; it goes to PACK/overlay_root, never into Data/).
A skse mod may carry "aot": {"sweep": "1000-5200"} (options for the AOT module of its DLL, passed on by tools/skse_capture.py).
SKSE VR needs three private files at the app's overlay root: the core DLL (from the list's runtime entry, or "skse_runtime": {"core": PATH}), the stub module and
the capture of the plugins' code patches (made by `tools/vxrt_build.py skse-capture`, or "skse_runtime": {"hooks": PATH, "capture": PATH}). build copies them into
PACK/overlay_root; hooks and capture are only taken from skse-capture when it was made for exactly this plugin set.

PACK/ gets
  mods.json         the same list with what was done (active, size_bytes, files, path); read by tools/vxrt_native_startup.py --mods-config,
                    by the visionOS app (xros/app, read-only launcher section) and by the runtime's start-up log
  Plugins.txt       "*Name" lines (SE-style) for the active plugins in priority order; also at merged/Plugins.txt
  mods/<id>/Data/   each applied mod's own folder (APFS clone of its source)
  merged/Data/      all applied mods flattened in PRIORITY ORDER (higher priority wins a clash): the single overlay the runtime reads.
                    The runtime keeps its one overlay layer (files.c); priority is resolved here, on the Mac, by this flatten.
No toggling at run time: to change the set, edit the list and build again. Sources are only read; nothing from a download is executed.
"""
import argparse, hashlib, json, os, re, shlex, struct, subprocess, sys
from pathlib import Path

OFFICIAL = {'skyrim.esm', 'update.esm', 'dawnguard.esm', 'hearthfires.esm', 'dragonborn.esm', 'skyrimvr.esm'}
REFUSE = ('.dll', '.exe', '.bat', '.cmd', '.sh', '.py', '.ps1', '.dylib', '.command')
KINDS = ('files', 'plugin', 'skse', 'runtime')      # runtime: a private runtime file for the app (the SKSE core DLL), not a mod: never in Data/
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


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''): h.update(b)
    return h.hexdigest()


def tree_stats(root, skse=False):
    """(files, bytes). kind skse may carry .dll files, only under SKSE/Plugins/ of Data (the user's own plugin downloads, kept private;
    they are never run by this tool); every other refused type, and any .dll elsewhere, is still an error."""
    n = size = 0
    for dp, dn, fn in os.walk(root):
        for x in dn + fn:
            if (Path(dp) / x).is_symlink(): raise ValueError(f'symlink in a mod source: {Path(dp) / x}')
        rel = Path(dp).relative_to(root).parts
        in_plugins = skse and len(rel) >= 2 and rel[0].lower() == 'skse' and rel[1].lower() == 'plugins'
        for f in fn:
            if f.lower().endswith(REFUSE) and not (in_plugins and f.lower().endswith('.dll')):
                raise ValueError(f'refused file type in a mod source: {Path(dp) / f}')
            n += 1; size += (Path(dp) / f).stat().st_size
    return n, size


def skse_plugin_files(data):
    """Every file under Data/SKSE/Plugins: path relative to Data, sha256, size, and for a DLL its place in the pipeline."""
    out = []
    for dp, dn, fn in os.walk(data):
        rel = Path(dp).relative_to(data).parts
        if len(rel) >= 2 and rel[0].lower() == 'skse' and rel[1].lower() == 'plugins':
            for f in sorted(fn):
                p = Path(dp) / f
                out.append(dict(path='/'.join((*rel, f)), sha256=sha256(p), size=p.stat().st_size, dll=f.lower().endswith('.dll')))
    return sorted(out, key=lambda e: e['path'].lower())


def skse_plugin_set(skse_plugins, core_sha):
    """The identity of what an SKSE capture depends on: the core DLL and every file under Data/SKSE/Plugins (a plugin's ini can gate a code write),
    with the AOT options of its module. A capture is valid for exactly this set; any change needs `vxrt_build.py skse-capture` again."""
    items = sorted([e['path'].lower(), e['sha256'], json.dumps(e.get('aot') or {}, sort_keys=True)] for e in skse_plugins)
    return hashlib.sha256(json.dumps([core_sha, items]).encode()).hexdigest()


def skse_capture_files(plugin_set):
    """{'hooks': path, 'capture': path} of the last `vxrt_build.py skse-capture` when it was made for this plugin set, else {}."""
    d = private_root() / 'skse-capture'
    try: st = json.loads((d / 'state.json').read_text())
    except (OSError, ValueError): return {}
    if st.get('plugin_set') != plugin_set or not st.get('complete'): return {}
    got = {'hooks': d / 'vxrt_hooks.dll', 'capture': d / 'skse_capture.txt'}
    return got if all(p.is_file() for p in got.values()) else {}


def clone(src, dst):
    dst.mkdir(parents=True, exist_ok=True)
    subprocess.run(['cp', '-cR', str(src) + '/.', str(dst)], check=True)


def private_root():
    return Path(os.environ.get('VXRT_PRIVATE_ROOT') or Path(__file__).resolve().parent.parent / 'build' / 'private').expanduser().resolve()


def nexus_tree(mod_id):
    return private_root() / 'mods-src' / mod_id


REPO = Path(__file__).resolve().parent.parent
DEFAULT_LIST = REPO / 'mods' / 'default.json'      # tracked: the default mod set (manifest only: no mod files, no private paths)


def resolve_list(arg=None):
    """The mods list to use: --list if given, else the user's own list at <VXRT_PRIVATE_ROOT>/mods-list.json if there is one, else the tracked default."""
    if arg: return Path(arg)
    user = private_root() / 'mods-list.json'
    return user if user.is_file() else DEFAULT_LIST


def list_problems(cfg):
    """What is wrong with a mods list (shape only: nothing is read from disk or the network). Used by the default's test and by `check`."""
    out = []; seen = set(); prios = set()
    if not isinstance(cfg.get('mods'), list) or not cfg['mods']: return ['no mods']
    for m in cfg['mods']:
        i = m.get('id', '')
        if not re.fullmatch(r'[a-z0-9][a-z0-9._-]*', i): out.append(f'bad id {i!r}')
        if i in seen: out.append(f'duplicate id {i}')
        seen.add(i)
        if m.get('kind') not in KINDS: out.append(f'{i}: kind must be one of {KINDS}')
        if not isinstance(m.get('priority'), int): out.append(f'{i}: priority must be an integer')
        elif m['priority'] in prios: out.append(f'{i}: priority {m["priority"]} is used twice')
        else: prios.add(m['priority'])
        if not isinstance(m.get('enabled', True), bool): out.append(f'{i}: enabled must be true or false')
        for p in m.get('plugins', []):
            if not p.lower().endswith(('.esp', '.esm', '.esl')): out.append(f'{i}: plugin {p!r} is not an ESP/ESM/ESL')
        how = [k for k in ('source', 'nexus', 'external', 'recipe') if k in m]
        if 'nexus' in m:
            n = m['nexus']
            if not isinstance(n, dict) or not str(n.get('mod_id', '')).isdigit() or not n.get('game'): out.append(f'{i}: nexus needs game and a numeric mod_id')
            elif n.get('file_id') and not str(n['file_id']).isdigit(): out.append(f'{i}: nexus.file_id must be numeric')
            if isinstance(n, dict) and n.get('md5') and not re.fullmatch(r'[0-9a-f]{32}', str(n['md5'])): out.append(f'{i}: nexus.md5 must be 32 lowercase hex digits')
        if 'source' in m and 'nexus' in m: out.append(f'{i}: give either source or nexus, not both')
        if 'external' in m and not all(m['external'].get(k) for k in ('url', 'file_name', 'md5', 'extract')): out.append(f'{i}: external needs url, file_name, md5 and extract')
        inst = m.get('install') or {}
        if inst.get('data_root') and (os.path.isabs(inst['data_root']) or '..' in Path(inst['data_root']).parts): out.append(f'{i}: install.data_root must stay inside the archive')
        r = m.get('recipe')
        if r is not None and r.get('kind') not in ('fomod_auto', 'skyui_nojit'): out.append(f'{i}: recipe kind must be fomod_auto or skyui_nojit')
        if r and r.get('kind') == 'skyui_nojit' and r.get('from') not in {x.get('id') for x in cfg['mods']}: out.append(f'{i}: recipe.from names no mod of the list')
        if m.get('kind') == 'runtime' and (m.get('provides') != 'skse_core' or 'external' not in m): out.append(f'{i}: a runtime entry needs "provides": "skse_core" and an external archive')
        if m.get('enabled', True) and m['kind'] not in ('skse', 'runtime') and not any(k in m for k in ('source', 'nexus', 'external', 'recipe')): out.append(f'{i}: enabled but no source, nexus, external or recipe')
        text = json.dumps(m)
        if re.search(r'/Users/|/home/|\b[A-Za-z]:\\\\', text): out.append(f'{i}: contains a machine path')
    return out


def _nexus_spec(m):
    n = m['nexus']
    if not isinstance(n, dict) or not all(n.get(k) for k in ('game', 'mod_id')) or not (n.get('file_id') or n.get('md5')):
        sys.exit(f"{m.get('id')}: nexus needs game, mod_id and a file_id (or, without one, a pinned md5)")
    if not re.fullmatch(r'[A-Za-z0-9_-]+', str(n['game'])) or not re.fullmatch(r'\d+', str(n['mod_id'])) or (n.get('file_id') and not re.fullmatch(r'\d+', str(n['file_id']))):
        sys.exit(f"{m.get('id')}: bad nexus game/mod_id/file_id")
    if n.get('md5') and not re.fullmatch(r'[0-9a-fA-F]{32}', str(n['md5'])):
        sys.exit(f"{m.get('id')}: nexus md5 must be 32 hex digits")
    return n


def _unpack(archive, dst):
    """Extract an archive (zip with the standard library, anything else with bsdtar) into the empty dir dst, refusing paths that leave it and symlinks."""
    import zipfile
    dst.mkdir(parents=True)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            for i in z.infolist():
                t = (dst / i.filename).resolve()
                if dst.resolve() not in t.parents and t != dst.resolve(): raise ValueError(f'{archive}: path leaves the folder: {i.filename}')
                if (i.external_attr >> 16) & 0o170000 == 0o120000: raise ValueError(f'{archive}: symlink {i.filename}')
            z.extractall(dst)
    else:
        r = subprocess.run(['tar', '-xf', str(archive), '-C', str(dst)], capture_output=True, text=True)
        if r.returncode: raise ValueError(f'cannot unpack {archive} (.7z/.rar need macOS tar or `brew install libarchive`): {r.stderr.strip()[:200]}')
    for dp, dn, fn in os.walk(dst):
        for x in dn + fn:
            if (Path(dp) / x).is_symlink(): raise ValueError(f'{archive}: symlink in the archive: {Path(dp) / x}')


def _into_tree(raw, tree):
    """raw (an unpacked archive) -> tree/Data. An archive with Data/ at its top (or in its only folder) keeps it; a FOMOD installer needs tools/fomod_auto.py."""
    top = [p for p in raw.iterdir()]
    if len(top) == 1 and top[0].is_dir() and top[0].name.lower() != 'data' and not (top[0].name.lower() in ('fomod',)):
        inner = [q.name.lower() for q in top[0].iterdir()]
        if 'data' in inner or 'fomod' in inner: raw = top[0]; top = list(raw.iterdir())
    names = {p.name.lower(): p for p in top}
    if 'fomod' in names:
        raise ValueError(f'{raw} is a FOMOD installer: run tools/fomod_auto.py --src {raw} --out {tree} and give the mod a "source" instead')
    tree.mkdir(parents=True)
    if 'data' in names: clone(names['data'], tree / 'Data')
    else: clone(raw, tree / 'Data')                  # loose files at the top: they are the Data/ contents


def _prune(data, patterns):
    """Remove the files of data/ whose path (relative, lower case, '/') matches one of the fnmatch patterns (debug symbols, script sources), then empty folders."""
    import fnmatch
    if not patterns: return
    pats = [p.lower() for p in patterns]
    for dp, dn, fn in os.walk(data):
        for f in fn:
            rel = (Path(dp) / f).relative_to(data).as_posix().lower()
            if any(fnmatch.fnmatchcase(rel, p) for p in pats): (Path(dp) / f).unlink()
    for dp, dn, fn in sorted(os.walk(data), key=lambda t: -len(t[0])):
        if Path(dp) != data and not os.listdir(dp): os.rmdir(dp)


def _fomod(raw, tree, recipe):
    """raw (an unpacked FOMOD archive) -> tree/Data by tools/fomod_auto.py with the recipe's choices (data only; nothing from the download runs)."""
    top = list(raw.iterdir())
    if len(top) == 1 and top[0].is_dir() and (top[0] / 'fomod').is_dir(): raw = top[0]
    cmd = [sys.executable, '-I', str(Path(__file__).resolve().parent / 'fomod_auto.py'), '--src', str(raw), '--out', str(tree)]
    for p in recipe.get('allow_plugins', []): cmd += ['--allow-plugin', p]
    for c in recipe.get('choose', []): cmd += ['--choose', c]
    for c in recipe.get('skip_options', []): cmd += ['--skip-option', c]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def _tree_ok(m, tree):
    if m.get('kind') == 'runtime': return (tree / Path(m['external']['extract']).name).is_file()
    return (tree / 'Data').is_dir()


def _fetch_external(m, lst, wait=0):
    """A mod that is not on Nexus (SKSE VR's scripts): the archive named in m['external'] from the private downloads folder or the browser's
    Downloads folder, checked against its md5, then only the files matching m['external']['extract'] (a glob under the archive's top folder)."""
    import shutil, tempfile
    x = m['external']; tree = nexus_tree(m['id']); marker = tree / '.external-md5'
    if marker.is_file() and marker.read_text().strip() == x['md5'].lower() and _tree_ok(m, tree):
        print(f"{m['id']}: already fetched and unpacked (md5 {x['md5']})"); return False
    import nexus
    try: found = nexus.external_fetch(m.get('name') or m['id'], x['url'], x['file_name'], x['md5'], wait=wait)
    except nexus.Skipped as e:
        print(f"{m['id']}: {e}", file=sys.stderr); return None
    with tempfile.TemporaryDirectory() as t:
        raw = Path(t) / 'raw'; _unpack(found, raw)
        top = list(raw.iterdir()); base = top[0] if len(top) == 1 and top[0].is_dir() else raw
        files = [p for p in sorted(base.glob(x['extract'])) if p.is_file()]
        if not files: raise ValueError(f"{m['id']}: nothing in {found.name} matches {x['extract']}")
        if m.get('kind') == 'runtime' and len(files) != 1: raise ValueError(f"{m['id']}: expected one file for {x['extract']}, found {len(files)}")
        new = Path(t) / 'tree'
        for p in files:
            d = new / (Path(p.name) if m.get('kind') == 'runtime' else p.relative_to(base)); d.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(p, d)
        (new / '.external-md5').write_text(x['md5'].lower() + '\n')
        if tree.exists(): shutil.rmtree(tree)
        tree.parent.mkdir(parents=True, exist_ok=True); shutil.move(str(new), str(tree))
    return True


def fetch(a):
    """Download the Nexus files of a list, pin md5s in it, unpack to mods-src/<id>. Idempotent: nothing is fetched for a mod whose archive and tree match."""
    import shutil
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import nexus
    lst = resolve_list(a.list).resolve(strict=True); cfg = json.loads(lst.read_text())
    links = {}
    for u in a.nxm or []:
        try: n = nexus.parse_nxm(u)
        except nexus.NexusError as e: sys.exit(f'--nxm: {e}')
        links[(n['game'].lower(), n['mod_id'], n['file_id'])] = n
    changed = False; todo = 0; skipped = []
    pending = [m for m in cfg['mods'] if 'nexus' in m and m.get('enabled', True) and not m.get('source')
               and not (not a.force and (nexus_tree(m['id']) / '.nexus-md5').is_file() and (m['nexus'].get('md5') or '').lower() == (nexus_tree(m['id']) / '.nexus-md5').read_text().strip().lower() and (nexus_tree(m['id']) / 'Data').is_dir())]
    done = 0
    for m in cfg['mods']:
        if 'external' in m and m.get('enabled', True) and not m.get('source'):
            try: r = _fetch_external(m, lst, nexus.default_wait(a.wait))
            except (ValueError, OSError) as e: print(f"{m['id']}: {e}", file=sys.stderr); sys.exit(1)
            if r is None: skipped.append(m['id'])
            elif r: todo += 1; print(f"{m['id']}: unpacked {m['external']['extract']}")
            continue
        if 'nexus' not in m or not m.get('enabled', True) or m.get('source'): continue
        n = _nexus_spec(m); game, mod, fid = n['game'], str(n['mod_id']), (str(n['file_id']) if n.get('file_id') else None)
        tree = nexus_tree(m['id']); marker = tree / '.nexus-md5'
        pinned = (n.get('md5') or '').lower() or None
        if not a.force and marker.is_file() and pinned and marker.read_text().strip() == pinned and (tree / 'Data').is_dir():
            print(f"{m['id']}: already fetched and unpacked (md5 {pinned})"); continue
        todo += 1
        try:
            r = nexus.fetch_file(game, mod, fid, nxm=links.get((game.lower(), mod, fid)), md5=pinned, wait=nexus.default_wait(a.wait),
                                 progress=(done, len(pending)), name=m.get('name') or m['id'], manual=a.manual or fid is None, accept_name=a.accept_name_match)
            tmp = tree.with_name(tree.name + '.tmp')
            if tmp.exists(): shutil.rmtree(tmp)
            raw = tmp / 'raw'; _unpack(Path(r['path']), raw)
            new = tmp / 'tree'
            inst = m.get('install') or {}
            if (m.get('recipe') or {}).get('kind') == 'fomod_auto': _fomod(raw, new, m['recipe'])
            else: _into_tree(raw / inst['data_root'] if inst.get('data_root') else raw, new)
            _prune(new / 'Data', inst.get('exclude', []))
            (new / '.nexus-md5').write_text(r['md5'] + '\n')
            if tree.exists(): shutil.rmtree(tree)
            tree.parent.mkdir(parents=True, exist_ok=True); os.replace(new, tree); shutil.rmtree(tmp)
        except nexus.Skipped as e:
            print(f"{m['id']}: {e}", file=sys.stderr); skipped.append(m['id']); continue
        except nexus.NeedInput as e:
            print(f"{m['id']}: {e}", file=sys.stderr); sys.exit(2)
        except (nexus.NexusError, ValueError) as e:
            print(f"{m['id']}: {e}", file=sys.stderr); sys.exit(1)
        done += 1
        if pinned != r['md5']:
            n['md5'] = r['md5']; changed = True
            print(f"{m['id']}: pinned md5 {r['md5']} in {lst.name}")
    if changed:
        tmp = lst.with_name(lst.name + '.tmp'); tmp.write_text(json.dumps(cfg, indent=1) + '\n'); os.replace(tmp, lst)
    if skipped: print(f"fetch: skipped {', '.join(skipped)}; run it again when you have their nxm links", file=sys.stderr); sys.exit(2)
    print(f'fetch: {todo} mod(s) fetched, {sum(1 for m in cfg["mods"] if "nexus" in m)} nexus entr(ies) in the list')


def build(a):
    lst = resolve_list(a.list).resolve(strict=True); out = Path(a.out).resolve()
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
        if 'nexus' in m:
            _nexus_spec(m)
            if m.get('source'): sys.exit(f"{m['id']}: give either source or nexus, not both")
        if m.get('enabled', True) and not m.get('source') and any(k in m for k in ('nexus', 'external')) and not _tree_ok(m, nexus_tree(m['id'])):
            print(f"{m['id']}: not fetched yet: run tools/mods.py fetch --list {lst} (or vxrt_build.py mods-fetch)", file=sys.stderr); sys.exit(2)
    for m in mods:                                   # (generated mods: the SkyUI LuaJIT-off overlay, from the fetched SkyUI tree)
        r = m.get('recipe') or {}
        if m.get('enabled', True) and r.get('kind') == 'skyui_nojit':
            base = next((x for x in mods if x['id'] == r.get('from')), None)
            if not base: sys.exit(f"{m['id']}: recipe.from {r.get('from')!r} is not in the list")
            sdir = (lst.parent / base['source']).resolve(strict=True) if base.get('source') else nexus_tree(base['id'])
            tree = nexus_tree(m['id'])
            if tree.exists(): subprocess.run(['rm', '-rf', str(tree)], check=True)
            sys.path.insert(0, str(Path(__file__).resolve().parent)); import skyui_nojit
            skyui_nojit.main(str(sdir / 'Data'), str(tree))
    (out / 'merged' / 'Data').mkdir(parents=True)
    res = []; plugins = []; skse_plugins = []; shadow = []; runtime = {}
    for m in sorted(mods, key=lambda m: (m['priority'], m['id'])):
        r = dict(id=m['id'], name=m.get('name', m['id']), kind=m['kind'], enabled=bool(m.get('enabled', True)), priority=m['priority'],
                 plugins=list(m.get('plugins', [])), memory_hint_mb=m.get('memory_hint_mb'), size_bytes=m.get('size_bytes'), files=None,
                 active=False, path=None, note=m.get('note', ''))
        if r['enabled'] and not m.get('source') and any(k in m for k in ('nexus', 'external')) or (r['enabled'] and (m.get('recipe') or {}).get('kind') == 'skyui_nojit'):
            m = dict(m, source=str(nexus_tree(m['id'])))    # (absolute: joins as itself)
        if m['kind'] == 'runtime':
            if r['enabled']:                              # (the SKSE core DLL: copied to overlay_root below, never merged into Data/)
                f = nexus_tree(m['id']) / Path(m['external']['extract']).name
                r.update(active=True, path=f"runtime/{f.name}", files=1, size_bytes=f.stat().st_size)
                runtime[m['provides']] = f
            else: r['note'] = r['note'] or 'disabled in the list'
        elif m['kind'] == 'skse' and not m.get('source'):
            r['note'] = r['note'] or SKSE_NOTE          # (listed only: no prepared source tree)
        elif r['enabled']:
            if not m.get('source'): sys.exit(f"{m['id']}: kind {m['kind']} needs a source")
            src = (lst.parent / m['source']).resolve(strict=True)
            if not (src / 'Data').is_dir(): sys.exit(f"{m['id']}: {src} has no Data/")
            n, size = tree_stats(src / 'Data', skse=m['kind'] == 'skse')
            clone(src / 'Data', out / 'mods' / m['id'] / 'Data')
            clone(src / 'Data', out / 'merged' / 'Data')          # in priority order, so a higher priority overwrites
            r.update(active=True, path=f"mods/{m['id']}", files=n, size_bytes=size)
            if m.get('shadow_install'):                      # (this mod's files may replace loose files of the install: SKSE's own .pex scripts)
                r['shadow_install'] = True
                shadow.extend(str(q.relative_to(src / 'Data')).replace(os.sep, '/') for q in sorted((src / 'Data').rglob('*')) if q.is_file())
            if m['kind'] == 'skse':
                for e in skse_plugin_files(src / 'Data'):
                    e['mod'] = m['id']
                    if m.get('aot'): e['aot'] = m['aot']
                    same = [x for x in skse_plugins if x['path'].lower() == e['path'].lower()]
                    if same:                                  # (a higher priority replaces the file in the merged tree: the list says what is there)
                        e['replaces_mod'] = same[0]['mod']
                        if same[0]['dll']: e['module_base'] = same[0]['module_base']
                        skse_plugins[skse_plugins.index(same[0])] = e
                        continue
                    if e['dll']:
                        e['module_base'] = '0x%x' % (int(a.plugin_base, 16) + 0x1000000 * sum(1 for x in skse_plugins if x['dll']))
                    skse_plugins.append(e)
            for p in r['plugins']:
                f = out / 'merged' / 'Data' / p
                if not f.is_file(): sys.exit(f"{m['id']}: plugin {p} is not at the top of its Data/")
                bad = [x for x in masters(f) if x.lower() not in OFFICIAL and x not in plugins]
                if bad: sys.exit(f'{m["id"]}: {p} needs masters that are not official or earlier in the load order: {bad}')
                if p not in plugins: plugins.append(p)
        else:
            r['note'] = r['note'] or 'disabled in the list'
        res.append(r)
    # SKSE VR itself: the core DLL, the stub module and the capture the AOT modules were made from, at the root of the overlay (the app
    # preloads them: xros/app main.m skyrimvr_start). The core comes from the list's runtime entry (the SKSE archive, fetched), or from
    # "skse_runtime" in the list; the stub module and the capture from "skse_runtime" or from `vxrt_build.py skse-capture` when that was made for this
    # exact plugin set. Private files, hashed here.
    root_files = []
    rt = {k: Path(v) for k, v in (cfg.get('skse_runtime') or {}).items()}
    core = rt.get('core') or runtime.get('skse_core')
    if skse_plugins and core:
        made = skse_capture_files(skse_plugin_set(skse_plugins, sha256(core)))
        for k in ('hooks', 'capture'):
            if k not in rt and k in made: rt[k] = made[k]
    if core or rt:
        rt['core'] = core
        (out / 'overlay_root').mkdir()
        for want, name in (('core', 'sksevr_1_4_15.dll'), ('hooks', 'vxrt_hooks.dll'), ('capture', 'skse_capture.txt')):
            if not rt.get(want): continue
            src = Path(rt[want]).resolve(strict=True)
            subprocess.run(['cp', '-c', str(src), str(out / 'overlay_root' / name)], check=True)
            root_files.append(dict(name=name, sha256=sha256(out / 'overlay_root' / name), size=src.stat().st_size))
    ptxt = ''.join(f'*{p}\r\n' for p in plugins)
    (out / 'Plugins.txt').write_text(ptxt, newline=''); (out / 'merged' / 'Plugins.txt').write_text(ptxt, newline='')
    act = [r for r in res if r['active']]
    doc = dict(version=1, profile=cfg.get('profile', 'default'), merged='merged', plugins_txt='Plugins.txt', plugins=plugins, mods=res,
               skse_plugins=skse_plugins, skse_plugin_set=skse_plugin_set(skse_plugins, next((f['sha256'] for f in root_files if f['name'] == 'sksevr_1_4_15.dll'), '')) if skse_plugins else None, shadow_install=shadow, overlay_root_files=root_files,
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
    for e in d.get('skse_plugins', []):
        print(f"  skse  {e['path']:<48} {e['sha256'][:12]}  {e['size']:>9}" + (f"  module {e['module_base']}" if e.get('module_base') else ''))
    print('  plugins:', ', '.join(d['plugins']) or '(none)'); print('  totals:', d['totals'])


def pipeline(a):
    """Append the pack's SKSE plugin DLLs to a tools/skyrim_aot_pipeline.py config (dlls: path, sha256, base), so one pack feeds the
    overlay (mods.json, merged/Data) and the AOT module set. Idempotent: earlier entries from this pack are replaced."""
    pack = Path(a.pack).resolve(strict=True); d = json.loads((pack / 'mods.json').read_text())
    cfg = json.loads(Path(a.config).read_text())
    mine = {str((pack / 'merged' / 'Data' / e['path'])) for e in d.get('skse_plugins', []) if e['dll']}
    cfg['dlls'] = [x for x in cfg['dlls'] if x['path'] not in mine]
    for e in d.get('skse_plugins', []):
        if e['dll']:
            p = pack / 'merged' / 'Data' / e['path']
            if sha256(p) != e['sha256']: sys.exit(f'{p} changed since the pack was built')
            cfg['dlls'].append(dict(path=str(p), sha256=e['sha256'], base=e['module_base'], **(e.get('aot') or {})))
    Path(a.out).write_text(json.dumps(cfg, indent=1)); print(f"{a.out}: {sum(1 for e in d.get('skse_plugins', []) if e['dll'])} plugin DLLs added")


def deploy(a):
    pack = Path(a.pack).resolve(strict=True); d = json.loads((pack / 'mods.json').read_text())
    dev = ['--device', a.device] if a.device else ['--device', '<DEVICE>']
    base = ['xcrun', 'devicectl', 'device', 'copy', 'to', *dev, '--domain-type', 'appDataContainer', '--domain-identifier', a.bundle]
    root = 'Documents/root'
    steps = [(str(pack / 'mods.json'), f'{root}/mods.json'),
             (str(pack / 'Plugins.txt'), f'{root}/drive_c/users/vxrt/AppData/Local/Skyrim VR/Plugins.txt')]
    for e in sorted((pack / 'merged' / 'Data').iterdir()):
        steps.append((str(e), f'{root}/overlay_skyrimvr/Data/{e.name}'))
    for f in d.get('overlay_root_files', []):
        steps.append((str(pack / 'overlay_root' / f['name']), f"{root}/overlay_skyrimvr/{f['name']}"))
    cmds = [base + ['--source', s, '--destination', t] for s, t in steps]
    for c in cmds: print(' '.join(shlex.quote(x) for x in c))
    if not a.yes:
        print('(dry run: nothing copied; add --yes only with the user\'s authorization for the physical device)'); return
    if not a.device: sys.exit('--device is required with --yes')
    for c in cmds: subprocess.run(c, check=True)


if __name__ == '__main__':
    ap = argparse.ArgumentParser(); sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build'); b.add_argument('--plugin-base', default='0x30c000000', help='arena base of the first SKSE plugin DLL module; 16 MB apart'); b.add_argument('--list', help='default: <VXRT_PRIVATE_ROOT>/mods-list.json if it exists, else mods/default.json'); b.add_argument('--out', required=True); b.add_argument('--force', action='store_true')
    f = sub.add_parser('fetch'); f.add_argument('--list', help='default: as for build'); f.add_argument('--nxm', action='append', help='nxm:// link from the website (non-premium); repeatable'); f.add_argument('--force', action='store_true'); f.add_argument('--manual', action='store_true', help='download in the browser and take the archive from the Downloads folder even if NEXUS_API_KEY is set'); f.add_argument('--accept-name-match', action='store_true', help='without a terminal: accept an archive whose name carries the mod id'); f.add_argument('--wait', type=int, help='seconds to wait per file for its nxm link without Premium (default 600 in a terminal, else 0)')
    s = sub.add_parser('show'); s.add_argument('pack')
    q = sub.add_parser('pipeline'); q.add_argument('pack'); q.add_argument('--config', required=True); q.add_argument('--out', required=True)
    p = sub.add_parser('deploy'); p.add_argument('pack'); p.add_argument('--bundle', required=True); p.add_argument('--device'); p.add_argument('--yes', action='store_true')
    a = ap.parse_args()
    {'build': build, 'fetch': fetch, 'show': lambda a: show(a.pack), 'pipeline': pipeline, 'deploy': deploy}[a.cmd](a)
