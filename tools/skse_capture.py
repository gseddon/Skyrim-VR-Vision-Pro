#!/usr/bin/env python3
"""skse_capture.py: make the private SKSE VR files for a mod pack, on this Mac (the `skse-capture` stage of tools/vxrt_build.py).

SKSE VR patches the game's code while it starts. The standalone headset cannot generate or patch code, so the patches are captured once on
the Mac and compiled into the game's modules ahead of time (research/2026-11-11-skse-vr-on-aot.md, sections 4 to 5c). What this does, for the
SKSE plugins of one pack (PACK/mods.json from tools/mods.py):

  1. a module set at the headset's addresses (the visionOS pipeline's bases, run on the Mac at the same arena; tools/skse_device_config.py)
  2. EARLY capture: the game is started up to its entry point only (VXRT_PRELOAD_EXIT): SKSE and every plugin write their patches
  3. modules rebuilt with those patches (the stub module vxrt_hooks.dll is made from the capture: tools/skse_hooks_pe.py)
  4. LATE capture: the game runs for about two minutes with those modules (not strict) and the capture is taken at 100 s, so patches a
     plugin makes after the main menu (VRIK's) are in it too
  5. modules rebuilt with the late capture
  6. strict VERIFY run: no fallback to the translator allowed, the code in memory must equal the capture (VXRT_CODE_VERIFY), a late write
     outside the capture stops the run (VXRT_CODE_WATCH), and every plugin must load
  7. the same module set for the headset (--target xros)  -> <private>/game_fw-xros-skse
  8. PACK/overlay_root gets vxrt_hooks.dll and skse_capture.txt (tools/mods.py deploy copies them to the headset)

The result is valid for exactly one plugin set (the core DLL and every file under Data/SKSE/Plugins, tools/mods.py skse_plugin_set); it is
recorded in <private>/skse-capture/state.json and a finished stage is skipped while the set is unchanged. The game runs on the Mac
(steps 2, 4 and 6; about 5 minutes in all); it refuses to start while another Skyrim run is active and waits instead.

  python3 -I tools/skse_capture.py run    --pack PACK [--force] [--late-seconds 100] [--verify-seconds 200] [--wait SECONDS]
  python3 -I tools/skse_capture.py status --pack PACK          prints done / stale / missing

Exit 0 done, 2 an input is missing (the message says what and which stage makes it), 1 failed. Subject of the verdicts: the actual game on the Mac
(development host, strict AOT); not a headset result.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mods
import skyrim_aot_pipeline as P
import vxrt_env as E

REPO = E.REPO
TEMPLATE = REPO / 'tools' / 'skyrim_aot_skyrimvr.json'
CORE_NAME, HOOKS_NAME, CAPTURE_NAME = 'sksevr_1_4_15.dll', 'vxrt_hooks.dll', 'skse_capture.txt'
HOOKS_SIZE = '0x100000'
# the prepared exe is pinned (E.PREPARED_EXE_SHA256): its preferred base and the window in which values count as pointers into it
EXE_PREFERRED, EXE_WINDOW = '0x140000000', '0x3a00000'
ARENA, ARENA_MB = '7000000000', '1024'       # the visionOS arena (Makefile XROS_ARENA), used by the Mac run too
OK, FAIL, MISSING = 0, 1, 2


class NeedInput(Exception):
    pass


class Failed(Exception):
    pass


def say(msg):
    print('skse-capture: ' + msg, file=sys.stderr, flush=True)


def sha(path):
    return E.sha256_file(path)


def run(cmd, log=None, **kw):
    """Run a command, its output to log (a path) or stderr; returns the exit code."""
    say('+ ' + ' '.join(str(c) for c in cmd))
    cmd = [str(c) for c in cmd]
    if log:
        with open(log, 'wb') as f:
            return subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, **kw).returncode
    return subprocess.run(cmd, stdout=sys.stderr, **kw).returncode


# --- the pack ------------------------------------------------------------------------------------------------------------

def load_pack(pack):
    pack = Path(pack).resolve()
    mj = pack / 'mods.json'
    if not mj.is_file():
        raise NeedInput('no mod pack at %s (made by: tools/vxrt_build.py mods)' % pack)
    doc = json.loads(mj.read_text())
    plugins = [e for e in doc.get('skse_plugins', [])]
    dlls = [e for e in plugins if e['dll']]
    core = pack / 'overlay_root' / CORE_NAME
    if not dlls:
        raise NeedInput('the pack has no SKSE plugin DLLs: nothing to capture (SKSE plugins are the kind "skse" mods of the list)')
    if not core.is_file():
        raise NeedInput('the pack has no SKSE VR core DLL (%s): the list needs the skse-core entry, fetched by: tools/vxrt_build.py mods-fetch, then mods --force' % core)
    return pack, doc, dlls, core


def plugin_set(doc, core):
    return mods.skse_plugin_set(doc['skse_plugins'], sha(core))


def work_dir():
    return E.private_root() / 'skse-capture'


def read_state():
    try:
        return json.loads((work_dir() / 'state.json').read_text())
    except (OSError, ValueError):
        return {}


def status(pack):
    """done / stale (made for another plugin set) / missing (never made) / n/a (the pack has no SKSE plugins)."""
    try:
        _, doc, _, core = load_pack(pack)
    except NeedInput:
        return 'n/a'
    st = read_state()
    if not st.get('complete'):
        return 'missing'
    w = work_dir()
    if st.get('plugin_set') != plugin_set(doc, core):
        return 'stale'
    return 'done' if all((w / n).is_file() for n in (HOOKS_NAME, CAPTURE_NAME)) and Path(st.get('game_fw', '/nonexistent')).is_dir() else 'missing'


# --- configs and modules -----------------------------------------------------------------------------------------------

def pin(path):
    return {'path': str(path), 'sha256': sha(path)}


def hex_(n):
    return '0x%x' % n


def base_config(pack, dlls, core, hooks):
    """tools/skyrim_aot_skyrimvr.json expanded, plus the SKSE core, the stub module and the pack's plugin DLLs (placeholder bases: the pipeline's
    visionOS layout ignores them and tools/skse_device_config.py reads the real ones)."""
    c = P.expand_config(json.loads(TEMPLATE.read_text()))
    c.pop('_note', None)
    nxt = 0x30a000000
    extra = [dict(path=str(core), sha256=sha(core)), dict(path=str(hooks), sha256=sha(hooks))]
    for e in dlls:
        p = pack / 'merged' / 'Data' / e['path']
        if sha(p) != e['sha256']:
            raise Failed('%s changed since the pack was built (rebuild the pack: tools/vxrt_build.py mods --force)' % p)
        extra.append(dict(path=str(p), sha256=e['sha256'], **(e.get('aot') or {})))
    for d in extra:
        d['base'] = hex_(nxt)
        nxt += 0x1000000
    c['dlls'] += extra
    return c


def device_config(cfg_path, out_path):
    """The same module set with the bases the visionOS pipeline gives it (a Mac build of it, run in the same arena, maps every image where the headset will)."""
    r = subprocess.run([sys.executable, '-I', str(REPO / 'tools' / 'skse_device_config.py'), str(cfg_path), str(out_path)], capture_output=True, text=True)
    if r.returncode:
        raise Failed('skse_device_config.py failed: %s' % (r.stderr or r.stdout)[-600:])
    return json.loads(Path(out_path).read_text())


def build_hooks(cfg, out, capture=None, tag=None, w=None):
    """vxrt_hooks.dll at its device base, from the capture (zero section without one); writes the stub roots and the roots in the exe."""
    hk = next(d for d in cfg['dlls'] if Path(d['path']).name == HOOKS_NAME)
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    eb = cfg['exe']['base']
    cmd = [sys.executable, '-I', REPO / 'tools' / 'skse_hooks_pe.py', '--base', hk['base'], '--size', HOOKS_SIZE, '--out', out]
    roots = exe_roots = None
    if capture:
        roots, exe_roots = w / ('roots-%s.txt' % tag), w / ('exe-roots-%s.txt' % tag)
        cmd += ['--capture', capture, '--image', 'SkyrimVR.exe=' + eb, '--roots', roots, '--exe-roots', exe_roots,
                '--exe-base', eb, '--exe-preferred', EXE_PREFERRED, '--exe-size', EXE_WINDOW]
    if run(cmd):
        raise Failed('skse_hooks_pe.py failed')
    return roots, exe_roots


def apply_capture(cfg, hooks, capture, roots, exe_roots):
    """Pin the stub module, the capture's patches and the roots into the config (a root file that is empty is left out)."""
    for d in cfg['dlls']:
        if Path(d['path']).name == HOOKS_NAME:
            d['path'], d['sha256'] = str(hooks), sha(hooks)
            d['roots'] = pin(roots) if roots and Path(roots).stat().st_size else None
    cfg['exe']['roots'] = pin(exe_roots) if exe_roots and Path(exe_roots).stat().st_size else None
    cfg['exe']['patches'] = pin(capture) if capture else None
    if not capture:
        cfg['exe'].pop('patches', None)
    if not cfg['exe'].get('roots'):
        cfg['exe']['roots'] = None


