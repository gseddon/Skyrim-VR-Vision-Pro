/*
 * WMA compatible decoder
 * Copyright (c) 2002 The FFmpeg Project
 *
 * WMA compatible codec
 * Copyright (c) 2002-2007 The FFmpeg Project
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/*
 * Derived from FFmpeg, FFmpeg revision bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa (tag n9.0.1):
 *   libavcodec/wmadec.c   (the decoder: exponents, blocks, frames, superframes and the bit reservoir)
 *   libavcodec/wma.c      (ff_wma_init, init_coef_vlc, ff_wma_total_gain_to_bits, ff_wma_run_level_decode)
 *   libavcodec/wma_common.c (ff_wma_get_frame_len_bits)
 *   libavcodec/wma_freqs.c  (ff_wma_critical_freqs)
 * for VXRuntime's XAudio2 xWMA voices (format tag 0x161, WMA v2). Local modifications (2026-11-09):
 *   - WMA v2 only: the WMA v1 branches (version 1) and WMA Pro's escape coding in the run/level decoder are
 *     removed; the TRACE dumps and log messages are removed.
 *   - libavcodec's infrastructure is replaced by small local equivalents, written for VXRuntime: a bit reader
 *     (reads past the end return zero bits, like FFmpeg's padded, safe reader), Huffman decoding by walking a
 *     binary code tree built from the same code tables (in place of libavcodec's VLC tables), an inverse MDCT
 *     computed through a DCT-IV and a radix-2 FFT (in place of libavutil's av_tx), the four float vector helpers
 *     (in place of AVFloatDSPContext) and the sine windows.
 *   - The codec context holds what AVCodecContext supplied (channels, sample rate, bit rate, block align); the
 *     exponent and coefficient tables are written as floats instead of through uint32_t type punning; output
 *     is interleaved 16-bit (rounded and clipped as libswresample converts float to s16).
 *   - The interface is wmadec.h's (open from WAVEFORMATEX fields, decode one packet, drain the overlap).
 * See src/wmadec/SOURCE.md.
 */

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "wmadec.h"
#include "wmadec_internal.h"
#include "wmadata.h"
#include "aac_scalefactor.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#define FF_ARRAY_ELEMS(a) (sizeof(a) / sizeof((a)[0]))
#define MIN_CACHE_BITS 25
#define INPUT_PADDING 64

// ---- local infrastructure (in place of libavcodec's) -----------------------------------------------------------

// A bit reader, most significant bit first. Reading past the end yields zero bits; the position stops 8 bits
// past the end (as FFmpeg's safe bitstream reader does).
typedef struct {
    const uint8_t *buf;
    int size_bits, index;
} GetBitContext;

static void init_get_bits(GetBitContext *g, const uint8_t *buf, int bits)
{
    g->buf = buf;
    g->size_bits = bits < 0 ? 0 : bits;
    g->index = 0;
}
static inline int byte_at(const GetBitContext *g, int i) { return i < (g->size_bits + 7) >> 3 ? g->buf[i] : 0; }
static inline void advance(GetBitContext *g, int n)
{
    g->index += n;
    if (g->index > g->size_bits + 8)
        g->index = g->size_bits + 8;
}
static inline unsigned get_bits1(GetBitContext *g)
{
    int i = g->index;
    unsigned v = (unsigned)(i < g->size_bits ? (g->buf[i >> 3] >> (7 - (i & 7))) & 1 : 0);
    advance(g, 1);
    return v;
}
static inline unsigned get_bits_long(GetBitContext *g, int n)
{
    if (n <= 0)
        return 0;
    int b = g->index >> 3;
    uint64_t w = 0;
    for (int k = 0; k < 5; k++)
        w = (w << 8) | (uint64_t)byte_at(g, b + k);
    uint32_t top = (uint32_t)(w >> (8 - (g->index & 7)));      // the 32 bits from the position on
    unsigned v = n >= 32 ? top : top >> (32 - n);
    // a byte straddling the end: the bits past size_bits read as zero
    int past = g->index + n - g->size_bits;
    if (past > 0) {
        if (past >= n) v = 0;
        else v &= ~((1u << past) - 1);
    }
    advance(g, n);
    return v;
}
static inline unsigned get_bits(GetBitContext *g, int n) { return get_bits_long(g, n); }
static inline void skip_bits(GetBitContext *g, int n) { advance(g, n); }
static inline int get_bits_count(const GetBitContext *g) { return g->index; }
static inline int get_bits_left(const GetBitContext *g) { return g->size_bits - g->index; }

// A Huffman code as a binary tree: node 0 is the root; next[b] is the child for bit b (0: none). A leaf holds
// its symbol. Decoding returns -1 for a bit sequence that is no code (as libavcodec's get_vlc2 does).
typedef struct { int32_t next[2]; int32_t sym; int32_t leaf; } VLCNode;
typedef struct { VLCNode *nodes; int count, cap; } VLC;

static int vlc_add(VLC *v, uint32_t code, int len, int sym)
{
    int node = 0;
    if (len <= 0 || len > 32)
        return -1;
    for (int i = len - 1; i >= 0; i--) {
        int b = (code >> i) & 1;
        if (v->nodes[node].leaf)
            return -1;                                          // a prefix of another code
        int c = v->nodes[node].next[b];
        if (!c) {
            if (v->count == v->cap) {
                int cap = v->cap * 2;
                VLCNode *n = realloc(v->nodes, sizeof(VLCNode) * cap);
                if (!n) return -1;
                v->nodes = n; v->cap = cap;
            }
            c = v->count++;
            memset(&v->nodes[c], 0, sizeof(VLCNode));
            v->nodes[node].next[b] = c;
        }
        node = c;
    }
    if (v->nodes[node].leaf || v->nodes[node].next[0] || v->nodes[node].next[1])
        return -1;
    v->nodes[node].leaf = 1;
    v->nodes[node].sym = sym;
    return 0;
}
static int vlc_begin(VLC *v)
{
    v->cap = 64;
    v->count = 1;
    v->nodes = calloc((size_t)v->cap, sizeof(VLCNode));
    return v->nodes ? 0 : -1;
}
// Codes given as values and lengths (symbol i is entry i).
static int vlc_init_codes(VLC *v, int n, const uint8_t *bits, const uint32_t *codes)
{
    if (vlc_begin(v) < 0)
        return -1;
    for (int i = 0; i < n; i++)
        if (bits[i] && vlc_add(v, codes[i], bits[i], i) < 0)
            return -1;
    return 0;
}
// Codes given by their lengths in code order (as ff_vlc_init_from_lengths assigns them): each next code
// follows the previous one in a left-aligned 32-bit code space.
static int vlc_init_from_lengths(VLC *v, int n, const uint8_t (*tab)[2], int offset)
{
    uint64_t code = 0;
    if (vlc_begin(v) < 0)
        return -1;
    for (int i = 0; i < n; i++) {
        int len = tab[i][1];
        if (len <= 0)
            continue;
        if (code & ((1ull << (32 - len)) - 1))
            return -1;
        if (vlc_add(v, (uint32_t)(code >> (32 - len)), len, tab[i][0] + offset) < 0)
            return -1;
        code += 1ull << (32 - len);
    }
    return 0;
}
static void vlc_free(VLC *v) { free(v->nodes); v->nodes = NULL; v->count = v->cap = 0; }
static inline int get_vlc(GetBitContext *g, const VLC *v)
{
    int node = 0;
    for (;;) {
        int c = v->nodes[node].next[get_bits1(g)];
        if (!c)
            return -1;
        if (v->nodes[c].leaf)
            return v->nodes[c].sym;
        node = c;
    }
}

