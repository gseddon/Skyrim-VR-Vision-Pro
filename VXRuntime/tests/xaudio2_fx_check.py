#!/usr/bin/env python3
"""Compares the XAudio2 output captures of tests/xaudio2_fx.c (VXRT_XAUDIO2_CAPTURE).
usage: xaudio2_fx_check.py NONE.capture DISABLED.capture ENABLED.capture [OFF.capture]
none and disabled: the same samples bit for bit from the first nonzero frame; enabled: a tail where none is silent,
the dry part still there; off (VXRT_XAUDIO2_NO_EFFECTS=1): bit for bit with none."""
import array, struct, sys

def load(path):
    d = open(path, 'rb').read()
    magic, ch, rate = struct.unpack_from('<III', d, 0)
    assert magic == 0x41435856 and ch == 2 and rate == 48000, (magic, ch, rate)
    a = array.array('f'); a.frombytes(d[12:12 + (len(d) - 12) // 4 * 4])
    first = next(i for i, x in enumerate(a) if x != 0)
    return a[first - first % 2:]

none, dis, en = (load(p) for p in sys.argv[1:4])
n = min(len(none), len(dis), len(en)) // 2 * 2
fail = []
if none[:n].tobytes() != dis[:n].tobytes(): fail.append('disabled effect is not a bit-exact passthrough')
if len(sys.argv) > 4:
    off = load(sys.argv[4]); m = min(n, len(off))
    if none[:m].tobytes() != off[:m].tobytes(): fail.append('VXRT_XAUDIO2_NO_EFFECTS=1 is not a bit-exact passthrough')
dry_end = 24000 * 2
tail_none = sum(abs(x) for x in none[dry_end + 4800:n]); tail_en = sum(abs(x) for x in en[dry_end + 4800:n])
peak = max(abs(x) for x in en[:n])
print('tail energy (sum |x|) after the dry signal: none %.6f, enabled %.3f; enabled peak %.3f; frames compared %d' % (tail_none, tail_en, peak, n // 2))
if tail_none != 0: fail.append('the dry mix is not silent after the signal')
if tail_en < 1.0: fail.append('the reverb has no tail')
if not (0.05 < peak < 4): fail.append('the reverb output level is odd')
if en[:n].tobytes() == none[:n].tobytes(): fail.append('enabled equals none')
print('xaudio2_fx: ' + ('FAILED: ' + '; '.join(fail) if fail else 'ok'))
sys.exit(1 if fail else 0)
