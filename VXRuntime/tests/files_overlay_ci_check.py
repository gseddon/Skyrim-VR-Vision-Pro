#!/usr/bin/env python3
"""A game folder with only vanilla files and an overlay with the mods, on a CASE-SENSITIVE volume (the visionOS app's situation),
run with the runtime's case-insensitive path layer switched on (VXRT_CI_PATHS=1): the game's DATA\\* scan must list vanilla and overlay
entries once each, and opens with other letters (DATA/mod.esp, data\\TEXTURES\\...) must find the overlay's and the install's files.
The volume is a sparse disk image made and detached here (hdiutil; nothing outside the temporary folder is touched)."""
import os, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
EXE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'build/files_overlay_ci.exe'
tmp = Path(tempfile.mkdtemp(prefix='vxcs-')).resolve()   # (the real path: the overlay compares path prefixes as strings)
img, mnt = tmp / 'cs.sparseimage', tmp / 'mnt'
mnt.mkdir()
subprocess.run(['hdiutil', 'create', '-size', '64m', '-fs', 'Case-sensitive APFS', '-type', 'SPARSE', '-volname', 'vxcs', str(img)], check=True, stdout=subprocess.DEVNULL)
subprocess.run(['hdiutil', 'attach', str(img), '-mountpoint', str(mnt)], check=True, stdout=subprocess.DEVNULL)
try:
    game, ov, root = mnt / 'game', mnt / 'overlay', mnt / 'root'
    (game / 'Data' / 'Interface').mkdir(parents=True); (game / 'Data' / 'Skyrim.esm').write_bytes(b'TES4esm!')
    (game / 'Data' / 'Interface' / 'Translate_ENGLISH.txt').write_bytes(b'x')
    (ov / 'Data' / 'Textures' / 'sub').mkdir(parents=True); (ov / 'Data' / 'SKSE' / 'Plugins').mkdir(parents=True); (ov / 'Data' / 'Scripts').mkdir()
    (ov / 'Data' / 'mod.esp').write_bytes(b'TES4mod!'); (ov / 'Data' / 'Textures' / 'sub' / 'a.dds').write_bytes(b'DDS ')
    (ov / 'Data' / 'SKSE' / 'Plugins' / 'p.dll').write_bytes(b'MZ'); (ov / 'Data' / 'Scripts' / 'a.pex').write_bytes(b'x')
    pt = root / 'drive_c/users/vxrt/AppData/Local/Skyrim VR'; pt.mkdir(parents=True); (pt / 'Plugins.txt').write_bytes(b'*mod.esp\r\n')
    (game / 'g.exe').write_bytes(EXE.read_bytes())
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VXRT_', 'VERANTYX_'))}
    env.update(VXRT_ROOT=str(root), VXRT_OVERLAY=f'{game}:{ov}', VXRT_CI_PATHS='1', VXRT_NO_WINE='1', VXRT_STEAM_BRIDGE='0', VXRT_NO_ACTIVATE='1', VXRT_MUTE='1')
    p = subprocess.run(['/usr/bin/arch', '-arm64', str(ROOT / 'build/vxrt-arm64'), str(game / 'g.exe')], cwd=game, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
    out = p.stdout
    print('\n'.join(l for l in out.splitlines() if not l.startswith('[vxrt]')))
    assert p.returncode == 0 and 'files_overlay_ci: all ok' in out, f'exit {p.returncode}'
    print('files_overlay_ci: -> ok')
finally:
    subprocess.run(['hdiutil', 'detach', str(mnt), '-force'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
