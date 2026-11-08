/* OpenVR DLL exports backed by the real xrizer ClientCore, through the static
 * Windows ABI bridge. A host must configure the provider and core factory. */
#include "xrizer_openvr_exports.h"
#include "xrizer_guest_bridge.h"
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static vx_xrizer_core_factory factory;
static void *factory_context;
static uint32_t generation;
static int initialized, retired;
static unsigned version_notes, interface_notes;
typedef struct description_copy { int error; char *text; struct description_copy *next; } description_copy;
static description_copy *descriptions;

enum { INIT_INSTALLATION_NOT_FOUND = 100, INIT_NOT_INITIALIZED = 109,
       INIT_INTERNAL = 124, INIT_ALREADY_RUNNING = 143 };

/* The caller holds lock. Descriptions returned to the guest remain valid for
 * the process lifetime, including after the native core has been cleaned up. */
static const char *description_locked(int error) {
    static const char unavailable[] = "OpenVR initialization error (description unavailable)";
    for (description_copy *p = descriptions; p; p = p->next)
        if (p->error == error) return p->text;
    const char *description = vx_xrizer_guest_error_description(error);
    if (!description) return unavailable;
    size_t n = strlen(description) + 1;
    description_copy *p = malloc(sizeof *p);
    char *text = malloc(n);
    if (!p || !text) { free(p); free(text); return unavailable; }
    memcpy(text, description, n);
    *p = (description_copy){ error, text, descriptions };
    descriptions = p;
    return text;
}

int vx_xrizer_openvr_enabled(void) {
    const char *v = getenv("VXRT_XRIZER_OPENVR");
    return v && !strcmp(v, "1");
}
int vx_xrizer_openvr_configure(vx_xrizer_core_factory f, void *context) {
    pthread_mutex_lock(&lock);
    int ok = f && !factory && !initialized;
    if (ok) { factory = f; factory_context = context; }
    pthread_mutex_unlock(&lock);
    return ok ? 0 : -1;
}
static WINAPI uint32_t xr_init2(int *error, int type, const char *startup) {
    pthread_mutex_lock(&lock);
    int err = INIT_INSTALLATION_NOT_FOUND;
    uint32_t result = 0;
    if (initialized) err = INIT_ALREADY_RUNNING;
    else if (retired) err = INIT_INTERNAL; /* Bridge permits one generation per process. */
    else if (factory) {
        void *native = factory(factory_context, &err);
        if (native) {
            if (!vx_xrizer_guest_core(native)) err = INIT_INTERNAL;
            else {
                err = vx_xrizer_guest_init(type, startup);
                if (!err) { initialized = 1; result = ++generation; }
                else { (void)description_locked(err); (void)vx_xrizer_guest_reset(); retired = 1; }
            }
        } else if (!err) err = INIT_INTERNAL;
    }
    if (error) *error = err;
    vx_log("xrizer OpenVR: InitInternal2 type %d startup %s token %u error %d", type, startup ? "present" : "null", result, err);
    pthread_mutex_unlock(&lock);
    return result;
}
static WINAPI uint32_t xr_init(int *error, int type) { return xr_init2(error, type, NULL); }
static WINAPI uint32_t xr_token(void) {
    pthread_mutex_lock(&lock); uint32_t result = generation; pthread_mutex_unlock(&lock); return result;
}
static WINAPI uint8_t xr_version(const char *name) {
    pthread_mutex_lock(&lock);
    uint8_t result = initialized && name && vx_xrizer_guest_version(name) == 0;
    if (version_notes++ < 64) vx_log("xrizer OpenVR: IsInterfaceVersionValid %.96s = %u", name ? name : "(null)", result);
    pthread_mutex_unlock(&lock); return result;
}
static WINAPI void *xr_interface(const char *name, int *error) {
    pthread_mutex_lock(&lock);
    void *result = NULL;
    if (!initialized) { if (error) *error = INIT_NOT_INITIALIZED; }
    else result = vx_xrizer_guest_interface(name, error);
    if (interface_notes++ < 64) vx_log("xrizer OpenVR: GetGenericInterface %.96s = %p error %d", name ? name : "(null)", result, error ? *error : -1);
    pthread_mutex_unlock(&lock); return result;
}
static WINAPI void xr_shutdown(void) {
    pthread_mutex_lock(&lock);
    if (initialized && vx_xrizer_guest_cleanup() == 0) {
        initialized = 0;
        (void)vx_xrizer_guest_reset();
        retired = 1;
    }
    ++generation;
    vx_log("xrizer OpenVR: ShutdownInternal generation %u", generation);
    pthread_mutex_unlock(&lock);
}
/* Native descriptions are borrowed from xrizer; copy to process-owned storage
 * before returning a guest pointer. This generic text is used only when core
 * acquisition failed and no native description exists. */
static WINAPI const char *xr_description(int error) {
    pthread_mutex_lock(&lock);
    const char *result = description_locked(error);
    pthread_mutex_unlock(&lock); return result;
}
static const vx_export exports[] = {
    {"VR_InitInternal", xr_init}, {"VR_InitInternal2", xr_init2},
    {"VR_GetInitToken", xr_token}, {"VR_IsInterfaceVersionValid", xr_version},
    {"VR_GetGenericInterface", xr_interface}, {"VR_ShutdownInternal", xr_shutdown},
    {"VR_GetVRInitErrorAsEnglishDescription", xr_description},
};
const vx_export *vx_xrizer_openvr_exports(size_t *count) {
    if (count) *count = sizeof exports / sizeof *exports;
    return exports;
}
#ifdef __aarch64__
#include "thunks/xrizer_openvr_exports.c.inc"
#endif