def build_modules(cfg_path, out, target=None, log=None):
    cmd = [sys.executable, REPO / 'tools' / 'skyrim_aot_pipeline.py', '--config', cfg_path, '--build', '--out', out]
    if target:
        cmd += ['--target', target]
    if run(cmd, log=log):
        raise Failed('the AOT pipeline failed (%s)' % (log or 'see above'))


# --- running the game ----------------------------------------------------------------------------------------------------

def wait_free(own, wait):
    """Refuse to start while the user's own session runs (or anything the harness cannot prove is isolated): wait for it, never touch it.
    Other isolated harness runs (their own roots, overlays and saves) may run at the same time; they only load the machine, which matters
    for the late capture's time-based point (the run reports the load it saw)."""
    deadline = time.time() + wait
    said = False
    while True:
        r = subprocess.run([sys.executable, REPO / 'tools' / 'vxrt_runtime_sessions.py', '--own', str(own), '--json'], capture_output=True, text=True)
        if r.returncode == 0:
            try:
                other = [x.get('run') or x.get('root') for x in json.loads(r.stdout).get('concurrent_runtime', [])]
            except ValueError:
                other = []
            if other:
                say('note: isolated runtime sessions are running at the same time (%s); the machine is loaded' % ', '.join(str(o) for o in other))
            return other
        if time.time() > deadline:
            raise NeedInput('a session that is not an isolated harness run is still active after %d s: %s' % (wait, r.stderr.strip()[:200] or r.stdout[:200]))
        if not said:
            say('another session (not an isolated harness run) is active; waiting for it to end (not touching it)')
            said = True
        time.sleep(15)


