#include "klepton_native.h"
#include "metal_host.h"
#include "session_host.h"
#include "image_sync_host.h"
#include "frame_host.h"
#include "input_host.h"
#define XR_USE_GRAPHICS_API_METAL 1
#include <openxr/openxr_platform.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
static int dev, queue, tokens[12], texture[12], created, released, fail_after;
static KlNativeSessionEvent injected;
static XrResult begin_result = XR_SUCCESS, end_result = XR_SUCCESS, exit_result = XR_SUCCESS;
static XrResult image_wait_result = XR_SUCCESS, image_write_result = XR_SUCCESS;
static unsigned waits, completions, frame_waits, cancelled, published;
static KlNativeFrameSample next_sample;
static KlNativeFramePair last_pair;
static KlNativeInputSample input_sample;
static KlNativeInputSample2 input_sample2;
static XrResult input_result = XR_SUCCESS;
static XrResult sample_input(void *ctx, KlNativeInputSample *out) { (void)ctx; *out = input_sample; return input_result; }
static XrResult sample_input2(void *ctx, KlNativeInputSample2 *out) { (void)ctx; *out = input_sample2; return input_result; }
static KlNativeInputSample3 input_sample3;
static XrResult sample_input3(void *ctx, KlNativeInputSample3 *out) { (void)ctx; *out = input_sample3; return input_result; }
static KlNativeInputHand2 absent_hand(void) {
    KlNativeInputHand2 hand = {0};
    hand.trigger = hand.stick_x = hand.stick_y = NAN;
    return hand;
}
static XrResult publish_result = XR_SUCCESS;
static XrResult cancel_result = XR_SUCCESS;
static XrResult host_wait_frame(void *ctx, KlNativeFrameSample *out) { (void)ctx; *out = next_sample; ++frame_waits; return XR_SUCCESS; }
static XrResult host_publish(void *ctx, const KlNativeFramePair *pair) { (void)ctx; ++published; if (publish_result == XR_SUCCESS) last_pair = *pair; return publish_result; }
static XrResult host_cancel(void *ctx, void *ticket) { (void)ctx; assert(ticket == &dev); ++cancelled; return cancel_result; }
static XrResult image_wait(void *ctx, void *lease, XrDuration timeout) { (void)ctx; assert(lease && timeout >= 0); ++waits; return image_wait_result; }
static XrResult image_complete(void *ctx, void *lease) { (void)ctx; assert(lease); ++completions; return image_write_result; }
static XrTime ack_time = 20;
static XrResult poll(void *ctx, KlNativeSessionEvent *event) {
    (void)ctx; if (!injected.type) return XR_EVENT_UNAVAILABLE;
    *event = injected; injected.type = 0; return XR_SUCCESS;
}
static XrResult begin_host(void *ctx, XrTime *time) { (void)ctx; *time = ack_time; return begin_result; }
static XrResult end_host(void *ctx, XrTime *time) { (void)ctx; *time = ack_time; return end_result; }
static XrResult request_exit_host(void *ctx) { (void)ctx; return exit_result; }
static XrSessionState poll_state(PFN_xrPollEvent fn, XrInstance instance) {
    XrEventDataBuffer b = { .type = XR_TYPE_EVENT_DATA_BUFFER };
    assert(fn(instance, &b) == XR_SUCCESS);
    assert(b.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED);
    return ((XrEventDataSessionStateChanged *)&b)->state;
}
static XrResult hmd(void *ctx) { (void)ctx; return XR_SUCCESS; }
static XrResult graphics(void *ctx, void **d, void **q) { (void)ctx; *d = &dev; *q = &queue; return XR_SUCCESS; }
static XrResult formats(void *ctx, uint32_t cap, uint32_t *count, int64_t *out) {
    (void)ctx; if (!count) return XR_ERROR_VALIDATION_FAILURE; *count = 1;
    if (!cap) return XR_SUCCESS;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    out[0] = 80; return XR_SUCCESS;
}
static XrResult create(void *ctx, const KlNativeMetalImageInfo *info, void **out, void **lease) {
    (void)ctx; assert(info->format == 80 && info->width == 16 && info->height == 16 && info->array_size == 2);
    if (fail_after && created == fail_after) return XR_ERROR_OUT_OF_MEMORY;
    *out = &texture[created]; *lease = &tokens[created++]; return XR_SUCCESS;
}
static void release(void *ctx, void *lease) { (void)ctx; assert(lease); ++released; }
#define GET(type, var, instance, name) \
    PFN_xrVoidFunction raw_##var = NULL; \
    assert(kl_native_get_instance_proc_addr(instance, name, &raw_##var) == XR_SUCCESS); \
    type var = (type)raw_##var; assert(var)
int main(void) {
    KlNativeHost host = { 1, sizeof(host), NULL, hmd, NULL };
    KlNativeMetalHost metal = { KL_NATIVE_METAL_HOST_VERSION, sizeof(metal), NULL, graphics, formats, create, release };
    assert(kl_native_configure(&host) == XR_SUCCESS);
    assert(kl_native_configure_metal(&metal) == XR_SUCCESS);
    KlNativeSessionHost platform = { KL_NATIVE_SESSION_HOST_VERSION, sizeof(platform), NULL, poll, begin_host, end_host, request_exit_host };
    assert(kl_native_configure_session(&platform) == XR_SUCCESS);
    KlNativeImageSyncHost sync = { KL_NATIVE_IMAGE_SYNC_HOST_VERSION, sizeof(sync), NULL, image_wait, image_complete };
    assert(kl_native_configure_image_sync(&sync) == XR_SUCCESS);
    KlNativeFrameHost frame_host = { KL_NATIVE_FRAME_HOST_VERSION, sizeof(frame_host), NULL, host_wait_frame, host_publish, host_cancel };
    assert(kl_native_configure_frame(&frame_host) == XR_SUCCESS);
    KlNativeInputHost input = { KL_NATIVE_INPUT_HOST_VERSION, sizeof(input), NULL, sample_input };
    assert(kl_native_configure_input(&input) == XR_SUCCESS);
    GET(PFN_xrEnumerateInstanceExtensionProperties, enum_ext, XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties");
    uint32_t count = 0;
    assert(enum_ext(NULL, 0, &count, NULL) == XR_SUCCESS && count == 1);
    XrExtensionProperties ext = { .type = XR_TYPE_EXTENSION_PROPERTIES };
    assert(enum_ext(NULL, 1, &count, &ext) == XR_SUCCESS && !strcmp(ext.extensionName, XR_KHR_METAL_ENABLE_EXTENSION_NAME));
    GET(PFN_xrCreateInstance, new_instance, XR_NULL_HANDLE, "xrCreateInstance");
    const char *requested = XR_KHR_METAL_ENABLE_EXTENSION_NAME;
    XrInstanceCreateInfo ci = { .type = XR_TYPE_INSTANCE_CREATE_INFO, .enabledExtensionCount = 1, .enabledExtensionNames = &requested };
    ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    XrInstance instance; assert(new_instance(&ci, &instance) == XR_SUCCESS);
    assert(kl_native_configure_metal(NULL) == XR_ERROR_CALL_ORDER_INVALID);
    GET(PFN_xrGetMetalGraphicsRequirementsKHR, req, instance, "xrGetMetalGraphicsRequirementsKHR");
    GET(PFN_xrCreateSession, new_session, instance, "xrCreateSession");
    GET(PFN_xrDestroySession, destroy_session, instance, "xrDestroySession");
    GET(PFN_xrCreateSwapchain, new_swap, instance, "xrCreateSwapchain");
    GET(PFN_xrDestroySwapchain, destroy_swap, instance, "xrDestroySwapchain");
    GET(PFN_xrEnumerateSwapchainImages, images, instance, "xrEnumerateSwapchainImages");
    GET(PFN_xrDestroyInstance, destroy_instance, instance, "xrDestroyInstance");
    GET(PFN_xrBeginSession, begin, instance, "xrBeginSession");
    GET(PFN_xrEndSession, end, instance, "xrEndSession");
    GET(PFN_xrRequestExitSession, request_exit, instance, "xrRequestExitSession");
    GET(PFN_xrPollEvent, poll_event, instance, "xrPollEvent");
    GET(PFN_xrCreateReferenceSpace, create_space, instance, "xrCreateReferenceSpace");
    GET(PFN_xrDestroySpace, destroy_space, instance, "xrDestroySpace");
    GET(PFN_xrLocateSpace, locate_space, instance, "xrLocateSpace");
    GET(PFN_xrWaitFrame, wait_frame, instance, "xrWaitFrame");
    GET(PFN_xrBeginFrame, begin_frame, instance, "xrBeginFrame");
    GET(PFN_xrEndFrame, end_frame, instance, "xrEndFrame");
    GET(PFN_xrLocateViews, locate_views, instance, "xrLocateViews");
    GET(PFN_xrAcquireSwapchainImage, acquire, instance, "xrAcquireSwapchainImage");
    GET(PFN_xrWaitSwapchainImage, wait_image, instance, "xrWaitSwapchainImage");
    GET(PFN_xrReleaseSwapchainImage, release_image, instance, "xrReleaseSwapchainImage");
    GET(PFN_xrCreateActionSet, create_set, instance, "xrCreateActionSet");
    GET(PFN_xrAttachSessionActionSets, attach_sets, instance, "xrAttachSessionActionSets");
    GET(PFN_xrSyncActions, sync_actions, instance, "xrSyncActions");
    GET(PFN_xrCreateAction, create_action, instance, "xrCreateAction");
    GET(PFN_xrStringToPath, to_path, instance, "xrStringToPath");
    GET(PFN_xrGetActionStateBoolean, bool_state, instance, "xrGetActionStateBoolean");
    GET(PFN_xrGetActionStateFloat, float_state, instance, "xrGetActionStateFloat");
    GET(PFN_xrGetActionStateVector2f, vector_state, instance, "xrGetActionStateVector2f");
    GET(PFN_xrGetActionStatePose, pose_state, instance, "xrGetActionStatePose");
    GET(PFN_xrGetCurrentInteractionProfile, current_profile, instance, "xrGetCurrentInteractionProfile");
    XrGraphicsBindingMetalKHR binding = { .type = XR_TYPE_GRAPHICS_BINDING_METAL_KHR, .commandQueue = &queue };
    XrSessionCreateInfo si = { .type = XR_TYPE_SESSION_CREATE_INFO, .next = &binding, .systemId = 1 };
    XrSession session;
    assert(new_session(instance, &si, &session) == XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING);
    XrGraphicsRequirementsMetalKHR r = { .type = XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR };
    assert(req(instance, 1, &r) == XR_SUCCESS && r.metalDevice == &dev);
    binding.commandQueue = &dev;
    assert(new_session(instance, &si, &session) == XR_ERROR_GRAPHICS_DEVICE_INVALID);
    binding.commandQueue = &queue;
    assert(new_session(instance, &si, &session) == XR_SUCCESS);
    assert(kl_native_configure_input(NULL) == XR_ERROR_CALL_ORDER_INVALID);
    KlNativeInputHost2 early2 = { KL_NATIVE_INPUT_HOST_VERSION_2, sizeof(early2), NULL, sample_input2 };
    assert(kl_native_configure_input2(&early2) == XR_ERROR_CALL_ORDER_INVALID);
    XrActionSetCreateInfo asi = { .type = XR_TYPE_ACTION_SET_CREATE_INFO };
    strcpy(asi.actionSetName, "input"); strcpy(asi.localizedActionSetName, "Input");
    XrActionSet set; assert(create_set(instance, &asi, &set) == XR_SUCCESS);
    XrPath hand; assert(to_path(instance, "/user/hand/left", &hand) == XR_SUCCESS);
    XrAction action[4];
    XrActionType types[4] = { XR_ACTION_TYPE_BOOLEAN_INPUT, XR_ACTION_TYPE_FLOAT_INPUT, XR_ACTION_TYPE_VECTOR2F_INPUT, XR_ACTION_TYPE_POSE_INPUT };
    for (unsigned i = 0; i < 4; ++i) {
        XrActionCreateInfo ai = { .type = XR_TYPE_ACTION_CREATE_INFO, .actionType = types[i], .countSubactionPaths = 1, .subactionPaths = &hand };
        snprintf(ai.actionName, sizeof ai.actionName, "action%u", i);
        snprintf(ai.localizedActionName, sizeof ai.localizedActionName, "Action %u", i);
        assert(create_action(set, &ai, &action[i]) == XR_SUCCESS);
    }
    XrActionStateGetInfo gi = { .type = XR_TYPE_ACTION_STATE_GET_INFO, .action = action[0], .subactionPath = hand };
    XrActionStateBoolean bs = { .type = XR_TYPE_ACTION_STATE_BOOLEAN, .currentState = XR_TRUE, .changedSinceLastSync = XR_TRUE, .lastChangeTime = 1, .isActive = XR_TRUE };
    XrActionStateFloat fl = { .type = XR_TYPE_ACTION_STATE_FLOAT, .currentState = 1, .isActive = XR_TRUE };
    XrActionStateVector2f vec = { .type = XR_TYPE_ACTION_STATE_VECTOR2F, .currentState = {1,1}, .isActive = XR_TRUE };
    XrActionStatePose pose = { .type = XR_TYPE_ACTION_STATE_POSE, .isActive = XR_TRUE };
    XrInteractionProfileState profile = { .type = XR_TYPE_INTERACTION_PROFILE_STATE, .interactionProfile = hand };
    XrSessionActionSetsAttachInfo attach = { .type = XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO, .countActionSets = 1, .actionSets = &set };
    XrActiveActionSet active = { .actionSet = set };
    XrActionsSyncInfo action_sync = { .type = XR_TYPE_ACTIONS_SYNC_INFO, .countActiveActionSets = 1, .activeActionSets = &active };
    assert(sync_actions(session, &action_sync) == XR_ERROR_ACTIONSET_NOT_ATTACHED);
    assert(attach_sets(session, &attach) == XR_SUCCESS);
    assert(attach_sets(session, &attach) == XR_ERROR_ACTIONSETS_ALREADY_ATTACHED);
    assert(sync_actions(session, &action_sync) == XR_ERROR_SESSION_NOT_RUNNING);
    assert(bool_state(session, &gi, &bs) == XR_ERROR_CALL_ORDER_INVALID);
    XrSessionBeginInfo bi = { .type = XR_TYPE_SESSION_BEGIN_INFO, .primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO };
    XrEventDataBuffer b = { .type = XR_TYPE_EVENT_DATA_BUFFER };
    assert(poll_event(instance, &b) == XR_EVENT_UNAVAILABLE);
    assert(begin(session, &bi) == XR_ERROR_SESSION_NOT_READY);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_FOCUSED, 5 };
    assert(poll_event(instance, &b) == XR_ERROR_CALL_ORDER_INVALID);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_READY, 10 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_READY);
    begin_result = XR_ERROR_RUNTIME_FAILURE;
    assert(begin(session, &bi) == XR_ERROR_RUNTIME_FAILURE);
    begin_result = XR_SUCCESS;
    assert(begin(session, &bi) == XR_SUCCESS);
    assert(destroy_session(session) == XR_ERROR_SESSION_RUNNING);
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_SYNCHRONIZED);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_VISIBLE, 19 };
    assert(poll_event(instance, &b) == XR_ERROR_TIME_INVALID);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_VISIBLE, 21 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_VISIBLE);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_FOCUSED, 22 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_FOCUSED);
    input_sample = (KlNativeInputSample){ .sample_id = 1, .sample_time = 23 };
    assert(sync_actions(session, &action_sync) == XR_SUCCESS);
    assert(sync_actions(session, &action_sync) == XR_SUCCESS); /* unchanged observation */
    assert(bool_state(session, &gi, &bs) == XR_SUCCESS && !bs.currentState && !bs.changedSinceLastSync && !bs.lastChangeTime && !bs.isActive);
    assert(current_profile(session, hand, &profile) == XR_SUCCESS && profile.interactionProfile == XR_NULL_PATH);
    gi.action = action[1]; assert(float_state(session, &gi, &fl) == XR_SUCCESS && fl.currentState == 0 && !fl.isActive);
    gi.action = action[2]; assert(vector_state(session, &gi, &vec) == XR_SUCCESS && vec.currentState.x == 0 && vec.currentState.y == 0 && !vec.isActive);
    gi.action = action[3]; assert(pose_state(session, &gi, &pose) == XR_SUCCESS && !pose.isActive);
    assert(bool_state(session, &gi, &bs) == XR_ERROR_ACTION_TYPE_MISMATCH);
    gi.action = action[0];
    input_sample.sample_time = 24;
    assert(sync_actions(session, &action_sync) == XR_ERROR_VALIDATION_FAILURE); /* same ID, conflicting time */
    input_sample.sample_id = 2; input_sample.sample_time = 22;
    assert(sync_actions(session, &action_sync) == XR_ERROR_VALIDATION_FAILURE);
    input_sample.sample_time = 24; input_sample.hand_connected[0] = XR_TRUE;
    assert(sync_actions(session, &action_sync) == XR_ERROR_FEATURE_UNSUPPORTED);
    assert(bool_state(session, &gi, &bs) == XR_ERROR_CALL_ORDER_INVALID);
    assert(current_profile(session, hand, &profile) == XR_ERROR_CALL_ORDER_INVALID);
    input_sample.hand_connected[0] = XR_FALSE;
    input_result = XR_ERROR_RUNTIME_FAILURE;
    assert(sync_actions(session, &action_sync) == XR_ERROR_RUNTIME_FAILURE);
    input_result = XR_SUCCESS;
    assert(sync_actions(session, &action_sync) == XR_SUCCESS);
    XrReferenceSpaceCreateInfo rs = { .type = XR_TYPE_REFERENCE_SPACE_CREATE_INFO,
        .referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL, .poseInReferenceSpace.orientation.w = 1 };
    XrSpace local, stage, view;
    assert(create_space(session, &rs, &local) == XR_SUCCESS);
    rs.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE;
    assert(create_space(session, &rs, &stage) == XR_SUCCESS);
    rs.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
    assert(create_space(session, &rs, &view) == XR_SUCCESS);
    next_sample = (KlNativeFrameSample){ .ticket = &dev, .frame_id = 101, .pose_id = 201,
        .predicted_display_time = 100, .predicted_display_period = 10, .should_render = XR_TRUE,
        .head_location_flags = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT,
        .local_from_head = { .orientation.w = 1, .position = {1, 1.5f, -2} },
        .head_from_eye = { { .orientation.w = 1, .position.x = -0.03f }, { .orientation.w = 1, .position.x = 0.03f } },
        .fov = { {-.8f,.8f,.8f,-.8f}, {-.8f,.8f,.8f,-.8f} } };
    XrFrameState fs = { .type = XR_TYPE_FRAME_STATE };
    assert(wait_frame(session, NULL, &fs) == XR_SUCCESS && fs.shouldRender == XR_TRUE && fs.predictedDisplayTime == 100);
    assert(wait_frame(session, NULL, &fs) == XR_ERROR_CALL_ORDER_INVALID);
    XrViewLocateInfo vi = { .type = XR_TYPE_VIEW_LOCATE_INFO, .viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, .displayTime = 100, .space = view };
    XrViewState vs = { .type = XR_TYPE_VIEW_STATE };
    XrView views[2] = { {.type = XR_TYPE_VIEW}, {.type = XR_TYPE_VIEW} };
    assert(locate_views(session, &vi, &vs, 2, &count, views) == XR_SUCCESS && count == 2);
    assert(views[0].pose.position.x < -0.029f && views[1].pose.position.x > 0.029f);
    vi.space = stage;
    assert(locate_views(session, &vi, &vs, 2, &count, views) == XR_SUCCESS && vs.viewStateFlags == 0);
    XrSpaceLocation location = { .type = XR_TYPE_SPACE_LOCATION };
    assert(locate_space(view, stage, 100, &location) == XR_SUCCESS && location.locationFlags == 0);
    assert(begin_frame(session, NULL) == XR_SUCCESS);
    XrFrameEndInfo fi = { .type = XR_TYPE_FRAME_END_INFO, .displayTime = 100, .environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE };
    cancel_result = XR_ERROR_RUNTIME_FAILURE;
    assert(end_frame(session, &fi) == XR_ERROR_RUNTIME_FAILURE);
    assert(destroy_session(session) == XR_ERROR_SESSION_RUNNING);
    cancel_result = XR_SUCCESS;
    assert(end_frame(session, &fi) == XR_SUCCESS && cancelled == 2 && published == 0);
    next_sample.frame_id = 102; next_sample.pose_id = 202; next_sample.predicted_display_time = 110;
    next_sample.stage_valid = XR_TRUE; next_sample.local_from_stage.orientation.w = 1;
    next_sample.local_from_stage.position.y = -1;
    assert(wait_frame(session, NULL, &fs) == XR_SUCCESS);
    assert(locate_space(view, stage, 110, &location) == XR_SUCCESS && location.locationFlags && location.pose.position.y == 2.5f);
    XrSpaceVelocity velocity = { .type = XR_TYPE_SPACE_VELOCITY, .velocityFlags = UINT64_MAX,
        .linearVelocity = {1, 2, 3}, .angularVelocity = {4, 5, 6} };
    location.next = &velocity;
    assert(locate_space(view, stage, 110, &location) == XR_SUCCESS && location.locationFlags && location.pose.position.y == 2.5f);
    assert(velocity.velocityFlags == 0 && velocity.linearVelocity.x == 0 && velocity.angularVelocity.z == 0);
    velocity.next = &velocity;
    assert(locate_space(view, stage, 110, &location) == XR_ERROR_VALIDATION_FAILURE);
    velocity.next = NULL; location.next = NULL;
    assert(begin_frame(session, NULL) == XR_SUCCESS);
    fi.displayTime = 110; assert(end_frame(session, &fi) == XR_SUCCESS);
    next_sample.frame_id = 103; next_sample.pose_id = 203; next_sample.predicted_display_time = 120;
    next_sample.local_from_head.orientation.w = 0; cancel_result = XR_ERROR_RUNTIME_FAILURE;
    assert(wait_frame(session, NULL, &fs) == XR_ERROR_RUNTIME_FAILURE);
    assert(wait_frame(session, NULL, &fs) == XR_ERROR_RUNTIME_FAILURE);
    cancel_result = XR_SUCCESS; next_sample.local_from_head.orientation.w = 1;
    next_sample.frame_id = 104; next_sample.pose_id = 204; next_sample.predicted_display_time = 130;
    assert(wait_frame(session, NULL, &fs) == XR_SUCCESS);
    assert(begin_frame(session, NULL) == XR_SUCCESS); fi.displayTime = 130;
    assert(end_frame(session, &fi) == XR_SUCCESS && published == 0);
    next_sample.frame_id = 0; next_sample.pose_id = 205; next_sample.predicted_display_time = 140;
    unsigned cancelled_before = cancelled;
    assert(wait_frame(session, NULL, &fs) == XR_ERROR_RUNTIME_FAILURE);
    assert(cancelled == cancelled_before + 1); /* opaque ticket still cancellable */
    assert(destroy_space(view) == XR_SUCCESS);
    assert(destroy_space(stage) == XR_SUCCESS);
    assert(destroy_space(local) == XR_SUCCESS);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_STOPPING, 23 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_STOPPING);
    end_result = XR_TIMEOUT_EXPIRED;
    assert(end(session) == XR_ERROR_RUNTIME_FAILURE);
    end_result = XR_ERROR_RUNTIME_FAILURE;
    assert(end(session) == XR_ERROR_RUNTIME_FAILURE);
    assert(destroy_session(session) == XR_ERROR_SESSION_RUNNING);
    ack_time = 24; end_result = XR_SUCCESS;
    assert(end(session) == XR_SUCCESS);
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_IDLE);
    XrSwapchainCreateInfo sc = { .type = XR_TYPE_SWAPCHAIN_CREATE_INFO, .format = 80, .sampleCount = 1, .width = 16, .height = 16, .faceCount = 1, .arraySize = 2, .mipCount = 1 };
    XrSwapchain swap;
    fail_after = 2;
    assert(new_swap(session, &sc, &swap) == XR_ERROR_OUT_OF_MEMORY && released == 2 && swap == XR_NULL_HANDLE);
    fail_after = 0;
    assert(new_swap(session, &sc, &swap) == XR_SUCCESS && created == 5);
    assert(acquire(swap, NULL, NULL) == XR_ERROR_VALIDATION_FAILURE);
    XrSwapchainImageWaitInfo wi = { .type = XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, .timeout = 1 };
    uint32_t i0, i1, i2;
    assert(wait_image(swap, &wi) == XR_ERROR_CALL_ORDER_INVALID);
    assert(release_image(swap, NULL) == XR_ERROR_CALL_ORDER_INVALID);
    assert(acquire(swap, NULL, &i0) == XR_SUCCESS && i0 == 0);
    assert(acquire(swap, NULL, &i1) == XR_SUCCESS && i1 == 1);
    assert(acquire(swap, NULL, &i2) == XR_SUCCESS && i2 == 2);
    assert(acquire(swap, NULL, &i2) == XR_ERROR_CALL_ORDER_INVALID);
    assert(destroy_swap(swap) == XR_ERROR_CALL_ORDER_INVALID);
    assert(destroy_session(session) == XR_ERROR_CALL_ORDER_INVALID);
    assert(destroy_instance(instance) == XR_ERROR_CALL_ORDER_INVALID);
    image_wait_result = XR_TIMEOUT_EXPIRED;
    assert(wait_image(swap, &wi) == XR_TIMEOUT_EXPIRED);
    assert(release_image(swap, NULL) == XR_ERROR_CALL_ORDER_INVALID);
    image_wait_result = XR_SUCCESS;
    assert(wait_image(swap, &wi) == XR_SUCCESS);
    assert(wait_image(swap, &wi) == XR_ERROR_CALL_ORDER_INVALID);
    image_write_result = XR_ERROR_RUNTIME_FAILURE;
    assert(release_image(swap, NULL) == XR_ERROR_RUNTIME_FAILURE);
    assert(destroy_swap(swap) == XR_ERROR_CALL_ORDER_INVALID);
    image_write_result = XR_SUCCESS;
    assert(release_image(swap, NULL) == XR_SUCCESS);
    assert(wait_image(swap, &wi) == XR_SUCCESS && release_image(swap, NULL) == XR_SUCCESS);
    assert(wait_image(swap, &wi) == XR_SUCCESS && release_image(swap, NULL) == XR_SUCCESS);
    assert(waits == 4 && completions == 4);
    assert(images(swap, 0, &count, NULL) == XR_SUCCESS && count == 3);
    XrSwapchainImageMetalKHR imgs[3]; memset(imgs, 0, sizeof imgs);
    for (unsigned i = 0; i < 3; ++i) imgs[i].type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR;
    assert(images(swap, 2, &count, (XrSwapchainImageBaseHeader *)imgs) == XR_ERROR_SIZE_INSUFFICIENT && count == 3);
    imgs[1].type = XR_TYPE_UNKNOWN;
    assert(images(swap, 3, &count, (XrSwapchainImageBaseHeader *)imgs) == XR_ERROR_VALIDATION_FAILURE);
    assert(imgs[0].texture == NULL && imgs[2].texture == NULL);
    imgs[1].type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR;
    assert(images(swap, 3, &count, (XrSwapchainImageBaseHeader *)imgs) == XR_SUCCESS);
    assert(imgs[0].texture == &texture[2] && imgs[2].texture == &texture[4]);
    /* One real release of a two-layer image may feed both projection eyes. */
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_READY, 200 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_READY);
    ack_time = 201;
    assert(begin(session, &bi) == XR_SUCCESS);
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_SYNCHRONIZED);
    rs.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    assert(create_space(session, &rs, &local) == XR_SUCCESS);
    next_sample.frame_id = 105; next_sample.pose_id = 205; next_sample.predicted_display_time = 210;
    assert(wait_frame(session, NULL, &fs) == XR_SUCCESS && fs.shouldRender == XR_TRUE);
    assert(begin_frame(session, NULL) == XR_SUCCESS);
    /* This completed release belongs to the current latched frame/pose. */
    assert(acquire(swap, NULL, &i0) == XR_SUCCESS);
    assert(wait_image(swap, &wi) == XR_SUCCESS);
    assert(release_image(swap, NULL) == XR_SUCCESS);
    XrCompositionLayerProjectionView projection_views[2] = {
        { .type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW, .pose = { .orientation.w = 1, .position = {1, 1.5f, -2} },
          .fov = {-.8f, .8f, .8f, -.8f}, .subImage = { .swapchain = swap, .imageRect = { {0,0}, {16,16} }, .imageArrayIndex = 0 } },
        { .type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW, .pose = { .orientation.w = 1, .position = {2, 1.5f, -2} },
          .fov = {-.8f, .8f, .8f, -.8f}, .subImage = { .swapchain = swap, .imageRect = { {0,0}, {16,16} }, .imageArrayIndex = 1 } } };
    XrCompositionLayerProjection projection = { .type = XR_TYPE_COMPOSITION_LAYER_PROJECTION, .space = local, .viewCount = 2, .views = projection_views };
    const XrCompositionLayerBaseHeader *layer = (const XrCompositionLayerBaseHeader *)&projection;
    fi.displayTime = 210; fi.layerCount = 1; fi.layers = &layer;
    projection_views[1].subImage.imageRect.extent.width = 17;
    assert(end_frame(session, &fi) == XR_ERROR_SWAPCHAIN_RECT_INVALID && published == 0);
    projection_views[1].subImage.imageRect.extent.width = 16;
    projection_views[1].subImage.imageArrayIndex = 0;
    assert(end_frame(session, &fi) == XR_ERROR_LAYER_INVALID && published == 0);
    projection_views[1].subImage.imageArrayIndex = 1;
    publish_result = XR_ERROR_RUNTIME_FAILURE;
    assert(end_frame(session, &fi) == XR_ERROR_RUNTIME_FAILURE && published == 1);
    publish_result = XR_SUCCESS;
    assert(end_frame(session, &fi) == XR_SUCCESS && published == 2);
    assert(last_pair.sample.frame_id == 105 && last_pair.sample.pose_id == 205 && last_pair.sample.ticket == &dev);
    assert(last_pair.eye[0].texture == last_pair.eye[1].texture && last_pair.eye[0].array_layer == 0 && last_pair.eye[1].array_layer == 1);
    assert(last_pair.eye[0].local_from_render_eye.position.x == 1 && last_pair.eye[1].local_from_render_eye.position.x == 2);
    next_sample.frame_id = 106; next_sample.pose_id = 206; next_sample.predicted_display_time = 220;
    assert(wait_frame(session, NULL, &fs) == XR_SUCCESS);
    assert(begin_frame(session, NULL) == XR_SUCCESS);
    fi.displayTime = 220;
    assert(end_frame(session, &fi) == XR_ERROR_CALL_ORDER_INVALID && published == 2);
    fi.layerCount = 0; fi.layers = NULL;
    assert(end_frame(session, &fi) == XR_SUCCESS); /* rejected pair can be cancelled */
    assert(destroy_space(local) == XR_SUCCESS);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_STOPPING, 230 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_STOPPING);
    ack_time = 231;
    assert(end(session) == XR_SUCCESS);
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_IDLE);
    assert(destroy_swap(swap) == XR_SUCCESS && released == 5);
    assert(destroy_swap(swap) == XR_ERROR_HANDLE_INVALID);
    assert(destroy_session(session) == XR_SUCCESS);
    assert(destroy_session(session) == XR_ERROR_HANDLE_INVALID);
    assert(new_session(instance, &si, &session) == XR_SUCCESS);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_READY, 300 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_READY);
    ack_time = 1;
    assert(begin(session, &bi) == XR_ERROR_RUNTIME_FAILURE);
    assert(destroy_session(session) == XR_ERROR_SESSION_RUNNING);
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_LOSS_PENDING);
    ack_time = 301;
    assert(end(session) == XR_SUCCESS);
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_IDLE);
    assert(destroy_session(session) == XR_SUCCESS);
    assert(new_session(instance, &si, &session) == XR_SUCCESS);
    assert(request_exit(session) == XR_ERROR_SESSION_NOT_RUNNING);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_READY, 400 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_READY);
    ack_time = 401; assert(begin(session, &bi) == XR_SUCCESS);
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_SYNCHRONIZED);
    exit_result = XR_ERROR_RUNTIME_FAILURE;
    assert(request_exit(session) == XR_ERROR_RUNTIME_FAILURE);
    exit_result = XR_SUCCESS;
    assert(request_exit(session) == XR_SUCCESS);
    assert(request_exit(session) == XR_ERROR_CALL_ORDER_INVALID);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_STOPPING, 402 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_STOPPING);
    ack_time = 403; assert(end(session) == XR_SUCCESS);
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_IDLE);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_EXITING, 404 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_EXITING);
    assert(destroy_session(session) == XR_SUCCESS);
    assert(destroy_instance(instance) == XR_SUCCESS);
    KlNativeInputHost2 host2 = { KL_NATIVE_INPUT_HOST_VERSION_2, sizeof(host2), NULL, sample_input2 };
    assert(kl_native_configure_input2(NULL) == XR_SUCCESS);
    assert(kl_native_configure_input2(&host2) == XR_SUCCESS);
    host2.version = 1; assert(kl_native_configure_input2(&host2) == XR_ERROR_VALIDATION_FAILURE);
    host2.version = KL_NATIVE_INPUT_HOST_VERSION_2;
    assert(new_instance(&ci, &instance) == XR_SUCCESS);
    assert(req(instance, 1, &r) == XR_SUCCESS);
    assert(new_session(instance, &si, &session) == XR_SUCCESS);
    XrActionSet set2; assert(create_set(instance, &asi, &set2) == XR_SUCCESS);
    XrPath hand2; assert(to_path(instance, "/user/hand/left", &hand2) == XR_SUCCESS);
    XrAction action2;
    XrActionCreateInfo ai2 = { .type = XR_TYPE_ACTION_CREATE_INFO, .actionType = XR_ACTION_TYPE_BOOLEAN_INPUT, .countSubactionPaths = 1, .subactionPaths = &hand2 };
    strcpy(ai2.actionName, "sense"); strcpy(ai2.localizedActionName, "Sense");
    assert(create_action(set2, &ai2, &action2) == XR_SUCCESS);
    XrSessionActionSetsAttachInfo attach2 = { .type = XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO, .countActionSets = 1, .actionSets = &set2 };
    assert(attach_sets(session, &attach2) == XR_SUCCESS);
    XrActiveActionSet active2 = { .actionSet = set2 };
    XrActionsSyncInfo sync2 = { .type = XR_TYPE_ACTIONS_SYNC_INFO, .countActiveActionSets = 1, .activeActionSets = &active2 };
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_READY, 10 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_READY);
    ack_time = 20; assert(begin(session, &bi) == XR_SUCCESS);
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_SYNCHRONIZED);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_VISIBLE, 21 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_VISIBLE);
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_FOCUSED, 22 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_FOCUSED);
    input_sample2 = (KlNativeInputSample2){ .sample_id = 1, .sample_time = 30, .hand = { absent_hand(), absent_hand() } };
    assert(sync_actions(session, &sync2) == XR_SUCCESS);
    input_sample2.sample_id = 2; input_sample2.sample_time = 40;
    input_sample2.hand[0].connected = XR_TRUE; input_sample2.hand[0].grip_position_tracked = XR_TRUE;
    input_sample2.hand[0].trigger = 0.25f; input_sample2.hand[0].primary_pressed = XR_TRUE;
    assert(sync_actions(session, &sync2) == XR_SUCCESS);
    profile.interactionProfile = hand2;
    assert(current_profile(session, hand2, &profile) == XR_SUCCESS && profile.interactionProfile == XR_NULL_PATH);
    gi.action = action2; gi.subactionPath = hand2;
    bs.isActive = XR_TRUE; assert(bool_state(session, &gi, &bs) == XR_SUCCESS && !bs.isActive && !bs.currentState);
    input_sample2.hand[0].primary_pressed = XR_FALSE;
    assert(sync_actions(session, &sync2) == XR_ERROR_VALIDATION_FAILURE); /* same id, changed controls */
    assert(bool_state(session, &gi, &bs) == XR_ERROR_CALL_ORDER_INVALID);
    input_sample2.sample_id = 3; input_sample2.sample_time = 50; input_sample2.hand[0].trigger = 1.5f;
    assert(sync_actions(session, &sync2) == XR_ERROR_VALIDATION_FAILURE);
    input_sample2.hand[0] = absent_hand(); input_sample2.hand[0].connected = XR_TRUE; input_sample2.hand[0].stick_x = 0.5f;
    assert(sync_actions(session, &sync2) == XR_ERROR_VALIDATION_FAILURE); /* one stick axis */
    injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_STOPPING, 60 };
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_STOPPING);
    ack_time = 61; assert(end(session) == XR_SUCCESS);
    assert(poll_state(poll_event, instance) == XR_SESSION_STATE_IDLE);
    assert(destroy_session(session) == XR_SUCCESS);
    assert(destroy_instance(instance) == XR_SUCCESS);
    {   /* Version 3: a host-observed profile becomes current only when suggested, with one change event. */
        KlNativeInputHost3 host3 = { KL_NATIVE_INPUT_HOST_VERSION_3, sizeof(host3), NULL, sample_input3 };
        host3.version = 2; assert(kl_native_configure_input3(&host3) == XR_ERROR_VALIDATION_FAILURE);
        host3.version = KL_NATIVE_INPUT_HOST_VERSION_3; assert(kl_native_configure_input3(&host3) == XR_SUCCESS);
        assert(new_instance(&ci, &instance) == XR_SUCCESS);
        GET(PFN_xrCreateActionSpace, action_space, instance, "xrCreateActionSpace");
        GET(PFN_xrSuggestInteractionProfileBindings, suggest, instance, "xrSuggestInteractionProfileBindings");
        GET(PFN_xrBeginFrame, begin_frame3, instance, "xrBeginFrame");
        GET(PFN_xrEndFrame, end_frame3, instance, "xrEndFrame");
        assert(req(instance, 1, &r) == XR_SUCCESS);
        assert(new_session(instance, &si, &session) == XR_SUCCESS);
        XrActionSet set3; assert(create_set(instance, &asi, &set3) == XR_SUCCESS);
        XrPath hands[2], touch, vive;
        assert(to_path(instance, "/user/hand/left", &hands[0]) == XR_SUCCESS && to_path(instance, "/user/hand/right", &hands[1]) == XR_SUCCESS);
        assert(to_path(instance, "/interaction_profiles/oculus/touch_controller", &touch) == XR_SUCCESS);
        assert(to_path(instance, "/interaction_profiles/htc/vive_controller", &vive) == XR_SUCCESS);
        XrAction a3[4];   /* a/x click (bool), trigger (float), stick (vector), grip (pose) */
        for (unsigned i = 0; i < 4; ++i) {
            XrActionCreateInfo ai = { .type = XR_TYPE_ACTION_CREATE_INFO, .actionType = types[i], .countSubactionPaths = 2, .subactionPaths = hands };
            snprintf(ai.actionName, sizeof ai.actionName, "v3action%u", i);
            snprintf(ai.localizedActionName, sizeof ai.localizedActionName, "V3 Action %u", i);
            assert(create_action(set3, &ai, &a3[i]) == XR_SUCCESS);
        }
        const char *bound[6] = { "/user/hand/left/input/trigger/value", "/user/hand/right/input/a/click", "/user/hand/left/input/x/click",
            "/user/hand/right/input/thumbstick", "/user/hand/left/input/grip/pose", "/user/hand/right/input/grip/pose" };
        XrActionSuggestedBinding sb[6];
        const unsigned which[6] = { 1, 0, 0, 2, 3, 3 };
        for (unsigned i = 0; i < 6; ++i) { sb[i].action = a3[which[i]]; assert(to_path(instance, bound[i], &sb[i].binding) == XR_SUCCESS); }
        XrInteractionProfileSuggestedBinding suggestion = { .type = XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING, .interactionProfile = touch, .countSuggestedBindings = 6, .suggestedBindings = sb };
        assert(suggest(instance, &suggestion) == XR_SUCCESS);
        XrActionSpaceCreateInfo asc = { .type = XR_TYPE_ACTION_SPACE_CREATE_INFO, .action = a3[0], .subactionPath = hands[0], .poseInActionSpace.orientation.w = 1 };
        XrSpace grip_left, grip_right, local3;
        assert(action_space(session, &asc, &grip_left) == XR_ERROR_ACTION_TYPE_MISMATCH);
        asc.action = a3[3]; assert(action_space(session, &asc, &grip_left) == XR_SUCCESS);
        asc.subactionPath = hands[1]; asc.poseInActionSpace.position.z = -0.1f; assert(action_space(session, &asc, &grip_right) == XR_SUCCESS);
        assert(create_space(session, &rs, &local3) == XR_SUCCESS);   /* rs is LOCAL here */
        XrSessionActionSetsAttachInfo attach3 = { .type = XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO, .countActionSets = 1, .actionSets = &set3 };
        assert(attach_sets(session, &attach3) == XR_SUCCESS);
        XrActiveActionSet active3 = { .actionSet = set3 };
        XrActionsSyncInfo sync3 = { .type = XR_TYPE_ACTIONS_SYNC_INFO, .countActiveActionSets = 1, .activeActionSets = &active3 };
        injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_READY, 10 };
        assert(poll_state(poll_event, instance) == XR_SESSION_STATE_READY);
        ack_time = 20; assert(begin(session, &bi) == XR_SUCCESS);
        assert(poll_state(poll_event, instance) == XR_SESSION_STATE_SYNCHRONIZED);
        injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_VISIBLE, 21 };
        assert(poll_state(poll_event, instance) == XR_SESSION_STATE_VISIBLE);
        injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_FOCUSED, 22 };
        assert(poll_state(poll_event, instance) == XR_SESSION_STATE_FOCUSED);
        for (unsigned h = 0; h < 2; ++h) {
            input_sample3.hand[h] = (KlNativeInputHand3){ .controls = absent_hand(), .profile = KL_NATIVE_INPUT_PROFILE_OCULUS_TOUCH,
                .local_from_grip = { .orientation.w = 1, .position = { h ? 0.2f : -0.2f, 1.1f, -0.35f } },
                .local_from_aim = { .orientation.w = 1, .position = { h ? 0.2f : -0.2f, 1.1f, -0.4f } } };
            input_sample3.hand[h].controls.connected = XR_TRUE;
            input_sample3.hand[h].controls.trigger = 0; input_sample3.hand[h].controls.stick_x = input_sample3.hand[h].controls.stick_y = 0;
        }
        input_sample3.sample_id = 1; input_sample3.sample_time = 30;
        input_sample3.hand[0].profile = KL_NATIVE_INPUT_PROFILE_NONE;
        assert(sync_actions(session, &sync3) == XR_ERROR_VALIDATION_FAILURE);   /* connected needs a profile */
        input_sample3.hand[0].profile = KL_NATIVE_INPUT_PROFILE_OCULUS_TOUCH;
        assert(sync_actions(session, &sync3) == XR_SUCCESS);
        XrEventDataBuffer eb = { .type = XR_TYPE_EVENT_DATA_BUFFER };
        assert(poll_event(instance, (eb.type = XR_TYPE_EVENT_DATA_BUFFER, &eb)) == XR_SUCCESS && eb.type == XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED &&
               ((XrEventDataInteractionProfileChanged *)&eb)->session == session);
        assert(poll_event(instance, (eb.type = XR_TYPE_EVENT_DATA_BUFFER, &eb)) == XR_EVENT_UNAVAILABLE);
        XrInteractionProfileState ps = { .type = XR_TYPE_INTERACTION_PROFILE_STATE };
        assert(current_profile(session, hands[0], &ps) == XR_SUCCESS && ps.interactionProfile == touch);
        assert(current_profile(session, hands[1], &ps) == XR_SUCCESS && ps.interactionProfile == touch);
        XrActionStateGetInfo g3 = { .type = XR_TYPE_ACTION_STATE_GET_INFO, .action = a3[1], .subactionPath = hands[0] };
        XrActionStateFloat f3 = { .type = XR_TYPE_ACTION_STATE_FLOAT, .currentState = 5 };
        assert(float_state(session, &g3, &f3) == XR_SUCCESS && f3.isActive && f3.currentState == 0 && !f3.changedSinceLastSync);
        g3.subactionPath = hands[1];   /* no trigger binding on the right */
        assert(float_state(session, &g3, &f3) == XR_SUCCESS && !f3.isActive);
        g3.action = a3[0]; g3.subactionPath = XR_NULL_PATH;
        XrActionStateBoolean b3 = { .type = XR_TYPE_ACTION_STATE_BOOLEAN, .currentState = XR_TRUE };
        assert(bool_state(session, &g3, &b3) == XR_SUCCESS && b3.isActive && !b3.currentState);
        g3.action = a3[2]; g3.subactionPath = hands[1];
        XrActionStateVector2f v3 = { .type = XR_TYPE_ACTION_STATE_VECTOR2F };
        assert(vector_state(session, &g3, &v3) == XR_SUCCESS && v3.isActive && v3.currentState.x == 0 && v3.currentState.y == 0);
        g3.action = a3[3]; g3.subactionPath = hands[0];
        XrActionStatePose p3 = { .type = XR_TYPE_ACTION_STATE_POSE };
        assert(pose_state(session, &g3, &p3) == XR_SUCCESS && p3.isActive);
        next_sample = (KlNativeFrameSample){ .ticket = &dev, .frame_id = 1, .pose_id = 1,
            .predicted_display_time = 35, .predicted_display_period = 10, .should_render = XR_TRUE,
            .head_location_flags = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT,
            .local_from_head = { .orientation.w = 1, .position = {0, 1.6f, 0} },
            .head_from_eye = { { .orientation.w = 1, .position.x = -0.03f }, { .orientation.w = 1, .position.x = 0.03f } },
            .fov = { {-.8f,.8f,.8f,-.8f}, {-.8f,.8f,.8f,-.8f} } };
        XrFrameState fs3 = { .type = XR_TYPE_FRAME_STATE };
        assert(wait_frame(session, NULL, &fs3) == XR_SUCCESS);
        XrSpaceVelocity vel = { .type = XR_TYPE_SPACE_VELOCITY };
        XrSpaceLocation loc = { .type = XR_TYPE_SPACE_LOCATION, .next = &vel };
        const XrSpaceLocationFlags valid = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
        assert(locate_space(grip_left, local3, 35, &loc) == XR_SUCCESS && loc.locationFlags == valid && !vel.velocityFlags &&
               loc.pose.position.x == -0.2f && loc.pose.position.y == 1.1f && loc.pose.position.z == -0.35f);
        assert(locate_space(grip_right, local3, 35, &loc) == XR_SUCCESS && loc.locationFlags == valid &&
               loc.pose.position.x == 0.2f && fabsf(loc.pose.position.z + 0.45f) < 1e-6f);
        input_sample3.sample_id = 2; input_sample3.sample_time = 40; input_sample3.hand[0].controls.trigger = 0.75f;
        input_sample3.hand[0].controls.grip_position_tracked = XR_TRUE;
        assert(sync_actions(session, &sync3) == XR_SUCCESS);
        assert(poll_event(instance, (eb.type = XR_TYPE_EVENT_DATA_BUFFER, &eb)) == XR_EVENT_UNAVAILABLE);   /* same profiles, no event */
        g3.action = a3[1]; g3.subactionPath = hands[0];
        assert(float_state(session, &g3, &f3) == XR_SUCCESS && f3.isActive && f3.currentState == 0.75f && f3.changedSinceLastSync && f3.lastChangeTime == 40);
        assert(locate_space(grip_left, local3, 35, &loc) == XR_SUCCESS && loc.locationFlags == valid);   /* tracked bits are and-ed with LOCAL, which reports valid only */
        input_sample3.sample_id = 3; input_sample3.sample_time = 50; input_sample3.hand[1].profile = KL_NATIVE_INPUT_PROFILE_HTC_VIVE;
        assert(sync_actions(session, &sync3) == XR_SUCCESS);   /* vive was not suggested: right hand has no profile */
        assert(poll_event(instance, (eb.type = XR_TYPE_EVENT_DATA_BUFFER, &eb)) == XR_SUCCESS && eb.type == XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED);
        assert(current_profile(session, hands[1], &ps) == XR_SUCCESS && ps.interactionProfile == XR_NULL_PATH);
        assert(locate_space(grip_right, local3, 35, &loc) == XR_SUCCESS && loc.locationFlags == 0);
        g3.action = a3[0]; g3.subactionPath = hands[1];
        assert(bool_state(session, &g3, &b3) == XR_SUCCESS && !b3.isActive);
        input_sample3.sample_id = 4; input_sample3.sample_time = 60;
        input_sample3.hand[1] = (KlNativeInputHand3){ .controls = absent_hand(), .local_from_grip.orientation.w = 1 };
        assert(sync_actions(session, &sync3) == XR_ERROR_VALIDATION_FAILURE);   /* a disconnected hand carries no pose */
        assert(locate_space(grip_left, local3, 35, &loc) == XR_SUCCESS && loc.locationFlags == 0);   /* failed sync: nothing located */
        input_sample3.hand[1] = (KlNativeInputHand3){ .controls = absent_hand() };
        assert(sync_actions(session, &sync3) == XR_SUCCESS);
        assert(poll_event(instance, (eb.type = XR_TYPE_EVENT_DATA_BUFFER, &eb)) == XR_EVENT_UNAVAILABLE);   /* right was already without a profile */
        XrFrameBeginInfo fb = { .type = XR_TYPE_FRAME_BEGIN_INFO };
        XrFrameEndInfo fe = { .type = XR_TYPE_FRAME_END_INFO, .displayTime = 35, .environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE };
        assert(begin_frame3(session, &fb) == XR_SUCCESS && end_frame3(session, &fe) == XR_SUCCESS);
        injected = (KlNativeSessionEvent){ KL_NATIVE_SESSION_STOPPING, 70 };
        assert(poll_state(poll_event, instance) == XR_SESSION_STATE_STOPPING);
        ack_time = 71; assert(end(session) == XR_SUCCESS);
        assert(poll_state(poll_event, instance) == XR_SESSION_STATE_IDLE);
        assert(destroy_session(session) == XR_SUCCESS);
        assert(destroy_instance(instance) == XR_SUCCESS);
        assert(kl_native_configure_input2(&host2) == XR_SUCCESS);   /* back to version 2: action spaces refused */
        assert(new_instance(&ci, &instance) == XR_SUCCESS);
        assert(req(instance, 1, &r) == XR_SUCCESS);
        assert(new_session(instance, &si, &session) == XR_SUCCESS);
        GET(PFN_xrCreateActionSpace, action_space2, instance, "xrCreateActionSpace");
        XrSpace refused; assert(action_space2(session, &asc, &refused) == XR_ERROR_FUNCTION_UNSUPPORTED);
        assert(destroy_session(session) == XR_SUCCESS);
        assert(destroy_instance(instance) == XR_SUCCESS);
    }
    assert(kl_native_configure_image_sync(NULL) == XR_SUCCESS);
    assert(new_instance(&ci, &instance) == XR_SUCCESS);
    assert(req(instance, 1, &r) == XR_SUCCESS);
    assert(new_session(instance, &si, &session) == XR_SUCCESS);
    assert(new_swap(session, &sc, &swap) == XR_SUCCESS);
    assert(acquire(swap, NULL, &i0) == XR_ERROR_FUNCTION_UNSUPPORTED);
    assert(destroy_swap(swap) == XR_SUCCESS);
    assert(destroy_session(session) == XR_SUCCESS);
    assert(destroy_instance(instance) == XR_SUCCESS);
    assert(kl_native_configure_metal(NULL) == XR_SUCCESS);
    puts("Metal provider mock resource lifecycle: pass; no GPU or frame");
}
