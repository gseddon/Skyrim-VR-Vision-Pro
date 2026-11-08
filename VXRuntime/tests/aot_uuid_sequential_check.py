#!/usr/bin/env python3
"""Owned strict-AOT check for rpcrt4!UuidCreateSequential."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile


VERDICT = 'aot_uuid_sequential: version 1, variant, stable node, increasing time, canaries held -> ok'
MISSING = 'called an unimplemented function: RPCRT4.dll!UuidCreateSequential'


def check(runtime, exe, modules, out, expect):
    root = out / 'run'
    root.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
    env.update(VXRT_ROOT=str(root / 'root'), VXRT_AOT_DIR=str(modules), VXRT_AOT_STRICT='1',
               VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1')
    command = ['/usr/bin/arch', '-arm64', str(runtime), str(exe)]
    with (root / 'runtime.log').open('wb') as log:
        p = subprocess.Popen(command, cwd=exe.parent, env=env, stdout=log, stderr=subprocess.STDOUT,
                             start_new_session=True)
        try:
            rc = p.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            raise AssertionError('fixture timed out')
    text = (root / 'runtime.log').read_text(errors='replace')
    (root / 'process.json').write_text(json.dumps({'command': command, 'returncode': rc, 'expect': expect}, indent=2) + '\n')
    summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', text)
    assert summaries and int(summaries[-1][0]) > 0, 'no positive AOT execution summary'
    if expect == 'missing':
        assert rc == 3, f'expected the unimplemented stop, got {rc}'
        assert MISSING in text, 'missing the named API diagnostic'
        assert 'has no recompiled code' not in text and int(summaries[-1][1]) == 0, 'attempted fallback'
        print('aot_uuid_sequential: unimplemented import stops by name -> ok')
        return
    assert rc == 0, f'expected success, got {rc}'
    assert VERDICT in text, 'missing success verdict'
    assert int(summaries[-1][1]) == 0, 'fallback into the translator'
    print(VERDICT)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--runtime', required=True, type=Path)
    ap.add_argument('--exe', required=True, type=Path)
    ap.add_argument('--aot-dir', required=True, type=Path)
    ap.add_argument('--expect', choices=('ok', 'missing'), default='ok')
    ap.add_argument('--out', type=Path)
    a = ap.parse_args()
    runtime, exe, modules = (p.resolve(strict=True) for p in (a.runtime, a.exe, a.aot_dir))
    if a.out:
        out = a.out.resolve()
        out.mkdir(parents=True, exist_ok=False)
        check(runtime, exe, modules, out, a.expect)
    else:
        with tempfile.TemporaryDirectory(prefix='aot-uuid-sequential-', dir=runtime.parent) as tmp:
            check(runtime, exe, modules, Path(tmp), a.expect)


if __name__ == '__main__':
    main()