def dll_path(cfg):
    inp = Path(cfg['dlls'][0]['path']).parent
    return ':'.join([str(inp)] + [str(x) for x in cfg.get('dll_roots', [])])


def early_run(cfg, modules, pack, w, out_capture, wait):
    """Start the game up to its entry point only: SKSE and the plugins write their patches, the runtime snapshots them (VXRT_CODE_CAPTURE)."""
    rt = REPO / 'VXRuntime' / 'build' / 'vxrt-arm64'
    hooks = next(d['path'] for d in cfg['dlls'] if Path(d['path']).name == HOOKS_NAME)
    core = next(d['path'] for d in cfg['dlls'] if Path(d['path']).name == CORE_NAME)
    prepared = Path(E.variables()['VXRT_PREPARED_EXE'])
    run_dir = w / 'run-early'
    wait_free(run_dir, wait)
    if run_dir.exists():
        shutil.rmtree(run_dir)
    (run_dir / 'exe' / 'Data').mkdir(parents=True)
    shutil.copy(prepared, run_dir / 'exe' / 'SkyrimVR.exe')
    subprocess.run(['cp', '-cR', str(pack / 'merged' / 'Data' / 'SKSE'), str(run_dir / 'exe' / 'Data' / 'SKSE')], check=True)
    env = dict(HOME=os.environ['HOME'], PATH=os.environ['PATH'], VXRT_ROOT=str(run_dir / 'root'), VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0',
               VXRT_NO_ACTIVATE='1', VXRT_MUTE='1', VXRT_DLL_PATH=dll_path(cfg), VXRT_AOT_DIR=str(modules),
               VXRT_AOT_ARENA=ARENA, VXRT_AOT_ARENA_MB=ARENA_MB, VXRT_PRELOAD='%s;%s' % (hooks, core), VXRT_EXEC_REGION=HOOKS_NAME,
               VXRT_PRELOAD_AT='telemetry', VXRT_CODE_CAPTURE=str(out_capture), VXRT_PRELOAD_EXIT='1')
    log = run_dir / 'out.log'
    say('early capture: the game starts up to its entry point (about a minute)')
    r = subprocess.run(['/usr/bin/arch', '-arm64', str(rt), str(run_dir / 'exe' / 'SkyrimVR.exe')], cwd=run_dir / 'exe', env=env,
                       stdout=open(log, 'wb'), stderr=subprocess.STDOUT)
    text = log.read_text(errors='replace')
    m = re.search(r'codehooks: capture \S+: (\d+) code runs \((\d+) bytes\) in loaded images, (\d+) bytes of region', text)
    if r.returncode != 0 or not m or not Path(out_capture).is_file():
        raise Failed('the early capture run failed (exit %s): see %s' % (r.returncode, log))
    for bad in re.findall(r'.*(?:unimplemented|missing import|preload failed).*', text)[:3]:
        say('warning in the early run: ' + bad.strip()[:200])
    return int(m.group(1)), int(m.group(3)), log


