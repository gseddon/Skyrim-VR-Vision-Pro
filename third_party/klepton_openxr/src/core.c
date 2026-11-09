/* Adapted from Klepton runtime/xr/kl_openxr.c, MIT, Copyright (c) 2026 Max Thomas.
 * Exact upstream revision and deviations: ../SOURCE.md. No guest loader. */
#include "klepton_native.h"
#include "metal_host.h"
#include "session_host.h"
#include "image_sync_host.h"
#include "frame_host.h"
#include "view_host.h"
#include "input_host.h"
#include "pose_math.h"
#define XR_USE_GRAPHICS_API_METAL 1
#include <openxr/openxr_platform.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

/* The initial host boundary is serialized. Never reuse a slot in this process:
 * a stale XrInstance must not become valid after destroy/recreate. */
#define INSTANCE_LIMIT 64
struct XrInstance_T { unsigned used, live, metal_enabled, metal_queried; };
static struct XrInstance_T instances[INSTANCE_LIMIT];
static KlNativeHost native_host;
static int configured;
static KlNativeMetalHost metal_host;
static int metal_configured;
static KlNativeSessionHost session_host;
static int session_configured;
static KlNativeImageSyncHost image_sync_host;
static int image_sync_configured;
static KlNativeFrameHost frame_host;
static int frame_configured;
static KlNativeViewHost view_host;
static int view_configured;
static KlNativeViewGeometryHost view_geometry_host;
static int view_geometry_configured;
static KlNativeInputHost input_host;
static KlNativeInputHost2 input_host2;
static KlNativeInputHost3 input_host3;
static int input_configured; /* 0, 1, 2 or 3 */
static int metal_extension_available(void) {
#ifdef KL_NATIVE_TEST_METAL_PARTIAL
    return metal_configured;
#else
    return 0; /* No frame/completion lifecycle yet. */
#endif
}
#define PATH_LIMIT 512
struct native_path { XrInstance owner; XrPath id; char name[XR_MAX_PATH_LENGTH]; };
static struct native_path paths[PATH_LIMIT];
static XrPath next_path = 1;
#define ACTION_SET_LIMIT 128
struct XrActionSet_T {
    unsigned used, live;
    XrInstance owner;
    uint32_t priority;
    char name[XR_MAX_ACTION_SET_NAME_SIZE];
    char localized[XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE];
};
static struct XrActionSet_T action_sets[ACTION_SET_LIMIT];
#define ACTION_LIMIT 256
#define ACTION_SUBPATH_LIMIT 16
struct XrAction_T {
    unsigned used, live;
    XrActionSet owner;
    XrActionType type;
    uint32_t subpath_count;
    XrPath subpaths[ACTION_SUBPATH_LIMIT];
    char name[XR_MAX_ACTION_NAME_SIZE];
    char localized[XR_MAX_LOCALIZED_ACTION_NAME_SIZE];
};
static struct XrAction_T actions[ACTION_LIMIT];
#define BINDING_LIMIT 2048
struct native_binding { XrInstance owner; XrPath profile, path; XrAction action; };
static struct native_binding bindings[BINDING_LIMIT];
#define SESSION_LIMIT 32
#define SWAPCHAIN_LIMIT 64
#define SWAPCHAIN_IMAGES 3
struct XrSession_T {
    unsigned used, live, running, event_pending, exit_requested;
    XrInstance owner;
    void *device, *queue;
    XrSessionState state;
    XrTime event_time;
    unsigned frame_ticket, frame_begun, frame_poison;
    uint64_t last_frame_id;
    XrTime last_predicted_time;
    KlNativeFrameSample sample;
    XrActionSet attached[ACTION_SET_LIMIT];
    uint32_t attached_count;
    uint64_t last_input_id;
    XrTime last_input_time;
    unsigned input_valid;
    unsigned has_input2;
    KlNativeInputSample2 last_input2;
    /* Version 3: the last two synced samples (for changedSinceLastSync) and
     * the profile made current per hand; a change queues one event. */
    unsigned has_input3, has_prev_input3, profile_event_pending;
    KlNativeInputSample3 last_input3, prev_input3;
    XrPath current_profile[2];
    XrTime profile_time[2];
};
struct XrSwapchain_T {
    unsigned used, live;
    XrSession owner;
    void *texture[SWAPCHAIN_IMAGES], *lease[SWAPCHAIN_IMAGES];
    uint8_t image_state[SWAPCHAIN_IMAGES], fifo[SWAPCHAIN_IMAGES];
    unsigned fifo_count, next_index;
    KlNativeMetalImageInfo info;
    unsigned last_released, last_valid;
    uint64_t release_serial, published_serial, released_frame_id, released_pose_id;
};
static struct XrSession_T sessions[SESSION_LIMIT];
static struct XrSwapchain_T swapchains[SWAPCHAIN_LIMIT];
#define SPACE_LIMIT 128
/* type is KL_ACTION_SPACE for an action space (action, subaction). */
#define KL_ACTION_SPACE ((XrReferenceSpaceType)0x7ffffff0)
struct XrSpace_T { unsigned used, live; XrSession owner; XrReferenceSpaceType type; XrPosef offset; XrAction action; XrPath subaction; };
static struct XrSpace_T spaces[SPACE_LIMIT];
static void destroy_instance_sessions(XrInstance instance);
static int instance_has_acquired_images(XrInstance instance);

#define KLXR_RET(x) return (x)
#define KLXR_ERROR_VALIDATION_FAILURE XR_ERROR_VALIDATION_FAILURE
#define KLXR_ERROR_SIZE_INSUFFICIENT XR_ERROR_SIZE_INSUFFICIENT
#define KLXR_SUCCESS XR_SUCCESS
#define KLXR_SYSTEM_ID ((XrSystemId)1)

/* From upstream kl_openxr.c:1056-1069; symbolic error names map to Khronos. */
static XrResult klxr_two_call(uint32_t capacity, uint32_t *count_out, uint32_t have) {
    if (!count_out) KLXR_RET(KLXR_ERROR_VALIDATION_FAILURE);
    *count_out = have;
    if (capacity == 0) return KLXR_SUCCESS;
    if (capacity < have) KLXR_RET(KLXR_ERROR_SIZE_INSUFFICIENT);
    return KLXR_SUCCESS;
}

static int valid_instance(XrInstance instance) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i)
        if (instance == &instances[i]) return instances[i].live != 0;
    return 0;
}
XrResult kl_native_configure(const KlNativeHost *host) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i)
        if (instances[i].live) return XR_ERROR_CALL_ORDER_INVALID;
    if (!host || host->version != 1 || host->size < sizeof(*host) || !host->hmd_available)
        return XR_ERROR_VALIDATION_FAILURE;
    native_host = *host;
    configured = 1;
    return XR_SUCCESS;
}

XrResult kl_native_configure_metal(const KlNativeMetalHost *host) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i)
        if (instances[i].live) return XR_ERROR_CALL_ORDER_INVALID;
    if (!host) { memset(&metal_host, 0, sizeof metal_host); metal_configured = 0; return XR_SUCCESS; }
    if (host->version != KL_NATIVE_METAL_HOST_VERSION || host->struct_size < sizeof(*host) ||
        !host->get_graphics || !host->enumerate_formats || !host->create_image || !host->release_image)
        return XR_ERROR_VALIDATION_FAILURE;
    void *device = NULL, *queue = NULL;
    XrResult result = host->get_graphics(host->context, &device, &queue);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    if (!device || !queue) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    metal_host = *host;
    metal_configured = 1;
    return XR_SUCCESS;
}

XrResult kl_native_configure_session(const KlNativeSessionHost *host) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i)
        if (instances[i].live) return XR_ERROR_CALL_ORDER_INVALID;
    if (!host) { memset(&session_host, 0, sizeof session_host); session_configured = 0; return XR_SUCCESS; }
    if (host->version != KL_NATIVE_SESSION_HOST_VERSION || host->struct_size < sizeof(*host) ||
        !host->poll_event || !host->begin_session || !host->end_session) return XR_ERROR_VALIDATION_FAILURE;
    session_host = *host; session_configured = 1;
    return XR_SUCCESS;
}

XrResult kl_native_configure_image_sync(const KlNativeImageSyncHost *host) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i)
        if (instances[i].live) return XR_ERROR_CALL_ORDER_INVALID;
    if (!host) { memset(&image_sync_host, 0, sizeof image_sync_host); image_sync_configured = 0; return XR_SUCCESS; }
    if (host->version != KL_NATIVE_IMAGE_SYNC_HOST_VERSION || host->struct_size < sizeof(*host) ||
        !host->wait_available || !host->complete_writes) return XR_ERROR_VALIDATION_FAILURE;
    image_sync_host = *host; image_sync_configured = 1;
    return XR_SUCCESS;
}

XrResult kl_native_configure_frame(const KlNativeFrameHost *host) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i)
        if (instances[i].live) return XR_ERROR_CALL_ORDER_INVALID;
    if (!host) { memset(&frame_host, 0, sizeof frame_host); frame_configured = 0; return XR_SUCCESS; }
    if (host->version != KL_NATIVE_FRAME_HOST_VERSION || host->struct_size < sizeof(*host) ||
        !host->wait_frame || !host->publish_pair || !host->cancel_frame) return XR_ERROR_VALIDATION_FAILURE;
    frame_host = *host; frame_configured = 1;
    return XR_SUCCESS;
}

XrResult kl_native_configure_views(const KlNativeViewHost *host) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i)
        if (instances[i].live) return XR_ERROR_CALL_ORDER_INVALID;
    if (!host) { memset(&view_host, 0, sizeof view_host); view_configured = 0; return XR_SUCCESS; }
    if (host->version != KL_NATIVE_VIEW_HOST_VERSION || host->struct_size < sizeof(*host) || !host->get_configuration) return XR_ERROR_VALIDATION_FAILURE;
    view_host = *host; view_configured = 1;
    return XR_SUCCESS;
}
XrResult kl_native_configure_view_geometry(const KlNativeViewGeometryHost *host) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i) if (instances[i].live) return XR_ERROR_CALL_ORDER_INVALID;
    if (!host) { memset(&view_geometry_host,0,sizeof view_geometry_host); view_geometry_configured=0; return XR_SUCCESS; }
    if (host->version!=KL_NATIVE_VIEW_GEOMETRY_VERSION || host->struct_size<sizeof(*host) || !host->get_geometry) return XR_ERROR_VALIDATION_FAILURE;
    view_geometry_host=*host; view_geometry_configured=1; return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_GetVxStaticViewGeometry(XrInstance instance, XrSystemId system, KlNativeViewGeometry *out) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (system!=KLXR_SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    if (!out || out->version!=KL_NATIVE_VIEW_GEOMETRY_VERSION || out->struct_size<sizeof(*out)) return XR_ERROR_VALIDATION_FAILURE;
    if (!view_geometry_configured) return XR_ERROR_FUNCTION_UNSUPPORTED;
    KlNativeViewGeometry value={.version=KL_NATIVE_VIEW_GEOMETRY_VERSION,.struct_size=sizeof(value)};
    XrResult result=view_geometry_host.get_geometry(view_geometry_host.context,&value);
    if (result!=XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    if (value.version!=KL_NATIVE_VIEW_GEOMETRY_VERSION || value.struct_size<sizeof(value) || !value.geometry_id) return XR_ERROR_VALIDATION_FAILURE;
    for (unsigned i=0;i<2;++i) {
        XrFovf f=value.fov[i];
        if (!kl_native_pose_valid(value.head_from_eye[i]) || !isfinite(f.angleLeft) || !isfinite(f.angleRight) ||
            !isfinite(f.angleUp) || !isfinite(f.angleDown) || f.angleLeft>=f.angleRight || f.angleDown>=f.angleUp ||
            f.angleLeft<=-1.5707963267948966f || f.angleRight>=1.5707963267948966f ||
            f.angleDown<=-1.5707963267948966f || f.angleUp>=1.5707963267948966f) return XR_ERROR_VALIDATION_FAILURE;
    }
    *out=value; return XR_SUCCESS;
}

static void clear_input_host(void) {
    memset(&input_host, 0, sizeof input_host);
    memset(&input_host2, 0, sizeof input_host2);
    memset(&input_host3, 0, sizeof input_host3);
    input_configured = 0;
}
XrResult kl_native_configure_input(const KlNativeInputHost *host) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i)
        if (instances[i].live) return XR_ERROR_CALL_ORDER_INVALID;
    if (!host) { clear_input_host(); return XR_SUCCESS; }
    if (host->version != KL_NATIVE_INPUT_HOST_VERSION || host->struct_size < sizeof(*host) || !host->sample) return XR_ERROR_VALIDATION_FAILURE;
    clear_input_host(); input_host = *host; input_configured = 1; return XR_SUCCESS;
}
XrResult kl_native_configure_input2(const KlNativeInputHost2 *host) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i)
        if (instances[i].live) return XR_ERROR_CALL_ORDER_INVALID;
    if (!host) { clear_input_host(); return XR_SUCCESS; }
    if (host->version != KL_NATIVE_INPUT_HOST_VERSION_2 || host->struct_size < sizeof(*host) || !host->sample) return XR_ERROR_VALIDATION_FAILURE;
    clear_input_host(); input_host2 = *host; input_configured = 2; return XR_SUCCESS;
}
XrResult kl_native_configure_input3(const KlNativeInputHost3 *host) {
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i)
        if (instances[i].live) return XR_ERROR_CALL_ORDER_INVALID;
    if (!host) { clear_input_host(); return XR_SUCCESS; }
    if (host->version != KL_NATIVE_INPUT_HOST_VERSION_3 || host->struct_size < sizeof(*host) || !host->sample) return XR_ERROR_VALIDATION_FAILURE;
    clear_input_host(); input_host3 = *host; input_configured = 3; return XR_SUCCESS;
}

