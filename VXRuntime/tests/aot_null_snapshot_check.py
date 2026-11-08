#!/usr/bin/env python3
"""Check bounded candidate reads and accurate unhandled AV labels."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser()
for arg in ('runtime', 'snapshot-exe', 'snapshot-aot', 'label-exe', 'label-aot', 'out'):
    p.add_argument('--' + arg, type=Path, required=True)
a = p.parse_args()
runtime, snap, snapmod, label, labelmod = (x.resolve(strict=True) for x in (a.runtime, a.snapshot_exe, a.snapshot_aot, a.label_exe, a.label_aot))
out = a.out.resolve(); out.mkdir(parents=True, exist_ok=False)
def run(name, exe, modules, args, diagnostic):
    d = out / name; d.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
    env.update(VXRT_ROOT=str(d / 'root'), VXRT_AOT_DIR=str(modules), VXRT_AOT_STRICT='1',
               VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1')
    if diagnostic: env['VXRT_AOT_NULL_DIAGNOSTIC'] = '1'
    cmd = ['/usr/bin/arch', '-arm64', str(runtime), str(exe), *args]
    r = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
    (d / 'runtime.log').write_bytes(r.stdout)
    (d / 'process.json').write_text(json.dumps({'command':cmd,'exit':r.returncode,'diagnostic':diagnostic},indent=2)+'\n')
    return r.returncode, r.stdout.decode(errors='replace')
rc, log = run('snapshot', snap, snapmod, [], True)
assert rc == 0 and 'aot_null_snapshot: execute/read/write guest access violations, resumed' in log, log
m = re.findall(r'aot-null-target: candidates rcx=(0x[0-9a-f]+) object-word=(0x[0-9a-f]+) rax=(0x[0-9a-f]+) caller=(0x[0-9a-f]+)', log)
symbols = subprocess.check_output(['x86_64-w64-mingw32-nm', '-n', str(snap)], text=True)
def symbol(name):
    match = re.search(r'^([0-9a-fA-F]+) [A-Za-z] ' + re.escape(name) + r'$', symbols, re.M)
    assert match, name
    return int(match.group(1), 16)
expected = (symbol('obj'), symbol('methods'), symbol('methods'), symbol('null_call_return'))
assert len(m) == 1 and tuple(int(v, 16) for v in m[0]) == expected, (expected, m, log)
assert int(m[0][3], 16) != 0xffffffffffff0000, log
assert re.search(r'aot-null-target: candidate table slot 6=0 ', log), log
assert [int(n) for n in re.findall(r'aot-null-target: candidate table slot (\d+)=', log)] == list(range(8)), log
assert log.count('rcx=0x1 object-word=unreadable:0 rax=0x1') == 3 and log.count('candidate table slot 0 unreadable') == 3, log
assert log.count('aot-null-target: candidates ') == 4, log
summary = re.search(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', log)
assert summary and int(summary.group(1)) > 0 and int(summary.group(2)) == 0, log
rc, log = run('default', snap, snapmod, [], False)
assert rc == 0 and 'aot-null-target:' not in log and 'aot_null_snapshot:' in log, log
summary = re.search(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', log)
assert summary and int(summary.group(1)) > 0 and int(summary.group(2)) == 0, log
for name, arg, word in [('execute','@e','executing 0'), ('read','@r','reading 0x10'), ('write','@w','writing 0x10')]:
    rc, log = run(name, label, labelmod, [arg], False)
    assert rc == 5 and 'unhandled exception 0xc0000005' in log and word in log, (name,rc,log)
print('snapshot valid/unreadable/default, execute/read/write labels -> ok')
