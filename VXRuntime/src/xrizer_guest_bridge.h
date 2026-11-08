#ifndef VX_XRIZER_GUEST_BRIDGE_H
#define VX_XRIZER_GUEST_BRIDGE_H
/* One core generation per process; reset permanently prevents recreation. native tables remain private. Returned object and tables
 * contain only statically registered Windows ABI wrappers. Reset only after
 * the guest has called Cleanup; the caller owns the native core lifetime. */
void *vx_xrizer_guest_core(void *native_core);
/* Init/version return native EVRInitError, or nonzero on invalid state.
 * Interface preserves native error for supported versions; unsupported is 106. */
int vx_xrizer_guest_init(int type, const char *startup);
int vx_xrizer_guest_cleanup(void);
int vx_xrizer_guest_version(const char *name);
void *vx_xrizer_guest_interface(const char *name, int *error);
/* Native string only; a guest export must provide guest-addressable storage. */
const char *vx_xrizer_guest_error_description(int error);
int vx_xrizer_guest_reset(void);
#endif