// Inverse MDCT (full output): out[n] = -scale * sum_k in[k] cos(pi/N (n + 1/2 + N/2)(k + 1/2)), n < 2N, for N
// coefficients (the sign libavutil's AV_TX_FLOAT_MDCT inverse with AV_TX_FULL_IMDCT has), computed as a DCT-IV
// through an N/2-point complex FFT and unfolded by its symmetries.
typedef struct {
    int n;                       // coefficients
    float *pre_re, *pre_im;      // exp(-i pi (4j+1) / 4N), j < N/2
    float *post_re, *post_im;    // exp(-i pi l / N), l < N/2
    float *tw_re, *tw_im;        // exp(-2 pi i k / (N/2)), k < N/4
    int *rev;                    // bit reversal of N/2
    float *re, *im, *u;
    float scale;
} IMDCT;

static int imdct_init(IMDCT *m, int n, float scale)
{
    int h = n / 2, bits = 0;
    while ((1 << bits) < h) bits++;
    memset(m, 0, sizeof *m);
    m->n = n; m->scale = scale;
    m->pre_re = malloc(sizeof(float) * h); m->pre_im = malloc(sizeof(float) * h);
    m->post_re = malloc(sizeof(float) * h); m->post_im = malloc(sizeof(float) * h);
    m->tw_re = malloc(sizeof(float) * (h / 2 + 1)); m->tw_im = malloc(sizeof(float) * (h / 2 + 1));
    m->rev = malloc(sizeof(int) * h);
    m->re = malloc(sizeof(float) * h); m->im = malloc(sizeof(float) * h); m->u = malloc(sizeof(float) * n);
    if (!m->pre_re || !m->pre_im || !m->post_re || !m->post_im || !m->tw_re || !m->tw_im || !m->rev || !m->re || !m->im || !m->u)
        return -1;
    for (int j = 0; j < h; j++) {
        double a = -M_PI * (4 * j + 1) / (4.0 * n), b = -M_PI * j / n;
        m->pre_re[j] = (float)cos(a); m->pre_im[j] = (float)sin(a);
        m->post_re[j] = (float)cos(b); m->post_im[j] = (float)sin(b);
        int r = 0;
        for (int k = 0; k < bits; k++) if (j & (1 << k)) r |= 1 << (bits - 1 - k);
        m->rev[j] = r;
    }
    for (int k = 0; k <= h / 2; k++) {
        double a = -2 * M_PI * k / h;
        m->tw_re[k] = (float)cos(a); m->tw_im[k] = (float)sin(a);
    }
    return 0;
}
static void imdct_free(IMDCT *m)
{
    free(m->pre_re); free(m->pre_im); free(m->post_re); free(m->post_im); free(m->tw_re); free(m->tw_im);
    free(m->rev); free(m->re); free(m->im); free(m->u);
    memset(m, 0, sizeof *m);
}
static void imdct_calc(IMDCT *m, float *out, const float *in)
{
    int n = m->n, h = n / 2;
    float *re = m->re, *im = m->im, *u = m->u;
    for (int j = 0; j < h; j++) {                               // (X[2j] + i X[N-1-2j]) * pre, in bit-reversed order
        float a = in[2 * j], b = in[n - 1 - 2 * j];
        int r = m->rev[j];
        re[r] = a * m->pre_re[j] - b * m->pre_im[j];
        im[r] = a * m->pre_im[j] + b * m->pre_re[j];
    }
    for (int len = 2; len <= h; len <<= 1) {                    // radix-2 decimation in time
        int half = len >> 1, step = h / len;
        for (int s = 0; s < h; s += len)
            for (int k = 0; k < half; k++) {
                float wr = m->tw_re[k * step], wi = m->tw_im[k * step];
                int p = s + k, q = p + half;
                float tr = re[q] * wr - im[q] * wi, ti = re[q] * wi + im[q] * wr;
                re[q] = re[p] - tr; im[q] = im[p] - ti;
                re[p] += tr; im[p] += ti;
            }
    }
    for (int l = 0; l < h; l++) {                               // W = FFT * post: u[2l] = Re W, u[N-1-2l] = -Im W
        float wr = re[l] * m->post_re[l] - im[l] * m->post_im[l];
        float wi = re[l] * m->post_im[l] + im[l] * m->post_re[l];
        u[2 * l] = wr * m->scale;
        u[n - 1 - 2 * l] = -wi * m->scale;
    }
    for (int i = 0; i < h; i++) {
        out[i] = -u[i + h];                                     // n < N/2
        out[3 * h + i] = u[i];                                  // 3N/2 <= n < 2N
    }
    for (int i = h; i < 3 * h; i++)
        out[i] = u[3 * h - 1 - i];                              // N/2 <= n < 3N/2
}

// The float vector helpers (AVFloatDSPContext's C versions).
static void vector_fmul_add(float *dst, const float *src0, const float *src1, const float *src2, int len)
{
    for (int i = 0; i < len; i++) dst[i] = src0[i] * src1[i] + src2[i];
}
static void vector_fmul_reverse(float *dst, const float *src0, const float *src1, int len)
{
    src1 += len - 1;
    for (int i = 0; i < len; i++) dst[i] = src0[i] * src1[-i];
}
static void butterflies_float(float *v1, float *v2, int len)
{
    for (int i = 0; i < len; i++) { float t = v1[i] - v2[i]; v1[i] += v2[i]; v2[i] = t; }
}
static int av_log2(unsigned v) { int n = 0; while (v > 1) { v >>= 1; n++; } return n; }
static double ff_exp10(double x) { return exp2(3.32192809488736234787 * x); }   // libavutil/ffmath.h

// ---- the decoder (libavcodec/wma.c, wma_common.c, wma_freqs.c, wmadec.c) ------------------------------------

static const uint16_t ff_wma_critical_freqs[25] = {
      100,   200,  300,  400,  510,  630,   770,   920,
     1080,  1270, 1480, 1720, 2000, 2320,  2700,  3150,
     3700,  4400, 5300, 6400, 7700, 9500, 12000, 15500,
    24500,
};

#define VLCBITS 9
#define EXPVLCBITS 8
#define HGAINVLCBITS 9

