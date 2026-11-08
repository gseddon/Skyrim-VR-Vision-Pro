/* Native pre-frame stereo configuration boundary; MIT, see ../LICENSE. */
#ifndef KL_NATIVE_VIEW_HOST_H
#define KL_NATIVE_VIEW_HOST_H
#include <openxr/openxr.h>
#include <stdint.h>
#define KL_NATIVE_VIEW_HOST_VERSION 1u
/* Values are the host drawable's actual supported configuration, not maximum
 * limits repurposed as recommendations. This query creates no frame ticket
 * and contains no tracked pose. The host may return an error until real
 * drawable configuration is available. */
typedef struct KlNativeViewConfiguration {
    XrBool32 primary_stereo_supported;
    XrBool32 opaque_supported;
    XrBool32 fov_mutable;
    XrViewConfigurationView view[2];
} KlNativeViewConfiguration;
typedef struct KlNativeViewHost {
    uint32_t version, struct_size;
    void *context;
    /* Native callback, serialized, non-reentrant, and valid until all
     * instances are destroyed. Fill both per-eye recommended and maximum
     * dimensions/sample counts and supported capabilities truthfully. */
    XrResult (*get_configuration)(void *context, KlNativeViewConfiguration *out);
} KlNativeViewHost;
XrResult kl_native_configure_views(const KlNativeViewHost *host);
#endif
