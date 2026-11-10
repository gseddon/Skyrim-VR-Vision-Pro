// Static Windows ABI adapters for the supported xrizer interface versions.
#include "vx.h"
#include "xrizer_guest_bridge.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { float m[4][4]; } matrix44;
typedef struct { float m[3][4]; } matrix34;
typedef struct { const void *vertices; uint32_t triangles; } hidden_mesh;
typedef struct { void **vtable; void *native; } guest_object;
typedef int (*native_init_fn)(void *, int, const char *);
typedef void (*native_cleanup_fn)(void *);
typedef void *(*native_interface_fn)(void *, const char *, int *);
typedef uint8_t (*native_present_fn)(void *);
typedef const char *(*native_error_fn)(void *, int);
typedef int (*native_version_fn)(void *, const char *);
typedef uint32_t (*native_role_fn)(void *, int);
typedef uint8_t (*native_poll_event_fn)(void *, void *, uint32_t);
typedef void (*native_dxgi_output_fn)(void *, int32_t *);
typedef uint32_t (*native_string_property_fn)(void *, uint32_t, int, char *, uint32_t, int *);
typedef void (*native_size_fn)(void *, uint32_t *, uint32_t *);
typedef matrix44 (*native_projection_fn)(void *, int, float, float);
typedef void (*native_raw_fn)(void *, int, float *, float *, float *, float *);
typedef hidden_mesh (*native_hidden_mesh_fn)(void *, int, int);
typedef matrix34 (*native_transform_fn)(void *, int);
typedef matrix44 (*native_projection_c_fn)(int, float, float);
typedef matrix34 (*native_transform_c_fn)(int);
typedef int (*native_wait_fn)(void *, void *, uint32_t, void *, uint32_t);
typedef int (*native_one_pose_fn)(void *, uint32_t, void *, void *);
typedef void (*native_handoff_fn)(void *);
typedef uint8_t (*native_frame_timing_fn)(void *, void *, uint32_t);
typedef void (*native_tracking_fn)(void *, int);
typedef int (*native_submit_fn)(void *, int, const void *, const void *, int);
typedef int (*native_device_class_fn)(void *, uint32_t);
typedef uint8_t (*native_device_bool_fn)(void *, uint32_t);
typedef uint8_t (*native_bool_property_fn)(void *, uint32_t, int, int *);
typedef float (*native_float_property_fn)(void *, uint32_t, int, int *);
typedef int32_t (*native_int32_property_fn)(void *, uint32_t, int, int *);
typedef uint64_t (*native_uint64_property_fn)(void *, uint32_t, int, int *);
typedef uint8_t (*native_controller_state_fn)(void *, uint32_t, void *, uint32_t);
typedef uint8_t (*native_controller_state_pose_fn)(void *, int, uint32_t, void *, uint32_t, void *);
typedef void (*native_haptic_fn)(void *, uint32_t, uint32_t, uint16_t);
// VRControllerState001_t (openvr.h): `#pragma pack(4)` on Linux/Apple only, so the native (xrizer) copy is 60 bytes
// with the two button masks at 4 and 12, while the Windows guest's is 64 bytes with them at 8 and 16 (natural
// alignment) and the five axes at 24 instead of 20.
typedef struct { uint32_t packet; uint64_t pressed, touched; float axis[10]; } __attribute__((packed, aligned(4))) native_controller_state;
typedef struct { uint32_t packet, pad; uint64_t pressed, touched; float axis[10]; } guest_controller_state;
_Static_assert(sizeof(native_controller_state) == 60 && __builtin_offsetof(native_controller_state, pressed) == 4 &&
               __builtin_offsetof(native_controller_state, axis) == 20, "Apple VRControllerState001_t");
_Static_assert(sizeof(guest_controller_state) == 64 && __builtin_offsetof(guest_controller_state, pressed) == 8 &&
               __builtin_offsetof(guest_controller_state, axis) == 24, "Windows VRControllerState001_t");
static void *core_table[7], *system_table[47], *compositor_table[44], *system_fns[47];
static guest_object core = {core_table, NULL}, system_object = {system_table, NULL}, compositor = {compositor_table, NULL};
static void *overlay_table[82];   // IVROverlay_018 (below)
static guest_object overlay = {overlay_table, NULL};
static void *rendermodels_table[18], *settings_table[12];   // IVRRenderModels_005, IVRSettings_002 (below)
static guest_object rendermodels_object = {rendermodels_table, NULL}, settings_object = {settings_table, NULL};
static void **native_system_fns;
static int initialized, cleaned, consumed;

