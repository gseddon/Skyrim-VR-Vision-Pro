#!/usr/bin/env python3 -I
"""tools/mods.py: the tracked default mod list (mods/default.json) is well formed, is what mods.py uses when there is no user list, and
builds into the same priority order / load order as the build installed on 2026-11-11 (from stand-in trees: no mod file is needed)."""
import json, os, struct, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import mods

DEFAULT = ROOT / 'mods' / 'default.json'
cfg = json.loads(DEFAULT.read_text())
assert mods.DEFAULT_LIST == DEFAULT and DEFAULT.is_file()
assert mods.list_problems(cfg) == [], mods.list_problems(cfg)
ids = [m['id'] for m in sorted(cfg['mods'], key=lambda m: m['priority'])]
assert ids == ['skyland', 'sksevr-scripts', 'skse-core', 'skyrimvrtools', 'higgs', 'planck', 'skyui-vr', 'skyui-vr-nojit', 'vrik', 'modlist-dump'], ids
by = {m['id']: m for m in cfg['mods']}
assert [p for m in sorted(cfg['mods'], key=lambda m: m['priority']) if m.get('enabled', True) for p in m.get('plugins', [])] == \
    ['Lit Road Signs.esp', 'Skyland Watercolor - Slow Green-Vanilla.esp', 'higgs_vr.esp', 'SkyUI_SE.esp', 'vrik.esp']
assert by['modlist-dump']['enabled'] is False and by['skyui-vr-nojit']['priority'] == by['skyui-vr']['priority'] + 1
assert by['skyui-vr-nojit']['recipe'] == dict(by['skyui-vr-nojit']['recipe'], kind='skyui_nojit', **{'from': 'skyui-vr'})
for m in cfg['mods']:
    if 'nexus' in m:
        assert m['nexus']['game'] and str(m['nexus']['mod_id']).isdigit() and len(m['nexus']['md5']) == 32, m['id']
        mods._nexus_spec(m)                                    # (an unrecorded file_id is allowed when the md5 is pinned)
text = DEFAULT.read_text()
assert '/Users/' not in text and 'op://' not in text and '.dll' not in text.lower().replace('core dll', '').replace('sksevr_1_4_15.dll', '')   # (the core DLL is named, never shipped)
# the shape check refuses what it should
bad = json.loads(text); bad['mods'][1]['priority'] = bad['mods'][0]['priority']; bad['mods'][2]['source'] = '/Users/x/mods'
assert len(mods.list_problems(bad)) >= 2

