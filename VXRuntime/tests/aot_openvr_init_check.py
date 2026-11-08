#!/usr/bin/env python3
"""Prove owned OpenVR export tracing preserves actual guest results and ABI."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile


def check(runtime, exe, modules, out):
    for name, traced in [('default', False), ('traced', True)]:
        root = out / name
        root.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
        env.update(VXRT_ROOT=str(root / 'root'), VXRT_AOT_DIR=str(modules), VXRT_AOT_STRICT='1',
                   VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1')
        if traced:
            env['VXRT_TRACE_OPENVR_INIT'] = '1'
        command = ['/usr/bin/arch', '-arm64', str(runtime), str(exe)]
        with (root / 'runtime.log').open('wb') as log:
            p = subprocess.Popen(command, cwd=exe.parent, env=env, stdout=log, stderr=subprocess.STDOUT,
                                 start_new_session=True)
            try:
                rc = p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
                raise AssertionError(f'{name}: fixture timed out')
        text = (root / 'runtime.log').read_text()
        (root / 'process.json').write_text(json.dumps({'command': command, 'returncode': rc, 'traced': traced}, indent=2) + '\n')
        assert rc == 0 and 'aot_openvr_init: ok' in text, f'{name}: guest return/error/pointer/last-error verdict failed'
        summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', text)
        assert summaries and int(summaries[-1][0]) > 0 and int(summaries[-1][1]) == 0, f'{name}: invalid AOT summary'
        if traced:
            for verdict in ['VR_InitInternal return token 257 error 11', 'VR_InitInternal2 return token 514 error 23',
                            'VR_IsInterfaceVersionValid(IVRSystem_019) return 1', 'VR_IsInterfaceVersionValid(bad) return 0',
                            'VR_GetInitToken return 514', 'VR_GetInitToken return 0', 'VR_ShutdownInternal return']:
                assert verdict in text, f'missing actual trace: {verdict}'
            assert re.search(r'VR_GetGenericInterface\(IVRSystem_019\) return 0x[0-9a-f]+ error 31', text), 'missing actual pointer/error'
            assert len(re.findall(r'openvr-init:', text)) <= 192, 'trace exceeded per-export bound'
            assert 'tracing IVR' not in text, 'initialization trace patched an interface'
        else:
            assert 'openvr-init:' not in text, 'default unexpectedly enables tracing'
    print('aot_openvr_init: real owned returns, errors, pointers and last-error preserved -> ok')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--runtime', required=True, type=Path)
    ap.add_argument('--exe', required=True, type=Path)
    ap.add_argument('--aot-dir', required=True, type=Path)
    ap.add_argument('--out', type=Path)
    a = ap.parse_args()
    runtime, exe, modules = (p.resolve(strict=True) for p in (a.runtime, a.exe, a.aot_dir))
    if a.out:
        out = a.out.resolve()
        out.mkdir(parents=True, exist_ok=False)
        check(runtime, exe, modules, out)
    else:
        with tempfile.TemporaryDirectory(prefix='aot-openvr-init-', dir=runtime.parent) as tmp:
            check(runtime, exe, modules, Path(tmp))


if __name__ == '__main__':
    main()
