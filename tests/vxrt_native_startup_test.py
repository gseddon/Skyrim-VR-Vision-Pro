import argparse
import importlib.util
import json
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import vxrt_native_startup as probe


class Child:
    rc = 0
    timeout = False
    log = b'[vxrt] aot: 4 entries into recompiled code, 0 C function calls, 8 native calls, 0 built-in export stubs followed, 0 fallbacks to the translator (0 addresses), 0 ordered accesses across 16 bytes\n'
    pid = 12345

    def __init__(self, cmd, **kwargs):
        self.calls = 0
        self.env = kwargs['env']
        kwargs['stdout'].write(self.log)

    def wait(self, timeout=None):
        self.calls += 1
        if self.timeout and self.calls == 1:
            raise subprocess.TimeoutExpired('fixture', timeout)
        return self.rc


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1]/'build')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.asset = self.root/'assets'; self.asset.mkdir()
        self.exe = self.root/'fixture.exe'
        b = bytearray(128); b[:2] = b'MZ'; struct.pack_into('<I', b, 60, 64)
        b[64:68] = b'PE\0\0'; struct.pack_into('<H', b, 68, 0x8664); struct.pack_into('<H', b, 88, 0x20b)
        self.exe.write_bytes(b)
        self.runtime = self.root/'vxrt-arm64'; self.runtime.write_bytes(b'fake'); self.runtime.chmod(0o755)
        self.aot = self.root/'aot'; self.aot.mkdir()
        (self.aot/f'fixture.exe-{probe.pe_hash(self.exe):016x}.dylib').write_bytes(b'module')
        self.args = argparse.Namespace(exe=str(self.exe), runtime=str(self.runtime), aot_dir=str(self.aot), asset_root=str(self.asset), dll_dir=[], out=str(self.root/'out'), seconds=1)
        Child.rc=0; Child.timeout=False
        self.base_log = Child.log
        patches = [patch.object(probe, 'REPO', self.root), patch.object(probe, 'cpu_types', return_value={0x0100000c}),
                   patch.object(probe.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', '')),
                   patch.object(probe.subprocess, 'check_output', return_value='testrev\n'),
                   patch.object(probe.subprocess, 'Popen', Child), patch.object(probe.os, 'killpg'), patch.object(probe.ledger, 'append')]
        for p in patches:
            p.start(); self.addCleanup(p.stop)

    def tearDown(self):
        Child.log = self.base_log

    def test_exit_counters_and_validation(self):
        r=probe.capture(self.args)
        self.assertEqual(r['status'], 'observed')
        self.assertEqual(r['level'], None)
        self.assertEqual(probe.validate(r), [])
        facts={o['metric']:o['value'] for o in r['observed']}
        self.assertTrue(facts['aot_executed'] and facts['zero_fallback_reported'])
        self.assertEqual(r['environment']['VXRT_AOT_STRICT'], '1')
        self.assertNotIn('VXRT_NATIVE_VR_SIMULATE',r['environment'])
        r['observed'][0]['value']=9
        self.assertIn('returncode does not match process record', probe.validate(r))

    def test_nonzero_is_recorded_without_success_claim(self):
        Child.rc=5; Child.log=b'[vxrt] called an unimplemented function\n'
        r=probe.capture(self.args)
        facts={o['metric']:o['value'] for o in r['observed']}
        self.assertEqual(facts['returncode'],5)
        self.assertFalse(facts['zero_fallback_reported'])
        self.assertTrue(facts['problem_lines'])
        self.assertEqual(r['derived'],[])

    def test_timeout_owns_process_group(self):
        Child.timeout=True; Child.rc=-9
        r=probe.capture(self.args)
        self.assertTrue(next(o['value'] for o in r['observed'] if o['metric']=='timed_out'))
        probe.os.killpg.assert_any_call(12345,signal.SIGKILL)

    def test_busy_refuses_without_child(self):
        with patch.object(probe.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'99 vxrt','')), patch.object(probe.subprocess,'Popen') as child:
            r=probe.capture(self.args)
            self.assertEqual(r['status'],'refused'); child.assert_not_called()

    def test_wrong_identity_or_output_refused(self):
        next(self.aot.iterdir()).unlink()
        with self.assertRaisesRegex(ValueError,'hash-matched'):probe.capture(self.args)
        self.args.out=str(self.root)
        with self.assertRaisesRegex(ValueError,'new directory'):probe.capture(self.args)

    def test_missing_address_is_not_zero_fallback(self):
        facts=probe.inspect_log('[vxrt] aot: VXRT_AOT_STRICT: 0x140001000 has no recompiled code; stopping\n')
        self.assertEqual(facts['missing_code'],['0x140001000'])
        self.assertFalse(facts['zero_fallback_reported'])

    def test_native_crash_without_summary_stays_unknown_and_preserves_old_schema(self):
        content = '[vxrt] 11:51:25.112 signal 10 at 0x10146b130 (address 0x4251bbfc0) in this runtime; native backtrace:\n0 vxrt-arm64-diag-004 0x10146b130 vx_x86_call + 0\n'
        old = probe.inspect_log(content)
        self.assertNotIn('native_signals', old)
        self.assertEqual(old['problem_lines'], [])
        facts = probe.inspect_log(content, 2)
        self.assertEqual(facts['native_signals'][0]['signal'], 10)
        self.assertEqual(facts['native_signals'][0]['pc'], '0x10146b130')
        self.assertTrue(facts['native_backtrace'])
        self.assertEqual(facts['aot_summaries'], [])
        self.assertFalse(facts['zero_fallback_reported'])

    def test_callback_diagnostics_are_explicit_and_bounded(self):
        self.args.callback_depth_limit = 8
        result = probe.capture(self.args)
        self.assertEqual(result['environment']['VXRT_CALLBACK_DEPTH_LIMIT'], '8')
        self.assertEqual(result['diagnostic']['callback_depth_limit'], 8)
        self.args.callback_depth_limit = 0
        self.args.out = str(self.root/'invalid')
        with self.assertRaisesRegex(ValueError, 'callback depth limit'):
            probe.capture(self.args)

    def test_openvr_trace_is_opt_in_and_keeps_strict_mode(self):
        self.args.trace_openvr_init = True
        result = probe.capture(self.args)
        self.assertEqual(result['environment']['VXRT_TRACE_OPENVR_INIT'], '1')
        self.assertEqual(result['environment']['VXRT_AOT_STRICT'], '1')
        self.assertNotIn('VXRT_TRACE_OPENVR', result['environment'])
        self.assertTrue(result['diagnostic']['openvr_init_passthrough_trace'])

    def test_xrizer_mode_confines_all_xdg_paths(self):
        self.args.experimental_xrizer = True
        dylib = self.root/'xrizer.dylib'; dylib.write_bytes(b'fixture')
        self.args.xrizer_dylib = str(dylib)
        with patch.dict(probe.os.environ, {'XDG_CONFIG_HOME': '/outside', 'XDG_RUNTIME_DIR': '/outside'}):
            result = probe.capture(self.args)
        env = result['environment']
        self.assertEqual(env['VXRT_XRIZER_OPENVR'], '1')
        self.assertEqual(env['VXRT_XRIZER_DYLIB'], str(dylib))
        self.assertEqual(result['artifacts']['xrizer_dylib']['sha256'], probe.digest(dylib))
        self.assertNotIn('XDG_RUNTIME_DIR', env)
        for kind in ('STATE', 'CONFIG', 'CACHE', 'DATA'):
            path = Path(env[f'XDG_{kind}_HOME'])
            self.assertTrue(path.is_dir() and path.is_relative_to(Path(self.args.out)))
        self.assertIn('development host', result['diagnostic']['experimental_xrizer'])

    def test_xrizer_requires_explicit_absolute_dylib(self):
        self.args.experimental_xrizer = True
        with self.assertRaisesRegex(ValueError, 'explicit xrizer dylib'):
            probe.capture(self.args)
        self.args.xrizer_dylib = 'relative.dylib'
        with self.assertRaisesRegex(ValueError, 'absolute'):
            probe.capture(self.args)


if __name__=='__main__':unittest.main()
