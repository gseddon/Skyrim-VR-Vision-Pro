#!/usr/bin/env python3
"""Check an owned guest bootstrap, real xrizer and synthetic offscreen Mac host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('runtime', 'exe', 'aot-dir', 'xrizer-dylib', 'out'):
        ap.add_argument('--' + name, required=True, type=Path)
    a = ap.parse_args()
    runtime, exe, modules, library = (p.resolve(strict=True) for p in (a.runtime, a.exe, a.aot_dir, a.xrizer_dylib))
    out = a.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    paths = [runtime, exe, library, *sorted(modules.glob('*.dylib'))]
    identity = {str(p): digest(p) for p in paths}
    (out/'identities.json').write_text(json.dumps(identity,indent=2)+'\n')
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_', 'XDG_'))}
    env.update(VXRT_ROOT=str(out/'root'), VXRT_AOT_DIR=str(modules), VXRT_AOT_STRICT='1', VXRT_NO_WINE='1',
               VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1', VXRT_XRIZER_OPENVR='1',
               VXRT_XRIZER_DYLIB=str(library), VXRT_XRIZER_DEV_AUDIT='1')
    for kind in ('STATE','CONFIG','CACHE','DATA'):
        path=out/'xdg'/kind.lower(); path.mkdir(parents=True,mode=0o700); env['XDG_'+kind+'_HOME']=str(path)
    command=['/usr/bin/arch','-arm64',str(runtime),str(exe)]
    timed_out=False
    with (out/'runtime.log').open('wb') as log:
        child=subprocess.Popen(command,cwd=exe.parent,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try: rc=child.wait(timeout=30)
        except subprocess.TimeoutExpired:
            timed_out=True; os.killpg(child.pid,signal.SIGKILL); rc=child.wait()
    log=(out/'runtime.log').read_text(errors='replace')
    summaries=re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator \((\d+) addresses\)',log)
    checks={'exit_zero':rc==0 and not timed_out,
        'guest_verdict':'xrizer_guest_devhost: real OpenVR exports / D3D11 stereo / nonzero poses -> ok' in log,
        'native_init':bool(re.search(r'xrizer OpenVR: InitInternal2 type 1 startup null token [1-9]\d* error 0',log)),
        'real_system':bool(re.search(r'actual native interface IVRSystem_019 pointer 0x[0-9a-f]+ error 0',log)),
        'real_compositor':bool(re.search(r'actual native interface IVRCompositor_022 pointer 0x[0-9a-f]+ error 0',log)),
        'development_label':'xrizer dev host: offscreen synthetic stationary head' in log,
        'standing_cancel': log.count('xrizer dev host: cancelled frame 1 pose 1') == 1,
        'two_pixels': bool(re.search(r'xrizer dev audit: pair frame 2 pose 2 variant 0 pixels match',log)) and bool(re.search(r'xrizer dev audit: pair frame 3 pose 3 variant 1 pixels match',log)),
        'leases_and_drain': bool(re.search(r'xrizer dev audit: drained pairs 2 reader leases 2/2 source leases (\d+)/\1 copies 4 lifecycle 1/1/1',log)),
        'no_xrizer_errors':not re.search(r'\bERROR\s+xrizer::',log),
        'lifecycle_drained':all(log.count(s)==1 for s in ('xrizer dev host: synthetic session begun',
            'xrizer dev host: synthetic session exit requested', 'xrizer dev host: session ended with frame queue drained')),
        'strict_aot':len(summaries)==1 and int(summaries[0][0])>0 and summaries[0][1:]==('0','0'),
        'inputs_unchanged':all(p.is_file() and digest(p)==identity[str(p)] for p in paths)}
    result={'subject':'owned Windows guest stereo + poses through synthetic offscreen Mac development host; no game/headset claim',
            'command':command,'environment':{k:v for k,v in env.items() if k.startswith(('VXRT_','XDG_'))},
            'returncode':rc,'timed_out':timed_out,'aot_summaries':summaries,'checks':checks,
            'runtime_log_sha256':digest(out/'runtime.log'),'identities_sha256':digest(out/'identities.json')}
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2)); return 0 if all(checks.values()) else 1

if __name__=='__main__': raise SystemExit(main())
