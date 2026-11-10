#!/usr/bin/env python3
"""tools/mods.py with owned, synthetic mods (no game or mod files): priority merge, Plugins.txt, SKSE entries, refusals, deploy dry run."""
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'tools/mods.py'


def esp(masters):
    sub = b''.join(b'MAST' + struct.pack('<H', len(m) + 1) + m.encode() + b'\0' + b'DATA' + struct.pack('<H', 8) + bytes(8) for m in masters)
    hedr = b'HEDR' + struct.pack('<H', 12) + struct.pack('<fII', 1.7, 0, 0x800)
    body = hedr + sub
    return b'TES4' + struct.pack('<IIIII', len(body), 0, 0, 0, 44) + body


class ModsPack(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.root = Path(self.t.name)
    def tearDown(self): self.t.cleanup()
    def mod(self, name, files):
        for rel, data in files.items():
            p = self.root / name / 'Data' / rel; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)
        return name
    def run_tool(self, *args, ok=True):
        r = subprocess.run([sys.executable, '-I', str(TOOL), *map(str, args)], capture_output=True, text=True)
        if ok: self.assertEqual(r.returncode, 0, r.stderr + r.stdout)
        else: self.assertNotEqual(r.returncode, 0)
        return r
    def lst(self, mods):
        p = self.root / 'list.json'; p.write_text(json.dumps(dict(profile='t', mods=mods))); return p

    def test_priority_plugins_skse_and_deploy(self):
        self.mod('a', {'Textures/x.dds': b'LOW', 'Textures/only_a.dds': b'A', 'a.esp': esp(['Skyrim.esm'])})
        self.mod('b', {'textures/X.dds': b'HIGH', 'b.esp': esp(['Skyrim.esm', 'a.esp'])})
        lst = self.lst([
            dict(id='b', name='B', kind='plugin', priority=20, source='b', plugins=['b.esp']),
            dict(id='a', name='A', kind='plugin', priority=10, source='a', plugins=['a.esp'], memory_hint_mb=5),
            dict(id='higgs', name='HIGGS', kind='skse', priority=40, size_bytes=1234),
            dict(id='off', name='Off', kind='files', priority=5, enabled=False)])
        out = self.root / 'pack'
        self.run_tool('build', '--list', lst, '--out', out)
        doc = json.loads((out / 'mods.json').read_text())
        by = {m['id']: m for m in doc['mods']}
        self.assertEqual([m['id'] for m in doc['mods']], ['off', 'a', 'b', 'higgs'])          # priority order
        self.assertTrue(by['a']['active'] and by['b']['active'])
        self.assertFalse(by['higgs']['active']); self.assertTrue(by['higgs']['enabled']); self.assertIn('SKSE', by['higgs']['note'])
        self.assertFalse(by['off']['active'])
        self.assertEqual(next((out / 'merged/Data/Textures').glob('[xX].dds')).read_bytes(), b'HIGH')   # higher priority wins
        self.assertEqual((out / 'merged/Data/Textures/only_a.dds').read_bytes(), b'A')
        self.assertEqual((out / 'Plugins.txt').read_bytes(), b'*a.esp\r\n*b.esp\r\n')
        self.assertEqual((out / 'merged/Plugins.txt').read_bytes(), b'*a.esp\r\n*b.esp\r\n')
        self.assertEqual(doc['totals']['active_mods'], 2); self.assertEqual(doc['totals']['active_memory_hint_mb'], 5)
        self.assertTrue((out / 'mods/a/Data/Textures/x.dds').is_file() and not (out / 'mods/higgs').exists())
        r = self.run_tool('deploy', out, '--bundle', 'com.example.app')
        self.assertIn('Documents/root/mods.json', r.stdout)
        self.assertIn('Skyrim VR/Plugins.txt', r.stdout)
        self.assertIn('Documents/root/overlay_skyrimvr/Data/Textures', r.stdout)
        self.assertIn('dry run', r.stdout)
        self.run_tool('deploy', out, '--bundle', 'x', '--yes', ok=False)       # --yes needs --device
        self.run_tool('show', out)

    def test_refusals(self):
        self.mod('dll', {'x.dll': b'MZ'})
        self.run_tool('build', '--list', self.lst([dict(id='dll', kind='files', priority=1, source='dll')]), '--out', self.root / 'p1', ok=False)
        self.mod('bad', {'bad.esp': esp(['Skyrim.esm', 'Unknown Mod.esp'])})
        self.run_tool('build', '--list', self.lst([dict(id='bad', kind='plugin', priority=1, source='bad', plugins=['bad.esp'])]), '--out', self.root / 'p2', ok=False)
        self.run_tool('build', '--list', self.lst([dict(id='Bad Id', kind='files', priority=1)]), '--out', self.root / 'p3', ok=False)
        self.run_tool('build', '--list', self.lst([dict(id='ok', kind='nope', priority=1)]), '--out', self.root / 'p4', ok=False)
        (self.root / 'link' / 'Data').mkdir(parents=True); (self.root / 'link/Data/l.dds').symlink_to('/etc/hosts')
        self.run_tool('build', '--list', self.lst([dict(id='link', kind='files', priority=1, source='link')]), '--out', self.root / 'p5', ok=False)

    def test_existing_output_needs_force(self):
        self.mod('a', {'t.dds': b'1'})
        lst = self.lst([dict(id='a', kind='files', priority=1, source='a')]); out = self.root / 'pk'
        self.run_tool('build', '--list', lst, '--out', out)
        self.run_tool('build', '--list', lst, '--out', out, ok=False)
        self.run_tool('build', '--list', lst, '--out', out, '--force')


if __name__ == '__main__':
    unittest.main()
