#!/usr/bin/env python3 -I
"""dispatch_roots.py <dll>: roots for an interpreter loop built on computed goto (Lua's luaV_execute in SkyUI-VR.dll).

Every handler ends with `jmp [rbx+rbp*8]` (FF 24 EB) and the next handler starts right after it; the table is filled at run time, so the
AOT generator finds no reference to the handlers. Prints the address after each such jump (padding skipped) as <preferred base + RVA>."""
import re, struct, sys
d = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]; n = struct.unpack_from('<H', d, pe + 6)[0]; opt = pe + 24
base = struct.unpack_from('<Q', d, opt + 24)[0]; so = opt + struct.unpack_from('<H', d, pe + 20)[0]
secs = [struct.unpack_from('<IIII', d, so + i*40 + 8) + (struct.unpack_from('<I', d, so + i*40 + 36)[0],) for i in range(n)]
out = set()
for vs, va, rs, rp, ch in secs:
    if not ch & 0x20000000: continue
    txt = d[rp:rp + min(vs, rs)]
    disp = [m.end() for m in re.finditer(re.escape(bytes([0xff, 0x24, 0xeb])), txt)]
    for o in disp:
        while o < len(txt) and txt[o] in (0xcc, 0x90): o += 1
        if o < len(txt): out.add(va + o)
    # Inside the loop's own extent (first to last dispatch, plus the slow paths after it) a label also follows an unconditional jump
    # (E9 rel32, EB rel8), a RET or an INT3 pad: those addresses are roots too. Some are not instruction starts; the generator refuses
    # what it cannot decode and the run never reaches them.
    if disp:
        lo, hi = disp[0], min(len(txt), disp[-1] + int(sys.argv[2], 0) if len(sys.argv) > 2 else disp[-1] + 0x2000)
        for m in re.finditer(rb'\xe9....|\xeb.|\xc3', txt[lo:hi], re.S):
            o = lo + m.end()
            while o < hi and txt[o] in (0xcc, 0x90): o += 1
            if o < hi: out.add(va + o)
for r in sorted(out): print('0x%x' % (base + r))