/* Klepton enumeration two-call behavior; no extensions or API layers are
 * advertised until their real implementation is present. */
static XrResult XRAPI_CALL klxr_EnumerateApiLayerProperties(uint32_t capacity, uint32_t *count, XrApiLayerProperties *properties) {
    (void)properties;
    return klxr_two_call(capacity, count, 0);
}
static XrResult XRAPI_CALL klxr_EnumerateInstanceExtensionProperties(const char *layer, uint32_t capacity, uint32_t *count, XrExtensionProperties *properties) {
    if (layer) return XR_ERROR_API_LAYER_NOT_PRESENT;
    uint32_t have = metal_extension_available() ? 1 : 0;
    XrResult result = klxr_two_call(capacity, count, have);
    if (result != XR_SUCCESS || !capacity || !have) return result;
    if (!properties || properties[0].type != XR_TYPE_EXTENSION_PROPERTIES || properties[0].next) return XR_ERROR_VALIDATION_FAILURE;
    snprintf(properties[0].extensionName, sizeof properties[0].extensionName, "%s", XR_KHR_METAL_ENABLE_EXTENSION_NAME);
    properties[0].extensionVersion = XR_KHR_metal_enable_SPEC_VERSION;
    return XR_SUCCESS;
}

/* Adapted from upstream klxr_CreateInstance:1262-1302. Replace singleton and
 * advertised extension table with bounded stale-safe handles and zero features. */
static XrResult XRAPI_CALL klxr_CreateInstance(const XrInstanceCreateInfo *info, XrInstance *instance) {
    if (!info || !instance || info->type != XR_TYPE_INSTANCE_CREATE_INFO) return XR_ERROR_VALIDATION_FAILURE;
    *instance = XR_NULL_HANDLE;
    if (!configured) return XR_ERROR_RUNTIME_UNAVAILABLE;
    if (info->enabledApiLayerCount) return XR_ERROR_API_LAYER_NOT_PRESENT;
    unsigned metal_enabled = 0;
    if (info->enabledExtensionCount && !info->enabledExtensionNames) return XR_ERROR_VALIDATION_FAILURE;
    for (uint32_t i = 0; i < info->enabledExtensionCount; ++i) {
        const char *name = info->enabledExtensionNames[i];
        if (!name) return XR_ERROR_VALIDATION_FAILURE;
        if (!metal_extension_available() || strcmp(name, XR_KHR_METAL_ENABLE_EXTENSION_NAME)) return XR_ERROR_EXTENSION_NOT_PRESENT;
        metal_enabled = 1;
    }
    if (XR_VERSION_MAJOR(info->applicationInfo.apiVersion) != 1 || XR_VERSION_MINOR(info->applicationInfo.apiVersion) != 0) return XR_ERROR_API_VERSION_UNSUPPORTED;
    if (info->next) return XR_ERROR_VALIDATION_FAILURE;
    for (unsigned i = 0; i < INSTANCE_LIMIT; ++i) {
        if (!instances[i].used) {
            instances[i].used = instances[i].live = 1;
            instances[i].metal_enabled = metal_enabled;
            *instance = &instances[i];
            return XR_SUCCESS;
        }
    }
    return XR_ERROR_LIMIT_REACHED;
}
static XrResult XRAPI_CALL klxr_DestroyInstance(XrInstance instance) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    for (unsigned i = 0; i < SESSION_LIMIT; ++i)
        if (sessions[i].live && sessions[i].owner == instance && (sessions[i].running || sessions[i].frame_ticket)) return XR_ERROR_SESSION_RUNNING;
    if (instance_has_acquired_images(instance)) return XR_ERROR_CALL_ORDER_INVALID;
    destroy_instance_sessions(instance);
    instance->live = 0;
    for (unsigned i = 0; i < BINDING_LIMIT; ++i) if (bindings[i].owner == instance) bindings[i].owner = XR_NULL_HANDLE;
    for (unsigned i = 0; i < ACTION_SET_LIMIT; ++i)
        if (action_sets[i].owner == instance) {
            for (unsigned j = 0; j < ACTION_LIMIT; ++j)
                if (actions[j].owner == &action_sets[i]) actions[j].live = 0;
            action_sets[i].live = 0;
        }
    for (unsigned i = 0; i < PATH_LIMIT; ++i)
        if (paths[i].owner == instance) memset(&paths[i], 0, sizeof paths[i]);
    return XR_SUCCESS;
}

/* Adapted from upstream klxr_GetSystem:1327-1342. HMD availability is host
 * evidence, not the upstream unconditional synthetic system claim. */
static XrResult XRAPI_CALL klxr_GetSystem(XrInstance instance, const XrSystemGetInfo *info, XrSystemId *system_id) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (!info || !system_id) return XR_ERROR_VALIDATION_FAILURE;
    if (info->type != XR_TYPE_SYSTEM_GET_INFO || info->next) return XR_ERROR_VALIDATION_FAILURE;
    if (info->formFactor != XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY) return XR_ERROR_FORM_FACTOR_UNSUPPORTED;
    XrResult result = native_host.hmd_available(native_host.context);
    if (XR_FAILED(result)) return result;
    if (result != XR_SUCCESS) return XR_ERROR_RUNTIME_FAILURE;
    *system_id = KLXR_SYSTEM_ID;
    return XR_SUCCESS;
}
/* Adapted from Klepton klxr_GetInstanceProperties (upstream 1310-1325):
 * identify this provider rather than imitating an Oculus runtime. */
static XrResult XRAPI_CALL klxr_GetInstanceProperties(XrInstance instance, XrInstanceProperties *props) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (!props || props->type != XR_TYPE_INSTANCE_PROPERTIES || props->next) return XR_ERROR_VALIDATION_FAILURE;
    props->runtimeVersion = XR_MAKE_VERSION(1, 0, 0);
    snprintf(props->runtimeName, sizeof props->runtimeName, "Klepton-derived native provider (partial)");
    return XR_SUCCESS;
}
/* Adapted from upstream klxr_GetSystemProperties 1344-1391. All platform
 * information comes from the host; never fabricate Quest identity or tracking. */
static XrResult XRAPI_CALL klxr_GetSystemProperties(XrInstance instance, XrSystemId system_id, XrSystemProperties *props) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (system_id != KLXR_SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    if (!props || props->type != XR_TYPE_SYSTEM_PROPERTIES || props->next) return XR_ERROR_VALIDATION_FAILURE;
    XrResult status = native_host.hmd_available(native_host.context);
    if (status != XR_SUCCESS) return XR_FAILED(status) ? status : XR_ERROR_RUNTIME_FAILURE;
    if (!native_host.system_properties) return XR_ERROR_FUNCTION_UNSUPPORTED;
    XrSystemProperties out = { .type = XR_TYPE_SYSTEM_PROPERTIES };
    status = native_host.system_properties(native_host.context, &out);
    if (status != XR_SUCCESS) return XR_FAILED(status) ? status : XR_ERROR_RUNTIME_FAILURE;
    if (out.type != XR_TYPE_SYSTEM_PROPERTIES || out.next ||
        !memchr(out.systemName, 0, sizeof out.systemName) || !out.systemName[0] ||
        !out.graphicsProperties.maxSwapchainImageWidth || !out.graphicsProperties.maxSwapchainImageHeight ||
        !out.graphicsProperties.maxLayerCount || out.trackingProperties.orientationTracking > XR_TRUE ||
        out.trackingProperties.positionTracking > XR_TRUE) return XR_ERROR_RUNTIME_FAILURE;
    out.systemId = system_id;
    *props = out;
    return XR_SUCCESS;
}
/* Derived from Klepton klxr_StringToPath/PathToString (upstream 3284–3318).
 * Paths are per-instance and stale IDs cannot become valid for another owner.
 * Unlike upstream, validate the complete OpenXR path grammar. */
static int path_well_formed(const char *s) {
    if (s[0] != '/') return 0;
    unsigned component = 0, nonperiod = 0;
    for (unsigned i = 1; i < XR_MAX_PATH_LENGTH; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (!c) return component && nonperiod;
        if (c == '/') {
            if (!component || !nonperiod) return 0;
            component = nonperiod = 0;
        } else {
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')) return 0;
            ++component;
            if (c != '.') nonperiod = 1;
        }
    }
    return 0;
}
static XrResult XRAPI_CALL klxr_StringToPath(XrInstance instance, const char *str, XrPath *path) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (!str || !path) return XR_ERROR_VALIDATION_FAILURE;
    *path = XR_NULL_PATH;
    if (!path_well_formed(str)) return XR_ERROR_PATH_FORMAT_INVALID;
    struct native_path *free_slot = NULL;
    for (unsigned i = 0; i < PATH_LIMIT; ++i) {
        if (paths[i].owner == instance && !strcmp(paths[i].name, str)) { *path = paths[i].id; return XR_SUCCESS; }
        if (!paths[i].owner && !free_slot) free_slot = &paths[i];
    }
    if (!free_slot || next_path == XR_NULL_PATH) return XR_ERROR_PATH_COUNT_EXCEEDED;
    free_slot->owner = instance;
    free_slot->id = next_path++;
    memcpy(free_slot->name, str, strlen(str) + 1);
    *path = free_slot->id;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_PathToString(XrInstance instance, XrPath path, uint32_t capacity, uint32_t *count, char *buffer) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    const char *str = NULL;
    for (unsigned i = 0; i < PATH_LIMIT; ++i)
        if (paths[i].owner == instance && paths[i].id == path) { str = paths[i].name; break; }
    if (!str || path == XR_NULL_PATH) return XR_ERROR_PATH_INVALID;
    uint32_t need = (uint32_t)strlen(str) + 1;
    XrResult result = klxr_two_call(capacity, count, need);
    if (result != XR_SUCCESS || !capacity) return result;
    if (!buffer) return XR_ERROR_VALIDATION_FAILURE;
    memcpy(buffer, str, need);
    return XR_SUCCESS;
}
/* Adapted from upstream action-set pool/create/destroy (3260–3274,
 * 3320–3359); add parent ownership, duplicate validation and non-reused
 * handles. Action sets are bookkeeping only, no controller state implied. */
static XrResult XRAPI_CALL klxr_CreateActionSet(XrInstance instance, const XrActionSetCreateInfo *info, XrActionSet *out) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (!info || !out || info->type != XR_TYPE_ACTION_SET_CREATE_INFO || info->next) return XR_ERROR_VALIDATION_FAILURE;
    *out = XR_NULL_HANDLE;
    if (!memchr(info->actionSetName, 0, sizeof info->actionSetName) || !info->actionSetName[0]) return XR_ERROR_NAME_INVALID;
    if (!memchr(info->localizedActionSetName, 0, sizeof info->localizedActionSetName) || !info->localizedActionSetName[0]) return XR_ERROR_LOCALIZED_NAME_INVALID;
    char path[XR_MAX_ACTION_SET_NAME_SIZE + 2];
    path[0] = '/';
    memcpy(path + 1, info->actionSetName, strlen(info->actionSetName) + 1);
    if (strchr(info->actionSetName, '/') || !path_well_formed(path)) return XR_ERROR_PATH_FORMAT_INVALID;
    struct XrActionSet_T *free_slot = NULL;
    for (unsigned i = 0; i < ACTION_SET_LIMIT; ++i) {
        struct XrActionSet_T *slot = &action_sets[i];
        if (slot->live && slot->owner == instance) {
            if (!strcmp(slot->name, info->actionSetName)) return XR_ERROR_NAME_DUPLICATED;
            if (!strcmp(slot->localized, info->localizedActionSetName)) return XR_ERROR_LOCALIZED_NAME_DUPLICATED;
        }
        if (!slot->used && !free_slot) free_slot = slot;
    }
    if (!free_slot) return XR_ERROR_LIMIT_REACHED;
    free_slot->used = free_slot->live = 1;
    free_slot->owner = instance;
    free_slot->priority = info->priority;
    memcpy(free_slot->name, info->actionSetName, strlen(info->actionSetName) + 1);
    memcpy(free_slot->localized, info->localizedActionSetName, strlen(info->localizedActionSetName) + 1);
    *out = free_slot;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_DestroyActionSet(XrActionSet set) {
    for (unsigned i = 0; i < ACTION_SET_LIMIT; ++i) {
        if (set == &action_sets[i] && action_sets[i].live && valid_instance(action_sets[i].owner)) {
            for (unsigned j = 0; j < ACTION_LIMIT; ++j) if (actions[j].live && actions[j].owner == set) {
                for (unsigned k = 0; k < BINDING_LIMIT; ++k) if (bindings[k].action == &actions[j]) bindings[k].owner = XR_NULL_HANDLE;
                actions[j].live = 0;
            }
            action_sets[i].live = 0;
            return XR_SUCCESS;
        }
    }
    return XR_ERROR_HANDLE_INVALID;
}
/* Adapted from upstream CreateAction/DestroyAction lines 3361-3384. Action
 * identity does not imply bindings, state, connected controllers or haptics. */
