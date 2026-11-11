#!/usr/bin/env python3
"""tools/nexus.py, tools/mods.py fetch and the mods-fetch stage against a local fake Nexus server (no network, no real key)."""
import hashlib, http.server, io, json, os, subprocess, sys, tempfile, threading, time, unittest, zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import nexus

KEY = 'SECRET-KEY-123'
NXMKEY = 'NXMKEYVALUE'


def make_zip():
    b = io.BytesIO()
    with zipfile.ZipFile(b, 'w') as z:
        z.writestr('Data/Textures/a.dds', b'DDS')
    return b.getvalue()


ZIP = make_zip()


class Fake(http.server.BaseHTTPRequestHandler):
    premium = False; limit429 = 0; md5 = hashlib.md5(ZIP).hexdigest(); payload = ZIP; hits = []

    def log_message(self, *a): pass

    def send(self, code, body=b'', headers=()):
        self.send_response(code)
        for k, v in headers: self.send_header(k, v)
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def j(self, code, obj, headers=()): self.send(code, json.dumps(obj).encode(), headers)

    def do_GET(self):
        S = type(self); S.hits.append((self.path, dict(self.headers)))
        path, _, q = self.path.partition('?')
        if path == '/cdn/f.zip':
            return self.send(200, S.payload)
        if self.headers.get('apikey') != KEY:
            return self.j(401, {'message': 'Please provide a valid API Key'})
        if S.limit429 > 0:
            S.limit429 -= 1
            return self.j(429, {'message': 'limit'}, [('Retry-After', '3')])
        if path == '/v1/users/validate.json':
            return self.j(200, {'name': 'Tester', 'is_premium': S.premium, 'is_supporter': False, 'email': 'x@example.com'})
        if path == '/v1/games/skyrimspecialedition/mods/7/files.json':
            return self.j(200, {'files': [{'file_id': 9, 'name': 'Main', 'file_name': 'Main-7-9.zip', 'version': '1.0', 'category_name': 'MAIN', 'size_in_bytes': len(ZIP), 'md5': S.md5}]})
        if path == '/v1/games/skyrimspecialedition/mods/7/files/9.json':
            return self.j(200, {'file_id': 9, 'file_name': 'Main-7-9.zip', 'size_in_bytes': len(ZIP), 'md5': S.md5})
        if path == '/v1/games/skyrimspecialedition/mods/7/files/9/download_link.json':
            if 'key=' in q and ('key=' + NXMKEY) not in q:
                return self.j(400, {'message': 'bad key'})
            if not S.premium and ('key=' + NXMKEY) not in q:
                return self.j(403, {'message': 'not premium'})
            return self.j(200, [{'name': 'CDN', 'short_name': 'cdn', 'URI': 'http://127.0.0.1:%d/cdn/f.zip' % self.server.server_port}])
        self.j(404, {'message': 'no'})


class Base(unittest.TestCase):
    def setUp(self):
        real = subprocess.run
        def guard(cmd, *a, **k):
            if cmd and cmd[0] == 'open': raise AssertionError('a test tried to open a page: %r' % (cmd,))
            return real(cmd, *a, **k)
        g = mock.patch.object(nexus.subprocess, 'run', guard); g.start(); self.addCleanup(g.stop)
        Fake.premium = False; Fake.limit429 = 0; Fake.md5 = hashlib.md5(ZIP).hexdigest(); Fake.payload = ZIP; Fake.hits = []
        self.srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fake)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.env = {'NEXUS_API_BASE': 'http://127.0.0.1:%d/v1' % self.srv.server_port, 'NEXUS_API_KEY': KEY, 'VXRT_PRIVATE_ROOT': str(self.root / 'priv'), 'VXRT_DOWNLOADS_DIR': str(self.root / 'Downloads')}
        (self.root / 'Downloads').mkdir()
        p = mock.patch.dict(os.environ, self.env); p.start(); self.addCleanup(p.stop)
        self.waits = []
        s = mock.patch.object(nexus, '_sleep', self.waits.append); s.start(); self.addCleanup(s.stop)
    def tearDown(self):
        self.srv.shutdown(); self.srv.server_close(); self.tmp.cleanup()
    def nxm(self, key=NXMKEY):
        return 'nxm://skyrimspecialedition/mods/7/files/9?key=%s&expires=4102444800&user_id=1' % key


