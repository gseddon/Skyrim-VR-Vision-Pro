/* Native input snapshot boundary; MIT, see ../LICENSE. */
#ifndef KL_NATIVE_INPUT_HOST_H
#define KL_NATIVE_INPUT_HOST_H
#include <openxr/openxr.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define KL_NATIVE_INPUT_HOST_VERSION 1u
/* This first version represents only the explicitly observed absence of both
 * hands. A connected hand is rejected until its profile, controls and poses
 * have a defined mapping. sample_time uses the same calibrated monotonic clock
 * as frame_host.h, and sample_id identifies this host observation. Repeated
 * polling of the same unchanged sample keeps its ID and timestamp. */
typedef struct KlNativeInputSample {
    uint64_t sample_id;
    XrTime sample_time;
    XrBool32 hand_connected[2]; /* left, right */
} KlNativeInputSample;
typedef struct KlNativeInputHost {
    uint32_t version, struct_size;
    void *context;
    /* Fill one coherent observation, or return an error. Serialized, native
     * ABI, non-reentrant; callback and context live through session teardown. */
    XrResult (*sample)(void *context, KlNativeInputSample *out);
} KlNativeInputHost;
XrResult kl_native_configure_input(const KlNativeInputHost *host);

#define KL_NATIVE_INPUT_HOST_VERSION_2 2u
/* One hand of a version-2 observation. trigger and stick are NAN when that
 * control was not observed. A disconnected hand carries no pose or controls.
 * This does not select an OpenXR interaction profile. */
typedef struct KlNativeInputHand2 {
    XrBool32 connected;
    XrBool32 grip_position_tracked;
    XrBool32 aim_position_tracked;
    float trigger;
    float stick_x, stick_y;
    XrBool32 primary_pressed, secondary_pressed, grip_pressed, menu_pressed, stick_pressed;
} KlNativeInputHand2;
typedef struct KlNativeInputSample2 {
    uint64_t sample_id;
    XrTime sample_time;
    KlNativeInputHand2 hand[2]; /* left, right */
} KlNativeInputSample2;
typedef struct KlNativeInputHost2 {
    uint32_t version, struct_size;
    void *context;
    XrResult (*sample)(void *context, KlNativeInputSample2 *out);
} KlNativeInputHost2;
XrResult kl_native_configure_input2(const KlNativeInputHost2 *host);
#ifdef __cplusplus
}
#endif
#endif
