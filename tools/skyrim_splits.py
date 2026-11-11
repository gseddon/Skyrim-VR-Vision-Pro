#!/usr/bin/env python3
"""skyrim_splits.py: record the module-splits profile every new Skyrim VR build needs (`vxrt_build.py aot` runs this when the profile is missing).

In plain words: a list of places in the game where it does a kind of memory access that Apple chips cannot do in one go. The recompiler has to know
them in advance, and learns them by watching the game run on your Mac for about 10 minutes.

The recording runs plain Skyrim: no mods, no SKSE, no plugins (play_skyrim_dev.sh without --mods-config). The profile only holds addresses inside SkyrimVR.exe.

The profile is the list of x86 instructions in SkyrimVR.exe whose ordered (atomic) memory access crosses 16 bytes, as the runtime sees them
in a game run (VXRT_AOT_SPLITS, VXRuntime/translator/aot.c); vxrt-aot gives those instructions plain accesses between barriers, which compiled
code can do and cannot otherwise fix up. A module set made without it stops SkyrimVRTools with a null call in the first minute of a strict run
(5 of 5 runs without it, none of 2 with it; plans/2026-11-11-skyrim-mods-combined.md). It holds only addresses of the player's own exe, is derived from
the game and, as an exception the user authorized on 2026-11-11 (it is only addresses in the owned exe, like the committed shader-hash manifest), a copy for the pinned
exe is committed (tools/profiles/); the build uses it first and records only when the exe does not match. Either way it is kept in
<VXRT_AOT_INPUTS>/splits-1022-at-0x140000000.txt with its sha256 beside it (.sha256), which the pipeline config pins (${VXRT_SPLITS_SHA256}).

  python3 -I tools/skyrim_splits.py record [--force] [--rounds N] [--seconds 600] [--no-tour]    build an unsplit Mac module set, run the game on the Mac with the
                                                                        scripted pad input, keep every address seen (a re-run adds to the file).
                                                                        A top-up round (one that starts from a profile) also tours: see TOUR below.
  python3 -I tools/skyrim_splits.py install                             use the profile tracked in the repository (tools/profiles/), which the build does first
  python3 -I tools/skyrim_splits.py status                              prints ok / missing / mismatch

TOUR (default for a round that starts from a profile; --no-tour turns it off): the game only runs an instruction when the player gets to it, so a top-up
round loads a copy of the "race" autosave (a character already in the world, from build/private/saves/race; the player's own saves are never written)
and teleports with the developer console to a spread of places: it presses F2 once, then for each place the backtick, types "coc <cell>" and Return
(the game closes the console when the teleport starts; the keys go through the dev keyboard, tools/play_skyrim_dev.sh --key-script), one place about every 110 s after the first 100 s. The first place is
typed twice, because the save may still be loading at the first try. Pictures from the sparse eye dumps show which places were reached.

Subject: the actual game on the Mac development host (non-strict AOT: an unsplit exe still runs, slowly, and the runtime fixes each access up);
the profile is as complete as the run's path through the game. Exit 0 ok, 2 an input is missing, 1 failed.
"""
import argparse
import json
from pathlib import Path
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vxrt_env as E

REPO = E.REPO


def splits_path():
    return Path(E.variables()['VXRT_SPLITS_FILE'])


def tracked():
    """The profile kept in the repository for exactly this prepared exe: tools/profiles/splits-<prepared exe sha256>.txt.gz (gzipped like the shader
    manifest), with the sha256 of the unpacked text in the .sha256 beside it. Returns the unpacked text, or None when there is none or it does not match."""
    import gzip
    f = REPO / 'tools' / 'profiles' / ('splits-%s.txt.gz' % E.PREPARED_EXE_SHA256)
    side = f.with_name(f.name + '.sha256')
    if not f.is_file() or not side.is_file():
        return None
    import hashlib
    data = gzip.decompress(f.read_bytes())
    return data if hashlib.sha256(data).hexdigest() == side.read_text().split()[0] else None