class Client(Base):
    def test_validate_prints_name_and_premium_not_key(self):
        Fake.premium = True
        out = io.StringIO()
        with mock.patch('sys.stdout', out): self.assertEqual(nexus.main(['validate']), 0)
        self.assertIn('Tester', out.getvalue()); self.assertIn('premium: yes', out.getvalue())
        self.assertNotIn(KEY, out.getvalue()); self.assertNotIn('example.com', out.getvalue())
        self.assertEqual(Fake.hits[0][1].get('Application-Name'), nexus.APP_NAME)

    def test_missing_key_exit_2_without_network(self):
        with mock.patch.dict(os.environ, {'NEXUS_API_KEY': ''}), mock.patch('sys.stderr', io.StringIO()) as e:
            self.assertEqual(nexus.main(['validate']), 2)
        self.assertIn('NEXUS_API_KEY', e.getvalue()); self.assertEqual(Fake.hits, [])

    def test_bad_key(self):
        with mock.patch.dict(os.environ, {'NEXUS_API_KEY': 'WRONGKEY'}), mock.patch('sys.stderr', io.StringIO()) as e:
            self.assertEqual(nexus.main(['validate']), 1)
        self.assertIn('rejected the API key', e.getvalue()); self.assertNotIn('WRONGKEY', e.getvalue())

    def test_files_list(self):
        out = io.StringIO()
        with mock.patch('sys.stdout', out): self.assertEqual(nexus.main(['files', 'skyrimspecialedition', '7']), 0)
        self.assertIn('Main-7-9.zip', out.getvalue())

    def test_premium_download_ok_and_idempotent(self):
        Fake.premium = True
        r = nexus.download('skyrimspecialedition', '7', '9')
        self.assertEqual(r['md5'], Fake.md5); self.assertEqual(Path(r['path']).read_bytes(), ZIP)
        self.assertEqual(Path(r['path']).parent, (self.root / 'priv' / 'downloads' / 'nexus').resolve())
        nexus.download('skyrimspecialedition', '7', '9')                  # a verified file is not fetched again
        cdn = [h for h in Fake.hits if '/cdn/' in h[0]]
        self.assertEqual(len(cdn), 1); self.assertNotIn('apikey', cdn[0][1])      # the key never goes to the CDN

    def test_non_premium_403_then_nxm(self):
        with self.assertRaises(nexus.NeedInput) as c: nexus.download('skyrimspecialedition', '7', '9')
        self.assertIn('Mod Manager Download', str(c.exception)); self.assertNotIn(KEY, str(c.exception))
        r = nexus.download('skyrimspecialedition', '7', '9', nxm=self.nxm())
        self.assertTrue(Path(r['path']).is_file())
        with mock.patch('sys.stderr', io.StringIO()) as e:
            self.assertEqual(nexus.main(['download', 'skyrimspecialedition', '7', '9']), 0)      # already there
        with self.assertRaises(nexus.NexusError): nexus.download('skyrimspecialedition', '7', '10', nxm=self.nxm())    # link for another file

    def test_bad_nxm_key(self):
        with self.assertRaises(nexus.NeedInput) as c: nexus.download('skyrimspecialedition', '7', '9', nxm=self.nxm('WRONG'))
        self.assertIn('invalid', str(c.exception)); self.assertNotIn('WRONG', str(c.exception))

    def test_rate_limit_retry(self):
        Fake.premium = True; Fake.limit429 = 2
        nexus.download('skyrimspecialedition', '7', '9')
        self.assertEqual(len(self.waits), 2); self.assertTrue(all(3 <= w <= 4 for w in self.waits))
        Fake.limit429 = 99
        with self.assertRaises(nexus.NexusError): nexus.list_files('skyrimspecialedition', '7', KEY)

    def test_md5_mismatch_discards_file(self):
        Fake.premium = True; Fake.md5 = 'f' * 32
        with self.assertRaises(nexus.NexusError) as c: nexus.download('skyrimspecialedition', '7', '9')
        self.assertIn('md5', str(c.exception))
        self.assertEqual(list((self.root / 'priv' / 'downloads' / 'nexus').iterdir()), [])
        Fake.md5 = hashlib.md5(ZIP).hexdigest()
        with self.assertRaises(nexus.NexusError): nexus.download('skyrimspecialedition', '7', '9', md5='0' * 32)   # a wrong pin also fails
        Fake.payload = ZIP + b'x'                                                                                  # size differs from the record
        with self.assertRaises(nexus.NexusError) as c: nexus.download('skyrimspecialedition', '7', '9')
        self.assertIn('size', str(c.exception))

    def test_key_never_in_error_text(self):
        self.assertNotIn(KEY, nexus.scrub('boom ' + KEY + ' https://x/?key=abc&e=1', KEY)); self.assertNotIn('abc', nexus.scrub('https://x/?key=abc', KEY))


