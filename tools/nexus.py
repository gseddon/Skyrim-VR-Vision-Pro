#!/usr/bin/env python3
"""Small Nexus Mods client (Python standard library only) for fetching the mods in a mods list.

  NEXUS_API_KEY=... python3 -I tools/nexus.py validate
  python3 -I tools/nexus.py files    <game> <mod_id>
  python3 -I tools/nexus.py download <game> <mod_id> <file_id> [--nxm nxm://...] [--md5 HEX]
  python3 -I tools/nexus.py nxm      nxm://<game>/mods/<mod_id>/files/<file_id>?key=..&expires=..      (the same, as an nxm handler would call it)

Which API: the v1 REST API (https://api.nexusmods.com/v1, `apikey` header).  The newer v3 API (documented in
"Nexus Mods API Documentation") marks its download-link endpoint "Experimental" (may change or be removed), has no
"who am I / premium" call and its file-version record shows no size or md5, which are what we verify downloads against.  v1 is the
long-standing interface used by mod managers: users/validate.json, mods/{id}/files.json, files/{id}.json and
files/{id}/download_link.json (a free user adds the key and expires of the website's nxm:// link).  The v3 endpoint
(GET /v3/games/{game}/mod-file-versions/{file}/download-link) takes the same key/expires query; switching is a one-function change.

The key: only the personal API key (nexusmods.com > Site preferences > API Keys), read from the environment variable
NEXUS_API_KEY.  Nexus has no username/password API login, so a password is never used or stored.  The key is sent only in the
`apikey` header to the API host (never to the CDN the download link points to) and is never printed or logged.

Downloads go to <VXRT_PRIVATE_ROOT>/downloads/nexus/ (default build/private/downloads/nexus).  Each is checked against the
size (and md5 when the API gives one) of the file's record, and against --md5 when you pin one.  A file that is already there and
checks out is not fetched again.  Your use of the downloads is under Nexus's terms: personal use, do not redistribute mods.

Exit status: 0 done, 1 failed, 2 a missing input (the key, or an nxm link for a non-premium account) with the message saying how to get it.
Tests point NEXUS_API_BASE at a local fake server; real use never sets it.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_BASE = 'https://api.nexusmods.com/v1'
APP_NAME = 'vxrt-skyrimvr-mods'
APP_VERSION = '1'
MAX_RETRIES = 3
MAX_WAIT = 900            # seconds a 429 may make us wait before we give up and say when to retry
REPO = Path(__file__).resolve().parent.parent

_sleep = time.sleep       # tests replace this


class NeedInput(Exception):
    """A missing input (exit 2)."""


class NexusError(Exception):
    """The request or the download failed (exit 1)."""


def api_base():
    return os.environ.get('NEXUS_API_BASE') or API_BASE


def private_root():
    return Path(os.environ.get('VXRT_PRIVATE_ROOT') or REPO / 'build' / 'private').expanduser().resolve()


def downloads_dir():
    return private_root() / 'downloads' / 'nexus'


def api_key():
    k = (os.environ.get('NEXUS_API_KEY') or '').strip()
    if not k:
        raise NeedInput('NEXUS_API_KEY is not set. Create a personal API key at nexusmods.com > Site preferences > API Keys '
                        'and export it (local/env.sh: see local.example.sh and docs/SETUP_SKYRIM.md). Your Nexus password does not work '
                        'for the API.')
    return k


def scrub(text, key=None):
    """Remove the API key and any key=... query value from text meant for a message."""
    text = str(text)
    if key:
        text = text.replace(key, '***')
    return re.sub(r'([?&]key=)[^&\s]+', r'\1***', text)


NXM_HELP = """\
This download needs an nxm:// link from the website (Nexus gives free accounts no direct API download link):
  1. Open the file's page on nexusmods.com (the Files tab of the mod), logged in.
  2. Click "Mod Manager Download" on that file (not "Manual"), then confirm the countdown/"Download" page if one shows.
  3. The link looks like  nxm://<game>/mods/<mod_id>/files/<file_id>?key=...&expires=...  Copy it (right-click the button and copy
     the link address, or take it from the "open with" prompt). It is valid for a short time.
  4. Run:  python3 -I tools/nexus.py download <game> <mod_id> <file_id> --nxm 'nxm://...'
     (or give it to `tools/mods.py fetch --nxm ...` / `tools/vxrt_build.py mods-fetch --nxm ...`). Quote it: it contains & characters.
