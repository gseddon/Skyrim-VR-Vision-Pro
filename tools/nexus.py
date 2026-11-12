#!/usr/bin/env python3
"""Small Nexus Mods client (Python standard library only) for fetching the mods in a mods list.

  NEXUS_API_KEY=... python3 -I tools/nexus.py validate
  python3 -I tools/nexus.py files    <game> <mod_id>
  python3 -I tools/nexus.py download <game> <mod_id> <file_id> [--nxm nxm://...] [--md5 HEX]
  python3 -I tools/nexus.py receive  nxm://...      (what the nxm handler app calls: queues the link; no key needed)
  python3 -I tools/nexus.py install-handler [--dry-run] | uninstall-handler | handler-status
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

Without Premium a download waits (--wait SECONDS, default 600 when run in a terminal, else 0) for the file's nxm link: from the
queue directory <downloads>/nexus/queue/ (filled by the nxm handler app, see install-handler) or pasted on stdin; Ctrl-C skips the file.

Exit status: 0 done, 1 failed, 2 a missing input (the key, or an nxm link for a non-premium account) with the message saying how to get it.
Tests point NEXUS_API_BASE at a local fake server; real use never sets it.
"""
import argparse
import datetime
import hashlib
import select
import shlex
import shutil
import subprocess
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

_sleep = time.sleep       # tests replace this (429 waits)
_poll_sleep = time.sleep  # tests replace this (queue polling)
POLL = 0.5
DEFAULT_WAIT = 600
STABLE = 1.5              # seconds a new file's size must stay the same before it counts as complete
ARCHIVE_EXT = ('.zip', '.7z', '.rar')
PARTIAL_EXT = ('.crdownload', '.download', '.part', '.partial', '.opdownload', '.tmp', '.aria2')


class NeedInput(Exception):
    """A missing input (exit 2)."""


class NotPremium(NeedInput):
    """403 on the download link: this account needs an nxm link for the file."""


class Skipped(NeedInput):
    """The user skipped the file (Ctrl-C) or the wait ran out."""


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
            raise NotPremium('Nexus refuses a direct download link (403): this account is not Premium and no valid nxm link was given.\n' + NXM_HELP)
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


def download(game, mod_id, file_id, nxm=None, md5=None, wait=0, progress=None):
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
    try:
        links = download_links(game, mod_id, file_id, key, nxm)
    except NotPremium:
        if not wait or nxm:
            raise
        nxm = await_nxm(game, mod_id, file_id, info, key, wait, progress)
        links = download_links(game, mod_id, file_id, key, nxm)
    link = links[0]['URI']
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


# --- the key-free path: the browser downloads, we pick the archive up from the Downloads folder ----------------------------

def browser_downloads_dir():
    return Path(os.environ.get('VXRT_DOWNLOADS_DIR') or '~/Downloads').expanduser()


def files_page(game, mod_id, file_id):
    if not file_id:                  # (a list that pins only the md5: the mod's Files tab, the file is matched by md5)
        return 'https://www.nexusmods.com/%s/mods/%s?tab=files' % (game, mod_id)
    return 'https://www.nexusmods.com/%s/mods/%s?tab=files&file_id=%s' % (game, mod_id, file_id)


_md5_cache = {}


def _cached_md5(p, st):
    k = (str(p), st.st_size, st.st_mtime_ns)
    if k not in _md5_cache:
        _md5_cache[k] = md5_file(p)
    return _md5_cache[k]


def _complete_archives(folder, sizes):
    """Archives in folder that look finished: right extension, not a partial download, size unchanged for STABLE seconds.
    sizes is the caller's {path: (size, since)} memory between polls."""
    now = time.time(); out = []; sizes['unstable'] = 0
    try:
        entries = list(folder.iterdir())
    except OSError as e:
        raise NexusError('cannot read the downloads folder %s: %s' % (folder, e.strerror or e))
    for p in entries:
        n = p.name.lower()
        if n.startswith('.') or not n.endswith(ARCHIVE_EXT) or n.endswith(PARTIAL_EXT) or not p.is_file():
            continue
        try:
            st = p.stat()
        except OSError:
            continue
        old = sizes.get(p) if p != 'unstable' else None
        if old is None or old[0] != st.st_size:
            sizes[p] = (st.st_size, now)
        if now - sizes[p][1] >= STABLE or now - st.st_mtime >= STABLE * 4:
            out.append((p, st))
        else:
            sizes['unstable'] += 1
    return sorted(out, key=lambda t: -t[1].st_mtime)


