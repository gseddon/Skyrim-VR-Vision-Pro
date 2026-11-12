#!/usr/bin/env python3 -I
"""tools/vxrt_build.py gaps: (1) aot rebuilds when the splits profile or compiler changed or no stamp exists, skips when it matches;
(2) the build's download cache is searched by md5 before asking for a download; (3) the Mac runtime make step runs first (mocked)."""
import hashlib, os, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
with tempfile.TemporaryDirectory() as t:
    t = Path(t).resolve(); priv = t / 'private'; priv.mkdir()
    os.environ['VXRT_PRIVATE_ROOT'] = str(priv)
    for k in ('VXRT_SKYRIM_DIR', 'VXRT_AOT_INPUTS', 'VXRT_SPLITS_FILE', 'VXRT_SPLITS_SHA256'): os.environ.pop(k, None)
    os.environ['SKYRIM_ASSET_ROOT'] = str(t)
    import vxrt_env as E, vxrt_build as B, skyrim_splits as S, nexus, argparse

    # --- (2) download cache by md5
    data = b'archive bytes'; md5 = hashlib.md5(data).hexdigest()
    (priv / 'skse').mkdir()
    assert nexus.cache_lookup(md5) is None
    (priv / 'skse' / 'wrong.7z').write_bytes(b'something else')
    assert nexus.cache_lookup(md5) is None, 'a wrong md5 in the cache is ignored'
    (priv / 'skse' / 'sksevr.7z').write_bytes(data)
    assert nexus.cache_lookup(md5) == priv / 'skse' / 'sksevr.7z'
    (priv / 'downloads').mkdir(); (priv / 'downloads' / 'renamed (1).7z').write_bytes(data)
    assert nexus.cache_lookup(md5) == priv / 'downloads' / 'renamed (1).7z'
    for f in list(priv.glob('*/*.7z')): os.utime(f, (1, 1))      # (finished long ago)
    nexus.browser_downloads_dir = lambda: t / 'nohome'
    assert nexus.external_fetch('SKSE', 'http://x', 'sksevr.7z', md5, wait=0) == priv / 'downloads' / 'renamed (1).7z'
    r = nexus.manual_fetch('skyrimspecialedition', '1', None, md5=md5, wait=0)
    assert r['md5'] == md5 and r['verified_by'] == 'pinned md5'
    try: nexus.external_fetch('SKSE', 'http://x', 'a.7z', hashlib.md5(b'nope').hexdigest(), wait=0); raise SystemExit('wrong md5 accepted')
    except nexus.Skipped: pass

    # --- (3) the make step
    calls = []
    assert E.ensure_mac_runtime(lambda c: calls.append(c) or 0) == 0
    assert calls[0][0] == 'make' and calls[0][-2:] == ['build/vxrt-arm64', 'build/vxrt-aot'], calls
    assert E.ensure_mac_runtime(lambda c: 7) == 7

    # --- (1) aot stamp
    comp = ROOT / 'VXRuntime' / 'build' / 'vxrt-aot'
    exe = t / 'prepared.exe'; exe.write_bytes(b'x'); os.environ['VXRT_PREPARED_EXE'] = str(exe)
    sp = S.splits_path(); sp.parent.mkdir(parents=True, exist_ok=True); sp.write_text('0x140000000\n')
    B.E.ensure_mac_runtime = lambda run=None: calls.append('make') or 0
    B.ensure_splits = lambda a: None
    B.aot_identity = lambda: {'splits_sha256': E.sha256_file(sp), 'compiler_sha256': 'c1'}
    runs = []; tick = iter(range(1000))
    B.time = type('T', (), {'strftime': staticmethod(lambda f: 't%03d' % next(tick))})      # (distinct names; the real ones are a second apart at least)
    def fake_run(cmd, **kw):
        runs.append(cmd)
        out = Path(str(cmd[cmd.index('--out') + 1])); (out / 'game_fw').mkdir(parents=True)
        return 0
    B.run = fake_run
    args = argparse.Namespace(force=False)
    old = priv / 'old_game_fw'; old.mkdir(); (priv / 'game_fw-xros').symlink_to(old)
    calls.clear()
    assert B.stage_aot(args)[0] == 0 and len(runs) == 1 and 'make' in calls, 'no stamp (old output): rebuild'
    link = priv / 'game_fw-xros'
    assert link.is_symlink() and link.resolve() != old.resolve() and old.is_dir(), 'replaced atomically, old output kept'
    assert B.aot_stamp_current(B.aot_identity())
    assert B.stage_aot(args)[0] == 0 and len(runs) == 1, 'stamp matches: skip'
    sp.write_text('0x140000000\n0x140000010\n')
    B.aot_identity = lambda: {'splits_sha256': E.sha256_file(sp), 'compiler_sha256': 'c1'}
    assert B.stage_aot(args)[0] == 0 and len(runs) == 2, 'splits changed: rebuild'
    B.aot_identity = lambda: {'splits_sha256': E.sha256_file(sp), 'compiler_sha256': 'c2'}
    assert B.stage_aot(args)[0] == 0 and len(runs) == 3, 'compiler changed: rebuild'
    # a failed rebuild keeps the working output
    B.aot_identity = lambda: {'splits_sha256': 'new', 'compiler_sha256': 'c2'}
    B.run = lambda cmd, **kw: 1
    before = link.resolve()
    assert B.stage_aot(args)[0] == 1 and link.resolve() == before and not B.aot_stamp_current(B.aot_identity())
    # a real directory is set aside, and put back when the build fails
    link.unlink(); link.mkdir(); (link / 'f').write_text('keep')
    assert B.stage_aot(args)[0] == 1 and (link / 'f').read_text() == 'keep'
    B.run = fake_run
    assert B.stage_aot(args)[0] == 0 and link.is_symlink() and list(priv.glob('game_fw-xros.pre-*'))[0].joinpath('f').read_text() == 'keep'
print('vxrt_build_gaps_test ok')
