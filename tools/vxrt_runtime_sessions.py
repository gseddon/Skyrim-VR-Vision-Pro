#!/usr/bin/env python3
"""Which running runtime processes conflict with a new harness run.

A run must not start while the user plays: any SteamVR (vrserver/vrcompositor), any Wine game, and any VXRuntime
process that is not provably owned by the harness or by the repository's own fixture tests refuses it.  A VXRuntime
process is owned when its environment is readable (same user, macOS KERN_PROCARGS2) and either

  * it carries the harness marker VXRT_HARNESS_RUN=<absolute run directory> and an explicit VXRT_ROOT that is not
    one of the user's roots, or
  * its VXRT_ROOT resolves inside a build directory of this repository's checkout (make check/check-arm64/
    aot-suite use VXRuntime/build/root; probes use <checkout>/build/...), worktrees included.

Anything unreadable, unmarked, on the default root (~/.vxrt) or on the user's roots is the user's.  An owned process
still conflicts when it writes where this run will (same or nested run directory, root or overlay, same TMPDIR).
Owned processes that may run concurrently are reported, so timing from overlapped runs can be discounted.
"""
import argparse
import ctypes
import json
import os
import re
import struct
import subprocess
import sys
import time
from pathlib import Path

MARKER = 'VXRT_HARNESS_RUN'
VXRT_NAME = re.compile(r'vxrt(-arm64)?(-[A-Za-z0-9_.]+)*')
VXRT_COMM = re.compile(r'vxrt(-[A-Za-z0-9_.]*)*')        # ucomm is cut at 16 characters
STEAMVR = re.compile(r'(^|[/\\\s])vr(server|compositor)(\.exe)?(\s|$)', re.I)
WINE_GAME = re.compile(r'wine.*(vrserver|hlvr|SkyrimVR)')
REPO = Path(__file__).resolve().parents[1]


def default_user_roots():
    """The player's roots (tools/vxrt_run.py USER_ROOTS): never a harness's."""
    drive = os.path.expanduser(os.environ.get('VXRT_DRIVE') or os.path.join(os.environ.get('VXRT_PRIVATE_ROOT') or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'build', 'private'), 'drive'))
    return [os.path.join(drive, 'vxrt_root'), os.path.join(drive, 'vxrt_steam_overlay')]


def checkout_roots(repo=REPO):
    """This checkout and, for a worktree, the main checkout (whose tree holds every worktree)."""
    roots = {Path(repo).resolve()}
    try:
        common = subprocess.run(['git', '-C', str(repo), 'rev-parse', '--path-format=absolute', '--git-common-dir'],
                                capture_output=True, text=True, timeout=10).stdout.strip()
        if common:
            roots.add(Path(common).resolve().parent)
    except (OSError, subprocess.SubprocessError):
        pass
    return sorted(roots)


