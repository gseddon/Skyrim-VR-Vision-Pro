// Static Windows ABI adapters for the supported xrizer interface versions.
#include "vx.h"
#include "xrizer_guest_bridge.h"
#include <stdlib.h>
#include <string.h>
typedef struct { float m[4][4]; } matrix44;
typedef struct { float m[3][4]; } matrix34;
typedef struct { void **vtable; void *native; } guest_object;
typedef int (*native_init_fn)(void *, int, const char *);
typedef void (*native_cleanup_fn)(void *);
typedef void *(*native_interface_fn)(void *, const char *, int *);
typedef uint8_t (*native_present_fn)(void *);
typedef const char *(*native_error_fn)(void *, int);
typedef int (*native_version_fn)(void *, const char *);
typedef uint32_t (*native_role_fn)(void *, int);
typedef void (*native_size_fn)(void *, uint32_t *, uint32_t *);
typedef matrix44 (*native_projection_fn)(void *, int, float, float);
typedef matrix34 (*native_transform_fn)(void *, int);
typedef matrix44 (*native_projection_c_fn)(int, float, float);
typedef matrix34 (*native_transform_c_fn)(int);
typedef int (*native_wait_fn)(void *, void *, uint32_t, void *, uint32_t);
typedef int (*native_one_pose_fn)(void *, uint32_t, void *, void *);
typedef void (*native_handoff_fn)(void *);
typedef int (*native_submit_fn)(void *, int, const void *, const void *, int);
static void *core_table[7], *system_table[47], *compositor_table[44], *system_fns[47];
static guest_object core = {core_table, NULL}, system_object = {system_table, NULL}, compositor = {compositor_table, NULL};
static void **native_system_fns;
static int initialized, cleaned, consumed;

