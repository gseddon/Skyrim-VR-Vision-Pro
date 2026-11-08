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

/* Static optical geometry, independent of a tracked head or frame ticket.
 * The host may change geometry_id when real drawable optics change. The
 * callback must fail until it has actual geometry; injected test geometry is
 * allowed only in explicitly selected fixtures. */
#define KL_NATIVE_VIEW_GEOMETRY_VERSION 1u
typedef struct KlNativeViewGeometry {
    uint32_t version, struct_size;
    uint64_t geometry_id;
    XrPosef head_from_eye[2];
    XrFovf fov[2];
} KlNativeViewGeometry;
typedef struct KlNativeViewGeometryHost {
    uint32_t version, struct_size;
    void *context;
    XrResult (*get_geometry)(void *context, KlNativeViewGeometry *out);
} KlNativeViewGeometryHost;
XrResult kl_native_configure_view_geometry(const KlNativeViewGeometryHost *host);
/* Private native-provider query resolved only by the explicit Apple frontend.
 * It creates no OpenXR frame, time, tracking observation or session state. */
typedef XrResult (XRAPI_PTR *PFN_xrGetVxStaticViewGeometry)(XrInstance, XrSystemId, KlNativeViewGeometry *);
#endif