typedef struct WMACodecContext {
    int channels, sample_rate, bit_rate, block_align;
    GetBitContext gb;
    int version;                            ///< 1 = 0x160 (WMAV1), 2 = 0x161 (WMAV2)
    int use_bit_reservoir;
    int use_variable_block_len;
    int use_exp_vlc;                        ///< exponent coding: 0 = lsp, 1 = vlc + delta
    int use_noise_coding;                   ///< true if perceptual noise is added
    int byte_offset_bits;
    VLC exp_vlc;
    int exponent_sizes[BLOCK_NB_SIZES];
    uint16_t exponent_bands[BLOCK_NB_SIZES][25];
    int high_band_start[BLOCK_NB_SIZES];    ///< index of first coef in high band
    int coefs_start;                        ///< first coded coef
    int coefs_end[BLOCK_NB_SIZES];          ///< max number of coded coefficients
    int exponent_high_sizes[BLOCK_NB_SIZES];
    int exponent_high_bands[BLOCK_NB_SIZES][HIGH_BAND_MAX_SIZE];
    VLC hgain_vlc;

    /* coded values in high bands */
    int high_band_coded[MAX_CHANNELS][HIGH_BAND_MAX_SIZE];
    int high_band_values[MAX_CHANNELS][HIGH_BAND_MAX_SIZE];

    /* there are two possible tables for spectral coefficients */
    VLC coef_vlc[2];
    uint16_t *run_table[2];
    float *level_table[2];
    uint16_t *int_table[2];
    const CoefVLCTable *coef_vlcs[2];
    /* frame info */
    int frame_len;                          ///< frame length in samples
    int frame_len_bits;                     ///< frame_len = 1 << frame_len_bits
    int nb_block_sizes;                     ///< number of block sizes
    /* block info */
    int reset_block_lengths;
    int block_len_bits;                     ///< log2 of current block length
    int next_block_len_bits;                ///< log2 of next block length
    int prev_block_len_bits;                ///< log2 of prev block length
    int block_len;                          ///< block length in samples
    int block_num;                          ///< block number in current frame
    int block_pos;                          ///< current position in frame
    uint8_t ms_stereo;                      ///< true if mid/side stereo mode
    uint8_t channel_coded[MAX_CHANNELS];    ///< true if channel is coded
    int exponents_bsize[MAX_CHANNELS];      ///< log2 ratio frame/exp. length
    float exponents[MAX_CHANNELS][BLOCK_MAX_SIZE];
    float max_exponent[MAX_CHANNELS];
    WMACoef coefs1[MAX_CHANNELS][BLOCK_MAX_SIZE];
    float coefs[MAX_CHANNELS][BLOCK_MAX_SIZE];
    float output[BLOCK_MAX_SIZE * 2];
    IMDCT mdct[BLOCK_NB_SIZES];
    float *windows[BLOCK_NB_SIZES];
    /* output buffer for one frame and the last for IMDCT windowing */
    float frame_out[MAX_CHANNELS][BLOCK_MAX_SIZE * 2];
    /* last frame info */
    uint8_t last_superframe[MAX_CODED_SUPERFRAME_SIZE + INPUT_PADDING]; /* padding added */
    int last_bitoffset;
    int last_superframe_len;
    int exponents_initialized[MAX_CHANNELS];
    float noise_table[NOISE_TAB_SIZE];
    int noise_index;
    float noise_mult; /* XXX: suppress that and integrate it in the noise array */
    /* lsp_to_curve tables */
    float lsp_cos_table[BLOCK_MAX_SIZE];
    float lsp_pow_e_table[256];
    float lsp_pow_m_table1[(1 << LSP_POW_BITS)];
    float lsp_pow_m_table2[(1 << LSP_POW_BITS)];

    /* VXRuntime: one packet's decoded frames, planar, before interleaving */
    float pcm[MAX_CHANNELS][16 * BLOCK_MAX_SIZE];
} WMACodecContext;

struct vx_wma { WMACodecContext c; int skip; };   // skip: output frames still to drop (see vx_wma_decode)

static int ff_wma_get_frame_len_bits(int sample_rate, int version, unsigned int decode_flags)
{
    int frame_len_bits;

    (void)decode_flags;
    if (sample_rate <= 16000)
        frame_len_bits = 9;
    else if (sample_rate <= 22050 || (sample_rate <= 32000 && version == 1))
        frame_len_bits = 10;
    else if (sample_rate <= 48000 || version < 3)
        frame_len_bits = 11;
    else if (sample_rate <= 96000)
        frame_len_bits = 12;
    else
        frame_len_bits = 13;
    return frame_len_bits;
}

/* XXX: use same run/length optimization as mpeg decoders */
static int init_coef_vlc(VLC *vlc, uint16_t **prun_table,
                         float **plevel_table, uint16_t **pint_table,
                         const CoefVLCTable *vlc_table)
{
    int n                        = vlc_table->n;
    const uint8_t  *table_bits   = vlc_table->huffbits;
    const uint32_t *table_codes  = vlc_table->huffcodes;
    const uint16_t *levels_table = vlc_table->levels;
    uint16_t *run_table, *int_table;
    float *flevel_table;
    int i, l, j, k, level;

    if (vlc_init_codes(vlc, n, table_bits, table_codes) < 0)
        return -1;

    run_table    = calloc((size_t)n, sizeof(uint16_t));
    flevel_table = calloc((size_t)n, sizeof(*flevel_table));
    int_table    = calloc((size_t)n, sizeof(uint16_t));
    if (!run_table || !flevel_table || !int_table) {
        free(run_table);
        free(flevel_table);
        free(int_table);
        return -1;
    }
    i            = 2;
    level        = 1;
    k            = 0;
    while (i < n) {
        int_table[k] = i;
        l            = levels_table[k++];
        for (j = 0; j < l; j++) {
            run_table[i]    = j;
            flevel_table[i] = level;
            i++;
        }
        level++;
    }
    *prun_table   = run_table;
    *plevel_table = flevel_table;
    *pint_table   = int_table;

    return 0;
}

static void sine_window_init(float *window, int n)
{
    for (int i = 0; i < n; i++)
        window[i] = sinf((i + 0.5) * (M_PI / (2.0 * n)));
}