static void require(int ok) { if (!ok) { vx_log("xrizer_guest_bridge: invalid fixture state/argument"); abort(); } }
static void **native_table(guest_object *self) { require(self && self->native); return *(void ***)self->native; }
static void unsupported_slot(const char *interface, unsigned slot) {
    vx_log("xrizer_guest_bridge: unsupported %s slot %u", interface, slot);
#ifdef __aarch64__
    { void xa_report(void); xa_report(); }
#endif
    abort();
}
static WINAPI void unsupported_core_0(void) { unsupported_slot("IVRClientCore_003", 0); }
static WINAPI void unsupported_core_1(void) { unsupported_slot("IVRClientCore_003", 1); }
static WINAPI void unsupported_core_2(void) { unsupported_slot("IVRClientCore_003", 2); }
static WINAPI void unsupported_core_3(void) { unsupported_slot("IVRClientCore_003", 3); }
static WINAPI void unsupported_core_4(void) { unsupported_slot("IVRClientCore_003", 4); }
static WINAPI void unsupported_core_5(void) { unsupported_slot("IVRClientCore_003", 5); }
static WINAPI void unsupported_core_6(void) { unsupported_slot("IVRClientCore_003", 6); }
static WINAPI void unsupported_system_0(void) { unsupported_slot("IVRSystem_019", 0); }
static WINAPI void unsupported_system_1(void) { unsupported_slot("IVRSystem_019", 1); }
static WINAPI void unsupported_system_2(void) { unsupported_slot("IVRSystem_019", 2); }
static WINAPI void unsupported_system_3(void) { unsupported_slot("IVRSystem_019", 3); }
static WINAPI void unsupported_system_4(void) { unsupported_slot("IVRSystem_019", 4); }
static WINAPI void unsupported_system_5(void) { unsupported_slot("IVRSystem_019", 5); }
static WINAPI void unsupported_system_6(void) { unsupported_slot("IVRSystem_019", 6); }
static WINAPI void unsupported_system_7(void) { unsupported_slot("IVRSystem_019", 7); }
static WINAPI void unsupported_system_8(void) { unsupported_slot("IVRSystem_019", 8); }
static WINAPI void unsupported_system_9(void) { unsupported_slot("IVRSystem_019", 9); }
static WINAPI void unsupported_system_10(void) { unsupported_slot("IVRSystem_019", 10); }
static WINAPI void unsupported_system_11(void) { unsupported_slot("IVRSystem_019", 11); }
static WINAPI void unsupported_system_12(void) { unsupported_slot("IVRSystem_019", 12); }
static WINAPI void unsupported_system_13(void) { unsupported_slot("IVRSystem_019", 13); }
static WINAPI void unsupported_system_14(void) { unsupported_slot("IVRSystem_019", 14); }
static WINAPI void unsupported_system_15(void) { unsupported_slot("IVRSystem_019", 15); }
static WINAPI void unsupported_system_16(void) { unsupported_slot("IVRSystem_019", 16); }
static WINAPI void unsupported_system_17(void) { unsupported_slot("IVRSystem_019", 17); }
static WINAPI void unsupported_system_18(void) { unsupported_slot("IVRSystem_019", 18); }
static WINAPI void unsupported_system_19(void) { unsupported_slot("IVRSystem_019", 19); }
static WINAPI void unsupported_system_20(void) { unsupported_slot("IVRSystem_019", 20); }
static WINAPI void unsupported_system_21(void) { unsupported_slot("IVRSystem_019", 21); }
static WINAPI void unsupported_system_22(void) { unsupported_slot("IVRSystem_019", 22); }
static WINAPI void unsupported_system_23(void) { unsupported_slot("IVRSystem_019", 23); }
static WINAPI void unsupported_system_24(void) { unsupported_slot("IVRSystem_019", 24); }
static WINAPI void unsupported_system_25(void) { unsupported_slot("IVRSystem_019", 25); }
static WINAPI void unsupported_system_26(void) { unsupported_slot("IVRSystem_019", 26); }
static WINAPI void unsupported_system_27(void) { unsupported_slot("IVRSystem_019", 27); }
static WINAPI void unsupported_system_28(void) { unsupported_slot("IVRSystem_019", 28); }
static WINAPI void unsupported_system_29(void) { unsupported_slot("IVRSystem_019", 29); }
static WINAPI void unsupported_system_30(void) { unsupported_slot("IVRSystem_019", 30); }
static WINAPI void unsupported_system_31(void) { unsupported_slot("IVRSystem_019", 31); }
static WINAPI void unsupported_system_32(void) { unsupported_slot("IVRSystem_019", 32); }
static WINAPI void unsupported_system_33(void) { unsupported_slot("IVRSystem_019", 33); }
static WINAPI void unsupported_system_34(void) { unsupported_slot("IVRSystem_019", 34); }
static WINAPI void unsupported_system_35(void) { unsupported_slot("IVRSystem_019", 35); }
static WINAPI void unsupported_system_36(void) { unsupported_slot("IVRSystem_019", 36); }
static WINAPI void unsupported_system_37(void) { unsupported_slot("IVRSystem_019", 37); }
static WINAPI void unsupported_system_38(void) { unsupported_slot("IVRSystem_019", 38); }
static WINAPI void unsupported_system_39(void) { unsupported_slot("IVRSystem_019", 39); }
static WINAPI void unsupported_system_40(void) { unsupported_slot("IVRSystem_019", 40); }
static WINAPI void unsupported_system_41(void) { unsupported_slot("IVRSystem_019", 41); }
static WINAPI void unsupported_system_42(void) { unsupported_slot("IVRSystem_019", 42); }
static WINAPI void unsupported_system_43(void) { unsupported_slot("IVRSystem_019", 43); }
static WINAPI void unsupported_system_44(void) { unsupported_slot("IVRSystem_019", 44); }
static WINAPI void unsupported_system_45(void) { unsupported_slot("IVRSystem_019", 45); }
static WINAPI void unsupported_system_46(void) { unsupported_slot("IVRSystem_019", 46); }
static WINAPI void unsupported_compositor_0(void) { unsupported_slot("IVRCompositor_022", 0); }
static WINAPI void unsupported_compositor_1(void) { unsupported_slot("IVRCompositor_022", 1); }
static WINAPI void unsupported_compositor_2(void) { unsupported_slot("IVRCompositor_022", 2); }
static WINAPI void unsupported_compositor_3(void) { unsupported_slot("IVRCompositor_022", 3); }
static WINAPI void unsupported_compositor_4(void) { unsupported_slot("IVRCompositor_022", 4); }
static WINAPI void unsupported_compositor_5(void) { unsupported_slot("IVRCompositor_022", 5); }
static WINAPI void unsupported_compositor_6(void) { unsupported_slot("IVRCompositor_022", 6); }
static WINAPI void unsupported_compositor_7(void) { unsupported_slot("IVRCompositor_022", 7); }
static WINAPI void unsupported_compositor_8(void) { unsupported_slot("IVRCompositor_022", 8); }
static WINAPI void unsupported_compositor_9(void) { unsupported_slot("IVRCompositor_022", 9); }
static WINAPI void unsupported_compositor_10(void) { unsupported_slot("IVRCompositor_022", 10); }
static WINAPI void unsupported_compositor_11(void) { unsupported_slot("IVRCompositor_022", 11); }
static WINAPI void unsupported_compositor_12(void) { unsupported_slot("IVRCompositor_022", 12); }
static WINAPI void unsupported_compositor_13(void) { unsupported_slot("IVRCompositor_022", 13); }
static WINAPI void unsupported_compositor_14(void) { unsupported_slot("IVRCompositor_022", 14); }
static WINAPI void unsupported_compositor_15(void) { unsupported_slot("IVRCompositor_022", 15); }
static WINAPI void unsupported_compositor_16(void) { unsupported_slot("IVRCompositor_022", 16); }
static WINAPI void unsupported_compositor_17(void) { unsupported_slot("IVRCompositor_022", 17); }
static WINAPI void unsupported_compositor_18(void) { unsupported_slot("IVRCompositor_022", 18); }
static WINAPI void unsupported_compositor_19(void) { unsupported_slot("IVRCompositor_022", 19); }
static WINAPI void unsupported_compositor_20(void) { unsupported_slot("IVRCompositor_022", 20); }
static WINAPI void unsupported_compositor_21(void) { unsupported_slot("IVRCompositor_022", 21); }
static WINAPI void unsupported_compositor_22(void) { unsupported_slot("IVRCompositor_022", 22); }
static WINAPI void unsupported_compositor_23(void) { unsupported_slot("IVRCompositor_022", 23); }
static WINAPI void unsupported_compositor_24(void) { unsupported_slot("IVRCompositor_022", 24); }
static WINAPI void unsupported_compositor_25(void) { unsupported_slot("IVRCompositor_022", 25); }
static WINAPI void unsupported_compositor_26(void) { unsupported_slot("IVRCompositor_022", 26); }
static WINAPI void unsupported_compositor_27(void) { unsupported_slot("IVRCompositor_022", 27); }
static WINAPI void unsupported_compositor_28(void) { unsupported_slot("IVRCompositor_022", 28); }
static WINAPI void unsupported_compositor_29(void) { unsupported_slot("IVRCompositor_022", 29); }
static WINAPI void unsupported_compositor_30(void) { unsupported_slot("IVRCompositor_022", 30); }
static WINAPI void unsupported_compositor_31(void) { unsupported_slot("IVRCompositor_022", 31); }
static WINAPI void unsupported_compositor_32(void) { unsupported_slot("IVRCompositor_022", 32); }
static WINAPI void unsupported_compositor_33(void) { unsupported_slot("IVRCompositor_022", 33); }
static WINAPI void unsupported_compositor_34(void) { unsupported_slot("IVRCompositor_022", 34); }
static WINAPI void unsupported_compositor_35(void) { unsupported_slot("IVRCompositor_022", 35); }
static WINAPI void unsupported_compositor_36(void) { unsupported_slot("IVRCompositor_022", 36); }
static WINAPI void unsupported_compositor_37(void) { unsupported_slot("IVRCompositor_022", 37); }
static WINAPI void unsupported_compositor_38(void) { unsupported_slot("IVRCompositor_022", 38); }
static WINAPI void unsupported_compositor_39(void) { unsupported_slot("IVRCompositor_022", 39); }
static WINAPI void unsupported_compositor_40(void) { unsupported_slot("IVRCompositor_022", 40); }
static WINAPI void unsupported_compositor_41(void) { unsupported_slot("IVRCompositor_022", 41); }
static WINAPI void unsupported_compositor_42(void) { unsupported_slot("IVRCompositor_022", 42); }
static WINAPI void unsupported_compositor_43(void) { unsupported_slot("IVRCompositor_022", 43); }
static WINAPI void unsupported_fns_0(void) { unsupported_slot("FnTable:IVRSystem_019", 0); }
static WINAPI void unsupported_fns_1(void) { unsupported_slot("FnTable:IVRSystem_019", 1); }
static WINAPI void unsupported_fns_2(void) { unsupported_slot("FnTable:IVRSystem_019", 2); }
static WINAPI void unsupported_fns_3(void) { unsupported_slot("FnTable:IVRSystem_019", 3); }
static WINAPI void unsupported_fns_4(void) { unsupported_slot("FnTable:IVRSystem_019", 4); }
static WINAPI void unsupported_fns_5(void) { unsupported_slot("FnTable:IVRSystem_019", 5); }
static WINAPI void unsupported_fns_6(void) { unsupported_slot("FnTable:IVRSystem_019", 6); }
static WINAPI void unsupported_fns_7(void) { unsupported_slot("FnTable:IVRSystem_019", 7); }
static WINAPI void unsupported_fns_8(void) { unsupported_slot("FnTable:IVRSystem_019", 8); }
static WINAPI void unsupported_fns_9(void) { unsupported_slot("FnTable:IVRSystem_019", 9); }
static WINAPI void unsupported_fns_10(void) { unsupported_slot("FnTable:IVRSystem_019", 10); }
static WINAPI void unsupported_fns_11(void) { unsupported_slot("FnTable:IVRSystem_019", 11); }
static WINAPI void unsupported_fns_12(void) { unsupported_slot("FnTable:IVRSystem_019", 12); }
static WINAPI void unsupported_fns_13(void) { unsupported_slot("FnTable:IVRSystem_019", 13); }
static WINAPI void unsupported_fns_14(void) { unsupported_slot("FnTable:IVRSystem_019", 14); }
static WINAPI void unsupported_fns_15(void) { unsupported_slot("FnTable:IVRSystem_019", 15); }
static WINAPI void unsupported_fns_16(void) { unsupported_slot("FnTable:IVRSystem_019", 16); }
static WINAPI void unsupported_fns_17(void) { unsupported_slot("FnTable:IVRSystem_019", 17); }
static WINAPI void unsupported_fns_18(void) { unsupported_slot("FnTable:IVRSystem_019", 18); }
static WINAPI void unsupported_fns_19(void) { unsupported_slot("FnTable:IVRSystem_019", 19); }
static WINAPI void unsupported_fns_20(void) { unsupported_slot("FnTable:IVRSystem_019", 20); }
static WINAPI void unsupported_fns_21(void) { unsupported_slot("FnTable:IVRSystem_019", 21); }
static WINAPI void unsupported_fns_22(void) { unsupported_slot("FnTable:IVRSystem_019", 22); }
static WINAPI void unsupported_fns_23(void) { unsupported_slot("FnTable:IVRSystem_019", 23); }
static WINAPI void unsupported_fns_24(void) { unsupported_slot("FnTable:IVRSystem_019", 24); }
static WINAPI void unsupported_fns_25(void) { unsupported_slot("FnTable:IVRSystem_019", 25); }
static WINAPI void unsupported_fns_26(void) { unsupported_slot("FnTable:IVRSystem_019", 26); }
static WINAPI void unsupported_fns_27(void) { unsupported_slot("FnTable:IVRSystem_019", 27); }
static WINAPI void unsupported_fns_28(void) { unsupported_slot("FnTable:IVRSystem_019", 28); }
static WINAPI void unsupported_fns_29(void) { unsupported_slot("FnTable:IVRSystem_019", 29); }
static WINAPI void unsupported_fns_30(void) { unsupported_slot("FnTable:IVRSystem_019", 30); }
static WINAPI void unsupported_fns_31(void) { unsupported_slot("FnTable:IVRSystem_019", 31); }
static WINAPI void unsupported_fns_32(void) { unsupported_slot("FnTable:IVRSystem_019", 32); }
static WINAPI void unsupported_fns_33(void) { unsupported_slot("FnTable:IVRSystem_019", 33); }
static WINAPI void unsupported_fns_34(void) { unsupported_slot("FnTable:IVRSystem_019", 34); }
static WINAPI void unsupported_fns_35(void) { unsupported_slot("FnTable:IVRSystem_019", 35); }
static WINAPI void unsupported_fns_36(void) { unsupported_slot("FnTable:IVRSystem_019", 36); }
static WINAPI void unsupported_fns_37(void) { unsupported_slot("FnTable:IVRSystem_019", 37); }
static WINAPI void unsupported_fns_38(void) { unsupported_slot("FnTable:IVRSystem_019", 38); }
static WINAPI void unsupported_fns_39(void) { unsupported_slot("FnTable:IVRSystem_019", 39); }
static WINAPI void unsupported_fns_40(void) { unsupported_slot("FnTable:IVRSystem_019", 40); }
static WINAPI void unsupported_fns_41(void) { unsupported_slot("FnTable:IVRSystem_019", 41); }
static WINAPI void unsupported_fns_42(void) { unsupported_slot("FnTable:IVRSystem_019", 42); }
static WINAPI void unsupported_fns_43(void) { unsupported_slot("FnTable:IVRSystem_019", 43); }
static WINAPI void unsupported_fns_44(void) { unsupported_slot("FnTable:IVRSystem_019", 44); }
static WINAPI void unsupported_fns_45(void) { unsupported_slot("FnTable:IVRSystem_019", 45); }
static WINAPI void unsupported_fns_46(void) { unsupported_slot("FnTable:IVRSystem_019", 46); }
static WINAPI int core_init(guest_object *self, int type, const char *startup) {
    require(self == &core && !initialized);
    native_init_fn fn = (native_init_fn)native_table(self)[0];
    int result = fn(self->native, type, startup); initialized = result == 0;
    vx_log("xrizer_guest_bridge: actual native Init return %d", result); return result;
}
static WINAPI void core_cleanup(guest_object *self) {
    require(self == &core && initialized && !cleaned);
    native_cleanup_fn fn = (native_cleanup_fn)native_table(self)[1]; fn(self->native);
    cleaned = 1; initialized = 0; system_object.native = compositor.native = overlay.native = rendermodels_object.native = settings_object.native = NULL; native_system_fns = NULL;
}
// ---- IVROverlay_018 (openvr 1.0.17 class IVROverlay, 82 slots): xrizer's own overlay interface, one typed forwarder per slot ----
// Parameters and results are declared as the header does, so the generated ABI thunks move Windows registers/stack to the
// native AAPCS64 ones (floats, 8-byte HmdVector2_t by value, 16-byte HmdRect2_t by reference on Windows, HFA natively).
typedef struct { float x, y; } overlay_vec2;
typedef struct { overlay_vec2 top_left, bottom_right; } overlay_rect2;
static const char *const overlay_names[82] = {"FindOverlay", "CreateOverlay", "DestroyOverlay", "SetHighQualityOverlay", "GetHighQualityOverlay", "GetOverlayKey", "GetOverlayName", "SetOverlayName", "GetOverlayImageData", "GetOverlayErrorNameFromEnum", "SetOverlayRenderingPid", "GetOverlayRenderingPid", "SetOverlayFlag", "GetOverlayFlag", "SetOverlayColor", "GetOverlayColor", "SetOverlayAlpha", "GetOverlayAlpha", "SetOverlayTexelAspect", "GetOverlayTexelAspect", "SetOverlaySortOrder", "GetOverlaySortOrder", "SetOverlayWidthInMeters", "GetOverlayWidthInMeters", "SetOverlayAutoCurveDistanceRangeInMeters", "GetOverlayAutoCurveDistanceRangeInMeters", "SetOverlayTextureColorSpace", "GetOverlayTextureColorSpace", "SetOverlayTextureBounds", "GetOverlayTextureBounds", "GetOverlayRenderModel", "SetOverlayRenderModel", "GetOverlayTransformType", "SetOverlayTransformAbsolute", "GetOverlayTransformAbsolute", "SetOverlayTransformTrackedDeviceRelative", "GetOverlayTransformTrackedDeviceRelative", "SetOverlayTransformTrackedDeviceComponent", "GetOverlayTransformTrackedDeviceComponent", "GetOverlayTransformOverlayRelative", "SetOverlayTransformOverlayRelative", "ShowOverlay", "HideOverlay", "IsOverlayVisible", "GetTransformForOverlayCoordinates", "PollNextOverlayEvent", "GetOverlayInputMethod", "SetOverlayInputMethod", "GetOverlayMouseScale", "SetOverlayMouseScale", "ComputeOverlayIntersection", "IsHoverTargetOverlay", "GetGamepadFocusOverlay", "SetGamepadFocusOverlay", "SetOverlayNeighbor", "MoveGamepadFocusToNeighbor", "SetOverlayDualAnalogTransform", "GetOverlayDualAnalogTransform", "SetOverlayTexture", "ClearOverlayTexture", "SetOverlayRaw", "SetOverlayFromFile", "GetOverlayTexture", "ReleaseNativeOverlayHandle", "GetOverlayTextureSize", "CreateDashboardOverlay", "IsDashboardVisible", "IsActiveDashboardOverlay", "SetDashboardOverlaySceneProcess", "GetDashboardOverlaySceneProcess", "ShowDashboard", "GetPrimaryDashboardDevice", "ShowKeyboard", "ShowKeyboardForOverlay", "GetKeyboardText", "HideKeyboard", "SetKeyboardTransformAbsolute", "SetKeyboardPositionForOverlay", "SetOverlayIntersectionMask", "GetOverlayFlags", "ShowMessageOverlay", "CloseMessageOverlay"};
static uint8_t overlay_seen[82];
// ---- keyboard: xrizer answers ShowKeyboard* with RequestFailed (the game then waits for a text that never comes) and
// GetKeyboardText is todo!(). Until a real text-entry path exists (visionOS), a keyboard request is answered as if the user
// accepted the text the game offered (its existing text, or "Dragonborn" when empty): success, then VREvent_KeyboardDone
// and VREvent_KeyboardClosed through PollNextOverlayEvent (ShowKeyboardForOverlay) or IVRSystem::PollNextEvent (ShowKeyboard).
static struct { pthread_mutex_t lock; char text[256]; uint64_t user; int next, count, to_system; } overlay_kbd = { PTHREAD_MUTEX_INITIALIZER };
static void overlay_keyboard_show(const char *existing, uint64_t user, int to_system, const char *what) {
    pthread_mutex_lock(&overlay_kbd.lock);
    snprintf(overlay_kbd.text, sizeof overlay_kbd.text, "%s", existing && *existing ? existing : "Dragonborn");
    overlay_kbd.user = user; overlay_kbd.to_system = to_system; overlay_kbd.next = 0; overlay_kbd.count = 2;
    vx_log("xrizer_guest_bridge: %s: no on-screen keyboard yet; accepting the offered text '%s' (KeyboardDone, KeyboardClosed queued for %s)",
           what, overlay_kbd.text, to_system ? "IVRSystem::PollNextEvent" : "PollNextOverlayEvent");
    pthread_mutex_unlock(&overlay_kbd.lock);
}
// Writes the next queued keyboard event in the Windows VREvent_t layout (data at byte 16); returns 0 when none is due.
static int overlay_keyboard_event(void *event, uint32_t size, int to_system) {
    int got = 0;
    pthread_mutex_lock(&overlay_kbd.lock);
    if (event && size >= 32 && overlay_kbd.next < overlay_kbd.count && overlay_kbd.to_system == to_system) {
        uint32_t type = overlay_kbd.next == 0 ? 1202 /* VREvent_KeyboardDone */ : 1200 /* VREvent_KeyboardClosed */, device = 0xffffffffu;
        memset(event, 0, size < 64 ? size : 64);
        memcpy(event, &type, 4); memcpy((char *)event + 4, &device, 4);
        memcpy((char *)event + 24, &overlay_kbd.user, 8);        // VREvent_Keyboard_t: cNewInput[8] at 16, uUserValue at 24
        overlay_kbd.next++; got = 1;
        vx_log("xrizer_guest_bridge: keyboard event %u delivered (user value %llu)", type, (unsigned long long)overlay_kbd.user);
    }
    pthread_mutex_unlock(&overlay_kbd.lock);
    return got;
}
static void overlay_note(unsigned slot) {   // the first call of each method is logged (which methods a game uses)
    if (!overlay_seen[slot]) { overlay_seen[slot] = 1; vx_log("xrizer_guest_bridge: IVROverlay_018::%s (slot %u) called", overlay_names[slot], slot); }
}
typedef int32_t (*overlay_native_0_fn)(void *, void *, void *);
static WINAPI int32_t overlay_0(guest_object *self, void * a0, void * a1) { // FindOverlay
    require(self == &overlay); overlay_note(0); overlay_native_0_fn fn = (overlay_native_0_fn)native_table(self)[0]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_1_fn)(void *, void *, void *, void *);
