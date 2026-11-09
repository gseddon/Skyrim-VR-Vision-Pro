# WMA v2 decoder: source record

Licence: **LGPL-2.1-or-later** (not MIT), as the FFmpeg files it is derived from. See
`THIRD_PARTY_NOTICES.md` ("WMA v2 decoder derived from FFmpeg") for the notice.

Purpose (the one FFmpeg reuse authorized in `AGENTS.md`, 2026-11-09): decoding xWMA / WMA v2 audio (format tag
0x161) in VXRuntime's XAudio2 runtime (`src/xaudio2.m`), which Skyrim's music and voice lines use.

## Upstream

- Project: FFmpeg, https://ffmpeg.org; repository https://git.ffmpeg.org/ffmpeg.git (fetched from the GitHub
  mirror https://github.com/FFmpeg/FFmpeg as raw files).
- Revision: `bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa` (tag `n9.0.1`; tag object `501bb49457b9dfb25d6a208832e0a6e6cd53108d`).
- Fetched 2026-11-09, only these files, into a scratch directory outside the source tree:
  `LICENSE.md`, `COPYING.LGPLv2.1`, `libavcodec/wmadec.c`, `wma.c`, `wma.h`, `wmadata.h`, `wma_common.c`,
  `wma_common.h`, `wma_freqs.c`, `wma_freqs.h`, `aactab.c`, `aactab.h`.
- Licence check: every file used carries FFmpeg's LGPL-2.1-or-later header; none is among the GPL parts listed in
  FFmpeg's `LICENSE.md`.

## Files

| File | From | Changes |
| --- | --- | --- |
| `wmadec.c` | `libavcodec/wmadec.c`, `wma.c`, `wma_common.c`, `wma_freqs.c` | see below |
| `wmadec_internal.h` | `libavcodec/wma.h` | only the constants and `CoefVLCTable` kept |
| `wmadata.h` | `libavcodec/wmadata.h` | include of `wma.h` replaced; two tables made `static`; values unchanged |
| `aac_scalefactor.h` | `libavcodec/aactab.c` | only `ff_aac_scalefactor_code` / `_bits`, made `static`; values unchanged |
| `wmadec.h` | (new) | the C interface: `vx_wma_open`, `vx_wma_decode`, `vx_wma_reset`, `vx_wma_close` |

Changes in `wmadec.c` (2026-11-09):

- WMA v2 only: the WMA v1 branches and WMA Pro's escape coding in the run/level decoder are removed, as are the
  TRACE dumps and log messages. The decoding itself (block lengths, noise coding, exponents by VLC or LSP,
  run/level coefficients, mid/side stereo, windowed overlap, superframes and the bit reservoir) follows FFmpeg's
  code line by line.
