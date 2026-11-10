import json
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
import skyrim_aot_pipeline as p


def owned_pe(image_size=0x2000):
    b = bytearray(0x400)
    b[:2] = b'MZ'; struct.pack_into('<I', b, 0x3c, 0x80)
    b[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HH', b, 0x84, 0x8664, 1)
    struct.pack_into('<H', b, 0x94, 0xf0)
    struct.pack_into('<H', b, 0x98, 0x20b)
    struct.pack_into('<I', b, 0x98+16, 0x1000)
    struct.pack_into('<Q', b, 0x98+24, 0x140000000)
    struct.pack_into('<II', b, 0x98+56, image_size, 0x200)
    struct.pack_into('<I', b, 0x98+108, 16)
    struct.pack_into('<IIII', b, 0x188+8, 0x200, 0x1000, 0x200, 0x200)
    struct.pack_into('<I', b, 0x188+36, 0x60000020)
    return b


class FakeTools:
    """vxrt-aot (name, gen) and clang: records what the pipeline passes and writes plausible outputs."""
    def __init__(self, compiler, parts=None, fail=None):
        self.compiler, self.parts, self.fail = str(compiler), parts or {}, fail
        self.gens, self.links, self.lock = [], [], threading.Lock()

    def __call__(self, cmd, **kw):
        if cmd[0] == self.compiler and cmd[1] == 'name':
            name = Path(cmd[2]).name.lower() + '-0123456789abcdef.dylib\n'
            return subprocess.CompletedProcess(cmd, 0, stdout=name.encode(), stderr=b'')
        if cmd[0] == self.compiler and cmd[1] == 'gen':
            env = kw['env']
            files = {k: Path(env[k]).read_text() for k in ('VXRT_AOT_SPLITS', 'VXRT_AOT_ROOTS') if k in env}
            self.gens.append({'pe': cmd[2], 'env': {k: v for k, v in env.items() if k.startswith('VXRT_AOT_')}, 'files': files})
            if self.fail == 'gen':
                return subprocess.CompletedProcess(cmd, 1)
            out = Path(cmd[3]); n = self.parts.get(Path(cmd[2]).name, 1)
            names = [out] if n == 1 else [out.with_name('S.p%d.s' % k) for k in range(n)]
            for s in names:
                s.write_text('// part\n')
            kw['stdout'].write(''.join(str(s) + '\n' for s in names).encode())
            return subprocess.CompletedProcess(cmd, 0)
        if cmd[0] == 'clang':
            target = Path(kw['cwd'])/cmd[cmd.index('-o') + 1]
            with self.lock:
                self.links.append((kw['cwd'], cmd))
            if self.fail == 'link' and '-dynamiclib' in cmd:
                return subprocess.CompletedProcess(cmd, 1, stdout=b'', stderr=b'ld: error')
            target.write_bytes(b'module ' + target.name.encode())
            return subprocess.CompletedProcess(cmd, 0, stdout=b'', stderr=b'')
        if self.fail == 'gate':
            return subprocess.CompletedProcess(cmd, 3)
        raise AssertionError('unexpected command %r' % (cmd,))


class PipelineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.compiler = self.root/'compiler'; self.compiler.write_bytes(b'compiler')
        self.original = self.root/'original'; self.original.write_bytes(b'original')
        self.exe = self.root/'prepared.exe'; self.exe.write_bytes(owned_pe())
        self.dll = self.root/'guest.dll'; self.dll.write_bytes(owned_pe())
        self.runtime = self.root/'runtime'; self.runtime.write_bytes(b'runtime')
        self.assets = self.root/'assets'; self.assets.mkdir()
        self.splits = self.root/'splits.txt'; self.splits.write_text('0x140001000\n\n0x140001ff0\n')
        self.roots = self.root/'roots.txt'; self.roots.write_text('140001010\n')
        self.cache = self.root/'cache'
        self.cfg = {'original':self.pin(self.original), 'prepared':self.pin(self.exe), 'dlls':[dict(self.pin(self.dll),base='0x180000000')],
                    'runtime':self.pin(self.runtime), 'exe_base':'0x140000000', 'asset_root':str(self.assets),
                    'dll_roots':[], 'jobs':1}
        for attr, value in [('REPO', self.root), ('PRIVATE', self.root), ('COMPILER', self.compiler), ('CACHE', self.cache)]:
            pt = patch.object(p, attr, value); pt.start(); self.addCleanup(pt.stop)
        for name, value in [('source_identity', {'commit':'head', 'patch_sha256':'patch'}), ('toolchain', {'clang':'clang 1', 'ld':'ld 1'})]:
            pt = patch.object(p, name, return_value=value); pt.start(); self.addCleanup(pt.stop)

    def pin(self, path):
        return {'path':str(path), 'sha256':p.digest(path)}

    def exe_block(self, **kw):
        self.cfg.pop('exe_base', None)
        self.cfg['exe'] = dict({'base':'0x308000000', 'part_mb':16, 'splits':self.pin(self.splits), 'roots':self.pin(self.roots)}, **kw)

    def ctx(self, **kw):
        return dict({'source':{'commit':'one','patch_sha256':'dirty'}, 'compiler':{'sha256':'c', 'source_commit':None},
                     'toolchain':{'clang':'1','ld':'1'}, 'jobs':1}, **kw)

    def key(self):
        return p.key_for(p.prepare(self.cfg)['modules'][0], self.ctx())[0]

    def test_plan_rejects_bad_hash_and_records_distinct_cache_keys(self):
        result = p.run(self.cfg, self.root/'plan')
        self.assertEqual(result['status'], 'planned')
        self.assertNotEqual(result['modules'][0]['key'], result['modules'][1]['key'])
        self.assertEqual(result['compiler']['sha256'], p.digest(self.compiler))
        self.cfg['prepared']['sha256'] = '0'*64
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            p.run(self.cfg, self.root/'bad')

    def test_cache_keys_cover_base_source_compiler_and_options(self):
        m = p.prepare(self.cfg)['modules'][0]
        key = p.key_for(m, self.ctx())[0]
        variants = [p.key_for(dict(m,base='0x150000000'),self.ctx())[0],
                    p.key_for(m,self.ctx(source={'commit':'one','patch_sha256':'changed'}))[0],
                    p.key_for(m,self.ctx(compiler={'sha256':'changed','source_commit':None}))[0],
                    p.key_for(m,self.ctx(compiler={'sha256':'c','source_commit':'f'*40}))[0],
                    p.key_for(m,self.ctx(toolchain={'clang':'2','ld':'1'}))[0],
                    p.key_for(m,self.ctx(jobs=2))[0],
                    p.key_for(dict(m,part_mb=16),self.ctx())[0]]
        self.assertEqual(len({key, *variants}), len(variants) + 1)

    def test_cache_keys_cover_profile_contents_and_the_shift(self):
        self.exe_block(); keys = {self.key()}
        self.exe_block(base='0x309000000'); keys.add(self.key())     # same files, different shifted content
        self.splits.write_text('0x140001000\n'); self.exe_block(); keys.add(self.key())
        self.exe_block(roots=None); keys.add(self.key())
        self.exe_block(roots=None, part_mb=None); keys.add(self.key())
        self.exe_block(roots=None, part_mb=None, splits=None); keys.add(self.key())
        self.assertEqual(len(keys), 6)

    def test_exe_block_shifts_profiles_and_passes_settings_to_the_compiler(self):
        self.exe_block(); self.cfg['jobs'] = 4
        tools = FakeTools(self.compiler, parts={'prepared.exe': 3})
        with patch.object(p.subprocess, 'run', side_effect=tools):
            result = p.run(self.cfg, self.root/'out', build=True)
        exe, dll = tools.gens
        self.assertEqual(exe['env']['VXRT_AOT_BASE'], '0x308000000')
        self.assertEqual(exe['env']['VXRT_AOT_PART_MB'], '16')
        self.assertEqual(exe['files'], {'VXRT_AOT_SPLITS': '0x308001000\n0x308001ff0\n', 'VXRT_AOT_ROOTS': '0x308001010\n'})
        self.assertEqual(dll['env'], {'VXRT_AOT_BASE': '0x180000000'})
        names = sorted(x.name for x in (self.root/'out/modules').iterdir())
        self.assertEqual(names, ['guest.dll-0123456789abcdef.dylib'] + ['prepared.exe-0123456789abcdef.p%d.dylib' % k for k in range(3)])
        # Linked relative to the build directory: the install name does not carry the cache path.
        outputs = sorted(c[c.index('-o') + 1] for _, c in tools.links if '-dynamiclib' in c)
        self.assertEqual(len(outputs), 4)
        self.assertIn('dylibs/prepared.exe-0123456789abcdef.p2.dylib', outputs)
        evidence = result['modules'][0]
        self.assertEqual(evidence['environment']['VXRT_AOT_PART_MB'], '16')
        cached = self.cache/evidence['key']
        self.assertEqual((cached/'splits.txt').read_text(), '0x308001000\n0x308001ff0\n')
        self.assertFalse((cached/'work').exists())

    def test_inherited_aot_variables_do_not_reach_the_compiler(self):
        tools = FakeTools(self.compiler)
        with patch.dict(p.os.environ, {'VXRT_AOT_SPLITS': '/elsewhere', 'VXRT_AOT_PART_MB': '1'}), patch.object(p.subprocess, 'run', side_effect=tools):
            p.run(self.cfg, self.root/'out', build=True)
        self.assertEqual(tools.gens[0]['env'], {'VXRT_AOT_BASE': '0x140000000'})

    def test_profile_addresses_must_be_hex_and_other_modules_addresses_are_left_out(self):
        for text in ('0x150000000\n', 'main+4\n', '\n'):
            with self.subTest(text=text):
                self.splits.write_text(text); self.exe_block()
                with self.assertRaisesRegex(ValueError, 'no address inside the image|not a hex'):
                    p.prepare(self.cfg)
        # A runtime profile also lists DLL addresses (here one at an old DLL base): counted, not passed on.
        self.splits.write_text('0x140001000\n0xf000265f5\n0x140002000\n'); self.exe_block()
        splits = p.prepare(self.cfg)['modules'][0]['splits']
        self.assertEqual((splits['used'], splits['outside_image']), (1, 2))
        tools = FakeTools(self.compiler)
        with patch.object(p.subprocess, 'run', side_effect=tools):
            p.run(self.cfg, self.root/'out', build=True)
        self.assertEqual(tools.gens[0]['files']['VXRT_AOT_SPLITS'], '0x308001000\n')

    def test_exe_block_and_exe_base_are_exclusive_and_checked(self):
        self.exe_block(); self.cfg['exe_base'] = '0x140000000'
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            p.prepare(self.cfg)
        self.exe_block(part_mb=0)
        with self.assertRaisesRegex(ValueError, 'part_mb'):
            p.prepare(self.cfg)
        self.exe_block(split='typo')
        with self.assertRaisesRegex(ValueError, 'unknown exe keys'):
            p.prepare(self.cfg)
        self.exe_block(); self.splits.write_text('0x140001004\n')
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            p.prepare(self.cfg)

    def test_pinned_compiler_is_checked_and_used(self):
        other = self.root/'vxrt-aot-pinned'; other.write_bytes(b'pinned')
        self.cfg['compiler'] = dict(self.pin(other), source_commit='a'*40)
        tools = FakeTools(other)
        with patch.object(p.subprocess, 'run', side_effect=tools):
            result = p.run(self.cfg, self.root/'out', build=True)
        self.assertEqual(result['compiler'], {'path': str(other), 'sha256': p.digest(other), 'source_commit': 'a'*40})
        self.assertEqual(len(tools.gens), 2)
        self.cfg['compiler']['source_commit'] = 'HEAD'
        with self.assertRaisesRegex(ValueError, 'source_commit'):
            p.prepare(self.cfg)
        self.cfg['compiler'] = dict(self.pin(other), source_commit='a'*40); other.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
            p.prepare(self.cfg)

    def test_private_inputs_may_live_in_the_main_checkout_outside_this_worktree(self):
        worktree = self.root/'.claude/worktrees/w'; worktree.mkdir(parents=True)
        with patch.object(p, 'REPO', worktree):
            self.assertEqual(p.prepare(self.cfg)['prepared']['path'], str(self.exe))
            with patch.object(p, 'PRIVATE', worktree), self.assertRaisesRegex(ValueError, 'inside checkout'):
                p.prepare(self.cfg)

    def test_cache_and_output_must_be_inside_the_checkout(self):
        with self.assertRaisesRegex(ValueError, 'cache must be inside'):
            p.run(self.cfg, self.root/'out', cache='/')
        with self.assertRaisesRegex(ValueError, 'new checkout-local'):
            p.run(self.cfg, self.root)

    def test_layout_rejects_wrong_isa_truncated_data_and_unbacked_sections(self):
        for change in ('machine', 'truncated', 'raw_bounds', 'entry'):
            with self.subTest(change=change):
                b = owned_pe()
                if change == 'machine': struct.pack_into('<H', b, 0x84, 0xaa64)
                elif change == 'truncated': b = b[:100]
                elif change == 'raw_bounds': struct.pack_into('<I', b, 0x188+20, 0x10000)
                else: struct.pack_into('<I', b, 0x98+16, 0x1800)
                self.exe.write_bytes(b)
                self.cfg['prepared']['sha256'] = p.digest(self.exe)
                with self.assertRaisesRegex(ValueError, 'PE layout'):
                    p.prepare(self.cfg)

    def test_distinct_module_bases_must_not_overlap_image_ranges(self):
        self.exe.write_bytes(owned_pe(0x20000))
        self.cfg['prepared']['sha256'] = p.digest(self.exe)
        self.cfg['dlls'][0]['base'] = '0x140010000'
        with self.assertRaisesRegex(ValueError, 'mappings overlap'):
            p.prepare(self.cfg)
        self.cfg['dlls'][0]['base'] = '0x140020000'
        self.assertEqual(p.prepare(self.cfg)['modules'][0]['pe']['image_size'], 0x20000)

    def test_failed_build_never_enters_cache(self):
        for fail in ('gen', 'link'):
            with self.subTest(fail=fail), patch.object(p.subprocess, 'run', side_effect=FakeTools(self.compiler, fail=fail)):
                with self.assertRaisesRegex(ValueError, 'build failed'):
                    p.run(self.cfg, self.root/('failed-' + fail), build=True)
                self.assertEqual(json.loads((self.root/('failed-' + fail)/'result.json').read_text())['status'], 'failed')
                self.assertEqual([x.name for x in self.cache.iterdir()], ['build.lock'])

    def test_cache_reuse_and_tampering_rejected(self):
        tools = FakeTools(self.compiler)
        with patch.object(p.subprocess, 'run', side_effect=tools):
            first = p.run(self.cfg, self.root/'first', build=True)
            second = p.run(self.cfg, self.root/'second', build=True)
            self.assertEqual(len(tools.gens), 2)
            self.assertTrue(all(m['cached'] for m in second['modules']))
            artifact = next((self.cache/first['modules'][0]['key']).glob('*.dylib'))
            artifact.chmod(0o644); artifact.write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'invalid cached'):
                p.run(self.cfg, self.root/'third', build=True)

    def test_owned_gate_failure_stops_probe(self):
        self.cfg['owned_gate'] = ['owned-fixture-check']
        with patch.object(p.subprocess, 'run', side_effect=FakeTools(self.compiler, fail='gate')):
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

    def test_explicit_xrizer_slot_stop_precedes_signal_and_keeps_unknown_counters(self):
        result = {'status':'observed', 'observed':[
            {'metric':'xrizer_bridge_stops','value':[{'interface':'IVRSystem_019','slot':12}]},
            {'metric':'native_signals','value':[{'signal':6,'pc':'0x1234'}]}]}
        category = p.classify(result)
        self.assertEqual(category['category'], 'unsupported_xrizer_bridge_slot')
        self.assertEqual(category['aot_summaries'], [])

    def test_unsupported_interface_is_observed_without_assuming_cause(self):
        result = {'status':'observed', 'observed':[
            {'metric':'xrizer_unsupported_interfaces','value':['IVROverlay_018']}]}
        category = p.classify(result)
        self.assertEqual(category['category'], 'unsupported_xrizer_interface_observed')
        self.assertIn('unknown', category['causality'])



class RuntimePin(unittest.TestCase):
    def test_stale_runtime_pin_is_recorded_for_builds_and_refused_for_probes(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / 'vxrt-arm64'; f.write_bytes(b'rebuilt runtime')
            item = {'path': str(f), 'sha256': '0' * 64}
            got = p.pin_runtime(item, strict=False)
            self.assertEqual(got['sha256'], p.digest(f))
            self.assertFalse(got['pin_matches'])
            with self.assertRaises(ValueError):
                p.pin_runtime(item, strict=True)
            item['sha256'] = p.digest(f)
            self.assertTrue(p.pin_runtime(item, strict=False)['pin_matches'])
            self.assertEqual(p.pin_runtime(item, strict=True)['sha256'], item['sha256'])


if __name__ == '__main__': unittest.main()