def cache_dirs():
    """Where this build keeps archives it has already fetched or been given (all under the private root)."""
    r = private_root()
    return [r / 'downloads', r / 'downloads' / 'nexus', r / 'skse']


def cache_lookup(md5, folders=None):
    """The archive in the build's own download cache whose md5 is `md5` (any file name), or None. The md5 is the only acceptance rule."""
    want = (md5 or '').lower()
    if not want:
        return None
    for f in (folders if folders is not None else cache_dirs()):
        try:
            entries = sorted(Path(f).iterdir())
        except OSError:
            continue
        for p in entries:
            n = p.name.lower()
            if n.startswith('.') or not n.endswith(ARCHIVE_EXT) or n.endswith(PARTIAL_EXT):
                continue
            try:
                if p.is_file() and _cached_md5(p, p.stat()) == want:
                    return p
            except OSError:
                continue
    return None


def manual_fetch(game, mod_id, file_id, name=None, md5=None, wait=0, progress=None, accept_name=False, folder=None):
    """No API key: ask the user to download the file in the browser ("Manual download", then "Slow download") and take the archive from the
    Downloads folder (new, or already there). Matched by the pinned md5, else by the mod id in the file name (Nexus names are
    <name>-<mod_id>-<version>-<timestamp>.<ext>) after a yes from the user. The archive is copied (not moved) into the private downloads dir."""
    game = _ident(game, 'game'); mod_id = _ident(mod_id, 'mod id', r'\d+'); file_id = _ident(file_id, 'file id', r'\d+') if file_id else None
    if not file_id and not md5:
        raise NexusError('without a file id the file can only be matched by its md5: pin it')
    folder = Path(folder) if folder else browser_downloads_dir()
    want_md5 = (md5 or '').lower() or None
    e = lambda m='': print(m, file=sys.stderr, flush=True)
    tty = sys.stdin is not None and sys.stdin.isatty()
    label = name or 'mod %s' % mod_id
    pos = ('%d of %d done' % progress) if isinstance(progress, tuple) else progress
    pat = re.compile(r'-%s-' % re.escape(mod_id))
    sizes = {}; refused = set(); said = set(); started = False
    hit = cache_lookup(want_md5)
    if hit:
        e('Using %s from the build\'s download cache (md5 %s).' % (hit, want_md5))
        return dict(path=str(hit), md5=want_md5, size=hit.stat().st_size, verified_by='pinned md5')

    def finish(src, st):
        dest = downloads_dir() / ('%s-%s-%s-%s' % (game, mod_id, file_id or 'md5', _safe_name(src.name)))
        dest.parent.mkdir(parents=True, exist_ok=True)
        part = dest.with_name(dest.name + '.part')
        try:
            shutil.copyfile(src, part)
            got = md5_file(part)
            if want_md5 and got != want_md5:
                raise NexusError('%s does not have the pinned md5 after copying' % src.name)
            os.replace(part, dest)
        finally:
            part.unlink(missing_ok=True)
        e('Picked up %s from %s (copied, the original is untouched; md5 %s).' % (src.name, folder, got))
        return dict(path=str(dest), md5=got, size=dest.stat().st_size, verified_by='pinned md5' if want_md5 else 'file name and your confirmation')

    def scan():
        for p, st in _complete_archives(folder, sizes):
            if p in refused:
                continue
            by_name = bool(pat.search(p.name))
            if want_md5:
                got = _cached_md5(p, st)
                if got == want_md5:
                    return finish(p, st)
                if by_name and p.name not in said:
                    said.add(p.name); e('Ignoring %s: it looks like a file of this mod but its md5 differs from the pinned one (%s).' % (p.name, want_md5))
                continue
            if not by_name:
                continue
            if accept_name:
                return finish(p, st)
            if not tty:
                if p.name not in said:
                    said.add(p.name); e('Found %s (name matches mod %s) but cannot ask you to confirm without a terminal; re-run with --accept-name-match.' % (p.name, mod_id))
                continue
            try:
                ok = input('Found %s in %s. Is this "%s" (file %s)? [y/N] ' % (p.name, folder, label, file_id)).strip().lower() in ('y', 'yes')
            except EOFError:
                ok = False
            if ok:
                return finish(p, st)
            refused.add(p)
        return None

    r = scan()
    if not r and sizes.get('unstable'):          # something is still being written (or was just written): give it a moment
        _poll_sleep(STABLE + 0.1); r = scan()
    if r:
        return r
    e()
    if pos:
        e('[%s]' % pos)
    e('No Nexus API key is set (or --manual was given), so the download goes through your browser:')
    e('  Mod:   %s' % label)
    e('  1. Open this page (logged in to Nexus):  %s' % files_page(game, mod_id, file_id))
    e('  2. Click "Manual download", then "Slow download".')
    e("  3. I'll pick the file up from your Downloads folder (%s)." % folder)
    e('Waiting up to %d s. Press Ctrl-C to skip this mod.' % wait)
    try:
        if tty and input('Open the page now with `open`? [y/N] ').strip().lower() in ('y', 'yes'):
            subprocess.run(['open', files_page(game, mod_id, file_id)])
        deadline = time.time() + wait
        while time.time() < deadline:
            _poll_sleep(POLL)
            r = scan()
            if r:
                return r
    except (KeyboardInterrupt, EOFError):
        e('Skipped %s.' % label)
        raise Skipped('skipped %s by request' % label)
    raise Skipped('no matching archive appeared in %s for %s within %d s' % (folder, label, wait))