- libavcodec/libavutil infrastructure replaced by small local code written for VXRuntime: a bit reader (reads past
  the end give zero bits, like FFmpeg's padded safe reader); Huffman decoding by walking a binary tree built from the
  same code tables (in place of `VLC`/`get_vlc2`; an unknown code gives -1 as there); an inverse MDCT (full output,
  scale 1/32768, the sign of `av_tx`'s `AV_TX_FLOAT_MDCT` inverse with `AV_TX_FULL_IMDCT`) computed through a DCT-IV
  and a radix-2 FFT; the four float vector helpers; the sine windows.
- The context holds what `AVCodecContext` supplied (channels, rate, bit rate, block align). Exponent and
  coefficient values are stored as floats rather than through `uint32_t` type punning (same values).
- With no extra format bytes, flags2 is 0x1F (what FFmpeg's xWMA demuxer supplies for WMA v2 in xWMA files).
- Output is interleaved 16-bit, rounded to nearest and clipped. The first frame after open/reset (always silent)
  is not returned: xWMA packet tables (`dpds`, `XAUDIO2_BUFFER_WMA`) count the output without it. FFmpeg instead
  skips two frames (its decoder delay) and appends the last frame's overlap at the end of the stream: the same total
  length, one frame later. `vx_wma_reset` also restarts the noise generator, so a stream decodes the same each time.

## Test vectors (owned)

`tests/wma/` (committed): synthetic signals encoded for this repository with the locally installed FFmpeg 9.0.1's
`wmav2` encoder (Nix build, `ffmpeg -f lavfi -i aevalsrc=...`; FFmpeg's encoder writes flags2 = 1: exponent VLCs,
no bit reservoir, fixed block length), and the same FFmpeg's decode of them (`pcm_f32le`, rounded to 16 bits):

| Vector | Signal | Format | Packets |
| --- | --- | --- | --- |
| `m22_24k` | `0.5*sin(2*PI*300*t)*sin(2*PI*2*t)+0.1*sin(2*PI*4000*t)`, 0.6 s | 22050 Hz mono, 24 kb/s, block 139 (noise coding) | 13 |
| `s44_32k` | two tones, a sweep and noise per channel (below), 0.3 s | 44100 Hz stereo, 32 kb/s, block 185 (noise coding, mid/side) | 7 |

Files: `<name>.wmav2` (packets, concatenated), `<name>.ref.s16` (FFmpeg's decode), `m22_24k_packets.h` (the
22.05 kHz packets as a C array for the guest test). Stereo signal:
`0.4*sin(2*PI*440*t)+0.2*sin(2*PI*3000*t*(1+t))+0.05*(random(0)-0.5)|0.3*sin(2*PI*660*t)+0.25*sin(2*PI*5000*t)+0.05*(random(1)-0.5)`.

## Verification (2026-11-09)

- Owned vectors, native (`build/wmadec_vectors tests/wma`, run by `make check` and `make check-arm64`): both decode
  to FFmpeg 9.0.1's output within one 16-bit step (m22: 7 of 11264 samples differ by one; s44: 20 of 20480; FFmpeg's
  s16 conversion through libswresample differs from rounding by one more often, so the reference is its float
  output); lengths are (packets - 1) frames; a reset decoder repeats itself; 2000 random packets with the xWMA flags
  are refused or decoded without a crash (also run under UBSan with bounds checks; AddressSanitizer did not start
  on this host).
- XAudio2 (owned fixture `tests/xaudio2_27.c` + `tests/xaudio2_wma_check.py` on the mixer capture,
  `VXRT_XAUDIO2_CAPTURE`): a WMA v2 voice plays the decoded samples (FFmpeg's within one step), the same when the
  packets are split into two buffers off a packet boundary, and PlayBegin / PlayLength bound the play; callbacks and
  samples played follow the packet tables. Run on `build/vxrt-arm64` and `build/vxrt` (Rosetta).
- Skyrim VR's own files, private and local only (read-only from the game's `Skyrim - Sounds.bsa` and
  `Skyrim - Voices_en0.bsa`; nothing committed): 14 music tracks (44.1 kHz and 32 kHz stereo, 48 kb/s) and 9 voice
  lines (44.1 kHz mono, 32 kb/s), all WMA v2 with no extra bytes (flags2 0x1F: bit reservoir, variable block
  lengths): no packet refused; every file's decoded length equals its `dpds` table's last value; per-packet totals
  are within one frame of the table; two of them (a 185 s track and a voice line) match FFmpeg 9.0.1's decode of the
  `.xwm` within one step; plausible levels (RMS 260-3900, five clipped samples in one loud track). 185 s of stereo
  music decodes in about 0.12 s on an M-series host.
- Not verified: WMA v2 streams with flags other than 0x01 and 0x1F; xWMA buffers a game streams in several parts
  with their own tables (the carry between buffers is only checked on the owned fixture); the actual game's audio
  path (no Skyrim run with this decoder yet); WMA Pro (0x162) and Lossless (0x163) are not decoded (silence).
