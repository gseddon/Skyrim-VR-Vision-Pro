#!/usr/bin/env python3 -I
"""skse_device_config.py <config.json> <out.json> [--hooks-dll PATH]: the same module set with the bases the visionOS pipeline assigns.

The SKSE capture (stub bytes, branch displacements, hooks region) depends on where every image is mapped. tools/skyrim_aot_pipeline.py
--target xros packs the images from the arena base in config order, ignoring the config's bases; this runs its --dry-run, reads those
bases and writes a copy of the config in which every module has them. A Mac-target build of that copy (with VXRT_AOT_ARENA=<arena>)
maps everything exactly where the device will, so a capture taken on the Mac holds for the device build."""
import json, re, subprocess, sys
from pathlib import Path
cfg, out = sys.argv[1], sys.argv[2]
repo = Path(__file__).resolve().parents[1]
txt = subprocess.run([sys.executable, str(repo / 'tools/skyrim_aot_pipeline.py'), '--config', cfg, '--target', 'xros', '--dry-run'],
                     capture_output=True, text=True, check=True).stdout
bases = {}
for l in txt.splitlines():
    m = re.match(r'^(\S+)\s+0x[0-9a-f]+\s+(0x[0-9a-f]+)\s', l)
    if m: bases[m.group(1).lower()] = m.group(2)
c = json.load(open(cfg))
c['exe']['base'] = bases[Path(c['prepared']['path']).name.lower()]
for d in c['dlls']:
    d['base'] = bases[Path(d['path']).name.lower()]
json.dump(c, open(out, 'w'), indent=1)
print('\n'.join('%-22s %s' % (k, v) for k, v in bases.items()))
