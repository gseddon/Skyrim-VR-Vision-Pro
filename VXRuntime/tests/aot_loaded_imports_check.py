#!/usr/bin/env python3
"""Owned strict-AOT check for the imports already bound on DLLs a Skyrim probe loaded."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile


VERDICT = 'aot_loaded_imports: 21 bound imports, owned results -> ok'


def check(runtime, exe, modules, out):
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
            rc = p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            raise AssertionError('fixture timed out')
    text = (root / 'runtime.log').read_text(errors='replace')
    (root / 'process.json').write_text(json.dumps({'command': command, 'returncode': rc}, indent=2) + '\n')
    summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', text)
    assert rc == 0, f'expected success, got {rc}\n{text[-2000:]}'
    assert VERDICT in text, f'missing success verdict\n{text[-2000:]}'
    assert summaries and int(summaries[-1][0]) > 0, 'no positive AOT execution summary'
    assert int(summaries[-1][1]) == 0, 'fallback into the translator'
    print(VERDICT)


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
        with tempfile.TemporaryDirectory(prefix='aot-loaded-imports-', dir=runtime.parent) as tmp:
            check(runtime, exe, modules, Path(tmp))


if __name__ == '__main__':
    main()