def install():
    """Use the profile tracked in the repository (it holds only addresses in the pinned SkyrimVR.exe): copy it into the private inputs with its hash.
    Returns True when a valid profile is in place afterwards. The player's own recording (`record`) adds to it."""
    f = splits_path()
    if status() == 'ok':
        return True
    t = tracked()
    if t is None:
        return False
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_bytes(t)
    f.with_name(f.name + '.sha256').write_text(E.sha256_file(f) + '\n')
    print('splits: using the profile tracked in the repository (tools/profiles, %d addresses); `record --force` adds your own recording to it' % len(t.split()), file=sys.stderr)
    return True


def status():
    f = splits_path()
    side = f.with_name(f.name + '.sha256')
    if not f.is_file():
        return 'missing'
    want = side.read_text().split()[0] if side.is_file() else E.SPLITS_SHA256
    return 'ok' if E.sha256_file(f) == want else 'mismatch'


def record(a):
    f = splits_path()
    if not a.force and install():
        print('splits: %s is in place' % f, file=sys.stderr)
        return 0
    if not Path(E.variables()['VXRT_PREPARED_EXE']).is_file():
        print('splits: the prepared SkyrimVR.exe is missing (made by: tools/vxrt_build.py prepare)', file=sys.stderr)
        return 2
    if not f.is_file() and tracked() is not None:
        install()                                     # (`record --force` adds to the shipped profile)
    rounds = a.rounds or (1 if f.is_file() else 2)
    for n in range(1, rounds + 1):
        # round 1 without any profile runs an unsplit exe, which is slow (the load alone takes minutes): it learns the load and the menus.
        # Later rounds run modules made with what is known, which is fast enough to reach Helgen, and add what is still missing.
        tour = f.is_file() and a.tour is not False
        rc = one_round(a, n, a.seconds if not f.is_file() else (a.top_up_seconds or (a.seconds if tour else 300)), tour)
        if rc:
            return rc
    return 0


# Places for the tour: cell ids of Skyrim.esm that `coc` accepts (interiors, exteriors and wilderness; checked against the cell records of the supported game).
TOUR_CELLS = ['WhiterunDragonsreach', 'RiverwoodSleepingGiantInn', 'BleakFallsBarrow01', 'SolitudeCastleDour', 'MarkarthUnderStoneKeep',
              'WhiterunExterior12', 'POITundra03']
TOUR_FIRST, TOUR_EVERY = 100, 110


def tour_script(seconds):
    """VXRT_XRIZER_DEV_KEY_SCRIPT for the tour (START:KEY:HOLD,..., seconds since the run started): one coc per slot; the first is repeated 40 s later.
    Returns (script, [(second, cell)]) for as many places as fit before the end of the run."""
    plan = [(TOUR_FIRST + i * TOUR_EVERY, c) for i, c in enumerate(TOUR_CELLS) if TOUR_FIRST + i * TOUR_EVERY + 40 <= seconds]
    if plan:
        plan.insert(1, (plan[0][0] + 40, plan[0][1]))
    # F2 once (the keys then go to the game), then per place: backtick opens the console, "coc <cell>", Return. No backtick afterwards: the game closes the
    # console itself when the teleport starts, so a closing backtick would open it again and turn every later place into stray game keys (seen 2026-11-11).
    keys = [(plan[0][0] - .5, 'f2', .1)] if plan else []
    for t0, cell in plan:
        keys.append((t0, 'grave', .2))
        t = t0 + .75
        for ch in 'coc ' + cell.lower():
            keys.append((t, 'space' if ch == ' ' else ch, .1))
            t += .25
        keys.append((t + .25, 'return', .2))
    return ','.join('%.2f:%s:%.2f' % k for k in keys), plan


def tour_saves(work):
    """A fresh saves directory holding only a copy of the newest 'race' autosave (a character already in the world; `coc` does nothing in the opening or the race menu)."""
    src = sorted((E.private_root() / 'saves' / 'race').glob('Autosave*.ess'), key=lambda p: p.stat().st_mtime)
    if not src:
        return None
    import shutil
    d = work / 'tour-saves'
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir()
    shutil.copy(src[-1], d)
    return d


