#!/usr/bin/env python3 -I
"""A different msvcp140.dll (SteamVR updates it) is accepted and recorded, not refused: the pipeline's pin, tools/skyrim_prepare.py inputs,
the aot stamp and the skse-capture state all key on the actual hash; a non-PE or ARM64 file is still refused. Simulated with tiny synthetic PEs."""
import contextlib, hashlib, io, json, os, struct, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))


def fake_pe(machine=0x8664, tag=b''):
    """A minimal PE32+ image: one 0x200-byte section; passes skyrim_aot_pipeline.pe_layout."""
    hdr = bytearray(0x400)
    hdr[:2] = b'MZ'; struct.pack_into('<I', hdr, 0x3c, 0x40)
    hdr[0x40:0x44] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', hdr, 0x44, machine, 1, 0, 0, 0, 240, 0x2022)
    o = 0x58
    struct.pack_into('<H', hdr, o, 0x20b); struct.pack_into('<I', hdr, o + 16, 0x1000); struct.pack_into('<Q', hdr, o + 24, 0x180000000)
    struct.pack_into('<II', hdr, o + 56, 0x2000, 0x200)       # image size, header size
    struct.pack_into('<I', hdr, o + 108, 16)
    s = o + 240                                                # section table
    hdr[s:s + 8] = b'.text\0\0\0'
    struct.pack_into('<IIII', hdr, s + 8, 0x200, 0x1000, 0x200, 0x200); struct.pack_into('<I', hdr, s + 36, 0x60000020)   # code, executable
    hdr[0x200:0x200 + len(tag)] = tag
    return bytes(hdr[:0x400])


with tempfile.TemporaryDirectory() as t:
    t = Path(t).resolve(); priv = t / 'private'; (priv / 'inputs').mkdir(parents=True)
    os.environ['VXRT_PRIVATE_ROOT'] = str(priv)
    for k in ('VXRT_SKYRIM_DIR', 'VXRT_AOT_INPUTS', 'VXRT_SPLITS_FILE', 'VXRT_SPLITS_SHA256'): os.environ.pop(k, None)
    os.environ['SKYRIM_ASSET_ROOT'] = str(t)
    import vxrt_env as E, vxrt_build as B, skse_capture as K, skyrim_prepare as SP, skyrim_aot_pipeline as P

    cfg = json.loads((ROOT / 'tools' / 'skyrim_aot_skyrimvr.json').read_text())
    item = next(d for d in cfg['dlls'] if d['path'].endswith('/msvcp140.dll'))
    assert item['pin'] == 'recorded' and item['sha256'] == E.MSVCP140_KNOWN_SHA256, 'config marks msvcp140 recorded'
    assert all(d.get('pin') != 'recorded' for d in cfg['dlls'] if d is not item), 'only msvcp140 is relaxed'

    newer = t / 'steamvr' / 'msvcp140.dll'; newer.parent.mkdir(); newer.write_bytes(fake_pe(tag=b'newer build'))
    want = hashlib.sha256(newer.read_bytes()).hexdigest(); assert want != E.MSVCP140_KNOWN_SHA256

    # --- the pipeline's pin: recorded accepts and returns the ACTUAL hash (the module key hashes it), fixed pins still refuse
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        copy = priv / 'inputs' / 'msvcp140.dll'; copy.write_bytes(newer.read_bytes())
        r = P.pin(dict(path=str(copy), sha256=E.MSVCP140_KNOWN_SHA256, pin='recorded'), True)
    assert r['sha256'] == want and r['known_sha256'] == E.MSVCP140_KNOWN_SHA256 and not r['pin_matches'] and 'building the one you have' in err.getvalue()
    try: P.pin(dict(path=str(copy), sha256=E.MSVCP140_KNOWN_SHA256), True); raise SystemExit('a fixed pin accepted another hash')
    except ValueError as e: assert 'SHA-256 mismatch' in str(e)
    arm = priv / 'inputs' / 'arm.dll'; arm.write_bytes(fake_pe(machine=0xaa64))
    try: P.pin(dict(path=str(arm), sha256=E.MSVCP140_KNOWN_SHA256, pin='recorded'), True); raise SystemExit('ARM64 accepted')
    except ValueError as e: assert 'x86-64 PE layout' in str(e)

    # --- prepare: place() copies a different msvcp140 with a note; garbage is refused with a message that says what to do
    dst = priv / 'out' / 'msvcp140.dll'
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        SP.place(newer, dst, E.MSVCP140_KNOWN_SHA256, recorded=True)
    assert dst.read_bytes() == newer.read_bytes() and 'SteamVR updates this DLL' in out.getvalue()
    junk = t / 'junk.dll'; junk.write_bytes(b'not a dll')
    try: SP.place(junk, dst, E.MSVCP140_KNOWN_SHA256, recorded=True); raise SystemExit('junk accepted')
    except SP.Refuse as e: assert 'vrwebhelper' in str(e)
    try: SP.place(newer, priv / 'out' / 'binkw64.dll', E.MSVCP140_KNOWN_SHA256); raise SystemExit('fixed pin accepted another hash')
    except SP.Refuse as e: assert 'config pins' in str(e)

    # --- aot stamp: keyed on the actual msvcp140 hash; a stamp from before the key means "the known one"
    inp = Path(E.variables()['VXRT_AOT_INPUTS']); inp.mkdir(parents=True, exist_ok=True)
    (inp / 'msvcp140.dll').write_bytes(newer.read_bytes())
    ident = B.aot_identity(); assert ident['msvcp140_sha256'] == want
    B.aot_stamp_path().write_text(json.dumps(ident))
    assert B.aot_stamp_current(ident)
    (inp / 'msvcp140.dll').write_bytes(fake_pe(tag=b'older build'))
    assert not B.aot_stamp_current(B.aot_identity()), 'a changed msvcp140.dll rebuilds'
    legacy = {k: v for k, v in ident.items() if k != 'msvcp140_sha256'}
    B.aot_stamp_path().write_text(json.dumps(legacy))
    assert not B.aot_stamp_current(ident), 'old stamp + different msvcp140: rebuild'
    ident_known = dict(ident, msvcp140_sha256=E.MSVCP140_KNOWN_SHA256)
    assert B.aot_stamp_current(ident_known), 'old stamp + the known msvcp140: no needless rebuild'

    # --- skse-capture: state records the hash; another msvcp140 makes it stale, an old state means the known one
    now = E.msvcp140_identity()
    assert K.msvcp_changed({'msvcp140_sha256': 'other'}) and not K.msvcp_changed({'msvcp140_sha256': now})
    assert K.msvcp_changed({}), 'a state without the key means the known one, which this is not'
    (inp / 'msvcp140.dll').unlink(); assert E.msvcp140_identity() is None and not K.msvcp_changed({'msvcp140_sha256': 'x'})
print('msvcp140_recorded_test: ok')
