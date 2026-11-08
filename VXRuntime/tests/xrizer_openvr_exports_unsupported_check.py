import argparse,hashlib,json,os,re,signal,subprocess
from pathlib import Path
p=argparse.ArgumentParser()
for n in ('runtime','exe','aot-dir','xrizer-dylib','out'):p.add_argument('--'+n,required=True,type=Path)
a=p.parse_args();runtime,exe,modules,lib=(q.resolve(strict=True) for q in (a.runtime,a.exe,a.aot_dir,a.xrizer_dylib));out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
def sha(x):return hashlib.sha256(x.read_bytes()).hexdigest()
paths=[runtime,exe,lib,*sorted(modules.glob('*.dylib'))];identity={str(x):sha(x) for x in paths}
(out/'identities.json').write_text(json.dumps(identity,indent=2)+'\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('VXRT_','VERANTYX_','XDG_'))}
env.update(VXRT_ROOT=str(out/'root'),VXRT_AOT_DIR=str(modules),VXRT_AOT_STRICT='1',VXRT_NO_WINE='1',VXRT_STEAM_BRIDGE='0',VXRT_NO_ACTIVATE='1',VXRT_MUTE='1',VXRT_XRIZER_OPENVR='1',VXRT_XRIZER_DYLIB=str(lib),VXRT_XRIZER_DEV_AUDIT='1')
for kind in ('STATE','CONFIG','CACHE','DATA'):
 d=out/'xdg'/kind.lower();d.mkdir(parents=True,mode=0o700);env['XDG_'+kind+'_HOME']=str(d)
cmd=['/usr/bin/arch','-arm64',str(runtime),str(exe)];timeout=False
with (out/'runtime.log').open('wb') as f:
 child=subprocess.Popen(cmd,cwd=exe.parent,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
 try:rc=child.wait(timeout=30)
 except subprocess.TimeoutExpired:timeout=True;os.killpg(child.pid,signal.SIGKILL);rc=child.wait()
log=(out/'runtime.log').read_text(errors='replace');summary=re.findall(r'aot: (\d+) entries into recompiled code,.*? (\d+) fallbacks to the translator \((\d+) addresses\)',log)
checks={'expected_abort':rc==-signal.SIGABRT and not timeout,'named_slot':log.count('xrizer_guest_bridge: unsupported IVRSystem_019 slot 6')==1,'no_guest_success':'ExitProcess(99)' not in log,'real_init':'xrizer OpenVR: InitInternal2 type 1 startup null token 1 error 0' in log,'counter_snapshot':len(summary)==1 and int(summary[0][0])>0 and summary[0][1:]==('0','0'),'no_unexpected_xrizer_panic':not re.search(r'\bERROR\s+xrizer\b',log),'inputs_unchanged':all(x.is_file() and sha(x)==identity[str(x)] for x in paths)}
result={'subject':'owned intentional unsupported-slot counter snapshot, synthetic Mac host; no game/headset claim','command':cmd,'environment':{k:v for k,v in env.items() if k.startswith(('VXRT_','XDG_'))},'returncode':rc,'timed_out':timeout,'aot_summaries':summary,'checks':checks,'runtime_log_sha256':sha(out/'runtime.log'),'identities_sha256':sha(out/'identities.json')}
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2));raise SystemExit(0 if all(checks.values()) else 1)
