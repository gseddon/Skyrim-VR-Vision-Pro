import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import vxrt_runtime_sessions as sessions

CHECKOUT = Path('/repo')
USER = ['/drive/vxrt_root', '/drive/vxrt_steam_overlay']
OWN = '/repo/build/probe-7'
RT = '/repo/VXRuntime/build/vxrt-arm64'


def run(procs, own=(OWN,), own_tmp=None, cwd=None, gone=()):
    """procs: [(pid, ucomm, command, (exe, argv, env) or None)]"""
    table = {p[0]: p[3] for p in procs}
    return sessions.preconditions(list(own), own_tmp, USER, checkouts=[CHECKOUT],
                                  ps=lambda: [p[:3] for p in procs], args=table.get,
                                  cwd_of=lambda pid: (cwd or {}).get(pid), alive_of=lambda pid: pid not in gone)


def vxrt(pid, env, argv=('game.exe',), exe=RT):
    return (pid, Path(exe).name[:16], ' '.join((exe,) + tuple(argv)), (exe, [exe, *argv], env))


class SessionsTest(unittest.TestCase):
    def verdict(self, checks):
        return {c['code']: c['ok'] for c in checks}

    def test_nothing_running(self):
        checks, concurrent = run([])
        self.assertEqual(self.verdict(checks), dict(user_not_playing=True, run_paths_unshared=True))
        self.assertEqual(concurrent, [])

    def test_users_vxrt_game_refused(self):
        checks, _ = run([vxrt(10, {'VXRT_ROOT': '/drive/vxrt_root', sessions.MARKER: '/elsewhere'})])
        self.assertFalse(self.verdict(checks)['user_not_playing'])
        self.assertIn("user's root", checks[0]['detail'])

    def test_default_root_refused(self):
        checks, _ = run([vxrt(11, {})])
        self.assertFalse(self.verdict(checks)['user_not_playing'])
        self.assertIn('default root', checks[0]['detail'])

    def test_vrserver_and_wine_refused(self):
        for proc in [(12, 'vrserver', '/Applications/SteamVR/vrserver', None),
                     (13, 'vrcompositor', 'vrcompositor', None),
                     (14, 'wine64-preloader', 'wine64-preloader C:\\SkyrimVR.exe', None)]:
            checks, _ = run([proc])
            self.assertFalse(self.verdict(checks)['user_not_playing'], proc)

    def test_owned_runtime_hosting_steamvr_refused(self):
        checks, _ = run([vxrt(15, {'VXRT_ROOT': '/repo/build/x/root'}, argv=('C:\\SteamVR\\bin\\win64\\vrserver.exe',))])
        self.assertFalse(self.verdict(checks)['user_not_playing'])

    def test_unmarked_vxrt_outside_repo_refused(self):
        checks, concurrent = run([vxrt(16, {'VXRT_ROOT': '/scratch/someone/root'})])
        self.assertFalse(self.verdict(checks)['user_not_playing'])
        self.assertIn('no VXRT_HARNESS_RUN marker', checks[0]['detail'])
        self.assertEqual(concurrent, [])

    def test_unreadable_environment_refused(self):
        checks, _ = run([(17, 'vxrt-arm64', RT + ' game.exe', None)])
        self.assertFalse(self.verdict(checks)['user_not_playing'])
        self.assertIn('environment unreadable', checks[0]['detail'])

    def test_process_gone_since_listing_ignored(self):
        self.assertTrue(all(c['ok'] for c in run([(40, 'vxrt-arm64', RT, None)], gone={40})[0]))
        self.assertTrue(all(c['ok'] for c in run([(41, '(vxrt-arm64)', '(vxrt-arm64)', None)])[0]))

    def test_owned_fixture_under_repo_build_allowed_and_recorded(self):
        # make check: VXRT_ROOT=build/root relative to VXRuntime/
        checks, concurrent = run([vxrt(18, {'VXRT_ROOT': 'build/root'}, argv=('build/hello_k32.exe',))],
                                 cwd={18: '/repo/VXRuntime'})
        self.assertEqual(self.verdict(checks), dict(user_not_playing=True, run_paths_unshared=True))
        self.assertEqual(concurrent[0]['pid'], 18)
        self.assertEqual(concurrent[0]['owner'], 'fixture')
        self.assertEqual(concurrent[0]['root'], '/repo/VXRuntime/build/root')
        self.assertIn('pid 18 fixture /repo/VXRuntime/build/root', checks[0]['detail'])

    def test_relative_root_without_cwd_refused(self):
        checks, _ = run([vxrt(19, {'VXRT_ROOT': 'build/root'})])
        self.assertFalse(self.verdict(checks)['user_not_playing'])

    def test_repo_root_outside_build_dir_not_fixture(self):
        checks, _ = run([vxrt(20, {'VXRT_ROOT': '/repo/roots/r'})])
        self.assertFalse(self.verdict(checks)['user_not_playing'])

    def test_other_harness_run_allowed_and_recorded(self):
        checks, concurrent = run([vxrt(21, {'VXRT_ROOT': '/scratch/fast_a/root', 'VXRT_OVERLAY': '/games:/scratch/fast_a/overlay',
                                            sessions.MARKER: '/scratch/fast_a'})])
        self.assertTrue(all(c['ok'] for c in checks))
        self.assertEqual((concurrent[0]['owner'], concurrent[0]['run']), ('harness', '/scratch/fast_a'))

    def test_same_run_dir_or_root_refused(self):
        same_run = vxrt(22, {'VXRT_ROOT': '/scratch/r/root', sessions.MARKER: OWN})
        same_root = vxrt(23, {'VXRT_ROOT': OWN + '/root'})
        same_overlay = vxrt(24, {'VXRT_ROOT': '/repo/build/q/root', 'VXRT_OVERLAY': '/games:' + OWN + '/overlay'})
        for proc in (same_run, same_root, same_overlay):
            checks, concurrent = run([proc])
            self.assertEqual(self.verdict(checks), dict(user_not_playing=True, run_paths_unshared=False), proc[0])
            self.assertEqual(concurrent, [])
        checks, _ = run([vxrt(25, {'VXRT_ROOT': '/repo/build/q/root', 'TMPDIR': '/scratch/t'})], own_tmp='/scratch/t')
        self.assertFalse(self.verdict(checks)['run_paths_unshared'])

    def test_lookalike_name_ignored(self):
        checks, _ = run([(26, 'vxrt_mcp', 'python vxrt_mcp.py', None),
                         (27, 'vxrt-arm64-diag-', '/x/vxrt-arm64-diag-004.sh', ('/x/vxrt-arm64-diag-004.sh-wrapper!', [], {}))])
        self.assertTrue(all(c['ok'] for c in checks))

    def test_mixed_reports_each(self):
        checks, concurrent = run([vxrt(30, {'VXRT_ROOT': '/repo/VXRuntime/build/root'}), vxrt(31, {})])
        self.assertFalse(self.verdict(checks)['user_not_playing'])
        self.assertIn('pid 31', checks[0]['detail'])
        self.assertIn('allowed concurrently', checks[0]['detail'])
        self.assertEqual([p['pid'] for p in concurrent], [30])


if __name__ == '__main__':
    unittest.main()