With Nexus Premium none of this is needed: the API issues the link itself."""


# --- HTTP ---------------------------------------------------------------------------------------------------------------

def _headers(key):
    h = {'Application-Name': APP_NAME, 'Application-Version': APP_VERSION, 'User-Agent': '%s/%s' % (APP_NAME, APP_VERSION),
         'Accept': 'application/json'}
    if key:
        h['apikey'] = key
    return h


def _parse_time(v):
    """Seconds from now until a reset header: a number of seconds, an HTTP/ISO timestamp, or None."""
    if v is None:
        return None
    v = str(v).strip()
    try:
        return max(0.0, float(v))
    except ValueError:
        pass
    try:
        t = datetime.datetime.fromisoformat(v.replace('Z', '+00:00'))
        if t.tzinfo is None:
            t = t.replace(tzinfo=datetime.timezone.utc)
        return max(0.0, (t - datetime.datetime.now(datetime.timezone.utc)).total_seconds())
    except ValueError:
        return None


def retry_wait(headers):
    """How long a 429 asks us to wait: Retry-After, else the reset of whichever Nexus limit (hourly, daily) is used up."""
    w = _parse_time(headers.get('Retry-After'))
    if w is not None:
        return w
    hourly_left = headers.get('X-RL-Hourly-Remaining')
    for name in (('X-RL-Hourly-Reset', 'X-RL-Daily-Reset') if str(hourly_left).strip() in ('0', '') else ('X-RL-Daily-Reset', 'X-RL-Hourly-Reset')):
        w = _parse_time(headers.get(name))
        if w is not None:
            return w
    return 60.0


def request(path_or_url, key=None, retries=MAX_RETRIES):
    """GET; returns (status, headers, urllib response) for a 2xx. Honours 429 (waits as the headers say, at most MAX_WAIT) and
    warns on stderr when the hourly allowance is nearly used. Other errors become NexusError/NeedInput with the key scrubbed."""
    url = path_or_url if '://' in path_or_url else api_base().rstrip('/') + '/' + path_or_url.lstrip('/')
    for attempt in range(retries + 1):
        req = urllib.request.Request(url, headers=_headers(key))
        try:
            r = urllib.request.urlopen(req, timeout=60)
            left = r.headers.get('X-RL-Hourly-Remaining')
            if left is not None and left.isdigit() and int(left) < 10:
                print('nexus: only %s API requests left this hour' % left, file=sys.stderr)
            return r.status, r.headers, r
        except urllib.error.HTTPError as e:
            if e.code == 429:
                wait = retry_wait(e.headers)
                e.close()
                if attempt >= retries:
                    raise NexusError('rate limited (429) and still limited after %d retries' % retries)
                if wait > MAX_WAIT:
                    raise NexusError('rate limited (429): Nexus asks for %d s; try again after that' % wait)
                print('nexus: rate limited, waiting %.0f s (try %d of %d)' % (wait, attempt + 1, retries), file=sys.stderr, flush=True)
                _sleep(wait + 0.5)
                continue
            body = ''
            try:
                body = e.read(300).decode('utf-8', 'replace')
            except Exception:
                pass
            e.close()
            raise HttpFail(e.code, scrub(body, key))
        except urllib.error.URLError as e:
            raise NexusError('cannot reach %s: %s' % (urllib.parse.urlsplit(url).netloc, scrub(e.reason, key)))
    raise NexusError('unreachable')


class HttpFail(NexusError):
    def __init__(self, code, body):
        super().__init__('HTTP %d %s' % (code, body[:200]))
        self.code, self.body = code, body


def get_json(path, key):
    try:
        _, _, r = request(path, key)
        with r:
            return json.loads(r.read().decode('utf-8'))
    except HttpFail as e:
        if e.code == 401:
            raise NexusError('Nexus rejected the API key (401). Check NEXUS_API_KEY: it must be the personal API key from '
                             'nexusmods.com > Site preferences > API Keys, not your password.')
        if e.code == 404:
            raise NexusError('not found (404): %s' % path)
        raise
    except json.JSONDecodeError:
        raise NexusError('Nexus returned something that is not JSON for %s' % path)


# --- API calls ----------------------------------------------------------------------------------------------------------

def _ident(s, what, pat=r'[A-Za-z0-9_-]+'):
    if not re.fullmatch(pat, str(s)):
        raise NexusError('bad %s: %r' % (what, s))
    return str(s)


def validate(key):
    return get_json('users/validate.json', key)


def list_files(game, mod_id, key):
    d = get_json('games/%s/mods/%s/files.json' % (_ident(game, 'game'), _ident(mod_id, 'mod id', r'\d+')), key)
    return d.get('files', [])


def file_info(game, mod_id, file_id, key):
    return get_json('games/%s/mods/%s/files/%s.json' % (_ident(game, 'game'), _ident(mod_id, 'mod id', r'\d+'), _ident(file_id, 'file id', r'\d+')), key)


def parse_nxm(url):
    """nxm://game/mods/<mod>/files/<file>?key=..&expires=..  ->  dict(game, mod_id, file_id, key, expires)."""
    u = urllib.parse.urlsplit(url)
    m = re.fullmatch(r'/mods/(\d+)/files/(\d+)', u.path)
    if u.scheme != 'nxm' or not u.netloc or not m:
        raise NexusError('not an nxm link of the form nxm://<game>/mods/<mod_id>/files/<file_id>?key=...&expires=...')
    q = urllib.parse.parse_qs(u.query)
    return dict(game=u.netloc, mod_id=m.group(1), file_id=m.group(2), key=(q.get('key') or [None])[0], expires=(q.get('expires') or [None])[0])


