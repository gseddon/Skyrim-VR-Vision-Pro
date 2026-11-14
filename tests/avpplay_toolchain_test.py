#!/usr/bin/env python3
"""tools/avpplay_toolchain on fake trees: what run.sh refuses before any stage runs and in which words (AVP Play shows the line after
"!! build FAILED:"), targets.py's answers, and what stage_sync.py puts into the mirror. No build, no device, no network."""
import os, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
TC = ROOT / 'tools' / 'avpplay_toolchain'
sys.path.insert(0, str(ROOT / 'tools'))
import skyrim_device_stage as S

PY = '/usr/bin/python3' if os.path.exists('/usr/bin/python3') else sys.executable   # the Python run.sh uses


class Adapter(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        g = self.t / 'AVP Play Downloads' / 'game'            # AVP Play's library folder has a blank in its name
        for n, c in (('Data/Skyrim.esm', 'esm'), ('Data/Strings/x.STRINGS', 's'), ('Skyrim.ini', 'i'), ('High.ini', 'h'),
                     ('SkyrimVR.exe', 'orig'), ('_CommonRedist/vc.exe', 'no'), ('binkw64.dll', 'b')):
            (g / n).parent.mkdir(parents=True, exist_ok=True); (g / n).write_text(c)
        self.game = g
        self.steamvr = self.t / 'AVP Play Downloads' / 'steamvr'
        (self.steamvr / 'vrwebhelper' / 'win64').mkdir(parents=True)
        (self.steamvr / 'vrwebhelper' / 'win64' / 'msvcp140.dll').write_text('m')
        self.priv = self.t / 'priv'

    def env(self, **more):
        e = {k: v for k, v in os.environ.items() if not k.startswith(('KLEPTON_', 'KL_LX_', 'VXRT_', 'XROS_', 'SKYRIM_', 'STEAMVR_'))}
        e.update(VXRT_PRIVATE_ROOT=str(self.priv), VXRT_LOCAL_ENV='/dev/null', AVPPLAY_VXRT_PYTHON=PY)
        e.update({k: str(v) for k, v in more.items()})
        return e

    def run_sh(self, *args, **env):
        return subprocess.run(['/bin/sh', str(TC / 'visionos' / 'run.sh'), *args], env=self.env(**env), capture_output=True, text=True)

    def good(self, **more):
        e = dict(KLEPTON_TARGET='skyrimvr', KLEPTON_TEAM='ABCDE12345', KLEPTON_DEVICE='00008142-FAKE', KL_LX_GAME=self.game, KL_LX_SYSROOT=self.steamvr)
        e.update(more)
        return e

    def refused(self, words, code=1, **env):
        r = self.run_sh('device', **env)
        self.assertEqual(r.returncode, code, r.stdout + r.stderr)
        self.assertIn(words, r.stdout)
        self.assertNotIn('== skyrimvr: stage', r.stdout)      # nothing was started
        return r

    def test_usage(self):
        r = self.run_sh()
        self.assertEqual(r.returncode, 2); self.assertIn('usage: run.sh device', r.stdout)

    def test_refusals_in_the_lines_avp_play_reads(self):
        self.refused("!! build FAILED: this toolchain builds Skyrim VR only (target skyrimvr), not 'alyx'", **self.good(KLEPTON_TARGET='alyx'))
        self.refused('!! build FAILED: KLEPTON_TEAM is not set to a 10-character Apple Developer Team ID', **self.good(KLEPTON_TEAM=''))
        self.refused('!! build FAILED: KLEPTON_TEAM is not set', **self.good(KLEPTON_TEAM='SHORT'))
        self.refused('!! no physical Vision Pro: KLEPTON_DEVICE is not set', **self.good(KLEPTON_DEVICE=''))
        self.refused("!! build FAILED: KL_LX_GAME does not point at a SkyrimVR folder", **self.good(KL_LX_GAME=self.t / 'nowhere'))
        self.refused("!! build FAILED: KL_LX_SYSROOT does not hold SteamVR's bin/vrwebhelper/win64 folder", **self.good(KL_LX_SYSROOT=self.t / 'nowhere'))

    def test_a_free_team_is_refused_before_anything_is_built(self):
        self.refused('!! build FAILED: Skyrim VR needs a paid Apple Developer team', **self.good(KLEPTON_EVA='0'))

    def test_a_build_folder_with_a_blank_is_refused(self):
        self.refused('!! build FAILED: the build folder has a blank in its path', **dict(self.good(), VXRT_PRIVATE_ROOT=self.t / 'with blank'))

    def test_game_folders_with_a_blank_reach_the_stages_through_links(self):
        # stopped by the free-team check, which comes after the links are made
        self.refused('paid Apple Developer team', **self.good(KLEPTON_EVA='0'))
        self.assertEqual(os.path.realpath(self.priv / 'avpplay' / 'game'), os.path.realpath(self.game))
        self.assertEqual(os.path.realpath(self.priv / 'avpplay' / 'steamvr-win64'), os.path.realpath(self.steamvr / 'vrwebhelper' / 'win64'))
        self.assertNotIn(' ', str(self.priv / 'avpplay' / 'game'))

    def targets(self, *args):
        return subprocess.run([PY, str(TC / 'visionos' / 'targets.py'), *args], capture_output=True, text=True)

    def test_targets(self):
        self.assertEqual(self.targets('skyrimvr', 'kind').stdout.strip(), 'vxruntime')
        self.assertEqual(self.targets('skyrimvr', 'devicetree').stdout.strip(), 'Documents/root/SkyrimVR')
        self.assertTrue(self.targets('skyrimvr', 'bundle').stdout.strip().endswith('dev.klepton.target.skyrimvr'))
        self.assertEqual(self.targets('alyx', 'kind').returncode, 1)
        self.assertEqual(self.targets('skyrimvr', 'nothing').returncode, 1)
        self.assertEqual(self.targets().returncode, 2)

    def sync(self, *args, **env):
        return subprocess.run([PY, str(TC / 'visionos' / 'stage_sync.py'), *args], env=self.env(**env), capture_output=True, text=True)

    def test_mirror_selection_dry_run(self):
        prep = self.t / 'prep.exe'; prep.write_text('prepared')
        inp = self.t / 'inputs'; inp.mkdir()
        for n in S.STAGED_DLLS:
            (inp / n).write_text(n)
        mirror = self.t / 'mirror'
        r = self.sync('--phase', 'all', '--dry-run', KLEPTON_TARGET='skyrimvr', KL_LX_GAME=self.game, KL_LX_MIRROR=mirror,
                      VXRT_PREPARED_EXE=prep, VXRT_AOT_INPUTS=inp, VXRT_REDIST_DIR=self.t / 'redist')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('-> Documents/root/SkyrimVR', r.stdout); self.assertIn('dry run', r.stdout)
        have = sorted(p.relative_to(mirror).as_posix() for p in mirror.rglob('*') if p.is_file())
        self.assertIn('Data/Skyrim.esm', have); self.assertIn('Data/Strings/x.STRINGS', have); self.assertIn('Skyrim.ini', have)
        self.assertNotIn('_CommonRedist/vc.exe', have)                         # not what the app reads
        self.assertEqual((mirror / 'SkyrimVR.exe').read_text(), 'prepared')   # the prepared exe, never the original
        self.assertEqual((mirror / 'binkw64.dll').read_text(), 'binkw64.dll')  # the staged DLL, not the game folder's
        self.assertEqual((self.game / 'SkyrimVR.exe').read_text(), 'orig')     # the game folder is only read

    def test_sync_refusals(self):
        r = self.sync('--phase', 'all', '--dry-run', KLEPTON_TARGET='skyrimvr', KL_LX_GAME=self.t / 'nowhere')
        self.assertEqual(r.returncode, 1); self.assertIn('!! KL_LX_GAME does not point at a SkyrimVR folder', r.stderr)
        r = self.sync('--phase', 'all', '--dry-run', KLEPTON_TARGET='alyx', KL_LX_GAME=self.game)
        self.assertEqual(r.returncode, 1); self.assertIn('!! this toolchain has no target', r.stderr)
        r = self.sync('--phase', 'all', '--dry-run', KLEPTON_TARGET='skyrimvr', KL_LX_GAME=self.game, KL_LX_MIRROR=self.t / 'm2',
                      VXRT_PREPARED_EXE=self.t / 'absent.exe', VXRT_AOT_INPUTS=self.t / 'absent', VXRT_REDIST_DIR=self.t / 'absent')
        self.assertEqual(r.returncode, 1); self.assertIn('!! no prepared SkyrimVR.exe', r.stderr)


class Mods(unittest.TestCase):
    """KLEPTON_GAME_MODS: the sets of visionos/mods.json and the list the stages get (vx_mods.py). No downloads."""
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())

    def vx(self, cmd, mods=None):
        e = {k: v for k, v in os.environ.items() if not k.startswith(('KLEPTON_', 'VXRT_'))}
        e['VXRT_PRIVATE_ROOT'] = str(self.t)
        if mods is not None:
            e['KLEPTON_GAME_MODS'] = mods
        return subprocess.run([PY, str(TC / 'visionos' / 'vx_mods.py'), cmd], env=e, capture_output=True, text=True)

    def test_sets(self):
        self.assertEqual(self.vx('sets').stdout.split(), [])                     # unset: the plain game
        self.assertEqual(self.vx('sets', '').stdout.split(), [])
        self.assertEqual(self.vx('sets', 'core').stdout.split(), ['core'])
        self.assertEqual(self.vx('sets', 'skyland, core').stdout.split(), ['core', 'skyland'])   # the file's order, blanks allowed
        r = self.vx('sets', 'bogus')
        self.assertNotEqual(r.returncode, 0); self.assertIn('!! mods: this toolchain has no mod set bogus', r.stdout + r.stderr)

    def test_sets_name_entries_of_the_projects_list(self):
        import json
        desc = json.loads((TC / 'visionos' / 'mods.json').read_text())
        ids = {m['id'] for m in json.loads((ROOT / 'mods' / 'default.json').read_text())['mods']}
        named = [i for s in desc['sets'] for i in s['entries']]
        self.assertTrue(named); self.assertEqual([i for i in named if i not in ids], [])
        self.assertEqual({s['id'] for s in desc['sets']}, {'core', 'skyland'})
        self.assertTrue(all(s.get('default') is False for s in desc['sets']))   # nothing is on unless the player chooses it

    def test_list_enables_exactly_the_chosen_sets(self):
        import json
        desc = json.loads((TC / 'visionos' / 'mods.json').read_text())
        core = set(next(s['entries'] for s in desc['sets'] if s['id'] == 'core'))
        r = self.vx('list', 'core')
        self.assertEqual(r.returncode, 0, r.stderr)
        path = Path(r.stdout.strip()); self.assertTrue(str(path).startswith(str(self.t)))
        got = {m['id'] for m in json.loads(path.read_text())['mods'] if m.get('enabled')}
        self.assertEqual(got, core)


if __name__ == '__main__':
    unittest.main()
