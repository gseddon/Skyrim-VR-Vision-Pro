#!/usr/bin/env python3 -I
"""tools/skyrim_splits.py: the committed module-splits profile is for the pinned exe and installs into a private root with its hash; a recording
run's addresses are shifted to the preferred base and added to what is there; the config pins the profile by the hash beside it."""
import gzip, hashlib, os, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
with tempfile.TemporaryDirectory() as t:
    os.environ['VXRT_PRIVATE_ROOT'] = t
    for k in ('VXRT_SKYRIM_DIR', 'VXRT_AOT_INPUTS', 'VXRT_SPLITS_FILE', 'VXRT_SPLITS_SHA256'): os.environ.pop(k, None)
    import vxrt_env as E, skyrim_splits as S
    f = ROOT / 'tools' / 'profiles' / ('splits-%s.txt.gz' % E.PREPARED_EXE_SHA256)
    assert f.is_file() and f.with_name(f.name + '.sha256').is_file(), 'the profile for the pinned exe is committed with its pin'
    data = gzip.decompress(f.read_bytes())
    assert hashlib.sha256(data).hexdigest() == f.with_name(f.name + '.sha256').read_text().split()[0]
    lines = data.decode().split()
    assert len(lines) >= 1000 and sum(x.startswith('0x14') for x in lines) >= len(lines) - 20, 'addresses in the exe at its preferred base (the author\'s profile carries 16 of an old binkw64 arena that the pipeline drops)'
    assert S.status() == 'missing' and S.tracked() == data
    assert S.install() and S.status() == 'ok'
    p = S.splits_path()
    assert p.read_bytes() == data and p.with_name(p.name + '.sha256').read_text().split()[0] == E.sha256_file(p)
    assert E.variables()['VXRT_SPLITS_SHA256'] == E.sha256_file(p)            # the pipeline config pins the file beside it
    rec = Path(t) / 'rec.txt'; rec.write_text('0x308000010\n0x308000020\n0x1\n0x3a000000000\n')   # (two in the run's image, two outside)
    before = len(lines)
    S.merge(rec, p, 0x308000000)
    got = p.read_text().split()
    assert len(got) == before + 2 and '0x140000010' in got and '0x140000020' in got and S.status() == 'ok'
    S.merge(rec, p, 0x308000000); assert len(p.read_text().split()) == before + 2        # adding again changes nothing
print('skyrim_splits_test: ok')
