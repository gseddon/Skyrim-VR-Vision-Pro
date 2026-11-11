/* Visibility-mask parameters for the Klepton provider (XR_KHR_visibility_mask), shared by the headset host
 * (xrizer_xros_host.m) and the Mac dev host (xrizer_dev_host.m). Levers: see vismask_shape.h. */
#ifndef VXRT_XRIZER_VISMASK_HOST_H
#define VXRT_XRIZER_VISMASK_HOST_H
#include "visibility_host.h"
#include "vismask_shape.h"
void vx_log(const char *fmt, ...);
static inline int vx_vismask_params(uint32_t eye, KlNativeVisibilityParams *out) {
    static int logged[2]; float v[5]; int on;
    int bad = vx_vismask_shape(eye, &on, v);
    *out = (KlNativeVisibilityParams){.enabled = on, .inset_left = v[0], .inset_right = v[1], .inset_up = v[2], .inset_down = v[3], .radius = v[4]};
    if (!logged[eye & 1]) {
        logged[eye & 1] = 1;
        if (bad) vx_log("vismask: VXRT_VISMASK_SHAPE is not l,r,u,d,radius: using the default %s", VX_VISMASK_DEFAULT_SHAPE);
        vx_log("vismask: eye %u the game asked for the hidden-area mesh: mask %s shape l=%.3f r=%.3f u=%.3f d=%.3f radius %.2f",
               eye, on ? "ON" : "off", v[0], v[1], v[2], v[3], v[4]);
    }
    return 0;
}
static inline XrResult vx_vismask_get_params(void *ctx, uint32_t eye, KlNativeVisibilityParams *out) {
    (void)ctx; if (!out || eye > 1) return XR_ERROR_VALIDATION_FAILURE; vx_vismask_params(eye, out); return XR_SUCCESS;
}
#endif