class ModsAndStage(Base):
    def lst(self, **nx):
        p = self.root / 'mods.json'
        p.write_text(json.dumps(dict(profile='t', mods=[dict(id='texmod', name='T', kind='files', priority=1, nexus=dict(game='skyrimspecialedition', mod_id=7, file_id=9, **nx))])))
        return p
    def run_py(self, *args):
        return subprocess.run([sys.executable, '-I', *map(str, args)], capture_output=True, text=True, env={**os.environ, **self.env})

    def test_fetch_pins_md5_then_builds_and_is_idempotent(self):
        Fake.premium = True; p = self.lst()
        r = self.run_py(ROOT / 'tools/mods.py', 'fetch', '--list', p); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(p.read_text())['mods'][0]['nexus']['md5'], Fake.md5)
        self.assertTrue((self.root / 'priv/mods-src/texmod/Data/Textures/a.dds').is_file())
        n = len(Fake.hits)
        r = self.run_py(ROOT / 'tools/mods.py', 'fetch', '--list', p); self.assertEqual(r.returncode, 0); self.assertEqual(len(Fake.hits), n)   # no network
        r = self.run_py(ROOT / 'tools/mods.py', 'build', '--list', p, '--out', self.root / 'pack'); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.root / 'pack/merged/Data/Textures/a.dds').read_bytes(), b'DDS')

    def test_build_before_fetch_exit_2(self):
        r = self.run_py(ROOT / 'tools/mods.py', 'build', '--list', self.lst(), '--out', self.root / 'pack'); self.assertEqual(r.returncode, 2); self.assertIn('fetch', r.stderr)

    def test_stage_exit_2_without_key_then_ok(self):
        Fake.premium = True; p = self.lst()
        env = {**os.environ, **self.env, 'NEXUS_API_KEY': '', 'VXRT_LOCAL_ENV': str(self.root / 'none.sh')}
        r = subprocess.run([sys.executable, str(ROOT / 'tools/vxrt_build.py'), 'mods-fetch', '--list', str(p), '--json'], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 2, r.stderr); self.assertEqual(json.loads(r.stdout)['status'], 'missing-input'); self.assertEqual(Fake.hits, [])
        env['NEXUS_API_KEY'] = KEY
        for _ in range(2):                                                                  # second run: idempotent
            r = subprocess.run([sys.executable, str(ROOT / 'tools/vxrt_build.py'), 'mods-fetch', '--list', str(p), '--json'], capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stderr); self.assertNotIn(KEY, r.stdout + r.stderr)
        self.assertEqual(sum('/cdn/' in h[0] for h in Fake.hits), 1)


