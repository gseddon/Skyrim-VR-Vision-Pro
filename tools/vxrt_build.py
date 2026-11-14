#!/usr/bin/env python3
"""One entry point for the Skyrim VR build stages: tools/vxrt_build.py <stage> [options].

    list [--json]     the stages with their inputs, outputs and current state (tools/vxrt_stages.json is the contract)
    doctor            check the prerequisites (tools/vxrt_doctor_skyrim.py)
    toolchain         Rust + Apple targets + locked crates (--with-steamless: also Steamless and a private .NET 8 SDK, without asking; --confirm asks)
    prepare           unpack the player's SkyrimVR.exe with Steamless, collect the pipeline's input DLLs
    aot               compile the prepared exe and DLLs for the headset  -> $VXRT_PRIVATE_ROOT/game_fw-xros
    shaders           Metal shader set from the committed manifest        -> $VXRT_PRIVATE_ROOT/shadercache-xros-manifest
    app               build and sign the app  (--unsigned: no signing; --install: devicectl install, needs VXRT_DEVICE_ID)
    stage-to-device   copy the game tree to the headset (dry run unless --run)
    mods-fetch        fetch the Nexus Mods files of a mods list, pin their md5, unpack  (--list L, default mods/default.json; the key is optional: without it, from ~/Downloads)
    mods              build a mod pack  (--list L, default mods/default.json [--out DIR] [--deploy])

Rules every stage follows: inputs come from the environment or arguments (local/env.sh, copied from local.example.sh, is read
first; the real environment wins); outputs go under VXRT_PRIVATE_ROOT (default build/private) except the toolchain and the
built app; exit 0 when the stage's outputs exist and were checked, 2 when an input is missing (the message names it and the
stage that makes it), 1 when the stage ran and failed. A finished stage is not redone (idempotent) unless --force.
--json prints one result object (stage, status, outputs, exit code) on stdout; progress goes to stderr then.
Nothing here downloads except `toolchain` and `mods-fetch`, and nothing touches the headset except `app --install`, `stage-to-device --run`
and `mods --deploy`.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vxrt_env as E

REPO = E.REPO
MANIFEST = REPO / 'tools' / 'vxrt_stages.json'
OK, FAIL, MISSING = 0, 1, 2


class NeedInput(Exception):
    pass


def say(msg):
    print(msg, file=sys.stderr, flush=True)


def need_env(*names):
    for n in names:
        if not os.environ.get(n):
            raise NeedInput('%s is not set (put it in local/env.sh; see local.example.sh and docs/SETUP_SKYRIM.md)' % n)


def need_path(path, stage, what=None):
    if not Path(path).exists():
        raise NeedInput('%s is missing: %s%s' % (what or 'an input', path, ' (made by: tools/vxrt_build.py %s)' % stage if stage else ''))


def v():
    return E.variables()


def priv():
    return E.private_root()


def run(cmd, **kw):
    say('+ ' + ' '.join(str(c) for c in cmd))
    kw.setdefault('stdout', sys.stderr)
    return subprocess.run([str(c) for c in cmd], **kw).returncode


def rustc_ok():
    return subprocess.run([str(REPO / 'tools' / 'setup_rust.sh'), '--check'], capture_output=True).returncode == 0


def prepared_ok():
    exe = Path(v()['VXRT_PREPARED_EXE'])
    return exe.is_file() and E.sha256_file(exe) == E.PREPARED_EXE_SHA256


# --- stages: each returns (exit code, [outputs]) ----------------------------------------------------------------------

def stage_toolchain(a):
    steam = priv() / 'skyrim-tools' / 'steamless-bin' / 'Steamless.CLI.dll'
    rc = OK
    if a.force or not rustc_ok():
        rc = run([REPO / 'tools' / 'setup_rust.sh'])
    else:
        say('toolchain: Rust already installed (setup_rust.sh --check)')
    if rc == OK and a.with_steamless and (a.force or not steam.is_file()):
        rc = run([sys.executable, REPO / 'tools' / 'skyrim_prepare.py', 'fetch-tools'] + (['--confirm'] if a.confirm and not a.yes else []),
                 stdin=None)
    return rc, [str(REPO / 'build/toolchains/xrizer-rust'), str(steam)]


def stage_prepare(a):
    need_env('SKYRIM_ASSET_ROOT', 'STEAMVR_WIN64_DLLS')
    if not prepared_ok():
        need_path(priv() / 'skyrim-tools' / 'steamless-bin' / 'Steamless.CLI.dll', 'toolchain --with-steamless', 'Steamless')
    elif not a.force:
        say('prepare: the prepared exe is already in place with the pinned hash')
    return run([sys.executable, REPO / 'tools' / 'skyrim_prepare.py', 'all']), [v()['VXRT_PREPARED_EXE'], v()['VXRT_AOT_INPUTS'], v()['VXRT_REDIST_DIR']]


def ensure_splits(a):
    """New builds always carry the module-splits profile: record it (tools/skyrim_splits.py, a Mac game run) when it is missing or does not match its hash."""
    import skyrim_splits
    st = skyrim_splits.status()
    if st == 'ok' or skyrim_splits.install():
        return
    say('aot: the module-splits profile is %s (%s). It is a list of places in the game where it does a kind of memory access Apple chips cannot do in one go; the recompiler must know them in advance, and learns them by watching the game run on this Mac for about 10 minutes. Recording it now.' % (st, skyrim_splits.splits_path()))
    rc = run([sys.executable, REPO / 'tools' / 'skyrim_splits.py', 'record'] + (['--force'] if st == 'mismatch' else []))
    if rc == MISSING:
        raise NeedInput('the module-splits profile could not be recorded (see above); it is made by: python3 tools/skyrim_splits.py record')
    if rc or skyrim_splits.status() != 'ok':
        raise NeedInput('the module-splits profile is missing and recording it failed; run python3 tools/skyrim_splits.py record and read its output')


def aot_identity():
    """What the aot output depends on besides the exe: the splits profile and the compiler (both by sha256)."""
    import skyrim_splits
    comp = REPO / 'VXRuntime' / 'build' / 'vxrt-aot'
    sp = skyrim_splits.splits_path()
    return {'splits_sha256': E.sha256_file(sp) if sp.is_file() else None, 'compiler_sha256': E.sha256_file(comp) if comp.is_file() else None,
            'msvcp140_sha256': E.msvcp140_identity()}


def aot_stamp_path():
    return priv() / 'game_fw-xros.stamp.json'


def aot_stamp_current(ident):
    try:
        st = json.loads(aot_stamp_path().read_text())
        if 'msvcp140_sha256' in ident and 'msvcp140_sha256' not in st:
            st['msvcp140_sha256'] = E.MSVCP140_KNOWN_SHA256      # (a stamp from before this key: made with the known one)
        return st == ident
    except (OSError, ValueError):
        return False        # missing (an output from before stamps) or unreadable: not known to match


def stage_aot(a):
    need_env('SKYRIM_ASSET_ROOT')
    need_path(v()['VXRT_PREPARED_EXE'], 'prepare', 'the prepared SkyrimVR.exe')
    link = priv() / 'game_fw-xros'
    rc = E.ensure_mac_runtime(run)                    # (the compiler; incremental, so cheap when current)
    if rc:
        return rc, []
    ensure_splits(a)
    ident = aot_identity()
    if link.exists() and not a.force:
        if aot_stamp_current(ident):
            say('aot: %s already exists and was built with this splits profile, compiler and msvcp140.dll (--force to compile again)' % link)
            return OK, [str(link)]
        say('aot: %s was built with a different (or unrecorded) splits profile, compiler or msvcp140.dll; rebuilding. The old output is kept until the new one succeeds.' % link)
    moved = None
    if link.exists() and not link.is_symlink():
        moved = link.with_name('game_fw-xros.pre-' + time.strftime('%Y%m%d-%H%M%S'))
        link.rename(moved)                           # (a real directory: set aside, put back if the build fails)
    out = priv() / 'skyrimvr' / E.ORIGINAL_EXE_SHA256 / ('aot-xros-' + time.strftime('%Y%m%d-%H%M%S'))
    rc = run([sys.executable, REPO / 'tools' / 'skyrim_aot_pipeline.py', '--config', REPO / 'tools' / 'skyrim_aot_skyrimvr.json',
              '--target', 'xros', '--build', '--out', out])
    if rc or not (out / 'game_fw').is_dir():
        if moved is not None and not link.exists():
            moved.rename(link)
        return rc or FAIL, []
    tmp = link.with_name(link.name + '.new')         # (the old output, or its symlink target, stays; the symlink is replaced atomically)
    tmp.unlink(missing_ok=True)
    tmp.symlink_to(out / 'game_fw')
    os.replace(tmp, link)
    aot_stamp_path().write_text(json.dumps(ident, indent=1) + '\n')
    return OK, [str(link)]


def stage_shaders(a):
    need_env('SKYRIM_ASSET_ROOT')
    if not (Path(os.environ['SKYRIM_ASSET_ROOT']) / 'Data').is_dir():
        raise NeedInput('no Data/ in SKYRIM_ASSET_ROOT=%s' % os.environ['SKYRIM_ASSET_ROOT'])
    d = priv() / 'shadercache-xros-manifest'
    if a.force:
        (d / '.complete').unlink(missing_ok=True)
    rc = run(['make', '-C', REPO / 'VXRuntime', 'xros-shader-set', 'XROS_SDK=xros'])
    return rc, [str(d / '.complete')]


APP = REPO / 'VXRuntime/build/xros-xrizer-fixture/derived/Build/Products/Debug-xros/VXRuntimeHost.app'


def skse_modules(plain):
    """The module set the app embeds: the plain one, or (when the mod pack has SKSE plugins) the one made by skse-capture for exactly that plugin set."""
    import skse_capture
    pack = priv() / 'mods-pack'
    st = skse_capture.status(pack)
    if st == 'n/a':
        return plain
    if st != 'done':
        raise NeedInput('the mod pack %s has SKSE plugins but the SKSE capture is %s: the app would stop at start-up (made by: tools/vxrt_build.py skse-capture)' % (pack, st))
    say('app: embedding the SKSE module set %s' % (priv() / 'game_fw-xros-skse'))
    return priv() / 'game_fw-xros-skse'


def stage_app(a):
    link = priv() / 'game_fw-xros'
    need_path(link, 'aot', 'the compiled game modules')
    link = skse_modules(link)
    need_path(priv() / 'shadercache-xros-manifest' / '.complete', 'shaders', 'the shader set')
    if not rustc_ok():
        raise NeedInput('no Rust toolchain at %s (made by: tools/vxrt_build.py toolchain)' % os.environ.get('XRIZER_RUST_ROOT', REPO / 'build/toolchains/xrizer-rust'))
    args = ['make', '-C', REPO / 'VXRuntime', 'XROS_XRIZER_GAME=1', 'XROS_SDK=xros', 'XROS_GAME_FW=' + str(link),
            'XROS_SHADER_SET=' + str(priv() / 'shadercache-xros-manifest')]
    if a.unsigned:
        args.append('XROS_CODE_SIGNING=NO')
    else:
        need_env('XROS_TEAM_ID', 'XROS_BUNDLE_PREFIX')
    if a.install:
        need_env('VXRT_DEVICE_ID')
    if os.environ.get('XROS_ALLOW_PROVISIONING'):
        args.append('XROS_ALLOW_PROVISIONING=' + os.environ['XROS_ALLOW_PROVISIONING'])
    rc = run(args + ['xros-app'])
    if rc == OK and not APP.is_dir():
        rc = FAIL
    if rc == OK and a.install:
        if a.unsigned:
            raise NeedInput('--install needs a signed app (drop --unsigned)')
        rc = run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', os.environ['VXRT_DEVICE_ID'], APP])
    return rc, [str(APP)]


def stage_stage(a):
    need_env('VXRT_DEVICE_ID', 'XROS_BUNDLE_PREFIX', 'SKYRIM_ASSET_ROOT')
    need_path(v()['VXRT_PREPARED_EXE'], 'prepare', 'the prepared SkyrimVR.exe')
    return run([sys.executable, REPO / 'tools' / 'skyrim_device_stage.py'] + (['--run', '--verify'] if a.run else [])), ['(headset) Documents/root/SkyrimVR']


def stage_mods_fetch(a):
    if a.list:
        need_path(a.list, None, 'the mods list')       # (no --list: tools/mods.py picks your own list, else mods/default.json)
    out = priv() / 'downloads' / 'nexus'
    # mods.py fetch asks for the key only when a mod still has to be downloaded, so a finished list needs no key and does nothing.
    rc = run([sys.executable, '-I', REPO / 'tools' / 'mods.py', 'fetch'] + (['--list', a.list] if a.list else []) + [x for u in (a.nxm or []) for x in ('--nxm', u)] + (['--force'] if a.force else []) + (['--wait', str(a.wait)] if a.wait is not None else []) + (['--manual'] if a.manual else []) + (['--accept-name-match'] if a.accept_name_match else []))
    if rc == MISSING:
        raise NeedInput('a Nexus file is not available yet (no matching archive in the Downloads folder, or no link; skipped or timed out); see the message above and docs/SETUP_SKYRIM.md')
    return rc, [str(out)]


def stage_mods(a):
    if a.list:
        need_path(a.list, None, 'the mods list')       # (no --list: tools/mods.py picks your own list, else mods/default.json)
    out = Path(a.out) if a.out else priv() / 'mods-pack'
    if out.exists() and not a.force:
        say('mods: %s already exists (--force to rebuild)' % out)
        rc = OK
    else:
        rc = run([sys.executable, '-I', REPO / 'tools' / 'mods.py', 'build', '--out', out] + (['--list', a.list] if a.list else []) + (['--force'] if a.force else []))
    if rc == OK and a.deploy:
        need_env('VXRT_DEVICE_ID', 'XROS_BUNDLE_PREFIX')
        rc = run([sys.executable, '-I', REPO / 'tools' / 'mods.py', 'deploy', out, '--bundle', os.environ['XROS_BUNDLE_PREFIX'] + '.SkyrimVR',
                  '--device', os.environ['VXRT_DEVICE_ID'], '--yes'])
    if rc == MISSING:
        raise NeedInput('a Nexus mod in the list is not fetched yet (made by: tools/vxrt_build.py mods-fetch)')
    return rc, [str(out)]


def stage_skse_capture(a):
    pack = Path(a.out) if a.out else priv() / 'mods-pack'
    need_path(pack / 'mods.json', 'mods', 'the mod pack')
    import skyrim_splits
    if skyrim_splits.status() != 'ok':
        raise NeedInput('the module-splits profile is %s: %s. It lists the places where the game does a memory access Apple chips cannot do in one go; the recompiler needs it in advance (made by: tools/vxrt_build.py aot, which records it by running the game on your Mac for about 10 minutes)' % (skyrim_splits.status(), skyrim_splits.splits_path()))
    import skse_capture
    st = skse_capture.status(pack)
    if st == 'n/a':
        need_path(pack / 'overlay_root' / skse_capture.CORE_NAME, 'mods-fetch (the skse-core entry), then mods --force', 'the SKSE VR core DLL in the pack')
        raise NeedInput('the pack has no SKSE plugin DLLs: nothing to capture')
    ns = argparse.Namespace(pack=str(pack), force=a.force, late_seconds=a.late_seconds, verify_seconds=a.verify_seconds, wait=a.wait_session)
    try:
        skse_capture.stage(ns)
    except skse_capture.NeedInput as e:
        raise NeedInput(str(e))
    except skse_capture.Failed as e:
        say('skse-capture: FAILED: %s' % e)
        return FAIL, []
    return OK, [str(priv() / 'skse-capture' / 'state.json'), str(priv() / 'game_fw-xros-skse')]


STAGES = {'toolchain': stage_toolchain, 'prepare': stage_prepare, 'aot': stage_aot, 'shaders': stage_shaders, 'app': stage_app,
          'stage-to-device': stage_stage, 'mods-fetch': stage_mods_fetch, 'mods': stage_mods, 'skse-capture': stage_skse_capture}


def stage_state(s):
    """done / missing, from the manifest's output paths (not for the headset)."""
    if s['name'] == 'skse-capture':
        import skse_capture
        st = skse_capture.status(E.private_root() / 'mods-pack')
        return {'done': 'done', 'stale': 'stale', 'n/a': 'unknown'}.get(st, 'missing')
    outs = [E.expand(o) for o in s['outputs'] if not o.startswith('(')]
    if not outs:
        return 'unknown'
    return 'done' if all(Path(o).exists() for o in outs) else 'missing'


