import gzip, importlib.machinery, importlib.util, os, tempfile, time, unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / 'tools' / 'shader_manifest_build'
loader = importlib.machinery.SourceFileLoader('shader_manifest_build', str(TOOL))
m = importlib.util.module_from_spec(importlib.util.spec_from_loader('shader_manifest_build', loader)); loader.exec_module(m)

ROWS = ['%064x\tps\tbase\t\t1\t%016x' % (i + 1, i + 1) for i in range(3)]
TEXT = '# vxrt-shader-manifest 1\n# translator=1\n' + '\n'.join(ROWS) + '\n'


class Stamp(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory(); self.out = Path(self.d.name) / 'out'; (self.out / 'pending').mkdir(parents=True)
        self.mf = Path(self.d.name) / 'm.tsv'; self.mf.write_text(TEXT)
        self.header, self.entries = m.read_manifest(str(self.mf))
    def tearDown(self): self.d.cleanup()

    def test_content_not_mtime_decides(self):
        want = m.stamp_text(str(self.mf), self.header, 'xros')
        self.assertFalse(m.is_complete(str(self.out), want, self.entries))
        (self.out / '.complete').write_text(want)
        os.utime(self.mf, (time.time() + 1000, time.time() + 1000))    # a newer manifest file (fresh checkout) is still current
        self.assertTrue(m.is_complete(str(self.out), want, self.entries))
        self.mf.write_text(TEXT.replace('translator=1', 'translator=2'))
        h, e = m.read_manifest(str(self.mf))
        self.assertFalse(m.is_complete(str(self.out), m.stamp_text(str(self.mf), h, 'xros'), e))

    def test_gzip_and_plain_hash_alike(self):
        gz = Path(self.d.name) / 'm.tsv.gz'; gz.write_bytes(gzip.compress(TEXT.encode()))
        self.assertEqual(m.stamp_text(str(gz), self.header, 'xros'), m.stamp_text(str(self.mf), self.header, 'xros'))

    def test_legacy_empty_marker_needs_a_full_ok_report(self):
        (self.out / '.complete').write_text('')
        self.assertFalse(m.is_complete(str(self.out), 'x', self.entries))
        (self.out / 'report.tsv').write_text(''.join('%s\tbase\tk\tok\n' % e[0] for e in self.entries))
        self.assertTrue(m.is_complete(str(self.out), 'x', self.entries))
        (self.out / 'pending' / 'a.metal').write_text('x')
        self.assertFalse(m.is_complete(str(self.out), 'x', self.entries))


if __name__ == '__main__': unittest.main()
