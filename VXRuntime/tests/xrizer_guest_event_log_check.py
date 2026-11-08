#!/usr/bin/env python3
"""Validate logs from the System019 Windows event-layout owned fixture."""
import argparse,re
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('log',type=Path);a=p.parse_args()
text=a.log.read_text(errors='replace')
assert 'xrizer_guest_devhost: real OpenVR exports / D3D11 stereo / nonzero poses -> ok' in text, 'missing guest verdict including event/canary assertions'
entries=re.findall(r'xrizer_guest_bridge: System019 slot30 size (\d+) result (\d+)',text)
assert ('19','0') in entries and ('48','0') in entries and ('48','1') in entries, f'missing actual native event outcomes: {entries}'
summary=re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator',text)
assert len(summary)==1 and int(summary[0][0])>0 and int(summary[0][1])==0, 'missing/invalid strict-AOT counters'
print('System019 Windows event 48-byte guarded HMD activation + null/short checks -> ok')
