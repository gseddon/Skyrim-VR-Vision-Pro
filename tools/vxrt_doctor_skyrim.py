#!/usr/bin/env python3
"""Check the prerequisites of the Skyrim VR on Vision Pro path, and say what to do about each that is missing.

    tools/vxrt_doctor_skyrim.py [--json] [--devices] [--build]

Reads local/env.sh like the other tools. Changes nothing (the --build option runs the default unsigned app build, a normal
make). Each check is ok, warn (not needed yet, or optional) or FAIL (a later stage cannot work); exit 1 if any FAIL.
--devices also asks `xcrun devicectl list devices` (a listing on this Mac; the headset is not contacted otherwise).
--build also runs `make -C VXRuntime xros-app XROS_CODE_SIGNING=NO`, the default app build that must keep linking.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vxrt_env as E

R = []     # (status, name, detail, fix)


def add(status, name, detail='', fix=''):
    R.append((status, name, detail, fix))


def out(*cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return r.returncode, (r.stdout + r.stderr).strip()
    except (OSError, subprocess.SubprocessError) as e:
        return 127, str(e)


def vtuple(s):
    return tuple(int(x) for x in re.findall(r'\d+', s)[:3])


def checks(a):
    v = E.variables()
    priv = E.private_root()
    # --- the Mac and Xcode
    arm = platform.machine() == 'arm64' and platform.system() == 'Darwin'
    add('ok' if arm else 'FAIL', 'Apple-silicon Mac', platform.platform(), 'the AOT compiler and runtime are arm64-only')
    mac = platform.mac_ver()[0]
    add('ok' if mac and vtuple(mac) >= (14,) else 'FAIL', 'macOS 14 or newer', mac, 'update macOS')
    rc, o = out('xcodebuild', '-version')
    add('ok' if rc == 0 and vtuple(o) >= (26,) else 'FAIL', 'Xcode 26 or newer', o.splitlines()[0] if o else 'not found',
        'install Xcode 26.x from the App Store / developer.apple.com, run it once, xcode-select -s /Applications/Xcode.app')
    for sdk in ('xros', 'xrsimulator'):
        rc, o = out('xcrun', '--sdk', sdk, '--show-sdk-version')
        add('ok' if rc == 0 else 'FAIL', 'visionOS SDK (%s)' % sdk, o if rc == 0 else 'missing',
            'Xcode > Settings > Components > visionOS (download the platform)')
    add('ok' if shutil.which('xcodegen') else 'FAIL', 'xcodegen', shutil.which('xcodegen') or 'not found', 'brew install xcodegen')
    add('ok' if sys.version_info >= (3, 9) else 'FAIL', 'python3 3.9+', platform.python_version(), 'brew install python')
    add('ok' if shutil.which('clang') else 'FAIL', 'clang (Xcode command line tools)', '', 'xcode-select --install')
    add('ok' if shutil.which('x86_64-w64-mingw32-gcc') else 'warn', 'MinGW (x86_64-w64-mingw32-gcc)',
        shutil.which('x86_64-w64-mingw32-gcc') or 'not found',
        'only for `make check` / the owned test programs, not for the Skyrim app: brew install mingw-w64')
    # --- Apple identity
    team = os.environ.get('XROS_TEAM_ID', '')
    add('ok' if re.fullmatch(r'[A-Z0-9]{10}', team) else 'FAIL', 'XROS_TEAM_ID', team or 'not set',
        'your paid Developer Program team (10 characters): developer.apple.com > Membership; put it in local/env.sh')
    if team:
        rc, o = out('security', 'find-identity', '-v', '-p', 'codesigning')
        add('ok' if '(%s)' % team in o or team in o else 'warn', 'a signing identity for the team in the keychain',
            'found' if team in o else 'none matching (Xcode creates one on the first signed build when you are signed in)',
            'Xcode > Settings > Accounts: add your Apple ID')
    prefix = os.environ.get('XROS_BUNDLE_PREFIX', '')
    add('ok' if prefix and prefix != 'dev.example.vxrt' else 'FAIL', 'XROS_BUNDLE_PREFIX', prefix or 'not set (placeholder dev.example.vxrt cannot be signed)',
        'a reverse-DNS prefix you own, e.g. com.yourname.vxrt; the app is <prefix>.SkyrimVR')
    dev = os.environ.get('VXRT_DEVICE_ID', '')
    add('ok' if dev else 'warn', 'VXRT_DEVICE_ID', dev or 'not set', 'xcrun devicectl list devices (Identifier column); needed to install and stage')
    if a.devices:
        rc, o = out('xcrun', 'devicectl', 'list', 'devices')
        line = next((l for l in o.splitlines() if dev and dev in l), '')
        add('ok' if line else 'warn', 'headset visible to devicectl', line.strip() or 'not listed', 'Developer Mode on, paired in Xcode, same network')
    # --- toolchains
    rust = subprocess.run([str(E.REPO / 'tools' / 'setup_rust.sh'), '--check'], capture_output=True, text=True,
                          env=dict(os.environ)).returncode == 0
    add('ok' if rust else 'FAIL', 'Rust 1.99.1 + Apple targets', v['XRIZER_RUST_ROOT'], 'tools/vxrt_build.py toolchain')
    steamless = priv / 'skyrim-tools' / 'steamless-bin' / 'Steamless.CLI.dll'
    prepared = Path(v['VXRT_PREPARED_EXE'])
    prepared_ok = prepared.is_file() and E.sha256_file(prepared) == E.PREPARED_EXE_SHA256
    add('ok' if steamless.is_file() else ('warn' if prepared_ok else 'FAIL'), 'Steamless (to unpack SkyrimVR.exe)',
        str(steamless) if steamless.is_file() else 'not built' + (' (not needed: the prepared exe is already there)' if prepared_ok else ''),
        'tools/vxrt_build.py toolchain --with-steamless')
    aot = E.REPO / 'VXRuntime' / 'build' / 'vxrt-aot'
    add('ok' if aot.is_file() else 'warn', 'AOT compiler built', str(aot), 'made by the aot stage (make -C VXRuntime build/vxrt-aot)')
    # --- the player's game
    root = os.environ.get('SKYRIM_ASSET_ROOT', '')
    exe = Path(root) / 'SkyrimVR.exe' if root else None
    if exe and exe.is_file():
        good = E.sha256_file(exe) == E.ORIGINAL_EXE_SHA256
        add('ok' if good else 'FAIL', 'SkyrimVR.exe is the pinned Steam build', str(exe) if good else 'another build: %s' % E.sha256_file(exe),
            'let Steam update/verify the game; the pipeline is pinned to one build')
        add('ok' if (Path(root) / 'Data' / 'Skyrim_VR - Main.bsa').is_file() else 'FAIL', 'Data/Skyrim_VR - Main.bsa', '', 'verify the game files in Steam')
    else:
        add('FAIL', 'SKYRIM_ASSET_ROOT (your SkyrimVR folder with SkyrimVR.exe)', root or 'not set',
            'download Skyrim VR (Steam app 611670, Windows build) with tools/vxrt_steam.py fetch, set SKYRIM_ASSET_ROOT in local/env.sh')
    vr = os.environ.get('STEAMVR_WIN64_DLLS', '')
    add('ok' if vr and (Path(vr) / 'msvcp140.dll').is_file() else ('warn' if prepared_ok and Path(v['VXRT_AOT_INPUTS'], 'msvcp140.dll').is_file() else 'FAIL'),
        'SteamVR bin/vrwebhelper/win64 (msvcp140.dll)', vr or 'not set', 'fetch SteamVR (app 250820) with tools/vxrt_steam.py and set STEAMVR_WIN64_DLLS')
    # --- private artifacts (the stages' outputs)
    add('ok' if prepared_ok else 'warn', 'prepared SkyrimVR.exe (pinned hash)', str(prepared), 'tools/vxrt_build.py prepare')
    inputs = all(Path(v['VXRT_AOT_INPUTS'], n).is_file() for n in ('binkw64.dll', 'openvr_api.dll', 'steam_api64.dll', 'msvcp140.dll')) \
        and all(Path(v['VXRT_REDIST_DIR'], n).is_file() for n in ('d3dx9_42.dll', 'X3DAudio1_7.dll'))
    add('ok' if inputs else 'warn', 'pipeline input DLLs', v['VXRT_AOT_INPUTS'], 'tools/vxrt_build.py prepare')
    fw = Path(os.environ.get('XROS_GAME_FW') or priv / 'game_fw-xros')
    add('ok' if fw.is_dir() else 'warn', 'compiled game modules (game_fw)', str(fw), 'tools/vxrt_build.py aot')
    shd = Path(os.environ.get('XROS_SHADER_DIR') or priv / 'shadercache-xros-manifest')
    add('ok' if (shd / '.complete').is_file() else 'warn', 'shader set', str(shd), 'tools/vxrt_build.py shaders')
    free = shutil.disk_usage(priv if priv.exists() else priv.parent if priv.parent.exists() else E.REPO).free / 2**30
    add('ok' if free >= 40 else 'warn', 'free disk for the private root (40 GB advised)', '%.0f GB' % free, 'AOT scratch, shader set and the staging tree need space')
    if a.build:
        rc = subprocess.run(['make', '-C', str(E.REPO / 'VXRuntime'), 'xros-app', 'XROS_CODE_SIGNING=NO'], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL).returncode
        add('ok' if rc == 0 else 'FAIL', 'default app build (make xros-app XROS_CODE_SIGNING=NO)', 'exit %d' % rc, 'rerun it without redirecting output')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--json', action='store_true'); ap.add_argument('--devices', action='store_true'); ap.add_argument('--build', action='store_true')
    a = ap.parse_args()
    for k, val in E.load_local_env().items():
        os.environ.setdefault(k, val)
    checks(a)
    if a.json:
        print(json.dumps([dict(status=s, check=n, detail=d, fix=f) for s, n, d, f in R], indent=1))
    else:
        for s, n, d, f in R:
            print('%-4s %-52s %s' % (s, n, d))
            if s != 'ok' and f:
                print('     -> ' + f)
    return 1 if any(s == 'FAIL' for s, *_ in R) else 0


if __name__ == '__main__':
    sys.exit(main())
