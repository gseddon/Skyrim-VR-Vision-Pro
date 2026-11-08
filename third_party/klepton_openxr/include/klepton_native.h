/* Klepton-derived provider, MIT; see ../LICENSE. Host pointers are native ABI. */
#ifndef KLEPTON_NATIVE_H
#define KLEPTON_NATIVE_H
#include <openxr/openxr.h>
#include <stdint.h>

/* Initial boundary only. Host state and callback remain valid until all
 * instances are destroyed. Access/configuration must be serialized by caller.
 * Return XR_SUCCESS only if an actual HMD system is available now, otherwise
 * XR_ERROR_FORM_FACTOR_UNAVAILABLE or an appropriate runtime failure. */
typedef struct KlNativeHost {
    uint32_t version;
    uint32_t size;
    void *context;
    XrResult (*hmd_available)(void *context);
    /* Optional; fills actual hardware capabilities in the supplied value.
     * Names must be NUL-terminated. Return an error when unavailable. */
    XrResult (*system_properties)(void *context, XrSystemProperties *out);
} KlNativeHost;
XrResult kl_native_configure(const KlNativeHost *host);
XRAPI_ATTR XrResult XRAPI_CALL kl_native_get_instance_proc_addr(
    XrInstance instance, const char *name, PFN_xrVoidFunction *function);
#endif
