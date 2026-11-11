import re, sys, os
here = os.path.dirname(os.path.abspath(__file__))
HDRS = os.path.join(here, '../../third_party/xrizer/upstream/openvr/headers/')
src = open(os.path.join(here, '../src/xrizer_guest_bridge.c'), encoding='utf-8').read()
# (bridge prefix, interface version string, pinned header, C++ class name, slot count)
IFACES = [('overlay', 'IVROverlay_018', 'openvr-1.0.17.h', 'IVROverlay', 82),
          ('rendermodels', 'IVRRenderModels_005', 'openvr-1.0.9.h', 'IVRRenderModels', 18),
          ('settings', 'IVRSettings_002', 'openvr-1.0.17.h', 'IVRSettings', 12)]
fail = 0
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
def check(prefix, version, header_file, cls, count):
    global fail
    hdr = open(HDRS + header_file, encoding='utf-8', errors='replace').read()
    vname = re.sub(r'_\d+$', '', version)
    assert '%s_Version = "%s"' % (vname, version) in hdr, (version, header_file)
    start = re.search(r'\n\s*class %s\n' % cls, hdr).start()
    end = hdr.index('static const char * const %s_Version' % vname, start)
    body = re.sub(r'/\*.*?\*/', '', hdr[start:end], flags=re.S)
    body = re.sub(r'//[^\n]*', '', body)
    decls = [re.sub(r'\s+', ' ', d) for d in re.findall(r'virtual\s+([^;]*?)\s*=\s*0\s*;', body, flags=re.S)]
    header = [(re.search(r'(\w+)\s*\(', d).group(1), split_args(d)) for d in decls]
    m = re.search(r'%s_names\[(\d+)\]\s*=\s*\{([^}]*)\}' % prefix, src)
    names = re.findall(r'"(\w+)"', m.group(2))
    before = fail
    if len(header) != count or len(names) != count or int(m.group(1)) != count:
        print('%s slot count: header %d, bridge %d, expected %d' % (version, len(header), len(names), count)); fail += 1
    for i, ((hn, args), bn) in enumerate(zip(header, names)):
        if hn != bn:
            print('%s slot %d: header %s, bridge %s' % (version, i, hn, bn)); fail += 1
            continue
        f = re.search(r'static WINAPI \w[\w \*]*? %s_%d\(guest_object \*self((?:, [^)]*)?)\)' % (prefix, i), src)
        if not f:
            print('%s slot %d (%s): no forwarder' % (version, i, hn)); fail += 1; continue
        params = [p for p in f.group(1).split(',') if p.strip()]
        if len(params) != len(args):
            print('%s slot %d (%s): header has %d parameters, forwarder %d' % (version, i, hn, len(args), len(params))); fail += 1
            continue
        for a, p in zip(args, params):
            isf = bool(re.match(r'(const\s+)?float\s+\w', a))
            if isf != p.strip().startswith('float '):
                print('%s slot %d (%s): float mismatch: %s vs %s' % (version, i, hn, a, p.strip())); fail += 1
            if re.match(r'HmdVector2_t\s+\w', a) and 'overlay_vec2' not in p:
                print('%s slot %d (%s): HmdVector2_t by value not declared' % (version, i, hn)); fail += 1
            if re.match(r'HmdRect2_t\s+\w', a) and 'overlay_rect2' not in p:
                print('%s slot %d (%s): HmdRect2_t by value not declared' % (version, i, hn)); fail += 1
        if not re.search(r'%s_table\[%d\]\s*=\s*%s_%d;' % (prefix, i, prefix, i), src):
            print('%s slot %d (%s): not installed' % (version, i, hn)); fail += 1
    print('xrizer_overlay_slots_check: %s %s (%d slots, %s %s order)' % (version, 'FAILED' if fail > before else 'ok', count, header_file, cls))
for spec in IFACES:
    check(*spec)
sys.exit(1 if fail else 0)
