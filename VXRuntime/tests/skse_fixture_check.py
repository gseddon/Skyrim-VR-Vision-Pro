#!/usr/bin/env python3
"""Owned fixture for the static script-extender scheme (research/2026-11-11-skse-vr-on-aot.md), whole chain on the Mac:
1. dev capture (translator allowed, labelled a development reference): preload the extension DLL with the executable-region
   service and VXRT_CODE_CAPTURE; the hooks fire.
2. prepare: the synthetic hooks module from the capture, then strict-AOT modules for the host (VXRT_AOT_PATCHES), the
   extension DLL and the hooks module.
3. strict AOT run, VXRT_CODE_VERIFY: hooks fire, zero fallbacks, the live code equals the capture.
Controls: the host module built without patches does not fire the hooks; a tampered capture stops the run (exit 3)."""
import argparse, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
B = ROOT / 'build/skse'
EXE, DLL = B / 'skse_fixture_host.exe', B / 'skse_fixture_ext.dll'


def run(name, extra, expect_rc, expect_text):
    out = B / ('run-' + name); out.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
    env.update(VXRT_ROOT=str(out / 'root'), VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1')
    env.update(extra)
    p = subprocess.run(['/usr/bin/arch', '-arm64', str(ROOT / 'build/vxrt-arm64'), str(EXE)], env=env, cwd=ROOT,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60, text=True)
    (out / 'out.log').write_text(p.stdout)
    assert p.returncode == expect_rc, f'{name}: exit {p.returncode}, wanted {expect_rc}\n{p.stdout[-1500:]}'
    assert expect_text in p.stdout, f'{name}: missing {expect_text!r}\n{p.stdout[-1500:]}'
    return p.stdout


def sh(*a, env=None):
    e = dict(os.environ); e.update(env or {})
    subprocess.run([str(x) for x in a], cwd=ROOT, env=e, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    pe = ROOT.parent / 'tools/skse_hooks_pe.py'
    if not pe.exists():
        pe = ROOT / '../tools/skse_hooks_pe.py'
    (B / 'blank').mkdir(exist_ok=True); (B / 'real').mkdir(exist_ok=True)
    cap = B / 'capture.txt'
    sh('python3', '-I', pe, '--base', '0x307000000', '--size', '0x100000', '--out', B / 'blank/vxrt_hooks.dll')
    run('cap', dict(VXRT_PRELOAD=f'{B}/blank/vxrt_hooks.dll;{DLL}', VXRT_EXEC_REGION='vxrt_hooks.dll', VXRT_CODE_CAPTURE=str(cap)),
        0, 'hooks fired')
    sh('python3', '-I', pe, '--base', '0x307000000', '--size', '0x100000', '--out', B / 'real/vxrt_hooks.dll', '--capture', cap,
       '--image', 'skse_fixture_host.exe=0x308000000', '--roots', B / 'roots.txt')
    for d in ('aot', 'aot-unpatched'):
        (B / d).mkdir(exist_ok=True)
    sh('tools/aot_build.sh', EXE, B / 'aot', env=dict(VXRT_AOT_PATCHES=str(cap)))
    sh('tools/aot_build.sh', DLL, B / 'aot')
    sh('tools/aot_build.sh', B / 'real/vxrt_hooks.dll', B / 'aot', env=dict(VXRT_AOT_ROOTS=str(B / 'roots.txt')))
    sh('tools/aot_build.sh', EXE, B / 'aot-unpatched')
    for f in list((B / 'aot').glob('skse_fixture_ext*')) + list((B / 'aot').glob('vxrt_hooks*')):
        (B / 'aot-unpatched' / f.name).write_bytes(f.read_bytes())
    common = lambda d, c: dict(VXRT_AOT_DIR=str(B / d), VXRT_AOT_STRICT='1', VXRT_PRELOAD=f'{B}/real/vxrt_hooks.dll;{DLL}',
                               VXRT_EXEC_REGION='vxrt_hooks.dll', VXRT_CODE_VERIFY=str(c))
    t = run('strict', common('aot', cap), 0, 'hooks fired (work=110 work2=1005)')
    m = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', t)
    assert m and int(m[-1][0]) > 0 and int(m[-1][1]) == 0, 'AOT counters missing or fallbacks present'
    assert 'verify' in t and '0 differ' in t
    run('unpatched', common('aot-unpatched', cap), 1, 'not hooked')
    bad = B / 'capture-bad.txt'
    bad.write_text(cap.read_text().replace('ff250000000000100006', 'ff250000000000100007'))
    run('tampered', common('aot', bad), 3, 'differs from the capture')
    print('skse_fixture: capture -> patched strict AOT, hooks fire, 0 fallbacks, verify ok; unpatched control not hooked; tampered capture stops -> ok')


main()