static XrResult XRAPI_CALL klxr_CreateAction(XrActionSet set, const XrActionCreateInfo *info, XrAction *out) {
    XrInstance owner = XR_NULL_HANDLE;
    for (unsigned i = 0; i < ACTION_SET_LIMIT; ++i)
        if (set == &action_sets[i] && action_sets[i].live && valid_instance(action_sets[i].owner)) owner = action_sets[i].owner;
    if (!owner) return XR_ERROR_HANDLE_INVALID;
    if (!info || !out || info->type != XR_TYPE_ACTION_CREATE_INFO || info->next) return XR_ERROR_VALIDATION_FAILURE;
    *out = XR_NULL_HANDLE;
    if (info->actionType != XR_ACTION_TYPE_POSE_INPUT && info->actionType != XR_ACTION_TYPE_BOOLEAN_INPUT &&
        info->actionType != XR_ACTION_TYPE_FLOAT_INPUT && info->actionType != XR_ACTION_TYPE_VECTOR2F_INPUT &&
        info->actionType != XR_ACTION_TYPE_VIBRATION_OUTPUT) return XR_ERROR_FEATURE_UNSUPPORTED;
    if (!memchr(info->actionName, 0, sizeof info->actionName) || !info->actionName[0]) return XR_ERROR_NAME_INVALID;
    if (!memchr(info->localizedActionName, 0, sizeof info->localizedActionName) || !info->localizedActionName[0]) return XR_ERROR_LOCALIZED_NAME_INVALID;
    char path[XR_MAX_ACTION_NAME_SIZE + 2]; path[0] = '/';
    memcpy(path + 1, info->actionName, strlen(info->actionName) + 1);
    if (strchr(info->actionName, '/') || !path_well_formed(path)) return XR_ERROR_PATH_FORMAT_INVALID;
    if (info->countSubactionPaths > ACTION_SUBPATH_LIMIT) return XR_ERROR_LIMIT_REACHED;
    if (info->countSubactionPaths && !info->subactionPaths) return XR_ERROR_VALIDATION_FAILURE;
    for (uint32_t i = 0; i < info->countSubactionPaths; ++i) {
        const char *name = NULL;
        for (unsigned j = 0; j < PATH_LIMIT; ++j) if (paths[j].owner == owner && paths[j].id == info->subactionPaths[i]) name = paths[j].name;
        if (!name || info->subactionPaths[i] == XR_NULL_PATH) return XR_ERROR_PATH_INVALID;
        if (strcmp(name, "/user/hand/left") && strcmp(name, "/user/hand/right")) return XR_ERROR_PATH_UNSUPPORTED;
        for (uint32_t j = 0; j < i; ++j) if (info->subactionPaths[j] == info->subactionPaths[i]) return XR_ERROR_PATH_INVALID;
    }
    struct XrAction_T *free_slot = NULL;
    for (unsigned i = 0; i < ACTION_LIMIT; ++i) {
        struct XrAction_T *slot = &actions[i];
        if (slot->live && slot->owner == set) {
            if (!strcmp(slot->name, info->actionName)) return XR_ERROR_NAME_DUPLICATED;
            if (!strcmp(slot->localized, info->localizedActionName)) return XR_ERROR_LOCALIZED_NAME_DUPLICATED;
        }
        if (!slot->used && !free_slot) free_slot = slot;
    }
    if (!free_slot) return XR_ERROR_LIMIT_REACHED;
    free_slot->used = free_slot->live = 1; free_slot->owner = set; free_slot->type = info->actionType;
    free_slot->subpath_count = info->countSubactionPaths;
    for (uint32_t i = 0; i < info->countSubactionPaths; ++i) free_slot->subpaths[i] = info->subactionPaths[i];
    memcpy(free_slot->name, info->actionName, strlen(info->actionName) + 1);
    memcpy(free_slot->localized, info->localizedActionName, strlen(info->localizedActionName) + 1);
    *out = free_slot; return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_DestroyAction(XrAction action) {
    for (unsigned i = 0; i < ACTION_LIMIT; ++i) if (action == &actions[i] && actions[i].live) {
        XrActionSet owner = actions[i].owner;
        for (unsigned j = 0; j < ACTION_SET_LIMIT; ++j) if (owner == &action_sets[j] && action_sets[j].live && valid_instance(action_sets[j].owner)) {
            for (unsigned k = 0; k < BINDING_LIMIT; ++k) if (bindings[k].action == action) bindings[k].owner = XR_NULL_HANDLE;
            actions[i].live = 0; return XR_SUCCESS;
        }
    }
    return XR_ERROR_HANDLE_INVALID;
}
static const char *owned_path(XrInstance owner, XrPath path) {
    if (!path) return NULL;
    for (unsigned i = 0; i < PATH_LIMIT; ++i)
        if (paths[i].owner == owner && paths[i].id == path) return paths[i].name;
    return NULL;
}
static XrAction valid_action_for(XrInstance owner, XrAction action) {
    for (unsigned i = 0; i < ACTION_LIMIT; ++i) if (action == &actions[i] && actions[i].live) {
        for (unsigned j = 0; j < ACTION_SET_LIMIT; ++j)
            if (actions[i].owner == &action_sets[j] && action_sets[j].live && action_sets[j].owner == owner) return action;
    }
    return XR_NULL_HANDLE;
}
static int member(const char *const *list, size_t count, const char *value) {
    for (size_t i = 0; i < count; ++i) if (!strcmp(list[i], value)) return 1;
    return 0;
}
/* Supported legacy profile component paths, including only the paths this
 * provider actually recognizes. Suggestions are stored; no profile becomes
 * active without a host reporting a supported connected device. */
static int binding_kind(const char *profile, const char *path) {
    static const char *const vive[] = { "squeeze/click", "menu/click", "trigger/click", "trigger/value", "trackpad/click", "trackpad/touch", "trackpad", "trackpad/x", "trackpad/y" };
    static const char *const index[] = { "a/click", "a/touch", "b/click", "b/touch", "trigger/click", "trigger/touch", "trigger/value", "squeeze/value", "squeeze/force", "thumbstick/click", "thumbstick/touch", "thumbstick", "trackpad/force", "trackpad/touch", "trackpad" };
    static const char *const touch[] = { "squeeze/value", "trigger/value", "trigger/touch", "thumbstick", "thumbstick/click", "thumbstick/touch", "thumbrest/touch" };
    static const char *const simple[] = { "select/click", "menu/click" };
    int left;
    if (!strncmp(path, "/user/hand/left/", 16)) { left = 1; path += 16; }
    else if (!strncmp(path, "/user/hand/right/", 17)) { left = 0; path += 17; }
    else return 0;
    int supported = !strcmp(profile, "/interaction_profiles/htc/vive_controller") || !strcmp(profile, "/interaction_profiles/valve/index_controller") || !strcmp(profile, "/interaction_profiles/oculus/touch_controller") || !strcmp(profile, "/interaction_profiles/khr/simple_controller");
    if (!supported) return 0;
    if (!strcmp(path, "output/haptic")) return 4;
    if (!strcmp(path, "input/grip/pose") || !strcmp(path, "input/aim/pose")) return 3;
    if (strncmp(path, "input/", 6)) return 0;
    path += 6;
    int legal = 0;
    if (!strcmp(profile, "/interaction_profiles/htc/vive_controller")) legal = member(vive, sizeof vive / sizeof vive[0], path);
    else if (!strcmp(profile, "/interaction_profiles/valve/index_controller")) legal = member(index, sizeof index / sizeof index[0], path);
    else if (!strcmp(profile, "/interaction_profiles/khr/simple_controller")) legal = member(simple, sizeof simple / sizeof simple[0], path);
    else {
        legal = member(touch, sizeof touch / sizeof touch[0], path);
        if (left) legal |= !strcmp(path, "x/click") || !strcmp(path, "x/touch") || !strcmp(path, "y/click") || !strcmp(path, "y/touch") || !strcmp(path, "menu/click");
        else legal |= !strcmp(path, "a/click") || !strcmp(path, "a/touch") || !strcmp(path, "b/click") || !strcmp(path, "b/touch");
    }
    if (!legal) return 0;
    return !strcmp(path, "trackpad") || !strcmp(path, "thumbstick") ? 2 : 1;
}
static XrResult XRAPI_CALL klxr_SuggestInteractionProfileBindings(XrInstance instance, const XrInteractionProfileSuggestedBinding *info) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (!info || info->type != XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING || info->next || (info->countSuggestedBindings && !info->suggestedBindings)) return XR_ERROR_VALIDATION_FAILURE;
    const char *profile = owned_path(instance, info->interactionProfile);
    if (!profile) return XR_ERROR_PATH_INVALID;
    for (unsigned i = 0; i < SESSION_LIMIT; ++i)
        if (sessions[i].live && sessions[i].owner == instance && sessions[i].attached_count) return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
    /* Do not accept an unknown profile even for an empty suggestion. */
    if (!binding_kind(profile, "/user/hand/left/output/haptic")) return XR_ERROR_PATH_UNSUPPORTED;
    uint32_t retained = 0;
    for (unsigned i = 0; i < BINDING_LIMIT; ++i) if (bindings[i].owner && !(bindings[i].owner == instance && bindings[i].profile == info->interactionProfile)) ++retained;
    if (info->countSuggestedBindings > BINDING_LIMIT - retained) return XR_ERROR_LIMIT_REACHED;
    for (uint32_t i = 0; i < info->countSuggestedBindings; ++i) {
        XrAction action = valid_action_for(instance, info->suggestedBindings[i].action);
        if (!action) return XR_ERROR_HANDLE_INVALID;
        const char *path = owned_path(instance, info->suggestedBindings[i].binding);
        if (!path) return XR_ERROR_PATH_INVALID;
        int kind = binding_kind(profile, path);
        if (!kind) return XR_ERROR_PATH_UNSUPPORTED;
        if (action->subpath_count) {
            const char *hand = !strncmp(path, "/user/hand/left/", 16) ? "/user/hand/left" : "/user/hand/right";
            int matched = 0;
            for (uint32_t j = 0; j < action->subpath_count; ++j) {
                const char *subpath = owned_path(instance, action->subpaths[j]);
                if (subpath && !strcmp(subpath, hand)) matched = 1;
            }
            if (!matched) return XR_ERROR_PATH_UNSUPPORTED;
        }
        if ((kind == 1 && action->type != XR_ACTION_TYPE_BOOLEAN_INPUT && action->type != XR_ACTION_TYPE_FLOAT_INPUT) || (kind == 2 && action->type != XR_ACTION_TYPE_VECTOR2F_INPUT) || (kind == 3 && action->type != XR_ACTION_TYPE_POSE_INPUT) || (kind == 4 && action->type != XR_ACTION_TYPE_VIBRATION_OUTPUT)) return XR_ERROR_ACTION_TYPE_MISMATCH;
    }
    for (unsigned i = 0; i < BINDING_LIMIT; ++i) if (bindings[i].owner == instance && bindings[i].profile == info->interactionProfile) bindings[i].owner = XR_NULL_HANDLE;
    for (uint32_t i = 0, slot = 0; i < info->countSuggestedBindings; ++i) {
        while (bindings[slot].owner) ++slot;
        bindings[slot++] = (struct native_binding){ instance, info->interactionProfile, info->suggestedBindings[i].binding, info->suggestedBindings[i].action };
    }
    return XR_SUCCESS;
}
/* View configuration is supplied by the real host before any frame ticket.
 * Adapted from Klepton's enumeration functions, without assumed sizes/FOV. */