def harness_run(modules, pack, cfg, hooks_hint, seconds, hooks, wait, code_hooks, label):
    """Run the game through tools/play_skyrim_dev.sh (xrizer dev host, scripted pad input that leaves the intro) with SKSE preloaded."""
    core = next(d['path'] for d in cfg['dlls'] if Path(d['path']).name == CORE_NAME)
    wait_free(work_dir() / ('run-' + label), wait)
    args = ['--no-build', '--mute', '--seconds', str(seconds), '--',
            '--overlay-ini', 'Skyrim.ini:General:sIntroSequence=', '--diag-env', 'VXRT_TRACE_FILES=1',
            '--overlay-ini', 'Skyrim.ini:Papyrus:bEnableLogging=1', '--overlay-ini', 'Skyrim.ini:Papyrus:bEnableTrace=1',
            '--overlay-ini', 'Skyrim.ini:Papyrus:bLoadDebugInformation=1',
            '--xinput-repeat', 'A@6-%d/2:0.3' % max(10, int(seconds) - 30),
            '--code-hook', 'VXRT_PRELOAD=%s;%s' % (hooks, core), '--code-hook', 'VXRT_EXEC_REGION=' + HOOKS_NAME,
            '--code-hook', 'VXRT_PRELOAD_AT=telemetry', '--code-hook', 'VXRT_AOT_ARENA=' + ARENA, '--code-hook', 'VXRT_AOT_ARENA_MB=' + ARENA_MB,
            '--mods-config', pack / 'mods.json']
    for h in code_hooks:
        args += ['--code-hook', h]
    env = dict(os.environ, SKYRIM_AOT_DIR=str(modules))
    log = work_dir() / ('run-%s.log' % label)
    say('%s run: the game runs for %d s on the Mac' % (label, seconds))
    r = subprocess.run([str(REPO / 'tools' / 'play_skyrim_dev.sh')] + [str(a) for a in args], env=env, stdout=open(log, 'wb'), stderr=subprocess.STDOUT)
    text = log.read_text(errors='replace')
    m = re.search(r'output and evidence: (\S+)', text)
    if not m:
        raise Failed('the %s run did not start (exit %s): see %s' % (label, r.returncode, log))
    out = Path(m.group(1))
    if not (out / 'startup.log').is_file():
        raise Failed('the %s run left no startup.log (it was probably refused: %s)' % (label, log))
    return out, r.returncode


