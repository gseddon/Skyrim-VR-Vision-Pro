#include "klepton_native.h"
#include "view_host.h"
#include <assert.h>
#include <stdio.h>
static int mode;
static int geometry_mode;
static XrResult geometry(void *ctx, KlNativeViewGeometry *out) {
    (void)ctx;
    if (geometry_mode==2) return XR_ERROR_RUNTIME_FAILURE;
    *out=(KlNativeViewGeometry){.version=KL_NATIVE_VIEW_GEOMETRY_VERSION,.struct_size=sizeof(*out),.geometry_id=7,
        .head_from_eye={{{0,0,0,1},{-.032f,0,0}},{{0,0,0,1},{.032f,0,0}}},
        .fov={{-.7f,.8f,.9f,-.6f},{-.73f,.82f,.9f,-.6f}}};
    if (geometry_mode==1) out->head_from_eye[0].orientation.w=0;
    if (geometry_mode==3) out->fov[0].angleRight=out->fov[0].angleLeft;
    return XR_SUCCESS;
}
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
    KlNativeViewGeometryHost geometry_host={KL_NATIVE_VIEW_GEOMETRY_VERSION,sizeof(geometry_host),NULL,geometry};
    assert(kl_native_configure_view_geometry(&geometry_host)==XR_SUCCESS);
    GET(PFN_xrCreateInstance, create, XR_NULL_HANDLE, "xrCreateInstance");
    XrInstanceCreateInfo ci = { .type = XR_TYPE_INSTANCE_CREATE_INFO };
    ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1,0,0);
    XrInstance inst; assert(create(&ci, &inst) == XR_SUCCESS);
    GET(PFN_xrEnumerateViewConfigurationViews, enumerate, inst, "xrEnumerateViewConfigurationViews");
    GET(PFN_xrEnumerateEnvironmentBlendModes, blends, inst, "xrEnumerateEnvironmentBlendModes");
    GET(PFN_xrGetViewConfigurationProperties, properties, inst, "xrGetViewConfigurationProperties");
    GET(PFN_xrDestroyInstance, destroy, inst, "xrDestroyInstance");
    GET(PFN_xrGetVxStaticViewGeometry, get_geometry, inst, "xrGetVxStaticViewGeometry");
    KlNativeViewGeometry actual={.version=KL_NATIVE_VIEW_GEOMETRY_VERSION,.struct_size=sizeof(actual)};
    assert(get_geometry(inst,1,&actual)==XR_SUCCESS && actual.geometry_id==7 && actual.head_from_eye[0].position.x==-.032f && actual.head_from_eye[1].position.x==.032f);
    assert(get_geometry(inst,1,NULL)==XR_ERROR_VALIDATION_FAILURE);
    geometry_mode=1; assert(get_geometry(inst,1,&actual)==XR_ERROR_VALIDATION_FAILURE);
    geometry_mode=2; assert(get_geometry(inst,1,&actual)==XR_ERROR_RUNTIME_FAILURE);
    geometry_mode=3; assert(get_geometry(inst,1,&actual)==XR_ERROR_VALIDATION_FAILURE);
    geometry_mode=0;
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
    assert(kl_native_configure_view_geometry(NULL)==XR_SUCCESS);
    assert(create(&ci,&inst)==XR_SUCCESS);
    GET(PFN_xrGetVxStaticViewGeometry, no_geometry, inst, "xrGetVxStaticViewGeometry");
    actual.version=KL_NATIVE_VIEW_GEOMETRY_VERSION; actual.struct_size=sizeof(actual);
    assert(no_geometry(inst,1,&actual)==XR_ERROR_FUNCTION_UNSUPPORTED);
    assert(destroy(inst)==XR_SUCCESS);
    puts("Host stereo view metadata: pass; injected values, no frame or tracking");
}