static XrResult get_view_config(XrInstance instance, XrSystemId system, KlNativeViewConfiguration *config) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (system != KLXR_SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    XrResult result = native_host.hmd_available(native_host.context);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    if (!view_configured) return XR_ERROR_FUNCTION_UNSUPPORTED;
    memset(config, 0, sizeof *config);
    for (unsigned i = 0; i < 2; ++i) config->view[i].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    result = view_host.get_configuration(view_host.context, config);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    if (config->primary_stereo_supported > XR_TRUE || config->opaque_supported > XR_TRUE || config->fov_mutable > XR_TRUE) return XR_ERROR_RUNTIME_FAILURE;
    if (config->primary_stereo_supported) for (unsigned i = 0; i < 2; ++i) {
        XrViewConfigurationView v = config->view[i];
        if (v.type != XR_TYPE_VIEW_CONFIGURATION_VIEW || v.next || !v.recommendedImageRectWidth || !v.recommendedImageRectHeight ||
            v.maxImageRectWidth < v.recommendedImageRectWidth || v.maxImageRectHeight < v.recommendedImageRectHeight ||
            !v.recommendedSwapchainSampleCount || v.maxSwapchainSampleCount < v.recommendedSwapchainSampleCount) return XR_ERROR_RUNTIME_FAILURE;
    }
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_EnumerateViewConfigurations(XrInstance instance, XrSystemId system, uint32_t capacity, uint32_t *count, XrViewConfigurationType *out) {
    KlNativeViewConfiguration config;
    XrResult result = get_view_config(instance, system, &config);
    if (result != XR_SUCCESS) return result;
    uint32_t have = config.primary_stereo_supported ? 1 : 0;
    result = klxr_two_call(capacity, count, have);
    if (result != XR_SUCCESS || !capacity || !have) return result;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    out[0] = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_GetViewConfigurationProperties(XrInstance instance, XrSystemId system, XrViewConfigurationType type, XrViewConfigurationProperties *out) {
    if (!out || out->type != XR_TYPE_VIEW_CONFIGURATION_PROPERTIES || out->next) return XR_ERROR_VALIDATION_FAILURE;
    KlNativeViewConfiguration config;
    XrResult result = get_view_config(instance, system, &config);
    if (result != XR_SUCCESS) return result;
    if (type != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO || !config.primary_stereo_supported) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    out->viewConfigurationType = type; out->fovMutable = config.fov_mutable;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_EnumerateViewConfigurationViews(XrInstance instance, XrSystemId system, XrViewConfigurationType type, uint32_t capacity, uint32_t *count, XrViewConfigurationView *views) {
    KlNativeViewConfiguration config;
    XrResult result = get_view_config(instance, system, &config);
    if (result != XR_SUCCESS) return result;
    if (type != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO || !config.primary_stereo_supported) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    result = klxr_two_call(capacity, count, 2);
    if (result != XR_SUCCESS || !capacity) return result;
    if (!views) return XR_ERROR_VALIDATION_FAILURE;
    for (unsigned i = 0; i < 2; ++i) if (views[i].type != XR_TYPE_VIEW_CONFIGURATION_VIEW || views[i].next) return XR_ERROR_VALIDATION_FAILURE;
    for (unsigned i = 0; i < 2; ++i) views[i] = config.view[i];
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_EnumerateEnvironmentBlendModes(XrInstance instance, XrSystemId system, XrViewConfigurationType type, uint32_t capacity, uint32_t *count, XrEnvironmentBlendMode *out) {
    KlNativeViewConfiguration config;
    XrResult result = get_view_config(instance, system, &config);
    if (result != XR_SUCCESS) return result;
    if (type != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO || !config.primary_stereo_supported) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    uint32_t have = config.opaque_supported ? 1 : 0;
    result = klxr_two_call(capacity, count, have);
    if (result != XR_SUCCESS || !capacity || !have) return result;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    out[0] = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    return XR_SUCCESS;
}

/* Metal session/swapchain use the host's actual resources. Frame and GPU
 * submission are not implemented; no swapchain image may be published yet. */
static int valid_session(XrSession session) {
    for (unsigned i = 0; i < SESSION_LIMIT; ++i)
        if (session == &sessions[i]) return sessions[i].live && valid_instance(sessions[i].owner);
    return 0;
}
static int valid_action_set_for(XrActionSet set, XrInstance owner) {
    for (unsigned i = 0; i < ACTION_SET_LIMIT; ++i)
        if (set == &action_sets[i]) return action_sets[i].live && action_sets[i].owner == owner;
    return 0;
}
static int attached_action_set(XrSession session, XrActionSet set) {
    for (uint32_t i = 0; i < session->attached_count; ++i) if (session->attached[i] == set) return 1;
    return 0;
}
static XrResult XRAPI_CALL klxr_AttachSessionActionSets(XrSession session, const XrSessionActionSetsAttachInfo *info) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!info || info->type != XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO || info->next || !info->countActionSets || !info->actionSets) return XR_ERROR_VALIDATION_FAILURE;
    if (session->attached_count) return XR_ERROR_ACTIONSETS_ALREADY_ATTACHED;
    if (info->countActionSets > ACTION_SET_LIMIT) return XR_ERROR_LIMIT_REACHED;
    for (uint32_t i = 0; i < info->countActionSets; ++i) {
        if (!valid_action_set_for(info->actionSets[i], session->owner)) return XR_ERROR_HANDLE_INVALID;
        for (uint32_t j = 0; j < i; ++j) if (info->actionSets[i] == info->actionSets[j]) return XR_ERROR_VALIDATION_FAILURE;
    }
    memcpy(session->attached, info->actionSets, info->countActionSets * sizeof(*info->actionSets));
    session->attached_count = info->countActionSets;
    return XR_SUCCESS;
}
static int xr_bool(XrBool32 value) { return value == XR_FALSE || value == XR_TRUE; }
static int hand2_ok(const KlNativeInputHand2 *hand) {
    if (!xr_bool(hand->connected) || !xr_bool(hand->grip_position_tracked) || !xr_bool(hand->aim_position_tracked) ||
        !xr_bool(hand->primary_pressed) || !xr_bool(hand->secondary_pressed) || !xr_bool(hand->grip_pressed) ||
        !xr_bool(hand->menu_pressed) || !xr_bool(hand->stick_pressed)) return 0;
    int trigger_absent = isnan(hand->trigger), stick_absent = isnan(hand->stick_x) && isnan(hand->stick_y);
    int stick_pair = isnan(hand->stick_x) == isnan(hand->stick_y);
    if (!hand->connected)
        return !hand->grip_position_tracked && !hand->aim_position_tracked && !hand->primary_pressed && !hand->secondary_pressed &&
            !hand->grip_pressed && !hand->menu_pressed && !hand->stick_pressed && trigger_absent && stick_absent;
    if (!trigger_absent && !(isfinite(hand->trigger) && hand->trigger >= 0.f && hand->trigger <= 1.f)) return 0;
    if (!stick_pair) return 0;
    if (!stick_absent && !(isfinite(hand->stick_x) && isfinite(hand->stick_y) && hand->stick_x >= -1.f && hand->stick_x <= 1.f && hand->stick_y >= -1.f && hand->stick_y <= 1.f)) return 0;
    return 1;
}

/* Version 3 input: profiles, bound controls and action-space poses. */
static const char *const profile_names[] = { NULL, "/interaction_profiles/oculus/touch_controller",
    "/interaction_profiles/valve/index_controller", "/interaction_profiles/htc/vive_controller",
    "/interaction_profiles/khr/simple_controller" };
static const char *const hand_names[2] = { "/user/hand/left", "/user/hand/right" };
static int hand3_ok(const KlNativeInputHand3 *hand) {
    if (!hand2_ok(&hand->controls)) return 0;
    if (!hand->controls.connected) {
        static const XrPosef zero;
        return hand->profile == KL_NATIVE_INPUT_PROFILE_NONE && !memcmp(&hand->local_from_grip, &zero, sizeof zero) && !memcmp(&hand->local_from_aim, &zero, sizeof zero);
    }
    return hand->profile >= KL_NATIVE_INPUT_PROFILE_OCULUS_TOUCH && hand->profile <= KL_NATIVE_INPUT_PROFILE_KHR_SIMPLE &&
        kl_native_pose_valid(hand->local_from_grip) && kl_native_pose_valid(hand->local_from_aim);
}
/* The application's path for this profile, only when it suggested bindings for it. */
static XrPath suggested_profile(XrInstance owner, uint32_t profile) {
    if (profile == KL_NATIVE_INPUT_PROFILE_NONE || profile >= sizeof profile_names / sizeof profile_names[0]) return XR_NULL_PATH;
    XrPath id = XR_NULL_PATH;
    for (unsigned i = 0; i < PATH_LIMIT && !id; ++i) if (paths[i].owner == owner && paths[i].id && !strcmp(paths[i].name, profile_names[profile])) id = paths[i].id;
    if (!id) return XR_NULL_PATH;
    for (unsigned i = 0; i < BINDING_LIMIT; ++i) if (bindings[i].owner == owner && bindings[i].profile == id) return id;
    return XR_NULL_PATH;
}
/* "input/trigger/value" for a binding path naming this hand, else NULL. */
static const char *hand_component(XrInstance owner, XrPath binding, unsigned hand) {
    const char *path = owned_path(owner, binding);
    size_t n = strlen(hand_names[hand]);
    if (!path || strncmp(path, hand_names[hand], n) || path[n] != '/') return NULL;
    return path + n + 1;
}
/* Value of one component of a connected hand: 1 scalar in *x, 2 vector in
 * *x,*y, 0 not observed (touch, force and absent controls). */
static int component_value(const char *c, const KlNativeInputHand2 *h, float *x, float *y) {
    XrBool32 b;
    *x = *y = 0;
    if (!strcmp(c, "input/trigger/value")) { if (isnan(h->trigger)) return 0; *x = h->trigger; return 1; }
    if (!strcmp(c, "input/trigger/click") || !strcmp(c, "input/select/click")) { if (isnan(h->trigger)) return 0; *x = h->trigger >= 0.5f ? 1.f : 0.f; return 1; }
    if (!strcmp(c, "input/thumbstick") || !strcmp(c, "input/trackpad")) { if (isnan(h->stick_x)) return 0; *x = h->stick_x; *y = h->stick_y; return 2; }
    if (!strcmp(c, "input/trackpad/x")) { if (isnan(h->stick_x)) return 0; *x = h->stick_x; return 1; }
    if (!strcmp(c, "input/trackpad/y")) { if (isnan(h->stick_y)) return 0; *x = h->stick_y; return 1; }
    if (!strcmp(c, "input/a/click") || !strcmp(c, "input/x/click")) b = h->primary_pressed;
    else if (!strcmp(c, "input/b/click") || !strcmp(c, "input/y/click")) b = h->secondary_pressed;
    else if (!strcmp(c, "input/squeeze/click") || !strcmp(c, "input/squeeze/value")) b = h->grip_pressed;
    else if (!strcmp(c, "input/menu/click")) b = h->menu_pressed;
    else if (!strcmp(c, "input/thumbstick/click") || !strcmp(c, "input/trackpad/click")) b = h->stick_pressed;
    else return 0;
    *x = b ? 1.f : 0.f; return 1;
}
struct bound_value { int active; float x, y; };
/* Every binding of the action for the current profile of the selected hand(s);
 * the largest magnitude wins, as the OpenXR combination rules allow. */
static struct bound_value bound_value(XrSession session, XrAction action, XrPath subaction, const KlNativeInputSample3 *sample) {
    struct bound_value v = {0};
    const char *sub = subaction ? owned_path(session->owner, subaction) : NULL;
    for (unsigned h = 0; h < 2; ++h) {
        if (sub && strcmp(sub, hand_names[h])) continue;
        const KlNativeInputHand3 *hand = &sample->hand[h];
        if (!hand->controls.connected || !session->current_profile[h]) continue;
        for (unsigned i = 0; i < BINDING_LIMIT; ++i) {
            const struct native_binding *b = &bindings[i];
            if (b->owner != session->owner || b->action != action || b->profile != session->current_profile[h]) continue;
            const char *c = hand_component(session->owner, b->path, h);
            if (!c) continue;
            if (action->type == XR_ACTION_TYPE_POSE_INPUT) { if (!strcmp(c, "input/grip/pose") || !strcmp(c, "input/aim/pose")) v.active = 1; continue; }
            float x, y; int kind = component_value(c, &hand->controls, &x, &y);
            if (!kind) continue;
            if (!v.active || (kind == 2 ? x * x + y * y > v.x * v.x + v.y * v.y : fabsf(x) > fabsf(v.x))) { v.x = x; v.y = y; }
            v.active = 1;
        }
    }
    return v;
}
/* Current and previous-sync values; lastChangeTime is the sample time of a
 * change seen at this sync and 0 otherwise (earlier changes are not kept). */
static int bound_pair(XrSession session, const XrActionStateGetInfo *info, struct bound_value *now, struct bound_value *was) {
    if (input_configured != 3 || !session->has_input3) return 0;
    *now = bound_value(session, info->action, info->subactionPath, &session->last_input3);
    *was = session->has_prev_input3 ? bound_value(session, info->action, info->subactionPath, &session->prev_input3) : (struct bound_value){0};
    return now->active;
}
static XrResult XRAPI_CALL klxr_SyncActions(XrSession session, const XrActionsSyncInfo *info) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    session->input_valid = 0; /* a failed sync cannot leave stale input observable */
    if (!info || info->type != XR_TYPE_ACTIONS_SYNC_INFO || info->next || (info->countActiveActionSets && !info->activeActionSets)) return XR_ERROR_VALIDATION_FAILURE;
    if (!session->attached_count) return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    for (uint32_t i = 0; i < info->countActiveActionSets; ++i) {
        XrActionSet set = info->activeActionSets[i].actionSet;
        if (!valid_action_set_for(set, session->owner)) return XR_ERROR_HANDLE_INVALID;
        if (!attached_action_set(session, set)) return XR_ERROR_ACTIONSET_NOT_ATTACHED;
        if (info->activeActionSets[i].subactionPath != XR_NULL_PATH) return XR_ERROR_PATH_UNSUPPORTED;
    }
    if (!session->running) return XR_ERROR_SESSION_NOT_RUNNING;
    if (session->state != XR_SESSION_STATE_FOCUSED) return XR_SESSION_NOT_FOCUSED;
    if (!input_configured) return XR_ERROR_FUNCTION_UNSUPPORTED;
    if (input_configured == 3) {
        KlNativeInputSample3 sample = {0};
        XrResult result = input_host3.sample(input_host3.context, &sample);
        if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
        if (!sample.sample_id || sample.sample_id < session->last_input_id || sample.sample_time <= 0 || sample.sample_time < session->last_input_time || (sample.sample_id == session->last_input_id && sample.sample_time != session->last_input_time)) return XR_ERROR_VALIDATION_FAILURE;
        if (!hand3_ok(&sample.hand[0]) || !hand3_ok(&sample.hand[1])) return XR_ERROR_VALIDATION_FAILURE;
        if (session->has_input3 && sample.sample_id == session->last_input3.sample_id && memcmp(sample.hand, session->last_input3.hand, sizeof sample.hand)) return XR_ERROR_VALIDATION_FAILURE;
        session->prev_input3 = session->last_input3; session->has_prev_input3 = session->has_input3;
        session->last_input_id = sample.sample_id; session->last_input_time = sample.sample_time; session->last_input3 = sample; session->has_input3 = 1; session->input_valid = 1;
        for (unsigned h = 0; h < 2; ++h) {
            XrPath now = sample.hand[h].controls.connected ? suggested_profile(session->owner, sample.hand[h].profile) : XR_NULL_PATH;
            if (now != session->current_profile[h]) { session->current_profile[h] = now; session->profile_time[h] = sample.sample_time; session->profile_event_pending = 1; }
        }
        return XR_SUCCESS;
    }
    if (input_configured == 2) {
        KlNativeInputSample2 sample = {0};
        XrResult result = input_host2.sample(input_host2.context, &sample);
        if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
        if (!sample.sample_id || sample.sample_id < session->last_input_id || sample.sample_time <= 0 || sample.sample_time < session->last_input_time || (sample.sample_id == session->last_input_id && sample.sample_time != session->last_input_time)) return XR_ERROR_VALIDATION_FAILURE;
        if (!hand2_ok(&sample.hand[0]) || !hand2_ok(&sample.hand[1])) return XR_ERROR_VALIDATION_FAILURE;
        if (session->has_input2 && sample.sample_id == session->last_input2.sample_id && memcmp(sample.hand, session->last_input2.hand, sizeof sample.hand)) return XR_ERROR_VALIDATION_FAILURE;
        session->last_input_id = sample.sample_id; session->last_input_time = sample.sample_time; session->last_input2 = sample; session->has_input2 = 1; session->input_valid = 1;
        return XR_SUCCESS; /* Profile stays unset and action state stays inactive. */
    }
    KlNativeInputSample sample = {0};
    XrResult result = input_host.sample(input_host.context, &sample);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    if (!sample.sample_id || sample.sample_id < session->last_input_id || sample.sample_time <= 0 || sample.sample_time < session->last_input_time || (sample.sample_id == session->last_input_id && sample.sample_time != session->last_input_time) || sample.hand_connected[0] > XR_TRUE || sample.hand_connected[1] > XR_TRUE) return XR_ERROR_VALIDATION_FAILURE;
    if (sample.hand_connected[0] || sample.hand_connected[1]) return XR_ERROR_FEATURE_UNSUPPORTED;
    session->last_input_id = sample.sample_id; session->last_input_time = sample.sample_time; session->input_valid = 1;
    return XR_SUCCESS;
}
static XrResult inactive_state_action(XrSession session, const XrActionStateGetInfo *info, XrActionType type) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!info || info->type != XR_TYPE_ACTION_STATE_GET_INFO || info->next) return XR_ERROR_VALIDATION_FAILURE;
    XrAction action = valid_action_for(session->owner, info->action);
    if (!action) return XR_ERROR_HANDLE_INVALID;
    if (action->type != type) return XR_ERROR_ACTION_TYPE_MISMATCH;
    if (!attached_action_set(session, action->owner)) return XR_ERROR_ACTIONSET_NOT_ATTACHED;
    if (info->subactionPath) {
        if (!owned_path(session->owner, info->subactionPath)) return XR_ERROR_PATH_INVALID;
        int found = 0;
        for (uint32_t i = 0; i < action->subpath_count; ++i) if (action->subpaths[i] == info->subactionPath) found = 1;
        if (!found) return XR_ERROR_PATH_UNSUPPORTED;
    }
    if (!session->input_valid) return XR_ERROR_CALL_ORDER_INVALID;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_GetActionStateBoolean(XrSession session, const XrActionStateGetInfo *info, XrActionStateBoolean *state) {
    if (!state || state->type != XR_TYPE_ACTION_STATE_BOOLEAN || state->next) return XR_ERROR_VALIDATION_FAILURE;
    XrResult result = inactive_state_action(session, info, XR_ACTION_TYPE_BOOLEAN_INPUT);
    if (result != XR_SUCCESS) return result;
    state->currentState = state->changedSinceLastSync = state->isActive = XR_FALSE; state->lastChangeTime = 0;
    struct bound_value now, was;
    if (bound_pair(session, info, &now, &was)) {
        XrBool32 current = now.x >= 0.5f, previous = was.x >= 0.5f;
        state->isActive = XR_TRUE; state->currentState = current;
        state->changedSinceLastSync = was.active && current != previous;
        state->lastChangeTime = state->changedSinceLastSync ? session->last_input3.sample_time : 0;
    }
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_GetActionStateFloat(XrSession session, const XrActionStateGetInfo *info, XrActionStateFloat *state) {
    if (!state || state->type != XR_TYPE_ACTION_STATE_FLOAT || state->next) return XR_ERROR_VALIDATION_FAILURE;
    XrResult result = inactive_state_action(session, info, XR_ACTION_TYPE_FLOAT_INPUT);
    if (result != XR_SUCCESS) return result;
    state->currentState = 0; state->changedSinceLastSync = state->isActive = XR_FALSE; state->lastChangeTime = 0;
    struct bound_value now, was;
    if (bound_pair(session, info, &now, &was)) {
        state->isActive = XR_TRUE; state->currentState = now.x;
        state->changedSinceLastSync = was.active && was.x != now.x;
        state->lastChangeTime = state->changedSinceLastSync ? session->last_input3.sample_time : 0;
    }
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_GetActionStateVector2f(XrSession session, const XrActionStateGetInfo *info, XrActionStateVector2f *state) {
    if (!state || state->type != XR_TYPE_ACTION_STATE_VECTOR2F || state->next) return XR_ERROR_VALIDATION_FAILURE;
    XrResult result = inactive_state_action(session, info, XR_ACTION_TYPE_VECTOR2F_INPUT);
    if (result != XR_SUCCESS) return result;
    state->currentState = (XrVector2f){0}; state->changedSinceLastSync = state->isActive = XR_FALSE; state->lastChangeTime = 0;
    struct bound_value now, was;
    if (bound_pair(session, info, &now, &was)) {
        state->isActive = XR_TRUE; state->currentState = (XrVector2f){ now.x, now.y };
        state->changedSinceLastSync = was.active && (was.x != now.x || was.y != now.y);
        state->lastChangeTime = state->changedSinceLastSync ? session->last_input3.sample_time : 0;
    }
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_GetActionStatePose(XrSession session, const XrActionStateGetInfo *info, XrActionStatePose *state) {
    if (!state || state->type != XR_TYPE_ACTION_STATE_POSE || state->next) return XR_ERROR_VALIDATION_FAILURE;
    XrResult result = inactive_state_action(session, info, XR_ACTION_TYPE_POSE_INPUT);
    if (result != XR_SUCCESS) return result;
    state->isActive = XR_FALSE;
    struct bound_value now, was;
    if (bound_pair(session, info, &now, &was)) state->isActive = XR_TRUE;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_GetCurrentInteractionProfile(XrSession session, XrPath hand, XrInteractionProfileState *state) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!state || state->type != XR_TYPE_INTERACTION_PROFILE_STATE || state->next) return XR_ERROR_VALIDATION_FAILURE;
    const char *path = owned_path(session->owner, hand);
    if (!path) return XR_ERROR_PATH_INVALID;
    if (strcmp(path, "/user/hand/left") && strcmp(path, "/user/hand/right")) return XR_ERROR_PATH_UNSUPPORTED;
    /* Version 3: the profile made current by the last successful sync stays
     * readable after a failed one, so a queued change event can be served. */
    if (input_configured == 3) { state->interactionProfile = session->current_profile[strcmp(path, "/user/hand/left") ? 1 : 0]; return XR_SUCCESS; }
    if (!session->input_valid) return XR_ERROR_CALL_ORDER_INVALID;
    state->interactionProfile = XR_NULL_PATH; return XR_SUCCESS;
}
static int valid_swapchain(XrSwapchain swapchain) {
    for (unsigned i = 0; i < SWAPCHAIN_LIMIT; ++i)
        if (swapchain == &swapchains[i]) return swapchains[i].live && valid_session(swapchains[i].owner);
    return 0;
}
static int session_has_acquired_images(XrSession session) {
    for (unsigned i = 0; i < SWAPCHAIN_LIMIT; ++i)
        if (swapchains[i].live && swapchains[i].owner == session && swapchains[i].fifo_count) return 1;
    return 0;
}
static int instance_has_acquired_images(XrInstance instance) {
    for (unsigned i = 0; i < SESSION_LIMIT; ++i)
        if (sessions[i].live && sessions[i].owner == instance && session_has_acquired_images(&sessions[i])) return 1;
    return 0;
}
static void release_swapchain(struct XrSwapchain_T *sc) {
    for (unsigned i = 0; i < SWAPCHAIN_IMAGES; ++i)
        if (sc->lease[i]) { metal_host.release_image(metal_host.context, sc->lease[i]); sc->lease[i] = NULL; sc->texture[i] = NULL; }
    sc->live = 0;
}
static void release_session(struct XrSession_T *session) {
    for (unsigned i = 0; i < SPACE_LIMIT; ++i)
        if (spaces[i].live && spaces[i].owner == session) spaces[i].live = 0;
    for (unsigned i = 0; i < SWAPCHAIN_LIMIT; ++i)
        if (swapchains[i].live && swapchains[i].owner == session) release_swapchain(&swapchains[i]);
    session->live = 0;
}
static void destroy_instance_sessions(XrInstance instance) {
    for (unsigned i = 0; i < SESSION_LIMIT; ++i)
        if (sessions[i].live && sessions[i].owner == instance) release_session(&sessions[i]);
}
static XrResult graphics(void **device, void **queue) {
    if (!metal_configured) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    *device = *queue = NULL;
    XrResult result = metal_host.get_graphics(metal_host.context, device, queue);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    return *device && *queue ? XR_SUCCESS : XR_ERROR_GRAPHICS_DEVICE_INVALID;
}
static XrResult XRAPI_CALL klxr_GetMetalGraphicsRequirementsKHR(XrInstance instance, XrSystemId system, XrGraphicsRequirementsMetalKHR *requirements) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (!instance->metal_enabled) return XR_ERROR_FUNCTION_UNSUPPORTED;
    if (system != KLXR_SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    if (!requirements || requirements->type != XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR || requirements->next) return XR_ERROR_VALIDATION_FAILURE;
    XrResult result = native_host.hmd_available(native_host.context);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    void *device, *queue;
    result = graphics(&device, &queue);
    if (result != XR_SUCCESS) return result;
    requirements->metalDevice = device;
    instance->metal_queried = 1;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_CreateSession(XrInstance instance, const XrSessionCreateInfo *info, XrSession *session) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (!info || !session || info->type != XR_TYPE_SESSION_CREATE_INFO) return XR_ERROR_VALIDATION_FAILURE;
    *session = XR_NULL_HANDLE;
    if (info->systemId != KLXR_SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    if (!instance->metal_enabled) return XR_ERROR_FEATURE_UNSUPPORTED;
    if (!instance->metal_queried) return XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING;
    XrResult availability = native_host.hmd_available(native_host.context);
    if (availability != XR_SUCCESS) return XR_FAILED(availability) ? availability : XR_ERROR_RUNTIME_FAILURE;
    if (!info->next) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    const XrGraphicsBindingMetalKHR *binding = info->next;
    if (binding->type != XR_TYPE_GRAPHICS_BINDING_METAL_KHR || binding->next || !binding->commandQueue) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    void *device, *queue;
    XrResult result = graphics(&device, &queue);
    if (result != XR_SUCCESS) return result;
    if (binding->commandQueue != queue) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    for (unsigned i = 0; i < SESSION_LIMIT; ++i)
        if (sessions[i].live) return XR_ERROR_LIMIT_REACHED; /* one host surface */
    for (unsigned i = 0; i < SESSION_LIMIT; ++i) {
        if (!sessions[i].used) {
            sessions[i] = (struct XrSession_T){ .used = 1, .live = 1, .owner = instance, .device = device, .queue = queue, .state = XR_SESSION_STATE_IDLE };
            *session = &sessions[i];
            return XR_SUCCESS;
        }
    }
    return XR_ERROR_LIMIT_REACHED;
}
static XrResult XRAPI_CALL klxr_DestroySession(XrSession session) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (session->running || session->frame_ticket) return XR_ERROR_SESSION_RUNNING;
    if (session_has_acquired_images(session)) return XR_ERROR_CALL_ORDER_INVALID;
    release_session(session);
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_EnumerateSwapchainFormats(XrSession session, uint32_t capacity, uint32_t *count, int64_t *formats) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!count || (capacity && !formats)) return XR_ERROR_VALIDATION_FAILURE;
    XrResult result = metal_host.enumerate_formats(metal_host.context, capacity, count, formats);
    return result > XR_SUCCESS ? XR_ERROR_RUNTIME_FAILURE : result;
}
static XrResult XRAPI_CALL klxr_CreateSwapchain(XrSession session, const XrSwapchainCreateInfo *info, XrSwapchain *swapchain) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!info || !swapchain || info->type != XR_TYPE_SWAPCHAIN_CREATE_INFO || info->next) return XR_ERROR_VALIDATION_FAILURE;
    *swapchain = XR_NULL_HANDLE;
    if (!info->width || !info->height || !info->arraySize || info->faceCount != 1 || info->mipCount != 1 || info->sampleCount != 1 || info->createFlags) return XR_ERROR_FEATURE_UNSUPPORTED;
    uint32_t count = 0;
    XrResult result = metal_host.enumerate_formats(metal_host.context, 0, &count, NULL);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    if (!count || count > 128) return XR_ERROR_RUNTIME_FAILURE;
    int64_t formats[128]; uint32_t written = 0;
    result = metal_host.enumerate_formats(metal_host.context, count, &written, formats);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    if (written > count) return XR_ERROR_RUNTIME_FAILURE;
    unsigned found = 0;
    for (uint32_t i = 0; i < written; ++i) if (formats[i] == info->format) found = 1;
    if (!found) return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    struct XrSwapchain_T *sc = NULL;
    for (unsigned i = 0; i < SWAPCHAIN_LIMIT; ++i) if (!swapchains[i].used) { sc = &swapchains[i]; break; }
    if (!sc) return XR_ERROR_LIMIT_REACHED;
    sc->used = 1; sc->owner = session;
    KlNativeMetalImageInfo image = { .format = info->format, .width = info->width, .height = info->height,
        .array_size = info->arraySize, .sample_count = info->sampleCount, .mip_count = info->mipCount, .usage = info->usageFlags };
    sc->info = image;
    for (unsigned i = 0; i < SWAPCHAIN_IMAGES; ++i) {
        result = metal_host.create_image(metal_host.context, &image, &sc->texture[i], &sc->lease[i]);
        if (result != XR_SUCCESS || !sc->texture[i] || !sc->lease[i]) {
            release_swapchain(sc);
            return result != XR_SUCCESS && XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
        }
    }
    sc->live = 1;
    *swapchain = sc;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_DestroySwapchain(XrSwapchain swapchain) {
    if (!valid_swapchain(swapchain)) return XR_ERROR_HANDLE_INVALID;
    if (swapchain->fifo_count) return XR_ERROR_CALL_ORDER_INVALID;
    release_swapchain(swapchain);
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_EnumerateSwapchainImages(XrSwapchain swapchain, uint32_t capacity, uint32_t *count, XrSwapchainImageBaseHeader *images) {
    if (!valid_swapchain(swapchain)) return XR_ERROR_HANDLE_INVALID;
    XrResult result = klxr_two_call(capacity, count, SWAPCHAIN_IMAGES);
    if (result != XR_SUCCESS || !capacity) return result;
    if (!images) return XR_ERROR_VALIDATION_FAILURE;
    XrSwapchainImageMetalKHR *metal = (XrSwapchainImageMetalKHR *)images;
    for (unsigned i = 0; i < SWAPCHAIN_IMAGES; ++i)
        if (metal[i].type != XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR || metal[i].next) return XR_ERROR_VALIDATION_FAILURE;
    for (unsigned i = 0; i < SWAPCHAIN_IMAGES; ++i) metal[i].texture = swapchain->texture[i];
    return XR_SUCCESS;
}

/* FIFO state from Klepton's acquire/wait/release seam, with host-verified
 * completion instead of assuming a submit or one queue wait proves readiness. */
static XrResult XRAPI_CALL klxr_AcquireSwapchainImage(XrSwapchain swapchain, const XrSwapchainImageAcquireInfo *info, uint32_t *index) {
    if (!valid_swapchain(swapchain)) return XR_ERROR_HANDLE_INVALID;
    if (!index || (info && (info->type != XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO || info->next))) return XR_ERROR_VALIDATION_FAILURE;
    if (!image_sync_configured) return XR_ERROR_FUNCTION_UNSUPPORTED;
    if (swapchain->fifo_count == SWAPCHAIN_IMAGES) return XR_ERROR_CALL_ORDER_INVALID;
    unsigned chosen = swapchain->next_index;
    if (swapchain->image_state[chosen]) return XR_ERROR_CALL_ORDER_INVALID;
    if (swapchain->last_valid && swapchain->last_released == chosen) swapchain->last_valid = 0;
    swapchain->image_state[chosen] = 1; /* acquired, not waited */
    swapchain->fifo[swapchain->fifo_count++] = (uint8_t)chosen;
    swapchain->next_index = (chosen + 1) % SWAPCHAIN_IMAGES;
    *index = chosen;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_WaitSwapchainImage(XrSwapchain swapchain, const XrSwapchainImageWaitInfo *info) {
    if (!valid_swapchain(swapchain)) return XR_ERROR_HANDLE_INVALID;
    if (!info || info->type != XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO || info->next || info->timeout < 0) return XR_ERROR_VALIDATION_FAILURE;
    if (!image_sync_configured) return XR_ERROR_FUNCTION_UNSUPPORTED;
    if (!swapchain->fifo_count) return XR_ERROR_CALL_ORDER_INVALID;
    unsigned index = swapchain->fifo[0];
    if (swapchain->image_state[index] != 1) return XR_ERROR_CALL_ORDER_INVALID;
    XrResult result = image_sync_host.wait_available(image_sync_host.context, swapchain->lease[index], info->timeout);
    if (result == XR_TIMEOUT_EXPIRED || XR_FAILED(result)) return result;
    if (result != XR_SUCCESS) return XR_ERROR_RUNTIME_FAILURE;
    swapchain->image_state[index] = 2; /* waited, application may write */
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_ReleaseSwapchainImage(XrSwapchain swapchain, const XrSwapchainImageReleaseInfo *info) {
    if (!valid_swapchain(swapchain)) return XR_ERROR_HANDLE_INVALID;
    if (info && (info->type != XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO || info->next)) return XR_ERROR_VALIDATION_FAILURE;
    if (!image_sync_configured) return XR_ERROR_FUNCTION_UNSUPPORTED;
    if (!swapchain->fifo_count) return XR_ERROR_CALL_ORDER_INVALID;
    unsigned index = swapchain->fifo[0];
    if (swapchain->image_state[index] != 2) return XR_ERROR_CALL_ORDER_INVALID;
    if (swapchain->release_serial == UINT64_MAX) return XR_ERROR_LIMIT_REACHED;
    XrResult result = image_sync_host.complete_writes(image_sync_host.context, swapchain->lease[index]);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    swapchain->last_released = index; swapchain->last_valid = 1; ++swapchain->release_serial;
    XrSession owner = swapchain->owner;
    swapchain->released_frame_id = owner->frame_ticket && owner->frame_begun && !owner->frame_poison ? owner->sample.frame_id : 0;
    swapchain->released_pose_id = swapchain->released_frame_id ? owner->sample.pose_id : 0;
    swapchain->image_state[index] = 0;
    --swapchain->fifo_count;
    memmove(swapchain->fifo, swapchain->fifo + 1, swapchain->fifo_count * sizeof swapchain->fifo[0]);
    return XR_SUCCESS; /* no frame publication */
}

/* Adapted from Klepton's event/session state functions; unlike its synthetic
 * READY this path is driven only by the host's acknowledged lifecycle. */
static XrResult XRAPI_CALL klxr_PollEvent(XrInstance instance, XrEventDataBuffer *buffer) {
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (!buffer || buffer->type != XR_TYPE_EVENT_DATA_BUFFER || buffer->next) return XR_ERROR_VALIDATION_FAILURE;
    XrSession session = XR_NULL_HANDLE;
    for (unsigned i = 0; i < SESSION_LIMIT; ++i)
        if (sessions[i].live && sessions[i].owner == instance) { session = &sessions[i]; break; }
    if (!session || !session_configured) return XR_EVENT_UNAVAILABLE;
    if (!session->event_pending && session->profile_event_pending) {
        XrEventDataInteractionProfileChanged changed = { .type = XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED, .session = session };
        memset(buffer, 0, sizeof *buffer);
        memcpy(buffer, &changed, sizeof changed);
        session->profile_event_pending = 0;
        return XR_SUCCESS;
    }
    if (!session->event_pending) {
        KlNativeSessionEvent event = {0};
        XrResult result = session_host.poll_event(session_host.context, &event);
        if (result == XR_EVENT_UNAVAILABLE) return result;
        if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
        if (event.time <= 0 || event.time < session->event_time) return XR_ERROR_TIME_INVALID;
        XrSessionState next = XR_SESSION_STATE_UNKNOWN;
        switch (event.type) {
            case KL_NATIVE_SESSION_READY:
                if (session->state == XR_SESSION_STATE_IDLE && !session->running) next = XR_SESSION_STATE_READY;
                break;
            case KL_NATIVE_SESSION_VISIBLE:
                if (session->running && (session->state == XR_SESSION_STATE_SYNCHRONIZED || session->state == XR_SESSION_STATE_FOCUSED)) next = XR_SESSION_STATE_VISIBLE;
                break;
            case KL_NATIVE_SESSION_FOCUSED:
                if (session->running && session->state == XR_SESSION_STATE_VISIBLE) next = XR_SESSION_STATE_FOCUSED;
                break;
            case KL_NATIVE_SESSION_STOPPING:
                if (session->running && (session->state == XR_SESSION_STATE_SYNCHRONIZED || session->state == XR_SESSION_STATE_VISIBLE || session->state == XR_SESSION_STATE_FOCUSED)) next = XR_SESSION_STATE_STOPPING;
                break;
            case KL_NATIVE_SESSION_LOSS:
                if (session->state != XR_SESSION_STATE_LOSS_PENDING && session->state != XR_SESSION_STATE_EXITING) next = XR_SESSION_STATE_LOSS_PENDING;
                break;
            case KL_NATIVE_SESSION_EXITING:
                if (session->exit_requested && !session->running && session->state == XR_SESSION_STATE_IDLE) next = XR_SESSION_STATE_EXITING;
                break;
        }
        if (next == XR_SESSION_STATE_UNKNOWN) return XR_ERROR_CALL_ORDER_INVALID;
        session->state = next; session->event_time = event.time; session->event_pending = 1;
    }
    XrEventDataSessionStateChanged event = { .type = XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED,
        .session = session, .state = session->state, .time = session->event_time };
    memset(buffer, 0, sizeof *buffer);
    memcpy(buffer, &event, sizeof event);
    session->event_pending = 0;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_BeginSession(XrSession session, const XrSessionBeginInfo *info) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!info || info->type != XR_TYPE_SESSION_BEGIN_INFO || info->next) return XR_ERROR_VALIDATION_FAILURE;
    if (info->primaryViewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    if (session->running) return XR_ERROR_SESSION_RUNNING;
    if (!session_configured || session->state != XR_SESSION_STATE_READY || session->event_pending) return XR_ERROR_SESSION_NOT_READY;
    XrTime time = 0;
    XrResult result = session_host.begin_session(session_host.context, &time);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    if (time <= 0 || time < session->event_time) {
        /* Host did begin despite violating the timestamp contract. Mark the
         * session lost and keep it running until an acknowledged drain. */
        session->running = 1; session->state = XR_SESSION_STATE_LOSS_PENDING; session->event_pending = 1;
        return XR_ERROR_RUNTIME_FAILURE;
    }
    session->running = 1; session->state = XR_SESSION_STATE_SYNCHRONIZED; session->event_time = time; session->event_pending = 1;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_RequestExitSession(XrSession session) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!session->running) return XR_ERROR_SESSION_NOT_RUNNING;
    if (session->exit_requested) return XR_ERROR_CALL_ORDER_INVALID;
    if (!session_configured || !session_host.request_exit) return XR_ERROR_FUNCTION_UNSUPPORTED;
    XrResult result = session_host.request_exit(session_host.context);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    session->exit_requested = 1; /* host events drive STOPPING and EXITING */
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_EndSession(XrSession session) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!session->running) return XR_ERROR_SESSION_NOT_RUNNING;
    if (!session_configured || (session->state != XR_SESSION_STATE_STOPPING && session->state != XR_SESSION_STATE_LOSS_PENDING) || session->event_pending) return XR_ERROR_SESSION_NOT_STOPPING;
    if (session_has_acquired_images(session) || session->frame_ticket) return XR_ERROR_CALL_ORDER_INVALID;
    XrTime time = 0;
    XrResult result = session_host.end_session(session_host.context, &time);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    if (time <= 0 || time < session->event_time) {
        /* Host confirmed drain, but its timestamp contract failed. Do not
         * report a normal transition or leave a phantom running session. */
        session->running = 0; session->state = XR_SESSION_STATE_LOSS_PENDING; session->event_pending = 1;
        return XR_ERROR_RUNTIME_FAILURE;
    }
    session->running = 0; session->state = XR_SESSION_STATE_IDLE; session->event_time = time; session->event_pending = 1;
    return XR_SUCCESS;
}

/* Reference-space and frame code adapts Klepton's reference-space/pose seam;
 * this provider uses explicit LOCAL and optional host-supplied LOCAL<-STAGE. */
static int valid_space(XrSpace space) {
    for (unsigned i = 0; i < SPACE_LIMIT; ++i)
        if (space == &spaces[i]) return spaces[i].live && valid_session(spaces[i].owner);
    return 0;
}
static XrResult XRAPI_CALL klxr_EnumerateReferenceSpaces(XrSession session, uint32_t capacity, uint32_t *count, XrReferenceSpaceType *out) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    XrResult result = klxr_two_call(capacity, count, 3);
    if (result != XR_SUCCESS || !capacity) return result;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    out[0] = XR_REFERENCE_SPACE_TYPE_VIEW; out[1] = XR_REFERENCE_SPACE_TYPE_LOCAL; out[2] = XR_REFERENCE_SPACE_TYPE_STAGE;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_CreateReferenceSpace(XrSession session, const XrReferenceSpaceCreateInfo *info, XrSpace *space) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!info || !space || info->type != XR_TYPE_REFERENCE_SPACE_CREATE_INFO || info->next) return XR_ERROR_VALIDATION_FAILURE;
    *space = XR_NULL_HANDLE;
    if (info->referenceSpaceType != XR_REFERENCE_SPACE_TYPE_VIEW && info->referenceSpaceType != XR_REFERENCE_SPACE_TYPE_LOCAL && info->referenceSpaceType != XR_REFERENCE_SPACE_TYPE_STAGE) return XR_ERROR_REFERENCE_SPACE_UNSUPPORTED;
    if (!kl_native_pose_valid(info->poseInReferenceSpace)) return XR_ERROR_POSE_INVALID;
    for (unsigned i = 0; i < SPACE_LIMIT; ++i) if (!spaces[i].used) {
        spaces[i] = (struct XrSpace_T){ .used = 1, .live = 1, .owner = session, .type = info->referenceSpaceType, .offset = info->poseInReferenceSpace };
        *space = &spaces[i]; return XR_SUCCESS;
    }
    return XR_ERROR_LIMIT_REACHED;
}
/* Version 3 input only: a pose action's space follows the grip or aim pose of
 * the binding that is current for its hand. */
