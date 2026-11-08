#include "klepton_native.h"
#include "view_host.h"
#include <assert.h>
#include <stdio.h>
static int mode;
static XrResult available(void *ctx) { (void)ctx; return XR_SUCCESS; }
static XrResult config(void *ctx, KlNativeViewConfiguration *out) {
    (void)ctx;
    if (mode == 3) return XR_ERROR_RUNTIME_FAILURE;
    out->primary_stereo_supported = mode == 2 ? XR_FALSE : XR_TRUE;
    out->opaque_supported = XR_TRUE; out->fov_mutable = XR_FALSE;
    for (unsigned i = 0; i < 2; ++i) {
        out->view[i].recommendedImageRectWidth = 1000 + i;
        out->view[i].recommendedImageRectHeight = 900 + i;
        out->view[i].maxImageRectWidth = mode == 1 ? 999 : 2000;
        out->view[i].maxImageRectHeight = 1800;
        out->view[i].recommendedSwapchainSampleCount = 1;
        out->view[i].maxSwapchainSampleCount = 1;
    }
    return XR_SUCCESS;
}
#define GET(type, var, instance, name) PFN_xrVoidFunction raw_##var = NULL; \
    assert(kl_native_get_instance_proc_addr(instance,name,&raw_##var) == XR_SUCCESS); type var=(type)raw_##var
int main(void) {
    KlNativeHost system = { 1, sizeof(system), NULL, available, NULL };
    KlNativeViewHost views = { KL_NATIVE_VIEW_HOST_VERSION, sizeof(views), NULL, config };
    assert(kl_native_configure(&system) == XR_SUCCESS);
    assert(kl_native_configure_views(&views) == XR_SUCCESS);
    GET(PFN_xrCreateInstance, create, XR_NULL_HANDLE, "xrCreateInstance");
    XrInstanceCreateInfo ci = { .type = XR_TYPE_INSTANCE_CREATE_INFO };
    ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1,0,0);
    XrInstance inst; assert(create(&ci, &inst) == XR_SUCCESS);
    GET(PFN_xrEnumerateViewConfigurationViews, enumerate, inst, "xrEnumerateViewConfigurationViews");
    GET(PFN_xrEnumerateEnvironmentBlendModes, blends, inst, "xrEnumerateEnvironmentBlendModes");
    GET(PFN_xrGetViewConfigurationProperties, properties, inst, "xrGetViewConfigurationProperties");
    GET(PFN_xrDestroyInstance, destroy, inst, "xrDestroyInstance");
    uint32_t count = 0;
    assert(enumerate(inst, 1, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &count, NULL) == XR_SUCCESS && count == 2);
    XrViewConfigurationView v[2] = { { .type = XR_TYPE_VIEW_CONFIGURATION_VIEW }, { .type = XR_TYPE_VIEW_CONFIGURATION_VIEW } };
    assert(enumerate(inst, 1, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 1, &count, v) == XR_ERROR_SIZE_INSUFFICIENT && count == 2);
    assert(enumerate(inst, 1, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &count, v) == XR_SUCCESS);
    assert(v[0].recommendedImageRectWidth == 1000 && v[1].recommendedImageRectWidth == 1001 && v[0].maxImageRectWidth == 2000);
    XrViewConfigurationProperties p = { .type = XR_TYPE_VIEW_CONFIGURATION_PROPERTIES };
    assert(properties(inst, 1, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, &p) == XR_SUCCESS && p.fovMutable == XR_FALSE);
    XrEnvironmentBlendMode blend;
    assert(blends(inst, 1, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 1, &count, &blend) == XR_SUCCESS && count == 1 && blend == XR_ENVIRONMENT_BLEND_MODE_OPAQUE);
    mode = 1; assert(enumerate(inst, 1, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &count, NULL) == XR_ERROR_RUNTIME_FAILURE);
    mode = 2; assert(enumerate(inst, 1, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &count, NULL) == XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED);
    mode = 3; assert(enumerate(inst, 1, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &count, NULL) == XR_ERROR_RUNTIME_FAILURE);
    assert(destroy(inst) == XR_SUCCESS);
    puts("Host stereo view metadata: pass; injected values, no frame or tracking");
}