def read_run(out):
    """What the run's log says: verify line, capture line, last AOT counter line, late writes, SKSE plugin load lines."""
    text = (out / 'startup.log').read_text(errors='replace')
    info = {'dir': str(out)}
    m = re.findall(r'codehooks: verify (\S+): (\d+) entries, (\d+) differ', text)
    info['verify'] = {'entries': int(m[-1][1]), 'differ': int(m[-1][2])} if m else None
    if not m and re.search(r'codehooks: watching \d+ executable sections', text):
        # with the watcher the runtime does the preload check inside it and logs no count: a mismatch stops the run with this message instead
        mism = len(re.findall(r'codehooks: verify: .* differs from the capture|VXRT_CODE_VERIFY: the code in memory', text))
        info['verify'] = {'entries': None, 'differ': mism, 'by': 'watcher'}
    m = re.findall(r'codehooks: capture (\S+): (\d+) code runs \((\d+) bytes\)', text)
    info['capture_runs'] = int(m[-1][1]) if m else None
    m = re.findall(r'aot: (\d+) entries into recompiled code.*?(\d+) fallbacks to the translator', text)
    info['aot'] = {'entries': int(m[-1][0]), 'fallbacks': int(m[-1][1])} if m else None
    info['late_writes'] = len(re.findall(r'LATE CODE WRITE', text))
    info['stopped'] = [l.strip()[:200] for l in re.findall(r'.*(?:VXRT_AOT_STRICT: stopping|code in memory is not the capture|no recompiled code).*', text)[:3]]
    info['watching'] = bool(re.search(r'codehooks: watching \d+ executable sections', text))
    logs = list(out.rglob('sksevr.log'))
    loaded = []
    if logs:
        for l in logs[0].read_text(errors='replace').splitlines():
            m = re.search(r'plugin (\S.*?\.dll) .*loaded correctly', l, re.I)
            if m:
                loaded.append(Path(m.group(1).replace('\\', '/')).name.lower())
    info['plugins_loaded'] = sorted(set(loaded))
    info['esp_not_active'] = any('is not active' in p.read_text(errors='replace') for p in out.rglob('*.log') if p.name != 'startup.log' and p.stat().st_size < 20e6)
    ts = re.findall(r'\[vxrt\] (\d\d):(\d\d):(\d\d)\.', text)
    if ts:
        t = lambda x: int(x[0]) * 3600 + int(x[1]) * 60 + int(x[2])
        info['seconds'] = (t(ts[-1]) - t(ts[0])) % 86400
    return info


# --- the stage -------------------------------------------------------------------------------------------------------

def make_step(w, name, fn, force, ps):
    """Run fn() once per plugin set: its JSON result is kept in w/<name>.done and reused on a re-run (a failed stage resumes where it stopped)."""
    mark = w / (name + '.done')
    if not force and mark.is_file():
        d = json.loads(mark.read_text())
        if d.get('plugin_set') == ps and d.get('ok_files_exist', True):
            say('%s: done already for this plugin set' % name)
            return d
    d = fn() or {}
    d['plugin_set'] = ps
    mark.write_text(json.dumps(d, indent=1))
    return d


