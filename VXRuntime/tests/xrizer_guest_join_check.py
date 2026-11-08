#!/usr/bin/env python3
"""Verify real xrizer/provider guest initialization and matrices without drawing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--runtime', required=True, type=Path)
    ap.add_argument('--exe', required=True, type=Path)
    ap.add_argument('--aot-dir', required=True, type=Path)
    ap.add_argument('--xrizer-dylib', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    a = ap.parse_args()
    runtime, exe, modules, library = (p.resolve(strict=True) for p in (a.runtime, a.exe, a.aot_dir, a.xrizer_dylib))
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    identities = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in [runtime, exe, library, *sorted(modules.glob('*.dylib'))]}
    (out / 'identities.json').write_text(json.dumps(identities, indent=2) + '\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_', 'XDG_'))}
    env.update(VXRT_ROOT=str(out / 'root'), VXRT_AOT_DIR=str(modules), VXRT_AOT_STRICT='1',
               VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1',
               VXRT_ABI_XRIZER_DYLIB=str(library), XDG_STATE_HOME=str(out / 'state'), XDG_CONFIG_HOME=str(out / 'config'))
    command = ['/usr/bin/arch', '-arm64', str(runtime), str(exe)]
    with (out / 'runtime.log').open('wb') as log:
        p = subprocess.Popen(command, cwd=exe.parent, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = p.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            raise AssertionError('joined xrizer fixture timed out')
    recorded_env = {k: v for k, v in env.items() if k.startswith(('VXRT_', 'XDG_'))}
    (out / 'process.json').write_text(json.dumps({'command': command, 'returncode': rc, 'env': recorded_env,
        'scope': 'owned Windows guest/native xrizer/partial provider, injected tracking, no texture submission or headset'}, indent=2) + '\n')
    text = (out / 'runtime.log').read_text()
    assert rc == 0, f'joined xrizer guest failed: {rc}'
    assert 'xrizer_guest_join: actual provider Init0/System019 matrices/empty-frame cancellation -> ok' in text, 'missing guest verdict'
    assert 'xrizer_guest_bridge: actual native Init return 0' in text, 'missing native initialization'
    for name in ['IVRSystem_019', 'IVRCompositor_022', 'FnTable:IVRSystem_019']:
        assert re.search(r'actual native interface ' + re.escape(name) + r' pointer 0x[0-9a-f]+ error 0', text), f'missing actual interface {name}'
    assert 'native stats waits 0 publishes 0 cancels 0' in text, 'refused poses acquired a frame'
    assert 'native stats waits 1 publishes 0 cancels 1 lifecycle 1/0/0 sessions 1/0 frame 101 pose 201' in text, 'missing clean empty-frame cancellation'
    assert 'native stats waits 1 publishes 0 cancels 1 lifecycle 1/1/1 sessions 1/1 frame 101 pose 201' in text, 'missing actual cleanup'
    summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', text)
    assert len(summaries) == 1 and int(summaries[0][0]) > 0 and int(summaries[0][1]) == 0, 'invalid AOT summary'
    assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p, h in identities.items()), 'input changed'
    print('xrizer_guest_join: real provider/MSVC matrices/pose refusals/empty cancel/cleanup -> ok')


if __name__ == '__main__':
    main()
