/* Spatial-controller observations for the native provider's input host version 3.
 * Producers (the Swift tracking adapter, or the opt-in VXRT_XROS_TEST_HANDS script) publish; the provider's input
 * callback (vx_xros_controllers_sample) reads. Plain C types so Swift can call publish through the bridging header.
 *
 * Sony PS VR2 Sense controllers are reported as the Oculus Touch profile (KL_NATIVE_INPUT_PROFILE_OCULUS_TOUCH):
 * two face buttons per hand (Square/Triangle left, Cross/Circle right = X/Y and A/B), trigger, grip, thumbstick with
 * click and a menu-class button; it is the profile whose xrizer mapping covers every control Skyrim VR's Oculus
 * columns use (src/input/profiles/oculus_touch.rs). Index would add finger/force inputs Sense does not have. */
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct vx_xros_controller_hand {
    int connected;
    int grip_position_tracked, aim_position_tracked;
    float grip[7], aim[7];              /* x y z, then quaternion x y z w; provider LOCAL space (ARKit origin) */
    float trigger, stick_x, stick_y;    /* 0..1, -1..1; NAN = not observed */
    int primary, secondary, grip_pressed, menu, stick_pressed;
} vx_xros_controller_hand;
/* Both hands (left, right) observed at time_ns on the Mach-uptime clock the provider's frame prediction uses.
 * A hand with connected == 0, or without valid grip and aim poses, is stored as fully disconnected. */
void vx_xros_controllers_publish(const vx_xros_controller_hand hands[2], int64_t time_ns);
/* 1 when VXRT_XROS_TEST_HANDS is set and parsed, -1 when set but malformed (hands stay disconnected), else 0. */
int vx_xros_controllers_test_script(void);
/* Haptic output. The provider forwards a vibration for a connected, bound hand to vx_xros_haptics_apply / _stop
 * (haptic_host.h), which logs it ("forwarded") and passes it to the actuator sink when one is registered. The sink is
 * registered by the tracking adapter when a Sense controller drives that hand (VXSenseHaptics); with no sink (simulator,
 * test hands) nothing vibrates and the log line says so. stop != 0 cancels. */
typedef void (*vx_xros_haptic_sink)(int hand, float amplitude, double seconds, float frequency, int stop);
void vx_xros_haptics_set_sink(vx_xros_haptic_sink sink);
#ifdef KL_NATIVE_HAPTIC_HOST_H
XrResult vx_xros_haptics_apply(void *context, uint32_t hand, const KlNativeHapticVibration *vibration);
XrResult vx_xros_haptics_stop(void *context, uint32_t hand);
#endif
#ifdef KL_NATIVE_INPUT_HOST_H
XrResult vx_xros_controllers_sample(void *context, KlNativeInputSample3 *out);
#endif
#ifdef __cplusplus
}
#endif