def external_fetch(name, url, file_name, md5, wait=0, folders=None):
    """An archive that is not on Nexus (SKSE VR): no key and no account. Found by its md5 (any file name, so a browser's "name (1).7z" counts)
    in the private downloads folder or the browser's Downloads folder; if it is not there yet, say where to get it and watch the folder for up
    to `wait` seconds (the same watcher as manual_fetch). Returns the path in place (nothing is copied)."""
    want = md5.lower()
    folders = [Path(f) for f in (folders or cache_dirs() + [browser_downloads_dir()])]
    sizes = {}
    e = lambda m='': print(m, file=sys.stderr, flush=True)

    def scan():
        for f in folders:
            direct = f / file_name
            for p, st in ([(direct, direct.stat())] if direct.is_file() else []) + (_complete_archives(f, sizes) if f.is_dir() else []):
                if _cached_md5(p, st) == want:
                    return p
        return None

    r = scan()
    if not r and sizes.get('unstable'):
        _poll_sleep(STABLE + 0.1); r = scan()
    if r:
        return r
    e('%s is not on Nexus. Download it in your browser (no account needed):' % name)
    e('  %s' % url)
    e('and keep the file name (%s). I check the md5 (%s) and pick it up from your Downloads folder (%s).' % (file_name, want, folders[-1]))
    if wait:
        e('Waiting up to %d s. Press Ctrl-C to skip.' % wait)
    try:
        deadline = time.time() + wait
        while time.time() < deadline:
            _poll_sleep(POLL)
            r = scan()
            if r:
                e('Found %s (md5 %s).' % (r, want))
                return r
    except KeyboardInterrupt:
        raise Skipped('skipped %s by request' % name)
    raise Skipped('no archive with md5 %s appeared in %s for %s' % (want, ', '.join(str(f) for f in folders), name))


def fetch_file(game, mod_id, file_id, nxm=None, md5=None, wait=0, progress=None, name=None, manual=False, accept_name=False):
    """One entry point: the API path when a key is set (and not --manual), else the Downloads-folder path."""
    if manual or not file_id or not (os.environ.get('NEXUS_API_KEY') or '').strip():
        if nxm:
            print('nexus: an nxm link cannot be used without an API key (the download-link call needs the key); using the Downloads folder instead.', file=sys.stderr)
        return manual_fetch(game, mod_id, file_id, name=name, md5=md5, wait=wait, progress=progress, accept_name=accept_name)
    return download(game, mod_id, file_id, nxm=nxm, md5=md5, wait=wait, progress=('%d of %d done' % progress) if isinstance(progress, tuple) else progress)


# --- nxm hand-off: the queue, the handler app, the prompt ------------------------------------------------------------------

def queue_dir():
    return downloads_dir() / 'queue'


