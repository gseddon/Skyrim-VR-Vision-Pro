// Static Windows ABI adapters for the supported xrizer interface versions.
#include "vx.h"
#include "xrizer_guest_bridge.h"
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
    cleaned = 1; initialized = 0; system_object.native = compositor.native = NULL; native_system_fns = NULL;
}
static int supported(const char *name) {
    return name && (!strcmp(name, "IVRSystem_019") || !strcmp(name, "IVRCompositor_022") ||
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
    if (calls > 5 && calls % 900) return;
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
    // A native pointer has no established guest-addressability or lifetime.
    if (result.vertices || result.triangles) unsupported_slot("IVRSystem_019 nonempty hidden mesh",33);
    *out=result; return out;
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
