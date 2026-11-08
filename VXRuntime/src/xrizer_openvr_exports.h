#ifndef VX_XRIZER_OPENVR_EXPORTS_H
#define VX_XRIZER_OPENVR_EXPORTS_H
#include <stddef.h>
#include "vx.h"
/* A host installs a real, configured ClientCore factory before guest startup.
 * The factory and its context remain alive through shutdown. No provider is
 * selected implicitly; experimental hosts must opt in separately. */
typedef void *(*vx_xrizer_core_factory)(void *context, int *error);
int vx_xrizer_openvr_configure(vx_xrizer_core_factory factory, void *context);
int vx_xrizer_openvr_enabled(void);
const vx_export *vx_xrizer_openvr_exports(size_t *count);
#endif
