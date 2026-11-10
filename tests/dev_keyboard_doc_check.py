#!/usr/bin/env python3
"""docs/dev-keyboard.md lists exactly the default key map of VXRuntime/src/xrizer_dev_host.m (dk_default_map)."""
import re
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
src = (root / 'VXRuntime/src/xrizer_dev_host.m').read_text()
block = re.search(r'dk_default_map\[\] =\s*((?:"[^"]*"\s*)+);', src).group(1)
default = dict(re.findall(r'(\w+)=([\w.]+)', ''.join(re.findall(r'"([^"]*)"', block))))
doc = {}
for line in (root / 'docs/dev-keyboard.md').read_text().splitlines():
    m = re.match(r'\|[^|]*\|\s*`(\w+)`\s*\|\s*`([\w.]+)`\s*\|', line)
    if m:
        doc[m.group(1)] = m.group(2)
bad = [k for k in sorted(set(default) | set(doc)) if default.get(k) != doc.get(k)]
if bad:
    print('dev keyboard doc differs from dk_default_map for: ' + ', '.join(f'{k} (code {default.get(k)}, doc {doc.get(k)})' for k in bad))
    sys.exit(1)
print(f'dev keyboard doc ok: {len(default)} default bindings')