static WINAPI int32_t overlay_1(guest_object *self, void * a0, void * a1, void * a2) { // CreateOverlay
    require(self == &overlay); overlay_note(1); overlay_native_1_fn fn = (overlay_native_1_fn)native_table(self)[1]; (void)fn;
    return fn(self->native, a0, a1, a2);
}
typedef int32_t (*overlay_native_2_fn)(void *, uint64_t);
static WINAPI int32_t overlay_2(guest_object *self, uint64_t a0) { // DestroyOverlay
    require(self == &overlay); overlay_note(2); overlay_native_2_fn fn = (overlay_native_2_fn)native_table(self)[2]; (void)fn;
    return fn(self->native, a0);
}
typedef int32_t (*overlay_native_3_fn)(void *, uint64_t);
static WINAPI int32_t overlay_3(guest_object *self, uint64_t a0) { // SetHighQualityOverlay
    require(self == &overlay); overlay_note(3); overlay_native_3_fn fn = (overlay_native_3_fn)native_table(self)[3]; (void)fn;
    return fn(self->native, a0);
}
typedef uint64_t (*overlay_native_4_fn)(void *);
static WINAPI uint64_t overlay_4(guest_object *self) { // GetHighQualityOverlay
    require(self == &overlay); overlay_note(4); overlay_native_4_fn fn = (overlay_native_4_fn)native_table(self)[4]; (void)fn;
    return fn(self->native);
}
typedef uint32_t (*overlay_native_5_fn)(void *, uint64_t, void *, uint32_t, void *);
static WINAPI uint32_t overlay_5(guest_object *self, uint64_t a0, void * a1, uint32_t a2, void * a3) { // GetOverlayKey
    require(self == &overlay); overlay_note(5); overlay_native_5_fn fn = (overlay_native_5_fn)native_table(self)[5]; (void)fn;
    return 0;
}
typedef uint32_t (*overlay_native_6_fn)(void *, uint64_t, void *, uint32_t, void *);
static WINAPI uint32_t overlay_6(guest_object *self, uint64_t a0, void * a1, uint32_t a2, void * a3) { // GetOverlayName
    require(self == &overlay); overlay_note(6); overlay_native_6_fn fn = (overlay_native_6_fn)native_table(self)[6]; (void)fn;
    return 0;
}
typedef int32_t (*overlay_native_7_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_7(guest_object *self, uint64_t a0, void * a1) { // SetOverlayName
    require(self == &overlay); overlay_note(7); overlay_native_7_fn fn = (overlay_native_7_fn)native_table(self)[7]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_8_fn)(void *, uint64_t, void *, uint32_t, void *, void *);
static WINAPI int32_t overlay_8(guest_object *self, uint64_t a0, void * a1, uint32_t a2, void * a3, void * a4) { // GetOverlayImageData
    require(self == &overlay); overlay_note(8); overlay_native_8_fn fn = (overlay_native_8_fn)native_table(self)[8]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef void * (*overlay_native_9_fn)(void *, int32_t);
static WINAPI void * overlay_9(guest_object *self, int32_t a0) { // GetOverlayErrorNameFromEnum
    require(self == &overlay); overlay_note(9); overlay_native_9_fn fn = (overlay_native_9_fn)native_table(self)[9]; (void)fn;
    return fn(self->native, a0);
}
typedef int32_t (*overlay_native_10_fn)(void *, uint64_t, uint32_t);
static WINAPI int32_t overlay_10(guest_object *self, uint64_t a0, uint32_t a1) { // SetOverlayRenderingPid
    require(self == &overlay); overlay_note(10); overlay_native_10_fn fn = (overlay_native_10_fn)native_table(self)[10]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef uint32_t (*overlay_native_11_fn)(void *, uint64_t);
static WINAPI uint32_t overlay_11(guest_object *self, uint64_t a0) { // GetOverlayRenderingPid
    require(self == &overlay); overlay_note(11); overlay_native_11_fn fn = (overlay_native_11_fn)native_table(self)[11]; (void)fn;
    return 0;
}
typedef int32_t (*overlay_native_12_fn)(void *, uint64_t, int32_t, uint8_t);
static WINAPI int32_t overlay_12(guest_object *self, uint64_t a0, int32_t a1, uint8_t a2) { // SetOverlayFlag
    require(self == &overlay); overlay_note(12); overlay_native_12_fn fn = (overlay_native_12_fn)native_table(self)[12]; (void)fn;
    return fn(self->native, a0, a1, a2);
}
typedef int32_t (*overlay_native_13_fn)(void *, uint64_t, int32_t, void *);
static WINAPI int32_t overlay_13(guest_object *self, uint64_t a0, int32_t a1, void * a2) { // GetOverlayFlag
    require(self == &overlay); overlay_note(13); overlay_native_13_fn fn = (overlay_native_13_fn)native_table(self)[13]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_14_fn)(void *, uint64_t, float, float, float);
static WINAPI int32_t overlay_14(guest_object *self, uint64_t a0, float a1, float a2, float a3) { // SetOverlayColor
    require(self == &overlay); overlay_note(14); overlay_native_14_fn fn = (overlay_native_14_fn)native_table(self)[14]; (void)fn;
    return fn(self->native, a0, a1, a2, a3);
}
typedef int32_t (*overlay_native_15_fn)(void *, uint64_t, void *, void *, void *);
static WINAPI int32_t overlay_15(guest_object *self, uint64_t a0, void * a1, void * a2, void * a3) { // GetOverlayColor
    require(self == &overlay); overlay_note(15); overlay_native_15_fn fn = (overlay_native_15_fn)native_table(self)[15]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_16_fn)(void *, uint64_t, float);
static WINAPI int32_t overlay_16(guest_object *self, uint64_t a0, float a1) { // SetOverlayAlpha
    require(self == &overlay); overlay_note(16); overlay_native_16_fn fn = (overlay_native_16_fn)native_table(self)[16]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_17_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_17(guest_object *self, uint64_t a0, void * a1) { // GetOverlayAlpha
    require(self == &overlay); overlay_note(17); overlay_native_17_fn fn = (overlay_native_17_fn)native_table(self)[17]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_18_fn)(void *, uint64_t, float);
static WINAPI int32_t overlay_18(guest_object *self, uint64_t a0, float a1) { // SetOverlayTexelAspect
    require(self == &overlay); overlay_note(18); overlay_native_18_fn fn = (overlay_native_18_fn)native_table(self)[18]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_19_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_19(guest_object *self, uint64_t a0, void * a1) { // GetOverlayTexelAspect
    require(self == &overlay); overlay_note(19); overlay_native_19_fn fn = (overlay_native_19_fn)native_table(self)[19]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_20_fn)(void *, uint64_t, uint32_t);
static WINAPI int32_t overlay_20(guest_object *self, uint64_t a0, uint32_t a1) { // SetOverlaySortOrder
    require(self == &overlay); overlay_note(20); overlay_native_20_fn fn = (overlay_native_20_fn)native_table(self)[20]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_21_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_21(guest_object *self, uint64_t a0, void * a1) { // GetOverlaySortOrder
    require(self == &overlay); overlay_note(21); overlay_native_21_fn fn = (overlay_native_21_fn)native_table(self)[21]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_22_fn)(void *, uint64_t, float);
static WINAPI int32_t overlay_22(guest_object *self, uint64_t a0, float a1) { // SetOverlayWidthInMeters
    require(self == &overlay); overlay_note(22); overlay_native_22_fn fn = (overlay_native_22_fn)native_table(self)[22]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_23_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_23(guest_object *self, uint64_t a0, void * a1) { // GetOverlayWidthInMeters
    require(self == &overlay); overlay_note(23); overlay_native_23_fn fn = (overlay_native_23_fn)native_table(self)[23]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_24_fn)(void *, uint64_t, float, float);
static WINAPI int32_t overlay_24(guest_object *self, uint64_t a0, float a1, float a2) { // SetOverlayAutoCurveDistanceRangeInMeters
    require(self == &overlay); overlay_note(24); overlay_native_24_fn fn = (overlay_native_24_fn)native_table(self)[24]; (void)fn;
    return fn(self->native, a0, a1, a2);
}
typedef int32_t (*overlay_native_25_fn)(void *, uint64_t, void *, void *);
static WINAPI int32_t overlay_25(guest_object *self, uint64_t a0, void * a1, void * a2) { // GetOverlayAutoCurveDistanceRangeInMeters
    require(self == &overlay); overlay_note(25); overlay_native_25_fn fn = (overlay_native_25_fn)native_table(self)[25]; (void)fn;
    return fn(self->native, a0, a1, a2);
}
typedef int32_t (*overlay_native_26_fn)(void *, uint64_t, int32_t);
static WINAPI int32_t overlay_26(guest_object *self, uint64_t a0, int32_t a1) { // SetOverlayTextureColorSpace
    require(self == &overlay); overlay_note(26); overlay_native_26_fn fn = (overlay_native_26_fn)native_table(self)[26]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_27_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_27(guest_object *self, uint64_t a0, void * a1) { // GetOverlayTextureColorSpace
    require(self == &overlay); overlay_note(27); overlay_native_27_fn fn = (overlay_native_27_fn)native_table(self)[27]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_28_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_28(guest_object *self, uint64_t a0, void * a1) { // SetOverlayTextureBounds
    require(self == &overlay); overlay_note(28); overlay_native_28_fn fn = (overlay_native_28_fn)native_table(self)[28]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_29_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_29(guest_object *self, uint64_t a0, void * a1) { // GetOverlayTextureBounds
    require(self == &overlay); overlay_note(29); overlay_native_29_fn fn = (overlay_native_29_fn)native_table(self)[29]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef uint32_t (*overlay_native_30_fn)(void *, uint64_t, void *, uint32_t, void *, void *);
static WINAPI uint32_t overlay_30(guest_object *self, uint64_t a0, void * a1, uint32_t a2, void * a3, void * a4) { // GetOverlayRenderModel
    require(self == &overlay); overlay_note(30); overlay_native_30_fn fn = (overlay_native_30_fn)native_table(self)[30]; (void)fn;
    return 0;
}
typedef int32_t (*overlay_native_31_fn)(void *, uint64_t, void *, void *);
static WINAPI int32_t overlay_31(guest_object *self, uint64_t a0, void * a1, void * a2) { // SetOverlayRenderModel
    require(self == &overlay); overlay_note(31); overlay_native_31_fn fn = (overlay_native_31_fn)native_table(self)[31]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_32_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_32(guest_object *self, uint64_t a0, void * a1) { // GetOverlayTransformType
    require(self == &overlay); overlay_note(32); overlay_native_32_fn fn = (overlay_native_32_fn)native_table(self)[32]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_33_fn)(void *, uint64_t, int32_t, void *);
static WINAPI int32_t overlay_33(guest_object *self, uint64_t a0, int32_t a1, void * a2) { // SetOverlayTransformAbsolute
    require(self == &overlay); overlay_note(33); overlay_native_33_fn fn = (overlay_native_33_fn)native_table(self)[33]; (void)fn;
    return fn(self->native, a0, a1, a2);
}
typedef int32_t (*overlay_native_34_fn)(void *, uint64_t, void *, void *);
static WINAPI int32_t overlay_34(guest_object *self, uint64_t a0, void * a1, void * a2) { // GetOverlayTransformAbsolute
    require(self == &overlay); overlay_note(34); overlay_native_34_fn fn = (overlay_native_34_fn)native_table(self)[34]; (void)fn;
    return fn(self->native, a0, a1, a2);
}
typedef int32_t (*overlay_native_35_fn)(void *, uint64_t, uint32_t, void *);
static WINAPI int32_t overlay_35(guest_object *self, uint64_t a0, uint32_t a1, void * a2) { // SetOverlayTransformTrackedDeviceRelative
    require(self == &overlay); overlay_note(35); overlay_native_35_fn fn = (overlay_native_35_fn)native_table(self)[35]; (void)fn;
    return fn(self->native, a0, a1, a2);
}
typedef int32_t (*overlay_native_36_fn)(void *, uint64_t, void *, void *);
static WINAPI int32_t overlay_36(guest_object *self, uint64_t a0, void * a1, void * a2) { // GetOverlayTransformTrackedDeviceRelative
    require(self == &overlay); overlay_note(36); overlay_native_36_fn fn = (overlay_native_36_fn)native_table(self)[36]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_37_fn)(void *, uint64_t, uint32_t, void *);
static WINAPI int32_t overlay_37(guest_object *self, uint64_t a0, uint32_t a1, void * a2) { // SetOverlayTransformTrackedDeviceComponent
    require(self == &overlay); overlay_note(37); overlay_native_37_fn fn = (overlay_native_37_fn)native_table(self)[37]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_38_fn)(void *, uint64_t, void *, void *, uint32_t);
static WINAPI int32_t overlay_38(guest_object *self, uint64_t a0, void * a1, void * a2, uint32_t a3) { // GetOverlayTransformTrackedDeviceComponent
    require(self == &overlay); overlay_note(38); overlay_native_38_fn fn = (overlay_native_38_fn)native_table(self)[38]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_39_fn)(void *, uint64_t, void *, void *);
static WINAPI int32_t overlay_39(guest_object *self, uint64_t a0, void * a1, void * a2) { // GetOverlayTransformOverlayRelative
    require(self == &overlay); overlay_note(39); overlay_native_39_fn fn = (overlay_native_39_fn)native_table(self)[39]; (void)fn;
    return fn(self->native, a0, a1, a2);
}
typedef int32_t (*overlay_native_40_fn)(void *, uint64_t, uint64_t, void *);
static WINAPI int32_t overlay_40(guest_object *self, uint64_t a0, uint64_t a1, void * a2) { // SetOverlayTransformOverlayRelative
    require(self == &overlay); overlay_note(40); overlay_native_40_fn fn = (overlay_native_40_fn)native_table(self)[40]; (void)fn;
    return fn(self->native, a0, a1, a2);
}
typedef int32_t (*overlay_native_41_fn)(void *, uint64_t);
static WINAPI int32_t overlay_41(guest_object *self, uint64_t a0) { // ShowOverlay
    require(self == &overlay); overlay_note(41); overlay_native_41_fn fn = (overlay_native_41_fn)native_table(self)[41]; (void)fn;
    return fn(self->native, a0);
}
typedef int32_t (*overlay_native_42_fn)(void *, uint64_t);
static WINAPI int32_t overlay_42(guest_object *self, uint64_t a0) { // HideOverlay
    require(self == &overlay); overlay_note(42); overlay_native_42_fn fn = (overlay_native_42_fn)native_table(self)[42]; (void)fn;
    return fn(self->native, a0);
}
typedef uint8_t (*overlay_native_43_fn)(void *, uint64_t);
static WINAPI uint8_t overlay_43(guest_object *self, uint64_t a0) { // IsOverlayVisible
    require(self == &overlay); overlay_note(43); overlay_native_43_fn fn = (overlay_native_43_fn)native_table(self)[43]; (void)fn;
    return fn(self->native, a0);
}
typedef int32_t (*overlay_native_44_fn)(void *, uint64_t, int32_t, overlay_vec2, void *);
static WINAPI int32_t overlay_44(guest_object *self, uint64_t a0, int32_t a1, overlay_vec2 a2, void * a3) { // GetTransformForOverlayCoordinates
    require(self == &overlay); overlay_note(44); overlay_native_44_fn fn = (overlay_native_44_fn)native_table(self)[44]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef uint8_t (*overlay_native_45_fn)(void *, uint64_t, void *, uint32_t);
static WINAPI uint8_t overlay_45(guest_object *self, uint64_t a0, void * a1, uint32_t a2) { // PollNextOverlayEvent
    require(self == &overlay); overlay_note(45); overlay_native_45_fn fn = (overlay_native_45_fn)native_table(self)[45]; (void)fn;
    if (overlay_keyboard_event(a1, a2, 0)) return 1;
    _Alignas(8) unsigned char ne[64] = {0};
    uint8_t r = fn(self->native, a0, a1 ? ne : NULL, a1 ? (a2 < sizeof ne ? a2 : (uint32_t)sizeof ne) : 0);   // xrizer's events use the native pack(4) layout
    if (r && a1 && a2 >= 20) { memcpy(a1, ne, 12); memcpy((char *)a1 + 16, ne + 12, 4); }
    return r;
}
typedef int32_t (*overlay_native_46_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_46(guest_object *self, uint64_t a0, void * a1) { // GetOverlayInputMethod
    require(self == &overlay); overlay_note(46); overlay_native_46_fn fn = (overlay_native_46_fn)native_table(self)[46]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_47_fn)(void *, uint64_t, int32_t);
static WINAPI int32_t overlay_47(guest_object *self, uint64_t a0, int32_t a1) { // SetOverlayInputMethod
    require(self == &overlay); overlay_note(47); overlay_native_47_fn fn = (overlay_native_47_fn)native_table(self)[47]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_48_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_48(guest_object *self, uint64_t a0, void * a1) { // GetOverlayMouseScale
    require(self == &overlay); overlay_note(48); overlay_native_48_fn fn = (overlay_native_48_fn)native_table(self)[48]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_49_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_49(guest_object *self, uint64_t a0, void * a1) { // SetOverlayMouseScale
    require(self == &overlay); overlay_note(49); overlay_native_49_fn fn = (overlay_native_49_fn)native_table(self)[49]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef uint8_t (*overlay_native_50_fn)(void *, uint64_t, void *, void *);
static WINAPI uint8_t overlay_50(guest_object *self, uint64_t a0, void * a1, void * a2) { // ComputeOverlayIntersection
    require(self == &overlay); overlay_note(50); overlay_native_50_fn fn = (overlay_native_50_fn)native_table(self)[50]; (void)fn;
    return fn(self->native, a0, a1, a2);
}
typedef uint8_t (*overlay_native_51_fn)(void *, uint64_t);
static WINAPI uint8_t overlay_51(guest_object *self, uint64_t a0) { // IsHoverTargetOverlay
    require(self == &overlay); overlay_note(51); overlay_native_51_fn fn = (overlay_native_51_fn)native_table(self)[51]; (void)fn;
    return 0;
}
typedef uint64_t (*overlay_native_52_fn)(void *);
static WINAPI uint64_t overlay_52(guest_object *self) { // GetGamepadFocusOverlay
    require(self == &overlay); overlay_note(52); overlay_native_52_fn fn = (overlay_native_52_fn)native_table(self)[52]; (void)fn;
    return 0;
}
typedef int32_t (*overlay_native_53_fn)(void *, uint64_t);
static WINAPI int32_t overlay_53(guest_object *self, uint64_t a0) { // SetGamepadFocusOverlay
    require(self == &overlay); overlay_note(53); overlay_native_53_fn fn = (overlay_native_53_fn)native_table(self)[53]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_54_fn)(void *, int32_t, uint64_t, uint64_t);
static WINAPI int32_t overlay_54(guest_object *self, int32_t a0, uint64_t a1, uint64_t a2) { // SetOverlayNeighbor
    require(self == &overlay); overlay_note(54); overlay_native_54_fn fn = (overlay_native_54_fn)native_table(self)[54]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_55_fn)(void *, int32_t, uint64_t);
static WINAPI int32_t overlay_55(guest_object *self, int32_t a0, uint64_t a1) { // MoveGamepadFocusToNeighbor
    require(self == &overlay); overlay_note(55); overlay_native_55_fn fn = (overlay_native_55_fn)native_table(self)[55]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_56_fn)(void *, uint64_t, int32_t, void *, float);
static WINAPI int32_t overlay_56(guest_object *self, uint64_t a0, int32_t a1, void * a2, float a3) { // SetOverlayDualAnalogTransform
    require(self == &overlay); overlay_note(56); overlay_native_56_fn fn = (overlay_native_56_fn)native_table(self)[56]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_57_fn)(void *, uint64_t, int32_t, void *, void *);
static WINAPI int32_t overlay_57(guest_object *self, uint64_t a0, int32_t a1, void * a2, void * a3) { // GetOverlayDualAnalogTransform
    require(self == &overlay); overlay_note(57); overlay_native_57_fn fn = (overlay_native_57_fn)native_table(self)[57]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_58_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_58(guest_object *self, uint64_t a0, void * a1) { // SetOverlayTexture
    require(self == &overlay); overlay_note(58); overlay_native_58_fn fn = (overlay_native_58_fn)native_table(self)[58]; (void)fn;
    return fn(self->native, a0, a1);
}
typedef int32_t (*overlay_native_59_fn)(void *, uint64_t);
static WINAPI int32_t overlay_59(guest_object *self, uint64_t a0) { // ClearOverlayTexture
    require(self == &overlay); overlay_note(59); overlay_native_59_fn fn = (overlay_native_59_fn)native_table(self)[59]; (void)fn;
    return fn(self->native, a0);
}
typedef int32_t (*overlay_native_60_fn)(void *, uint64_t, void *, uint32_t, uint32_t, uint32_t);
static WINAPI int32_t overlay_60(guest_object *self, uint64_t a0, void * a1, uint32_t a2, uint32_t a3, uint32_t a4) { // SetOverlayRaw
    require(self == &overlay); overlay_note(60); overlay_native_60_fn fn = (overlay_native_60_fn)native_table(self)[60]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_61_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_61(guest_object *self, uint64_t a0, void * a1) { // SetOverlayFromFile
    require(self == &overlay); overlay_note(61); overlay_native_61_fn fn = (overlay_native_61_fn)native_table(self)[61]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_62_fn)(void *, uint64_t, void *, void *, void *, void *, void *, void *, void *, void *);
static WINAPI int32_t overlay_62(guest_object *self, uint64_t a0, void * a1, void * a2, void * a3, void * a4, void * a5, void * a6, void * a7, void * a8) { // GetOverlayTexture
    require(self == &overlay); overlay_note(62); overlay_native_62_fn fn = (overlay_native_62_fn)native_table(self)[62]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_63_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_63(guest_object *self, uint64_t a0, void * a1) { // ReleaseNativeOverlayHandle
    require(self == &overlay); overlay_note(63); overlay_native_63_fn fn = (overlay_native_63_fn)native_table(self)[63]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_64_fn)(void *, uint64_t, void *, void *);
static WINAPI int32_t overlay_64(guest_object *self, uint64_t a0, void * a1, void * a2) { // GetOverlayTextureSize
    require(self == &overlay); overlay_note(64); overlay_native_64_fn fn = (overlay_native_64_fn)native_table(self)[64]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_65_fn)(void *, void *, void *, void *, void *);
static WINAPI int32_t overlay_65(guest_object *self, void * a0, void * a1, void * a2, void * a3) { // CreateDashboardOverlay
    require(self == &overlay); overlay_note(65); overlay_native_65_fn fn = (overlay_native_65_fn)native_table(self)[65]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef uint8_t (*overlay_native_66_fn)(void *);
static WINAPI uint8_t overlay_66(guest_object *self) { // IsDashboardVisible
    require(self == &overlay); overlay_note(66); overlay_native_66_fn fn = (overlay_native_66_fn)native_table(self)[66]; (void)fn;
    return fn(self->native);
}
typedef uint8_t (*overlay_native_67_fn)(void *, uint64_t);
static WINAPI uint8_t overlay_67(guest_object *self, uint64_t a0) { // IsActiveDashboardOverlay
    require(self == &overlay); overlay_note(67); overlay_native_67_fn fn = (overlay_native_67_fn)native_table(self)[67]; (void)fn;
    return 0;
}
typedef int32_t (*overlay_native_68_fn)(void *, uint64_t, uint32_t);
static WINAPI int32_t overlay_68(guest_object *self, uint64_t a0, uint32_t a1) { // SetDashboardOverlaySceneProcess
    require(self == &overlay); overlay_note(68); overlay_native_68_fn fn = (overlay_native_68_fn)native_table(self)[68]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_69_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_69(guest_object *self, uint64_t a0, void * a1) { // GetDashboardOverlaySceneProcess
    require(self == &overlay); overlay_note(69); overlay_native_69_fn fn = (overlay_native_69_fn)native_table(self)[69]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef void (*overlay_native_70_fn)(void *, void *);
static WINAPI void overlay_70(guest_object *self, void * a0) { // ShowDashboard
    require(self == &overlay); overlay_note(70); overlay_native_70_fn fn = (overlay_native_70_fn)native_table(self)[70]; (void)fn;
    return;
}
typedef uint32_t (*overlay_native_71_fn)(void *);
static WINAPI uint32_t overlay_71(guest_object *self) { // GetPrimaryDashboardDevice
    require(self == &overlay); overlay_note(71); overlay_native_71_fn fn = (overlay_native_71_fn)native_table(self)[71]; (void)fn;
    return 0;
}
typedef int32_t (*overlay_native_72_fn)(void *, int32_t, int32_t, void *, uint32_t, void *, uint8_t, uint64_t);
static WINAPI int32_t overlay_72(guest_object *self, int32_t a0, int32_t a1, void * a2, uint32_t a3, void * a4, uint8_t a5, uint64_t a6) { // ShowKeyboard
    require(self == &overlay); overlay_note(72); overlay_native_72_fn fn = (overlay_native_72_fn)native_table(self)[72]; (void)fn;
    overlay_keyboard_show((const char *)a4, a6, 1, "IVROverlay_018::ShowKeyboard"); return 0;
}
typedef int32_t (*overlay_native_73_fn)(void *, uint64_t, int32_t, int32_t, void *, uint32_t, void *, uint8_t, uint64_t);
static WINAPI int32_t overlay_73(guest_object *self, uint64_t a0, int32_t a1, int32_t a2, void * a3, uint32_t a4, void * a5, uint8_t a6, uint64_t a7) { // ShowKeyboardForOverlay
    require(self == &overlay); overlay_note(73); overlay_native_73_fn fn = (overlay_native_73_fn)native_table(self)[73]; (void)fn;
    overlay_keyboard_show((const char *)a5, a7, 0, "IVROverlay_018::ShowKeyboardForOverlay"); return 0;
}
typedef uint32_t (*overlay_native_74_fn)(void *, void *, uint32_t);
static WINAPI uint32_t overlay_74(guest_object *self, void * a0, uint32_t a1) { // GetKeyboardText
    require(self == &overlay); overlay_note(74); overlay_native_74_fn fn = (overlay_native_74_fn)native_table(self)[74]; (void)fn;
    pthread_mutex_lock(&overlay_kbd.lock);
    uint32_t n = (uint32_t)strlen(overlay_kbd.text);
    if (a0 && a1) { uint32_t c = n < a1 - 1 ? n : a1 - 1; memcpy(a0, overlay_kbd.text, c); ((char *)a0)[c] = 0; }
    pthread_mutex_unlock(&overlay_kbd.lock);
    return n;
}
typedef void (*overlay_native_75_fn)(void *);
static WINAPI void overlay_75(guest_object *self) { // HideKeyboard
    require(self == &overlay); overlay_note(75); overlay_native_75_fn fn = (overlay_native_75_fn)native_table(self)[75]; (void)fn;
    pthread_mutex_lock(&overlay_kbd.lock); overlay_kbd.next = overlay_kbd.count = 0; pthread_mutex_unlock(&overlay_kbd.lock);
}
typedef void (*overlay_native_76_fn)(void *, int32_t, void *);
static WINAPI void overlay_76(guest_object *self, int32_t a0, void * a1) { // SetKeyboardTransformAbsolute
    require(self == &overlay); overlay_note(76); overlay_native_76_fn fn = (overlay_native_76_fn)native_table(self)[76]; (void)fn;
    return;
}
typedef void (*overlay_native_77_fn)(void *, uint64_t, overlay_rect2);
static WINAPI void overlay_77(guest_object *self, uint64_t a0, overlay_rect2 a1) { // SetKeyboardPositionForOverlay
    require(self == &overlay); overlay_note(77); overlay_native_77_fn fn = (overlay_native_77_fn)native_table(self)[77]; (void)fn;
    return;
}
typedef int32_t (*overlay_native_78_fn)(void *, uint64_t, void *, uint32_t, uint32_t);
static WINAPI int32_t overlay_78(guest_object *self, uint64_t a0, void * a1, uint32_t a2, uint32_t a3) { // SetOverlayIntersectionMask
    require(self == &overlay); overlay_note(78); overlay_native_78_fn fn = (overlay_native_78_fn)native_table(self)[78]; (void)fn;
    return fn(self->native, a0, a1, a2, a3);
}
typedef int32_t (*overlay_native_79_fn)(void *, uint64_t, void *);
static WINAPI int32_t overlay_79(guest_object *self, uint64_t a0, void * a1) { // GetOverlayFlags
    require(self == &overlay); overlay_note(79); overlay_native_79_fn fn = (overlay_native_79_fn)native_table(self)[79]; (void)fn;
    return 23;   /* RequestFailed: xrizer's method is todo!() */
}
typedef int32_t (*overlay_native_80_fn)(void *, void *, void *, void *, void *, void *, void *);
static WINAPI int32_t overlay_80(guest_object *self, void * a0, void * a1, void * a2, void * a3, void * a4, void * a5) { // ShowMessageOverlay
    require(self == &overlay); overlay_note(80); overlay_native_80_fn fn = (overlay_native_80_fn)native_table(self)[80]; (void)fn;
    return 5;   /* RequestFailed: xrizer's method is todo!() */
}
typedef void (*overlay_native_81_fn)(void *);
static WINAPI void overlay_81(guest_object *self) { // CloseMessageOverlay
    require(self == &overlay); overlay_note(81); overlay_native_81_fn fn = (overlay_native_81_fn)native_table(self)[81]; (void)fn;
    return;
}
static void overlay_install(void) {
    for (unsigned i = 0; i < 82; i++) overlay_table[i] = NULL;
    overlay_table[0] = overlay_0;
    overlay_table[1] = overlay_1;
    overlay_table[2] = overlay_2;
    overlay_table[3] = overlay_3;
    overlay_table[4] = overlay_4;
    overlay_table[5] = overlay_5;
    overlay_table[6] = overlay_6;
    overlay_table[7] = overlay_7;
    overlay_table[8] = overlay_8;
    overlay_table[9] = overlay_9;
    overlay_table[10] = overlay_10;
    overlay_table[11] = overlay_11;
    overlay_table[12] = overlay_12;
    overlay_table[13] = overlay_13;
    overlay_table[14] = overlay_14;
    overlay_table[15] = overlay_15;
    overlay_table[16] = overlay_16;
    overlay_table[17] = overlay_17;
    overlay_table[18] = overlay_18;
    overlay_table[19] = overlay_19;
    overlay_table[20] = overlay_20;
    overlay_table[21] = overlay_21;
    overlay_table[22] = overlay_22;
    overlay_table[23] = overlay_23;
    overlay_table[24] = overlay_24;
    overlay_table[25] = overlay_25;
    overlay_table[26] = overlay_26;
    overlay_table[27] = overlay_27;
    overlay_table[28] = overlay_28;
    overlay_table[29] = overlay_29;
    overlay_table[30] = overlay_30;
    overlay_table[31] = overlay_31;
    overlay_table[32] = overlay_32;
    overlay_table[33] = overlay_33;
    overlay_table[34] = overlay_34;
    overlay_table[35] = overlay_35;
    overlay_table[36] = overlay_36;
    overlay_table[37] = overlay_37;
    overlay_table[38] = overlay_38;
    overlay_table[39] = overlay_39;
    overlay_table[40] = overlay_40;
    overlay_table[41] = overlay_41;
    overlay_table[42] = overlay_42;
    overlay_table[43] = overlay_43;
    overlay_table[44] = overlay_44;
    overlay_table[45] = overlay_45;
    overlay_table[46] = overlay_46;
    overlay_table[47] = overlay_47;
    overlay_table[48] = overlay_48;
    overlay_table[49] = overlay_49;
    overlay_table[50] = overlay_50;
    overlay_table[51] = overlay_51;
    overlay_table[52] = overlay_52;
    overlay_table[53] = overlay_53;
    overlay_table[54] = overlay_54;
    overlay_table[55] = overlay_55;
    overlay_table[56] = overlay_56;
    overlay_table[57] = overlay_57;
    overlay_table[58] = overlay_58;
    overlay_table[59] = overlay_59;
    overlay_table[60] = overlay_60;
    overlay_table[61] = overlay_61;
    overlay_table[62] = overlay_62;
    overlay_table[63] = overlay_63;
    overlay_table[64] = overlay_64;
    overlay_table[65] = overlay_65;
    overlay_table[66] = overlay_66;
    overlay_table[67] = overlay_67;
    overlay_table[68] = overlay_68;
    overlay_table[69] = overlay_69;
    overlay_table[70] = overlay_70;
    overlay_table[71] = overlay_71;
    overlay_table[72] = overlay_72;
    overlay_table[73] = overlay_73;
    overlay_table[74] = overlay_74;
    overlay_table[75] = overlay_75;
    overlay_table[76] = overlay_76;
    overlay_table[77] = overlay_77;
    overlay_table[78] = overlay_78;
    overlay_table[79] = overlay_79;
    overlay_table[80] = overlay_80;
    overlay_table[81] = overlay_81;
}
// RenderModel_t / RenderModel_TextureMap_t are `pack(8)` on Windows and `pack(4)` on Apple, so their pointers sit at different
// offsets: xrizer's (native) struct is copied into a Windows-layout one for the guest, the vertex/index/texel arrays stay where
// xrizer made them, and the free calls hand the native struct back. A small table maps one to the other.
typedef struct { const void *vertices; uint32_t vertex_count; const void *indices; uint32_t triangle_count; int32_t texture; } guest_render_model;
typedef struct { uint16_t width, height; const void *texels; } guest_texture_map;
typedef struct __attribute__((packed, aligned(4))) { const void *vertices; uint32_t vertex_count; const void *indices; uint32_t triangle_count; int32_t texture; } native_render_model;
typedef struct __attribute__((packed, aligned(4))) { uint16_t width, height; const void *texels; } native_texture_map;
_Static_assert(sizeof(guest_render_model) == 32 && sizeof(native_render_model) == 28, "RenderModel_t");
_Static_assert(sizeof(guest_texture_map) == 16 && sizeof(native_texture_map) == 12, "RenderModel_TextureMap_t");
static struct { void *guest, *native; int texture; } rm_map[256];
static pthread_mutex_t rm_lock = PTHREAD_MUTEX_INITIALIZER;
static void *rm_wrap(void *native, int texture) {
    void *g = calloc(1, texture ? sizeof(guest_texture_map) : sizeof(guest_render_model));
    if (texture) { const native_texture_map *n = native; guest_texture_map *w = g; w->width = n->width; w->height = n->height; w->texels = n->texels; }
    else { const native_render_model *n = native; guest_render_model *w = g;
           w->vertices = n->vertices; w->vertex_count = n->vertex_count; w->indices = n->indices; w->triangle_count = n->triangle_count; w->texture = n->texture; }
    pthread_mutex_lock(&rm_lock);
    int i = 0; while (i < 256 && rm_map[i].guest) i++;
    if (i < 256) { rm_map[i].guest = g; rm_map[i].native = native; rm_map[i].texture = texture; }
    else vx_log("xrizer_guest_bridge: IVRRenderModels: more than 256 models/textures alive; one is not freed");
    pthread_mutex_unlock(&rm_lock);
    return g;
}
static void rm_free(void *guest, int texture, void (*native_free)(void *, void *)) {
    void *native = NULL;
    pthread_mutex_lock(&rm_lock);
    for (int i = 0; i < 256; i++) if (rm_map[i].guest == guest && rm_map[i].texture == texture) { native = rm_map[i].native; rm_map[i].guest = NULL; break; }
    pthread_mutex_unlock(&rm_lock);
    if (!native) { vx_log("xrizer_guest_bridge: IVRRenderModels: Free of an unknown %s %p ignored", texture ? "texture" : "model", guest); return; }
    native_free(rendermodels_object.native, native);
    free(guest);
}
static void controller_state_to_native(native_controller_state *n, const guest_controller_state *g) {
    n->packet = g->packet; n->pressed = g->pressed; n->touched = g->touched; memcpy(n->axis, g->axis, sizeof n->axis);
}
// ---- IVRRenderModels_005 (openvr 1.0.9 class IVRRenderModels): xrizer's own interface, one typed forwarder per slot (18 slots) ----
static const char *const rendermodels_names[18] = {"LoadRenderModel_Async", "FreeRenderModel", "LoadTexture_Async", "FreeTexture", "LoadTextureD3D11_Async", "LoadIntoTextureD3D11_Async", "FreeTextureD3D11", "GetRenderModelName", "GetRenderModelCount", "GetComponentCount", "GetComponentName", "GetComponentButtonMask", "GetComponentRenderModelName", "GetComponentState", "RenderModelHasComponent", "GetRenderModelThumbnailURL", "GetRenderModelOriginalPath", "GetRenderModelErrorNameFromEnum"};
static uint8_t rendermodels_seen[18];
static void rendermodels_note(unsigned slot) {   // the first call of each method is logged
    if (!rendermodels_seen[slot]) { rendermodels_seen[slot] = 1; vx_log("xrizer_guest_bridge: IVRRenderModels_005::%s (slot %u) called", rendermodels_names[slot], slot); }
}
static void rendermodels_result(unsigned slot, uint64_t value) {   // what xrizer answered the first time
    static uint8_t shown[18]; if (!shown[slot]) { shown[slot] = 1; vx_log("xrizer_guest_bridge: IVRRenderModels_005::%s returned %llu (%#llx)", rendermodels_names[slot], (unsigned long long)value, (unsigned long long)value); }
}
typedef int32_t (*rendermodels_native_0_fn)(void *, void *, void *);
static WINAPI int32_t rendermodels_0(guest_object *self, void * a0, void * a1) { // LoadRenderModel_Async
    require(self == &rendermodels_object); rendermodels_note(0); rendermodels_native_0_fn fn = (rendermodels_native_0_fn)native_table(self)[0]; (void)fn;
    void *np = NULL; int32_t r = fn(self->native, a0, &np);
    if (np) *(void **)a1 = rm_wrap(np, 0);
    rendermodels_result(0, (uint64_t)(uint32_t)r);
    return r;
}
typedef void (*rendermodels_native_1_fn)(void *, void *);
static WINAPI void rendermodels_1(guest_object *self, void * a0) { // FreeRenderModel
    require(self == &rendermodels_object); rendermodels_note(1); rendermodels_native_1_fn fn = (rendermodels_native_1_fn)native_table(self)[1]; (void)fn;
    rm_free(a0, 0, (void (*)(void *, void *))fn);
}
typedef int32_t (*rendermodels_native_2_fn)(void *, int32_t, void *);
static WINAPI int32_t rendermodels_2(guest_object *self, int32_t a0, void * a1) { // LoadTexture_Async
    require(self == &rendermodels_object); rendermodels_note(2); rendermodels_native_2_fn fn = (rendermodels_native_2_fn)native_table(self)[2]; (void)fn;
    void *np = NULL; int32_t r = fn(self->native, a0, &np);
    if (np) *(void **)a1 = rm_wrap(np, 1);
    rendermodels_result(2, (uint64_t)(uint32_t)r);
    return r;
}
typedef void (*rendermodels_native_3_fn)(void *, void *);
static WINAPI void rendermodels_3(guest_object *self, void * a0) { // FreeTexture
    require(self == &rendermodels_object); rendermodels_note(3); rendermodels_native_3_fn fn = (rendermodels_native_3_fn)native_table(self)[3]; (void)fn;
    rm_free(a0, 1, (void (*)(void *, void *))fn);
}
typedef int32_t (*rendermodels_native_4_fn)(void *, int32_t, void *, void *);
static WINAPI int32_t rendermodels_4(guest_object *self, int32_t a0, void * a1, void * a2) { // LoadTextureD3D11_Async
    require(self == &rendermodels_object); rendermodels_note(4); rendermodels_native_4_fn fn = (rendermodels_native_4_fn)native_table(self)[4]; (void)fn;
    int32_t r = fn(self->native, a0, a1, a2); rendermodels_result(4, (uint64_t)r); return r;
}
typedef int32_t (*rendermodels_native_5_fn)(void *, int32_t, void *);
static WINAPI int32_t rendermodels_5(guest_object *self, int32_t a0, void * a1) { // LoadIntoTextureD3D11_Async
    require(self == &rendermodels_object); rendermodels_note(5); rendermodels_native_5_fn fn = (rendermodels_native_5_fn)native_table(self)[5]; (void)fn;
    int32_t r = fn(self->native, a0, a1); rendermodels_result(5, (uint64_t)r); return r;
}
typedef void (*rendermodels_native_6_fn)(void *, void *);
static WINAPI void rendermodels_6(guest_object *self, void * a0) { // FreeTextureD3D11
    require(self == &rendermodels_object); rendermodels_note(6); rendermodels_native_6_fn fn = (rendermodels_native_6_fn)native_table(self)[6]; (void)fn;
    
}
typedef uint32_t (*rendermodels_native_7_fn)(void *, uint32_t, void *, uint32_t);
static WINAPI uint32_t rendermodels_7(guest_object *self, uint32_t a0, void * a1, uint32_t a2) { // GetRenderModelName
    require(self == &rendermodels_object); rendermodels_note(7); rendermodels_native_7_fn fn = (rendermodels_native_7_fn)native_table(self)[7]; (void)fn;
    uint32_t r = fn(self->native, a0, a1, a2); rendermodels_result(7, (uint64_t)r); return r;
}
typedef uint32_t (*rendermodels_native_8_fn)(void *);
static WINAPI uint32_t rendermodels_8(guest_object *self) { // GetRenderModelCount
    require(self == &rendermodels_object); rendermodels_note(8); rendermodels_native_8_fn fn = (rendermodels_native_8_fn)native_table(self)[8]; (void)fn;
    uint32_t r = fn(self->native); rendermodels_result(8, (uint64_t)r); return r;
}
typedef uint32_t (*rendermodels_native_9_fn)(void *, void *);
static WINAPI uint32_t rendermodels_9(guest_object *self, void * a0) { // GetComponentCount
    require(self == &rendermodels_object); rendermodels_note(9); rendermodels_native_9_fn fn = (rendermodels_native_9_fn)native_table(self)[9]; (void)fn;
    uint32_t r = fn(self->native, a0); rendermodels_result(9, (uint64_t)r); return r;
}
typedef uint32_t (*rendermodels_native_10_fn)(void *, void *, uint32_t, void *, uint32_t);
static WINAPI uint32_t rendermodels_10(guest_object *self, void * a0, uint32_t a1, void * a2, uint32_t a3) { // GetComponentName
    require(self == &rendermodels_object); rendermodels_note(10); rendermodels_native_10_fn fn = (rendermodels_native_10_fn)native_table(self)[10]; (void)fn;
    uint32_t r = fn(self->native, a0, a1, a2, a3); rendermodels_result(10, (uint64_t)r); return r;
}
typedef uint64_t (*rendermodels_native_11_fn)(void *, void *, void *);
static WINAPI uint64_t rendermodels_11(guest_object *self, void * a0, void * a1) { // GetComponentButtonMask
    require(self == &rendermodels_object); rendermodels_note(11); rendermodels_native_11_fn fn = (rendermodels_native_11_fn)native_table(self)[11]; (void)fn;
    uint64_t r = fn(self->native, a0, a1); rendermodels_result(11, (uint64_t)r); return r;
}
typedef uint32_t (*rendermodels_native_12_fn)(void *, void *, void *, void *, uint32_t);
static WINAPI uint32_t rendermodels_12(guest_object *self, void * a0, void * a1, void * a2, uint32_t a3) { // GetComponentRenderModelName
    require(self == &rendermodels_object); rendermodels_note(12); rendermodels_native_12_fn fn = (rendermodels_native_12_fn)native_table(self)[12]; (void)fn;
    uint32_t r = fn(self->native, a0, a1, a2, a3); rendermodels_result(12, (uint64_t)r); return r;
}
typedef uint8_t (*rendermodels_native_13_fn)(void *, void *, void *, void *, void *, void *);
static WINAPI uint8_t rendermodels_13(guest_object *self, void * a0, void * a1, void * a2, void * a3, void * a4) { // GetComponentState
    require(self == &rendermodels_object); rendermodels_note(13); rendermodels_native_13_fn fn = (rendermodels_native_13_fn)native_table(self)[13]; (void)fn;
    native_controller_state ns; if (a2) controller_state_to_native(&ns, (const guest_controller_state *)a2);
    uint8_t r = fn(self->native, a0, a1, a2 ? (void *)&ns : NULL, a3, a4); rendermodels_result(13, r); return r;
}
typedef uint8_t (*rendermodels_native_14_fn)(void *, void *, void *);
static WINAPI uint8_t rendermodels_14(guest_object *self, void * a0, void * a1) { // RenderModelHasComponent
    require(self == &rendermodels_object); rendermodels_note(14); rendermodels_native_14_fn fn = (rendermodels_native_14_fn)native_table(self)[14]; (void)fn;
    uint8_t r = fn(self->native, a0, a1); rendermodels_result(14, (uint64_t)r); return r;
}
typedef uint32_t (*rendermodels_native_15_fn)(void *, void *, void *, uint32_t, void *);
static WINAPI uint32_t rendermodels_15(guest_object *self, void * a0, void * a1, uint32_t a2, void * a3) { // GetRenderModelThumbnailURL
    require(self == &rendermodels_object); rendermodels_note(15); rendermodels_native_15_fn fn = (rendermodels_native_15_fn)native_table(self)[15]; (void)fn;
    if (a3) *(int32_t *)a3 = 200; /* VRRenderModelError_NotSupported */ if (a1 && a2) *(char *)a1 = 0; return 0;
}
typedef uint32_t (*rendermodels_native_16_fn)(void *, void *, void *, uint32_t, void *);
static WINAPI uint32_t rendermodels_16(guest_object *self, void * a0, void * a1, uint32_t a2, void * a3) { // GetRenderModelOriginalPath
    require(self == &rendermodels_object); rendermodels_note(16); rendermodels_native_16_fn fn = (rendermodels_native_16_fn)native_table(self)[16]; (void)fn;
    if (a3) *(int32_t *)a3 = 200; if (a1 && a2) *(char *)a1 = 0; return 0;
}
typedef void * (*rendermodels_native_17_fn)(void *, int32_t);
static WINAPI void * rendermodels_17(guest_object *self, int32_t a0) { // GetRenderModelErrorNameFromEnum
    require(self == &rendermodels_object); rendermodels_note(17); rendermodels_native_17_fn fn = (rendermodels_native_17_fn)native_table(self)[17]; (void)fn;
    void * r = fn(self->native, a0); rendermodels_result(17, (uint64_t)r); return r;
}
static void rendermodels_install(void) {
    rendermodels_table[0] = rendermodels_0;
    rendermodels_table[1] = rendermodels_1;
    rendermodels_table[2] = rendermodels_2;
    rendermodels_table[3] = rendermodels_3;
    rendermodels_table[4] = rendermodels_4;
    rendermodels_table[5] = rendermodels_5;
    rendermodels_table[6] = rendermodels_6;
    rendermodels_table[7] = rendermodels_7;
    rendermodels_table[8] = rendermodels_8;
    rendermodels_table[9] = rendermodels_9;
    rendermodels_table[10] = rendermodels_10;
    rendermodels_table[11] = rendermodels_11;
    rendermodels_table[12] = rendermodels_12;
    rendermodels_table[13] = rendermodels_13;
    rendermodels_table[14] = rendermodels_14;
    rendermodels_table[15] = rendermodels_15;
    rendermodels_table[16] = rendermodels_16;
    rendermodels_table[17] = rendermodels_17;
}
// ---- IVRSettings_002 (openvr 1.0.17 class IVRSettings): xrizer's own interface, one typed forwarder per slot (12 slots) ----
static const char *const settings_names[12] = {"GetSettingsErrorNameFromEnum", "Sync", "SetBool", "SetInt32", "SetFloat", "SetString", "GetBool", "GetInt32", "GetFloat", "GetString", "RemoveSection", "RemoveKeyInSection"};
static uint8_t settings_seen[12];
static void settings_note(unsigned slot) {   // the first call of each method is logged
    if (!settings_seen[slot]) { settings_seen[slot] = 1; vx_log("xrizer_guest_bridge: IVRSettings_002::%s (slot %u) called", settings_names[slot], slot); }
}
static void settings_result(unsigned slot, uint64_t value) {   // what xrizer answered the first time
    static uint8_t shown[12]; if (!shown[slot]) { shown[slot] = 1; vx_log("xrizer_guest_bridge: IVRSettings_002::%s returned %llu (%#llx)", settings_names[slot], (unsigned long long)value, (unsigned long long)value); }
}
typedef void * (*settings_native_0_fn)(void *, int32_t);
static WINAPI void * settings_0(guest_object *self, int32_t a0) { // GetSettingsErrorNameFromEnum
    require(self == &settings_object); settings_note(0); settings_native_0_fn fn = (settings_native_0_fn)native_table(self)[0]; (void)fn;
    void * r = fn(self->native, a0); settings_result(0, (uint64_t)r); return r;
}
typedef uint8_t (*settings_native_1_fn)(void *, uint8_t, void *);
static WINAPI uint8_t settings_1(guest_object *self, uint8_t a0, void * a1) { // Sync
    require(self == &settings_object); settings_note(1); settings_native_1_fn fn = (settings_native_1_fn)native_table(self)[1]; (void)fn;
    uint8_t r = fn(self->native, a0, a1); settings_result(1, (uint64_t)r); return r;
}
typedef void (*settings_native_2_fn)(void *, void *, void *, uint8_t, void *);
static WINAPI void settings_2(guest_object *self, void * a0, void * a1, uint8_t a2, void * a3) { // SetBool
    require(self == &settings_object); settings_note(2); settings_native_2_fn fn = (settings_native_2_fn)native_table(self)[2]; (void)fn;
    fn(self->native, a0, a1, a2, a3);
}
typedef void (*settings_native_3_fn)(void *, void *, void *, int32_t, void *);
static WINAPI void settings_3(guest_object *self, void * a0, void * a1, int32_t a2, void * a3) { // SetInt32
    require(self == &settings_object); settings_note(3); settings_native_3_fn fn = (settings_native_3_fn)native_table(self)[3]; (void)fn;
    fn(self->native, a0, a1, a2, a3);
}
typedef void (*settings_native_4_fn)(void *, void *, void *, float, void *);
static WINAPI void settings_4(guest_object *self, void * a0, void * a1, float a2, void * a3) { // SetFloat
    require(self == &settings_object); settings_note(4); settings_native_4_fn fn = (settings_native_4_fn)native_table(self)[4]; (void)fn;
    fn(self->native, a0, a1, a2, a3);
}
typedef void (*settings_native_5_fn)(void *, void *, void *, void *, void *);
static WINAPI void settings_5(guest_object *self, void * a0, void * a1, void * a2, void * a3) { // SetString
    require(self == &settings_object); settings_note(5); settings_native_5_fn fn = (settings_native_5_fn)native_table(self)[5]; (void)fn;
    fn(self->native, a0, a1, a2, a3);
}
typedef uint8_t (*settings_native_6_fn)(void *, void *, void *, void *);
static WINAPI uint8_t settings_6(guest_object *self, void * a0, void * a1, void * a2) { // GetBool
    require(self == &settings_object); settings_note(6); settings_native_6_fn fn = (settings_native_6_fn)native_table(self)[6]; (void)fn;
    uint8_t r = fn(self->native, a0, a1, a2); settings_result(6, (uint64_t)r); return r;
}
typedef int32_t (*settings_native_7_fn)(void *, void *, void *, void *);
static WINAPI int32_t settings_7(guest_object *self, void * a0, void * a1, void * a2) { // GetInt32
    require(self == &settings_object); settings_note(7); settings_native_7_fn fn = (settings_native_7_fn)native_table(self)[7]; (void)fn;
    int32_t r = fn(self->native, a0, a1, a2); settings_result(7, (uint64_t)r); return r;
}
typedef float (*settings_native_8_fn)(void *, void *, void *, void *);
static WINAPI float settings_8(guest_object *self, void * a0, void * a1, void * a2) { // GetFloat
    require(self == &settings_object); settings_note(8); settings_native_8_fn fn = (settings_native_8_fn)native_table(self)[8]; (void)fn;
    float r = fn(self->native, a0, a1, a2); settings_result(8, (uint64_t)(int64_t)(r * 1000.0f)); return r;   /* (logged as milli-units) */
}
typedef void (*settings_native_9_fn)(void *, void *, void *, void *, uint32_t, void *);
static WINAPI void settings_9(guest_object *self, void * a0, void * a1, void * a2, uint32_t a3, void * a4) { // GetString
    require(self == &settings_object); settings_note(9); settings_native_9_fn fn = (settings_native_9_fn)native_table(self)[9]; (void)fn;
    fn(self->native, a0, a1, a2, a3, a4);
}
typedef void (*settings_native_10_fn)(void *, void *, void *);
static WINAPI void settings_10(guest_object *self, void * a0, void * a1) { // RemoveSection
    require(self == &settings_object); settings_note(10); settings_native_10_fn fn = (settings_native_10_fn)native_table(self)[10]; (void)fn;
    fn(self->native, a0, a1);
}
typedef void (*settings_native_11_fn)(void *, void *, void *, void *);
static WINAPI void settings_11(guest_object *self, void * a0, void * a1, void * a2) { // RemoveKeyInSection
    require(self == &settings_object); settings_note(11); settings_native_11_fn fn = (settings_native_11_fn)native_table(self)[11]; (void)fn;
    fn(self->native, a0, a1, a2);
}
static void settings_install(void) {
    settings_table[0] = settings_0;
    settings_table[1] = settings_1;
    settings_table[2] = settings_2;
    settings_table[3] = settings_3;
    settings_table[4] = settings_4;
    settings_table[5] = settings_5;
    settings_table[6] = settings_6;
    settings_table[7] = settings_7;
    settings_table[8] = settings_8;
    settings_table[9] = settings_9;
    settings_table[10] = settings_10;
    settings_table[11] = settings_11;
}
static int supported(const char *name) {
    return name && (!strcmp(name, "IVRSystem_019") || !strcmp(name, "IVRCompositor_022") || !strcmp(name, "IVROverlay_018") ||
                    !strcmp(name, "IVRRenderModels_005") || !strcmp(name, "IVRSettings_002") ||
                    !strcmp(name, "FnTable:IVRSystem_019"));
}
static WINAPI int core_version(guest_object *self, const char *name) {
    require(self == &core && name); if (!supported(name)) return 106; native_version_fn fn = (native_version_fn)native_table(self)[2]; return fn(self->native, name);
}
static WINAPI uint8_t core_present(guest_object *self) {
    require(self == &core); native_present_fn fn = (native_present_fn)native_table(self)[4]; return fn(self->native);
}
static WINAPI void *core_interface(guest_object *self, const char *name, int *error) {
    require(self == &core && initialized && name);
    if (!supported(name)) { if (error) *error = 106; return NULL; }
    native_interface_fn fn = (native_interface_fn)native_table(self)[3];
    void *p = fn(self->native, name, error);
    vx_log("xrizer_guest_bridge: actual native interface %s pointer %p error %d", name, p, error ? *error : -1);
    if (!p) return NULL;
    if (!strcmp(name, "IVRSystem_019")) { system_object.native = p; return &system_object; }
    if (!strcmp(name, "IVRCompositor_022")) { compositor.native = p; return &compositor; }
    if (!strcmp(name, "IVROverlay_018")) { overlay.native = p; return &overlay; }
    if (!strcmp(name, "IVRRenderModels_005")) { rendermodels_object.native = p; return &rendermodels_object; }
    if (!strcmp(name, "IVRSettings_002")) { settings_object.native = p; return &settings_object; }
    if (!strcmp(name, "FnTable:IVRSystem_019")) { native_system_fns = p; return system_fns; }
    if (error) *error = 106; return NULL;
}
static WINAPI void render_size(guest_object *self, uint32_t *width, uint32_t *height) {
    require(self == &system_object); native_size_fn fn = (native_size_fn)native_table(self)[0]; fn(self->native, width, height);
}
static WINAPI matrix44 *member_projection(guest_object *self, matrix44 *out, int eye, float near_z, float far_z) {
    require(self == &system_object && out); native_projection_fn fn = (native_projection_fn)native_table(self)[1];
    *out = fn(self->native, eye, near_z, far_z); return out;
}
// OpenVR slot 2. The native method writes the four tangents; top and bottom stay in its order.
static WINAPI void projection_raw(guest_object *self, int eye, float *left, float *right, float *top, float *bottom) {
    require(self == &system_object);
    native_raw_fn fn = (native_raw_fn)native_table(self)[2];
    fn(self->native, eye, left, right, top, bottom);
}
static WINAPI matrix34 *member_transform(guest_object *self, matrix34 *out, int eye) {
    require(self == &system_object && out); native_transform_fn fn = (native_transform_fn)native_table(self)[4];
    *out = fn(self->native, eye); return out;
}
static WINAPI matrix44 *fntable_projection(matrix44 *out, int eye, float near_z, float far_z) {
    require(native_system_fns && out); native_projection_c_fn fn = (native_projection_c_fn)native_system_fns[1];
    *out = fn(eye, near_z, far_z); return out;
}
static WINAPI void fntable_raw(int eye, float *left, float *right, float *top, float *bottom) {
    require(native_system_fns != NULL);
    void (*fn)(int, float *, float *, float *, float *) = (void (*)(int, float *, float *, float *, float *))native_system_fns[2];
    fn(eye, left, right, top, bottom);
}
static WINAPI matrix34 *fntable_transform(matrix34 *out, int eye) {
    require(native_system_fns && out); native_transform_c_fn fn = (native_transform_c_fn)native_system_fns[4];
    *out = fn(eye); return out;
}
// (TrackedDevicePose_t, 80 bytes on both sides: a 3x4 matrix, two vectors, eTrackingResult, bPoseIsValid, bDeviceIsConnected)
static void note_poses(const char *what, int result, const void *render, uint32_t count) {
    static unsigned calls; calls++;
    if (calls > 30 && calls % 120) return;
    const uint8_t *p = render ? VX_LOW(render) : NULL;
    int32_t tracking = 0; float m[12] = { 0 };
    if (p && count) { memcpy(m, p, sizeof m); memcpy(&tracking, p + 72, 4); }
    vx_log("xrizer_guest_bridge: %s call %u result %d, %u render poses; HMD tracking %d valid %u connected %u position %.3f %.3f %.3f", what, calls, result,
           count, tracking, p && count ? p[76] : 0, p && count ? p[77] : 0, m[3], m[7], m[11]);
    // Read-only: every other device the array reports connected (index, tracking result, valid, position).
    for (uint32_t i = 1; p && i < count && i < 64; i++) {
        const uint8_t *d = p + 80 * (size_t)i;
        if (!d[77]) continue;
        float n[12]; int32_t t; memcpy(n, d, sizeof n); memcpy(&t, d + 72, 4);
        vx_log("xrizer_guest_bridge: %s call %u device %u tracking %d valid %u connected 1 position %.3f %.3f %.3f", what, calls, i, t, d[76], n[3], n[7], n[11]);
    }
}
static WINAPI int wait_poses(guest_object *self, void *render, uint32_t render_count, void *game, uint32_t game_count) {
    require(self == &compositor); native_wait_fn fn = (native_wait_fn)native_table(self)[2];
    int r = fn(self->native, render, render_count, game, game_count);
    note_poses("WaitGetPoses", r, render, render_count);
    vx_diag_rtti_array_tick();
    return r;
}
static WINAPI int last_poses(guest_object *self, void *render, uint32_t render_count, void *game, uint32_t game_count) {
    require(self == &compositor); native_wait_fn fn = (native_wait_fn)native_table(self)[3];
    int r = fn(self->native, render, render_count, game, game_count);
    note_poses("GetLastPoses", r, render, render_count);
    return r;
}
static WINAPI int one_pose(guest_object *self, uint32_t index, void *render, void *game) {
    require(self == &compositor); native_one_pose_fn fn = (native_one_pose_fn)native_table(self)[4];
    return fn(self->native, index, render, game);
}
static WINAPI uint32_t controller_index(guest_object *self, int role) {
    require(self == &system_object); native_role_fn fn = (native_role_fn)native_table(self)[18];
    uint32_t r = fn(self->native, role);
    static unsigned calls; calls++;
    if (calls <= 8 || !(calls % 1000)) vx_log("xrizer_guest_bridge: System019 slot18 role %d -> device %u (call %u)", role, r, calls);
    return r;
}
// IVRSystem slot 19, GetControllerRoleForTrackedDeviceIndex(uint32_t index) -> ETrackedControllerRole (a 32-bit enum); scalars only.
typedef int (*native_index_role_fn)(void *, uint32_t);
static WINAPI int controller_role(guest_object *self, uint32_t index) {
    require(self == &system_object); native_index_role_fn fn = (native_index_role_fn)native_table(self)[19];
    int r = fn(self->native, index);
    static unsigned calls; calls++;
    if (calls <= 8 || !(calls % 1000)) vx_log("xrizer_guest_bridge: System019 slot19 device %u -> role %d (call %u)", index, r, calls);
    return r;
}
// System019 Windows VREvent_t data is at byte 16; the pinned Apple native
// VREvent_t data is at byte 12. Current xrizer emits controller-sized payloads.
static WINAPI uint8_t poll_event(guest_object *self, void *event, uint32_t size) {
    require(self == &system_object);
    if (overlay_keyboard_event(event,size,1)) return 1;   // ShowKeyboard's events (see the IVROverlay keyboard note)
    native_poll_event_fn fn=(native_poll_event_fn)native_table(self)[30];
    _Alignas(8) unsigned char native_event[60]={0};
    uint8_t result=fn(self->native,event ? native_event : NULL,size >= 20 ? sizeof native_event : 0);
    if (result) {
        if (!event || size < 20) unsupported_slot("IVRSystem_019 invalid native event",30);
        memcpy(event,native_event,12);
        memcpy((unsigned char *)event+16,native_event+12,4);
    }
    if (result) { uint32_t type, device; memcpy(&type, native_event, 4); memcpy(&device, native_event + 4, 4);
        vx_log("xrizer_guest_bridge: System019 slot30 size %u result 1 event type %u device %u",size,type,device); }
    else vx_log("xrizer_guest_bridge: System019 slot30 size %u result 0",size);
    return result;
}
static WINAPI hidden_mesh *hidden_area_mesh(guest_object *self, hidden_mesh *out, int eye, int kind) {
    require(self == &system_object && out);
    native_hidden_mesh_fn fn=(native_hidden_mesh_fn)native_table(self)[33];
    hidden_mesh result=fn(self->native,eye,kind);
    vx_log("xrizer_guest_bridge: System019 slot33 eye %d type %d native vertices %p triangles %u",
           eye,kind,result.vertices,result.triangles);
    // The native pointer is xrizer's leaked Rust allocation: no established guest-addressability or lifetime. Copy the mesh
    // (HmdVector2_t[3 * triangles], two floats a vertex) into a bridge-owned buffer per (eye, kind) that the guest reads as plain
    // memory (the AOT code shares the process address space) and that stays valid until the next call for the same eye and kind;
    // a replaced buffer is leaked, not freed, in case the game still holds the old pointer. A zero mesh is passed on as an empty one.
    if (!result.triangles) { out->vertices=NULL; out->triangles=0; return out; }   // (a leaked empty Vec is a dangling non-null pointer)
    if (!result.vertices || result.triangles > 4096 || eye < 0 || eye > 1 || kind < 0 || kind > 2)
        unsupported_slot("IVRSystem_019 invalid hidden mesh",33);
    static float *mesh_copy[2][3];
    size_t bytes=(size_t)result.triangles*3*2*sizeof(float);
    float *copy=malloc(bytes);
    if (!copy) unsupported_slot("IVRSystem_019 hidden mesh out of memory",33);
    memcpy(copy,result.vertices,bytes);
    mesh_copy[eye][kind]=copy;
    out->vertices=copy; out->triangles=result.triangles; return out;
}
static WINAPI void dxgi_output(guest_object *self, int32_t *adapter) {
    require(self == &system_object);
    native_dxgi_output_fn fn=(native_dxgi_output_fn)native_table(self)[7];
    fn(self->native,adapter);
    vx_log("xrizer_guest_bridge: System019 slot7 output %d",adapter ? *adapter : -1);
}
static WINAPI uint32_t string_property(guest_object *self, uint32_t device, int property, char *value, uint32_t capacity, int *error) {
    require(self == &system_object);
    native_string_property_fn fn = (native_string_property_fn)native_table(self)[28];
    uint32_t result=fn(self->native, device, property, value, capacity, error);
    vx_log("xrizer_guest_bridge: System019 slot28 device %u property %d capacity %u result %u error %d",
           device,property,capacity,result,error ? *error : -1);
    return result;
}
static WINAPI uint8_t input_available(guest_object *self) {
    require(self == &system_object); native_present_fn fn = (native_present_fn)native_table(self)[39];
    uint8_t r = fn(self->native);
    static unsigned calls; calls++;
    if (calls <= 3 || !(calls % 1000)) vx_log("xrizer_guest_bridge: System019 slot39 IsInputAvailable %u (call %u)", r, calls);
    return r;
}
// IVRSystem_019 slots 20-25, 34-36: scalars, enums and the caller's error pointer pass through unchanged
// (ETrackedPropertyError and ETrackedDeviceClass are 32-bit enums on both sides; TrackedDevicePose_t is 80 bytes on
// both, see note_poses); only VRControllerState001_t is repacked.
static WINAPI int device_class(guest_object *self, uint32_t device) {
    require(self == &system_object); native_device_class_fn fn = (native_device_class_fn)native_table(self)[20];
    int r = fn(self->native, device);
    static unsigned calls; calls++;
    if (calls <= 8 || !(calls % 1000)) vx_log("xrizer_guest_bridge: System019 slot20 device %u class %d (call %u)", device, r, calls);
    return r;
}
static WINAPI uint8_t device_connected(guest_object *self, uint32_t device) {
    require(self == &system_object); native_device_bool_fn fn = (native_device_bool_fn)native_table(self)[21];
    uint8_t r = fn(self->native, device);
    static unsigned calls; calls++;
    if (calls <= 8 || !(calls % 1000)) vx_log("xrizer_guest_bridge: System019 slot21 device %u connected %u (call %u)", device, r, calls);
    return r;
}
static void note_property(unsigned slot, uint32_t device, int property, const int *error, double value) {
    static unsigned calls[4]; unsigned n = ++calls[slot - 22];
    if (n <= 16 || !(n % 1000)) vx_log("xrizer_guest_bridge: System019 slot%u device %u property %d value %g error %d (call %u)",
                                     slot, device, property, value, error ? *error : -1, n);
}
static WINAPI uint8_t bool_property(guest_object *self, uint32_t device, int property, int *error) {
    require(self == &system_object); native_bool_property_fn fn = (native_bool_property_fn)native_table(self)[22];
    uint8_t r = fn(self->native, device, property, error); note_property(22, device, property, error, r); return r;
}
static WINAPI float float_property(guest_object *self, uint32_t device, int property, int *error) {
    require(self == &system_object); native_float_property_fn fn = (native_float_property_fn)native_table(self)[23];
    float r = fn(self->native, device, property, error); note_property(23, device, property, error, r); return r;
}
static WINAPI int32_t int32_property(guest_object *self, uint32_t device, int property, int *error) {
    require(self == &system_object); native_int32_property_fn fn = (native_int32_property_fn)native_table(self)[24];
    int32_t r = fn(self->native, device, property, error); note_property(24, device, property, error, r); return r;
}
static WINAPI uint64_t uint64_property(guest_object *self, uint32_t device, int property, int *error) {
    require(self == &system_object); native_uint64_property_fn fn = (native_uint64_property_fn)native_table(self)[25];
    uint64_t r = fn(self->native, device, property, error); note_property(25, device, property, error, (double)r); return r;
}
static void copy_controller_state(void *guest, const native_controller_state *n) {
    guest_controller_state g = { .packet = n->packet, .pressed = n->pressed, .touched = n->touched };
    memcpy(g.axis, n->axis, sizeof g.axis);
    memcpy(guest, &g, sizeof g);
}
static void note_controller_state(unsigned slot, uint32_t device, uint32_t size, uint8_t r, const native_controller_state *n) {
    static unsigned calls[2], changes; unsigned c = ++calls[slot - 34];
    // A state that differs from the one this device last returned is logged too ("changed"), so what the guest read
    // after an input change is on record (bounded).
    static struct { uint64_t pressed, touched; float axis[6]; uint8_t seen; } last[2][16];
    int changed = 0;
    if (r && device < 16) {
        __typeof__(last[0][0]) *l = &last[slot - 34][device];
        changed = l->seen && (l->pressed != n->pressed || l->touched != n->touched || memcmp(l->axis, n->axis, sizeof l->axis));
        l->pressed = n->pressed; l->touched = n->touched; memcpy(l->axis, n->axis, sizeof l->axis); l->seen = 1;
    }
    if (changed && ++changes <= 4000)
        vx_log("xrizer_guest_bridge: System019 slot%u device %u changed: packet %u pressed %#llx touched %#llx axis0 %.3f %.3f "
            "axis1 %.3f axis2 %.3f (call %u, change %u)", slot, device, n->packet, (unsigned long long)n->pressed,
            (unsigned long long)n->touched, n->axis[0], n->axis[1], n->axis[2], n->axis[4], c, changes);
    if (c <= 8 || !(c % 1000)) vx_log("xrizer_guest_bridge: System019 slot%u device %u size %u result %u packet %u pressed %#llx touched %#llx "
        "axis0 %.3f %.3f axis1 %.3f (call %u)", slot, device, size, r, n->packet, (unsigned long long)n->pressed,
        (unsigned long long)n->touched, n->axis[0], n->axis[1], n->axis[2], c);
}
// The guest's size is the Windows struct's (64); xrizer is called with its own (60) and the result is repacked.
// Another size is a struct this bridge does not know: refused, nothing written, as xrizer itself refuses one.
static WINAPI uint8_t controller_state(guest_object *self, uint32_t device, void *state, uint32_t size) {
    require(self == &system_object); native_controller_state_fn fn = (native_controller_state_fn)native_table(self)[34];
    if (!state || size != sizeof(guest_controller_state)) { vx_log("xrizer_guest_bridge: System019 slot34 refused size %u state %p", size, state); return 0; }
    native_controller_state n; memset(&n, 0, sizeof n);
    uint8_t r = fn(self->native, device, &n, sizeof n);
    copy_controller_state(state, &n); note_controller_state(34, device, size, r, &n);
    return r;
}
static WINAPI uint8_t controller_state_pose(guest_object *self, int origin, uint32_t device, void *state, uint32_t size, void *pose) {
    require(self == &system_object); native_controller_state_pose_fn fn = (native_controller_state_pose_fn)native_table(self)[35];
    if (!state || size != sizeof(guest_controller_state)) { vx_log("xrizer_guest_bridge: System019 slot35 refused size %u state %p", size, state); return 0; }
    native_controller_state n; memset(&n, 0, sizeof n);
    uint8_t r = fn(self->native, origin, device, &n, sizeof n, pose);
    copy_controller_state(state, &n); note_controller_state(35, device, size, r, &n);
    return r;
}
static WINAPI void haptic_pulse(guest_object *self, uint32_t device, uint32_t axis, uint16_t duration_us) {
    require(self == &system_object); native_haptic_fn fn = (native_haptic_fn)native_table(self)[36];
    static unsigned calls; calls++;
    if (calls <= 8 || !(calls % 1000)) vx_log("xrizer_guest_bridge: System019 slot36 device %u axis %u duration %u us (call %u)", device, axis, duration_us, calls);
    fn(self->native, device, axis, duration_us);
}
static WINAPI void tracking_space(guest_object *self, int origin) {
    require(self == &compositor); native_tracking_fn fn = (native_tracking_fn)native_table(self)[0];
    fn(self->native, origin);
}
typedef struct { void *handle; int32_t type, color; } guest_texture;
typedef struct { float u0, v0, u1, v1; } guest_bounds;
static WINAPI int submit(guest_object *self, int eye, const void *texture, const void *bounds, int flags) {
    require(self == &compositor);
    static unsigned noted;
    int note = noted < 4;
    if (note) {
        const guest_texture *t = texture ? VX_LOW(texture) : NULL;
        const guest_bounds *b = bounds ? VX_LOW(bounds) : NULL;
        vx_log("xrizer_guest_bridge: Submit eye %d flags %#x handle %p type %d color %d bounds %s%.3f %.3f %.3f %.3f",
               eye, flags, t ? t->handle : NULL, t ? t->type : -1, t ? t->color : -1, b ? "" : "(none) ",
               b ? b->u0 : 0.f, b ? b->v0 : 0.f, b ? b->u1 : 0.f, b ? b->v1 : 0.f);
        noted++;
    }
    native_submit_fn fn = (native_submit_fn)native_table(self)[5];
    int result = fn(self->native, eye, texture, bounds, flags);
    if (note) vx_log("xrizer_guest_bridge: Submit result %d", result);
    return result;
}
static WINAPI void handoff(guest_object *self) {
    require(self == &compositor); native_handoff_fn fn = (native_handoff_fn)native_table(self)[7]; fn(self->native);
}
// IVRCompositor_022 slot 8, GetFrameTiming(Compositor_FrameTiming *, uint32_t framesAgo) -> bool. The structure starts with its own
// m_nSize and is `#pragma pack(4)` in openvr_driver.h on every platform (its one double sits at byte 24, already aligned), so the
// Windows and Apple layouts are the same; xrizer reads that size and fills only what fits, so the guest's pointer goes through
// as it does for the pose arrays.
static WINAPI uint8_t frame_timing(guest_object *self, void *timing, uint32_t frames_ago) {
    require(self == &compositor);
    native_frame_timing_fn fn = (native_frame_timing_fn)native_table(self)[8];
    return fn(self->native, timing, frames_ago);
}
static WINAPI uint8_t can_render_scene(guest_object *self) {
    require(self == &compositor);
    native_present_fn fn = (native_present_fn)native_table(self)[24];
    return fn(self->native);
}
void *vx_xrizer_guest_core(void *native_core) {
    if (!native_core || core.native || initialized || consumed) return NULL;
    consumed = 1;
    core_table[0] = unsupported_core_0;
    core_table[1] = unsupported_core_1;
    core_table[2] = unsupported_core_2;
    core_table[3] = unsupported_core_3;
    core_table[4] = unsupported_core_4;
    core_table[5] = unsupported_core_5;
    core_table[6] = unsupported_core_6;
    system_table[0] = unsupported_system_0;
    system_table[1] = unsupported_system_1;
    system_table[2] = unsupported_system_2;
    system_table[3] = unsupported_system_3;
    system_table[4] = unsupported_system_4;
    system_table[5] = unsupported_system_5;
    system_table[6] = unsupported_system_6;
    system_table[7] = unsupported_system_7;
    system_table[8] = unsupported_system_8;
    system_table[9] = unsupported_system_9;
    system_table[10] = unsupported_system_10;
    system_table[11] = unsupported_system_11;
    system_table[12] = unsupported_system_12;
    system_table[13] = unsupported_system_13;
    system_table[14] = unsupported_system_14;
    system_table[15] = unsupported_system_15;
    system_table[16] = unsupported_system_16;
    system_table[17] = unsupported_system_17;
    system_table[18] = unsupported_system_18;
    system_table[19] = unsupported_system_19;
    system_table[20] = unsupported_system_20;
    system_table[21] = unsupported_system_21;
    system_table[22] = unsupported_system_22;
    system_table[23] = unsupported_system_23;
    system_table[24] = unsupported_system_24;
    system_table[25] = unsupported_system_25;
    system_table[26] = unsupported_system_26;
    system_table[27] = unsupported_system_27;
    system_table[28] = unsupported_system_28;
    system_table[29] = unsupported_system_29;
    system_table[30] = unsupported_system_30;
    system_table[31] = unsupported_system_31;
    system_table[32] = unsupported_system_32;
    system_table[33] = unsupported_system_33;
    system_table[34] = unsupported_system_34;
    system_table[35] = unsupported_system_35;
    system_table[36] = unsupported_system_36;
    system_table[37] = unsupported_system_37;
    system_table[38] = unsupported_system_38;
    system_table[39] = unsupported_system_39;
    system_table[40] = unsupported_system_40;
    system_table[41] = unsupported_system_41;
    system_table[42] = unsupported_system_42;
    system_table[43] = unsupported_system_43;
    system_table[44] = unsupported_system_44;
    system_table[45] = unsupported_system_45;
    system_table[46] = unsupported_system_46;
    compositor_table[0] = unsupported_compositor_0;
    compositor_table[1] = unsupported_compositor_1;
    compositor_table[2] = unsupported_compositor_2;
    compositor_table[3] = unsupported_compositor_3;
    compositor_table[4] = unsupported_compositor_4;
    compositor_table[5] = unsupported_compositor_5;
    compositor_table[6] = unsupported_compositor_6;
    compositor_table[7] = unsupported_compositor_7;
    compositor_table[8] = unsupported_compositor_8;
    compositor_table[9] = unsupported_compositor_9;
    compositor_table[10] = unsupported_compositor_10;
    compositor_table[11] = unsupported_compositor_11;
    compositor_table[12] = unsupported_compositor_12;
    compositor_table[13] = unsupported_compositor_13;
    compositor_table[14] = unsupported_compositor_14;
    compositor_table[15] = unsupported_compositor_15;
    compositor_table[16] = unsupported_compositor_16;
    compositor_table[17] = unsupported_compositor_17;
    compositor_table[18] = unsupported_compositor_18;
    compositor_table[19] = unsupported_compositor_19;
    compositor_table[20] = unsupported_compositor_20;
    compositor_table[21] = unsupported_compositor_21;
    compositor_table[22] = unsupported_compositor_22;
    compositor_table[23] = unsupported_compositor_23;
    compositor_table[24] = unsupported_compositor_24;
    compositor_table[25] = unsupported_compositor_25;
    compositor_table[26] = unsupported_compositor_26;
    compositor_table[27] = unsupported_compositor_27;
    compositor_table[28] = unsupported_compositor_28;
    compositor_table[29] = unsupported_compositor_29;
    compositor_table[30] = unsupported_compositor_30;
    compositor_table[31] = unsupported_compositor_31;
    compositor_table[32] = unsupported_compositor_32;
    compositor_table[33] = unsupported_compositor_33;
    compositor_table[34] = unsupported_compositor_34;
    compositor_table[35] = unsupported_compositor_35;
    compositor_table[36] = unsupported_compositor_36;
    compositor_table[37] = unsupported_compositor_37;
    compositor_table[38] = unsupported_compositor_38;
    compositor_table[39] = unsupported_compositor_39;
    compositor_table[40] = unsupported_compositor_40;
    compositor_table[41] = unsupported_compositor_41;
    compositor_table[42] = unsupported_compositor_42;
    compositor_table[43] = unsupported_compositor_43;
    system_fns[0] = unsupported_fns_0;
    system_fns[1] = unsupported_fns_1;
    system_fns[2] = unsupported_fns_2;
    system_fns[3] = unsupported_fns_3;
    system_fns[4] = unsupported_fns_4;
    system_fns[5] = unsupported_fns_5;
    system_fns[6] = unsupported_fns_6;
    system_fns[7] = unsupported_fns_7;
    system_fns[8] = unsupported_fns_8;
    system_fns[9] = unsupported_fns_9;
    system_fns[10] = unsupported_fns_10;
    system_fns[11] = unsupported_fns_11;
    system_fns[12] = unsupported_fns_12;
    system_fns[13] = unsupported_fns_13;
    system_fns[14] = unsupported_fns_14;
    system_fns[15] = unsupported_fns_15;
    system_fns[16] = unsupported_fns_16;
    system_fns[17] = unsupported_fns_17;
    system_fns[18] = unsupported_fns_18;
    system_fns[19] = unsupported_fns_19;
    system_fns[20] = unsupported_fns_20;
    system_fns[21] = unsupported_fns_21;
    system_fns[22] = unsupported_fns_22;
    system_fns[23] = unsupported_fns_23;
    system_fns[24] = unsupported_fns_24;
    system_fns[25] = unsupported_fns_25;
    system_fns[26] = unsupported_fns_26;
    system_fns[27] = unsupported_fns_27;
    system_fns[28] = unsupported_fns_28;
    system_fns[29] = unsupported_fns_29;
    system_fns[30] = unsupported_fns_30;
    system_fns[31] = unsupported_fns_31;
    system_fns[32] = unsupported_fns_32;
    system_fns[33] = unsupported_fns_33;
    system_fns[34] = unsupported_fns_34;
    system_fns[35] = unsupported_fns_35;
    system_fns[36] = unsupported_fns_36;
    system_fns[37] = unsupported_fns_37;
    system_fns[38] = unsupported_fns_38;
    system_fns[39] = unsupported_fns_39;
    system_fns[40] = unsupported_fns_40;
    system_fns[41] = unsupported_fns_41;
    system_fns[42] = unsupported_fns_42;
    system_fns[43] = unsupported_fns_43;
    system_fns[44] = unsupported_fns_44;
    system_fns[45] = unsupported_fns_45;
    system_fns[46] = unsupported_fns_46;
    core_table[0] = core_init; core_table[1] = core_cleanup; core_table[2] = core_version; core_table[3] = core_interface; core_table[4] = core_present;
    system_table[0] = render_size; system_table[1] = member_projection; system_table[2] = projection_raw; system_table[4] = member_transform;
    system_table[7] = dxgi_output; system_table[18] = controller_index; system_table[19] = controller_role; system_table[28] = string_property; system_table[30] = poll_event; system_table[33] = hidden_area_mesh; system_table[39] = input_available;
    system_table[20] = device_class; system_table[21] = device_connected; system_table[22] = bool_property; system_table[23] = float_property;
    system_table[24] = int32_property; system_table[25] = uint64_property; system_table[34] = controller_state;
    system_table[35] = controller_state_pose; system_table[36] = haptic_pulse;
    compositor_table[0] = tracking_space; compositor_table[2] = wait_poses; compositor_table[3] = last_poses; compositor_table[4] = one_pose; compositor_table[5] = submit; compositor_table[7] = handoff; compositor_table[8] = frame_timing; compositor_table[24] = can_render_scene;
    system_fns[1] = fntable_projection; system_fns[2] = fntable_raw; system_fns[4] = fntable_transform;
    overlay_install(); rendermodels_install(); settings_install();
    cleaned = 0; core.native = native_core; return &core;
}
int vx_xrizer_guest_init(int type, const char *startup) {
    if (!core.native || initialized) return 1;
    return core_init(&core, type, startup);
}
int vx_xrizer_guest_cleanup(void) {
    if (!core.native || !initialized) return -1;
    core_cleanup(&core); return 0;
}
int vx_xrizer_guest_version(const char *name) {
    if (!core.native || !name) return 106;
    return core_version(&core, name);
}
void *vx_xrizer_guest_interface(const char *name, int *error) {
    if (!core.native || !initialized || !name) { if (error) *error = 106; return NULL; }
    return core_interface(&core, name, error);
}
const char *vx_xrizer_guest_error_description(int error) {
    if (!core.native) return NULL;
    native_error_fn fn = (native_error_fn)native_table(&core)[5];
    return fn(core.native, error);
}
int vx_xrizer_guest_reset(void) {
    if (initialized || !core.native) return -1;
    core.native = NULL; cleaned = 0; return 0;
}
#ifdef __aarch64__
#include "thunks/xrizer_guest_bridge.c.inc"
#endif
