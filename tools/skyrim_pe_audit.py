#!/usr/bin/env python3
"""Read-only PE32+ aggregate metadata audit; requires a locally built x86dec dylib."""
import collections
import ctypes
import hashlib
import json
import math
import struct
import sys
from pathlib import Path


def audit(path, lib):
    data = Path(path).read_bytes()
    u16 = lambda o: struct.unpack_from('<H', data, o)[0]
    u32 = lambda o: struct.unpack_from('<I', data, o)[0]
    pe = u32(0x3c)
    if data[:2] != b'MZ' or data[pe:pe + 4] != b'PE\0\0' or u16(pe + 24) != 0x20b:
        raise ValueError('expected PE32+')
    n, opts = u16(pe + 6), u16(pe + 20)
    opt = pe + 24
    entry = u32(opt + 16)
    exc, excsize = u32(opt + 112 + 3 * 8), u32(opt + 116 + 3 * 8)
    sections = []
    for i in range(n):
        o = opt + opts + i * 40
        name = data[o:o + 8].split(b'\0')[0].decode('ascii', 'replace')
        vs, va, rawsz, raw = struct.unpack_from('<IIII', data, o + 8)
        flags = u32(o + 36)
        sections.append(dict(name=name, va=va, vs=vs, rawsz=rawsz, raw=raw, executable=bool(flags & 0x20000000)))
    def section(rva, size=1, raw=False):
        for s in sections:
            length = s['rawsz'] if raw else max(s['vs'], s['rawsz'])
            if s['va'] <= rva and rva + size <= s['va'] + length:
                return s
        return None
    def offset(rva, size=1):
        s = section(rva, size, True)
        return s['raw'] + rva - s['va'] if s and s['raw'] + rva - s['va'] + size <= len(data) else None
    def decode(rva):
        o = offset(rva, 1)
        if o is None:
            return None
        s = section(rva, 1, True)
        b = data[o:min(o + 15, s['raw'] + s['rawsz'], len(data))]
        buf = ctypes.create_string_buffer(b)
        out = ctypes.create_string_buffer(1024)
        return lib.x86_decode(buf, len(b), out)
    counts = collections.Counter()
    ranges = collections.defaultdict(list)
    rootdecode = collections.Counter()
    pos = offset(exc, excsize) if excsize else None
    if excsize and pos is None:
        raise ValueError('exception directory not entirely file-backed')
    for i in range(excsize // 12):
        begin, end, unwind = struct.unpack_from('<III', data, pos + 12 * i)
        s = section(begin)
        good = bool(s and s['executable'] and end > begin and section(end - 1) is s)
        counts['entries'] += 1
        counts['valid_executable_range' if good else 'invalid_executable_range'] += 1
        counts['unwind_file_backed' if offset(unwind & ~1) is not None else 'unwind_not_file_backed'] += 1
        if good:
            counts['range_' + s['name']] += 1
            ranges[s['name']].append((begin, end))
            d = decode(begin)
            rootdecode['decoded' if d and d > 0 else 'not_decoded_or_unbacked'] += 1
    result = dict(path=str(path), sha256=hashlib.sha256(data).hexdigest(), file_bytes=len(data), entry_rva=hex(entry), entry_section=(section(entry) or {}).get('name'), entry_decodes=bool(decode(entry)), exception_directory_bytes=excsize, pdata=dict(counts), pdata_start_decode=dict(rootdecode), sections=[])
    for s in sections:
        if not s['executable']:
            continue
        blob = data[s['raw']:s['raw'] + min(s['rawsz'], s['vs'])]
        def entropy(b):
            c = collections.Counter(b)
            return -sum((v / len(b)) * math.log2(v / len(b)) for v in c.values()) if b else 0
        pages = [entropy(blob[i:i + 4096]) for i in range(0, len(blob), 4096) if len(blob[i:i + 4096]) == 4096]
        merged = []
        for a, b in sorted(ranges[s['name']]):
            if merged and a <= merged[-1][1]: merged[-1] = (merged[-1][0], max(b, merged[-1][1]))
            else: merged.append((a, b))
        result['sections'].append(dict(name=s['name'], rva=hex(s['va']), virtual_bytes=s['vs'], file_backed_bytes=len(blob), entropy=round(entropy(blob), 4), full_pages=len(pages), pages_entropy_ge_7_9=sum(x >= 7.9 for x in pages), pages_entropy_lt_6=sum(x < 6 for x in pages), zero_90_cc_bytes=sum(blob.count(bytes([x])) for x in (0, 0x90, 0xcc)), pdata_union_bytes=sum(b-a for a,b in merged)))
    return result


def main():
    lib = ctypes.CDLL(sys.argv[1])
    lib.x86_decode.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    lib.x86_decode.restype = ctypes.c_int
    print(json.dumps([audit(p, lib) for p in sys.argv[2:]], indent=2))

if __name__ == '__main__':
    main()
