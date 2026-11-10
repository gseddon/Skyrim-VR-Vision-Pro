/* XR_KHR_visibility_mask host boundary and mesh generator; MIT, see ../LICENSE.
 * Local to this repository (not derived from Klepton). */
#ifndef KL_NATIVE_VISIBILITY_HOST_H
#define KL_NATIVE_VISIBILITY_HOST_H
#include <openxr/openxr.h>
#include <stdint.h>
#define KL_NATIVE_VISIBILITY_HOST_VERSION 1u
/* The visible region of one eye image is a rounded rectangle inside the eye's
 * field of view. Insets are fractions (0..0.45) of the eye's full tangent width
 * (left, right) or height (up, down), measured inward from that FOV edge, so
 * 0 keeps the whole edge. radius is the corner radius as a fraction (0..1) of
 * the smaller half-extent of the inset rectangle. enabled == 0 means no hidden
 * area: the mask queries succeed with empty meshes (as a runtime with no
 * visibility information does). */
typedef struct KlNativeVisibilityParams {
    XrBool32 enabled;
    float inset_left, inset_right, inset_up, inset_down, radius;
} KlNativeVisibilityParams;
typedef struct KlNativeVisibilityHost {
    uint32_t version, struct_size;
    void *context;
    /* Serialized by the caller of xrGetVisibilityMaskKHR; may read the
     * environment or a file. Fill *out; return XR_SUCCESS. */
    XrResult (*get_params)(void *context, uint32_t eye, KlNativeVisibilityParams *out);
} KlNativeVisibilityHost;
XrResult kl_native_configure_visibility(const KlNativeVisibilityHost *host);
#endif
