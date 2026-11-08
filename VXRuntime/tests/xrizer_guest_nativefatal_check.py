#!/usr/bin/env python3
"""Check one real native SIGBUS diagnostic; no overflow or game claim."""
import argparse, hashlib, json, os, re, signal, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
for name in ('runtime','exe','aot-dir','out'): p.add_argument('--'+name,required=True,type=Path)
a=p.parse_args(); runtime,exe,modules=(x.resolve(strict=True) for x in (a.runtime,a.exe,a.aot_dir))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
paths=[runtime,exe,*sorted(modules.glob('*.dylib'))]; assert len(paths)>2
hashes={str(x):hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
(out/'identities.json').write_text(json.dumps(hashes,indent=2)+'\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('VXRT_','VERANTYX_','XDG_'))}
env.update(VXRT_ROOT=str(out/'root'),VXRT_AOT_DIR=str(modules),VXRT_AOT_STRICT='1',VXRT_NO_WINE='1',VXRT_STEAM_BRIDGE='0',VXRT_NO_ACTIVATE='1',VXRT_MUTE='1')
cmd=['/usr/bin/arch','-arm64',str(runtime),str(exe)]
with (out/'runtime.log').open('wb') as log:
    child=subprocess.Popen(cmd,cwd=exe.parent,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try: rc=child.wait(timeout=10)
    except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL);child.wait();rc=-1
text=(out/'runtime.log').read_text(errors='replace')
(out/'process.json').write_text(json.dumps({'command':cmd,'returncode':rc,'environment':{k:v for k,v in env.items() if k.startswith('VXRT_')},'scope':'owned guest to native raise(SIGBUS); actual game and stack exhaustion not tested','aot_counters':'unknown unless present in log'},indent=2)+'\n')
expected=re.search(r'expected stack_low=(0x[0-9a-f]+) stack_high=(0x[0-9a-f]+) tid=(0x[0-9a-f]+)',text)
record=re.search(r'arm64: native fatal signal=(0x[0-9a-f]+) code=(0x[0-9a-f]+) address=(0x[0-9a-f]+) pc=(0x[0-9a-f]+) sp=(0x[0-9a-f]+) lr=(0x[0-9a-f]+) fp=(0x[0-9a-f]+) stack_low=(0x[0-9a-f]+) stack_high=(0x[0-9a-f]+) tid=(0x[0-9a-f]+)',text)
assert rc==128+signal.SIGBUS, f'unexpected exit {rc}'
assert expected and record, 'missing actual native-stack record'
v=[int(x,16) for x in record.groups()]; e=[int(x,16) for x in expected.groups()]
assert v[0]==signal.SIGBUS and v[3] and v[4] and v[5] and v[6], 'missing mcontext values'
assert v[7:]==e and e[0]<=v[4]<e[1] and e[2], 'cached native stack identity/SP mismatch'
assert 'unexpected return' not in text and 'ExitProcess(99)' not in text
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in hashes.items()), 'input changed'
print('owned guest/native SIGBUS: mcontext and cached native stack match -> ok')
