#!/usr/bin/env python3
"""Exercise device-run safety without connecting to a device."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'VXRuntime/tools/xros_device_run.sh'
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f: f.write(json.dumps(args) + '\n')
mode = os.environ.get('MODE', '')
if 'processes' in args:
    if mode == 'unknown': print('{}')
    else: print(json.dumps({'result': {'runningProcesses': [{'executable': '/apps/VXRuntimeHost.app/VXRuntimeHost'}] if mode == 'active' else []}}))
elif 'launch' in args:
    if mode == 'launch_fail': sys.exit(7)
    pathlib.Path(os.environ['NONCE']).write_text(args[args.index('-lognonce') + 1])
elif 'copy' in args:
    dst = pathlib.Path(args[args.index('--destination') + 1])
    source = args[args.index('--source') + 1]
    if mode == 'copy_fail' and dst.name == 'vxrt.log': sys.exit(9)
    if mode == 'missing' and dst.name == 'vxrt.log': sys.exit(0)
    if source.endswith('host_log.jsonl'):
        content = '{"event":"launch","test":"old"}\n'
        if mode != 'stale':
            nonce = pathlib.Path(os.environ['NONCE']).read_text() if mode != 'wrongnonce' else 'wrong'
            content += json.dumps({'event':'launch', 'test':'hello', 'nonce':nonce}) + '\n'
    else: content = 'runtime log\n'
    dst.write_text(content)
'''

class DeviceRunTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'; self.bin.mkdir()
        exe = self.bin / 'xcrun'; exe.write_text(FAKE); exe.chmod(0o755)
        self.calls = self.root / 'calls'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        DEV='explicit-device', WAIT='0', OUT=str(self.root / 'out'), CALLS=str(self.calls), NONCE=str(self.root / 'nonce'))
    def tearDown(self): self.temp.cleanup()
    def run_script(self, *args, **env):
        e = dict(self.env, **env)
        return subprocess.run([str(SCRIPT), *args], env=e, text=True, capture_output=True)
    def calls_read(self):
        import json
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
    def test_invalid_arguments_do_not_mutate(self):
        for args, env in [(('hello', '../oops'), {}), (('hello@bad',), {}), (('hello',), {'WAIT':'301'}), (('hello',), {'DEV':''}), ((), {}), (('hello', 'world'), {})]:
            self.assertNotEqual(self.run_script(*args, **env).returncode, 0)
        self.assertFalse(self.calls.exists()); self.assertFalse((self.root / 'out').exists())
    def test_active_and_unknown_refuse_before_launch(self):
        for mode in ('active', 'unknown'):
            self.assertNotEqual(self.run_script('hello', MODE=mode).returncode, 0)
        self.assertFalse(any('launch' in c for c in self.calls_read()))
    def test_success_and_no_termination(self):
        self.assertEqual(self.run_script('hello').returncode, 0)
        self.assertFalse(any('--terminate-existing' in c for c in self.calls_read()))
        self.assertFalse(any('before.jsonl' in c for call in self.calls_read() for c in call))
        cases = list((self.root / 'out').glob('run.*/hello.vr.*'))
        self.assertEqual(len(cases), 1)
        self.assertEqual((cases[0] / 'launch.status').read_text().strip(), '0')
        self.assertEqual((cases[0] / 'vxrt.log.copy.status').read_text().strip(), '0')
    def test_failures_and_stale_evidence_fail_closed(self):
        for mode in ('launch_fail', 'copy_fail', 'missing', 'stale', 'wrongnonce'):
            self.assertNotEqual(self.run_script('hello', MODE=mode).returncode, 0, mode)
    def test_output_outside_repo_rejected(self):
        self.assertNotEqual(self.run_script('hello', OUT='/tmp/not-allowed').returncode, 0)
        self.assertFalse(self.calls.exists())

if __name__ == '__main__': unittest.main()
