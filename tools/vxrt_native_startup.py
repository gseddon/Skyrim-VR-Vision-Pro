#!/usr/bin/env python3
"""Bounded native AOT startup evidence, without assigning a VR/game compatibility level."""
import argparse
import hashlib
import json
import os
from pathlib import Path

DIAG_ENV = {'VXRT_STATS', 'VXRT_TRACE_PASSES', 'VXRT_PASS_DUMP', 'VXRT_TRACE_DRAWS', 'VXRT_TRACE_TEXTURES', 'VXRT_TRACE_MAPS', 'VXRT_DUMP_SHADERS', 'VXRT_DRAW_SNAPSHOT', 'VXRT_TRACE_AUDIO', 'VXRT_XRIZER_DEV_DUMP_EVERY', 'VXRT_TRACE_CLEAR_STACK'}
import re
import signal
import struct
import subprocess
import sys

import vxrt_ledger as ledger
import vxrt_runtime_sessions as sessions

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'VXRuntime/tools'))
from native_vr_run import cpu_types
SUMMARY = re.compile(r'aot: (\d+) entries into recompiled code, .*?, (\d+) fallbacks to the translator \((\d+) addresses\)')


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def source_identity():
    """Capture tracked patch and untracked source bytes, excluding ignored build artifacts."""
    patch = subprocess.check_output(['git', '-C', str(REPO), 'diff', '--binary', 'HEAD', '--'])
    names = subprocess.check_output(['git', '-C', str(REPO), 'ls-files', '--others', '--exclude-standard', '-z'])
    h = hashlib.sha256(patch)
    for name in sorted(filter(None, names.split(b'\0'))):
        path = REPO / os.fsdecode(name)
        if path.is_file() and not path.is_symlink():
            h.update(name + b'\0' + digest(path).encode() + b'\0')
    return {'commit': subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip(),
            'patch_sha256': h.hexdigest()}


def pe_hash(path):
    data = Path(path).read_bytes()
    if len(data) < 64 or data[:2] != b'MZ':
        raise ValueError('expected a Windows PE image')
    off = struct.unpack_from('<I', data, 60)[0]
    if off + 26 > len(data) or data[off:off+4] != b'PE\0\0' or struct.unpack_from('<H', data, off+4)[0] != 0x8664 or struct.unpack_from('<H', data, off+24)[0] != 0x20b:
        raise ValueError('expected an x86-64 PE32+ image')
    h = 1469598103934665603
    for b in data:
        h = ((h ^ b) * 1099511628211) & 0xffffffffffffffff
    return h


def inspect_log(content, version=1):
    summaries = [dict(entries=int(e), fallback_requests=int(f), missing_addresses=int(a)) for e, f, a in SUMMARY.findall(content)]
    missing = re.findall(r'VXRT_AOT_STRICT: (0x[0-9a-fA-F]+) has no recompiled code', content)
    patterns = (
        'has no recompiled code', 'unimplemented function', 'dll not found', 'dll not loaded',
        'could not load', 'cannot load', 'unhandled', 'messagebox:', 'not used', '[vxrt] abort:')
    if version >= 2:
        patterns += ('signal ', 'native backtrace:', 'callback depth limit', 'callback_depth_limit', 'openvr-init:', 'aot-null-target:')
    if version >= 3:
        patterns += ('xrizer_guest_bridge: unsupported ', 'xrizer openvr: getgenericinterface ')
    candidates = [line for line in content.splitlines() if any(x in line.lower() for x in patterns)]
    # Preserve bounded null-target snapshots even after earlier problem lines.
    problem_lines = candidates[:30]
    if version >= 2:
        problem_lines += [line for line in candidates[30:] if 'aot-null-target:' in line.lower()][:30]
    facts = dict(aot_summaries=summaries, missing_code=missing, problem_lines=problem_lines,
                aot_executed=any(s['entries'] > 0 for s in summaries),
                zero_fallback_reported=bool(summaries) and all(s['fallback_requests'] == 0 and s['missing_addresses'] == 0 for s in summaries))
    if version >= 2:
        facts['native_signals'] = [dict(signal=int(sig), pc=pc, address=address, detail=detail)
            for sig, pc, address, detail in re.findall(
                r'\bsignal (\d+) at (0x[0-9a-fA-F]+) \(address (0x[0-9a-fA-F]+|0)\)([^\n]*)', content)]
        facts['native_backtrace'] = re.findall(r'^\d+\s+\S+\s+0x[0-9a-fA-F]+\s+[^\n]*', content, re.MULTILINE)[:64]
    if version >= 3:
        facts['xrizer_bridge_stops'] = [dict(interface=name, slot=int(slot)) for name, slot in re.findall(
            r'xrizer_guest_bridge: unsupported ([A-Za-z0-9_:]+) slot (\d+)', content)]
        facts['xrizer_unsupported_interfaces'] = re.findall(
            r'xrizer OpenVR: GetGenericInterface ([^\s]+) = (?:0x0|\(nil\)) error 106\b', content)
    if version >= 4:
        facts['xrizer_panics'] = [dict(source=source, line=int(line), column=int(column), message=message)
            for source, line, column, message in re.findall(
                r'\bERROR xrizer\b[^\n]*panicked at ([^\s:]+):(\d+):(\d+):\n([^\n]+)', content)]
    return facts