def one_round(a, n, seconds, tour):
    f = splits_path()
    priv = E.private_root()
    work = priv / 'skyrimvr' / E.ORIGINAL_EXE_SHA256 / 'aot-splits-record'
    work.mkdir(parents=True, exist_ok=True)
    cfg = json.loads((REPO / 'tools' / 'skyrim_aot_skyrimvr.json').read_text())
    import skyrim_aot_pipeline as P
    cfg = P.expand_config(cfg)
    cfg.pop('_note', None)
    cfg['exe']['splits'] = {'path': str(f), 'sha256': E.sha256_file(f)} if f.is_file() else None
    (work / 'config.json').write_text(json.dumps(cfg, indent=1))
    out = work / ('modules-' + time.strftime('%Y%m%d-%H%M%S'))
    print('splits: round %d: building the Mac module set %s' % (n, 'with the profile so far' if cfg['exe']['splits'] else 'unsplit (the first time takes a while)'), file=sys.stderr)
    if subprocess.run([sys.executable, str(REPO / 'tools' / 'skyrim_aot_pipeline.py'), '--config', str(work / 'config.json'), '--build', '--out', str(out)],
                      stdout=sys.stderr).returncode:
        return 1
    if not (REPO / 'VXRuntime' / 'build' / 'play-host' / 'vxrt-arm64').is_file():
        if subprocess.run([str(REPO / 'tools' / 'play_skyrim_dev.sh'), '--build-only'], env=dict(os.environ, SKYRIM_AOT_DIR=str(priv)), stdout=sys.stderr).returncode:
            print('splits: the Mac dev-host build failed (tools/vxrt_build.py toolchain)', file=sys.stderr)
            return 2
    rec = work / 'recorded.txt'
    rec.unlink(missing_ok=True)
    print('splits: round %d: running the game on the Mac for %d s' % (n, seconds), file=sys.stderr)
    log = work / 'record-run.log'
    env, tour_args, a_until = dict(os.environ, SKYRIM_AOT_DIR=str(out / 'modules')), [], max(10, seconds - 10)
    if tour:
        saves, (script, plan) = tour_saves(work), tour_script(seconds)
        if saves is None:
            print('splits: no "race" autosave in %s (a character in the world): --no-tour runs without the teleports' % (E.private_root() / 'saves' / 'race'), file=sys.stderr)
            return 2
        env['SKYRIM_SAVES_DIR'] = str(saves)
        tour_args, a_until = ['--key-script', script], TOUR_FIRST - 5            # (the pad's A would press into the console)
        (work / 'tour-plan.json').write_text(json.dumps(plan))
        print('splits: round %d: tour (seconds into the run): %s' % (n, ', '.join('%d %s' % p for p in plan)), file=sys.stderr)
    with open(log, 'wb') as lf:
        subprocess.run([str(REPO / 'tools' / 'play_skyrim_dev.sh'), '--no-build', '--mute', '--seconds', str(seconds)] + tour_args + ['--',
                        '--overlay-ini', 'Skyrim.ini:General:sIntroSequence=', '--xinput-repeat', 'A@6-%d/2:0.3' % a_until,
                        '--aot-splits', str(rec), '--dump-eyes', '--diag-env', 'VXRT_XRIZER_DEV_DUMP_EVERY=%d' % a.eye_every],
                       env=env, stdout=lf, stderr=subprocess.STDOUT)
    evidence(log, work, a, 'r%d' % n)
    if not rec.is_file():
        print('splits: the run wrote no profile (see %s)' % log, file=sys.stderr)
        return 1
    return merge(rec, f, int(cfg['exe']['base'], 16))


