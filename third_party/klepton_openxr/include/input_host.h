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

#define KL_NATIVE_INPUT_HOST_VERSION_3 3u
/* Version 3 adds what version 2 leaves out: which kind of controller the host
 * observes in each hand, and that hand's grip and aim poses in LOCAL space at
 * sample_time. The provider makes the profile current for a hand only when
 * the application suggested bindings for it, reports each change with
 * XrEventDataInteractionProfileChanged, and then reports bound controls as
 * active and action spaces as located. Poses are not predicted to a display
 * time: xrLocateSpace reports the latest synced sample. Position/orientation
 * "tracked" bits follow grip/aim_position_tracked; without them a connected
 * hand's poses are valid but untracked. */
enum {
    KL_NATIVE_INPUT_PROFILE_NONE = 0,
    KL_NATIVE_INPUT_PROFILE_OCULUS_TOUCH = 1,   /* /interaction_profiles/oculus/touch_controller */
    KL_NATIVE_INPUT_PROFILE_VALVE_INDEX = 2,    /* /interaction_profiles/valve/index_controller */
    KL_NATIVE_INPUT_PROFILE_HTC_VIVE = 3,       /* /interaction_profiles/htc/vive_controller */
    KL_NATIVE_INPUT_PROFILE_KHR_SIMPLE = 4      /* /interaction_profiles/khr/simple_controller */
};
typedef struct KlNativeInputHand3 {
    KlNativeInputHand2 controls;     /* same rules as version 2 */
    uint32_t profile;                /* KL_NATIVE_INPUT_PROFILE_*; NONE exactly when disconnected */
    XrPosef local_from_grip;         /* valid poses when connected, all zero when disconnected */
    XrPosef local_from_aim;
} KlNativeInputHand3;
typedef struct KlNativeInputSample3 {
    uint64_t sample_id;
    XrTime sample_time;
    KlNativeInputHand3 hand[2]; /* left, right */
} KlNativeInputSample3;
typedef struct KlNativeInputHost3 {
    uint32_t version, struct_size;
    void *context;
    XrResult (*sample)(void *context, KlNativeInputSample3 *out);
} KlNativeInputHost3;
XrResult kl_native_configure_input3(const KlNativeInputHost3 *host);
#ifdef __cplusplus
}
#endif
#endif
