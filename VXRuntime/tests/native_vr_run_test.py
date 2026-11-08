import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'tools/native_vr_run.py'
spec = importlib.util.spec_from_file_location('native_vr_run', MODULE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class FakeProcess:
    def __init__(self, command, **kwargs):
        self.pid = 12345
        self.command = command
        self.env = kwargs['env']
        kwargs['stdout'].write(self.log)
        self.calls = 0

    def wait(self, timeout=None):
        self.calls += 1
        if self.timeout and self.calls == 1:
            raise subprocess.TimeoutExpired(self.command, timeout)
        return self.code


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1] / 'build')
        self.repo = Path(self.temp.name)
        self.old_repo = runner.REPO
        runner.REPO = self.repo
        (self.repo / 'VXRuntime/build').mkdir(parents=True)
        (self.repo / 'VXRuntime/tests').mkdir()
        (self.repo / 'VXRuntime/tests/native_vr_d3d11.cpp').write_text('fixture source')
        self.exe = self.repo / 'VXRuntime/build/native_vr_d3d11.exe'
        self.exe.write_bytes(b'MZ fixture')
        self.runtime = self.repo / 'runtime'
        self.runtime.write_bytes(b'\xcf\xfa\xed\xfe' + struct.pack('<I', 0x0100000c))
        self.runtime.chmod(0o755)
        self.modules = self.repo / 'modules'; self.modules.mkdir()
        h = 1469598103934665603
        for byte in self.exe.read_bytes():
            h = ((h ^ byte) * 1099511628211) & 0xffffffffffffffff
        (self.modules / f'native_vr_d3d11.exe-{h:016x}.dylib').write_bytes(self.runtime.read_bytes())
        self.args = ['--mode', 'aot', '--runtime', str(self.runtime), '--exe', str(self.exe),
                     '--aot-dir', str(self.modules), '--out', str(self.repo / 'out')]
        FakeProcess.log = b'native_vr: ok\n[vxrt] aot: 4 entries into recompiled code, 0 C function calls, 0 native calls, 0 built-in export stubs followed, 0 fallbacks to the translator (0 addresses), 0 ordered accesses across 16 bytes\n'
        FakeProcess.code = 0; FakeProcess.timeout = False
        self.git = patch.object(runner, 'git', side_effect=lambda *a: b'abcdef\n' if a[0] == 'rev-parse' else b'')
        self.git.start()
        self.probe = patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', ''))
        self.probe.start()
        self.child = patch.object(runner.subprocess, 'Popen', FakeProcess); self.child.start()
        self.killer = patch.object(runner.os, 'killpg'); self.killer.start()

    def tearDown(self):
        self.killer.stop(); self.child.stop(); self.probe.stop(); self.git.stop()
        runner.REPO = self.old_repo; self.temp.cleanup()

    def test_success_and_environment(self):
        import json
        with patch.dict(os.environ, {'VXRT_AOT_DIR': 'inherited', 'VXRT_VCPU': '1'}):
            self.assertEqual(runner.main(self.args), 0)
        data = json.loads((self.repo / 'out/result.json').read_text())
        self.assertTrue(data['fixture_verdict'] and data['aot_summary_ok'] and data['passed'])
        self.assertEqual(data['environment']['VXRT_AOT_DIR'], str(self.modules))
        self.assertIn('VXRuntime/tests/native_vr_d3d11.cpp', data['source_inputs_sha256'])
        self.assertEqual(data['command'][1], '-arm64')
        runner.subprocess.run.assert_called_once_with(['pgrep', '-x', 'vxrt|vxrt-arm64'], capture_output=True, text=True)

    def test_missing_summary_verdict_and_nonzero(self):
        for log, code in [(b'native_vr: ok\n', 0), (b'aot: 1 entries into recompiled code, 1 fallbacks to the translator (1 addresses)\n', 0), (FakeProcess.log, 1)]:
            FakeProcess.log, FakeProcess.code = log, code
            args = self.args[:-1] + [str(self.repo / ('out' + str(code) + str(len(log))))]
            self.assertEqual(runner.main(args), 1)

    def test_timeout_kills_only_owned_group(self):
        FakeProcess.timeout = True; FakeProcess.code = -9
        self.assertEqual(runner.main(self.args), 1)
        runner.os.killpg.assert_called_once_with(12345, runner.signal.SIGKILL)

    def test_busy_and_wrong_arch_refused(self):
        runner.subprocess.run.return_value = subprocess.CompletedProcess([], 0, '123 build/vxrt', '')
        self.assertEqual(runner.main(self.args), 2)
        self.assertFalse((self.repo / 'out').exists())
        runner.subprocess.run.return_value = subprocess.CompletedProcess([], 1, '', '')
        self.runtime.write_bytes(b'\xcf\xfa\xed\xfe' + struct.pack('<I', 0x01000007))
        self.assertEqual(runner.main(self.args), 2)

    def test_wrong_fixture_and_missing_aot_refused(self):
        self.exe.unlink(); self.assertEqual(runner.main(self.args), 2)
        self.exe.write_bytes(b'MZ fixture')
        next(self.modules.iterdir()).unlink(); self.assertEqual(runner.main(self.args), 2)


if __name__ == '__main__':
    unittest.main()