static void require(int ok) { if (!ok) { vx_log("xrizer_guest_bridge: invalid fixture state/argument"); abort(); } }
static void **native_table(guest_object *self) { require(self && self->native); return *(void ***)self->native; }
static WINAPI void unsupported_core_0(void) { vx_log("xrizer_guest_bridge: unsupported IVRClientCore_003 slot 0"); abort(); }
static WINAPI void unsupported_core_1(void) { vx_log("xrizer_guest_bridge: unsupported IVRClientCore_003 slot 1"); abort(); }
static WINAPI void unsupported_core_2(void) { vx_log("xrizer_guest_bridge: unsupported IVRClientCore_003 slot 2"); abort(); }
static WINAPI void unsupported_core_3(void) { vx_log("xrizer_guest_bridge: unsupported IVRClientCore_003 slot 3"); abort(); }
static WINAPI void unsupported_core_4(void) { vx_log("xrizer_guest_bridge: unsupported IVRClientCore_003 slot 4"); abort(); }
static WINAPI void unsupported_core_5(void) { vx_log("xrizer_guest_bridge: unsupported IVRClientCore_003 slot 5"); abort(); }
static WINAPI void unsupported_core_6(void) { vx_log("xrizer_guest_bridge: unsupported IVRClientCore_003 slot 6"); abort(); }
static WINAPI void unsupported_system_0(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 0"); abort(); }
static WINAPI void unsupported_system_1(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 1"); abort(); }
static WINAPI void unsupported_system_2(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 2"); abort(); }
static WINAPI void unsupported_system_3(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 3"); abort(); }
static WINAPI void unsupported_system_4(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 4"); abort(); }
static WINAPI void unsupported_system_5(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 5"); abort(); }
static WINAPI void unsupported_system_6(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 6"); abort(); }
static WINAPI void unsupported_system_7(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 7"); abort(); }
static WINAPI void unsupported_system_8(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 8"); abort(); }
static WINAPI void unsupported_system_9(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 9"); abort(); }
static WINAPI void unsupported_system_10(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 10"); abort(); }
static WINAPI void unsupported_system_11(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 11"); abort(); }
static WINAPI void unsupported_system_12(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 12"); abort(); }
static WINAPI void unsupported_system_13(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 13"); abort(); }
static WINAPI void unsupported_system_14(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 14"); abort(); }
static WINAPI void unsupported_system_15(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 15"); abort(); }
static WINAPI void unsupported_system_16(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 16"); abort(); }
static WINAPI void unsupported_system_17(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 17"); abort(); }
static WINAPI void unsupported_system_18(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 18"); abort(); }
static WINAPI void unsupported_system_19(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 19"); abort(); }
static WINAPI void unsupported_system_20(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 20"); abort(); }
static WINAPI void unsupported_system_21(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 21"); abort(); }
static WINAPI void unsupported_system_22(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 22"); abort(); }
static WINAPI void unsupported_system_23(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 23"); abort(); }
static WINAPI void unsupported_system_24(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 24"); abort(); }
static WINAPI void unsupported_system_25(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 25"); abort(); }
static WINAPI void unsupported_system_26(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 26"); abort(); }
static WINAPI void unsupported_system_27(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 27"); abort(); }
static WINAPI void unsupported_system_28(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 28"); abort(); }
static WINAPI void unsupported_system_29(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 29"); abort(); }
static WINAPI void unsupported_system_30(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 30"); abort(); }
static WINAPI void unsupported_system_31(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 31"); abort(); }
static WINAPI void unsupported_system_32(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 32"); abort(); }
static WINAPI void unsupported_system_33(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 33"); abort(); }
static WINAPI void unsupported_system_34(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 34"); abort(); }
static WINAPI void unsupported_system_35(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 35"); abort(); }
static WINAPI void unsupported_system_36(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 36"); abort(); }
static WINAPI void unsupported_system_37(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 37"); abort(); }
static WINAPI void unsupported_system_38(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 38"); abort(); }
static WINAPI void unsupported_system_39(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 39"); abort(); }
static WINAPI void unsupported_system_40(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 40"); abort(); }
static WINAPI void unsupported_system_41(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 41"); abort(); }
static WINAPI void unsupported_system_42(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 42"); abort(); }
static WINAPI void unsupported_system_43(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 43"); abort(); }
static WINAPI void unsupported_system_44(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 44"); abort(); }
static WINAPI void unsupported_system_45(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 45"); abort(); }
static WINAPI void unsupported_system_46(void) { vx_log("xrizer_guest_bridge: unsupported IVRSystem_019 slot 46"); abort(); }
static WINAPI void unsupported_compositor_0(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 0"); abort(); }
static WINAPI void unsupported_compositor_1(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 1"); abort(); }
static WINAPI void unsupported_compositor_2(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 2"); abort(); }
static WINAPI void unsupported_compositor_3(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 3"); abort(); }
static WINAPI void unsupported_compositor_4(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 4"); abort(); }
static WINAPI void unsupported_compositor_5(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 5"); abort(); }
static WINAPI void unsupported_compositor_6(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 6"); abort(); }
static WINAPI void unsupported_compositor_7(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 7"); abort(); }
static WINAPI void unsupported_compositor_8(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 8"); abort(); }
static WINAPI void unsupported_compositor_9(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 9"); abort(); }
static WINAPI void unsupported_compositor_10(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 10"); abort(); }
static WINAPI void unsupported_compositor_11(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 11"); abort(); }
static WINAPI void unsupported_compositor_12(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 12"); abort(); }
static WINAPI void unsupported_compositor_13(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 13"); abort(); }
static WINAPI void unsupported_compositor_14(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 14"); abort(); }
static WINAPI void unsupported_compositor_15(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 15"); abort(); }
static WINAPI void unsupported_compositor_16(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 16"); abort(); }
static WINAPI void unsupported_compositor_17(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 17"); abort(); }
static WINAPI void unsupported_compositor_18(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 18"); abort(); }
static WINAPI void unsupported_compositor_19(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 19"); abort(); }
static WINAPI void unsupported_compositor_20(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 20"); abort(); }
static WINAPI void unsupported_compositor_21(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 21"); abort(); }
static WINAPI void unsupported_compositor_22(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 22"); abort(); }
static WINAPI void unsupported_compositor_23(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 23"); abort(); }
static WINAPI void unsupported_compositor_24(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 24"); abort(); }
static WINAPI void unsupported_compositor_25(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 25"); abort(); }
static WINAPI void unsupported_compositor_26(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 26"); abort(); }
static WINAPI void unsupported_compositor_27(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 27"); abort(); }
static WINAPI void unsupported_compositor_28(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 28"); abort(); }
static WINAPI void unsupported_compositor_29(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 29"); abort(); }
static WINAPI void unsupported_compositor_30(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 30"); abort(); }
static WINAPI void unsupported_compositor_31(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 31"); abort(); }
static WINAPI void unsupported_compositor_32(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 32"); abort(); }
static WINAPI void unsupported_compositor_33(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 33"); abort(); }
static WINAPI void unsupported_compositor_34(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 34"); abort(); }
static WINAPI void unsupported_compositor_35(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 35"); abort(); }
static WINAPI void unsupported_compositor_36(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 36"); abort(); }
static WINAPI void unsupported_compositor_37(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 37"); abort(); }
static WINAPI void unsupported_compositor_38(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 38"); abort(); }
static WINAPI void unsupported_compositor_39(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 39"); abort(); }
static WINAPI void unsupported_compositor_40(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 40"); abort(); }
static WINAPI void unsupported_compositor_41(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 41"); abort(); }
static WINAPI void unsupported_compositor_42(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 42"); abort(); }
static WINAPI void unsupported_compositor_43(void) { vx_log("xrizer_guest_bridge: unsupported IVRCompositor_022 slot 43"); abort(); }
static WINAPI void unsupported_fns_0(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 0"); abort(); }
static WINAPI void unsupported_fns_1(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 1"); abort(); }
static WINAPI void unsupported_fns_2(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 2"); abort(); }
static WINAPI void unsupported_fns_3(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 3"); abort(); }
static WINAPI void unsupported_fns_4(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 4"); abort(); }
static WINAPI void unsupported_fns_5(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 5"); abort(); }
static WINAPI void unsupported_fns_6(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 6"); abort(); }
static WINAPI void unsupported_fns_7(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 7"); abort(); }
static WINAPI void unsupported_fns_8(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 8"); abort(); }
static WINAPI void unsupported_fns_9(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 9"); abort(); }
static WINAPI void unsupported_fns_10(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 10"); abort(); }
static WINAPI void unsupported_fns_11(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 11"); abort(); }
static WINAPI void unsupported_fns_12(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 12"); abort(); }
static WINAPI void unsupported_fns_13(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 13"); abort(); }
static WINAPI void unsupported_fns_14(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 14"); abort(); }
static WINAPI void unsupported_fns_15(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 15"); abort(); }
static WINAPI void unsupported_fns_16(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 16"); abort(); }
static WINAPI void unsupported_fns_17(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 17"); abort(); }
static WINAPI void unsupported_fns_18(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 18"); abort(); }
static WINAPI void unsupported_fns_19(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 19"); abort(); }
static WINAPI void unsupported_fns_20(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 20"); abort(); }
static WINAPI void unsupported_fns_21(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 21"); abort(); }
static WINAPI void unsupported_fns_22(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 22"); abort(); }
static WINAPI void unsupported_fns_23(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 23"); abort(); }
static WINAPI void unsupported_fns_24(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 24"); abort(); }
static WINAPI void unsupported_fns_25(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 25"); abort(); }
static WINAPI void unsupported_fns_26(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 26"); abort(); }
static WINAPI void unsupported_fns_27(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 27"); abort(); }
static WINAPI void unsupported_fns_28(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 28"); abort(); }
static WINAPI void unsupported_fns_29(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 29"); abort(); }
static WINAPI void unsupported_fns_30(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 30"); abort(); }
static WINAPI void unsupported_fns_31(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 31"); abort(); }
static WINAPI void unsupported_fns_32(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 32"); abort(); }
static WINAPI void unsupported_fns_33(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 33"); abort(); }
static WINAPI void unsupported_fns_34(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 34"); abort(); }
static WINAPI void unsupported_fns_35(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 35"); abort(); }
static WINAPI void unsupported_fns_36(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 36"); abort(); }
static WINAPI void unsupported_fns_37(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 37"); abort(); }
static WINAPI void unsupported_fns_38(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 38"); abort(); }
static WINAPI void unsupported_fns_39(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 39"); abort(); }
static WINAPI void unsupported_fns_40(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 40"); abort(); }
static WINAPI void unsupported_fns_41(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 41"); abort(); }
static WINAPI void unsupported_fns_42(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 42"); abort(); }
static WINAPI void unsupported_fns_43(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 43"); abort(); }
static WINAPI void unsupported_fns_44(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 44"); abort(); }
static WINAPI void unsupported_fns_45(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 45"); abort(); }
static WINAPI void unsupported_fns_46(void) { vx_log("xrizer_guest_bridge: unsupported FnTable:IVRSystem_019 slot 46"); abort(); }
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
static WINAPI matrix34 *member_transform(guest_object *self, matrix34 *out, int eye) {
    require(self == &system_object && out); native_transform_fn fn = (native_transform_fn)native_table(self)[4];
    *out = fn(self->native, eye); return out;
}
static WINAPI matrix44 *fntable_projection(matrix44 *out, int eye, float near_z, float far_z) {
    require(native_system_fns && out); native_projection_c_fn fn = (native_projection_c_fn)native_system_fns[1];
    *out = fn(eye, near_z, far_z); return out;
}
static WINAPI matrix34 *fntable_transform(matrix34 *out, int eye) {
    require(native_system_fns && out); native_transform_c_fn fn = (native_transform_c_fn)native_system_fns[4];
    *out = fn(eye); return out;
}
static WINAPI int wait_poses(guest_object *self, void *render, uint32_t render_count, void *game, uint32_t game_count) {
    require(self == &compositor); native_wait_fn fn = (native_wait_fn)native_table(self)[2];
    return fn(self->native, render, render_count, game, game_count);
}
static WINAPI int last_poses(guest_object *self, void *render, uint32_t render_count, void *game, uint32_t game_count) {
    require(self == &compositor); native_wait_fn fn = (native_wait_fn)native_table(self)[3];
    return fn(self->native, render, render_count, game, game_count);
}
static WINAPI int one_pose(guest_object *self, uint32_t index, void *render, void *game) {
    require(self == &compositor); native_one_pose_fn fn = (native_one_pose_fn)native_table(self)[4];
    return fn(self->native, index, render, game);
}
static WINAPI uint32_t controller_index(guest_object *self, int role) {
    require(self == &system_object); native_role_fn fn = (native_role_fn)native_table(self)[18]; return fn(self->native, role);
}
static WINAPI uint8_t input_available(guest_object *self) {
    require(self == &system_object); native_present_fn fn = (native_present_fn)native_table(self)[39]; return fn(self->native);
}
static WINAPI int submit(guest_object *self, int eye, const void *texture, const void *bounds, int flags) {
    require(self == &compositor); native_submit_fn fn = (native_submit_fn)native_table(self)[5];
    return fn(self->native, eye, texture, bounds, flags);
}
static WINAPI void handoff(guest_object *self) {
    require(self == &compositor); native_handoff_fn fn = (native_handoff_fn)native_table(self)[7]; fn(self->native);
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
    system_table[0] = render_size; system_table[1] = member_projection; system_table[4] = member_transform;
    system_table[18] = controller_index; system_table[39] = input_available;
    compositor_table[2] = wait_poses; compositor_table[3] = last_poses; compositor_table[4] = one_pose; compositor_table[5] = submit; compositor_table[7] = handoff;
    system_fns[1] = fntable_projection; system_fns[4] = fntable_transform;
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
