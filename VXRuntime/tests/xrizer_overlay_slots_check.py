#!/usr/bin/env python3
"""IVROverlay_018 in the guest bridge (src/xrizer_guest_bridge.c) must list the methods of openvr 1.0.17's class
IVROverlay in the header's order (a vtable is its slots), with the parameter counts and float/by-value parameters the
forwarders declare. Static check of the owned source against the pinned header."""
import re, sys, os
here = os.path.dirname(os.path.abspath(__file__))
hdr = open(os.path.join(here, '../../third_party/xrizer/upstream/openvr/headers/openvr-1.0.17.h'), encoding='utf-8', errors='replace').read()
src = open(os.path.join(here, '../src/xrizer_guest_bridge.c'), encoding='utf-8').read()
assert 'IVROverlay_Version = "IVROverlay_018"' in hdr
start = hdr.index('\tclass IVROverlay\n')
end = hdr.index('static const char * const IVROverlay_Version', start)
body = re.sub(r'/\*.*?\*/', '', hdr[start:end], flags=re.S)
body = re.sub(r'//[^\n]*', '', body)
decls = [re.sub(r'\s+', ' ', d) for d in re.findall(r'virtual\s+([^;]*?)\s*=\s*0\s*;', body, flags=re.S)]
def split_args(sig):
    inner = sig[sig.index('(') + 1:sig.rindex(')')]
    depth, cur, out = 0, '', []
    for ch in inner:
        if ch == '(':
            depth += 1
        if ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur.strip()); cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out
header = []
for d in decls:
    name = re.search(r'(\w+)\s*\(', d).group(1)
    header.append((name, split_args(d)))
m = re.search(r'overlay_names\[(\d+)\]\s*=\s*\{([^}]*)\}', src)
names = re.findall(r'"(\w+)"', m.group(2))
fail = 0
if len(header) != 82 or len(names) != 82 or int(m.group(1)) != 82:
    print('slot count: header %d, bridge %d' % (len(header), len(names))); fail += 1
for i, ((hn, args), bn) in enumerate(zip(header, names)):
    if hn != bn:
        print('slot %d: header %s, bridge %s' % (i, hn, bn)); fail += 1
        continue
    f = re.search(r'static WINAPI \w[\w \*]*? overlay_%d\(guest_object \*self((?:, [^)]*)?)\)' % i, src)
    if not f:
        print('slot %d (%s): no forwarder overlay_%d' % (i, hn, i)); fail += 1; continue
    params = [p for p in f.group(1).split(',') if p.strip()]
    if len(params) != len(args):
        print('slot %d (%s): header has %d parameters, forwarder %d' % (i, hn, len(args), len(params))); fail += 1
        continue
    for a, p in zip(args, params):
        isf = bool(re.match(r'(const\s+)?float\s+\w', a))
        if isf != p.strip().startswith('float '):
            print('slot %d (%s): float mismatch: %s vs %s' % (i, hn, a, p.strip())); fail += 1
    byval2 = [a for a in args if re.match(r'HmdVector2_t\s+\w', a)]
    if byval2 and not any('overlay_vec2' in p for p in params):
        print('slot %d (%s): HmdVector2_t by value not declared' % (i, hn)); fail += 1
    byrect = [a for a in args if re.match(r'HmdRect2_t\s+\w', a)]
    if byrect and not any('overlay_rect2' in p for p in params):
        print('slot %d (%s): HmdRect2_t by value not declared' % (i, hn)); fail += 1
    sm = re.search(r'overlay_table\[%d\]\s*=\s*overlay_%d;' % (i, i), src)
    if not sm:
        print('slot %d (%s): not installed' % (i, hn)); fail += 1
print('xrizer_overlay_slots_check: %s' % ('FAILED (%d)' % fail if fail else 'ok (82 slots, IVROverlay_018, openvr 1.0.17 order)'))
sys.exit(1 if fail else 0)
