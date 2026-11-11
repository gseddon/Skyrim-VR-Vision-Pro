#!/usr/bin/env python3
"""tools/skyrim_device_stage.py on a fake tree: file selection, what the headset lacks, the dry run. No device."""
import json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import skyrim_device_stage as S


class Stage(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        a = self.t / 'game'
        (a / 'Data' / 'Strings').mkdir(parents=True)
        for n, c in (('Data/Skyrim.esm', 'esm'), ('Data/Strings/x.STRINGS', 's'), ('Skyrim.ini', 'i'), ('High.ini', 'h'),
                     ('SkyrimVR.exe', 'orig'), ('_CommonRedist/vc.exe', 'no'), ('binkw64.dll', 'b')):
            (a / n).parent.mkdir(parents=True, exist_ok=True); (a / n).write_text(c)
        self.prep = self.t / 'prep.exe'; self.prep.write_text('prepared')
        self.inp = self.t / 'inputs'; self.inp.mkdir()
        for n in S.STAGED_DLLS:
            (self.inp / n).write_text(n)
        self.a = a

    def test_selection(self):
        f = S.plan(self.a, self.prep, self.inp, self.t / 'redist')
        self.assertIn('Data/Strings/x.STRINGS', f)
        self.assertEqual(f['SkyrimVR.exe'], self.prep)            # the prepared one, never the original
        self.assertNotIn('_CommonRedist/vc.exe', f)
        self.assertEqual(f['binkw64.dll'], self.inp / 'binkw64.dll')

    def test_missing_input(self):
        (self.inp / 'msvcp140.dll').unlink()
        with self.assertRaises(S.Missing):
            S.plan(self.a, self.prep, self.inp, self.t / 'redist')

    def test_resume(self):
        f = S.plan(self.a, self.prep, self.inp, self.t / 'redist')
        listing = {'result': {'files': [{'relativePath': 'Documents/root/SkyrimVR/Data/Skyrim.esm', 'size': 3},
                                         {'relativePath': 'Documents/root/SkyrimVR/Skyrim.ini', 'size': 99}]}}
        todo = S.missing_files(f, S.on_device(listing))
        self.assertNotIn('Data/Skyrim.esm', todo)                 # present, same size
        self.assertIn('Skyrim.ini', todo)                         # present, other size
        self.assertIn('SkyrimVR.exe', todo)

    def test_dry_run_exit_codes(self):
        env = dict(os.environ, VXRT_LOCAL_ENV='/nonexistent', VXRT_PRIVATE_ROOT=str(self.t / 'priv'))
        for k in ('VXRT_DEVICE_ID', 'SKYRIM_ASSET_ROOT', 'XROS_BUNDLE_PREFIX'):
            env.pop(k, None)
        r = subprocess.run([sys.executable, str(ROOT / 'tools/skyrim_device_stage.py')], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2); self.assertIn('is not set', r.stderr)


if __name__ == '__main__':
    unittest.main()
