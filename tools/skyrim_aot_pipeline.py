#!/usr/bin/env python3
"""Plan or build private Skyrim AOT modules; optional bounded native startup.

JSON: original and prepared are {path,sha256}; dlls is a list of
{path,sha256,base}; runtime is {path,sha256}; asset_root, dll_roots,
exe_base, jobs and optional owned_gate (argument vector) complete the config.
Paths must be absolute. Inputs are pinned; prepared and DLLs must be private
repository-local copies. --probe requires --build and an explicit passing gate.
This validates basic PE layout and mapping ranges. It does not prepare inputs
or establish the provenance or semantic completeness of a prepared image.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / 'VXRuntime/tools/aot_build.sh'
COMPILER = REPO / 'VXRuntime/build/vxrt-aot'
CACHE = REPO / 'build/private/skyrim-aot-cache'


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''):
            h.update(b)
    return h.hexdigest()


def source_identity():
    def git(*args):
        return subprocess.check_output(['git', '-C', str(REPO), *args])
    head = git('rev-parse', 'HEAD').decode().strip()
    patch = git('diff', '--binary', 'HEAD', '--', 'VXRuntime')
    extra = git('ls-files', '--others', '--exclude-standard', '-z', '--', 'VXRuntime').split(b'\0')
    h = hashlib.sha256(patch)
    for name in sorted(filter(None, extra)):
        p = REPO / os.fsdecode(name)
        if p.is_file():
            h.update(name + b'\0' + digest(p).encode() + b'\0')
    return {'commit': head, 'patch_sha256': h.hexdigest()}


def pin(item, private=False):
    path = Path(item['path'])
    if not path.is_absolute():
        raise ValueError('input paths must be absolute')
    path = path.resolve(strict=True)
    if not path.is_file() or (private and not path.is_relative_to(REPO)):
        raise ValueError('input must be a regular file' + (' inside checkout' if private else ''))
    expected = item['sha256'].lower()
    if not re.fullmatch(r'[0-9a-f]{64}', expected) or digest(path) != expected:
        raise ValueError('SHA-256 mismatch: ' + str(path))
    return {'path': str(path), 'sha256': expected}


def base(value):
    if not isinstance(value, str) or not re.fullmatch(r'0x[0-9a-fA-F]+', value):
        raise ValueError('base must be a hex string')
    n = int(value, 16)
    if n <= 0 or n >= 2**64 or n % 65536:
        raise ValueError('base must be a nonzero 64-bit 64K-aligned address')
    return hex(n)


def directory(value):
    path = Path(value)
    if not path.is_absolute() or not path.resolve(strict=True).is_dir():
        raise ValueError('root must be an absolute directory')
    return str(path.resolve())


def pe_layout(path):
    """Reject malformed/wrong-ISA images before building or reusing modules."""
    data = Path(path).read_bytes()
    def reject(reason):
        raise ValueError('invalid x86-64 PE layout: ' + reason + ': ' + str(path))
    if len(data) < 64 or data[:2] != b'MZ':
        reject('DOS header')
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if pe < 64 or pe + 24 > len(data) or data[pe:pe+4] != b'PE\0\0':
        reject('PE header')
    machine, count = struct.unpack_from('<HH', data, pe+4)
    optional_size = struct.unpack_from('<H', data, pe+20)[0]
    opt = pe+24
    table = opt+optional_size
    if machine != 0x8664 or not 1 <= count <= 96 or optional_size < 112 or table+40*count > len(data):
        reject('machine, optional header or section table')
    if struct.unpack_from('<H', data, opt)[0] != 0x20b:
        reject('not PE32+')
    entry = struct.unpack_from('<I', data, opt+16)[0]
    preferred = struct.unpack_from('<Q', data, opt+24)[0]
    image_size, header_size = struct.unpack_from('<II', data, opt+56)
    directories = struct.unpack_from('<I', data, opt+108)[0]
    if not image_size or not table+40*count <= header_size <= min(len(data), image_size) or 112+8*directories > optional_size:
        reject('image/header/directory bounds')
    sections = []
    for i in range(count):
        off = table+40*i
        virtual_size, rva, raw_size, raw = struct.unpack_from('<IIII', data, off+8)
        flags = struct.unpack_from('<I', data, off+36)[0]
        size = max(virtual_size, raw_size)
        if size and (rva < header_size or rva+size > image_size):
            reject('section virtual bounds')
        if raw_size and (raw < header_size or raw+raw_size > len(data)):
            reject('section file bounds')
        if size:
            sections.append((rva, rva+size, flags))
    sections.sort()
    if any(a[1] > b[0] for a, b in zip(sections, sections[1:])):
        reject('overlapping virtual sections')
    if entry and not any(lo <= entry < hi and flags & 0x20000000 for lo, hi, flags in sections):
        reject('entry is outside executable sections')
    return {'machine': '0x8664', 'bits': 64, 'image_size': image_size,
            'preferred_base': hex(preferred), 'entry_rva': hex(entry), 'sections': count}


def prepare(config):
    original = pin(config['original'])
    exe = pin(config['prepared'], True)
    if original['path'] == exe['path']:
        raise ValueError('original and prepared must be separate files')
    runtime = pin(config['runtime'])
    modules = [dict(exe, base=base(config['exe_base']))]
    modules += [dict(pin(item, True), base=base(item['base'])) for item in config['dlls']]
    if len({Path(m['path']).name.lower() for m in modules}) != len(modules):
        raise ValueError('module basenames must be unique')
    if len({m['base'] for m in modules}) != len(modules):
        raise ValueError('module bases must be distinct; overlap requires separate review')
    for module in modules:
        module['pe'] = pe_layout(module['path'])
    # The loader reserves at 64K granularity; distinct bases can still overlap.
    ranges = sorted((int(m['base'], 16), int(m['base'], 16) +
                     ((m['pe']['image_size']+65535)//65536)*65536) for m in modules)
    if any(end > 2**64 for _, end in ranges) or any(a[1] > b[0] for a, b in zip(ranges, ranges[1:])):
        raise ValueError('module image mappings overlap or overflow')
    jobs = config.get('jobs', 1)
    if type(jobs) is not int or not 1 <= jobs <= 64:
        raise ValueError('jobs must be an integer from 1 to 64')
    gate = config.get('owned_gate')
    if gate is not None and (not isinstance(gate, list) or not gate or not all(isinstance(x, str) and x for x in gate)):
        raise ValueError('owned_gate must be a nonempty argument vector')
    return {'original': original, 'prepared': exe, 'runtime': runtime, 'modules': modules,
            'asset_root': directory(config['asset_root']), 'dll_roots': [directory(p) for p in config['dll_roots']],
            'jobs': jobs, 'owned_gate': gate}


def key_for(module, identity, compiler_hash, script_hash, jobs):
    data = {'sha256': module['sha256'], 'name': Path(module['path']).name,
            'base': module['base'], 'source': identity, 'compiler_sha256': compiler_hash,
            'script_sha256': script_hash, 'jobs': jobs, 'target': 'macos-arm64'}
    return hashlib.sha256(json.dumps(data, sort_keys=True).encode()).hexdigest(), data


def valid_cache(path, key):
    try:
        meta = json.loads((path / 'manifest.json').read_text())
        files = meta['artifacts']
        if set(files) != {p.name for p in path.glob('*.dylib')}:
            return False
        return (meta['key'] == key and meta['returncode'] == 0 and bool(files)
                and all(Path(n).name == n and n.endswith('.dylib') and (path/n).is_file()
                        and not (path/n).is_symlink() and digest(path/n) == h for n, h in files.items()))
    except (OSError, ValueError, KeyError, TypeError):
        return False


def build_module(module, identity, compiler_hash, script_hash, jobs, out):
    key, inputs = key_for(module, identity, compiler_hash, script_hash, jobs)
    dest = CACHE / key
    if dest.exists():
        if not valid_cache(dest, key):
            raise ValueError('invalid cached module: ' + str(dest))
        return dest, {'key': key, 'cached': True}
    tmp = Path(tempfile.mkdtemp(prefix='.building-', dir=CACHE))
    try:
        env = {k: v for k, v in os.environ.items() if not k.startswith('VXRT_AOT_') and k != 'AOT_JOBS'}
        env.update(VXRT_AOT_BASE=module['base'], AOT_JOBS=str(jobs))
        cmd = [str(SCRIPT), module['path'], str(tmp)]
        log = out / (key + '.build.log')
        with log.open('wb') as f:
            proc = subprocess.run(cmd, cwd=REPO, env=env, stdout=f, stderr=subprocess.STDOUT)
        artifacts = {p.name: digest(p) for p in sorted(tmp.glob('*.dylib')) if p.is_file() and not p.is_symlink()}
        result = {'key': key, 'cached': False, 'command': cmd, 'environment': {'VXRT_AOT_BASE': module['base'], 'AOT_JOBS': str(jobs)},
                  'returncode': proc.returncode, 'log': str(log), 'log_sha256': digest(log), 'artifacts': artifacts, 'inputs': inputs}
        (out / (key + '.build.json')).write_text(json.dumps(result, indent=2) + '\n')
        if proc.returncode or not artifacts:
            raise ValueError('module build failed or produced no dylibs; see ' + str(log))
        if digest(module['path']) != module['sha256'] or digest(COMPILER) != compiler_hash or digest(SCRIPT) != script_hash or source_identity() != identity:
            raise ValueError('input or build source changed during build')
        (tmp / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n')
        for p in tmp.iterdir():
            p.chmod(0o444)
        tmp.chmod(0o555)
        tmp.rename(dest)
        return dest, result
    finally:
        if tmp.exists():
            shutil.rmtree(tmp)


def classify(result):
    if result.get('status') != 'observed':
        return {'category': 'precondition', 'evidence': result.get('preconditions', [])}
    facts = {o['metric']: o['value'] for o in result.get('observed', [])}
    if facts.get('xrizer_bridge_stops'):
        return {'category': 'unsupported_xrizer_bridge_slot', 'evidence': facts['xrizer_bridge_stops'],
                'aot_summaries': facts.get('aot_summaries', [])}
    if facts.get('native_signals'):
        return {'category': 'native_signal', 'evidence': facts['native_signals'],
                'backtrace': facts.get('native_backtrace', []),
                'xrizer_unsupported_interfaces_observed': facts.get('xrizer_unsupported_interfaces', [])}
    lines = facts.get('problem_lines', [])
    patterns = [('has no recompiled code', 'missing_aot_code'), ('unimplemented function', 'missing_api'), ('dll not found', 'missing_dependency'), ('dll not loaded', 'missing_dependency'), ('could not load', 'loader'), ('cannot load', 'loader')]
    for line in lines:
        for pattern, category in patterns:
            if pattern in line.lower():
                return {'category': category, 'evidence': [line]}
    if facts.get('missing_code'):
        return {'category': 'missing_aot_code', 'evidence': facts['missing_code']}
    if facts.get('xrizer_unsupported_interfaces'):
        return {'category': 'unsupported_xrizer_interface_observed', 'evidence': facts['xrizer_unsupported_interfaces'],
                'causality': 'unknown; an application may handle an unsupported interface',
                'aot_summaries': facts.get('aot_summaries', [])}
    return {'category': 'unknown', 'evidence': {'returncode': facts.get('returncode'), 'timed_out': facts.get('timed_out'), 'problem_lines': lines,
                                                'aot_summaries': facts.get('aot_summaries', [])}}


def run(config, out, build=False, probe=False):
    if probe and not build:
        raise ValueError('--probe requires --build')
    out = Path(out).resolve()
    if out == REPO or not out.is_relative_to(REPO) or out.exists():
        raise ValueError('output must be a new checkout-local directory')
    cfg = prepare(config)
    if probe and not cfg['owned_gate']:
        raise ValueError('--probe requires an explicit owned_gate command')
    identity = source_identity()
    compiler_hash, script_hash = digest(COMPILER), digest(SCRIPT)
    out.mkdir(parents=True, mode=0o700)
    result = {'subject': 'private prepared-input AOT; no game or VR compatibility claim', 'status': 'planned',
              'config': cfg, 'source': identity, 'compiler_sha256': compiler_hash, 'script_sha256': script_hash,
              'target': 'macos-arm64', 'modules': [], 'unknown': ['prepared image provenance and semantic completeness', 'runtime code coverage', 'physical headset and playability']}
    def save():
        (out/'result.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    save()
    if not build:
        result['modules'] = [dict(key=key_for(m, identity, compiler_hash, script_hash, cfg['jobs'])[0], input=m) for m in cfg['modules']]
        save(); return result
    CACHE.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        with (CACHE/'build.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            dirs = []
            for m in cfg['modules']:
                dest, evidence = build_module(m, identity, compiler_hash, script_hash, cfg['jobs'], out)
                dirs.append(dest); result['modules'].append(evidence); save()
            module_set = out/'modules'; module_set.mkdir()
            for dest in dirs:
                manifest = json.loads((dest/'manifest.json').read_text())
                for name in manifest['artifacts']:
                    link = module_set/name
                    if link.exists() or link.is_symlink():
                        raise ValueError('duplicate generated module name: ' + name)
                    link.symlink_to(dest/name)
        result['status'] = 'built'; save()
        if cfg['owned_gate']:
            log = out/'owned-gate.log'
            with log.open('wb') as f:
                p = subprocess.run(cfg['owned_gate'], cwd=REPO, stdout=f, stderr=subprocess.STDOUT)
            result['gate'] = {'command': cfg['owned_gate'], 'returncode': p.returncode, 'log': str(log), 'log_sha256': digest(log)}
            if p.returncode:
                raise ValueError('owned gate failed')
        if probe:
            # A gate is arbitrary caller-supplied code: recheck every pinned input.
            prepare(config)
            if source_identity() != identity or digest(COMPILER) != compiler_hash or digest(SCRIPT) != script_hash:
                raise ValueError('source or compiler changed before probe')
            cmd = [sys.executable, str(REPO/'tools/vxrt_native_startup.py'), '--exe', cfg['prepared']['path'], '--runtime', cfg['runtime']['path'], '--aot-dir', str(module_set), '--asset-root', cfg['asset_root'], '--out', str(out/'startup'), '--seconds', str(config.get('seconds', 20))]
            for root in cfg['dll_roots']:
                cmd += ['--dll-dir', root]
            log = out/'probe-command.log'
            with log.open('wb') as f:
                p = subprocess.run(cmd, cwd=REPO, stdout=f, stderr=subprocess.STDOUT)
            result['probe'] = {'command': cmd, 'returncode': p.returncode, 'log': str(log), 'log_sha256': digest(log)}
            path = out/'startup/result.json'
            if path.exists():
                observation = json.loads(path.read_text())
                result['probe']['result_sha256'] = digest(path)
                result['probe']['first_blocker'] = classify(observation)
            if p.returncode:
                raise ValueError('native startup probe refused or failed')
            result['status'] = 'probe_observed'
        save(); return result
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        result['status'] = 'failed'; result['error'] = str(e); save()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True); parser.add_argument('--out', required=True)
    parser.add_argument('--build', action='store_true'); parser.add_argument('--probe', action='store_true')
    args = parser.parse_args()
    try:
        result = run(json.loads(Path(args.config).read_text()), args.out, args.build, args.probe)
        print(json.dumps(result, indent=2)); return 0
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as e:
        print('pipeline: ' + str(e), file=sys.stderr); return 1


if __name__ == '__main__':
    sys.exit(main())
