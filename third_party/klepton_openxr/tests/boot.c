#include "klepton_native.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static XrResult available(void *p) { return *(int *)p ? XR_SUCCESS : XR_ERROR_FORM_FACTOR_UNAVAILABLE; }
static XrResult get_properties(void *p, XrSystemProperties *out) {
    int mode = *(int *)p;
    if (mode == 3) return XR_ERROR_RUNTIME_FAILURE;
    strcpy(out->systemName, "Owned mock display");
    out->vendorId = 42;
    out->graphicsProperties.maxSwapchainImageWidth = 2048;
    out->graphicsProperties.maxSwapchainImageHeight = 2048;
    out->graphicsProperties.maxLayerCount = 4;
    out->trackingProperties.orientationTracking = XR_TRUE;
    out->trackingProperties.positionTracking = mode == 2 ? 2 : XR_FALSE;
    return XR_SUCCESS;
}
#define GET(type, var, instance, name) \
    PFN_xrVoidFunction raw_##var = NULL; \
    assert(kl_native_get_instance_proc_addr(instance, name, &raw_##var) == XR_SUCCESS); \
    type var = (type)raw_##var; assert(var != NULL)
int main(void) {
    int present = 0;
    KlNativeHost host = { 1, sizeof(host), &present, available, NULL };
    assert(kl_native_configure(NULL) == XR_ERROR_VALIDATION_FAILURE);
    GET(PFN_xrCreateInstance, create, XR_NULL_HANDLE, "xrCreateInstance");
    GET(PFN_xrEnumerateInstanceExtensionProperties, extensions, XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties");
    GET(PFN_xrEnumerateApiLayerProperties, layers, XR_NULL_HANDLE, "xrEnumerateApiLayerProperties");
    uint32_t n = 99;
    assert(extensions(NULL, 0, &n, NULL) == XR_SUCCESS && n == 0);
    assert(layers(0, &n, NULL) == XR_SUCCESS && n == 0);
    assert(extensions("missing", 0, &n, NULL) == XR_ERROR_API_LAYER_NOT_PRESENT);
    assert(layers(0, NULL, NULL) == XR_ERROR_VALIDATION_FAILURE);
    XrInstanceCreateInfo ci = { .type = XR_TYPE_INSTANCE_CREATE_INFO };
    ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    XrInstance instance = XR_NULL_HANDLE;
    assert(create(&ci, &instance) == XR_ERROR_RUNTIME_UNAVAILABLE && instance == XR_NULL_HANDLE);
    assert(kl_native_configure(&host) == XR_SUCCESS);
    const char *bad_extension = "XR_FAKE_missing";
    ci.enabledExtensionNames = &bad_extension;
    ci.enabledExtensionCount = 1;
    assert(create(&ci, &instance) == XR_ERROR_EXTENSION_NOT_PRESENT && instance == XR_NULL_HANDLE);
    ci.enabledExtensionCount = 0;
    ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 1, 0);
    assert(create(&ci, &instance) == XR_ERROR_API_VERSION_UNSUPPORTED);
    ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    assert(create(&ci, &instance) == XR_SUCCESS && instance != XR_NULL_HANDLE);
    assert(kl_native_configure(&host) == XR_ERROR_CALL_ORDER_INVALID);
    GET(PFN_xrDestroyInstance, destroy, instance, "xrDestroyInstance");
    GET(PFN_xrGetSystem, system, instance, "xrGetSystem");
    GET(PFN_xrCreateSession, session, instance, "xrCreateSession");
    GET(PFN_xrGetInstanceProperties, instance_properties, instance, "xrGetInstanceProperties");
    GET(PFN_xrGetSystemProperties, properties, instance, "xrGetSystemProperties");
    GET(PFN_xrCreateActionSet, create_set, instance, "xrCreateActionSet");
    GET(PFN_xrDestroyActionSet, destroy_set, instance, "xrDestroyActionSet");
    XrActionSetCreateInfo set_info = { .type = XR_TYPE_ACTION_SET_CREATE_INFO };
    XrActionSet set = XR_NULL_HANDLE, set2 = XR_NULL_HANDLE;
    assert(create_set(instance, &set_info, &set) == XR_ERROR_NAME_INVALID);
    strcpy(set_info.actionSetName, "gameplay");
    assert(create_set(instance, &set_info, &set) == XR_ERROR_LOCALIZED_NAME_INVALID);
    strcpy(set_info.localizedActionSetName, "Gameplay");
    assert(create_set(instance, &set_info, &set) == XR_SUCCESS);
    assert(create_set(instance, &set_info, &set2) == XR_ERROR_NAME_DUPLICATED);
    strcpy(set_info.actionSetName, "menus");
    assert(create_set(instance, &set_info, &set2) == XR_ERROR_LOCALIZED_NAME_DUPLICATED);
    strcpy(set_info.actionSetName, "bad/name");
    assert(create_set(instance, &set_info, &set2) == XR_ERROR_PATH_FORMAT_INVALID);
    assert(destroy_set((XrActionSet)(uintptr_t)7) == XR_ERROR_HANDLE_INVALID);
    assert(destroy_set(set) == XR_SUCCESS);
    assert(destroy_set(set) == XR_ERROR_HANDLE_INVALID);
    strcpy(set_info.actionSetName, "gameplay");
    assert(create_set(instance, &set_info, &set2) == XR_SUCCESS && set2 != set);
    GET(PFN_xrStringToPath, to_path, instance, "xrStringToPath");
    GET(PFN_xrPathToString, to_string, instance, "xrPathToString");
    XrPath left = XR_NULL_PATH, repeated = XR_NULL_PATH;
    assert(to_path(instance, "/user/hand/left", &left) == XR_SUCCESS && left != XR_NULL_PATH);
    assert(to_path(instance, "/user/hand/left", &repeated) == XR_SUCCESS && repeated == left);
    GET(PFN_xrCreateAction, create_action, instance, "xrCreateAction");
    GET(PFN_xrDestroyAction, destroy_action, instance, "xrDestroyAction");
    XrActionCreateInfo ai = { .type = XR_TYPE_ACTION_CREATE_INFO, .actionType = XR_ACTION_TYPE_POSE_INPUT,
        .countSubactionPaths = 1, .subactionPaths = &left };
    strcpy(ai.actionName, "grip-pose"); strcpy(ai.localizedActionName, "Grip Pose");
    XrAction action = XR_NULL_HANDLE, other = XR_NULL_HANDLE;
    assert(create_action((XrActionSet)(uintptr_t)7, &ai, &action) == XR_ERROR_HANDLE_INVALID);
    assert(create_action(set2, &ai, &action) == XR_SUCCESS && action != XR_NULL_HANDLE);
    assert(create_action(set2, &ai, &other) == XR_ERROR_NAME_DUPLICATED);
    assert(destroy_action((XrAction)(uintptr_t)7) == XR_ERROR_HANDLE_INVALID);
    assert(destroy_action(action) == XR_SUCCESS);
    assert(destroy_action(action) == XR_ERROR_HANDLE_INVALID);
    XrPath bad = UINT64_MAX; ai.subactionPaths = &bad;
    assert(create_action(set2, &ai, &other) == XR_ERROR_PATH_INVALID);
    XrPath unsupported = XR_NULL_PATH;
    assert(to_path(instance, "/user/head", &unsupported) == XR_SUCCESS);
    ai.subactionPaths = &unsupported;
    assert(create_action(set2, &ai, &other) == XR_ERROR_PATH_UNSUPPORTED);
    XrPath duplicate_paths[] = { left, left };
    ai.subactionPaths = duplicate_paths; ai.countSubactionPaths = 2;
    assert(create_action(set2, &ai, &other) == XR_ERROR_PATH_INVALID);
    ai.subactionPaths = NULL;
    assert(create_action(set2, &ai, &other) == XR_ERROR_VALIDATION_FAILURE);
    ai.countSubactionPaths = 1;
    ai.subactionPaths = &left; ai.actionType = (XrActionType)999;
    assert(create_action(set2, &ai, &other) == XR_ERROR_FEATURE_UNSUPPORTED);
    XrActionType supported_types[] = { XR_ACTION_TYPE_FLOAT_INPUT, XR_ACTION_TYPE_VECTOR2F_INPUT, XR_ACTION_TYPE_VIBRATION_OUTPUT };
    for (unsigned i = 0; i < sizeof supported_types / sizeof supported_types[0]; ++i) {
        ai.actionType = supported_types[i];
        assert(create_action(set2, &ai, &other) == XR_SUCCESS);
        assert(destroy_action(other) == XR_SUCCESS);
        assert(destroy_action(other) == XR_ERROR_HANDLE_INVALID);
    }
    ai.actionType = XR_ACTION_TYPE_BOOLEAN_INPUT;
    assert(create_action(set2, &ai, &other) == XR_SUCCESS && other != action);
    assert(destroy_action(other) == XR_SUCCESS);
    ai.actionType = XR_ACTION_TYPE_POSE_INPUT;
    assert(create_action(set2, &ai, &other) == XR_SUCCESS && other != action);
    assert(destroy_set(set2) == XR_SUCCESS);
    assert(destroy_action(other) == XR_ERROR_HANDLE_INVALID);
    assert(to_path(instance, "/user//left", &repeated) == XR_ERROR_PATH_FORMAT_INVALID);
    assert(to_path(instance, "/user/../left", &repeated) == XR_ERROR_PATH_FORMAT_INVALID);
    assert(to_path(instance, "/user/Left", &repeated) == XR_ERROR_PATH_FORMAT_INVALID);
    uint32_t path_size = 0;
    assert(to_string(instance, left, 0, &path_size, NULL) == XR_SUCCESS && path_size == 16);
    char path_buffer[32];
    assert(to_string(instance, left, 4, &path_size, path_buffer) == XR_ERROR_SIZE_INSUFFICIENT && path_size == 16);
    assert(to_string(instance, left, sizeof(path_buffer), &path_size, path_buffer) == XR_SUCCESS && !strcmp(path_buffer, "/user/hand/left"));
    XrInstanceProperties ip = { .type = XR_TYPE_INSTANCE_PROPERTIES };
    assert(instance_properties(instance, &ip) == XR_SUCCESS && strstr(ip.runtimeName, "partial"));
    PFN_xrVoidFunction missing = (PFN_xrVoidFunction)(uintptr_t)1;
    assert(kl_native_get_instance_proc_addr(instance, "xrGetMetalGraphicsRequirementsKHR", &missing) == XR_ERROR_FUNCTION_UNSUPPORTED && missing == NULL);
    assert(kl_native_get_instance_proc_addr((XrInstance)(uintptr_t)7, "xrGetSystem", &missing) == XR_ERROR_HANDLE_INVALID && missing == NULL);
    XrSystemGetInfo si = { .type = XR_TYPE_SYSTEM_GET_INFO, .formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY };
    XrSystemId system_id = XR_NULL_SYSTEM_ID;
    assert(system(instance, &si, &system_id) == XR_ERROR_FORM_FACTOR_UNAVAILABLE && system_id == XR_NULL_SYSTEM_ID);
    present = 1;
    assert(system(instance, &si, &system_id) == XR_SUCCESS && system_id != XR_NULL_SYSTEM_ID);
    XrSystemProperties sp = { .type = XR_TYPE_SYSTEM_PROPERTIES };
    assert(properties(instance, system_id, &sp) == XR_ERROR_FUNCTION_UNSUPPORTED);
    si.formFactor = XR_FORM_FACTOR_HANDHELD_DISPLAY;
    assert(system(instance, &si, &system_id) == XR_ERROR_FORM_FACTOR_UNSUPPORTED);
    assert(kl_native_get_instance_proc_addr((XrInstance)(uintptr_t)7, "xrCreateInstance", &missing) == XR_ERROR_HANDLE_INVALID);
    XrSessionCreateInfo sci = { .type = XR_TYPE_SESSION_CREATE_INFO, .systemId = system_id };
    XrSession sess = (XrSession)(uintptr_t)1;
    assert(session(instance, &sci, &sess) == XR_ERROR_FEATURE_UNSUPPORTED && sess == XR_NULL_HANDLE);
    assert(create_set(instance, &set_info, &set2) == XR_SUCCESS);
    assert(create_action(set2, &ai, &other) == XR_SUCCESS);
    assert(destroy(instance) == XR_SUCCESS);
    assert(destroy_action(other) == XR_ERROR_HANDLE_INVALID);
    assert(destroy_set(set2) == XR_ERROR_HANDLE_INVALID);
    assert(destroy(instance) == XR_ERROR_HANDLE_INVALID);
    XrInstance fresh = XR_NULL_HANDLE;
    assert(create(&ci, &fresh) == XR_SUCCESS && fresh != instance);
    assert(to_string(fresh, left, 0, &path_size, NULL) == XR_ERROR_PATH_INVALID);
    assert(system(instance, &si, &system_id) == XR_ERROR_HANDLE_INVALID);
    assert(destroy(fresh) == XR_SUCCESS);
    host.system_properties = get_properties;
    assert(kl_native_configure(&host) == XR_SUCCESS);
    assert(create(&ci, &fresh) == XR_SUCCESS);
    GET(PFN_xrGetSystemProperties, properties2, fresh, "xrGetSystemProperties");
    sp = (XrSystemProperties){ .type = XR_TYPE_SYSTEM_PROPERTIES };
    assert(properties2(fresh, 1, &sp) == XR_SUCCESS && sp.vendorId == 42 && sp.trackingProperties.positionTracking == XR_FALSE);
    present = 2;
    assert(properties2(fresh, 1, &sp) == XR_ERROR_RUNTIME_FAILURE);
    present = 3;
    assert(properties2(fresh, 1, &sp) == XR_ERROR_RUNTIME_FAILURE);
    present = 0;
    assert(properties2(fresh, 1, &sp) == XR_ERROR_FORM_FACTOR_UNAVAILABLE);
    assert(properties2(fresh, 7, &sp) == XR_ERROR_SYSTEM_INVALID);
    assert(destroy(fresh) == XR_SUCCESS);
    assert(kl_native_get_instance_proc_addr(XR_NULL_HANDLE, "xrGetSystem", &missing) == XR_ERROR_HANDLE_INVALID);
    puts("klepton native owned boot fixture: pass; no session or VR frame");
    return 0;
}
