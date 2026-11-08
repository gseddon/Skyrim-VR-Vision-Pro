#!/usr/bin/env python3
"""Run the owned MSVC D3D11/xrizer stereo fixture in strict AOT."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess

p = argparse.ArgumentParser(description=__doc__)
for option in ('runtime', 'exe', 'aot-dir', 'xrizer-dylib', 'out'):
    p.add_argument('--' + option, required=True, type=Path)
a = p.parse_args()
runtime, exe, modules, library = (x.resolve(strict=True) for x in (a.runtime, a.exe, a.aot_dir, a.xrizer_dylib))
out = a.out.resolve(); out.mkdir(parents=True, exist_ok=False)
inputs = [runtime, exe, library, *sorted(modules.glob('*.dylib'))]
assert len(inputs) > 3, 'missing AOT modules'
hashes = {str(x): hashlib.sha256(x.read_bytes()).hexdigest() for x in inputs}
(out / 'identities.json').write_text(json.dumps(hashes, indent=2) + '\n')
env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_', 'XDG_'))}
env.update(VXRT_ROOT=str(out/'root'), VXRT_AOT_DIR=str(modules), VXRT_AOT_STRICT='1', VXRT_NO_WINE='1',
           VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1', VXRT_ABI_XRIZER_DYLIB=str(library),
           XDG_STATE_HOME=str(out/'state'), XDG_CONFIG_HOME=str(out/'config'))
command = ['/usr/bin/arch', '-arm64', str(runtime), str(exe)]
with (out/'runtime.log').open('wb') as f:
    proc = subprocess.Popen(command, cwd=exe.parent, env=env, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
    try: rc = proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL); proc.wait(); rc = -1
(out/'process.json').write_text(json.dumps({'command': command, 'returncode': rc,
    'env': {k:v for k,v in env.items() if k.startswith(('VXRT_', 'XDG_'))},
    'scope': 'owned Windows guest, injected Mac provider; no headset or Skyrim'}, indent=2)+'\n')
text=(out/'runtime.log').read_text()
assert rc == 0, f'guest exited {rc}'
assert 'xrizer_guest_stereo: real D3D11 two changing stereo pairs -> ok' in text
queues=re.findall(r'producer queue (0x[0-9a-f]+) provider queue (0x[0-9a-f]+) checked complete',text)
assert len(queues)==4 and all(a != b for a,b in queues), 'missing distinct, completed producer queues'
assert len(re.findall(r'destination copy eye [01] GPU complete',text))==4
assert text.count('injected producer status failure (test control)')==1
assert 'active-lease destroy refused; external wrapper rejected' in text
leases=re.findall(r'leases (\d+)/(\d+) copies (\d+) frame (\d+) pose (\d+)', text)
assert len(leases)==2 and all(int(a)>0 and a==b for a,b,_,_,_ in leases)
assert [tuple(map(int, x[2:])) for x in leases]==[(2,101,201),(4,102,202)]
summary=re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator',text)
assert len(summary)==1 and int(summary[0][0])>0 and int(summary[0][1])==0, 'missing/invalid AOT counters'
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in hashes.items()), 'input changed'
print('owned guest D3D11 / real xrizer / provider: two pixel-checked stereo pairs, strict AOT -> ok')