def validate(result):
    problems = []
    if result.get('kind') != 'native_aot_startup' or result.get('level') is not None:
        problems.append('invalid scope or compatibility level')
    if result.get('status') not in ('observed', 'refused'):
        problems.append('invalid evidence status')
    if result.get('status') == 'observed':
        if result.get('schema_version', 1) >= 3:
            source = result.get('source_identity', {})
            if source.get('commit') != result.get('source_commit') or not re.fullmatch(r'[0-9a-f]{64}', source.get('patch_sha256', '')):
                problems.append('invalid source identity')
        keys = ['runtime', 'exe']
        if result.get('schema_version', 1) >= 3:
            keys.append('xrizer_dylib')
        for key in keys:
            item = result['artifacts'].get(key)
            if not item or not Path(item['path']).is_file() or digest(item['path']) != item['sha256']:
                problems.append(key + ' artifact changed or missing')
        for item in result.get('observed', []):
            path = REPO / item['artifact']
            if not path.is_file() or digest(path) != item['sha256']:
                problems.append('observation artifact changed or missing')
        log = REPO / result['log']
        if log.is_file():
            facts = inspect_log(log.read_text(errors='replace'), result.get('schema_version', 1))
            actual = {o['metric']: o['value'] for o in result['observed']}
            for key, value in facts.items():
                if actual.get(key) != value:
                    problems.append(key + ' does not match log')
        for item in result['artifacts']['modules']:
            if not Path(item['path']).is_file() or digest(item['path']) != item['sha256']:
                problems.append('AOT artifact changed or missing')
        process_file = REPO / result['process']
        if process_file.is_file():
            process = json.loads(process_file.read_text())
            actual = {o['metric']: o['value'] for o in result['observed']}
            for key, value in process.items():
                if actual.get(key) != value:
                    problems.append(key + ' does not match process record')
        else:
            problems.append('process record missing')
    return problems


def expand_xinput_repeat(repeat, script=None):
    """BUTTONS@FROM-TO/EVERY[:HOLD] (seconds from process start, HOLD defaults to 0.2) as START:BUTTONS:HOLD entries,
    merged with an explicit --xinput-script and ordered by start time."""
    m = re.fullmatch(r'([A-Za-z]+(?:\+[A-Za-z]+)*|0x[0-9a-fA-F]+|[0-9]+)@([0-9]+(?:\.[0-9]+)?)-([0-9]+(?:\.[0-9]+)?)/([0-9]+(?:\.[0-9]+)?)(?::([0-9]+(?:\.[0-9]+)?))?', repeat)
    if not m:
        raise ValueError('--xinput-repeat: expected BUTTONS@FROM_S-TO_S/EVERY_S[:HOLD_S], e.g. A@30-120/3')
    buttons, start, end, every, hold = m.group(1), float(m.group(2)), float(m.group(3)), float(m.group(4)), float(m.group(5) or 0.2)
    if every <= hold or every < 0.5 or end < start or (end - start) / every > 500:
        raise ValueError('--xinput-repeat: EVERY must exceed HOLD (and be at least 0.5 s), TO must not precede FROM, at most 500 presses')
    entries = []
    t = start
    while t <= end + 1e-9:
        entries.append((t, '%g:%s:%g' % (t, buttons, hold)))
        t += every
    if script:
        for item in script.split(','):
            entries.append((float(item.split(':')[0]), item))
    return ','.join(item for _, item in sorted(entries, key=lambda e: e[0]))