static int ff_wma_init(WMACodecContext *s, int flags2)
{
    int channels = s->channels;
    int i;
    float bps1, high_freq;
    float bps;
    int sample_rate1;
    int coef_vlc_table;

    if (s->sample_rate > 50000 ||
        channels    > 2            ||
        s->bit_rate    <= 0)
        return -1;

    s->version = 2;

    /* compute MDCT block size */
    s->frame_len_bits = ff_wma_get_frame_len_bits(s->sample_rate,
                                                  s->version, 0);
    s->next_block_len_bits = s->frame_len_bits;
    s->prev_block_len_bits = s->frame_len_bits;
    s->block_len_bits      = s->frame_len_bits;

    s->frame_len = 1 << s->frame_len_bits;
    if (s->use_variable_block_len) {
        int nb_max, nb;
        nb = ((flags2 >> 3) & 3) + 1;
        if ((s->bit_rate / channels) >= 32000)
            nb += 2;
        nb_max = s->frame_len_bits - BLOCK_MIN_BITS;
        if (nb > nb_max)
            nb = nb_max;
        s->nb_block_sizes = nb + 1;
    } else
        s->nb_block_sizes = 1;

    /* init rate dependent parameters */
    s->use_noise_coding = 1;
    high_freq           = s->sample_rate * 0.5;

    /* if version 2, then the rates are normalized */
    sample_rate1 = s->sample_rate;
    if (s->version == 2) {
        if (sample_rate1 >= 44100)
            sample_rate1 = 44100;
        else if (sample_rate1 >= 22050)
            sample_rate1 = 22050;
        else if (sample_rate1 >= 16000)
            sample_rate1 = 16000;
        else if (sample_rate1 >= 11025)
            sample_rate1 = 11025;
        else if (sample_rate1 >= 8000)
            sample_rate1 = 8000;
    }

    bps                 = (float) s->bit_rate /
                          (float) (channels * s->sample_rate);
    s->byte_offset_bits = av_log2((int) (bps * s->frame_len / 8.0 + 0.5)) + 2;
    if (s->byte_offset_bits + 3 > MIN_CACHE_BITS)
        return -1;

    /* compute high frequency value and choose if noise coding should
     * be activated */
    bps1 = bps;
    if (channels == 2)
        bps1 = bps * 1.6;
    if (sample_rate1 == 44100) {
        if (bps1 >= 0.61)
            s->use_noise_coding = 0;
        else
            high_freq = high_freq * 0.4;
    } else if (sample_rate1 == 22050) {
        if (bps1 >= 1.16)
            s->use_noise_coding = 0;
        else if (bps1 >= 0.72)
            high_freq = high_freq * 0.7;
        else
            high_freq = high_freq * 0.6;
    } else if (sample_rate1 == 16000) {
        if (bps > 0.5)
            high_freq = high_freq * 0.5;
        else
            high_freq = high_freq * 0.3;
    } else if (sample_rate1 == 11025)
        high_freq = high_freq * 0.7;
    else if (sample_rate1 == 8000) {
        if (bps <= 0.625)
            high_freq = high_freq * 0.5;
        else if (bps > 0.75)
            s->use_noise_coding = 0;
        else
            high_freq = high_freq * 0.65;
    } else {
        if (bps >= 0.8)
            high_freq = high_freq * 0.75;
        else if (bps >= 0.6)
            high_freq = high_freq * 0.6;
        else
            high_freq = high_freq * 0.5;
    }

    /* compute the scale factor band sizes for each MDCT block size */
    {
        int a, b, pos, lpos, k, block_len, i, j, n;
        const uint8_t *table;

        s->coefs_start = 0;
        for (k = 0; k < s->nb_block_sizes; k++) {
            block_len = s->frame_len >> k;

            /* hardcoded tables */
            table = NULL;
            a     = s->frame_len_bits - BLOCK_MIN_BITS - k;
            if (a < 3) {
                if (s->sample_rate >= 44100)
                    table = exponent_band_44100[a];
                else if (s->sample_rate >= 32000)
                    table = exponent_band_32000[a];
                else if (s->sample_rate >= 22050)
                    table = exponent_band_22050[a];
            }
            if (table) {
                n = *table++;
                for (i = 0; i < n; i++)
                    s->exponent_bands[k][i] = table[i];
                s->exponent_sizes[k] = n;
            } else {
                j    = 0;
                lpos = 0;
                for (i = 0; i < 25; i++) {
                    a     = ff_wma_critical_freqs[i];
                    b     = s->sample_rate;
                    pos   = ((block_len * 2 * a) + (b << 1)) / (4 * b);
                    pos <<= 2;
                    if (pos > block_len)
                        pos = block_len;
                    if (pos > lpos)
                        s->exponent_bands[k][j++] = pos - lpos;
                    if (pos >= block_len)
                        break;
                    lpos = pos;
                }
                s->exponent_sizes[k] = j;
            }

            /* max number of coefs */
            s->coefs_end[k] = (s->frame_len - ((s->frame_len * 9) / 100)) >> k;
            /* high freq computation */
            s->high_band_start[k] = (int) ((block_len * 2 * high_freq) /
                                           s->sample_rate + 0.5);
            n   = s->exponent_sizes[k];
            j   = 0;
            pos = 0;
            for (i = 0; i < n; i++) {
                int start, end;
                start = pos;
                pos  += s->exponent_bands[k][i];
                end   = pos;
                if (start < s->high_band_start[k])
                    start = s->high_band_start[k];
                if (end > s->coefs_end[k])
                    end = s->coefs_end[k];
                if (end > start && j < HIGH_BAND_MAX_SIZE)
                    s->exponent_high_bands[k][j++] = end - start;
            }
            s->exponent_high_sizes[k] = j;
        }
    }

    /* init MDCT windows : simple sine window */
    for (i = 0; i < s->nb_block_sizes; i++) {
        int len = 1 << (s->frame_len_bits - i);
        s->windows[i] = malloc(sizeof(float) * len);
        if (!s->windows[i])
            return -1;
        sine_window_init(s->windows[i], len);
    }

    s->reset_block_lengths = 1;

    if (s->use_noise_coding) {
        /* init the noise generator */
        if (s->use_exp_vlc)
            s->noise_mult = 0.02;
        else
            s->noise_mult = 0.04;

        {
            unsigned int seed;
            float norm;
            seed = 1;
            norm = (1.0 / (float) (1LL << 31)) * sqrt(3) * s->noise_mult;
            for (i = 0; i < NOISE_TAB_SIZE; i++) {
                seed              = seed * 314159 + 1;
                s->noise_table[i] = (float) ((int) seed) * norm;
            }
        }
    }

    /* choose the VLC tables for the coefficients */
    coef_vlc_table = 2;
    if (s->sample_rate >= 32000) {
        if (bps1 < 0.72)
            coef_vlc_table = 0;
        else if (bps1 < 1.16)
            coef_vlc_table = 1;
    }
    s->coef_vlcs[0] = &coef_vlcs[coef_vlc_table * 2];
    s->coef_vlcs[1] = &coef_vlcs[coef_vlc_table * 2 + 1];
    if (init_coef_vlc(&s->coef_vlc[0], &s->run_table[0], &s->level_table[0],
                      &s->int_table[0], s->coef_vlcs[0]) < 0)
        return -1;

    return init_coef_vlc(&s->coef_vlc[1], &s->run_table[1], &s->level_table[1],
                         &s->int_table[1], s->coef_vlcs[1]);
}

static int ff_wma_total_gain_to_bits(int total_gain)
{
    if (total_gain < 15)
        return 13;
    else if (total_gain < 32)
        return 12;
    else if (total_gain < 40)
        return 11;
    else if (total_gain < 45)
        return 10;
    else
        return  9;
}

static void ff_wma_end(WMACodecContext *s)
{
    int i;

    for (i = 0; i < BLOCK_NB_SIZES; i++) {
        imdct_free(&s->mdct[i]);
        free(s->windows[i]);
        s->windows[i] = NULL;
    }
    vlc_free(&s->exp_vlc);
    vlc_free(&s->hgain_vlc);
    for (i = 0; i < 2; i++) {
        vlc_free(&s->coef_vlc[i]);
        free(s->run_table[i]);
        free(s->level_table[i]);
        free(s->int_table[i]);
        s->run_table[i] = NULL; s->level_table[i] = NULL; s->int_table[i] = NULL;
    }
}

/**
 * Decode run level compressed coefficients (WMA v1/v2 escape coding).
 * @return 0 on success, -1 otherwise
 */
static int ff_wma_run_level_decode(GetBitContext *gb,
                                   const VLC *vlc, const float *level_table,
                                   const uint16_t *run_table,
                                   WMACoef *ptr, int offset, int num_coefs,
                                   int block_len, int frame_len_bits,
                                   int coef_nb_bits)
{
    int code, level, sign;
    const unsigned int coef_mask = block_len - 1;
    for (; offset < num_coefs; offset++) {
        code = get_vlc(gb, vlc);
        if (code > 1) {
            /** normal code */
            offset                 += run_table[code];
            sign                    = get_bits1(gb);
            ptr[offset & coef_mask] = sign ? level_table[code] : -level_table[code];
        } else if (code == 1) {
            /** EOB */
            break;
        } else {
            /** escape */
            level = get_bits(gb, coef_nb_bits);
            /** NOTE: this is rather suboptimal. reading
             *  block_len_bits would be better */
            offset += get_bits(gb, frame_len_bits);
            sign                    = get_bits1(gb) - 1;
            ptr[offset & coef_mask] = (level ^ sign) - sign;
        }
    }
    /** NOTE: EOB can be omitted */
    if (offset > num_coefs)
        return -1;

    return 0;
}

static void wma_lsp_to_curve_init(WMACodecContext *s, int frame_len);

static int wma_decode_init(WMACodecContext *s, const uint8_t *extradata, int extradata_size)
{
    int i, flags2;

    if (!s->block_align)
        return -1;

    /* extract flag info */
    flags2 = VX_WMA_XWMA_FLAGS2;                 /* VXRuntime: xWMA's implicit flags (FFmpeg's xwma demuxer) */
    if (extradata && extradata_size >= 6)
        flags2 = extradata[4] | extradata[5] << 8;

    s->use_exp_vlc            = flags2 & 0x0001;
    s->use_bit_reservoir      = flags2 & 0x0002;
    s->use_variable_block_len = flags2 & 0x0004;

    if (extradata && extradata_size >= 8){
        if ((extradata[4] | extradata[5] << 8)==0xd && s->use_variable_block_len){
            s->use_variable_block_len= 0; // this fixes issue1503
        }
    }

    for (i=0; i<MAX_CHANNELS; i++)
        s->max_exponent[i] = 1.0;

    if (ff_wma_init(s, flags2) < 0)
        return -1;

    /* init MDCT */
    for (i = 0; i < s->nb_block_sizes; i++) {
        float scale = 1.0 / 32768.0;
        if (imdct_init(&s->mdct[i], 1 << (s->frame_len_bits - i), scale) < 0)
            return -1;
    }

    if (s->use_noise_coding) {
        if (vlc_init_from_lengths(&s->hgain_vlc, FF_ARRAY_ELEMS(ff_wma_hgain_hufftab),
                                  ff_wma_hgain_hufftab, -18) < 0)
            return -1;
    }

    if (s->use_exp_vlc) {
        if (vlc_init_codes(&s->exp_vlc, sizeof(ff_aac_scalefactor_bits),
                           ff_aac_scalefactor_bits, ff_aac_scalefactor_code) < 0)
            return -1;
    } else
        wma_lsp_to_curve_init(s, s->frame_len);

    return 0;
}