static XrResult XRAPI_CALL klxr_CreateActionSpace(XrSession session, const XrActionSpaceCreateInfo *info, XrSpace *space) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!info || !space || info->type != XR_TYPE_ACTION_SPACE_CREATE_INFO || info->next) return XR_ERROR_VALIDATION_FAILURE;
    *space = XR_NULL_HANDLE;
    if (input_configured != 3) return XR_ERROR_FUNCTION_UNSUPPORTED;
    XrAction action = valid_action_for(session->owner, info->action);
    if (!action) return XR_ERROR_HANDLE_INVALID;
    if (action->type != XR_ACTION_TYPE_POSE_INPUT) return XR_ERROR_ACTION_TYPE_MISMATCH;
    if (info->subactionPath) {
        if (!owned_path(session->owner, info->subactionPath)) return XR_ERROR_PATH_INVALID;
        int found = 0;
        for (uint32_t i = 0; i < action->subpath_count; ++i) if (action->subpaths[i] == info->subactionPath) found = 1;
        if (!found) return XR_ERROR_PATH_UNSUPPORTED;
    }
    if (!kl_native_pose_valid(info->poseInActionSpace)) return XR_ERROR_POSE_INVALID;
    for (unsigned i = 0; i < SPACE_LIMIT; ++i) if (!spaces[i].used) {
        spaces[i] = (struct XrSpace_T){ .used = 1, .live = 1, .owner = session, .type = KL_ACTION_SPACE, .offset = info->poseInActionSpace,
            .action = action, .subaction = info->subactionPath };
        *space = &spaces[i]; return XR_SUCCESS;
    }
    return XR_ERROR_LIMIT_REACHED;
}
static int local_from_action_space(XrSpace space, XrPosef *out, XrSpaceLocationFlags *flags) {
    XrSession s = space->owner;
    *flags = 0;
    if (input_configured != 3 || !s->input_valid || !s->has_input3 || !valid_action_for(s->owner, space->action)) return 0;
    const char *sub = space->subaction ? owned_path(s->owner, space->subaction) : NULL;
    for (unsigned h = 0; h < 2; ++h) {
        if (sub && strcmp(sub, hand_names[h])) continue;
        const KlNativeInputHand3 *hand = &s->last_input3.hand[h];
        if (!hand->controls.connected || !s->current_profile[h]) continue;
        for (unsigned i = 0; i < BINDING_LIMIT; ++i) {
            const struct native_binding *b = &bindings[i];
            if (b->owner != s->owner || b->action != space->action || b->profile != s->current_profile[h]) continue;
            const char *c = hand_component(s->owner, b->path, h);
            int grip = c && !strcmp(c, "input/grip/pose"), aim = c && !strcmp(c, "input/aim/pose");
            if (!grip && !aim) continue;
            XrBool32 tracked = grip ? hand->controls.grip_position_tracked : hand->controls.aim_position_tracked;
            *flags = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT |
                (tracked ? XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT | XR_SPACE_LOCATION_POSITION_TRACKED_BIT : 0);
            *out = kl_native_pose_compose(grip ? hand->local_from_grip : hand->local_from_aim, space->offset);
            return 1;
        }
    }
    return 0;
}
static XrResult XRAPI_CALL klxr_DestroySpace(XrSpace space) {
    if (!valid_space(space)) return XR_ERROR_HANDLE_INVALID;
    space->live = 0; return XR_SUCCESS;
}
/* Output is local_from_space. Invalid tracking returns zero flags; it never
 * substitutes an identity pose or guesses a floor. */
