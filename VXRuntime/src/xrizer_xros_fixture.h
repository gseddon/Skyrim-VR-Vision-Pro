/* Explicit simulator-only integration with the existing immersive compositor. */
#pragma once
#include <stdint.h>
#include "native_vr.h"
#ifdef __cplusplus
extern "C" {
#endif
int vx_xros_fixture_enabled(void);
int vx_xros_fixture_start(void *device, void *queue);
/* Drawables supply their actual optical transforms and tangents; prediction is
 * in the verified compositor/Mach seconds epoch. A null head is identity and
 * untracked. Tracked bits require the caller's observed device anchor. */
int vx_xros_fixture_offer(uint32_t width, uint32_t height, const float eyes[32],
                          const float tangents[8], double prediction, const float head[16], int tracked);
/* One-way surface loss; no restart or re-registration in this process. */
int vx_xros_fixture_surface_lost(void);
int vx_xros_fixture_wait_ready(void);
int vx_xros_fixture_present_begin(double time);
int vx_xros_fixture_acquire(vx_native_vr_frame *frame);
int vx_xros_fixture_release(uint64_t lease);
/* VXRT_XRIZER_XROS_PRESENT=1 (with the offscreen producer): the simulator's
 * single-view drawable shows the acquired provider pair side by side, left eye
 * in the left half. This is an inspection layout for a mono simulator surface,
 * not stereo display. */
int vx_xros_fixture_present_enabled(void);
/* Encodes the side-by-side pair into `color` (view 0 only) and a readback of
 * each eye's 4x3 texel centres after it; returns 1 when encoded. */
int vx_xros_fixture_draw_inspection(void *cb, int view, void *color, void *depth);
/* Called from the drawable command buffer's completion with RGBA bytes
 * (2 eyes x 3 rows x 4 columns x 4), the drawable format and completion. */
void vx_xros_fixture_record_drawable(uint64_t frame_id, uint64_t pose_id, int completed, uint32_t format,
                                     const unsigned char samples[96]);
#ifdef __cplusplus
}
#endif