def receive(url):
    """Queue an nxm link (called by the handler app). Validates its form; prints no part of the link."""
    n = parse_nxm(url)
    if not (n['key'] and n['expires']):
        raise NexusError('that nxm link has no key and expires')
    q = queue_dir(); q.mkdir(parents=True, exist_ok=True)
    os.chmod(q, 0o700)
    name = '%d-%s-%s-%s.nxm' % (time.time() * 1000, n['game'], n['mod_id'], n['file_id'])
    tmp = q / (name + '.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(url.strip() + '\n')
    os.replace(tmp, q / name)
    return q / name


def _queued():
    q = queue_dir()
    return sorted(q.glob('*.nxm')) if q.is_dir() else []


def _stdin_line():
    """A line the user pasted, or None when none is waiting (only when stdin is a terminal)."""
    if sys.stdin is None or not sys.stdin.isatty():
        return None
    if select.select([sys.stdin], [], [], 0)[0]:
        return sys.stdin.readline().strip()
    return None


def _mod_name(game, mod_id, key):
    try:
        return get_json('games/%s/mods/%s.json' % (_ident(game, 'game'), _ident(mod_id, 'mod id', r'\d+')), key).get('name') or None
    except (NexusError, NeedInput):
        return None


def handler_bundle_id():
    return 'local.vxrt.NexusHandler'


def handler_installed():
    try:
        return get_default_handler() == handler_bundle_id()
    except Exception:
        return False


def _link_matches(n, game, mod_id, file_id):
    return (n['game'].lower(), n['mod_id'], n['file_id']) == (str(game).lower(), str(mod_id), str(file_id))


def await_nxm(game, mod_id, file_id, info, key, wait, progress=None):
    """Tell the user how to get this file's nxm link, then wait for it in the queue or on stdin. Returns the parsed link.
    Raises Skipped on Ctrl-C or timeout. Wrong-file links are refused politely and the wait goes on."""
    modname = _mod_name(game, mod_id, key) or 'mod %s' % mod_id
    fname = info.get('name') or info.get('file_name') or 'file %s' % file_id
    url = 'https://www.nexusmods.com/%s/mods/%s?tab=files&file_id=%s' % (game, mod_id, file_id)
    auto = handler_installed()
    tty = sys.stdin is not None and sys.stdin.isatty()
    e = lambda m='': print(m, file=sys.stderr, flush=True)
    e()
    if progress:
        e('[%s]' % progress)
    e('This account is not Premium, so Nexus needs you to start the download in your browser:')
    e('  Mod:   %s' % modname)
    e('  File:  %s' % fname)
    e('  1. Open this page (logged in to Nexus):  %s' % url)
    e('  2. Click "Mod Manager Download" on the file "%s".' % fname)
    if auto:
        e("  3. That's all: the nxm handler is installed, so I'll pick the link up automatically.")
    else:
        e('  3. The nxm handler is not installed, so copy the nxm:// link' + (' and paste it here, then press Return.' if tty else ' and run: python3 -I tools/nexus.py receive \'nxm://...\''))
        e('     (python3 -I tools/nexus.py install-handler sets up the handler once.)')
    e('Waiting up to %d s. Press Ctrl-C to skip this file.' % wait)
    if tty:
        try:
            if input('Open the page now with `open`? [y/N] ').strip().lower() in ('y', 'yes'):
                subprocess.run(['open', url])
        except EOFError:
            pass
        except KeyboardInterrupt:
            raise Skipped('skipped %s by request' % fname)
    seen = set(); deadline = time.time() + wait
    try:
        while True:
            cands = [(p, None) for p in _queued()]
            line = _stdin_line()
            if line:
                cands.append((None, line))
            for p, text in cands:
                try:
                    text = text or p.read_text().strip()
                    n = parse_nxm(text)
                except (NexusError, OSError):
                    if text is not None and p is None:
                        e('That is not an nxm:// link; copy the whole link from "Mod Manager Download".')
                    continue
                if not _link_matches(n, game, mod_id, file_id):
                    tag = p.name if p else 'stdin'
                    if tag not in seen:
                        seen.add(tag)
                        e('That link is for a different file (%s mod %s file %s), not %s. Keeping waiting; click "Mod Manager Download" on the right file.'
                          % (n['game'], n['mod_id'], n['file_id'], file_id))
                    continue
                if not (n['key'] and n['expires']) or int(n['expires'] or 0) < time.time():
                    if (p.name if p else 'stdin') not in seen:
                        seen.add(p.name if p else 'stdin'); e('That link has expired or is incomplete; click "Mod Manager Download" again.')
                    continue
                if p:
                    p.unlink(missing_ok=True)
                e('Got the link for %s.' % fname)
                return n
            if time.time() >= deadline:
                raise Skipped('timed out after %d s waiting for the nxm link of %s' % (wait, fname))
            _poll_sleep(POLL)
    except KeyboardInterrupt:
        e('Skipped %s.' % fname)
        raise Skipped('skipped %s by request' % fname)


# --- the handler app -------------------------------------------------------------------------------------------------------

def tools_dir():
    return private_root() / 'tools'


def app_path():
    return tools_dir() / 'NexusHandler.app'


def _applescript_str(s):
    if any(c in s for c in '"\\\n'):
        raise NexusError('a path contains a quote, backslash or newline; cannot build the handler: %s' % s)
    return '"%s"' % s


def build_app():
    """Compile the AppleScript applet (osacompile) with the nxm URL scheme, into <private>/tools/NexusHandler.app. Not committed."""
    app = app_path(); app.parent.mkdir(parents=True, exist_ok=True)
    script = ('on open location theURL\n'
              '  do shell script "VXRT_PRIVATE_ROOT=" & quoted form of %s & " " & quoted form of %s & " -I " & quoted form of %s & " receive " & quoted form of theURL\n'
              'end open location\n') % (_applescript_str(str(private_root())), _applescript_str(sys.executable), _applescript_str(str(Path(__file__).resolve())))
    src = app.parent / 'NexusHandler.applescript'
    src.write_text(script)
    if app.exists():
        shutil.rmtree(app)
    r = subprocess.run(['osacompile', '-o', str(app), str(src)], capture_output=True, text=True)
    if r.returncode:
        raise NexusError('osacompile failed: %s' % r.stderr.strip()[:200])
    plist = str(app / 'Contents' / 'Info.plist')
    for args in (['-replace', 'CFBundleIdentifier', '-string', handler_bundle_id()],
                 ['-replace', 'LSUIElement', '-bool', 'true'],
                 ['-replace', 'CFBundleURLTypes', '-json', json.dumps([{'CFBundleURLName': 'Nexus Mods link', 'CFBundleURLSchemes': ['nxm']}])]):
        r = subprocess.run(['plutil'] + args + [plist], capture_output=True, text=True)
        if r.returncode:
            raise NexusError('plutil failed: %s' % r.stderr.strip()[:200])
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], capture_output=True)
    return app