class Handoff(Base):
    def setUp(self):
        super().setUp()
        Fake.premium = False
        for name, v in (('POLL', 0.02),):
            m = mock.patch.object(nexus, name, v); m.start(); self.addCleanup(m.stop)
        for name, v in (('handler_installed', lambda: False), ('_stdin_line', lambda: None)):
            m = mock.patch.object(nexus, name, v); m.start(); self.addCleanup(m.stop)
        self.err = io.StringIO(); m = mock.patch('sys.stderr', self.err); m.start(); self.addCleanup(m.stop)

    def test_receive_queues_and_download_picks_it_up(self):
        t = threading.Timer(0.3, lambda: nexus.receive(self.nxm())); t.start()
        r = nexus.download('skyrimspecialedition', '7', '9', wait=10, progress='2 of 5 done')
        self.assertTrue(Path(r['path']).is_file()); self.assertEqual(list(nexus.queue_dir().glob('*.nxm')), [])    # consumed
        msg = self.err.getvalue()
        self.assertIn('2 of 5 done', msg); self.assertIn('Mod Manager Download', msg); self.assertIn('?tab=files&file_id=9', msg)
        self.assertIn('Main-7-9.zip', msg); self.assertIn('receive', msg)
        self.assertNotIn(NXMKEY, msg); self.assertNotIn('4102444800', msg); self.assertNotIn(KEY, msg)

    def test_receive_file_mode_and_rejects_junk(self):
        p = nexus.receive(self.nxm()); self.assertEqual(p.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(nexus.NexusError): nexus.receive('https://example.com/x')
        with self.assertRaises(nexus.NexusError): nexus.receive('nxm://skyrimspecialedition/mods/7/files/9')      # no key

    def test_wrong_file_is_refused_politely_and_kept_then_right_one_taken(self):
        wrong = 'nxm://skyrimspecialedition/mods/7/files/10?key=%s&expires=4102444800' % NXMKEY
        nexus.receive(wrong)
        threading.Timer(0.3, lambda: nexus.receive(self.nxm())).start()
        r = nexus.download('skyrimspecialedition', '7', '9', wait=10)
        self.assertTrue(Path(r['path']).is_file())
        self.assertIn('different file', self.err.getvalue()); self.assertEqual(len(list(nexus.queue_dir().glob('*.nxm'))), 1)   # the other file's link is kept
        self.assertNotIn(NXMKEY, self.err.getvalue())

    def test_expired_link_ignored_and_timeout_skips(self):
        nexus.receive('nxm://skyrimspecialedition/mods/7/files/9?key=%s&expires=1000' % NXMKEY)
        with self.assertRaises(nexus.Skipped): nexus.download('skyrimspecialedition', '7', '9', wait=1)
        self.assertIn('expired', self.err.getvalue())

    def test_stdin_paste(self):
        lines = iter([self.nxm()])
        with mock.patch.object(nexus, '_stdin_line', lambda: next(lines, None)):
            r = nexus.download('skyrimspecialedition', '7', '9', wait=5)
        self.assertTrue(Path(r['path']).is_file())

    def test_ctrl_c_skips(self):
        with mock.patch.object(nexus, '_poll_sleep', side_effect=KeyboardInterrupt):
            with self.assertRaises(nexus.Skipped): nexus.download('skyrimspecialedition', '7', '9', wait=5)

    def test_premium_never_prompts(self):
        Fake.premium = True; nexus.download('skyrimspecialedition', '7', '9', wait=5)
        self.assertNotIn('Mod Manager', self.err.getvalue())

    def test_no_wait_keeps_exit_2_instructions(self):
        with self.assertRaises(nexus.NotPremium): nexus.download('skyrimspecialedition', '7', '9', wait=0)

    def test_mods_fetch_skip_then_resume(self):
        p = self.root / 'mods.json'
        p.write_text(json.dumps(dict(profile='t', mods=[dict(id='texmod', kind='files', priority=1, nexus=dict(game='skyrimspecialedition', mod_id=7, file_id=9))])))
        env = {**os.environ, **self.env}
        r = subprocess.run([sys.executable, '-I', str(ROOT / 'tools/mods.py'), 'fetch', '--list', str(p), '--wait', '0'], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 2); self.assertNotIn(KEY, r.stdout + r.stderr)
        nexus.receive(self.nxm())
        r = subprocess.run([sys.executable, '-I', str(ROOT / 'tools/mods.py'), 'fetch', '--list', str(p), '--wait', '5'], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0, r.stderr); self.assertNotIn(NXMKEY, r.stdout + r.stderr)
        self.assertTrue((self.root / 'priv/mods-src/texmod/Data/Textures/a.dds').is_file())


class KeyFree(Base):
    """No API key: the browser downloads, the Downloads folder is watched."""
    def setUp(self):
        super().setUp()
        os.environ.pop('NEXUS_API_KEY', None)
        self.dl = self.root / 'Downloads'
        for name, v in (('POLL', 0.02), ('STABLE', 0.1)):
            m = mock.patch.object(nexus, name, v); m.start(); self.addCleanup(m.stop)
        self.err = io.StringIO(); m = mock.patch('sys.stderr', self.err); m.start(); self.addCleanup(m.stop)
        Fake.hits = []
    def put(self, name, data=ZIP):
        (self.dl / name).write_bytes(data); return self.dl / name

    def test_existing_file_by_pinned_md5_no_key_no_network(self):
        self.put('Whatever-name.zip')
        r = nexus.fetch_file('skyrimspecialedition', '7', '9', md5=hashlib.md5(ZIP).hexdigest(), wait=0, name='Texture Mod')
        self.assertEqual(Path(r['path']).read_bytes(), ZIP); self.assertEqual(r['md5'], hashlib.md5(ZIP).hexdigest())
        self.assertTrue((self.dl / 'Whatever-name.zip').exists())               # copied, not moved
        self.assertEqual(Fake.hits, [])

    def test_new_file_arrives_partial_ignored_then_complete(self):
        self.put('Main-7-1-0-1700000000.zip.crdownload', b'partial'); self.put('x-7-1.zip.download', b'p')
        def arrive():
            time.sleep(0.3); self.put('Main-7-1-0-1700000000.zip')
        threading.Thread(target=arrive).start()
        with mock.patch('builtins.input', lambda p='': 'y' if p.startswith('Found') else 'n'), mock.patch('sys.stdin') as si:
            si.isatty.return_value = True
            r = nexus.fetch_file('skyrimspecialedition', '7', '9', wait=10, progress=(1, 5), name='Texture Mod')
        self.assertEqual(Path(r['path']).read_bytes(), ZIP)
        m = self.err.getvalue()
        self.assertIn('1 of 5 done', m); self.assertIn('Manual download', m); self.assertIn('Slow download', m); self.assertIn('?tab=files&file_id=9', m)
        self.assertIn('Texture Mod', m)

    def test_partial_alone_times_out(self):
        self.put('Main-7-1.zip.crdownload', b'x'); self.put('Main-7-1.7z.part', b'x')
        with self.assertRaises(nexus.Skipped): nexus.fetch_file('skyrimspecialedition', '7', '9', wait=1, md5=hashlib.md5(b'x').hexdigest())

    def test_name_match_needs_confirmation(self):
        self.put('Main-7-1-0-1700000000.zip'); self.put('Other-8-1.zip')
        with mock.patch('builtins.input', lambda p='': 'n'), mock.patch('sys.stdin') as si:
            si.isatty.return_value = True
            with self.assertRaises(nexus.Skipped): nexus.fetch_file('skyrimspecialedition', '7', '9', wait=1)
        with mock.patch('sys.stdin') as si:                                       # no terminal: refuses to guess...
            si.isatty.return_value = False
            with self.assertRaises(nexus.Skipped): nexus.fetch_file('skyrimspecialedition', '7', '9', wait=1)
            r = nexus.fetch_file('skyrimspecialedition', '7', '9', wait=1, accept_name=True)    # ...unless told to
        self.assertIn('Main-7-1-0-1700000000.zip', r['path'])
        self.assertNotIn('Other-8', r['path'])

    def test_md5_mismatch_rejected_even_if_name_matches(self):
        self.put('Main-7-1-0-1700000000.zip')
        with self.assertRaises(nexus.Skipped): nexus.fetch_file('skyrimspecialedition', '7', '9', md5='0' * 32, wait=1)
        self.assertIn('differs from the pinned', self.err.getvalue())
        self.assertEqual(list((self.root / 'priv/downloads/nexus').glob('*.zip')) if (self.root / 'priv/downloads/nexus').exists() else [], [])

    def test_nxm_without_key_is_explained(self):
        self.put('a.zip')
        nexus.fetch_file('skyrimspecialedition', '7', '9', nxm=self.nxm(), md5=hashlib.md5(ZIP).hexdigest(), wait=0)
        self.assertIn('needs the key', self.err.getvalue().replace('cannot be used without an API key (the download-link call needs the key)', 'needs the key'))

    def test_mods_fetch_end_to_end_without_key_then_pin(self):
        self.put('Main-7-1-0-1700000000.zip')
        p = self.root / 'mods.json'
        p.write_text(json.dumps(dict(profile='t', mods=[dict(id='texmod', name='Tex', kind='files', priority=1, nexus=dict(game='skyrimspecialedition', mod_id=7, file_id=9))])))
        env = {k: v for k, v in {**os.environ, **self.env}.items() if k != 'NEXUS_API_KEY'}
        run = lambda *x: subprocess.run([sys.executable, '-I', str(ROOT / 'tools/mods.py'), 'fetch', '--list', str(p), *x], capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
        r = run('--wait', '0'); self.assertEqual(r.returncode, 2, r.stderr)          # no terminal: will not guess from the name
        r = run('--wait', '0', '--accept-name-match'); self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(p.read_text())['mods'][0]['nexus']['md5'], hashlib.md5(ZIP).hexdigest())      # pinned
        self.assertTrue((self.root / 'priv/mods-src/texmod/Data/Textures/a.dds').is_file())
        (self.dl / 'Main-7-1-0-1700000000.zip').unlink()
        r = run('--wait', '0'); self.assertEqual(r.returncode, 0, r.stderr); self.assertEqual(Fake.hits, [])        # done: needs nothing
        self.assertNotIn('nxm', (r.stderr + r.stdout))


class HandlerApp(Base):
    def setUp(self):
        super().setUp()
        self.state = {'cur': 'org.example.vortex', 'sets': []}
        for name, v in (('get_default_handler', lambda scheme='nxm': self.state['cur']),
                        ('set_default_handler', lambda b, scheme='nxm': (self.state['sets'].append(b), self.state.update(cur=b))),
                        ('_lsregister', lambda app: None)):
            m = mock.patch.object(nexus, name, v); m.start(); self.addCleanup(m.stop)

    def run_cmd(self, *args, answer=None, tty=True):
        out = io.StringIO()
        with mock.patch('sys.stdout', out), mock.patch('sys.stderr', io.StringIO()) as e, \
             mock.patch('builtins.input', lambda prompt='': answer), mock.patch('sys.stdin') as si:
            si.isatty.return_value = tty
            rc = nexus.main(list(args))
        return rc, out.getvalue() + e.getvalue()

    def test_dry_run_changes_nothing(self):
        rc, o = self.run_cmd('install-handler', '--dry-run')
        self.assertEqual(rc, 0); self.assertIn('SYSTEM-WIDE', o); self.assertIn('org.example.vortex', o); self.assertIn('Vortex', o)
        self.assertEqual(self.state['sets'], []); self.assertFalse(nexus.app_path().exists())

    def test_no_auto_yes_and_n_answer(self):
        rc, o = self.run_cmd('install-handler', tty=False); self.assertEqual(rc, 2)
        rc, o = self.run_cmd('install-handler', answer='n'); self.assertEqual(rc, 0); self.assertIn('Not changed', o)
        rc, o = self.run_cmd('install-handler', answer=''); self.assertIn('Not changed', o)
        self.assertEqual(self.state['sets'], []); self.assertFalse(nexus.app_path().exists())

    @unittest.skipUnless(sys.platform == 'darwin' and Path('/usr/bin/osacompile').exists(), 'needs macOS osacompile')
    def test_install_builds_app_records_previous_and_uninstall_restores(self):
        rc, o = self.run_cmd('install-handler', answer='y'); self.assertEqual(rc, 0, o)
        self.assertEqual(self.state['sets'], [nexus.handler_bundle_id()])
        plist = json.loads(subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(nexus.app_path() / 'Contents/Info.plist')], capture_output=True, text=True).stdout)
        self.assertEqual(plist['CFBundleURLTypes'][0]['CFBundleURLSchemes'], ['nxm']); self.assertEqual(plist['CFBundleIdentifier'], nexus.handler_bundle_id())
        self.assertEqual(json.loads(nexus.prev_file().read_text())['previous'], 'org.example.vortex')
        self.assertTrue(str(nexus.app_path()).startswith(str((self.root / 'priv').resolve())))
        rc, o = self.run_cmd('uninstall-handler'); self.assertEqual(rc, 0, o)
        self.assertEqual(self.state['cur'], 'org.example.vortex'); self.assertFalse(nexus.app_path().exists())

    def test_uninstall_when_not_ours_does_nothing(self):
        rc, o = self.run_cmd('uninstall-handler'); self.assertEqual(rc, 0); self.assertEqual(self.state['sets'], [])


if __name__ == '__main__':
    unittest.main()
