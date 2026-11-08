#!/usr/bin/env python3
"""Distinguish a missing Windows API from an unrecognized code address."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile


def check(runtime, exe, modules, out):
    for name, args in [('entry', []), ('interior', ['@'])]:
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
        (root / 'process.json').write_text(json.dumps({'command': command, 'returncode': rc}, indent=2) + '\n')
        assert rc == 3, f'{name}: expected explicit failure, got {rc}'
        summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', text)
        assert summaries and int(summaries[-1][0]) > 0, f'{name}: no positive AOT execution summary'
        missing = 'called an unimplemented function: kernel32.dll!VXRT_MissingImportFixture'
        if name == 'entry':
            assert missing in text, f'{name}: missing exact API diagnostic'
            assert 'aot_missing_import.exe+0x' in text, f'{name}: caller image not identified'
            assert 'has no recompiled code' not in text and int(summaries[-1][1]) == 0, f'{name}: attempted fallback'
        else:
            assert missing not in text, f'{name}: interior address accepted as an API entry'
            assert 'has no recompiled code' in text and int(summaries[-1][1]) == 1, f'{name}: missing strict code failure'
    print('aot_missing_import: named API failure and interior code rejection -> ok')


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
        with tempfile.TemporaryDirectory(prefix='aot-missing-import-', dir=runtime.parent) as tmp:
            check(runtime, exe, modules, Path(tmp))


if __name__ == '__main__':
    main()
