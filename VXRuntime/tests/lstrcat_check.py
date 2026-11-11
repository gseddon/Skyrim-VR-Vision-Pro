#!/usr/bin/env python3
"""lstrcatA fixture: the exe runs under the translator and, with its own module, under strict AOT with zero fallbacks."""
import os, re, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / 'build/lstrcat/lstrcat_a.exe'
def run(name, extra):
    out = ROOT / 'build/lstrcat' / ('run-' + name); out.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
    env.update(VXRT_ROOT=str(out / 'root'), VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1'); env.update(extra)
    p = subprocess.run(['/usr/bin/arch', '-arm64', str(ROOT / 'build/vxrt-arm64'), str(EXE)], env=env, cwd=ROOT, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, timeout=60)
    assert p.returncode == 0 and 'lstrcpyA, lstrcatA, lstrlenA -> ok' in p.stdout, f'{name}: exit {p.returncode}\n{p.stdout[-1500:]}'
    return p.stdout
run('translator', {})
aot = ROOT / 'build/lstrcat/aot'; aot.mkdir(exist_ok=True)
subprocess.run(['tools/aot_build.sh', str(EXE), str(aot)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
t = run('strict', {'VXRT_AOT_DIR': str(aot), 'VXRT_AOT_STRICT': '1'})
m = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks', t)
assert m and int(m[-1][0]) > 0 and int(m[-1][1]) == 0, 'AOT counters missing or fallbacks present'
print('lstrcat_a: lstrcpyA, lstrcatA, lstrlenA under the translator and strict AOT (0 fallbacks) -> ok')