def download_links(game, mod_id, file_id, key, nxm=None):
    path = 'games/%s/mods/%s/files/%s/download_link.json' % (_ident(game, 'game'), _ident(mod_id, 'mod id', r'\d+'), _ident(file_id, 'file id', r'\d+'))
    if nxm:
        if not (nxm.get('key') and nxm.get('expires')):
            raise NexusError('the nxm link has no key and expires; copy the whole link')
        path += '?' + urllib.parse.urlencode(dict(key=nxm['key'], expires=nxm['expires']))
    try:
        _, _, r = request(path, key)
        with r:
            links = json.loads(r.read().decode('utf-8'))
    except HttpFail as e:
        if e.code == 403:
            raise NeedInput('Nexus refuses a direct download link (403): this account is not Premium and no valid nxm link was given.\n' + NXM_HELP)
        if e.code == 400:
            raise NeedInput('Nexus says the nxm key is invalid (400); get a fresh link.\n' + NXM_HELP)
        if e.code == 410:
            raise NeedInput('The nxm link has expired (410); get a fresh one.\n' + NXM_HELP)
        if e.code == 401:
            raise NexusError('Nexus rejected the API key (401). Check NEXUS_API_KEY.')
        if e.code == 404:
            raise NexusError('file not found (404): %s mod %s file %s' % (game, mod_id, file_id))
        raise
    if not isinstance(links, list) or not links or not isinstance(links[0], dict) or not links[0].get('URI'):
        raise NexusError('Nexus returned no download link')
    return links


# --- download -----------------------------------------------------------------------------------------------------------

def md5_file(path):
    h = hashlib.md5()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def _safe_name(s):
    s = os.path.basename(str(s or '').replace('\\', '/'))
    s = re.sub(r'[^A-Za-z0-9._+() -]', '_', s).strip(' .')
    return s or 'file'


def archive_path(game, mod_id, file_id, info):
    return downloads_dir() / ('%s-%s-%s-%s' % (game, mod_id, file_id, _safe_name(info.get('file_name') or info.get('name'))))


def check_file(path, size=None, md5=None):
    """None if the file matches the known size/md5, else a reason."""
    if size is not None and path.stat().st_size != size:
        return 'size %d, expected %d' % (path.stat().st_size, size)
    if md5 and md5_file(path) != md5.lower():
        return 'md5 differs from %s' % md5.lower()
    return None


