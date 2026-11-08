import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

spec=importlib.util.spec_from_file_location('deps', Path(__file__).resolve().parents[1]/'tools/skyrim_deps.py')
deps=importlib.util.module_from_spec(spec); spec.loader.exec_module(deps)

class PETest(unittest.TestCase):
    def test_import_and_delay_named_and_ordinal(self):
        b=bytearray(0xc00); b[:2]=b'MZ'; struct.pack_into('<I',b,0x3c,0x80); b[0x80:0x84]=b'PE\0\0'
        struct.pack_into('<HH',b,0x84,0x8664,1); struct.pack_into('<H',b,0x94,0xf0); opt=0x98
        struct.pack_into('<H',b,opt,0x20b); struct.pack_into('<Q',b,opt+24,0x140000000)
        struct.pack_into('<II',b,opt+112+8,0x1000,40); struct.pack_into('<II',b,opt+112+13*8,0x1040,64)
        s=opt+0xf0; struct.pack_into('<IIII',b,s+8,0x800,0x1000,0x800,0x400)
        struct.pack_into('<IIIII',b,0x400,0x1100,0,0,0x1080,0x1100)
        struct.pack_into('<IIIIIIII',b,0x440,1,0x1090,0,0x1120,0x1120,0,0,0)
        b[0x480:0x48a]=b'first.dll\0'; b[0x490:0x49a]=b'later.dll\0'
        struct.pack_into('<QQQ',b,0x500,0x1140,0x8000000000000005,0)
        struct.pack_into('<QQ',b,0x520,0x1150,0)
        b[0x542:0x548]=b'Alpha\0'; b[0x552:0x557]=b'Beta\0'
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'x.exe'; p.write_bytes(b); image=deps.PE(p)
            self.assertEqual(image.imports(), [{'dll':'first.dll','symbols':['Alpha','#5']}])
            self.assertEqual(image.imports(True), [{'dll':'later.dll','symbols':['Beta']}])
            self.assertEqual(image.bits,64)

if __name__=='__main__': unittest.main()
