/* Typed, refusal-only OpenXR 1.0 entry points. Session/space/swapchain/action
 * handles do not yet exist. Replace each entry with real behavior as implemented. */
static XrResult XRAPI_CALL refuse_xrResultToString(XrInstance instance, XrResult value, char buffer[XR_MAX_RESULT_STRING_SIZE]) {
    (void)value;
    (void)buffer;
    return valid_instance(instance) ? XR_ERROR_FUNCTION_UNSUPPORTED : XR_ERROR_HANDLE_INVALID;
}
static XrResult XRAPI_CALL refuse_xrStructureTypeToString(XrInstance instance, XrStructureType value, char buffer[XR_MAX_STRUCTURE_NAME_SIZE]) {
    (void)value;
    (void)buffer;
    return valid_instance(instance) ? XR_ERROR_FUNCTION_UNSUPPORTED : XR_ERROR_HANDLE_INVALID;
}
static XrResult XRAPI_CALL refuse_xrGetReferenceSpaceBoundsRect(XrSession session, XrReferenceSpaceType referenceSpaceType, XrExtent2Df* bounds) {
    (void)referenceSpaceType;
    (void)bounds;
    return valid_session(session) ? XR_ERROR_FUNCTION_UNSUPPORTED : XR_ERROR_HANDLE_INVALID;
}
static XrResult XRAPI_CALL refuse_xrEnumerateBoundSourcesForAction(XrSession session, const XrBoundSourcesForActionEnumerateInfo* enumerateInfo, uint32_t sourceCapacityInput, uint32_t* sourceCountOutput, XrPath* sources) {
    (void)enumerateInfo;
    (void)sourceCapacityInput;
    (void)sourceCountOutput;
    (void)sources;
    return valid_session(session) ? XR_ERROR_FUNCTION_UNSUPPORTED : XR_ERROR_HANDLE_INVALID;
}
static XrResult XRAPI_CALL refuse_xrGetInputSourceLocalizedName(XrSession session, const XrInputSourceLocalizedNameGetInfo* getInfo, uint32_t bufferCapacityInput, uint32_t* bufferCountOutput, char* buffer) {
    (void)getInfo;
    (void)bufferCapacityInput;
    (void)bufferCountOutput;
    (void)buffer;
    return valid_session(session) ? XR_ERROR_FUNCTION_UNSUPPORTED : XR_ERROR_HANDLE_INVALID;
}
static XrResult XRAPI_CALL refuse_xrApplyHapticFeedback(XrSession session, const XrHapticActionInfo* hapticActionInfo, const XrHapticBaseHeader* hapticFeedback) {
    (void)hapticActionInfo;
    (void)hapticFeedback;
    return valid_session(session) ? XR_ERROR_FUNCTION_UNSUPPORTED : XR_ERROR_HANDLE_INVALID;
}
static XrResult XRAPI_CALL refuse_xrStopHapticFeedback(XrSession session, const XrHapticActionInfo* hapticActionInfo) {
    (void)hapticActionInfo;
    return valid_session(session) ? XR_ERROR_FUNCTION_UNSUPPORTED : XR_ERROR_HANDLE_INVALID;
}