def capture(args):
    out = Path(args.out).resolve()
    if out == REPO or not out.is_relative_to(REPO) or out.exists():
        raise ValueError('output must be a new directory inside this checkout')
    limit = 300 if getattr(args, 'experimental_xrizer', False) else 60   # longer observation only on the labelled dev host
    if not 0 < args.seconds <= limit:
        raise ValueError(f'seconds must be in (0, {limit}]')
    callback_limit = getattr(args, 'callback_depth_limit', None)
    if callback_limit is not None and not 2 <= callback_limit <= 256:
        raise ValueError('callback depth limit must be from 2 to 256')
    ring_at = getattr(args, 'trace_call_ring', None)
    if ring_at is not None and not 1 <= ring_at < args.seconds:
        raise ValueError('call ring time must be at least 1 second and before the timeout')
    xrizer_path = getattr(args, 'xrizer_dylib', None)
    if bool(getattr(args, 'experimental_xrizer', False)) != bool(xrizer_path):
        raise ValueError('experimental xrizer requires an explicit xrizer dylib, and vice versa')
    if xrizer_path:
        xrizer_path = Path(xrizer_path)
        if not xrizer_path.is_absolute():
            raise ValueError('xrizer dylib path must be absolute')
        xrizer_path = xrizer_path.resolve(strict=True)
        if not xrizer_path.is_file() or 0x0100000c not in cpu_types(xrizer_path):
            raise ValueError('xrizer dylib must be an ARM64 Mach-O file')
    exe = Path(args.exe).resolve(strict=True)
    runtime = Path(args.runtime).resolve(strict=True)
    directory = Path(args.aot_dir).resolve(strict=True)
    assets = Path(args.asset_root).resolve(strict=True)
    dlls = [Path(p).resolve(strict=True) for p in args.dll_dir]
    if not exe.is_relative_to(REPO):
        raise ValueError('execute only a private repository-local image or an owned fixture')
    if not assets.is_dir() or any(not p.is_dir() for p in dlls):
        raise ValueError('asset and DLL roots must be directories')
    if not runtime.is_file() or not os.access(runtime, os.X_OK) or 0x0100000c not in cpu_types(runtime):
        raise ValueError('runtime must be an executable ARM64 Mach-O')
    if not directory.is_dir() or not directory.is_relative_to(REPO):
        raise ValueError('AOT directory must be repository-local')
    stem = f'{exe.name.lower()}-{pe_hash(exe):016x}'
    modules = sorted(directory.glob('*.dylib'))
    if not any(p.name in (stem + '.dylib', stem + '.p0.dylib') for p in modules):
        raise ValueError('no hash-matched AOT module for executable')
    if any(0x0100000c not in cpu_types(p) for p in modules):
        raise ValueError('AOT modules must be ARM64 Mach-O files')
    # Private copied DLLs may live under the checkout; only original external
    # trees share the read-only overlay, whose destination must stay outside it.
    originals = [p for p in dlls if not p.is_relative_to(REPO)]
    source = Path(os.path.commonpath([str(assets), *map(str, originals)]))
    if source == Path('/') or REPO.is_relative_to(source) or out.is_relative_to(assets):
        raise ValueError('asset/DLL overlay would include repository outputs or filesystem root')
    # Do not run through the user's session (SteamVR, a Wine game, any runtime not provably harness/fixture-owned)
    # nor alongside a runtime writing into this run's directories; owned isolated runs may overlap and are recorded.
    checks, concurrent = sessions.preconditions([out], out/'temp')
    idle = all(c['ok'] for c in checks)
    out.mkdir(parents=True)
    result = dict(kind='native_aot_startup', schema_version=4 if getattr(args, 'experimental_xrizer', False) else 2, level=None, status='refused' if not idle else 'observed',
                  appid=getattr(args, 'appid', None),
                  scope='startup checkpoint only; no VR compatibility, frame, gameplay or performance claim',
                  source_commit=subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip(),
                  preconditions=checks,
                  observed=[], derived=[], inferred=[], unknown=[
                      'main-game code execution and scene initialization', 'VR connection and stereo frame delivery',
                      'headset input, audio and playability', 'code coverage outside observed startup path'])
    if concurrent:
        result.setdefault('diagnostic', {})['concurrent_runtime'] = dict(processes=concurrent,
            scope='owned runtime processes running when this run started; timing and fps may be affected')
    if idle:
        if getattr(args, 'experimental_xrizer', False):
            result['source_identity'] = source_identity()
        root, overlay, temp = out/'root', out/'overlay', out/'temp'
        for path in (root, overlay, temp):
            path.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
        if getattr(args, 'experimental_xrizer', False):
            env = {k: v for k, v in env.items() if not k.startswith('XDG_')}
            for kind in ('STATE', 'CONFIG', 'CACHE', 'DATA'):
                path = out / 'xdg' / kind.lower()
                path.mkdir(parents=True, mode=0o700)
                env[f'XDG_{kind}_HOME'] = str(path)
            env['VXRT_XRIZER_OPENVR'] = '1'
            env['VXRT_XRIZER_DYLIB'] = str(xrizer_path)
            result.setdefault('diagnostic', {})['experimental_xrizer'] = 'development host; injected head and disconnected controllers'
        env.update(VXRT_ROOT=str(root), VXRT_OVERLAY=f'{source}:{overlay}', VXRT_AOT_DIR=str(directory),
                   VXRT_AOT_STRICT='1', VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_MESSAGEBOX='auto',
                   VXRT_NO_ACTIVATE='1', VXRT_MUTE='1', VERANTYX_AUDIO='0', TMPDIR=str(temp),
                   VXRT_LOG_TIME='1', VXRT_TRACE_CALLS='3')
        env[sessions.MARKER] = str(out)               # marks this run's processes as harness-owned for other runs
        if dlls:
            env['VXRT_DLL_PATH'] = ':'.join(map(str, dlls))
        if callback_limit is not None:
            env['VXRT_CALLBACK_DEPTH_LIMIT'] = str(callback_limit)
            result.setdefault('diagnostic', {}).update(callback_depth_limit=callback_limit,
                scope='bounded diagnostic stop; not ordinary startup acceptance')
        if getattr(args, 'trace_openvr_init', False):
            env['VXRT_TRACE_OPENVR_INIT'] = '1'
            result.setdefault('diagnostic', {})['openvr_init_passthrough_trace'] = True
        if getattr(args, 'trace_null_target', False):
            env['VXRT_AOT_NULL_DIAGNOSTIC'] = '1'
            result.setdefault('diagnostic', {}).update(null_target_trace=True,
                null_target_scope='opt-in null-target snapshot; diagnostic evidence only')
        if getattr(args, 'dev_synthetic_stage', False):
            if not getattr(args, 'experimental_xrizer', False):
                raise ValueError('--dev-synthetic-stage requires --experimental-xrizer')
            env['VXRT_XRIZER_DEV_STAGE'] = '1'
            result.setdefault('diagnostic', {})['dev_synthetic_stage'] = 'synthetic origin declared the floor; not a physical floor or tracking claim'
        if getattr(args, 'dump_eyes', False):
            if not getattr(args, 'experimental_xrizer', False):
                raise ValueError('--dump-eyes requires --experimental-xrizer')
            (out / 'eyes').mkdir()
            env['VXRT_XRIZER_DEV_DUMP'] = str(out / 'eyes')
            result.setdefault('diagnostic', {})['dump_eyes'] = 'raw RGBA of published eyes, selected frames; development host only'
        if getattr(args, 'wait_dump', None):
            env['VXRT_WAIT_DUMP'] = args.wait_dump
            result.setdefault('diagnostic', {})['wait_dump'] = args.wait_dump
        for item in getattr(args, 'diag_env', None) or []:
            name, _, value = item.partition('=')
            if name not in DIAG_ENV:
                raise ValueError('--diag-env %s: only %s are allowed (read-only tracing of the renderer)' % (name, ', '.join(sorted(DIAG_ENV))))
            env[name] = value or '1'
            result.setdefault('diagnostic', {}).setdefault('diag_env', {})[name] = env[name]
        if getattr(args, 'aot_splits', None):
            splits = os.path.abspath(args.aot_splits)
            env['VXRT_AOT_SPLITS'] = splits
            result.setdefault('diagnostic', {})['aot_splits'] = splits
        if getattr(args, 'xinput_repeat', None):
            args.xinput_script = expand_xinput_repeat(args.xinput_repeat, getattr(args, 'xinput_script', None))
        if getattr(args, 'xinput_script', None):
            spec = args.xinput_script
            entry = r'[0-9]+(\.[0-9]+)?:([A-Za-z]+(\+[A-Za-z]+)*|0x[0-9a-fA-F]+|[0-9]+):[0-9]+(\.[0-9]+)?'
            if not re.fullmatch(entry + '(,' + entry + ')*', spec):
                raise ValueError('--xinput-script: expected START_S:BUTTONS:HOLD_S[,...] with BUTTONS names joined by + (A B X Y START BACK LB RB UP DOWN LEFT RIGHT LS RS) or a number')
            env['VXRT_XINPUT_SCRIPT'] = spec
            result.setdefault('diagnostic', {})['xinput_script'] = spec
            result['diagnostic']['xinput_script_scope'] = 'scripted virtual gamepad (times from process start); not a physical controller or tracking claim'
        if getattr(args, 'stay_active', False):
            env['VXRT_STAY_ACTIVE'] = '1'
            result.setdefault('diagnostic', {})['stay_active'] = 'game window stays the active window when the Mac is busy elsewhere (as in a headset session); not an input or tracking claim'
        if getattr(args, 'fault_objects', False):
            env['VXRT_FAULT_OBJECTS'] = '1'
            result.setdefault('diagnostic', {})['fault_objects'] = 'register pointee dump at an unhandled fault'
        if getattr(args, 'trace_files', False):
            env['VXRT_TRACE_FILES'] = '2' if getattr(args, 'trace_all_opens', False) else '1'
            result.setdefault('diagnostic', {})['trace_failed_file_opens'] = True
            if getattr(args, 'trace_all_opens', False):
                result['diagnostic']['trace_all_file_opens'] = True
        if ring_at is not None:
            env['VXRT_TRACE_CALLS_RING'] = '1'
            env['VXRT_TRACE_CALLS_RING_AT'] = str(ring_at)
            result.setdefault('diagnostic', {}).update(call_ring_at=ring_at,
                call_ring_scope='diagnostic dump of each thread\'s last runtime calls; not a startup acceptance')
        inputs = [exe]
        original = assets / exe.name
        if original.is_file() and original.resolve() != exe:
            inputs.append(original)
        for base in [assets, *dlls]:
            inputs.extend(p for p in base.glob('*.dll') if p.is_file())
        input_hashes = {str(p): digest(p) for p in set(inputs)}
        if xrizer_path:
            input_hashes[str(xrizer_path)] = digest(xrizer_path)
        result['artifacts'] = dict(runtime=dict(path=str(runtime), sha256=digest(runtime)),
                                   exe=dict(path=str(exe), sha256=digest(exe)),
                                   modules=[dict(path=str(p), sha256=digest(p)) for p in modules],
                                   read_only_inputs=input_hashes)
        if xrizer_path:
            result['artifacts']['xrizer_dylib'] = dict(path=str(xrizer_path), sha256=digest(xrizer_path))
        cmd = ['/usr/bin/arch', '-arm64', str(runtime), str(exe)]
        result.update(command=cmd, cwd=str(assets), environment={k:v for k,v in env.items() if k.startswith(('VXRT_', 'VERANTYX_')) or k=='TMPDIR' or (getattr(args, 'experimental_xrizer', False) and k.startswith('XDG_'))}, timeout_seconds=args.seconds)
        log = out/'startup.log'
        timed_out = False
        with log.open('wb') as f:
            p = subprocess.Popen(cmd, cwd=assets, env=env, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                rc = p.wait(timeout=args.seconds)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(p.pid, signal.SIGKILL)
                rc = p.wait()
        # No helper from the owned process group should survive the observation window.
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        facts = inspect_log(log.read_text(errors='replace'), result['schema_version'])
        process = out/'process.json'
        unchanged = all(Path(p).is_file() and digest(p) == h for p,h in input_hashes.items())
        process_data = dict(returncode=rc, timed_out=timed_out, read_only_inputs_unchanged=unchanged)
        if getattr(args, 'experimental_xrizer', False):
            process_data['source_unchanged'] = source_identity() == result['source_identity']
        process.write_text(json.dumps(process_data, indent=2)+'\n')
        result['log'] = str(log.relative_to(REPO))
        result['process'] = str(process.relative_to(REPO))
        for key, value in [*process_data.items(), *facts.items()]:
            art = process if key in process_data else log
            result['observed'].append(dict(id=f'o{len(result["observed"])+1}', metric=key, value=value,
                                           artifact=str(art.relative_to(REPO)), sha256=digest(art)))
    path = out/'result.json'
    path.write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    problems = validate(result)
    if problems:
        raise ValueError('invalid evidence: ' + '; '.join(problems))
    ledger.append(dict(kind=result['kind'], result=str(path.relative_to(REPO)), result_sha256=digest(path)))
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--exe'); ap.add_argument('--runtime'); ap.add_argument('--aot-dir')
    ap.add_argument('--asset-root'); ap.add_argument('--dll-dir', action='append', default=[])
    ap.add_argument('--appid', help='optional subject label, not a compatibility claim')
    ap.add_argument('--out'); ap.add_argument('--seconds', type=float, default=20)
    ap.add_argument('--callback-depth-limit', type=int, help='diagnostic only: stop at nested callback depth 2..256')
    ap.add_argument('--trace-openvr-init', action='store_true', help='diagnostic only: transparently log real OpenVR initialization results')
    ap.add_argument('--trace-null-target', action='store_true', help='diagnostic only: capture a null AOT target snapshot')
    ap.add_argument('--dev-synthetic-stage', action='store_true', help='diagnostic only: the experimental dev host declares its synthetic local origin to be the floor, so Standing tracking space is valid; no physical floor is claimed')
    ap.add_argument('--dump-eyes', action='store_true', help='diagnostic only: the experimental dev host writes raw RGBA of the published eyes for frames 1, 2, 60, 300 and 600 under <out>/eyes')
    ap.add_argument('--diag-env', action='append', metavar='NAME[=VALUE]', help='diagnostic only, repeatable: one of the renderer tracing knobs (%s)' % ', '.join(sorted(DIAG_ENV)))
    ap.add_argument('--xinput-script', default=None, metavar='SPEC', help='diagnostic only: VXRT_XINPUT_SCRIPT, a scripted virtual gamepad START_S:BUTTONS:HOLD_S[,...] (e.g. 40:A:0.3) with times from process start')
    ap.add_argument('--xinput-repeat', default=None, metavar='SPEC', help='diagnostic only: press a scripted-gamepad button repeatedly, BUTTONS@FROM_S-TO_S/EVERY_S[:HOLD_S] (e.g. A@30-120/3), merged with --xinput-script; the same virtual gamepad as --xinput-script')
    ap.add_argument('--stay-active', action='store_true', help='VXRT_STAY_ACTIVE=1: the game window stays the active window when the Mac moves on to another app (a game played in a headset is seldom frontmost; an inactive Skyrim pauses its world)')
    ap.add_argument('--aot-splits', default=None, metavar='FILE', help='diagnostic only: VXRT_AOT_SPLITS file the runtime writes with the x86 instructions whose ordered access crossed 16 bytes (input for vxrt-aot)')
    ap.add_argument('--wait-dump', default=None, help='diagnostic only: VXRT_WAIT_DUMP seconds list, e.g. 30,50: log threads blocked in waits, with their guest return addresses')
    ap.add_argument('--fault-objects', action='store_true', help='diagnostic only: at an unhandled fault, log what each register points at (VXRT_FAULT_OBJECTS=1)')
    ap.add_argument('--trace-files', action='store_true', help='diagnostic only: log guest file opens that fail, with the path (VXRT_TRACE_FILES=1)')
    ap.add_argument('--trace-all-opens', action='store_true', help='diagnostic only: with --trace-files, log every guest file open (VXRT_TRACE_FILES=2)')
    ap.add_argument('--trace-call-ring', type=int, metavar='SECONDS', help='diagnostic only: dump each thread\'s last runtime calls after this many seconds, before the timeout')
    ap.add_argument('--experimental-xrizer', action='store_true', help='select experimental native xrizer development host; requires a configured runtime')
    ap.add_argument('--xrizer-dylib', help='absolute path to the pinned native ARM64 xrizer dylib for experimental mode')
    ap.add_argument('--validate', metavar='RESULT_JSON')
    args = ap.parse_args()
    try:
        if args.validate:
            problems = validate(json.loads(Path(args.validate).read_text()))
            print(json.dumps(dict(valid=not problems, problems=problems)))
            return 1 if problems else 0
        if not all((args.exe, args.runtime, args.aot_dir, args.asset_root, args.out)):
            ap.error('exe, runtime, aot-dir, asset-root and out are required')
        result = capture(args)
        print(json.dumps(result, indent=2))
        return 3 if result['status'] == 'refused' else 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('native startup: ' + str(error), file=sys.stderr)
        return 4


if __name__ == '__main__':
    sys.exit(main())
