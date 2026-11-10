/* Native haptic output boundary; MIT, see ../LICENSE. */
#ifndef KL_NATIVE_HAPTIC_HOST_H
#define KL_NATIVE_HAPTIC_HOST_H
#include <openxr/openxr.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define KL_NATIVE_HAPTIC_HOST_VERSION 1u
/* Independent of the input host: an input host of any version keeps working
 * without it, and then xrApplyHapticFeedback / xrStopHapticFeedback return
 * XR_ERROR_FEATURE_UNSUPPORTED. The provider forwards only to a hand that the
 * last xrSyncActions saw connected (input host version 3) and whose current
 * interaction profile has the application's vibration action bound
 * (output/haptic), so a disconnected, unbound or unsuggested hand returns
 * XR_SUCCESS without calling the host (OpenXR: nothing is bound, nothing
 * vibrates). A NULL subaction path applies to every bound hand.
 *
 * duration is nanoseconds, or XR_MIN_HAPTIC_DURATION (-1) for the shortest
 * pulse the hardware can make; frequency is Hz, or XR_FREQUENCY_UNSPECIFIED
 * (0); amplitude is 0..1. A host that cannot realise a frequency uses
 * amplitude and duration only (best effort); the provider does not reject
 * frequencies. stop cancels the hand's vibration. Callbacks use the native
 * ABI, are serialized, must not reenter the provider, and a failure result is
 * returned to the application as XR_ERROR_RUNTIME_FAILURE. */
typedef struct KlNativeHapticVibration {
    XrDuration duration;
    float frequency;
    float amplitude;
} KlNativeHapticVibration;
typedef struct KlNativeHapticHost {
    uint32_t version, struct_size;
    void *context;
    XrResult (*apply)(void *context, uint32_t hand /* 0 left, 1 right */, const KlNativeHapticVibration *vibration);
    XrResult (*stop)(void *context, uint32_t hand);
} KlNativeHapticHost;
/* NULL clears. Refused while an instance exists. */
XrResult kl_native_configure_haptics(const KlNativeHapticHost *host);
#ifdef __cplusplus
}
#endif
#endif
