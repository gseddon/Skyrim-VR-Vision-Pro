/* Link-only probe. This executable is not launched and configures no host. */
#include "xrizer_xros_host.h"
#include <stddef.h>
extern int32_t xrizer_configure_openxr_provider(PFN_xrGetInstanceProcAddr);
extern int32_t xrizer_configure_metal_host(const XrizerMetalHost *);
extern void *VRClientCoreFactory(const char *, int *);
static int install(vx_xros_xrizer_factory factory, void *context) {
    (void)factory; (void)context; return -1;
}
/* Volatile table forces native direct references through the actual static ABI. */
static const vx_xros_xrizer_static_api api = {
    VX_XROS_XRIZER_API_VERSION, sizeof(api), xrizer_configure_openxr_provider,
    xrizer_configure_metal_host, VRClientCoreFactory, install
};
/* the host reports the game's submit time to the per-frame timing record (native_vr_present.m); this probe links the host alone */
void vx_xros_timing_submit(uint64_t id) { (void)id; }
/* the host logs through the runtime's vx_log (VXRT_UPSCALE lines); the probe has no runtime */
void vx_log(const char *fmt, ...) { (void)fmt; }
int main(void) {
    const vx_xros_xrizer_static_api *volatile pinned = &api;
    return vx_xros_xrizer_register(NULL, pinned, NULL);
}
