#!/usr/bin/env python3
"""Offline emitter control: refusal PC is the failed instruction, not block start."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--tool', required=True, type=Path)
p.add_argument('--exe', required=True, type=Path)
a = p.parse_args()
tool, exe = a.tool.resolve(strict=True), a.exe.resolve(strict=True)
with tempfile.TemporaryDirectory(prefix='aot-refusal-detail-') as tmp:
    outputs = []
    for detail in (False, True):
        env = {k: v for k, v in os.environ.items() if not k.startswith('VXRT_AOT_')}
        env['VXRT_AOT_REFUSED'] = '1'
        if detail: env['VXRT_AOT_REFUSED_DETAIL'] = '1'
        out = Path(tmp) / ('on.s' if detail else 'off.s')
        result = subprocess.run([str(tool), 'gen', str(exe), str(out)], env=env, text=True, capture_output=True, check=True)
        outputs.append(out.read_bytes())
        match = re.search(r'^refused (0x[0-9a-f]+)$', result.stderr, re.M)
        assert match, result.stderr
        if detail:
            info = re.search(r'^refusal-detail block=(0x[0-9a-f]+) pc=(0x[0-9a-f]+) reason=(\w+)$', result.stderr, re.M)
            assert info and info.group(1) == match.group(1) and int(info.group(2), 16) == int(info.group(1), 16) + 1 and info.group(3) == 'instruction', result.stderr
        else: assert 'refusal-detail' not in result.stderr
    assert outputs[0] == outputs[1], 'diagnostic altered emitted output'
print('offline refusal detail: failure PC, default silence, identical output -> ok')
