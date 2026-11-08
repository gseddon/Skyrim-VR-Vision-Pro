/* Host call through the guest bridge into a fake native GetProjectionRaw. Not a guest thunk proof. */
#include "xrizer_guest_bridge.h"
#include <stdio.h>
#include <string.h>
typedef struct { void **vtable; } native_object;
static void *core_vt[7], *system_vt[47], *system_fns[47], *compositor_vt[44];
static native_object native_core = {core_vt}, native_system = {system_vt}, native_compositor = {compositor_vt};
static int raw_calls;
static int native_init(void *self, int type, const char *startup) {
    return self == &native_core && type == 1 && startup && !strcmp(startup, "owned") ? 0 : 7;
}
static int native_version(void *self, const char *name) {
    (void)self;
    return name && (!strcmp(name, "IVRSystem_019") || !strcmp(name, "FnTable:IVRSystem_019")) ? 0 : 106;
}
static void *native_interface(void *self, const char *name, int *error) {
    void *p = NULL;
    if (self == &native_core && name) {
        if (!strcmp(name, "IVRSystem_019")) p = &native_system;
        else if (!strcmp(name, "FnTable:IVRSystem_019")) p = system_fns;
        else if (!strcmp(name, "IVRCompositor_022")) p = &native_compositor;
    }
    if (error) *error = p ? 0 : 106;
    return p;
}
static void native_raw(void *self, int eye, float *left, float *right, float *top, float *bottom) {
    if (self != &native_system || eye != 0 || !left || !right || !top || !bottom) return;
    *left = -1.25f; *right = 0.75f; *top = -0.5f; *bottom = 1.5f; raw_calls++;
}
static void native_raw_c(int eye, float *left, float *right, float *top, float *bottom) {
    if (eye != 1 || !left || !right || !top || !bottom) return;
    *left = -0.25f; *right = 1.75f; *top = -1.5f; *bottom = 0.5f; raw_calls++;
}
static int can_calls;
static unsigned char native_can_render(void *self) {
    if (self != &native_compositor) return 0;
    can_calls++;
    return 1;
}
static int close_to(float a, float b) { float d = a - b; return d > -0.00001f && d < 0.00001f; }
void vx_log(const char *format, ...) { (void)format; }
void xa_report(void) {}
int main(void) {
    core_vt[0] = (void *)native_init; core_vt[2] = (void *)native_version; core_vt[3] = (void *)native_interface;
    system_vt[2] = (void *)native_raw; system_fns[2] = (void *)native_raw_c;
    compositor_vt[24] = (void *)native_can_render;
    int error = -1;
    void *core = vx_xrizer_guest_core(&native_core);
    if (!core || vx_xrizer_guest_init(1, "owned") != 0) return 1;
    void *system = vx_xrizer_guest_interface("IVRSystem_019", &error);
    if (!system || error != 0) return 2;
    void **table = *(void ***)system;
    void (*raw)(void *, int, float *, float *, float *, float *) = table[2];
    float left = 0, right = 0, top = 0, bottom = 0;
    raw(system, 0, &left, &right, &top, &bottom);
    if (raw_calls != 1 || !close_to(left, -1.25f) || !close_to(right, 0.75f) || !close_to(top, -0.5f) || !close_to(bottom, 1.5f)) return 3;
    void **fns = vx_xrizer_guest_interface("FnTable:IVRSystem_019", &error);
    if (!fns || error != 0) return 4;
    void (*raw_c)(int, float *, float *, float *, float *) = fns[2];
    raw_c(1, &left, &right, &top, &bottom);
    if (raw_calls != 2 || !close_to(left, -0.25f) || !close_to(right, 1.75f) || !close_to(top, -1.5f) || !close_to(bottom, 0.5f)) return 5;
    void *compositor = vx_xrizer_guest_interface("IVRCompositor_022", &error);
    if (!compositor || error != 0) return 6;
    unsigned char (*can)(void *) = (*(void ***)compositor)[24];
    if (can(compositor) != 1 || can_calls != 1) return 7;
    puts("xrizer_projection_raw: bridge slot 2, FnTable slot 2, compositor CanRenderScene -> ok");
    return 0;
}
