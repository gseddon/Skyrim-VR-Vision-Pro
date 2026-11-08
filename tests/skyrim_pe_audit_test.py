import ctypes
import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / 'tools' / 'skyrim_pe_audit.py'
spec = importlib.util.spec_from_file_location('audit', MODULE)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class Decoder:
    def x86_decode(self, buf, size, out):
        return 0 if ctypes.string_at(buf, 1) == b'\xff' else 1


class AuditTest(unittest.TestCase):
    def test_ranges_and_roots(self):
        b = bytearray(0x800)
        b[:2] = b'MZ'
        struct.pack_into('<I', b, 0x3c, 0x80)
        b[0x80:0x84] = b'PE\0\0'
        struct.pack_into('<HH', b, 0x84, 0x8664, 2)
        struct.pack_into('<H', b, 0x94, 0xf0)
        opt = 0x98
        struct.pack_into('<H', b, opt, 0x20b)
        struct.pack_into('<I', b, opt + 16, 0x1000)
        struct.pack_into('<II', b, opt + 112 + 24, 0x2000, 36)
        for index, (name, va, raw, flags) in enumerate([(b'.text', 0x1000, 0x400, 0x20000000), (b'.pdata', 0x2000, 0x600, 0x40000000)]):
            off = opt + 0xf0 + index * 40
            b[off:off + len(name)] = name
            struct.pack_into('<IIII', b, off + 8, 0x200, va, 0x200, raw)
            struct.pack_into('<I', b, off + 36, flags)
        b[0x400:0x500] = b'\x90' * 256
        b[0x410] = 0xff
        struct.pack_into('<IIIIIIIII', b, 0x600, 0x1000, 0x1020, 0x2050, 0x1010, 0x1030, 0x2050, 0x1100, 0x2100, 0x2050)
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'fixture.exe'
            path.write_bytes(b)
            result = audit.audit(path, Decoder())
        self.assertEqual(result['entry_section'], '.text')
        self.assertEqual(result['pdata']['valid_executable_range'], 2)
        self.assertEqual(result['pdata']['invalid_executable_range'], 1)
        self.assertEqual(result['pdata_start_decode'], {'decoded': 1, 'not_decoded_or_unbacked': 1})
        self.assertEqual(result['sections'][0]['pdata_union_bytes'], 0x30)


if __name__ == '__main__':
    unittest.main()
