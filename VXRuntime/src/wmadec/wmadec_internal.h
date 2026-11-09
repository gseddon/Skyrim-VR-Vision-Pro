/*
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
 * Derived from FFmpeg (libavcodec/wma.h, FFmpeg revision bf1b838f2ab88b4f8fd83443325c782ea0e0f7fa, tag n9.0.1)
 * for VXRuntime's XAudio2 xWMA decoder. Local modifications (2026-11-09): only the constants and the
 * CoefVLCTable type the tables in wmadata.h need are kept; the codec context is in wmadec.c, without libavcodec's
 * AVCodecContext, GetBitContext, VLC, AVTXContext and AVFloatDSPContext. See src/wmadec/SOURCE.md.
 */

#ifndef VX_WMADEC_INTERNAL_H
#define VX_WMADEC_INTERNAL_H

#include <stdint.h>

/* size of blocks */
#define BLOCK_MIN_BITS 7
#define BLOCK_MAX_BITS 11
#define BLOCK_MAX_SIZE (1 << BLOCK_MAX_BITS)

#define BLOCK_NB_SIZES (BLOCK_MAX_BITS - BLOCK_MIN_BITS + 1)

/* XXX: find exact max size */
#define HIGH_BAND_MAX_SIZE 16

#define NB_LSP_COEFS 10

/* XXX: is it a suitable value ? */
#define MAX_CODED_SUPERFRAME_SIZE 32768

#define MAX_CHANNELS 2

#define NOISE_TAB_SIZE 8192

#define LSP_POW_BITS 7

typedef float WMACoef;          ///< type for decoded coefficients, int16_t would be enough for wma 1/2

typedef struct CoefVLCTable {
    int n;                      ///< total number of codes
    int max_level;
    const uint32_t *huffcodes;  ///< VLC bit values
    const uint8_t *huffbits;    ///< VLC bit size
    const uint16_t *levels;     ///< table to build run/level tables
} CoefVLCTable;

#endif /* VX_WMADEC_INTERNAL_H */
