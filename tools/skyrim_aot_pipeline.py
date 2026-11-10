#!/usr/bin/env python3
"""Plan or build private Skyrim AOT modules; optional bounded native startup.

JSON: original and prepared are {path,sha256}; dlls is a list of
{path,sha256,base}; runtime is {path,sha256}; asset_root, dll_roots, jobs and
optional owned_gate (argument vector) complete the config. The exe is given by
either exe_base (a hex base) or an exe block {base, part_mb, splits, roots}:
splits and roots are null or a pinned {path,sha256} file of hex addresses at
the image's preferred base, which the pipeline shifts by (base - preferred
ImageBase) and passes to vxrt-aot as VXRT_AOT_SPLITS and VXRT_AOT_ROOTS
(addresses outside the image are left out and counted); part_mb is
VXRT_AOT_PART_MB. compiler is an optional pinned
{path,sha256,source_commit} vxrt-aot; without it this checkout's
VXRuntime/build/vxrt-aot is used and only its hash is recorded.
Paths must be absolute. Inputs are pinned; the prepared exe, DLLs and address
files must be private copies inside the repository's main checkout (which
contains its worktrees). Each module is built by vxrt-aot gen, then every part
is assembled and linked in parallel; a dylib's install name is
dylibs/<name> wherever it is built. --probe requires --build and an explicit
passing gate.
This validates basic PE layout and mapping ranges. It does not prepare inputs
or establish the provenance or semantic completeness of a prepared image.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
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
COMPILER = REPO / 'VXRuntime/build/vxrt-aot'
CACHE = REPO / 'build/private/skyrim-aot-cache'
PRIVATE = None    # the main checkout (parent of the git common directory); found on first use
# Changes when the build steps below would produce different files from the same inputs.
BUILDER = 'vxrt-aot gen; clang -arch arm64 -c; clang -arch arm64 -dynamiclib -o dylibs/<name> (cwd: build dir); v1'


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


def toolchain():
    """The assembler/linker identity: the same .s can link differently with another clang/ld."""
    clang = subprocess.run(['clang', '--version'], capture_output=True, check=True).stdout.decode().splitlines()
    ld = subprocess.run(['ld', '-v'], capture_output=True).stderr.decode().splitlines()
    return {'clang': clang[0] if clang else '', 'ld': ld[0] if ld else ''}


def private_root():
    """Private inputs and outputs live in the main checkout; a worktree is inside it."""
    global PRIVATE
    if PRIVATE is None:
        try:
            common = subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', '--path-format=absolute',
                                              '--git-common-dir'], stderr=subprocess.DEVNULL).decode().strip()
            common = Path(common).resolve()
            PRIVATE = common.parent if common.name == '.git' and REPO.is_relative_to(common.parent) else REPO
        except (OSError, subprocess.SubprocessError):
            PRIVATE = REPO
    return Path(PRIVATE)


def pin(item, private=False):
    path = Path(item['path'])
    if not path.is_absolute():
        raise ValueError('input paths must be absolute')
    path = path.resolve(strict=True)
    if not path.is_file() or (private and not path.is_relative_to(private_root())):
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


def shifted(item, module):
    """An address file (hex, one per line) moved from the image's preferred base to the module's base.

    A runtime profile lists addresses of every module the run used; those outside this image at
    its preferred base belong to other modules (or other bases) and are left out and counted.
    Returns (text, used, outside)."""
    preferred, size = int(module['pe']['preferred_base'], 16), module['pe']['image_size']
    delta = int(module['base'], 16) - preferred
    lines, outside = [], 0
    for n, line in enumerate(Path(item['path']).read_text().splitlines(), 1):
        if not line.strip():
            continue
        if not re.fullmatch(r'\s*(0x)?[0-9a-fA-F]+\s*', line):
            raise ValueError('address file line %d is not a hex address: %s' % (n, item['path']))
        a = int(line, 16)
        if preferred <= a < preferred + size:
            lines.append('0x%x\n' % (a + delta))
        else:
            outside += 1
    if not lines:
        raise ValueError('address file has no address inside the image (use null for none): ' + item['path'])
    return ''.join(lines), len(lines), outside


def part_mb(value):
    if value is None:
        return None
    if type(value) not in (int, float) or not 0 < value <= 4096:
        raise ValueError('part_mb must be a number from 1 to 4096')
    return value


def compiler_config(config):
    item = config.get('compiler')
    if item is None:
        return {'path': str(COMPILER), 'sha256': None, 'source_commit': None}
    commit = item.get('source_commit')
    if not isinstance(commit, str) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('compiler.source_commit must be a 40-digit commit id')
    return dict(pin(item), source_commit=commit)


def pin_runtime(item, strict):
    """The runtime only runs in --probe, so only a probe needs it to match its pin. A build records what is there:
    the play script rebuilds its runtime on every change, so a stale pin must not refuse module generation."""
    if strict:
        return pin(item)
    path = Path(item['path'])
    if not path.is_absolute():
        raise ValueError('input paths must be absolute')
    path = path.resolve(strict=True)
    if not path.is_file():
        raise ValueError('input must be a regular file')
    actual, expected = digest(path), str(item.get('sha256', '')).lower()
    if actual != expected:
        print(f'note: runtime {path} is {actual[:12]}..., pinned {expected[:12]}...; recorded, not used by a build', file=sys.stderr)
    return {'path': str(path), 'sha256': actual, 'pinned_sha256': expected, 'pin_matches': actual == expected}


def prepare(config, strict_runtime=True):
    original = pin(config['original'])
    exe = pin(config['prepared'], True)
    if original['path'] == exe['path']:
        raise ValueError('original and prepared must be separate files')
    runtime = pin_runtime(config['runtime'], strict_runtime)
    if ('exe' in config) == ('exe_base' in config):
        raise ValueError('give exactly one of exe_base and exe')
    block = config.get('exe') or {'base': config['exe_base']}
    unknown = set(block) - {'base', 'part_mb', 'splits', 'roots'}
    if unknown:
        raise ValueError('unknown exe keys: ' + ', '.join(sorted(unknown)))
    modules = [dict(exe, base=base(block['base']), part_mb=part_mb(block.get('part_mb')),
                    splits=pin(block['splits'], True) if block.get('splits') else None,
                    roots=pin(block['roots'], True) if block.get('roots') else None)]
    modules += [dict(pin(item, True), base=base(item['base']), part_mb=None, splits=None, roots=None)
                for item in config['dlls']]
    if len({Path(m['path']).name.lower() for m in modules}) != len(modules):
        raise ValueError('module basenames must be unique')
    if len({m['base'] for m in modules}) != len(modules):
        raise ValueError('module bases must be distinct; overlap requires separate review')
    for module in modules:
        module['pe'] = pe_layout(module['path'])
        for kind in ('splits', 'roots'):
            if module[kind]:
                text, used, outside = shifted(module[kind], module)
                module[kind].update(shifted_sha256=hashlib.sha256(text.encode()).hexdigest(), used=used,
                                    outside_image=outside)
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
            'compiler': compiler_config(config),
            'asset_root': directory(config['asset_root']), 'dll_roots': [directory(p) for p in config['dll_roots']],
            'jobs': jobs, 'owned_gate': gate}


def key_for(module, ctx):
    """ctx: source, compiler {sha256, source_commit}, toolchain, jobs."""
    data = {'sha256': module['sha256'], 'name': Path(module['path']).name,
            'base': module['base'], 'part_mb': module.get('part_mb'),
            'splits': module['splits'] and {k: module['splits'][k] for k in ('sha256', 'shifted_sha256')},
            'roots': module['roots'] and {k: module['roots'][k] for k in ('sha256', 'shifted_sha256')},
            'source': ctx['source'], 'compiler_sha256': ctx['compiler']['sha256'],
            'compiler_source_commit': ctx['compiler']['source_commit'], 'toolchain': ctx['toolchain'],
            'builder': BUILDER, 'jobs': ctx['jobs'], 'target': 'macos-arm64'}
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


def module_env(module, work):
    """The compiler's environment: nothing inherited from VXRT_AOT_*, then this module's settings."""
    env = {k: v for k, v in os.environ.items() if not k.startswith('VXRT_AOT_') and k != 'AOT_JOBS'}
    env['VXRT_AOT_BASE'] = module['base']
    if module['part_mb'] is not None:
        env['VXRT_AOT_PART_MB'] = ('%d' % module['part_mb']) if module['part_mb'] == int(module['part_mb']) else repr(module['part_mb'])
    for kind, var in (('splits', 'VXRT_AOT_SPLITS'), ('roots', 'VXRT_AOT_ROOTS')):
        if module[kind]:
            (work/(kind + '.txt')).write_text(shifted(module[kind], module)[0])
            env[var] = str(work/(kind + '.txt'))
    return env


def compile_module(module, compiler, jobs, work, log):
    """vxrt-aot gen into work/s, then each part assembled and linked (cwd work) to work/dylibs/<stem>[.p<k>].dylib."""
    (work/'s').mkdir(); (work/'dylibs').mkdir()
    env = module_env(module, work)
    commands = []
    name = subprocess.run([compiler, 'name', module['path']], capture_output=True, env=env)
    stem = name.stdout.decode().strip()
    log.write(name.stderr)
    if name.returncode or not re.fullmatch(r'[A-Za-z0-9_.+-]+\.dylib', stem):
        raise ValueError('vxrt-aot name failed for ' + module['path'])
    stem = stem[:-len('.dylib')]
    gen = [compiler, 'gen', module['path'], str(work/'s/S.s')]
    commands.append(gen)
    with (work/'S.list').open('wb') as listing:
        log.flush()
        p = subprocess.run(gen, cwd=work, env=env, stdout=listing, stderr=log)
    if p.returncode:
        raise ValueError('vxrt-aot gen failed (%d)' % p.returncode)
    parts = []
    for line in (work/'S.list').read_text().split():
        s = Path(line)
        if s.parent != work/'s' or not re.fullmatch(r'S(\.p\d+)?\.s', s.name):
            raise ValueError('unexpected vxrt-aot output: ' + line)
        k = re.fullmatch(r'S\.p(\d+)\.s', s.name)
        parts.append((s, 'dylibs/%s%s.dylib' % (stem, '.p' + k.group(1) if k else '')))
    if not parts:
        raise ValueError('vxrt-aot listed no output')
    def link(part):
        s, dylib = part
        obj = s.with_suffix('.o')
        steps = [['clang', '-arch', 'arm64', '-c', '-o', str(obj), str(s)],
                 ['clang', '-arch', 'arm64', '-dynamiclib', '-o', dylib, str(obj)]]
        for cmd in steps:
            r = subprocess.run(cmd, cwd=work, capture_output=True)
            if r.returncode:
                return cmd, r.returncode, r.stdout + r.stderr
        return steps, 0, b''
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(link, parts))
    for cmd, code, output in results:
        log.write(output)
        if code:
            raise ValueError('assemble/link failed (%d): %s' % (code, ' '.join(cmd)))
        commands.extend(cmd)
    shutil.rmtree(work/'s')
    return commands, env


def build_module(module, ctx, cache, out):
    key, inputs = key_for(module, ctx)
    dest = cache / key
    if dest.exists():
        if not valid_cache(dest, key):
            raise ValueError('invalid cached module: ' + str(dest))
        return dest, {'key': key, 'cached': True}
    tmp = Path(tempfile.mkdtemp(prefix='.building-', dir=cache))
    try:
        work = tmp/'work'; work.mkdir()
        log = out / (key + '.build.log')
        commands, env, error = [], {}, None
        with log.open('wb') as f:
            try:
                commands, env = compile_module(module, ctx['compiler']['path'], ctx['jobs'], work, f)
            except (OSError, ValueError, subprocess.SubprocessError) as e:
                error = str(e)
        artifacts = {}
        if not error:
            for p in sorted((work/'dylibs').glob('*.dylib')):
                if p.is_file() and not p.is_symlink():
                    p.rename(tmp/p.name); artifacts[p.name] = digest(tmp/p.name)
            for name in ('splits.txt', 'roots.txt', 'S.list'):
                if (work/name).exists():
                    (work/name).rename(tmp/name)
        recorded = {k: v for k, v in env.items() if k.startswith('VXRT_AOT_')}
        result = {'key': key, 'cached': False, 'commands': commands, 'environment': recorded,
                  'returncode': 1 if error else 0, 'error': error, 'log': str(log), 'log_sha256': digest(log),
                  'artifacts': artifacts, 'inputs': inputs}
        (out / (key + '.build.json')).write_text(json.dumps(result, indent=2) + '\n')
        if error or not artifacts:
            raise ValueError('module build failed or produced no dylibs (%s); see %s' % (error, log))
        pinned = [(module['path'], module['sha256']), (ctx['compiler']['path'], ctx['compiler']['sha256'])]
        pinned += [(module[k]['path'], module[k]['sha256']) for k in ('splits', 'roots') if module[k]]
        if any(digest(p) != h for p, h in pinned) or toolchain() != ctx['toolchain'] or source_identity() != ctx['source']:
            raise ValueError('input or build source changed during build')
        shutil.rmtree(work)
        (tmp / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n')
        for p in tmp.iterdir():
            p.chmod(0o444)
        tmp.chmod(0o555)
        tmp.rename(dest)
        return dest, result
    finally:
        if tmp.exists():
            tmp.chmod(0o755)
            shutil.rmtree(tmp)


def classify(result):
    if result.get('status') != 'observed':
        return {'category': 'precondition', 'evidence': result.get('preconditions', [])}
    facts = {o['metric']: o['value'] for o in result.get('observed', [])}
    if facts.get('xrizer_bridge_stops'):
        return {'category': 'unsupported_xrizer_bridge_slot', 'evidence': facts['xrizer_bridge_stops'],
                'aot_summaries': facts.get('aot_summaries', [])}
    if facts.get('xrizer_panics'):
        return {'category': 'xrizer_panic', 'evidence': facts['xrizer_panics'],
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


def run(config, out, build=False, probe=False, cache=None):
    if probe and not build:
        raise ValueError('--probe requires --build')
    out = Path(out).resolve()
    root = private_root()
    if out == REPO or out == root or not out.is_relative_to(root) or out.exists():
        raise ValueError('output must be a new checkout-local directory')
    cache = Path(cache).resolve() if cache else CACHE
    if not cache.is_relative_to(root):
        raise ValueError('cache must be inside the checkout')
    cfg = prepare(config, strict_runtime=probe)
    if probe and not cfg['owned_gate']:
        raise ValueError('--probe requires an explicit owned_gate command')
    compiler = dict(cfg['compiler'])
    if compiler['sha256'] is None:
        compiler['sha256'] = digest(compiler['path'])
    ctx = {'source': source_identity(), 'compiler': compiler, 'toolchain': toolchain(), 'jobs': cfg['jobs']}
    out.mkdir(parents=True, mode=0o700)
    result = {'subject': 'private prepared-input AOT; no game or VR compatibility claim', 'status': 'planned',
              'config': cfg, 'source': ctx['source'], 'compiler': compiler, 'toolchain': ctx['toolchain'],
              'builder': BUILDER, 'cache': str(cache), 'target': 'macos-arm64', 'modules': [],
              'unknown': ['prepared image provenance and semantic completeness', 'runtime code coverage', 'physical headset and playability']}
    def save():
        (out/'result.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    save()
    if not build:
        result['modules'] = [dict(key=key_for(m, ctx)[0], input=m) for m in cfg['modules']]
        save(); return result
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        with (cache/'build.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            dirs = []
            for m in cfg['modules']:
                dest, evidence = build_module(m, ctx, cache, out)
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
            prepare(config, strict_runtime=True)
            if source_identity() != ctx['source'] or digest(compiler['path']) != compiler['sha256']:
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
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--config', required=True); parser.add_argument('--out', required=True)
    parser.add_argument('--cache', help='module cache directory inside the checkout (default build/private/skyrim-aot-cache)')
    parser.add_argument('--build', action='store_true'); parser.add_argument('--probe', action='store_true')
    args = parser.parse_args()
    try:
        result = run(json.loads(Path(args.config).read_text()), args.out, args.build, args.probe, args.cache)
        print(json.dumps(result, indent=2)); return 0
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as e:
        print('pipeline: ' + str(e), file=sys.stderr); return 1


if __name__ == '__main__':
    sys.exit(main())