/**
 * compute x^-0.25 with an exponent and mantissa table. We use linear
 * interpolation to reduce the mantissa table size at a small speed
 * expense (linear interpolation approximately doubles the number of
 * bits of precision).
 */
static inline float pow_m1_4(WMACodecContext *s, float x)
{
    union {
        float f;
        unsigned int v;
    } u, t;
    unsigned int e, m;
    float a, b;

    u.f = x;
    e   =  u.v >>  23;
    m   = (u.v >> (23 - LSP_POW_BITS)) & ((1 << LSP_POW_BITS) - 1);
    /* build interpolation scale: 1 <= t < 2. */
    t.v = ((u.v << LSP_POW_BITS) & ((1 << 23) - 1)) | (127 << 23);
    a   = s->lsp_pow_m_table1[m];
    b   = s->lsp_pow_m_table2[m];
    return s->lsp_pow_e_table[e & 255] * (a + b * t.f);
}

static void wma_lsp_to_curve_init(WMACodecContext *s, int frame_len)
{
    float wdel, a, b;
    int i, e, m;

    wdel = M_PI / frame_len;
    for (i = 0; i < frame_len; i++)
        s->lsp_cos_table[i] = 2.0f * cos(wdel * i);

    /* tables for x^-0.25 computation */
    for (i = 0; i < 256; i++) {
        e                     = i - 126;
        s->lsp_pow_e_table[i] = exp2f(e * -0.25);
    }

    /* NOTE: these two tables are needed to avoid two operations in
     * pow_m1_4 */
    b = 1.0;
    for (i = (1 << LSP_POW_BITS) - 1; i >= 0; i--) {
        m                      = (1 << LSP_POW_BITS) + i;
        a                      = (float) m * (0.5 / (1 << LSP_POW_BITS));
        a                      = 1/sqrt(sqrt(a));
        s->lsp_pow_m_table1[i] = 2 * a - b;
        s->lsp_pow_m_table2[i] = b - a;
        b                      = a;
    }
}

/**
 * NOTE: We use the same code as Vorbis here
 */
static void wma_lsp_to_curve(WMACodecContext *s, float *out, float *val_max_ptr,
                             int n, float *lsp)
{
    int i, j;
    float p, q, w, v, val_max;

    val_max = 0;
    for (i = 0; i < n; i++) {
        p = 0.5f;
        q = 0.5f;
        w = s->lsp_cos_table[i];
        for (j = 1; j < NB_LSP_COEFS; j += 2) {
            q *= w - lsp[j - 1];
            p *= w - lsp[j];
        }
        p *= p * (2.0f - w);
        q *= q * (2.0f + w);
        v  = p + q;
        v  = pow_m1_4(s, v);
        if (v > val_max)
            val_max = v;
        out[i] = v;
    }
    *val_max_ptr = val_max;
}

/**
 * decode exponents coded with LSP coefficients (same idea as Vorbis)
 */
static void decode_exp_lsp(WMACodecContext *s, int ch)
{
    float lsp_coefs[NB_LSP_COEFS];
    int val, i;

    for (i = 0; i < NB_LSP_COEFS; i++) {
        if (i == 0 || i >= 8)
            val = get_bits(&s->gb, 3);
        else
            val = get_bits(&s->gb, 4);
        lsp_coefs[i] = ff_wma_lsp_codebook[i][val];
    }

    wma_lsp_to_curve(s, s->exponents[ch], &s->max_exponent[ch],
                     s->block_len, lsp_coefs);
}

/** pow(10, i / 16.0) for i in -60..95 */
static const float pow_tab[] = {
    1.7782794100389e-04, 2.0535250264571e-04,
    2.3713737056617e-04, 2.7384196342644e-04,
    3.1622776601684e-04, 3.6517412725484e-04,
    4.2169650342858e-04, 4.8696752516586e-04,
    5.6234132519035e-04, 6.4938163157621e-04,
    7.4989420933246e-04, 8.6596432336006e-04,
    1.0000000000000e-03, 1.1547819846895e-03,
    1.3335214321633e-03, 1.5399265260595e-03,
    1.7782794100389e-03, 2.0535250264571e-03,
    2.3713737056617e-03, 2.7384196342644e-03,
    3.1622776601684e-03, 3.6517412725484e-03,
    4.2169650342858e-03, 4.8696752516586e-03,
    5.6234132519035e-03, 6.4938163157621e-03,
    7.4989420933246e-03, 8.6596432336006e-03,
    1.0000000000000e-02, 1.1547819846895e-02,
    1.3335214321633e-02, 1.5399265260595e-02,
    1.7782794100389e-02, 2.0535250264571e-02,
    2.3713737056617e-02, 2.7384196342644e-02,
    3.1622776601684e-02, 3.6517412725484e-02,
    4.2169650342858e-02, 4.8696752516586e-02,
    5.6234132519035e-02, 6.4938163157621e-02,
    7.4989420933246e-02, 8.6596432336007e-02,
    1.0000000000000e-01, 1.1547819846895e-01,
    1.3335214321633e-01, 1.5399265260595e-01,
    1.7782794100389e-01, 2.0535250264571e-01,
    2.3713737056617e-01, 2.7384196342644e-01,
    3.1622776601684e-01, 3.6517412725484e-01,
    4.2169650342858e-01, 4.8696752516586e-01,
    5.6234132519035e-01, 6.4938163157621e-01,
    7.4989420933246e-01, 8.6596432336007e-01,
    1.0000000000000e+00, 1.1547819846895e+00,
    1.3335214321633e+00, 1.5399265260595e+00,
    1.7782794100389e+00, 2.0535250264571e+00,
    2.3713737056617e+00, 2.7384196342644e+00,
    3.1622776601684e+00, 3.6517412725484e+00,
    4.2169650342858e+00, 4.8696752516586e+00,
    5.6234132519035e+00, 6.4938163157621e+00,
    7.4989420933246e+00, 8.6596432336007e+00,
    1.0000000000000e+01, 1.1547819846895e+01,
    1.3335214321633e+01, 1.5399265260595e+01,
    1.7782794100389e+01, 2.0535250264571e+01,
    2.3713737056617e+01, 2.7384196342644e+01,
    3.1622776601684e+01, 3.6517412725484e+01,
    4.2169650342858e+01, 4.8696752516586e+01,
    5.6234132519035e+01, 6.4938163157621e+01,
    7.4989420933246e+01, 8.6596432336007e+01,
    1.0000000000000e+02, 1.1547819846895e+02,
    1.3335214321633e+02, 1.5399265260595e+02,
    1.7782794100389e+02, 2.0535250264571e+02,
    2.3713737056617e+02, 2.7384196342644e+02,
    3.1622776601684e+02, 3.6517412725484e+02,
    4.2169650342858e+02, 4.8696752516586e+02,
    5.6234132519035e+02, 6.4938163157621e+02,
    7.4989420933246e+02, 8.6596432336007e+02,
    1.0000000000000e+03, 1.1547819846895e+03,
    1.3335214321633e+03, 1.5399265260595e+03,
    1.7782794100389e+03, 2.0535250264571e+03,
    2.3713737056617e+03, 2.7384196342644e+03,
    3.1622776601684e+03, 3.6517412725484e+03,
    4.2169650342858e+03, 4.8696752516586e+03,
    5.6234132519035e+03, 6.4938163157621e+03,
    7.4989420933246e+03, 8.6596432336007e+03,
    1.0000000000000e+04, 1.1547819846895e+04,
    1.3335214321633e+04, 1.5399265260595e+04,
    1.7782794100389e+04, 2.0535250264571e+04,
    2.3713737056617e+04, 2.7384196342644e+04,
    3.1622776601684e+04, 3.6517412725484e+04,
    4.2169650342858e+04, 4.8696752516586e+04,
    5.6234132519035e+04, 6.4938163157621e+04,
    7.4989420933246e+04, 8.6596432336007e+04,
    1.0000000000000e+05, 1.1547819846895e+05,
    1.3335214321633e+05, 1.5399265260595e+05,
    1.7782794100389e+05, 2.0535250264571e+05,
    2.3713737056617e+05, 2.7384196342644e+05,
    3.1622776601684e+05, 3.6517412725484e+05,
    4.2169650342858e+05, 4.8696752516586e+05,
    5.6234132519035e+05, 6.4938163157621e+05,
    7.4989420933246e+05, 8.6596432336007e+05,
};

