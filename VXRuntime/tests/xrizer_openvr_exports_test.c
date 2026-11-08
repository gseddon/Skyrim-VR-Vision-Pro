/* CPU-only lifecycle test with an owned fake bridge; not a guest ABI proof. */
#include "xrizer_openvr_exports.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
static int init_error, cleanup_count, resets, last_type, retired;
static const char *last_startup;
static int native_core, guest_object;
void vx_log(const char *format, ...) { (void)format; }
void *vx_xrizer_guest_core(void *core) { assert(core == &native_core); return retired ? NULL : &guest_object; }
int vx_xrizer_guest_init(int type, const char *startup) { last_type = type; last_startup = startup; return init_error; }
int vx_xrizer_guest_cleanup(void) { ++cleanup_count; return 0; }
int vx_xrizer_guest_reset(void) { ++resets; retired = 1; return 0; }
int vx_xrizer_guest_version(const char *name) { return strcmp(name, "IVRSystem_019") ? 106 : 0; }
void *vx_xrizer_guest_interface(const char *name, int *error) {
    int e = vx_xrizer_guest_version(name); if (error) *error = e; return e ? NULL : &guest_object;
}
const char *vx_xrizer_guest_error_description(int error) { return !retired && error == 124 ? "owned internal error" : NULL; }
static void *make_core(void *context, int *error) { assert(context == &native_core); *error = 0; return context; }
static void *lookup(const vx_export *table, size_t n, const char *name) {
    for (size_t i = 0; i < n; ++i) if (!strcmp(table[i].name, name)) return table[i].fn;
    assert(!"missing export"); return NULL;
}
int main(int argc, char **argv) {
    size_t n; const vx_export *t = vx_xrizer_openvr_exports(&n);
    uint32_t (WINAPI *init)(int *,int,const char *) = lookup(t,n,"VR_InitInternal2");
    uint32_t (WINAPI *token)(void) = lookup(t,n,"VR_GetInitToken");
    uint8_t (WINAPI *version)(const char *) = lookup(t,n,"VR_IsInterfaceVersionValid");
    void *(WINAPI *interface)(const char *,int *) = lookup(t,n,"VR_GetGenericInterface");
    void (WINAPI *shutdown)(void) = lookup(t,n,"VR_ShutdownInternal");
    const char *(WINAPI *description)(int) = lookup(t,n,"VR_GetVRInitErrorAsEnglishDescription");
    int err = -1;
    if (argc == 2 && !strcmp(argv[1], "init-failure")) {
        assert(vx_xrizer_openvr_configure(make_core,&native_core) == 0);
        init_error = 124;
        assert(init(&err,1,NULL) == 0 && err == 124 && resets == 1 && token() == 0);
        assert(!strcmp(description(124),"owned internal error"));
        assert(init(&err,1,NULL) == 0 && err == 124 && resets == 1);
        puts("xrizer_openvr_exports_test: init-failure ok"); return 0;
    }
    assert(!interface("IVRSystem_019", &err) && err == 109 && !version("IVRSystem_019"));
    assert(init(&err,1,NULL) == 0 && err == 100 && token() == 0);
    assert(vx_xrizer_openvr_configure(make_core,&native_core) == 0);
    assert(init(&err,1,"owned") == 1 && err == 0 && token() == 1);
    assert(last_type == 1 && !strcmp(last_startup,"owned"));
    const char *saved = description(124);
    assert(!strcmp(saved,"owned internal error"));
    assert(version("IVRSystem_019") && !version("unsupported"));
    assert(interface("IVRSystem_019", &err) == &guest_object && err == 0);
    assert(!interface("unsupported", &err) && err == 106);
    assert(init(&err,1,NULL) == 0 && err == 143 && token() == 1);
    shutdown(); assert(cleanup_count == 1 && resets == 1 && token() == 2);
    assert(!interface("IVRSystem_019", &err) && err == 109);
    assert(!strcmp(saved,"owned internal error"));
    assert(init(&err,1,NULL) == 0 && err == 124 && token() == 2);
    shutdown(); assert(cleanup_count == 1 && token() == 3);
    puts("xrizer_openvr_exports_test: ok"); return 0;
}