_JXA_GET = 'function run(a){ObjC.import("CoreServices");var r=$.LSCopyDefaultHandlerForURLScheme($(a[0]));try{return ObjC.unwrap(ObjC.castRefToObject(r))||""}catch(e){return ""}}'
_JXA_SET = 'function run(a){ObjC.import("CoreServices");return String($.LSSetDefaultHandlerForURLScheme($(a[0]),$(a[1])))}'


def get_default_handler(scheme='nxm'):
    r = subprocess.run(['osascript', '-l', 'JavaScript', '-e', _JXA_GET, scheme], capture_output=True, text=True, timeout=30)
    if r.returncode:
        raise NexusError('cannot read the default handler: %s' % r.stderr.strip()[:200])
    return r.stdout.strip()


def set_default_handler(bundle_id, scheme='nxm'):
    r = subprocess.run(['osascript', '-l', 'JavaScript', '-e', _JXA_SET, scheme, bundle_id], capture_output=True, text=True, timeout=30)
    if r.returncode or r.stdout.strip() != '0':
        raise NexusError('LSSetDefaultHandlerForURLScheme failed (%s %s)' % (r.stdout.strip(), r.stderr.strip()[:200]))


def _lsregister(app):
    ls = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
    subprocess.run([ls, '-f', str(app)], capture_output=True)


def prev_file():
    return tools_dir() / 'nxm-handler-previous.json'


def _handler_note(h):
    low = h.lower()
    if any(x in low for x in ('vortex', 'modorganizer', 'mo2', 'nexus')):
        return ' (this looks like a Nexus mod manager such as Vortex or Mod Organizer; its nxm links will come to this tool instead until you run uninstall-handler)'
    return ''


