#!/usr/bin/env python3
"""Check recorded EMMS red/green and separately labelled Rosetta observations."""
import argparse,re
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('evidence',type=Path);a=p.parse_args(); d=a.evidence
text=lambda name:(d/name).read_text(errors='replace')
status=lambda name:int(text(name).strip())
verdict='xrizer_guest_emms: tags emptied; x87 physical values/control/non-TOP status, flags and MXCSR preserved -> ok'
strong=d/'strong'
def slog(name): return (strong/name).read_text(errors='replace')
def sstatus(name): return int(slog(name).strip())
assert sstatus('reference.status')==0 and verdict in slog('reference.log')
assert 'ftw=c0/00 fsw=3000/3000' in text('reference-probe.log'), 'missing observed Rosetta TOP divergence'
assert slog('red-build.status').strip()=='0 0' and 'refused 0x140001000' in slog('red-build.log')
assert sstatus('red.status')==3 and '0x140001000 has no recompiled code; stopping' in slog('red.log') and verdict not in slog('red.log')
assert re.search(r'aot: [1-9]\d* entries into recompiled code,.*? 1 fallbacks to the translator',slog('red.log'))
assert slog('green-build.status').strip()=='0 0' and '0 blocks the translator refused' in slog('green-build.log')
for name in ('green','c12'):
    assert sstatus(name+'.status')==0 and verdict in slog(name+'.log')
    assert re.search(r'aot: [1-9]\d* entries into recompiled code,.*? 0 fallbacks to the translator \(0 addresses\)',slog(name+'.log'))
assert sstatus('jit.status')==0 and verdict in slog('jit.log')
for name in ('text','import','suite','split'):
    assert (d/'suite-work'/'evidence'/(name+'.status')).read_text().strip()=='0 0', name
print('owned EMMS red/green, C12 compatibility, reference divergence and AOT suite -> ok')
