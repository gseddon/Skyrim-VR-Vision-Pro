/* Native input snapshot boundary; MIT, see ../LICENSE. */
#ifndef KL_NATIVE_INPUT_HOST_H
#define KL_NATIVE_INPUT_HOST_H
#include <openxr/openxr.h>
#include <stdint.h>
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
#endif
