#!/usr/bin/env python3
"""Check a real MSVC guest call through static native ABI adapters and its raw-pointer control."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile


def check(runtime, exe, modules, out):
    identities = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in [runtime, exe, *sorted(modules.glob('*.dylib'))]}
    (out / 'identities.json').write_text(json.dumps(identities, indent=2) + '\n')
    for name, args, expected in [('static-wrappers', [], 0), ('raw-native-pointer', ['@'], 3)]:
        root = out / name
        root.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
        env.update(VXRT_ROOT=str(root / 'root'), VXRT_AOT_DIR=str(modules), VXRT_AOT_STRICT='1',
                   VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1')
        command = ['/usr/bin/arch', '-arm64', str(runtime), str(exe), *args]
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
        recorded_env = {k: v for k, v in env.items() if k.startswith('VXRT_')}
        (root / 'process.json').write_text(json.dumps({'command': command, 'returncode': rc, 'env': recorded_env}, indent=2) + '\n')
        assert rc == expected, f'{name}: expected {expected}, got {rc}'
        summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', text)
        assert len(summaries) == 1 and int(summaries[0][0]) > 0, f'{name}: invalid AOT summary'
        if expected == 0:
            assert 'xrizer_guest_abi: MSVC member/C FnTable scalar/float/matrix -> ok' in text, 'missing guest verdict'
            assert int(summaries[0][1]) == 0 and 'VXRT_AOT_STRICT:' not in text, 'static wrappers fell back'
        else:
            assert 'xrizer_guest_abi: MSVC' not in text, 'raw native pointer reached success'
            assert re.search(r'fallback to the translator at 0x[0-9a-f]+ \(no image\)', text), 'raw pointer not classified'
            assert re.search(r'VXRT_AOT_STRICT: 0x[0-9a-f]+ has no recompiled code; stopping', text), 'missing strict stop'
            assert int(summaries[0][1]) == 1, 'negative control did not record exactly one missing target'
        assert 'invalid native fixture argument' not in text, 'native ABI argument assertion failed'
    assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p, h in identities.items()), 'input changed'
    print('xrizer_guest_abi: static wrappers pass, raw native pointer rejected before execution -> ok')


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
        with tempfile.TemporaryDirectory(prefix='xrizer-guest-abi-', dir=runtime.parent) as tmp:
            check(runtime, exe, modules, Path(tmp))


if __name__ == '__main__':
    main()