/**
 * decode exponents coded with VLC codes
 */
static int decode_exp_vlc(WMACodecContext *s, int ch)
{
    int last_exp, n, code;
    const uint16_t *ptr;
    float v, max_scale;
    float *q, *q_end;
    const float *ptab = pow_tab + 60;

    ptr       = s->exponent_bands[s->frame_len_bits - s->block_len_bits];
    q         = s->exponents[ch];
    q_end     = q + s->block_len;
    max_scale = 0;
    last_exp = 36;

    while (q < q_end) {
        code = get_vlc(&s->gb, &s->exp_vlc);
        /* NOTE: this offset is the same as MPEG-4 AAC! */
        last_exp += code - 60;
        if ((unsigned) last_exp + 60 >= FF_ARRAY_ELEMS(pow_tab))
            return -1;
        v  = ptab[last_exp];
        if (v > max_scale)
            max_scale = v;
        n = *ptr++;
        do {                                    /* (FFmpeg: an unrolled loop of the same stores) */
            *q++ = v;
        } while (--n > 0 && q < q_end);
    }
    s->max_exponent[ch] = max_scale;
    return 0;
}

/**
 * Apply MDCT window and add into output.
 *
 * We ensure that when the windows overlap their squared sum
 * is always 1 (MDCT reconstruction rule).
 */
static void wma_window(WMACodecContext *s, float *out)
{
    float *in = s->output;
    int block_len, bsize, n;

    /* left part */
    if (s->block_len_bits <= s->prev_block_len_bits) {
        block_len = s->block_len;
        bsize     = s->frame_len_bits - s->block_len_bits;

        vector_fmul_add(out, in, s->windows[bsize],
                        out, block_len);
    } else {
        block_len = 1 << s->prev_block_len_bits;
        n         = (s->block_len - block_len) / 2;
        bsize     = s->frame_len_bits - s->prev_block_len_bits;

        vector_fmul_add(out + n, in + n, s->windows[bsize],
                        out + n, block_len);

        memcpy(out + n + block_len, in + n + block_len, n * sizeof(float));
    }

    out += s->block_len;
    in  += s->block_len;

    /* right part */
    if (s->block_len_bits <= s->next_block_len_bits) {
        block_len = s->block_len;
        bsize     = s->frame_len_bits - s->block_len_bits;

        vector_fmul_reverse(out, in, s->windows[bsize], block_len);
    } else {
        block_len = 1 << s->next_block_len_bits;
        n         = (s->block_len - block_len) / 2;
        bsize     = s->frame_len_bits - s->next_block_len_bits;

        memcpy(out, in, n * sizeof(float));

        vector_fmul_reverse(out + n, in + n, s->windows[bsize],
                            block_len);

        memset(out + n + block_len, 0, n * sizeof(float));
    }
}

/**
 * @return
 * 0 if OK.
 * 1 if last block of frame.
 * -1 if unrecoverable error.
 */