def download(game, mod_id, file_id, nxm=None, md5=None):
    """Fetch one file; returns dict(path, md5, size, verified_by). Skips the transfer when the file is already there and verifies."""
    key = api_key()
    if nxm:
        n = parse_nxm(nxm) if isinstance(nxm, str) else nxm
        if (n['game'].lower(), n['mod_id'], n['file_id']) != (str(game).lower(), str(mod_id), str(file_id)):
            raise NexusError('the nxm link is for %s mod %s file %s, not %s mod %s file %s' % (n['game'], n['mod_id'], n['file_id'], game, mod_id, file_id))
        nxm = n
    info = file_info(game, mod_id, file_id, key)
    size = info.get('size_in_bytes')
    size = size if isinstance(size, int) and size > 0 else None
    api_md5 = info.get('md5') if re.fullmatch(r'[0-9a-fA-F]{32}', str(info.get('md5') or '')) else None
    want_md5 = (md5 or api_md5 or '').lower() or None
    dest = archive_path(game, mod_id, file_id, info)
    dest.parent.mkdir(parents=True, exist_ok=True)
    how = ' and '.join(x for x in (('size' if size else None), ('md5 (pinned)' if md5 else 'md5 (Nexus)' if api_md5 else None)) if x) or 'nothing (Nexus gave no size or md5)'
    if dest.is_file():
        why = check_file(dest, size, want_md5)
        if why is None:
            print('nexus: %s is already here (checked: %s)' % (dest.name, how), file=sys.stderr)
            return dict(path=str(dest), md5=md5_file(dest), size=dest.stat().st_size, verified_by=how)
        print('nexus: %s is there but %s; fetching again' % (dest.name, why), file=sys.stderr)
    link = download_links(game, mod_id, file_id, key, nxm)[0]['URI']
    sp = urllib.parse.urlsplit(link)
    if sp.scheme != 'https' and not (os.environ.get('NEXUS_API_BASE') and sp.scheme == 'http'):
        raise NexusError('Nexus gave a download link that is not https; refusing it')
    part = dest.with_name(dest.name + '.part')
    h = hashlib.md5(); got = 0
    try:
        _, _, r = request(link, None)          # the CDN link is signed: the API key is not sent to it
        with r, open(part, 'wb') as f:
            for b in iter(lambda: r.read(1 << 20), b''):
                f.write(b); h.update(b); got += len(b)
    except HttpFail as e:
        part.unlink(missing_ok=True)
        raise NexusError('the download server answered %s' % scrub(e))
    except BaseException:
        part.unlink(missing_ok=True)
        raise
    digest = h.hexdigest()
    problems = []
    if size is not None and got != size:
        problems.append('size %d, Nexus says %d' % (got, size))
    if want_md5 and digest != want_md5:
        problems.append('md5 %s, expected %s (%s)' % (digest, want_md5, 'pinned' if md5 else 'from Nexus'))
    if problems:
        part.unlink(missing_ok=True)
        raise NexusError('download of %s failed verification: %s. The file was discarded.' % (dest.name, '; '.join(problems)))
    os.replace(part, dest)
    print('nexus: downloaded %s (%d bytes, md5 %s; checked: %s)' % (dest.name, got, digest, how), file=sys.stderr)
    return dict(path=str(dest), md5=digest, size=got, verified_by=how)


# --- CLI ----------------------------------------------------------------------------------------------------------------

def cmd_validate(a):
    d = validate(api_key())
    print('user: %s' % d.get('name'))
    print('premium: %s' % ('yes' if d.get('is_premium') else 'no'))
    print('supporter: %s' % ('yes' if d.get('is_supporter') else 'no'))
    if not d.get('is_premium'):
        print('note: without Premium each download needs an nxm:// link from the website (tools/nexus.py download --nxm ...).')


def cmd_files(a):
    for f in sorted(list_files(a.game, a.mod_id, api_key()), key=lambda f: f.get('uploaded_timestamp') or 0):
        size = f.get('size_in_bytes') or (f.get('size_kb') or 0) * 1024
        print('%-10s %-9s %-8s %10.1f MB  %s  [%s]%s' % (f.get('file_id'), f.get('category_name') or '-', f.get('version') or f.get('mod_version') or '-',
              size / 1e6, f.get('name'), f.get('file_name'), '  md5 ' + f['md5'] if f.get('md5') else ''))


def cmd_download(a):
    r = download(a.game, a.mod_id, a.file_id, nxm=a.nxm, md5=a.md5)
    print(json.dumps(r) if a.json else '%s  md5 %s' % (r['path'], r['md5']))


def cmd_nxm(a):
    n = parse_nxm(a.url)
    r = download(n['game'], n['mod_id'], n['file_id'], nxm=n, md5=a.md5)
    print(json.dumps(r) if a.json else '%s  md5 %s' % (r['path'], r['md5']))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('validate').set_defaults(fn=cmd_validate)
    p = sub.add_parser('files'); p.add_argument('game'); p.add_argument('mod_id'); p.set_defaults(fn=cmd_files)
    p = sub.add_parser('download'); p.add_argument('game'); p.add_argument('mod_id'); p.add_argument('file_id')
    p.add_argument('--nxm', help='the nxm:// link from "Mod Manager Download" (needed without Premium)')
    p.add_argument('--md5', help='pinned md5 the file must have'); p.add_argument('--json', action='store_true'); p.set_defaults(fn=cmd_download)
    p = sub.add_parser('nxm'); p.add_argument('url'); p.add_argument('--md5'); p.add_argument('--json', action='store_true'); p.set_defaults(fn=cmd_nxm)
    a = ap.parse_args(argv)
    try:
        a.fn(a)
    except NeedInput as e:
        print('nexus: %s' % scrub(e, os.environ.get('NEXUS_API_KEY')), file=sys.stderr)
        return 2
    except NexusError as e:
        print('nexus: %s' % scrub(e, os.environ.get('NEXUS_API_KEY')), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
