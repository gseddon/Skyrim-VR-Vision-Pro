#!/usr/bin/env python3 -I
"""tools/mods.py: a higher-priority mod that replaces a file of a skse mod (tools/skyui_nojit.py's MainEntry.lua) is listed once in
skse_plugins, with the winning hash, and the merged tree holds the winner."""
import hashlib, json, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import skyui_nojit
with tempfile.TemporaryDirectory(dir=ROOT / 'build') as t:
    t = Path(t)
    sk = t / 'skyui/Data/SKSE/Plugins/SkyUI-VR'; sk.mkdir(parents=True)
    orig = b'function f() return 1 end\n'
    (sk / 'MainEntry.lua').write_bytes(orig); (sk / 'inspect.lua').write_bytes(b'return {}\n')
    skyui_nojit.main(str(t / 'skyui/Data'), str(t / 'nojit'))
    (t / 'list.json').write_text(json.dumps({'mods': [
        {'id': 'skyui-vr', 'kind': 'skse', 'priority': 50, 'source': 'skyui'},
        {'id': 'skyui-vr-nojit', 'kind': 'skse', 'priority': 51, 'source': 'nojit'}]}))
    subprocess.run([sys.executable, '-I', str(ROOT / 'tools/mods.py'), 'build', '--list', str(t / 'list.json'), '--out', str(t / 'pack')], check=True, stdout=subprocess.DEVNULL)
    doc = json.loads((t / 'pack/mods.json').read_text())
    entries = [e for e in doc['skse_plugins'] if e['path'].lower().endswith('mainentry.lua')]
    merged = (t / 'pack/merged/Data/SKSE/Plugins/SkyUI-VR/MainEntry.lua').read_bytes()
    assert len(entries) == 1, entries
    assert entries[0]['mod'] == 'skyui-vr-nojit' and entries[0]['replaces_mod'] == 'skyui-vr', entries
    assert entries[0]['sha256'] == hashlib.sha256(merged).hexdigest()
    assert merged.startswith(b'-- vxrt:') and b'jit.off()' in merged.split(b'\n')[1] and merged.endswith(orig)
    assert len([e for e in doc['skse_plugins'] if e['path'].lower().endswith('inspect.lua')]) == 1
print('mods_override_test: ok')