static int wma_decode_block(WMACodecContext *s)
{
    int channels = s->channels;
    int n, v, a, bsize;
    int coef_nb_bits, total_gain;
    int nb_coefs[MAX_CHANNELS];
    float mdct_norm;

    /* compute current block length */
    if (s->use_variable_block_len) {
        n = av_log2(s->nb_block_sizes - 1) + 1;

        if (s->reset_block_lengths) {
            s->reset_block_lengths = 0;
            v                      = get_bits(&s->gb, n);
            if (v >= s->nb_block_sizes)
                return -1;
            s->prev_block_len_bits = s->frame_len_bits - v;
            v                      = get_bits(&s->gb, n);
            if (v >= s->nb_block_sizes)
                return -1;
            s->block_len_bits = s->frame_len_bits - v;
        } else {
            /* update block lengths */
            s->prev_block_len_bits = s->block_len_bits;
            s->block_len_bits      = s->next_block_len_bits;
        }
        v = get_bits(&s->gb, n);
        if (v >= s->nb_block_sizes)
            return -1;
        s->next_block_len_bits = s->frame_len_bits - v;
    } else {
        /* fixed block len */
        s->next_block_len_bits = s->frame_len_bits;
        s->prev_block_len_bits = s->frame_len_bits;
        s->block_len_bits      = s->frame_len_bits;
    }

    if (s->frame_len_bits - s->block_len_bits >= s->nb_block_sizes)
        return -1;

    /* now check if the block length is coherent with the frame length */
    s->block_len = 1 << s->block_len_bits;
    if ((s->block_pos + s->block_len) > s->frame_len)
        return -1;

    if (channels == 2)
        s->ms_stereo = get_bits1(&s->gb);
    v = 0;
    for (int ch = 0; ch < channels; ch++) {
        a                    = get_bits1(&s->gb);
        s->channel_coded[ch] = a;
        v                   |= a;
    }

    bsize = s->frame_len_bits - s->block_len_bits;

    /* if no channel coded, no need to go further */
    /* XXX: fix potential framing problems */
    if (!v)
        goto next;

    /* read total gain and extract corresponding number of bits for
     * coef escape coding */
    total_gain = 1;
    for (;;) {
        if (get_bits_left(&s->gb) < 7)
            return -1;
        a           = get_bits(&s->gb, 7);
        total_gain += a;
        if (a != 127)
            break;
    }

    coef_nb_bits = ff_wma_total_gain_to_bits(total_gain);

    /* compute number of coefficients */
    n = s->coefs_end[bsize] - s->coefs_start;
    for (int ch = 0; ch < channels; ch++)
        nb_coefs[ch] = n;

    /* complex coding */
    if (s->use_noise_coding) {
        for (int ch = 0; ch < channels; ch++) {
            if (s->channel_coded[ch]) {
                int n;
                n = s->exponent_high_sizes[bsize];
                for (int i = 0; i < n; i++) {
                    const unsigned a          = get_bits1(&s->gb);
                    s->high_band_coded[ch][i] = a;
                    /* if noise coding, the coefficients are not transmitted */
                    if (a)
                        nb_coefs[ch] -= s->exponent_high_bands[bsize][i];
                }
            }
        }
        for (int ch = 0; ch < channels; ch++) {
            if (s->channel_coded[ch]) {
                int n, val;

                n   = s->exponent_high_sizes[bsize];
                val = (int) 0x80000000;
                for (int i = 0; i < n; i++) {
                    if (s->high_band_coded[ch][i]) {
                        if (val == (int) 0x80000000) {
                            val = get_bits(&s->gb, 7) - 19;
                        } else {
                            val += get_vlc(&s->gb, &s->hgain_vlc);
                        }
                        s->high_band_values[ch][i] = val;
                    }
                }
            }
        }
    }

    /* exponents can be reused in short blocks. */
    if ((s->block_len_bits == s->frame_len_bits) || get_bits1(&s->gb)) {
        for (int ch = 0; ch < channels; ch++) {
            if (s->channel_coded[ch]) {
                if (s->use_exp_vlc) {
                    if (decode_exp_vlc(s, ch) < 0)
                        return -1;
                } else {
                    decode_exp_lsp(s, ch);
                }
                s->exponents_bsize[ch] = bsize;
                s->exponents_initialized[ch] = 1;
            }
        }
    }

    for (int ch = 0; ch < channels; ch++) {
        if (s->channel_coded[ch] && !s->exponents_initialized[ch])
            return -1;
    }

    /* parse spectral coefficients : just RLE encoding */
    for (int ch = 0; ch < channels; ch++) {
        if (s->channel_coded[ch]) {
            int tindex;
            WMACoef *ptr = &s->coefs1[ch][0];
            int ret;

            /* special VLC tables are used for ms stereo because
             * there is potentially less energy there */
            tindex = (ch == 1 && s->ms_stereo);
            memset(ptr, 0, s->block_len * sizeof(WMACoef));
            ret = ff_wma_run_level_decode(&s->gb, &s->coef_vlc[tindex],
                                          s->level_table[tindex], s->run_table[tindex],
                                          ptr, 0, nb_coefs[ch],
                                          s->block_len, s->frame_len_bits, coef_nb_bits);
            if (ret < 0)
                return ret;
        }
    }

    /* normalize */
    {
        int n4 = s->block_len / 2;
        mdct_norm = 1.0 / (float) n4;
    }

    /* finally compute the MDCT coefficients */
    for (int ch = 0; ch < channels; ch++) {
        if (s->channel_coded[ch]) {
            WMACoef *coefs1;
            float *coefs, *exponents, mult, mult1, noise;
            int n, n1, last_high_band, esize;
            float exp_power[HIGH_BAND_MAX_SIZE];

            coefs1    = s->coefs1[ch];
            exponents = s->exponents[ch];
            esize     = s->exponents_bsize[ch];
            mult      = ff_exp10(total_gain * 0.05) / s->max_exponent[ch];
            mult     *= mdct_norm;
            coefs     = s->coefs[ch];
            if (s->use_noise_coding) {
                mult1 = mult;
                /* very low freqs : noise */
                for (int i = 0; i < s->coefs_start; i++) {
                    *coefs++ = s->noise_table[s->noise_index] *
                               exponents[i << bsize >> esize] * mult1;
                    s->noise_index = (s->noise_index + 1) &
                                     (NOISE_TAB_SIZE - 1);
                }

                n1 = s->exponent_high_sizes[bsize];

                /* compute power of high bands */
                exponents = s->exponents[ch] +
                            (s->high_band_start[bsize] << bsize >> esize);
                last_high_band = 0; /* avoid warning */
                for (int j = 0; j < n1; j++) {
                    n = s->exponent_high_bands[s->frame_len_bits -
                                               s->block_len_bits][j];
                    if (s->high_band_coded[ch][j]) {
                        float e2, v;
                        e2 = 0;
                        for (int i = 0; i < n; i++) {
                            v   = exponents[i << bsize >> esize];
                            e2 += v * v;
                        }
                        exp_power[j]   = e2 / n;
                        last_high_band = j;
                    }
                    exponents += n << bsize >> esize;
                }

                /* main freqs and high freqs */
                exponents = s->exponents[ch] + (s->coefs_start << bsize >> esize);
                for (int j = -1; j < n1; j++) {
                    if (j < 0)
                        n = s->high_band_start[bsize] - s->coefs_start;
                    else
                        n = s->exponent_high_bands[s->frame_len_bits -
                                                   s->block_len_bits][j];
                    if (j >= 0 && s->high_band_coded[ch][j]) {
                        /* use noise with specified power */
                        mult1 = sqrt(exp_power[j] / exp_power[last_high_band]);
                        /* XXX: use a table */
                        mult1  = mult1 * ff_exp10(s->high_band_values[ch][j] * 0.05);
                        mult1  = mult1 / (s->max_exponent[ch] * s->noise_mult);
                        mult1 *= mdct_norm;
                        for (int i = 0; i < n; i++) {
                            noise          = s->noise_table[s->noise_index];
                            s->noise_index = (s->noise_index + 1) & (NOISE_TAB_SIZE - 1);
                            *coefs++       = noise * exponents[i << bsize >> esize] * mult1;
                        }
                        exponents += n << bsize >> esize;
                    } else {
                        /* coded values + small noise */
                        for (int i = 0; i < n; i++) {
                            noise          = s->noise_table[s->noise_index];
                            s->noise_index = (s->noise_index + 1) & (NOISE_TAB_SIZE - 1);
                            *coefs++       = ((*coefs1++) + noise) *
                                             exponents[i << bsize >> esize] * mult;
                        }
                        exponents += n << bsize >> esize;
                    }
                }

                /* very high freqs : noise */
                n     = s->block_len - s->coefs_end[bsize];
                mult1 = mult * exponents[(-(1 << bsize)) >> esize];
                for (int i = 0; i < n; i++) {
                    *coefs++       = s->noise_table[s->noise_index] * mult1;
                    s->noise_index = (s->noise_index + 1) & (NOISE_TAB_SIZE - 1);
                }
            } else {
                /* XXX: optimize more */
                for (int i = 0; i < s->coefs_start; i++)
                    *coefs++ = 0.0;
                n = nb_coefs[ch];
                for (int i = 0; i < n; i++)
                    *coefs++ = coefs1[i] * exponents[i << bsize >> esize] * mult;
                n = s->block_len - s->coefs_end[bsize];
                for (int i = 0; i < n; i++)
                    *coefs++ = 0.0;
            }
        }
    }

    if (s->ms_stereo && s->channel_coded[1]) {
        /* nominal case for ms stereo: we do it before mdct */
        /* no need to optimize this case because it should almost
         * never happen */
        if (!s->channel_coded[0]) {
            memset(s->coefs[0], 0, sizeof(float) * s->block_len);
            s->channel_coded[0] = 1;
        }

        butterflies_float(s->coefs[0], s->coefs[1], s->block_len);
    }

next:
    for (int ch = 0; ch < channels; ch++) {
        int n4, index;

        n4 = s->block_len / 2;
        if (s->channel_coded[ch])
            imdct_calc(&s->mdct[bsize], s->output, s->coefs[ch]);
        else if (!(s->ms_stereo && ch == 1))
            memset(s->output, 0, sizeof(s->output));

        /* multiply by the window and add in the frame */
        index = (s->frame_len / 2) + s->block_pos - n4;
        wma_window(s, &s->frame_out[ch][index]);
    }

    /* update block number */
    s->block_num++;
    s->block_pos += s->block_len;
    if (s->block_pos >= s->frame_len)
        return 1;
    else
        return 0;
}

