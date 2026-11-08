#!/usr/bin/env python3
"""Verify opt-in callback diagnostics against legitimate nested guest calls."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile


def check(runtime, exe, modules, out):
    for name, args, limit, expected in [('shallow', [], 2, 0), ('deep-limited', ['@'], 2, 3),
                                       ('deep-allowed', ['@'], 8, 0), ('deep-default', ['@'], None, 0)]:
        root = out / name
        root.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
        env.update(VXRT_ROOT=str(root / 'root'), VXRT_AOT_DIR=str(modules), VXRT_AOT_STRICT='1',
                   VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1')
        if limit is not None:
            env['VXRT_CALLBACK_DEPTH_LIMIT'] = str(limit)
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
        (root / 'process.json').write_text(json.dumps({'command': command, 'returncode': rc, 'limit': limit}, indent=2) + '\n')
        assert rc == expected, f'{name}: expected {expected}, got {rc}'
        summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', text)
        assert summaries and int(summaries[-1][0]) > 0 and int(summaries[-1][1]) == 0, f'{name}: invalid AOT summary'
        if expected:
            assert 'VXRT_CALLBACK_DEPTH_LIMIT: depth 3 exceeds 2; stopping (diagnostic)' in text, 'missing depth stop'
            assert len(re.findall(r'arm64: callback\[\d+\]', text)) == 3, 'missing bounded callback chain'
            assert re.search(r'native stack 0x[0-9a-f]+-0x[0-9a-f]+ \(\d+ bytes\)', text), 'missing host stack bounds'
            assert re.search(r'context \d+ bytes, level \d+ bytes', text), 'missing context sizes'
            assert 'aot_callback_depth: ok' not in text, 'limited path unexpectedly completed'
        else:
            assert 'aot_callback_depth: ok' in text and 'stopping (diagnostic)' not in text, f'{name}: normal nesting changed'
    print('aot_callback_depth: shallow/deep, opt-in stop and default behavior -> ok')


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
        with tempfile.TemporaryDirectory(prefix='aot-callback-depth-', dir=runtime.parent) as tmp:
            check(runtime, exe, modules, Path(tmp))


if __name__ == '__main__':
    main()
