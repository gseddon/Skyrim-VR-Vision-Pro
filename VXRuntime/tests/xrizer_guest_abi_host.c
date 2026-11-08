// Test-only native backend: independent ABI goldens, not xrizer/VR behavior.
#include "vx.h"
#include <stdlib.h>
#include <string.h>

typedef struct { float m[4][4]; } matrix44;
typedef struct { float m[3][4]; } matrix34;
typedef struct { void **vtable; uint64_t tag; } fixture_object;
static void *system_table[47], *compositor_table[51], *raw_system_table[47];
static void *system_fns[47], *compositor_fns[51];
static fixture_object system_object = {system_table, 0x5a170019};
static fixture_object compositor_object = {compositor_table, 0x5a170022};
static fixture_object raw_system_object = {raw_system_table, 0x5a170019};
static int initialized;

static void require(int ok) { if (!ok) { vx_log("xrizer_guest_abi: invalid native fixture argument"); abort(); } }
// These ordinary native functions return real aggregates through Darwin's ABI.
// They deliberately have no guest thunk. The explicit wrappers below adapt them.
__attribute__((noinline)) static matrix44 native_projection(const fixture_object *self, int eye, float near_z, float far_z) {
    require(self && self->tag == 0x5a170019 && eye == 1 && near_z == 0.25f && far_z == 7.5f);
    matrix44 out;
    for (int r = 0; r < 4; ++r) for (int c = 0; c < 4; ++c)
        out.m[r][c] = 37 + eye * 100 + r * 11 + c * 3 + near_z * 2 + far_z * 0.5f;
    return out;
}
__attribute__((noinline)) static matrix34 native_transform(const fixture_object *self, int eye) {
    require(self && self->tag == 0x5a170019 && eye == 0);
    matrix34 out;
    for (int r = 0; r < 3; ++r) for (int c = 0; c < 4; ++c) out.m[r][c] = -13 + eye * 41 + r * 7 + c * 2;
    return out;
}
__attribute__((noinline)) static float native_time(const fixture_object *self) {
    require(self && self->tag == 0x5a170022);
    return 13.625f;
}
static WINAPI void unsupported(void) { vx_log("xrizer_guest_abi: unused fixture slot called"); abort(); }
static WINAPI void render_size(fixture_object *self, uint32_t *width, uint32_t *height) {
    require(self == &system_object && width && height); *width = 1920; *height = 1080;
}
// MSVC C++ member return: RCX=self, RDX=hidden buffer, R8=eye,
// XMM3=near, stack slot 4=far. The generator sees those exact explicit slots.
static WINAPI matrix44 *member_projection(fixture_object *self, matrix44 *out, int eye, float near_z, float far_z) {
    require(out != NULL); *out = native_projection(self, eye, near_z, far_z); return out;
}
static WINAPI matrix34 *member_transform(fixture_object *self, matrix34 *out, int eye) {
    require(out != NULL); *out = native_transform(self, eye); return out;
}
static WINAPI uint32_t member_role(fixture_object *self, int role) {
    require(self == &system_object && (role == 1 || role == 2)); return role == 1 ? 17 : 29;
}
static WINAPI float member_time(fixture_object *self) { return native_time(self); }
// C FnTable return has no self: RCX=buffer, RDX=eye, XMM2/3=near/far.
static WINAPI matrix44 *fntable_projection(matrix44 *out, int eye, float near_z, float far_z) {
    require(out != NULL); *out = native_projection(&system_object, eye, near_z, far_z); return out;
}
static WINAPI matrix34 *fntable_transform(matrix34 *out, int eye) {
    require(out != NULL); *out = native_transform(&system_object, eye); return out;
}
static WINAPI float fntable_time(void) { return native_time(&compositor_object); }
static WINAPI uint32_t FixtureInit(int type, const char *startup, int *error) {
    int ok = type == 1 && startup && !strcmp(startup, "owned");
    if (error) *error = ok ? 0 : 77;
    initialized = ok;
    return ok ? 0x11223344 : 0;
}
static WINAPI void *FixtureFactory(const char *name, int *error) {
    void *p = NULL;
    if (initialized && name) {
        if (!strcmp(name, "IVRSystem_019")) p = &system_object;
        else if (!strcmp(name, "IVRCompositor_022")) p = &compositor_object;
        else if (!strcmp(name, "FnTable:IVRSystem_019")) p = system_fns;
        else if (!strcmp(name, "FnTable:IVRCompositor_022")) p = compositor_fns;
        else if (!strcmp(name, "Raw:IVRSystem_019")) p = &raw_system_object;
    }
    if (error) *error = p ? 0 : 105;
    return p;
}
static const vx_export exports[] = { VX_EXPORT(FixtureInit), VX_EXPORT(FixtureFactory) };
__attribute__((constructor)) static void register_fixture(void) {
    for (int i = 0; i < 47; ++i) system_table[i] = raw_system_table[i] = system_fns[i] = unsupported;
    for (int i = 0; i < 51; ++i) compositor_table[i] = compositor_fns[i] = unsupported;
    system_table[0] = render_size; system_table[1] = member_projection;
    system_table[4] = member_transform; system_table[18] = member_role;
    compositor_table[10] = member_time;
    system_fns[1] = fntable_projection; system_fns[4] = fntable_transform; compositor_fns[10] = fntable_time;
    raw_system_table[1] = native_projection;
    vx_register_module("vxrt_guest_abi_fixture.dll", exports, sizeof exports / sizeof *exports);
}
#ifdef __aarch64__
#include "thunks/xrizer_guest_abi_host.c.inc"
#endif
