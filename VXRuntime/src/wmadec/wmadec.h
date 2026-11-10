/*
 * WMA v2 (format tag 0x161) decoder for VXRuntime's XAudio2 xWMA voices: a small C interface to the decoder in
 * wmadec.c, which is derived from FFmpeg's libavcodec/wmadec.c and wma.c (FFmpeg revision
 * bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa, tag n9.0.1).
 * Copyright (c) 2002-2007 The FFmpeg Project
 *
 * This file is part of the FFmpeg-derived WMA decoder in VXRuntime and is licensed, like FFmpeg's decoder, under
 * the GNU Lesser General Public License version 2.1 or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the
 * implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public
 * License for more details. You should have received a copy of the GNU Lesser General Public License along with
 * this library; if not, write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
 * MA 02110-1301 USA. See src/wmadec/SOURCE.md.
 */
#ifndef VX_WMADEC_H
#define VX_WMADEC_H
#include <stdint.h>

typedef struct vx_wma vx_wma;

// The flags WMA v2 streams in xWMA files carry implicitly (their WAVEFORMATEX has no extra bytes): exponent VLCs,
// the bit reservoir, variable block lengths (as FFmpeg's xWMA demuxer sets them).
#define VX_WMA_XWMA_FLAGS2 0x1F

// A decoder for one stream. `extra`/`extra_size`: the WAVEFORMATEX's extra bytes (flags2 is the 16-bit value at
// offset 4 when there are at least 6); none: VX_WMA_XWMA_FLAGS2. NULL if the format is not one WMA v2 can carry
// (1-2 channels, rate <= 50 kHz, bit rate > 0, block_align > 0).
vx_wma *vx_wma_open(int channels, int sample_rate, int bit_rate, int block_align, const uint8_t *extra, int extra_size);
void vx_wma_close(vx_wma *s);
// Forgets the bit reservoir and the overlap of the previous frame (a new, unrelated packet sequence follows).
void vx_wma_reset(vx_wma *s);
// The most frames one packet can produce (15 frames of the stream's frame length).
int vx_wma_max_frames(const vx_wma *s);
int vx_wma_frame_len(const vx_wma *s);
// Decodes one packet (`size` >= block_align bytes; block_align are used) into interleaved 16-bit frames at `out`
// (room for vx_wma_max_frames). Returns the number of frames written (0: the packet only filled the bit reservoir),
// or a negative value if the packet is invalid (the reservoir is then dropped, as FFmpeg does). The first frame
// after vx_wma_open / vx_wma_reset (always silent) is not returned: what remains is what xWMA packet tables
// count, so after packet k the frames returned in all are cumulative[k] / (2 * channels).
int vx_wma_decode(vx_wma *s, const uint8_t *packet, int size, int16_t *out);

#endif
