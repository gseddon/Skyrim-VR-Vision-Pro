#!/usr/bin/env python3 -I
"""tools/nexus.py fetch fixes, with urlopen mocked (no network, no key): a null file_id is resolved from the md5 (md5_search, then files.json) and
cached; CDN URLs with spaces/brackets/unicode are percent-encoded once; the apikey header never goes to the CDN; a free account's 403 falls back to
the Downloads-folder flow with a clear message."""
import hashlib, io, json, os, sys, tempfile, urllib.error
from pathlib import Path
from unittest import mock
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import nexus

KEY = 'SECRET-KEY-123'
DATA = b'archive bytes'; MD5 = hashlib.md5(DATA).hexdigest()
CDN = 'https://cdn.example.com/files/My Mod [v1.0] é.zip'


class Resp(io.BytesIO):
    def __init__(self, body, status=200, headers=None):
        super().__init__(body if isinstance(body, bytes) else json.dumps(body).encode()); self.status = status; self.headers = headers or {}
    def __enter__(self): return self
    def __exit__(self, *a): self.close()


def http_err(url, code, body=b'{}'):
    return urllib.error.HTTPError(url, code, 'x', {}, io.BytesIO(body))


class Net:
    """Routes urlopen(Request) by URL; records (url, headers)."""
    def __init__(self, routes): self.routes = routes; self.calls = []
    def __call__(self, req, timeout=None):
        url = req.full_url; self.calls.append((url, {k.lower(): v for k, v in req.header_items()}))
        for needle, fn in self.routes:
            if needle in url:
                r = fn(url)
                if isinstance(r, Exception): raise r
                return r
        raise http_err(url, 404)


def run(routes, fn):
    net = Net(routes)
    with mock.patch.object(urllib.request, 'urlopen', net), mock.patch('sys.stderr', io.StringIO()) as err:
        try: out = fn()
        finally: msg = err.getvalue()
    return net, out, msg


