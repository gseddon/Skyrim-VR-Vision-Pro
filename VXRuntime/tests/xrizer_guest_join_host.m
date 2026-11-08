// Owned joined fixture only. Native Rust tables remain behind these static stubs.
#import <Foundation/Foundation.h>
#include "vx.h"
#include "xrizer_guest_host.h"
#include <stdlib.h>
#include <string.h>

#include "xrizer_guest_bridge.h"
static vx_xrizer_guest_host *host;
static void require(int ok) { if (!ok) { vx_log("xrizer_guest_join: invalid fixture state/argument"); abort(); } }
static WINAPI void *FixtureGetClientCore(int *error) {
    require(!host);
    const char *path = getenv("VXRT_ABI_XRIZER_DYLIB");
    require(path && vx_xrizer_guest_host_create(path, NULL, &host) == 0 && host);
    void *core = vx_xrizer_guest_host_factory(host, "IVRClientCore_003", error);
    return core ? vx_xrizer_guest_core(core) : NULL;
}
static WINAPI int FixtureVerify(int after_cleanup) {
    vx_xrizer_guest_host_stats s; vx_xrizer_guest_host_get_stats(host, &s);
    vx_log("xrizer_guest_join: native stats waits %u publishes %u cancels %u lifecycle %u/%u/%u sessions %u/%u frame %llu pose %llu predicted %lld outstanding %u source %u/%u/%u",
           s.waits,s.publishes,s.cancels,s.begins,s.exits,s.ends,s.sessions_created,s.sessions_destroyed,
           (unsigned long long)s.frame_id,(unsigned long long)s.pose_id,(long long)s.predicted_display_time,s.outstanding,
           s.source_acquires,s.source_releases,s.source_copies);
    if (after_cleanup == -1) {
        int error = 0;
        if (vx_xrizer_guest_version("IVRSystem_999") != 106 ||
            vx_xrizer_guest_interface("IVRSystem_999", &error) || error != 106) return 1;
        return !(s.waits == 0 && s.publishes == 0 && s.cancels == 0 && s.outstanding == 0);
    }
    return !(s.waits == 1 && s.publishes == 0 && s.cancels == 1 && s.begins == 1 &&
             s.exits == (uint32_t)after_cleanup && s.ends == (uint32_t)after_cleanup && s.sessions_created == 1 &&
             s.sessions_destroyed == (uint32_t)after_cleanup && s.frame_id == 101 && s.pose_id == 201 &&
             s.predicted_display_time > 0 && s.outstanding == 0 && s.source_acquires == 0 && s.source_releases == 0 && s.source_copies == 0);
}
static WINAPI int FixtureFinish(void) { if (vx_xrizer_guest_reset()) return -1; return vx_xrizer_guest_host_finish(host); }
static const vx_export exports[] = { VX_EXPORT(FixtureGetClientCore), VX_EXPORT(FixtureVerify), VX_EXPORT(FixtureFinish) };
__attribute__((constructor)) static void register_fixture(void) {
    vx_register_module("vxrt_guest_join_fixture.dll", exports, sizeof exports / sizeof *exports);
}
#ifdef __aarch64__
#include "thunks/xrizer_guest_join_host.m.inc"
#endif
