#!/usr/bin/env python3
"""Prove a real no-provider xrizer error survives a Windows MSVC guest ABI boundary."""
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
            raise AssertionError('real xrizer fixture timed out')
    recorded_env = {k: v for k, v in env.items() if k.startswith(('VXRT_', 'XDG_'))}
    (out / 'process.json').write_text(json.dumps({'command': command, 'returncode': rc, 'env': recorded_env}, indent=2) + '\n')
    text = (out / 'runtime.log').read_text()
    assert rc == 0, f'real xrizer guest failed: {rc}'
    assert 'xrizer_guest_real: real factory/version/bool/Init150 through MSVC guest thunks -> ok' in text, 'missing actual guest verdict'
    assert re.search(r'actual native ClientCore factory pointer 0x[0-9a-f]+ error 0', text), 'missing native factory result'
    summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator', text)
    assert len(summaries) == 1 and int(summaries[0][0]) > 0 and int(summaries[0][1]) == 0, 'invalid AOT summary'
    assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p, h in identities.items()), 'input changed'
    print('xrizer_guest_real: actual no-provider Init150 preserved through static MSVC guest thunks -> ok')


if __name__ == '__main__':
    main()