static int local_from_space(XrSpace space, const KlNativeFrameSample *sample, XrPosef *out, XrSpaceLocationFlags *flags) {
    XrPosef base = { .orientation = {0,0,0,1}, .position = {0,0,0} };
    if (space->type == KL_ACTION_SPACE) return local_from_action_space(space, out, flags);
    *flags = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
    if (space->type == XR_REFERENCE_SPACE_TYPE_STAGE) {
        if (!sample->stage_valid) { *flags = 0; return 0; }
        base = sample->local_from_stage;
    } else if (space->type == XR_REFERENCE_SPACE_TYPE_VIEW) {
        *flags = sample->head_location_flags;
        if ((*flags & (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT)) !=
            (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT)) { *flags = 0; return 0; }
        base = sample->local_from_head;
    }
    *out = kl_native_pose_compose(base, space->offset);
    return 1;
}
static XrResult XRAPI_CALL klxr_LocateSpace(XrSpace space, XrSpace base_space, XrTime time, XrSpaceLocation *location) {
    if (!valid_space(space) || !valid_space(base_space)) return XR_ERROR_HANDLE_INVALID;
    if (space->owner != base_space->owner) return XR_ERROR_HANDLE_INVALID;
    if (!location || location->type != XR_TYPE_SPACE_LOCATION) return XR_ERROR_VALIDATION_FAILURE;
    XrSpaceVelocity *velocity = location->next;
    if (velocity && (velocity->type != XR_TYPE_SPACE_VELOCITY || velocity->next)) return XR_ERROR_VALIDATION_FAILURE;
    XrSession session = space->owner;
    if (!session->frame_ticket || session->frame_poison || time != session->sample.predicted_display_time) return XR_ERROR_TIME_INVALID;
    /* No measured velocity in the frame host contract. Never infer it from
     * neighboring snapshots or claim a valid zero-velocity observation. */
    if (velocity) {
        velocity->velocityFlags = 0;
        velocity->linearVelocity = (XrVector3f){0};
        velocity->angularVelocity = (XrVector3f){0};
    }
    XrPosef a, b; XrSpaceLocationFlags fa, fb;
    if (!local_from_space(space, &session->sample, &a, &fa) || !local_from_space(base_space, &session->sample, &b, &fb)) { location->locationFlags = 0; return XR_SUCCESS; }
    location->pose = kl_native_pose_relative(b, a);
    location->locationFlags = fa & fb;
    return XR_SUCCESS;
}
static int valid_sample(const KlNativeFrameSample *sample, XrSession session) {
    const XrSpaceLocationFlags valid = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
    const XrSpaceLocationFlags tracked = XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT | XR_SPACE_LOCATION_POSITION_TRACKED_BIT;
    if (!sample->ticket || !sample->frame_id || sample->frame_id <= session->last_frame_id || !sample->pose_id || sample->predicted_display_time <= session->last_predicted_time || sample->predicted_display_period <= 0 || sample->should_render > XR_TRUE || sample->stage_valid > XR_TRUE) return 0;
    if (sample->head_location_flags & ~(valid | tracked)) return 0;
    if ((sample->head_location_flags & XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT) && !(sample->head_location_flags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT)) return 0;
    if ((sample->head_location_flags & XR_SPACE_LOCATION_POSITION_TRACKED_BIT) && !(sample->head_location_flags & XR_SPACE_LOCATION_POSITION_VALID_BIT)) return 0;
    if (sample->head_location_flags && !kl_native_pose_valid(sample->local_from_head)) return 0;
    if (sample->stage_valid && !kl_native_pose_valid(sample->local_from_stage)) return 0;
    if (sample->should_render && (sample->head_location_flags & valid) != valid) return 0;
    for (unsigned i = 0; i < 2; ++i) {
        XrFovf f = sample->fov[i];
        if (!kl_native_pose_valid(sample->head_from_eye[i]) || !isfinite(f.angleLeft) || !isfinite(f.angleRight) || !isfinite(f.angleUp) || !isfinite(f.angleDown) || f.angleLeft >= f.angleRight || f.angleDown >= f.angleUp) return 0;
    }
    return 1;
}
static XrResult cancel_ticket(XrSession session) {
    if (!session->frame_ticket) return XR_SUCCESS;
    if (!session->sample.ticket) return XR_ERROR_RUNTIME_FAILURE;
    XrResult result = frame_host.cancel_frame(frame_host.context, session->sample.ticket);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    session->frame_ticket = session->frame_begun = session->frame_poison = 0;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_WaitFrame(XrSession session, const XrFrameWaitInfo *info, XrFrameState *state) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if ((info && (info->type != XR_TYPE_FRAME_WAIT_INFO || info->next)) || !state || state->type != XR_TYPE_FRAME_STATE || state->next) return XR_ERROR_VALIDATION_FAILURE;
    if (!session->running) return XR_ERROR_SESSION_NOT_RUNNING;
    if (!frame_configured) return XR_ERROR_FUNCTION_UNSUPPORTED;
    if (session->frame_ticket) {
        if (!session->frame_poison) return XR_ERROR_CALL_ORDER_INVALID;
        XrResult cancel = cancel_ticket(session);
        if (cancel != XR_SUCCESS) return cancel;
    }
    KlNativeFrameSample sample = {0};
    XrResult result = frame_host.wait_frame(frame_host.context, &sample);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    session->sample = sample; session->frame_ticket = 1;
    if (!valid_sample(&sample, session)) {
        session->frame_poison = 1;
        if (sample.ticket) (void)cancel_ticket(session);
        return XR_ERROR_RUNTIME_FAILURE;
    }
    session->last_frame_id = sample.frame_id; session->last_predicted_time = sample.predicted_display_time;
    state->predictedDisplayTime = sample.predicted_display_time; state->predictedDisplayPeriod = sample.predicted_display_period;
    state->shouldRender = sample.should_render;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_BeginFrame(XrSession session, const XrFrameBeginInfo *info) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (info && (info->type != XR_TYPE_FRAME_BEGIN_INFO || info->next)) return XR_ERROR_VALIDATION_FAILURE;
    if (!session->running) return XR_ERROR_SESSION_NOT_RUNNING;
    if (!session->frame_ticket || session->frame_poison || session->frame_begun) return XR_ERROR_CALL_ORDER_INVALID;
    session->frame_begun = 1; return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_EndFrame(XrSession session, const XrFrameEndInfo *info) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!info || info->type != XR_TYPE_FRAME_END_INFO || info->next) return XR_ERROR_VALIDATION_FAILURE;
    if (!session->running) return XR_ERROR_SESSION_NOT_RUNNING;
    if (!session->frame_ticket || session->frame_poison || !session->frame_begun) return XR_ERROR_CALL_ORDER_INVALID;
    if (info->displayTime != session->sample.predicted_display_time) return XR_ERROR_TIME_INVALID;
    if (info->environmentBlendMode != XR_ENVIRONMENT_BLEND_MODE_OPAQUE) return XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED;
    if (!info->layerCount) return cancel_ticket(session);
    if (!session->sample.should_render || !info->layers || info->layerCount != 1) return XR_ERROR_FEATURE_UNSUPPORTED;
    const XrCompositionLayerBaseHeader *base = info->layers[0];
    if (!base || base->type != XR_TYPE_COMPOSITION_LAYER_PROJECTION || base->next || base->layerFlags) return XR_ERROR_LAYER_INVALID;
    const XrCompositionLayerProjection *projection = (const XrCompositionLayerProjection *)base;
    if (!valid_space(projection->space) || projection->space->owner != session) return XR_ERROR_HANDLE_INVALID;
    if (projection->viewCount != 2 || !projection->views) return XR_ERROR_LAYER_INVALID;
    XrPosef local_from_layer; XrSpaceLocationFlags flags;
    if (!local_from_space(projection->space, &session->sample, &local_from_layer, &flags)) return XR_ERROR_LAYER_INVALID;
    KlNativeFramePair pair = { .sample = session->sample };
    XrSwapchain used[2];
    for (unsigned i = 0; i < 2; ++i) {
        const XrCompositionLayerProjectionView *view = &projection->views[i];
        XrSwapchain sc = view->subImage.swapchain;
        if (view->type != XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW || view->next || !valid_swapchain(sc) || sc->owner != session) return XR_ERROR_LAYER_INVALID;
        if (!sc->last_valid || sc->release_serial <= sc->published_serial ||
            sc->released_frame_id != session->sample.frame_id || sc->released_pose_id != session->sample.pose_id) return XR_ERROR_CALL_ORDER_INVALID;
        const XrRect2Di rect = view->subImage.imageRect;
        if (rect.offset.x < 0 || rect.offset.y < 0 || rect.extent.width <= 0 || rect.extent.height <= 0 ||
            (uint64_t)(uint32_t)rect.offset.x + (uint32_t)rect.extent.width > sc->info.width ||
            (uint64_t)(uint32_t)rect.offset.y + (uint32_t)rect.extent.height > sc->info.height ||
            view->subImage.imageArrayIndex >= sc->info.array_size) return XR_ERROR_SWAPCHAIN_RECT_INVALID;
        XrFovf f = view->fov;
        if (!kl_native_pose_valid(view->pose) || !isfinite(f.angleLeft) || !isfinite(f.angleRight) || !isfinite(f.angleUp) || !isfinite(f.angleDown) || f.angleLeft >= f.angleRight || f.angleDown >= f.angleUp) return XR_ERROR_LAYER_INVALID;
        unsigned index = sc->last_released;
        pair.eye[i] = (KlNativeFrameEye){ .texture = sc->texture[index], .image_lease = sc->lease[index], .format = sc->info.format,
            .array_layer = view->subImage.imageArrayIndex, .rect = rect,
            .local_from_render_eye = kl_native_pose_compose(local_from_layer, view->pose), .fov = f };
        used[i] = sc;
    }
    if (pair.eye[0].texture == pair.eye[1].texture && pair.eye[0].array_layer == pair.eye[1].array_layer) {
        XrRect2Di a = pair.eye[0].rect, b = pair.eye[1].rect;
        int64_t ax = (int64_t)a.offset.x + a.extent.width, ay = (int64_t)a.offset.y + a.extent.height;
        int64_t bx = (int64_t)b.offset.x + b.extent.width, by = (int64_t)b.offset.y + b.extent.height;
        if (a.offset.x < bx && b.offset.x < ax && a.offset.y < by && b.offset.y < ay) return XR_ERROR_LAYER_INVALID;
    }
    XrResult result = frame_host.publish_pair(frame_host.context, &pair);
    if (result != XR_SUCCESS) return XR_FAILED(result) ? result : XR_ERROR_RUNTIME_FAILURE;
    used[0]->published_serial = used[0]->release_serial;
    used[1]->published_serial = used[1]->release_serial;
    session->frame_ticket = session->frame_begun = session->frame_poison = 0;
    return XR_SUCCESS;
}
static XrResult XRAPI_CALL klxr_LocateViews(XrSession session, const XrViewLocateInfo *info, XrViewState *state, uint32_t capacity, uint32_t *count, XrView *views) {
    if (!valid_session(session)) return XR_ERROR_HANDLE_INVALID;
    if (!info || info->type != XR_TYPE_VIEW_LOCATE_INFO || info->next || !state || state->type != XR_TYPE_VIEW_STATE || state->next) return XR_ERROR_VALIDATION_FAILURE;
    if (info->viewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    if (!valid_space(info->space) || info->space->owner != session) return XR_ERROR_HANDLE_INVALID;
    if (!session->frame_ticket || session->frame_poison || info->displayTime != session->sample.predicted_display_time) return XR_ERROR_TIME_INVALID;
    XrResult result = klxr_two_call(capacity, count, 2);
    if (result != XR_SUCCESS || !capacity) return result;
    if (!views) return XR_ERROR_VALIDATION_FAILURE;
    for (unsigned i = 0; i < 2; ++i) if (views[i].type != XR_TYPE_VIEW || views[i].next) return XR_ERROR_VALIDATION_FAILURE;
    XrPosef base; XrSpaceLocationFlags base_flags;
    const KlNativeFrameSample *sample = &session->sample;
    const XrSpaceLocationFlags valid = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
    if (!local_from_space(info->space, sample, &base, &base_flags) || (sample->head_location_flags & valid) != valid) { state->viewStateFlags = 0; return XR_SUCCESS; }
    for (unsigned i = 0; i < 2; ++i) {
        XrPosef eye = kl_native_pose_compose(sample->local_from_head, sample->head_from_eye[i]);
        views[i].pose = kl_native_pose_relative(base, eye); views[i].fov = sample->fov[i];
    }
    state->viewStateFlags = XR_VIEW_STATE_ORIENTATION_VALID_BIT | XR_VIEW_STATE_POSITION_VALID_BIT;
    if (sample->head_location_flags & XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT) state->viewStateFlags |= XR_VIEW_STATE_ORIENTATION_TRACKED_BIT;
    if (sample->head_location_flags & XR_SPACE_LOCATION_POSITION_TRACKED_BIT) state->viewStateFlags |= XR_VIEW_STATE_POSITION_TRACKED_BIT;
    return XR_SUCCESS;
}

#include "refusals.inc"

/* Derived from Klepton klxr_GetInstanceProcAddr and klxr_install, upstream
 * lines 718-739 and 6613-6753. Only implemented entries are exposed; unknown
 * calls return an error instead of the upstream aborting placeholder. */
XRAPI_ATTR XrResult XRAPI_CALL kl_native_get_instance_proc_addr(XrInstance instance, const char *name, PFN_xrVoidFunction *function) {
    if (!function || !name) return XR_ERROR_VALIDATION_FAILURE;
    *function = NULL;
    if (instance != XR_NULL_HANDLE && !valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
#define GLOBAL(n, f) if (!strcmp(name, n)) { *function = (PFN_xrVoidFunction)(f); return XR_SUCCESS; }
    GLOBAL("xrCreateInstance", klxr_CreateInstance)
    GLOBAL("xrEnumerateApiLayerProperties", klxr_EnumerateApiLayerProperties)
    GLOBAL("xrEnumerateInstanceExtensionProperties", klxr_EnumerateInstanceExtensionProperties)
#undef GLOBAL
    if (!valid_instance(instance)) return XR_ERROR_HANDLE_INVALID;
#define INSTANCE(n, f) if (!strcmp(name, n)) { *function = (PFN_xrVoidFunction)(f); return XR_SUCCESS; }
    INSTANCE("xrGetInstanceProcAddr", kl_native_get_instance_proc_addr)
    INSTANCE("xrDestroyInstance", klxr_DestroyInstance)
    INSTANCE("xrGetSystem", klxr_GetSystem)
    INSTANCE("xrGetVxStaticViewGeometry", klxr_GetVxStaticViewGeometry)
    INSTANCE("xrGetInstanceProperties", klxr_GetInstanceProperties)
    INSTANCE("xrGetSystemProperties", klxr_GetSystemProperties)
    INSTANCE("xrStringToPath", klxr_StringToPath)
    INSTANCE("xrPathToString", klxr_PathToString)
    INSTANCE("xrCreateActionSet", klxr_CreateActionSet)
    INSTANCE("xrDestroyActionSet", klxr_DestroyActionSet)
    INSTANCE("xrCreateAction", klxr_CreateAction)
    INSTANCE("xrDestroyAction", klxr_DestroyAction)
    INSTANCE("xrSuggestInteractionProfileBindings", klxr_SuggestInteractionProfileBindings)
    INSTANCE("xrEnumerateViewConfigurations", klxr_EnumerateViewConfigurations)
    INSTANCE("xrGetViewConfigurationProperties", klxr_GetViewConfigurationProperties)
    INSTANCE("xrEnumerateViewConfigurationViews", klxr_EnumerateViewConfigurationViews)
    INSTANCE("xrEnumerateEnvironmentBlendModes", klxr_EnumerateEnvironmentBlendModes)
    INSTANCE("xrEnumerateReferenceSpaces", klxr_EnumerateReferenceSpaces)
    INSTANCE("xrCreateReferenceSpace", klxr_CreateReferenceSpace)
    INSTANCE("xrCreateActionSpace", klxr_CreateActionSpace)
    INSTANCE("xrDestroySpace", klxr_DestroySpace)
    INSTANCE("xrLocateSpace", klxr_LocateSpace)
    INSTANCE("xrWaitFrame", klxr_WaitFrame)
    INSTANCE("xrBeginFrame", klxr_BeginFrame)
    INSTANCE("xrEndFrame", klxr_EndFrame)
    INSTANCE("xrLocateViews", klxr_LocateViews)
    INSTANCE("xrPollEvent", klxr_PollEvent)
    INSTANCE("xrBeginSession", klxr_BeginSession)
    INSTANCE("xrEndSession", klxr_EndSession)
    INSTANCE("xrRequestExitSession", klxr_RequestExitSession)
    INSTANCE("xrCreateSession", klxr_CreateSession)
    INSTANCE("xrDestroySession", klxr_DestroySession)
    INSTANCE("xrAttachSessionActionSets", klxr_AttachSessionActionSets)
    INSTANCE("xrSyncActions", klxr_SyncActions)
    INSTANCE("xrGetCurrentInteractionProfile", klxr_GetCurrentInteractionProfile)
    INSTANCE("xrGetActionStateBoolean", klxr_GetActionStateBoolean)
    INSTANCE("xrGetActionStateFloat", klxr_GetActionStateFloat)
    INSTANCE("xrGetActionStateVector2f", klxr_GetActionStateVector2f)
    INSTANCE("xrGetActionStatePose", klxr_GetActionStatePose)
    INSTANCE("xrEnumerateSwapchainFormats", klxr_EnumerateSwapchainFormats)
    INSTANCE("xrCreateSwapchain", klxr_CreateSwapchain)
    INSTANCE("xrDestroySwapchain", klxr_DestroySwapchain)
    INSTANCE("xrEnumerateSwapchainImages", klxr_EnumerateSwapchainImages)
    INSTANCE("xrAcquireSwapchainImage", klxr_AcquireSwapchainImage)
    INSTANCE("xrWaitSwapchainImage", klxr_WaitSwapchainImage)
    INSTANCE("xrReleaseSwapchainImage", klxr_ReleaseSwapchainImage)
    if (!strcmp(name, "xrGetMetalGraphicsRequirementsKHR")) {
        if (!instance->metal_enabled) return XR_ERROR_FUNCTION_UNSUPPORTED;
        *function = (PFN_xrVoidFunction)klxr_GetMetalGraphicsRequirementsKHR;
        return XR_SUCCESS;
    }
#include "refusal_dispatch.inc"
#undef INSTANCE
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}
