#!/usr/bin/env python3 -I
"""jt_roots.py <dll> <known root RVA, hex>... : find the pointer tables (runs of 64-bit absolute code addresses in the image's data) that
contain the given RVAs, and print every RVA in those tables, one per line, as 0x<preferred base + RVA> (roots for vxrt-aot).

For the jump tables of an interpreter loop whose bound the generator cannot recover (Lua's luaV_execute in SkyUI-VR.dll): a profile run
(VXRT_AOT_MISSES) finds some entries; the table has the rest."""
import struct, sys
d = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]; n = struct.unpack_from('<H', d, pe + 6)[0]; opt = pe + 24
base = struct.unpack_from('<Q', d, opt + 24)[0]; so = opt + struct.unpack_from('<H', d, pe + 20)[0]
secs = [(d[so + i*40:so + i*40 + 8].rstrip(b'\0').decode(),) + struct.unpack_from('<IIII', d, so + i*40 + 8) + (struct.unpack_from('<I', d, so + i*40 + 36)[0],) for i in range(n)]
code = [(va, va + vs) for nm, vs, va, rs, rp, ch in secs if ch & 0x20000000]
def is_code(a): return any(lo <= a - base < hi for lo, hi in code)
known = {int(x, 16) for x in sys.argv[2:]}
out = set()
for nm, vs, va, rs, rp, ch in secs:
    if ch & 0x20000000: continue
    blob = d[rp:rp + min(vs, rs)]
    for al in range(0, len(blob) - 7, 8):
        v = struct.unpack_from('<Q', blob, al)[0]
        if is_code(v) and (v - base) in known:
            lo = al
            while lo >= 8 and is_code(struct.unpack_from('<Q', blob, lo - 8)[0]): lo -= 8
            hi = al
            while hi + 16 <= len(blob) and is_code(struct.unpack_from('<Q', blob, hi + 8)[0]): hi += 8
            for q in range(lo, hi + 8, 8): out.add(struct.unpack_from('<Q', blob, q)[0] - base)
            print('table in %s at rva %#x: %d entries' % (nm, va + lo, (hi - lo) // 8 + 1), file=sys.stderr)
for r in sorted(out): print('0x%x' % (base + r))
