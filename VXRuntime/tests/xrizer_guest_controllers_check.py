#!/usr/bin/env python3
"""Owned guest fixture: IVRSystem_019 controller slots through the Windows guest ABI bridge and real xrizer, with the
offscreen development host's synthetic stationary controllers (VXRT_XRIZER_DEV_CONTROLLERS). Builds the MSVC-ABI
guest (clang++ --target=x86_64-pc-windows-msvc, mingw ld), its AOT module (vxrt-aot), runs it under strict AOT and
checks the guest verdict and the bridge's log. Fixture only: not a game, headset or physical-input claim."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(cmd, log, **kw):
    log.write(('$ ' + ' '.join(map(str, cmd)) + '\n').encode()); log.flush()
    r = subprocess.run(list(map(str, cmd)), stdout=log, stderr=subprocess.STDOUT, **kw)
    if r.returncode: raise SystemExit(f'{cmd[0]} failed with {r.returncode}')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('runtime', 'xrizer-dylib', 'out'):
        ap.add_argument('--' + name, required=True, type=Path)
    ap.add_argument('--aot-tool', type=Path, default=REPO / 'VXRuntime/build/vxrt-aot')
    ap.add_argument('--kernel32', type=Path, default=Path('/opt/homebrew/opt/mingw-w64/toolchain-x86_64/x86_64-w64-mingw32/lib/libkernel32.a'))
    a = ap.parse_args()
    runtime, library, tool = (p.resolve(strict=True) for p in (a.runtime, a.xrizer_dylib, a.aot_tool))
    out = a.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    headers = REPO / 'third_party/xrizer/upstream/openvr/headers'
    source = HERE / 'xrizer_guest_controllers.cpp'
    header, obj, exe, asm, armobj, aot = (out / n for n in ('openvr-guest-abi.h', 'guest.obj', 'xrizer_guest_controllers.exe', 'guest.s', 'guest-aot.o', 'guest-aot'))
    aot.mkdir()
    with (out / 'build.log').open('wb') as log:
        run(['python3', HERE / 'xrizer_guest_abi_header.py', headers / 'openvr-1.3.22.h', header], log)
        run(['clang++', '--target=x86_64-pc-windows-msvc', '-std=c++17', '-O1', '-fno-exceptions', '-fno-rtti', '-fno-stack-protector',
             '-I', out, '-I', headers, '-c', source, '-o', obj], log)
        run(['x86_64-w64-mingw32-ld', '-e', 'mainCRTStartup', '--subsystem', 'console', '-o', exe, obj, a.kernel32], log)
        name = subprocess.check_output([str(tool), 'name', str(exe)], text=True).strip()
        run([tool, 'gen', exe, asm], log)
        run(['clang', '-arch', 'arm64', '-c', '-o', armobj, asm], log)
        run(['clang', '-arch', 'arm64', '-dynamiclib', '-o', aot / name, armobj], log)
    paths = [runtime, library, tool, source, exe, aot / name]
    identity = {str(p): digest(p) for p in paths}
    (out / 'identities.json').write_text(json.dumps(identity, indent=2) + '\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_', 'XDG_'))}
    env.update(VXRT_ROOT=str(out / 'root'), VXRT_AOT_DIR=str(aot), VXRT_AOT_STRICT='1', VXRT_NO_WINE='1',
               VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1', VXRT_XRIZER_OPENVR='1',
               VXRT_XRIZER_DYLIB=str(library), VXRT_XRIZER_DEV_CONTROLLERS='touch', VXRT_XRIZER_DEV_STAGE='1')
    for kind in ('STATE', 'CONFIG', 'CACHE', 'DATA'):
        path = out / 'xdg' / kind.lower(); path.mkdir(parents=True, mode=0o700); env['XDG_' + kind + '_HOME'] = str(path)
    command = ['/usr/bin/arch', '-arm64', str(runtime), str(exe)]
    timed_out = False
    with (out / 'runtime.log').open('wb') as log:
        child = subprocess.Popen(command, cwd=exe.parent, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try: rc = child.wait(timeout=60)
        except subprocess.TimeoutExpired:
            timed_out = True; os.killpg(child.pid, signal.SIGKILL); rc = child.wait()
    log = (out / 'runtime.log').read_text(errors='replace')
    summaries = re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator \((\d+) addresses\)', log)
    xrizer_log = out / 'xdg/state/xrizer/xrizer.txt'
    xlog = xrizer_log.read_text(errors='replace') if xrizer_log.is_file() else ''
    checks = {
        'exit_zero': rc == 0 and not timed_out,
        'guest_verdict': 'xrizer_guest_controllers: synthetic controllers through real xrizer and guest ABI -> ok' in log,
        'diagnostic_label': 'xrizer dev host: synthetic stationary controllers (oculus/touch_controller profile), diagnostic, not physical input' in log,
        'profiles_changed': all(f'/user/hand/{h} interaction profile changed: /interaction_profiles/oculus/touch_controller' in xlog for h in ('left', 'right')),
        'activation_events': all(re.search(rf'slot30 size 64 result 1 event type 100 device {d}\b', log) for d in (0, 1, 2)),
        'state_repacked': bool(re.search(r'slot34 device [12] size 64 result 1 packet \d+ pressed 0 touched 0 axis0 0\.000 0\.000 axis1 0\.000', log)),
        'unknown_size_refused': 'xrizer_guest_bridge: System019 slot34 refused size 60' in log,
        'state_with_pose': bool(re.search(r'slot35 device [12] size 64 result 1 ', log)),
        'haptic_passed': bool(re.search(r'slot36 device [12] axis 0 duration 500 us', log)),
        'no_unsupported_slot': 'unsupported' not in log,
        # The guest never submits, so a frame is outstanding at shutdown and the dev host refuses the exit request
        # (its documented rule); that one error is expected here, any other is not.
        'no_xrizer_panic': 'panicked' not in xlog and not re.search(r'\bERROR\s+xrizer::(?!openxr_data ThreadId\(\d+\)\] OpenXR request exit failed: ERROR_RUNTIME_FAILURE)', xlog),
        'strict_aot': len(summaries) >= 1 and int(summaries[-1][0]) > 0 and summaries[-1][1:] == ('0', '0'),
        'inputs_unchanged': all(digest(p) == identity[str(p)] for p in paths)}
    result = {'subject': 'owned Windows guest controller slots through synthetic offscreen Mac development host controllers; no game/headset/physical input claim',
              'command': command, 'environment': {k: v for k, v in env.items() if k.startswith(('VXRT_', 'XDG_'))},
              'returncode': rc, 'timed_out': timed_out, 'aot_summaries': summaries, 'checks': checks,
              'runtime_log_sha256': digest(out / 'runtime.log'), 'identities_sha256': digest(out / 'identities.json')}
    (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2)); return 0 if all(checks.values()) else 1


if __name__ == '__main__': raise SystemExit(main())
