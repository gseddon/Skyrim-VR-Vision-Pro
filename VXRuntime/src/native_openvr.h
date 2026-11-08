#ifndef VX_NATIVE_OPENVR_H
#define VX_NATIVE_OPENVR_H
#include "native_vr.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t sequence;
    double sample_time;
    uint32_t connected, tracking_valid;
    float origin_from_grip[16];
    uint64_t pressed, touched;
    float axis[5][2];
} vx_native_openvr_controller;

// Host-side interface. A headset supplies poses and consumes completed frame leases.
int vx_native_openvr_enabled(void);
vx_native_vr *vx_native_openvr_queue(void);
int vx_native_openvr_set_render_size(uint32_t width, uint32_t height);
int vx_native_openvr_set_state(const vx_native_vr_pose *pose, const vx_native_openvr_controller controllers[2]);
int vx_native_openvr_set_pose(const vx_native_vr_pose *pose);
void *vx_native_openvr_export(const char *name);
#ifdef __cplusplus
}
#endif
#endif
