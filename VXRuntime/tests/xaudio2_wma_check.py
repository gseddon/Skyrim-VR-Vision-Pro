#!/usr/bin/env python3
"""Checks the xWMA (WMA v2) plays of tests/xaudio2_27.c in its XAudio2 output capture (VXRT_XAUDIO2_CAPTURE).

The test plays the owned vector tests/wma/m22_24k through a mono 22.05 kHz mastering voice three times:
(a) one buffer, (b) two buffers split off a packet boundary, (c) PlayBegin 2048, PlayLength 3000. The decoded
stream is FFmpeg's decode of the same packets one frame (1024) earlier, so FFmpeg's samples ref[0:] are the
stream's frames 1024 on. Expected in the capture, each within one 16-bit step of ref and bounded by silence:
ref[0:11264] twice (a, b: preceded by the same 1024 frames), and ref[1024:4024] once (c).
usage: xaudio2_wma_check.py CAPTURE REF.s16
"""
import array
import struct
import sys

cap_path, ref_path = sys.argv[1], sys.argv[2]
data = open(cap_path, 'rb').read()
ref = array.array('h', open(ref_path, 'rb').read())
if sys.byteorder != 'little':
    ref.byteswap()

# the mono 22.05 kHz mastering voice's segment
segments, p = [], 0
while p + 12 <= len(data):
    magic, ch, rate = struct.unpack_from('<III', data, p)
    if magic != 0x41435856:
        sys.exit('xaudio2 wma: capture is malformed at byte %d -> FAILED' % p)
    q = data.find(struct.pack('<I', 0x41435856), p + 12)
    end = q if q >= 0 else len(data)
    # (a header is 4-byte aligned like the floats; a float equal to the magic would be a NaN pattern, never mixed)
    segments.append((ch, rate, data[p + 12:end])); p = end
mono = [s for s in segments if s[0] == 1 and s[1] == 22050]
if len(mono) != 1:
    sys.exit('xaudio2 wma: %d mono 22050 Hz mastering voices in the capture (%s) -> FAILED' % (len(mono), [(s[0], s[1]) for s in segments]))
raw = mono[0][2]
cap = array.array('f', raw[:len(raw) // 4 * 4])
s = [x * 32768.0 for x in cap]
print('xaudio2 wma: capture %d frames (%.2f s), %d mastering voices' % (len(s), len(s) / 22050, len(segments)))
if any(abs(x - round(x)) > 1e-3 for x in s):
    sys.exit('xaudio2 wma: the mix is not the decoded 16-bit samples (resampled or scaled?) -> FAILED')
s = [int(round(x)) for x in s]


def find(snippet):
    """Positions where the capture holds `snippet` (within one step)."""
    a = next(i for i, v in enumerate(snippet) if abs(v) > 2000)
    hits = []
    for p in range(a, len(s) - (len(snippet) - a) + 1):
        if abs(s[p] - snippet[a]) > 1:
            continue
        start = p - a
        if all(abs(s[start + i] - snippet[i]) <= 1 for i in range(len(snippet))):
            hits.append(start)
    return hits


failures = 0
full = list(ref[0:11264])
hits = find(full)
print('xaudio2 wma: ref[0:11264] at frames %s' % hits)
if len(hits) != 2:
    print('check failed: the whole stream played %d times, not 2 (a, b)' % len(hits)); failures += 1
else:
    for h in hits:
        if h < 1024 or (h + 11264 < len(s) and s[h + 11264] != 0):
            print('check failed: the play at %d is not bounded by its first frame and silence' % h); failures += 1
    if s[hits[0] - 1024:hits[0]] != s[hits[1] - 1024:hits[1]]:
        print('check failed: (a) and (b) start differently'); failures += 1
    if all(v == 0 for v in s[hits[0] - 1024:hits[0]]):
        print('(note: the stream\'s first 1024 frames are silent)')
part = list(ref[1024:4024])
hits_c = [h for h in find(part) if not hits or all(abs(h - x) > 11264 for x in hits)]
print('xaudio2 wma: ref[1024:4024] (PlayBegin 2048, PlayLength 3000) at frames %s' % hits_c)
if len(hits_c) != 1:
    print('check failed: (c) played %d times, not once' % len(hits_c)); failures += 1
elif s[hits_c[0] - 1] != 0 or (hits_c[0] + 3000 < len(s) and s[hits_c[0] + 3000] != 0):
    print('check failed: (c) is not bounded by silence (PlayBegin / PlayLength)'); failures += 1
print('xaudio2 wma: %s' % ('%d check(s) FAILED' % failures if failures else 'ok'))
sys.exit(1 if failures else 0)
