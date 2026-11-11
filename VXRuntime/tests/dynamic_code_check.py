#!/usr/bin/env python3
"""Run-time code under strict AOT: a JIT's VirtualAlloc/VirtualProtect(PAGE_EXECUTE_*) outside an image fails with 1655 (ProhibitDynamicCode),
the program's own image can still be patched, and without strict the same sequence works under the translator (the control)."""
import os, re, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / 'build/dynamic_code/dynamic_code_a.exe'
def run(name, extra):
    out = ROOT / 'build/dynamic_code' / ('run-' + name); out.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
    env.update(VXRT_ROOT=str(out / 'root'), VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1'); env.update(extra)
    p = subprocess.run(['/usr/bin/arch', '-arm64', str(ROOT / 'build/vxrt-arm64'), str(EXE)], env=env, cwd=ROOT, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, timeout=60)
    return p
p = run('control', {'JIT_EXPECT_BLOCKED': '0'})
assert p.returncode == 0 and 'executable requests allowed (no strict), generated code ran -> ok' in p.stdout, f'control: exit {p.returncode}\n{p.stdout[-1500:]}'
aot = ROOT / 'build/dynamic_code/aot'; aot.mkdir(exist_ok=True)
subprocess.run(['tools/aot_build.sh', str(EXE), str(aot)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
p = run('strict', {'VXRT_AOT_DIR': str(aot), 'VXRT_AOT_STRICT': '1', 'JIT_EXPECT_BLOCKED': '1'})
assert p.returncode == 0 and 'executable requests refused (1655), image patching allowed -> ok' in p.stdout, f'strict: exit {p.returncode}\n{p.stdout[-1500:]}'
assert 'refused, 1655 ERROR_DYNAMIC_CODE_BLOCKED' in p.stdout, 'the refusal was not logged'
m = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks', p.stdout)
assert m and int(m[-1][0]) > 0 and int(m[-1][1]) == 0, 'AOT counters missing or fallbacks present'
print('dynamic_code_a: control runs generated code; strict AOT refuses executable VirtualAlloc/VirtualProtect (1655), image patching allowed, 0 fallbacks -> ok')