def stage(a):
    pack, doc, dlls, core = load_pack(a.pack)
    ps = plugin_set(doc, core)
    w = work_dir()
    st = read_state()
    if status(pack) == 'done' and not a.force:
        say('done already for this plugin set (%s); --force to redo' % ps[:12])
        finalize(pack, doc, w)
        return st
    for exe in ('vxrt-arm64', 'vxrt-aot'):
        if not (REPO / 'VXRuntime' / 'build' / exe).is_file():
            raise NeedInput('%s is not built (made by: make -C VXRuntime build/vxrt-aot build/vxrt-arm64)' % exe)
    prepared = Path(E.variables()['VXRT_PREPARED_EXE'])
    if not prepared.is_file() or sha(prepared) != E.PREPARED_EXE_SHA256:
        raise NeedInput('the prepared SkyrimVR.exe is missing or not the pinned one: %s (made by: tools/vxrt_build.py prepare)' % prepared)
    if not (REPO / 'VXRuntime' / 'build' / 'play-host' / 'vxrt-arm64').is_file():
        say('building the dev-host runtime for the Mac runs (tools/play_skyrim_dev.sh --build-only; needs the Rust toolchain: vxrt_build.py toolchain)')
        if run([REPO / 'tools' / 'play_skyrim_dev.sh', '--build-only'], env=dict(os.environ, SKYRIM_AOT_DIR=str(E.private_root()))):   # (the script wants a module dir to exist even to build)
            raise NeedInput('tools/play_skyrim_dev.sh --build-only failed (toolchain, SKYRIM_ASSET_ROOT, STEAMVR_WIN64_DLLS?)')
    if a.force and w.is_dir():
        for p in w.glob('*.done'):
            p.unlink()
    w.mkdir(parents=True, exist_ok=True)
    tmp = w / 'work'
    tmp.mkdir(exist_ok=True)
    st_run = {'plugin_set': ps, 'complete': False, 'started': time.strftime('%Y-%m-%dT%H:%M:%S'), 'plugins': [e['path'] for e in dlls]}
    (w / 'state.json').write_text(json.dumps(st_run, indent=1))

    # 1. configs: the empty-capture module set at the device bases
    hooks0 = tmp / 'hk0' / HOOKS_NAME
    cfg0 = base_config(pack, dlls, core, hooks0 if hooks0.is_file() else _placeholder_hooks(tmp, hooks0))
    (tmp / 'config-order.json').write_text(json.dumps(cfg0, indent=1))
    cfg = device_config(tmp / 'config-order.json', tmp / 'config-dev.json')
    say('bases: ' + ', '.join('%s %s' % (Path(d['path']).name, d['base']) for d in cfg['dlls'][6:]))

    def mac_build(tag, hooks, capture, roots, exe_roots):
        c = json.loads(json.dumps(cfg))
        apply_capture(c, hooks, capture, roots, exe_roots)
        path = tmp / ('config-%s.json' % tag)
        path.write_text(json.dumps(c, indent=1))
        out = w / ('mac-' + tag)
        if out.exists():
            shutil.rmtree(out)
        build_modules(path, out, log=w / ('pipeline-%s.log' % tag))
        return c, path, out / 'modules'

    def stepfn(name, fn):
        return make_step(w, name, fn, a.force, ps)

    # 2. the module set with an empty capture (zero stub module)
    def s_empty():
        build_hooks(cfg, hooks0, None)
        empty = tmp / 'cap-empty.txt'
        empty.write_text('')
        c, path, mod = mac_build('empty', hooks0, None, None, None)
        return {'modules': str(mod)}
    e0 = stepfn('modules-empty', s_empty)
    # 3. early capture
    cap_early = w / 'cap-early.txt'

    def s_early():
        runs, region, log = early_run(cfg, Path(e0['modules']), pack, w, cap_early, a.wait)
        return {'runs': runs, 'region_bytes': region, 'capture_sha256': sha(cap_early), 'log': str(log)}
    ce = stepfn('early-capture', s_early)
    say('early capture: %d code runs, %d bytes of region' % (ce['runs'], ce['region_bytes']))
    hooks1 = tmp / 'hk1' / HOOKS_NAME

    def s_mod1():
        roots, exe_roots = build_hooks(cfg, hooks1, cap_early, 'early', w)
        c, path, mod = mac_build('early', hooks1, cap_early, roots, exe_roots)
        return {'modules': str(mod)}
    m1 = stepfn('modules-early', s_mod1)
    # 4. late capture (not strict: the early modules lack the late patches)
    cap_late = w / 'cap-late.txt'

    def s_late():
        out, rc = harness_run(Path(m1['modules']), pack, cfg, None, a.late_seconds + 25, hooks1, a.wait,
                              ['VXRT_AOT_STRICT=0', 'VXRT_CODE_WATCH=1000', 'VXRT_CODE_CAPTURE=%s' % cap_late, 'VXRT_CODE_CAPTURE_AT=%d' % a.late_seconds], 'late')
        info = read_run(out)
        if not cap_late.is_file() or not info['capture_runs']:
            raise Failed('the late capture was not written (run %s, exit %s)' % (out, rc))
        info.update(runs=info['capture_runs'], capture_sha256=sha(cap_late))
        return info
    cl = stepfn('late-capture', s_late)
    say('late capture: %d code runs (early: %d)' % (cl['runs'], ce['runs']))
    hooks2 = tmp / 'hk2' / HOOKS_NAME

    def s_mod2():
        roots, exe_roots = build_hooks(cfg, hooks2, cap_late, 'late', w)
        c, path, mod = mac_build('late', hooks2, cap_late, roots, exe_roots)
        return {'modules': str(mod), 'config': str(path)}
    m2 = stepfn('modules-late', s_mod2)
    # 5. strict verify run
    def s_verify():
        out, rc = harness_run(Path(m2['modules']), pack, cfg, None, a.verify_seconds, hooks2, a.wait,
                              ['VXRT_CODE_WATCH=1000', 'VXRT_CODE_VERIFY=%s' % cap_late], 'verify')
        info = read_run(out)
        expect = sorted(Path(d['path']).name.lower() for d in cfg['dlls'] if d['path'].startswith(str(pack / 'merged')))
        problems = []
        if not info['verify'] or info['verify']['differ'] != 0 or (not info['verify']['entries'] and info['verify'].get('by') != 'watcher'):
            problems.append('verify did not pass: %s' % info['verify'])
        if not info['aot'] or info['aot']['fallbacks'] != 0 or not info['aot']['entries']:
            problems.append('AOT counters: %s (need entries > 0 and 0 fallbacks; missing counters are a failure)' % info['aot'])
        if info['late_writes'] or info['stopped']:
            problems.append('late writes %d, stops %s' % (info['late_writes'], info['stopped']))
        if not info['watching']:
            problems.append('the late-write watcher was not running')
        missing = [n for n in expect if n not in info['plugins_loaded']]
        if missing:
            problems.append('plugins not loaded by SKSE: %s (loaded: %s)' % (missing, info['plugins_loaded']))
        if info['esp_not_active']:
            problems.append('a plugin reports its ESP is not active')
        if (info.get('seconds') or 0) < min(60, a.verify_seconds * 0.5):
            problems.append('the run lasted only %ss' % info.get('seconds'))
        info['expected_plugins'] = expect
        info['ok'] = not problems
        if problems:
            raise Failed('strict verify run %s failed: %s' % (out, '; '.join(problems)))
        return info
    vr = stepfn('strict-verify', s_verify)
    say('strict verify: %s entries, %s fallbacks, verify %s (%s differ), %d plugins loaded' % (
        vr['aot']['entries'], vr['aot']['fallbacks'], 'ok' if not vr['verify']['differ'] else 'FAILED', vr['verify']['differ'], len(vr['plugins_loaded'])))

    # 6. the modules for the headset, from the same config
    def s_xros():
        c = json.loads(Path(m2['config']).read_text())
        link = E.private_root() / 'game_fw-xros-skse'
        out = E.private_root() / 'skyrimvr' / E.ORIGINAL_EXE_SHA256 / ('aot-xros-skse-' + time.strftime('%Y%m%d-%H%M%S'))
        build_modules(m2['config'], out, target='xros', log=w / 'pipeline-xros.log')
        fw = out / 'game_fw'
        bases = dict(l.split() for l in (fw / 'bases.txt').read_text().splitlines() if l.strip())
        want = {Path(d['path']).name.lower(): d['base'] for d in c['dlls']}
        want['skyrimvr.exe'] = c['exe']['base']
        diff = [(k, v, bases.get(k)) for k, v in want.items() if {kk.lower(): vv for kk, vv in bases.items()}.get(k) != v]
        if diff:
            raise Failed('the visionOS module bases differ from the Mac run bases (the capture would not hold): %s' % diff[:4])
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(fw)
        return {'game_fw': str(fw), 'link': str(link), 'bases_match_mac': True}
    xr = stepfn('xros-modules', s_xros)

    shutil.copyfile(hooks2, w / HOOKS_NAME)
    shutil.copyfile(cap_late, w / CAPTURE_NAME)
    st_run.update(complete=True, finished=time.strftime('%Y-%m-%dT%H:%M:%S'), early_runs=ce['runs'], late_runs=cl['runs'],
                  capture_sha256=sha(w / CAPTURE_NAME), hooks_sha256=sha(w / HOOKS_NAME), verify=vr, game_fw=xr['game_fw'], game_fw_link=xr['link'],
                  mac_modules=m2['modules'], core_sha256=sha(core))
    (w / 'state.json').write_text(json.dumps(st_run, indent=1))
    finalize(pack, doc, w)
    for tag in ('empty', 'early'):                      # (the intermediate module sets are not needed any more)
        shutil.rmtree(w / ('mac-' + tag), ignore_errors=True)
    return st_run


