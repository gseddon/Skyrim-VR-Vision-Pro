#!/usr/bin/env python3
"""Put the player's Skyrim VR game tree into the Skyrim app's container on their own Vision Pro, with devicectl.

    tools/skyrim_device_stage.py                 dry run (default): what would be staged, sizes, what the headset already has
    tools/skyrim_device_stage.py --run           stage a hard-link tree under <private root>/device-stage, then copy what the
                                                 headset lacks (one devicectl call per directory, not per file)
    tools/skyrim_device_stage.py --run --verify  also list the container afterwards and compare sizes

Inputs (environment or arguments): VXRT_DEVICE_ID (--device), the app's bundle id (--bundle-id, default
$XROS_BUNDLE_PREFIX.SkyrimVR), SKYRIM_ASSET_ROOT (read only), VXRT_PRIVATE_ROOT. Needs the prepared exe and the DLL inputs
(tools/skyrim_prepare.py all) and the signed app installed (tools/vxrt_build.py app). Exits 2 on a missing input.

What goes where (VXRuntime/xros/app/Sources/main.m, skyrimvr_start): the game folder is
Documents/root/SkyrimVR in the app's container, holding Data/ (whole: the runtime opens every archive), the four .ini files,
the PREPARED SkyrimVR.exe (byte-identical to the one the AOT modules were made from) and the DLLs the exe loads. The
original SkyrimVR.exe and Steam's files (_CommonRedist, steamapps) are not copied. Case: the headset's file system is
case-sensitive; the runtime matches names case-insensitively (VISIONOS_PORT.md).

The game's files go to the user's own headset, nothing is committed or shared. About 14 GB; devicectl costs about 34 s of
overhead per call, hence one call per directory, and a resume that sends only missing or size-different files (hard links of
just those in a delta tree). Re-running after an interruption is safe: nothing on the headset is deleted.
The copy semantics of `devicectl device copy to` for a directory and the JSON of `device info files` were written from
its help text; check the dry run, and --verify, on the first real run. Subject: no device was touched writing this.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vxrt_env as E

DEST = 'Documents/root/SkyrimVR'
INI = ('Skyrim.ini', 'SkyrimPrefs.ini', 'High.ini', 'Medium.ini', 'Low.ini')
STAGED_DLLS = ('binkw64.dll', 'steam_api64.dll', 'msvcp140.dll', 'd3dx9_42.dll', 'X3DAudio1_7.dll')


class Missing(Exception):
    pass


def plan(asset_root, prepared, inputs, redist):
    """{relative path in the game folder: source path}. Raises Missing for anything required that is absent."""
    asset_root = Path(asset_root)
    files = {}
    data = asset_root / 'Data'
    if not data.is_dir():
        raise Missing('no Data/ in %s' % asset_root)
    for p in sorted(data.rglob('*')):
        if p.is_file() and not p.name.startswith('.'):
            files[str(p.relative_to(asset_root))] = p
    for n in INI:
        if (asset_root / n).is_file():
            files[n] = asset_root / n
    if 'Skyrim.ini' not in files:
        raise Missing('no Skyrim.ini in %s' % asset_root)
    if not Path(prepared).is_file():
        raise Missing('no prepared SkyrimVR.exe at %s (tools/skyrim_prepare.py unpack)' % prepared)
    files['SkyrimVR.exe'] = Path(prepared)
    for n in STAGED_DLLS:
        for d in (inputs, redist):
            if (Path(d) / n).is_file():
                files[n] = Path(d) / n
                break
        else:
            raise Missing('no %s in %s or %s (tools/skyrim_prepare.py inputs)' % (n, inputs, redist))
    return files


def on_device(listing):
    """{relative path: size} from the JSON of `devicectl device info files`; tolerant of the exact schema."""
    out = {}

    def walk(o):
        if isinstance(o, dict):
            name = o.get('relativePath') or o.get('path') or o.get('name')
            size = next((o[k] for k in ('size', 'fileSize', 'sizeInBytes') if isinstance(o.get(k), int)), None)
            if isinstance(name, str) and size is not None and not o.get('isDirectory') and not name.endswith('/'):
                out[name.split(DEST + '/', 1)[-1].lstrip('/')] = size
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(listing)
    return out


def missing_files(files, have):
    return {rel: src for rel, src in files.items() if have.get(rel) != src.stat().st_size}


def link_tree(root, files):
    shutil.rmtree(root, ignore_errors=True)
    for rel, src in files.items():
        dst = root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(src, dst)
        except OSError:
            shutil.copyfile(src, dst)       # another volume: a real copy (disk), the staging tree is still immutable


def devicectl(args, **kw):
    return subprocess.run(['xcrun', 'devicectl', *args], **kw)


def listing(device, bundle, out):
    r = devicectl(['--timeout', '120', 'device', 'info', 'files', '--device', device, '--domain-type', 'appDataContainer',
                   '--domain-identifier', bundle, '--subdirectory', DEST, '--json-output', str(out)],
                  capture_output=True)
    if r.returncode or not Path(out).is_file():
        return None
    try:
        return json.loads(Path(out).read_text())
    except ValueError:
        return None


def mb(n):
    return '%.1f MB' % (n / 2**20)


def main():
    for k, v in E.load_local_env().items():
        os.environ.setdefault(k, v)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--device', default=os.environ.get('VXRT_DEVICE_ID'), help='CoreDevice id (xcrun devicectl list devices); default $VXRT_DEVICE_ID')
    ap.add_argument('--bundle-id', default=None, help='default $XROS_BUNDLE_PREFIX.SkyrimVR')
    ap.add_argument('--asset-root', default=os.environ.get('SKYRIM_ASSET_ROOT'))
    ap.add_argument('--run', action='store_true', help='copy; without it only report')
    ap.add_argument('--verify', action='store_true')
    ap.add_argument('--stage-dir', default=None, help='default <private root>/device-stage')
    a = ap.parse_args()
    v = E.variables()
    bundle = a.bundle_id or (os.environ['XROS_BUNDLE_PREFIX'] + '.SkyrimVR' if os.environ.get('XROS_BUNDLE_PREFIX') else None)
    for what, val, hint in (('SKYRIM_ASSET_ROOT / --asset-root', a.asset_root, 'your SkyrimVR folder'),
                            ('VXRT_DEVICE_ID / --device', a.device, 'xcrun devicectl list devices, Identifier column'),
                            ('XROS_BUNDLE_PREFIX / --bundle-id', bundle, 'the prefix the app was built with')):
        if not val:
            print('skyrim_device_stage: %s is not set (%s)' % (what, hint), file=sys.stderr)
            return 2
    try:
        files = plan(a.asset_root, v['VXRT_PREPARED_EXE'], v['VXRT_AOT_INPUTS'], v['VXRT_REDIST_DIR'])
    except Missing as e:
        print('skyrim_device_stage: ' + str(e), file=sys.stderr)
        return 2
    total = sum(p.stat().st_size for p in files.values())
    print('plan: %d files, %s -> %s (bundle %s, device %s)' % (len(files), mb(total), DEST, bundle, a.device))
    stage = Path(a.stage_dir) if a.stage_dir else E.private_root() / 'device-stage'
    have = {}
    lst = listing(a.device, bundle, stage.parent / 'device-listing.json') if a.run or a.verify else None
    if lst is not None:
        have = on_device(lst)
        print('headset has %d files under %s' % (len(have), DEST))
    elif a.run:
        print('note: could not list the headset container (app installed? headset awake?); sending everything')
    todo = missing_files(files, have)
    print('to send: %d files, %s' % (len(todo), mb(sum(p.stat().st_size for p in todo.values()))))
    if not a.run:
        print('dry run: nothing written, nothing sent (add --run)')
        return 0
    if not todo:
        print('nothing to send')
    else:
        delta = stage / 'delta'
        stage.mkdir(parents=True, exist_ok=True)
        link_tree(delta, todo)
        tops = sorted({rel.split('/')[0] for rel in todo})
        for top in tops:    # one call per top-level entry: Data/ (or its missing part), each loose file group
            r = devicectl(['device', 'copy', 'to', '--device', a.device, '--domain-type', 'appDataContainer',
                           '--domain-identifier', bundle, '--source', str(delta / top), '--destination', DEST + '/' + top])
            if r.returncode:
                print('skyrim_device_stage: devicectl copy of %s failed (%d); re-run to resume' % (top, r.returncode), file=sys.stderr)
                return 1
        shutil.rmtree(delta, ignore_errors=True)
    if a.verify:
        lst = listing(a.device, bundle, stage.parent / 'device-listing.json')
        bad = missing_files(files, on_device(lst)) if lst is not None else files
        if bad:
            print('verify: %d files missing or of another size, first: %s' % (len(bad), sorted(bad)[:5]), file=sys.stderr)
            return 1
        print('verify: all %d files present with the sizes of the Mac copies' % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main())
