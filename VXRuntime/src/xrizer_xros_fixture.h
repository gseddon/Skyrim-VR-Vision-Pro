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
#ifdef __cplusplus
}
#endif
