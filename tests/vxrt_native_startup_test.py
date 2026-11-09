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
import skyrim_aot_pipeline as pipeline


class Child:
    rc = 0
    timeout = False
    log = b'[vxrt] aot: 4 entries into recompiled code, 0 C function calls, 8 native calls, 0 built-in export stubs followed, 0 fallbacks to the translator (0 addresses), 0 ordered accesses across 16 bytes\n'
    pid = 12345

    def __init__(self, cmd, **kwargs):
        self.calls = 0
        self.env = kwargs['env']
        Child.last_env = self.env.copy()
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
                   patch.object(probe.subprocess, 'check_output', side_effect=lambda *a, **kw: 'testrev\n' if kw.get('text') else b''),
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

    def test_null_target_trace_is_explicit_sealed_and_preserves_counters(self):
        Child.log += b'[vxrt] unimplemented function\n' * 35
        Child.log += b'[vxrt] aot-null-target: rip=0 caller=0x1234\n'
        with patch.dict(probe.os.environ, {'VXRT_AOT_NULL_DIAGNOSTIC': '1',
                                           'VXRT_UNRELATED': 'unsafe', 'VERANTYX_OTHER': 'unsafe'}):
            ordinary = probe.capture(self.args)
            self.assertNotIn('VXRT_AOT_NULL_DIAGNOSTIC', Child.last_env)
            self.assertNotIn('VXRT_AOT_NULL_DIAGNOSTIC', ordinary['environment'])
            self.assertNotIn('VXRT_UNRELATED', ordinary['environment'])
            self.assertNotIn('VERANTYX_OTHER', ordinary['environment'])
            self.args.out = str(self.root/'traced')
            self.args.trace_null_target = True
            traced = probe.capture(self.args)
        self.assertEqual(Child.last_env['VXRT_AOT_NULL_DIAGNOSTIC'], '1')
        self.assertNotIn('VXRT_UNRELATED', Child.last_env)
        self.assertEqual(traced['environment']['VXRT_AOT_NULL_DIAGNOSTIC'], '1')
        self.assertNotIn('VXRT_UNRELATED', traced['environment'])
        self.assertEqual(traced['environment']['VXRT_AOT_STRICT'], '1')
        self.assertTrue(traced['diagnostic']['null_target_trace'])
        self.assertIn('diagnostic evidence only', traced['diagnostic']['null_target_scope'])
        sealed = json.loads((Path(self.args.out)/'result.json').read_text())
        self.assertEqual(sealed, traced)
        self.assertEqual(probe.validate(sealed), [])
        facts = {o['metric']: o['value'] for o in sealed['observed']}
        self.assertTrue(any('aot-null-target:' in line for line in facts['problem_lines']))
        self.assertEqual(facts['aot_summaries'], [{'entries': 4, 'fallback_requests': 0, 'missing_addresses': 0}])
        self.assertTrue(facts['aot_executed'] and facts['zero_fallback_reported'])
        self.assertEqual(sealed['derived'], [])
        self.assertEqual(sealed['level'], None)

    def test_xinput_script_is_validated_and_labelled_diagnostic(self):
        self.args.xinput_script = '40:A:0.3,50:START+B:0.5'
        result = probe.capture(self.args)
        self.assertEqual(result['environment']['VXRT_XINPUT_SCRIPT'], '40:A:0.3,50:START+B:0.5')
        self.assertIn('not a physical controller', result['diagnostic']['xinput_script_scope'])
        for bad in ('A', '40:A', '40:A:x', '40::1', '40:A:1,'):
            self.args.xinput_script = bad
            with self.assertRaises(ValueError):
                probe.capture(self.args)

    def test_xinput_repeat_expands_merges_and_is_validated(self):
        self.assertEqual(probe.expand_xinput_repeat('A@30-36/3'), '30:A:0.2,33:A:0.2,36:A:0.2')
        self.assertEqual(probe.expand_xinput_repeat('START@10-12/1:0.5', '11.5:B:0.3'), '10:START:0.5,11:START:0.5,11.5:B:0.3,12:START:0.5')
        for bad in ('A', 'A@30-20/3', 'A@30-40/0.2', 'A@30-40/0.2:0.2', 'A@30-40/1:1', 'A@0-9999/1', '@30-40/3'):
            with self.assertRaises(ValueError):
                probe.expand_xinput_repeat(bad)
        self.args.xinput_repeat = 'A@30-33/3'
        result = probe.capture(self.args)
        self.assertEqual(result['environment']['VXRT_XINPUT_SCRIPT'], '30:A:0.2,33:A:0.2')
        self.assertIn('not a physical controller', result['diagnostic']['xinput_script_scope'])

    def test_stay_active_is_opt_in_and_labelled(self):
        result = probe.capture(self.args)
        self.assertNotIn('VXRT_STAY_ACTIVE', result['environment'])
        self.args.stay_active = True
        self.args.out = str(Path(self.args.out).parent/'stay-active-out')
        result = probe.capture(self.args)
        self.assertEqual(result['environment']['VXRT_STAY_ACTIVE'], '1')
        self.assertIn('not an input or tracking claim', result['diagnostic']['stay_active'])

    def test_null_target_cli_flag_reaches_capture(self):
        args = ['probe', '--exe', 'x', '--runtime', 'r', '--aot-dir', 'a',
                '--asset-root', 'assets', '--out', 'out', '--trace-null-target']
        with patch.object(sys, 'argv', args), patch.object(probe, 'capture', return_value={'status': 'observed'}) as capture, patch('builtins.print'):
            self.assertEqual(probe.main(), 0)
        self.assertTrue(capture.call_args.args[0].trace_null_target)

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
        self.assertEqual(result['source_identity']['commit'], 'testrev')
        self.assertTrue(next(o['value'] for o in result['observed'] if o['metric']=='source_unchanged'))
        self.assertNotIn('XDG_RUNTIME_DIR', env)
        for kind in ('STATE', 'CONFIG', 'CACHE', 'DATA'):
            path = Path(env[f'XDG_{kind}_HOME'])
            self.assertTrue(path.is_dir() and path.is_relative_to(Path(self.args.out)))
        self.assertIn('development host', result['diagnostic']['experimental_xrizer'])
        self.assertEqual(probe.validate(result), [])
        dylib.write_bytes(b'changed')
        self.assertIn('xrizer_dylib artifact changed or missing', probe.validate(result))

    def test_xrizer_requires_explicit_absolute_dylib(self):
        self.args.experimental_xrizer = True
        with self.assertRaisesRegex(ValueError, 'explicit xrizer dylib'):
            probe.capture(self.args)
        self.args.xrizer_dylib = 'relative.dylib'
        with self.assertRaisesRegex(ValueError, 'absolute'):
            probe.capture(self.args)

    def test_xrizer_stops_are_versioned_and_missing_counters_remain_unknown(self):
        log = ('[vxrt] xrizer OpenVR: GetGenericInterface IVROverlay_018 = 0x0 error 106\n'
               '[vxrt] xrizer_guest_bridge: unsupported IVRSystem_019 slot 12\n'
               '[vxrt] signal 6 at 0x1234 (address 0) in this runtime\n')
        old = probe.inspect_log(log, 2)
        self.assertNotIn('xrizer_bridge_stops', old)
        facts = probe.inspect_log(log, 3)
        self.assertEqual(facts['xrizer_bridge_stops'], [{'interface': 'IVRSystem_019', 'slot': 12}])
        self.assertEqual(facts['xrizer_unsupported_interfaces'], ['IVROverlay_018'])
        self.assertEqual(facts['aot_summaries'], [])
        self.assertFalse(facts['zero_fallback_reported'])

    def test_xrizer_panic_is_schema4_only_and_has_no_invented_summary(self):
        log = ('[2026-11-08T13:12:01.355 ERROR xrizer ThreadId(1)] panicked at src/system.rs:75:14:\n'
               "Couldn't locate views: ERROR_TIME_INVALID\n")
        self.assertNotIn('xrizer_panics', probe.inspect_log(log, 3))
        facts = probe.inspect_log(log, 4)
        self.assertEqual(facts['xrizer_panics'], [{'source':'src/system.rs','line':75,'column':14,
                                                   'message':"Couldn't locate views: ERROR_TIME_INVALID"}])
        result = {'status':'observed','observed':[{'metric':k,'value':v} for k,v in facts.items()]}
        classified = pipeline.classify(result)
        self.assertEqual(classified['category'], 'xrizer_panic')
        self.assertEqual(classified['aot_summaries'], [])


if __name__=='__main__':unittest.main()
