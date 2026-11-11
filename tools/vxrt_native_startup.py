#!/usr/bin/env python3
"""Bounded native AOT startup evidence, without assigning a VR/game compatibility level."""
import argparse
import hashlib
import json
import os
from pathlib import Path

CODE_HOOK_ENV = {'VXRT_PRELOAD', 'VXRT_EXEC_REGION', 'VXRT_CODE_VERIFY', 'VXRT_CODE_CAPTURE', 'VXRT_PRELOAD_EXIT', 'VXRT_CODE_CAPTURE_AT', 'VXRT_CODE_CAPTURE_EXIT', 'VXRT_CODE_WATCH', 'VXRT_AOT_STRICT', 'VXRT_AOT_MISSES', 'VXRT_PRELOAD_AT', 'VXRT_AOT_ARENA', 'VXRT_AOT_ARENA_MB', 'VXRT_DIR_ORDER'}   # (VXRuntime/src/codehooks.c: SKSE VR preload, capture and verify)
DIAG_ENV = {'VXRT_KEYBOARD', 'VXRT_KEYBOARD_TEXT', 'VXRT_TRACE_FILES', 'VXRT_TRACE_INPUT', 'VXRT_STATS', 'VXRT_TRACE_WINDOWS', 'VXRT_TRACE_PASSES', 'VXRT_PASS_DUMP', 'VXRT_TRACE_DRAWS', 'VXRT_TRACE_TEXTURES', 'VXRT_TRACE_MAPS', 'VXRT_DUMP_SHADERS', 'VXRT_DRAW_SNAPSHOT', 'VXRT_TRACE_AUDIO', 'VXRT_XRIZER_DEV_DUMP_EVERY', 'VXRT_TRACE_CLEAR_STACK', 'VXRT_DIAG_RTTI_ARRAY', 'VXRT_DIAG_RTTI_ARRAY_WORDS', 'VXRT_TRACE_DRAW_STACK', 'VXRT_TRACE_INI', 'VXRT_XR_SYNC_SUBMIT', 'VXRT_XR_SUBMIT_INFLIGHT', 'VXRT_FLUSH_DRAWS', 'VXRT_XRIZER_DEV_DUMP',
            'VXRT_AOT_FPCR_HIST', 'VXRT_AOT_FPCR_ALWAYS', 'VXRT_VISMASK', 'VXRT_VISMASK_SHAPE', 'VXRT_VISMASK_PROBE'}   # (the last two: module stubs' FPCR/FPSR counters, and the switch back to the previous stubs, RECOMP.md "FPCR") # XR_SYNC_SUBMIT=1: old blocking eye submit; XR_SUBMIT_INFLIGHT bound; FLUSH_DRAWS mid-frame commit threshold; XRIZER_DEV_DUMP=<dir> eye stats/raw frames
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
    if getattr(args, 'experimental_xrizer', False) and getattr(args, 'dev_keyboard', None) == '1':
        limit = 3600                                      # an interactive dev-keyboard session someone is playing
    if not 0 < args.seconds <= limit:
        raise ValueError(f'seconds must be in (0, {limit}]')
    callback_limit = getattr(args, 'callback_depth_limit', None)
    if callback_limit is not None and not 2 <= callback_limit <= 256:
        raise ValueError('callback depth limit must be from 2 to 256')
    # Call tracing (src/calltrace.c) puts a logging trampoline on every Windows call into the runtime for the whole
    # run: about 20% more process CPU on Skyrim (2026-11-10 A/B). Default 3 for probes; play passes 0 (off).
    trace_calls = getattr(args, 'trace_calls', 3)
    if trace_calls < 0:
        raise ValueError('--trace-calls must be 0 (off) or more')
    ring_at = getattr(args, 'trace_call_ring', None)
    if ring_at is not None and not 1 <= ring_at < args.seconds:
        raise ValueError('call ring time must be at least 1 second and before the timeout')
    if ring_at is not None and trace_calls == 0:
        raise ValueError('--trace-call-ring needs call tracing (--trace-calls N, N > 0)')
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
        # Seeded settings: a repository-owned tree of authored files (no game files) copied into this run's private
        # root (C:\\ is root/drive_c), e.g. the settings a game otherwise asks for on its first launch. Default for
        # --experimental-xrizer dev runs when tools/prefs_seed/<appid> exists; --prefs-seed none turns it off.
        seed = getattr(args, 'prefs_seed', None)
        if seed is None and getattr(args, 'experimental_xrizer', False) and getattr(args, 'appid', None):
            default = REPO / 'tools/prefs_seed' / str(args.appid)
            seed = str(default) if default.is_dir() else None
        if seed and seed != 'none':
            seed_dir = Path(seed).resolve(strict=True)
            copied = {}
            for src in sorted(p for p in seed_dir.rglob('*') if p.is_file() and p.name != 'README.md'):
                dst = root / src.relative_to(seed_dir)
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes(src.read_bytes())
                copied[str(src.relative_to(seed_dir))] = digest(src)
            result.setdefault('diagnostic', {})['prefs_seed'] = dict(source=str(seed_dir), files=copied,
                scope='authored settings copied into the private root before start; not game files')
        # --saves-dir DIR: the game's "My Games/Skyrim VR/Saves" in this run's private root becomes a symlink to DIR, so saves
        # (and a save copied in by hand) outlive the run; the root itself is per-run. DIR is private user data, never committed.
        saves = getattr(args, 'saves_dir', None)
        if saves:
            target = Path(saves).resolve()
            target.mkdir(parents=True, exist_ok=True)
            link = root / 'drive_c/users/vxrt/Documents/My Games/Skyrim VR/Saves'
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target, target_is_directory=True)
            result.setdefault('diagnostic', {})['saves_dir'] = dict(link=str(link), target=str(target),
                scope='persistent saves directory linked into the private root; contents are user data, not recorded')
        # --mods-dir DIR: DIR/Data holds a flattened loose-file mod tree (textures, meshes, ...). Each top-level entry of
        # DIR/Data becomes a symlink inside this run's overlay Data, so the game finds it through the overlay; the install
        # is only read. DIR is private user data (git-ignored), never committed. No ESP/BSA handling: those need plugins.txt.
        mods = getattr(args, 'mods_dir', None)
        mods_cfg = getattr(args, 'mods_config', None)
        if mods_cfg:
            # --mods-config PACK/mods.json (tools/mods.py): the pack's merged tree (priority resolved on the Mac) and its
            # Plugins.txt are applied exactly like --mods-dir; the list (active or not, with reasons) is recorded.
            if mods:
                raise ValueError('--mods-config and --mods-dir are alternatives')
            cfgp = Path(mods_cfg).resolve(strict=True); cfg = json.loads(cfgp.read_text())
            if cfg.get('version') != 1 or not isinstance(cfg.get('mods'), list):
                raise ValueError('--mods-config: expected a version 1 mods.json from tools/mods.py')
            mroot = (cfgp.parent / cfg['merged']).resolve(strict=True)
            if not mroot.is_relative_to(cfgp.parent.resolve()):
                raise ValueError('--mods-config: merged tree must be inside the pack')
            mods = str(mroot)
            result.setdefault('diagnostic', {})['mods_config'] = dict(file=str(cfgp), profile=cfg.get('profile'), plugins=cfg.get('plugins'),
                mods=[dict(id=m['id'], kind=m['kind'], enabled=m['enabled'], active=m['active'], size_bytes=m.get('size_bytes'), note=m.get('note')) for m in cfg['mods']],
                scope='priority resolved by tools/mods.py when the pack was built; the runtime keeps one overlay layer')
        if mods:
            mdata = Path(mods).resolve(strict=True) / 'Data'
            if not mdata.is_dir():
                raise ValueError('--mods-dir: expected DIR/Data')
            odata = overlay / assets.relative_to(source) / 'Data'
            odata.mkdir(parents=True, exist_ok=True)
            linked = {}
            # Per-file overlay: an entry the install does not have is linked whole; a directory the install has (Scripts, interface,
            # Textures, ...) becomes a real overlay directory (the install's spelling) holding links to the mod's files, and the
            # runtime lists overlay and install together (files.c); a FILE the install already has is still refused.
            def link_tree(src_dir, dst_dir, inst_dir, rel, count, shadow_ok=frozenset()):
                inst = {e.name.lower(): e for e in inst_dir.iterdir()} if inst_dir is not None and inst_dir.is_dir() else {}
                for ent in sorted(src_dir.iterdir()):
                    have = inst.get(ent.name.lower())
                    if have is None:
                        (dst_dir / ent.name).symlink_to(ent, target_is_directory=ent.is_dir())
                        count[rel + ent.name] = sum(1 for q in ent.rglob('*') if q.is_file()) if ent.is_dir() else 1
                    elif have.is_dir() and ent.is_dir():
                        sub = dst_dir / have.name
                        sub.mkdir(exist_ok=True)
                        link_tree(ent, sub, have, rel + have.name + '/', count, shadow_ok)
                    elif (rel + ent.name).lower() in shadow_ok and have.is_file() and ent.is_file():
                        (dst_dir / have.name).symlink_to(ent)       # (listed by the pack as allowed to replace an install file)
                        count[rel + ent.name + ' (replaces the install file)'] = 1
                    else:
                        raise ValueError(f'--mods-dir: Data/{rel}{ent.name} already exists in the install; refusing to shadow it')
            link_tree(mdata, odata, assets / 'Data', '', linked, frozenset(x.lower() for x in (cfg.get('shadow_install') or [])) if mods_cfg else frozenset())
            # Plugins.txt: the game opens C:\users\vxrt\AppData\Local\Skyrim VR\Plugins.txt (seen in a file trace). DIR/Plugins.txt if
            # present, else one "*Name" line per .esp/.esm/.esl at the top of DIR/Data (SE-style: the star enables; the official
            # masters are implicit). Official-master-only plugins are the caller's responsibility (tools/fomod_auto.py checks).
            plug = [e.name for e in sorted(mdata.iterdir()) if e.is_file() and e.suffix.lower() in ('.esp', '.esm', '.esl')]
            ptxt = Path(mods).resolve() / 'Plugins.txt'
            if ptxt.is_file() or plug:
                pdst = root / 'drive_c/users/vxrt/AppData/Local/Skyrim VR/Plugins.txt'
                pdst.parent.mkdir(parents=True, exist_ok=True)
                pdst.write_text(ptxt.read_text() if ptxt.is_file() else ''.join(f'*{n}\r\n' for n in plug), newline='')
                result.setdefault('diagnostic', {})['plugins_txt'] = dict(path=str(pdst), plugins=plug, from_file=ptxt.is_file())
            result.setdefault('diagnostic', {})['mods_dir'] = dict(source=str(mdata), linked_entries=linked,
                scope='loose files linked into the run overlay; install untouched; effect on the game unverified until a file trace shows the opens')
        # --overlay-ini FILE:SECTION:KEY=VALUE: a per-run copy of an ini of the asset tree (FILE is relative to --asset-root)
        # inside this run's overlay with one key set; the original is only read. The game reads the copy through the overlay.
        for spec in getattr(args, 'overlay_ini', None) or []:
            name, sec, kv = spec.split(':', 2)
            key, _, val = kv.partition('=')
            if not (name and sec and key) or '/' in name or '..' in name:
                raise ValueError('--overlay-ini: expected FILE:SECTION:KEY=VALUE, FILE a plain name in the asset root')
            dst = overlay / assets.relative_to(source) / name
            orig = assets / name
            lines = orig.read_text(encoding='utf-8', errors='replace').splitlines() if orig.is_file() else []
            out_l, in_sec, done = [], False, False
            for ln in lines:
                st = ln.strip()
                if st.startswith('['):
                    if in_sec and not done:
                        out_l.append(f'{key}={val}'); done = True
                    in_sec = st.lower() == f'[{sec.lower()}]'
                elif in_sec and st.split('=', 1)[0].strip().lower() == key.lower():
                    ln = f'{key}={val}'; done = True
                out_l.append(ln)
            if not done:
                if not in_sec:
                    out_l.append(f'[{sec}]')
                out_l.append(f'{key}={val}')
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text('\r\n'.join(out_l) + '\r\n', encoding='utf-8')
            result.setdefault('diagnostic', {}).setdefault('overlay_ini', []).append(dict(file=name, section=sec, key=key, value=val,
                copy=str(dst), original_sha256=digest(orig) if orig.is_file() else None,
                scope='per-run copy in the overlay; the asset root file is not modified'))
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
                   VXRT_LOG_TIME='1', VXRT_TRACE_CALLS=str(trace_calls))
        # D3D11/D3D12 shader library cache (VXRuntime/src/d3d12.m, d3d11_draw.m). The harness strips VXRT_* from the caller's
        # environment, so it is passed here: one folder shared by every run (not the per-run out/ or TMPDIR, which are
        # deleted), in the checkout's git-ignored build/private. Holds translated game shaders: private, never committed.
        # VXRT_SHADER_CACHE in the caller's environment overrides it ('0': off). The game only reads <key>.metallib and
        # queues the source of each miss in pending/; tools/shadercache_fill.sh compiles those (about 11000 distinct
        # shaders in a Skyrim boot, ~50 MB of .metal and ~170 MB of .metallib) so the next boot loads them. `rm -rf
        # build/private/shadercache` clears it; the libraries are also trimmed to VXRT_SHADER_CACHE_MAX_MB (1024).
        cache = os.environ.get('VXRT_SHADER_CACHE') or str(REPO / 'build' / 'private' / 'shadercache')
        if cache != '0':
            Path(cache).mkdir(parents=True, exist_ok=True, mode=0o700)
        env['VXRT_SHADER_CACHE'] = cache
        result.setdefault('diagnostic', {})['shader_cache'] = cache
        if getattr(args, 'audio', False):
            env['VXRT_MUTE'] = '0'; env['VERANTYX_AUDIO'] = '1'
            result.setdefault('diagnostic', {})['audio'] = 'unmuted: XAudio2/WASAPI output to the Mac default output device'
        if getattr(args, 'hud', False):
            env['MTL_HUD_ENABLED'] = '1'
            result.setdefault('diagnostic', {})['metal_hud'] = 'MTL_HUD_ENABLED=1: Apple Metal Performance HUD on the Metal layers'
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
        if getattr(args, 'dev_synthetic_controllers', None):
            if not getattr(args, 'experimental_xrizer', False):
                raise ValueError('--dev-synthetic-controllers requires --experimental-xrizer')
            env['VXRT_XRIZER_DEV_CONTROLLERS'] = args.dev_synthetic_controllers
            result['diagnostic']['experimental_xrizer'] = 'development host; injected head and synthetic stationary controllers'
            result['diagnostic']['dev_synthetic_controllers'] = dict(profile=args.dev_synthetic_controllers,
                scope='two connected, stationary, untracked synthetic controllers (no buttons pressed) from the dev host through the provider and xrizer; diagnostic, not physical input or tracking')
        if getattr(args, 'dev_keyboard', None) or getattr(args, 'dev_key_script', None) or getattr(args, 'dev_keymap', None):
            if not getattr(args, 'experimental_xrizer', False):
                raise ValueError('--dev-keyboard/--dev-key-script/--dev-keymap require --experimental-xrizer')
            mode = getattr(args, 'dev_keyboard', None) or 'script'
            env['VXRT_XRIZER_DEV_KEYBOARD'] = mode
            if getattr(args, 'dev_key_script', None): env['VXRT_XRIZER_DEV_KEY_SCRIPT'] = args.dev_key_script
            if getattr(args, 'dev_keymap', None): env['VXRT_XRIZER_DEV_KEYMAP'] = args.dev_keymap
            result.setdefault('diagnostic', {})['experimental_xrizer'] = 'development host; injected head and synthetic keyboard-driven controllers'
            result['diagnostic']['dev_keyboard'] = dict(mode=mode, script=env.get('VXRT_XRIZER_DEV_KEY_SCRIPT'), keymap=env.get('VXRT_XRIZER_DEV_KEYMAP'),
                scope='Mac keyboard / scripted keys driving two synthetic untracked controllers (Oculus Touch unless --dev-synthetic-controllers) and the synthetic head; diagnostic, not physical input or tracking')
        if getattr(args, 'audio_capture', None):
            env['VXRT_XAUDIO2_CAPTURE'] = os.path.abspath(args.audio_capture)
            result.setdefault('diagnostic', {})['audio_capture'] = env['VXRT_XAUDIO2_CAPTURE']
        if getattr(args, 'dump_eyes', False):
            if not getattr(args, 'experimental_xrizer', False):
                raise ValueError('--dump-eyes requires --experimental-xrizer')
            (out / 'eyes').mkdir()
            env['VXRT_XRIZER_DEV_DUMP'] = str(out / 'eyes')
            result.setdefault('diagnostic', {})['dump_eyes'] = 'raw RGBA of published eyes, selected frames; development host only'
        if getattr(args, 'd3d11_capture', None):
            # VXRT_D3D11_CAPTURE (VXRuntime/src/d3d11_capture.m): the program's Direct3D 11 calls, its shaders and
            # textures, for tools/d3d11_replay.m. Game-derived data: written outside the repository, never over a file.
            cap = Path(os.path.abspath(args.d3d11_capture))
            if cap.is_relative_to(REPO) or cap.exists():
                raise ValueError('--d3d11-capture: a new file outside the repository (the capture holds the program\'s data)')
            env['VXRT_D3D11_CAPTURE'] = str(cap)
            frames = getattr(args, 'd3d11_capture_eye_frames', None)
            if frames is not None:
                if frames < 1:
                    raise ValueError('--d3d11-capture-eye-frames must be at least 1')
                env['VXRT_D3D11_CAPTURE_EYE_FRAMES'] = str(frames)
            result.setdefault('diagnostic', {})['d3d11_capture'] = {'file': str(cap), 'eye_frames': frames,
                'scope': 'Direct3D 11 calls recorded for replay; diagnostic, private game-derived data, not a compatibility claim'}
        if getattr(args, 'wait_dump', None):
            env['VXRT_WAIT_DUMP'] = args.wait_dump
            result.setdefault('diagnostic', {})['wait_dump'] = args.wait_dump
        for item in getattr(args, 'diag_env', None) or []:
            name, _, value = item.partition('=')
            if name not in DIAG_ENV:
                raise ValueError('--diag-env %s: only %s are allowed (read-only tracing of the renderer)' % (name, ', '.join(sorted(DIAG_ENV))))
            env[name] = value or '1'
            result.setdefault('diagnostic', {}).setdefault('diag_env', {})[name] = env[name]
        for item in getattr(args, 'code_hook', None) or []:   # the static script-extender scheme (research/2026-11-11-skse-vr-on-aot.md)
            name, _, value = item.partition('=')
            if name not in CODE_HOOK_ENV or not value:
                raise ValueError('--code-hook %s: NAME=VALUE with NAME one of %s' % (name, ', '.join(sorted(CODE_HOOK_ENV))))
            env[name] = value
            result.setdefault('diagnostic', {}).setdefault('code_hook', {})[name] = value
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
        run_exe = exe
        skse_plugins = (cfg.get('skse_plugins') if mods_cfg else None) or []
        if skse_plugins:
            # SKSE reads <directory of the running exe>/Data/SKSE/Plugins, not the overlay: a per-run directory holds an APFS clone
            # of the prepared exe (same bytes, so the same AOT module) and a clone of the pack's Data/SKSE tree.
            xdir = out / 'exe'
            (xdir / 'Data').mkdir(parents=True)
            subprocess.run(['cp', '-c', str(exe), str(xdir / exe.name)], check=True)
            subprocess.run(['cp', '-cR', str(mroot / 'Data' / 'SKSE'), str(xdir / 'Data' / 'SKSE')], check=True)
            if digest(xdir / exe.name) != digest(exe):
                raise ValueError('per-run exe clone differs from the prepared exe')
            run_exe = xdir / exe.name
            result.setdefault('diagnostic', {})['skse_plugins'] = dict(dir=str(xdir / 'Data' / 'SKSE' / 'Plugins'), plugins=skse_plugins,
                scope='per-run copy of the pack tree where SKSE reads it; hashes are those the pipeline built modules for')
            for pl in skse_plugins:
                if pl.get('sha256') and digest(xdir / 'Data' / pl['path']) != pl['sha256']:
                    raise ValueError(f"skse plugin {pl['path']} differs from the pack's recorded hash")
        cmd = ['/usr/bin/arch', '-arm64', str(runtime), str(run_exe)]
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
    ap.add_argument('--dev-synthetic-controllers', nargs='?', const='touch', choices=('touch', 'index', 'vive'), help='diagnostic only: the experimental dev host reports two connected, stationary synthetic controllers of this kind (default touch) through the provider and xrizer; not physical input')
    ap.add_argument('--dev-keyboard', nargs='?', const='1', choices=('1', 'script'), help='diagnostic only: VXRT_XRIZER_DEV_KEYBOARD; 1 opens the dev host\'s mirror window whose keys drive synthetic controllers (see VXRuntime/src/xrizer_dev_host.m), script uses --dev-key-script only')
    ap.add_argument('--dev-key-script', metavar='START:KEYS:HOLD[,...]', help='diagnostic only: VXRT_XRIZER_DEV_KEY_SCRIPT (seconds since the dev host started, or fN frames); implies --dev-keyboard script')
    ap.add_argument('--dev-keymap', metavar='SPEC|/FILE', help='diagnostic only: VXRT_XRIZER_DEV_KEYMAP override of the dev keyboard map')
    ap.add_argument('--audio-capture', metavar='FILE', help='diagnostic only: VXRT_XAUDIO2_CAPTURE, the XAudio2 mastering mix ("VXCA" header, float32) written to FILE; keep game audio private')
    ap.add_argument('--prefs-seed', metavar='DIR|none', help='a tree copied into the run\'s private root (drive_c/...) before start; default for --experimental-xrizer: tools/prefs_seed/<appid> when present; none: no seed')
    ap.add_argument('--saves-dir', metavar='DIR', help='link C:\\users\\vxrt\\Documents\\My Games\\Skyrim VR\\Saves of the run\'s private root to DIR (created if missing) so saves persist across runs')
    ap.add_argument('--mods-config', metavar='PACK/mods.json', help='diagnostic: a mod pack built by tools/mods.py; its merged tree and Plugins.txt are applied like --mods-dir and its list is recorded in the result')
    ap.add_argument('--mods-dir', metavar='DIR', help='diagnostic: link each top-level entry of DIR/Data (a flattened loose-file mod tree) into the run\'s overlay Data; the install is not touched')
    ap.add_argument('--overlay-ini', action='append', metavar='FILE:SECTION:KEY=VALUE', help='diagnostic only, repeatable: set one ini key in a per-run copy of FILE (from the asset root) inside the run\'s overlay, e.g. Skyrim.ini:General:sIntroSequence= (empty value); the original is not touched')
    ap.add_argument('--dump-eyes', action='store_true', help='diagnostic only: the experimental dev host writes raw RGBA of the published eyes for frames 1, 2, 60, 300 and 600 under <out>/eyes')
    ap.add_argument('--code-hook', action='append', metavar='NAME=VALUE', help='repeatable: %s (SKSE VR preload; research/2026-11-11-skse-vr-on-aot.md)' % ', '.join(sorted(CODE_HOOK_ENV)))
    ap.add_argument('--diag-env', action='append', metavar='NAME[=VALUE]', help='diagnostic only, repeatable: one of the renderer tracing knobs (%s)' % ', '.join(sorted(DIAG_ENV)))
    ap.add_argument('--xinput-script', default=None, metavar='SPEC', help='diagnostic only: VXRT_XINPUT_SCRIPT, a scripted virtual gamepad START_S:BUTTONS:HOLD_S[,...] (e.g. 40:A:0.3) with times from process start')
    ap.add_argument('--xinput-repeat', default=None, metavar='SPEC', help='diagnostic only: press a scripted-gamepad button repeatedly, BUTTONS@FROM_S-TO_S/EVERY_S[:HOLD_S] (e.g. A@30-120/3), merged with --xinput-script; the same virtual gamepad as --xinput-script')
    ap.add_argument('--stay-active', action='store_true', help='VXRT_STAY_ACTIVE=1: the game window stays the active window when the Mac moves on to another app (a game played in a headset is seldom frontmost; an inactive Skyrim pauses its world)')
    ap.add_argument('--audio', action='store_true', help='unmute: VXRT_MUTE=0, the game\'s sound goes to the Mac\'s default output device (the harness mutes by default)')
    ap.add_argument('--hud', action='store_true', help='diagnostic only: MTL_HUD_ENABLED=1, Apple\'s Metal Performance HUD')
    ap.add_argument('--aot-splits', default=None, metavar='FILE', help='diagnostic only: VXRT_AOT_SPLITS file the runtime writes with the x86 instructions whose ordered access crossed 16 bytes (input for vxrt-aot)')
    ap.add_argument('--d3d11-capture', default=None, metavar='FILE', help='diagnostic only: VXRT_D3D11_CAPTURE, record the Direct3D 11 calls for VXRuntime/build/vxrt-d3d11-replay into FILE (new, outside the repository)')
    ap.add_argument('--d3d11-capture-eye-frames', type=int, default=None, metavar='N', help='diagnostic only: with --d3d11-capture, stop the capture after the VR frame with id N')
    ap.add_argument('--wait-dump', default=None, help='diagnostic only: VXRT_WAIT_DUMP seconds list, e.g. 30,50: log threads blocked in waits, with their guest return addresses')
    ap.add_argument('--fault-objects', action='store_true', help='diagnostic only: at an unhandled fault, log what each register points at (VXRT_FAULT_OBJECTS=1)')
    ap.add_argument('--trace-calls', type=int, default=3, metavar='N', help='VXRT_TRACE_CALLS: log the first N calls per runtime function (default 3; 0: off, no trampolines; costs CPU on every call)')
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
