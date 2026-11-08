import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
import skyrim_aot_pipeline as p


class PipelineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.compiler = self.root/'compiler'; self.compiler.write_bytes(b'compiler')
        self.script = self.root/'builder'; self.script.write_bytes(b'build script')
        self.original = self.root/'original'; self.original.write_bytes(b'original')
        self.exe = self.root/'prepared.exe'; self.exe.write_bytes(b'prepared')
        self.dll = self.root/'guest.dll'; self.dll.write_bytes(b'dll')
        self.runtime = self.root/'runtime'; self.runtime.write_bytes(b'runtime')
        self.assets = self.root/'assets'; self.assets.mkdir()
        self.cache = self.root/'cache'
        def pin(path): return {'path':str(path), 'sha256':p.digest(path)}
        self.cfg = {'original':pin(self.original), 'prepared':pin(self.exe), 'dlls':[dict(pin(self.dll),base='0x180000000')],
                    'runtime':pin(self.runtime), 'exe_base':'0x140000000', 'asset_root':str(self.assets),
                    'dll_roots':[], 'jobs':1}
        for attr, value in [('REPO', self.root), ('COMPILER', self.compiler), ('SCRIPT', self.script), ('CACHE', self.cache)]:
            pt = patch.object(p, attr, value); pt.start(); self.addCleanup(pt.stop)
        pt = patch.object(p, 'source_identity', return_value={'commit':'head', 'patch_sha256':'patch'})
        pt.start(); self.addCleanup(pt.stop)

    def test_plan_rejects_bad_hash_and_records_distinct_cache_keys(self):
        result = p.run(self.cfg, self.root/'plan')
        self.assertEqual(result['status'], 'planned')
        self.assertNotEqual(result['modules'][0]['key'], result['modules'][1]['key'])
        self.cfg['prepared']['sha256'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            p.run(self.cfg, self.root/'bad')

    def test_cache_keys_cover_base_source_compiler_and_options(self):
        m = p.prepare(self.cfg)['modules'][0]
        ident = {'commit':'one','patch_sha256':'dirty'}
        key = p.key_for(m, ident, 'compiler', 'script', 1)[0]
        variants = [p.key_for(dict(m,base='0x150000000'),ident,'compiler','script',1)[0],
                    p.key_for(m,dict(ident,patch_sha256='changed'),'compiler','script',1)[0],
                    p.key_for(m,ident,'changed','script',1)[0], p.key_for(m,ident,'compiler','changed',1)[0],
                    p.key_for(m,ident,'compiler','script',2)[0]]
        self.assertTrue(all(key != v for v in variants))

    def test_failed_build_never_enters_cache(self):
        def failure(cmd, **kw):
            (Path(cmd[2])/'bad.dylib').write_bytes(b'partial')
            return subprocess.CompletedProcess(cmd, 1)
        with patch.object(p.subprocess, 'run', side_effect=failure):
            with self.assertRaisesRegex(ValueError, 'build failed'):
                p.run(self.cfg, self.root/'failed', build=True)
        self.assertEqual(json.loads((self.root/'failed/result.json').read_text())['status'], 'failed')
        self.assertEqual([x.name for x in self.cache.iterdir()], ['build.lock'])

    def test_cache_reuse_and_tampering_rejected(self):
        def success(cmd, **kw):
            (Path(cmd[2])/(Path(cmd[1]).name+'.dylib')).write_bytes(b'module')
            return subprocess.CompletedProcess(cmd, 0)
        with patch.object(p.subprocess, 'run', side_effect=success) as call:
            first = p.run(self.cfg, self.root/'first', build=True)
            second = p.run(self.cfg, self.root/'second', build=True)
            self.assertEqual(call.call_count, 2)
            self.assertTrue(all(m['cached'] for m in second['modules']))
            artifact = next((self.cache/first['modules'][0]['key']).glob('*.dylib'))
            artifact.chmod(0o644); artifact.write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'invalid cached'):
                p.run(self.cfg, self.root/'third', build=True)

    def test_owned_gate_failure_stops_probe(self):
        self.cfg['owned_gate'] = ['owned-fixture-check']
        def run(cmd, **kw):
            if cmd[0] == str(self.script):
                (Path(cmd[2])/(Path(cmd[1]).name+'.dylib')).write_bytes(b'module')
                return subprocess.CompletedProcess(cmd, 0)
            self.assertEqual(cmd, ['owned-fixture-check'])
            return subprocess.CompletedProcess(cmd, 3)
        with patch.object(p.subprocess, 'run', side_effect=run):
            with self.assertRaisesRegex(ValueError, 'gate failed'):
                p.run(self.cfg, self.root/'out', build=True, probe=True)
        result = json.loads((self.root/'out/result.json').read_text())
        self.assertEqual(result['gate']['returncode'], 3)
        self.assertNotIn('probe', result)

    def test_unknown_counters_are_not_claimed_as_zero(self):
        result = {'status':'observed', 'observed':[{'metric':'returncode','value':0}]}
        self.assertEqual(p.classify(result)['category'], 'unknown')
        self.assertEqual(p.classify(result)['evidence']['aot_summaries'], [])
        result['observed'].append({'metric':'missing_code','value':['0x123']})
        self.assertEqual(p.classify(result)['category'], 'missing_aot_code')

    def test_native_signal_is_classified_without_inventing_coverage(self):
        result = {'status':'observed', 'observed':[
            {'metric':'native_signals','value':[{'signal':10,'pc':'0x10146b130'}]},
            {'metric':'native_backtrace','value':['0 vxrt-arm64 0x10146b130 vx_x86_call + 0']}]}
        category = p.classify(result)
        self.assertEqual(category['category'], 'native_signal')
        self.assertEqual(category['evidence'], [{'signal':10,'pc':'0x10146b130'}])
        self.assertTrue(category['backtrace'])


if __name__ == '__main__': unittest.main()
