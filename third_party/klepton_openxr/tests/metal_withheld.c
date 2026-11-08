#include "metal_host.h"
#include "klepton_native.h"
#include <assert.h>
#include <stdio.h>
static int device, queue;
static XrResult graphics(void *ctx, void **d, void **q) { (void)ctx; *d = &device; *q = &queue; return XR_SUCCESS; }
static XrResult formats(void *ctx, uint32_t cap, uint32_t *count, int64_t *out) { (void)ctx; (void)cap; (void)out; *count = 0; return XR_SUCCESS; }
static XrResult image(void *ctx, const KlNativeMetalImageInfo *i, void **tex, void **lease) { (void)ctx; (void)i; (void)tex; (void)lease; return XR_ERROR_FEATURE_UNSUPPORTED; }
static void release(void *ctx, void *lease) { (void)ctx; (void)lease; }
int main(void) {
    KlNativeMetalHost host = { KL_NATIVE_METAL_HOST_VERSION, sizeof(host), NULL, graphics, formats, image, release };
    assert(kl_native_configure_metal(&host) == XR_SUCCESS);
    PFN_xrVoidFunction raw = NULL;
    assert(kl_native_get_instance_proc_addr(XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties", &raw) == XR_SUCCESS);
    PFN_xrEnumerateInstanceExtensionProperties get_extensions = (PFN_xrEnumerateInstanceExtensionProperties)raw;
    uint32_t count = 99;
    assert(get_extensions(NULL, 0, &count, NULL) == XR_SUCCESS && count == 0);
    puts("Metal extension withheld from ordinary build: pass");
}
