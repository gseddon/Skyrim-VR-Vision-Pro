#!/usr/bin/env python3
"""Run the owned native_vr_d3d11 fixture only; this is not game-profile evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
SUMMARY = re.compile(r'aot: (\d+) entries into recompiled code, .*?, (\d+) fallbacks to the translator \((\d+) addresses\)')
SOURCES = ('VXRuntime/tests/native_vr_d3d11.cpp', 'VXRuntime/src/native_openvr.m',
           'VXRuntime/src/native_openvr.h', 'VXRuntime/src/native_vr.c', 'VXRuntime/src/native_vr.h',
           'VXRuntime/src/d3d11.m', 'VXRuntime/src/d3d_common.h', 'VXRuntime/translator/xlat.c',
           'VXRuntime/translator/engine.c', 'VXRuntime/translator/aot.c', 'VXRuntime/translator/aot.h',
           'VXRuntime/translator/xlat.h', 'VXRuntime/translator/xlat_sse.inc', 'VXRuntime/translator/x86dec.c',
           'VXRuntime/translator/x87.c', 'VXRuntime/translator/a64.h', 'VXRuntime/Makefile',
           'VXRuntime/tests/openvr/openvr.h', 'VXRuntime/tools/native_vr_run.py')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cpu_types(path):
    data = path.read_bytes()[:4096]
    if len(data) < 8:
        return set()
    magic = data[:4]
    if magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'):
        return {struct.unpack_from('<I', data, 4)[0]}
    if magic in (b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce'):
        return {struct.unpack_from('>I', data, 4)[0]}
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        n = struct.unpack_from('>I', data, 4)[0]
        stride = 24 if magic[-1] == 0xbf else 20
        if n > 100 or 8 + n * stride > len(data):
            return set()
        return {struct.unpack_from('>I', data, 8 + i * stride)[0] for i in range(n)}
    return set()


def checked_path(path, name):
    p = Path(path).resolve(strict=True)
    if not p.is_file():
        raise ValueError(f'{name} must be a file')
    return p


def git(*args):
    return subprocess.run(['git', '-C', str(REPO), *args], check=True, stdout=subprocess.PIPE).stdout


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--mode', required=True, choices=('rosetta', 'jit', 'aot'))
    ap.add_argument('--runtime', required=True)
    ap.add_argument('--exe', required=True)
    ap.add_argument('--aot-dir')
    ap.add_argument('--out', required=True)
    ap.add_argument('--timeout', type=float, default=30)
    args = ap.parse_args(argv)
    try:
        if not 0 < args.timeout <= 300:
            raise ValueError('timeout must be between 0 and 300 seconds')
        runtime = checked_path(args.runtime, 'runtime')
        exe = checked_path(args.exe, 'fixture')
        if exe != (REPO / 'VXRuntime/build/native_vr_d3d11.exe').resolve() or exe.read_bytes()[:2] != b'MZ':
            raise ValueError('exe must be the owned native_vr_d3d11.exe PE fixture')
        expected = 0x01000007 if args.mode == 'rosetta' else 0x0100000c
        if expected not in cpu_types(runtime) or not os.access(runtime, os.X_OK):
            raise ValueError('runtime Mach-O architecture or executable bit does not match mode')
        if (args.mode == 'aot') != bool(args.aot_dir):
            raise ValueError('--aot-dir is required only for aot mode')
        modules = []
        if args.aot_dir:
            directory = Path(args.aot_dir).resolve(strict=True)
            if not directory.is_dir():
                raise ValueError('aot directory is not a directory')
            modules = sorted(directory.glob('*.dylib'))
            h = 1469598103934665603
            for byte in exe.read_bytes():
                h = ((h ^ byte) * 1099511628211) & 0xffffffffffffffff
            stem = f'native_vr_d3d11.exe-{h:016x}'
            if not modules or not any(p.name == stem + '.dylib' or p.name == stem + '.p0.dylib' for p in modules):
                raise ValueError('aot directory lacks fixture module')
            if any(not p.is_file() or 0x0100000c not in cpu_types(p) for p in modules):
                raise ValueError('aot modules must be arm64 Mach-O files')
        out = Path(args.out).resolve()
        if out == REPO or not out.is_relative_to(REPO):
            raise ValueError('output must be a new directory inside the repository')
        sources = {name: digest(REPO / name) for name in SOURCES if (REPO / name).is_file()}
        if 'VXRuntime/tests/native_vr_d3d11.cpp' not in sources:
            raise ValueError('owned fixture source is missing')
        revision = git('rev-parse', 'HEAD').decode().strip()
        diff = git('diff', '--binary', 'HEAD')
        untracked = git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0')
        for name in sorted(filter(None, untracked)):
            path = REPO / os.fsdecode(name)
            if path.is_file() and not path.is_symlink():
                diff += b'\0' + name + b'\0' + bytes.fromhex(digest(path))
        diff_hash = hashlib.sha256(diff).hexdigest()
        probe = subprocess.run(['pgrep', '-x', 'vxrt|vxrt-arm64'], capture_output=True, text=True)
        if probe.returncode not in (0, 1):
            raise ValueError('could not check running vxrt processes')
        if probe.returncode == 0:
            raise ValueError('vxrt process already running: ' + probe.stdout.strip())
        out.mkdir(parents=True, exist_ok=False)
        root, overlay = out / 'root', out / 'overlay'
        root.mkdir(); overlay.mkdir()
        env = os.environ.copy()
        for key in list(env):
            if key.startswith('VXRT_'):
                env.pop(key)
        env.update(VXRT_ROOT=str(root), VXRT_OVERLAY=f'{REPO}:{overlay}', VXRT_NATIVE_VR='1', VXRT_NATIVE_VR_SIMULATE='1', VXRT_NO_WINE='1')
        if args.mode == 'aot':
            env['VXRT_AOT_DIR'] = str(directory)
            env['VXRT_AOT_STRICT'] = '1'
        cmd = ['/usr/bin/arch', '-x86_64' if args.mode == 'rosetta' else '-arm64', str(runtime), str(exe)]
        evidence = {'scope': 'owned native_vr_d3d11 fixture only; not game-profile evidence', 'mode': args.mode,
                    'command': cmd, 'source_revision': revision, 'dirty_diff_sha256': diff_hash,
                    'source_inputs_sha256': sources, 'source_evidence': 'snapshot at run time; artifact hashes identify binaries, but source hashes alone do not prove their build provenance', 'runtime_sha256': digest(runtime), 'exe_sha256': digest(exe),
                    'aot_modules_sha256': {str(p.resolve()): digest(p) for p in modules},
                    'environment': {k: env[k] for k in ('VXRT_ROOT', 'VXRT_OVERLAY', 'VXRT_NATIVE_VR', 'VXRT_NATIVE_VR_SIMULATE', 'VXRT_NO_WINE', 'VXRT_AOT_DIR', 'VXRT_AOT_STRICT') if k in env},
                    'timeout_seconds': args.timeout}
        log = out / 'fixture.log'; timed_out = False
        with log.open('wb') as f:
            p = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, env=env, start_new_session=True)
            try:
                rc = p.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(p.pid, signal.SIGKILL)
                rc = p.wait()
        content = log.read_text(errors='replace')
        summaries = SUMMARY.findall(content)
        summary_ok = bool(summaries) and all(int(e) > 0 and int(f) == 0 and int(a) == 0 for e, f, a in summaries)
        verdict = bool(re.search(r'^native_vr: ok\s*$', content, re.MULTILINE))
        evidence.update(returncode=rc, timed_out=timed_out, log_sha256=digest(log), fixture_verdict=verdict,
                        aot_summary_ok=summary_ok if args.mode == 'aot' else None,
                        passed=rc == 0 and not timed_out and verdict and (args.mode != 'aot' or summary_ok))
        (out / 'result.json').write_text(json.dumps(evidence, indent=2, sort_keys=True) + '\n')
        return 0 if evidence['passed'] else 1
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f'native_vr_run: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
