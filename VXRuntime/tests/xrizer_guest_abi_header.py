#!/usr/bin/env python3
"""Make a freestanding view of the pinned OpenVR classes without changing them."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('source', type=Path)
ap.add_argument('out', type=Path)
a = ap.parse_args()
data = a.source.read_bytes()
text = data.decode().split('#endif // _OPENVR_API', 1)[0] + '#endif // _OPENVR_API\n'
# Only the unused convenience helper depends on a C++ standard library. Keep
# every interface/type declaration byte-for-byte, including their packing.
text = text.replace('#include <string>', '')
start = text.index('\tclass CVRSettingHelper\n')
end = text.index('\n\t};', start) + len('\n\t};')
text = text[:start] + text[end:]
assert 'std::' not in text
for cls, version, expected in [
    ('IVRSystem', '019', {0: 'GetRecommendedRenderTargetSize', 1: 'GetProjectionMatrix',
                         4: 'GetEyeToHeadTransform', 18: 'GetTrackedDeviceIndexForControllerRole'}),
    ('IVRCompositor', '022', {10: 'GetFrameTimeRemaining'}),
]:
    body = re.search(r'class ' + cls + r'\s*\{(.*?)\n\};', text, re.S).group(1)
    methods = re.findall(r'virtual\s+[^;]*?\b(\w+)\s*\(', body)
    assert f'{cls}_{version}' in text
    for index, method in expected.items():
        assert methods[index] == method, (cls, index, methods[index], method)
a.out.parent.mkdir(parents=True, exist_ok=True)
a.out.write_text(text)
a.out.with_suffix('.json').write_text(json.dumps({
    'source': str(a.source.resolve()), 'source_sha256': hashlib.sha256(data).hexdigest(),
    'view_sha256': hashlib.sha256(a.out.read_bytes()).hexdigest(),
    'removed': ['unused CVRSettingHelper and string include', 'external inline API wrapper section'],
}, indent=2) + '\n')