/* decode a frame of frame_len samples */
static int wma_decode_frame(WMACodecContext *s, int samples_offset)
{
    /* read each block */
    s->block_num = 0;
    s->block_pos = 0;
    for (;;) {
        int ret = wma_decode_block(s);
        if (ret < 0)
            return ret;
        if (ret)
            break;
    }

    for (int ch = 0; ch < s->channels; ch++) {
        /* copy current block to output */
        memcpy(s->pcm[ch] + samples_offset, s->frame_out[ch],
               s->frame_len * sizeof(*s->frame_out[ch]));
        /* prepare for next block */
        memmove(&s->frame_out[ch][0], &s->frame_out[ch][s->frame_len],
                s->frame_len * sizeof(*s->frame_out[ch]));
    }

    return 0;
}

/* Returns the frames decoded into s->pcm, or -1. */
static int wma_decode_superframe(WMACodecContext *s, const uint8_t *buf, int buf_size)
{
    int nb_frames, bit_offset, pos, len, ret;
    uint8_t *q;
    int samples_offset;

    if (buf_size < s->block_align)
        return -1;
    if (s->block_align)
        buf_size = s->block_align;

    init_get_bits(&s->gb, buf, buf_size * 8);

    if (s->use_bit_reservoir) {
        /* read super frame header */
        skip_bits(&s->gb, 4); /* super frame index */
        nb_frames = get_bits(&s->gb, 4) - (s->last_superframe_len <= 0);
        if (nb_frames <= 0) {
            int is_error = nb_frames < 0 || get_bits_left(&s->gb) <= 8;
            if (is_error)
                return -1;

            if ((s->last_superframe_len + buf_size - 1) >
                MAX_CODED_SUPERFRAME_SIZE) {
                ret = -1;
                goto fail;
            }

            q   = s->last_superframe + s->last_superframe_len;
            len = buf_size - 1;
            while (len > 0) {
                *q++ = get_bits (&s->gb, 8);
                len --;
            }
            memset(q, 0, INPUT_PADDING);

            s->last_superframe_len += 8*buf_size - 8;
            return 0;
        }
    } else
        nb_frames = 1;

    int total = nb_frames * s->frame_len;
    samples_offset = 0;

    if (s->use_bit_reservoir) {
        bit_offset = get_bits(&s->gb, s->byte_offset_bits + 3);
        if (bit_offset > get_bits_left(&s->gb)) {
            ret = -1;
            goto fail;
        }

        if (s->last_superframe_len > 0) {
            /* add bit_offset bits to last frame */
            if ((s->last_superframe_len + ((bit_offset + 7) >> 3)) >
                MAX_CODED_SUPERFRAME_SIZE) {
                ret = -1;
                goto fail;
            }
            q   = s->last_superframe + s->last_superframe_len;
            len = bit_offset;
            while (len > 7) {
                *q++ = get_bits(&s->gb, 8);
                len -= 8;
            }
            if (len > 0)
                *q++ = get_bits(&s->gb, len) << (8 - len);
            memset(q, 0, INPUT_PADDING);

            /* XXX: bit_offset bits into last frame */
            init_get_bits(&s->gb, s->last_superframe,
                          s->last_superframe_len * 8 + bit_offset);
            /* skip unused bits */
            if (s->last_bitoffset > 0)
                skip_bits(&s->gb, s->last_bitoffset);
            /* this frame is stored in the last superframe and in the
             * current one */
            if ((ret = wma_decode_frame(s, samples_offset)) < 0)
                goto fail;
            samples_offset += s->frame_len;
            nb_frames--;
        }

        /* read each frame starting from bit_offset */
        pos = bit_offset + 4 + 4 + s->byte_offset_bits + 3;
        if (pos >= MAX_CODED_SUPERFRAME_SIZE * 8 || pos > buf_size * 8)
            return -1;
        init_get_bits(&s->gb, buf + (pos >> 3), (buf_size - (pos >> 3)) * 8);
        len = pos & 7;
        if (len > 0)
            skip_bits(&s->gb, len);

        s->reset_block_lengths = 1;
        for (int i = 0; i < nb_frames; i++) {
            if ((ret = wma_decode_frame(s, samples_offset)) < 0)
                goto fail;
            samples_offset += s->frame_len;
        }

        /* we copy the end of the frame in the last frame buffer */
        pos               = get_bits_count(&s->gb) +
                            ((bit_offset + 4 + 4 + s->byte_offset_bits + 3) & ~7);
        s->last_bitoffset = pos & 7;
        pos             >>= 3;
        len               = buf_size - pos;
        if (len > MAX_CODED_SUPERFRAME_SIZE || len < 0) {
            ret = -1;
            goto fail;
        }
        s->last_superframe_len = len;
        memcpy(s->last_superframe, buf + pos, len);
    } else {
        /* single frame decode */
        if ((ret = wma_decode_frame(s, samples_offset)) < 0)
            goto fail;
        samples_offset += s->frame_len;
    }

    return total;

fail:
    /* when error, we reset the bit reservoir */
    s->last_superframe_len = 0;
    return ret;
}

// ---- VXRuntime's interface (wmadec.h) ---------------------------------------------------------------------------

vx_wma *vx_wma_open(int channels, int sample_rate, int bit_rate, int block_align, const uint8_t *extra, int extra_size)
{
    if (channels < 1 || channels > MAX_CHANNELS || sample_rate <= 0 || bit_rate <= 0 || block_align <= 0 ||
        block_align > MAX_CODED_SUPERFRAME_SIZE)
        return NULL;
    vx_wma *w = calloc(1, sizeof *w);
    if (!w)
        return NULL;
    WMACodecContext *s = &w->c;
    s->channels = channels; s->sample_rate = sample_rate; s->bit_rate = bit_rate; s->block_align = block_align;
    if (wma_decode_init(s, extra, extra_size) < 0) {
        vx_wma_close(w);
        return NULL;
    }
    w->skip = s->frame_len;
    return w;
}
void vx_wma_close(vx_wma *w)
{
    if (!w)
        return;
    ff_wma_end(&w->c);
    free(w);
}
void vx_wma_reset(vx_wma *w)
{
    WMACodecContext *s = &w->c;
    s->last_bitoffset = s->last_superframe_len = 0;      // (FFmpeg's flush)
    // VXRuntime: and the rest of what a fresh decoder starts with, so a stream decodes the same every time
    memset(s->frame_out, 0, sizeof s->frame_out);
    s->reset_block_lengths = 1;
    s->noise_index = 0;
    for (int i = 0; i < MAX_CHANNELS; i++) {
        s->exponents_initialized[i] = 0;
        s->max_exponent[i] = 1.0;
    }
    w->skip = s->frame_len;
}
int vx_wma_frame_len(const vx_wma *w) { return w->c.frame_len; }
int vx_wma_max_frames(const vx_wma *w) { return 15 * w->c.frame_len; }

static int16_t to_s16(float f)
{
    long v = lrintf(f * 32768.0f);
    return (int16_t)(v < -32768 ? -32768 : v > 32767 ? 32767 : v);
}
int vx_wma_decode(vx_wma *w, const uint8_t *packet, int size, int16_t *out)
{
    WMACodecContext *s = &w->c;
    int n = wma_decode_superframe(s, packet, size);
    if (n <= 0)
        return n;
    // The first frame a stream decodes to is the overlap of nothing (silence); xWMA's packet tables count the
    // output without it, so it is dropped. (FFmpeg instead drops two frames, its decoder delay, and appends the
    // last frame's overlap at the end of the stream: the same total, one frame later.)
    int first = w->skip < n ? w->skip : n;
    w->skip -= first;
    for (int i = first; i < n; i++)
        for (int ch = 0; ch < s->channels; ch++)
            out[(i - first) * s->channels + ch] = to_s16(s->pcm[ch][i]);
    return n - first;
}