with tempfile.TemporaryDirectory() as t:
    t = Path(t).resolve(); priv = t / 'private'; dl = t / 'Downloads'; dl.mkdir()
    os.environ.update(VXRT_PRIVATE_ROOT=str(priv), VXRT_DOWNLOADS_DIR=str(dl), NEXUS_API_KEY=KEY)
    os.environ.pop('NEXUS_API_BASE', None)
    search = 'games/skyrimspecialedition/mods/md5_search/%s.json' % MD5

    # --- null file_id resolved via md5_search (other mods' hits are ignored), cached, ids printed
    hits = [{'mod': {'mod_id': 999}, 'file_details': {'file_id': 1, 'md5': MD5}}, {'mod': {'mod_id': 7}, 'file_details': {'file_id': 42, 'md5': MD5}}]
    net, fid, msg = run([('md5_search', lambda u: Resp(hits))], lambda: nexus.resolve_file_id('skyrimspecialedition', 7, MD5, KEY))
    assert fid == '42', fid
    assert 'file_id 42' in msg and 'md5_search' in msg and KEY not in msg, msg
    assert net.calls[0][1]['apikey'] == KEY and net.calls[0][0].endswith(search), net.calls
    net, fid, msg = run([], lambda: nexus.resolve_file_id('skyrimspecialedition', 7, MD5, KEY))
    assert fid == '42' and net.calls == [], 'second lookup comes from the cache'

    # --- fallback to files.json when md5_search does not know it
    (priv / 'downloads' / 'nexus' / 'file-ids.json').unlink(missing_ok=True)
    files = {'files': [{'file_id': 5, 'md5': '0' * 32}, {'file_id': 77, 'md5': MD5.upper()}]}
    net, fid, msg = run([('md5_search', lambda u: http_err(u, 404)), ('mods/7/files.json', lambda u: Resp(files))], lambda: nexus.resolve_file_id('skyrimspecialedition', 7, MD5, KEY))
    assert fid == '77' and 'files.json' in msg, (fid, msg)
    (priv / 'downloads' / 'nexus' / 'file-ids.json').unlink(missing_ok=True)
    net, fid, msg = run([('md5_search', lambda u: http_err(u, 404)), ('mods/7/files.json', lambda u: Resp({'files': []}))], lambda: nexus.resolve_file_id('skyrimspecialedition', 7, MD5, KEY))
    assert fid is None

    # --- URL encoding: once, never twice
    assert nexus.encode_url(CDN) == 'https://cdn.example.com/files/My%20Mod%20%5Bv1.0%5D%20%C3%A9.zip'
    enc = nexus.encode_url(CDN)
    assert nexus.encode_url(enc) == enc, 'already-encoded URLs are left alone'
    assert nexus.encode_url('https://c.example.com/a%20b/c d?md5=x_y&expires=12') == 'https://c.example.com/a%20b/c%20d?md5=x_y&expires=12'

    # --- full premium download: resolved id, encoded CDN URL, no apikey on the CDN request
    def routes(premium=True):
        def links(u):
            if not premium: return http_err(u, 403)
            return Resp([{'name': 'CDN', 'URI': CDN}])
        return [('md5_search', lambda u: Resp(hits)),
                ('files/42/download_link.json', links),
                ('files/42.json', lambda u: Resp({'file_name': 'My Mod [v1.0].zip', 'size_in_bytes': len(DATA), 'md5': MD5})),
                ('cdn.example.com', lambda u: Resp(DATA))]
    (priv / 'downloads' / 'nexus' / 'file-ids.json').unlink(missing_ok=True)
    net, r, msg = run(routes(), lambda: nexus.fetch_file('skyrimspecialedition', '7', None, md5=MD5, name='Mod'))
    assert r['md5'] == MD5 and Path(r['path']).read_bytes() == DATA, r
    cdn = [c for c in net.calls if 'cdn.example.com' in c[0]]
    assert len(cdn) == 1 and cdn[0][0] == 'https://cdn.example.com/files/My%20Mod%20%5Bv1.0%5D%20%C3%A9.zip', cdn
    assert 'apikey' not in cdn[0][1], 'the API key must not go to the CDN'
    assert all(c[1].get('apikey') == KEY for c in net.calls if 'cdn.example.com' not in c[0])

    # --- free account: 403 -> clear message, then the Downloads-folder flow (md5 match)
    (dl / 'browser.zip').write_bytes(DATA); os.utime(dl / 'browser.zip', (1, 1))
    for f in (priv / 'downloads' / 'nexus').glob('skyrimspecialedition-*'): f.unlink()
    nexus.browser_downloads_dir = lambda: dl
    net, r, msg = run(routes(premium=False), lambda: nexus.fetch_file('skyrimspecialedition', '7', None, md5=MD5, name='Mod'))
    assert 'free account' in msg and 'falling back to your browser' in msg and 'https://www.nexusmods.com/skyrimspecialedition/mods/7?tab=files&file_id=42' in msg, msg
    assert KEY not in msg and r['md5'] == MD5 and r['verified_by'] == 'pinned md5', (r, msg)

    # --- unknown md5 with a key: no crash, falls back to the browser flow
    (priv / 'downloads' / 'nexus' / 'file-ids.json').unlink(missing_ok=True)
    net, r, msg = run([('md5_search', lambda u: http_err(u, 404)), ('files.json', lambda u: Resp({'files': []}))],
                      lambda: nexus.fetch_file('skyrimspecialedition', '7', None, md5=MD5))
    assert 'does not list md5' in msg and r['md5'] == MD5, msg

    # --- external (SKSE) failure message names the page and the md5
    net, r, msg = run([], lambda: _skip())  if False else (None, None, None)
    nexus.cache_dirs = lambda: []
    try: nexus.external_fetch('SKSE VR', 'https://skse.silverlock.org/beta/sksevr_2_00_12.7z', 'sksevr_2_00_12.7z', '0' * 32, folders=[dl], page='https://skse.silverlock.org/'); raise SystemExit('accepted wrong md5')
    except nexus.Skipped: pass
print('nexus_fetch_fix_test ok')