def png_small(rgba_path, w, h, out, width=320):
    """A small PNG (nearest-neighbour) of one raw RGBA eye image, as evidence that the run was in the game."""
    import struct, zlib
    d = Path(rgba_path).read_bytes()
    step = max(1, w // width)
    rows = []
    for y in range(0, h, step):
        row = bytearray(b'\0')
        for x in range(0, w, step):
            o = (y * w + x) * 4
            row += d[o:o + 3]
        rows.append(bytes(row))
    ww, hh = len(range(0, w, step)), len(rows)
    def chunk(t, b):
        c = struct.pack('>I', len(b)) + t + b
        return c + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
    Path(out).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', ww, hh, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


def evidence(log, work, a, tag):
    """The recording run is only useful if it got into the game: keep a few small PNGs of the sparse eye dumps (the cart ride at Helgen is the
    mark), with the seconds into the run, and delete the raw dumps (they hold the game's pictures; 8 MB each)."""
    m = re.search(r'output and evidence: (\S+)', Path(log).read_text(errors='replace'))
    if not m:
        return
    out = Path(m.group(1))
    eyes = out / 'eyes'
    files = sorted(eyes.glob('frame*_eye0_*.rgba'), key=lambda p: int(re.match(r'frame(\d+)_', p.name).group(1))) if eyes.is_dir() else []
    ev = work / ('evidence-' + tag)
    import shutil
    shutil.rmtree(ev, ignore_errors=True)
    ev.mkdir()
    first = min((p.stat().st_mtime for p in files), default=None)
    rows = []
    for p in files:
        fid, w, h = re.match(r'frame(\d+)_eye0_(\d+)x(\d+)\.rgba', p.name).groups()
        t = p.stat().st_mtime - first
        if int(fid) in (1, 2, 60) or int(fid) % a.eye_every:
            continue
        png = ev / ('frame%s-%ds.png' % (fid, t))
        png_small(p, int(w), int(h), png)
        rows.append({'frame': int(fid), 'seconds_after_first_frame': round(t), 'png': str(png)})
    if not a.keep_eyes:
        import shutil
        shutil.rmtree(eyes, ignore_errors=True)
    (ev / 'eyes.json').write_text(json.dumps({'run': str(out), 'dumps': rows}, indent=1))
    print('splits: eye evidence (small PNGs, raw dumps %s): %s' % ('kept' if a.keep_eyes else 'deleted', json.dumps(rows)), file=sys.stderr)


EXE_PREFERRED, EXE_WINDOW = 0x140000000, 0x3a00000


def merge(rec, f, run_base):
    """The runtime writes addresses where the exe was mapped in the run; the profile holds them at the exe's preferred base (the pipeline shifts them
    to wherever it places the image). Addresses outside the image are dropped. A re-run adds to the existing file."""
    t = tracked()
    have = set(f.read_text().split()) if f.is_file() else (set(t.decode().split()) if t else set())
    new = set()
    for x in rec.read_text().split():
        a = int(x, 16)
        if run_base <= a < run_base + EXE_WINDOW:
            new.add('%#x' % (a - run_base + EXE_PREFERRED))
    allv = sorted(have | new, key=lambda x: int(x, 16))
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(''.join(x + '\n' for x in allv))
    f.with_name(f.name + '.sha256').write_text(E.sha256_file(f) + '\n')
    print('splits: %d addresses (%d new) -> %s' % (len(allv), len(allv) - len(have), f), file=sys.stderr)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('record')
    r.add_argument('--seconds', type=int, default=600, help='length of the recording run (an unsplit exe runs slowly: 600 s gets well into the game)')
    r.add_argument('--force', action='store_true', help='record even if a profile is in place (adds to it)')
    r.add_argument('--eye-every', type=int, default=1500, help='keep a picture every N rendered frames as evidence that the run reached the game (then delete the raw dumps)')
    r.add_argument('--keep-eyes', action='store_true')
    r.add_argument('--tour', dest='tour', action='store_true', default=None, help='teleport with the developer console during the round (coc to %d places, from a copy of the "race" autosave); the default for a round that starts from a profile' % len(TOUR_CELLS))
    r.add_argument('--no-tour', dest='tour', action='store_false', help='do not teleport: the round only plays through the opening')
    r.add_argument('--rounds', type=int, help='recording rounds (default 2 without a profile, 1 when adding to one): each round after the first runs modules made with the profile so far')
    r.add_argument('--top-up-seconds', type=int, help='length of every round that starts from a profile (default: --seconds with the tour, 300 s without)')
    sub.add_parser('status')
    sub.add_parser('install')
    a = ap.parse_args()
    for k, val in E.load_local_env().items():
        os.environ.setdefault(k, val)
    if a.cmd == 'status':
        print(status())
        return 0
    if a.cmd == 'install':
        return 0 if install() else 2
    return record(a)


if __name__ == '__main__':
    sys.exit(main())
