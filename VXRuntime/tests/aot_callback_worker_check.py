#!/usr/bin/env python3
"""Check callback diagnostic identities and stack bounds on a managed pthread."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--runtime', type=Path, required=True)
p.add_argument('--exe', type=Path, required=True)
p.add_argument('--aot-dir', type=Path, required=True)
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
runtime, exe, modules = (x.resolve(strict=True) for x in (a.runtime, a.exe, a.aot_dir))
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=False)
for name, limit, expected in [('limited', 3, 3), ('allowed', 8, 0), ('default', None, 0)]:
    d = out / name
    d.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
    env.update(VXRT_ROOT=str(d / 'root'), VXRT_AOT_DIR=str(modules), VXRT_AOT_STRICT='1',
               VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1')
    if limit is not None: env['VXRT_CALLBACK_DEPTH_LIMIT'] = str(limit)
    command = ['/usr/bin/arch', '-arm64', str(runtime), str(exe)]
    with (d / 'runtime.log').open('wb') as log:
        proc = subprocess.Popen(command, cwd=exe.parent, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try: rc = proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            raise AssertionError(name + ': timed out')
    (d / 'process.json').write_text(json.dumps({'command': command, 'returncode': rc, 'limit': limit}, indent=2) + '\n')
    log = (d / 'runtime.log').read_text()
    assert rc == expected, (name, rc, log)
    summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', log)
    assert summaries and int(summaries[-1][0]) > 0 and int(summaries[-1][1]) == 0, name
    if not expected:
        assert 'aot_callback_worker: ok' in log and 'stopping (diagnostic)' not in log
        continue
    assert 'depth 4 exceeds 3; stopping (diagnostic)' in log and 'aot_callback_worker: ok' not in log
    m = re.search(r'callback thread (\d+) native stack (0x[0-9a-f]+)-(0x[0-9a-f]+) \((\d+) bytes\), SP (0x[0-9a-f]+)', log)
    assert m, log
    tid, low, high, size, sp = (int(x, 0) for x in m.groups())
    assert tid and low < sp < high and high - low == size and size >= 2 * 1024 * 1024
    rows = re.findall(r'callback\[(\d+)\] fn (0x[0-9a-f]+) \(([^)]*)\), dispatch (0x[0-9a-f]+|0) \(([^)]*)\), thunk (0x[0-9a-f]+|0) \(([^)]*)\), caller (0x[0-9a-f]+|0), guest SP (0x[0-9a-f]+|0), native SP (0x[0-9a-f]+)', log)
    assert len(rows) == 4, log
    previous = high
    for i, row in enumerate(rows, 1):
        idx, fn, image, rip, _, thunk, symbol, caller, guest_sp, host_sp = row
        host_sp = int(host_sp, 16)
        assert int(idx) == i and int(fn, 16) and 'aot_callback_worker.exe+' in image
        assert low < host_sp < previous
        previous = host_sp
        if i > 1:
            assert int(rip, 0) and int(thunk, 0) and int(caller, 0) and int(guest_sp, 0)
            assert symbol == 'vxt_EnumSystemLocalesA'
    assert previous == sp
print('managed worker: limited/allowed/default, bounds and callback identities passed')