def cmd_install_handler(a):
    prev = get_default_handler()
    me = handler_bundle_id()
    print('install-handler: this changes a SYSTEM-WIDE setting outside this repository.')
    print('  It builds a small AppleScript app at %s (git-ignored, never committed),' % app_path())
    print('  then makes it the default macOS handler for nxm:// links ("Mod Manager Download" on nexusmods.com).')
    print('  Every nxm:// link then goes to: python3 -I %s receive <link>, which only saves it in %s.' % (Path(__file__).resolve(), queue_dir()))
    print('  Current default handler for nxm://: %s%s' % (prev or '(none)', _handler_note(prev) if prev else ''))
    print('  It is recorded in %s so `uninstall-handler` can restore it.' % prev_file())
    if prev == me:
        print('Already installed.'); return
    if a.dry_run:
        print('(dry run: nothing built, nothing changed)'); return
    if not (sys.stdin and sys.stdin.isatty()):
        raise NeedInput('install-handler asks for confirmation and needs a terminal; there is no --yes')
    try:
        if input('Make this tool the default nxm:// handler? [y/N] ').strip().lower() not in ('y', 'yes'):
            print('Not changed.'); return
    except (EOFError, KeyboardInterrupt):
        print('\nNot changed.'); return
    app = build_app()
    prev_file().write_text(json.dumps({'previous': prev, 'installed': me}) + '\n')
    _lsregister(app)
    set_default_handler(me)
    now = get_default_handler()
    print('Installed. Default nxm:// handler is now: %s' % now if now == me else 'Warning: the default handler reads %r after setting; check System Settings / Finder.' % now)


def cmd_uninstall_handler(a):
    me = handler_bundle_id(); cur = get_default_handler()
    prev = None
    if prev_file().is_file():
        prev = json.loads(prev_file().read_text()).get('previous') or None
    print('uninstall-handler: current nxm:// handler: %s; recorded previous: %s' % (cur or '(none)', prev or '(none)'))
    if cur != me:
        print('This tool is not the default nxm:// handler; nothing to restore.')
    elif prev and prev != me:
        if a.dry_run:
            print('(dry run) would restore %s' % prev)
        else:
            set_default_handler(prev); print('Restored %s as the nxm:// handler.' % prev)
    else:
        print('There was no previous handler to restore. macOS cannot clear a default; choose one in the app that should handle nxm:// links, or leave it.')
    if not a.dry_run and app_path().exists():
        shutil.rmtree(app_path()); print('Removed %s' % app_path())
        prev_file().unlink(missing_ok=True)


def cmd_handler_status(a):
    cur = get_default_handler()
    print('nxm:// handler: %s' % (cur or '(none)'))
    print('this tool is the handler: %s' % ('yes' if cur == handler_bundle_id() else 'no'))
    print('app built: %s' % ('yes (%s)' % app_path() if app_path().exists() else 'no'))
    print('queued links: %d' % len(_queued()))


def cmd_receive(a):
    receive(a.url)
    print('queued')


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


def default_wait(v):
    return DEFAULT_WAIT if v is None and sys.stdin is not None and sys.stdin.isatty() else (v or 0)


def cmd_download(a):
    r = fetch_file(a.game, a.mod_id, a.file_id, nxm=a.nxm, md5=a.md5, wait=default_wait(a.wait), manual=a.manual, accept_name=a.accept_name_match)
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
    p.add_argument('--md5', help='pinned md5 the file must have'); p.add_argument('--json', action='store_true')
    p.add_argument('--manual', action='store_true', help='use the browser and the Downloads folder even when a key is set')
    p.add_argument('--accept-name-match', action='store_true', help='without a terminal: accept an archive whose name carries the mod id (otherwise pin --md5)')
    p.add_argument('--wait', type=int, help='seconds to wait for the nxm link of a non-premium download (default 600 in a terminal, else 0)'); p.set_defaults(fn=cmd_download)
    p = sub.add_parser('receive'); p.add_argument('url'); p.set_defaults(fn=cmd_receive)
    for name, fn in (('install-handler', cmd_install_handler), ('uninstall-handler', cmd_uninstall_handler)):
        p = sub.add_parser(name); p.add_argument('--dry-run', action='store_true', help='show what would change; change nothing'); p.set_defaults(fn=fn)
    sub.add_parser('handler-status').set_defaults(fn=cmd_handler_status)
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
