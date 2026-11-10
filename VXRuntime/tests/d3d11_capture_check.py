#!/usr/bin/env python3
"""Direct3D 11 capture and replay (src/d3d11_capture.m, tools/d3d11_replay.m) on owned fixtures.

usage: d3d11_capture_check.py <vxrt> [replayer]

build/d3d11_capture.exe (six frames: textures made without contents, initial data, UpdateSubresource, Map
WRITE_DISCARD / WRITE_NO_OVERWRITE / staging WRITE, depth, blending, scissors, the swap chain's buffer, Present) and
build/draw.exe are run with VXRT_D3D11_CAPTURE, then replayed: every image the program read back must be the same
bytes in the replay (the program's own printed hashes, and the hashes the capture recorded at its Maps). Also: a
frame range, a capture stopped after n presents (its end record), and a capture cut short inside a record."""
import os, re, shutil, subprocess, sys

vxrt = sys.argv[1]
replay = sys.argv[2] if len(sys.argv) > 2 else 'build/vxrt-d3d11-replay'
out = 'build/d3d11-capture-check'
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)
failures = []

def check(cond, what):
    if not cond: failures.append(what); print('  FAILED:', what)

def capture(exe, name, extra=None):
    env = dict(os.environ, VXRT_ROOT='build/root', VXRT_NO_ACTIVATE='1', VXRT_D3D11_CAPTURE=f'{out}/{name}.cap', **(extra or {}))
    p = subprocess.run([vxrt, f'build/{exe}'], env=env, capture_output=True, text=True, timeout=120)
    check(p.returncode == 0, f'{exe} exit {p.returncode}')
    return p.stdout

def run_replay(cap, *args):
    p = subprocess.run([replay, cap, '--quiet', *args], capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout + p.stderr

# 1. the six-frame fixture, all of it
live = capture('d3d11_capture.exe', 'frames')
frames = re.findall(r'frame (\d+): target fnv ([0-9a-f]{16}) .*?swap chain buffer fnv ([0-9a-f]{16})', live)
check(len(frames) == 6, f'six frames printed by the program, got {len(frames)}')
rc, text = run_replay(f'{out}/frames.cap', '--check-reads', '--dump-reads', '--dump-dir', f'{out}/reads')
reads = re.findall(r'read (\d+) \(frame (\d+)\): object \d+ sub \d+, \d+ bytes, fnv ([0-9a-f]{16}), live ([0-9a-f]{16})', text)
check(rc == 0, f'replay --check-reads exit {rc}')
check('6 frames (presents)' in text and 'the same 12' in text, 'replay: 6 frames, 12 readbacks the same')
for f, target, back in frames:
    got = [r for r in reads if r[1] == f]
    check(len(got) == 2 and got[0][2] == target and got[1][2] == back,
          f'frame {f}: the program read target {target}, buffer {back}; the replay {[g[2] for g in got]}')
print('d3d11_capture.exe:', ', '.join(f'frame {f} {t[:8]}/{b[:8]}' for f, t, b in frames), '-> replay the same' if not failures else '')

# 2. frames 3-4 only: the replay stops after frame 4, the reads of frames 3 and 4 checked
rc, text = run_replay(f'{out}/frames.cap', '--frames', '3-4', '--check-reads')
check(rc == 0 and 'compared with the live program\'s: 4, the same 4' in text and '4 frames (presents)' in text, 'frames 3-4: 4 readbacks the same, stopped after frame 4')

# 3. a capture stopped after 3 presents ends with its end record
capture('d3d11_capture.exe', 'three', {'VXRT_D3D11_CAPTURE_FRAMES': '3'})
rc, text = run_replay(f'{out}/three.cap', '--check-reads')
check(rc == 0 and "the capture's end" in text and '3 frames (presents)' in text and 'the same 6' in text, 'stopped after 3 presents: end record, 6 readbacks the same')

# 4. cut short inside a record (a crashed program): the prefix replays
data = open(f'{out}/frames.cap', 'rb').read()
open(f'{out}/cut.cap', 'wb').write(data[:len(data) * 2 // 3 + 5])
rc, text = run_replay(f'{out}/cut.cap', '--check-reads')
m = re.search(r'compared with the live program\'s: (\d+), the same (\d+)', text)
check(rc == 0 and 'cut short' in text and m and int(m.group(1)) >= 4 and m.group(1) == m.group(2), 'a capture cut short: its prefix replays, readbacks the same')

# 5. tests/draw.c: triangles, textures, shader math, depth, blending, stencil, mips, geometry shader, stream output
capture('draw.exe', 'draw')
rc, text = run_replay(f'{out}/draw.cap', '--check-reads')
m = re.search(r'compared with the live program\'s: (\d+), the same (\d+)', text)
check(rc == 0 and m and int(m.group(1)) >= 15 and m.group(1) == m.group(2), f'draw.exe: every readback the same ({m.group(0) if m else text[-300:]})')
print('draw.exe:', m.group(0) if m else '?')

print('d3d11 capture/replay:', 'ok' if not failures else f'{len(failures)} FAILED')
sys.exit(1 if failures else 0)
