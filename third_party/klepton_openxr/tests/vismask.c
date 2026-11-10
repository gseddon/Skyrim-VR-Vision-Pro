/* XR_KHR_visibility_mask owned fixture: the provider's extension plumbing and the generated meshes.
 * Mock hosts, no GPU, no frame, no headset. */
#include "klepton_native.h"
#include "metal_host.h"
#include "session_host.h"
#include "image_sync_host.h"
#include "frame_host.h"
#include "input_host.h"
#include "view_host.h"
#include "visibility_host.h"
#include "../src/vismask.h"
#define XR_USE_GRAPHICS_API_METAL 1
#include <openxr/openxr_platform.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
static int dev, queue;
static KlNativeVisibilityParams params;
static unsigned geometry_ok = 1;
static XrResult hmd(void *c) { (void)c; return XR_SUCCESS; }
static XrResult graphics(void *c, void **d, void **q) { (void)c; *d = &dev; *q = &queue; return XR_SUCCESS; }
static XrResult formats(void *c, uint32_t cap, uint32_t *n, int64_t *o) { (void)c; *n = 1; if (cap) o[0] = 80; return XR_SUCCESS; }
static XrResult mk(void *c, const KlNativeMetalImageInfo *i, void **o, void **l) { (void)c; (void)i; (void)o; (void)l; return XR_ERROR_OUT_OF_MEMORY; }
static void rel(void *c, void *l) { (void)c; (void)l; }
static XrResult poll(void *c, KlNativeSessionEvent *e) { (void)c; (void)e; return XR_EVENT_UNAVAILABLE; }
static XrResult bg(void *c, XrTime *t) { (void)c; *t = 1; return XR_SUCCESS; }
static XrResult rq(void *c) { (void)c; return XR_SUCCESS; }
static XrResult iw(void *c, void *l, XrDuration t) { (void)c; (void)l; (void)t; return XR_SUCCESS; }
static XrResult ic(void *c, void *l) { (void)c; (void)l; return XR_SUCCESS; }
static XrResult fw(void *c, KlNativeFrameSample *o) { (void)c; (void)o; return XR_ERROR_RUNTIME_FAILURE; }
static XrResult fp(void *c, const KlNativeFramePair *p) { (void)c; (void)p; return XR_ERROR_RUNTIME_FAILURE; }
static XrResult fc(void *c, void *t) { (void)c; (void)t; return XR_SUCCESS; }
static XrResult si_(void *c, KlNativeInputSample *o) { (void)c; (void)o; return XR_ERROR_RUNTIME_FAILURE; }
static XrResult geometry(void *c, KlNativeViewGeometry *o) {
    (void)c; if (!geometry_ok) return XR_ERROR_FORM_FACTOR_UNAVAILABLE;
    /* the headset's eyes: tan l/r/u/d = -1.732 / 1.0 / 1.0 / -1.19 (left), mirrored horizontally (right) */
    *o = (KlNativeViewGeometry){.version = KL_NATIVE_VIEW_GEOMETRY_VERSION, .struct_size = sizeof *o, .geometry_id = 3,
        .head_from_eye = {{{0, 0, 0, 1}, {-.032f, 0, 0}}, {{0, 0, 0, 1}, {.032f, 0, 0}}},
        .fov = {{atanf(-1.732f), atanf(1.0f), atanf(1.0f), atanf(-1.19f)}, {atanf(-1.0f), atanf(1.732f), atanf(1.0f), atanf(-1.19f)}}};
    return XR_SUCCESS;
}
static XrResult get_params(void *c, uint32_t eye, KlNativeVisibilityParams *o) { (void)c; (void)eye; *o = params; return XR_SUCCESS; }
static float tri_area(XrVector2f a, XrVector2f b, XrVector2f c) { return .5f * ((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)); }
/* summed signed area and the smallest signed triangle area of a triangle list */
static void measure(const XrVisibilityMaskKHR *m, const XrVector2f *v, const uint32_t *ix, float *sum, float *min) {
    *sum = 0; *min = 1e9f;
    for (uint32_t i = 0; i < m->indexCountOutput; i += 3) {
        assert(ix[i] < m->vertexCountOutput && ix[i + 1] < m->vertexCountOutput && ix[i + 2] < m->vertexCountOutput);
        float a = tri_area(v[ix[i]], v[ix[i + 1]], v[ix[i + 2]]);
        *sum += a; if (a < *min) *min = a;
    }
}
#define GET(type, var, inst, name) PFN_xrVoidFunction raw_##var = NULL; \
    assert(kl_native_get_instance_proc_addr(inst, name, &raw_##var) == XR_SUCCESS); type var = (type)raw_##var; assert(var)
int main(void) {
    KlNativeHost host = {1, sizeof host, NULL, hmd, NULL};
    KlNativeMetalHost metal = {KL_NATIVE_METAL_HOST_VERSION, sizeof metal, NULL, graphics, formats, mk, rel};
    KlNativeSessionHost sess = {KL_NATIVE_SESSION_HOST_VERSION, sizeof sess, NULL, poll, bg, bg, rq};
    KlNativeImageSyncHost sync = {KL_NATIVE_IMAGE_SYNC_HOST_VERSION, sizeof sync, NULL, iw, ic};
    KlNativeFrameHost frame = {KL_NATIVE_FRAME_HOST_VERSION, sizeof frame, NULL, fw, fp, fc};
    KlNativeInputHost input = {KL_NATIVE_INPUT_HOST_VERSION, sizeof input, NULL, si_};
    KlNativeViewGeometryHost geo = {KL_NATIVE_VIEW_GEOMETRY_VERSION, sizeof geo, NULL, geometry};
    KlNativeVisibilityHost vis = {KL_NATIVE_VISIBILITY_HOST_VERSION, sizeof vis, NULL, get_params};
    assert(kl_native_configure(&host) == XR_SUCCESS && kl_native_configure_metal(&metal) == XR_SUCCESS &&
           kl_native_configure_session(&sess) == XR_SUCCESS && kl_native_configure_image_sync(&sync) == XR_SUCCESS &&
           kl_native_configure_frame(&frame) == XR_SUCCESS && kl_native_configure_input(&input) == XR_SUCCESS &&
           kl_native_configure_view_geometry(&geo) == XR_SUCCESS);
    GET(PFN_xrEnumerateInstanceExtensionProperties, enum_ext, XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties");
    GET(PFN_xrCreateInstance, new_instance, XR_NULL_HANDLE, "xrCreateInstance");
    uint32_t count = 0;
    assert(enum_ext(NULL, 0, &count, NULL) == XR_SUCCESS && count == 1); /* metal only: no visibility host yet */
    XrInstanceCreateInfo ci = {.type = XR_TYPE_INSTANCE_CREATE_INFO};
    ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    const char *names[2] = {XR_KHR_METAL_ENABLE_EXTENSION_NAME, XR_KHR_VISIBILITY_MASK_EXTENSION_NAME};
    ci.enabledExtensionCount = 2; ci.enabledExtensionNames = names;
    XrInstance instance;
    assert(new_instance(&ci, &instance) == XR_ERROR_EXTENSION_NOT_PRESENT); /* not advertised, so refused */
    assert(kl_native_configure_visibility(&vis) == XR_SUCCESS);
    XrExtensionProperties ext[2] = {{.type = XR_TYPE_EXTENSION_PROPERTIES}, {.type = XR_TYPE_EXTENSION_PROPERTIES}};
    assert(enum_ext(NULL, 0, &count, NULL) == XR_SUCCESS && count == 2);
    assert(enum_ext(NULL, 2, &count, ext) == XR_SUCCESS && !strcmp(ext[1].extensionName, "XR_KHR_visibility_mask"));
    /* an instance without the extension has no entry point */
    ci.enabledExtensionCount = 1;
    XrInstance plain; assert(new_instance(&ci, &plain) == XR_SUCCESS);
    PFN_xrVoidFunction none; assert(kl_native_get_instance_proc_addr(plain, "xrGetVisibilityMaskKHR", &none) == XR_ERROR_FUNCTION_UNSUPPORTED);
    GET(PFN_xrDestroyInstance, destroy_plain, plain, "xrDestroyInstance"); assert(destroy_plain(plain) == XR_SUCCESS);
    ci.enabledExtensionCount = 2;
    assert(new_instance(&ci, &instance) == XR_SUCCESS);
    GET(PFN_xrGetVisibilityMaskKHR, get_mask, instance, "xrGetVisibilityMaskKHR");
    GET(PFN_xrGetMetalGraphicsRequirementsKHR, req, instance, "xrGetMetalGraphicsRequirementsKHR");
    GET(PFN_xrCreateSession, new_session, instance, "xrCreateSession");
    XrGraphicsRequirementsMetalKHR r = {.type = XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
    assert(req(instance, 1, &r) == XR_SUCCESS);
    XrGraphicsBindingMetalKHR binding = {.type = XR_TYPE_GRAPHICS_BINDING_METAL_KHR, .commandQueue = &queue};
    XrSessionCreateInfo si = {.type = XR_TYPE_SESSION_CREATE_INFO, .next = &binding, .systemId = 1};
    XrSession session; assert(new_session(instance, &si, &session) == XR_SUCCESS);
    const XrViewConfigurationType stereo = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    /* disabled: success, empty */
    XrVisibilityMaskKHR m = {.type = XR_TYPE_VISIBILITY_MASK_KHR};
    for (int t = 1; t <= 3; ++t)
        assert(get_mask(session, stereo, 0, (XrVisibilityMaskTypeKHR)t, &m) == XR_SUCCESS && !m.vertexCountOutput && !m.indexCountOutput);
    /* validation */
    assert(get_mask(session, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_MONO, 0, XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR, &m) == XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED);
    assert(get_mask(session, stereo, 2, XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR, &m) == XR_ERROR_VALIDATION_FAILURE);
    assert(get_mask(session, stereo, 0, (XrVisibilityMaskTypeKHR)9, &m) == XR_ERROR_VALIDATION_FAILURE);
    assert(get_mask(NULL, stereo, 0, XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR, &m) == XR_ERROR_HANDLE_INVALID);
    /* enabled: asymmetric insets and rounded corners */
    params = (KlNativeVisibilityParams){.enabled = 1, .inset_left = .10f, .inset_right = .05f, .inset_up = .20f, .inset_down = .0f, .radius = .5f};
    for (unsigned eye = 0; eye < 2; ++eye) {
        XrFovf f; { KlNativeViewGeometry g; geometry(NULL, &g); f = g.fov[eye]; }
        float xl = tanf(f.angleLeft), xr = tanf(f.angleRight), yd = tanf(f.angleDown), yu = tanf(f.angleUp), full = (xr - xl) * (yu - yd);
        float hidden = 0, visible = 0, mn;
        XrVisibilityMaskTypeKHR types[3] = {XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR, XR_VISIBILITY_MASK_TYPE_VISIBLE_TRIANGLE_MESH_KHR, XR_VISIBILITY_MASK_TYPE_LINE_LOOP_KHR};
        for (int t = 0; t < 3; ++t) {
            XrVisibilityMaskKHR q = {.type = XR_TYPE_VISIBILITY_MASK_KHR};
            assert(get_mask(session, stereo, eye, types[t], &q) == XR_SUCCESS && q.vertexCountOutput > 0 && q.indexCountOutput > 0);
            XrVector2f v[64]; uint32_t ix[256];
            assert(q.vertexCountOutput <= 64 && q.indexCountOutput <= 256);
            XrVisibilityMaskKHR small = q; small.vertexCapacityInput = q.vertexCountOutput - 1; small.indexCapacityInput = q.indexCountOutput; small.vertices = v; small.indices = ix;
            assert(get_mask(session, stereo, eye, types[t], &small) == XR_ERROR_SIZE_INSUFFICIENT);
            q.vertexCapacityInput = q.vertexCountOutput; q.indexCapacityInput = q.indexCountOutput; q.vertices = v; q.indices = ix;
            assert(get_mask(session, stereo, eye, types[t], &q) == XR_SUCCESS);
            for (uint32_t i = 0; i < q.vertexCountOutput; ++i)
                assert(v[i].x >= xl - 1e-4f && v[i].x <= xr + 1e-4f && v[i].y >= yd - 1e-4f && v[i].y <= yu + 1e-4f);
            if (t == 2) { assert(q.indexCountOutput == q.vertexCountOutput); continue; }
            float sum; measure(&q, v, ix, &sum, &mn);
            assert(mn > -1e-6f && "no clockwise triangle (zero-area ones appear where an inset is 0)");
            if (t == 0) hidden = sum; else visible = sum;
        }
        printf("eye %u: hidden %.4f + visible %.4f = %.4f of full %.4f (hidden %.1f%%)\n", eye, hidden, visible, hidden + visible, full, 100 * hidden / full);
        assert(fabsf(hidden + visible - full) < 1e-3f * full); /* the two meshes tile the eye image exactly */
        assert(hidden > 0.05f * full && visible > 0.5f * full);
    }
    /* sharp corners (radius 0) and a vanished geometry both stay valid */
    params.radius = 0;
    { XrVisibilityMaskKHR q = {.type = XR_TYPE_VISIBILITY_MASK_KHR}; assert(get_mask(session, stereo, 0, XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR, &q) == XR_SUCCESS && q.indexCountOutput == 24); }
    geometry_ok = 0;
    assert(get_mask(session, stereo, 0, XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR, &m) == XR_SUCCESS && !m.indexCountOutput);
    printf("XR_KHR_visibility_mask owned fixture: pass; mock hosts, no GPU, no frame, no headset\n");
    return 0;
}
