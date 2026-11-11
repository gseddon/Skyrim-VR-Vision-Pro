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
    for d in ('blank', 'real', 'aot', 'aot-early', 'aot-unpatched'):
        (B / d).mkdir(exist_ok=True)
    full, early = B / 'capture.txt', B / 'capture-early.txt'
    sh('python3', '-I', pe, '--base', '0x307000000', '--size', '0x100000', '--out', B / 'blank/vxrt_hooks.dll')
    pre = dict(VXRT_PRELOAD=f'{B}/blank/vxrt_hooks.dll;{DLL}', VXRT_EXEC_REGION='vxrt_hooks.dll')
    # 1. dev captures (translator allowed, a development reference): at the end of the preload list, and 3 s later, after the late hook
    run('cap-early', dict(pre, VXRT_CODE_CAPTURE=str(early)), 0, 'hooks fired')
    run('cap-full', dict(pre, VXRT_CODE_CAPTURE=str(full), VXRT_CODE_CAPTURE_AT='3'), 0, 'hooks fired')
    assert early.read_text().count('\nP ') + early.read_text().startswith('P ') == 1, 'the early capture should hold site 1 only'
    assert full.read_text().count('P skse_fixture_host') == 2, 'the full capture should hold both sites'
    # 2. modules from the full capture (the exe with its patches, the extension DLL, the hooks module with the stubs)
    sh('python3', '-I', pe, '--base', '0x307000000', '--size', '0x100000', '--out', B / 'real/vxrt_hooks.dll', '--capture', full,
       '--image', 'skse_fixture_host.exe=0x308000000', '--roots', B / 'roots.txt')
    sh('tools/aot_build.sh', EXE, B / 'aot', env=dict(VXRT_AOT_PATCHES=str(full)))
    sh('tools/aot_build.sh', DLL, B / 'aot')
    sh('tools/aot_build.sh', B / 'real/vxrt_hooks.dll', B / 'aot', env=dict(VXRT_AOT_ROOTS=str(B / 'roots.txt')))
    # controls' modules: the host without patches; the host with the early capture only (the late hook is missing from it)
    sh('tools/aot_build.sh', EXE, B / 'aot-unpatched')
    sh('tools/aot_build.sh', EXE, B / 'aot-early', env=dict(VXRT_AOT_PATCHES=str(early)))
    for d in ('aot-unpatched', 'aot-early'):
        for f in list((B / 'aot').glob('skse_fixture_ext*')) + list((B / 'aot').glob('vxrt_hooks*')):
            (B / d / f.name).write_bytes(f.read_bytes())
    common = lambda d, c: dict(VXRT_AOT_DIR=str(B / d), VXRT_AOT_STRICT='1', VXRT_PRELOAD=f'{B}/real/vxrt_hooks.dll;{DLL}',
                               VXRT_EXEC_REGION='vxrt_hooks.dll', VXRT_CODE_VERIFY=str(c), VXRT_CODE_WATCH='100')
    t = run('strict', common('aot', full), 0, 'hooks fired (work=110 work2=1005)')
    m = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', t)
    assert m and int(m[-1][0]) > 0 and int(m[-1][1]) == 0, 'AOT counters missing or fallbacks present'
    assert 'watching' in t and 'LATE CODE WRITE' not in t
    run('unpatched', common('aot-unpatched', full), 1, 'not hooked')
    run('late', common('aot-early', early), 3, 'LATE CODE WRITE not in the capture')
    bad = B / 'capture-bad.txt'
    bad.write_text(full.read_text().replace('ff250000000000100006', 'ff250000000000100007'))
    run('tampered', common('aot', bad), 3, 'differs from the capture')
    print('skse_fixture: capture (early and at +3 s) -> patched strict AOT, hooks fire incl. the late one, 0 fallbacks, watch ok; '
          'controls: unpatched not hooked, capture missing the late hook stops with its address, tampered capture stops -> ok')


main()