def list_processes():
    """[(pid, ucomm, command)] of every process."""
    out = subprocess.run(['ps', '-axww', '-o', 'pid=,ucomm=,command='], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit():
            rows.append((int(parts[0]), parts[1], parts[2] if len(parts) > 2 else ''))
    return rows


def proc_args(pid):
    """(executable path, argv, env) of a process from KERN_PROCARGS2, or None if unreadable."""
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        argmax, size = ctypes.c_int(0), ctypes.c_size_t(ctypes.sizeof(ctypes.c_int))
        if libc.sysctl((ctypes.c_int * 2)(1, 8), 2, ctypes.byref(argmax), ctypes.byref(size), None, 0) or argmax.value <= 0:
            return None
        buf, size = ctypes.create_string_buffer(argmax.value), ctypes.c_size_t(argmax.value)
        if libc.sysctl((ctypes.c_int * 3)(1, 49, pid), 3, buf, ctypes.byref(size), None, 0):
            return None
        data = buf.raw[:size.value]
    except (OSError, AttributeError, ValueError):
        return None
    if len(data) < 5:
        return None
    argc = struct.unpack_from('i', data)[0]
    exe, _, rest = data[4:].partition(b'\0')
    strings = rest.lstrip(b'\0').split(b'\0')
    if argc < 1 or len(strings) < argc:
        return None
    argv = [os.fsdecode(s) for s in strings[:argc]]
    env = {}
    for s in strings[argc:]:
        if not s:
            break
        k, sep, v = os.fsdecode(s).partition('=')
        if sep:
            env[k] = v
    return os.fsdecode(exe), argv, env


def alive(pid):
    try:
        os.kill(pid, 0)                               # (signal 0: an existence check, nothing is sent)
    except ProcessLookupError:
        return False
    except OSError:
        pass
    return True


def proc_cwd(pid):
    """A process's working directory (to resolve a relative VXRT_ROOT), or None."""
    try:
        out = subprocess.run(['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if line.startswith('n/'):
            return line[1:]
    return None


def _real(path, cwd=None):
    p = Path(path)
    if not p.is_absolute():
        if cwd is None:
            return None
        p = Path(cwd) / p
    return Path(os.path.realpath(p))


def _overlaps(a, b):
    return a == b or a.is_relative_to(b) or b.is_relative_to(a)


def classify(pid, info, cwd_of, checkouts, user_roots):
    """('owned', record) or ('user', record) for one VXRuntime process."""
    rec = dict(pid=pid)
    if info is None:
        return 'user', dict(rec, reason='environment unreadable: not provably harness-owned')
    exe, argv, env = info
    rec['exe'] = exe
    if any(STEAMVR.search(a) for a in argv[1:]):
        return 'user', dict(rec, reason='hosts SteamVR (vrserver/vrcompositor)')
    root = env.get('VXRT_ROOT', '')
    if not root:
        return 'user', dict(rec, reason='default root (~/.vxrt): shared, not provably harness-owned')
    cwd = None if os.path.isabs(root) else cwd_of(pid)
    real_root = _real(root, cwd)
    if real_root is None:
        return 'user', dict(rec, reason=f'relative root {root} with unreadable working directory')
    rec['root'] = str(real_root)
    if any(_overlaps(real_root, Path(os.path.realpath(u))) for u in user_roots):
        return 'user', dict(rec, reason="uses the user's root")
    marker = env.get(MARKER, '')
    in_build = next((c for c in checkouts if real_root.is_relative_to(c) and 'build' in real_root.relative_to(c).parts), None)
    if marker and os.path.isabs(marker):
        rec.update(owner='harness', run=os.path.realpath(marker))
    elif in_build is not None:
        rec.update(owner='fixture', checkout=str(in_build))
    else:
        return 'user', dict(rec, reason=f'no {MARKER} marker and root outside the repository build directories')
    writes = [real_root] + ([Path(rec['run'])] if 'run' in rec else [])
    upper = env.get('VXRT_OVERLAY', '').rpartition(':')[2]
    if upper:
        up = _real(upper, cwd if cwd is not None else (None if os.path.isabs(upper) else cwd_of(pid)))
        if up is not None:
            writes.append(up)
            rec['overlay'] = str(up)
    rec['_writes'] = writes
    if env.get('TMPDIR'):
        rec['_tmp'] = _real(env['TMPDIR'], cwd)
    return 'owned', rec


def survey(own_paths, own_tmp=None, user_roots=None, checkouts=None, ps=None, args=None, cwd_of=None, alive_of=None):
    """{'user': [...], 'conflicts': [...], 'concurrent': [...]} for a run that writes into own_paths."""
    user_roots = default_user_roots() if user_roots is None else user_roots
    ps, args, cwd_of, alive_of = ps or list_processes, args or proc_args, cwd_of or proc_cwd, alive_of or alive
    checkouts = [Path(c).resolve() for c in (checkouts if checkouts is not None else checkout_roots())]
    own = [Path(os.path.realpath(p)) for p in own_paths]
    own_tmp = Path(os.path.realpath(own_tmp)) if own_tmp else None
    user, conflicts, concurrent = [], [], []
    me = os.getpid()
    for pid, comm, command in ps():
        if pid == me:
            continue
        exiting = comm.startswith('(') and comm.endswith(')')     # ps shows a process that is exiting as (name)
        name = os.path.basename(comm.strip('()'))
        if name in ('vrserver', 'vrcompositor'):
            user.append(dict(pid=pid, command=command[:160], reason='SteamVR is running'))
            continue
        if WINE_GAME.search(command):
            user.append(dict(pid=pid, command=command[:160], reason='a Wine game or SteamVR is running'))
            continue
        if not VXRT_COMM.fullmatch(name):
            continue
        info = args(pid)
        for _ in range(5 if info is None and not exiting else 0):   # (unreadable for a moment while starting/exiting)
            time.sleep(0.02)
            info = args(pid)
            if info is not None or not alive_of(pid):
                break
        if info is None and (exiting or not alive_of(pid)):
            continue                                  # exited since the listing: nothing of it runs any more
        if info is not None and not VXRT_NAME.fullmatch(os.path.basename(info[0])):
            continue                                  # a longer name that only starts like the runtime's
        kind, rec = classify(pid, info, cwd_of, checkouts, user_roots)
        if kind == 'user' and not alive_of(pid):
            continue                                  # exited while being read (its cwd or environment went with it)
        if kind == 'user':
            rec.setdefault('command', command[:160])
            user.append(rec)
            continue
        writes, tmp = rec.pop('_writes'), rec.pop('_tmp', None)
        clash = [str(w) for w in writes if any(_overlaps(w, o) for o in own)]
        if own_tmp is not None and tmp is not None and tmp == own_tmp:
            clash.append(f'TMPDIR {tmp}')
        if clash:
            conflicts.append(dict(rec, reason='writes where this run will: ' + ', '.join(clash)))
        else:
            concurrent.append(rec)
    return dict(user=user, conflicts=conflicts, concurrent=concurrent)


def _describe(rec):
    where = rec.get('run') or rec.get('root') or rec.get('command', '')
    return f"pid {rec['pid']} {rec.get('owner', '')} {where}".replace('  ', ' ') + (f" ({rec['reason']})" if 'reason' in rec else '')


def preconditions(own_paths, own_tmp=None, user_roots=None, **kw):
    """(typed precondition checks, concurrent owned processes) for a harness run."""
    s = survey(own_paths, own_tmp, user_roots, **kw)
    allowed = '; allowed concurrently (harness/fixture-owned, isolated): ' + '; '.join(map(_describe, s['concurrent'])) if s['concurrent'] else ''
    idle = not s['user']
    checks = [dict(code='user_not_playing', ok=idle,
                   detail=('no user runtime, SteamVR or Wine game running' if idle else
                           'running: ' + '; '.join(map(_describe, s['user']))) + allowed),
              dict(code='run_paths_unshared', ok=not s['conflicts'],
                   detail='no other runtime process uses this run\'s directories' if not s['conflicts'] else
                   'in use: ' + '; '.join(map(_describe, s['conflicts'])))]
    return checks, s['concurrent']


def main():
    ap = argparse.ArgumentParser(description='refuse (exit 3) when a run writing into --own would conflict')
    ap.add_argument('--own', action='append', default=[], required=True, help="a directory this run writes into")
    ap.add_argument('--tmp', help="this run's TMPDIR")
    ap.add_argument('--user-root', action='append', default=[])
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()
    checks, concurrent = preconditions(a.own, a.tmp, a.user_root or None)
    if a.json:
        print(json.dumps(dict(preconditions=checks, concurrent_runtime=concurrent), indent=2))
    else:
        for c in checks:
            print(('ok   ' if c['ok'] else 'FAIL ') + c['code'] + ': ' + c['detail'])
    sys.exit(0 if all(c['ok'] for c in checks) else 3)


if __name__ == '__main__':
    main()
