/* Native Apple provider registration; GPL-3.0-or-later like xrizer. */
#ifndef XRIZER_PROVIDER_CONFIG_H
#define XRIZER_PROVIDER_CONFIG_H
#include <stdint.h>
#include <openxr/openxr.h>
/* Configure exactly once before initialization. The function pointer and host
 * callback state must remain valid for process lifetime. This only validates
 * OpenXR bootstrap dispatch and does not enable or prove a usable runtime. */
int32_t xrizer_configure_openxr_provider(PFN_xrGetInstanceProcAddr get_instance_proc_addr);
#endif