def _placeholder_hooks(tmp, path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([sys.executable, '-I', str(REPO / 'tools' / 'skse_hooks_pe.py'), '--base', '0x305800000', '--size', HOOKS_SIZE, '--out', str(path)], capture_output=True)
    if r.returncode:
        raise Failed('skse_hooks_pe.py failed')
    return path


def finalize(pack, doc, w):
    """Put the stub module and the capture into the pack's overlay_root (the app and `mods.py deploy` read them there)."""
    ov = pack / 'overlay_root'
    mj = pack / 'mods.json'
    d = json.loads(mj.read_text())
    files = [f for f in d.get('overlay_root_files', []) if f['name'] not in (HOOKS_NAME, CAPTURE_NAME)]
    for n in (HOOKS_NAME, CAPTURE_NAME):
        subprocess.run(['cp', '-c', str(w / n), str(ov / n)], check=True)
        files.append(dict(name=n, sha256=sha(ov / n), size=(ov / n).stat().st_size))
    d['overlay_root_files'] = files
    d['skse_capture'] = {k: read_state().get(k) for k in ('plugin_set', 'early_runs', 'late_runs', 'capture_sha256', 'hooks_sha256')}
    mj.write_text(json.dumps(d, indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('run')
    r.add_argument('--pack', required=True)
    r.add_argument('--force', action='store_true')
    r.add_argument('--late-seconds', type=int, default=100, help='when the late capture is taken after the preload (default 100: past the main menu)')
    r.add_argument('--verify-seconds', type=int, default=200)
    r.add_argument('--wait', type=int, default=3600, help='seconds to wait for another Skyrim run to end')
    s = sub.add_parser('status')
    s.add_argument('--pack', required=True)
    a = ap.parse_args()
    if a.cmd == 'status':
        print(status(a.pack))
        return OK
    try:
        stage(a)
    except NeedInput as e:
        print('skse-capture: ' + str(e), file=sys.stderr)
        return MISSING
    except Failed as e:
        print('skse-capture: FAILED: ' + str(e), file=sys.stderr)
        return FAIL
    return OK


if __name__ == '__main__':
    sys.exit(main())