with tempfile.TemporaryDirectory() as t:
    t = Path(t).resolve(); priv = t / 'private'; priv.mkdir()
    env = dict(os.environ, VXRT_PRIVATE_ROOT=str(priv))
    os.environ['VXRT_PRIVATE_ROOT'] = str(priv)
    assert mods.resolve_list() == DEFAULT                          # no user list: the tracked default
    assert mods.resolve_list(str(t / 'x.json')) == t / 'x.json'    # --list wins
    (priv / 'mods-list.json').write_text('{"mods": []}')
    assert mods.resolve_list() == priv / 'mods-list.json'          # a user list beats the default
    (priv / 'mods-list.json').unlink()

    def run(*a): return subprocess.run([sys.executable, '-I', str(ROOT / 'tools/mods.py'), *a], env=env, capture_output=True, text=True)
    r = run('build', '--out', str(t / 'pack'))                      # nothing fetched yet: the CLI read the default and says what is missing
    assert r.returncode == 2 and 'not fetched yet' in r.stderr and 'default.json' in r.stderr, (r.returncode, r.stderr)

    tes4 = b'TES4' + struct.pack('<I', 0) + b'\0' * 16
    def tree(i, files):
        for rel, data in files.items():
            p = priv / 'mods-src' / i / 'Data' / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)
    tree('skyland', {'textures/a.dds': b'x', 'Lit Road Signs.esp': tes4, 'Skyland Watercolor - Slow Green-Vanilla.esp': tes4})
    tree('sksevr-scripts', {'Scripts/Actor.pex': b'x'})
    (priv / 'mods-src' / 'skse-core').mkdir(parents=True); (priv / 'mods-src' / 'skse-core' / 'sksevr_1_4_15.dll').write_bytes(b'MZ core')
    tree('skyrimvrtools', {'SKSE/Plugins/vrtools.ini': b'x'})
    tree('higgs', {'SKSE/Plugins/higgs.ini': b'x', 'higgs_vr.esp': tes4})
    tree('planck', {'SKSE/Plugins/planck.ini': b'x'})
    tree('skyui-vr', {'SKSE/Plugins/SkyUI-VR/MainEntry.lua': b'return 1\n', 'SkyUI_SE.esp': tes4})
    tree('vrik', {'SKSE/Plugins/vrik.ini': b'x', 'vrik.esp': tes4})
    r = run('build', '--out', str(t / 'pack'))
    assert r.returncode == 0, r.stderr
    doc = json.loads((t / 'pack/mods.json').read_text())
    assert doc['profile'] == 'default' and doc['plugins'] == ['Lit Road Signs.esp', 'Skyland Watercolor - Slow Green-Vanilla.esp', 'higgs_vr.esp', 'SkyUI_SE.esp', 'vrik.esp'], doc['plugins']
    act = [m['id'] for m in doc['mods'] if m['active']]
    assert act == ids[:-1], act
    lua = (t / 'pack/merged/Data/SKSE/Plugins/SkyUI-VR/MainEntry.lua').read_bytes()
    assert b'jit.off()' in lua and lua.endswith(b'return 1\n')         # the jit.off overlay won over SkyUI's own file
    e = [x for x in doc['skse_plugins'] if x['path'].lower().endswith('mainentry.lua')]
    assert len(e) == 1 and e[0]['mod'] == 'skyui-vr-nojit' and e[0]['replaces_mod'] == 'skyui-vr', e
    assert doc['shadow_install'] == ['Scripts/Actor.pex']

    import hashlib, nexus                                          # no file_id recorded: the Downloads-folder path matches by the pinned md5
    dl = t / 'dl'; dl.mkdir(); (dl / 'HIGGS-43930-1-10-10-1.zip').write_bytes(b'archive')
    got = nexus.manual_fetch('skyrimspecialedition', '43930', None, md5=hashlib.md5(b'archive').hexdigest(), folder=dl)
    assert got['md5'] == hashlib.md5(b'archive').hexdigest() and got['verified_by'] == 'pinned md5' and Path(got['path']).is_file(), got

    # the SKSE core comes from the list's runtime entry; hooks and capture only when skse-capture was made for exactly this plugin set
    assert [f['name'] for f in doc['overlay_root_files']] == ['sksevr_1_4_15.dll'] and doc['skse_plugin_set'], doc['overlay_root_files']
    assert (t / 'pack/overlay_root/sksevr_1_4_15.dll').read_bytes() == b'MZ core' and not (t / 'pack/merged/Data/sksevr_1_4_15.dll').exists()
    assert [m['kind'] for m in doc['mods'] if m['id'] == 'skse-core'] == ['runtime']
    sk = priv / 'skse-capture'; sk.mkdir()
    (sk / 'vxrt_hooks.dll').write_bytes(b'hooks'); (sk / 'skse_capture.txt').write_text('P x 0 00\n')
    (sk / 'state.json').write_text(json.dumps({'plugin_set': 'some other set', 'complete': True}))
    r = run('build', '--out', str(t / 'pack2')); assert r.returncode == 0, r.stderr
    assert [f['name'] for f in json.loads((t / 'pack2/mods.json').read_text())['overlay_root_files']] == ['sksevr_1_4_15.dll']      # stale: not taken
    (sk / 'state.json').write_text(json.dumps({'plugin_set': doc['skse_plugin_set'], 'complete': True}))
    r = run('build', '--out', str(t / 'pack3')); assert r.returncode == 0, r.stderr
    assert sorted(f['name'] for f in json.loads((t / 'pack3/mods.json').read_text())['overlay_root_files']) == ['skse_capture.txt', 'sksevr_1_4_15.dll', 'vxrt_hooks.dll']
    other = json.loads((t / 'pack3/mods.json').read_text())['skse_plugins']; other[0]['sha256'] = '0' * 64
    assert mods.skse_plugin_set(other, 'c') != mods.skse_plugin_set(json.loads((t / 'pack3/mods.json').read_text())['skse_plugins'], 'c')   # a changed plugin file is a new set

    # an archive that is not on Nexus is found by its md5 under any file name, in the downloads folders
    ext = t / 'extdl'; ext.mkdir(); (ext / 'sksevr_2_00_12 (1).7z').write_bytes(b'skse archive'); import time
    time.sleep(2)
    got = nexus.external_fetch('SKSE', 'https://example.invalid/x.7z', 'sksevr_2_00_12.7z', hashlib.md5(b'skse archive').hexdigest(), folders=[t / 'none', ext])
    assert got.name == 'sksevr_2_00_12 (1).7z'
    try: nexus.external_fetch('SKSE', 'https://example.invalid/x.7z', 'sksevr_2_00_12.7z', '0' * 32, folders=[ext]); raise SystemExit('should have been skipped')
    except nexus.Skipped: pass

    d = t / 'prune/Data'; (d / 'SKSE/Plugins').mkdir(parents=True); (d / 'Source/Scripts').mkdir(parents=True)
    for rel in ('SKSE/Plugins/a.dll', 'SKSE/Plugins/a.pdb', 'Source/Scripts/a.psc', '.gitignore'): (d / rel).write_text('x')
    mods._prune(d, by['higgs']['install']['exclude'])
    assert sorted(str(p.relative_to(d)) for p in d.rglob('*') if p.is_file()) == ['SKSE/Plugins/a.dll'] and not (d / 'Source').exists()
print('mods_default_test: ok')
