// Owned joined fixture only. Native Rust tables remain behind these static stubs.
#import <Foundation/Foundation.h>
#include "vx.h"
#include "xrizer_guest_host.h"
#include <stdlib.h>
#include <string.h>

typedef struct { float m[4][4]; } matrix44;
typedef struct { float m[3][4]; } matrix34;
typedef struct { void **vtable; void *native; } guest_object;
typedef int (*native_init_fn)(void *, int, const char *);
typedef void (*native_cleanup_fn)(void *);
typedef void *(*native_interface_fn)(void *, const char *, int *);
typedef uint8_t (*native_present_fn)(void *);
typedef void (*native_size_fn)(void *, uint32_t *, uint32_t *);
typedef matrix44 (*native_projection_fn)(void *, int, float, float);
typedef matrix34 (*native_transform_fn)(void *, int);
typedef matrix44 (*native_projection_c_fn)(int, float, float);
typedef matrix34 (*native_transform_c_fn)(int);
typedef int (*native_wait_fn)(void *, void *, uint32_t, void *, uint32_t);
typedef int (*native_one_pose_fn)(void *, uint32_t, void *, void *);
typedef void (*native_handoff_fn)(void *);
static void *core_table[7], *system_table[47], *compositor_table[44], *system_fns[47];
static guest_object core = {core_table, NULL}, system_object = {system_table, NULL}, compositor = {compositor_table, NULL};
static void **native_system_fns;
static vx_xrizer_guest_host *host;
static int initialized, cleaned;

static void require(int ok) { if (!ok) { vx_log("xrizer_guest_join: invalid fixture state/argument"); abort(); } }
static void **native_table(guest_object *self) { require(self && self->native); return *(void ***)self->native; }
static WINAPI void unsupported(void) { vx_log("xrizer_guest_join: unused test-only slot"); abort(); }
static WINAPI int core_init(guest_object *self, int type, const char *startup) {
    require(self == &core && !initialized);
    native_init_fn fn = (native_init_fn)native_table(self)[0];
    int result = fn(self->native, type, startup); initialized = result == 0;
    vx_log("xrizer_guest_join: actual native Init return %d", result); return result;
}
static WINAPI void core_cleanup(guest_object *self) {
    require(self == &core && initialized && !cleaned);
    native_cleanup_fn fn = (native_cleanup_fn)native_table(self)[1]; fn(self->native);
    cleaned = 1; initialized = 0; system_object.native = compositor.native = NULL; native_system_fns = NULL;
}
static WINAPI uint8_t core_present(guest_object *self) {
    require(self == &core); native_present_fn fn = (native_present_fn)native_table(self)[4]; return fn(self->native);
}
static WINAPI void *core_interface(guest_object *self, const char *name, int *error) {
    require(self == &core && initialized && name);
    native_interface_fn fn = (native_interface_fn)native_table(self)[3];
    void *p = fn(self->native, name, error);
    vx_log("xrizer_guest_join: actual native interface %s pointer %p error %d", name, p, error ? *error : -1);
    if (!p) return NULL;
    if (!strcmp(name, "IVRSystem_019")) { system_object.native = p; return &system_object; }
    if (!strcmp(name, "IVRCompositor_022")) { compositor.native = p; return &compositor; }
    if (!strcmp(name, "FnTable:IVRSystem_019")) { native_system_fns = p; return system_fns; }
    require(0); return NULL;
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
static WINAPI uint8_t input_available(guest_object *self) {
    require(self == &system_object); native_present_fn fn = (native_present_fn)native_table(self)[39]; return fn(self->native);
}
static WINAPI void handoff(guest_object *self) {
    require(self == &compositor); native_handoff_fn fn = (native_handoff_fn)native_table(self)[7]; fn(self->native);
}
static WINAPI void *FixtureGetClientCore(int *error) {
    require(!host);
    const char *path = getenv("VXRT_ABI_XRIZER_DYLIB");
    require(path && vx_xrizer_guest_host_create(path, NULL, &host) == 0 && host);
    core.native = vx_xrizer_guest_host_factory(host, "IVRClientCore_003", error);
    return core.native ? &core : NULL;
}
static WINAPI int FixtureVerify(int after_cleanup) {
    vx_xrizer_guest_host_stats s; vx_xrizer_guest_host_get_stats(host, &s);
    vx_log("xrizer_guest_join: native stats waits %u publishes %u cancels %u lifecycle %u/%u/%u sessions %u/%u frame %llu pose %llu predicted %lld outstanding %u source %u/%u/%u",
           s.waits,s.publishes,s.cancels,s.begins,s.exits,s.ends,s.sessions_created,s.sessions_destroyed,
           (unsigned long long)s.frame_id,(unsigned long long)s.pose_id,(long long)s.predicted_display_time,s.outstanding,
           s.source_acquires,s.source_releases,s.source_copies);
    if (after_cleanup == -1) return !(s.waits == 0 && s.publishes == 0 && s.cancels == 0 && s.outstanding == 0);
    return !(s.waits == 1 && s.publishes == 0 && s.cancels == 1 && s.begins == 1 &&
             s.exits == (uint32_t)after_cleanup && s.ends == (uint32_t)after_cleanup && s.sessions_created == 1 &&
             s.sessions_destroyed == (uint32_t)after_cleanup && s.frame_id == 101 && s.pose_id == 201 &&
             s.predicted_display_time > 0 && s.outstanding == 0 && s.source_acquires == 0 && s.source_releases == 0 && s.source_copies == 0);
}
static WINAPI int FixtureFinish(void) { require(cleaned); return vx_xrizer_guest_host_finish(host); }
static const vx_export exports[] = { VX_EXPORT(FixtureGetClientCore), VX_EXPORT(FixtureVerify), VX_EXPORT(FixtureFinish) };
__attribute__((constructor)) static void register_fixture(void) {
    for (int i = 0; i < 7; ++i) core_table[i] = unsupported;
    for (int i = 0; i < 47; ++i) system_table[i] = system_fns[i] = unsupported;
    for (int i = 0; i < 44; ++i) compositor_table[i] = unsupported;
    core_table[0] = core_init; core_table[1] = core_cleanup; core_table[3] = core_interface; core_table[4] = core_present;
    system_table[0] = render_size; system_table[1] = member_projection; system_table[4] = member_transform;
    system_table[39] = input_available;
    compositor_table[2] = wait_poses; compositor_table[3] = last_poses; compositor_table[4] = one_pose; compositor_table[7] = handoff;
    system_fns[1] = fntable_projection; system_fns[4] = fntable_transform;
    vx_register_module("vxrt_guest_join_fixture.dll", exports, sizeof exports / sizeof *exports);
}
#ifdef __aarch64__
#include "thunks/xrizer_guest_join_host.m.inc"
#endif
