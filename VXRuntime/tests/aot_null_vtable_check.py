#!/usr/bin/env python3
"""A managed worker's null vtable call raises one recoverable execute AV."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser()
for arg in ('old-runtime', 'runtime', 'exe', 'aot-dir', 'out'):
    p.add_argument('--' + arg, type=Path, required=True)
a = p.parse_args()
old, fixed, exe, modules = (x.resolve(strict=True) for x in (a.old_runtime, a.runtime, a.exe, a.aot_dir))
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=False)
for name, runtime, limit, expected in [('red', old, '4', 3), ('green', fixed, None, 0), ('green-limited', fixed, '4', 0)]:
    d = out / name
    d.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
    env.update(VXRT_ROOT=str(d / 'root'), VXRT_AOT_DIR=str(modules), VXRT_AOT_STRICT='1',
               VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1')
    if limit: env['VXRT_CALLBACK_DEPTH_LIMIT'] = limit
    cmd = ['/usr/bin/arch', '-arm64', str(runtime), str(exe)]
    r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
    (d / 'runtime.log').write_bytes(r.stdout)
    (d / 'process.json').write_text(json.dumps({'command': cmd, 'exit': r.returncode, 'limit': limit}, indent=2) + '\n')
    log = r.stdout.decode(errors='replace')
    assert r.returncode == expected, (name, r.returncode, log)
    summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', log)
    assert summaries and int(summaries[-1][0]) > 0 and int(summaries[-1][1]) == 0, name
    if expected:
        assert 'depth 5 exceeds 4' in log and len(re.findall(r'callback\[\d+\] fn 0 ', log)) >= 3
        assert 'aot_null_vtable:' not in log
    else:
        assert 'aot_null_vtable: execute/read/write guest access violations, resumed' in log
        assert 'stopping (diagnostic)' not in log
print('strict AOT: null-vtable red and execute/read/write AV continuation green -> ok')