def cmd_list(a):
    spec = json.loads(MANIFEST.read_text())
    for s in spec['stages']:
        s['state'] = stage_state(s)
    if a.json:
        print(json.dumps(spec, indent=2))
    else:
        for s in spec['stages']:
            print('%-16s %-8s %s' % (s['name'], s['state'], s['summary']))
    return OK


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('stage', choices=['list', 'doctor', *STAGES])
    ap.add_argument('--force', action='store_true', help='redo the stage even if its outputs exist')
    ap.add_argument('--json', action='store_true', help='print one result object on stdout')
    ap.add_argument('--with-steamless', action='store_true', help='toolchain: also fetch and build Steamless and a .NET 8 SDK')
    ap.add_argument('--confirm', action='store_true', help='toolchain: ask before downloading Steamless (default: list it and go ahead)')
    ap.add_argument('--yes', action='store_true', help=argparse.SUPPRESS)    # accepted for old callers; now the default
    ap.add_argument('--unsigned', action='store_true', help='app: XROS_CODE_SIGNING=NO')
    ap.add_argument('--install', action='store_true', help='app: install on the headset after the build')
    ap.add_argument('--run', action='store_true', help='stage-to-device: really copy (default: dry run)')
    ap.add_argument('--list', help='mods: the mods list')
    ap.add_argument('--out', help='mods, skse-capture: the pack directory')
    ap.add_argument('--manual', action='store_true', help='mods-fetch: use the browser and the Downloads folder even if NEXUS_API_KEY is set')
    ap.add_argument('--accept-name-match', action='store_true', help='mods-fetch: without a terminal, accept an archive whose name carries the mod id')
    ap.add_argument('--wait', type=int, help='mods-fetch: seconds to wait per file for its nxm link (non-premium)')
    ap.add_argument('--nxm', action='append', help='mods-fetch: nxm:// link from the Nexus website for a file (without Premium); repeatable')
    ap.add_argument('--late-seconds', type=int, default=100, help='skse-capture: seconds into the game when the late capture is taken')
    ap.add_argument('--verify-seconds', type=int, default=200, help='skse-capture: length of the strict verify run')
    ap.add_argument('--wait-session', type=int, default=3600, help='skse-capture: seconds to wait for another Skyrim run to end before giving up')
    ap.add_argument('--deploy', action='store_true', help='mods: copy the pack to the headset')
    a = ap.parse_args()
    try:
        for k, val in E.load_local_env().items():
            os.environ.setdefault(k, val)
    except ValueError as e:
        print('vxrt_build: ' + str(e), file=sys.stderr)
        return FAIL
    os.environ.setdefault('VXRT_PRIVATE_ROOT', str(E.private_root()))
    if a.stage == 'list':
        return cmd_list(a)
    if a.stage == 'doctor':
        return subprocess.run([sys.executable, str(REPO / 'tools' / 'vxrt_doctor_skyrim.py')] + (['--json'] if a.json else [])).returncode
    result = {'stage': a.stage, 'status': 'failed', 'outputs': [], 'exit': FAIL}
    try:
        rc, outs = STAGES[a.stage](a)
        result.update(status='ok' if rc == OK else 'failed', outputs=outs, exit=rc)
    except NeedInput as e:
        print('vxrt_build %s: %s' % (a.stage, e), file=sys.stderr)
        result.update(status='missing-input', error=str(e), exit=MISSING)
    except E.Unset as e:
        print('vxrt_build %s: %s' % (a.stage, e), file=sys.stderr)
        result.update(status='missing-input', error=str(e), exit=MISSING)
    if a.json:
        print(json.dumps(result))
    return result['exit']


if __name__ == '__main__':
    sys.exit(main())
