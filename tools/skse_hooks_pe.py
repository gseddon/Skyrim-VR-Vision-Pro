#!/usr/bin/env python3 -I
"""Build the synthetic hooks module for the static script-extender scheme (research/2026-11-11-skse-vr-on-aot.md).

A capture (VXRT_CODE_CAPTURE, VXRuntime/src/codehooks.c) holds the executable memory a script extender wrote ("R" line).
This writes a minimal x86-64 PE DLL whose one section is that memory at a fixed base, so the AOT compiler can translate
the stubs and the runtime serves the extender's executable allocations from it (VXRT_EXEC_REGION). Without --capture the
section is zero (the module the capture run itself uses).

  skse_hooks_pe.py --base 0x307000000 --size 0x100000 --out vxrt_hooks.dll [--capture capture.txt --image host.exe=0x308000000 ... --roots roots.txt]

--roots writes the stubs' entry addresses (targets of E8/E9 rel32 patches in the capture that land in the section), one
hex address per line, for vxrt-aot (VXRT_AOT_ROOTS). --image NAME=BASE gives the base each patched image is mapped at.
"""
import argparse
import struct
import sys


def build(base, size, content):
    assert size % 0x1000 == 0 and len(content) <= size
    hdr = bytearray(0x200)
    hdr[0:2] = b'MZ'
    struct.pack_into('<I', hdr, 0x3c, 0x40)
    hdr[0x40:0x44] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', hdr, 0x44, 0x8664, 1, 0, 0, 0, 240, 0x2022)
    o = 0x58
    struct.pack_into('<HBBIIIII', hdr, o, 0x20b, 14, 0, size, 0, 0, 0, 0x1000)   # magic, linker, code size, entry 0, base of code
    struct.pack_into('<QIIHHHHHHIIIIHHQQQQII', hdr, o + 24, base, 0x1000, 0x200, 6, 0, 0, 0, 6, 0, 0,
                     0x1000 + size, 0x200, 0, 3, 0x8120, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    sec = o + 112 + 16 * 8
    hdr[sec:sec + 8] = b'.hook\0\0\0'
    struct.pack_into('<IIIIIIHHI', hdr, sec + 8, size, 0x1000, size, 0x200, 0, 0, 0, 0, 0xE0000020)
    return bytes(hdr) + bytes(content) + bytes(size - len(content))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--base', required=True)
    ap.add_argument('--size', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--capture')
    ap.add_argument('--image', action='append', default=[])
    ap.add_argument('--roots')
    ap.add_argument('--exe-roots', help='write the addresses in the region that point into the program image, as roots for its module '
                    '(where a stub jumps back to: after the bytes a hook replaced, which nothing else reaches); needs --exe-base/-preferred/-size')
    ap.add_argument('--exe-base'); ap.add_argument('--exe-preferred'); ap.add_argument('--exe-size')
    a = ap.parse_args()
    base, size = int(a.base, 16), int(a.size, 16)
    bases = {k.lower(): int(v, 16) for k, v in (x.split('=') for x in a.image)}
    content = bytearray()
    patches = []
    pointers = []     # 'T' lines: pointers into the region written into data (vtable swaps)
    if a.capture:
        with open(a.capture) as f:
            for line in f:
                p = line.split()
                if len(p) not in (4, 5):        # (P lines may carry the original bytes as a fifth field)
                    continue
                if p[0] == 'R':
                    off = int(p[2], 16)
                    assert off == 0x1000, 'region offset %#x: the region is the first section at RVA 0x1000' % off
                    content = bytearray.fromhex(p[3])
                elif p[0] == 'T':
                    pointers.append(int(p[3], 16))
                elif p[0] == 'P':
                    patches.append((p[1].lower(), int(p[2], 16), bytes.fromhex(p[3])))
    roots = set()
    for name, rva, data in patches:
        if name not in bases:
            continue
        for i in range(0, max(0, len(data) - 4)):
            # a patch run that starts after the opcode byte (unchanged bytes are not in the run) is found by its rel32 alone only
            # when the opcode is inside the run; the other form is resolved from the opcode in the running image, see --image
            if data[i] in (0xe8, 0xe9):
                rel = struct.unpack_from('<i', data, i + 1)[0]
                t = bases[name] + rva + i + 5 + rel
                if base + 0x1000 <= t < base + 0x1000 + len(content):
                    roots.add(t)
    lo, hi = base + 0x1000, base + 0x1000 + len(content)
    # rel32 patches through a pointer slot (FF 15 / FF 25: Write6Branch/Write6Call): the slot is in the region and holds the stub
    for name, rva, data in patches:
        if name not in bases:
            continue
        for i in range(0, max(0, len(data) - 5)):
            if data[i] == 0xff and data[i + 1] in (0x15, 0x25):
                slot = bases[name] + rva + i + 6 + struct.unpack_from('<i', data, i + 2)[0]
                if lo <= slot and slot + 8 <= hi:
                    t = struct.unpack_from('<Q', content, slot - lo)[0]
                    if lo <= t < hi:
                        roots.add(t)
    roots.update(pointers)
    # and any 8-byte value inside the region that points into it (a stub reached through a data pointer): a root is harmless if it
    # is not code, the generator refuses what it cannot decode
    for i in range(0, max(0, len(content) - 7)):
        t = struct.unpack_from('<Q', content, i)[0]
        if lo <= t < hi:
            roots.add(t)
    if a.exe_roots:
        eb, ep, es = int(a.exe_base, 16), int(a.exe_preferred, 16), int(a.exe_size, 16)
        er = set()
        for i in range(0, max(0, len(content) - 7)):
            t = struct.unpack_from('<Q', content, i)[0]
            if eb <= t < eb + es:
                er.add(t - eb + ep)       # (the pipeline shifts roots from the preferred base)
        open(a.exe_roots, 'w').write(''.join('%x\n' % r for r in sorted(er)))
        print('%d roots in the program image' % len(er), file=sys.stderr)
    open(a.out, 'wb').write(build(base, size, content))
    if a.roots:
        open(a.roots, 'w').write(''.join('%x\n' % r for r in sorted(roots)))
    print('%s: base %#x, %#x bytes, %d bytes of code, %d roots' % (a.out, base, size, len(content), len(roots)), file=sys.stderr)


main()
